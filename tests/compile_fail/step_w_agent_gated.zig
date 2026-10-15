//! expect: zastra: step 'draft_reply' calls `w.agent(support).generate`, but agent 'support' has approval-gated tool 'issue_refund'. Use `w.agent(support).run(...)` and declare `pub const Suspend = z.Approvals(support);` and `pub const Resume = z.Decisions(support);` on the step
const std = @import("std");
const z = @import("zastra");
const Ctx = struct {};
const A = struct { x: u8 };
const B = struct { y: u8 };
const ToA = struct {
    pub const Input = A;
    pub const Output = A;
    pub fn run(w: *z.StepCtx(Ctx, @This()), in: Input) !Output { _ = w; return in; }
};
const ToB = struct {
    pub const Input = A;
    pub const Output = B;
    pub fn run(w: *z.StepCtx(Ctx, @This()), in: Input) !Output { _ = w; return .{ .y = in.x }; }
};
const FromB = struct {
    pub const Input = B;
    pub const Output = B;
    pub fn run(w: *z.StepCtx(Ctx, @This()), in: Input) !Output { _ = w; return in; }
};
fn yes(_: A) bool { return true; }
const IssueRefund = struct {
    pub const description = "d";
    pub const Input = struct { x: u8 };
    pub const Output = struct { y: u8 };
    pub const effects = .{.spends_money};
    pub fn execute(_: *z.ToolCtx(Ctx), in: Input) !Output { return .{ .y = in.x }; }
};
const Support = z.Agent(Ctx, .{ .name = "support", .model = "anthropic/claude-sonnet-5-5", .tools = .{IssueRefund} });
const DraftReply = struct {
    pub const Input = A;
    pub const Output = A;
    pub fn run(w: *z.StepCtx(Ctx, @This()), in: Input) !Output {
        _ = try w.agent(Support).generate("x", .{});
        return in;
    }
};
const W = z.Workflow(Ctx, "w", A).then(DraftReply).commit();
const App = z.App(.{ .ctx = Ctx, .agents = .{Support}, .workflows = .{W} });
export fn f(rt: *App.Runtime) void { _ = rt.workflow(W).start(std.heap.page_allocator, .{ .x = 1 }, .{}) catch {}; }
