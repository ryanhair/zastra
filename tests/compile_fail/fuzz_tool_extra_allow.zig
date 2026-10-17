//! expect: zastra: z.testing.fuzzTool(Refund): `.allow_effects` names `.network`, but the tool doesn't declare it; remove it
const std = @import("std");
const z = @import("zastra");
const Ctx = struct {};
const Refund = struct {
    pub const description = "d";
    pub const Input = struct { cents: u32 };
    pub const Output = struct { ok: bool };
    pub const effects = .{ .reads, .writes };
    pub fn execute(_: *z.ToolCtx(Ctx), _: Input) !Output {
        return .{ .ok = true };
    }
};
const A = z.Agent(Ctx, .{ .name = "a", .model = "anthropic/claude-sonnet-4-6", .tools = .{Refund}, .allow = .{ .reads, .writes } });
const App = z.App(.{ .ctx = Ctx, .agents = .{A} });
export fn run() void {
    var ctx: Ctx = .{};
    z.testing.fuzzTool(App, Refund, .{ .ctx = &ctx, .allow_effects = .{ .writes, .network } }) catch {};
}
