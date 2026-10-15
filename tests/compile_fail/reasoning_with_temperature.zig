//! expect: zastra: agent 'a': `.temperature` can't be combined with reasoning; remove one of them
const z = @import("zastra");
const Ctx = struct {};
const A = z.Agent(Ctx, .{ .name = "a", .model = "anthropic/claude-sonnet-4-6", .reasoning = .on, .temperature = 0.2 });
comptime { _ = A; }
