//! expect: z.migrate(V1, f): `f` must be a function `fn (std.mem.Allocator, V1) !Next`
const std = @import("std");
const z = @import("zastra");
const Ctx = struct {};
const V1 = struct { name: ?[]const u8 = null };
const Notes = struct {
    first: ?[]const u8 = null,
    pub const migrations = .{z.migrate(V1, 42)};
};
const A = z.Agent(Ctx, .{ .name = "a", .model = "anthropic/claude-sonnet-5-5", .memory = .{ .working = Notes } });
comptime { _ = A.prefix; }
