//! expect: zastra: agent input must be a string, a z.Message, or a slice of z.Message; got comptime_int
const std = @import("std");
const z = @import("zastra");
const Ctx = struct {};
const A = z.Agent(Ctx, .{ .name = "a", .model = "anthropic/claude-sonnet-5-5" });
const App = z.App(.{ .ctx = Ctx, .agents = .{A} });
export fn f(rt: *App.Runtime) void {
    _ = rt.agent(A).generate(std.heap.page_allocator, 5, .{}) catch {};
}
