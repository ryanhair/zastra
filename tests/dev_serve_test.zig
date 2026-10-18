//! `dev serve` (PLAN.md §19.2, D50) against a harness runtime, over a real
//! socket with std.http.Client.

const std = @import("std");
const z = @import("zastra");
const t = std.testing;
const Io = std.Io;

const Gate = struct {
    open: Io.Event = .unset,
    entered: std.atomic.Value(u32) = .init(0),
};
const Ctx = struct {
    refunds: std.atomic.Value(u32) = .init(0),
    gate: Gate = .{},
};

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
    pub const Input = struct { order_id: []const u8, amount_cents: u32 };
    pub const Output = struct { refund_id: []const u8 };
    pub const needs_approval = true;
    pub const effects = .{ .reads, .writes, .spends_money };
    pub fn execute(tc: *z.ToolCtx(Ctx), _: Input) !Output {
        _ = tc.ctx.refunds.fetchAdd(1, .monotonic);
        return .{ .refund_id = "R-1" };
    }
};

/// Blocks until the test opens the gate.
const Wait = struct {
    pub const description = "Wait.";
    pub const Input = struct {};
    pub const Output = struct { ok: bool };
    pub fn execute(tc: *z.ToolCtx(Ctx), _: Input) !Output {
        _ = tc.ctx.gate.entered.fetchAdd(1, .release);
        try tc.ctx.gate.open.wait(tc.io);
        return .{ .ok = true };
    }
};

const Report = struct {
    summary: []const u8,
    score: u8,
    pub const stream_strings = .{.summary};
};

const Refunder = z.Agent(Ctx, .{
    .name = "refunder",
    .model = "anthropic/claude-sonnet-4-6",
    .instructions = "You handle refunds.",
    .tools = .{ LookupOrder, IssueRefund },
});
const Reporter = z.Agent(Ctx, .{ .name = "reporter", .model = "anthropic/claude-sonnet-4-6", .output = Report, .partial_output = true });
const Waiter = z.Agent(Ctx, .{ .name = "waiter", .model = "anthropic/claude-sonnet-4-6", .tools = .{Wait} });

const Claim = struct { order_id: []const u8, cents: u32 };
const Approve = struct {
    pub const Input = Claim;
    pub const Output = struct { refunded: bool, by: []const u8 };
    pub const Suspend = struct { order_id: []const u8 };
    pub const Resume = struct { approved: bool, by: []const u8 };
    pub fn run(w: *z.StepCtx(Ctx, @This()), in: Input) !z.Suspendable(@This()) {
        const d = w.resumed orelse return .{ .suspended = .{ .order_id = in.order_id } };
        return .{ .done = .{ .refunded = d.approved, .by = d.by } };
    }
};
const Flow = z.Workflow(Ctx, "refund_flow", Claim).then(Approve).commit();

const App = z.App(.{ .ctx = Ctx, .agents = .{ Refunder, Reporter, Waiter }, .workflows = .{Flow}, .storage = .sqlite });
const Server = z.dev.Server(App);

const Fixture = struct {
    ctx: Ctx = .{},
    h: *z.testing.Harness(App) = undefined,
    srv: *Server = undefined,
    trace_path: []const u8 = "",
    trace_file: Io.File = undefined,

    fn init(f: *Fixture, opts: z.dev.ServeOptions) !void {
        std.Io.Dir.cwd().createDirPath(t.io, ".zig-cache/tmp") catch {};
        f.trace_path = try t.allocator.print(".zig-cache/tmp/zastra-serve-{d}.jsonl", .{Io.Clock.real.now(t.io).nanoseconds});
        f.trace_file = try Io.Dir.cwd().createFile(t.io, f.trace_path, .{});
        f.h = try z.testing.harness(App, .{ .ctx = &f.ctx, .tracing = .{ .jsonl = .{ .file = f.trace_file, .append = true } } });
        var o = opts;
        o.port = 0;
        o.trace_file = f.trace_path;
        f.srv = try Server.init(t.allocator, t.io, &f.h.rt, o);
        try f.srv.start();
    }

    fn deinit(f: *Fixture) void {
        f.srv.deinit();
        f.h.deinit();
        f.trace_file.close(t.io);
        Io.Dir.cwd().deleteFile(t.io, f.trace_path) catch {};
        t.allocator.free(f.trace_path);
    }

    const Resp = struct { status: std.http.Status, body: []const u8 };

    fn call(f: *Fixture, arena: std.mem.Allocator, method: std.http.Method, path: []const u8, body: ?[]const u8, headers: []const std.http.Header, host: ?[]const u8) !Resp {
        var client: std.http.Client = .{ .allocator = t.allocator, .io = t.io };
        defer client.deinit();
        var aw: Io.Writer.Allocating = .init(arena);
        const url = try arena.print("http://127.0.0.1:{d}{s}", .{ f.srv.port(), path });
        const r = try client.fetch(.{
            .location = .{ .url = url },
            .method = method,
            .payload = body,
            .response_writer = &aw.writer,
            .extra_headers = headers,
            .headers = .{ .host = if (host) |hst| .{ .override = hst } else .default, .content_type = if (body != null) .{ .override = "application/json" } else .default },
            .keep_alive = false,
        });
        return .{ .status = r.status, .body = aw.written() };
    }

    fn get(f: *Fixture, arena: std.mem.Allocator, path: []const u8) !Resp {
        return f.call(arena, .GET, path, null, &.{}, null);
    }

    fn post(f: *Fixture, arena: std.mem.Allocator, path: []const u8, body: []const u8) !Resp {
        return f.call(arena, .POST, path, body, &.{}, null);
    }
};

const Event = struct { kind: []const u8, data: []const u8 };

fn sse(arena: std.mem.Allocator, body: []const u8) ![]const Event {
    var out: std.ArrayList(Event) = .empty;
    var blocks = std.mem.splitSequence(u8, body, "\n\n");
    while (blocks.next()) |b| {
        if (b.len == 0) continue;
        var kind: []const u8 = "";
        var data: std.ArrayList(u8) = .empty;
        var lines = std.mem.splitScalar(u8, b, '\n');
        while (lines.next()) |l| {
            if (std.mem.startsWith(u8, l, "event: ")) kind = l[7..];
            if (std.mem.startsWith(u8, l, "data: ")) {
                if (data.items.len > 0) try data.append(arena, '\n');
                try data.appendSlice(arena, l[6..]);
            }
        }
        try out.append(arena, .{ .kind = kind, .data = data.items });
    }
    return out.items;
}

fn kinds(arena: std.mem.Allocator, events: []const Event) ![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    for (events) |e| {
        // Collapse runs of the same kind (deltas, partials).
        const last_start = if (std.mem.lastIndexOfScalar(u8, out.items, ',')) |i| i + 1 else 0;
        if (out.items.len > 0 and std.mem.eql(u8, out.items[last_start..], e.kind)) continue;
        if (out.items.len > 0) try out.append(arena, ',');
        try out.appendSlice(arena, e.kind);
    }
    return out.items;
}

fn field(arena: std.mem.Allocator, text: []const u8, comptime path: []const []const u8) !std.json.Value {
    var v = try std.json.parseFromSliceLeaky(std.json.Value, arena, text, .{});
    inline for (path) |k| {
        if (k[0] == '#') {
            v = v.array.items[try std.fmt.parseInt(usize, k[1..], 10)];
        } else v = v.object.get(k) orelse return error.MissingField;
    }
    return v;
}

test "dev serve: agents, workflows, models and errors" {
    var arena: std.heap.ArenaAllocator = .init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var f: Fixture = .{};
    try f.init(.{});
    defer f.deinit();

    var r = try f.get(a, "/api/agents");
    try t.expectEqual(.ok, r.status);
    try t.expectEqualStrings("refunder", (try field(a, r.body, &.{ "#0", "id" })).string);
    try t.expectEqualStrings("spends_money", (try field(a, r.body, &.{ "#0", "tools", "#1", "effects", "#2" })).string);

    r = try f.get(a, "/api/agents/reporter");
    try t.expect((try field(a, r.body, &.{"partial_output"})).bool);
    r = try f.get(a, "/api/agents/nobody");
    try t.expectEqual(.not_found, r.status);
    try t.expectEqualStrings("UnknownAgent", (try field(a, r.body, &.{ "error", "code" })).string);

    r = try f.get(a, "/api/workflows");
    try t.expectEqualStrings("refund_flow", (try field(a, r.body, &.{ "#0", "id" })).string);
    r = try f.get(a, "/api/workflows/refund_flow/graph");
    try t.expect(std.mem.startsWith(u8, (try field(a, r.body, &.{"mermaid"})).string, "flowchart"));

    r = try f.get(a, "/api/models");
    try t.expectEqualStrings("anthropic/claude-sonnet-4-6", (try field(a, r.body, &.{ "#0", "model" })).string);

    r = try f.get(a, "/api/nothing");
    try t.expectEqual(.not_found, r.status);
    r = try f.post(a, "/api/agents/refunder/generate", "{\"input\":42}");
    try t.expectEqual(.bad_request, r.status);
    r = try f.post(a, "/api/agents/refunder/generate", "not json");
    try t.expectEqual(.bad_request, r.status);
    r = try f.post(a, "/api/workflows/refund_flow/start", "{\"input\":{\"order_id\":\"A\"}}");
    try t.expectEqual(.bad_request, r.status);
    try t.expect(std.mem.indexOf(u8, (try field(a, r.body, &.{ "error", "message" })).string, "cents") != null);
}

test "dev serve: generate, then stream with tool and partial-output events" {
    var arena: std.heap.ArenaAllocator = .init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var f: Fixture = .{};
    try f.init(.{});
    defer f.deinit();

    f.h.script(Refunder, &.{ .tool(LookupOrder, .{ .order_id = "ORD-1" }), .text("It's $90.") });
    var r = try f.post(a, "/api/agents/refunder/generate", "{\"input\":\"How much was ORD-1?\"}");
    try t.expectEqual(.ok, r.status);
    try t.expectEqualStrings("completed", (try field(a, r.body, &.{"status"})).string);
    try t.expectEqualStrings("It's $90.", (try field(a, r.body, &.{"text"})).string);

    f.h.script(Refunder, &.{ .tool(LookupOrder, .{ .order_id = "ORD-2" }), .text("Line one.\nLine two.") });
    r = try f.post(a, "/api/agents/refunder/stream", "{\"input\":[{\"role\":\"user\",\"content\":{\"type\":\"text\",\"value\":\"ORD-2?\"}}]}");
    try t.expectEqual(.ok, r.status);
    var events = try sse(a, r.body);
    try t.expectEqualStrings("tool_call,tool_result,step_finish,text_delta,step_finish,finish,result", try kinds(a, events));
    try t.expectEqualStrings("ORD-2", (try field(a, events[1].data, &.{"content"})).string[7..12]);
    // Text deltas are raw text (as in the C ABI); multi-line data reassembles.
    var text: std.ArrayList(u8) = .empty;
    for (events) |e| if (std.mem.eql(u8, e.kind, "text_delta")) try text.appendSlice(a, e.data);
    try t.expectEqualStrings("Line one.\nLine two.", text.items);

    f.h.script(Reporter, &.{.output(.{ .summary = "A long summary of the ticket, streamed as it grows.", .score = 3 })});
    r = try f.post(a, "/api/agents/reporter/stream", "{\"input\":\"Summarize.\"}");
    events = try sse(a, r.body);
    var partials: usize = 0;
    for (events) |e| if (std.mem.eql(u8, e.kind, "output_partial")) {
        partials += 1;
    };
    try t.expect(partials >= 1);
    try t.expectEqual(@as(i64, 3), (try field(a, events[events.len - 1].data, &.{ "output", "score" })).integer);
}

test "dev serve: an approval suspends the stream; resume/stream continues it" {
    var arena: std.heap.ArenaAllocator = .init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var f: Fixture = .{};
    try f.init(.{});
    defer f.deinit();

    f.h.script(Refunder, &.{.tool(IssueRefund, .{ .order_id = "ORD-1", .amount_cents = 90_00 })});
    var r = try f.post(a, "/api/agents/refunder/stream", "{\"input\":\"Refund ORD-1.\"}");
    var events = try sse(a, r.body);
    try t.expectEqualStrings("tool_call,approval_request,suspended", try kinds(a, events));
    const last = events[events.len - 1].data;
    const run_id = (try field(a, last, &.{"run_id"})).string;
    const call_id = (try field(a, last, &.{ "requests", "#0", "id" })).string;
    try t.expectEqualStrings("issue_refund", (try field(a, last, &.{ "requests", "#0", "tool" })).string);
    try t.expectEqual(0, f.ctx.refunds.load(.acquire));

    r = try f.get(a, "/api/runs?status=suspended&kind=agent");
    try t.expectEqualStrings(run_id, (try field(a, r.body, &.{ "#0", "run_id" })).string);
    try t.expect((try field(a, r.body, &.{ "#0", "resumable" })).bool);
    r = try f.get(a, try a.print("/api/runs/{s}", .{run_id}));
    try t.expectEqualStrings("suspended", (try field(a, r.body, &.{"status"})).string);

    f.h.script(Refunder, &.{.text("Refunded.")});
    r = try f.post(a, try a.print("/api/runs/{s}/resume/stream", .{run_id}), try a.print("{{\"decisions\":[{{\"id\":\"{s}\",\"approve\":true}}]}}", .{call_id}));
    events = try sse(a, r.body);
    try t.expectEqualStrings("tool_result,step_finish,text_delta,step_finish,finish,result", try kinds(a, events));
    try t.expectEqual(1, f.ctx.refunds.load(.acquire));

    // Resuming again: the run is done.
    r = try f.post(a, try a.print("/api/runs/{s}/resume", .{run_id}), "{}");
    try t.expectEqual(.conflict, r.status);

    // The run's spans are in the trace file.
    r = try f.get(a, try a.print("/api/traces/{s}", .{run_id}));
    try t.expectEqual(.ok, r.status);
    try t.expect((try std.json.parseFromSliceLeaky(std.json.Value, a, r.body, .{})).array.items.len >= 3);
}

test "dev serve: workflows start, suspend, resume and cancel" {
    var arena: std.heap.ArenaAllocator = .init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var f: Fixture = .{};
    try f.init(.{});
    defer f.deinit();

    var r = try f.post(a, "/api/workflows/refund_flow/start", "{\"input\":{\"order_id\":\"A\",\"cents\":5}}");
    try t.expectEqualStrings("suspended", (try field(a, r.body, &.{"status"})).string);
    const run_id = try a.dupe(u8, (try field(a, r.body, &.{"run_id"})).string);
    r = try f.post(a, try a.print("/api/runs/{s}/resume", .{run_id}), "{\"value\":{\"approved\":true}}");
    try t.expectEqual(.bad_request, r.status);
    r = try f.post(a, try a.print("/api/runs/{s}/resume", .{run_id}), "{\"step\":\"elsewhere\",\"value\":{\"approved\":true,\"by\":\"ryan\"}}");
    try t.expectEqual(.conflict, r.status);
    r = try f.post(a, try a.print("/api/runs/{s}/resume", .{run_id}), "{\"value\":{\"approved\":true,\"by\":\"ryan\"}}");
    try t.expectEqualStrings("completed", (try field(a, r.body, &.{"status"})).string);
    try t.expectEqualStrings("ryan", (try field(a, r.body, &.{ "output", "by" })).string);

    r = try f.post(a, "/api/workflows/refund_flow/start", "{\"input\":{\"order_id\":\"B\",\"cents\":5}}");
    const second = try a.dupe(u8, (try field(a, r.body, &.{"run_id"})).string);
    r = try f.post(a, try a.print("/api/runs/{s}/cancel", .{second}), "");
    try t.expectEqual(.ok, r.status);
    r = try f.post(a, try a.print("/api/runs/{s}/cancel", .{second}), "");
    try t.expectEqual(.conflict, r.status);
    r = try f.get(a, "/api/runs/nope");
    try t.expectEqual(.not_found, r.status);
}

test "dev serve: a second request runs while the first is busy; a client leaving cancels its run" {
    var arena: std.heap.ArenaAllocator = .init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var f: Fixture = .{};
    try f.init(.{});
    defer f.deinit();

    // Four steps; the first blocks in a tool until the gate opens.
    f.h.script(Waiter, &.{ .tool(Wait, .{}), .tool(Wait, .{}), .tool(Wait, .{}), .text("done") });
    const addr: Io.net.IpAddress = try .parseIp4("127.0.0.1", f.srv.port());
    var conn = try addr.connect(t.io, .{ .mode = .stream });
    {
        var wbuf: [512]u8 = undefined;
        var w = conn.writer(t.io, &wbuf);
        const body = "{\"input\":\"wait\"}";
        try w.interface.print("POST /api/agents/waiter/stream HTTP/1.1\r\nhost: 127.0.0.1\r\ncontent-type: application/json\r\ncontent-length: {d}\r\n\r\n{s}", .{ body.len, body });
        try w.interface.flush();
    }
    while (f.ctx.gate.entered.load(.acquire) == 0) try t.io.sleep(.fromMilliseconds(5), .awake);

    // The server answers others meanwhile.
    f.h.script(Refunder, &.{.text("hi")});
    const r = try f.post(a, "/api/agents/refunder/generate", "{\"input\":\"hi\"}");
    try t.expectEqualStrings("hi", (try field(a, r.body, &.{"text"})).string);

    // The client leaves; the run stops at its next event instead of
    // working through the rest of the script.
    conn.close(t.io);
    f.ctx.gate.open.set(t.io);
    var waited: u32 = 0;
    while (f.ctx.gate.entered.load(.acquire) < 3 and waited < 500) : (waited += 10) try t.io.sleep(.fromMilliseconds(10), .awake);
    try t.expect(f.h.remaining(Waiter) >= 1);
}

test "dev serve: Host, Origin, token and body-size rules" {
    var arena: std.heap.ArenaAllocator = .init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    // A non-loopback host needs a token.
    {
        var ctx: Ctx = .{};
        const h = try z.testing.harness(App, .{ .ctx = &ctx });
        defer h.deinit();
        try t.expectError(error.NeedsToken, Server.init(t.allocator, t.io, &h.rt, .{ .host = "0.0.0.0", .port = 0 }));
    }

    var f: Fixture = .{};
    try f.init(.{ .token = "s3cret", .allow_origin = "http://localhost:5173" });
    defer f.deinit();
    const auth: []const std.http.Header = &.{.{ .name = "authorization", .value = "Bearer s3cret" }};

    var r = try f.call(a, .GET, "/api/agents", null, &.{}, null);
    try t.expectEqual(.unauthorized, r.status);
    r = try f.call(a, .GET, "/api/agents", null, &.{.{ .name = "authorization", .value = "Bearer wrong!" }}, null);
    try t.expectEqual(.unauthorized, r.status);
    r = try f.call(a, .GET, "/api/agents", null, auth, null);
    try t.expectEqual(.ok, r.status);

    // DNS rebinding: a page on evil.example resolving to 127.0.0.1.
    r = try f.call(a, .GET, "/api/agents", null, auth, "evil.example");
    try t.expectEqual(.forbidden, r.status);
    r = try f.call(a, .GET, "/api/agents", null, auth, "localhost:4111");
    try t.expectEqual(.ok, r.status);

    // Cross-site requests from a browser.
    r = try f.call(a, .GET, "/api/agents", null, auth ++ &[_]std.http.Header{.{ .name = "origin", .value = "https://evil.example" }}, null);
    try t.expectEqual(.forbidden, r.status);
    r = try f.call(a, .GET, "/api/agents", null, auth ++ &[_]std.http.Header{.{ .name = "origin", .value = "http://localhost:3000" }}, null);
    try t.expectEqual(.ok, r.status);

    // Oversized bodies are refused from the Content-Length, before reading.
    const addr: Io.net.IpAddress = try .parseIp4("127.0.0.1", f.srv.port());
    var conn = try addr.connect(t.io, .{ .mode = .stream });
    defer conn.close(t.io);
    var wbuf: [512]u8 = undefined;
    var w = conn.writer(t.io, &wbuf);
    try w.interface.writeAll("POST /api/agents/refunder/generate HTTP/1.1\r\nhost: localhost\r\nauthorization: Bearer s3cret\r\ncontent-length: 1048577\r\n\r\n");
    try w.interface.flush();
    var rbuf: [1024]u8 = undefined;
    var rd = conn.reader(t.io, &rbuf);
    const line = try rd.interface.takeDelimiterExclusive('\n');
    try t.expect(std.mem.startsWith(u8, line, "HTTP/1.1 413"));
}

/// Volatile values out of a response: run ids, times, durations, span ids.
fn scrub(arena: std.mem.Allocator, text: []const u8) ![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    var i: usize = 0;
    const keys = [_][]const u8{ "elapsed_ms", "created_at", "updated_at", "start_ns", "end_ns", "trace_id", "span_id", "parent_id", "duration_ms", "prefix_hash" };
    outer: while (i < text.len) {
        if (std.mem.startsWith(u8, text[i..], "run_") and i + 20 <= text.len and isHex(text[i + 4 .. i + 20])) {
            try out.appendSlice(arena, "run_X");
            i += 20;
            continue;
        }
        for (keys) |k| {
            if (text[i] == '"' and std.mem.startsWith(u8, text[i + 1 ..], k) and std.mem.startsWith(u8, text[i + 1 + k.len ..], "\":")) {
                try out.print(arena, "\"{s}\":", .{k});
                i += k.len + 3;
                // Skip the value: a string or a number.
                if (i < text.len and text[i] == '"') {
                    const end = std.mem.indexOfScalarPos(u8, text, i + 1, '"') orelse text.len;
                    i = end + 1;
                } else while (i < text.len and (std.ascii.isDigit(text[i]) or text[i] == '-')) i += 1;
                try out.append(arena, '_');
                continue :outer;
            }
        }
        try out.append(arena, text[i]);
        i += 1;
    }
    return out.items;
}

fn isHex(s: []const u8) bool {
    for (s) |ch| if (!std.ascii.isHex(ch)) return false;
    return true;
}

test "dev serve: every response shape (golden)" {
    var arena: std.heap.ArenaAllocator = .init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var f: Fixture = .{};
    try f.init(.{});
    defer f.deinit();
    var log: std.ArrayList(u8) = .empty;

    const Call = struct { m: std.http.Method, path: []const u8, body: ?[]const u8 = null };
    const record = struct {
        fn record(fx: *Fixture, aa: std.mem.Allocator, l: *std.ArrayList(u8), c: Call) ![]const u8 {
            const r = try fx.call(aa, c.m, c.path, c.body, &.{}, null);
            const head = try aa.print("### {t} {s}{s}{s}", .{ c.m, c.path, if (c.body != null) " " else "", c.body orelse "" });
            try l.print(aa, "{s}\n{d}\n{s}\n\n", .{ try scrub(aa, head), @backingInt(r.status), try scrub(aa, r.body) });
            return r.body;
        }
    }.record;

    _ = try record(&f, a, &log, .{ .m = .GET, .path = "/api/agents/refunder" });
    _ = try record(&f, a, &log, .{ .m = .GET, .path = "/api/workflows" });
    _ = try record(&f, a, &log, .{ .m = .GET, .path = "/api/workflows/refund_flow/graph" });
    _ = try record(&f, a, &log, .{ .m = .GET, .path = "/api/models" });
    f.h.script(Refunder, &.{ .tool(LookupOrder, .{ .order_id = "ORD-1" }), .text("It's $90.") });
    _ = try record(&f, a, &log, .{ .m = .POST, .path = "/api/agents/refunder/generate", .body = "{\"input\":\"ORD-1?\"}" });
    f.h.script(Reporter, &.{.output(.{ .summary = "Short.", .score = 3 })});
    _ = try record(&f, a, &log, .{ .m = .POST, .path = "/api/agents/reporter/stream", .body = "{\"input\":\"Summarize.\"}" });
    f.h.script(Refunder, &.{.tool(IssueRefund, .{ .order_id = "ORD-1", .amount_cents = 90_00 })});
    const susp = try record(&f, a, &log, .{ .m = .POST, .path = "/api/agents/refunder/stream", .body = "{\"input\":\"Refund ORD-1.\"}" });
    const ev = try sse(a, susp);
    const run_id = (try field(a, ev[ev.len - 1].data, &.{"run_id"})).string;
    const call_id = (try field(a, ev[ev.len - 1].data, &.{ "requests", "#0", "id" })).string;
    _ = try record(&f, a, &log, .{ .m = .GET, .path = "/api/runs?kind=agent" });
    _ = try record(&f, a, &log, .{ .m = .GET, .path = try a.print("/api/runs/{s}", .{run_id}) });
    f.h.script(Refunder, &.{.text("Refunded.")});
    _ = try record(&f, a, &log, .{ .m = .POST, .path = try a.print("/api/runs/{s}/resume", .{run_id}), .body = try a.print("{{\"decisions\":[{{\"id\":\"{s}\",\"approve\":true}}]}}", .{call_id}) });
    const started = try record(&f, a, &log, .{ .m = .POST, .path = "/api/workflows/refund_flow/start", .body = "{\"input\":{\"order_id\":\"A\",\"cents\":5}}" });
    const wf_run = (try field(a, started, &.{"run_id"})).string;
    _ = try record(&f, a, &log, .{ .m = .POST, .path = try a.print("/api/runs/{s}/resume", .{wf_run}), .body = "{\"value\":{\"approved\":true,\"by\":\"ryan\"}}" });
    const second = try record(&f, a, &log, .{ .m = .POST, .path = "/api/workflows/refund_flow/start", .body = "{\"input\":{\"order_id\":\"B\",\"cents\":5}}" });
    _ = try record(&f, a, &log, .{ .m = .POST, .path = try a.print("/api/runs/{s}/cancel", .{(try field(a, second, &.{"run_id"})).string}), .body = "" });
    // The same approval, continued as a stream.
    f.h.script(Refunder, &.{.tool(IssueRefund, .{ .order_id = "ORD-2", .amount_cents = 10_00 })});
    const susp2 = try sse(a, (try f.post(a, "/api/agents/refunder/stream", "{\"input\":\"Refund ORD-2.\"}")).body);
    const run2 = (try field(a, susp2[susp2.len - 1].data, &.{"run_id"})).string;
    const call2 = (try field(a, susp2[susp2.len - 1].data, &.{ "requests", "#0", "id" })).string;
    f.h.script(Refunder, &.{.text("Done.")});
    _ = try record(&f, a, &log, .{ .m = .POST, .path = try a.print("/api/runs/{s}/resume/stream", .{run2}), .body = try a.print("{{\"decisions\":[{{\"id\":\"{s}\",\"deny\":\"Too much.\"}}]}}", .{call2}) });
    _ = try record(&f, a, &log, .{ .m = .GET, .path = try a.print("/api/traces/{s}", .{run2}) });
    _ = try record(&f, a, &log, .{ .m = .POST, .path = "/api/agents/refunder/generate", .body = "{\"input\":7}" });
    _ = try record(&f, a, &log, .{ .m = .GET, .path = "/api/runs/nope" });

    const path = "tests/golden/dev_serve/session.txt";
    if (std.c.getenv("ZASTRA_UPDATE_GOLDEN") != null) {
        try Io.Dir.cwd().createDirPath(t.io, "tests/golden/dev_serve");
        try Io.Dir.cwd().writeFile(t.io, .{ .sub_path = path, .data = log.items });
        return;
    }
    const want = Io.Dir.cwd().readFileAlloc(t.io, path, a, .limited(1 << 20)) catch |err| {
        std.debug.print("can't read {s} ({t}); run with ZASTRA_UPDATE_GOLDEN=1 to create it\n", .{ path, err });
        return err;
    };
    try t.expectEqualStrings(want, log.items);
}
