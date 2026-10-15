//! The provider layer (PLAN.md §6.2).
//!
//! A provider is a module with:
//! - `buildPrefix(comptime PrefixParts) Prefix`: the static part of the
//!   request body, serialized at comptime (§5.5)
//! - `Stream`: `open(arena, http, Request)`, `next() !?Event`, `close()`
//!
//! Providers are selected at comptime from a model's `catalog.Spec.api`
//! through `Impl(api)`, so an App that only uses Anthropic models never
//! references the OpenAI module (§5.6).

const std = @import("std");
const catalog = @import("../catalog/catalog.zig");
const msg = @import("../message.zig");
const Http = @import("http.zig").Http;
const Allocator = std.mem.Allocator;

pub const Message = msg.Message;
pub const Usage = msg.Usage;
pub const FinishReason = msg.FinishReason;

pub fn Impl(comptime api: catalog.Api) type {
    return switch (api) {
        .anthropic => @import("anthropic.zig"),
        .openai_responses => @import("openai_responses.zig"),
        .openai_compat => @import("openai_compat.zig"),
    };
}

/// One tool definition, as the agent knows it at comptime.
pub const ToolDef = struct {
    name: []const u8,
    description: []const u8,
    /// Schema rendered in the provider's tool dialect.
    schema: []const u8,
    /// OpenAI strict mode is possible (no `z.Json` inside).
    strict_ok: bool = true,
};

pub const OutputFormat = struct {
    name: []const u8,
    /// Schema rendered in the provider's structured-output dialect.
    schema: []const u8,
};

pub const Effort = enum { low, medium, high, xhigh, max };

/// Reasoning settings resolved at comptime from an agent's `.reasoning` and
/// `.show_reasoning` against the model's capabilities (PLAN.md D37).
pub const Reasoning = union(enum) {
    /// Reason, and stream readable reasoning if `summarized`. Anthropic
    /// `{type:"adaptive"}` (plus `display: "summarized"`); OpenAI an effort,
    /// `.effort` or "medium" (plus `summary: "auto"`).
    on: struct { summarized: bool = false },
    /// Anthropic `{type:"enabled", budget_tokens: N}`.
    budget: u32,
    /// Anthropic `{type:"disabled"}`; OpenAI effort "none".
    disabled,
};

/// Everything static about a request.
pub const PrefixParts = struct {
    spec: catalog.Spec,
    system: ?[]const u8 = null,
    tools: []const ToolDef = &.{},
    output: ?OutputFormat = null,
    temperature: ?f64 = null,
    effort: ?Effort = null,
    reasoning: ?Reasoning = null,
    /// Raw JSON object members appended verbatim, e.g.
    /// `"thinking":{"type":"adaptive","display":"summarized"}`.
    extra: ?[]const u8 = null,
    /// More tool definitions are added at runtime (MCP): always emit the
    /// tools array and record where to insert them.
    dynamic_tools: bool = false,
};

/// The precomputed request prefix. `json` is an unterminated JSON object;
/// the provider's `writeBody` completes it.
pub const Prefix = struct {
    json: []const u8,
    /// The prefix ends inside an open array (Anthropic `system` blocks,
    /// OpenAI `messages` or `input`) holding this many items.
    open_items: u32,
    hash: u64,
    /// Byte offset just before the tools array's closing `]`, when the
    /// prefix was built with `dynamic_tools`.
    tools_insert_at: ?usize = null,
    static_tools: u32 = 0,

    /// Splice runtime tool definitions (comma-separated provider JSON) into
    /// the tools array. Done once per agent at `App.init`.
    pub fn withTools(p: Prefix, gpa: Allocator, defs_json: []const u8) Allocator.Error!Prefix {
        const at = p.tools_insert_at orelse return p;
        if (defs_json.len == 0) return p;
        const sep = if (p.static_tools > 0) "," else "";
        const json = try std.mem.concat(gpa, u8, &.{ p.json[0..at], sep, defs_json, p.json[at..] });
        return .{
            .json = json,
            .open_items = p.open_items,
            .hash = std.hash.Wyhash.hash(0, json),
            .tools_insert_at = null,
            .static_tools = p.static_tools,
        };
    }
};

pub fn prefixHash(comptime json: []const u8) u64 {
    @setEvalBranchQuota(10_000_000);
    return std.hash.Wyhash.hash(0, json);
}

pub const ToolChoice = union(enum) {
    auto,
    none,
    /// Any tool (Anthropic `any`, OpenAI `required`).
    required,
    tool: []const u8,
};

/// Everything dynamic about a request.
pub const Request = struct {
    /// "https://api.anthropic.com" etc., already resolved from the environment.
    base_url: []const u8,
    api_key: ?[]const u8,
    prefix: Prefix,
    /// Appended to the system prompt at runtime (working memory), outside
    /// the cached prefix.
    system_suffix: ?[]const u8 = null,
    messages: []const Message,
    max_tokens: u32,
    max_tokens_field: catalog.MaxTokensField = .max_tokens,
    tool_choice: ToolChoice = .auto,
    headers: []const [2][]const u8 = &.{},
    /// Filled when the provider returns an error response.
    diag: ?*Diagnostic = null,
};

pub const Delta = union(enum) {
    text: []const u8,
    reasoning: []const u8,
    tool_call_start: struct { index: u32, id: []const u8, name: []const u8 },
    tool_call_args: struct { index: u32, json: []const u8 },
};

pub const Finish = struct {
    reason: FinishReason,
    usage: Usage,
    /// The complete assistant message, allocated in the stream's arena.
    message: Message,
};

pub const Event = union(enum) {
    delta: Delta,
    finish: Finish,
};

pub const Error = error{
    OutOfMemory,
    Canceled,
    ConnectionFailed,
    Timeout,
    StreamInterrupted,
    InvalidUrl,
    NoCaCertificates,
    CaBundleInvalid,
    /// 401/403.
    Unauthorized,
    /// 429 after retries.
    RateLimited,
    /// 400/404/422: the request was rejected. See the diagnostic.
    BadRequest,
    /// 5xx after retries, or an `error` event mid-stream.
    ProviderError,
    /// The provider sent something zastra couldn't parse.
    ProtocolError,
};

/// Details of the last failure, without allocation surprises: fixed buffers.
pub const Diagnostic = struct {
    status: u16 = 0,
    message_buf: [1024]u8 = undefined,
    message_len: usize = 0,

    pub fn message(d: *const Diagnostic) []const u8 {
        return d.message_buf[0..d.message_len];
    }

    pub fn set(d: *Diagnostic, status: u16, text: []const u8) void {
        d.status = status;
        d.message_len = @min(text.len, d.message_buf.len);
        @memcpy(d.message_buf[0..d.message_len], text[0..d.message_len]);
    }

    pub fn print(d: *Diagnostic, status: u16, comptime fmt: []const u8, args: anytype) void {
        d.status = status;
        const s = std.fmt.bufPrint(&d.message_buf, fmt, args) catch d.message_buf[0..];
        d.message_len = s.len;
    }
};

/// Map an error HTTP status to an error, recording the body in `diag`.
pub fn statusError(status: u16, body: []const u8, diag: ?*Diagnostic) Error {
    if (diag) |d| d.set(status, body);
    return switch (status) {
        401, 403 => error.Unauthorized,
        429 => error.RateLimited,
        400, 404, 409, 413, 422 => error.BadRequest,
        else => error.ProviderError,
    };
}

/// Map a failed body read, explaining an idle timeout in `diag`.
pub fn bodyReadError(res: *@import("http.zig").Response, diag: ?*Diagnostic) Error {
    const err = res.readError();
    if (err == error.Timeout) if (diag) |d|
        d.print(0, "no data from the provider for {d} ms (raise `.http.idle_timeout_ms` in App.init for slow reasoning models)", .{res.http.opts.idle_timeout_ms});
    return err;
}

pub fn mapHttpError(err: anyerror) Error {
    return switch (err) {
        error.OutOfMemory => error.OutOfMemory,
        error.Canceled => error.Canceled,
        error.Timeout => error.Timeout,
        error.InvalidUrl => error.InvalidUrl,
        error.StreamInterrupted => error.StreamInterrupted,
        error.NoCaCertificates => error.NoCaCertificates,
        error.CaBundleInvalid => error.CaBundleInvalid,
        else => error.ConnectionFailed,
    };
}

/// Accumulates the assistant message across stream events.
pub const Builder = struct {
    arena: Allocator,
    blocks: std.ArrayList(msg.Block) = .empty,
    /// Per provider index: position in `blocks` and in-progress buffers.
    open: std.AutoArrayHashMapUnmanaged(u32, Open) = .empty,

    pub const Open = struct {
        block: usize,
        buf: std.ArrayList(u8) = .empty,
        sig: std.ArrayList(u8) = .empty,
    };

    pub fn startText(b: *Builder, index: u32) !void {
        try b.blocks.append(b.arena, .{ .text = "" });
        try b.open.put(b.arena, index, .{ .block = b.blocks.items.len - 1 });
    }
    pub fn startReasoning(b: *Builder, index: u32, initial_sig: ?[]const u8) !void {
        try b.blocks.append(b.arena, .{ .reasoning = .{ .text = "" } });
        var o: Open = .{ .block = b.blocks.items.len - 1 };
        if (initial_sig) |s| try o.sig.appendSlice(b.arena, s);
        try b.open.put(b.arena, index, o);
    }
    pub fn startToolUse(b: *Builder, index: u32, id: []const u8, name: []const u8) !void {
        try b.blocks.append(b.arena, .{ .tool_use = .{ .id = try b.arena.dupe(u8, id), .name = try b.arena.dupe(u8, name), .input_json = "" } });
        try b.open.put(b.arena, index, .{ .block = b.blocks.items.len - 1 });
    }
    pub fn addOpaque(b: *Builder, provider: []const u8, json: []const u8) !void {
        try b.blocks.append(b.arena, .{ .provider_opaque = .{ .provider = provider, .json = try b.arena.dupe(u8, json) } });
    }
    pub fn append(b: *Builder, index: u32, bytes: []const u8) !void {
        const o = b.open.getPtr(index) orelse return;
        try o.buf.appendSlice(b.arena, bytes);
    }
    pub fn appendSig(b: *Builder, index: u32, bytes: []const u8) !void {
        const o = b.open.getPtr(index) orelse return;
        try o.sig.appendSlice(b.arena, bytes);
    }
    pub fn has(b: *Builder, index: u32) bool {
        return b.open.contains(index);
    }
    pub fn stop(b: *Builder, index: u32) void {
        const o = b.open.fetchSwapRemove(index) orelse return;
        finalize(b, o.value);
    }
    fn finalize(b: *Builder, o: Open) void {
        const blk = &b.blocks.items[o.block];
        switch (blk.*) {
            .text => blk.* = .{ .text = o.buf.items },
            .reasoning => blk.* = .{ .reasoning = .{ .text = o.buf.items, .signature = if (o.sig.items.len > 0) o.sig.items else null } },
            .tool_use => |t| blk.* = .{ .tool_use = .{ .id = t.id, .name = t.name, .input_json = if (o.buf.items.len == 0) "{}" else o.buf.items } },
            else => {},
        }
    }
    pub fn finish(b: *Builder) Message {
        for (b.open.values()) |o| finalize(b, o);
        b.open.clearRetainingCapacity();
        // Drop empty text blocks (providers sometimes open one and never fill it).
        var out: std.ArrayList(msg.Block) = .empty;
        for (b.blocks.items) |blk| {
            if (blk == .text and blk.text.len == 0) continue;
            out.append(b.arena, blk) catch return .{ .role = .assistant, .content = .{ .blocks = b.blocks.items } };
        }
        return .{ .role = .assistant, .content = .{ .blocks = out.items } };
    }
};

/// Small helpers for writing request JSON at runtime.
pub const W = struct {
    pub fn str(w: *std.Io.Writer, s: []const u8) !void {
        try std.json.Stringify.encodeJsonString(s, .{}, w);
    }
};

/// Comptime JSON string literal (re-exported for providers).
pub const jsonStr = @import("../schema/json_schema.zig").str;

/// Parse an SSE `data:` payload into a dynamic value.
pub fn parseData(scratch: Allocator, data: []const u8) Error!std.json.Value {
    return std.json.parseFromSliceLeaky(std.json.Value, scratch, data, .{}) catch |err| switch (err) {
        error.OutOfMemory => error.OutOfMemory,
        else => error.ProtocolError,
    };
}

pub fn getObj(v: std.json.Value, key: []const u8) ?std.json.ObjectMap {
    if (v != .object) return null;
    const x = v.object.get(key) orelse return null;
    return if (x == .object) x.object else null;
}
pub fn getStr(v: std.json.Value, key: []const u8) ?[]const u8 {
    if (v != .object) return null;
    const x = v.object.get(key) orelse return null;
    return if (x == .string) x.string else null;
}
pub fn getInt(v: std.json.Value, key: []const u8) ?i64 {
    if (v != .object) return null;
    const x = v.object.get(key) orelse return null;
    return if (x == .integer) x.integer else null;
}
pub fn getU64(v: std.json.Value, key: []const u8) u64 {
    const i = getInt(v, key) orelse return 0;
    return if (i < 0) 0 else @intCast(i);
}

/// The base URL for a spec: `<base_url_env>` from the environment if set.
pub fn baseUrl(spec: catalog.Spec, env: ?*const std.process.Environ.Map) []const u8 {
    if (spec.base_url_env) |name| if (env) |e| if (e.get(name)) |v| if (v.len > 0) return std.mem.trimEnd(u8, v, "/");
    return spec.base_url;
}
