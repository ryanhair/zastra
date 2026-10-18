//! Structural type fingerprints (PLAN.md §5.8).
//!
//! The fingerprint depends on field names, field types and their order, and on
//! enum tags; not on `@typeName`, so moving or renaming a type doesn't change
//! it, while changing its shape does.

const std = @import("std");
const Json = @import("../schema/json.zig").Json;

pub fn of(comptime T: type) u64 {
    return hash(describe(T));
}

pub fn hash(comptime s: []const u8) u64 {
    comptime {
        @setEvalBranchQuota(10_000_000);
        return std.hash.Wyhash.hash(0, s);
    }
}

/// A canonical structural description of `T`.
pub fn describe(comptime T: type) []const u8 {
    comptime {
        @setEvalBranchQuota(10_000_000);
        return desc(T, &.{});
    }
}

fn desc(comptime T: type, comptime stack: []const type) []const u8 {
    comptime {
        if (T == Json) return "json";
        for (stack, 0..) |S, i| if (S == T) return std.fmt.comptimePrint("^{d}", .{stack.len - i});
        const next = stack ++ &[_]type{T};
        return switch (@typeInfo(T)) {
            .void => "void",
            .bool => "bool",
            .int => |i| std.fmt.comptimePrint("{c}{d}", .{ if (i.signedness == .signed) 'i' else 'u', i.bits }),
            .float => |f| std.fmt.comptimePrint("f{d}", .{f.bits}),
            .optional => |o| "?" ++ desc(o.child, next),
            .pointer => |p| if (p.size == .slice and p.child == u8) "str" else "[]" ++ desc(p.child, next),
            .array => |a| std.fmt.comptimePrint("[{d}]", .{a.len}) ++ desc(a.child, next),
            .@"enum" => |e| blk: {
                var s: []const u8 = "enum{";
                for (e.field_names) |n| s = s ++ n ++ ",";
                break :blk s ++ "}";
            },
            .@"struct" => |st| blk: {
                var s: []const u8 = "struct{";
                for (st.field_names, st.field_types) |n, ft| s = s ++ n ++ ":" ++ desc(ft, next) ++ ",";
                break :blk s ++ "}";
            },
            .@"union" => |u| blk: {
                var s: []const u8 = "union{";
                for (u.field_names, u.field_types) |n, ft| s = s ++ n ++ ":" ++ desc(ft, next) ++ ",";
                break :blk s ++ "}";
            },
            else => "?" ++ @typeName(T),
        };
    }
}

test "shape changes change the fingerprint; names don't" {
    const A = struct { x: u8, y: []const u8 };
    const B = struct { x: u8, y: []const u8 };
    const C = struct { x: u16, y: []const u8 };
    const D = struct { y: []const u8, x: u8 };
    const E = struct { x: u8, y: []const u8, z: ?bool };
    try std.testing.expectEqual(comptime of(A), comptime of(B));
    try std.testing.expect(comptime of(A) != of(C));
    try std.testing.expect(comptime of(A) != of(D));
    try std.testing.expect(comptime of(A) != of(E));
    try std.testing.expect(comptime of(enum { a, b }) != of(enum { a, c }));
}
