//! expect: zastra: agent 'plain' has no approval-gated tools, so its runs never suspend; there is nothing to resume or cancel
const std = @import("std");
const z = @import("zastra");
const Ctx = struct {};
const Plain = z.Agent(Ctx, .{ .name = "plain", .model = "anthropic/claude-sonnet-5-5" });
const App = z.App(.{ .ctx = Ctx, .agents = .{Plain} });
fn f(rt: *App.Runtime, arena: std.mem.Allocator) void {
    _ = rt.agent(Plain).resumeRun(arena, "run_1", &.{}) catch {};
}
comptime {
    _ = &f;
}
