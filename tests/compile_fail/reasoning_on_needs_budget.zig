//! expect: zastra: agent 'a': model "anthropic/claude-haiku-4-5" needs a reasoning budget; use `.reasoning = .{ .budget = 4_000 }` (tokens, less than `.max_tokens`)
const z = @import("zastra");
const Ctx = struct {};
const A = z.Agent(Ctx, .{ .name = "a", .model = "anthropic/claude-haiku-4-5", .reasoning = .on });
comptime { _ = A; }
