//! expect: zastra: z.testing.fuzzTool(Refund): the tool declares `.writes`, and fuzzing calls it hundreds of times; point its context at test doubles and pass `.allow_effects = .{ .writes }`
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
    z.testing.fuzzTool(App, Refund, .{ .ctx = &ctx }) catch {};
}
