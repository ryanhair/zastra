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

/// Names of a struct's (or tuple's) fields.
pub fn fieldNames(comptime T: type) []const []const u8 {
    comptime {
        const fields = std.meta.fields(T);
        var names: [fields.len][]const u8 = undefined;
        for (fields, 0..) |f, i| names[i] = f.name;
        const final = names;
        return &final;
    }
}

pub fn declNames(comptime T: type) []const []const u8 {
    comptime {
        if (!isContainer(T)) return &.{};
        const decls = std.meta.declarations(T);
        var names: [decls.len][]const u8 = undefined;
        for (decls, 0..) |d, i| names[i] = d.name;
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
