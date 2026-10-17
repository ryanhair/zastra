//! MCP over stdio (PLAN.md §17.5): newline-delimited JSON-RPC with a spawned
//! server. A background reader routes responses to waiting requests by id,
//! notes `notifications/tools/list_changed`, and answers the requests legacy
//! servers may send (zastra declares no client capabilities).
//!
//! The era is found with a `server/discover` probe: a result or a modern
//! error means 2026-07-28; any other error, or no answer within the probe
//! timeout, means a legacy server, which gets the `initialize` handshake.

const std = @import("std");
const builtin = @import("builtin");
const protocol = @import("protocol.zig");
const json = @import("../schema/json.zig");
const Allocator = std.mem.Allocator;
const Io = std.Io;

extern "kernel32" fn TerminateProcess(process: std.os.windows.HANDLE, exit_code: u32) callconv(.winapi) std.os.windows.BOOL;

pub const Stdio = struct {
    gpa: Allocator,
    io: Io,
    name: []const u8,
    child: std.process.Child,
    in: Io.File.Writer = undefined,
    out: Io.File.Reader = undefined,
    in_buf: [4096]u8 = undefined,
    out_buf: [64 * 1024]u8 = undefined,
    write_mutex: Io.Mutex = .init,
    pending_mutex: Io.Mutex = .init,
    pending: std.AutoHashMapUnmanaged(i64, *Pending) = .empty,
    next_id: std.atomic.Value(i64) = .init(1),
    reader: ?Io.Future(void) = null,
    closed: std.atomic.Value(bool) = .init(false),
    era: protocol.Era = .modern,
    /// The server advertised `tools.listChanged`.
    list_changed_cap: bool = false,
    /// Set by the reader when the server's tool list changed.
    changed: std.atomic.Value(bool) = .init(false),

    const Pending = struct {
        event: Io.Event = .unset,
        /// The reply line (gpa-owned), or null if the server went away.
        line: ?[]u8 = null,
    };

    pub const Options = struct {
        /// How long a silent server gets to answer the `server/discover`
        /// probe before it's treated as legacy.
        probe_timeout_ms: u32 = 5_000,
    };

    pub fn start(gpa: Allocator, io: Io, name: []const u8, argv: []const []const u8, env: ?*const std.process.Environ.Map, opts: Options) !*Stdio {
        const c = try gpa.create(Stdio);
        c.* = .{ .gpa = gpa, .io = io, .name = name, .child = undefined };
        c.child = std.process.spawn(io, .{
            .argv = argv,
            .stdin = .pipe,
            .stdout = .pipe,
            .stderr = .inherit,
            .environ_map = env,
        }) catch |err| {
            gpa.destroy(c);
            return err;
        };
        c.in = c.child.stdin.?.writerStreaming(io, &c.in_buf);
        c.out = c.child.stdout.?.readerStreaming(io, &c.out_buf);
        c.reader = io.concurrent(readLoop, .{c}) catch {
            c.child.kill(io);
            gpa.destroy(c);
            return error.McpNeedsConcurrency;
        };
        c.negotiate(opts) catch |err| {
            c.stop();
            return err;
        };
        return c;
    }

    fn negotiate(c: *Stdio, opts: Options) !void {
        var arena: std.heap.ArenaAllocator = .init(c.gpa);
        defer arena.deinit();
        const a = arena.allocator();
        const probe = c.requestEra(a, .modern, "server/discover", "", opts.probe_timeout_ms) catch |err| switch (err) {
            error.Timeout => null,
            else => return err,
        };
        if (probe) |reply| switch (reply) {
            .result => |r| {
                c.era = .modern;
                c.list_changed_cap = listChanged(r);
                return;
            },
            .err => |e| if (e.isModern()) {
                // Modern, but not 2026-07-28: use a legacy version it lists.
                for (e.supportedVersions()) |v| if (v == .string) for (protocol.legacy_versions) |lv| {
                    if (std.mem.eql(u8, v.string, lv)) return c.initialize(a);
                };
                std.log.err("zastra: MCP server '{s}' supports none of zastra's protocol versions ({s}, {s}): {s}", .{ c.name, protocol.modern_version, protocol.legacy_version, e.message });
                return error.McpUnsupportedVersion;
            },
        };
        return c.initialize(a);
    }

    fn initialize(c: *Stdio, a: Allocator) !void {
        c.era = .legacy;
        const r = try c.requestEra(a, .legacy, "initialize", protocol.initializeParams(protocol.legacy_version), 30_000);
        switch (r) {
            .result => |res| c.list_changed_cap = listChanged(res),
            .err => |e| {
                std.log.err("zastra: MCP server '{s}' rejected initialize: {s}", .{ c.name, e.message });
                return error.McpRequestFailed;
            },
        }
        try c.send(try protocol.notificationJson(a, "notifications/initialized", ""));
    }

    fn listChanged(result: std.json.Value) bool {
        const caps = if (result == .object) result.object.get("capabilities") orelse return false else return false;
        const tools = if (caps == .object) caps.object.get("tools") orelse return false else return false;
        const lc = if (tools == .object) tools.object.get("listChanged") orelse return false else return false;
        return lc == .bool and lc.bool;
    }

    /// Open a `subscriptions/listen` stream for tool list changes (modern
    /// servers that advertise `listChanged`). Its notifications are handled
    /// by the reader; the request itself stays open until shutdown.
    pub fn subscribe(c: *Stdio) !void {
        if (c.era != .modern or !c.list_changed_cap) return;
        var arena: std.heap.ArenaAllocator = .init(c.gpa);
        defer arena.deinit();
        const id = c.next_id.fetchAdd(1, .monotonic);
        try c.send(try protocol.requestJson(arena.allocator(), .modern, id, "subscriptions/listen", "\"notifications\":{\"toolsListChanged\":true}"));
    }

    pub fn request(c: *Stdio, arena: Allocator, method: []const u8, params: []const u8, timeout_ms: ?u32) !protocol.Reply {
        return c.requestEra(arena, c.era, method, params, timeout_ms);
    }

    fn requestEra(c: *Stdio, arena: Allocator, era: protocol.Era, method: []const u8, params: []const u8, timeout_ms: ?u32) !protocol.Reply {
        if (c.closed.load(.acquire)) return error.McpServerExited;
        const id = c.next_id.fetchAdd(1, .monotonic);
        var p: Pending = .{};
        {
            c.pending_mutex.lockUncancelable(c.io);
            defer c.pending_mutex.unlock(c.io);
            try c.pending.put(c.gpa, id, &p);
        }
        c.send(try protocol.requestJson(arena, era, id, method, params)) catch |err| {
            c.forget(id, &p);
            return err;
        };
        if (timeout_ms) |ms| {
            p.event.waitTimeout(c.io, .{ .duration = .{ .raw = .fromMilliseconds(ms), .clock = .awake } }) catch |err| {
                c.forget(id, &p);
                return switch (err) {
                    error.Timeout => if (p.event.isSet()) c.take(arena, &p) else error.Timeout,
                    error.Canceled => error.Canceled,
                };
            };
        } else p.event.wait(c.io) catch {
            c.forget(id, &p);
            return error.Canceled;
        };
        return c.take(arena, &p);
    }

    /// Stop waiting for `id`. If the reader already answered, its line is freed.
    fn forget(c: *Stdio, id: i64, p: *Pending) void {
        c.pending_mutex.lockUncancelable(c.io);
        _ = c.pending.remove(id);
        c.pending_mutex.unlock(c.io);
        if (p.event.isSet()) if (p.line) |l| {
            c.gpa.free(l);
            p.line = null;
        };
    }

    fn take(c: *Stdio, arena: Allocator, p: *Pending) !protocol.Reply {
        const line = p.line orelse return error.McpServerExited;
        defer c.gpa.free(line);
        p.line = null;
        const in = protocol.parseIncoming(arena, line) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            error.ProtocolError => return error.McpProtocolError,
        };
        return switch (in) {
            .reply => |r| r.reply,
            else => error.McpProtocolError,
        };
    }

    fn send(c: *Stdio, line: []const u8) !void {
        c.write_mutex.lockUncancelable(c.io);
        defer c.write_mutex.unlock(c.io);
        const w = &c.in.interface;
        try w.writeAll(line);
        try w.writeByte('\n');
        try w.flush();
    }

    fn readLoop(c: *Stdio) void {
        var scratch: std.heap.ArenaAllocator = .init(c.gpa);
        defer scratch.deinit();
        while (true) {
            _ = scratch.reset(.retain_capacity);
            const a = scratch.allocator();
            var line: Io.Writer.Allocating = .init(a);
            _ = c.out.interface.streamDelimiter(&line.writer, '\n') catch break;
            c.out.interface.toss(1);
            const text = std.mem.trim(u8, line.written(), " \r\t");
            if (text.len == 0) continue;
            const in = protocol.parseIncoming(a, text) catch continue;
            switch (in) {
                .reply => |r| {
                    c.pending_mutex.lockUncancelable(c.io);
                    defer c.pending_mutex.unlock(c.io);
                    const p = c.pending.get(r.id) orelse continue; // e.g. the listen stream ending
                    _ = c.pending.remove(r.id);
                    p.line = c.gpa.dupe(u8, text) catch null;
                    p.event.set(c.io);
                },
                .notification => |n| if (std.mem.eql(u8, n.method, "notifications/tools/list_changed")) {
                    c.changed.store(true, .release);
                },
                .request => |r| {
                    // Legacy servers may ask for sampling, roots or
                    // elicitation; zastra declared none of them.
                    const id_json = json.stringifyValueAlloc(a, r.id) catch continue;
                    const reply = std.fmt.allocPrint(a, "{{\"jsonrpc\":\"2.0\",\"id\":{s},\"error\":{{\"code\":-32601,\"message\":\"zastra doesn't support {s}\"}}}}", .{ id_json, r.method }) catch continue;
                    c.send(reply) catch {};
                },
                .other => {},
            }
        }
        c.closed.store(true, .release);
        c.pending_mutex.lockUncancelable(c.io);
        defer c.pending_mutex.unlock(c.io);
        var it = c.pending.valueIterator();
        while (it.next()) |p| p.*.event.set(c.io);
        c.pending.clearRetainingCapacity();
    }

    /// Close stdin (the spec's shutdown signal), then make sure the process
    /// is gone and the reader has finished.
    pub fn stop(c: *Stdio) void {
        if (c.child.stdin) |f| {
            f.close(c.io);
            c.child.stdin = null;
        }
        // Give the server a moment to exit on its own; then end it without
        // closing the pipe the reader is still reading.
        var waited: u32 = 0;
        while (!c.closed.load(.acquire) and waited < 1_000) : (waited += 10)
            c.io.sleep(.fromMilliseconds(10), .awake) catch break;
        if (!c.closed.load(.acquire)) if (c.child.id) |id| {
            if (builtin.os.tag == .windows) {
                _ = TerminateProcess(id, 1);
            } else std.posix.kill(id, .KILL) catch {};
        };
        if (c.reader) |*f| f.await(c.io);
        c.child.kill(c.io);
        c.pending.deinit(c.gpa);
        c.gpa.destroy(c);
    }
};
