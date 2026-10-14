//! expect: doesn't support tool use, but the agent declares `.tools`
const std = @import("std");
const z = @import("zastra");
const Ctx = struct { db: u32 = 0 };
const Bad = struct {
    pub const description = "d";
    pub const Input = struct { x: u8 };
    pub const Output = struct { y: u8 };
    pub fn execute(_: *z.ToolCtx(Ctx), in: Input) !Output { return .{ .y = in.x }; }
};
const A = z.Agent(Ctx, .{ .name = "a", .model = z.custom(.{ .provider = .openai_compat, .id = "m", .base_url = "http://x", .supports = .{ .tools = false } }), .tools = .{Bad} });
comptime { _ = A.prefix; }
