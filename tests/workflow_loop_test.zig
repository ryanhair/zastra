//! `z.step.loop` (PLAN.md §18.3, D45, D46).

const std = @import("std");
const z = @import("zastra");
const t = std.testing;

const Db = struct {
    bumps: std.atomic.Value(u32) = .init(0),
    pings: std.atomic.Value(u32) = .init(0),
};
const Ctx = struct { db: *Db };

const Draft = struct { text: []const u8, score: u32 };

fn goodEnough(d: Draft) bool {
    return d.score >= 3;
}
fn never(_: Draft) bool {
    return false;
}

const Bump = struct {
    pub const Input = Draft;
    pub const Output = Draft;
    pub fn run(w: *z.StepCtx(Ctx, @This()), in: Input) !Output {
        _ = w.ctx.db.bumps.fetchAdd(1, .monotonic);
        return .{ .text = try w.fmt("{s}+", .{in.text}), .score = in.score + 1 };
    }
};

const Refine = z.step.loop(Bump, .{ .until = goodEnough, .max = 5 });
const Simple = z.Workflow(Ctx, "simple", Draft).then(Refine).commit();
const Limited = z.Workflow(Ctx, "limited", Draft).then(z.step.loop(Bump, .{ .until = never, .max = 2 })).commit();
const Finished = z.Workflow(Ctx, "finished", Draft).then(z.step.loop(Bump, .{ .until = never, .max = 2, .on_limit = .finish })).commit();

// ── an agent inside a loop ───────────────────────────────────────────────────

const Critic = z.Agent(Ctx, .{ .name = "critic", .model = "anthropic/claude-sonnet-4-6", .output = Draft });
const AgentLoop = z.Workflow(Ctx, "agent_loop", Draft)
    .then(z.step.loop(z.step.agent(Critic, .{ .input = Draft }), .{ .until = goodEnough, .max = 4 }))
    .commit();

// ── a gated agent inside a loop ──────────────────────────────────────────────

const Ping = struct {
    pub const description = "Ping the editor.";
    pub const Input = struct { note: []const u8 };
    pub const Output = struct { ok: bool };
    pub const needs_approval = true;
    pub fn execute(tc: *z.ToolCtx(Ctx), _: Input) !Output {
        _ = tc.ctx.db.pings.fetchAdd(1, .monotonic);
        return .{ .ok = true };
    }
};
const Editor = z.Agent(Ctx, .{ .name = "editor", .model = "anthropic/claude-sonnet-4-6", .tools = .{Ping}, .output = Draft });
const EditStep = z.step.agent(Editor, .{ .input = Draft });
const GatedLoop = z.Workflow(Ctx, "gated_loop", Draft)
    .then(z.step.loop(EditStep, .{ .until = goodEnough, .max = 5 }))
    .commit();

// ── a workflow body with a suspendable step, a parallel group and a nested loop

const Gate = struct {
    pub const Input = Draft;
    pub const Output = Draft;
    pub const Suspend = struct { score: u32 };
    pub const Resume = struct { ok: bool };
    pub fn run(w: *z.StepCtx(Ctx, @This()), in: Input) !z.Suspendable(@This()) {
        if (in.score == 5) {
            const r = w.resumed orelse return .{ .suspended = .{ .score = in.score } };
            if (!r.ok) return error.Rejected;
        }
        return .{ .done = in };
    }
};
const Left = struct {
    pub const Input = Draft;
    pub const Output = u32;
    pub fn run(_: *z.StepCtx(Ctx, @This()), in: Input) !Output {
        return in.score;
    }
};
const Right = struct {
    pub const Input = Draft;
    pub const Output = []const u8;
    pub fn run(_: *z.StepCtx(Ctx, @This()), in: Input) !Output {
        return in.text;
    }
};
const Join = struct {
    pub const Input = z.step.parallel(.{ .l = Left, .r = Right }).Output;
    pub const Output = Draft;
    pub fn run(_: *z.StepCtx(Ctx, @This()), in: Input) !Output {
        return .{ .text = in.r, .score = in.l };
    }
};
fn twice(d: Draft) bool {
    return d.text.len % 2 == 0;
}
const Body = z.Workflow(Ctx, "body", Draft)
    .then(Bump)
    .then(z.step.loop(Bump, .{ .until = twice, .max = 2, .on_limit = .finish, .name = "inner" }))
    .then(z.step.parallel(.{ .l = Left, .r = Right }))
    .then(Join)
    .then(Gate)
    .commit();
const Outer = z.Workflow(Ctx, "outer", Draft).then(z.step.loop(Body, .{ .until = atLeastSix, .max = 3 })).commit();
fn atLeastSix(d: Draft) bool {
    return d.score >= 6;
}

const App = z.App(.{ .ctx = Ctx, .agents = .{ Critic, Editor }, .workflows = .{ Simple, Limited, Finished, AgentLoop, GatedLoop, Outer, CrashLoop }, .storage = .sqlite });

const start: Draft = .{ .text = "d", .score = 0 };

test "a loop runs until `until` holds" {
    var db: Db = .{};
    var ctx: Ctx = .{ .db = &db };
    var h = try z.testing.harness(App, .{ .ctx = &ctx });
    defer h.deinit();
    const r = try h.workflow(Simple).start(start);
    try t.expectEqual(@as(u32, 3), r.completed.score);
    try t.expectEqualStrings("d+++", r.completed.text);
    try t.expectEqual(@as(u32, 3), db.bumps.load(.monotonic));
}

test "the iteration limit fails the run, or finishes with `.on_limit = .finish`" {
    var db: Db = .{};
    var ctx: Ctx = .{ .db = &db };
    var h = try z.testing.harness(App, .{ .ctx = &ctx });
    defer h.deinit();
    const f = try h.workflow(Limited).start(start);
    try t.expectEqual(error.LoopLimit, f.failed.err);
    try t.expectEqualStrings("loop_bump", f.failed.step);
    try t.expect(std.mem.indexOf(u8, f.failed.message, "limit of 2 iterations") != null);
    const r = try h.workflow(Finished).start(start);
    try t.expectEqual(@as(u32, 2), r.completed.score);
    try t.expectEqual(@as(u32, 4), db.bumps.load(.monotonic));
}

test "an agent step inside a loop" {
    var db: Db = .{};
    var ctx: Ctx = .{ .db = &db };
    var h = try z.testing.harness(App, .{ .ctx = &ctx });
    defer h.deinit();
    h.script(Critic, &.{
        .output(.{ .text = "better", .score = 2 }),
        .output(.{ .text = "best", .score = 5 }),
    });
    const r = try h.workflow(AgentLoop).start(start);
    try t.expectEqualStrings("best", r.completed.text);
    try t.expectEqual(@as(usize, 0), h.remaining(Critic));
    // The second iteration saw the first one's output.
    try t.expect(std.mem.indexOf(u8, h.requests()[1], "better") != null);
}

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

test "a gated agent suspends in iteration 2 and resumes after a restart" {
    var buf: [256]u8 = undefined;
    const path = try tmpDb(&buf, "loop-gated");
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
        h.script(Editor, &.{
            // Iteration 1 answers without a tool; iteration 2 asks to ping.
            .output(.{ .text = "first", .score = 1 }),
            .tool(Ping, .{ .note = "second" }),
        });
        const paused = try z.testing.expectSuspended(try h.workflow(GatedLoop).start(start), .editor);
        run_id = try std.fmt.bufPrint(&run_id_buf, "{s}", .{paused.run_id});
        req_id = try std.fmt.bufPrint(&req_id_buf, "{s}", .{paused.payload.requests[0].id});
        // Each iteration's agent call is its own saved run.
        const a = h.arena.allocator();
        const store = h.rt.state().storage.?;
        const first = (try store.loadRun(a, try std.fmt.allocPrint(a, "{s}/loop_editor.editor@0#0", .{run_id}))).?;
        try t.expectEqualStrings("completed", first.status);
        const second = (try store.loadRun(a, try std.fmt.allocPrint(a, "{s}/loop_editor.editor@1#0", .{run_id}))).?;
        try t.expectEqualStrings("suspended", second.status);
    }
    var h = try z.testing.harness(App, .{ .ctx = &ctx, .storage_path = path });
    defer h.deinit();
    h.script(Editor, &.{.output(.{ .text = "third", .score = 4 })});
    const r = try h.workflow(GatedLoop).resumeStep(z.step.agentOf(Editor), run_id, .{ .approve = &.{req_id} });
    // Iteration 2 continued its own run; iteration 1's result wasn't reused.
    try t.expectEqualStrings("third", r.completed.text);
    try t.expectEqual(@as(u32, 1), db.pings.load(.monotonic));
    try t.expectEqual(@as(usize, 0), h.remaining(Editor));
}

test "a workflow body: nested loop, parallel group, and a suspend mid-iteration" {
    var db: Db = .{};
    var ctx: Ctx = .{ .db = &db };
    var h = try z.testing.harness(App, .{ .ctx = &ctx });
    defer h.deinit();
    // Each outer iteration: Bump, then the inner loop bumps until the text
    // has even length (once here), then the parallel group and Join. Iteration
    // 1 ends at score 3; iteration 2 reaches the Gate at score 5 and suspends.
    const paused = try z.testing.expectSuspended(try h.workflow(Outer).start(start), .gate);
    try t.expectEqual(@as(u32, 5), paused.payload.score);
    try t.expectEqual(@as(u32, 5), db.bumps.load(.monotonic));
    // Resuming replays iteration 2 without re-running its finished steps,
    // then iteration 3 runs and ends the loop.
    const done = try h.workflow(Outer).resumeStep(Gate, paused.run_id, .{ .ok = true });
    try t.expectEqual(@as(u32, 7), done.completed.score);
    try t.expectEqualStrings("d+++++++", done.completed.text);
    try t.expectEqual(@as(u32, 7), db.bumps.load(.monotonic));
}

test "mermaid and fingerprint" {
    try t.expect(std.mem.indexOf(u8, Simple.mermaid, "subgraph loop_bump_sub [loop_bump]") != null);
    try t.expect(std.mem.indexOf(u8, Simple.mermaid, "loop_bump_bump -.->|repeat, max 5| loop_bump_start") != null);
    // `.max`, `.until` and `.on_limit` aren't part of the shape.
    const Other = z.Workflow(Ctx, "simple", Draft).then(z.step.loop(Bump, .{ .until = never, .max = 9, .on_limit = .finish })).commit();
    try t.expectEqual(Simple.fingerprint_value, Other.fingerprint_value);
    const Different = z.Workflow(Ctx, "simple", Draft).then(Bump).commit();
    try t.expect(Simple.fingerprint_value != Different.fingerprint_value);
}

// ── a crash between the body's last save and the loop's progress save ───────

const Hold = struct {
    pub const Input = Draft;
    pub const Output = Draft;
    pub const Suspend = struct { score: u32 };
    pub const Resume = struct { ok: bool };
    pub fn run(w: *z.StepCtx(Ctx, @This()), in: Input) !z.Suspendable(@This()) {
        if (w.resumed == null) return .{ .suspended = .{ .score = in.score } };
        return .{ .done = in };
    }
};
const HoldBody = z.Workflow(Ctx, "hold_body", Draft).then(Bump).then(Hold).commit();
fn atLeastTwo(d: Draft) bool {
    return d.score >= 2;
}
const CrashLoop = z.Workflow(Ctx, "crash_loop", Draft).then(z.step.loop(HoldBody, .{ .until = atLeastTwo, .max = 5 })).commit();

test "a crash after the body's last save neither repeats the body nor runs an extra iteration" {
    var db: Db = .{};
    var ctx: Ctx = .{ .db = &db };
    var h = try z.testing.harness(App, .{ .ctx = &ctx });
    defer h.deinit();
    const a = h.arena.allocator();
    const store = h.rt.state().storage.?;
    // Iteration 0 bumps to score 1 and suspends at Hold.
    const paused = try z.testing.expectSuspended(try h.workflow(CrashLoop).start(start), .hold);
    try t.expectEqual(@as(u32, 1), db.bumps.load(.monotonic));
    // Rewrite the snapshot to what a crash right after Hold's save leaves:
    // every body step done, the loop's progress not yet advanced.
    var rec = (try store.loadRun(a, paused.run_id)).?;
    const bump_slot = "\"loop_hold_body.hold_body.bump\":{\"value\":{\"text\":\"d+\",\"score\":1}}";
    try t.expect(std.mem.indexOf(u8, rec.state_json, bump_slot) != null);
    rec.state_json = try std.mem.replaceOwned(u8, a, rec.state_json, bump_slot, bump_slot ++ ",\"loop_hold_body.hold_body.hold\":{\"value\":{\"text\":\"d+\",\"score\":1}}");
    try store.saveRun(rec);
    // The replay takes iteration 0 from the snapshot, then iteration 1 runs
    // once: one more bump, not two, and the loop ends on `until`.
    const r = try h.workflow(CrashLoop).resumeStep(Hold, paused.run_id, .{ .ok = true });
    const r2 = switch (r) {
        .suspended => |s| try h.workflow(CrashLoop).resumeStep(Hold, s.run_id, .{ .ok = true }),
        else => r,
    };
    try t.expectEqual(@as(u32, 2), r2.completed.score);
    try t.expectEqualStrings("d++", r2.completed.text);
    try t.expectEqual(@as(u32, 2), db.bumps.load(.monotonic));
}
