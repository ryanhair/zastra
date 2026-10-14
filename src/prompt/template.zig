//! Comptime-checked prompt templates (PLAN.md §5.9).
//!
//! "Subject: {subject}\n\n{body}" against a type `T`:
//! - `{field}` must name a field of `T` (did-you-mean on typos)
//! - `{field.sub}` paths walk nested structs (and optionals of structs)
//! - `{{` and `}}` are literal braces
//! - strings are inserted as-is; every other value is written as JSON

const std = @import("std");
const errors = @import("../meta/errors.zig");
const reflect = @import("../meta/reflect.zig");
const json = @import("../schema/json.zig");

const Part = union(enum) {
    lit: []const u8,
    path: []const []const u8,
};

fn parse(comptime T: type, comptime tpl: []const u8, comptime who: []const u8) []const Part {
    comptime {
        @setEvalBranchQuota(1_000_000);
        var parts: []const Part = &.{};
        var lit: []const u8 = "";
        var i: usize = 0;
        while (i < tpl.len) {
            const c = tpl[i];
            if (c == '{') {
                if (i + 1 < tpl.len and tpl[i + 1] == '{') {
                    lit = lit ++ "{";
                    i += 2;
                    continue;
                }
                const close = std.mem.indexOfScalarPos(u8, tpl, i + 1, '}') orelse
                    errors.fail("{s}: prompt template has an unclosed '{{' at byte {d}; write '{{{{' for a literal brace", .{ who, i });
                const inner = std.mem.trim(u8, tpl[i + 1 .. close], " ");
                if (inner.len == 0) errors.fail("{s}: prompt template has an empty placeholder '{{}}' at byte {d}", .{ who, i });
                if (lit.len > 0) parts = parts ++ &[_]Part{.{ .lit = lit }};
                lit = "";
                var segs: []const []const u8 = &.{};
                var it = std.mem.splitScalar(u8, inner, '.');
                while (it.next()) |s| segs = segs ++ &[_][]const u8{s};
                checkPath(T, segs, inner, who);
                parts = parts ++ &[_]Part{.{ .path = segs }};
                i = close + 1;
            } else if (c == '}') {
                if (i + 1 < tpl.len and tpl[i + 1] == '}') {
                    lit = lit ++ "}";
                    i += 2;
                    continue;
                }
                errors.fail("{s}: prompt template has a stray '}}' at byte {d}; write '}}}}' for a literal brace", .{ who, i });
            } else {
                lit = lit ++ &[_]u8{c};
                i += 1;
            }
        }
        if (lit.len > 0) parts = parts ++ &[_]Part{.{ .lit = lit }};
        return parts;
    }
}

fn Unwrap(comptime T: type) type {
    return switch (@typeInfo(T)) {
        .optional => |o| o.child,
        .pointer => |p| if (p.size == .one) p.child else T,
        else => T,
    };
}

fn checkPath(comptime T: type, comptime segs: []const []const u8, comptime full: []const u8, comptime who: []const u8) void {
    comptime {
        var Cur = T;
        for (segs) |s| {
            const S = Unwrap(Cur);
            if (@typeInfo(S) != .@"struct") errors.fail("{s}: prompt template placeholder '{{{s}}}': '{s}' is not a struct field path ({s} has no fields)", .{ who, full, s, @typeName(S) });
            if (!@hasField(S, s)) errors.fail("{s}: prompt template placeholder '{{{s}}}' names `{s}`, which is not a field of {s}{s}", .{
                who, full, s, reflect.shortTypeName(S), errors.didYouMean(s, reflect.fieldNames(S)),
            });
            Cur = @FieldType(S, s);
        }
    }
}

/// Check a template at comptime (for use in declarations).
pub fn check(comptime T: type, comptime tpl: []const u8, comptime who: []const u8) void {
    _ = parse(T, tpl, who);
}

/// Render `tpl` with `value` into `w`.
pub fn render(comptime T: type, comptime tpl: []const u8, value: T, w: *std.Io.Writer) std.Io.Writer.Error!void {
    const parts = comptime parse(T, tpl, "z.prompt.render");
    inline for (parts) |part| switch (part) {
        .lit => |l| try w.writeAll(l),
        .path => |segs| try renderPath(value, segs, w),
    };
}

fn renderPath(value: anytype, comptime segs: []const []const u8, w: *std.Io.Writer) std.Io.Writer.Error!void {
    if (segs.len == 0) return renderValue(value, w);
    const V = @TypeOf(value);
    switch (@typeInfo(V)) {
        .optional => if (value) |v| return renderPath(v, segs, w) else return w.writeAll("null"),
        .pointer => |p| if (p.size == .one) return renderPath(value.*, segs, w),
        else => {},
    }
    return renderPath(@field(value, segs[0]), segs[1..], w);
}

fn renderValue(value: anytype, w: *std.Io.Writer) std.Io.Writer.Error!void {
    const V = @TypeOf(value);
    if (comptime reflect.isString(V)) return w.writeAll(value);
    if (@typeInfo(V) == .optional) {
        if (value) |v| return renderValue(v, w);
        return w.writeAll("null");
    }
    return json.write(value, w);
}

/// Render into an allocated string.
pub fn renderAlloc(comptime T: type, comptime tpl: []const u8, gpa: std.mem.Allocator, value: T) error{OutOfMemory}![]u8 {
    var aw: std.Io.Writer.Allocating = .init(gpa);
    defer aw.deinit();
    render(T, tpl, value, &aw.writer) catch return error.OutOfMemory;
    return aw.toOwnedSlice();
}

test render {
    const Ticket = struct {
        subject: []const u8,
        body: []const u8,
        meta: struct { n: u8, tag: ?[]const u8 },
    };
    const out = try renderAlloc(Ticket, "S: {subject} | {{lit}} | {meta.n} {meta.tag} {meta}", std.testing.allocator, .{
        .subject = "Broken",
        .body = "x",
        .meta = .{ .n = 3, .tag = null },
    });
    defer std.testing.allocator.free(out);
    try std.testing.expectEqualStrings("S: Broken | {lit} | 3 null {\"n\":3}", out);
}
