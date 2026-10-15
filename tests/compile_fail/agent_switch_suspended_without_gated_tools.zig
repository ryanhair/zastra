//! expect: no field named 'suspended'
const std = @import("std");
const z = @import("zastra");
const Ctx = struct {};
const Plain = z.Agent(Ctx, .{ .name = "plain", .model = "anthropic/claude-sonnet-5-5" });
const App = z.App(.{ .ctx = Ctx, .agents = .{Plain} });
fn f(rt: *App.Runtime, arena: std.mem.Allocator) void {
    // Agents without gated tools return the plain result struct (D22).
    const r = rt.agent(Plain).generate(arena, "hi", .{}) catch return;
    _ = r.suspended;
}
comptime {
    _ = &f;
}
