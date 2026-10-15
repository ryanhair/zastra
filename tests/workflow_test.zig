//! Workflows end to end (PLAN.md §5.7, §5.8, §6.6).

const std = @import("std");
const z = @import("zastra");
const t = std.testing;

const Db = struct {
    refunds: std.atomic.Value(u32) = .init(0),
    flaky_calls: std.atomic.Value(u32) = .init(0),
};
const Ctx = struct { db: *Db, auto_refund_limit_cents: u32 = 50_00 };

const Order = struct { id: []const u8, total_cents: u32 };
const Ticket = struct { customer_id: []const u8, subject: []const u8, body: []const u8 };
const Triage = struct {
    category: enum { refund, shipping, other },
    urgency: u8,
    order_id: ?[]const u8 = null,
    summary: []const u8,
};
const Resolution = struct { kind: enum { refunded, answered, escalated }, message: []const u8 };

const TriageAgent = z.Agent(Ctx, .{ .name = "triage", .model = "openai/gpt-5-mini", .output = Triage });
const ReplyWriter = z.Agent(Ctx, .{ .name = "reply_writer", .model = "anthropic/claude-sonnet-5-5" });

const Classify = z.step.agent(TriageAgent, .{ .input = Ticket, .prompt = "Subject: {subject}\n\n{body}" });

const FetchOrder = struct {
    pub const Input = Triage;
    pub const Output = ?Order;
    pub fn run(w: *z.StepCtx(Ctx, @This()), in: Input) !Output {
        _ = w;
        const id = in.order_id orelse return null;
        return .{ .id = id, .total_cents = 90_00 };
    }
};

const ApproveRefund = struct {
    pub const Input = ?Order;
    pub const Output = Resolution;
    pub const Suspend = struct { order_id: []const u8, amount_cents: u32 };
    pub const Resume = struct { approved: bool, approver: []const u8 };
    pub const needs = .{ .triage = z.initial(Triage) };

    pub fn run(w: *z.StepCtx(Ctx, @This()), in: Input) !z.Suspendable(@This()) {
        const order = in orelse return .{ .done = .{ .kind = .escalated, .message = "No order." } };
        if (order.total_cents > w.ctx.auto_refund_limit_cents) {
            const decision = w.resumed orelse return .{ .suspended = .{ .order_id = order.id, .amount_cents = order.total_cents } };
            if (!decision.approved) return .{ .done = .{ .kind = .escalated, .message = try w.fmt("Declined by {s}.", .{decision.approver}) } };
        }
        _ = w.ctx.db.refunds.fetchAdd(1, .monotonic);
        return .{ .done = .{ .kind = .refunded, .message = try w.fmt("Refund for {s} ({s})", .{ order.id, w.needs.triage.summary }) } };
    }
};

const FaqHit = struct { question: []const u8, answer: []const u8 };
const SearchFaq = struct {
    pub const Input = Triage;
    pub const Output = []const FaqHit;
    pub fn run(w: *z.StepCtx(Ctx, @This()), in: Input) !Output {
        _ = in;
        const hits = try w.arena.alloc(FaqHit, 1);
        hits[0] = .{ .question = "Hours?", .answer = "9-5" };
        return hits;
    }
};

const Gather = z.step.parallel(.{ .order = FetchOrder, .faq = SearchFaq });

const DraftReply = struct {
    pub const Input = Gather.Output;
    pub const Output = Resolution;
    pub const needs = .{ .ticket = Classify };
    pub fn run(w: *z.StepCtx(Ctx, @This()), in: Input) !Output {
        const reply = try w.agent(ReplyWriter).generate(
            try w.fmt("Ticket summary: {s}\nRelevant FAQ: {f}\nOrder: {f}", .{ w.needs.ticket.summary, z.fmt.json(in.faq), z.fmt.json(in.order) }),
            .{},
        );
        return .{ .kind = .answered, .message = reply.text };
    }
};

const NotifyCustomer = struct {
    pub const Input = Resolution;
    pub const Output = struct { sent: bool, to: []const u8 };
    pub const needs = .{ .ticket = z.initial(Ticket) };
    pub fn run(w: *z.StepCtx(Ctx, @This()), in: Input) !Output {
        _ = in;
        return .{ .sent = true, .to = w.needs.ticket.customer_id };
    }
};

fn wantsRefund(tr: Triage) bool {
    return tr.category == .refund;
}

const RefundPath = z.Workflow(Ctx, "refund", Triage).then(FetchOrder).then(ApproveRefund).commit();
const AnswerPath = z.Workflow(Ctx, "answer", Triage).then(Gather).then(DraftReply).commit();

const HandleTicket = z.Workflow(Ctx, "handle_ticket", Ticket)
    .then(Classify)
    .branch(.{
        .{ wantsRefund, RefundPath },
        .{ z.otherwise, AnswerPath },
    })
    .then(NotifyCustomer)
    .commit();

const App = z.App(.{ .ctx = Ctx, .agents = .{ TriageAgent, ReplyWriter }, .workflows = .{HandleTicket} });

const ticket: Ticket = .{ .customer_id = "c-42", .subject = "Broken", .body = "Arrived cracked. ORD-1" };

test "derived types: Suspended, open workflows, agents" {
    // AnswerPath needs Classify from the enclosing workflow: it's open (D13).
    try t.expectEqual(@as(usize, 1), AnswerPath.open_needs.len);
    try t.expectEqual(@as(usize, 0), HandleTicket.open_needs.len);
    // Exactly one suspendable step, so a switch over Suspended is exhaustive.
    const s: HandleTicket.Suspended = .{ .approve_refund = .{ .order_id = "x", .amount_cents = 1 } };
    switch (s) {
        .approve_refund => |p| try t.expectEqual(@as(u32, 1), p.amount_cents),
    }
    // Agents reachable through z.step.agent (w.agent calls inside run bodies are not).
    try t.expectEqual(@as(usize, 1), HandleTicket.agents.len);
}

test "large refunds pause for approval and resume" {
    var db: Db = .{};
    var ctx: Ctx = .{ .db = &db };
    var h = try z.testing.harness(App, .{ .ctx = &ctx });
    defer h.deinit();
    h.script(TriageAgent, &.{.output(.{ .category = .refund, .urgency = 3, .order_id = "ORD-1", .summary = "Broken item" })});

    const first = try h.workflow(HandleTicket).start(ticket);
    const paused = try z.testing.expectSuspended(first, .approve_refund);
    try t.expectEqual(@as(u32, 90_00), paused.payload.amount_cents);
    try t.expectEqual(@as(u32, 0), db.refunds.load(.monotonic));

    const done = try h.workflow(HandleTicket).resumeStep(ApproveRefund, paused.run_id, .{ .approved = true, .approver = "ryan" });
    try t.expect(done.completed.sent);
    try t.expectEqualStrings("c-42", done.completed.to);
    try t.expectEqual(@as(u32, 1), db.refunds.load(.monotonic));
    // The classify agent ran once: the resumed run replays from the snapshot.
    try t.expectEqual(@as(usize, 0), h.remaining(TriageAgent));
    // The prompt template rendered the ticket.
    try t.expect(std.mem.indexOf(u8, h.requests()[0], "Subject: Broken\\n\\nArrived cracked. ORD-1") != null);

    // Resuming again: the run is completed now.
    try t.expectError(error.NotSuspendedAtStep, h.workflow(HandleTicket).resumeStep(ApproveRefund, paused.run_id, .{ .approved = true, .approver = "ryan" }));
}

test "declined approval" {
    var db: Db = .{};
    var ctx: Ctx = .{ .db = &db };
    var h = try z.testing.harness(App, .{ .ctx = &ctx });
    defer h.deinit();
    h.script(TriageAgent, &.{.output(.{ .category = .refund, .urgency = 3, .order_id = "ORD-1", .summary = "Broken" })});
    const first = try h.workflow(HandleTicket).start(ticket);
    const paused = try z.testing.expectSuspended(first, .approve_refund);
    const done = try h.workflow(HandleTicket).resumeStep(ApproveRefund, paused.run_id, .{ .approved = false, .approver = "sam" });
    try t.expect(done == .completed);
    try t.expectEqual(@as(u32, 0), db.refunds.load(.monotonic));
}

test "otherwise branch: parallel gather, nested needs, agent inside a step" {
    var db: Db = .{};
    var ctx: Ctx = .{ .db = &db };
    var h = try z.testing.harness(App, .{ .ctx = &ctx });
    defer h.deinit();
    h.script(TriageAgent, &.{.output(.{ .category = .shipping, .urgency = 2, .order_id = "ORD-7", .summary = "Where is it" })});
    h.script(ReplyWriter, &.{.text("It ships tomorrow.")});
    const r = try h.workflow(HandleTicket).start(ticket);
    try t.expect(r.completed.sent);
    // DraftReply saw Classify's output (from the enclosing workflow) and the parallel results.
    const reply_req = h.requests()[1];
    try t.expect(std.mem.indexOf(u8, reply_req, "Ticket summary: Where is it") != null);
    try t.expect(std.mem.indexOf(u8, reply_req, "ORD-7") != null);
    try t.expect(std.mem.indexOf(u8, reply_req, "9-5") != null);
}

test "fingerprint: shape changes change it; a mismatch is detected on resume" {
    const A = z.Workflow(Ctx, "w", Triage).then(FetchOrder).commit();
    const B = z.Workflow(Ctx, "w", Triage).then(FetchOrder).commit();
    const C = z.Workflow(Ctx, "w", Triage).then(SearchFaq).commit();
    try t.expectEqual(A.fingerprint_value, B.fingerprint_value);
    try t.expect(A.fingerprint_value != C.fingerprint_value);

    var db: Db = .{};
    var ctx: Ctx = .{ .db = &db };
    var h = try z.testing.harness(App, .{ .ctx = &ctx });
    defer h.deinit();
    h.script(TriageAgent, &.{.output(.{ .category = .refund, .urgency = 3, .order_id = "ORD-1", .summary = "x" })});
    const first = try h.workflow(HandleTicket).start(ticket);
    const paused = try z.testing.expectSuspended(first, .approve_refund);
    // Simulate a deploy with a different workflow shape: rewrite the stored fingerprint.
    const store = h.rt.state().storage.?;
    var arena: std.heap.ArenaAllocator = .init(t.allocator);
    defer arena.deinit();
    var rec = (try store.loadRun(arena.allocator(), paused.run_id)).?;
    rec.fingerprint ^= 1;
    try store.saveRun(rec);
    try t.expectError(error.SnapshotIncompatible, h.workflow(HandleTicket).resumeStep(ApproveRefund, paused.run_id, .{ .approved = true, .approver = "r" }));
    try t.expect(std.mem.indexOf(u8, h.rt.lastDiagnostic(), "doesn't match the current workflow") != null);
}

const Flaky = struct {
    pub const Input = Triage;
    pub const Output = Triage;
    pub const retry = z.Retry{ .attempts = 3, .backoff = .{ .fixed = 1 } };
    pub fn run(w: *z.StepCtx(Ctx, @This()), in: Input) !Output {
        const n = w.ctx.db.flaky_calls.fetchAdd(1, .monotonic);
        if (n < 2) return error.Transient;
        return in;
    }
};
const AlwaysFails = struct {
    pub const Input = Triage;
    pub const Output = Triage;
    pub fn run(w: *z.StepCtx(Ctx, @This()), in: Input) !Output {
        _ = w;
        _ = in;
        return error.Boom;
    }
};
const RetryWf = z.Workflow(Ctx, "retry", Triage).then(Flaky).commit();
const FailWf = z.Workflow(Ctx, "fail", Triage).then(AlwaysFails).commit();
const App2 = z.App(.{ .ctx = Ctx, .workflows = .{ RetryWf, FailWf } });

test "retries, and failures as values" {
    var db: Db = .{};
    var ctx: Ctx = .{ .db = &db };
    var h = try z.testing.harness(App2, .{ .ctx = &ctx });
    defer h.deinit();
    const tr: Triage = .{ .category = .other, .urgency = 1, .summary = "s" };
    const r = try h.workflow(RetryWf).start(tr);
    try t.expect(r == .completed);
    try t.expectEqual(@as(u32, 3), db.flaky_calls.load(.monotonic));
    const f = try h.workflow(FailWf).start(tr);
    try t.expectEqualStrings("always_fails", f.failed.step);
    try t.expectEqual(error.Boom, f.failed.err);
}

const SlowOk = struct {
    pub const Input = Triage;
    pub const Output = Triage;
    pub fn run(w: *z.StepCtx(Ctx, @This()), in: Input) !Output {
        try w.io.sleep(.fromSeconds(5), .awake);
        _ = w.ctx.db.flaky_calls.fetchAdd(1, .monotonic);
        return in;
    }
};
const SlowFail = struct {
    pub const Input = Triage;
    pub const Output = Triage;
    pub fn run(w: *z.StepCtx(Ctx, @This()), in: Input) !Output {
        _ = in;
        try w.io.sleep(.fromMilliseconds(300), .awake);
        return error.Late;
    }
};
const FastFail = struct {
    pub const Input = Triage;
    pub const Output = Triage;
    pub fn run(w: *z.StepCtx(Ctx, @This()), in: Input) !Output {
        _ = w;
        _ = in;
        return error.Boom;
    }
};
const FastFail2 = struct {
    pub const Input = Triage;
    pub const Output = Triage;
    pub fn run(w: *z.StepCtx(Ctx, @This()), in: Input) !Output {
        _ = w;
        _ = in;
        return error.Bang;
    }
};
const CancelWf = z.Workflow(Ctx, "cancel_slow", Triage).then(z.step.parallel(.{ .fast = FastFail, .slow = SlowOk })).commit();
const EarliestWf = z.Workflow(Ctx, "earliest", Triage).then(z.step.parallel(.{ .late = SlowFail, .fast = FastFail })).commit();
const BothWf = z.Workflow(Ctx, "both_fail", Triage).then(z.step.parallel(.{ .a = FastFail, .b = FastFail2 })).commit();
const App3 = z.App(.{ .ctx = Ctx, .workflows = .{ CancelWf, EarliestWf, BothWf } });

fn expectParallelFailures(inline_branches: bool) !void {
    var db: Db = .{};
    var ctx: Ctx = .{ .db = &db };
    var h = try z.testing.harness(App3, .{ .ctx = &ctx });
    defer h.deinit();
    const tr: Triage = .{ .category = .other, .urgency = 1, .summary = "s" };
    const io = t.io;

    // A failing branch cancels a slow sibling instead of waiting for it.
    const t0 = std.Io.Clock.awake.now(io);
    const r = try h.workflow(CancelWf).start(tr);
    const elapsed_ms = t0.durationTo(std.Io.Clock.awake.now(io)).toMilliseconds();
    try t.expectEqual(error.Boom, r.failed.err);
    try t.expect(std.mem.endsWith(u8, r.failed.step, ".fast"));
    try t.expect(elapsed_ms < 1000);
    try t.expectEqual(@as(u32, 0), db.flaky_calls.load(.monotonic));

    // The earliest failure in time is reported, not the first declared.
    if (!inline_branches) {
        const e = try h.workflow(EarliestWf).start(tr);
        try t.expectEqual(error.Boom, e.failed.err);
        try t.expect(std.mem.endsWith(u8, e.failed.step, ".fast"));
    }

    // Two branches failing at once: exactly one is reported.
    for (0..20) |_| {
        const b = try h.workflow(BothWf).start(tr);
        try t.expect(b.failed.err == error.Boom or b.failed.err == error.Bang);
        try t.expect(std.mem.indexOf(u8, b.failed.message, @errorName(b.failed.err)) != null);
    }
}

test "parallel: the first failure cancels siblings (D47)" {
    try expectParallelFailures(false);
}

test "parallel: branches run inline when concurrency is unavailable" {
    const saved = t.io_instance.concurrent_limit;
    t.io_instance.concurrent_limit = .nothing;
    defer t.io_instance.concurrent_limit = saved;
    try expectParallelFailures(true);
}

test "mermaid" {
    try t.expect(std.mem.indexOf(u8, HandleTicket.mermaid, "flowchart TD") != null);
    try t.expect(std.mem.indexOf(u8, HandleTicket.mermaid, "approve_refund") != null);
}

const SqlApp = z.App(.{ .ctx = Ctx, .agents = .{ TriageAgent, ReplyWriter }, .workflows = .{HandleTicket}, .storage = .sqlite });

test "sqlite: a suspended run survives a restart and resumes" {
    var db: Db = .{};
    var ctx: Ctx = .{ .db = &db };
    var tmp = t.tmpDir(.{});
    defer tmp.cleanup();
    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const n = try tmp.dir.realPath(t.io, &path_buf);
    const path = try std.fmt.allocPrint(t.allocator, "{s}/wf.sqlite", .{path_buf[0..n]});
    defer t.allocator.free(path);

    var run_id_buf: [64]u8 = undefined;
    var run_id: []const u8 = "";
    {
        var h = try z.testing.harness(SqlApp, .{ .ctx = &ctx });
        defer h.deinit();
        // The harness uses :memory:; use a real runtime on a file instead.
        var replay: z.provider.http.Replay = .init(t.allocator, &.{});
        defer replay.deinit();
        replay.responder = h.replay.responder;
        var rt = try SqlApp.init(t.allocator, t.io, .{ .ctx = &ctx, .storage_path = path, .testing = .{ .replay = &replay } });
        defer rt.deinit();
        h.script(TriageAgent, &.{.output(.{ .category = .refund, .urgency = 3, .order_id = "ORD-9", .summary = "x" })});
        var arena: std.heap.ArenaAllocator = .init(t.allocator);
        defer arena.deinit();
        const r = try rt.workflow(HandleTicket).start(arena.allocator(), ticket, .{});
        const p = try z.testing.expectSuspended(r, .approve_refund);
        @memcpy(run_id_buf[0..p.run_id.len], p.run_id);
        run_id = run_id_buf[0..p.run_id.len];
    }
    // "Days later", a new process.
    {
        var replay: z.provider.http.Replay = .init(t.allocator, &.{});
        defer replay.deinit();
        var rt = try SqlApp.init(t.allocator, t.io, .{ .ctx = &ctx, .storage_path = path, .testing = .{ .replay = &replay } });
        defer rt.deinit();
        var arena: std.heap.ArenaAllocator = .init(t.allocator);
        defer arena.deinit();
        const done = try rt.workflow(HandleTicket).resumeStep(ApproveRefund, arena.allocator(), run_id, .{ .approved = true, .approver = "ryan" });
        try t.expect(done.completed.sent);
        // No model calls were needed to resume.
        try t.expectEqual(@as(usize, 0), replay.requests.items.len);
    }
    try t.expectEqual(@as(u32, 1), db.refunds.load(.monotonic));
}

const PauseV1 = struct {
    pub const Input = Triage;
    pub const Output = Triage;
    pub const Suspend = struct { why: []const u8 };
    pub const Resume = struct { ok: bool };
    pub fn run(w: *z.StepCtx(Ctx, @This()), in: Input) !z.Suspendable(@This()) {
        if (w.resumed == null) return .{ .suspended = .{ .why = "check" } };
        return .{ .done = in };
    }
};
const Extra = struct {
    pub const Input = Triage;
    pub const Output = Triage;
    pub fn run(w: *z.StepCtx(Ctx, @This()), in: Input) !Output {
        _ = w;
        return in;
    }
};
const V1 = z.Workflow(Ctx, "versioned", Triage).then(PauseV1).commit();
fn migrateV1(arena: std.mem.Allocator, old: []const u8) anyerror![]const u8 {
    _ = arena;
    return old; // the new step slot simply starts empty
}
const V2 = z.Workflow(Ctx, "versioned", Triage).then(Extra).then(PauseV1).migration(V1.fingerprint_value, migrateV1).commit();
const AppV1 = z.App(.{ .ctx = Ctx, .workflows = .{V1} });
const AppV2 = z.App(.{ .ctx = Ctx, .workflows = .{V2} });

test "migrations: an old snapshot resumes on a new workflow shape" {
    var db: Db = .{};
    var ctx: Ctx = .{ .db = &db };
    try t.expect(V1.fingerprint_value != V2.fingerprint_value);

    var h1 = try z.testing.harness(AppV1, .{ .ctx = &ctx });
    defer h1.deinit();
    const r = try h1.workflow(V1).start(.{ .category = .other, .urgency = 1, .summary = "s" });
    const p = try z.testing.expectSuspended(r, .pause_v1);
    // Move the stored run into a V2 runtime sharing the same storage contents.
    var arena: std.heap.ArenaAllocator = .init(t.allocator);
    defer arena.deinit();
    const rec = (try h1.rt.state().storage.?.loadRun(arena.allocator(), p.run_id)).?;
    var h2 = try z.testing.harness(AppV2, .{ .ctx = &ctx });
    defer h2.deinit();
    try h2.rt.state().storage.?.saveRun(rec);
    const done = try h2.workflow(V2).resumeStep(PauseV1, p.run_id, .{ .ok = true });
    try t.expect(done == .completed);
}
