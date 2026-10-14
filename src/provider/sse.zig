//! Server-Sent Events parser (PLAN.md §6.2).
//!
//! Incremental: `feed` accepts arbitrary chunks (split anywhere, including
//! inside a CRLF pair) and `next` yields complete events. Handles `event:`,
//! multi-line `data:`, `id:`, `retry:` and comment lines, per the WHATWG
//! EventSource parsing rules.

const std = @import("std");
const Allocator = std.mem.Allocator;

pub const Event = struct {
    /// "message" when the stream didn't name the event.
    event: []const u8,
    data: []const u8,
    id: ?[]const u8,
    retry_ms: ?u64,
};

pub const Parser = struct {
    gpa: Allocator,
    /// Bytes fed but not yet consumed as complete lines.
    buf: std.ArrayList(u8) = .empty,
    pos: usize = 0,
    /// The previous chunk ended in '\r'; a leading '\n' belongs to it.
    skip_lf: bool = false,
    // Fields of the event being assembled.
    event: std.ArrayList(u8) = .empty,
    data: std.ArrayList(u8) = .empty,
    has_data: bool = false,
    last_id: std.ArrayList(u8) = .empty,
    has_id: bool = false,
    retry_ms: ?u64 = null,
    // Storage for the event most recently returned by `next`.
    out_event: std.ArrayList(u8) = .empty,
    out_data: std.ArrayList(u8) = .empty,

    pub fn init(gpa: Allocator) Parser {
        return .{ .gpa = gpa };
    }

    pub fn deinit(p: *Parser) void {
        p.buf.deinit(p.gpa);
        p.event.deinit(p.gpa);
        p.data.deinit(p.gpa);
        p.last_id.deinit(p.gpa);
        p.out_event.deinit(p.gpa);
        p.out_data.deinit(p.gpa);
    }

    pub fn feed(p: *Parser, bytes: []const u8) Allocator.Error!void {
        // Compact consumed bytes before growing.
        if (p.pos > 0 and p.pos == p.buf.items.len) {
            p.buf.clearRetainingCapacity();
            p.pos = 0;
        } else if (p.pos > 4096) {
            const rest = p.buf.items[p.pos..];
            std.mem.copyForwards(u8, p.buf.items[0..rest.len], rest);
            p.buf.shrinkRetainingCapacity(rest.len);
            p.pos = 0;
        }
        try p.buf.appendSlice(p.gpa, bytes);
    }

    /// The next complete event, or null if more input is needed. The returned
    /// slices are valid until the next call to `next` or `feed`.
    pub fn next(p: *Parser) Allocator.Error!?Event {
        while (true) {
            if (p.skip_lf and p.pos < p.buf.items.len) {
                if (p.buf.items[p.pos] == '\n') p.pos += 1;
                p.skip_lf = false;
            }
            const rest = p.buf.items[p.pos..];
            const eol = std.mem.indexOfAny(u8, rest, "\r\n") orelse return null;
            const line = rest[0..eol];
            p.pos += eol + 1;
            if (rest[eol] == '\r') {
                if (eol + 1 < rest.len) {
                    if (rest[eol + 1] == '\n') p.pos += 1;
                } else p.skip_lf = true;
            }
            if (try p.processLine(line)) |ev| return ev;
        }
    }

    /// Flush a final event that wasn't followed by a blank line (end of stream).
    pub fn finish(p: *Parser) Allocator.Error!?Event {
        const rest = p.buf.items[p.pos..];
        if (rest.len > 0) {
            p.pos = p.buf.items.len;
            if (try p.processLine(rest)) |ev| return ev;
        }
        return p.dispatch();
    }

    fn processLine(p: *Parser, line: []const u8) Allocator.Error!?Event {
        if (line.len == 0) return p.dispatch();
        if (line[0] == ':') return null; // comment
        const colon = std.mem.indexOfScalar(u8, line, ':');
        const field = if (colon) |c| line[0..c] else line;
        var value: []const u8 = if (colon) |c| line[c + 1 ..] else "";
        if (value.len > 0 and value[0] == ' ') value = value[1..];

        if (std.mem.eql(u8, field, "event")) {
            p.event.clearRetainingCapacity();
            try p.event.appendSlice(p.gpa, value);
        } else if (std.mem.eql(u8, field, "data")) {
            if (p.has_data) try p.data.append(p.gpa, '\n');
            try p.data.appendSlice(p.gpa, value);
            p.has_data = true;
        } else if (std.mem.eql(u8, field, "id")) {
            if (std.mem.indexOfScalar(u8, value, 0) == null) {
                p.last_id.clearRetainingCapacity();
                try p.last_id.appendSlice(p.gpa, value);
                p.has_id = true;
            }
        } else if (std.mem.eql(u8, field, "retry")) {
            p.retry_ms = std.fmt.parseInt(u64, value, 10) catch p.retry_ms;
        }
        return null;
    }

    fn dispatch(p: *Parser) Allocator.Error!?Event {
        defer {
            p.event.clearRetainingCapacity();
            p.data.clearRetainingCapacity();
            p.has_data = false;
        }
        if (!p.has_data) return null;
        p.out_event.clearRetainingCapacity();
        try p.out_event.appendSlice(p.gpa, if (p.event.items.len == 0) "message" else p.event.items);
        p.out_data.clearRetainingCapacity();
        try p.out_data.appendSlice(p.gpa, p.data.items);
        return .{
            .event = p.out_event.items,
            .data = p.out_data.items,
            .id = if (p.has_id) p.last_id.items else null,
            .retry_ms = p.retry_ms,
        };
    }
};

/// Pull events from a `std.Io.Reader`.
pub const Stream = struct {
    parser: Parser,
    reader: *std.Io.Reader,
    done: bool = false,

    pub fn init(gpa: Allocator, reader: *std.Io.Reader) Stream {
        return .{ .parser = .init(gpa), .reader = reader };
    }

    pub fn deinit(s: *Stream) void {
        s.parser.deinit();
    }

    pub fn next(s: *Stream) !?Event {
        while (true) {
            if (try s.parser.next()) |ev| return ev;
            if (s.done) return null;
            var chunk: [4096]u8 = undefined;
            const n = s.reader.readSliceShort(&chunk) catch return error.ReadFailed;
            if (n == 0) {
                s.done = true;
                return s.parser.finish();
            }
            try s.parser.feed(chunk[0..n]);
        }
    }
};

// ── tests ────────────────────────────────────────────────────────────────────

const sample =
    ": comment\r\n" ++
    "event: message_start\r\n" ++
    "data: {\"a\":1}\r\n" ++
    "\r\n" ++
    "data: line one\n" ++
    "data: line two\n" ++
    "id: 7\n" ++
    "retry: 1500\n" ++
    "\n" ++
    "event: ping\r" ++
    "data:nospace\r" ++
    "\r" ++
    "event: ignored-no-data\n\n" ++
    "data: [DONE]\n\n";

const Expected = struct { event: []const u8, data: []const u8, id: ?[]const u8 = null };
const expected = [_]Expected{
    .{ .event = "message_start", .data = "{\"a\":1}" },
    .{ .event = "message", .data = "line one\nline two", .id = "7" },
    .{ .event = "ping", .data = "nospace", .id = "7" },
    .{ .event = "message", .data = "[DONE]", .id = "7" },
};

fn checkSplit(split: usize, step: usize) !void {
    var p: Parser = .init(std.testing.allocator);
    defer p.deinit();
    var got: usize = 0;
    var i: usize = 0;
    const cuts = [_]usize{ split, sample.len };
    var start: usize = 0;
    for (cuts) |cut| {
        var off = start;
        while (off < cut) {
            const end = @min(cut, off + step);
            try p.feed(sample[off..end]);
            off = end;
            while (try p.next()) |ev| {
                try std.testing.expectEqualStrings(expected[got].event, ev.event);
                try std.testing.expectEqualStrings(expected[got].data, ev.data);
                if (expected[got].id) |id| try std.testing.expectEqualStrings(id, ev.id.?);
                got += 1;
            }
        }
        start = cut;
        i += 1;
    }
    while (try p.finish()) |ev| {
        try std.testing.expectEqualStrings(expected[got].data, ev.data);
        got += 1;
        break;
    }
    try std.testing.expectEqual(expected.len, got);
}

test "every split offset and chunk size" {
    for (0..sample.len + 1) |split| try checkSplit(split, sample.len);
    for (1..8) |step| try checkSplit(0, step);
}

test "event without trailing blank line is flushed at end of stream" {
    var p: Parser = .init(std.testing.allocator);
    defer p.deinit();
    try p.feed("data: tail");
    try std.testing.expect(try p.next() == null);
    const ev = (try p.finish()).?;
    try std.testing.expectEqualStrings("tail", ev.data);
}

test "fuzz: parser never crashes" {
    try std.testing.fuzz({}, struct {
        fn f(_: void, smith: *std.testing.Smith) anyerror!void {
            var p: Parser = .init(std.testing.allocator);
            defer p.deinit();
            var buf: [256]u8 = undefined;
            const n = smith.slice(&buf);
            try p.feed(buf[0..n]);
            while (try p.next()) |_| {}
            _ = try p.finish();
        }
    }.f, .{});
}
