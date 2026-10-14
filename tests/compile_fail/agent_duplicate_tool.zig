//! expect: two tools are named 'bad'
const std = @import("std");
const z = @import("zastra");
const Ctx = struct { db: u32 = 0 };
const Bad = struct {
    pub const description = "d";
    pub const Input = struct { x: u8 };
    pub const Output = struct { y: u8 };
    pub fn execute(_: *z.ToolCtx(Ctx), in: Input) !Output { return .{ .y = in.x }; }
};
const Bad2 = struct {
    pub const description = "d";
    pub const Input = struct { x: u8 };
    pub const Output = struct { y: u8 };
    pub fn execute(_: *z.ToolCtx(Ctx), in: Input) !Output { return .{ .y = in.x }; }
    pub const name = "bad";
};
const A = z.Agent(Ctx, .{ .name = "a", .model = "anthropic/claude-sonnet-5-5", .tools = .{ Bad, Bad2 } });
comptime { _ = A.prefix; }
