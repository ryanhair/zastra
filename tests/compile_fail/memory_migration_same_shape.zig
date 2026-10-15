//! expect: `Notes.migrations[0]` migrates from Old, which has the same shape as Notes; a value of that shape already loads as-is
const std = @import("std");
const z = @import("zastra");
const Ctx = struct {};
const Old = struct { name: ?[]const u8 = null };
const Notes = struct {
    name: ?[]const u8 = null,
    pub const migrations = .{z.migrate(Old, fromOld)};
    fn fromOld(_: std.mem.Allocator, o: Old) !Notes {
        return .{ .name = o.name };
    }
};
const A = z.Agent(Ctx, .{ .name = "a", .model = "anthropic/claude-sonnet-5-5", .memory = .{ .working = Notes } });
comptime { _ = A.prefix; }
