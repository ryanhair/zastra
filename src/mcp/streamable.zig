//! MCP over Streamable HTTP (PLAN.md §17.5, D38).
//!
//! Modern (2026-07-28): every message is a POST carrying `_meta` and the
//! mirrored `MCP-Protocol-Version`, `Mcp-Method`, `Mcp-Name` and
//! `Mcp-Param-*` headers; there are no sessions. Replies are a JSON object or
//! an SSE stream scoped to the request. Tool list changes arrive on a
//! `subscriptions/listen` stream read by a background task.
//!
//! Legacy (2025-11-25): an `initialize` POST, then the `Mcp-Session-Id` the
//! server returns on every request, and a DELETE at shutdown. The deprecated
//! HTTP+SSE transport (2024-11-05) isn't supported.
//!
//! Era detection: a modern `server/discover` first. A 4xx whose body is not
//! a recognized modern error means a legacy server.

const std = @import("std");
const protocol = @import("protocol.zig");
const http = @import("../provider/http.zig");
const sse = @import("../provider/sse.zig");
const provider = @import("../provider/provider.zig");
const Allocator = std.mem.Allocator;
const Io = std.Io;

pub const Decl = struct {
    url: []const u8,
    /// An environment variable that, when set, replaces `url` (per-deploy
    /// endpoints, tests).
    url_env: ?[]const u8 = null,
    /// `Authorization: Bearer <value of this env var>`.
    bearer_env: ?[]const u8 = null,
    headers: []const [2][]const u8 = &.{},
    /// If the server can't be reached at `App.init`, start without its
    /// tools instead of failing.
    optional: bool = false,
};

pub const Streamable = struct {
    gpa: Allocator,
    io: Io,
    name: []const u8,
    decl: Decl,
    client: *http.Http,
    auth: ?[]const u8 = null,
    era: protocol.Era = .modern,
    /// The legacy protocol version, sent as `MCP-Protocol-Version`.
    legacy_version: []const u8 = protocol.legacy_version,
    session_id: ?[]u8 = null,
    list_changed_cap: bool = false,
    next_id: std.atomic.Value(i64) = .init(1),
    /// Set when the tool list changed (or the listen stream dropped, so
    /// changes may have been missed).
    changed: std.atomic.Value(bool) = .init(false),
    listen: ?Io.Future(void) = null,
    listening: std.atomic.Value(bool) = .init(false),
    /// Why the last request failed, for the caller's diagnostic.
    diag: provider.Diagnostic = .{},

    /// On failure, `diag` says why.
    pub fn start(gpa: Allocator, io: Io, client: *http.Http, name: []const u8, decl: Decl, env: ?*const std.process.Environ.Map, diag: *provider.Diagnostic) !*Streamable {
        const c = try gpa.create(Streamable);
        errdefer gpa.destroy(c);
        c.* = .{ .gpa = gpa, .io = io, .name = name, .decl = decl, .client = client };
        errdefer diag.* = c.diag;
        if (decl.url_env) |k| if (env) |e| if (e.get(k)) |v| if (v.len > 0) {
            c.decl.url = v;
        };
        if (decl.bearer_env) |k| {
            const v = (if (env) |e| e.get(k) else null) orelse {
                c.diag.print(0, "MCP server '{s}' needs {s} (its bearer token)", .{ name, k });
                return error.McpMissingToken;
            };
            c.auth = try gpa.print("Bearer {s}", .{v});
        }
        errdefer if (c.auth) |x| gpa.free(x);
        errdefer if (c.session_id) |x| gpa.free(x);
        try c.negotiate();
        return c;
    }

    fn negotiate(c: *Streamable) !void {
        var arena: std.heap.ArenaAllocator = .init(c.gpa);
        defer arena.deinit();
        const a = arena.allocator();
        const probe = try c.post(a, .modern, "server/discover", "", null, &.{});
        switch (probe) {
            .reply => |r| switch (r) {
                .result => |res| {
                    c.list_changed_cap = listChanged(res);
                    return;
                },
                .err => |e| {
                    if (e.code == protocol.unsupported_version) {
                        for (e.supportedVersions()) |v| if (v == .string) for (protocol.legacy_versions) |lv| {
                            if (std.mem.eql(u8, v.string, lv)) {
                                c.legacy_version = lv;
                                return c.initialize(a);
                            }
                        };
                    }
                    c.diag.print(0, "MCP server '{s}' rejected the protocol probe: {s} ({d})", .{ c.name, e.message, e.code });
                    return error.McpRequestFailed;
                },
            },
            .legacy_hint => return c.initialize(a),
        }
    }

    fn initialize(c: *Streamable, a: Allocator) !void {
        c.era = .legacy;
        const r = c.post(a, .legacy, "initialize", protocol.initializeParams(protocol.legacy_version), null, &.{}) catch |err| {
            if (err == error.McpHttpStatus) c.diag.print(0, "MCP server '{s}' at {s} answers neither the 2026-07-28 nor the 2025-11-25 Streamable HTTP protocol ({s}); the deprecated HTTP+SSE transport (2024-11-05) isn't supported", .{ c.name, c.decl.url, c.diag.message() });
            return err;
        };
        switch (r) {
            .reply => |reply| switch (reply) {
                .result => |res| {
                    c.list_changed_cap = listChanged(res);
                    if (protocol.getStr(res, "protocolVersion")) |v| for (protocol.legacy_versions) |lv| {
                        if (std.mem.eql(u8, v, lv)) c.legacy_version = lv;
                    };
                },
                .err => |e| {
                    c.diag.print(0, "MCP server '{s}' rejected initialize: {s}", .{ c.name, e.message });
                    return error.McpRequestFailed;
                },
            },
            .legacy_hint => {
                c.diag.print(0, "MCP server '{s}' at {s} doesn't answer initialize; the deprecated HTTP+SSE transport (2024-11-05) isn't supported", .{ c.name, c.decl.url });
                return error.McpRequestFailed;
            },
        }
        try c.notify(a, "notifications/initialized");
    }

    fn listChanged(result: std.json.Value) bool {
        const caps = if (result == .object) result.object.get("capabilities") orelse return false else return false;
        const tools = if (caps == .object) caps.object.get("tools") orelse return false else return false;
        const lc = if (tools == .object) tools.object.get("listChanged") orelse return false else return false;
        return lc == .bool and lc.bool;
    }

    /// Send a request. `name` becomes `Mcp-Name` (modern `tools/call`);
    /// `params_headers` are the call's `Mcp-Param-*` headers.
    pub fn request(c: *Streamable, arena: Allocator, method: []const u8, params: []const u8, name: ?[]const u8, param_headers: []const std.http.Header) !protocol.Reply {
        return switch (try c.post(arena, c.era, method, params, name, param_headers)) {
            .reply => |r| r,
            .legacy_hint => error.McpHttpStatus,
        };
    }

    const Outcome = union(enum) {
        reply: protocol.Reply,
        /// A 4xx without a recognized modern error: the server is legacy.
        legacy_hint,
    };

    fn headers(c: *Streamable, arena: Allocator, era: protocol.Era, method: []const u8, name: ?[]const u8, extra: []const std.http.Header) ![]const std.http.Header {
        var hs: std.ArrayList(std.http.Header) = .empty;
        try hs.append(arena, .{ .name = "accept", .value = "application/json, text/event-stream" });
        switch (era) {
            .modern => {
                try hs.append(arena, .{ .name = "MCP-Protocol-Version", .value = protocol.modern_version });
                try hs.append(arena, .{ .name = "Mcp-Method", .value = method });
                if (name) |n| try hs.append(arena, .{ .name = "Mcp-Name", .value = try protocol.headerValue(arena, n) });
                try hs.appendSlice(arena, extra);
            },
            .legacy => {
                if (!std.mem.eql(u8, method, "initialize")) try hs.append(arena, .{ .name = "MCP-Protocol-Version", .value = c.legacy_version });
                if (c.session_id) |sid| try hs.append(arena, .{ .name = "Mcp-Session-Id", .value = sid });
            },
        }
        if (c.auth) |v| try hs.append(arena, .{ .name = "authorization", .value = v });
        for (c.decl.headers) |h| try hs.append(arena, .{ .name = h[0], .value = h[1] });
        return hs.items;
    }

    fn post(c: *Streamable, arena: Allocator, era: protocol.Era, method: []const u8, params: []const u8, name: ?[]const u8, extra: []const std.http.Header) !Outcome {
        const id = c.next_id.fetchAdd(1, .monotonic);
        const body = try protocol.requestJson(arena, era, id, method, params);
        const res = c.client.request(c.decl.url, try c.headers(arena, era, method, name, extra), body, .{}) catch |err| {
            c.diag.print(0, "MCP server '{s}' ({s}): {t}", .{ c.name, c.decl.url, err });
            return error.McpConnectionFailed;
        };
        defer res.close();
        if (res.status == 401 or res.status == 403) {
            const www = res.header("www-authenticate") orelse "";
            if (c.decl.bearer_env) |k| {
                c.diag.print(res.status, "MCP server '{s}' rejected the token in {s} ({d}{s}{s})", .{ c.name, k, res.status, if (www.len > 0) ": " else "", www });
            } else {
                c.diag.print(res.status, "MCP server '{s}' needs authorization ({d}{s}{s}); set `.bearer_env` in z.mcp.http(...)", .{ c.name, res.status, if (www.len > 0) ": " else "", www });
            }
            return error.McpUnauthorized;
        }
        if (era == .legacy and std.mem.eql(u8, method, "initialize")) if (res.header("mcp-session-id")) |sid| {
            if (c.session_id) |old| c.gpa.free(old);
            c.session_id = try c.gpa.dupe(u8, sid);
        };
        if (!res.ok()) {
            const text = res.readAll(arena, 64 * 1024) catch "";
            if (protocol.errorBody(arena, text)) |e| {
                if (era == .modern and !e.isModern() and res.status >= 400 and res.status < 500) return .legacy_hint;
                return .{ .reply = .{ .err = e } };
            }
            if (era == .modern and res.status >= 400 and res.status < 500) return .legacy_hint;
            c.diag.print(res.status, "MCP server '{s}': HTTP {d}: {s}", .{ c.name, res.status, text[0..@min(text.len, 300)] });
            return error.McpHttpStatus;
        }
        const ctype = res.header("content-type") orelse "";
        if (std.mem.startsWith(u8, ctype, "text/event-stream")) {
            var events: sse.Stream = .init(c.gpa, res.reader);
            defer events.deinit();
            while (events.next() catch {
                c.diag.print(0, "MCP server '{s}': the response stream broke off", .{c.name});
                return error.McpConnectionFailed;
            }) |ev| {
                const in = protocol.parseIncoming(arena, ev.data) catch continue;
                switch (in) {
                    .reply => |r| if (r.id == id) return .{ .reply = r.reply },
                    .notification => |n| c.onNotification(n.method),
                    else => {},
                }
            }
            c.diag.print(0, "MCP server '{s}': the response stream ended without a reply to {s}", .{ c.name, method });
            return error.McpProtocolError;
        }
        const text = res.readAll(arena, 16 << 20) catch {
            c.diag.print(0, "MCP server '{s}': reading the response failed", .{c.name});
            return error.McpConnectionFailed;
        };
        const in = protocol.parseIncoming(arena, text) catch {
            c.diag.print(0, "MCP server '{s}': the response isn't JSON-RPC: {s}", .{ c.name, text[0..@min(text.len, 200)] });
            return error.McpProtocolError;
        };
        return switch (in) {
            .reply => |r| .{ .reply = r.reply },
            else => error.McpProtocolError,
        };
    }

    fn notify(c: *Streamable, arena: Allocator, method: []const u8) !void {
        const body = try protocol.notificationJson(arena, method, "");
        const res = c.client.request(c.decl.url, try c.headers(arena, .legacy, method, null, &.{}), body, .{}) catch return error.McpConnectionFailed;
        res.close();
    }

    fn onNotification(c: *Streamable, method: []const u8) void {
        if (std.mem.eql(u8, method, "notifications/tools/list_changed")) c.changed.store(true, .release);
    }

    /// Start (or restart) the `subscriptions/listen` stream for tool list
    /// changes, when the server is modern and advertises `listChanged`.
    pub fn subscribe(c: *Streamable) void {
        if (c.era != .modern or !c.list_changed_cap) return;
        if (c.listening.load(.acquire)) return;
        if (c.listen) |*f| {
            f.await(c.io);
            c.listen = null;
        }
        c.listening.store(true, .release);
        c.listen = c.io.concurrent(listenLoop, .{c}) catch blk: {
            c.listening.store(false, .release);
            break :blk null;
        };
    }

    fn listenLoop(c: *Streamable) void {
        defer {
            // Changes may have been missed while the stream was down.
            c.changed.store(true, .release);
            c.listening.store(false, .release);
        }
        var arena: std.heap.ArenaAllocator = .init(c.gpa);
        defer arena.deinit();
        const a = arena.allocator();
        const id = c.next_id.fetchAdd(1, .monotonic);
        const body = protocol.requestJson(a, .modern, id, "subscriptions/listen", "\"notifications\":{\"toolsListChanged\":true}") catch return;
        const hs = c.headers(a, .modern, "subscriptions/listen", null, &.{}) catch return;
        const res = c.client.request(c.decl.url, hs, body, .{ .idle_timeout_ms = 0, .max_retries = 0 }) catch return;
        defer res.close();
        if (!res.ok()) return;
        var events: sse.Stream = .init(c.gpa, res.reader);
        defer events.deinit();
        var scratch: std.heap.ArenaAllocator = .init(c.gpa);
        defer scratch.deinit();
        while (events.next() catch null) |ev| {
            _ = scratch.reset(.retain_capacity);
            const in = protocol.parseIncoming(scratch.allocator(), ev.data) catch continue;
            switch (in) {
                .notification => |n| c.onNotification(n.method),
                .reply => return, // the server closed the subscription
                else => {},
            }
        }
    }

    pub fn stop(c: *Streamable) void {
        if (c.listen) |*f| f.cancel(c.io);
        // Legacy sessions end with a DELETE.
        if (c.era == .legacy and c.session_id != null) {
            var arena: std.heap.ArenaAllocator = .init(c.gpa);
            defer arena.deinit();
            if (c.headers(arena.allocator(), .legacy, "", null, &.{})) |hs| {
                if (c.client.request(c.decl.url, hs, "", .{ .method = .DELETE, .max_retries = 0 })) |res| res.close() else |_| {}
            } else |_| {}
        }
        if (c.session_id) |sid| c.gpa.free(sid);
        if (c.auth) |x| c.gpa.free(x);
        c.gpa.destroy(c);
    }
};
