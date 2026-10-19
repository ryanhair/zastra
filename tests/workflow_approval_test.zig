//! Approval-gated agents inside workflows (PLAN.md §17.4, D34).

const std = @import("std");
const z = @import("zastra");
const t = std.testing;

const Db = struct { refunds: std.atomic.Value(u32) = .init(0) };
const Ctx = struct { db: *Db };

const Claim = struct { order_id: []const u8, cents: u32 };
const Resolution = struct { refunded: bool, note: []const u8 };

const IssueRefund = struct {
    pub const description = "Refund an order.";
    pub const Input = struct { order_id: []const u8, amount_cents: u32 };
    pub const Output = struct { refund_id: []const u8 };
    pub fn needsApproval(_: *z.ToolCtx(Ctx), in: Input) bool {
        return in.amount_cents > 50_00;
    }
    pub fn execute(tc: *z.ToolCtx(Ctx), in: Input) !Output {
        _ = in;
        _ = tc.ctx.db.refunds.fetchAdd(1, .monotonic);
        return .{ .refund_id = "R-1" };
    }
};

const Refunder = z.Agent(Ctx, .{
    .name = "refunder",
    .model = "anthropic/claude-sonnet-4-6",
    .instructions = "Refund claims.",
    .tools = .{IssueRefund},
    .output = Resolution,
});

/// A gated agent as a step: the workflow pauses for its approvals.
const RefundStep = z.step.agent(Refunder, .{ .input = Claim, .prompt = "Refund {cents} cents on {order_id}." });

const Notify = struct {
    pub const Input = Resolution;
    pub const Output = struct { sent: bool };
    pub fn run(_: *z.StepCtx(Ctx, @This()), in: Input) !Output {
        return .{ .sent = in.refunded };
    }
};

const Flow = z.Workflow(Ctx, "refund_flow", Claim).then(RefundStep).then(Notify).commit();

/// A custom step making two gated agent calls, with no resume branch.
const TwoRefunds = struct {
    pub const Input = Claim;
    pub const Output = u32;
    pub const Suspend = z.Approvals(Refunder);
    pub const Resume = z.Decisions(Refunder);

    pub fn run(w: *z.StepCtx(Ctx, @This()), in: Input) !z.Suspendable(@This()) {
        var refunded: u32 = 0;
        for ([_][]const u8{ "first", "second" }) |which| {
            switch (try w.agent(Refunder).run(try w.fmt("Refund the {s} half of {s}.", .{ which, in.order_id }), .{})) {
                .done => |d| if (d.output.refunded) {
                    refunded += 1;
                },
                .suspended => |a| return .{ .suspended = a },
            }
        }
        return .{ .done = refunded };
    }
};
const Twice = z.Workflow(Ctx, "twice", Claim).then(TwoRefunds).commit();

const App = z.App(.{ .ctx = Ctx, .agents = .{Refunder}, .workflows = .{ Flow, Twice }, .storage = .sqlite });

fn tmpDb(buf: []u8, name: []const u8) ![]const u8 {
    std.Io.Dir.cwd().createDirPath(t.io, ".zig-cache/tmp") catch {};
    return std.fmt.bufPrint(buf, ".zig-cache/tmp/zastra-{s}-{d}.sqlite", .{ name, std.Io.Clock.real.now(t.io).nanoseconds });
}

fn cleanup(path: []const u8) void {
    var buf: [512]u8 = undefined;
    for ([_][]const u8{ "", "-wal", "-shm" }) |sfx| {
        const p = std.fmt.bufPrint(&buf, "{s}{s}", .{ path, sfx }) catch continue;
        std.Io.Dir.cwd().deleteFile(t.io, p) catch {};
    }
}

const done_output: Resolution = .{ .refunded = true, .note = "Refunded." };

test "a gated agent step suspends the workflow; restart; resume with decisions" {
    var buf: [256]u8 = undefined;
    const path = try tmpDb(&buf, "wf-agent");
    defer cleanup(path);
    var db: Db = .{};
    var ctx: Ctx = .{ .db = &db };
    var ids: [2][64]u8 = undefined;
    var run_id: []const u8 = "";
    var req_id: []const u8 = "";
    {
        var h = try z.testing.harness(App, .{ .ctx = &ctx, .storage_path = path });
        defer h.deinit();
        h.script(Refunder, &.{.tool(IssueRefund, .{ .order_id = "ORD-1", .amount_cents = 90_00 })});
        const first = try h.workflow(Flow).start(.{ .order_id = "ORD-1", .cents = 90_00 });
        const paused = try z.testing.expectSuspended(first, .refunder);
        try t.expectEqual(@as(usize, 1), paused.payload.requests.len);
        switch (paused.payload.requests[0].call) {
            .issue_refund => |in| try t.expectEqual(@as(u32, 90_00), in.amount_cents),
        }
        run_id = try std.fmt.bufPrint(&ids[0], "{s}", .{paused.run_id});
        req_id = try std.fmt.bufPrint(&ids[1], "{s}", .{paused.payload.requests[0].id});
        try t.expectEqual(@as(u32, 0), db.refunds.load(.monotonic));
    }
    var h = try z.testing.harness(App, .{ .ctx = &ctx, .storage_path = path });
    defer h.deinit();
    h.script(Refunder, &.{.output(done_output)});
    // Nothing decided: still suspended, same request.
    const again = try z.testing.expectSuspended(try h.workflow(Flow).resumeStep(z.step.agentOf(Refunder), run_id, .{}), .refunder);
    try t.expectEqualStrings(req_id, again.payload.requests[0].id);
    const done = try h.workflow(Flow).resumeStep(z.step.agentOf(Refunder), run_id, .{ .approve = &.{req_id} });
    try t.expect(done.completed.sent);
    try t.expectEqual(@as(u32, 1), db.refunds.load(.monotonic));
    // The workflow run is done; resuming it again is refused.
    try t.expectError(error.NotSuspendedAtStep, h.workflow(Flow).resumeStep(RefundStep, run_id, .{ .approve = &.{req_id} }));
}

test "a denied approval reaches the model; the step finishes" {
    var db: Db = .{};
    var ctx: Ctx = .{ .db = &db };
    var h = try z.testing.harness(App, .{ .ctx = &ctx });
    defer h.deinit();
    h.script(Refunder, &.{
        .tool(IssueRefund, .{ .order_id = "ORD-1", .amount_cents = 90_00 }),
        .output(.{ .refunded = false, .note = "Declined." }),
    });
    const paused = try z.testing.expectSuspended(try h.workflow(Flow).start(.{ .order_id = "ORD-1", .cents = 90_00 }), .refunder);
    const done = try h.workflow(Flow).resumeStep(RefundStep, paused.run_id, .{ .deny = &.{.{ .id = paused.payload.requests[0].id, .reason = "too much" }} });
    try t.expect(!done.completed.sent);
    try t.expectEqual(@as(u32, 0), db.refunds.load(.monotonic));
    try t.expect(std.mem.indexOf(u8, h.requests()[1], "The user denied this tool call: too much") != null);
}

test "a custom step with two gated agent calls replays without repeating the first" {
    var db: Db = .{};
    var ctx: Ctx = .{ .db = &db };
    var h = try z.testing.harness(App, .{ .ctx = &ctx });
    defer h.deinit();
    h.script(Refunder, &.{.tool(IssueRefund, .{ .order_id = "ORD-1", .amount_cents = 60_00 })});
    const p1 = try z.testing.expectSuspended(try h.workflow(Twice).start(.{ .order_id = "ORD-1", .cents = 120_00 }), .two_refunds);

    // Approving the first call finishes it; the second call then suspends.
    h.script(Refunder, &.{ .output(done_output), .tool(IssueRefund, .{ .order_id = "ORD-1", .amount_cents = 60_00 }) });
    const p2 = try z.testing.expectSuspended(try h.workflow(Twice).resumeStep(TwoRefunds, p1.run_id, .{ .approve = &.{p1.payload.requests[0].id} }), .two_refunds);
    try t.expect(!std.mem.eql(u8, p1.payload.requests[0].id, p2.payload.requests[0].id));
    try t.expectEqual(@as(u32, 1), db.refunds.load(.monotonic));

    // On this replay the first call returns its saved result without a
    // model request; only the second one continues.
    h.script(Refunder, &.{.output(done_output)});
    const done = try h.workflow(Twice).resumeStep(TwoRefunds, p1.run_id, .{ .approve = &.{p2.payload.requests[0].id} });
    try t.expectEqual(@as(u32, 2), done.completed);
    try t.expectEqual(@as(u32, 2), db.refunds.load(.monotonic));
    try t.expectEqual(@as(usize, 0), h.remaining(Refunder));
    // Two agent runs, saved under the workflow run.
    const runs = try h.runs().list(.{ .kind = .agent, .owner_id = "refunder" });
    try t.expectEqual(@as(usize, 2), runs.len);
    for (runs) |r| try t.expect(std.mem.startsWith(u8, r.run_id, p1.run_id));
}

test "a workflow run being resumed elsewhere is RunBusy" {
    var db: Db = .{};
    var ctx: Ctx = .{ .db = &db };
    var h = try z.testing.harness(App, .{ .ctx = &ctx });
    defer h.deinit();
    h.script(Refunder, &.{.tool(IssueRefund, .{ .order_id = "ORD-1", .amount_cents = 90_00 })});
    const paused = try z.testing.expectSuspended(try h.workflow(Flow).start(.{ .order_id = "ORD-1", .cents = 90_00 }), .refunder);
    try h.claimRun(paused.run_id);
    try t.expectError(error.RunBusy, h.workflow(Flow).resumeStep(RefundStep, paused.run_id, .{ .approve = &.{paused.payload.requests[0].id} }));
    try t.expectEqual(@as(u32, 0), db.refunds.load(.monotonic));
}

test "the gated agent's version is part of the workflow fingerprint" {
    const Refunder2 = z.Agent(Ctx, .{ .name = "refunder", .model = "anthropic/claude-sonnet-4-6", .instructions = "Refund claims carefully.", .tools = .{IssueRefund}, .output = Resolution });
    const Flow2 = z.Workflow(Ctx, "refund_flow", Claim).then(z.step.agent(Refunder2, .{ .input = Claim, .prompt = "Refund {cents} cents on {order_id}." })).then(Notify).commit();
    try t.expect(Flow.fingerprint_value != Flow2.fingerprint_value);
    try t.expect(std.mem.indexOf(u8, Flow.mermaid, "refunder ⏸") != null);
}
