//! Tracing (PLAN.md §6.8): spans written as JSON lines.
//!
//! Span kinds: agent_run, agent_step, model_call, tool_call, workflow_run,
//! workflow_step, mcp_call. Prompt and response bodies are excluded unless
//! `include_content` is set.

const std = @import("std");
const json = @import("../schema/json.zig");
const Io = std.Io;

pub const Kind = enum { agent_run, agent_step, model_call, tool_call, workflow_run, workflow_step, mcp_call };

pub const Config = union(enum) {
    off,
    jsonl: Jsonl,

    pub const Jsonl = struct {
        file: Io.File,
        include_content: bool = false,
    };
};

/// `z.trace.jsonl(file)`
pub fn jsonl(file: Io.File) Config {
    return .{ .jsonl = .{ .file = file } };
}

pub const Attr = struct {
    key: []const u8,
    value: Value,

    pub const Value = union(enum) {
        str: []const u8,
        int: i64,
        uint: u64,
        float: f64,
        boolean: bool,
    };
};

pub const Tracer = struct {
    io: Io,
    config: Config,
    mutex: Io.Mutex = .init,

    pub fn enabled(t: *const Tracer) bool {
        return t.config != .off;
    }

    pub fn includeContent(t: *const Tracer) bool {
        return switch (t.config) {
            .off => false,
            .jsonl => |j| j.include_content,
        };
    }

    pub fn newId(t: *Tracer) [16]u8 {
        var raw: [8]u8 = undefined;
        t.io.random(&raw);
        var out: [16]u8 = undefined;
        _ = std.fmt.bufPrint(&out, "{x:0>16}", .{std.mem.readInt(u64, &raw, .little)}) catch unreachable;
        return out;
    }

    pub fn now(t: *Tracer) i128 {
        return Io.Clock.real.now(t.io).nanoseconds;
    }

    /// Begin a span. Call `end` exactly once.
    pub fn begin(t: *Tracer, kind: Kind, name: []const u8, trace_id: [16]u8, parent: ?*const Span) Span {
        return .{
            .tracer = t,
            .kind = kind,
            .name = name,
            .trace_id = trace_id,
            .span_id = if (t.enabled()) t.newId() else @splat('0'),
            .parent_id = if (parent) |p| p.span_id else null,
            .start_ns = if (t.enabled()) t.now() else 0,
        };
    }
};

pub const Span = struct {
    tracer: *Tracer,
    kind: Kind,
    name: []const u8,
    trace_id: [16]u8,
    span_id: [16]u8,
    parent_id: ?[16]u8,
    start_ns: i128,
    attrs_buf: [24]Attr = undefined,
    attrs_len: usize = 0,
    err: ?[]const u8 = null,

    pub fn attr(s: *Span, key: []const u8, value: anytype) void {
        if (s.attrs_len == s.attrs_buf.len) return;
        const T = @TypeOf(value);
        const v: Attr.Value = switch (@typeInfo(T)) {
            .bool => .{ .boolean = value },
            .int, .comptime_int => if (value < 0) .{ .int = @intCast(value) } else .{ .uint = @intCast(value) },
            .float, .comptime_float => .{ .float = @floatCast(value) },
            else => .{ .str = value },
        };
        s.attrs_buf[s.attrs_len] = .{ .key = key, .value = v };
        s.attrs_len += 1;
    }

    pub fn fail(s: *Span, message: []const u8) void {
        s.err = message;
    }

    pub fn end(s: *Span) void {
        const t = s.tracer;
        const cfg = switch (t.config) {
            .off => return,
            .jsonl => |j| j,
        };
        const end_ns = t.now();
        var buf: [8192]u8 = undefined;
        var w: Io.Writer = .fixed(&buf);
        s.write(&w, end_ns) catch {
            // Oversized span (long content): drop attributes rather than fail.
            w = .fixed(&buf);
            s.attrs_len = 0;
            s.write(&w, end_ns) catch return;
        };
        t.mutex.lockUncancelable(t.io);
        defer t.mutex.unlock(t.io);
        cfg.file.writeStreamingAll(t.io, w.buffered()) catch {};
    }

    fn write(s: *Span, w: *Io.Writer, end_ns: i128) Io.Writer.Error!void {
        try w.print("{{\"trace_id\":\"{s}\",\"span_id\":\"{s}\"", .{ s.trace_id, s.span_id });
        if (s.parent_id) |p| try w.print(",\"parent_id\":\"{s}\"", .{p}) else try w.writeAll(",\"parent_id\":null");
        try w.writeAll(",\"name\":");
        try json.writeString(s.name, w);
        try w.print(",\"kind\":\"{t}\",\"start_ns\":{d},\"end_ns\":{d},\"status\":\"{s}\"", .{
            s.kind, s.start_ns, end_ns, if (s.err == null) "ok" else "error",
        });
        if (s.err) |e| {
            try w.writeAll(",\"error\":");
            try json.writeString(e, w);
        }
        try w.writeAll(",\"attrs\":{");
        for (s.attrs_buf[0..s.attrs_len], 0..) |a, i| {
            if (i > 0) try w.writeByte(',');
            try json.writeString(a.key, w);
            try w.writeByte(':');
            switch (a.value) {
                .str => |v| try json.writeString(v, w),
                .int => |v| try w.print("{d}", .{v}),
                .uint => |v| try w.print("{d}", .{v}),
                .float => |v| try w.print("{d}", .{v}),
                .boolean => |v| try w.writeAll(if (v) "true" else "false"),
            }
        }
        try w.writeAll("}}\n");
    }
};
