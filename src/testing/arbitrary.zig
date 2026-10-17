//! `z.testing.arbitrary(T, arena, source)`: random values of a schema type
//! that `schema.parse(T, ...)` accepts (PLAN.md §19.3, D51).
//!
//! The source is a seeded `std.Random` (deterministic, for normal tests) or a
//! `*std.testing.Smith` (coverage-guided, under `zig build test --fuzz`).
//! About a quarter of picks are boundaries: `min`, `max`, 0, empty and
//! maximum-length strings and arrays, and characters that need escaping.
//! `pattern` isn't generated (D27); a type can take over its own generation
//! with `pub fn arbitrary(gen: *z.testing.Gen) !T`.

const std = @import("std");
const errors = @import("../meta/errors.zig");
const reflect = @import("../meta/reflect.zig");
const json_mod = @import("../schema/json.zig");
const json_schema = @import("../schema/json_schema.zig");
const parse_mod = @import("../schema/parse.zig");
const validate = @import("../mcp/validate.zig");
const Json = json_mod.Json;
const Allocator = std.mem.Allocator;
const Smith = std.testing.Smith;

pub const Error = error{OutOfMemory};

pub const Options = struct {
    /// Upper bound for strings whose schema has no `max_len` (in characters).
    max_len: u32 = 64,
    /// Upper bound for slices whose schema has no `max_items`.
    max_items: u32 = 8,
};

/// A random `T`. Memory comes from `arena`. `source` is a `std.Random` or a
/// `*std.testing.Smith`.
pub fn arbitrary(comptime T: type, arena: Allocator, source: anytype) Error!T {
    var g: Gen = .init(arena, source, .{});
    return g.value(T);
}

/// The generator. `arbitrary` overrides get one; tests that want other
/// bounds make their own: `var g: z.testing.Gen = .init(arena, prng.random(), .{ .max_items = 2 });`
pub const Gen = struct {
    arena: Allocator,
    options: Options,
    source: Source,

    const Source = union(enum) {
        random: std.Random,
        smith: *Smith,
    };

    pub fn init(arena: Allocator, source: anytype, options: Options) Gen {
        const S = @TypeOf(source);
        const src: Source = if (S == std.Random)
            .{ .random = source }
        else if (S == *Smith)
            .{ .smith = source }
        else
            errors.fail("z.testing.arbitrary: the source must be a `std.Random` or a `*std.testing.Smith`, got {s}", .{@typeName(S)});
        return .{ .arena = arena, .options = options, .source = src };
    }

    // Raw draws. `site` separates the decisions for the fuzzer's coverage
    // feedback; it doesn't change the distribution.

    fn draw(g: *Gen, span: u64, comptime site: []const u8) u64 {
        return switch (g.source) {
            .random => |r| r.intRangeAtMost(u64, 0, span),
            .smith => |s| s.valueRangeAtMostWithHash(u64, 0, span, comptime hash(site)),
        };
    }

    fn hash(comptime site: []const u8) u32 {
        return std.hash.Fnv1a_32.hash(site);
    }

    /// True with probability `num / den`.
    pub fn chance(g: *Gen, num: u32, den: u32) bool {
        return g.draw(den - 1, "chance") < num;
    }

    pub fn boolean(g: *Gen) bool {
        return g.draw(1, "bool") == 1;
    }

    /// An index into a non-empty collection of `len` items.
    pub fn index(g: *Gen, len: usize) usize {
        std.debug.assert(len > 0);
        return @intCast(g.draw(@intCast(len - 1), "index"));
    }

    /// An integer in `[lo, hi]`, edge-biased.
    pub fn int(g: *Gen, comptime T: type, lo: T, hi: T) T {
        std.debug.assert(lo <= hi);
        const l: i128 = lo;
        const h: i128 = hi;
        if (g.chance(1, 4)) {
            const edges = [_]i128{ l, h, 0, 1, -1, l + 1, h - 1 };
            const e = edges[g.draw(edges.len - 1, "int edge")];
            if (e >= l and e <= h) return @intCast(e);
        }
        const span: u64 = @intCast(@min(h - l, std.math.maxInt(u64)));
        return @intCast(l + g.draw(span, "int"));
    }

    /// A finite float in `[lo, hi]`, edge-biased. The value survives being
    /// written as JSON and read back.
    pub fn float(g: *Gen, comptime T: type, lo: f64, hi: f64) T {
        std.debug.assert(lo <= hi);
        var f: f64 = undefined;
        if (g.chance(1, 4)) {
            const edges = [_]f64{ lo, hi, 0, 1, -1, 0.5, 1e-7, 0.1 };
            f = edges[g.draw(edges.len - 1, "float edge")];
            if (f < lo or f > hi) f = lo;
        } else {
            const unit: f64 = @as(f64, @floatFromInt(g.draw(1 << 53, "float"))) / (1 << 53);
            f = lo + (hi - lo) * unit;
            if (!std.math.isFinite(f)) f = lo / 2 + hi / 2 + (hi / 2 - lo / 2) * (unit * 2 - 1);
            f = std.math.clamp(f, lo, hi);
        }
        return narrow(T, f, lo, hi);
    }

    /// A string of `min_len..max_len` characters (UTF-8 code points).
    pub fn string(g: *Gen, min_len: usize, max_len: usize) Error![]const u8 {
        std.debug.assert(min_len <= max_len);
        const n: usize = if (g.chance(1, 4))
            (if (g.boolean()) min_len else max_len)
        else
            min_len + @as(usize, @intCast(g.draw(@intCast(max_len - min_len), "string len")));
        var out: std.ArrayList(u8) = .empty;
        try out.ensureTotalCapacity(g.arena, n);
        var buf: [4]u8 = undefined;
        for (0..n) |_| {
            const cp: u21 = if (g.chance(1, 4))
                special[g.draw(special.len - 1, "special char")]
            else
                @intCast(0x20 + g.draw(0x7e - 0x20, "ascii char"));
            const len = std.unicode.utf8Encode(cp, &buf) catch unreachable;
            try out.appendSlice(g.arena, buf[0..len]);
        }
        return out.items;
    }

    /// Characters that need escaping, are multi-byte, or sit at the edges of
    /// what's valid.
    const special = [_]u21{
        '"',    '\\',   '/',      0,       '\n',   '\t',   '\r',    0x08,   0x0c,   0x1f,
        0x7f,   0xe9,   0x4e2d,   0x1f600, 0x2028, 0x2029, 0xfeff,  0xfffd, 0xd7ff, 0xe000,
        0xfffe, 0xffff, 0x10ffff, 0x80,    0x7ff,  0x800,  0x10000,
    };

    /// A random value of `T`; honors `arbitrary` overrides. For use inside
    /// overrides, to generate the parts.
    pub fn value(g: *Gen, comptime T: type) Error!T {
        return g.at(T, null);
    }

    /// `C` carries the constraints literal for this position (see
    /// `parse.zig`), or is null.
    fn at(g: *Gen, comptime T: type, comptime C: ?type) Error!T {
        if (T == Json) return g.json(0);
        if (comptime hasOverride(T)) {
            checkOverride(T);
            return T.arbitrary(g);
        }
        switch (@typeInfo(T)) {
            .bool => return g.boolean(),
            .int => {
                const lo: T = if (C) |CC| (if (comptime has(CC, "min")) cval(CC, "min") else std.math.minInt(T)) else std.math.minInt(T);
                const hi: T = if (C) |CC| (if (comptime has(CC, "max")) cval(CC, "max") else std.math.maxInt(T)) else std.math.maxInt(T);
                return g.int(T, lo, hi);
            },
            .float => {
                const big: f64 = @min(1e6, @as(f64, std.math.floatMax(T)));
                const lo: f64 = if (C) |CC| (if (comptime has(CC, "min")) cval(CC, "min") else -big) else -big;
                const hi: f64 = if (C) |CC| (if (comptime has(CC, "max")) cval(CC, "max") else big) else big;
                return g.float(T, lo, hi);
            },
            .@"enum" => |info| {
                const i = g.index(info.fields.len);
                inline for (info.fields, 0..) |f, j| if (i == j) return @field(T, f.name);
                unreachable;
            },
            .optional => |info| {
                if (g.chance(1, 4)) return null;
                // JSON `null` inside an optional reads back as null.
                if (info.child == Json) return try g.jsonNonNull();
                return try g.at(info.child, C);
            },
            .pointer => |ptr| {
                if (ptr.size != .slice) @compileError("zastra: z.testing.arbitrary can't generate " ++ @typeName(T));
                if (ptr.child == u8) {
                    if (C) |CC| if (comptime has(CC, "one_of")) {
                        const opts = cval(CC, "one_of");
                        const i = g.index(opts.len);
                        inline for (0..opts.len) |j| if (i == j) return try g.arena.dupe(u8, opts[j]);
                        unreachable;
                    };
                    const min_len: usize = if (C) |CC| (if (comptime has(CC, "min_len")) cval(CC, "min_len") else 0) else 0;
                    const max_len: usize = if (C) |CC| (if (comptime has(CC, "max_len")) cval(CC, "max_len") else @max(min_len, g.options.max_len)) else g.options.max_len;
                    const s = try g.string(min_len, max_len);
                    return if (ptr.is_const) s else @constCast(s);
                }
                const min_items: usize = if (C) |CC| (if (comptime has(CC, "min_items")) cval(CC, "min_items") else 0) else 0;
                const max_items: usize = if (C) |CC| (if (comptime has(CC, "max_items")) cval(CC, "max_items") else @max(min_items, g.options.max_items)) else g.options.max_items;
                const n: usize = if (g.chance(1, 4))
                    (if (g.boolean()) min_items else max_items)
                else
                    min_items + @as(usize, @intCast(g.draw(@intCast(max_items - min_items), "items")));
                const out = try g.arena.alloc(ptr.child, n);
                for (out) |*item| item.* = try g.at(ptr.child, null);
                return out;
            },
            .array => |a| {
                var out: T = undefined;
                for (&out) |*item| item.* = try g.at(a.child, null);
                return out;
            },
            .@"struct" => return g.object(T),
            .@"union" => |u| {
                if (u.tag_type == null) @compileError("zastra: z.testing.arbitrary can't generate untagged union " ++ @typeName(T));
                const i = g.index(u.fields.len);
                inline for (u.fields, 0..) |f, j| if (i == j) {
                    return @unionInit(T, f.name, try g.at(f.type, null));
                };
                unreachable;
            },
            .void => return {},
            else => @compileError("zastra: z.testing.arbitrary can't generate " ++ @typeName(T)),
        }
    }

    fn object(g: *Gen, comptime S: type) Error!S {
        var out: S = undefined;
        inline for (std.meta.fields(S)) |f| {
            const C: ?type = comptime if (reflect.hasDecl(S, "constraints") and @hasField(@TypeOf(S.constraints), f.name))
                ConstraintsOf(S, f.name)
            else
                null;
            const d = f.defaultValue();
            if (d != null and g.chance(1, 4)) {
                @field(out, f.name) = d.?;
            } else if (@typeInfo(f.type) == .optional and d != null and d.? != null) {
                // JSON drops null optionals, and a missing field reads back
                // as the default, so null isn't a value this field can hold.
                @field(out, f.name) = try g.at(@typeInfo(f.type).optional.child, C);
            } else {
                @field(out, f.name) = try g.at(f.type, C);
            }
        }
        return out;
    }

    /// Small untyped JSON, in the canonical form `parse` produces for `z.Json`.
    fn json(g: *Gen, depth: u32) Error!Json {
        const v = try g.jsonValue(depth);
        const raw = std.json.Stringify.valueAlloc(g.arena, v, .{}) catch return error.OutOfMemory;
        return .{ .raw = raw };
    }

    fn jsonNonNull(g: *Gen) Error!Json {
        while (true) {
            const j = try g.json(0);
            if (!std.mem.eql(u8, j.raw, "null")) return j;
        }
    }

    fn jsonValue(g: *Gen, depth: u32) Error!std.json.Value {
        const kinds: u64 = if (depth >= 2) 4 else 6;
        return switch (g.draw(kinds - 1, "json kind")) {
            0 => .null,
            1 => .{ .bool = g.boolean() },
            2 => .{ .integer = g.int(i64, -1_000_000, 1_000_000) },
            3 => .{ .string = try g.string(0, 8) },
            4 => blk: {
                var a: std.json.Array = .init(g.arena);
                for (0..g.draw(3, "json array len")) |_| try a.append(try g.jsonValue(depth + 1));
                break :blk .{ .array = a };
            },
            else => blk: {
                var o: std.json.ObjectMap = .empty;
                const keys = [_][]const u8{ "a", "b", "id", "name", "\"q\"", "\u{e9}" };
                const n = g.draw(3, "json object len");
                for (keys[0..n]) |k| try o.put(g.arena, k, try g.jsonValue(depth + 1));
                break :blk .{ .object = o };
            },
        };
    }
};

/// Cast to `T`, keeping the result inside `[lo, hi]` once written as JSON
/// (shortest round-trip decimal) and read back as f64, which is what
/// `parse` checks.
fn narrow(comptime T: type, f: f64, lo: f64, hi: f64) T {
    var x: T = @floatCast(f);
    if (T == f64) return x;
    for (0..8) |_| {
        var buf: [64]u8 = undefined;
        const s = std.fmt.bufPrint(&buf, "{d}", .{x}) catch unreachable;
        const back = std.fmt.parseFloat(f64, s) catch unreachable;
        if (back < lo) {
            x = std.math.nextAfter(T, x, std.math.inf(T));
        } else if (back > hi) {
            x = std.math.nextAfter(T, x, -std.math.inf(T));
        } else return x;
    }
    return x;
}

fn hasOverride(comptime T: type) bool {
    return switch (@typeInfo(T)) {
        .@"struct", .@"union", .@"enum" => @hasDecl(T, "arbitrary"),
        else => false,
    };
}

fn checkOverride(comptime T: type) void {
    comptime {
        const name = reflect.shortTypeName(T);
        const F = @TypeOf(T.arbitrary);
        const want = "`pub fn arbitrary(gen: *z.testing.Gen) !" ++ name ++ "`";
        const info = @typeInfo(F);
        if (info != .@"fn") errors.fail("{s}.arbitrary must be a function: {s}", .{ name, want });
        const params = info.@"fn".params;
        if (params.len != 1 or params[0].type != *Gen)
            errors.fail("{s}.arbitrary must take one `*z.testing.Gen` parameter: {s}", .{ name, want });
        const R = info.@"fn".return_type orelse errors.fail("{s}.arbitrary must return {s}: {s}", .{ name, name, want });
        const ok = switch (@typeInfo(R)) {
            .error_union => |eu| eu.payload == T,
            else => R == T,
        };
        if (!ok) errors.fail("{s}.arbitrary returns {s}, not {s}: {s}", .{ name, @typeName(R), name, want });
    }
}

/// See `parse.zig`: constraints literals travel as a type with one decl.
fn ConstraintsOf(comptime S: type, comptime field: []const u8) type {
    const lit = @field(S.constraints, field);
    return struct {
        pub const value = lit;
    };
}

fn has(comptime CC: type, comptime key: []const u8) bool {
    return @hasField(@TypeOf(CC.value), key);
}

fn cval(comptime CC: type, comptime key: []const u8) @TypeOf(@field(CC.value, key)) {
    return @field(CC.value, key);
}

pub const RoundTripOptions = struct {
    seed: u64 = 0,
    count: u32 = 500,
    gen: Options = .{},
};

/// For `count` arbitrary values of `T`: the JSON zastra writes parses back to
/// an equal value, and validates against `json_schema.of(T)`. A failure
/// prints the seed, the iteration and the JSON.
pub fn expectRoundTrip(comptime T: type, opts: RoundTripOptions) !void {
    var outer: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer outer.deinit();
    const schema = try parseSchema(T, outer.allocator());
    var prng: std.Random.DefaultPrng = .init(opts.seed);
    for (0..opts.count) |i| {
        var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
        defer arena.deinit();
        var g: Gen = .init(arena.allocator(), prng.random(), opts.gen);
        const v = try g.value(T);
        check(T, arena.allocator(), schema, v) catch |err| {
            const text = json_mod.stringifyAlloc(arena.allocator(), v) catch "";
            std.debug.print("z.testing.expectRoundTrip({s}): seed {d}, iteration {d}: {t}\n  {s}\n", .{ @typeName(T), opts.seed, i, err, text });
            return err;
        };
    }
}

/// One value of the round-trip property, for `std.testing.fuzz` bodies.
pub fn roundTrip(comptime T: type, arena: Allocator, v: T) !void {
    return check(T, arena, try parseSchema(T, arena), v);
}

fn parseSchema(comptime T: type, arena: Allocator) !std.json.Value {
    return std.json.parseFromSliceLeaky(std.json.Value, arena, comptime json_schema.of(T), .{});
}

fn check(comptime T: type, arena: Allocator, schema: std.json.Value, v: T) !void {
    const text = try json_mod.stringifyAlloc(arena, v);
    var issue: parse_mod.Issue = .{};
    const back = parse_mod.parse(T, arena, text, &issue) catch |err| {
        std.debug.print("parse rejected a generated value: {f}\n", .{issue});
        return err;
    };
    try std.testing.expectEqualDeep(v, back);
    const doc = try std.json.parseFromSliceLeaky(std.json.Value, arena, text, .{});
    if (try validate.validate(arena, schema, doc)) |bad| {
        std.debug.print("the JSON doesn't match the schema: {s}: {s}\n", .{ bad.path, bad.message });
        return error.SchemaMismatch;
    }
}
