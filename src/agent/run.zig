//! The agent loop (PLAN.md §6.4), as a pull-based state machine.
//!
//! `Stream(A).next()` drives everything: memory load, the provider request,
//! streaming deltas, tool-call parsing, approvals, parallel tool execution,
//! structured-output parsing with one repair attempt, memory save and
//! tracing. `generate` is stream-and-collect.

const std = @import("std");
const msg = @import("../message.zig");
const provider = @import("../provider/provider.zig");
const runtime = @import("../runtime.zig");
const parse = @import("../schema/parse.zig");
const json = @import("../schema/json.zig");
const partial = @import("../schema/partial.zig");
const migrate = @import("../schema/migrate.zig");
const stream_parse = @import("../schema/stream_parse.zig");
const fingerprint = @import("../meta/fingerprint.zig");
const trace = @import("../trace/trace.zig");
const ToolCtx = @import("../context.zig").ToolCtx;
const agent_mod = @import("agent.zig");
const ev = @import("events.zig");
const storage = @import("../storage/storage.zig");
const Allocator = std.mem.Allocator;
const Message = msg.Message;

pub const Error = provider.Error || error{
    /// A tool needs a decision; call `respond` for each pending approval,
    /// or `suspendRun` to save the run and decide later.
    ApprovalPending,
    /// `respond` or `resumeRun` with an id that isn't pending. The
    /// diagnostic lists the pending ids.
    UnknownApproval,
    /// `resumeRun`/`cancelRun`: no saved run with that id.
    RunNotFound,
    /// The saved run belongs to another agent or to a workflow.
    WrongAgent,
    /// The saved run isn't suspended (it finished, failed or was canceled).
    NotSuspended,
    /// Another resume claimed the run first (PLAN.md D32).
    RunBusy,
    /// The run was saved by a different version of the agent (prompt,
    /// model or tools changed). The diagnostic names what changed; deny
    /// and restart instead (PLAN.md §17.3).
    SnapshotIncompatible,
    /// The saved run didn't parse.
    CorruptSnapshot,
    /// Structured output failed validation after the repair attempt.
    OutputInvalid,
    /// The provider's API key isn't in the environment.
    MissingApiKey,
    /// Stored history or working memory couldn't be read.
    StorageFailed,
    /// A working-memory migration (`z.migrate`) returned an error (§18.2).
    MigrationFailed,
    /// An MCP call failed at the transport level.
    McpFailed,
    /// A tool returned an error that isn't in its `ModelErrors`; the run is
    /// aborted and the diagnostic names the tool and the error.
    ToolFailed,
};

pub fn Options(comptime A: type) type {
    return struct {
        /// Scopes message history (`.memory.history`).
        thread: ?[]const u8 = null,
        /// Scopes working memory (`.memory.working`), e.g. a customer id.
        resource: ?[]const u8 = null,
        max_steps: ?u32 = null,
        max_tokens: ?u32 = null,
        /// Include the run's messages in the result.
        include_messages: bool = false,
        /// For `generate`: decide approvals inline instead of suspending.
        on_approval: ?struct {
            ctx: ?*anyopaque = null,
            decide: *const fn (ctx: ?*anyopaque, call: A.ApprovalCall) ev.Decision,
        } = null,
        /// Stop after a step when this returns true.
        stop_when: ?*const fn (step: ev.StepFinish) bool = null,
        /// Reuse a run id (workflows pass theirs).
        run_id: ?[]const u8 = null,
        /// Parent span (workflows).
        trace_parent: ?*const trace.Span = null,
        trace_id: ?[16]u8 = null,
        /// Internal (workflow steps, D34): save the run under `run_id` when
        /// it finishes, result included, so a replayed step reuses it
        /// instead of running the agent again.
        keep_result: bool = false,
    };
}

/// A finished run's result as stored for `keep_result` (no messages).
pub fn StoredResult(comptime A: type) type {
    if (A.has_output_type) return struct {
        text: []const u8,
        output: A.Output,
        steps: u32,
        usage: msg.Usage,
        finish_reason: msg.FinishReason,
    };
    return struct {
        text: []const u8,
        steps: u32,
        usage: msg.Usage,
        finish_reason: msg.FinishReason,
    };
}

/// Load a kept result (see `Options.keep_result`).
pub fn loadKeptResult(comptime A: type, arena: Allocator, run_id: []const u8, state_json: []const u8) error{ OutOfMemory, CorruptSnapshot }!GenerateResult(A) {
    var issue: parse.Issue = .{};
    const r = parse.parse(StoredResult(A), arena, state_json, &issue) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        error.ValidationFailed => return error.CorruptSnapshot,
    };
    return .{
        .text = r.text,
        .output = if (comptime A.has_output_type) r.output else {},
        .steps = r.steps,
        .usage = r.usage,
        .finish_reason = r.finish_reason,
        .messages = &.{},
        .run_id = run_id,
    };
}

pub fn GenerateResult(comptime A: type) type {
    return struct {
        /// The text of the final assistant message.
        text: []const u8,
        /// The typed output, when the agent declares `.output`.
        output: A.Output,
        steps: u32,
        usage: msg.Usage,
        finish_reason: msg.FinishReason,
        /// This run's messages (input, assistant turns, tool results), when
        /// `include_messages` is set.
        messages: []const Message,
        run_id: []const u8,
    };
}

/// A run paused for approval and saved to storage (PLAN.md §17.3, D31).
/// Decide with `resumeRun(run_id, decisions)`, in this process or another
/// one with the same storage.
pub fn Suspended(comptime A: type) type {
    return struct {
        run_id: []const u8,
        /// The calls waiting for a decision, typed per tool.
        requests: []const ev.ApprovalRequest(A.ApprovalCall),
    };
}

/// What `generate` and `resumeRun` return for an agent with
/// approval-gated tools.
pub fn RunResult(comptime A: type) type {
    return union(enum) {
        completed: GenerateResult(A),
        suspended: Suspended(A),
    };
}

/// `generate`'s result: `RunResult(A)` for agents with approval-gated
/// tools, the plain `GenerateResult(A)` for the rest (D22).
pub fn Result(comptime A: type) type {
    return if (A.has_approvals) RunResult(A) else GenerateResult(A);
}

/// What a saved agent run holds (PLAN.md §17.3). History is appended once,
/// when the run finishes, so `messages` includes loaded history and
/// `new_from` marks where this run's messages start.
const Snapshot = struct {
    version: u32 = 1,
    prefix_hash: []const u8,
    tools: []const ToolPrint,
    messages: []const Message,
    new_from: usize,
    calls: []const SavedCall,
    step: u32,
    max_steps: u32,
    max_tokens: ?u32,
    usage: msg.Usage,
    step_usage: msg.Usage,
    repair_used: bool,
    working_json: ?[]const u8,
    working_dirty: bool,
    thread: ?[]const u8,
    resource: ?[]const u8,
    trace_id: []const u8,
    created_at: i64,
    keep_result: bool = false,
    /// Hex `A.run_core_fingerprint` and the working-memory fingerprint, so a
    /// run saved before a migrated working-memory change can resume (§18.2).
    core_hash: ?[]const u8 = null,
    working_fingerprint: ?[]const u8 = null,
};

const SavedCall = struct {
    id: []const u8,
    /// "none", "pending", "approved" or "denied".
    approval: []const u8,
    deny_reason: []const u8 = "",
};

/// A tool's name and the hash of its definition, so a fingerprint mismatch
/// can say which tool changed.
pub const ToolPrint = struct { name: []const u8, hash: []const u8 };

/// What `stream`/`generate` accept as input: a prompt string or messages.
pub fn toMessages(arena: Allocator, input: anytype) Allocator.Error![]const Message {
    const T = @TypeOf(input);
    if (comptime @import("../meta/reflect.zig").isString(T)) {
        const out = try arena.alloc(Message, 1);
        out[0] = .user(input);
        return out;
    }
    if (T == Message) {
        const out = try arena.alloc(Message, 1);
        out[0] = input;
        return out;
    }
    if (T == []const Message or T == []Message) return input;
    switch (@typeInfo(T)) {
        .pointer => |p| if (p.size == .one) switch (@typeInfo(p.child)) {
            .array => |a| if (a.child == Message) return input,
            else => {},
        },
        else => {},
    }
    @compileError("zastra: agent input must be a string, a z.Message, or a slice of z.Message; got " ++ @typeName(T));
}

const Phase = enum { init, request, streaming, awaiting_approval, execute, done };

const CallKind = enum { user, mcp, final_answer, working_memory, unknown };

pub fn Stream(comptime A: type) type {
    const Impl = provider.Impl(A.model.api);
    const Ctx = A.Ctx;

    return struct {
        const Self = @This();

        const Call = struct {
            id: []const u8,
            name: []const u8,
            input_json: []const u8,
            kind: CallKind,
            tool_index: usize = 0,
            parsed: ?A.ToolCall = null,
            output: ?A.Output = null,
            working: ?A.WorkingUpdate = null,
            parse_error: ?[]const u8 = null,
            approval: enum { none, pending, approved, denied } = .none,
            deny_reason: []const u8 = "",
            // results (written by the task, copied by the run)
            content: []const u8 = "",
            is_error: bool = false,
            elapsed_ms: u64 = 0,
            fatal: ?anyerror = null,
            arena: ?*std.heap.ArenaAllocator = null,
            mcp_server: []const u8 = "",
            mcp_tool: []const u8 = "",
        };

        st: *runtime.State,
        arena: Allocator,
        opts: Options(A),
        run_id: []const u8,
        trace_id: [16]u8,
        messages: std.ArrayList(Message) = .empty,
        /// Index of the first message this run added (after loaded history).
        new_from: usize = 0,
        step: u32 = 0,
        max_steps: u32,
        usage: msg.Usage = .{},
        queue: std.ArrayList(A.Event) = .empty,
        qpos: usize = 0,
        phase: Phase = .init,
        pstream: ?Impl.Stream = null,
        calls: std.ArrayList(Call) = .empty,
        pending: u32 = 0,
        repair_used: bool = false,
        output: ?A.Output = null,
        last_text: []const u8 = "",
        finish_reason: msg.FinishReason = .other,
        working: A.Working = if (A.has_working_memory) .{} else {},
        working_dirty: bool = false,
        system_suffix: ?[]const u8 = null,
        diag: provider.Diagnostic = .{},
        run_span: trace.Span = undefined,
        step_span: trace.Span = undefined,
        model_span: trace.Span = undefined,
        step_open: bool = false,
        canceled: bool = false,
        step_usage: msg.Usage = .{},
        input: []const Message,
        /// The run has a row in storage (it was suspended at some point), so
        /// its final status is written there too.
        persisted: bool = false,
        /// The request prefix, fixed for the whole run (MCP tool lists
        /// refreshed later apply to the next run).
        prefix: provider.Prefix = A.prefix,
        created_at: i64 = 0,
        /// Partial output (D43). A single field, void without
        /// `.partial_output`, so other agents are byte-for-byte unchanged.
        partial: if (A.partial_output) PartialState else void = undefined,

        const PartialState = struct {
            parser: stream_parse.Parser(A.Output),
            /// Off for `generate`, which never shows partial values.
            on: bool = true,
            /// The `final_answer` call's index in the current turn.
            final_index: ?u32 = null,
        };

        const tag_headers = [_][2][]const u8{.{ "x-zastra-agent", A.id }};

        pub fn init(st: *runtime.State, arena: Allocator, input: []const Message, opts: Options(A)) Allocator.Error!*Self {
            const s = try arena.create(Self);
            s.* = .{
                .st = st,
                .arena = arena,
                .opts = opts,
                .run_id = opts.run_id orelse try st.newId(arena, "run"),
                .trace_id = opts.trace_id orelse st.tracer.newId(),
                .max_steps = opts.max_steps orelse A.max_steps_default,
                .input = input,
                .created_at = st.nowMs(),
                .persisted = opts.keep_result,
            };
            if (A.partial_output) s.partial = .{ .parser = .init(st.gpa) };
            s.run_span = st.tracer.begin(.agent_run, A.id, s.trace_id, opts.trace_parent);
            s.run_span.attr("agent", A.id);
            s.run_span.attr("run_id", s.run_id);
            s.run_span.attr("model", comptime A.model.fullName());
            return s;
        }

        // ── public API ───────────────────────────────────────────────────

        /// The next event, or null when the run is over. Text deltas are
        /// valid until the next call.
        pub fn next(s: *Self) Error!?A.Event {
            return s.nextInner() catch |err| {
                s.fail(err);
                return err;
            };
        }

        /// Decide a pending approval: `.approve` or `.{ .deny = "reason" }`.
        pub fn respond(s: *Self, approval_id: []const u8, decision: ev.Decision) Error!void {
            for (s.calls.items) |*c| {
                if (c.approval != .pending or !std.mem.eql(u8, c.id, approval_id)) continue;
                switch (decision) {
                    .approve => c.approval = .approved,
                    .deny => |reason| {
                        c.approval = .denied;
                        c.deny_reason = try s.arena.dupe(u8, reason);
                    },
                }
                s.pending -= 1;
                return;
            }
            s.diag.print(0, "agent '{s}' run '{s}': no pending approval '{s}'; pending: {f}", .{ A.id, s.run_id, approval_id, PendingIds{ .calls = s.calls.items } });
            s.st.setDiag(&s.diag);
            return error.UnknownApproval;
        }

        const PendingIds = struct {
            calls: []const Call,
            pub fn format(p: PendingIds, w: *std.Io.Writer) std.Io.Writer.Error!void {
                var n: usize = 0;
                for (p.calls) |c| if (c.approval == .pending) {
                    try w.print("{s}{s}", .{ if (n > 0) ", " else "", c.id });
                    n += 1;
                };
                if (n == 0) try w.writeAll("none");
            }
        };

        /// Save the run while approvals are pending and stop streaming. The
        /// returned run id resumes it later with `resumeRun`/`resumeStream`,
        /// in this process or another one with the same storage. Decisions
        /// already made with `respond` are kept. (`suspend` is a Zig keyword.)
        pub fn suspendRun(s: *Self) Error!Suspended(A) {
            if (comptime !A.has_approvals) unreachable;
            if (s.phase != .awaiting_approval or s.pending == 0) {
                s.diag.print(0, "agent '{s}' run '{s}': suspendRun() needs a pending approval", .{ A.id, s.run_id });
                s.st.setDiag(&s.diag);
                return error.NotSuspended;
            }
            const store = s.st.storage orelse return error.StorageFailed;
            const snap = try s.snapshot();
            store.saveRun(.{
                .run_id = s.run_id,
                .kind = .agent,
                .owner_id = A.id,
                .fingerprint = A.run_fingerprint,
                .status = "suspended",
                .suspended_at = "approval",
                .state_json = try json.stringifyAlloc(s.arena, snap),
                .created_at = s.created_at,
                .updated_at = s.st.nowMs(),
            }) catch |err| {
                s.diag.print(0, "agent '{s}' run '{s}': saving the suspended run: {t}", .{ A.id, s.run_id, err });
                s.st.setDiag(&s.diag);
                return error.StorageFailed;
            };
            s.persisted = true;
            var reqs: std.ArrayList(ev.ApprovalRequest(A.ApprovalCall)) = .empty;
            for (s.calls.items) |c| if (c.approval == .pending) {
                if (s.approvalCall(c)) |call| try reqs.append(s.arena, .{ .id = c.id, .call = call });
            };
            if (s.step_open) {
                s.step_span.attr("suspended", true);
                s.step_span.end();
                s.step_open = false;
            }
            s.run_span.attr("suspended", true);
            s.run_span.attr("steps", s.step);
            s.run_span.end();
            s.phase = .done;
            return .{ .run_id = s.run_id, .requests = reqs.items };
        }

        fn approvalCall(s: *Self, c: Call) ?A.ApprovalCall {
            _ = s;
            if (comptime !A.has_approvals) return null;
            const pc = c.parsed orelse return null;
            inline for (A.tools, 0..) |TI, i| if (comptime TI.approval_kind != .never) if (i == c.tool_index)
                return @unionInit(A.ApprovalCall, TI.name, @field(pc, TI.name));
            return null;
        }

        fn snapshot(s: *Self) Error!Snapshot {
            const calls = try s.arena.alloc(SavedCall, s.calls.items.len);
            for (s.calls.items, calls) |c, *o| o.* = .{ .id = c.id, .approval = @tagName(c.approval), .deny_reason = c.deny_reason };
            return .{
                .prefix_hash = try std.fmt.allocPrint(s.arena, "{x:0>16}", .{A.prefix_hash}),
                .tools = &A.tool_prints,
                .messages = s.messages.items,
                .new_from = s.new_from,
                .calls = calls,
                .step = s.step,
                .max_steps = s.max_steps,
                .max_tokens = s.opts.max_tokens,
                .usage = s.usage,
                .step_usage = s.step_usage,
                .repair_used = s.repair_used,
                .working_json = if (A.has_working_memory) try json.stringifyAlloc(s.arena, s.working) else null,
                .working_dirty = s.working_dirty,
                .core_hash = try std.fmt.allocPrint(s.arena, "{x:0>16}", .{A.run_core_fingerprint}),
                .working_fingerprint = if (A.has_working_memory) try std.fmt.allocPrint(s.arena, "{x:0>16}", .{A.working_fingerprint}) else null,
                .thread = s.opts.thread,
                .resource = s.opts.resource,
                .trace_id = try std.fmt.allocPrint(s.arena, "{x}", .{s.trace_id[0..]}),
                .created_at = s.created_at,
                .keep_result = s.opts.keep_result,
            };
        }

        /// Rebuild a stream from a saved run, waiting at its approvals.
        fn restore(st: *runtime.State, arena: Allocator, run_id: []const u8, snap: Snapshot) Error!*Self {
            var trace_id: [16]u8 = @splat(0);
            _ = std.fmt.hexToBytes(&trace_id, snap.trace_id) catch {};
            const s = try init(st, arena, &.{}, .{
                .thread = snap.thread,
                .resource = snap.resource,
                .max_steps = snap.max_steps,
                .max_tokens = snap.max_tokens,
                .run_id = run_id,
                .trace_id = trace_id,
                .keep_result = snap.keep_result,
            });
            errdefer s.deinit();
            s.persisted = true;
            s.created_at = snap.created_at;
            s.run_span.attr("resumed", true);
            try s.messages.appendSlice(arena, snap.messages);
            s.new_from = snap.new_from;
            s.step = snap.step;
            s.usage = snap.usage;
            s.step_usage = snap.step_usage;
            s.repair_used = snap.repair_used;
            s.working_dirty = snap.working_dirty;
            if (A.has_working_memory) {
                if (snap.working_json) |wj| {
                    const fp = if (snap.working_fingerprint) |h| std.fmt.parseInt(u64, h, 16) catch return error.CorruptSnapshot else A.working_fingerprint;
                    if (fp == A.working_fingerprint) {
                        var issue: parse.Issue = .{};
                        s.working = parse.parse(A.Working, arena, wj, &issue) catch return error.CorruptSnapshot;
                    } else {
                        s.working = (try s.migrateWorking(snap.resource orelse "", fp, wj)) orelse return error.CorruptSnapshot;
                    }
                }
                s.system_suffix = try s.workingSuffix();
            }
            // The calls come from the assistant turn that asked for them.
            const last = if (s.messages.items.len > 0) s.messages.items[s.messages.items.len - 1] else return error.CorruptSnapshot;
            if (last.role != .assistant or last.content != .blocks) return error.CorruptSnapshot;
            for (last.content.blocks) |b| if (b == .tool_use) try s.addCall(b.tool_use);
            if (s.calls.items.len != snap.calls.len) return error.CorruptSnapshot;
            for (s.calls.items, snap.calls) |*c, saved| {
                if (!std.mem.eql(u8, c.id, saved.id)) return error.CorruptSnapshot;
                c.approval = std.meta.stringToEnum(@TypeOf(c.approval), saved.approval) orelse return error.CorruptSnapshot;
                c.deny_reason = saved.deny_reason;
                if (c.approval == .pending) s.pending += 1;
            }
            try s.loadPrefix();
            s.step_span = st.tracer.begin(.agent_step, A.id, s.trace_id, &s.run_span);
            s.step_span.attr("step", s.step);
            s.step_span.attr("resumed", true);
            s.step_open = true;
            s.phase = .awaiting_approval;
            return s;
        }

        /// Migrate a working-memory value saved with fingerprint `fp` (§18.2).
        /// Null when no migration covers it, or the old value doesn't parse
        /// as the shape it was saved under (logged).
        fn migrateWorking(s: *Self, res: []const u8, fp: u64, value_json: []const u8) Error!?A.Working {
            if (comptime !A.has_working_memory) return null;
            var issue: parse.Issue = .{};
            var failed: anyerror = error.Unknown;
            return migrate.run(A.Working, s.arena, fp, value_json, &issue, &failed) catch |err| switch (err) {
                error.OutOfMemory => return error.OutOfMemory,
                error.ValidationFailed => {
                    std.log.warn("zastra: agent '{s}': working memory for '{s}' didn't parse as the shape it was saved under ({f}); starting from defaults", .{ A.id, res, issue });
                    return null;
                },
                error.MigrationFailed => {
                    s.diag.print(0, "agent '{s}': migrating working memory for '{s}' from 0x{x:0>16}: {t}", .{ A.id, res, fp, failed });
                    return error.MigrationFailed;
                },
            };
        }

        fn workingSuffix(s: *Self) Allocator.Error![]const u8 {
            return std.fmt.allocPrint(s.arena, "Working memory (what you know about this user; update it with `{s}`):\n{f}", .{ agent_mod.working_memory_tool, json.fmt(s.working) });
        }

        /// Queue `approval_request` events for the calls still pending (a
        /// resumed stream shows them again, e.g. to a reconnecting UI).
        fn requeuePending(s: *Self) Error!void {
            if (comptime !A.has_approvals) return;
            for (s.calls.items) |c| if (c.approval == .pending) {
                if (s.approvalCall(c)) |call| try s.push(@unionInit(A.Event, "approval_request", .{ .id = c.id, .call = call }));
            };
        }

        /// Stop the run. The next `next()` yields a `.finish` with reason
        /// `.canceled`. To interrupt a blocked network read, run `next()` in
        /// an `io.async` task and cancel that future.
        pub fn cancel(s: *Self) void {
            s.canceled = true;
        }

        /// The collected result after the stream finished.
        pub fn result(s: *Self) Error!GenerateResult(A) {
            var out: A.Output = undefined;
            if (A.has_output_type) {
                out = s.output orelse {
                    s.diag.print(0, "agent '{s}' finished ({t}) without producing its output", .{ A.id, s.finish_reason });
                    s.st.setDiag(&s.diag);
                    return error.OutputInvalid;
                };
            } else out = {};
            return .{
                .text = s.last_text,
                .output = out,
                .steps = s.step,
                .usage = s.usage,
                .finish_reason = s.finish_reason,
                .messages = if (s.opts.include_messages) s.messages.items[s.new_from..] else &.{},
                .run_id = s.run_id,
            };
        }

        pub fn deinit(s: *Self) void {
            if (A.partial_output) s.partial.parser.deinit();
            if (s.pstream) |*ps| ps.close();
            s.pstream = null;
            s.freeCallArenas();
            if (s.phase != .done) {
                s.run_span.fail("abandoned");
                s.run_span.end();
                s.phase = .done;
            }
        }

        // ── state machine ────────────────────────────────────────────────

        fn nextInner(s: *Self) Error!?A.Event {
            while (true) {
                if (s.qpos < s.queue.items.len) {
                    const e = s.queue.items[s.qpos];
                    s.qpos += 1;
                    return e;
                }
                s.queue.clearRetainingCapacity();
                s.qpos = 0;
                if (s.canceled and s.phase != .done) {
                    if (s.pstream) |*ps| ps.close();
                    s.pstream = null;
                    try s.finishRun(.canceled);
                    continue;
                }
                switch (s.phase) {
                    .init => {
                        try s.start();
                        s.phase = .request;
                    },
                    .request => {
                        if (s.step >= s.max_steps) {
                            try s.finishRun(.max_steps);
                            continue;
                        }
                        try s.openRequest();
                        s.phase = .streaming;
                    },
                    .streaming => {
                        const e = (try s.pstream.?.next()) orelse return error.StreamInterrupted;
                        switch (e) {
                            .delta => |d| switch (d) {
                                .text => |t| if (t.len > 0) {
                                    if (comptime A.partial_output and A.native_structured_output) if (s.partial.on) if (try s.partial.parser.feed(t)) |v| {
                                        try s.push(@unionInit(A.Event, "text_delta", t));
                                        try s.push(@unionInit(A.Event, "output_partial", v));
                                        continue;
                                    };
                                    return @unionInit(A.Event, "text_delta", t);
                                },
                                // Without `.show_reasoning` the text is dropped here; the
                                // block itself still goes back to the provider.
                                .reasoning => |t| if (A.show_reasoning and t.len > 0) return @unionInit(A.Event, "reasoning_delta", t),
                                else => if (comptime A.partial_output and !A.native_structured_output) if (s.partial.on) switch (d) {
                                    // The `final_answer` call's arguments are the output.
                                    .tool_call_start => |c| if (std.mem.eql(u8, c.name, agent_mod.final_answer_tool)) {
                                        s.partial.final_index = c.index;
                                    },
                                    .tool_call_args => |c| if (s.partial.final_index == c.index) if (try s.partial.parser.feed(c.json)) |v| return @unionInit(A.Event, "output_partial", v),
                                    else => {},
                                },
                            },
                            .finish => |f| try s.onModelFinish(f),
                        }
                    },
                    .awaiting_approval => {
                        if (s.pending > 0) return error.ApprovalPending;
                        s.phase = .execute;
                    },
                    .execute => try s.executeTools(),
                    .done => return null,
                }
            }
        }

        fn fail(s: *Self, err: anyerror) void {
            if (err == error.ApprovalPending) return;
            if (s.diag.message_len == 0) s.diag.print(0, "agent '{s}': {t}", .{ A.id, err });
            s.st.setDiag(&s.diag);
            if (s.phase != .done) {
                if (s.step_open) {
                    s.step_span.fail(@errorName(err));
                    s.step_span.end();
                    s.step_open = false;
                }
                s.run_span.fail(s.diag.message());
                s.run_span.end();
                s.phase = .done;
                s.saveStatus("failed");
            }
        }

        /// For runs that were saved while suspended: record how they ended.
        fn saveStatus(s: *Self, status: []const u8) void {
            if (!s.persisted) return;
            const store = s.st.storage orelse return;
            var state_json: []const u8 = "{}";
            if (s.opts.keep_result and std.mem.eql(u8, status, "completed")) {
                if (A.has_output_type) {
                    if (s.output) |o| state_json = json.stringifyAlloc(s.arena, StoredResult(A){ .text = s.last_text, .output = o, .steps = s.step, .usage = s.usage, .finish_reason = s.finish_reason }) catch "{}";
                } else {
                    state_json = json.stringifyAlloc(s.arena, StoredResult(A){ .text = s.last_text, .steps = s.step, .usage = s.usage, .finish_reason = s.finish_reason }) catch "{}";
                }
            }
            store.saveRun(.{
                .run_id = s.run_id,
                .kind = .agent,
                .owner_id = A.id,
                .fingerprint = A.run_fingerprint,
                .status = status,
                .suspended_at = null,
                .state_json = state_json,
                .created_at = s.created_at,
                .updated_at = s.st.nowMs(),
            }) catch |err| std.log.warn("zastra: agent '{s}' run '{s}': recording status '{s}': {t}", .{ A.id, s.run_id, status, err });
        }

        fn push(s: *Self, e: A.Event) Allocator.Error!void {
            try s.queue.append(s.arena, e);
        }

        /// Take the MCP-completed prefix for this run.
        fn loadPrefix(s: *Self) Error!void {
            if (A.mcp_tools.len == 0) return;
            const vt = s.st.mcp_vtable orelse return error.McpFailed;
            s.prefix = vt.prefix(s.st.mcp.?, A.id) catch |err| switch (err) {
                error.OutOfMemory => return error.OutOfMemory,
                else => {
                    s.diag.print(0, "agent '{s}': MCP tools: {t}", .{ A.id, err });
                    return error.McpFailed;
                },
            };
        }

        fn start(s: *Self) Error!void {
            try s.loadPrefix();
            // Memory: history, then working memory (§6.5).
            if (A.history_messages > 0) if (s.opts.thread) |thread| if (s.st.storage) |store| {
                const rows = store.loadHistory(s.arena, thread, A.history_messages) catch |err| {
                    s.diag.print(0, "agent '{s}': loading history for thread '{s}': {t}", .{ A.id, thread, err });
                    return error.StorageFailed;
                };
                var loaded: std.ArrayList(Message) = .empty;
                for (rows) |row| {
                    const m = msg.fromJson(s.arena, row) catch {
                        s.diag.print(0, "agent '{s}': corrupt message in thread '{s}'", .{ A.id, thread });
                        return error.StorageFailed;
                    };
                    try loaded.append(s.arena, m);
                }
                // Never start mid tool exchange: drop leading messages until
                // the first plain user turn.
                var first: usize = 0;
                while (first < loaded.items.len and !isPlainUser(loaded.items[first])) first += 1;
                // Thinking blocks are bound to the exact prefix they were
                // produced under. Across runs that prefix changes (history
                // window, working-memory suffix), so replaying them would be
                // rejected; drop them from loaded history. Within a run they
                // are passed back unchanged (PLAN.md D30).
                for (loaded.items[first..]) |m| try s.messages.append(s.arena, try withoutThinking(s.arena, m));
            };
            if (A.has_working_memory) {
                if (s.opts.resource) |res| if (s.st.storage) |store| {
                    const wm = store.getWorkingMemory(s.arena, res, A.id) catch |err| {
                        s.diag.print(0, "agent '{s}': loading working memory for '{s}': {t}", .{ A.id, res, err });
                        return error.StorageFailed;
                    };
                    if (wm) |w| {
                        if (w.fingerprint != A.working_fingerprint) {
                            if (try s.migrateWorking(res, w.fingerprint, w.value_json)) |v| {
                                s.working = v;
                                // Saved back, with the new fingerprint, when the run ends.
                                s.working_dirty = true;
                            } else {
                                std.log.warn("zastra: agent '{s}': working memory for '{s}' was saved with a different {s} shape (fingerprint 0x{x:0>16}); starting from defaults. Add `z.migrate(<old shape>, ...)` to {s}.migrations to keep it", .{ A.id, res, @typeName(A.Working), w.fingerprint, @typeName(A.Working) });
                            }
                        } else {
                            var issue: parse.Issue = .{};
                            s.working = parse.parse(A.Working, s.arena, w.value_json, &issue) catch blk: {
                                std.log.warn("zastra: agent '{s}': working memory for '{s}' didn't parse ({f}); starting from defaults", .{ A.id, res, issue });
                                break :blk .{};
                            };
                        }
                    }
                };
                s.system_suffix = try s.workingSuffix();
            }
            s.new_from = s.messages.items.len;
            try s.messages.appendSlice(s.arena, s.input);
        }

        fn withoutThinking(arena: Allocator, m: Message) Allocator.Error!Message {
            if (m.role != .assistant) return m;
            const bs = switch (m.content) {
                .text => return m,
                .blocks => |b| b,
            };
            var out: std.ArrayList(msg.Block) = .empty;
            for (bs) |b| switch (b) {
                .reasoning => {},
                .provider_opaque => |o| if (std.mem.indexOf(u8, o.json, "\"type\":\"redacted_thinking\"") == null) try out.append(arena, b),
                else => try out.append(arena, b),
            };
            return .{ .role = .assistant, .content = .{ .blocks = out.items } };
        }

        fn isPlainUser(m: Message) bool {
            if (m.role != .user) return false;
            return m.count(.tool_result) == 0;
        }

        fn openRequest(s: *Self) Error!void {
            const spec = A.model;
            const key = s.st.apiKey(spec);
            if (spec.api_key_env != null and key == null and !s.st.tag_requests) {
                s.diag.print(0, "agent '{s}': {s} is not set (needed for model {s})", .{ A.id, spec.api_key_env.?, comptime spec.fullName() });
                return error.MissingApiKey;
            }
            const max_tokens = s.opts.max_tokens orelse A.max_tokens_default;
            if (A.reasoning_budget) |budget| if (max_tokens <= budget) {
                s.diag.print(0, "agent '{s}': max_tokens {d} must be greater than the reasoning budget ({d}); the budget counts toward it", .{ A.id, max_tokens, budget });
                return error.BadRequest;
            };
            if (comptime A.partial_output) if (s.partial.on) {
                // Partial values from an earlier turn (a repair, a retried
                // final_answer, JSON before tool calls) didn't become the output.
                if (s.partial.parser.produced()) try s.push(@unionInit(A.Event, "output_partial_reset", {}));
                s.partial.parser.reset();
                s.partial.final_index = null;
            };
            s.step_span = s.st.tracer.begin(.agent_step, A.id, s.trace_id, &s.run_span);
            s.step_span.attr("step", s.step);
            s.step_open = true;
            s.model_span = s.st.tracer.begin(.model_call, comptime spec.fullName(), s.trace_id, &s.step_span);
            s.model_span.attr("model", comptime spec.fullName());
            s.model_span.attr("prefix_hash", A.prefix_hash);

            const prefix = s.prefix;
            const req: provider.Request = .{
                .base_url = s.st.baseUrl(spec),
                .api_key = key,
                .prefix = prefix,
                .system_suffix = s.system_suffix,
                .messages = s.messages.items,
                .max_tokens = max_tokens,
                .max_tokens_field = spec.max_tokens_field,
                .headers = if (s.st.tag_requests) &tag_headers else spec.headers,
                .diag = &s.diag,
            };
            s.pstream = Impl.Stream.open(s.arena, &s.st.http, req) catch |err| {
                s.model_span.fail(s.diag.message());
                s.model_span.end();
                return err;
            };
        }

        fn onModelFinish(s: *Self, f: provider.Finish) Error!void {
            if (s.pstream) |*ps| ps.close();
            s.pstream = null;

            var usage = f.usage;
            usage.cost_usd = A.model.costUsd(usage);
            s.usage.add(usage);
            s.model_span.attr("input_tokens", usage.input_tokens);
            s.model_span.attr("output_tokens", usage.output_tokens);
            s.model_span.attr("cache_read_tokens", usage.cache_read_tokens);
            s.model_span.attr("cost_usd", usage.cost_usd);
            s.model_span.attr("finish_reason", @tagName(f.reason));
            s.model_span.end();

            try s.messages.append(s.arena, f.message);
            s.last_text = try f.message.allText(s.arena);
            s.finish_reason = f.reason;
            s.calls.clearRetainingCapacity();

            switch (f.message.content) {
                .blocks => |bs| for (bs) |b| if (b == .tool_use) try s.addCall(b.tool_use),
                .text => {},
            }

            if (s.calls.items.len == 0) {
                // A final answer (or a refusal / truncation).
                if (A.has_output_type and s.output == null) {
                    if (A.native_structured_output) {
                        var issue: parse.Issue = .{};
                        if (parse.parse(A.Output, s.arena, s.last_text, &issue)) |o| {
                            s.output = o;
                        } else |err| switch (err) {
                            error.OutOfMemory => return error.OutOfMemory,
                            error.ValidationFailed => return s.repair(try std.fmt.allocPrint(s.arena,
                                "Your response didn't match the required JSON schema: {s}: {s}. Respond again with only the corrected JSON object.", .{ issue.path, issue.message }), issue),
                        }
                    } else {
                        return s.repair("You must call the `" ++ agent_mod.final_answer_tool ++ "` tool with your final answer.", .{ .path = "$", .message = "no final_answer call" });
                    }
                }
                try s.endStep(usage, f.reason);
                return s.finishRun(f.reason);
            }

            // Tool calls: announce, check approvals.
            for (s.calls.items) |*c| {
                if (c.parsed) |pc| if (A.has_tool_events) try s.push(@unionInit(A.Event, "tool_call", pc));
            }
            for (s.calls.items) |*c| {
                if (c.kind != .user or c.parsed == null) continue;
                inline for (A.tools, 0..) |TI, i| if (i == c.tool_index) {
                    const needs = switch (TI.approval_kind) {
                        .never => false,
                        .always => true,
                        .dynamic => blk: {
                            var span = s.st.tracer.begin(.tool_call, TI.name, s.trace_id, &s.step_span);
                            var tctx: ToolCtx(Ctx) = .{
                                .ctx = @ptrCast(@alignCast(s.st.ctx)),
                                .arena = s.arena,
                                .io = s.st.io,
                                .run_id = s.run_id,
                                .tool_call_id = c.id,
                                .trace = &span,
                            };
                            break :blk TI.Tool.needsApproval(&tctx, @field(c.parsed.?, TI.name));
                        },
                    };
                    if (needs) {
                        if (comptime A.has_approvals) {
                            c.approval = .pending;
                            s.pending += 1;
                            const call = @unionInit(A.ApprovalCall, TI.name, @field(c.parsed.?, TI.name));
                            try s.push(@unionInit(A.Event, "approval_request", .{ .id = c.id, .call = call }));
                        }
                    }
                };
            }
            s.phase = if (s.pending > 0) .awaiting_approval else .execute;
            s.step_usage = usage;
        }

        fn repair(s: *Self, text: []const u8, issue: parse.Issue) Error!void {
            if (s.repair_used) {
                s.diag.print(0, "agent '{s}': output invalid after repair: {s}: {s}; raw: {s}", .{ A.id, issue.path, issue.message, s.last_text });
                return error.OutputInvalid;
            }
            s.repair_used = true;
            try s.messages.append(s.arena, .user(text));
            if (s.step_open) {
                s.step_span.attr("repair", true);
                s.step_span.end();
                s.step_open = false;
            }
            s.step += 1;
            s.phase = .request;
        }

        fn addCall(s: *Self, tu: msg.ToolUse) Error!void {
            var c: Call = .{ .id = tu.id, .name = tu.name, .input_json = tu.input_json, .kind = .unknown };
            var issue: parse.Issue = .{};
            inline for (A.tools, 0..) |TI, i| if (std.mem.eql(u8, tu.name, TI.name)) {
                c.kind = .user;
                c.tool_index = i;
                if (parse.parse(TI.Input, s.arena, tu.input_json, &issue)) |in| {
                    c.parsed = @unionInit(A.ToolCall, TI.name, in);
                } else |err| switch (err) {
                    error.OutOfMemory => return error.OutOfMemory,
                    error.ValidationFailed => c.parse_error = try std.fmt.allocPrint(s.arena, "Invalid arguments for {s}: {s}: {s}. Fix them and call the tool again.", .{ TI.name, issue.path, issue.message }),
                }
            };
            if (A.has_output_type and !A.native_structured_output and std.mem.eql(u8, tu.name, agent_mod.final_answer_tool)) {
                c.kind = .final_answer;
                if (parse.parse(A.Output, s.arena, tu.input_json, &issue)) |o| {
                    c.output = o;
                } else |err| switch (err) {
                    error.OutOfMemory => return error.OutOfMemory,
                    error.ValidationFailed => c.parse_error = try std.fmt.allocPrint(s.arena, "The final answer didn't match the schema: {s}: {s}. Call {s} again with a corrected answer.", .{ issue.path, issue.message, agent_mod.final_answer_tool }),
                }
            }
            if (A.has_working_memory and std.mem.eql(u8, tu.name, agent_mod.working_memory_tool)) {
                c.kind = .working_memory;
                if (parse.parse(A.WorkingUpdate, s.arena, tu.input_json, &issue)) |w| {
                    c.working = w;
                } else |err| switch (err) {
                    error.OutOfMemory => return error.OutOfMemory,
                    error.ValidationFailed => c.parse_error = try std.fmt.allocPrint(s.arena, "Invalid working-memory update: {s}: {s}", .{ issue.path, issue.message }),
                }
            }
            if (c.kind == .unknown and A.mcp_tools.len > 0) {
                // MCP tools are named "<server>__<tool>".
                if (std.mem.indexOf(u8, tu.name, "__")) |sep| {
                    c.kind = .mcp;
                    c.mcp_server = tu.name[0..sep];
                    c.mcp_tool = tu.name[sep + 2 ..];
                    if (comptime @hasField(A.ToolCall, "mcp"))
                        c.parsed = @unionInit(A.ToolCall, "mcp", .{ .server = c.mcp_server, .tool = c.mcp_tool, .args_json = tu.input_json });
                }
            }
            if (c.kind == .unknown) c.parse_error = try std.fmt.allocPrint(s.arena, "There is no tool named '{s}'.", .{tu.name});
            try s.calls.append(s.arena, c);
        }

        fn executeTools(s: *Self) Error!void {
            var group: std.Io.Group = .init;
            var sequential = false;
            for (s.calls.items) |c| if (c.kind == .user) {
                inline for (A.tools, 0..) |TI, i| if (i == c.tool_index and !TI.parallel) {
                    sequential = true;
                };
            };

            for (s.calls.items) |*c| {
                if (c.parse_error) |e| {
                    c.content = e;
                    c.is_error = true;
                    continue;
                }
                if (c.approval == .denied) {
                    c.content = try std.fmt.allocPrint(s.arena, "The user denied this tool call: {s}", .{c.deny_reason});
                    c.is_error = true;
                    continue;
                }
                switch (c.kind) {
                    .final_answer => {
                        s.output = c.output;
                        c.content = "Received.";
                    },
                    .working_memory => {
                        if (A.has_working_memory) {
                            s.working = partial.merge(A.Working, s.working, c.working.?);
                            s.working_dirty = true;
                        }
                        c.content = "Saved.";
                    },
                    .user, .mcp => {
                        if (sequential) runCall(s, c) else group.async(s.st.io, runCall, .{ s, c });
                    },
                    .unknown => {},
                }
            }
            group.await(s.st.io) catch {
                group.cancel(s.st.io);
                s.freeCallArenas();
                return error.Canceled;
            };

            // Copy results out of the per-call arenas (single-threaded again).
            var results: std.ArrayList(msg.Block) = .empty;
            var fatal: ?anyerror = null;
            var fatal_tool: []const u8 = "";
            for (s.calls.items) |*c| {
                if (c.fatal) |f| if (fatal == null) {
                    fatal = f;
                    fatal_tool = c.name;
                };
                c.content = try s.arena.dupe(u8, c.content);
                try results.append(s.arena, .{ .tool_result = .{ .id = c.id, .name = c.name, .content = c.content, .is_error = c.is_error } });
                if (A.has_tool_events and c.kind != .final_answer and c.kind != .working_memory)
                    try s.push(@unionInit(A.Event, "tool_result", ev.ToolResult{ .id = c.id, .tool = c.name, .content = c.content, .is_error = c.is_error, .elapsed_ms = c.elapsed_ms }));
            }
            s.freeCallArenas();
            if (fatal) |f| {
                s.diag.print(0, "agent '{s}': tool '{s}' failed: {t}", .{ A.id, fatal_tool, f });
                return error.ToolFailed;
            }
            try s.messages.append(s.arena, .{ .role = .tool, .content = .{ .blocks = results.items } });

            try s.endStep(s.step_usage, .tool_use);
            if (A.has_output_type and s.output != null and !A.native_structured_output) return s.finishRun(.end_turn);
            if (s.opts.stop_when) |sw| if (sw(.{ .index = s.step - 1, .reason = .tool_use, .usage = s.step_usage })) return s.finishRun(.stopped);
            s.phase = .request;
        }

        fn runCall(s: *Self, c: *Call) void {
            const arena = s.st.gpa.create(std.heap.ArenaAllocator) catch {
                c.fatal = error.OutOfMemory;
                return;
            };
            arena.* = .init(s.st.gpa);
            c.arena = arena;
            const t0 = std.Io.Clock.awake.now(s.st.io);
            defer c.elapsed_ms = @intCast(@max(0, @divFloor(t0.durationTo(std.Io.Clock.awake.now(s.st.io)).nanoseconds, std.time.ns_per_ms)));

            if (c.kind == .mcp) {
                var span = s.st.tracer.begin(.mcp_call, c.name, s.trace_id, &s.step_span);
                defer span.end();
                const vt = s.st.mcp_vtable orelse {
                    c.fatal = error.McpFailed;
                    return;
                };
                const r = vt.call(s.st.mcp.?, arena.allocator(), c.mcp_server, c.mcp_tool, c.input_json) catch |err| {
                    span.fail(@errorName(err));
                    c.fatal = err;
                    return;
                };
                c.content = r.content;
                c.is_error = r.is_error;
                return;
            }

            inline for (A.tools, 0..) |TI, i| if (i == c.tool_index) {
                var span = s.st.tracer.begin(.tool_call, TI.name, s.trace_id, &s.step_span);
                defer span.end();
                span.attr("tool", TI.name);
                var tctx: ToolCtx(Ctx) = .{
                    .ctx = @ptrCast(@alignCast(s.st.ctx)),
                    .arena = arena.allocator(),
                    .io = s.st.io,
                    .run_id = s.run_id,
                    .tool_call_id = c.id,
                    .trace = &span,
                };
                const input = @field(c.parsed.?, TI.name);
                if (TI.Tool.execute(&tctx, input)) |out| {
                    c.content = json.stringifyAlloc(arena.allocator(), out) catch {
                        c.fatal = error.OutOfMemory;
                        return;
                    };
                } else |err| {
                    if (modelErrorMessage(TI, err)) |m| {
                        c.content = m;
                        c.is_error = true;
                        span.attr("model_error", @errorName(err));
                    } else {
                        span.fail(@errorName(err));
                        c.fatal = err;
                    }
                }
            };
        }

        fn modelErrorMessage(comptime TI: type, err: anyerror) ?[]const u8 {
            const set = @typeInfo(TI.ModelErrors).error_set orelse return null;
            inline for (set) |e| if (std.mem.eql(u8, @errorName(err), e.name)) return @field(TI.Tool.error_messages, e.name);
            return null;
        }

        fn freeCallArenas(s: *Self) void {
            for (s.calls.items) |*c| if (c.arena) |a| {
                a.deinit();
                s.st.gpa.destroy(a);
                c.arena = null;
            };
        }

        fn endStep(s: *Self, usage: msg.Usage, reason: msg.FinishReason) Error!void {
            if (s.step_open) {
                s.step_span.end();
                s.step_open = false;
            }
            try s.push(@unionInit(A.Event, "step_finish", ev.StepFinish{ .index = s.step, .reason = reason, .usage = usage }));
            s.step += 1;
        }

        fn finishRun(s: *Self, reason: msg.FinishReason) Error!void {
            s.finish_reason = reason;
            try s.save();
            s.run_span.attr("steps", s.step);
            s.run_span.attr("input_tokens", s.usage.input_tokens);
            s.run_span.attr("output_tokens", s.usage.output_tokens);
            s.run_span.attr("cost_usd", s.usage.cost_usd);
            s.run_span.attr("finish_reason", @tagName(reason));
            if (s.step_open) {
                s.step_span.end();
                s.step_open = false;
            }
            s.run_span.end();
            try s.push(@unionInit(A.Event, "finish", ev.Finish{ .reason = reason, .steps = s.step, .usage = s.usage }));
            s.phase = .done;
            s.saveStatus(if (reason == .canceled) "canceled" else "completed");
        }

        fn save(s: *Self) Error!void {
            const store = s.st.storage orelse return;
            const now = s.st.nowMs();
            if (A.history_messages > 0) if (s.opts.thread) |thread| {
                const new = s.messages.items[s.new_from..];
                const rows = try s.arena.alloc([]const u8, new.len);
                for (new, 0..) |m, i| rows[i] = try msg.toJson(s.arena, m);
                store.appendMessages(thread, s.opts.resource, rows, now) catch |err| {
                    s.diag.print(0, "agent '{s}': saving history for thread '{s}': {t}", .{ A.id, thread, err });
                    return error.StorageFailed;
                };
            };
            if (A.has_working_memory and s.working_dirty) if (s.opts.resource) |res| {
                const value = try json.stringifyAlloc(s.arena, s.working);
                store.putWorkingMemory(res, A.id, A.working_fingerprint, value, now) catch |err| {
                    s.diag.print(0, "agent '{s}': saving working memory for '{s}': {t}", .{ A.id, res, err });
                    return error.StorageFailed;
                };
            };
        }
    };
}

/// `generate`: run to completion and collect the result. An agent with
/// approval-gated tools returns `.suspended` (after saving the run) when a
/// call needs a decision and there's no `on_approval`.
pub fn generate(comptime A: type, st: *runtime.State, arena: Allocator, input: []const Message, opts: Options(A)) Error!Result(A) {
    const s = try Stream(A).init(st, arena, input, opts);
    defer s.deinit();
    if (A.partial_output) s.partial.on = false;
    return drive(A, s, opts);
}

fn drive(comptime A: type, s: *Stream(A), opts: Options(A)) Error!Result(A) {
    while (true) {
        const e = s.next() catch |err| {
            if (comptime A.has_approvals) if (err == error.ApprovalPending) return .{ .suspended = try s.suspendRun() };
            return err;
        } orelse break;
        if (comptime A.has_approvals) switch (e) {
            inline else => |payload, tag| if (comptime std.mem.eql(u8, @tagName(tag), "approval_request")) {
                if (opts.on_approval) |decide| try s.respond(payload.id, decide.decide(decide.ctx, payload.call));
            },
        };
    }
    const r = try s.result();
    return if (comptime A.has_approvals) .{ .completed = r } else r;
}

/// One decision for `resumeRun`/`resumeStream`.
pub const ApprovalDecision = struct {
    /// The request id from `Suspended.requests` or an `approval_request` event.
    id: []const u8,
    decision: ev.Decision,
};

/// Load a suspended run, check it, claim it and apply `decisions`.
fn reopen(comptime A: type, st: *runtime.State, arena: Allocator, run_id: []const u8, decisions: []const ApprovalDecision) Error!*Stream(A) {
    const store = st.storage orelse return error.StorageFailed;
    const rec = (store.loadRun(arena, run_id) catch |err| {
        st.diagPrint("agent '{s}': loading run '{s}': {t}", .{ A.id, run_id, err });
        return error.StorageFailed;
    }) orelse {
        st.diagPrint("agent '{s}': no saved run '{s}'", .{ A.id, run_id });
        return error.RunNotFound;
    };
    if (rec.kind != .agent or !std.mem.eql(u8, rec.owner_id, A.id)) {
        st.diagPrint("run '{s}' belongs to {t} '{s}', not agent '{s}'", .{ run_id, rec.kind, rec.owner_id, A.id });
        return error.WrongAgent;
    }
    if (!std.mem.eql(u8, rec.status, "suspended")) {
        st.diagPrint("agent '{s}' run '{s}' is {s}, not suspended", .{ A.id, run_id, rec.status });
        return if (std.mem.eql(u8, rec.status, "running")) error.RunBusy else error.NotSuspended;
    }
    var issue: parse.Issue = .{};
    const snap = parse.parse(Snapshot, arena, rec.state_json, &issue) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        error.ValidationFailed => {
            st.diagPrint("agent '{s}' run '{s}': saved run doesn't parse: {f}", .{ A.id, run_id, issue });
            return error.CorruptSnapshot;
        },
    };
    if (rec.fingerprint != A.run_fingerprint and !migratable(A, snap)) {
        st.diagPrint("agent '{s}' run '{s}' was saved by a different version of the agent: {f}. Deny its approvals and start a new run", .{ A.id, run_id, Changes(A){ .saved = snap.tools } });
        return error.SnapshotIncompatible;
    }
    const s = Stream(A).restore(st, arena, try arena.dupe(u8, run_id), snap) catch |err| {
        if (err == error.CorruptSnapshot) st.diagPrint("agent '{s}' run '{s}': saved run is inconsistent", .{ A.id, run_id });
        return err;
    };
    errdefer s.deinit();
    // Check every id before claiming, so a typo changes nothing.
    for (decisions) |d| {
        const known = for (s.calls.items) |c| {
            if (c.approval == .pending and std.mem.eql(u8, c.id, d.id)) break true;
        } else false;
        if (!known) {
            s.diag.print(0, "agent '{s}' run '{s}': no pending approval '{s}'; pending: {f}", .{ A.id, run_id, d.id, Stream(A).PendingIds{ .calls = s.calls.items } });
            st.setDiag(&s.diag);
            return error.UnknownApproval;
        }
    }
    const claimed = store.claimRun(run_id, "suspended", "running", st.nowMs()) catch return error.StorageFailed;
    if (!claimed) {
        st.diagPrint("agent '{s}' run '{s}' is already being resumed", .{ A.id, run_id });
        return error.RunBusy;
    }
    for (decisions) |d| try s.respond(d.id, d.decision);
    return s;
}

/// A run saved before a working-memory change that `z.migrate` covers: the
/// rest of the agent is unchanged, and the saved shape is in the chain.
fn migratable(comptime A: type, snap: Snapshot) bool {
    if (comptime !(A.has_working_memory and migrate.has(A.Working))) return false;
    const core = std.fmt.parseInt(u64, snap.core_hash orelse return false, 16) catch return false;
    if (core != A.run_core_fingerprint) return false;
    const fp = std.fmt.parseInt(u64, snap.working_fingerprint orelse return false, 16) catch return false;
    if (fp == A.working_fingerprint) return true;
    inline for (A.Working.migrations) |M| if (M.from_fingerprint == fp) return true;
    return false;
}

/// What changed between a saved run's agent and the current one.
fn Changes(comptime A: type) type {
    return struct {
        saved: []const ToolPrint,
        pub fn format(c: @This(), w: *std.Io.Writer) std.Io.Writer.Error!void {
            var n: usize = 0;
            for (A.tool_prints) |now| {
                const old = for (c.saved) |o| {
                    if (std.mem.eql(u8, o.name, now.name)) break o;
                } else null;
                if (old == null) {
                    try w.print("{s}tool '{s}' was added", .{ if (n > 0) "; " else "", now.name });
                    n += 1;
                } else if (!std.mem.eql(u8, old.?.hash, now.hash)) {
                    try w.print("{s}tool '{s}' changed", .{ if (n > 0) "; " else "", now.name });
                    n += 1;
                }
            }
            for (c.saved) |o| {
                const still = for (A.tool_prints) |now| {
                    if (std.mem.eql(u8, o.name, now.name)) break true;
                } else false;
                if (!still) {
                    try w.print("{s}tool '{s}' was removed", .{ if (n > 0) "; " else "", o.name });
                    n += 1;
                }
            }
            if (n == 0) try w.writeAll("its instructions, model or settings changed");
        }
    };
}

/// Resume a suspended run with decisions for some or all of its pending
/// approvals (D33): with some still pending it's saved again and returned
/// as `.suspended`; otherwise it runs on (and may suspend again).
pub fn resumeRun(comptime A: type, st: *runtime.State, arena: Allocator, run_id: []const u8, decisions: []const ApprovalDecision) Error!RunResult(A) {
    const s = try reopen(A, st, arena, run_id, decisions);
    defer s.deinit();
    if (s.pending > 0) return .{ .suspended = try s.suspendRun() };
    return drive(A, s, .{});
}

/// Like `resumeRun`, streaming. Approvals still pending are emitted again
/// as `approval_request` events first.
pub fn resumeStream(comptime A: type, st: *runtime.State, arena: Allocator, run_id: []const u8, decisions: []const ApprovalDecision) Error!*Stream(A) {
    const s = try reopen(A, st, arena, run_id, decisions);
    try s.requeuePending();
    return s;
}

/// Abandon a suspended run: it's marked `canceled` and can't be resumed.
pub fn cancelRun(comptime A: type, st: *runtime.State, arena: Allocator, run_id: []const u8) Error!void {
    const store = st.storage orelse return error.StorageFailed;
    const rec = (store.loadRun(arena, run_id) catch return error.StorageFailed) orelse {
        st.diagPrint("agent '{s}': no saved run '{s}'", .{ A.id, run_id });
        return error.RunNotFound;
    };
    if (rec.kind != .agent or !std.mem.eql(u8, rec.owner_id, A.id)) {
        st.diagPrint("run '{s}' belongs to {t} '{s}', not agent '{s}'", .{ run_id, rec.kind, rec.owner_id, A.id });
        return error.WrongAgent;
    }
    if (!(store.claimRun(run_id, "suspended", "canceled", st.nowMs()) catch return error.StorageFailed)) {
        st.diagPrint("agent '{s}' run '{s}' is {s}, not suspended", .{ A.id, run_id, rec.status });
        return if (std.mem.eql(u8, rec.status, "running")) error.RunBusy else error.NotSuspended;
    }
}
