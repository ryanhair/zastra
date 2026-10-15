//! expect: zastra: agent 'a': unknown `.reasoning = .of` (did you mean 'off'?); use `.default`, `.on`, `.off` or `.{ .budget = N }`
const z = @import("zastra");
const Ctx = struct {};
const A = z.Agent(Ctx, .{ .name = "a", .model = "anthropic/claude-sonnet-4-6", .reasoning = .of });
comptime { _ = A; }
