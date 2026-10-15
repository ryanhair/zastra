//! MCP wire details shared by the stdio and HTTP connections (PLAN.md §17.5,
//! D38): request framing for both eras, reply classification, header value
//! encoding and `x-mcp-header` handling.
//!
//! Modern (2026-07-28) requests are stateless: every request carries its
//! protocol version and client capabilities in `params._meta`. Legacy
//! (2025-11-25 and earlier) servers need an `initialize` handshake first.

const std = @import("std");
const json = @import("../schema/json.zig");
const Allocator = std.mem.Allocator;
const Value = std.json.Value;

pub const modern_version = "2026-07-28";
pub const legacy_version = "2025-11-25";
/// Legacy versions zastra can fall back to, newest first.
pub const legacy_versions = [_][]const u8{ legacy_version, "2025-06-18", "2025-03-26" };
pub const client_name = "zastra";
pub const client_version = "0.1.0";

pub const Era = enum { modern, legacy };

/// Protocol-defined error codes (2026-07-28).
pub const header_mismatch = -32020;
pub const missing_client_capability = -32021;
pub const unsupported_version = -32022;

const meta_json = "\"_meta\":{\"io.modelcontextprotocol/protocolVersion\":\"" ++ modern_version ++
    "\",\"io.modelcontextprotocol/clientInfo\":{\"name\":\"" ++ client_name ++ "\",\"version\":\"" ++ client_version ++
    "\"},\"io.modelcontextprotocol/clientCapabilities\":{}}";

/// A JSON-RPC request. `params` are the members of the params object
/// (`"name":"x","arguments":{}`), possibly empty; modern requests get `_meta`.
pub fn requestJson(arena: Allocator, era: Era, id: i64, method: []const u8, params: []const u8) Allocator.Error![]u8 {
    const sep = if (params.len > 0) "," else "";
    return switch (era) {
        .modern => std.fmt.allocPrint(arena, "{{\"jsonrpc\":\"2.0\",\"id\":{d},\"method\":\"{s}\",\"params\":{{{s}{s}{s}}}}}", .{ id, method, params, sep, meta_json }),
        .legacy => std.fmt.allocPrint(arena, "{{\"jsonrpc\":\"2.0\",\"id\":{d},\"method\":\"{s}\",\"params\":{{{s}}}}}", .{ id, method, params }),
    };
}

pub fn notificationJson(arena: Allocator, method: []const u8, params: []const u8) Allocator.Error![]u8 {
    return std.fmt.allocPrint(arena, "{{\"jsonrpc\":\"2.0\",\"method\":\"{s}\",\"params\":{{{s}}}}}", .{ method, params });
}

pub fn initializeParams(comptime version: []const u8) []const u8 {
    return "\"protocolVersion\":\"" ++ version ++ "\",\"capabilities\":{},\"clientInfo\":{\"name\":\"" ++ client_name ++ "\",\"version\":\"" ++ client_version ++ "\"}";
}

pub const RpcError = struct {
    code: i64,
    message: []const u8,
    data: Value = .null,

    /// One of the errors only a 2026-07-28 server sends.
    pub fn isModern(e: RpcError) bool {
        return e.code == header_mismatch or e.code == missing_client_capability or e.code == unsupported_version;
    }

    /// `data.supported` of an UnsupportedProtocolVersion error.
    pub fn supportedVersions(e: RpcError) []const Value {
        if (e.data != .object) return &.{};
        const s = e.data.object.get("supported") orelse return &.{};
        return if (s == .array) s.array.items else &.{};
    }
};

pub const Reply = union(enum) {
    result: Value,
    err: RpcError,
};

/// What a parsed incoming line or SSE event is.
pub const Incoming = union(enum) {
    reply: struct { id: i64, reply: Reply },
    notification: struct { method: []const u8, params: Value },
    /// A request from the server (legacy only): zastra declares no client
    /// capabilities, so it answers with an error.
    request: struct { id: Value, method: []const u8 },
    other,
};

pub fn parseIncoming(arena: Allocator, text: []const u8) error{ OutOfMemory, ProtocolError }!Incoming {
    const v = std.json.parseFromSliceLeaky(Value, arena, text, .{}) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return error.ProtocolError,
    };
    if (v != .object) return .other;
    const o = v.object;
    if (o.get("method")) |m| if (m == .string) {
        if (o.get("id")) |id| return .{ .request = .{ .id = id, .method = m.string } };
        return .{ .notification = .{ .method = m.string, .params = o.get("params") orelse .null } };
    };
    const id = o.get("id") orelse return .other;
    const n: i64 = switch (id) {
        .integer => |i| i,
        .string => |s| std.fmt.parseInt(i64, s, 10) catch return .other,
        else => return .other,
    };
    if (o.get("error")) |e| return .{ .reply = .{ .id = n, .reply = .{ .err = rpcError(e) } } };
    return .{ .reply = .{ .id = n, .reply = .{ .result = o.get("result") orelse .null } } };
}

pub fn rpcError(e: Value) RpcError {
    if (e != .object) return .{ .code = 0, .message = "" };
    return .{
        .code = if (e.object.get("code")) |c| (if (c == .integer) c.integer else 0) else 0,
        .message = if (e.object.get("message")) |m| (if (m == .string) m.string else "") else "",
        .data = e.object.get("data") orelse .null,
    };
}

/// An HTTP error body that is a JSON-RPC error response, if it is one.
pub fn errorBody(arena: Allocator, body: []const u8) ?RpcError {
    const in = parseIncoming(arena, body) catch return null;
    return switch (in) {
        .reply => |r| switch (r.reply) {
            .err => |e| e,
            .result => null,
        },
        else => blk: {
            // An error without an id is still a JSON-RPC error.
            const v = std.json.parseFromSliceLeaky(Value, arena, body, .{}) catch break :blk null;
            if (v != .object) break :blk null;
            const e = v.object.get("error") orelse break :blk null;
            break :blk rpcError(e);
        },
    };
}

/// `result.resultType`; absent means "complete" (earlier versions).
pub fn resultType(result: Value) []const u8 {
    if (result != .object) return "complete";
    const t = result.object.get("resultType") orelse return "complete";
    return if (t == .string) t.string else "complete";
}

pub fn getStr(v: Value, key: []const u8) ?[]const u8 {
    if (v != .object) return null;
    const x = v.object.get(key) orelse return null;
    return if (x == .string) x.string else null;
}

pub fn getInt(v: Value, key: []const u8) ?i64 {
    if (v != .object) return null;
    const x = v.object.get(key) orelse return null;
    return if (x == .integer) x.integer else null;
}

// ── HTTP header values ───────────────────────────────────────────────────────

/// A header value as the Streamable HTTP binding requires: plain if it is
/// header-safe ASCII, else `=?base64?<base64 of UTF-8>?=`.
pub fn headerValue(arena: Allocator, v: []const u8) Allocator.Error![]const u8 {
    if (headerSafe(v)) return v;
    const enc = std.base64.standard.Encoder;
    const out = try arena.alloc(u8, "=?base64?".len + enc.calcSize(v.len) + "?=".len);
    @memcpy(out[0..9], "=?base64?");
    _ = enc.encode(out[9 .. out.len - 2], v);
    @memcpy(out[out.len - 2 ..], "?=");
    return out;
}

fn headerSafe(v: []const u8) bool {
    if (v.len == 0) return true;
    if (v[0] == ' ' or v[0] == '\t' or v[v.len - 1] == ' ' or v[v.len - 1] == '\t') return false;
    for (v) |c| if (!(c == ' ' or c == '\t' or (c >= 0x21 and c <= 0x7e))) return false;
    // A plain value that looks encoded must be encoded too.
    if (std.mem.startsWith(u8, v, "=?base64?") and std.mem.endsWith(u8, v, "?=")) return false;
    return true;
}

// ── x-mcp-header ─────────────────────────────────────────────────────────────

/// A tool parameter mirrored into an `Mcp-Param-{name}` header.
pub const ParamHeader = struct {
    name: []const u8,
    /// The chain of `properties` keys from the schema root.
    path: []const []const u8,
};

/// Collect a tool's `x-mcp-header` annotations, or say why they're invalid
/// (the tool is then excluded, as the spec requires).
pub fn paramHeaders(arena: Allocator, schema: Value) Allocator.Error!union(enum) { ok: []const ParamHeader, invalid: []const u8 } {
    var out: std.ArrayList(ParamHeader) = .empty;
    var path: std.ArrayList([]const u8) = .empty;
    if (try collect(arena, schema, &path, &out, true)) |why| return .{ .invalid = why };
    for (out.items, 0..) |a, i| for (out.items[0..i]) |b| if (std.ascii.eqlIgnoreCase(a.name, b.name))
        return .{ .invalid = try std.fmt.allocPrint(arena, "x-mcp-header \"{s}\" is used twice", .{a.name}) };
    return .{ .ok = out.items };
}

fn collect(arena: Allocator, schema: Value, path: *std.ArrayList([]const u8), out: *std.ArrayList(ParamHeader), reachable: bool) Allocator.Error!?[]const u8 {
    if (schema != .object) return null;
    const o = schema.object;
    if (o.get("x-mcp-header")) |h| {
        if (!reachable or path.items.len == 0) return "x-mcp-header must be on a property reached only through `properties`";
        if (h != .string or h.string.len == 0 or !isToken(h.string)) return "x-mcp-header must be a non-empty HTTP header token";
        const ty = getStr(schema, "type") orelse "";
        if (!std.mem.eql(u8, ty, "string") and !std.mem.eql(u8, ty, "integer") and !std.mem.eql(u8, ty, "boolean"))
            return try std.fmt.allocPrint(arena, "x-mcp-header \"{s}\" is on a parameter of type '{s}'; only string, integer and boolean are allowed", .{ h.string, ty });
        try out.append(arena, .{ .name = h.string, .path = try arena.dupe([]const u8, path.items) });
    }
    var it = o.iterator();
    while (it.next()) |e| {
        const k = e.key_ptr.*;
        if (std.mem.eql(u8, k, "properties")) {
            if (e.value_ptr.* != .object) continue;
            var pit = e.value_ptr.object.iterator();
            while (pit.next()) |p| {
                try path.append(arena, p.key_ptr.*);
                defer _ = path.pop();
                if (try collect(arena, p.value_ptr.*, path, out, reachable)) |why| return why;
            }
        } else if (std.mem.eql(u8, k, "x-mcp-header")) {
            continue;
        } else switch (e.value_ptr.*) {
            // Anything below another keyword isn't statically reachable.
            .object => if (try collect(arena, e.value_ptr.*, path, out, false)) |why| return why,
            .array => |a| for (a.items) |x| {
                if (try collect(arena, x, path, out, false)) |why| return why;
            },
            else => {},
        }
    }
    return null;
}

fn isToken(s: []const u8) bool {
    for (s) |c| {
        const ok = std.ascii.isAlphanumeric(c) or std.mem.indexOfScalar(u8, "!#$%&'*+-.^_`|~", c) != null;
        if (!ok) return false;
    }
    return true;
}

/// The `Mcp-Param-*` headers for one call's arguments. Absent and null
/// values are omitted.
pub fn paramHeaderValues(arena: Allocator, headers: []const ParamHeader, args: Value) Allocator.Error![]const std.http.Header {
    var out: std.ArrayList(std.http.Header) = .empty;
    for (headers) |h| {
        var v = args;
        for (h.path) |k| {
            if (v != .object) break;
            v = v.object.get(k) orelse .null;
        } else {
            const text: ?[]const u8 = switch (v) {
                .string => |s| s,
                .integer => |i| try std.fmt.allocPrint(arena, "{d}", .{i}),
                .bool => |b| if (b) "true" else "false",
                else => null,
            };
            if (text) |t| try out.append(arena, .{
                .name = try std.fmt.allocPrint(arena, "Mcp-Param-{s}", .{h.name}),
                .value = try headerValue(arena, t),
            });
        }
    }
    return out.items;
}

test headerValue {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    // The examples from the Streamable HTTP binding.
    try std.testing.expectEqualStrings("us-west1", try headerValue(a, "us-west1"));
    try std.testing.expectEqualStrings("=?base64?SGVsbG8sIOS4lueVjA==?=", try headerValue(a, "Hello, 世界"));
    try std.testing.expectEqualStrings("=?base64?IHBhZGRlZCA=?=", try headerValue(a, " padded "));
    try std.testing.expectEqualStrings("=?base64?bGluZTEKbGluZTI=?=", try headerValue(a, "line1\nline2"));
    try std.testing.expectEqualStrings("=?base64?PT9iYXNlNjQ/bGl0ZXJhbD89?=", try headerValue(a, "=?base64?literal?="));
}

test paramHeaders {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const ok = try std.json.parseFromSliceLeaky(Value, a,
        \\{"type":"object","properties":{"region":{"type":"string","x-mcp-header":"Region"},"opts":{"type":"object","properties":{"n":{"type":"integer","x-mcp-header":"N"}}}}}
    , .{});
    const hs = (try paramHeaders(a, ok)).ok;
    try std.testing.expectEqual(@as(usize, 2), hs.len);
    const args = try std.json.parseFromSliceLeaky(Value, a, "{\"region\":\"Zürich\",\"opts\":{\"n\":7}}", .{});
    const vals = try paramHeaderValues(a, hs, args);
    try std.testing.expectEqualStrings("Mcp-Param-Region", vals[0].name);
    try std.testing.expectEqualStrings("=?base64?WsO8cmljaA==?=", vals[0].value);
    try std.testing.expectEqualStrings("7", vals[1].value);
    for ([_][]const u8{
        \\{"type":"object","properties":{"xs":{"type":"array","items":{"type":"string","x-mcp-header":"X"}}}}
        ,
        \\{"type":"object","properties":{"f":{"type":"number","x-mcp-header":"F"}}}
        ,
        \\{"type":"object","properties":{"a":{"type":"string","x-mcp-header":"A"},"b":{"type":"string","x-mcp-header":"a"}}}
        ,
        \\{"type":"object","properties":{"a":{"type":"string","x-mcp-header":"bad name"}}}
        ,
        \\{"type":"object","anyOf":[{"properties":{"a":{"type":"string","x-mcp-header":"A"}}}]}
    }) |bad| {
        const s = try std.json.parseFromSliceLeaky(Value, a, bad, .{});
        try std.testing.expect((try paramHeaders(a, s)) == .invalid);
    }
}

test requestJson {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const r = try requestJson(arena.allocator(), .modern, 3, "tools/list", "");
    const v = try std.json.parseFromSliceLeaky(Value, arena.allocator(), r, .{});
    const meta = v.object.get("params").?.object.get("_meta").?;
    try std.testing.expectEqualStrings(modern_version, getStr(meta, "io.modelcontextprotocol/protocolVersion").?);
    const l = try requestJson(arena.allocator(), .legacy, 4, "tools/call", "\"name\":\"x\"");
    try std.testing.expectEqualStrings("{\"jsonrpc\":\"2.0\",\"id\":4,\"method\":\"tools/call\",\"params\":{\"name\":\"x\"}}", l);
}
