//! Comptime reflection helpers: names, declaration lookup and typo detection.

const std = @import("std");
const errors = @import("errors.zig");

/// The last component of `@typeName(T)`, ignoring dots inside generic
/// argument lists: "app.Order.Item" → "Item".
pub fn shortTypeName(comptime T: type) []const u8 {
    comptime {
        const full = @typeName(T);
        var depth: usize = 0;
        var start: usize = 0;
        for (full, 0..) |c, i| switch (c) {
            '(' => depth += 1,
            ')' => depth -= 1,
            '.' => if (depth == 0) {
                start = i + 1;
            },
            else => {},
        };
        return full[start..];
    }
}

/// "LookupOrder" → "lookup_order", "HTTPClient" → "http_client".
pub fn snakeCase(comptime s: []const u8) []const u8 {
    comptime {
        var out: []const u8 = "";
        for (s, 0..) |c, i| {
            if (std.ascii.isUpper(c)) {
                const prev_lower = i > 0 and (std.ascii.isLower(s[i - 1]) or std.ascii.isDigit(s[i - 1]));
                const acronym_end = i > 0 and std.ascii.isUpper(s[i - 1]) and i + 1 < s.len and std.ascii.isLower(s[i + 1]);
                if (prev_lower or acronym_end) out = out ++ "_";
                out = out ++ &[_]u8{std.ascii.toLower(c)};
            } else {
                out = out ++ &[_]u8{c};
            }
        }
        return out;
    }
}

/// UPPER_SNAKE of a snake_case id, for C constants.
pub fn upperSnake(comptime s: []const u8) []const u8 {
    comptime {
        var out: [s.len]u8 = undefined;
        for (s, 0..) |c, i| out[i] = if (c == '-' or c == '.' or c == '/') '_' else std.ascii.toUpper(c);
        const final = out;
        return &final;
    }
}

/// Is `T` a container type that can carry declarations?
pub fn isContainer(comptime T: type) bool {
    return switch (@typeInfo(T)) {
        .@"struct", .@"enum", .@"union", .@"opaque" => true,
        else => false,
    };
}

pub fn hasDecl(comptime T: type, comptime name: []const u8) bool {
    return isContainer(T) and @hasDecl(T, name);
}

/// One field of a struct, union or enum, or one error of an error set.
/// `@typeInfo` lists these as parallel arrays; this is one entry of them.
pub const Field = struct {
    name: [:0]const u8,
    /// `void` for enum fields and errors.
    type: type = void,
    /// Struct fields only.
    default_value_ptr: ?*const anyopaque = null,
    is_comptime: bool = false,
    /// Enum fields only.
    value: comptime_int = 0,

    pub fn defaultValue(comptime f: Field) ?f.type {
        const dp: *const f.type = @ptrCast(@alignCast(f.default_value_ptr orelse return null));
        return dp.*;
    }
};

/// The fields of a struct, tuple, union or enum, or the errors of an error
/// set, in declaration order.
pub inline fn fields(comptime T: type) []const Field {
    return comptime fieldsOf(T);
}

fn fieldsOf(comptime T: type) []const Field {
    {
        switch (@typeInfo(T)) {
            .@"struct" => |s| {
                var out: [s.field_names.len]Field = undefined;
                for (&out, s.field_names, s.field_types, s.field_attrs) |*o, n, ft, a|
                    o.* = .{ .name = n, .type = ft, .default_value_ptr = a.default_value_ptr, .is_comptime = a.@"comptime" };
                const final = out;
                return &final;
            },
            .@"union" => |u| {
                var out: [u.field_names.len]Field = undefined;
                for (&out, u.field_names, u.field_types) |*o, n, ft| o.* = .{ .name = n, .type = ft };
                const final = out;
                return &final;
            },
            .@"enum" => |e| {
                var out: [e.field_names.len]Field = undefined;
                for (&out, e.field_names, e.field_values) |*o, n, v| o.* = .{ .name = n, .value = v };
                const final = out;
                return &final;
            },
            .error_set => |es| {
                const names = es.error_names orelse @compileError("fields: `anyerror` has no error list");
                var out: [names.len]Field = undefined;
                for (&out, names) |*o, n| o.* = .{ .name = n };
                const final = out;
                return &final;
            },
            else => @compileError("fields: " ++ @typeName(T) ++ " has no fields"),
        }
    }
}

/// Names of a struct's (or tuple's) fields.
pub fn fieldNames(comptime T: type) []const []const u8 {
    comptime {
        const fs = fields(T);
        var names: [fs.len][]const u8 = undefined;
        for (fs, 0..) |f, i| names[i] = f.name;
        const final = names;
        return &final;
    }
}

pub fn declNames(comptime T: type) []const []const u8 {
    comptime {
        if (!isContainer(T)) return &.{};
        const decls = std.meta.declarations(T);
        var names: [decls.len][]const u8 = undefined;
        for (decls, 0..) |d, i| names[i] = d;
        const final = names;
        return &final;
    }
}

fn contains(comptime haystack: []const []const u8, comptime needle: []const u8) bool {
    for (haystack) |h| if (std.mem.eql(u8, h, needle)) return true;
    return false;
}

/// PLAN.md §5.14: a `pub` declaration within edit distance 2 of a known
/// declaration name fails to compile. Other unknown declarations are fine.
pub fn checkDeclTypos(
    comptime T: type,
    comptime known: []const []const u8,
    comptime what: []const u8,
    comptime who: []const u8,
) void {
    comptime {
        for (declNames(T)) |d| {
            if (contains(known, d)) continue;
            if (errors.closest(d, known)) |near| {
                errors.fail("{s} '{s}' declares `{s}`; did you mean `{s}`?", .{ what, who, d, near });
            }
        }
    }
}

/// Like `checkDeclTypos` but for the fields of a config struct literal, where
/// any unknown field is an error.
pub fn checkConfigFields(
    comptime Cfg: type,
    comptime known: []const []const u8,
    comptime what: []const u8,
) void {
    comptime {
        for (fieldNames(Cfg)) |f| {
            if (contains(known, f)) continue;
            errors.fail("{s} has unknown option `.{s}`{s}; valid options are {s}", .{
                what, f, errors.didYouMean(f, known), errors.list(known),
            });
        }
    }
}

/// Is a value of type `T` a comptime string ([]const u8, *const [N:0]u8, ...)?
pub fn isString(comptime T: type) bool {
    return switch (@typeInfo(T)) {
        .pointer => |p| switch (p.size) {
            .slice => p.child == u8,
            .one => switch (@typeInfo(p.child)) {
                .array => |a| a.child == u8,
                else => false,
            },
            else => false,
        },
        else => false,
    };
}

pub fn isTuple(comptime T: type) bool {
    return switch (@typeInfo(T)) {
        .@"struct" => |s| s.is_tuple,
        else => false,
    };
}

test snakeCase {
    try std.testing.expectEqualStrings("lookup_order", comptime snakeCase("LookupOrder"));
    try std.testing.expectEqualStrings("http_client", comptime snakeCase("HTTPClient"));
    try std.testing.expectEqualStrings("triage_agent", comptime snakeCase("TriageAgent"));
    try std.testing.expectEqualStrings("already_snake", comptime snakeCase("already_snake"));
    try std.testing.expectEqualStrings("SUPPORT_AGENT", comptime upperSnake("support_agent"));
}

test shortTypeName {
    const Outer = struct {
        pub const Inner = struct {};
    };
    try std.testing.expectEqualStrings("Inner", comptime shortTypeName(Outer.Inner));
}
