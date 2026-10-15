//! expect: zastra: agent 'a': model "openai/gpt-5.4-mini" doesn't reason unless asked; add `.reasoning = .on` to use `.show_reasoning`
const z = @import("zastra");
const Ctx = struct {};
const A = z.Agent(Ctx, .{ .name = "a", .model = "openai/gpt-5.4-mini", .show_reasoning = true });
comptime { _ = A; }
