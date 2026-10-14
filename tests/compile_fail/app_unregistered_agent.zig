//! expect: rt.agent(...): agent 'b' isn't registered in z.App
const std = @import("std");
const z = @import("zastra");
const Ctx = struct { db: u32 = 0 };
const A = z.Agent(Ctx, .{ .name = "a", .model = "anthropic/claude-sonnet-5-5" });
const B = z.Agent(Ctx, .{ .name = "b", .model = "anthropic/claude-sonnet-5-5" });
const App = z.App(.{ .ctx = Ctx, .agents = .{A} });
export fn f(rt: *App.Runtime) void { _ = rt.agent(B); }
