//! expect: zastra: agent 'a': model "anthropic/claude-sonnet-5" can only turn reasoning off at effort `high` or below; got `.effort = .max`
const z = @import("zastra");
const Ctx = struct {};
const A = z.Agent(Ctx, .{ .name = "a", .model = "anthropic/claude-sonnet-5", .reasoning = .off, .effort = .max });
comptime { _ = A; }
