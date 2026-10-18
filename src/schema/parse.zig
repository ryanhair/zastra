//! Validated parsing of model JSON into Zig types (PLAN.md §5.2).
//!
//! `parse(T, arena, text, &issue)` accepts exactly what `json_schema.of(T)`
//! describes, enforces `constraints`, and on failure fills `issue` with a JSON
//! path and a message written to be sent back to the model.

const std = @import("std");
const errors = @import("../meta/errors.zig");
const reflect = @import("../meta/reflect.zig");
const Json = @import("json.zig").Json;
const json = @import("json.zig");
const Value = std.json.Value;
const Allocator = std.mem.Allocator;

pub const Issue = struct {
    /// JSON path of the offending value, e.g. "$.items[0].qty".
    path: []const u8 = "$",
    /// One sentence, suitable for the model.
    message: []const u8 = "",

    pub fn format(self: Issue, w: *std.Io.Writer) std.Io.Writer.Error!void {
        try w.print("{s}: {s}", .{ self.path, self.message });
    }
};

pub const Error = error{ ValidationFailed, OutOfMemory };

/// Parse and validate. All memory comes from `arena` (strings are copied, so
/// the result doesn't borrow from `text`).
pub fn parse(comptime T: type, arena: Allocator, text: []const u8, issue: *Issue) Error!T {
    const v = std.json.parseFromSliceLeaky(Value, arena, text, .{ .allocate = .alloc_always }) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => {
            issue.* = .{ .path = "$", .message = try arena.print("invalid JSON ({t})", .{err}) };
            return error.ValidationFailed;
        },
    };
    return fromValue(T, arena, v, issue);
}

/// Validate an already-parsed `std.json.Value`.
pub fn fromValue(comptime T: type, arena: Allocator, v: Value, issue: *Issue) Error!T {
    var p: Parser = .{ .arena = arena, .issue = issue };
    p.path.appendSlice(arena, "$") catch return error.OutOfMemory;
    return p.value(T, v, null);
}

const Parser = struct {
    arena: Allocator,
    issue: *Issue,
    path: std.ArrayList(u8) = .empty,

    fn fail(p: *Parser, comptime fmt: []const u8, args: anytype) Error {
        p.issue.* = .{
            .path = try p.arena.dupe(u8, p.path.items),
            .message = try p.arena.print(fmt, args),
        };
        return error.ValidationFailed;
    }

    fn kindName(v: Value) []const u8 {
        return switch (v) {
            .null => "null",
            .bool => "a boolean",
            .integer, .float, .number_string => "a number",
            .string => "a string",
            .array => "an array",
            .object => "an object",
        };
    }

    /// `C` is the constraints literal for this position, or null.
    fn value(p: *Parser, comptime T: type, v: Value, comptime C: ?type) Error!T {
        if (T == Json) {
            const raw = json.stringifyValueAlloc(p.arena, v) catch |err| switch (err) {
                error.OutOfMemory => return error.OutOfMemory,
                error.TooDeep => return p.fail("nested more than {d} levels deep", .{json.max_value_depth}),
            };
            return .{ .raw = raw };
        }
        switch (@typeInfo(T)) {
            .bool => return switch (v) {
                .bool => |b| b,
                else => p.fail("expected a boolean, got {s}", .{kindName(v)}),
            },
            .int => {
                const n: i128 = switch (v) {
                    .integer => |i| i,
                    .float => |f| if (@floor(f) == f and @abs(f) < 1e18) @intFromFloat(f) else return p.fail("expected an integer, got {d}", .{f}),
                    .number_string => |s| std.fmt.parseInt(i128, s, 10) catch return p.fail("expected an integer, got {s}", .{s}),
                    else => return p.fail("expected an integer, got {s}", .{kindName(v)}),
                };
                const lo: i128 = if (C) |CC| (if (has(CC, "min")) cval(CC, "min") else std.math.minInt(T)) else std.math.minInt(T);
                const hi: i128 = if (C) |CC| (if (has(CC, "max")) cval(CC, "max") else std.math.maxInt(T)) else std.math.maxInt(T);
                if (n < lo) return p.fail("must be at least {d}, got {d}", .{ lo, n });
                if (n > hi) return p.fail("must be at most {d}, got {d}", .{ hi, n });
                return @intCast(n);
            },
            .float => {
                const f: f64 = switch (v) {
                    .integer => |i| @floatFromInt(i),
                    .float => |f| f,
                    .number_string => |s| std.fmt.parseFloat(f64, s) catch return p.fail("expected a number, got {s}", .{s}),
                    else => return p.fail("expected a number, got {s}", .{kindName(v)}),
                };
                if (C) |CC| {
                    if (comptime has(CC, "min")) {
                        if (f < @as(f64, cval(CC, "min"))) return p.fail("must be at least {d}, got {d}", .{ @as(f64, cval(CC, "min")), f });
                    }
                    if (comptime has(CC, "max")) {
                        if (f > @as(f64, cval(CC, "max"))) return p.fail("must be at most {d}, got {d}", .{ @as(f64, cval(CC, "max")), f });
                    }
                }
                return @floatCast(f);
            },
            .@"enum" => |info| {
                const s = switch (v) {
                    .string => |s| s,
                    else => return p.fail("expected a string, got {s}", .{kindName(v)}),
                };
                if (std.meta.stringToEnum(T, s)) |e| return e;
                const names = comptime blk: {
                    var n: [info.field_names.len][]const u8 = undefined;
                    for (info.field_names, 0..) |name, i| n[i] = name;
                    const final = n;
                    break :blk &final;
                };
                return p.fail("must be one of {s}, got \"{s}\"", .{ comptime errors.list(names), s });
            },
            .optional => |info| {
                if (v == .null) return null;
                return try p.value(info.child, v, C);
            },
            .pointer => |ptr| {
                if (ptr.size != .slice) @compileError("zastra: can't parse " ++ @typeName(T));
                if (ptr.child == u8) {
                    const s = switch (v) {
                        .string => |s| s,
                        else => return p.fail("expected a string, got {s}", .{kindName(v)}),
                    };
                    if (C) |CC| try p.stringConstraints(CC, s);
                    return s;
                }
                const items = switch (v) {
                    .array => |a| a.items,
                    else => return p.fail("expected an array, got {s}", .{kindName(v)}),
                };
                if (C) |CC| {
                    if (comptime has(CC, "min_items")) {
                        if (items.len < cval(CC, "min_items")) return p.fail("must have at least {d} items, got {d}", .{ cval(CC, "min_items"), items.len });
                    }
                    if (comptime has(CC, "max_items")) {
                        if (items.len > cval(CC, "max_items")) return p.fail("must have at most {d} items, got {d}", .{ cval(CC, "max_items"), items.len });
                    }
                }
                const out = try p.arena.alloc(ptr.child, items.len);
                for (items, 0..) |item, i| {
                    const mark = p.path.items.len;
                    p.path.print(p.arena, "[{d}]", .{i}) catch return error.OutOfMemory;
                    out[i] = try p.value(ptr.child, item, null);
                    p.path.shrinkRetainingCapacity(mark);
                }
                return out;
            },
            .array => |a| {
                const items = switch (v) {
                    .array => |arr| arr.items,
                    else => return p.fail("expected an array, got {s}", .{kindName(v)}),
                };
                if (items.len != a.len) return p.fail("must have exactly {d} items, got {d}", .{ a.len, items.len });
                var out: T = undefined;
                for (items, 0..) |item, i| {
                    const mark = p.path.items.len;
                    p.path.print(p.arena, "[{d}]", .{i}) catch return error.OutOfMemory;
                    out[i] = try p.value(a.child, item, null);
                    p.path.shrinkRetainingCapacity(mark);
                }
                return out;
            },
            .@"struct" => {
                const obj = switch (v) {
                    .object => |o| o,
                    else => return p.fail("expected an object, got {s}", .{kindName(v)}),
                };
                return p.object(T, obj, &.{});
            },
            .@"union" => |u| {
                const obj = switch (v) {
                    .object => |o| o,
                    else => return p.fail("expected an object with a \"type\" field, got {s}", .{kindName(v)}),
                };
                const tag_v = obj.get("type") orelse return p.fail("missing \"type\" field", .{});
                const tag_s = switch (tag_v) {
                    .string => |s| s,
                    else => return p.fail("\"type\" must be a string", .{}),
                };
                const Tag = u.tag_type.?;
                const tag = std.meta.stringToEnum(Tag, tag_s) orelse {
                    const names = comptime reflect.fieldNames(T);
                    return p.fail("\"type\" must be one of {s}, got \"{s}\"", .{ comptime errors.list(names), tag_s });
                };
                switch (tag) {
                    inline else => |t| {
                        const P = @FieldType(T, @tagName(t));
                        switch (@typeInfo(P)) {
                            .void => {
                                try p.rejectUnknown(obj, &.{"type"});
                                return @unionInit(T, @tagName(t), {});
                            },
                            .@"struct" => return @unionInit(T, @tagName(t), try p.object(P, obj, &.{"type"})),
                            else => {
                                try p.rejectUnknown(obj, &.{ "type", "value" });
                                const pv = obj.get("value") orelse return p.fail("missing \"value\" field", .{});
                                const mark = p.path.items.len;
                                p.path.appendSlice(p.arena, ".value") catch return error.OutOfMemory;
                                const out = try p.value(P, pv, null);
                                p.path.shrinkRetainingCapacity(mark);
                                return @unionInit(T, @tagName(t), out);
                            },
                        }
                    },
                }
            },
            else => @compileError("zastra: can't parse " ++ @typeName(T)),
        }
    }

    fn object(p: *Parser, comptime S: type, obj: std.json.ObjectMap, comptime extra_keys: []const []const u8) Error!S {
        const names = comptime reflect.fieldNames(S);
        try p.rejectUnknown(obj, comptime extra_keys ++ names);
        var out: S = undefined;
        inline for (reflect.fields(S)) |f| {
            const C: ?type = comptime if (reflect.hasDecl(S, "constraints") and @hasField(@TypeOf(S.constraints), f.name))
                ConstraintsOf(S, f.name)
            else
                null;
            const mark = p.path.items.len;
            p.path.appendSlice(p.arena, "." ++ f.name) catch return error.OutOfMemory;
            if (obj.get(f.name)) |fv| {
                @field(out, f.name) = try p.value(f.type, fv, C);
            } else if (f.defaultValue()) |d| {
                @field(out, f.name) = d;
            } else if (@typeInfo(f.type) == .optional) {
                @field(out, f.name) = null;
            } else {
                return p.fail("missing required field", .{});
            }
            p.path.shrinkRetainingCapacity(mark);
        }
        return out;
    }

    fn rejectUnknown(p: *Parser, obj: std.json.ObjectMap, comptime allowed: []const []const u8) Error!void {
        for (obj.keys()) |k| {
            const known = for (allowed) |a| {
                if (std.mem.eql(u8, a, k)) break true;
            } else false;
            if (known) continue;
            if (errors.closest(k, allowed)) |near|
                return p.fail("unknown field \"{s}\" (did you mean \"{s}\"?)", .{ k, near });
            return p.fail("unknown field \"{s}\"; allowed fields are {s}", .{ k, comptime errors.list(allowed) });
        }
    }

    fn stringConstraints(p: *Parser, comptime CC: type, s: []const u8) Error!void {
        const len = std.unicode.utf8CountCodepoints(s) catch s.len;
        if (comptime has(CC, "min_len")) {
            if (len < cval(CC, "min_len")) return p.fail("must be at least {d} characters, got {d}", .{ cval(CC, "min_len"), len });
        }
        if (comptime has(CC, "max_len")) {
            if (len > cval(CC, "max_len")) return p.fail("must be at most {d} characters, got {d}", .{ cval(CC, "max_len"), len });
        }
        if (comptime has(CC, "one_of")) {
            const opts = cval(CC, "one_of");
            inline for (0..opts.len) |i| if (std.mem.eql(u8, opts[i], s)) return;
            return p.fail("must be one of the allowed values, got \"{s}\"", .{s});
        }
        // `pattern` is emitted into the schema only; it isn't enforced here.
    }
};

/// Constraints are anonymous struct literals; carry them around as a type
/// whose single decl holds the value.
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
