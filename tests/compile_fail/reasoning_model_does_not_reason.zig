//! expect: zastra: agent 'a': model "openai/gpt-4.1" doesn't reason; remove `.reasoning` and `.show_reasoning`
const z = @import("zastra");
const Ctx = struct {};
const A = z.Agent(Ctx, .{ .name = "a", .model = "openai/gpt-4.1", .reasoning = .on });
comptime { _ = A; }
