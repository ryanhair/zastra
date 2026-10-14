//! MCP client over stdio (PLAN.md §6.7): JSON-RPC 2.0, newline-delimited.
//!
//! `App.init` spawns each declared server, runs `initialize`, lists its tools
//! (following `nextCursor`), and splices the allowed tools into each agent's
//! request prefix. Tool lists are fixed for the life of the runtime;
//! `notifications/tools/list_changed` is logged.
//!
//! MCP tools are runtime-typed: the model sees them as `<server>__<tool>`,
//! arguments are validated against the server's `inputSchema`, and they show
//! up as the `.mcp` variant of an agent's `ToolCall`.

const std = @import("std");
const runtime = @import("../runtime.zig");
const provider = @import("../provider/provider.zig");
const errors = @import("../meta/errors.zig");
const mcp_decl = @import("mcp.zig");
const validate = @import("validate.zig");
const json = @import("../schema/json.zig");
const Allocator = std.mem.Allocator;
const Io = std.Io;

pub const protocol_version = "2025-06-18";

pub const Tool = struct {
    name: []const u8,
    /// `name` made safe for every provider (^[a-zA-Z0-9_-]+$).
    safe_name: []const u8,
    description: []const u8,
    schema_json: []const u8,
    schema: std.json.Value,
};

pub const Server = struct {
    name: []const u8,
    child: std.process.Child,
    in: Io.File.Writer,
    out: Io.File.Reader,
    in_buf: [4096]u8 = undefined,
    out_buf: [64 * 1024]u8 = undefined,
    next_id: i64 = 1,
    mutex: Io.Mutex = .init,
    tools: []Tool = &.{},
    arena: std.heap.ArenaAllocator,

    /// Send a request and wait for its response. Returns the `result`.
    fn request(s: *Server, io: Io, arena: Allocator, method: []const u8, params_json: []const u8) !std.json.Value {
        s.mutex.lockUncancelable(io);
        defer s.mutex.unlock(io);
        const id = s.next_id;
        s.next_id += 1;
        const w = &s.in.interface;
        try w.print("{{\"jsonrpc\":\"2.0\",\"id\":{d},\"method\":\"{s}\",\"params\":{s}}}\n", .{ id, method, params_json });
        try w.flush();
        while (true) {
            var line: Io.Writer.Allocating = .init(arena);
            _ = s.out.interface.streamDelimiter(&line.writer, '\n') catch |err| switch (err) {
                error.EndOfStream => return error.McpServerExited,
                else => return error.McpReadFailed,
            };
            s.out.interface.toss(1);
            const text = std.mem.trim(u8, line.written(), " \r\t");
            if (text.len == 0) continue;
            const v = std.json.parseFromSliceLeaky(std.json.Value, arena, text, .{}) catch return error.McpProtocolError;
            if (v != .object) continue;
            const rid = v.object.get("id") orelse {
                if (v.object.get("method")) |m| if (m == .string and std.mem.eql(u8, m.string, "notifications/tools/list_changed"))
                    std.log.info("zastra: MCP server '{s}' changed its tool list; zastra keeps the list from startup", .{s.name});
                continue;
            };
            if (rid != .integer or rid.integer != id) continue;
            if (v.object.get("error")) |e| {
                const msg = if (e == .object) (if (e.object.get("message")) |m| (if (m == .string) m.string else "") else "") else "";
                std.log.warn("zastra: MCP server '{s}' {s} failed: {s}", .{ s.name, method, msg });
                return error.McpRequestFailed;
            }
            return v.object.get("result") orelse .null;
        }
    }

    fn notify(s: *Server, io: Io, method: []const u8) !void {
        s.mutex.lockUncancelable(io);
        defer s.mutex.unlock(io);
        try s.in.interface.print("{{\"jsonrpc\":\"2.0\",\"method\":\"{s}\"}}\n", .{method});
        try s.in.interface.flush();
    }
};

pub const Manager = struct {
    gpa: Allocator,
    io: Io,
    st: *runtime.State,
    servers: []*Server,

    pub const vtable: runtime.McpVTable = .{ .call = callImpl };

    pub fn start(gpa: Allocator, io: Io, st: *runtime.State, comptime names: []const []const u8, comptime transports: []const mcp_decl.Transport) !*Manager {
        const m = try gpa.create(Manager);
        errdefer gpa.destroy(m);
        m.* = .{ .gpa = gpa, .io = io, .st = st, .servers = try gpa.alloc(*Server, names.len) };
        var started: usize = 0;
        errdefer {
            for (m.servers[0..started]) |s| stopServer(gpa, io, s);
            gpa.free(m.servers);
        }
        inline for (names, transports, 0..) |name, t, i| {
            m.servers[i] = startServer(gpa, io, name, t.stdio, st.env) catch |err| {
                st.diag.print(0, "MCP server '{s}' ({s}): {t}", .{ name, t.stdio[0], err });
                return error.McpFailed;
            };
            started += 1;
        }
        return m;
    }

    fn startServer(gpa: Allocator, io: Io, name: []const u8, argv: []const []const u8, env: ?*const std.process.Environ.Map) !*Server {
        const s = try gpa.create(Server);
        errdefer gpa.destroy(s);
        s.* = .{ .name = name, .child = undefined, .in = undefined, .out = undefined, .arena = .init(gpa) };
        errdefer s.arena.deinit();
        s.child = try std.process.spawn(io, .{
            .argv = argv,
            .stdin = .pipe,
            .stdout = .pipe,
            .stderr = .inherit,
            .environ_map = env,
        });
        errdefer {
            s.child.kill(io);
        }
        s.in = s.child.stdin.?.writerStreaming(io, &s.in_buf);
        s.out = s.child.stdout.?.readerStreaming(io, &s.out_buf);

        const a = s.arena.allocator();
        _ = try s.request(io, a, "initialize", "{\"protocolVersion\":\"" ++ protocol_version ++ "\",\"capabilities\":{},\"clientInfo\":{\"name\":\"zastra\",\"version\":\"0.1.0\"}}");
        try s.notify(io, "notifications/initialized");

        var tools: std.ArrayList(Tool) = .empty;
        var cursor: ?[]const u8 = null;
        while (true) {
            const params = if (cursor) |c| try std.fmt.allocPrint(a, "{{\"cursor\":{f}}}", .{json.fmt(c)}) else "{}";
            const r = try s.request(io, a, "tools/list", params);
            if (r != .object) return error.McpProtocolError;
            if (r.object.get("tools")) |list| if (list == .array) for (list.array.items) |t| {
                if (t != .object) continue;
                const tname = provider.getStr(t, "name") orelse continue;
                const schema = t.object.get("inputSchema") orelse try std.json.parseFromSliceLeaky(std.json.Value, a, "{\"type\":\"object\"}", .{});
                try tools.append(a, .{
                    .name = tname,
                    .safe_name = try safeName(a, tname),
                    .description = provider.getStr(t, "description") orelse "",
                    .schema_json = try std.json.Stringify.valueAlloc(a, schema, .{}),
                    .schema = schema,
                });
            };
            cursor = provider.getStr(r, "nextCursor");
            if (cursor == null) break;
        }
        s.tools = tools.items;
        return s;
    }

    fn safeName(a: Allocator, n: []const u8) ![]const u8 {
        const out = try a.alloc(u8, @min(n.len, 48));
        for (out, 0..) |*c, i| c.* = if (std.ascii.isAlphanumeric(n[i]) or n[i] == '_' or n[i] == '-') n[i] else '_';
        return out;
    }

    fn stopServer(gpa: Allocator, io: Io, s: *Server) void {
        if (s.child.stdin) |f| {
            f.close(io);
            s.child.stdin = null;
        }
        s.child.kill(io);
        s.arena.deinit();
        gpa.destroy(s);
    }

    pub fn stop(m: *Manager) void {
        for (m.servers) |s| stopServer(m.gpa, m.io, s);
        m.gpa.free(m.servers);
        m.gpa.destroy(m);
    }

    fn server(m: *Manager, name: []const u8) ?*Server {
        for (m.servers) |s| if (std.mem.eql(u8, s.name, name)) return s;
        return null;
    }

    /// `A.prefix` with A's MCP tools spliced in. Unknown names in `.allow`
    /// fail here, at `App.init`.
    pub fn completePrefix(m: *Manager, comptime A: type) !provider.Prefix {
        const Impl = provider.Impl(A.model.api);
        var aw: Io.Writer.Allocating = .init(m.gpa);
        defer aw.deinit();
        const w = &aw.writer;
        var n: usize = 0;
        inline for (A.mcp_tools) |set| {
            const s = m.server(set.server_name).?;
            if (set.allow) |allow| for (allow) |want| {
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

    fn callImpl(ptr: *anyopaque, arena: Allocator, server_name: []const u8, safe_tool: []const u8, args_json: []const u8) anyerror!runtime.McpResult {
        const m: *Manager = @ptrCast(@alignCast(ptr));
        const s = m.server(server_name) orelse return .{ .content = "Unknown MCP server.", .is_error = true };
        const t = for (s.tools) |t| {
            if (std.mem.eql(u8, t.safe_name, safe_tool)) break t;
        } else return .{ .content = try std.fmt.allocPrint(arena, "MCP server '{s}' has no tool '{s}'.", .{ server_name, safe_tool }), .is_error = true };

        const args = std.json.parseFromSliceLeaky(std.json.Value, arena, if (args_json.len == 0) "{}" else args_json, .{}) catch
            return .{ .content = "Invalid arguments: not valid JSON.", .is_error = true };
        if (try validate.validate(arena, t.schema, args)) |issue|
            return .{ .content = try std.fmt.allocPrint(arena, "Invalid arguments for {s}: {s}: {s}. Fix them and call the tool again.", .{ t.name, issue.path, issue.message }), .is_error = true };

        const params = try std.fmt.allocPrint(arena, "{{\"name\":{f},\"arguments\":{s}}}", .{ json.fmt(t.name), if (args_json.len == 0) "{}" else args_json });
        const r = try s.request(m.io, arena, "tools/call", params);
        const is_error = if (r == .object) (if (r.object.get("isError")) |e| e == .bool and e.bool else false) else false;
        // Prefer structured content; otherwise join the text parts.
        if (r == .object) if (r.object.get("structuredContent")) |sc| if (sc != .null)
            return .{ .content = try std.json.Stringify.valueAlloc(arena, sc, .{}), .is_error = is_error };
        var text: std.ArrayList(u8) = .empty;
        if (r == .object) if (r.object.get("content")) |c| if (c == .array) for (c.array.items) |part| {
            if (provider.getStr(part, "text")) |tx| {
                if (text.items.len > 0) try text.append(arena, '\n');
                try text.appendSlice(arena, tx);
            } else {
                if (text.items.len > 0) try text.append(arena, '\n');
                try text.appendSlice(arena, try std.json.Stringify.valueAlloc(arena, part, .{}));
            }
        };
        return .{ .content = text.items, .is_error = is_error };
    }
};
