//! expect: agent 'a' was declared with context
const std = @import("std");
const z = @import("zastra");
const Ctx = struct { db: u32 = 0 };
const Other = struct {};
const A = z.Agent(Other, .{ .name = "a", .model = "anthropic/claude-sonnet-5-5" });
const App = z.App(.{ .ctx = Ctx, .agents = .{A} });
comptime { _ = App.required_env; }
