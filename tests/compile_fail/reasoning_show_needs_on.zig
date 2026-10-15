//! expect: zastra: agent 'a': model "anthropic/claude-sonnet-4-6" doesn't reason unless asked; add `.reasoning = .on` to use `.show_reasoning`
const z = @import("zastra");
const Ctx = struct {};
const A = z.Agent(Ctx, .{ .name = "a", .model = "anthropic/claude-sonnet-4-6", .show_reasoning = true });
comptime { _ = A; }
