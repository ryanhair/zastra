//! expect: tool 'Bad' requires `ctx.http: *u32`, but the App's Ctx (Ctx) has no field `http`
const std = @import("std");
const z = @import("zastra");
const Ctx = struct { db: u32 = 0 };
const Bad = struct {
    pub const description = "d";
    pub const Input = struct { x: u8 };
    pub const Output = struct { y: u8 };
    pub const Requires = struct { http: *u32 };
    pub fn execute(t: anytype, in: Input) !Output { _ = t; return .{ .y = in.x }; }
};
const A = z.Agent(Ctx, .{ .name = "a", .model = "anthropic/claude-sonnet-5-5", .tools = .{Bad} });
comptime { _ = A.prefix; }
