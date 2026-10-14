//! A small runtime JSON Schema validator for MCP tool arguments (PLAN.md
//! §6.7). Supports the subset MCP servers use in practice: `type` (string or
//! array), `properties`, `required`, `additionalProperties: false`, `items`,
//! `enum`, `const`, `anyOf`/`oneOf`, `minimum`/`maximum`,
//! `minLength`/`maxLength`, `minItems`/`maxItems`. Unknown keywords are
//! ignored. Errors are written for the model.

const std = @import("std");
const Value = std.json.Value;
const Allocator = std.mem.Allocator;

pub const Issue = struct { path: []const u8, message: []const u8 };

pub fn validate(arena: Allocator, schema: Value, v: Value) Allocator.Error!?Issue {
    var path: std.ArrayList(u8) = .empty;
    try path.appendSlice(arena, "$");
    return check(arena, schema, v, &path);
}

fn typeName(v: Value) []const u8 {
    return switch (v) {
        .null => "null",
        .bool => "boolean",
        .integer => "integer",
        .float, .number_string => "number",
        .string => "string",
        .array => "array",
        .object => "object",
    };
}

fn isType(v: Value, t: []const u8) bool {
    if (std.mem.eql(u8, t, "number")) return v == .integer or v == .float or v == .number_string;
    if (std.mem.eql(u8, t, "integer")) return v == .integer or (v == .float and @floor(v.float) == v.float);
    return std.mem.eql(u8, typeName(v), t);
}

fn num(v: Value) ?f64 {
    return switch (v) {
        .integer => |i| @floatFromInt(i),
        .float => |f| f,
        .number_string => |s| std.fmt.parseFloat(f64, s) catch null,
        else => null,
    };
}

fn issue(arena: Allocator, path: *std.ArrayList(u8), comptime fmt: []const u8, args: anytype) Allocator.Error!?Issue {
    return .{ .path = try arena.dupe(u8, path.items), .message = try std.fmt.allocPrint(arena, fmt, args) };
}

fn check(arena: Allocator, schema: Value, v: Value, path: *std.ArrayList(u8)) Allocator.Error!?Issue {
    if (schema != .object) return null; // `true` / `{}`-like schemas accept anything
    const s = schema.object;

    if (s.get("type")) |t| switch (t) {
        .string => |name| if (!isType(v, name)) return issue(arena, path, "expected {s}, got {s}", .{ name, typeName(v) }),
        .array => |names| {
            const ok = for (names.items) |n| {
                if (n == .string and isType(v, n.string)) break true;
            } else false;
            if (!ok) return issue(arena, path, "has the wrong type ({s})", .{typeName(v)});
        },
        else => {},
    };
    if (s.get("enum")) |e| if (e == .array) {
        const ok = for (e.array.items) |x| {
            if (jsonEql(x, v)) break true;
        } else false;
        if (!ok) return issue(arena, path, "must be one of the allowed values", .{});
    };
    if (s.get("const")) |c| if (!jsonEql(c, v)) return issue(arena, path, "must equal the constant value", .{});
    inline for (.{ "anyOf", "oneOf" }) |kw| if (s.get(kw)) |alts| if (alts == .array) {
        const ok = for (alts.array.items) |alt| {
            if ((try check(arena, alt, v, path)) == null) break true;
        } else false;
        if (!ok) return issue(arena, path, "doesn't match any allowed shape", .{});
    };
    if (num(v)) |n| {
        if (s.get("minimum")) |m| if (num(m)) |lo| if (n < lo) return issue(arena, path, "must be at least {d}", .{lo});
        if (s.get("maximum")) |m| if (num(m)) |hi| if (n > hi) return issue(arena, path, "must be at most {d}", .{hi});
    }
    if (v == .string) {
        const len = std.unicode.utf8CountCodepoints(v.string) catch v.string.len;
        if (s.get("minLength")) |m| if (m == .integer and len < m.integer) return issue(arena, path, "must be at least {d} characters", .{m.integer});
        if (s.get("maxLength")) |m| if (m == .integer and len > m.integer) return issue(arena, path, "must be at most {d} characters", .{m.integer});
    }
    if (v == .array) {
        const items = v.array.items;
        if (s.get("minItems")) |m| if (m == .integer and items.len < m.integer) return issue(arena, path, "must have at least {d} items", .{m.integer});
        if (s.get("maxItems")) |m| if (m == .integer and items.len > m.integer) return issue(arena, path, "must have at most {d} items", .{m.integer});
        if (s.get("items")) |is| for (items, 0..) |item, i| {
            const mark = path.items.len;
            try path.print(arena, "[{d}]", .{i});
            if (try check(arena, is, item, path)) |x| return x;
            path.shrinkRetainingCapacity(mark);
        };
    }
    if (v == .object) {
        const o = v.object;
        if (s.get("required")) |req| if (req == .array) for (req.array.items) |r| {
            if (r == .string and !o.contains(r.string)) return issue(arena, path, "missing required field \"{s}\"", .{r.string});
        };
        const props = if (s.get("properties")) |p| (if (p == .object) p.object else null) else null;
        const closed = if (s.get("additionalProperties")) |ap| ap == .bool and !ap.bool else false;
        var it = o.iterator();
        while (it.next()) |e| {
            const sub = if (props) |p| p.get(e.key_ptr.*) else null;
            if (sub) |ss| {
                const mark = path.items.len;
                try path.print(arena, ".{s}", .{e.key_ptr.*});
                if (try check(arena, ss, e.value_ptr.*, path)) |x| return x;
                path.shrinkRetainingCapacity(mark);
            } else if (closed) {
                return issue(arena, path, "unknown field \"{s}\"", .{e.key_ptr.*});
            }
        }
    }
    return null;
}

fn jsonEql(a: Value, b: Value) bool {
    if (num(a)) |x| if (num(b)) |y| return x == y;
    if (std.meta.activeTag(a) != std.meta.activeTag(b)) return false;
    return switch (a) {
        .null => true,
        .bool => |x| x == b.bool,
        .string => |x| std.mem.eql(u8, x, b.string),
        else => false,
    };
}

test validate {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const schema = try std.json.parseFromSliceLeaky(Value, a,
        \\{"type":"object","properties":{"q":{"type":"string","minLength":2},"n":{"type":"integer","maximum":5}},"required":["q"],"additionalProperties":false}
    , .{});
    const ok = try std.json.parseFromSliceLeaky(Value, a, "{\"q\":\"hi\",\"n\":3}", .{});
    try std.testing.expect((try validate(a, schema, ok)) == null);
    const bad = try std.json.parseFromSliceLeaky(Value, a, "{\"q\":\"hi\",\"n\":9}", .{});
    const i = (try validate(a, schema, bad)).?;
    try std.testing.expectEqualStrings("$.n", i.path);
    const missing = try std.json.parseFromSliceLeaky(Value, a, "{}", .{});
    try std.testing.expect(std.mem.indexOf(u8, (try validate(a, schema, missing)).?.message, "\"q\"") != null);
}
