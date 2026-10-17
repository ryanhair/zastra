//! OTLP/HTTP span exporter, JSON encoding (PLAN.md §19.1, D49).
//!
//! Referenced only from `z.trace.otlp(...)`, so Apps that trace to JSONL or
//! not at all link none of this. `Span.end` encodes the span and queues it;
//! a background task sends batches to `<endpoint>/v1/traces`. Export
//! failures are logged, never returned to a run.

const std = @import("std");
const trace = @import("trace.zig");
const json = @import("../schema/json.zig");
const http = @import("../provider/http.zig");
const Http = http.Http;
const Allocator = std.mem.Allocator;
const Io = std.Io;
const Writer = Io.Writer;

pub const Options = struct {
    /// Base URL; spans go to `<endpoint>/v1/traces`. Default:
    /// `OTEL_EXPORTER_OTLP_TRACES_ENDPOINT` (used as is), then
    /// `OTEL_EXPORTER_OTLP_ENDPOINT`, then `http://localhost:4318`.
    endpoint: ?[]const u8 = null,
    /// Request headers, e.g. `.{ "x-honeycomb-team", .{ .env = "HONEYCOMB_API_KEY" } }`.
    /// Default: `OTEL_EXPORTER_OTLP_HEADERS` (`k1=v1,k2=v2`).
    headers: []const Header = &.{},
    /// Default: `OTEL_SERVICE_NAME`, then "zastra".
    service_name: ?[]const u8 = null,
    /// Add prompts and responses to model spans (`gen_ai.input.messages`,
    /// `gen_ai.output.messages`).
    include_content: bool = false,
    /// Send once this many spans are queued...
    batch_size: u32 = 512,
    /// ...or this often.
    interval_ms: u32 = 2_000,
    /// Queued spans beyond this drop the oldest.
    queue_size: u32 = 2_048,
    /// `rt.deinit()` waits this long for the last batch.
    shutdown_timeout_ms: u32 = 5_000,
    /// Per request, until response headers.
    timeout_ms: u32 = 10_000,
    /// Retries for 429/5xx and connection errors.
    max_retries: u8 = 2,
};

pub const Header = struct { []const u8, HeaderValue };
pub const HeaderValue = union(enum) {
    value: []const u8,
    /// Read from this environment variable at `App.init`; a missing variable
    /// leaves the header out, with a warning.
    env: []const u8,
};

/// Called by `App.init` through `trace.Config.otlp.start`.
pub fn start(gpa: Allocator, io: Io, env: ?*const std.process.Environ.Map, ca_bundle: http.CaBundle, opts: Options) trace.StartError!trace.Exporter {
    const e = try gpa.create(Exporter);
    errdefer gpa.destroy(e);
    e.* = .{ .gpa = gpa, .io = io, .opts = opts, .http = undefined };
    errdefer e.freeConfig();
    try e.configure(env);
    e.http = if (std.mem.startsWith(u8, e.url, "https://"))
        Http.init(gpa, io, e.httpOptions(ca_bundle), env) catch |err| switch (err) {
            error.OutOfMemory, error.NoCaCertificates, error.CaBundleInvalid, error.Canceled => |x| return x,
            else => return error.CaBundleInvalid,
        }
    else
        Http.initPlain(gpa, io, e.httpOptions(ca_bundle), env);
    errdefer e.http.deinit();
    e.group.concurrent(io, Exporter.sendLoop, .{e}) catch {
        // No concurrency: batches are sent from `Span.end` and at deinit.
        e.background = false;
    };
    return .{ .ptr = e, .vtable = &vtable };
}

const vtable: trace.Exporter.VTable = .{
    .push = Exporter.push,
    .includeContent = Exporter.includeContent,
    .deinit = Exporter.deinit,
};

const Exporter = struct {
    gpa: Allocator,
    io: Io,
    opts: Options,
    http: Http,
    url: []const u8 = "",
    headers: []std.http.Header = &.{},
    /// The request body up to the first span.
    body_head: []const u8 = "",

    mutex: Io.Mutex = .init,
    queue: std.ArrayList([]u8) = .empty,
    dropped: u64 = 0,
    /// Serializes sends between the background task and `Span.end`.
    send_mutex: Io.Mutex = .init,
    last_warn_ms: ?i64 = null,

    background: bool = true,
    group: Io.Group = .init,
    wake: Io.Event = .unset,
    stopped: Io.Event = .unset,
    closing: std.atomic.Value(bool) = .init(false),

    fn configure(e: *Exporter, env: ?*const std.process.Environ.Map) Allocator.Error!void {
        const get = struct {
            fn f(m: ?*const std.process.Environ.Map, k: []const u8) ?[]const u8 {
                const v = (m orelse return null).get(k) orelse return null;
                return if (v.len == 0) null else v;
            }
        }.f;
        e.url = if (e.opts.endpoint) |ep|
            try std.fmt.allocPrint(e.gpa, "{s}/v1/traces", .{std.mem.trimEnd(u8, ep, "/")})
        else if (get(env, "OTEL_EXPORTER_OTLP_TRACES_ENDPOINT")) |u|
            try e.gpa.dupe(u8, u)
        else
            try std.fmt.allocPrint(e.gpa, "{s}/v1/traces", .{std.mem.trimEnd(u8, get(env, "OTEL_EXPORTER_OTLP_ENDPOINT") orelse "http://localhost:4318", "/")});

        var hs: std.ArrayList(std.http.Header) = .empty;
        errdefer {
            for (hs.items) |h| {
                e.gpa.free(h.name);
                e.gpa.free(h.value);
            }
            hs.deinit(e.gpa);
        }
        try hs.append(e.gpa, .{ .name = try e.gpa.dupe(u8, "content-type"), .value = try e.gpa.dupe(u8, "application/json") });
        if (e.opts.headers.len > 0) {
            for (e.opts.headers) |h| {
                const v = switch (h[1]) {
                    .value => |v| v,
                    .env => |k| get(env, k) orelse {
                        std.log.warn("zastra: OTLP header '{s}': {s} is not set; sending without it", .{ h[0], k });
                        continue;
                    },
                };
                try hs.append(e.gpa, .{ .name = try e.gpa.dupe(u8, h[0]), .value = try e.gpa.dupe(u8, v) });
            }
        } else if (get(env, "OTEL_EXPORTER_OTLP_HEADERS")) |list| {
            var it = std.mem.splitScalar(u8, list, ',');
            while (it.next()) |pair| {
                const eq = std.mem.indexOfScalar(u8, pair, '=') orelse continue;
                const k = std.mem.trim(u8, pair[0..eq], " ");
                if (k.len == 0) continue;
                const v = try percentDecode(e.gpa, std.mem.trim(u8, pair[eq + 1 ..], " "));
                errdefer e.gpa.free(v);
                try hs.append(e.gpa, .{ .name = try e.gpa.dupe(u8, k), .value = v });
            }
        }
        e.headers = try hs.toOwnedSlice(e.gpa);

        const service = e.opts.service_name orelse get(env, "OTEL_SERVICE_NAME") orelse "zastra";
        var w: Writer.Allocating = .init(e.gpa);
        defer w.deinit();
        const out = &w.writer;
        out.writeAll("{\"resourceSpans\":[{\"resource\":{\"attributes\":[") catch return error.OutOfMemory;
        writeStrAttr(out, "service.name", service) catch return error.OutOfMemory;
        out.writeByte(',') catch return error.OutOfMemory;
        writeStrAttr(out, "telemetry.sdk.name", "zastra") catch return error.OutOfMemory;
        out.writeByte(',') catch return error.OutOfMemory;
        writeStrAttr(out, "telemetry.sdk.language", "zig") catch return error.OutOfMemory;
        out.writeAll("]},\"scopeSpans\":[{\"scope\":{\"name\":\"zastra\"},\"spans\":[") catch return error.OutOfMemory;
        e.body_head = try w.toOwnedSlice();
    }

    fn httpOptions(e: *const Exporter, ca_bundle: http.CaBundle) http.Options {
        return .{ .ca_bundle = ca_bundle, .timeout_ms = e.opts.timeout_ms, .idle_timeout_ms = e.opts.timeout_ms, .max_retries = e.opts.max_retries, .base_backoff_ms = 200 };
    }

    fn freeConfig(e: *Exporter) void {
        e.gpa.free(e.url);
        for (e.headers) |h| {
            e.gpa.free(h.name);
            e.gpa.free(h.value);
        }
        e.gpa.free(e.headers);
        e.gpa.free(e.body_head);
    }

    fn includeContent(ptr: *anyopaque) bool {
        const e: *Exporter = @ptrCast(@alignCast(ptr));
        return e.opts.include_content;
    }

    fn push(ptr: *anyopaque, s: *const trace.Span, end_ns: i128) void {
        const e: *Exporter = @ptrCast(@alignCast(ptr));
        var w: Writer.Allocating = .init(e.gpa);
        writeSpan(&w.writer, s, end_ns) catch {
            w.deinit();
            return;
        };
        const bytes = w.toOwnedSlice() catch {
            w.deinit();
            return;
        };
        const full = blk: {
            e.mutex.lockUncancelable(e.io);
            defer e.mutex.unlock(e.io);
            if (e.queue.items.len >= e.opts.queue_size) {
                e.gpa.free(e.queue.orderedRemove(0));
                e.dropped += 1;
            }
            e.queue.append(e.gpa, bytes) catch {
                e.gpa.free(bytes);
                return;
            };
            break :blk e.queue.items.len >= e.opts.batch_size;
        };
        if (!full) return;
        if (e.background) e.wake.set(e.io) else e.flushAll();
    }

    fn sendLoop(e: *Exporter) void {
        defer e.stopped.set(e.io);
        while (true) {
            e.wake.waitTimeout(e.io, .{ .duration = .{ .raw = .fromMilliseconds(e.opts.interval_ms), .clock = .awake } }) catch |err| switch (err) {
                error.Timeout => {},
                error.Canceled => return,
            };
            e.wake.reset();
            const closing = e.closing.load(.acquire);
            e.flushAll();
            if (closing) return;
        }
    }

    /// Send everything queued, a batch at a time.
    fn flushAll(e: *Exporter) void {
        e.send_mutex.lockUncancelable(e.io);
        defer e.send_mutex.unlock(e.io);
        while (true) {
            var batch: std.ArrayList([]u8) = .empty;
            defer {
                for (batch.items) |b| e.gpa.free(b);
                batch.deinit(e.gpa);
            }
            const dropped = blk: {
                e.mutex.lockUncancelable(e.io);
                defer e.mutex.unlock(e.io);
                const n = @min(e.queue.items.len, e.opts.batch_size);
                batch.appendSlice(e.gpa, e.queue.items[0..n]) catch return;
                std.mem.copyForwards([]u8, e.queue.items, e.queue.items[n..]);
                e.queue.shrinkRetainingCapacity(e.queue.items.len - n);
                const d = e.dropped;
                e.dropped = 0;
                break :blk d;
            };
            if (dropped > 0) e.warn("the span queue was full; dropped the {d} oldest spans", .{dropped});
            if (batch.items.len == 0) return;
            e.send(batch.items) catch |err| switch (err) {
                error.Canceled => return,
            };
        }
    }

    fn send(e: *Exporter, spans: []const []u8) error{Canceled}!void {
        var w: Writer.Allocating = .init(e.gpa);
        defer w.deinit();
        const out = &w.writer;
        (blk: {
            out.writeAll(e.body_head) catch |x| break :blk x;
            for (spans, 0..) |s, i| {
                if (i > 0) out.writeByte(',') catch |x| break :blk x;
                out.writeAll(s) catch |x| break :blk x;
            }
            out.writeAll("]}]}]}") catch |x| break :blk x;
        }) catch return;
        const res = e.http.request(e.url, e.headers, w.written(), .{}) catch |err| switch (err) {
            error.Canceled => return error.Canceled,
            else => {
                e.warn("exporting {d} spans to {s}: {t}", .{ spans.len, e.url, err });
                return;
            },
        };
        defer res.close();
        if (!res.ok()) e.warn("exporting {d} spans to {s}: HTTP {d}", .{ spans.len, e.url, res.status });
    }

    /// At most one warning a minute.
    fn warn(e: *Exporter, comptime fmt: []const u8, args: anytype) void {
        const now: i64 = @intCast(@divFloor(Io.Clock.awake.now(e.io).nanoseconds, std.time.ns_per_ms));
        if (e.last_warn_ms) |last| if (now - last < 60_000) return;
        e.last_warn_ms = now;
        std.log.warn("zastra: OTLP: " ++ fmt, args);
    }

    fn deinit(ptr: *anyopaque) void {
        const e: *Exporter = @ptrCast(@alignCast(ptr));
        if (e.background) {
            e.closing.store(true, .release);
            e.wake.set(e.io);
            e.stopped.waitTimeout(e.io, .{ .duration = .{ .raw = .fromMilliseconds(e.opts.shutdown_timeout_ms), .clock = .awake } }) catch {};
            e.group.cancel(e.io);
        } else e.flushAll();
        for (e.queue.items) |b| e.gpa.free(b);
        e.queue.deinit(e.gpa);
        e.http.deinit();
        e.freeConfig();
        e.gpa.destroy(e);
    }
};

fn percentDecode(gpa: Allocator, s: []const u8) Allocator.Error![]u8 {
    const out = try gpa.alloc(u8, s.len);
    var n: usize = 0;
    var i: usize = 0;
    while (i < s.len) : (n += 1) {
        if (s[i] == '%' and i + 2 < s.len) {
            if (std.fmt.parseInt(u8, s[i + 1 .. i + 3], 16)) |b| {
                out[n] = b;
                i += 3;
                continue;
            } else |_| {}
        }
        out[n] = s[i];
        i += 1;
    }
    return gpa.realloc(out, n);
}

// ── encoding ─────────────────────────────────────────────────────────────────

/// zastra attribute keys → OpenTelemetry GenAI semantic conventions. Keys
/// not listed go out as `zastra.<key>`.
const renames = std.StaticStringMap([]const u8).initComptime(.{
    .{ "agent", "gen_ai.agent.name" },
    .{ "model", "gen_ai.request.model" },
    .{ "input_tokens", "gen_ai.usage.input_tokens" },
    .{ "output_tokens", "gen_ai.usage.output_tokens" },
    .{ "cache_read_tokens", "gen_ai.usage.cache_read.input_tokens" },
    .{ "tool", "gen_ai.tool.name" },
    .{ "input_messages", "gen_ai.input.messages" },
    .{ "output_messages", "gen_ai.output.messages" },
});

fn operation(kind: trace.Kind) ?[]const u8 {
    return switch (kind) {
        .agent_run => "invoke_agent",
        .model_call => "chat",
        .tool_call, .mcp_call => "execute_tool",
        else => null,
    };
}

pub fn writeSpan(w: *Writer, s: *const trace.Span, end_ns: i128) Writer.Error!void {
    try w.print("{{\"traceId\":\"{s}\",\"spanId\":\"{s}\"", .{ s.trace_id, s.span_id });
    if (s.parent_id) |p| try w.print(",\"parentSpanId\":\"{s}\"", .{p});
    try w.writeAll(",\"name\":");
    const name = if (operation(s.kind)) |op| op else @tagName(s.kind);
    try writeJoined(w, name, s.name);
    // SPAN_KIND_CLIENT for calls leaving the process, else INTERNAL.
    const kind: u8 = switch (s.kind) {
        .model_call, .mcp_call => 3,
        else => 1,
    };
    try w.print(",\"kind\":{d},\"startTimeUnixNano\":\"{d}\",\"endTimeUnixNano\":\"{d}\",\"attributes\":[", .{ kind, s.start_ns, end_ns });
    var first = true;
    if (operation(s.kind)) |op| {
        try writeStrAttr(w, "gen_ai.operation.name", op);
        first = false;
    }
    for (s.attrs_buf[0..s.attrs_len]) |a| {
        if (!first) try w.writeByte(',');
        first = false;
        if (std.mem.eql(u8, a.key, "finish_reason") and a.value == .str) {
            try w.writeAll("{\"key\":\"gen_ai.response.finish_reasons\",\"value\":{\"arrayValue\":{\"values\":[{\"stringValue\":");
            try json.writeString(a.value.str, w);
            try w.writeAll("}]}}}");
            continue;
        }
        try w.writeAll("{\"key\":");
        if (renames.get(a.key)) |k| try json.writeString(k, w) else try writeJoinedKey(w, a.key);
        try w.writeAll(",\"value\":");
        try writeValue(w, a.value);
        try w.writeByte('}');
        // The provider, from "provider/model".
        if (std.mem.eql(u8, a.key, "model") and a.value == .str and s.kind == .model_call) {
            if (std.mem.indexOfScalar(u8, a.value.str, '/')) |slash| {
                try w.writeByte(',');
                try writeStrAttr(w, "gen_ai.provider.name", a.value.str[0..slash]);
            }
        }
    }
    try w.writeByte(']');
    if (s.err) |msg| {
        try w.writeAll(",\"status\":{\"code\":2,\"message\":");
        try json.writeString(msg, w);
        try w.writeByte('}');
    }
    try w.writeByte('}');
}

fn writeJoined(w: *Writer, a: []const u8, b: []const u8) Writer.Error!void {
    try w.writeByte('"');
    try json.writeStringBody(a, w);
    try w.writeByte(' ');
    try json.writeStringBody(b, w);
    try w.writeByte('"');
}

fn writeJoinedKey(w: *Writer, key: []const u8) Writer.Error!void {
    try w.writeAll("\"zastra.");
    try json.writeStringBody(key, w);
    try w.writeByte('"');
}

fn writeStrAttr(w: *Writer, key: []const u8, v: []const u8) Writer.Error!void {
    try w.writeAll("{\"key\":");
    try json.writeString(key, w);
    try w.writeAll(",\"value\":{\"stringValue\":");
    try json.writeString(v, w);
    try w.writeAll("}}");
}

fn writeValue(w: *Writer, v: trace.Attr.Value) Writer.Error!void {
    switch (v) {
        .str => |x| {
            try w.writeAll("{\"stringValue\":");
            try json.writeString(x, w);
            try w.writeByte('}');
        },
        // OTLP/JSON carries 64-bit integers as strings.
        .int => |x| try w.print("{{\"intValue\":\"{d}\"}}", .{x}),
        .uint => |x| try w.print("{{\"intValue\":\"{d}\"}}", .{@min(x, std.math.maxInt(i64))}),
        .float => |x| try w.print("{{\"doubleValue\":{d}}}", .{x}),
        .boolean => |x| try w.print("{{\"boolValue\":{}}}", .{x}),
    }
}
