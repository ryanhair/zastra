//! A small runtime JSON Schema validator for MCP tool arguments (PLAN.md
//! §6.7, D40). Supports the keywords MCP servers use in practice: `type`
//! (string or array), `properties`, `required`, `additionalProperties: false`,
//! `items`, `prefixItems`, `enum`, `const`, `anyOf`/`oneOf`/`allOf`,
//! `if`/`then`/`else`, local `$ref` (into `$defs`/`definitions`),
//! `minimum`/`maximum`, `minLength`/`maxLength`, `minItems`/`maxItems`.
//! Unknown keywords are ignored. Validation is bounded (depth 64, 10k
//! subschemas visited); past the bounds the arguments are accepted.
//! Errors are written for the model.

const std = @import("std");
const Value = std.json.Value;
const Allocator = std.mem.Allocator;

pub const Issue = struct { path: []const u8, message: []const u8 };

pub const max_depth = 64;
pub const max_nodes = 10_000;

const Ctx = struct {
    arena: Allocator,
    root: Value,
    nodes: u32 = 0,
    depth: u32 = 0,
    /// A bound was hit: stop and accept.
    gave_up: bool = false,
};

pub fn validate(arena: Allocator, schema: Value, v: Value) Allocator.Error!?Issue {
    var path: std.ArrayList(u8) = .empty;
    try path.appendSlice(arena, "$");
    var cx: Ctx = .{ .arena = arena, .root = schema };
    const r = try check(&cx, schema, v, &path);
    return if (cx.gave_up) null else r;
}

/// Whether the validator can handle `schema`: every `$ref` must point into
/// the schema itself. If it can't, zastra skips argument validation for the
/// tool (with a warning) instead of hiding the tool.
pub fn supported(schema: Value) ?[]const u8 {
    return unsupported(schema, schema, 0);
}

fn unsupported(root: Value, s: Value, depth: u32) ?[]const u8 {
    if (depth > max_depth) return "the schema is nested too deeply";
    switch (s) {
        .object => |o| {
            if (o.get("$ref")) |r| {
                if (r != .string or resolve(root, r.string) == null) return "it uses a `$ref` that doesn't point into the schema";
            }
            if (o.get("$dynamicRef") != null) return "it uses `$dynamicRef`";
            var it = o.iterator();
            while (it.next()) |e| if (unsupported(root, e.value_ptr.*, depth + 1)) |why| return why;
        },
        .array => |a| for (a.items) |x| if (unsupported(root, x, depth + 1)) |why| return why,
        else => {},
    }
    return null;
}

/// Resolve a local reference like `#`, `#/$defs/Name` or `#/definitions/a/b`.
fn resolve(root: Value, ref: []const u8) ?Value {
    if (!std.mem.startsWith(u8, ref, "#")) return null;
    var v = root;
    var it = std.mem.tokenizeScalar(u8, ref[1..], '/');
    while (it.next()) |raw| {
        var buf: [256]u8 = undefined;
        // JSON Pointer escapes: ~1 is '/', ~0 is '~'.
        const seg = unescape(raw, &buf) orelse return null;
        switch (v) {
            .object => |o| v = o.get(seg) orelse return null,
            .array => |a| {
                const i = std.fmt.parseInt(usize, seg, 10) catch return null;
                if (i >= a.items.len) return null;
                v = a.items[i];
            },
            else => return null,
        }
    }
    return v;
}

fn unescape(raw: []const u8, buf: []u8) ?[]const u8 {
    var n: usize = 0;
    var i: usize = 0;
    while (i < raw.len) : (i += 1) {
        if (n >= buf.len) return null;
        if (raw[i] == '~' and i + 1 < raw.len) {
            buf[n] = if (raw[i + 1] == '1') '/' else '~';
            i += 1;
        } else buf[n] = raw[i];
        n += 1;
    }
    return buf[0..n];
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

fn check(cx: *Ctx, schema: Value, v: Value, path: *std.ArrayList(u8)) Allocator.Error!?Issue {
    if (cx.gave_up) return null;
    cx.nodes += 1;
    if (cx.nodes > max_nodes or cx.depth >= max_depth) {
        cx.gave_up = true;
        return null;
    }
    cx.depth += 1;
    defer cx.depth -= 1;
    return checkInner(cx, schema, v, path);
}

fn checkInner(cx: *Ctx, schema: Value, v: Value, path: *std.ArrayList(u8)) Allocator.Error!?Issue {
    const arena = cx.arena;
    if (schema == .bool and !schema.bool) return issue(arena, path, "isn't allowed here", .{});
    if (schema != .object) return null; // `true` / `{}`-like schemas accept anything
    const s = schema.object;

    if (s.get("$ref")) |r| if (r == .string) {
        if (resolve(cx.root, r.string)) |target| if (try check(cx, target, v, path)) |x| return x;
    };
    if (s.get("allOf")) |all| if (all == .array) for (all.array.items) |sub| {
        if (try check(cx, sub, v, path)) |x| return x;
    };
    if (s.get("if")) |cond| {
        var probe: std.ArrayList(u8) = .empty;
        try probe.appendSlice(arena, path.items);
        const matched = (try check(cx, cond, v, &probe)) == null;
        if (s.get(if (matched) "then" else "else")) |branch| if (try check(cx, branch, v, path)) |x| return x;
    }

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
            if ((try check(cx, alt, v, path)) == null) break true;
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
        // 2020-12: `prefixItems` for the leading positions, `items` for the rest.
        var first: usize = 0;
        if (s.get("prefixItems")) |pi| if (pi == .array) {
            for (pi.array.items, 0..) |sub, i| {
                if (i >= items.len) break;
                const mark = path.items.len;
                try path.print(arena, "[{d}]", .{i});
                if (try check(cx, sub, items[i], path)) |x| return x;
                path.shrinkRetainingCapacity(mark);
            }
            first = pi.array.items.len;
        };
        if (s.get("items")) |is| if (is != .array) for (items, 0..) |item, i| {
            if (i < first) continue;
            const mark = path.items.len;
            try path.print(arena, "[{d}]", .{i});
            if (try check(cx, is, item, path)) |x| return x;
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
                if (try check(cx, ss, e.value_ptr.*, path)) |x| return x;
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

test "D40: $ref, allOf, if/then/else, prefixItems, bounds" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const schema = try std.json.parseFromSliceLeaky(Value, a,
        \\{"type":"object","$defs":{"Pos":{"type":"integer","minimum":1}},
        \\ "properties":{"n":{"$ref":"#/$defs/Pos"},"pair":{"type":"array","prefixItems":[{"type":"string"},{"type":"integer"}],"items":false},
        \\   "kind":{"type":"string"},"size":{"type":"integer"}},
        \\ "allOf":[{"required":["n"]}],
        \\ "if":{"properties":{"kind":{"const":"big"}},"required":["kind"]},"then":{"required":["size"]}}
    , .{});
    try std.testing.expect(supported(schema) == null);
    const cases = [_]struct { args: []const u8, path: ?[]const u8 }{
        .{ .args = "{\"n\":2,\"pair\":[\"a\",1]}", .path = null },
        .{ .args = "{\"n\":0}", .path = "$.n" },
        .{ .args = "{}", .path = "$" },
        .{ .args = "{\"n\":1,\"pair\":[\"a\",\"b\"]}", .path = "$.pair[1]" },
        .{ .args = "{\"n\":1,\"pair\":[\"a\",1,2]}", .path = "$.pair[2]" },
        .{ .args = "{\"n\":1,\"kind\":\"big\"}", .path = "$" },
        .{ .args = "{\"n\":1,\"kind\":\"big\",\"size\":3}", .path = null },
    };
    for (cases) |c| {
        const v = try std.json.parseFromSliceLeaky(Value, a, c.args, .{});
        const r = try validate(a, schema, v);
        if (c.path) |p| {
            try std.testing.expectEqualStrings(p, r.?.path);
        } else try std.testing.expect(r == null);
    }
    const remote = try std.json.parseFromSliceLeaky(Value, a, "{\"properties\":{\"x\":{\"$ref\":\"https://example.com/s.json\"}}}", .{});
    try std.testing.expect(supported(remote) != null);
    // A self-referencing schema stops at the bounds instead of recursing forever.
    const loop = try std.json.parseFromSliceLeaky(Value, a, "{\"$ref\":\"#\"}", .{});
    try std.testing.expect((try validate(a, loop, .null)) == null);
}
