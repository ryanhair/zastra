//! expect: `Notes.migrations[0]` returns V2, but the next step expects Notes; each migration must return the next one's input, and the last must return Notes
const std = @import("std");
const z = @import("zastra");
const Ctx = struct {};
const V1 = struct { name: ?[]const u8 = null };
const V2 = struct { first: ?[]const u8 = null };
const Notes = struct {
    first: ?[]const u8 = null,
    vip: bool = false,
    pub const migrations = .{z.migrate(V1, fromV1)};
    fn fromV1(_: std.mem.Allocator, o: V1) !V2 {
        return .{ .first = o.name };
    }
};
const A = z.Agent(Ctx, .{ .name = "a", .model = "anthropic/claude-sonnet-5-5", .memory = .{ .working = Notes } });
comptime { _ = A.prefix; }
