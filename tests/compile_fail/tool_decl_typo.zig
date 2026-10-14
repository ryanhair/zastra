//! expect: zastra: tool 'Bad' declares `needApproval`; did you mean `needsApproval`?
const std = @import("std");
const z = @import("zastra");
const Ctx = struct { db: u32 = 0 };
const Bad = struct {
    pub const description = "d";
    pub const Input = struct { x: u8 };
    pub const Output = struct { y: u8 };
    pub fn execute(_: *z.ToolCtx(Ctx), in: Input) !Output { return .{ .y = in.x }; }
    pub fn needApproval(_: *z.ToolCtx(Ctx), _: Input) bool { return true; }
};
const A = z.Agent(Ctx, .{ .name = "a", .model = "anthropic/claude-sonnet-5-5", .tools = .{Bad} });
comptime { _ = A.prefix; }
