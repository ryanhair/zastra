//! expect: zastra: agent 'a': `.show_reasoning = true` with `.reasoning = .off`; remove one of them
const z = @import("zastra");
const Ctx = struct {};
const A = z.Agent(Ctx, .{ .name = "a", .model = "anthropic/claude-sonnet-4-6", .reasoning = .off, .show_reasoning = true });
comptime { _ = A; }
