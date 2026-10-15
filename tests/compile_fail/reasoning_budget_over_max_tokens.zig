//! expect: zastra: agent 'a': `.reasoning = .{ .budget = 8000 }` must be less than `.max_tokens` (8000); the budget counts toward it
const z = @import("zastra");
const Ctx = struct {};
const A = z.Agent(Ctx, .{ .name = "a", .model = "anthropic/claude-sonnet-4-6", .reasoning = .{ .budget = 8000 }, .max_tokens = 8000 });
comptime { _ = A; }
