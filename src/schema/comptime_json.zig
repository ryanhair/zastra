//! Serialize comptime-known values to JSON at comptime (few-shot examples in
//! the request prefix, §5.10). Same shape as `json.zig`.

const std = @import("std");
const str = @import("json_schema.zig").str;
const Json = @import("json.zig").Json;

pub fn of(comptime T: type, comptime v: T) []const u8 {
    comptime {
        @setEvalBranchQuota(1_000_000);
        if (T == Json) return v.raw;
        return switch (@typeInfo(T)) {
            .bool => if (v) "true" else "false",
            .int, .float, .comptime_int, .comptime_float => std.fmt.comptimePrint("{d}", .{v}),
            .@"enum" => str(@tagName(v)),
            .optional => |o| if (v) |x| of(o.child, x) else "null",
            .pointer => |p| if (p.child == u8) str(v) else blk: {
                var s: []const u8 = "[";
                for (v, 0..) |x, i| s = s ++ (if (i == 0) "" else ",") ++ of(p.child, x);
                break :blk s ++ "]";
            },
            .array => |a| blk: {
                var s: []const u8 = "[";
                for (v, 0..) |x, i| s = s ++ (if (i == 0) "" else ",") ++ of(a.child, x);
                break :blk s ++ "]";
            },
            .@"struct" => "{" ++ fields(T, v, true) ++ "}",
            .@"union" => blk: {
                const tag = @tagName(std.meta.activeTag(v));
                const P = @FieldType(T, tag);
                const payload = @field(v, tag);
                break :blk "{\"type\":" ++ str(tag) ++ switch (@typeInfo(P)) {
                    .void => "",
                    .@"struct" => blk2: {
                        const f = fields(P, payload, false);
                        break :blk2 f;
                    },
                    else => ",\"value\":" ++ of(P, payload),
                } ++ "}";
            },
            else => @compileError("zastra: can't serialize " ++ @typeName(T) ++ " at comptime"),
        };
    }
}

fn fields(comptime T: type, comptime v: T, comptime first_in: bool) []const u8 {
    comptime {
        var s: []const u8 = "";
        var first = first_in;
        for (std.meta.fields(T)) |f| {
            const x = @field(v, f.name);
            if (@typeInfo(f.type) == .optional and x == null) continue;
            s = s ++ (if (first) "" else ",") ++ str(f.name) ++ ":" ++ of(f.type, x);
            first = false;
        }
        return s;
    }
}

test of {
    const T = struct { a: u8, b: ?[]const u8 = null, c: enum { x, y } = .y, d: []const u8 = "hi" };
    try std.testing.expectEqualStrings("{\"a\":1,\"c\":\"y\",\"d\":\"hi\"}", comptime of(T, .{ .a = 1 }));
}
