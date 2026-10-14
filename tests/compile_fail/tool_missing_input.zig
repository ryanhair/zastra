//! expect: zastra: Bad is not a tool: missing `pub const Input`
const std = @import("std");
const z = @import("zastra");
const Ctx = struct { db: u32 = 0 };
const Bad = struct {
    pub const description = "d";
    pub const Output = struct { y: u8 };
    pub fn execute(_: *z.ToolCtx(Ctx), in: u8) !Output { return .{ .y = in }; }
};
const A = z.Agent(Ctx, .{ .name = "a", .model = "anthropic/claude-sonnet-5-5", .tools = .{Bad} });
comptime { _ = A.prefix; }
