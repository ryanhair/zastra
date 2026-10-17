//! OpenAI-compatible Chat Completions provider (PLAN.md §6.2). Covers OpenAI
//! and, through `z.custom`, OpenRouter, Groq, Together, Ollama, vLLM, ...

const std = @import("std");
const p = @import("provider.zig");
const msg = @import("../message.zig");
const sse = @import("sse.zig");
const stream = @import("stream.zig");
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

pub const path = "/chat/completions";

pub fn auth(arena: Allocator, api_key: ?[]const u8) Allocator.Error![]const std.http.Header {
    const k = api_key orelse return &.{};
    const hs = try arena.alloc(std.http.Header, 1);
    hs[0] = .{ .name = "authorization", .value = try std.fmt.allocPrint(arena, "Bearer {s}", .{k}) };
    return hs;
}

pub const Stream = stream.SseStream(@This());

pub const end_marker = "[DONE]";

pub const State = struct {
    usage: msg.Usage = .{},
    stop_reason: ?msg.FinishReason = null,
    started_text: bool = false,
    started_reasoning: bool = false,
    /// Indexes of the tool calls started so far.
    tool_ids: std.AutoHashMapUnmanaged(u32, void) = .empty,
};

/// `[DONE]`, or the end of the body once a finish reason arrived.
pub fn onEnd(st: *State, out: *stream.Out, why: stream.End) p.Error!void {
    if (why == .eof and st.stop_reason == null) return error.StreamInterrupted;
    const msg_out = out.builder.finish();
    var reason = st.stop_reason orelse .end_turn;
    // Some compatible servers report "stop" even when they returned tool calls.
    if (reason == .end_turn and msg_out.count(.tool_use) > 0) reason = .tool_use;
    try out.finish(.{ .reason = reason, .usage = st.usage, .message = msg_out });
}

/// A chunk can carry reasoning, content and several tool-call deltas; each
/// becomes its own event, in that order.
pub fn onEvent(st: *State, _: sse.Event, v: std.json.Value, out: *stream.Out) p.Error!void {
    const b = out.builder;
    if (v != .object) return error.ProtocolError;
    if (v.object.get("error")) |e| {
        if (out.diag) |dg| dg.print(0, "openai stream error: {s}", .{p.getStr(e, "message") orelse "unknown"});
        return error.ProviderError;
    }
    if (v.object.get("usage")) |u| if (u == .object) {
        const prompt = p.getU64(u, "prompt_tokens");
        var cached: u64 = 0;
        if (u.object.get("prompt_tokens_details")) |d| cached = p.getU64(d, "cached_tokens");
        st.usage.input_tokens = prompt -| cached;
        st.usage.cache_read_tokens = cached;
        st.usage.output_tokens = p.getU64(u, "completion_tokens");
    };
    const choices = v.object.get("choices") orelse return;
    if (choices != .array or choices.array.items.len == 0) return;
    const c = choices.array.items[0];
    if (c.object.get("finish_reason")) |fr| if (fr == .string) {
        st.stop_reason = mapStop(fr.string);
    };
    const d = c.object.get("delta") orelse return;
    if (d != .object) return;

    if (p.getStr(d, "reasoning_content") orelse p.getStr(d, "reasoning")) |r| if (r.len > 0) {
        if (!st.started_reasoning) {
            try b.startReasoning(reasoning_index, null);
            st.started_reasoning = true;
        }
        try b.append(reasoning_index, r);
        try out.push(.{ .delta = .{ .reasoning = r } });
    };
    if (p.getStr(d, "content")) |t| if (t.len > 0) {
        if (!st.started_text) {
            try b.startText(text_index);
            st.started_text = true;
        }
        try b.append(text_index, t);
        try out.push(.{ .delta = .{ .text = t } });
    };
    if (d.object.get("tool_calls")) |tcs| if (tcs == .array) for (tcs.array.items) |tc| {
        const idx: u32 = @intCast(p.getInt(tc, "index") orelse 0);
        const f = tc.object.get("function");
        if (!st.tool_ids.contains(idx)) {
            const sent = p.getStr(tc, "id") orelse "";
            // Some servers send no id; the delta and the message share the made-up one.
            const id = if (sent.len > 0) sent else std.fmt.allocPrint(out.arena, "call_{d}", .{idx}) catch return error.OutOfMemory;
            const fname = if (f) |ff| p.getStr(ff, "name") orelse "" else "";
            try b.startToolUse(idx, id, fname);
            st.tool_ids.put(out.arena, idx, {}) catch return error.OutOfMemory;
            try out.push(.{ .delta = .{ .tool_call_start = .{ .index = idx, .id = id, .name = fname } } });
        }
        if (f) |ff| if (p.getStr(ff, "arguments")) |args| if (args.len > 0) {
            try b.append(idx, args);
            try out.push(.{ .delta = .{ .tool_call_args = .{ .index = idx, .json = args } } });
        };
    };
}

fn mapStop(s: []const u8) msg.FinishReason {
    if (std.mem.eql(u8, s, "stop")) return .end_turn;
    if (std.mem.eql(u8, s, "tool_calls") or std.mem.eql(u8, s, "function_call")) return .tool_use;
    if (std.mem.eql(u8, s, "length")) return .max_tokens;
    if (std.mem.eql(u8, s, "content_filter")) return .refusal;
    return .other;
}
