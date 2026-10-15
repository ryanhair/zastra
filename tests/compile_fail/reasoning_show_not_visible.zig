//! expect: zastra: agent 'a': model "openai/gpt-5-mini" doesn't return readable reasoning through Chat Completions (summaries arrive with the Responses API, PLAN.md §17.2); remove `.show_reasoning`
const z = @import("zastra");
const Ctx = struct {};
const A = z.Agent(Ctx, .{ .name = "a", .model = "openai/gpt-5-mini", .show_reasoning = true });
comptime { _ = A; }
