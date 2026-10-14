//! expect: zastra: h.script(a, ...): Other is not a tool of agent 'a'
const std = @import("std");
const z = @import("zastra");
const Ctx = struct {};
const Mine = struct {
    pub const description = "d";
    pub const Input = struct { x: u8 };
    pub const Output = struct { y: u8 };
    pub fn execute(_: *z.ToolCtx(Ctx), in: Input) !Output {
        return .{ .y = in.x };
    }
};
const Other = struct {
    pub const description = "d";
    pub const Input = struct { x: u8 };
    pub const Output = struct { y: u8 };
    pub fn execute(_: *z.ToolCtx(Ctx), in: Input) !Output {
        return .{ .y = in.x };
    }
};
const A = z.Agent(Ctx, .{ .name = "a", .model = "anthropic/claude-sonnet-5-5", .tools = .{Mine} });
export fn f() void {
    const s = z.testing.Step(A).tool(Other, .{ .x = 1 });
    _ = s;
}
