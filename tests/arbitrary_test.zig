//! z.testing.arbitrary (PLAN.md §19.3, D51): per-mapping and per-constraint
//! checks, and the round-trip property over many schema types.

const std = @import("std");
const z = @import("zastra");

fn gen(arena: std.mem.Allocator, prng: *std.Random.DefaultPrng) z.testing.Gen {
    return .init(arena, prng.random(), .{});
}

test "integers stay within min/max and hit the bounds" {
    const T = struct {
        n: i32,
        pub const constraints = .{ .n = .{ .min = -5, .max = 7 } };
    };
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    var prng: std.Random.DefaultPrng = .init(1);
    var seen_lo = false;
    var seen_hi = false;
    for (0..500) |_| {
        const v = try z.testing.arbitrary(T, arena.allocator(), prng.random());
        try std.testing.expect(v.n >= -5 and v.n <= 7);
        seen_lo = seen_lo or v.n == -5;
        seen_hi = seen_hi or v.n == 7;
    }
    try std.testing.expect(seen_lo and seen_hi);
}

test "integer types without constraints cover their range edges" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    var prng: std.Random.DefaultPrng = .init(2);
    var seen_min = false;
    var seen_max = false;
    for (0..500) |_| {
        const v = try z.testing.arbitrary(i64, arena.allocator(), prng.random());
        seen_min = seen_min or v == std.math.minInt(i64);
        seen_max = seen_max or v == std.math.maxInt(i64);
    }
    try std.testing.expect(seen_min and seen_max);
}

test "floats stay within min/max, including narrow types" {
    const T = struct {
        a: f64,
        b: f32,
        c: f32,
        pub const constraints = .{ .a = .{ .min = -1.5, .max = 2 }, .b = .{ .min = 0, .max = 0.1 }, .c = .{ .min = 0.3, .max = 0.30000001 } };
    };
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    var prng: std.Random.DefaultPrng = .init(3);
    for (0..500) |_| {
        const v = try z.testing.arbitrary(T, arena.allocator(), prng.random());
        try std.testing.expect(std.math.isFinite(v.a) and v.a >= -1.5 and v.a <= 2);
    }
    try z.testing.expectRoundTrip(T, .{ .seed = 3 });
}

test "strings respect min_len/max_len in characters, and one_of" {
    const T = struct {
        s: []const u8,
        t: []const u8,
        u: ?[]const u8 = null,
        pub const constraints = .{
            .s = .{ .min_len = 2, .max_len = 5 },
            .t = .{ .one_of = .{ "low", "high" } },
            .u = .{ .max_len = 0 },
        };
    };
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    var prng: std.Random.DefaultPrng = .init(4);
    var lens: [6]bool = @splat(false);
    var special = false;
    for (0..500) |_| {
        const v = try z.testing.arbitrary(T, arena.allocator(), prng.random());
        const n = try std.unicode.utf8CountCodepoints(v.s);
        try std.testing.expect(n >= 2 and n <= 5);
        lens[n] = true;
        special = special or std.mem.indexOfAny(u8, v.s, "\"\\\x00") != null or n != v.s.len;
        try std.testing.expect(std.mem.eql(u8, v.t, "low") or std.mem.eql(u8, v.t, "high"));
        if (v.u) |u| try std.testing.expectEqualStrings("", u);
    }
    try std.testing.expect(lens[2] and lens[5] and special);
}

test "slices respect min_items/max_items; defaults bound the rest" {
    const T = struct {
        a: []const u8,
        b: []const u16,
        c: []const bool,
        pub const constraints = .{ .b = .{ .min_items = 1, .max_items = 3 } };
    };
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    var prng: std.Random.DefaultPrng = .init(5);
    var g: z.testing.Gen = .init(arena.allocator(), prng.random(), .{ .max_len = 4, .max_items = 2 });
    var empty = false;
    for (0..500) |_| {
        const v = try g.value(T);
        try std.testing.expect(try std.unicode.utf8CountCodepoints(v.a) <= 4);
        try std.testing.expect(v.b.len >= 1 and v.b.len <= 3);
        try std.testing.expect(v.c.len <= 2);
        empty = empty or v.c.len == 0;
    }
    try std.testing.expect(empty);
}

test "every enum tag and union variant shows up; optionals are sometimes null" {
    const E = enum { a, b, c, d };
    const U = union(enum) { none, n: u8, p: struct { q: bool }, e: E };
    const T = struct { e: E, u: U, o: ?u8, d: u8 = 42 };
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    var prng: std.Random.DefaultPrng = .init(6);
    var tags: [4]bool = @splat(false);
    var variants: [4]bool = @splat(false);
    var nulls: usize = 0;
    var defaults: usize = 0;
    for (0..500) |_| {
        const v = try z.testing.arbitrary(T, arena.allocator(), prng.random());
        tags[@backingInt(v.e)] = true;
        variants[@backingInt(std.meta.activeTag(v.u))] = true;
        if (v.o == null) nulls += 1;
        if (v.d == 42) defaults += 1;
    }
    try std.testing.expect(std.mem.allEqual(bool, &tags, true));
    try std.testing.expect(std.mem.allEqual(bool, &variants, true));
    try std.testing.expect(nulls > 50 and nulls < 250);
    try std.testing.expect(defaults > 50);
}

test "an optional field with a non-null default is never null" {
    const T = struct { o: ?u8 = 3 };
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    var prng: std.Random.DefaultPrng = .init(7);
    for (0..200) |_| try std.testing.expect((try z.testing.arbitrary(T, arena.allocator(), prng.random())).o != null);
}

test "z.Json gets small JSON that parses" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    var prng: std.Random.DefaultPrng = .init(8);
    var kinds: [6]bool = @splat(false);
    for (0..300) |_| {
        const j = try z.testing.arbitrary(z.Json, arena.allocator(), prng.random());
        const v = try std.json.parseFromSliceLeaky(std.json.Value, arena.allocator(), j.raw, .{});
        kinds[
            switch (v) {
                .null => 0,
                .bool => 1,
                .integer => 2,
                .string => 3,
                .array => 4,
                .object => 5,
                else => unreachable,
            }
        ] = true;
    }
    try std.testing.expect(std.mem.allEqual(bool, &kinds, true));
}

const Point = struct {
    x: i32,
    y: i32,
    /// Only points on the diagonal: a rule the schema can't express.
    pub fn arbitrary(g: *z.testing.Gen) !Point {
        const x = g.int(i32, -100, 100);
        return .{ .x = x, .y = x };
    }
};

test "a type's own arbitrary is used, also when nested" {
    const T = struct { p: Point, ps: []const Point };
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    var prng: std.Random.DefaultPrng = .init(9);
    for (0..200) |_| {
        const v = try z.testing.arbitrary(T, arena.allocator(), prng.random());
        try std.testing.expectEqual(v.p.x, v.p.y);
        for (v.ps) |p| try std.testing.expectEqual(p.x, p.y);
    }
}

test "the same seed gives the same values" {
    const T = struct { a: []const u8, b: []const i16, c: ?f64 };
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    var p1: std.Random.DefaultPrng = .init(10);
    var p2: std.Random.DefaultPrng = .init(10);
    for (0..50) |_| try std.testing.expectEqualDeep(
        try z.testing.arbitrary(T, arena.allocator(), p1.random()),
        try z.testing.arbitrary(T, arena.allocator(), p2.random()),
    );
}

test "a Smith source generates valid values" {
    const T = struct {
        s: []const u8,
        n: u8,
        u: union(enum) { a, b: []const u8 },
        pub const constraints = .{ .s = .{ .min_len = 1, .max_len = 3 }, .n = .{ .min = 10, .max = 20 } };
    };
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    var bytes: [4096]u8 = undefined;
    var prng: std.Random.DefaultPrng = .init(11);
    for (0..100) |_| {
        prng.random().bytes(&bytes);
        var smith: std.testing.Smith = .{ .in = &bytes };
        const v = try z.testing.arbitrary(T, arena.allocator(), &smith);
        try std.testing.expect(v.n >= 10 and v.n <= 20);
        try z.testing.roundTrip(T, arena.allocator(), v);
    }
    // An exhausted input still produces a valid value.
    var smith: std.testing.Smith = .{ .in = &.{} };
    const v = try z.testing.arbitrary(T, arena.allocator(), &smith);
    try std.testing.expect(v.n == 10 and v.s.len >= 1);
}

// --- The round-trip property ---------------------------------------------

const Status = enum { open, pending, closed };
const Address = struct {
    street: []const u8,
    city: []const u8,
    zip: ?[]const u8 = null,
    pub const constraints = .{ .zip = .{ .min_len = 5, .max_len = 10, .pattern = "^[0-9-]+$" } };
};
const Item = struct {
    sku: []const u8,
    qty: u16 = 1,
    price: f64,
    pub const constraints = .{ .qty = .{ .min = 1, .max = 99 }, .price = .{ .min = 0 } };
};
const Payment = union(enum) {
    card: struct { last4: []const u8, brand: enum { visa, amex } },
    cash,
    credit: i64,
};

const round_trip_types = .{
    bool,
    u8,
    i8,
    u64,
    i64,
    u1,
    i3,
    f64,
    f32,
    []const u8,
    ?[]const u8,
    Status,
    []const Status,
    [3]u8,
    [2][]const u8,
    []const ?i32,
    []const []const u8,
    z.Json,
    []const z.Json,
    Address,
    Item,
    []const Item,
    Payment,
    []const Payment,
    Point,
    struct { a: u8 },
    struct {},
    struct { a: ?u8 = null, b: bool = true, c: []const u8 = "x", d: Status = .closed },
    struct { o: ?Address, items: []const Item, pay: Payment, s: Status },
    union(enum) { a: u8, b: []const u8, c: ?bool, d: [2]u8, e: void, f: struct { x: ?i8 } },
    union(enum) { only },
    struct { n: ?f32, nested: struct { deep: struct { leaf: ?[]const u8 } } },
    struct {
        name: []const u8,
        tags: []const []const u8,
        level: i16,
        ratio: f32,
        pub const constraints = .{
            .name = .{ .min_len = 1, .max_len = 3 },
            .tags = .{ .max_items = 2 },
            .level = .{ .min = -3, .max = 3 },
            .ratio = .{ .min = 0, .max = 1 },
        };
    },
    struct {
        kind: []const u8,
        pub const constraints = .{ .kind = .{ .one_of = .{ "a", "b\"c", "\u{1f600}" } } };
    },
    struct { j: z.Json, oj: ?z.Json },
};

test "round trip: parse(stringify(v)) == v and the JSON matches the schema" {
    inline for (round_trip_types, 0..) |T, i| {
        try z.testing.expectRoundTrip(T, .{ .seed = i, .count = 500 });
    }
}

test "round trip under the fuzzer" {
    // `zig build fuzz --fuzz` drives this with coverage feedback; a normal
    // run tries the empty input once.
    try std.testing.fuzz({}, struct {
        fn one(_: void, smith: *std.testing.Smith) anyerror!void {
            var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
            defer arena.deinit();
            inline for (round_trip_types) |T| {
                const v = try z.testing.arbitrary(T, arena.allocator(), smith);
                try z.testing.roundTrip(T, arena.allocator(), v);
            }
        }
    }.one, .{});
}

test "round trip from Smith byte inputs" {
    // What the fuzzer feeds a Smith, without coverage feedback, so normal
    // runs exercise the Smith path beyond the empty input.
    var prng: std.Random.DefaultPrng = .init(12);
    var bytes: [2048]u8 = undefined;
    for (0..200) |_| {
        prng.random().bytes(&bytes);
        var smith: std.testing.Smith = .{ .in = &bytes };
        var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
        defer arena.deinit();
        inline for (round_trip_types) |T| {
            const v = try z.testing.arbitrary(T, arena.allocator(), &smith);
            try z.testing.roundTrip(T, arena.allocator(), v);
        }
    }
}
