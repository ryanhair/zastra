//! JSON shapes shared by the C ABI (PLAN.md §9) and `dev serve` (§19.2):
//! run results, suspensions, workflow results and stream events. A client
//! written against one works against the other.

const std = @import("std");
const json = @import("../schema/json.zig");
const run = @import("../agent/run.zig");
const Allocator = std.mem.Allocator;

/// The C ABI's event kind numbers, by event tag.
pub fn eventKind(comptime tag: []const u8) c_int {
    const names = [_][]const u8{ "text_delta", "reasoning_delta", "tool_call", "tool_result", "approval_request", "step_finish", "finish", "output_partial", "output_partial_reset" };
    inline for (names, 0..) |n, i| if (comptime std.mem.eql(u8, n, tag)) return i;
    return 6;
}

/// An event's payload: raw text for text and reasoning deltas, `{}` for
/// `output_partial_reset`, JSON otherwise.
pub fn eventJson(arena: Allocator, event: anytype) ![]const u8 {
    switch (event) {
        inline else => |payload, tag| {
            const kind = comptime eventKind(@tagName(tag));
            if (comptime kind <= 1) return payload;
            if (comptime kind == 8) return "{}";
            return json.stringifyAlloc(arena, payload);
        },
    }
}

/// `{"status":"completed",...}` or, for gated agents,
/// `{"status":"suspended","run_id":...,"requests":[{"id","tool","input"}]}`.
pub fn runResultJson(comptime A: type, arena: Allocator, r: run.Result(A)) ![]const u8 {
    if (comptime !A.has_approvals) return agentResultJson(A, arena, r);
    return switch (r) {
        .completed => |c| agentResultJson(A, arena, c),
        .suspended => |su| suspendedJson(A, arena, su),
    };
}

pub fn suspendedJson(comptime A: type, arena: Allocator, su: run.Suspended(A)) ![]const u8 {
    var aw: std.Io.Writer.Allocating = .init(arena);
    const w = &aw.writer;
    try w.writeAll("{\"status\":\"suspended\",\"run_id\":");
    try json.writeString(su.run_id, w);
    try w.writeAll(",\"requests\":[");
    for (su.requests, 0..) |req, i| {
        if (i > 0) try w.writeByte(',');
        try w.writeAll("{\"id\":");
        try json.writeString(req.id, w);
        switch (req.call) {
            inline else => |input, tag| {
                try w.print(",\"tool\":\"{s}\",\"input\":", .{@tagName(tag)});
                try json.write(input, w);
            },
        }
        try w.writeByte('}');
    }
    try w.writeAll("]}");
    return aw.written();
}

pub fn agentResultJson(comptime A: type, arena: Allocator, r: run.GenerateResult(A)) ![]const u8 {
    var aw: std.Io.Writer.Allocating = .init(arena);
    const w = &aw.writer;
    try w.writeAll("{\"status\":\"completed\",\"text\":");
    try json.writeString(r.text, w);
    if (A.has_output_type) {
        try w.writeAll(",\"output\":");
        try json.write(r.output, w);
    }
    try w.print(",\"steps\":{d},\"finish_reason\":\"{t}\",\"run_id\":", .{ r.steps, r.finish_reason });
    try json.writeString(r.run_id, w);
    try w.writeAll(",\"usage\":");
    try json.write(r.usage, w);
    try w.writeByte('}');
    return aw.written();
}

pub fn workflowResultJson(comptime W: type, arena: Allocator, r: W.Result) ![]const u8 {
    var aw: std.Io.Writer.Allocating = .init(arena);
    const w = &aw.writer;
    switch (r) {
        inline else => |payload, tag| {
            const t = @tagName(tag);
            if (comptime std.mem.eql(u8, t, "completed")) {
                try w.writeAll("{\"status\":\"completed\",\"output\":");
                try json.write(payload, w);
                try w.writeByte('}');
            } else if (comptime std.mem.eql(u8, t, "suspended")) {
                try w.writeAll("{\"status\":\"suspended\",\"run_id\":");
                try json.writeString(payload.run_id, w);
                switch (payload.at) {
                    inline else => |p, at| {
                        try w.print(",\"at\":\"{s}\",\"payload\":", .{@tagName(at)});
                        try json.write(p, w);
                    },
                }
                try w.writeByte('}');
            } else {
                try w.writeAll("{\"status\":\"failed\",\"step\":");
                try json.writeString(payload.step, w);
                try w.print(",\"error\":\"{t}\",\"message\":", .{payload.err});
                try json.writeString(payload.message, w);
                try w.writeByte('}');
            }
        },
    }
    return aw.written();
}
