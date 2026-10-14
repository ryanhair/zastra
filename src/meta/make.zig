//! Building types at comptime: tagged unions and structs from name/type lists.

const std = @import("std");

/// `union(enum) { names[i]: types[i], ... }`
pub fn TaggedUnion(comptime names: []const []const u8, comptime types: []const type) type {
    comptime {
        std.debug.assert(names.len == types.len);
        const Tag = Enum(names);
        var zn: [names.len][]const u8 = undefined;
        for (names, 0..) |n, i| zn[i] = n;
        const final_names = zn;
        const final_types: [types.len]type = types[0..types.len].*;
        return @Union(.auto, Tag, &final_names, &final_types, &@splat(.{}));
    }
}

/// `enum { names... }`
pub fn Enum(comptime names: []const []const u8) type {
    comptime {
        const Int = std.math.IntFittingRange(0, @max(names.len, 1) - 1);
        var vals: [names.len]Int = undefined;
        for (0..names.len) |i| vals[i] = i;
        var zn: [names.len][]const u8 = undefined;
        for (names, 0..) |n, i| zn[i] = n;
        const final_names = zn;
        const final_vals = vals;
        return @Enum(Int, .exhaustive, &final_names, &final_vals);
    }
}

/// `struct { names[i]: types[i], ... }` with no defaults.
pub fn Struct(comptime names: []const []const u8, comptime types: []const type) type {
    comptime {
        var zn: [names.len][]const u8 = undefined;
        for (names, 0..) |n, i| zn[i] = n;
        const final_names = zn;
        const final_types: [types.len]type = types[0..types.len].*;
        return @Struct(.auto, null, &final_names, &final_types, &@splat(.{}));
    }
}

/// Like `Struct`, but every field is optional and defaults to null.
pub fn OptionalStruct(comptime names: []const []const u8, comptime types: []const type) type {
    comptime {
        var zn: [names.len][]const u8 = undefined;
        var ts: [names.len]type = undefined;
        var attrs: [names.len]std.builtin.Type.StructField.Attributes = undefined;
        for (names, types, 0..) |n, T, i| {
            zn[i] = n;
            ts[i] = ?T;
            const none: ?T = null;
            attrs[i] = .{ .default_value_ptr = @ptrCast(&none) };
        }
        const final_names = zn;
        const final_types = ts;
        const final_attrs = attrs;
        return @Struct(.auto, null, &final_names, &final_types, &final_attrs);
    }
}

test TaggedUnion {
    const U = TaggedUnion(&.{ "a", "b" }, &.{ u8, bool });
    const u: U = .{ .b = true };
    try std.testing.expect(u.b);
    const S = OptionalStruct(&.{"x"}, &.{u8});
    const s: S = .{};
    try std.testing.expect(s.x == null);
}
