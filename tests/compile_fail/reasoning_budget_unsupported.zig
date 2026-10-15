//! expect: zastra: agent 'a': model "anthropic/claude-sonnet-5-5" doesn't take a reasoning budget; use `.reasoning = .on` (it decides how much to think; `.effort` steers it)
const z = @import("zastra");
const Ctx = struct {};
const A = z.Agent(Ctx, .{ .name = "a", .model = "anthropic/claude-sonnet-5-5", .reasoning = .{ .budget = 4_000 } });
comptime { _ = A; }
