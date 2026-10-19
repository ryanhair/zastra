//! Step-level declarations (PLAN.md §6.6): `z.StepCtx`, `z.Suspendable`,
//! `z.Retry`, `z.initial`, `z.otherwise`, `z.step.agent`, `z.step.parallel`.

const std = @import("std");
const errors = @import("../meta/errors.zig");
const reflect = @import("../meta/reflect.zig");
const make = @import("../meta/make.zig");
const template = @import("../prompt/template.zig");
const agent_mod = @import("../agent/agent.zig");
const agent_run = @import("../agent/run.zig");
const runs = @import("../runs.zig");
const runtime = @import("../runtime.zig");
const trace = @import("../trace/trace.zig");
const ev = @import("../agent/events.zig");
const Allocator = std.mem.Allocator;

pub const known_step_decls = [_][]const u8{ "Input", "Output", "run", "name", "Suspend", "Resume", "needs", "retry", "retry_on", "timeout_ms" };

/// `z.initial(T)`: the input of the innermost workflow containing the step,
/// as a `needs` entry. `T` must equal that workflow's Input (checked at
/// `.commit()`).
pub fn initial(comptime T: type) type {
    return struct {
        pub const zastra_initial = true;
        pub const Type = T;
    };
}

pub fn isInitial(comptime T: type) bool {
    return @TypeOf(T) == type and reflect.isContainer(T) and @hasDecl(T, "zastra_initial");
}

/// The default arm of a `.branch(...)`; must be last.
pub const otherwise = struct {
    pub const zastra_otherwise = true;
};

pub const Backoff = union(enum) {
    none,
    fixed: u32,
    exponential: u32,

    pub fn exponentialMs(base_ms: u32) Backoff {
        return .{ .exponential = base_ms };
    }

    pub fn delayMs(b: Backoff, attempt: u32) u64 {
        return switch (b) {
            .none => 0,
            .fixed => |ms| ms,
            .exponential => |ms| @as(u64, ms) << @intCast(@min(attempt, 16)),
        };
    }
};

/// Per-step retry policy: `pub const retry = z.Retry{ .attempts = 3, .backoff = .{ .exponential = 200 } }`.
pub const Retry = struct {
    /// Total attempts, including the first.
    attempts: u32 = 1,
    backoff: Backoff = .none,
};

/// The return type of a suspendable step's `run`.
pub fn Suspendable(comptime S: type) type {
    if (!@hasDecl(S, "Suspend") or !@hasDecl(S, "Resume"))
        errors.fail("z.Suspendable({s}): the step needs both `pub const Suspend` and `pub const Resume`", .{reflect.shortTypeName(S)});
    return union(enum) {
        done: S.Output,
        suspended: S.Suspend,
    };
}

/// `z.Approvals(A)`: what a step that runs approval-gated agent `A` suspends
/// with (D34). Declare `pub const Suspend = z.Approvals(A);` and
/// `pub const Resume = z.Decisions(A);`.
pub fn Approvals(comptime A: type) type {
    comptime {
        if (!agent_mod.isAgent(A)) errors.fail("z.Approvals(A): A must be an agent created with z.Agent", .{});
        if (!A.has_approvals) errors.fail("z.Approvals({s}): agent '{s}' has no approval-gated tools, so it never needs approvals", .{ A.id, A.id });
        return struct {
            pub const zastra_approvals_of = A;
            /// The calls waiting for a decision, typed per tool.
            requests: []const ev.ApprovalRequest(A.ApprovalCall),
        };
    }
}

/// `z.Decisions(A)`: how a step suspended with `z.Approvals(A)` is resumed.
/// Requests left out stay pending, and the step suspends again with them.
pub fn Decisions(comptime A: type) type {
    _ = Approvals(A);
    return ApprovalDecisions;
}

pub const ApprovalDecisions = struct {
    /// Request ids to approve.
    approve: []const []const u8 = &.{},
    /// Request ids to deny, with the reason the model sees.
    deny: []const Denial = &.{},

    pub const Denial = struct { id: []const u8, reason: []const u8 };

    pub fn toList(d: ApprovalDecisions, arena: Allocator) Allocator.Error![]const agent_run.ApprovalDecision {
        const out = try arena.alloc(agent_run.ApprovalDecision, d.approve.len + d.deny.len);
        for (d.approve, 0..) |id, i| out[i] = .{ .id = id, .decision = .approve };
        for (d.deny, 0..) |x, i| out[d.approve.len + i] = .{ .id = x.id, .decision = .{ .deny = x.reason } };
        return out;
    }
};

/// `z.step.agentOf(A)`: names the `z.step.agent(A, ...)` step in
/// `resumeStep` without keeping its type around.
pub fn agentOf(comptime A: type) type {
    return struct {
        pub const zastra_agent_of = A;
    };
}

pub fn isWorkflow(comptime T: type) bool {
    return @TypeOf(T) == type and reflect.isContainer(T) and @hasDecl(T, "zastra_workflow");
}

pub fn isParallel(comptime T: type) bool {
    return @TypeOf(T) == type and reflect.isContainer(T) and @hasDecl(T, "zastra_parallel");
}

pub fn isLoop(comptime T: type) bool {
    return @TypeOf(T) == type and reflect.isContainer(T) and @hasDecl(T, "zastra_loop");
}

pub fn isSuspendable(comptime S: type) bool {
    return reflect.isContainer(S) and @hasDecl(S, "Suspend") and @hasDecl(S, "Resume");
}

/// A step's id: `pub const name`, else snake_case of the type name.
pub fn idOf(comptime S: type) []const u8 {
    return comptime idOfImpl(S);
}

fn idOfImpl(comptime S: type) []const u8 {
    if (isWorkflow(S)) return S.id;
    if (@hasDecl(S, "name")) return S.name;
    return reflect.snakeCase(reflect.shortTypeName(S));
}

/// Validate a plain step type (not a workflow or parallel group).
pub fn checkStep(comptime S: type, comptime Ctx: type) void {
    comptime {
        const id = if (reflect.isContainer(S)) idOf(S) else @typeName(S);
        if (!reflect.isContainer(S)) errors.fail("{s} is not a step: steps are struct types with `Input`, `Output` and `run`", .{@typeName(S)});
        reflect.checkDeclTypos(S, &known_step_decls, "step", id);
        for ([_][]const u8{ "Input", "Output", "run" }) |d| if (!@hasDecl(S, d))
            errors.fail("step '{s}' is missing `pub const {s}`{s}", .{ id, d, if (std.mem.eql(u8, d, "run")) " (`pub fn run(w: *z.StepCtx(Ctx, @This()), in: Input) !Output`)" else "" });
        if (@hasDecl(S, "Suspend") != @hasDecl(S, "Resume"))
            errors.fail("step '{s}' declares only one of `Suspend` and `Resume`; suspendable steps need both", .{id});
        const F = @TypeOf(S.run);
        if (@typeInfo(F) != .@"fn") errors.fail("step '{s}': `run` must be a function", .{id});
        const info = @typeInfo(F).@"fn";
        if (info.param_types.len != 2) errors.fail("step '{s}': `run` takes {d} parameters; expected `run(w: *z.StepCtx(Ctx, @This()), in: Input)`", .{ id, info.param_types.len });
        if (info.param_types[0]) |P| if (P != *StepCtx(Ctx, S))
            errors.fail("step '{s}': `run`'s first parameter is {s}; expected *z.StepCtx({s}, @This())", .{ id, @typeName(P), reflect.shortTypeName(Ctx) });
        if (info.param_types[1]) |P| if (P != S.Input)
            errors.fail("step '{s}': `run`'s second parameter is {s}; expected Input ({s})", .{ id, @typeName(P), @typeName(S.Input) });
        const R = info.return_type.?;
        const payload = switch (@typeInfo(R)) {
            .error_union => |eu| eu.payload,
            else => R,
        };
        const want = if (isSuspendable(S)) Suspendable(S) else S.Output;
        if (payload != want) errors.fail("step '{s}': `run` returns {s}; expected !{s}", .{
            id, @typeName(R), if (isSuspendable(S)) "z.Suspendable(@This())" else "Output",
        });
        if (@hasDecl(S, "retry") and @TypeOf(S.retry) != Retry) errors.fail("step '{s}': `retry` must be a z.Retry", .{id});
        if (@hasDecl(S, "retry_on") and (@TypeOf(S.retry_on) != type or @typeInfo(S.retry_on) != .error_set))
            errors.fail("step '{s}': `retry_on` must be an error set", .{id});
        if (@hasDecl(S, "timeout_ms") and @typeInfo(@TypeOf(S.timeout_ms)) != .comptime_int and @typeInfo(@TypeOf(S.timeout_ms)) != .int)
            errors.fail("step '{s}': `timeout_ms` must be an integer", .{id});
        if (@hasDecl(S, "needs")) _ = NeedsOf(S);
    }
}

/// The typed `w.needs` struct for step `S`.
pub fn NeedsOf(comptime S: type) type {
    comptime {
        if (!@hasDecl(S, "needs")) return struct {};
        const N = @TypeOf(S.needs);
        if (@typeInfo(N) != .@"struct" or reflect.isTuple(N))
            errors.fail("step '{s}': `needs` must be a struct literal like `.{{ .ticket = Classify }}`", .{idOf(S)});
        var names: []const []const u8 = &.{};
        var types: []const type = &.{};
        for (reflect.fields(N)) |f| {
            const R = @field(S.needs, f.name);
            if (@TypeOf(R) != type) errors.fail("step '{s}': `needs.{s}` must be a step type or `z.initial(T)`", .{ idOf(S), f.name });
            const T = if (isInitial(R)) R.Type else if (reflect.isContainer(R) and @hasDecl(R, "Output")) R.Output else errors.fail("step '{s}': `needs.{s}` = {s}, which is not a step (no `Output`)", .{ idOf(S), f.name, @typeName(R) });
            names = names ++ &[_][]const u8{f.name};
            types = types ++ &[_]type{T};
        }
        return make.Struct(names, types);
    }
}

/// The context handed to a step's `run`.
pub fn StepCtx(comptime Ctx: type, comptime S: type) type {
    return struct {
        const Self = @This();
        pub const Resumed = if (isSuspendable(S)) ?S.Resume else void;

        ctx: *Ctx,
        /// The workflow run's arena: values returned from `run` may point into it.
        arena: Allocator,
        io: std.Io,
        run_id: []const u8,
        /// Typed results of earlier steps declared in `needs`.
        needs: NeedsOf(S),
        /// For suspendable steps: null on the first run, the resume value after
        /// `resumeStep`.
        resumed: Resumed,
        trace: *trace.Span,
        /// Internal.
        state: *runtime.State,
        step_id: []const u8,
        resource: ?[]const u8,
        trace_id: trace.TraceId,
        /// Internal: numbers this attempt's `w.agent(A).run` calls, for
        /// their saved run ids.
        agent_calls: u32 = 0,
        /// Internal: the retry attempt, part of those ids (D63).
        attempt: u32 = 0,
        /// Internal: `"@<i>"` per enclosing `z.step.loop` iteration, so a
        /// saved agent run belongs to one iteration (D46).
        iteration: []const u8 = "",

        /// Format into `arena`.
        pub fn fmt(w: *Self, comptime f: []const u8, args: anytype) Allocator.Error![]u8 {
            return w.arena.print(f, args);
        }

        /// Call an agent from this step. History is scoped to this run and
        /// step (`"<run_id>/<step_id>"`), working memory to the workflow's
        /// `resource` (PLAN.md D17).
        pub fn agent(w: *Self, comptime A: type) AgentCall(A) {
            return .{ .w = w };
        }

        pub fn AgentCall(comptime A: type) type {
            return struct {
                w: *Self,

                /// Run an agent without approval-gated tools to completion.
                pub fn generate(c: @This(), input: anytype, opts: agent_run.Options(A)) agent_run.Error!agent_run.GenerateResult(A) {
                    if (A.has_approvals) {
                        comptime var gated: []const u8 = "";
                        inline for (A.tools) |TI| if (TI.approval_kind != .never and gated.len == 0) {
                            gated = TI.name;
                        };
                        errors.fail("step '{s}' calls `w.agent({s}).generate`, but agent '{s}' has approval-gated tool '{s}'. Use `w.agent({s}).run(...)` and declare `pub const Suspend = z.Approvals({s});` and `pub const Resume = z.Decisions({s});` on the step, so the workflow can pause for the approval (PLAN.md D34)", .{ idOf(S), A.id, A.id, gated, A.id, A.id, A.id });
                    }
                    const msgs = try agent_run.toMessages(c.w.arena, input);
                    return agent_run.generate(A, c.w.state, c.w.arena, msgs, try c.options(opts));
                }

                pub const RunResult = union(enum) {
                    done: agent_run.GenerateResult(A),
                    suspended: Approvals(A),
                };

                /// Run an agent with approval-gated tools. Return
                /// `.{ .suspended = a }` from the step when it suspends. When
                /// the step is resumed and replayed, this call picks the saved
                /// agent run back up with the step's decisions, and calls that
                /// already finished return their saved results (D34).
                pub fn run(c: @This(), input: anytype, opts: agent_run.Options(A)) agent_run.Error!RunResult {
                    comptime {
                        if (!A.has_approvals) errors.fail("step '{s}' calls `w.agent({s}).run`, but agent '{s}' has no approval-gated tools; use `.generate(...)`", .{ idOf(S), A.id, A.id });
                        if (!isSuspendable(S) or S.Suspend != Approvals(A) or S.Resume != ApprovalDecisions)
                            errors.fail("step '{s}' calls `w.agent({s}).run`, so it must declare `pub const Suspend = z.Approvals({s});` and `pub const Resume = z.Decisions({s});`", .{ idOf(S), A.id, A.id, A.id });
                    }
                    const w = c.w;
                    const n = w.agent_calls;
                    w.agent_calls += 1;
                    const id = try runs.childId(w.arena, w.run_id, w.step_id, w.iteration, w.attempt, n);
                    var o = try c.options(opts);
                    o.run_id = id;
                    o.keep_result = true;
                    const found = try runs.findChild(w.state, w.arena, id, .{ .kind = .agent, .id = A.id });
                    const r: agent_run.RunResult(A) = if (found) |saved| blk: {
                        if (saved.status == .completed)
                            return .{ .done = try agent_run.loadKeptResult(A, w.arena, id, saved.state_json) };
                        // The step's decisions go to the first suspended call.
                        var decisions: []const agent_run.ApprovalDecision = &.{};
                        if (w.resumed) |d| {
                            decisions = try d.toList(w.arena);
                            w.resumed = null;
                        }
                        break :blk try agent_run.resumeRun(A, w.state, w.arena, id, decisions);
                    } else blk: {
                        const msgs = try agent_run.toMessages(w.arena, input);
                        break :blk try agent_run.generate(A, w.state, w.arena, msgs, o);
                    };
                    return switch (r) {
                        .completed => |done| .{ .done = done },
                        .suspended => |su| .{ .suspended = .{ .requests = su.requests } },
                    };
                }

                fn options(c: @This(), opts: agent_run.Options(A)) Allocator.Error!agent_run.Options(A) {
                    var o = opts;
                    if (o.thread == null) o.thread = try c.w.arena.print("{s}/{s}", .{ c.w.run_id, c.w.step_id });
                    if (o.resource == null) o.resource = c.w.resource;
                    if (o.trace_parent == null) o.trace_parent = c.w.trace;
                    if (o.trace_id == null) o.trace_id = c.w.trace_id;
                    return o;
                }
            };
        }
    };
}

/// `z.step.agent(A, .{ .input = T, .prompt = "...{field}..." })`: an agent as
/// a workflow step. The prompt is checked against `T` at comptime. The step's
/// Output is the agent's `.output` type, or the reply text.
pub fn agentStep(comptime A: type, comptime opts: anytype) type {
    comptime {
        if (!agent_mod.isAgent(A)) errors.fail("z.step.agent(A, ...): A must be an agent created with z.Agent", .{});
        reflect.checkConfigFields(@TypeOf(opts), &.{ "input", "prompt", "name" }, "z.step.agent(...) options");
        if (!@hasField(@TypeOf(opts), "input")) errors.fail("z.step.agent({s}, ...): `.input` (the step's Input type) is required", .{A.id});
        const In = opts.input;
        const prompt: []const u8 = if (@hasField(@TypeOf(opts), "prompt")) opts.prompt else "{" ++ "}";
        const step_name: []const u8 = if (@hasField(@TypeOf(opts), "name")) opts.name else A.id;
        if (@hasField(@TypeOf(opts), "prompt")) template.check(In, prompt, "step '" ++ step_name ++ "'");
        const Out = if (A.has_output_type) A.Output else []const u8;
        const promptText = PromptText(In, opts).render;
        if (A.has_approvals) return struct {
            // An agent with approval-gated tools pauses the workflow for its
            // approvals (D34).
            const Self = @This();
            pub const Input = In;
            pub const Output = Out;
            pub const name = step_name;
            pub const zastra_agent_step = A;
            pub const Suspend = Approvals(A);
            pub const Resume = ApprovalDecisions;

            pub fn run(w: *StepCtx(A.Ctx, Self), in: Input) !Suspendable(Self) {
                const r = try w.agent(A).run(try promptText(w.arena, in), .{});
                return switch (r) {
                    .done => |d| .{ .done = if (A.has_output_type) d.output else d.text },
                    .suspended => |a| .{ .suspended = a },
                };
            }
        };
        return struct {
            const Self = @This();
            pub const Input = In;
            pub const Output = Out;
            pub const name = step_name;
            pub const zastra_agent_step = A;

            pub fn run(w: *StepCtx(A.Ctx, Self), in: Input) !Output {
                const r = try w.agent(A).generate(try promptText(w.arena, in), .{});
                return if (A.has_output_type) r.output else r.text;
            }
        };
    }
}

fn PromptText(comptime In: type, comptime opts: anytype) type {
    return struct {
        fn render(arena: Allocator, in: In) ![]const u8 {
            if (@hasField(@TypeOf(opts), "prompt")) return template.renderAlloc(In, opts.prompt, arena, in);
            return @import("../schema/json.zig").stringifyAlloc(arena, in);
        }
    };
}

/// `z.step.parallel(.{ .order = FetchOrder, .faq = SearchFaq })`: run steps
/// concurrently on the same Input. Output is a struct keyed like the input.
pub fn parallel(comptime branches: anytype) type {
    comptime {
        const B = @TypeOf(branches);
        if (@typeInfo(B) != .@"struct" or reflect.isTuple(B) or reflect.fields(B).len == 0)
            errors.fail("z.step.parallel(...) takes a struct literal of named steps, like `.{{ .order = FetchOrder, .faq = SearchFaq }}`", .{});
        const fields = reflect.fields(B);
        const First = @field(branches, fields[0].name);
        var names: []const []const u8 = &.{};
        var outs: []const type = &.{};
        var id: []const u8 = "parallel";
        for (fields) |f| {
            const S = @field(branches, f.name);
            if (@TypeOf(S) != type or isWorkflow(S) or isParallel(S) or isLoop(S)) errors.fail("z.step.parallel: `.{s}` must be a step type (workflows, loops and nested parallel groups aren't supported inside parallel)", .{f.name});
            if (!@hasDecl(S, "Input")) errors.fail("z.step.parallel: `.{s}` ({s}) is not a step", .{ f.name, @typeName(S) });
            if (S.Input != First.Input) errors.fail("z.step.parallel: every branch must accept the same Input; `.{s}` takes {s}, but `.{s}` takes {s}", .{
                f.name, @typeName(S.Input), fields[0].name, @typeName(First.Input),
            });
            if (@hasDecl(S, "zastra_agent_step") and S.zastra_agent_step.has_approvals)
                errors.fail("z.step.parallel: `.{s}` runs agent '{s}', which has approval-gated tools; parallel branches can't pause for approval. Run it as its own step before or after the group (PLAN.md D34)", .{ f.name, S.zastra_agent_step.id });
            if (isSuspendable(S)) errors.fail("z.step.parallel: `.{s}` is suspendable; steps inside a parallel group can't suspend in v1", .{f.name});
            names = names ++ &[_][]const u8{f.name};
            outs = outs ++ &[_]type{S.Output};
            id = id ++ "_" ++ f.name;
        }
        const Out = make.Struct(names, outs);
        const final_id = id;
        return struct {
            pub const zastra_parallel = true;
            pub const Input = First.Input;
            pub const Output = Out;
            pub const name = final_id;
            pub const steps = branches;
        };
    }
}

pub const LoopLimit = enum {
    /// Fail the run with `error.LoopLimit`.
    fail,
    /// Return the last iteration's value.
    finish,
};

/// `z.step.loop(Body, .{ .until = done, .max = 5 })`: run `Body` (a step,
/// a parallel group or a workflow whose Input equals its Output) until
/// `until(value)` is true, at most `max` times (PLAN.md §18.3, D45). The
/// body always runs at least once. `.on_limit = .finish` returns the last
/// value when `max` is reached instead of failing with `error.LoopLimit`.
pub fn loop(comptime Body: anytype, comptime opts: anytype) type {
    comptime {
        if (@TypeOf(Body) != type or !reflect.isContainer(Body) or !@hasDecl(Body, "Input") or !@hasDecl(Body, "Output"))
            errors.fail("z.step.loop(Body, ...): Body must be a step, a parallel group or a workflow", .{});
        reflect.checkConfigFields(@TypeOf(opts), &.{ "until", "max", "on_limit", "name" }, "z.step.loop(...) options");
        const body_id = idOf(Body);
        if (Body.Input != Body.Output)
            errors.fail("z.step.loop: body '{s}' takes `{s}` but returns `{s}`; a loop feeds each iteration's output into the next, so they must match. Wrap the body in a workflow that ends with a step converting back to `{s}`", .{
                body_id, reflect.shortTypeName(Body.Input), reflect.shortTypeName(Body.Output), reflect.shortTypeName(Body.Input),
            });
        if (!@hasField(@TypeOf(opts), "max"))
            errors.fail("z.step.loop({s}, ...): `.max` is required (the most iterations to run); every loop must end. A bound decided at runtime goes in `.until`", .{body_id});
        const max_iters = opts.max;
        if (@typeInfo(@TypeOf(max_iters)) != .comptime_int and @typeInfo(@TypeOf(max_iters)) != .int)
            errors.fail("z.step.loop({s}, ...): `.max` must be an integer", .{body_id});
        if (max_iters < 1) errors.fail("z.step.loop({s}, ...): `.max` must be at least 1", .{body_id});
        if (!@hasField(@TypeOf(opts), "until"))
            errors.fail("z.step.loop({s}, ...): `.until` is required: `fn ({s}) bool`, checked after each iteration", .{ body_id, reflect.shortTypeName(Body.Output) });
        const F = @TypeOf(opts.until);
        const ok = switch (@typeInfo(F)) {
            .@"fn" => |f| f.param_types.len == 1 and f.param_types[0] == Body.Output and f.return_type == bool,
            else => false,
        };
        if (!ok) errors.fail("z.step.loop({s}, ...): `.until` must be `fn ({s}) bool`, got {s}", .{ body_id, reflect.shortTypeName(Body.Output), @typeName(F) });
        const on_limit: LoopLimit = if (@hasField(@TypeOf(opts), "on_limit")) opts.on_limit else .fail;
        const loop_name: []const u8 = if (@hasField(@TypeOf(opts), "name")) opts.name else "loop_" ++ body_id;
        return struct {
            pub const zastra_loop = true;
            pub const Input = Body.Input;
            pub const Output = Body.Output;
            pub const name = loop_name;
            pub const body = Body;
            pub const until = opts.until;
            pub const max: u32 = max_iters;
            pub const limit = on_limit;
            /// Stored between iterations: how many finished, and the latest value.
            pub const Progress = struct { iter: u32, value: Body.Output };
        };
    }
}
