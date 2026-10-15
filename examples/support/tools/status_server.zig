//! The example's service-status MCP server: Streamable HTTP, protocol
//! 2026-07-28 (stateless: no `initialize`, no sessions). One tool,
//! `service_status`, whose `service` parameter is mirrored into an
//! `Mcp-Param-Service` header (`x-mcp-header`) so a gateway could route on it.
//!
//!   status-mcp-server [port]     (0 picks a free port; prints the URL)

const std = @import("std");
const Io = std.Io;

const statuses = .{
    .{ "shipping", "degraded: carrier delays in the EU, 1-2 extra days" },
    .{ "refunds", "operational" },
    .{ "accounts", "operational" },
};

pub fn main(init: std.process.Init) !void {
    const io = init.io;
    const args = try init.minimal.args.toSlice(init.arena.allocator());
    const port = if (args.len > 1) try std.fmt.parseInt(u16, args[1], 10) else 8931;
    const addr: Io.net.IpAddress = try .parseIp4("127.0.0.1", port);
    var server = try addr.listen(io, .{ .reuse_address = true });
    defer server.deinit(io);
    var out_buf: [256]u8 = undefined;
    var out = Io.File.stdout().writerStreaming(io, &out_buf);
    try out.interface.print("http://127.0.0.1:{d}/mcp\n", .{server.socket.address.getPort()});
    try out.interface.flush();
    var group: Io.Group = .init;
    defer group.cancel(io);
    while (true) {
        const conn = server.accept(io) catch return;
        group.async(io, serve, .{ io, init.gpa, conn });
    }
}

fn serve(io: Io, gpa: std.mem.Allocator, conn: Io.net.Stream) void {
    defer conn.close(io);
    var rbuf: [16 * 1024]u8 = undefined;
    var wbuf: [16 * 1024]u8 = undefined;
    var r = conn.reader(io, &rbuf);
    var w = conn.writer(io, &wbuf);
    var srv: std.http.Server = .init(&r.interface, &w.interface);
    while (true) {
        var req = srv.receiveHead() catch return;
        var arena: std.heap.ArenaAllocator = .init(gpa);
        defer arena.deinit();
        handle(arena.allocator(), &req) catch return;
    }
}

fn handle(a: std.mem.Allocator, req: *std.http.Server.Request) !void {
    const json_type: []const std.http.Header = &.{.{ .name = "content-type", .value = "application/json" }};
    if (req.head.method != .POST) return req.respond("", .{ .status = .method_not_allowed });
    var body_buf: [4096]u8 = undefined;
    const body = try req.readerExpectNone(&body_buf).readAlloc(a, @intCast(req.head.content_length orelse 0));
    const v = std.json.parseFromSliceLeaky(std.json.Value, a, body, .{}) catch return req.respond("", .{ .status = .bad_request });
    const id = v.object.get("id") orelse return req.respond("", .{ .status = .accepted });
    const method = v.object.get("method").?.string;
    const params = v.object.get("params") orelse .null;
    const meta = if (params == .object) params.object.get("_meta") else null;
    const version = if (meta) |m| (if (m.object.get("io.modelcontextprotocol/protocolVersion")) |pv| pv.string else "") else "";
    if (!std.mem.eql(u8, version, "2026-07-28"))
        return req.respond(try std.fmt.allocPrint(a, "{{\"jsonrpc\":\"2.0\",\"id\":{d},\"error\":{{\"code\":-32022,\"message\":\"Unsupported protocol version\",\"data\":{{\"supported\":[\"2026-07-28\"],\"requested\":\"{s}\"}}}}}}", .{ id.integer, version }), .{ .status = .bad_request, .extra_headers = json_type });

    const result: []const u8 = if (std.mem.eql(u8, method, "server/discover"))
        "{\"resultType\":\"complete\",\"supportedVersions\":[\"2026-07-28\"],\"capabilities\":{\"tools\":{}},\"_meta\":{\"io.modelcontextprotocol/serverInfo\":{\"name\":\"acme-status\",\"version\":\"1.0\"}}}"
    else if (std.mem.eql(u8, method, "tools/list"))
        "{\"resultType\":\"complete\",\"ttlMs\":300000,\"tools\":[{\"name\":\"service_status\",\"description\":\"Current status of an Acme service (shipping, refunds, accounts).\",\"inputSchema\":{\"type\":\"object\",\"properties\":{\"service\":{\"type\":\"string\",\"enum\":[\"shipping\",\"refunds\",\"accounts\"],\"x-mcp-header\":\"Service\"}},\"required\":[\"service\"],\"additionalProperties\":false}}]}"
    else if (std.mem.eql(u8, method, "tools/call")) blk: {
        const service = params.object.get("arguments").?.object.get("service").?.string;
        var status: []const u8 = "unknown service";
        inline for (statuses) |s| if (std.mem.eql(u8, s[0], service)) {
            status = s[1];
        };
        break :blk try std.fmt.allocPrint(a, "{{\"resultType\":\"complete\",\"content\":[{{\"type\":\"text\",\"text\":\"{s}: {s}\"}}]}}", .{ service, status });
    } else return req.respond(try std.fmt.allocPrint(a, "{{\"jsonrpc\":\"2.0\",\"id\":{d},\"error\":{{\"code\":-32601,\"message\":\"Method not found\"}}}}", .{id.integer}), .{ .status = .not_found, .extra_headers = json_type });
    try req.respond(try std.fmt.allocPrint(a, "{{\"jsonrpc\":\"2.0\",\"id\":{d},\"result\":{s}}}", .{ id.integer, result }), .{ .extra_headers = json_type });
}
