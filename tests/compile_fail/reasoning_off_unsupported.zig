//! expect: zastra: agent 'a': model "anthropic/claude-opus-5-5" can't turn reasoning off; remove `.reasoning = .off` (use `.effort = .low` to make it cheaper and faster)
const z = @import("zastra");
const Ctx = struct {};
const A = z.Agent(Ctx, .{ .name = "a", .model = "anthropic/claude-opus-5-5", .reasoning = .off });
comptime { _ = A; }
