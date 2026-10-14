//! Size variant 2 (PLAN.md §5.6): both providers, SQLite storage, memory.
const std = @import("std");
const z = @import("zastra");

const Ctx = struct {};
const Out = struct { label: []const u8, score: u8 };
const A = z.Agent(Ctx, .{ .name = "a", .model = "anthropic/claude-haiku-5-5", .memory = .{ .history = .{ .last_messages = 10 } } });
const B = z.Agent(Ctx, .{ .name = "b", .model = "openai/gpt-5-mini", .output = Out });
const App = z.App(.{ .ctx = Ctx, .agents = .{ A, B }, .storage = .sqlite });

pub fn main(init: std.process.Init) !void {
    var ctx: Ctx = .{};
    var rt = try App.init(init.gpa, init.io, .{ .ctx = &ctx, .env = init.environ_map });
    defer rt.deinit();
    var arena: std.heap.ArenaAllocator = .init(init.gpa);
    defer arena.deinit();
    const r = try rt.agent(A).generate(arena.allocator(), "hi", .{ .thread = "t" });
    const o = try rt.agent(B).generate(arena.allocator(), r.text, .{});
    std.debug.print("{s} {d}\n", .{ o.output.label, o.output.score });
}
