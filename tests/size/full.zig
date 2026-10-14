//! Size variant 3 (PLAN.md §5.6): everything: both providers, SQLite, MCP,
//! working memory, tracing, a suspendable workflow with a parallel group.
const std = @import("std");
const z = @import("zastra");

const Ctx = struct {};
const Ticket = struct { subject: []const u8, body: []const u8 };
const Triage = struct { category: enum { refund, other }, summary: []const u8 };
const Notes = struct { name: ?[]const u8 = null };
const Lookup = struct {
    pub const description = "Look up an order.";
    pub const Input = struct { id: []const u8 };
    pub const Output = struct { total_cents: u32 };
    pub const ModelErrors = error{NotFound};
    pub const error_messages = .{ .NotFound = "No such order." };
    pub fn execute(_: *z.ToolCtx(Ctx), in: Input) !Output {
        if (in.id.len == 0) return error.NotFound;
        return .{ .total_cents = 100 };
    }
};
const Support = z.Agent(Ctx, .{
    .name = "support",
    .model = "anthropic/claude-sonnet-5-5",
    .tools = .{ Lookup, z.mcp.tools(.docs, .{}) },
    .memory = .{ .history = .{ .last_messages = 20 }, .working = Notes },
});
const TriageAgent = z.Agent(Ctx, .{ .name = "triage", .model = "openai/gpt-5-mini", .output = Triage });
const Classify = z.step.agent(TriageAgent, .{ .input = Ticket, .prompt = "{subject}: {body}" });
const Approve = struct {
    pub const Input = Triage;
    pub const Output = Triage;
    pub const Suspend = struct { why: []const u8 };
    pub const Resume = struct { ok: bool };
    pub fn run(w: *z.StepCtx(Ctx, @This()), in: Input) !z.Suspendable(@This()) {
        if (in.category == .refund and w.resumed == null) return .{ .suspended = .{ .why = "refund" } };
        return .{ .done = in };
    }
};
const Len = struct {
    pub const Input = Triage;
    pub const Output = usize;
    pub fn run(w: *z.StepCtx(Ctx, @This()), in: Input) !Output {
        _ = w;
        return in.summary.len;
    }
};
const Same = struct {
    pub const Input = Triage;
    pub const Output = Triage;
    pub fn run(w: *z.StepCtx(Ctx, @This()), in: Input) !Output {
        _ = w;
        return in;
    }
};
const W = z.Workflow(Ctx, "flow", Ticket)
    .then(Classify)
    .then(Approve)
    .then(z.step.parallel(.{ .len = Len, .same = Same }))
    .commit();
const App = z.App(.{
    .ctx = Ctx,
    .agents = .{ Support, TriageAgent },
    .workflows = .{W},
    .storage = .sqlite,
    .mcp = .{ .docs = z.mcp.stdio(&.{"docs-mcp-server"}) },
});

pub fn main(init: std.process.Init) !void {
    var ctx: Ctx = .{};
    var rt = try App.init(init.gpa, init.io, .{ .ctx = &ctx, .env = init.environ_map, .tracing = z.trace.jsonl(std.Io.File.stderr()) });
    defer rt.deinit();
    var arena: std.heap.ArenaAllocator = .init(init.gpa);
    defer arena.deinit();
    var s = try rt.agent(Support).stream(arena.allocator(), "hi", .{ .thread = "t", .resource = "r" });
    defer s.deinit();
    while (try s.next()) |e| switch (e) {
        .text_delta => |d| std.debug.print("{s}", .{d}),
        else => {},
    };
    const r = try rt.workflow(W).start(arena.allocator(), .{ .subject = "s", .body = "b" }, .{});
    switch (r) {
        .completed => |o| std.debug.print("{d}\n", .{o.len}),
        .suspended => |p| _ = try rt.workflow(W).resumeStep(Approve, arena.allocator(), p.run_id, .{ .ok = true }),
        .failed => |f| std.debug.print("{s}\n", .{f.message}),
    }
}
