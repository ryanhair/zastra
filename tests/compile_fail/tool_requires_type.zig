//! expect: tool 'Bad' requires `ctx.db: u64`, but the App's Ctx has `db: u32`
const std = @import("std");
const z = @import("zastra");
const Ctx = struct { db: u32 = 0 };
const Bad = struct {
    pub const description = "d";
    pub const Input = struct { x: u8 };
    pub const Output = struct { y: u8 };
    pub const Requires = struct { db: u64 };
    pub fn execute(t: anytype, in: Input) !Output { _ = t; return .{ .y = in.x }; }
};
const A = z.Agent(Ctx, .{ .name = "a", .model = "anthropic/claude-sonnet-5-5", .tools = .{Bad} });
comptime { _ = A.prefix; }
