//! expect: h.scriptModel("anthropic/claude-haiku-4-5", ...): rt.model has no tools or output, so `.tool(...)` can't be scripted
const std = @import("std");
const z = @import("zastra");
const Ctx = struct {};
const Lookup = struct {
    pub const description = "Look something up.";
    pub const Input = struct { q: []const u8 };
    pub const Output = struct { a: []const u8 };
    pub fn execute(_: *z.ToolCtx(Ctx), _: Input) !Output {
        return .{ .a = "" };
    }
};
const A = z.Agent(Ctx, .{ .name = "a", .model = "anthropic/claude-haiku-4-5", .tools = .{Lookup} });
const App = z.App(.{ .ctx = Ctx, .agents = .{A} });
export fn f() void {
    var h: *z.testing.Harness(App) = undefined;
    _ = &h;
    h.scriptModel("anthropic/claude-haiku-4-5", &.{.tool(Lookup, .{ .q = "x" })});
}
