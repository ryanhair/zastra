//! expect: `execute`'s second parameter is u8; expected Input
const std = @import("std");
const z = @import("zastra");
const Ctx = struct { db: u32 = 0 };
const Bad = struct {
    pub const description = "d";
    pub const Input = struct { x: u8 };
    pub const Output = struct { y: u8 };
    pub fn execute(_: *z.ToolCtx(Ctx), in: u8) !Output { return .{ .y = in }; }
};
const A = z.Agent(Ctx, .{ .name = "a", .model = "anthropic/claude-sonnet-5-5", .tools = .{Bad} });
comptime { _ = A.prefix; }
