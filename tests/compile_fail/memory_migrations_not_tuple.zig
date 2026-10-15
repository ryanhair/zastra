//! expect: `Notes.migrations` must be a tuple of `z.migrate(Old, f)`
const std = @import("std");
const z = @import("zastra");
const Ctx = struct {};
const V1 = struct { name: ?[]const u8 = null };
const Notes = struct {
    first: ?[]const u8 = null,
    pub const migrations = z.migrate(V1, fromV1);
    fn fromV1(_: std.mem.Allocator, o: V1) !Notes {
        return .{ .first = o.name };
    }
};
const A = z.Agent(Ctx, .{ .name = "a", .model = "anthropic/claude-sonnet-5-5", .memory = .{ .working = Notes } });
comptime { _ = A.prefix; }
