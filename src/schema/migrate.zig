//! Working-memory migrations (PLAN.md §18.2, D48).
//!
//!     pub const CustomerNotes = struct {
//!         ...
//!         pub const migrations = .{ z.migrate(NotesV1, fromV1), z.migrate(NotesV2, fromV2) };
//!     };
//!
//! Each `z.migrate(Old, f)` turns a value stored with `Old`'s shape into the
//! next version; `f` is `fn (Allocator, Old) !Next`. The list runs oldest
//! first and ends at the type that declares it. A value stored under any
//! listed shape is parsed as that shape and carried through every later step.

const std = @import("std");
const errors = @import("../meta/errors.zig");
const reflect = @import("../meta/reflect.zig");
const fingerprint = @import("../meta/fingerprint.zig");
const parse = @import("parse.zig");
const Allocator = std.mem.Allocator;

/// `z.migrate(Old, f)`: one step of a working-memory migration chain.
pub fn migrate(comptime Old: type, comptime f: anytype) type {
    comptime {
        if (@TypeOf(Old) != type or @typeInfo(Old) != .@"struct")
            errors.fail("z.migrate(Old, f): `Old` must be the struct type the value was saved as", .{});
        const F = @TypeOf(f);
        const info = switch (@typeInfo(F)) {
            .@"fn" => |i| i,
            else => errors.fail("z.migrate({s}, f): `f` must be a function `fn (std.mem.Allocator, {s}) !Next`, got {s}", .{ reflect.shortTypeName(Old), reflect.shortTypeName(Old), @typeName(F) }),
        };
        if (info.params.len != 2 or info.params[0].type != Allocator or info.params[1].type != Old)
            errors.fail("z.migrate({s}, f): `f` must take `(std.mem.Allocator, {s})`", .{ reflect.shortTypeName(Old), reflect.shortTypeName(Old) });
        const R = info.return_type.?;
        const Next = switch (@typeInfo(R)) {
            .error_union => |eu| eu.payload,
            else => R,
        };
        return struct {
            pub const zastra_migration = true;
            pub const From = Old;
            pub const To = Next;
            pub const from_fingerprint = fingerprint.of(Old);

            pub fn step(arena: Allocator, old: Old) anyerror!Next {
                return f(arena, old);
            }
        };
    }
}

pub fn has(comptime T: type) bool {
    return @hasDecl(T, "migrations");
}

/// Check `T.migrations` at comptime: a tuple of `z.migrate` steps, each
/// producing the next one's input and the last producing `T`.
pub fn check(comptime T: type, comptime who: []const u8) void {
    comptime {
        if (!has(T)) return;
        const ms = T.migrations;
        const name = reflect.shortTypeName(T);
        if (!reflect.isTuple(@TypeOf(ms)))
            errors.fail("{s}: `{s}.migrations` must be a tuple of `z.migrate(Old, f)`, like `.{{ z.migrate({s}V1, fromV1) }}`", .{ who, name, name });
        if (ms.len == 0) errors.fail("{s}: `{s}.migrations` is empty; remove it or add `z.migrate(Old, f)`", .{ who, name });
        const now = fingerprint.of(T);
        for (ms, 0..) |M, i| {
            if (@TypeOf(M) != type or !@hasDecl(M, "zastra_migration"))
                errors.fail("{s}: `{s}.migrations[{d}]` must be `z.migrate(Old, f)`", .{ who, name, i });
            if (M.from_fingerprint == now)
                errors.fail("{s}: `{s}.migrations[{d}]` migrates from {s}, which has the same shape as {s}; a value of that shape already loads as-is", .{ who, name, i, reflect.shortTypeName(M.From), name });
            for (0..i) |j| if (ms[j].from_fingerprint == M.from_fingerprint)
                errors.fail("{s}: `{s}.migrations[{d}]` and `[{d}]` migrate from the same shape", .{ who, name, j, i });
            const want = if (i + 1 < ms.len) ms[i + 1].From else T;
            if (M.To != want)
                errors.fail("{s}: `{s}.migrations[{d}]` returns {s}, but the next step expects {s}; each migration must return the next one's input, and the last must return {s}", .{
                    who, name, i, reflect.shortTypeName(M.To), reflect.shortTypeName(want), name,
                });
        }
    }
}

pub const Error = error{ OutOfMemory, ValidationFailed, MigrationFailed };

/// Migrate `json`, stored under fingerprint `from`, to `T`. Null when no step
/// of the chain starts at `from`.
pub fn run(comptime T: type, arena: Allocator, from: u64, json: []const u8, issue: *parse.Issue, failed: *anyerror) Error!?T {
    if (comptime !has(T)) return null;
    const ms = T.migrations;
    inline for (0..ms.len) |i| {
        if (ms[i].from_fingerprint == from) {
            const old = try parse.parse(ms[i].From, arena, json, issue);
            return try carry(T, i, arena, old, failed);
        }
    }
    return null;
}

fn carry(comptime T: type, comptime i: usize, arena: Allocator, v: T.migrations[i].From, failed: *anyerror) Error!T {
    const ms = T.migrations;
    const next = ms[i].step(arena, v) catch |err| {
        if (err == error.OutOfMemory) return error.OutOfMemory;
        failed.* = err;
        return error.MigrationFailed;
    };
    if (i + 1 == ms.len) return next;
    return carry(T, i + 1, arena, next, failed);
}

test "a chain migrates from any listed version" {
    const V1 = struct { name: []const u8 = "" };
    const V2 = struct { first: []const u8 = "", last: []const u8 = "" };
    const V3 = struct {
        first: []const u8 = "",
        last: []const u8 = "",
        vip: bool = false,
        pub const migrations = .{ migrate(V1, v1), migrate(V2, v2) };
        fn v1(_: Allocator, o: V1) !V2 {
            const sp = std.mem.indexOfScalar(u8, o.name, ' ') orelse return .{ .first = o.name };
            return .{ .first = o.name[0..sp], .last = o.name[sp + 1 ..] };
        }
        fn v2(_: Allocator, o: V2) !@This() {
            return .{ .first = o.first, .last = o.last };
        }
    };
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    var issue: parse.Issue = .{};
    var failed: anyerror = error.Unknown;
    const a = (try run(V3, arena.allocator(), comptime fingerprint.of(V1), "{\"name\":\"Ada Lovelace\"}", &issue, &failed)).?;
    try std.testing.expectEqualStrings("Lovelace", a.last);
    const b = (try run(V3, arena.allocator(), comptime fingerprint.of(V2), "{\"first\":\"Grace\",\"last\":\"Hopper\"}", &issue, &failed)).?;
    try std.testing.expectEqualStrings("Grace", b.first);
    try std.testing.expect(try run(V3, arena.allocator(), 1234, "{}", &issue, &failed) == null);
    comptime check(V3, "test");
}
