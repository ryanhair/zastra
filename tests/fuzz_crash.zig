//! Run as a child process by fuzz_tool_test.zig: a tool that panics on the
//! empty string, so fuzzTool's crash note can be checked.

const std = @import("std");
const z = @import("zastra");

const Ctx = struct {};

const Echo = struct {
    pub const description = "d";
    pub const Input = struct { text: []const u8 };
    pub const Output = struct { first: u8 };
    pub fn execute(_: *z.ToolCtx(Ctx), in: Input) !Output {
        return .{ .first = in.text[0] }; // index out of bounds on ""
    }
};

const Agent = z.Agent(Ctx, .{ .name = "a", .model = "anthropic/claude-sonnet-4-6", .tools = .{Echo} });
const App = z.App(.{ .ctx = Ctx, .agents = .{Agent} });

test "crash" {
    var ctx: Ctx = .{};
    try z.testing.fuzzTool(App, Echo, .{ .ctx = &ctx, .iterations = 300, .hostile = false });
}
