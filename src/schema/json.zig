//! Writing schema-compatible Zig values as JSON, in the exact shape that
//! `json_schema.zig` describes and `parse.zig` reads back:
//! - `null` optional struct fields are omitted
//! - `union(enum)` values are objects with a `"type"` discriminator; struct
//!   payloads are flattened, other payloads go under `"value"`
//! - `Json` values are written verbatim

const std = @import("std");
const reflect = @import("../meta/reflect.zig");
const Writer = std.Io.Writer;

/// Untyped JSON: the escape hatch in schemas. `raw` is a complete JSON value.
pub const Json = struct {
    raw: []const u8,

    pub const @"null": Json = .{ .raw = "null" };
};

pub fn write(value: anytype, w: *Writer) Writer.Error!void {
    const T = @TypeOf(value);
    if (T == Json) return w.writeAll(value.raw);
    switch (@typeInfo(T)) {
        .bool => try w.writeAll(if (value) "true" else "false"),
        .int, .comptime_int => try w.print("{d}", .{value}),
        .float, .comptime_float => {
            if (std.math.isNan(value) or std.math.isInf(value)) return w.writeAll("null");
            try w.print("{d}", .{value});
        },
        .@"enum" => try writeString(@tagName(value), w),
        .enum_literal => try writeString(@tagName(value), w),
        .null => try w.writeAll("null"),
        .optional => if (value) |v| try write(v, w) else try w.writeAll("null"),
        .pointer => |p| switch (p.size) {
            .slice => if (p.child == u8) try writeString(value, w) else {
                try w.writeByte('[');
                for (value, 0..) |item, i| {
                    if (i > 0) try w.writeByte(',');
                    try write(item, w);
                }
                try w.writeByte(']');
            },
            .one => switch (@typeInfo(p.child)) {
                .array => |a| if (a.child == u8) try writeString(value, w) else try write(value.*, w),
                else => try write(value.*, w),
            },
            else => @compileError("zastra: can't write " ++ @typeName(T) ++ " as JSON"),
        },
        // Arrays are JSON arrays, `[N]u8` included, as the schema says.
        // (A pointer to a byte array, like a string literal, is a string.)
        .array => {
            try w.writeByte('[');
            for (value, 0..) |item, i| {
                if (i > 0) try w.writeByte(',');
                try write(item, w);
            }
            try w.writeByte(']');
        },
        .@"struct" => |s| {
            try w.writeByte('{');
            if (s.is_tuple) @compileError("zastra: can't write tuple " ++ @typeName(T) ++ " as JSON");
            var first = true;
            try writeFields(value, w, &first);
            try w.writeByte('}');
        },
        .@"union" => |u| {
            if (u.tag_type == null) @compileError("zastra: can't write untagged union " ++ @typeName(T) ++ " as JSON");
            try w.writeAll("{\"type\":");
            switch (value) {
                inline else => |payload, tag| {
                    try writeString(@tagName(tag), w);
                    const P = @TypeOf(payload);
                    switch (@typeInfo(P)) {
                        .void => {},
                        .@"struct" => {
                            var first = false;
                            try writeFields(payload, w, &first);
                        },
                        else => {
                            try w.writeAll(",\"value\":");
                            try write(payload, w);
                        },
                    }
                },
            }
            try w.writeByte('}');
        },
        .void => try w.writeAll("null"),
        else => @compileError("zastra: can't write " ++ @typeName(T) ++ " as JSON"),
    }
}

fn writeFields(value: anytype, w: *Writer, first: *bool) Writer.Error!void {
    inline for (reflect.fields(@TypeOf(value))) |f| {
        const v = @field(value, f.name);
        const skip = @typeInfo(f.type) == .optional and v == null;
        if (!skip) {
            if (!first.*) try w.writeByte(',');
            first.* = false;
            try writeString(f.name, w);
            try w.writeByte(':');
            try write(v, w);
        }
    }
}

pub fn writeString(s: []const u8, w: *Writer) Writer.Error!void {
    try std.json.Stringify.encodeJsonString(s, .{}, w);
}

/// Like `writeString`, without the quotes.
pub fn writeStringBody(s: []const u8, w: *Writer) Writer.Error!void {
    try std.json.Stringify.encodeJsonStringChars(s, .{}, w);
}

/// The deepest nesting `stringifyValueAlloc` writes. `std.json.Stringify`
/// asserts a depth of at most 256 in safe builds, and `std.json.Value`s from
/// models and servers can be nested arbitrarily deep.
pub const max_value_depth = 256;

/// `std.json.Stringify.valueAlloc` for untrusted values: `error.TooDeep`
/// instead of a panic past `max_value_depth`.
pub fn stringifyValueAlloc(gpa: std.mem.Allocator, v: std.json.Value) error{ OutOfMemory, TooDeep }![]u8 {
    if (tooDeep(v, 0)) return error.TooDeep;
    return std.json.Stringify.valueAlloc(gpa, v, .{}) catch return error.OutOfMemory;
}

fn tooDeep(v: std.json.Value, depth: usize) bool {
    switch (v) {
        .array => |a| {
            if (depth + 1 > max_value_depth) return true;
            for (a.items) |item| if (tooDeep(item, depth + 1)) return true;
        },
        .object => |o| {
            if (depth + 1 > max_value_depth) return true;
            for (o.values()) |item| if (tooDeep(item, depth + 1)) return true;
        },
        else => {},
    }
    return false;
}

/// Serialize into a newly allocated slice.
pub fn stringifyAlloc(gpa: std.mem.Allocator, value: anytype) error{OutOfMemory}![]u8 {
    var aw: Writer.Allocating = .init(gpa);
    defer aw.deinit();
    write(value, &aw.writer) catch return error.OutOfMemory;
    return aw.toOwnedSlice();
}

/// `{f}` formatter: `w.fmt("order: {f}", .{z.fmt.json(order)})`.
pub fn fmt(value: anytype) Formatter(@TypeOf(value)) {
    return .{ .value = value };
}

pub fn Formatter(comptime T: type) type {
    return struct {
        value: T,
        pub fn format(self: @This(), w: *Writer) Writer.Error!void {
            try write(self.value, w);
        }
    };
}

test write {
    const T = struct {
        a: u8,
        b: ?[]const u8 = null,
        c: enum { x, y } = .y,
        u: union(enum) { none, n: u8, p: struct { q: bool } },
        j: Json = .{ .raw = "[1,2]" },
    };
    const gpa = std.testing.allocator;
    const s = try stringifyAlloc(gpa, T{ .a = 1, .u = .{ .p = .{ .q = true } } });
    defer gpa.free(s);
    try std.testing.expectEqualStrings("{\"a\":1,\"c\":\"y\",\"u\":{\"type\":\"p\",\"q\":true},\"j\":[1,2]}", s);

    // `[N]u8` is an array, as the schema describes it; a string literal is a string.
    const b = try stringifyAlloc(gpa, .{ .bytes = [2]u8{ 104, 105 }, .lit = "hi" });
    defer gpa.free(b);
    try std.testing.expectEqualStrings("{\"bytes\":[104,105],\"lit\":\"hi\"}", b);
}
