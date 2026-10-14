//! expect: two agents are named 'a'
const std = @import("std");
const z = @import("zastra");
const Ctx = struct { db: u32 = 0 };
const A = z.Agent(Ctx, .{ .name = "a", .model = "anthropic/claude-sonnet-5-5" });
const B = z.Agent(Ctx, .{ .name = "a", .model = "openai/gpt-5-mini" });
const App = z.App(.{ .ctx = Ctx, .agents = .{ A, B } });
comptime { _ = App.required_env; }
