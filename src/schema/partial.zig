//! `z.Partial(T)` (PLAN.md §5.15): `T` with every field optional, applied
//! recursively to nested structs. Used for working-memory updates (merge
//! semantics) and streaming partial output.

const std = @import("std");
const reflect = @import("../meta/reflect.zig");
const make = @import("../meta/make.zig");

pub fn Partial(comptime T: type) type {
    comptime {
        const info = @typeInfo(T);
        if (info != .@"struct") return T;
        const fields = reflect.fields(T);
        var names: [fields.len][]const u8 = undefined;
        var types: [fields.len]type = undefined;
        for (fields, 0..) |f, i| {
            names[i] = f.name;
            const Inner = switch (@typeInfo(f.type)) {
                .optional => |o| o.child,
                else => f.type,
            };
            types[i] = if (@typeInfo(Inner) == .@"struct") Partial(Inner) else Inner;
        }
        return make.OptionalStruct(&names, &types);
    }
}

/// Apply `patch` to `base`: set fields overwrite, nested structs merge,
/// unset fields keep their value.
pub fn merge(comptime T: type, base: T, patch: Partial(T)) T {
    var out = base;
    inline for (reflect.fields(T)) |f| {
        if (@field(patch, f.name)) |v| {
            const Inner = switch (@typeInfo(f.type)) {
                .optional => |o| o.child,
                else => f.type,
            };
            if (@typeInfo(Inner) == .@"struct") {
                const cur: Inner = switch (@typeInfo(f.type)) {
                    .optional => @field(base, f.name) orelse std.mem.zeroInit(Inner, .{}),
                    else => @field(base, f.name),
                };
                @field(out, f.name) = merge(Inner, cur, v);
            } else {
                @field(out, f.name) = v;
            }
        }
    }
    return out;
}

test merge {
    const Notes = struct {
        name: ?[]const u8 = null,
        contact: ?enum { email, sms } = null,
        issues: []const []const u8 = &.{},
        prefs: struct { lang: []const u8 = "en", tz: []const u8 = "UTC" } = .{},
    };
    const base: Notes = .{ .name = "Ada" };
    const out = merge(Notes, base, .{ .contact = .sms, .prefs = .{ .tz = "CET" } });
    try std.testing.expectEqualStrings("Ada", out.name.?);
    try std.testing.expectEqual(.sms, out.contact.?);
    try std.testing.expectEqualStrings("en", out.prefs.lang);
    try std.testing.expectEqualStrings("CET", out.prefs.tz);
}
