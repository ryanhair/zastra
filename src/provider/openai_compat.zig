//! OpenAI-compatible Chat Completions provider (PLAN.md §6.2). Covers OpenAI
//! and, through `z.custom`, OpenRouter, Groq, Together, Ollama, vLLM, ...

const std = @import("std");
const p = @import("provider.zig");
const msg = @import("../message.zig");
const sse = @import("sse.zig");
const http = @import("http.zig");
const Allocator = std.mem.Allocator;
const Writer = std.Io.Writer;

pub const name = "openai";

const text_index: u32 = 1_000_000;
const reasoning_index: u32 = 1_000_001;

pub fn buildPrefix(comptime parts: p.PrefixParts) p.Prefix {
    comptime {
        @setEvalBranchQuota(10_000_000);
        const s = parts.spec;
        var j: []const u8 = "{\"model\":" ++ p.jsonStr(s.id) ++ ",\"stream\":true,\"stream_options\":{\"include_usage\":true}";
        var insert_at: ?usize = null;
        if (parts.tools.len > 0 or parts.dynamic_tools) {
            j = j ++ ",\"tools\":[";
            for (parts.tools, 0..) |t, i| {
                j = j ++ (if (i == 0) "" else ",") ++ "{\"type\":\"function\",\"function\":{\"name\":" ++ p.jsonStr(t.name) ++
                    ",\"description\":" ++ p.jsonStr(t.description) ++
                    ",\"parameters\":" ++ t.schema ++
                    (if (t.strict_ok) ",\"strict\":true" else "") ++ "}}";
            }
            if (parts.dynamic_tools) insert_at = j.len;
            j = j ++ "]";
        }
        if (parts.output) |o| j = j ++ ",\"response_format\":{\"type\":\"json_schema\",\"json_schema\":{\"name\":" ++
            p.jsonStr(o.name) ++ ",\"schema\":" ++ o.schema ++ ",\"strict\":true}}";
        if (parts.temperature) |t| j = j ++ std.fmt.comptimePrint(",\"temperature\":{d}", .{t});
        if (parts.effort) |e| if (s.supports.reasoning) {
            j = j ++ ",\"reasoning_effort\":\"" ++ switch (e) {
                .low => "low",
                .medium => "medium",
                .high, .xhigh, .max => "high",
            } ++ "\"";
        };
        if (parts.extra) |x| j = j ++ "," ++ x;
        j = j ++ ",\"messages\":[";
        var open: u32 = 0;
        if (parts.system) |sys| {
            j = j ++ "{\"role\":\"system\",\"content\":" ++ p.jsonStr(sys) ++ "}";
            open = 1;
        }
        return .{ .json = j, .open_items = open, .hash = p.prefixHash(j), .tools_insert_at = insert_at, .static_tools = parts.tools.len };
    }
}

/// A runtime tool definition (MCP). Not strict: MCP schemas are arbitrary.
pub fn writeToolDef(w: *Writer, tool_name: []const u8, description: []const u8, schema_json: []const u8) Writer.Error!void {
    try w.writeAll("{\"type\":\"function\",\"function\":{\"name\":");
    try p.W.str(w, tool_name);
    try w.writeAll(",\"description\":");
    try p.W.str(w, description);
    try w.writeAll(",\"parameters\":");
    try w.writeAll(schema_json);
    try w.writeAll("}}");
}

pub fn writeBody(w: *Writer, req: p.Request) Writer.Error!void {
    try w.writeAll(req.prefix.json);
    var n: usize = req.prefix.open_items;
    if (req.system_suffix) |sfx| if (sfx.len > 0) {
        if (n > 0) try w.writeByte(',');
        try w.writeAll("{\"role\":\"system\",\"content\":");
        try p.W.str(w, sfx);
        try w.writeByte('}');
        n += 1;
    };
    for (req.messages) |m| try writeMessage(w, m, &n);
    try w.print("],\"{t}\":{d}", .{ req.max_tokens_field, req.max_tokens });
    switch (req.tool_choice) {
        .auto => {},
        .none => try w.writeAll(",\"tool_choice\":\"none\""),
        .required => try w.writeAll(",\"tool_choice\":\"required\""),
        .tool => |t| {
            try w.writeAll(",\"tool_choice\":{\"type\":\"function\",\"function\":{\"name\":");
            try p.W.str(w, t);
            try w.writeAll("}}");
        },
    }
    try w.writeByte('}');
}

fn sep(w: *Writer, n: *usize) Writer.Error!void {
    if (n.* > 0) try w.writeByte(',');
    n.* += 1;
}

fn writeMessage(w: *Writer, m: msg.Message, n: *usize) Writer.Error!void {
    switch (m.role) {
        .system, .user => {
            try sep(w, n);
            try w.print("{{\"role\":\"{s}\",\"content\":", .{@tagName(m.role)});
            switch (m.content) {
                .text => |t| try p.W.str(w, t),
                .blocks => |bs| {
                    try w.writeByte('[');
                    var k: usize = 0;
                    for (bs) |b| switch (b) {
                        .text => |t| {
                            if (k > 0) try w.writeByte(',');
                            k += 1;
                            try w.writeAll("{\"type\":\"text\",\"text\":");
                            try p.W.str(w, t);
                            try w.writeByte('}');
                        },
                        .image => |im| {
                            if (k > 0) try w.writeByte(',');
                            k += 1;
                            try w.writeAll("{\"type\":\"image_url\",\"image_url\":{\"url\":");
                            switch (im.source) {
                                .url => |u| try p.W.str(w, u),
                                .base64 => |data| try w.print("\"data:{s};base64,{s}\"", .{ im.media_type, data }),
                            }
                            try w.writeAll("}}");
                        },
                        else => {},
                    };
                    try w.writeByte(']');
                },
            }
            try w.writeByte('}');
        },
        .assistant => {
            try sep(w, n);
            try w.writeAll("{\"role\":\"assistant\",\"content\":");
            switch (m.content) {
                .text => |t| {
                    try p.W.str(w, t);
                    try w.writeByte('}');
                },
                .blocks => |bs| {
                    var has_text = false;
                    for (bs) |b| if (b == .text and b.text.len > 0) {
                        has_text = true;
                    };
                    if (has_text) {
                        try w.writeByte('"');
                        for (bs) |b| if (b == .text) try std.json.Stringify.encodeJsonStringChars(b.text, .{}, w);
                        try w.writeByte('"');
                    } else try w.writeAll("null");
                    var k: usize = 0;
                    for (bs) |b| if (b == .tool_use) {
                        try w.writeAll(if (k == 0) ",\"tool_calls\":[" else ",");
                        k += 1;
                        try w.writeAll("{\"id\":");
                        try p.W.str(w, b.tool_use.id);
                        try w.writeAll(",\"type\":\"function\",\"function\":{\"name\":");
                        try p.W.str(w, b.tool_use.name);
                        try w.writeAll(",\"arguments\":");
                        try p.W.str(w, if (b.tool_use.input_json.len == 0) "{}" else b.tool_use.input_json);
                        try w.writeAll("}}");
                    };
                    if (k > 0) try w.writeByte(']');
                    try w.writeByte('}');
                },
            }
        },
        .tool => switch (m.content) {
            .text => |t| {
                try sep(w, n);
                try w.writeAll("{\"role\":\"user\",\"content\":");
                try p.W.str(w, t);
                try w.writeByte('}');
            },
            .blocks => |bs| for (bs) |b| if (b == .tool_result) {
                try sep(w, n);
                try w.writeAll("{\"role\":\"tool\",\"tool_call_id\":");
                try p.W.str(w, b.tool_result.id);
                try w.writeAll(",\"content\":");
                if (b.tool_result.is_error) {
                    const prefixed = "Error: ";
                    try w.writeByte('"');
                    try std.json.Stringify.encodeJsonStringChars(prefixed, .{}, w);
                    try std.json.Stringify.encodeJsonStringChars(b.tool_result.content, .{}, w);
                    try w.writeByte('"');
                } else try p.W.str(w, b.tool_result.content);
                try w.writeByte('}');
            },
        },
    }
}

pub const Stream = struct {
    arena: Allocator,
    scratch: std.heap.ArenaAllocator,
    res: *http.Response,
    events: sse.Stream,
    builder: p.Builder,
    usage: msg.Usage = .{},
    stop_reason: ?msg.FinishReason = null,
    diag: ?*p.Diagnostic,
    done: bool = false,
    started_text: bool = false,
    started_reasoning: bool = false,
    tool_ids: std.AutoHashMapUnmanaged(u32, void) = .empty,

    pub fn open(arena: Allocator, h: *http.Http, req: p.Request) p.Error!Stream {
        var aw: Writer.Allocating = .init(arena);
        writeBody(&aw.writer, req) catch return error.OutOfMemory;
        const url = std.fmt.allocPrint(arena, "{s}/chat/completions", .{req.base_url}) catch return error.OutOfMemory;
        var headers: std.ArrayList(std.http.Header) = .empty;
        headers.append(arena, .{ .name = "accept", .value = "text/event-stream" }) catch return error.OutOfMemory;
        if (req.api_key) |k| {
            const v = std.fmt.allocPrint(arena, "Bearer {s}", .{k}) catch return error.OutOfMemory;
            headers.append(arena, .{ .name = "authorization", .value = v }) catch return error.OutOfMemory;
        }
        for (req.headers) |hd| headers.append(arena, .{ .name = hd[0], .value = hd[1] }) catch return error.OutOfMemory;

        const res = h.post(url, headers.items, aw.written()) catch |err| return p.mapHttpError(err);
        if (!res.ok()) {
            defer res.close();
            const body = res.readAll(arena, 8192) catch "";
            return p.statusError(res.status, errorMessage(arena, res.status, body), req.diag);
        }
        return .{
            .arena = arena,
            .scratch = .init(h.gpa),
            .res = res,
            .events = .init(h.gpa, res.reader),
            .builder = .{ .arena = arena },
            .diag = req.diag,
        };
    }

    pub fn close(s: *Stream) void {
        s.events.deinit();
        s.scratch.deinit();
        s.tool_ids.deinit(s.arena);
        s.res.close();
    }

    fn finish(s: *Stream) p.Event {
        s.done = true;
        const msg_out = s.builder.finish();
        var reason = s.stop_reason orelse .end_turn;
        // Some compatible servers report "stop" even when they returned tool calls.
        if (reason == .end_turn and msg_out.count(.tool_use) > 0) reason = .tool_use;
        return .{ .finish = .{ .reason = reason, .usage = s.usage, .message = msg_out } };
    }

    pub fn next(s: *Stream) p.Error!?p.Event {
        if (s.done) return null;
        while (true) {
            _ = s.scratch.reset(.retain_capacity);
            const ev = s.events.next() catch |err| switch (err) {
                error.OutOfMemory => return error.OutOfMemory,
                else => return s.res.readError(),
            } orelse {
                if (s.stop_reason != null) return s.finish();
                return error.StreamInterrupted;
            };
            if (std.mem.eql(u8, std.mem.trim(u8, ev.data, " "), "[DONE]")) return s.finish();
            const sa = s.scratch.allocator();
            const v = try p.parseData(sa, ev.data);
            if (v != .object) return error.ProtocolError;
            if (v.object.get("error")) |e| {
                if (s.diag) |dg| dg.print(0, "openai stream error: {s}", .{p.getStr(e, "message") orelse "unknown"});
                return error.ProviderError;
            }
            if (v.object.get("usage")) |u| if (u == .object) {
                const prompt = p.getU64(u, "prompt_tokens");
                var cached: u64 = 0;
                if (u.object.get("prompt_tokens_details")) |d| cached = p.getU64(d, "cached_tokens");
                s.usage.input_tokens = prompt -| cached;
                s.usage.cache_read_tokens = cached;
                s.usage.output_tokens = p.getU64(u, "completion_tokens");
            };
            const choices = v.object.get("choices") orelse continue;
            if (choices != .array or choices.array.items.len == 0) continue;
            const c = choices.array.items[0];
            if (c.object.get("finish_reason")) |fr| if (fr == .string) {
                s.stop_reason = mapStop(fr.string);
            };
            const d = c.object.get("delta") orelse continue;
            if (d != .object) continue;

            // A chunk can carry several things; emit the first and buffer the
            // rest into the builder (deltas for tools are rarely mixed).
            var out: ?p.Event = null;
            if (p.getStr(d, "reasoning_content") orelse p.getStr(d, "reasoning")) |r| if (r.len > 0) {
                if (!s.started_reasoning) {
                    try s.builder.startReasoning(reasoning_index, null);
                    s.started_reasoning = true;
                }
                try s.builder.append(reasoning_index, r);
                out = out orelse p.Event{ .delta = .{ .reasoning = r } };
            };
            if (p.getStr(d, "content")) |t| if (t.len > 0) {
                if (!s.started_text) {
                    try s.builder.startText(text_index);
                    s.started_text = true;
                }
                try s.builder.append(text_index, t);
                out = out orelse p.Event{ .delta = .{ .text = t } };
            };
            if (d.object.get("tool_calls")) |tcs| if (tcs == .array) for (tcs.array.items) |tc| {
                const idx: u32 = @intCast(p.getInt(tc, "index") orelse 0);
                const f = tc.object.get("function");
                if (!s.tool_ids.contains(idx)) {
                    const id = p.getStr(tc, "id") orelse "";
                    const fname = if (f) |ff| p.getStr(ff, "name") orelse "" else "";
                    try s.builder.startToolUse(idx, if (id.len > 0) id else try std.fmt.allocPrint(s.arena, "call_{d}", .{idx}), fname);
                    s.tool_ids.put(s.arena, idx, {}) catch return error.OutOfMemory;
                    out = out orelse p.Event{ .delta = .{ .tool_call_start = .{ .index = idx, .id = id, .name = fname } } };
                }
                if (f) |ff| if (p.getStr(ff, "arguments")) |args| if (args.len > 0) {
                    try s.builder.append(idx, args);
                    out = out orelse p.Event{ .delta = .{ .tool_call_args = .{ .index = idx, .json = args } } };
                };
            };
            if (out) |e| return e;
        }
    }
};

fn mapStop(s: []const u8) msg.FinishReason {
    if (std.mem.eql(u8, s, "stop")) return .end_turn;
    if (std.mem.eql(u8, s, "tool_calls") or std.mem.eql(u8, s, "function_call")) return .tool_use;
    if (std.mem.eql(u8, s, "length")) return .max_tokens;
    if (std.mem.eql(u8, s, "content_filter")) return .refusal;
    return .other;
}

fn errorMessage(arena: Allocator, status: u16, body: []const u8) []const u8 {
    const v = std.json.parseFromSliceLeaky(std.json.Value, arena, body, .{}) catch
        return std.fmt.allocPrint(arena, "openai {d}: {s}", .{ status, body }) catch body;
    const e = (if (v == .object) v.object.get("error") else null) orelse v;
    return std.fmt.allocPrint(arena, "openai {d} {s}: {s}", .{
        status, p.getStr(e, "type") orelse p.getStr(e, "code") orelse "error", p.getStr(e, "message") orelse body,
    }) catch body;
}
