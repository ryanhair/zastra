//! OTLP export (PLAN.md §19.1, D49) and 128-bit trace ids.

const std = @import("std");
const z = @import("zastra");
const Fake = @import("fake_otlp.zig").Fake;
const t = std.testing;

const Ctx = struct {};

const LookupOrder = struct {
    pub const description = "Look up an order by its ID.";
    pub const Input = struct { order_id: []const u8 };
    pub const Output = struct { id: []const u8, total_cents: u32 };
    pub fn execute(tc: *z.ToolCtx(Ctx), in: Input) !Output {
        return .{ .id = try tc.arena.dupe(u8, in.order_id), .total_cents = 90_00 };
    }
};

const IssueRefund = struct {
    pub const description = "Refund an order.";
    pub const Input = struct { order_id: []const u8 };
    pub const Output = struct { refund_id: []const u8 };
    pub const needs_approval = true;
    pub fn execute(_: *z.ToolCtx(Ctx), _: Input) !Output {
        return .{ .refund_id = "R-1" };
    }
};

const Support = z.Agent(Ctx, .{
    .name = "support",
    .model = "anthropic/claude-sonnet-4-6",
    .instructions = "You help customers.",
    .tools = .{LookupOrder},
});
const Refunder = z.Agent(Ctx, .{
    .name = "refunder",
    .model = "anthropic/claude-sonnet-4-6",
    .instructions = "You handle refunds.",
    .tools = .{IssueRefund},
});
const App = z.App(.{ .ctx = Ctx, .agents = .{ Support, Refunder }, .storage = .sqlite });

/// One agent run with a tool call: 6 spans.
fn runOnce(h: anytype) !void {
    h.script(Support, &.{
        .tool(LookupOrder, .{ .order_id = "ORD-1" }),
        .text("ORD-1 totals $90."),
    });
    const r = try h.agent(Support).generate("Where is ORD-1?", .{});
    try t.expectEqualStrings("ORD-1 totals $90.", r.text);
}

fn otlp(f: *Fake, o: z.trace.OtlpOptions) z.trace.Config {
    var opts = o;
    opts.endpoint = f.url;
    return z.trace.otlp(opts);
}

/// Replace random ids, times and run ids so the body can be compared.
fn normalize(a: std.mem.Allocator, body: []const u8) ![]const u8 {
    var parsed = try std.json.parseFromSliceLeaky(std.json.Value, a, body, .{});
    var ids: std.StringHashMapUnmanaged([]const u8) = .empty;
    try walk(a, &parsed, &ids);
    return std.json.Stringify.valueAlloc(a, parsed, .{ .whitespace = .indent_2 });
}

fn walk(a: std.mem.Allocator, v: *std.json.Value, ids: *std.StringHashMapUnmanaged([]const u8)) !void {
    switch (v.*) {
        .object => |*o| {
            var it = o.iterator();
            while (it.next()) |e| {
                const k = e.key_ptr.*;
                if (std.mem.eql(u8, k, "traceId") or std.mem.eql(u8, k, "spanId") or std.mem.eql(u8, k, "parentSpanId")) {
                    const id = e.value_ptr.string;
                    const g = try ids.getOrPut(a, id);
                    if (!g.found_existing) g.value_ptr.* = try std.fmt.allocPrint(a, "{s}{d}", .{ if (k[0] == 't') "trace-" else "span-", ids.count() });
                    e.value_ptr.* = .{ .string = g.value_ptr.* };
                } else if (std.mem.endsWith(u8, k, "TimeUnixNano")) {
                    e.value_ptr.* = .{ .string = "<time>" };
                } else if (std.mem.eql(u8, k, "key") and e.value_ptr.* == .string and
                    (std.mem.eql(u8, e.value_ptr.string, "zastra.run_id") or std.mem.eql(u8, e.value_ptr.string, "zastra.prefix_hash")))
                {
                    o.getPtr("value").?.* = .{ .string = "<varies>" };
                } else try walk(a, e.value_ptr, ids);
            }
        },
        .array => |arr| for (arr.items) |*x| try walk(a, x, ids),
        else => {},
    }
}

test "OTLP: the body for one agent run with a tool call" {
    const f = try Fake.start(t.allocator, t.io);
    defer f.stop();
    var ctx: Ctx = .{};
    {
        var h = try z.testing.harness(App, .{ .ctx = &ctx, .tracing = otlp(f, .{ .service_name = "support-test" }) });
        defer h.deinit();
        try runOnce(h);
        // Nothing is sent before `rt.deinit()` with the default batch size.
        try t.expectEqual(@as(usize, 0), f.count());
    }
    try t.expectEqual(@as(usize, 1), f.count());
    const req = f.requests()[0];
    try t.expectEqualStrings("/v1/traces", req.path);
    try t.expectEqualStrings("application/json", req.content_type);
    var arena: std.heap.ArenaAllocator = .init(t.allocator);
    defer arena.deinit();
    const got = try normalize(arena.allocator(), req.body);
    const want = @embedFile("golden/otlp/agent_run.json");
    if (!std.mem.eql(u8, std.mem.trimEnd(u8, want, "\n"), got)) {
        std.debug.print("\n--- tests/golden/otlp/agent_run.json should be:\n{s}\n", .{got});
        return error.GoldenMismatch;
    }
}

test "OTLP: a batch goes out once `batch_size` spans are queued" {
    const f = try Fake.start(t.allocator, t.io);
    defer f.stop();
    var ctx: Ctx = .{};
    var h = try z.testing.harness(App, .{ .ctx = &ctx, .tracing = otlp(f, .{ .batch_size = 3, .interval_ms = 60_000 }) });
    defer h.deinit();
    try runOnce(h);
    try t.expect(f.waitFor(2, 2_000));
    for (f.requests()) |r| try t.expectEqual(@as(usize, 3), std.mem.count(u8, r.body, "\"spanId\""));
}

test "OTLP: a batch goes out every `interval_ms`" {
    const f = try Fake.start(t.allocator, t.io);
    defer f.stop();
    var ctx: Ctx = .{};
    var h = try z.testing.harness(App, .{ .ctx = &ctx, .tracing = otlp(f, .{ .interval_ms = 50 }) });
    defer h.deinit();
    try runOnce(h);
    try t.expect(f.waitFor(1, 2_000));
}

test "OTLP: a full queue drops the oldest spans" {
    const f = try Fake.start(t.allocator, t.io);
    defer f.stop();
    var ctx: Ctx = .{};
    {
        t.log_level = .err;
        defer t.log_level = .warn;
        var h = try z.testing.harness(App, .{ .ctx = &ctx, .tracing = otlp(f, .{ .queue_size = 2, .interval_ms = 60_000 }) });
        defer h.deinit();
        try runOnce(h);
    }
    try t.expectEqual(@as(usize, 1), f.count());
    const body = f.requests()[0].body;
    try t.expectEqual(@as(usize, 2), std.mem.count(u8, body, "\"spanId\""));
    // The last two to end: the second step, then the run.
    try t.expect(std.mem.indexOf(u8, body, "\"name\":\"agent_step support\"") != null);
    try t.expect(std.mem.indexOf(u8, body, "\"name\":\"invoke_agent support\"") != null);
}

test "OTLP: a collector error is retried, then dropped; the run succeeds" {
    const f = try Fake.start(t.allocator, t.io);
    defer f.stop();
    f.status.store(503, .release);
    var ctx: Ctx = .{};
    {
        t.log_level = .err;
        defer t.log_level = .warn;
        var h = try z.testing.harness(App, .{ .ctx = &ctx, .tracing = otlp(f, .{ .max_retries = 1 }) });
        defer h.deinit();
        try runOnce(h);
    }
    // The first attempt and one retry.
    try t.expectEqual(@as(usize, 2), f.count());
}

test "OTLP: defaults from OTEL_* environment variables" {
    const f = try Fake.start(t.allocator, t.io);
    defer f.stop();
    var env: std.process.Environ.Map = .init(t.allocator);
    defer env.deinit();
    try env.put("OTEL_EXPORTER_OTLP_ENDPOINT", f.url);
    try env.put("OTEL_EXPORTER_OTLP_HEADERS", "x-team=abc, x-note=two%20words");
    try env.put("OTEL_SERVICE_NAME", "from-env");
    var ctx: Ctx = .{};
    {
        var h = try z.testing.harness(App, .{ .ctx = &ctx, .env = &env, .tracing = z.trace.otlp(.{}) });
        defer h.deinit();
        try runOnce(h);
    }
    const req = f.requests()[0];
    try t.expectEqualStrings("abc", Fake.header(req, "x-team").?);
    try t.expectEqualStrings("two words", Fake.header(req, "x-note").?);
    try t.expect(std.mem.indexOf(u8, req.body, "{\"key\":\"service.name\",\"value\":{\"stringValue\":\"from-env\"}}") != null);
}

test "OTLP: explicit headers, one read from the environment" {
    const f = try Fake.start(t.allocator, t.io);
    defer f.stop();
    var env: std.process.Environ.Map = .init(t.allocator);
    defer env.deinit();
    try env.put("COLLECTOR_KEY", "secret");
    var ctx: Ctx = .{};
    {
        var h = try z.testing.harness(App, .{ .ctx = &ctx, .env = &env, .tracing = otlp(f, .{ .headers = &.{
            .{ "x-key", .{ .env = "COLLECTOR_KEY" } },
            .{ "x-plain", .{ .value = "v" } },
        } }) });
        defer h.deinit();
        try runOnce(h);
    }
    const req = f.requests()[0];
    try t.expectEqualStrings("secret", Fake.header(req, "x-key").?);
    try t.expectEqualStrings("v", Fake.header(req, "x-plain").?);
}

test "OTLP: without concurrency, batches are sent inline" {
    const f = try Fake.start(t.allocator, t.io);
    defer f.stop();
    const saved = t.io_instance.concurrent_limit;
    t.io_instance.concurrent_limit = .nothing;
    defer t.io_instance.concurrent_limit = saved;
    var ctx: Ctx = .{};
    {
        var h = try z.testing.harness(App, .{ .ctx = &ctx, .tracing = otlp(f, .{ .batch_size = 4 }) });
        defer h.deinit();
        try runOnce(h);
        // The fourth span to end filled a batch and sent it from `Span.end`.
        try t.expectEqual(@as(usize, 1), f.count());
    }
    try t.expectEqual(@as(usize, 2), f.count());
}

test "OTLP: content is opt-in" {
    const f = try Fake.start(t.allocator, t.io);
    defer f.stop();
    var ctx: Ctx = .{};
    {
        var h = try z.testing.harness(App, .{ .ctx = &ctx, .tracing = otlp(f, .{ .include_content = true }) });
        defer h.deinit();
        try runOnce(h);
        h.scriptModel("anthropic/claude-haiku-4-5", &.{.text("Hi there.")});
        _ = try h.model("anthropic/claude-haiku-4-5").generate(&.{.user("Say hi.")}, .{});
    }
    const body = f.requests()[0].body;
    try t.expect(std.mem.indexOf(u8, body, "gen_ai.input.messages") != null);
    try t.expect(std.mem.indexOf(u8, body, "Where is ORD-1?") != null);
    try t.expect(std.mem.indexOf(u8, body, "ORD-1 totals $90.") != null);
    // `rt.model` gets a root span of its own.
    try t.expect(std.mem.indexOf(u8, body, "\"name\":\"chat anthropic/claude-haiku-4-5\"") != null);
    try t.expect(std.mem.indexOf(u8, body, "Say hi.") != null);
}

fn tmpPath(buf: []u8, name: []const u8, ext: []const u8) ![]const u8 {
    std.Io.Dir.cwd().createDirPath(t.io, ".zig-cache/tmp") catch {};
    return std.fmt.bufPrint(buf, ".zig-cache/tmp/zastra-{s}-{d}.{s}", .{ name, std.Io.Clock.real.now(t.io).nanoseconds, ext });
}

test "trace ids: 128-bit and the same in every span, the JSONL file and the saved run" {
    var pbuf: [256]u8 = undefined;
    const trace_path = try tmpPath(&pbuf, "trace", "jsonl");
    defer std.Io.Dir.cwd().deleteFile(t.io, trace_path) catch {};
    const file = try std.Io.Dir.cwd().createFile(t.io, trace_path, .{ .read = true });
    defer file.close(t.io);

    var ctx: Ctx = .{};
    var h = try z.testing.harness(App, .{ .ctx = &ctx, .tracing = z.trace.jsonl(file) });
    defer h.deinit();
    h.script(Refunder, &.{.tool(IssueRefund, .{ .order_id = "ORD-1" })});
    const s = (try h.agent(Refunder).generate("Refund ORD-1", .{})).suspended;
    const a = h.arena.allocator();
    // The saved run, while suspended.
    const rec = (try h.rt.state().storage.?.loadRun(a, s.run_id)).?;
    h.script(Refunder, &.{.text("Refunded.")});
    _ = try h.agent(Refunder).resumeRun(s.run_id, &.{.{ .id = s.requests[0].id, .decision = .approve }});

    const text = try std.Io.Dir.cwd().readFileAlloc(t.io, trace_path, a, .limited(1 << 20));
    var trace_id: ?[]const u8 = null;
    var spans: usize = 0;
    var lines = std.mem.splitScalar(u8, text, '\n');
    while (lines.next()) |line| {
        if (line.len == 0) continue;
        const v = try std.json.parseFromSliceLeaky(std.json.Value, a, line, .{});
        const id = v.object.get("trace_id").?.string;
        try t.expectEqual(@as(usize, 32), id.len);
        if (trace_id) |want| try t.expectEqualStrings(want, id) else trace_id = id;
        spans += 1;
    }
    // Before and after the resume.
    try t.expect(spans >= 5);
    const needle = try std.fmt.allocPrint(a, "\"trace_id\":\"{s}\"", .{trace_id.?});
    try t.expect(std.mem.indexOf(u8, rec.state_json, needle) != null);
}
