//! expect: no field named 'order' in struct
const std = @import("std");
const z = @import("zastra");
const Ctx = struct {};
const Lookup = struct {
    pub const description = "d";
    pub const Input = struct { order_id: []const u8 };
    pub const Output = struct { y: u8 };
    pub fn execute(_: *z.ToolCtx(Ctx), in: Input) !Output {
        _ = in;
        return .{ .y = 1 };
    }
};
const A = z.Agent(Ctx, .{ .name = "a", .model = "anthropic/claude-sonnet-5-5", .tools = .{Lookup} });
export fn f() void {
    const s = z.testing.Step(A).tool(Lookup, .{ .order = "x" });
    _ = s;
}
