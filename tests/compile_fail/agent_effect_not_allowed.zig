//! expect: zastra: agent 'a' doesn't allow effect `.spends_money`, but tool 'Bad' declares it
const std = @import("std");
const z = @import("zastra");
const Ctx = struct { db: u32 = 0 };
const Bad = struct {
    pub const description = "d";
    pub const Input = struct { x: u8 };
    pub const Output = struct { y: u8 };
    pub fn execute(_: *z.ToolCtx(Ctx), in: Input) !Output { return .{ .y = in.x }; }
    pub const effects = .{ .reads, .spends_money };
};
const A = z.Agent(Ctx, .{ .name = "a", .model = "anthropic/claude-sonnet-5-5", .tools = .{Bad}, .allow = .{.reads} });
comptime { _ = A.prefix; }
