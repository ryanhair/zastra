//! An in-process OTLP/HTTP collector for tests (PLAN.md §19.1): records each
//! request's body and headers and answers with `status`.

const std = @import("std");
const Io = std.Io;

pub const Request = struct {
    path: []const u8,
    content_type: []const u8,
    headers: []const std.http.Header,
    body: []const u8,
};

pub const Fake = struct {
    gpa: std.mem.Allocator,
    io: Io,
    server: Io.net.Server,
    accept_task: ?Io.Future(void) = null,
    group: Io.Group = .init,
    mutex: Io.Mutex = .init,
    arena: std.heap.ArenaAllocator,
    seen: std.ArrayList(Request) = .empty,
    stopping: std.atomic.Value(bool) = .init(false),
    /// Response status for every request.
    status: std.atomic.Value(u16) = .init(200),
    url_buf: [64]u8 = undefined,
    /// The endpoint to configure: requests go to `<url>/v1/traces`.
    url: []const u8 = "",

    pub fn start(gpa: std.mem.Allocator, io: Io) !*Fake {
        const f = try gpa.create(Fake);
        const addr: Io.net.IpAddress = try .parseIp4("127.0.0.1", 0);
        f.* = .{ .gpa = gpa, .io = io, .server = try addr.listen(io, .{ .reuse_address = true }), .arena = .init(gpa) };
        f.url = try std.fmt.bufPrint(&f.url_buf, "http://127.0.0.1:{d}", .{f.server.socket.address.getPort()});
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

    pub fn requests(f: *Fake) []const Request {
        f.mutex.lockUncancelable(f.io);
        defer f.mutex.unlock(f.io);
        return f.seen.items;
    }

    pub fn count(f: *Fake) usize {
        return f.requests().len;
    }

    /// Wait up to `ms` for at least `n` requests.
    pub fn waitFor(f: *Fake, n: usize, ms: u32) bool {
        var waited: u32 = 0;
        while (waited < ms) : (waited += 10) {
            if (f.count() >= n) return true;
            f.io.sleep(.fromMilliseconds(10), .awake) catch return false;
        }
        return f.count() >= n;
    }

    fn acceptLoop(f: *Fake) void {
        while (true) {
            const conn = f.server.accept(f.io) catch return;
            f.group.concurrent(f.io, handle, .{ f, conn }) catch handle(f, conn);
        }
    }

    fn handle(f: *Fake, conn: Io.net.Stream) void {
        defer conn.close(f.io);
        var rbuf: [16 * 1024]u8 = undefined;
        var wbuf: [4 * 1024]u8 = undefined;
        var r = conn.reader(f.io, &rbuf);
        var w = conn.writer(f.io, &wbuf);
        var srv: std.http.Server = .init(&r.interface, &w.interface);
        while (!f.stopping.load(.acquire)) {
            var req = srv.receiveHead() catch return;
            f.serve(&req) catch return;
        }
    }

    fn serve(f: *Fake, req: *std.http.Server.Request) !void {
        var hs: std.ArrayList(std.http.Header) = .empty;
        var path: []const u8 = undefined;
        var content_type: []const u8 = "";
        {
            f.mutex.lockUncancelable(f.io);
            defer f.mutex.unlock(f.io);
            const a = f.arena.allocator();
            path = try a.dupe(u8, req.head.target);
            var it = req.iterateHeaders();
            while (it.next()) |h| {
                try hs.append(a, .{ .name = try a.dupe(u8, h.name), .value = try a.dupe(u8, h.value) });
                if (std.ascii.eqlIgnoreCase(h.name, "content-type")) content_type = hs.items[hs.items.len - 1].value;
            }
        }
        const len = req.head.content_length orelse 0;
        var body_buf: [4096]u8 = undefined;
        const br = req.readerExpectNone(&body_buf);
        const body = blk: {
            f.mutex.lockUncancelable(f.io);
            defer f.mutex.unlock(f.io);
            break :blk try br.readAlloc(f.arena.allocator(), @intCast(len));
        };
        {
            f.mutex.lockUncancelable(f.io);
            defer f.mutex.unlock(f.io);
            try f.seen.append(f.gpa, .{ .path = path, .content_type = content_type, .headers = hs.items, .body = body });
        }
        try req.respond("{}", .{ .status = @enumFromInt(f.status.load(.acquire)), .extra_headers = &.{.{ .name = "content-type", .value = "application/json" }} });
    }

    pub fn header(r: Request, name: []const u8) ?[]const u8 {
        for (r.headers) |h| if (std.ascii.eqlIgnoreCase(h.name, name)) return h.value;
        return null;
    }
};
