//! An in-process Streamable HTTP MCP server for tests (PLAN.md §17.5).
//!
//! - `.modern`: 2026-07-28. Checks the mirrored headers against the body,
//!   answers `tools/call` for `lookup` as an SSE stream, keeps a
//!   `subscriptions/listen` stream open and announces a tool list change
//!   after `grow` is called. `tools/list` has a `ttlMs`.
//! - `.legacy`: 2025-11-25 sessions: `initialize` returns `Mcp-Session-Id`,
//!   later requests must carry it, and DELETE ends it.
//! - `.unauthorized`: every request gets 401 with `WWW-Authenticate`.

const std = @import("std");
const Io = std.Io;

pub const Mode = enum { modern, legacy, unauthorized };

pub const Seen = struct {
    method: []const u8,
    mcp_method: []const u8,
    mcp_name: []const u8,
    protocol_version: []const u8,
    session: []const u8,
    authorization: []const u8,
    params: []const u8,
    body: []const u8,
};

pub const Fake = struct {
    gpa: std.mem.Allocator,
    io: Io,
    mode: Mode,
    server: Io.net.Server,
    accept_task: ?Io.Future(void) = null,
    group: Io.Group = .init,
    mutex: Io.Mutex = .init,
    arena: std.heap.ArenaAllocator,
    seen: std.ArrayList(Seen) = .empty,
    grown: std.atomic.Value(bool) = .init(false),
    deleted: std.atomic.Value(bool) = .init(false),
    stopping: std.atomic.Value(bool) = .init(false),
    lists: std.atomic.Value(u32) = .init(0),
    url_buf: [64]u8 = undefined,
    url: []const u8 = "",

    pub fn start(gpa: std.mem.Allocator, io: Io, mode: Mode) !*Fake {
        const f = try gpa.create(Fake);
        const addr: Io.net.IpAddress = try .parseIp4("127.0.0.1", 0);
        f.* = .{ .gpa = gpa, .io = io, .mode = mode, .server = try addr.listen(io, .{ .reuse_address = true }), .arena = .init(gpa) };
        f.url = try std.fmt.bufPrint(&f.url_buf, "http://127.0.0.1:{d}/mcp", .{f.server.socket.address.getPort()});
        f.accept_task = try io.concurrent(acceptLoop, .{f});
        return f;
    }

    pub fn stop(f: *Fake) void {
        f.stopping.store(true, .release);
        if (f.accept_task) |*t| t.cancel(f.io);
        f.group.cancel(f.io);
        f.server.deinit(f.io);
        f.arena.deinit();
        f.seen.deinit(f.gpa);
        f.gpa.destroy(f);
    }

    /// Requests received so far (copies).
    pub fn requests(f: *Fake) []const Seen {
        f.mutex.lockUncancelable(f.io);
        defer f.mutex.unlock(f.io);
        return f.seen.items;
    }

    pub fn find(f: *Fake, mcp_method: []const u8) ?Seen {
        for (f.requests()) |s| if (std.mem.eql(u8, s.mcp_method, mcp_method) or std.mem.indexOf(u8, s.body, mcp_method) != null) return s;
        return null;
    }

    fn acceptLoop(f: *Fake) void {
        while (true) {
            const conn = f.server.accept(f.io) catch return;
            // `concurrent`, not `async`: a listen stream holds its handler open.
            f.group.concurrent(f.io, handle, .{ f, conn }) catch handle(f, conn);
        }
    }

    fn record(f: *Fake, s: Seen) void {
        f.mutex.lockUncancelable(f.io);
        defer f.mutex.unlock(f.io);
        const a = f.arena.allocator();
        f.seen.append(f.gpa, .{
            .method = a.dupe(u8, s.method) catch "",
            .mcp_method = a.dupe(u8, s.mcp_method) catch "",
            .mcp_name = a.dupe(u8, s.mcp_name) catch "",
            .protocol_version = a.dupe(u8, s.protocol_version) catch "",
            .session = a.dupe(u8, s.session) catch "",
            .authorization = a.dupe(u8, s.authorization) catch "",
            .params = a.dupe(u8, s.params) catch "",
            .body = a.dupe(u8, s.body) catch "",
        }) catch {};
    }

    fn handle(f: *Fake, conn: Io.net.Stream) void {
        defer conn.close(f.io);
        var rbuf: [16 * 1024]u8 = undefined;
        var wbuf: [16 * 1024]u8 = undefined;
        var r = conn.reader(f.io, &rbuf);
        var w = conn.writer(f.io, &wbuf);
        var srv: std.http.Server = .init(&r.interface, &w.interface);
        var arena: std.heap.ArenaAllocator = .init(f.gpa);
        defer arena.deinit();
        while (!f.stopping.load(.acquire)) {
            _ = arena.reset(.retain_capacity);
            var req = srv.receiveHead() catch return;
            f.serve(arena.allocator(), &req) catch return;
        }
    }

    fn header(req: *std.http.Server.Request, name: []const u8) []const u8 {
        var it = req.iterateHeaders();
        while (it.next()) |h| if (std.ascii.eqlIgnoreCase(h.name, name)) return h.value;
        return "";
    }

    fn serve(f: *Fake, a: std.mem.Allocator, req: *std.http.Server.Request) !void {
        var seen: Seen = .{
            .method = @tagName(req.head.method),
            .mcp_method = header(req, "mcp-method"),
            .mcp_name = header(req, "mcp-name"),
            .protocol_version = header(req, "mcp-protocol-version"),
            .session = header(req, "mcp-session-id"),
            .authorization = header(req, "authorization"),
            .params = "",
            .body = "",
        };
        var params: std.ArrayList(u8) = .empty;
        var it = req.iterateHeaders();
        while (it.next()) |h| if (std.ascii.startsWithIgnoreCase(h.name, "mcp-param-")) {
            try params.print(a, "{s}={s};", .{ h.name["mcp-param-".len..], h.value });
        };
        seen.params = params.items;
        // Copy the headers before reading the body (which reuses the buffer).
        seen = .{
            .method = try a.dupe(u8, seen.method),
            .mcp_method = try a.dupe(u8, seen.mcp_method),
            .mcp_name = try a.dupe(u8, seen.mcp_name),
            .protocol_version = try a.dupe(u8, seen.protocol_version),
            .session = try a.dupe(u8, seen.session),
            .authorization = try a.dupe(u8, seen.authorization),
            .params = seen.params,
            .body = "",
        };
        const len = req.head.content_length orelse 0;
        var body_buf: [4096]u8 = undefined;
        const br = req.readerExpectNone(&body_buf);
        seen.body = try br.readAlloc(a, @intCast(len));
        f.record(seen);

        if (f.mode == .unauthorized) {
            return req.respond("", .{ .status = .unauthorized, .extra_headers = &.{.{ .name = "www-authenticate", .value = "Bearer realm=\"fake\"" }} });
        }
        if (req.head.method == .DELETE) {
            f.deleted.store(true, .release);
            return req.respond("", .{});
        }
        const v = std.json.parseFromSliceLeaky(std.json.Value, a, seen.body, .{}) catch
            return req.respond("", .{ .status = .bad_request });
        const method = v.object.get("method").?.string;
        const id = v.object.get("id") orelse return req.respond("", .{ .status = .accepted });
        const params_v = v.object.get("params") orelse .null;
        switch (f.mode) {
            .unauthorized => unreachable,
            .legacy => return f.legacy(a, req, method, id.integer, seen.session),
            .modern => return f.modern(a, req, method, id.integer, params_v, seen),
        }
    }

    fn json(req: *std.http.Server.Request, body: []const u8, extra: []const std.http.Header) !void {
        var hs: [4]std.http.Header = undefined;
        hs[0] = .{ .name = "content-type", .value = "application/json" };
        for (extra, 0..) |h, i| hs[i + 1] = h;
        try req.respond(body, .{ .extra_headers = hs[0 .. 1 + extra.len] });
    }

    fn legacy(f: *Fake, a: std.mem.Allocator, req: *std.http.Server.Request, method: []const u8, id: i64, session: []const u8) !void {
        _ = f;
        if (std.mem.eql(u8, method, "initialize")) return json(req, try std.fmt.allocPrint(a,
            \\{{"jsonrpc":"2.0","id":{d},"result":{{"protocolVersion":"2025-11-25","capabilities":{{"tools":{{}}}},"serverInfo":{{"name":"legacy","version":"1"}}}}}}
        , .{id}), &.{.{ .name = "mcp-session-id", .value = "sess-1" }});
        if (!std.mem.eql(u8, session, "sess-1"))
            return req.respond("{\"jsonrpc\":\"2.0\",\"error\":{\"code\":-32000,\"message\":\"Bad Request: No valid session ID provided\"},\"id\":null}", .{ .status = .bad_request, .extra_headers = &.{.{ .name = "content-type", .value = "application/json" }} });
        if (std.mem.eql(u8, method, "tools/list")) return json(req, try std.fmt.allocPrint(a,
            \\{{"jsonrpc":"2.0","id":{d},"result":{{"tools":[{{"name":"wiki","description":"Ask the wiki.","inputSchema":{{"type":"object","properties":{{"q":{{"type":"string"}}}},"required":["q"]}}}}]}}}}
        , .{id}), &.{});
        if (std.mem.eql(u8, method, "tools/call")) return json(req, try std.fmt.allocPrint(a,
            \\{{"jsonrpc":"2.0","id":{d},"result":{{"content":[{{"type":"text","text":"legacy answer"}}]}}}}
        , .{id}), &.{});
        return json(req, try std.fmt.allocPrint(a, "{{\"jsonrpc\":\"2.0\",\"id\":{d},\"error\":{{\"code\":-32601,\"message\":\"no such method\"}}}}", .{id}), &.{});
    }

    fn modern(f: *Fake, a: std.mem.Allocator, req: *std.http.Server.Request, method: []const u8, id: i64, params: std.json.Value, seen: Seen) !void {
        // Header/body validation, as a modern server must.
        const meta_version = blk: {
            if (params != .object) break :blk "";
            const meta = params.object.get("_meta") orelse break :blk "";
            const pv = meta.object.get("io.modelcontextprotocol/protocolVersion") orelse break :blk "";
            break :blk pv.string;
        };
        const name_body = if (params == .object) (if (params.object.get("name")) |n| n.string else "") else "";
        const name_ok = !std.mem.eql(u8, method, "tools/call") or std.mem.eql(u8, decodeHeader(a, seen.mcp_name), name_body);
        if (!std.mem.eql(u8, seen.protocol_version, meta_version) or !std.mem.eql(u8, seen.mcp_method, method) or !name_ok)
            return req.respond(try std.fmt.allocPrint(a, "{{\"jsonrpc\":\"2.0\",\"id\":{d},\"error\":{{\"code\":-32020,\"message\":\"Header mismatch\"}}}}", .{id}), .{ .status = .bad_request, .extra_headers = &.{.{ .name = "content-type", .value = "application/json" }} });

        if (std.mem.eql(u8, method, "server/discover")) return json(req, try std.fmt.allocPrint(a,
            \\{{"jsonrpc":"2.0","id":{d},"result":{{"resultType":"complete","supportedVersions":["2026-07-28"],"capabilities":{{"tools":{{"listChanged":true}}}}}}}}
        , .{id}), &.{});
        if (std.mem.eql(u8, method, "tools/list")) {
            _ = f.lists.fetchAdd(1, .monotonic);
            return json(req, try std.fmt.allocPrint(a,
                \\{{"jsonrpc":"2.0","id":{d},"result":{{"resultType":"complete","ttlMs":60000,"tools":[
                \\{{"name":"lookup","description":"Look up a city.","inputSchema":{{"type":"object","properties":{{"city":{{"type":"string","x-mcp-header":"City"}},"limit":{{"type":"integer","x-mcp-header":"Limit"}}}},"required":["city"]}}}},
                \\{{"name":"bad_header","description":"Invalid x-mcp-header.","inputSchema":{{"type":"object","properties":{{"x":{{"type":"number","x-mcp-header":"X"}}}}}}}},
                \\{{"name":"grow","description":"Adds a tool.","inputSchema":{{"type":"object"}}}}{s}]}}}}
            , .{ id, if (f.grown.load(.acquire)) ",{\"name\":\"grown\",\"description\":\"Added later.\",\"inputSchema\":{\"type\":\"object\"}}" else "" }), &.{});
        }
        if (std.mem.eql(u8, method, "subscriptions/listen")) {
            var buf: [1024]u8 = undefined;
            var bw = try req.respondStreaming(&buf, .{ .respond_options = .{ .extra_headers = &.{.{ .name = "content-type", .value = "text/event-stream" }} } });
            try bw.writer.print("data: {{\"jsonrpc\":\"2.0\",\"method\":\"notifications/subscriptions/acknowledged\",\"params\":{{\"_meta\":{{\"io.modelcontextprotocol/subscriptionId\":{d}}},\"notifications\":{{\"toolsListChanged\":true}}}}}}\n\n", .{id});
            try bw.flush();
            var announced = false;
            while (!f.stopping.load(.acquire)) {
                if (!announced and f.grown.load(.acquire)) {
                    try bw.writer.print("data: {{\"jsonrpc\":\"2.0\",\"method\":\"notifications/tools/list_changed\",\"params\":{{\"_meta\":{{\"io.modelcontextprotocol/subscriptionId\":{d}}}}}}}\n\n", .{id});
                    try bw.flush();
                    announced = true;
                }
                try bw.writer.writeAll(":\n\n"); // keep-alive comment
                try bw.flush();
                f.io.sleep(.fromMilliseconds(10), .awake) catch return;
            }
            return bw.end();
        }
        if (std.mem.eql(u8, method, "tools/call")) {
            if (std.mem.eql(u8, name_body, "grow")) {
                f.grown.store(true, .release);
                return json(req, try std.fmt.allocPrint(a, "{{\"jsonrpc\":\"2.0\",\"id\":{d},\"result\":{{\"resultType\":\"complete\",\"content\":[{{\"type\":\"text\",\"text\":\"grown\"}}]}}}}", .{id}), &.{});
            }
            // `lookup`: an SSE response with a progress notification first.
            var buf: [1024]u8 = undefined;
            var bw = try req.respondStreaming(&buf, .{ .respond_options = .{ .extra_headers = &.{.{ .name = "content-type", .value = "text/event-stream" }} } });
            try bw.writer.writeAll("data: {\"jsonrpc\":\"2.0\",\"method\":\"notifications/progress\",\"params\":{\"progress\":1}}\n\n");
            try bw.writer.print("data: {{\"jsonrpc\":\"2.0\",\"id\":{d},\"result\":{{\"resultType\":\"complete\",\"content\":[{{\"type\":\"text\",\"text\":\"sunny\"}}]}}}}\n\n", .{id});
            return bw.end();
        }
        return req.respond(try std.fmt.allocPrint(a, "{{\"jsonrpc\":\"2.0\",\"id\":{d},\"error\":{{\"code\":-32601,\"message\":\"Method not found\"}}}}", .{id}), .{ .status = .not_found, .extra_headers = &.{.{ .name = "content-type", .value = "application/json" }} });
    }

    fn decodeHeader(a: std.mem.Allocator, v: []const u8) []const u8 {
        if (!std.mem.startsWith(u8, v, "=?base64?") or !std.mem.endsWith(u8, v, "?=")) return v;
        const inner = v[9 .. v.len - 2];
        const dec = std.base64.standard.Decoder;
        const n = dec.calcSizeForSlice(inner) catch return v;
        const out = a.alloc(u8, n) catch return v;
        dec.decode(out, inner) catch return v;
        return out;
    }
};
