//! Workflow execution (PLAN.md §6.6): `rt.workflow(W).start(...)` and
//! `.resumeStep(Step, ...)`.
//!
//! Execution is comptime-unrolled over the graph. The run state (`W.State`)
//! is snapshotted to storage after every step; only state is stored, never
//! continuations. Resuming (or recovering) replays the graph from the top,
//! skipping steps whose outputs are already in the state, so a step runs at
//! least once (D16).

const std = @import("std");
const runtime = @import("../runtime.zig");
const step = @import("step.zig");
const wf_mod = @import("workflow.zig");
const json = @import("../schema/json.zig");
const parse = @import("../schema/parse.zig");
const trace = @import("../trace/trace.zig");
const storage = @import("../storage/storage.zig");
const Allocator = std.mem.Allocator;

pub const Error = error{
    OutOfMemory,
    /// The snapshot couldn't be written or read.
    StorageFailed,
    /// No run with that id.
    RunNotFound,
    /// The run belongs to a different workflow.
    WrongWorkflow,
    /// The run is not suspended at the step passed to `resumeStep`.
    NotSuspendedAtStep,
    /// The snapshot was taken with a different workflow shape and no
    /// migration covers it (PLAN.md §5.8). The diagnostic has both fingerprints.
    SnapshotIncompatible,
    /// The stored state didn't parse.
    CorruptSnapshot,
    /// Another resume claimed the run first (PLAN.md D32).
    RunBusy,
};

pub const StartOptions = struct {
    /// Working-memory scope for agents called from steps (D17).
    resource: ?[]const u8 = null,
    run_id: ?[]const u8 = null,
};

const Avail = struct { T: type, path: []const u8 };

fn join(comptime prefix: []const u8, comptime id: []const u8) []const u8 {
    return if (prefix.len == 0) id else prefix ++ "." ++ id;
}

fn pathOf(comptime avail: []const Avail, comptime R: type, comptime consumer: []const u8) []const u8 {
    comptime {
        var i = avail.len;
        while (i > 0) {
            i -= 1;
            if (avail[i].T == R) return avail[i].path;
        }
        @import("../meta/errors.zig").fail("step '{s}' needs '{s}', which doesn't run before it on every path", .{ consumer, step.idOf(R) });
    }
}

pub fn Handle(comptime W: type) type {
    return struct {
        const Self = @This();
        st: *runtime.State,

        pub const Result = W.Result;

        /// Start a run. Step failures come back as `.failed`; errors are for
        /// infrastructure problems (storage, memory).
        pub fn start(h: Self, arena: Allocator, input: W.Input, opts: StartOptions) Error!W.Result {
            const state = try arena.create(W.State);
            state.* = .{ .input = input };
            var x: Exec(W) = .{
                .st = h.st,
                .arena = arena,
                .state = state,
                .run_id = opts.run_id orelse try h.st.newId(arena, "wfrun"),
                .resource = opts.resource,
                .created_at = h.st.nowMs(),
            };
            return x.run();
        }

        /// Resume a run suspended at step `S` with its typed `Resume` value.
        /// For a `z.step.agent(A, ...)` step, `S` can be `z.step.agentOf(A)`.
        pub fn resumeStep(h: Self, comptime S_: type, arena: Allocator, run_id: []const u8, value: ResumeOf(S_)) Error!W.Result {
            const S = StepOf(S_);
            const store = h.st.storage orelse return error.StorageFailed;
            const rec = (store.loadRun(arena, run_id) catch return error.StorageFailed) orelse {
                h.st.diagPrint("workflow '{s}': no run '{s}'", .{ W.id, run_id });
                return error.RunNotFound;
            };
            if (rec.kind != .workflow or !std.mem.eql(u8, rec.owner_id, W.id)) {
                h.st.diagPrint("run '{s}' belongs to {t} '{s}', not workflow '{s}'", .{ run_id, rec.kind, rec.owner_id, W.id });
                return error.WrongWorkflow;
            }
            var state_json = rec.state_json;
            if (rec.fingerprint != W.fingerprint_value) {
                const mig = for (W.migrations) |m| {
                    if (m.from == rec.fingerprint) break m;
                } else {
                    h.st.diagPrint("workflow '{s}' run '{s}': snapshot fingerprint 0x{x:0>16} doesn't match the current workflow (0x{x:0>16}) and no migration covers it", .{ W.id, run_id, rec.fingerprint, W.fingerprint_value });
                    return error.SnapshotIncompatible;
                };
                state_json = mig.migrate(arena, state_json) catch {
                    h.st.diagPrint("workflow '{s}' run '{s}': migration from 0x{x:0>16} failed", .{ W.id, run_id, rec.fingerprint });
                    return error.SnapshotIncompatible;
                };
            }
            const at = rec.suspended_at orelse "";
            if (std.mem.eql(u8, rec.status, "running")) {
                h.st.diagPrint("workflow '{s}' run '{s}' is running (being resumed elsewhere)", .{ W.id, run_id });
                return error.RunBusy;
            }
            const ok = std.mem.eql(u8, rec.status, "suspended") and pathIsStep(S, at);
            if (!ok) {
                h.st.diagPrint("workflow '{s}' run '{s}' is {s}{s}{s}, not suspended at '{s}'", .{
                    W.id, run_id, rec.status, if (at.len > 0) " at " else "", at, comptime step.idOf(S),
                });
                return error.NotSuspendedAtStep;
            }
            var issue: parse.Issue = .{};
            const state = try arena.create(W.State);
            state.* = parse.parse(W.State, arena, state_json, &issue) catch |err| switch (err) {
                error.OutOfMemory => return error.OutOfMemory,
                error.ValidationFailed => {
                    h.st.diagPrint("workflow '{s}' run '{s}': stored state doesn't parse: {f}", .{ W.id, run_id, issue });
                    return error.CorruptSnapshot;
                },
            };
            state.resume_at = at;
            state.resume_json = try json.stringifyAlloc(arena, value);
            // Only one resume may run: claim the run before executing anything.
            const claimed = store.claimRun(run_id, "suspended", "running", h.st.nowMs()) catch return error.StorageFailed;
            if (!claimed) {
                h.st.diagPrint("workflow '{s}' run '{s}' is already being resumed", .{ W.id, run_id });
                return error.RunBusy;
            }
            var x: Exec(W) = .{
                .st = h.st,
                .arena = arena,
                .state = state,
                .run_id = try arena.dupe(u8, run_id),
                .resource = null,
                .created_at = rec.created_at,
            };
            return x.run();
        }

        pub fn ResumeOf(comptime S: type) type {
            return StepOf(S).Resume;
        }

        /// `S` itself, or the step `z.step.agentOf(A)` names.
        pub fn StepOf(comptime S: type) type {
            comptime {
                const errors = @import("../meta/errors.zig");
                if (@hasDecl(S, "zastra_agent_of")) {
                    const A = S.zastra_agent_of;
                    var found: ?type = null;
                    for (W.suspendable_steps) |T| if (@hasDecl(T, "zastra_agent_step") and T.zastra_agent_step == A) {
                        if (found != null) errors.fail("resumeStep(z.step.agentOf({s}), ...): workflow '{s}' has more than one step running agent '{s}'; pass the step type instead", .{ A.id, W.id, A.id });
                        found = T;
                    };
                    return found orelse errors.fail("resumeStep(z.step.agentOf({s}), ...): workflow '{s}' has no suspendable step running agent '{s}'", .{ A.id, W.id, A.id });
                }
                for (W.suspendable_steps) |T| if (T == S) return S;
                errors.fail("resumeStep({s}, ...): '{s}' is not a suspendable step of workflow '{s}'", .{ step.idOf(S), step.idOf(S), W.id });
            }
        }

        fn pathIsStep(comptime S: type, path: []const u8) bool {
            inline for (W.slots) |s| if (s.S == S and std.mem.eql(u8, s.path, path)) return true;
            return false;
        }
    };
}

fn Exec(comptime W: type) type {
    return struct {
        const X = @This();

        st: *runtime.State,
        arena: Allocator,
        state: *W.State,
        run_id: []const u8,
        resource: ?[]const u8,
        created_at: i64,
        trace_id: [16]u8 = undefined,
        run_span: trace.Span = undefined,
        suspended: ?W.Suspended = null,
        suspended_at: []const u8 = "",
        failed_step: []const u8 = "",
        failed_err: anyerror = error.Unknown,
        failed_msg: []const u8 = "",

        fn run(x: *X) Error!W.Result {
            x.trace_id = x.st.tracer.newId();
            x.run_span = x.st.tracer.begin(.workflow_run, W.id, x.trace_id, null);
            x.run_span.attr("workflow", W.id);
            x.run_span.attr("run_id", x.run_id);
            try x.save("running", null);
            const out = execNodes(W.nodes, "", &.{}, W.Input, 0, x, x.state.input, x.state.input) catch |err| switch (err) {
                error.WorkflowSuspended => {
                    try x.save("suspended", x.suspended_at);
                    x.run_span.attr("suspended_at", x.suspended_at);
                    x.run_span.end();
                    if (comptime !W.can_suspend) unreachable;
                    return @unionInit(W.Result, "suspended", .{ .run_id = x.run_id, .at = x.suspended.? });
                },
                error.WorkflowStepFailed => {
                    try x.save("failed", x.failed_step);
                    x.run_span.fail(x.failed_msg);
                    x.run_span.end();
                    x.st.diagPrint("{s}", .{x.failed_msg});
                    return .{ .failed = .{ .step = x.failed_step, .err = x.failed_err, .message = x.failed_msg } };
                },
                error.OutOfMemory => return error.OutOfMemory,
                error.StorageFailed => return error.StorageFailed,
            };
            try x.save("completed", null);
            x.run_span.end();
            return .{ .completed = out };
        }

        const Flow = error{ WorkflowSuspended, WorkflowStepFailed, OutOfMemory, StorageFailed };

        fn save(x: *X, status: []const u8, at: ?[]const u8) error{ OutOfMemory, StorageFailed }!void {
            const store = x.st.storage orelse return;
            const body = try json.stringifyAlloc(x.arena, x.state.*);
            store.saveRun(.{
                .run_id = x.run_id,
                .kind = .workflow,
                .owner_id = W.id,
                .fingerprint = W.fingerprint_value,
                .status = status,
                .suspended_at = at,
                .state_json = body,
                .created_at = x.created_at,
                .updated_at = x.st.nowMs(),
            }) catch |err| {
                x.st.diagPrint("workflow '{s}' run '{s}': saving snapshot: {t}", .{ W.id, x.run_id, err });
                return error.StorageFailed;
            };
        }

        fn fail(x: *X, path: []const u8, err: anyerror, comptime fmt: []const u8, args: anytype) Flow {
            x.failed_step = path;
            x.failed_err = err;
            x.failed_msg = std.fmt.allocPrint(x.arena, fmt, args) catch "step failed";
            return error.WorkflowStepFailed;
        }

        /// Execute `nodes[i..]` starting from value `cur`.
        fn execNodes(comptime nodes: []const wf_mod.Node, comptime prefix: []const u8, comptime avail: []const Avail, comptime Initial: type, comptime i: usize, x: *X, initial: Initial, cur: anytype) Flow!Last(nodes, i, @TypeOf(cur)) {
            if (i == nodes.len) return cur;
            const n = nodes[i];
            switch (n.kind) {
                .step => {
                    const out = try execStep(n.T, prefix, avail, Initial, x, initial, cur);
                    const next_avail = comptime avail ++ &[_]Avail{.{ .T = n.T, .path = join(prefix, step.idOf(n.T)) }};
                    return execNodes(nodes, prefix, next_avail, Initial, i + 1, x, initial, out);
                },
                .branch => {
                    const out = try execBranch(n, prefix, avail, Initial, x, initial, cur);
                    return execNodes(nodes, prefix, avail, Initial, i + 1, x, initial, out);
                },
            }
        }

        fn Last(comptime nodes: []const wf_mod.Node, comptime i: usize, comptime Cur: type) type {
            if (i == nodes.len) return Cur;
            const n = nodes[i];
            return switch (n.kind) {
                .step => Last(nodes, i + 1, n.T.Output),
                .branch => Last(nodes, i + 1, n.arms[0].T.Output),
            };
        }

        fn execBranch(comptime n: wf_mod.Node, comptime prefix: []const u8, comptime avail: []const Avail, comptime Initial: type, x: *X, initial: Initial, cur: anytype) Flow!n.arms[0].T.Output {
            const bpath = comptime join(prefix, std.fmt.comptimePrint("branch_{d}", .{n.index}));
            const idx: u8 = if (@field(x.state.steps, bpath)) |stored| stored else blk: {
                inline for (n.arms, 0..) |arm, ai| {
                    if (arm.Pred == step.otherwise or arm.Pred.f(cur)) {
                        @field(x.state.steps, bpath) = ai;
                        try x.save("running", null);
                        break :blk ai;
                    }
                }
                return x.fail(bpath, error.NoBranchMatched, "workflow '{s}': no branch arm matched at '{s}' and there is no `z.otherwise`", .{ W.id, bpath });
            };
            inline for (n.arms, 0..) |arm, ai| if (ai == idx) return execStep(arm.T, prefix, avail, Initial, x, initial, cur);
            return x.fail(bpath, error.CorruptSnapshot, "workflow '{s}': stored branch index {d} at '{s}' is out of range", .{ W.id, idx, bpath });
        }

        fn execStep(comptime S: type, comptime prefix: []const u8, comptime avail: []const Avail, comptime Initial: type, x: *X, initial: Initial, input: S.Input) Flow!S.Output {
            const path = comptime join(prefix, step.idOf(S));
            if (@field(x.state.steps, path)) |done| return done.value;

            const out: S.Output = if (comptime step.isWorkflow(S))
                try execNodes(S.nodes, path, avail, S.Input, 0, x, input, input)
            else if (comptime step.isParallel(S))
                try execParallel(S, path, avail, Initial, x, initial, input)
            else
                try execPlain(S, path, avail, Initial, x, initial, input, x.arena);

            @field(x.state.steps, path) = .{ .value = out };
            try x.save("running", null);
            return out;
        }

        fn buildNeeds(comptime S: type, comptime avail: []const Avail, comptime Initial: type, x: *X, initial: Initial) step.NeedsOf(S) {
            var needs: step.NeedsOf(S) = undefined;
            if (@hasDecl(S, "needs")) inline for (std.meta.fields(@TypeOf(S.needs))) |f| {
                const R = @field(S.needs, f.name);
                if (comptime step.isInitial(R)) {
                    @field(needs, f.name) = initial;
                } else {
                    const p = comptime pathOf(avail, R, step.idOf(S));
                    @field(needs, f.name) = @field(x.state.steps, p).?.value;
                }
            };
            return needs;
        }

        fn execPlain(comptime S: type, comptime path: []const u8, comptime avail: []const Avail, comptime Initial: type, x: *X, initial: Initial, input: S.Input, arena: Allocator) Flow!S.Output {
            var span = x.st.tracer.begin(.workflow_step, path, x.trace_id, &x.run_span);
            defer span.end();
            span.attr("step", path);
            var w: step.StepCtx(W.Ctx, S) = .{
                .ctx = @ptrCast(@alignCast(x.st.ctx)),
                .arena = arena,
                .io = x.st.io,
                .run_id = x.run_id,
                .needs = buildNeeds(S, avail, Initial, x, initial),
                .resumed = if (comptime step.isSuspendable(S)) null else {},
                .trace = &span,
                .state = x.st,
                .step_id = path,
                .resource = x.resource,
                .trace_id = x.trace_id,
            };
            if (comptime step.isSuspendable(S)) {
                if (x.state.resume_at) |at| if (std.mem.eql(u8, at, path)) {
                    var issue: parse.Issue = .{};
                    w.resumed = parse.parse(S.Resume, x.arena, x.state.resume_json orelse "null", &issue) catch
                        return x.fail(path, error.CorruptSnapshot, "step '{s}': resume value doesn't parse: {f}", .{ path, issue });
                    x.state.resume_at = null;
                    x.state.resume_json = null;
                    span.attr("resumed", true);
                };
            }

            const retry: step.Retry = if (@hasDecl(S, "retry")) S.retry else .{};
            var attempt: u32 = 0;
            while (true) : (attempt += 1) {
                const r = runOnce(S, &w, input);
                if (r) |res| {
                    if (comptime step.isSuspendable(S)) switch (res) {
                        .done => |o| return o,
                        .suspended => |payload| {
                            x.suspended = @unionInit(W.Suspended, step.idOf(S), payload);
                            x.suspended_at = path;
                            span.attr("suspended", true);
                            return error.WorkflowSuspended;
                        },
                    } else return res;
                } else |err| {
                    const retryable = if (@hasDecl(S, "retry_on")) inSet(S.retry_on, err) else true;
                    if (!retryable or attempt + 1 >= retry.attempts) {
                        span.fail(@errorName(err));
                        const diag = x.st.diag.message();
                        return x.fail(path, err, "workflow '{s}': step '{s}' failed: {t}{s}{s}", .{ W.id, path, err, if (diag.len > 0) " — " else "", diag });
                    }
                    span.attr("retries", attempt + 1);
                    const ms = retry.backoff.delayMs(attempt);
                    if (ms > 0) x.st.io.sleep(.fromMilliseconds(@intCast(ms)), .awake) catch
                        return x.fail(path, error.Canceled, "workflow '{s}': step '{s}' canceled", .{ W.id, path });
                }
            }
        }

        fn Payload(comptime S: type) type {
            const R = @typeInfo(@TypeOf(S.run)).@"fn".return_type.?;
            return switch (@typeInfo(R)) {
                .error_union => |eu| eu.payload,
                else => R,
            };
        }

        /// One attempt, bounded by `timeout_ms` when the step declares it.
        fn runOnce(comptime S: type, w: *step.StepCtx(W.Ctx, S), input: S.Input) anyerror!Payload(S) {
            if (!@hasDecl(S, "timeout_ms")) return S.run(w, input);
            const Sel = std.Io.Select(union(enum) {
                done: anyerror!Payload(S),
                timeout: std.Io.Cancelable!void,
            });
            const Wrap = struct {
                fn call(ww: *step.StepCtx(W.Ctx, S), in: S.Input) anyerror!Payload(S) {
                    return S.run(ww, in);
                }
                fn sleep(io: std.Io) std.Io.Cancelable!void {
                    try io.sleep(.fromMilliseconds(S.timeout_ms), .awake);
                }
            };
            var buf: [2]Sel.Union = undefined;
            var sel: Sel = .init(w.io, &buf);
            sel.concurrent(.done, Wrap.call, .{ w, input }) catch return S.run(w, input);
            sel.concurrent(.timeout, Wrap.sleep, .{w.io}) catch {
                const u = sel.await() catch {
                    sel.cancelDiscard();
                    return error.Canceled;
                };
                sel.cancelDiscard();
                return u.done;
            };
            const first = sel.await() catch {
                sel.cancelDiscard();
                return error.Canceled;
            };
            sel.cancelDiscard();
            return switch (first) {
                .done => |r| r,
                .timeout => error.StepTimeout,
            };
        }

        fn inSet(comptime E: type, err: anyerror) bool {
            const set = @typeInfo(E).error_set orelse return true;
            inline for (set) |e| if (std.mem.eql(u8, e.name, @errorName(err))) return true;
            return false;
        }

        fn execParallel(comptime P: type, comptime path: []const u8, comptime avail: []const Avail, comptime Initial: type, x: *X, initial: Initial, input: P.Input) Flow!P.Output {
            const fields = std.meta.fields(@TypeOf(P.steps));
            const Slot = struct {
                arena: std.heap.ArenaAllocator,
                json_out: []const u8 = "",
                err: ?anyerror = null,
                flow: ?Flow = null,
            };
            var slots: [fields.len]Slot = undefined;
            for (&slots) |*s| s.* = .{ .arena = .init(x.st.gpa) };
            defer for (&slots) |*s| s.arena.deinit();

            var group: std.Io.Group = .init;
            inline for (fields, 0..) |f, i| {
                const S = @field(P.steps, f.name);
                const Task = struct {
                    fn go(xx: *X, slot: *Slot, init_v: Initial, in: P.Input) void {
                        const child_path = comptime path ++ "." ++ f.name;
                        const out = execPlain(S, child_path, avail, Initial, xx, init_v, in, slot.arena.allocator()) catch |e| {
                            slot.flow = e;
                            return;
                        };
                        slot.json_out = json.stringifyAlloc(slot.arena.allocator(), out) catch {
                            slot.flow = error.OutOfMemory;
                            return;
                        };
                    }
                };
                group.async(x.st.io, Task.go, .{ x, &slots[i], initial, input });
            }
            group.await(x.st.io) catch return x.fail(path, error.Canceled, "workflow '{s}': parallel step '{s}' canceled", .{ W.id, path });

            var out: P.Output = undefined;
            inline for (fields, 0..) |f, i| {
                if (slots[i].flow) |e| return e;
                const S = @field(P.steps, f.name);
                var issue: parse.Issue = .{};
                @field(out, f.name) = parse.parse(S.Output, x.arena, slots[i].json_out, &issue) catch
                    return x.fail(path, error.CorruptSnapshot, "parallel step '{s}.{s}': output didn't round-trip through JSON: {f}", .{ path, f.name, issue });
            }
            return out;
        }
    };
}
