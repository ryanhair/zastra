//! OpenAI Responses API provider (PLAN.md §17.2, D35, D36). Catalog `openai/*`
//! models use it; `openai_compat.zig` stays for OpenAI-compatible servers.
//!
//! Requests are stateless (`store: false`). Reasoning comes back as items
//! with `encrypted_content`, kept as `.reasoning` blocks (summary text, the
//! encrypted content as the signature) and sent back within a run so the
//! model keeps its reasoning across tool steps.

const std = @import("std");
const p = @import("provider.zig");
const msg = @import("../message.zig");
const sse = @import("sse.zig");
const stream = @import("stream.zig");
const catalog = @import("../catalog/catalog.zig");
const Allocator = std.mem.Allocator;
const Writer = std.Io.Writer;

pub const name = "openai";

/// The API rejects `max_output_tokens` below this.
const min_output_tokens = 16;

pub fn buildPrefix(comptime parts: p.PrefixParts) p.Prefix {
    comptime {
        @setEvalBranchQuota(10_000_000);
        const s = parts.spec;
        const reasoning_on = s.supports.reasoning and !(parts.reasoning != null and parts.reasoning.? == .disabled);
        var j: []const u8 = "{\"model\":" ++ p.jsonStr(s.id) ++ ",\"stream\":true,\"store\":false";
        if (reasoning_on) j = j ++ ",\"include\":[\"reasoning.encrypted_content\"]";
        if (parts.system) |sys| j = j ++ ",\"instructions\":" ++ p.jsonStr(sys);
        var insert_at: ?usize = null;
        if (parts.tools.len > 0 or parts.dynamic_tools) {
            j = j ++ ",\"tools\":[";
            for (parts.tools, 0..) |t, i| {
                j = j ++ (if (i == 0) "" else ",") ++ "{\"type\":\"function\",\"name\":" ++ p.jsonStr(t.name) ++
                    ",\"description\":" ++ p.jsonStr(t.description) ++
                    ",\"parameters\":" ++ t.schema ++
                    ",\"strict\":" ++ (if (t.strict_ok) "true" else "false") ++ "}";
            }
            if (parts.dynamic_tools) insert_at = j.len;
            j = j ++ "]";
            if (!s.supports.parallel_tools) j = j ++ ",\"parallel_tool_calls\":false";
        }
        if (parts.output) |o| j = j ++ ",\"text\":{\"format\":{\"type\":\"json_schema\",\"name\":" ++
            p.jsonStr(o.name) ++ ",\"schema\":" ++ o.schema ++ ",\"strict\":true}}";
        if (s.supports.reasoning) j = j ++ reasoningJson(s.supports.reasoning_modes, parts.effort, parts.reasoning);
        if (parts.temperature) |t| j = j ++ std.fmt.comptimePrint(",\"temperature\":{d}", .{t});
        if (parts.extra) |x| j = j ++ "," ++ x;
        j = j ++ ",\"input\":[";
        return .{ .json = j, .open_items = 0, .hash = p.prefixHash(j), .tools_insert_at = insert_at, .static_tools = parts.tools.len };
    }
}

/// `,"reasoning":{...}`, or nothing when the model's defaults apply.
fn reasoningJson(comptime modes: catalog.ReasoningModes, comptime effort: ?p.Effort, comptime reasoning: ?p.Reasoning) []const u8 {
    comptime {
        var e: ?[]const u8 = if (effort) |x| switch (x) {
            .low => "low",
            .medium => "medium",
            .high => "high",
            .xhigh, .max => if (modes.xhigh_effort) "xhigh" else "high",
        } else null;
        var summary = false;
        if (reasoning) |r| switch (r) {
            .disabled => e = "none",
            .on => |o| {
                if (e == null and !modes.default_on) e = "medium";
                summary = o.summarized;
            },
            .budget => unreachable, // rejected in agent.resolveReasoning
        };
        if (e == null and !summary) return "";
        var j: []const u8 = ",\"reasoning\":{";
        if (e) |x| j = j ++ "\"effort\":\"" ++ x ++ "\"";
        if (summary) j = j ++ (if (e != null) "," else "") ++ "\"summary\":\"auto\"";
        return j ++ "}";
    }
}

/// A runtime tool definition (MCP). Not strict: MCP schemas are arbitrary.
pub fn writeToolDef(w: *Writer, tool_name: []const u8, description: []const u8, schema_json: []const u8) Writer.Error!void {
    try w.writeAll("{\"type\":\"function\",\"name\":");
    try p.W.str(w, tool_name);
    try w.writeAll(",\"description\":");
    try p.W.str(w, description);
    try w.writeAll(",\"parameters\":");
    try w.writeAll(schema_json);
    try w.writeAll(",\"strict\":false}");
}

pub fn writeBody(w: *Writer, req: p.Request) Writer.Error!void {
    try w.writeAll(req.prefix.json);
    var n: usize = req.prefix.open_items;
    if (req.system_suffix) |sfx| if (sfx.len > 0) {
        try sep(w, &n);
        try w.writeAll("{\"role\":\"developer\",\"content\":");
        try p.W.str(w, sfx);
        try w.writeByte('}');
    };
    for (req.messages) |m| try writeMessage(w, m, &n);
    try w.print("],\"max_output_tokens\":{d},\"prompt_cache_key\":\"zastra-{x}\"", .{ @max(req.max_tokens, min_output_tokens), req.prefix.hash });
    switch (req.tool_choice) {
        .auto => {},
        .none => try w.writeAll(",\"tool_choice\":\"none\""),
        .required => try w.writeAll(",\"tool_choice\":\"required\""),
        .tool => |t| {
            try w.writeAll(",\"tool_choice\":{\"type\":\"function\",\"name\":");
            try p.W.str(w, t);
            try w.writeByte('}');
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
            try w.writeAll(if (m.role == .system) "{\"role\":\"developer\",\"content\":" else "{\"role\":\"user\",\"content\":");
            switch (m.content) {
                .text => |t| try p.W.str(w, t),
                .blocks => |bs| {
                    try w.writeByte('[');
                    var k: usize = 0;
                    for (bs) |b| switch (b) {
                        .text => |t| {
                            if (k > 0) try w.writeByte(',');
                            k += 1;
                            try w.writeAll("{\"type\":\"input_text\",\"text\":");
                            try p.W.str(w, t);
                            try w.writeByte('}');
                        },
                        .image => |im| {
                            if (k > 0) try w.writeByte(',');
                            k += 1;
                            try w.writeAll("{\"type\":\"input_image\",\"image_url\":");
                            switch (im.source) {
                                .url => |u| try p.W.str(w, u),
                                .base64 => |data| try w.print("\"data:{s};base64,{s}\"", .{ im.media_type, data }),
                            }
                            try w.writeByte('}');
                        },
                        else => {},
                    };
                    try w.writeByte(']');
                },
            }
            try w.writeByte('}');
        },
        .assistant => switch (m.content) {
            .text => |t| {
                try sep(w, n);
                try writeAssistantText(w, t);
            },
            .blocks => |bs| for (bs) |b| switch (b) {
                .text => |t| if (t.len > 0) {
                    try sep(w, n);
                    try writeAssistantText(w, t);
                },
                // Reasoning without encrypted content (another provider's,
                // or cut off) can't be sent back.
                .reasoning => |r| if (r.signature) |enc| {
                    try sep(w, n);
                    try w.writeAll("{\"type\":\"reasoning\",\"encrypted_content\":");
                    try p.W.str(w, enc);
                    try w.writeAll(",\"summary\":[");
                    if (r.text.len > 0) {
                        try w.writeAll("{\"type\":\"summary_text\",\"text\":");
                        try p.W.str(w, r.text);
                        try w.writeByte('}');
                    }
                    try w.writeAll("]}");
                },
                .tool_use => |tu| {
                    try sep(w, n);
                    try w.writeAll("{\"type\":\"function_call\",\"call_id\":");
                    try p.W.str(w, tu.id);
                    try w.writeAll(",\"name\":");
                    try p.W.str(w, tu.name);
                    try w.writeAll(",\"arguments\":");
                    try p.W.str(w, if (tu.input_json.len == 0) "{}" else tu.input_json);
                    try w.writeByte('}');
                },
                .provider_opaque => |o| if (std.mem.eql(u8, o.provider, name)) {
                    try sep(w, n);
                    try w.writeAll(o.json);
                },
                else => {},
            },
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
                try w.writeAll("{\"type\":\"function_call_output\",\"call_id\":");
                try p.W.str(w, b.tool_result.id);
                try w.writeAll(",\"output\":");
                if (b.tool_result.is_error) {
                    try w.writeAll("\"Error: ");
                    try std.json.Stringify.encodeJsonStringChars(b.tool_result.content, .{}, w);
                    try w.writeByte('"');
                } else try p.W.str(w, b.tool_result.content);
                try w.writeByte('}');
            },
        },
    }
}

fn writeAssistantText(w: *Writer, t: []const u8) Writer.Error!void {
    try w.writeAll("{\"type\":\"message\",\"role\":\"assistant\",\"content\":[{\"type\":\"output_text\",\"text\":");
    try p.W.str(w, t);
    try w.writeAll("}]}");
}

pub const path = "/responses";

pub fn auth(arena: Allocator, api_key: ?[]const u8) Allocator.Error![]const std.http.Header {
    const k = api_key orelse return &.{};
    const hs = try arena.alloc(std.http.Header, 1);
    hs[0] = .{ .name = "authorization", .value = try std.fmt.allocPrint(arena, "Bearer {s}", .{k}) };
    return hs;
}

pub const Stream = stream.SseStream(@This());

pub const State = struct {
    refused: bool = false,
};

/// `response.completed`, `response.incomplete` or `response.failed`.
fn finish(st: *State, response: std.json.Value, out: *stream.Out) p.Error!void {
    const status = p.getStr(response, "status") orelse "completed";
    if (std.mem.eql(u8, status, "failed")) {
        const e = response.object.get("error") orelse .null;
        if (out.diag) |d| d.print(0, "openai response failed: {s}: {s}", .{ p.getStr(e, "code") orelse "error", p.getStr(e, "message") orelse "unknown" });
        return error.ProviderError;
    }
    var usage: msg.Usage = .{};
    if (response.object.get("usage")) |u| if (u == .object) {
        var cached: u64 = 0;
        var written: u64 = 0;
        if (u.object.get("input_tokens_details")) |d| {
            cached = p.getU64(d, "cached_tokens");
            written = p.getU64(d, "cache_write_tokens");
        }
        usage.input_tokens = p.getU64(u, "input_tokens") -| cached -| written;
        usage.cache_read_tokens = cached;
        usage.cache_write_tokens = written;
        usage.output_tokens = p.getU64(u, "output_tokens");
    };
    const message = out.builder.finish();
    var reason: msg.FinishReason = if (message.count(.tool_use) > 0) .tool_use else .end_turn;
    if (st.refused) reason = .refusal;
    if (std.mem.eql(u8, status, "incomplete")) {
        const why = if (response.object.get("incomplete_details")) |d| p.getStr(d, "reason") orelse "" else "";
        reason = if (std.mem.eql(u8, why, "max_output_tokens")) .max_tokens else if (std.mem.eql(u8, why, "content_filter")) .refusal else .other;
    }
    try out.finish(.{ .reason = reason, .usage = usage, .message = message });
}

pub fn onEvent(st: *State, _: sse.Event, v: std.json.Value, out: *stream.Out) p.Error!void {
    const b = out.builder;
    if (v != .object) return error.ProtocolError;
    const ty = p.getStr(v, "type") orelse return;
    const idx: u32 = if (p.getInt(v, "output_index")) |i| @intCast(@max(i, 0)) else 0;

    if (eql(ty, "response.output_text.delta") or eql(ty, "response.refusal.delta")) {
        const d = p.getStr(v, "delta") orelse return;
        if (eql(ty, "response.refusal.delta")) st.refused = true;
        if (d.len == 0) return;
        if (!b.has(idx)) try b.startText(idx);
        try b.append(idx, d);
        try out.push(.{ .delta = .{ .text = d } });
    } else if (eql(ty, "response.reasoning_summary_text.delta")) {
        const d = p.getStr(v, "delta") orelse return;
        if (d.len == 0 or !b.has(idx)) return;
        try b.append(idx, d);
        try out.push(.{ .delta = .{ .reasoning = d } });
    } else if (eql(ty, "response.reasoning_summary_part.added")) {
        // Summaries can come in several parts; keep them as paragraphs.
        if ((p.getInt(v, "summary_index") orelse 0) > 0) try b.append(idx, "\n\n");
    } else if (eql(ty, "response.function_call_arguments.delta")) {
        const d = p.getStr(v, "delta") orelse return;
        if (d.len == 0 or !b.has(idx)) return;
        try b.append(idx, d);
        try out.push(.{ .delta = .{ .tool_call_args = .{ .index = idx, .json = d } } });
    } else if (eql(ty, "response.output_item.added")) {
        const item = v.object.get("item") orelse return;
        const kind = p.getStr(item, "type") orelse return;
        if (eql(kind, "message")) {
            try b.startText(idx);
        } else if (eql(kind, "reasoning")) {
            try b.startReasoning(idx, null);
        } else if (eql(kind, "function_call")) {
            const id = p.getStr(item, "call_id") orelse "";
            const fname = p.getStr(item, "name") orelse "";
            try b.startToolUse(idx, id, fname);
            try out.push(.{ .delta = .{ .tool_call_start = .{ .index = idx, .id = id, .name = fname } } });
        }
    } else if (eql(ty, "response.output_item.done")) {
        const item = v.object.get("item") orelse return;
        const kind = p.getStr(item, "type") orelse "";
        if (b.open.getPtr(idx)) |o| {
            // The final encrypted content differs from the one sent
            // with `output_item.added`; only this one round-trips.
            if (eql(kind, "reasoning")) if (p.getStr(item, "encrypted_content")) |enc| try b.appendSig(idx, enc);
            if (eql(kind, "function_call") and o.buf.items.len == 0)
                if (p.getStr(item, "arguments")) |args| try b.append(idx, args);
        }
        b.stop(idx);
    } else if (eql(ty, "response.completed") or eql(ty, "response.incomplete") or eql(ty, "response.failed")) {
        const r = v.object.get("response") orelse return error.ProtocolError;
        if (r != .object) return error.ProtocolError;
        try finish(st, r, out);
    } else if (eql(ty, "error")) {
        if (out.diag) |d| d.print(0, "openai stream error: {s}: {s}", .{ p.getStr(v, "code") orelse "error", p.getStr(v, "message") orelse "unknown" });
        return error.ProviderError;
    }
}

fn eql(a: []const u8, b: []const u8) bool {
    return std.mem.eql(u8, a, b);
}
