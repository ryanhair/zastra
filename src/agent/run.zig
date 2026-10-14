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
const trace = @import("../trace/trace.zig");
const ToolCtx = @import("../context.zig").ToolCtx;
const agent_mod = @import("agent.zig");
const ev = @import("events.zig");
const Allocator = std.mem.Allocator;
const Message = msg.Message;

pub const Error = provider.Error || error{
    /// A tool needs a decision; call `respond` for each pending approval.
    ApprovalPending,
    /// `generate` hit an approval-gated call without `on_approval`.
    ApprovalRequired,
    /// `respond` with an id that isn't pending.
    UnknownApproval,
    /// Structured output failed validation after the repair attempt.
    OutputInvalid,
    /// The provider's API key isn't in the environment.
    MissingApiKey,
    /// Stored history or working memory couldn't be read.
    StorageFailed,
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
        /// For `generate`: decide approvals inline instead of returning
        /// `error.ApprovalRequired`.
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
            };
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
            return error.UnknownApproval;
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
                                .text => |t| if (t.len > 0) return @unionInit(A.Event, "text_delta", t),
                                .reasoning => |t| return @unionInit(A.Event, "reasoning_delta", t),
                                else => {},
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
            }
        }

        fn push(s: *Self, e: A.Event) Allocator.Error!void {
            try s.queue.append(s.arena, e);
        }

        fn start(s: *Self) Error!void {
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
                            std.log.warn("zastra: agent '{s}': working memory for '{s}' was saved with a different {s} shape; starting from defaults", .{ A.id, res, @typeName(A.Working) });
                        } else {
                            var issue: parse.Issue = .{};
                            s.working = parse.parse(A.Working, s.arena, w.value_json, &issue) catch blk: {
                                std.log.warn("zastra: agent '{s}': working memory for '{s}' didn't parse ({f}); starting from defaults", .{ A.id, res, issue });
                                break :blk .{};
                            };
                        }
                    }
                };
                s.system_suffix = try std.fmt.allocPrint(s.arena,
                    "Working memory (what you know about this user; update it with `{s}`):\n{f}", .{ agent_mod.working_memory_tool, json.fmt(s.working) });
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
            s.step_span = s.st.tracer.begin(.agent_step, A.id, s.trace_id, &s.run_span);
            s.step_span.attr("step", s.step);
            s.step_open = true;
            s.model_span = s.st.tracer.begin(.model_call, comptime spec.fullName(), s.trace_id, &s.step_span);
            s.model_span.attr("model", comptime spec.fullName());
            s.model_span.attr("prefix_hash", A.prefix_hash);

            const prefix = if (A.mcp_tools.len > 0) (s.st.prefixes.get(A.id) orelse A.prefix) else A.prefix;
            const req: provider.Request = .{
                .base_url = s.st.baseUrl(spec),
                .api_key = key,
                .prefix = prefix,
                .system_suffix = s.system_suffix,
                .messages = s.messages.items,
                .max_tokens = s.opts.max_tokens orelse A.max_tokens_default,
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

/// `generate`: run to completion and collect the result.
pub fn generate(comptime A: type, st: *runtime.State, arena: Allocator, input: []const Message, opts: Options(A)) Error!GenerateResult(A) {
    const s = try Stream(A).init(st, arena, input, opts);
    defer s.deinit();
    while (try s.next()) |e| {
        if (comptime A.has_approvals) switch (e) {
            inline else => |payload, tag| if (comptime std.mem.eql(u8, @tagName(tag), "approval_request")) {
                const decide = opts.on_approval orelse {
                    s.diag.print(0, "agent '{s}': tool call needs approval ({t}); use `stream` and `respond`, or pass `.on_approval` to generate", .{ A.id, std.meta.activeTag(payload.call) });
                    st.setDiag(&s.diag);
                    return error.ApprovalRequired;
                };
                try s.respond(payload.id, decide.decide(decide.ctx, payload.call));
            },
        };
    }
    return s.result();
}
