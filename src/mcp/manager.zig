//! The MCP client manager (PLAN.md §6.7, §17.5, D38–D40).
//!
//! `App.init` connects to each declared server (stdio or Streamable HTTP,
//! either protocol era), lists its tools and splices the allowed ones into
//! each agent's request prefix. Tool lists are refreshed when a server says
//! they changed (a `subscriptions/listen` stream, or a legacy
//! `notifications/tools/list_changed`) or when their `ttlMs` runs out. A
//! refresh is applied at the next run start; a running agent keeps its tool
//! list for its whole run. Tools are sorted by name, so an unchanged list
//! gives a byte-identical prefix and keeps the prompt cache.
//!
//! MCP tools are runtime-typed: the model sees them as `<server>__<tool>`,
//! arguments are validated against the server's `inputSchema`, and they show
//! up as the `.mcp` variant of an agent's `ToolCall`.

const std = @import("std");
const runtime = @import("../runtime.zig");
const provider = @import("../provider/provider.zig");
const http = @import("../provider/http.zig");
const errors = @import("../meta/errors.zig");
const mcp_decl = @import("mcp.zig");
const protocol = @import("protocol.zig");
const validate = @import("validate.zig");
const json = @import("../schema/json.zig");
const Stdio = @import("stdio.zig").Stdio;
const Streamable = @import("streamable.zig").Streamable;
const Allocator = std.mem.Allocator;
const Io = std.Io;

pub const Tool = struct {
    name: []const u8,
    /// `name` made safe for every provider (^[a-zA-Z0-9_-]+$).
    safe_name: []const u8,
    description: []const u8,
    schema_json: []const u8,
    schema: std.json.Value,
    /// `x-mcp-header` parameters (HTTP servers).
    params: []const protocol.ParamHeader = &.{},
    /// False when the validator can't handle the schema (D40).
    validated: bool = true,
};

/// Which transports an App declares; only those are compiled in (§5.6).
pub const Kinds = struct { stdio: bool = false, http: bool = false };

pub fn kindsOf(comptime transports: []const mcp_decl.Transport) Kinds {
    var k: Kinds = .{};
    for (transports) |t| switch (t) {
        .stdio => k.stdio = true,
        .http => k.http = true,
    };
    return k;
}

pub const Options = struct {
    /// How long a stdio server gets to answer the `server/discover` probe
    /// before it's treated as a legacy (initialize) server.
    probe_timeout_ms: u32 = 5_000,
};

pub fn Manager(comptime kinds: Kinds) type {
    return struct {
        const M = @This();

        gpa: Allocator,
        io: Io,
        st: *runtime.State,
        servers: []*Server,
        client: if (kinds.http) *http.Http else void,
        mutex: Io.Mutex = .init,
        agents: std.ArrayList(Entry) = .empty,
        /// Prefixes replaced by a refresh; runs may still use them.
        retired: std.ArrayList([]const u8) = .empty,

        pub const vtable: runtime.McpVTable = .{ .call = callImpl, .prefix = prefixImpl };

        const Conn = union(enum) {
            stdio: if (kinds.stdio) *Stdio else void,
            http: if (kinds.http) *Streamable else void,
            /// An optional server that wasn't reachable at `App.init`.
            absent,
        };

        const Server = struct {
            name: []const u8,
            conn: Conn,
            tools: []const Tool = &.{},
            /// One arena per tool listing; kept until `stop` because calls
            /// in flight may still read an older list.
            arenas: std.ArrayList(*std.heap.ArenaAllocator) = .empty,
            generation: u64 = 0,
            expires_at_ms: ?i64 = null,
        };

        const Entry = struct {
            id: []const u8,
            servers: []const []const u8,
            build: *const fn (m: *M, strict: bool) anyerror!provider.Prefix,
            key: u64,
            prefix: provider.Prefix,
        };

        pub fn start(gpa: Allocator, io: Io, st: *runtime.State, comptime names: []const []const u8, comptime transports: []const mcp_decl.Transport, opts: Options) !*M {
            const m = try gpa.create(M);
            errdefer gpa.destroy(m);
            m.* = .{ .gpa = gpa, .io = io, .st = st, .servers = try gpa.alloc(*Server, names.len), .client = undefined };
            errdefer gpa.free(m.servers);
            if (kinds.http) {
                m.client = try gpa.create(http.Http);
                m.client.* = http.Http.init(gpa, io, .{ .max_retries = 1 }, st.env) catch |err| {
                    gpa.destroy(m.client);
                    st.diag.print(0, "MCP: starting the HTTP client: {t}", .{err});
                    return error.McpFailed;
                };
            }
            errdefer if (kinds.http) {
                m.client.deinit();
                gpa.destroy(m.client);
            };
            var started: usize = 0;
            errdefer for (m.servers[0..started]) |s| m.stopServer(s);
            inline for (names, transports, 0..) |name, t, i| {
                m.servers[i] = m.startServer(name, t, opts) catch |err| {
                    if (st.diag.message_len == 0) st.diag.print(0, "MCP server '{s}': {t}", .{ name, err });
                    return error.McpFailed;
                };
                started += 1;
            }
            return m;
        }

        fn startServer(m: *M, name: []const u8, comptime t: mcp_decl.Transport, opts: Options) !*Server {
            const s = try m.gpa.create(Server);
            errdefer m.gpa.destroy(s);
            s.* = .{ .name = name, .conn = switch (t) {
                .stdio => |argv| .{ .stdio = Stdio.start(m.gpa, m.io, name, argv, m.st.env, .{ .probe_timeout_ms = opts.probe_timeout_ms }) catch |err| {
                    m.st.diag.print(0, "MCP server '{s}' ({s}): {t}", .{ name, argv[0], err });
                    return err;
                } },
                .http => |d| blk: {
                    var diag: provider.Diagnostic = .{};
                    const c = Streamable.start(m.gpa, m.io, m.client, name, d, m.st.env, &diag) catch |err| {
                        if (diag.message_len == 0) diag.print(0, "MCP server '{s}' ({s}): {t}", .{ name, d.url, err });
                        if (d.optional) {
                            std.log.info("zastra: optional MCP server '{s}' is unavailable, so its tools are left out: {s}", .{ name, diag.message() });
                            break :blk .absent;
                        }
                        m.st.diag = diag;
                        return err;
                    };
                    break :blk .{ .http = c };
                },
            } };
            if (s.conn == .absent) return s;
            errdefer m.stopConn(s);
            m.listTools(s) catch |err| {
                if (m.st.diag.message_len == 0) m.st.diag.print(0, "MCP server '{s}': listing tools: {t}", .{ name, err });
                return err;
            };
            m.subscribe(s);
            return s;
        }

        fn stopConn(m: *M, s: *Server) void {
            _ = m;
            switch (s.conn) {
                .stdio => |c| if (kinds.stdio) c.stop() else unreachable,
                .http => |c| if (kinds.http) c.stop() else unreachable,
                .absent => {},
            }
        }

        fn stopServer(m: *M, s: *Server) void {
            m.stopConn(s);
            for (s.arenas.items) |a| {
                a.deinit();
                m.gpa.destroy(a);
            }
            s.arenas.deinit(m.gpa);
            m.gpa.destroy(s);
        }

        pub fn stop(m: *M) void {
            for (m.servers) |s| m.stopServer(s);
            m.gpa.free(m.servers);
            for (m.agents.items) |e| m.gpa.free(e.prefix.json);
            m.agents.deinit(m.gpa);
            for (m.retired.items) |j| m.gpa.free(j);
            m.retired.deinit(m.gpa);
            if (kinds.http) {
                m.client.deinit();
                m.gpa.destroy(m.client);
            }
            m.gpa.destroy(m);
        }

        fn request(m: *M, s: *Server, arena: Allocator, method: []const u8, params: []const u8, name: ?[]const u8, param_headers: []const std.http.Header) !protocol.Reply {
            _ = m;
            return switch (s.conn) {
                .stdio => |c| if (kinds.stdio) c.request(arena, method, params, null) else unreachable,
                .http => |c| if (kinds.http) c.request(arena, method, params, name, param_headers) else unreachable,
                .absent => error.McpServerUnavailable,
            };
        }

        fn isHttp(s: *const Server) bool {
            return s.conn == .http;
        }

        fn subscribe(m: *M, s: *Server) void {
            _ = m;
            switch (s.conn) {
                .stdio => |c| if (kinds.stdio) c.subscribe() catch |err| std.log.warn("zastra: MCP server '{s}': subscribing to tool list changes: {t}", .{ s.name, err }) else unreachable,
                .http => |c| if (kinds.http) c.subscribe() else unreachable,
                .absent => {},
            }
        }

        /// The server said its tool list changed (or a listen stream dropped).
        fn takeChanged(s: *Server) bool {
            return switch (s.conn) {
                .stdio => |c| if (kinds.stdio) c.changed.swap(false, .acq_rel) else unreachable,
                .http => |c| if (kinds.http) c.changed.swap(false, .acq_rel) else unreachable,
                .absent => false,
            };
        }

        fn serverDiag(s: *Server) []const u8 {
            return switch (s.conn) {
                .stdio, .absent => "",
                .http => |c| if (kinds.http) c.diag.message() else unreachable,
            };
        }

        /// List `s`'s tools (all pages) into a fresh arena.
        fn listTools(m: *M, s: *Server) !void {
            const ar = try m.gpa.create(std.heap.ArenaAllocator);
            ar.* = .init(m.gpa);
            errdefer {
                ar.deinit();
                m.gpa.destroy(ar);
            }
            const a = ar.allocator();
            var tools: std.ArrayList(Tool) = .empty;
            var cursor: ?[]const u8 = null;
            var ttl: ?i64 = null;
            while (true) {
                const params = if (cursor) |c| try std.fmt.allocPrint(a, "\"cursor\":{f}", .{json.fmt(c)}) else "";
                const reply = m.request(s, a, "tools/list", params, null, &.{}) catch |err| {
                    const d = serverDiag(s);
                    if (d.len > 0) m.st.diag.set(0, d);
                    return err;
                };
                const r = switch (reply) {
                    .result => |r| r,
                    .err => |e| {
                        m.st.diag.print(0, "MCP server '{s}': tools/list failed: {s}", .{ s.name, e.message });
                        return error.McpRequestFailed;
                    },
                };
                if (r != .object) return error.McpProtocolError;
                if (r.object.get("tools")) |list| if (list == .array) for (list.array.items) |t| {
                    if (t != .object) continue;
                    if (try m.toolOf(s, a, t)) |tool| try tools.append(a, tool);
                };
                if (protocol.getInt(r, "ttlMs")) |ms| if (ms >= 0) {
                    ttl = if (ttl) |cur| @min(cur, ms) else ms;
                };
                cursor = protocol.getStr(r, "nextCursor");
                if (cursor == null) break;
            }
            std.mem.sort(Tool, tools.items, {}, struct {
                fn lt(_: void, x: Tool, y: Tool) bool {
                    return std.mem.order(u8, x.name, y.name) == .lt;
                }
            }.lt);
            try s.arenas.append(m.gpa, ar);
            s.tools = tools.items;
            s.generation +%= 1;
            s.expires_at_ms = if (ttl) |ms| m.st.nowMs() + ms else null;
        }

        fn toolOf(m: *M, s: *Server, a: Allocator, t: std.json.Value) !?Tool {
            _ = m;
            const name = protocol.getStr(t, "name") orelse return null;
            const schema = t.object.get("inputSchema") orelse try std.json.parseFromSliceLeaky(std.json.Value, a, "{\"type\":\"object\"}", .{});
            var tool: Tool = .{
                .name = name,
                .safe_name = try safeName(a, name),
                .description = protocol.getStr(t, "description") orelse "",
                .schema_json = try std.json.Stringify.valueAlloc(a, schema, .{}),
                .schema = schema,
            };
            if (kinds.http and isHttp(s)) switch (try protocol.paramHeaders(a, schema)) {
                .ok => |ps| tool.params = ps,
                .invalid => |why| {
                    std.log.warn("zastra: MCP server '{s}': skipping tool '{s}': {s}", .{ s.name, name, why });
                    return null;
                },
            };
            if (validate.supported(schema)) |why| {
                std.log.warn("zastra: MCP server '{s}': arguments to tool '{s}' won't be validated: {s}", .{ s.name, name, why });
                tool.validated = false;
            }
            return tool;
        }

        fn safeName(a: Allocator, n: []const u8) ![]const u8 {
            const out = try a.alloc(u8, @min(n.len, 48));
            for (out, 0..) |*c, i| c.* = if (std.ascii.isAlphanumeric(n[i]) or n[i] == '_' or n[i] == '-') n[i] else '_';
            return out;
        }

        fn server(m: *M, name: []const u8) ?*Server {
            for (m.servers) |s| if (std.mem.eql(u8, s.name, name)) return s;
            return null;
        }

        /// Re-list servers whose tools changed or expired. Holds `mutex`.
        fn refreshLocked(m: *M) void {
            const now = m.st.nowMs();
            for (m.servers) |s| {
                const changed = takeChanged(s);
                const expired = if (s.expires_at_ms) |t| now >= t else false;
                if (changed or expired) m.listTools(s) catch |err|
                    std.log.warn("zastra: MCP server '{s}': refreshing tools failed ({t}); keeping the previous list", .{ s.name, err });
                if (changed) m.subscribe(s);
            }
        }

        fn keyOf(m: *M, names: []const []const u8) u64 {
            var h: std.hash.Wyhash = .init(0);
            for (names) |n| if (m.server(n)) |s| h.update(std.mem.asBytes(&s.generation));
            return h.final();
        }

        /// Register agent `A` (at `App.init`): build its prefix. Unknown
        /// names in `.allow` fail here.
        pub fn register(m: *M, comptime A: type) !void {
            const names = comptime blk: {
                var ns: []const []const u8 = &.{};
                for (A.mcp_tools) |set| ns = ns ++ &[_][]const u8{set.server_name};
                break :blk ns;
            };
            const p = try completePrefix(m, A, true);
            try m.agents.append(m.gpa, .{ .id = A.id, .servers = names, .build = Build(A).f, .key = m.keyOf(names), .prefix = p });
        }

        fn Build(comptime A: type) type {
            return struct {
                fn f(m: *M, strict: bool) anyerror!provider.Prefix {
                    return completePrefix(m, A, strict);
                }
            };
        }

        /// The prefix for a run of agent `agent_id` starting now, after
        /// applying any pending tool list refresh.
        fn prefixImpl(ptr: *anyopaque, agent_id: []const u8) anyerror!provider.Prefix {
            const m: *M = @ptrCast(@alignCast(ptr));
            m.mutex.lockUncancelable(m.io);
            defer m.mutex.unlock(m.io);
            m.refreshLocked();
            for (m.agents.items) |*e| if (std.mem.eql(u8, e.id, agent_id)) {
                const key = m.keyOf(e.servers);
                if (key == e.key) return e.prefix;
                const p = e.build(m, false) catch |err| {
                    std.log.warn("zastra: agent '{s}': rebuilding its MCP tools failed ({t}); keeping the previous list", .{ agent_id, err });
                    return e.prefix;
                };
                try m.retired.append(m.gpa, e.prefix.json);
                e.prefix = p;
                e.key = key;
                return p;
            };
            return error.McpUnknownAgent;
        }

        /// `A.prefix` with A's MCP tools spliced in. `strict`: a name in
        /// `.allow` the server doesn't have is an error (at `App.init`);
        /// after a refresh it's skipped.
        fn completePrefix(m: *M, comptime A: type, strict: bool) !provider.Prefix {
            const Impl = provider.Impl(A.model.api);
            var aw: Io.Writer.Allocating = .init(m.gpa);
            defer aw.deinit();
            const w = &aw.writer;
            var n: usize = 0;
            inline for (A.mcp_tools) |set| {
                const s = m.server(set.server_name).?;
                if (strict and s.conn != .absent) if (set.allow) |allow| for (allow) |want| {
                    const found = for (s.tools) |t| {
                        if (std.mem.eql(u8, t.name, want)) break true;
                    } else false;
                    if (!found) {
                        var names: std.ArrayList([]const u8) = .empty;
                        defer names.deinit(m.gpa);
                        for (s.tools) |t| try names.append(m.gpa, t.name);
                        const near = errors.closest(want, names.items);
                        m.st.diag.print(0, "agent '{s}': MCP server '{s}' has no tool '{s}'{s}{s}{s}", .{
                            A.id, s.name, want, if (near != null) " (did you mean '" else "", near orelse "", if (near != null) "'?)" else "",
                        });
                        return error.McpUnknownTool;
                    }
                };
                for (s.tools) |t| {
                    if (set.allow) |allow| {
                        const ok = for (allow) |want| {
                            if (std.mem.eql(u8, t.name, want)) break true;
                        } else false;
                        if (!ok) continue;
                    }
                    if (n > 0) try w.writeByte(',');
                    n += 1;
                    const exposed = try std.fmt.allocPrint(m.gpa, "{s}__{s}", .{ s.name, t.safe_name });
                    defer m.gpa.free(exposed);
                    try Impl.writeToolDef(w, exposed, t.description, t.schema_json);
                }
            }
            const p = try A.prefix.withTools(m.gpa, aw.written());
            if (p.json.ptr == A.prefix.json.ptr) return .{ .json = try m.gpa.dupe(u8, p.json), .open_items = p.open_items, .hash = p.hash };
            return p;
        }

        fn findTool(m: *M, server_name: []const u8, safe_tool: []const u8) ?struct { s: *Server, t: Tool } {
            m.mutex.lockUncancelable(m.io);
            defer m.mutex.unlock(m.io);
            const s = m.server(server_name) orelse return null;
            for (s.tools) |t| if (std.mem.eql(u8, t.safe_name, safe_tool)) return .{ .s = s, .t = t };
            return null;
        }

        fn callImpl(ptr: *anyopaque, arena: Allocator, server_name: []const u8, safe_tool: []const u8, args_json: []const u8) anyerror!runtime.McpResult {
            const m: *M = @ptrCast(@alignCast(ptr));
            const found = m.findTool(server_name, safe_tool) orelse
                return .{ .content = try std.fmt.allocPrint(arena, "MCP server '{s}' has no tool '{s}'.", .{ server_name, safe_tool }), .is_error = true };
            const s = found.s;
            const t = found.t;

            const args_text = if (args_json.len == 0) "{}" else args_json;
            const args = std.json.parseFromSliceLeaky(std.json.Value, arena, args_text, .{}) catch
                return .{ .content = "Invalid arguments: not valid JSON.", .is_error = true };
            if (t.validated) if (try validate.validate(arena, t.schema, args)) |issue|
                return .{ .content = try std.fmt.allocPrint(arena, "Invalid arguments for {s}: {s}: {s}. Fix them and call the tool again.", .{ t.name, issue.path, issue.message }), .is_error = true };
            const param_headers = if (kinds.http and isHttp(s)) try protocol.paramHeaderValues(arena, t.params, args) else &.{};

            var params = try std.fmt.allocPrint(arena, "\"name\":{f},\"arguments\":{s}", .{ json.fmt(t.name), args_text });
            // An InputRequiredResult with only `requestState` may be retried
            // right away; one asking for input zastra can't give ends the call.
            var attempt: u32 = 0;
            while (attempt < 3) : (attempt += 1) {
                const reply = m.request(s, arena, "tools/call", params, t.name, param_headers) catch |err| {
                    const d = serverDiag(s);
                    if (d.len > 0) m.st.diagPrint("{s}", .{d});
                    return err;
                };
                const r = switch (reply) {
                    .result => |r| r,
                    .err => |e| {
                        // The tool's schema may have changed: re-list at the next run.
                        if (e.code == protocol.header_mismatch) markChanged(s);
                        return .{ .content = try std.fmt.allocPrint(arena, "The MCP server returned an error: {s}", .{e.message}), .is_error = true };
                    },
                };
                const rt = protocol.resultType(r);
                if (std.mem.eql(u8, rt, "complete")) return render(arena, r);
                if (!std.mem.eql(u8, rt, "input_required"))
                    return .{ .content = try std.fmt.allocPrint(arena, "The MCP server returned an unrecognized result type '{s}'.", .{rt}), .is_error = true };
                if (r.object.get("inputRequests")) |reqs| if (reqs == .object and reqs.object.count() > 0) {
                    var what: std.ArrayList(u8) = .empty;
                    var it = reqs.object.iterator();
                    while (it.next()) |e| {
                        if (what.items.len > 0) try what.appendSlice(arena, ", ");
                        try what.appendSlice(arena, protocol.getStr(e.value_ptr.*, "method") orelse e.key_ptr.*);
                    }
                    std.log.warn("zastra: MCP server '{s}' tool '{s}' asked for input zastra can't provide: {s}", .{ s.name, t.name, what.items });
                    return .{ .content = try std.fmt.allocPrint(arena, "The MCP server needs input zastra can't provide ({s}), so '{s}' couldn't run.", .{ what.items, t.name }), .is_error = true };
                };
                const state = r.object.get("requestState") orelse
                    return .{ .content = "The MCP server asked for more input without saying what.", .is_error = true };
                params = try std.fmt.allocPrint(arena, "\"name\":{f},\"arguments\":{s},\"requestState\":{s}", .{ json.fmt(t.name), args_text, try std.json.Stringify.valueAlloc(arena, state, .{}) });
            }
            return .{ .content = "The MCP server kept asking for more input.", .is_error = true };
        }

        fn markChanged(s: *Server) void {
            switch (s.conn) {
                .stdio => |c| if (kinds.stdio) c.changed.store(true, .release) else unreachable,
                .http => |c| if (kinds.http) c.changed.store(true, .release) else unreachable,
                .absent => {},
            }
        }

        /// Prefer structured content; otherwise join the content parts.
        fn render(arena: Allocator, r: std.json.Value) !runtime.McpResult {
            const is_error = if (r == .object) (if (r.object.get("isError")) |e| e == .bool and e.bool else false) else false;
            if (r == .object) if (r.object.get("structuredContent")) |sc| if (sc != .null)
                return .{ .content = try std.json.Stringify.valueAlloc(arena, sc, .{}), .is_error = is_error };
            var text: std.ArrayList(u8) = .empty;
            if (r == .object) if (r.object.get("content")) |c| if (c == .array) for (c.array.items) |part| {
                if (text.items.len > 0) try text.append(arena, '\n');
                if (protocol.getStr(part, "text")) |tx| {
                    try text.appendSlice(arena, tx);
                } else try text.appendSlice(arena, try std.json.Stringify.valueAlloc(arena, part, .{}));
            };
            return .{ .content = text.items, .is_error = is_error };
        }
    };
}
