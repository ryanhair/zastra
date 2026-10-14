//! Anthropic Messages API provider (PLAN.md §6.2).

const std = @import("std");
const p = @import("provider.zig");
const msg = @import("../message.zig");
const sse = @import("sse.zig");
const http = @import("http.zig");
const catalog = @import("../catalog/catalog.zig");
const Allocator = std.mem.Allocator;
const Writer = std.Io.Writer;

pub const name = "anthropic";
pub const api_version = "2023-06-01";

/// Comptime request prefix. Key order is fixed so the bytes are stable.
/// Prompt caching: a breakpoint after the static system prompt (or the last
/// tool when there is no system prompt), plus top-level automatic caching of
/// the conversation, when the model supports caching (§5.5).
pub fn buildPrefix(comptime parts: p.PrefixParts) p.Prefix {
    comptime {
        @setEvalBranchQuota(10_000_000);
        const s = parts.spec;
        const cache = s.supports.prompt_caching;
        const cc = ",\"cache_control\":{\"type\":\"ephemeral\"}";
        var j: []const u8 = "{\"model\":" ++ p.jsonStr(s.id) ++ ",\"stream\":true";
        if (parts.tools.len > 0) {
            j = j ++ ",\"tools\":[";
            for (parts.tools, 0..) |t, i| {
                const last = i == parts.tools.len - 1;
                j = j ++ (if (i == 0) "" else ",") ++ "{\"name\":" ++ p.jsonStr(t.name) ++
                    ",\"description\":" ++ p.jsonStr(t.description) ++
                    ",\"input_schema\":" ++ t.schema ++
                    (if (last and cache and parts.system == null) cc else "") ++ "}";
            }
            j = j ++ "]";
        }
        if (parts.output != null or parts.effort != null) {
            var oc: []const u8 = "";
            if (parts.output) |o| oc = oc ++ "\"format\":{\"type\":\"json_schema\",\"schema\":" ++ o.schema ++ "}";
            if (parts.effort) |e| oc = oc ++ (if (oc.len > 0) "," else "") ++ "\"effort\":\"" ++ @tagName(e) ++ "\"";
            j = j ++ ",\"output_config\":{" ++ oc ++ "}";
        }
        if (parts.temperature) |t| j = j ++ std.fmt.comptimePrint(",\"temperature\":{d}", .{t});
        if (parts.extra) |x| j = j ++ "," ++ x;
        if (cache) j = j ++ cc;
        var open: u32 = 0;
        if (parts.system) |sys| {
            j = j ++ ",\"system\":[{\"type\":\"text\",\"text\":" ++ p.jsonStr(sys) ++ (if (cache) cc else "") ++ "}";
            open = 1;
        }
        return .{ .json = j, .open_items = open, .hash = p.prefixHash(j) };
    }
}

/// Complete the request body: system suffix, max_tokens, tool_choice, messages.
pub fn writeBody(w: *Writer, req: p.Request) Writer.Error!void {
    try w.writeAll(req.prefix.json);
    // Leading system-role messages join the system prompt.
    var first: usize = 0;
    while (first < req.messages.len and req.messages[first].role == .system) first += 1;
    const extra_system = first > 0 or req.system_suffix != null;
    if (req.prefix.open_items > 0 or extra_system) {
        var n: u32 = req.prefix.open_items;
        if (req.prefix.open_items == 0) try w.writeAll(",\"system\":[");
        for (req.messages[0..first]) |m| {
            const t = switch (m.content) {
                .text => |t| t,
                .blocks => |bs| if (bs.len > 0 and bs[0] == .text) bs[0].text else "",
            };
            if (t.len == 0) continue;
            try w.writeAll(if (n > 0) ",{\"type\":\"text\",\"text\":" else "{\"type\":\"text\",\"text\":");
            try p.W.str(w, t);
            try w.writeAll("}");
            n += 1;
        }
        if (req.system_suffix) |sfx| if (sfx.len > 0) {
            try w.writeAll(if (n > 0) ",{\"type\":\"text\",\"text\":" else "{\"type\":\"text\",\"text\":");
            try p.W.str(w, sfx);
            try w.writeAll("}");
        };
        try w.writeAll("]");
    }
    try w.print(",\"max_tokens\":{d}", .{req.max_tokens});
    switch (req.tool_choice) {
        .auto => {},
        .none => try w.writeAll(",\"tool_choice\":{\"type\":\"none\"}"),
        .required => try w.writeAll(",\"tool_choice\":{\"type\":\"any\"}"),
        .tool => |t| {
            try w.writeAll(",\"tool_choice\":{\"type\":\"tool\",\"name\":");
            try p.W.str(w, t);
            try w.writeAll("}");
        },
    }
    try w.writeAll(",\"messages\":[");
    for (req.messages[first..], 0..) |m, i| {
        if (i > 0) try w.writeByte(',');
        try writeMessage(w, m);
    }
    try w.writeAll("]}");
}

fn hasContent(m: msg.Message) bool {
    return switch (m.content) {
        .text => true,
        .blocks => |bs| for (bs) |b| {
            if (blockEmitted(b)) break true;
        } else false,
    };
}

fn blockEmitted(b: msg.Block) bool {
    return switch (b) {
        .reasoning => |r| r.signature != null,
        .provider_opaque => |o| std.mem.eql(u8, o.provider, name),
        .text => |t| t.len > 0,
        else => true,
    };
}

fn writeMessage(w: *Writer, m: msg.Message) Writer.Error!void {
    if (!hasContent(m)) {
        // Keep the array well-formed: an assistant turn with nothing we can
        // send becomes an empty text placeholder.
        try w.writeAll("{\"role\":\"assistant\",\"content\":\".\"}");
        return;
    }
    const role = switch (m.role) {
        .assistant => "assistant",
        .user, .tool, .system => "user",
    };
    try w.print("{{\"role\":\"{s}\",\"content\":", .{role});
    switch (m.content) {
        .text => |t| {
            if (m.role == .system) {
                try w.writeAll("[{\"type\":\"text\",\"text\":");
                try p.W.str(w, t);
                try w.writeAll("}]");
            } else try p.W.str(w, t);
        },
        .blocks => |bs| {
            try w.writeByte('[');
            var n: usize = 0;
            for (bs) |b| {
                if (!blockEmitted(b)) continue;
                if (n > 0) try w.writeByte(',');
                n += 1;
                try writeBlock(w, b);
            }
            try w.writeByte(']');
        },
    }
    try w.writeByte('}');
}

fn writeBlock(w: *Writer, b: msg.Block) Writer.Error!void {
    switch (b) {
        .text => |t| {
            try w.writeAll("{\"type\":\"text\",\"text\":");
            try p.W.str(w, t);
            try w.writeByte('}');
        },
        .image => |im| switch (im.source) {
            .base64 => |data| {
                try w.writeAll("{\"type\":\"image\",\"source\":{\"type\":\"base64\",\"media_type\":");
                try p.W.str(w, im.media_type);
                try w.writeAll(",\"data\":");
                try p.W.str(w, data);
                try w.writeAll("}}");
            },
            .url => |u| {
                try w.writeAll("{\"type\":\"image\",\"source\":{\"type\":\"url\",\"url\":");
                try p.W.str(w, u);
                try w.writeAll("}}");
            },
        },
        .tool_use => |t| {
            try w.writeAll("{\"type\":\"tool_use\",\"id\":");
            try p.W.str(w, t.id);
            try w.writeAll(",\"name\":");
            try p.W.str(w, t.name);
            try w.writeAll(",\"input\":");
            try w.writeAll(if (t.input_json.len == 0) "{}" else t.input_json);
            try w.writeByte('}');
        },
        .tool_result => |t| {
            try w.writeAll("{\"type\":\"tool_result\",\"tool_use_id\":");
            try p.W.str(w, t.id);
            try w.writeAll(",\"content\":");
            try p.W.str(w, t.content);
            if (t.is_error) try w.writeAll(",\"is_error\":true");
            try w.writeByte('}');
        },
        .reasoning => |r| {
            try w.writeAll("{\"type\":\"thinking\",\"thinking\":");
            try p.W.str(w, r.text);
            try w.writeAll(",\"signature\":");
            try p.W.str(w, r.signature orelse "");
            try w.writeByte('}');
        },
        .provider_opaque => |o| try w.writeAll(o.json),
    }
}

pub const Stream = struct {
    arena: Allocator,
    scratch: std.heap.ArenaAllocator,
    res: *http.Response,
    events: sse.Stream,
    builder: p.Builder,
    usage: msg.Usage = .{},
    stop_reason: msg.FinishReason = .other,
    diag: ?*p.Diagnostic,
    done: bool = false,

    /// Send the request. `arena` holds the request body and the accumulated
    /// assistant message; it must outlive the stream.
    pub fn open(arena: Allocator, h: *http.Http, req: p.Request) p.Error!Stream {
        var aw: Writer.Allocating = .init(arena);
        writeBody(&aw.writer, req) catch return error.OutOfMemory;
        const url = std.fmt.allocPrint(arena, "{s}/v1/messages", .{req.base_url}) catch return error.OutOfMemory;

        var headers: std.ArrayList(std.http.Header) = .empty;
        headers.append(arena, .{ .name = "anthropic-version", .value = api_version }) catch return error.OutOfMemory;
        headers.append(arena, .{ .name = "accept", .value = "text/event-stream" }) catch return error.OutOfMemory;
        if (req.api_key) |k| headers.append(arena, .{ .name = "x-api-key", .value = k }) catch return error.OutOfMemory;
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
        s.res.close();
    }

    /// Next delta or the final event. Delta slices are valid until the next call.
    pub fn next(s: *Stream) p.Error!?p.Event {
        if (s.done) return null;
        while (true) {
            _ = s.scratch.reset(.retain_capacity);
            const ev = s.events.next() catch |err| switch (err) {
                error.OutOfMemory => return error.OutOfMemory,
                else => return s.res.readError(),
            } orelse return error.StreamInterrupted;
            const sa = s.scratch.allocator();
            const v = try p.parseData(sa, ev.data);
            const kind = p.getStr(v, "type") orelse ev.event;

            if (std.mem.eql(u8, kind, "message_start")) {
                if (p.getObj(v, "message")) |m| if (m.get("usage")) |u| s.readUsage(u);
            } else if (std.mem.eql(u8, kind, "content_block_start")) {
                const index: u32 = @intCast(p.getInt(v, "index") orelse 0);
                const cb_v = (if (v == .object) v.object.get("content_block") else null) orelse return error.ProtocolError;
                const t = p.getStr(cb_v, "type") orelse "";
                if (std.mem.eql(u8, t, "text")) {
                    try s.builder.startText(index);
                    const initial = p.getStr(cb_v, "text") orelse "";
                    if (initial.len > 0) {
                        try s.builder.append(index, initial);
                        return .{ .delta = .{ .text = initial } };
                    }
                } else if (std.mem.eql(u8, t, "thinking")) {
                    try s.builder.startReasoning(index, p.getStr(cb_v, "signature"));
                    const initial = p.getStr(cb_v, "thinking") orelse "";
                    if (initial.len > 0) {
                        try s.builder.append(index, initial);
                        return .{ .delta = .{ .reasoning = initial } };
                    }
                } else if (std.mem.eql(u8, t, "tool_use")) {
                    const id = p.getStr(cb_v, "id") orelse return error.ProtocolError;
                    const tname = p.getStr(cb_v, "name") orelse return error.ProtocolError;
                    try s.builder.startToolUse(index, id, tname);
                    return .{ .delta = .{ .tool_call_start = .{ .index = index, .id = id, .name = tname } } };
                } else {
                    // redacted_thinking, server tool blocks, fallback markers, and
                    // anything newer: round-trip verbatim (PLAN.md §12).
                    const raw = std.json.Stringify.valueAlloc(sa, cb_v, .{}) catch return error.OutOfMemory;
                    try s.builder.addOpaque(name, raw);
                }
            } else if (std.mem.eql(u8, kind, "content_block_delta")) {
                const index: u32 = @intCast(p.getInt(v, "index") orelse 0);
                const d = (if (v == .object) v.object.get("delta") else null) orelse continue;
                const dt = p.getStr(d, "type") orelse "";
                if (std.mem.eql(u8, dt, "text_delta")) {
                    const t = p.getStr(d, "text") orelse "";
                    try s.builder.append(index, t);
                    return .{ .delta = .{ .text = t } };
                } else if (std.mem.eql(u8, dt, "thinking_delta")) {
                    const t = p.getStr(d, "thinking") orelse "";
                    try s.builder.append(index, t);
                    if (t.len > 0) return .{ .delta = .{ .reasoning = t } };
                } else if (std.mem.eql(u8, dt, "signature_delta")) {
                    try s.builder.appendSig(index, p.getStr(d, "signature") orelse "");
                } else if (std.mem.eql(u8, dt, "input_json_delta")) {
                    const t = p.getStr(d, "partial_json") orelse "";
                    if (s.builder.has(index)) {
                        try s.builder.append(index, t);
                        return .{ .delta = .{ .tool_call_args = .{ .index = index, .json = t } } };
                    }
                }
            } else if (std.mem.eql(u8, kind, "content_block_stop")) {
                s.builder.stop(@intCast(p.getInt(v, "index") orelse 0));
            } else if (std.mem.eql(u8, kind, "message_delta")) {
                if (p.getObj(v, "delta")) |d| if (d.get("stop_reason")) |sr| if (sr == .string) {
                    s.stop_reason = mapStop(sr.string);
                };
                if (v.object.get("usage")) |u| s.readUsage(u);
            } else if (std.mem.eql(u8, kind, "message_stop")) {
                s.done = true;
                return .{ .finish = .{ .reason = s.stop_reason, .usage = s.usage, .message = s.builder.finish() } };
            } else if (std.mem.eql(u8, kind, "error")) {
                const e = (if (v == .object) v.object.get("error") else null) orelse v;
                if (s.diag) |dg| dg.print(0, "anthropic stream error {s}: {s}", .{ p.getStr(e, "type") orelse "?", p.getStr(e, "message") orelse "" });
                return error.ProviderError;
            }
            // ping and unknown events: ignore.
        }
    }

    fn readUsage(s: *Stream, u: std.json.Value) void {
        s.usage.input_tokens = @max(s.usage.input_tokens, p.getU64(u, "input_tokens"));
        s.usage.output_tokens = @max(s.usage.output_tokens, p.getU64(u, "output_tokens"));
        s.usage.cache_read_tokens = @max(s.usage.cache_read_tokens, p.getU64(u, "cache_read_input_tokens"));
        s.usage.cache_write_tokens = @max(s.usage.cache_write_tokens, p.getU64(u, "cache_creation_input_tokens"));
    }
};

fn mapStop(s: []const u8) msg.FinishReason {
    const map = .{
        .{ "end_turn", .end_turn },         .{ "tool_use", .tool_use },
        .{ "max_tokens", .max_tokens },     .{ "model_context_window_exceeded", .max_tokens },
        .{ "stop_sequence", .stop_sequence }, .{ "refusal", .refusal },
        .{ "pause_turn", .other },
    };
    inline for (map) |e| if (std.mem.eql(u8, s, e[0])) return e[1];
    return .other;
}

/// "anthropic 400 invalid_request_error: <message>" from an error body.
fn errorMessage(arena: Allocator, status: u16, body: []const u8) []const u8 {
    const v = std.json.parseFromSliceLeaky(std.json.Value, arena, body, .{}) catch
        return std.fmt.allocPrint(arena, "anthropic {d}: {s}", .{ status, body }) catch body;
    const e = (if (v == .object) v.object.get("error") else null) orelse v;
    return std.fmt.allocPrint(arena, "anthropic {d} {s}: {s}", .{
        status, p.getStr(e, "type") orelse "error", p.getStr(e, "message") orelse body,
    }) catch body;
}
