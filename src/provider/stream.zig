//! The request and event stream every wire module shares (PLAN.md §6.2,
//! D53).
//!
//! `SseStream(Wire)` sends the request, maps error responses, reads SSE
//! events, parses their data as JSON and queues the events `Wire.onEvent`
//! produces. A wire module supplies:
//! - `name`: the label in diagnostics ("anthropic", "openai")
//! - `path`: appended to the base URL, e.g. "/v1/messages"
//! - `writeBody(*Writer, Request)`
//! - `auth(arena, api_key) ![]const std.http.Header`
//! - `State`: per-stream parse state, default-initialized
//! - `onEvent(*State, sse.Event, data: std.json.Value, *Out) Error!void`
//! - optionally `end_marker` (data that ends the stream instead of JSON) and
//!   `onEnd(*State, *Out, End) Error!void` for it and for the end of the
//!   body. Without `onEnd`, a body that ends before a finish event is
//!   `error.StreamInterrupted`.

const std = @import("std");
const p = @import("provider.zig");
const sse = @import("sse.zig");
const http = @import("http.zig");
const Allocator = std.mem.Allocator;
const Writer = std.Io.Writer;

/// What `Wire.onEvent` writes into.
pub const Out = struct {
    /// Outlives the stream: the request body and the assistant message.
    arena: Allocator,
    /// Freed once the events of the current SSE event have been returned.
    scratch: Allocator,
    builder: *p.Builder,
    diag: ?*p.Diagnostic,
    queue: *std.ArrayList(p.Event),
    done: *bool,

    /// Queue an event. A wire module may push any number per SSE event.
    pub fn push(o: *Out, e: p.Event) Allocator.Error!void {
        try o.queue.append(o.scratch, e);
    }

    /// Queue the final event; the stream returns null after it.
    pub fn finish(o: *Out, f: p.Finish) Allocator.Error!void {
        o.done.* = true;
        try o.push(.{ .finish = f });
    }
};

/// Why `Wire.onEnd` was called.
pub const End = enum {
    /// The event data was `Wire.end_marker`.
    marker,
    /// The response body ended.
    eof,
};

pub fn SseStream(comptime Wire: type) type {
    return struct {
        const Self = @This();

        arena: Allocator,
        scratch: std.heap.ArenaAllocator,
        res: *http.Response,
        events: sse.Stream,
        builder: p.Builder,
        diag: ?*p.Diagnostic,
        state: Wire.State = .{},
        /// Events from the current SSE event, allocated in `scratch`.
        queue: std.ArrayList(p.Event) = .empty,
        pos: usize = 0,
        done: bool = false,

        /// Send the request. `arena` holds the request body and the
        /// accumulated assistant message; it must outlive the stream.
        pub fn open(arena: Allocator, h: *http.Http, req: p.Request) p.Error!Self {
            var aw: Writer.Allocating = .init(arena);
            Wire.writeBody(&aw.writer, req) catch return error.OutOfMemory;
            const url = arena.print("{s}" ++ Wire.path, .{req.base_url}) catch return error.OutOfMemory;

            var headers: std.ArrayList(std.http.Header) = .empty;
            headers.append(arena, .{ .name = "accept", .value = "text/event-stream" }) catch return error.OutOfMemory;
            headers.appendSlice(arena, Wire.auth(arena, req.api_key) catch return error.OutOfMemory) catch return error.OutOfMemory;
            for (req.headers) |hd| headers.append(arena, .{ .name = hd[0], .value = hd[1] }) catch return error.OutOfMemory;

            const res = h.post(url, headers.items, aw.written()) catch |err| return p.mapHttpError(err);
            if (!res.ok()) {
                defer res.close();
                const body = res.readAll(arena, 8192) catch "";
                return p.statusError(res.status, errorMessage(arena, Wire.name, res.status, body), req.diag);
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

        pub fn close(s: *Self) void {
            s.events.deinit();
            s.scratch.deinit();
            s.res.close();
        }

        /// Next delta or the final event. Delta slices are valid until the
        /// next call.
        pub fn next(s: *Self) p.Error!?p.Event {
            while (true) {
                if (s.pos < s.queue.items.len) {
                    defer s.pos += 1;
                    return s.queue.items[s.pos];
                }
                if (s.done) return null;
                _ = s.scratch.reset(.retain_capacity);
                s.queue = .empty;
                s.pos = 0;
                var out: Out = .{
                    .arena = s.arena,
                    .scratch = s.scratch.allocator(),
                    .builder = &s.builder,
                    .diag = s.diag,
                    .queue = &s.queue,
                    .done = &s.done,
                };
                const ev = s.events.next() catch |err| switch (err) {
                    error.OutOfMemory => return error.OutOfMemory,
                    else => return p.bodyReadError(s.res, s.diag),
                } orelse {
                    try s.end(&out, .eof);
                    continue;
                };
                if (@hasDecl(Wire, "end_marker") and std.mem.eql(u8, std.mem.trim(u8, ev.data, " "), Wire.end_marker)) {
                    try s.end(&out, .marker);
                    continue;
                }
                const data = try p.parseData(out.scratch, ev.data);
                try Wire.onEvent(&s.state, ev, data, &out);
            }
        }

        fn end(s: *Self, out: *Out, why: End) p.Error!void {
            if (@hasDecl(Wire, "onEnd")) try Wire.onEnd(&s.state, out, why);
            if (!s.done) return error.StreamInterrupted;
        }
    };
}

/// "<name> <status> <type or code>: <message>" from an error body.
fn errorMessage(arena: Allocator, comptime name: []const u8, status: u16, body: []const u8) []const u8 {
    const v = std.json.parseFromSliceLeaky(std.json.Value, arena, body, .{}) catch
        return arena.print(name ++ " {d}: {s}", .{ status, body }) catch body;
    const e = (if (v == .object) v.object.get("error") else null) orelse v;
    return arena.print(name ++ " {d} {s}: {s}", .{
        status, p.getStr(e, "type") orelse p.getStr(e, "code") orelse "error", p.getStr(e, "message") orelse body,
    }) catch body;
}
