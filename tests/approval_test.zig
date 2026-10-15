//! Saved agent runs and approvals (PLAN.md §17.3, D31–D33).

const std = @import("std");
const z = @import("zastra");
const t = std.testing;

const Db = struct { refunds: std.atomic.Value(u32) = .init(0) };
const Ctx = struct { db: *Db };

const LookupOrder = struct {
    pub const description = "Look up an order by its ID.";
    pub const Input = struct { order_id: []const u8 };
    pub const Output = struct { id: []const u8, total_cents: u32 };
    pub fn execute(tc: *z.ToolCtx(Ctx), in: Input) !Output {
        return .{ .id = try tc.arena.dupe(u8, in.order_id), .total_cents = 90_00 };
    }
};

const IssueRefund = struct {
    pub const description = "Refund all or part of an order.";
    pub const Input = struct { order_id: []const u8, amount_cents: u32 };
    pub const Output = struct { refund_id: []const u8 };
    pub const needs_approval = true;
    pub fn execute(tc: *z.ToolCtx(Ctx), in: Input) !Output {
        _ = in;
        _ = tc.ctx.db.refunds.fetchAdd(1, .monotonic);
        return .{ .refund_id = "R-1" };
    }
};

const Notes = struct { name: ?[]const u8 = null };

const Refunder = z.Agent(Ctx, .{
    .name = "refunder",
    .model = "anthropic/claude-sonnet-4-6",
    .instructions = "You handle refunds.",
    .reasoning = .on,
    .tools = .{ LookupOrder, IssueRefund },
    .memory = .{ .history = .{ .last_messages = 20 }, .working = Notes },
});

/// The same agent after a deploy that changed a tool.
const IssueRefundV2 = struct {
    pub const name = "issue_refund";
    pub const description = "Refund all or part of an order, with a reason.";
    pub const Input = struct { order_id: []const u8, amount_cents: u32, reason: []const u8 };
    pub const Output = struct { refund_id: []const u8 };
    pub const needs_approval = true;
    pub fn execute(_: *z.ToolCtx(Ctx), _: Input) !Output {
        return .{ .refund_id = "R-2" };
    }
};
const RefunderV2 = z.Agent(Ctx, .{
    .name = "refunder",
    .model = "anthropic/claude-sonnet-4-6",
    .instructions = "You handle refunds.",
    .reasoning = .on,
    .tools = .{ LookupOrder, IssueRefundV2 },
    .memory = .{ .history = .{ .last_messages = 20 }, .working = Notes },
});

const Plain = z.Agent(Ctx, .{ .name = "plain", .model = "anthropic/claude-sonnet-4-6", .tools = .{LookupOrder} });

const App = z.App(.{ .ctx = Ctx, .agents = .{ Refunder, Plain }, .storage = .sqlite });
const AppV2 = z.App(.{ .ctx = Ctx, .agents = .{RefunderV2}, .storage = .sqlite });
const MemApp = z.App(.{ .ctx = Ctx, .agents = .{Refunder} });

fn tmpDb(buf: []u8, name: []const u8) ![]const u8 {
    const path = try std.fmt.bufPrint(buf, ".zig-cache/tmp/zastra-{s}-{d}.sqlite", .{ name, std.Io.Clock.real.now(t.io).nanoseconds });
    std.Io.Dir.cwd().createDirPath(t.io, ".zig-cache/tmp") catch {};
    return path;
}

fn cleanup(path: []const u8) void {
    var buf: [512]u8 = undefined;
    for ([_][]const u8{ "", "-wal", "-shm" }) |sfx| {
        const p = std.fmt.bufPrint(&buf, "{s}{s}", .{ path, sfx }) catch continue;
        std.Io.Dir.cwd().deleteFile(t.io, p) catch {};
    }
}

test "suspend, restart, resume: the run continues where it stopped" {
    var buf: [256]u8 = undefined;
    const path = try tmpDb(&buf, "restart");
    defer cleanup(path);
    var db: Db = .{};
    var ctx: Ctx = .{ .db = &db };
    var run_id_buf: [64]u8 = undefined;
    var req_id_buf: [64]u8 = undefined;
    var run_id: []const u8 = "";
    var req_id: []const u8 = "";
    {
        var h = try z.testing.harness(App, .{ .ctx = &ctx, .storage_path = path });
        defer h.deinit();
        h.script(Refunder, &.{
            .tool(LookupOrder, .{ .order_id = "ORD-1" }),
            .withReasoning("It's $90; refund it all.", .tool(IssueRefund, .{ .order_id = "ORD-1", .amount_cents = 90_00 })),
        });
        const r = try h.agent(Refunder).generate("Refund ORD-1", .{ .thread = "t1", .resource = "c1" });
        const s = r.suspended;
        try t.expectEqual(@as(usize, 1), s.requests.len);
        switch (s.requests[0].call) {
            .issue_refund => |in| try t.expectEqual(@as(u32, 90_00), in.amount_cents),
        }
        run_id = try std.fmt.bufPrint(&run_id_buf, "{s}", .{s.run_id});
        req_id = try std.fmt.bufPrint(&req_id_buf, "{s}", .{s.requests[0].id});
        try t.expectEqual(@as(u32, 0), db.refunds.load(.monotonic));
        // Nothing reaches history until the run finishes.
        const runs = try h.rt.state().storage.?.listRuns(h.arena.allocator(), .{ .kind = .agent, .status = "suspended" });
        try t.expectEqual(@as(usize, 1), runs.len);
        try t.expectEqualStrings("refunder", runs[0].owner_id);
    }
    // A new process with the same database.
    var h = try z.testing.harness(App, .{ .ctx = &ctx, .storage_path = path });
    defer h.deinit();
    h.script(Refunder, &.{.text("Refunded $90.")});
    const r = try h.agent(Refunder).resumeRun(run_id, &.{.{ .id = req_id, .decision = .approve }});
    try t.expectEqualStrings("Refunded $90.", r.completed.text);
    try t.expectEqual(@as(u32, 3), r.completed.steps);
    try t.expectEqual(@as(u32, 1), db.refunds.load(.monotonic));
    // The thinking block from before the restart went back with its signature,
    // followed by the tool result.
    const body = h.requests()[0];
    try t.expect(std.mem.indexOf(u8, body, "\"thinking\":\"It's $90; refund it all.\",\"signature\":\"sig_scripted_2\"") != null);
    try t.expect(std.mem.indexOf(u8, body, "{\\\"refund_id\\\":\\\"R-1\\\"}") != null);
    // History holds the whole run once; the run is recorded as completed.
    const hist = try h.rt.state().storage.?.loadHistory(h.arena.allocator(), "t1", 20);
    try t.expectEqual(@as(usize, 6), hist.len);
    const rec = (try h.rt.state().storage.?.loadRun(h.arena.allocator(), run_id)).?;
    try t.expectEqualStrings("completed", rec.status);
    // Resuming a finished run is an error, not a second execution.
    try t.expectError(error.NotSuspended, h.agent(Refunder).resumeRun(run_id, &.{.{ .id = req_id, .decision = .approve }}));
    try t.expectEqual(@as(u32, 1), db.refunds.load(.monotonic));
}

test "partial decisions, deny, unknown ids" {
    var db: Db = .{};
    var ctx: Ctx = .{ .db = &db };
    var h = try z.testing.harness(MemApp, .{ .ctx = &ctx });
    defer h.deinit();
    h.script(Refunder, &.{.tools(&.{
        .{ .issue_refund = .{ .order_id = "ORD-1", .amount_cents = 100 } },
        .{ .issue_refund = .{ .order_id = "ORD-2", .amount_cents = 200 } },
    })});
    const s = (try h.agent(Refunder).generate("Refund both", .{})).suspended;
    try t.expectEqual(@as(usize, 2), s.requests.len);

    // An unknown id changes nothing and lists what's pending.
    try t.expectError(error.UnknownApproval, h.agent(Refunder).resumeRun(s.run_id, &.{.{ .id = "nope", .decision = .approve }}));
    try t.expect(std.mem.indexOf(u8, h.rt.lastDiagnostic(), s.requests[0].id) != null);

    // Deciding one keeps the run suspended with the other.
    const r1 = try h.agent(Refunder).resumeRun(s.run_id, &.{.{ .id = s.requests[0].id, .decision = .approve }});
    try t.expectEqual(@as(usize, 1), r1.suspended.requests.len);
    try t.expectEqualStrings(s.requests[1].id, r1.suspended.requests[0].id);
    try t.expectEqual(@as(u32, 0), db.refunds.load(.monotonic));

    // Denying the second runs the first and reports the denial to the model.
    h.script(Refunder, &.{.text("Refunded ORD-1 only.")});
    const r2 = try h.agent(Refunder).resumeRun(s.run_id, &.{.{ .id = s.requests[1].id, .decision = .{ .deny = "over limit" } }});
    try t.expectEqualStrings("Refunded ORD-1 only.", r2.completed.text);
    try t.expectEqual(@as(u32, 1), db.refunds.load(.monotonic));
    try t.expect(std.mem.indexOf(u8, h.requests()[1], "The user denied this tool call: over limit") != null);
}

test "a run claimed by another resume is RunBusy; cancelRun" {
    var db: Db = .{};
    var ctx: Ctx = .{ .db = &db };
    var h = try z.testing.harness(MemApp, .{ .ctx = &ctx });
    defer h.deinit();
    h.script(Refunder, &.{
        .tool(IssueRefund, .{ .order_id = "ORD-1", .amount_cents = 100 }),
        .tool(IssueRefund, .{ .order_id = "ORD-2", .amount_cents = 100 }),
    });
    const a = (try h.agent(Refunder).generate("Refund", .{})).suspended;
    const store = h.rt.state().storage.?;
    // Another process got there first.
    try t.expect(try store.claimRun(a.run_id, "suspended", "running", 0));
    try t.expectError(error.RunBusy, h.agent(Refunder).resumeRun(a.run_id, &.{.{ .id = a.requests[0].id, .decision = .approve }}));
    try t.expectEqual(@as(u32, 0), db.refunds.load(.monotonic));

    const b = (try h.agent(Refunder).generate("Refund", .{})).suspended;
    try h.agent(Refunder).cancelRun(b.run_id);
    try t.expectError(error.NotSuspended, h.agent(Refunder).resumeRun(b.run_id, &.{.{ .id = b.requests[0].id, .decision = .approve }}));
    try t.expectError(error.NotSuspended, h.agent(Refunder).cancelRun(b.run_id));
    try t.expectError(error.RunNotFound, h.agent(Refunder).cancelRun("run_missing"));
}

test "a run saved by a different version of the agent is SnapshotIncompatible" {
    var buf: [256]u8 = undefined;
    const path = try tmpDb(&buf, "fingerprint");
    defer cleanup(path);
    var db: Db = .{};
    var ctx: Ctx = .{ .db = &db };
    var run_id_buf: [64]u8 = undefined;
    var run_id: []const u8 = "";
    var req_id_buf: [64]u8 = undefined;
    var req_id: []const u8 = "";
    {
        var h = try z.testing.harness(App, .{ .ctx = &ctx, .storage_path = path });
        defer h.deinit();
        h.script(Refunder, &.{.tool(IssueRefund, .{ .order_id = "ORD-1", .amount_cents = 100 })});
        const s = (try h.agent(Refunder).generate("Refund", .{})).suspended;
        run_id = try std.fmt.bufPrint(&run_id_buf, "{s}", .{s.run_id});
        req_id = try std.fmt.bufPrint(&req_id_buf, "{s}", .{s.requests[0].id});
    }
    var h = try z.testing.harness(AppV2, .{ .ctx = &ctx, .storage_path = path });
    defer h.deinit();
    try t.expectError(error.SnapshotIncompatible, h.agent(RefunderV2).resumeRun(run_id, &.{.{ .id = req_id, .decision = .approve }}));
    try t.expect(std.mem.indexOf(u8, h.rt.lastDiagnostic(), "tool 'issue_refund' changed") != null);
}

test "resumeStream shows pending approvals again; suspendRun from a live stream" {
    var db: Db = .{};
    var ctx: Ctx = .{ .db = &db };
    var h = try z.testing.harness(MemApp, .{ .ctx = &ctx });
    defer h.deinit();
    h.script(Refunder, &.{.tool(IssueRefund, .{ .order_id = "ORD-1", .amount_cents = 100 })});
    var s = try h.agent(Refunder).stream("Refund", .{});
    var req_id: []const u8 = "";
    while (s.next() catch |err| switch (err) {
        error.ApprovalPending => null,
        else => return err,
    }) |e| switch (e) {
        .approval_request => |req| req_id = req.id,
        else => {},
    };
    const susp = try s.suspendRun();
    s.deinit();
    try t.expectEqualStrings(req_id, susp.requests[0].id);

    // A UI reconnects: the request comes back as an event, then it decides.
    var s2 = try h.agent(Refunder).resumeStream(susp.run_id, &.{});
    defer s2.deinit();
    h.script(Refunder, &.{.text("Done.")});
    var seen = false;
    var text: std.ArrayList(u8) = .empty;
    defer text.deinit(t.allocator);
    while (true) {
        const e = s2.next() catch |err| switch (err) {
            error.ApprovalPending => {
                try s2.respond(req_id, .approve);
                continue;
            },
            else => return err,
        } orelse break;
        switch (e) {
            .approval_request => |req| {
                try t.expectEqualStrings(req_id, req.id);
                seen = true;
            },
            .text_delta => |d| try text.appendSlice(t.allocator, d),
            else => {},
        }
    }
    try t.expect(seen);
    try t.expectEqualStrings("Done.", text.items);
    try t.expectEqual(@as(u32, 1), db.refunds.load(.monotonic));
}

test "agents without gated tools keep the plain result" {
    const R = z.AgentHandle(Plain).Result;
    comptime std.debug.assert(@typeInfo(R) == .@"struct" and @hasField(R, "text"));
    const RR = z.AgentHandle(Refunder).Result;
    comptime std.debug.assert(@typeInfo(RR) == .@"union" and @hasField(RR, "suspended"));
}
