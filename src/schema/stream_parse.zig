//! Partial structured output while it streams (PLAN.md §5.15, §18.4, D44).
//!
//! Not a full incremental JSON parser. A byte scanner keeps depth, string and
//! escape state and records *boundaries*: points where a value just ended at
//! depth 1 or 2, so everything before them is complete except the containers
//! still open. At a boundary the buffered prefix is cut there, the open
//! containers are closed, and the result is parsed leniently into
//! `z.Partial(T)`: fields that are missing or don't parse stay null.
//!
//! Strings listed in `T.stream_strings` also produce partial values as they
//! grow (every 64 bytes at most), cut at a character boundary.

const std = @import("std");
const Partial = @import("partial.zig").Partial;
const parse = @import("parse.zig");
const errors = @import("../meta/errors.zig");
const reflect = @import("../meta/reflect.zig");
const Allocator = std.mem.Allocator;
const Value = std.json.Value;

const max_depth = 64;
const string_step = 64;

/// The fields of `T` that stream as they grow, from `pub const stream_strings`.
pub fn streamStrings(comptime T: type) []const []const u8 {
    comptime {
        if (!@hasDecl(T, "stream_strings")) return &.{};
        const S = T.stream_strings;
        const name = reflect.shortTypeName(T);
        if (!reflect.isTuple(@TypeOf(S)))
            errors.fail("{s}.stream_strings must be a tuple of field names, like `.{{ .summary }}`", .{name});
        var out: []const []const u8 = &.{};
        for (S) |f| {
            if (@typeInfo(@TypeOf(f)) != .enum_literal)
                errors.fail("{s}.stream_strings: entries are field names like `.summary`", .{name});
            const fname = @tagName(f);
            if (!@hasField(T, fname))
                errors.fail("{s}.stream_strings names `.{s}`, which isn't a field of {s}{s}", .{ name, fname, name, errors.didYouMean(fname, reflect.fieldNames(T)) });
            const F = @FieldType(T, fname);
            const Inner = switch (@typeInfo(F)) {
                .optional => |o| o.child,
                else => F,
            };
            if (Inner != []const u8)
                errors.fail("{s}.stream_strings names `.{s}`, which is {s}; only string fields can stream as they grow", .{ name, fname, @typeName(F) });
            out = out ++ &[_][]const u8{fname};
        }
        return out;
    }
}

pub fn Parser(comptime T: type) type {
    const streamed = streamStrings(T);
    return struct {
        const Self = @This();

        gpa: Allocator,
        buf: std.ArrayList(u8) = .empty,
        /// Holds the latest partial value; reset before each new one.
        scratch: std.heap.ArenaAllocator,

        started: bool = false,
        dead: bool = false,
        complete: bool = false,
        stack: [max_depth]u8 = undefined,
        depth: usize = 0,
        expect_key: bool = false,
        in_string: bool = false,
        string_is_key: bool = false,
        escape: bool = false,
        /// Hex digits still expected after `\u`.
        hex_left: u8 = 0,
        /// UTF-8 continuation bytes still expected.
        utf8_left: u8 = 0,
        in_scalar: bool = false,
        /// The last key seen at depth 1, as a range of `buf`.
        key_start: usize = 0,
        key_end: usize = 0,
        string_start: usize = 0,

        /// The latest safe cut, and the open-container depth at that point.
        boundary: usize = 0,
        boundary_depth: usize = 0,
        emitted: usize = 0,
        /// Inside a `stream_strings` value: the end of its last complete
        /// character, and where the last partial cut it.
        streaming: bool = false,
        string_safe: usize = 0,
        string_emitted: usize = 0,

        pub fn init(gpa: Allocator) Self {
            return .{ .gpa = gpa, .scratch = .init(gpa) };
        }

        pub fn deinit(p: *Self) void {
            p.buf.deinit(p.gpa);
            p.scratch.deinit();
        }

        /// Start over (a new model turn, or a repair attempt).
        pub fn reset(p: *Self) void {
            p.buf.clearRetainingCapacity();
            const gpa = p.gpa;
            const buf = p.buf;
            const scratch = p.scratch;
            p.* = .{ .gpa = gpa, .buf = buf, .scratch = scratch };
        }

        /// Whether any partial value was produced since the last reset.
        pub fn produced(p: *const Self) bool {
            return p.emitted > 0 or p.string_emitted > 0;
        }

        /// Feed a delta. Returns at most one partial value per call, valid
        /// until the next call.
        pub fn feed(p: *Self, chunk: []const u8) Allocator.Error!?Partial(T) {
            if (p.dead or p.complete) return null;
            const from = p.buf.items.len;
            try p.buf.appendSlice(p.gpa, chunk);
            for (p.buf.items[from..], from..) |c, i| {
                p.scan(c, i);
                if (p.dead) return null;
                if (p.complete) break;
            }
            if (p.streaming and p.in_string and p.string_safe >= p.string_emitted + string_step) {
                p.string_emitted = p.string_safe;
                return p.emit(p.string_safe, p.depth, true);
            }
            if (p.boundary > p.emitted) {
                p.emitted = p.boundary;
                return p.emit(p.boundary, p.boundary_depth, false);
            }
            return null;
        }

        fn scan(p: *Self, c: u8, i: usize) void {
            if (!p.started) {
                if (std.ascii.isWhitespace(c)) return;
                if (c != '{') {
                    p.dead = true;
                    return;
                }
                p.started = true;
                p.push('{');
                return;
            }
            if (p.in_string) return p.scanString(c, i);
            if (p.in_scalar) switch (c) {
                ',', '}', ']', ' ', '\t', '\n', '\r' => {
                    p.in_scalar = false;
                    p.valueEnded(i);
                },
                else => return,
            };
            switch (c) {
                '"' => {
                    p.in_string = true;
                    p.string_is_key = p.top() == '{' and p.expect_key;
                    p.string_start = i + 1;
                    p.string_safe = i + 1;
                    p.streaming = !p.string_is_key and p.depth == 1 and p.keyStreams();
                    p.string_emitted = if (p.streaming) i + 1 else 0;
                },
                '{', '[' => p.push(c),
                '}', ']' => {
                    if (p.depth == 0) {
                        p.dead = true;
                        return;
                    }
                    p.depth -= 1;
                    if (p.depth == 0) {
                        p.complete = true;
                        p.boundary = i + 1;
                        p.boundary_depth = 0;
                    } else p.valueEnded(i + 1);
                },
                ':' => p.expect_key = false,
                ',' => p.expect_key = p.top() == '{',
                ' ', '\t', '\n', '\r' => {},
                else => p.in_scalar = true,
            }
        }

        fn scanString(p: *Self, c: u8, i: usize) void {
            if (p.hex_left > 0) {
                p.hex_left -= 1;
                if (p.hex_left == 0) p.string_safe = i + 1;
                return;
            }
            if (p.escape) {
                p.escape = false;
                if (c == 'u') p.hex_left = 4 else p.string_safe = i + 1;
                return;
            }
            if (p.utf8_left > 0) {
                p.utf8_left -= 1;
                if (p.utf8_left == 0) p.string_safe = i + 1;
                return;
            }
            switch (c) {
                '\\' => p.escape = true,
                '"' => {
                    p.in_string = false;
                    p.streaming = false;
                    if (p.string_is_key) {
                        if (p.depth == 1) {
                            p.key_start = p.string_start;
                            p.key_end = i;
                        }
                    } else p.valueEnded(i + 1);
                },
                else => {
                    p.utf8_left = if (c < 0x80) 0 else if (c >> 5 == 0b110) 1 else if (c >> 4 == 0b1110) 2 else if (c >> 3 == 0b11110) 3 else 0;
                    if (p.utf8_left == 0) p.string_safe = i + 1;
                },
            }
        }

        fn push(p: *Self, c: u8) void {
            if (p.depth == max_depth) {
                p.dead = true;
                return;
            }
            p.stack[p.depth] = c;
            p.depth += 1;
            p.expect_key = c == '{';
        }

        fn top(p: *const Self) u8 {
            return if (p.depth == 0) 0 else p.stack[p.depth - 1];
        }

        /// A value ended just before `at`, inside the innermost open container.
        fn valueEnded(p: *Self, at: usize) void {
            if (p.depth <= 2) {
                p.boundary = at;
                p.boundary_depth = p.depth;
            }
        }

        fn keyStreams(p: *const Self) bool {
            const key = p.buf.items[p.key_start..p.key_end];
            inline for (streamed) |f| if (std.mem.eql(u8, key, f)) return true;
            return false;
        }

        fn emit(p: *Self, cut: usize, depth: usize, close_string: bool) Allocator.Error!?Partial(T) {
            _ = p.scratch.reset(.retain_capacity);
            const a = p.scratch.allocator();
            var text: std.ArrayList(u8) = .empty;
            try text.ensureTotalCapacity(a, cut + depth + 1);
            text.appendSliceAssumeCapacity(p.buf.items[0..cut]);
            if (close_string) text.appendAssumeCapacity('"');
            var d = depth;
            while (d > 0) {
                d -= 1;
                text.appendAssumeCapacity(if (p.stack[d] == '{') '}' else ']');
            }
            const v = std.json.parseFromSliceLeaky(Value, a, text.items, .{}) catch |err| switch (err) {
                error.OutOfMemory => return error.OutOfMemory,
                else => return null,
            };
            return try lenient(T, a, v);
        }
    };
}

/// Convert a parsed prefix into `Partial(T)`, leaving fields that are
/// missing or don't validate as null.
pub fn lenient(comptime T: type, arena: Allocator, v: Value) Allocator.Error!Partial(T) {
    var out: Partial(T) = .{};
    if (v != .object) return out;
    inline for (std.meta.fields(T)) |f| if (v.object.get(f.name)) |fv| {
        const Inner = switch (@typeInfo(f.type)) {
            .optional => |o| o.child,
            else => f.type,
        };
        if (@typeInfo(Inner) == .@"struct") {
            @field(out, f.name) = try lenient(Inner, arena, fv);
        } else {
            var issue: parse.Issue = .{};
            @field(out, f.name) = parse.fromValue(Inner, arena, fv, &issue) catch |err| switch (err) {
                error.OutOfMemory => return error.OutOfMemory,
                error.ValidationFailed => null,
            };
        }
    };
    return out;
}

// ── tests ────────────────────────────────────────────────────────────────────

const Item = struct { sku: []const u8, qty: u32 };
const Out = struct {
    category: enum { refund, other },
    summary: []const u8,
    items: []const Item = &.{},
    meta: struct { lang: []const u8 = "", score: u8 = 0 } = .{},
    pub const stream_strings = .{.summary};
};

fn collect(gpa: Allocator, text: []const u8, chunk: usize) !std.ArrayList([]u8) {
    var p: Parser(Out) = .init(gpa);
    defer p.deinit();
    var out: std.ArrayList([]u8) = .empty;
    var i: usize = 0;
    while (i < text.len) : (i += chunk) {
        if (try p.feed(text[i..@min(text.len, i + chunk)])) |v| {
            var aw: std.Io.Writer.Allocating = .init(gpa);
            try std.json.Stringify.value(v, .{}, &aw.writer);
            try out.append(gpa, try aw.toOwnedSlice());
        }
    }
    return out;
}

test "partial values appear as fields complete" {
    const gpa = std.testing.allocator;
    const text =
        \\{"category":"refund","items":[{"sku":"A","qty":1},{"sku":"B","qty":2}],"meta":{"lang":"en","score":3},"summary":"ok"}
    ;
    var got = try collect(gpa, text, 1);
    defer {
        for (got.items) |g| gpa.free(g);
        got.deinit(gpa);
    }
    const want = [_][]const u8{
        \\{"category":"refund","summary":null,"items":null,"meta":null}
        ,
        \\{"category":"refund","summary":null,"items":[{"sku":"A","qty":1}],"meta":null}
        ,
        \\{"category":"refund","summary":null,"items":[{"sku":"A","qty":1},{"sku":"B","qty":2}],"meta":null}
        ,
        \\{"category":"refund","summary":null,"items":[{"sku":"A","qty":1},{"sku":"B","qty":2}],"meta":{"lang":"en","score":null}}
        ,
        \\{"category":"refund","summary":null,"items":[{"sku":"A","qty":1},{"sku":"B","qty":2}],"meta":{"lang":"en","score":3}}
        ,
        \\{"category":"refund","summary":"ok","items":[{"sku":"A","qty":1},{"sku":"B","qty":2}],"meta":{"lang":"en","score":3}}
        ,
    };
    // Byte-at-a-time feeding produces the closing `}` of `items`/`meta`
    // boundaries too; keep only distinct consecutive values.
    var distinct: std.ArrayList([]const u8) = .empty;
    defer distinct.deinit(gpa);
    for (got.items) |g| if (distinct.items.len == 0 or !std.mem.eql(u8, distinct.items[distinct.items.len - 1], g)) try distinct.append(gpa, g);
    try std.testing.expectEqual(want.len, distinct.items.len);
    for (want, distinct.items) |w, g| try std.testing.expectEqualStrings(w, g);
}

test "stream_strings fields grow; other strings appear whole" {
    const gpa = std.testing.allocator;
    var long: [200]u8 = undefined;
    @memset(&long, 'x');
    const text = try std.fmt.allocPrint(gpa, "{{\"summary\":\"{s}\",\"category\":\"other\"}}", .{&long});
    defer gpa.free(text);
    var got = try collect(gpa, text, 10);
    defer {
        for (got.items) |g| gpa.free(g);
        got.deinit(gpa);
    }
    // The summary grows in steps of at least 64 bytes (cut at chunk ends);
    // `category` appears only once complete.
    try std.testing.expect(got.items.len >= 3);
    var last_len: usize = 0;
    for (got.items[0 .. got.items.len - 1]) |g| {
        try std.testing.expect(std.mem.indexOf(u8, g, "\"category\":null") != null);
        const n = std.mem.count(u8, g, "x");
        // Growth steps are at least 64 bytes; the last one may be the
        // string completing.
        try std.testing.expect(n > last_len and n <= 200 and (n == 200 or n >= last_len + 64));
        last_len = n;
    }
    try std.testing.expect(std.mem.indexOf(u8, got.items[got.items.len - 1], "\"category\":\"other\"") != null);
}

test "escapes and multibyte characters are never split" {
    const gpa = std.testing.allocator;
    const body = "é" ** 40 ++ "\\u00e9\\n" ** 10;
    const text = "{\"summary\":\"" ++ body ++ "\",\"category\":\"other\"}";
    for (1..8) |chunk| {
        var got = try collect(gpa, text, chunk);
        defer {
            for (got.items) |g| gpa.free(g);
            got.deinit(gpa);
        }
        try std.testing.expect(got.items.len >= 2);
    }
}

test "every prefix of an output closes into a parseable value" {
    const gpa = std.testing.allocator;
    const text =
        \\{ "category" : "other", "summary": "a \"quoted\" \\ word", "items": [ {"sku": "A", "qty": 10}, {"sku":"B","qty":2} ], "meta": {"lang":"en"} }
    ;
    for (1..text.len + 1) |n| {
        var p: Parser(Out) = .init(gpa);
        defer p.deinit();
        _ = try p.feed(text[0..n]);
        try std.testing.expect(!p.dead);
    }
}

test "text that isn't a JSON object produces nothing" {
    var p: Parser(Out) = .init(std.testing.allocator);
    defer p.deinit();
    try std.testing.expect(try p.feed("Sure! Here's the answer: {\"category\":\"other\"}") == null);
    try std.testing.expect(p.dead);
}
