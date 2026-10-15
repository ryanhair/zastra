//! expect: zastra: agent 'a': model "openai/gpt-5-mini" can't turn reasoning off; remove `.reasoning = .off` (use `.effort = .low` to make it cheaper and faster)
const z = @import("zastra");
const Ctx = struct {};
const A = z.Agent(Ctx, .{ .name = "a", .model = "openai/gpt-5-mini", .reasoning = .off });
comptime { _ = A; }
