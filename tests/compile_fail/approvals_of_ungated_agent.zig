//! expect: zastra: z.Approvals(plain): agent 'plain' has no approval-gated tools, so it never needs approvals
const z = @import("zastra");
const Ctx = struct {};
const Plain = z.Agent(Ctx, .{ .name = "plain", .model = "anthropic/claude-sonnet-5-5" });
comptime { _ = z.Approvals(Plain); }
