//! Size variant 1 (PLAN.md §5.6): Anthropic only, memory storage, no MCP.
const std = @import("std");
const z = @import("zastra");

const Ctx = struct {};
const Echo = struct {
    pub const description = "Echo the input.";
    pub const Input = struct { text: []const u8 };
    pub const Output = struct { text: []const u8 };
    pub fn execute(_: *z.ToolCtx(Ctx), in: Input) !Output {
        return .{ .text = in.text };
    }
};
const A = z.Agent(Ctx, .{ .name = "a", .model = "anthropic/claude-haiku-5-5", .tools = .{Echo} });
const App = z.App(.{ .ctx = Ctx, .agents = .{A} });

pub fn main(init: std.process.Init) !void {
    var ctx: Ctx = .{};
    var rt = try App.init(init.gpa, init.io, .{ .ctx = &ctx, .env = init.environ_map });
    defer rt.deinit();
    var arena: std.heap.ArenaAllocator = .init(init.gpa);
    defer arena.deinit();
    const r = try rt.agent(A).generate(arena.allocator(), "hi", .{});
    std.debug.print("{s}\n", .{r.text});
}
