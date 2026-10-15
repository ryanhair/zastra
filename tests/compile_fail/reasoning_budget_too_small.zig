//! expect: zastra: agent 'a': `.reasoning = .{ .budget = 512 }` is below the minimum of 1024 tokens
const z = @import("zastra");
const Ctx = struct {};
const A = z.Agent(Ctx, .{ .name = "a", .model = "anthropic/claude-sonnet-4-6", .reasoning = .{ .budget = 512 } });
comptime { _ = A; }
