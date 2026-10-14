//! Step-level declarations (PLAN.md §6.6): `z.StepCtx`, `z.Suspendable`,
//! `z.Retry`, `z.initial`, `z.otherwise`, `z.step.agent`, `z.step.parallel`.

const std = @import("std");
const errors = @import("../meta/errors.zig");
const reflect = @import("../meta/reflect.zig");
const make = @import("../meta/make.zig");
const template = @import("../prompt/template.zig");
const agent_mod = @import("../agent/agent.zig");
const run = @import("../agent/run.zig");
const runtime = @import("../runtime.zig");
const trace = @import("../trace/trace.zig");
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

pub fn isWorkflow(comptime T: type) bool {
    return @TypeOf(T) == type and reflect.isContainer(T) and @hasDecl(T, "zastra_workflow");
}

pub fn isParallel(comptime T: type) bool {
    return @TypeOf(T) == type and reflect.isContainer(T) and @hasDecl(T, "zastra_parallel");
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
        if (info.params.len != 2) errors.fail("step '{s}': `run` takes {d} parameters; expected `run(w: *z.StepCtx(Ctx, @This()), in: Input)`", .{ id, info.params.len });
        if (info.params[0].type) |P| if (P != *StepCtx(Ctx, S))
            errors.fail("step '{s}': `run`'s first parameter is {s}; expected *z.StepCtx({s}, @This())", .{ id, @typeName(P), reflect.shortTypeName(Ctx) });
        if (info.params[1].type) |P| if (P != S.Input)
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
        for (std.meta.fields(N)) |f| {
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
        trace_id: [16]u8,

        /// Format into `arena`.
        pub fn fmt(w: *Self, comptime f: []const u8, args: anytype) Allocator.Error![]u8 {
            return std.fmt.allocPrint(w.arena, f, args);
        }

        /// Call an agent from this step. History is scoped to this run and
        /// step (`"<run_id>/<step_id>"`), working memory to the workflow's
        /// `resource` (PLAN.md D17).
        pub fn agent(w: *Self, comptime A: type) AgentCall(A) {
            if (A.has_approvals) {
                comptime var gated: []const u8 = "";
                inline for (A.tools) |TI| if (TI.approval_kind != .never and gated.len == 0) {
                    gated = TI.name;
                };
                errors.fail("step '{s}' calls agent '{s}', which has approval-gated tool '{s}'. Agents in workflow steps can't pause for approval in v1; move the approval into a step with `Suspend`/`Resume`, or use an agent without gated tools (PLAN.md D18)", .{ idOf(S), A.id, gated });
            }
            return .{ .w = w };
        }

        pub fn AgentCall(comptime A: type) type {
            return struct {
                w: *Self,
                pub fn generate(c: @This(), input: anytype, opts: run.Options(A)) run.Error!run.GenerateResult(A) {
                    var o = opts;
                    if (o.thread == null) o.thread = try std.fmt.allocPrint(c.w.arena, "{s}/{s}", .{ c.w.run_id, c.w.step_id });
                    if (o.resource == null) o.resource = c.w.resource;
                    if (o.trace_parent == null) o.trace_parent = c.w.trace;
                    if (o.trace_id == null) o.trace_id = c.w.trace_id;
                    const msgs = try run.toMessages(c.w.arena, input);
                    return run.generate(A, c.w.state, c.w.arena, msgs, o);
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
        if (A.has_approvals) errors.fail("step '{s}' uses agent '{s}', which has approval-gated tools. Agents in workflow steps can't pause for approval in v1; move the approval into a step with `Suspend`/`Resume`, or use an agent without gated tools (PLAN.md D18)", .{ step_name, A.id });
        const Out = if (A.has_output_type) A.Output else []const u8;
        return struct {
            const Self = @This();
            pub const Input = In;
            pub const Output = Out;
            pub const name = step_name;
            pub const zastra_agent_step = A;

            pub fn run(w: *StepCtx(A.Ctx, Self), in: Input) !Output {
                const text = if (@hasField(@TypeOf(opts), "prompt"))
                    try template.renderAlloc(In, prompt, w.arena, in)
                else
                    try @import("../schema/json.zig").stringifyAlloc(w.arena, in);
                const r = try w.agent(A).generate(text, .{});
                return if (A.has_output_type) r.output else r.text;
            }
        };
    }
}

/// `z.step.parallel(.{ .order = FetchOrder, .faq = SearchFaq })`: run steps
/// concurrently on the same Input. Output is a struct keyed like the input.
pub fn parallel(comptime branches: anytype) type {
    comptime {
        const B = @TypeOf(branches);
        if (@typeInfo(B) != .@"struct" or reflect.isTuple(B) or std.meta.fields(B).len == 0)
            errors.fail("z.step.parallel(...) takes a struct literal of named steps, like `.{{ .order = FetchOrder, .faq = SearchFaq }}`", .{});
        const fields = std.meta.fields(B);
        const First = @field(branches, fields[0].name);
        var names: []const []const u8 = &.{};
        var outs: []const type = &.{};
        var id: []const u8 = "parallel";
        for (fields) |f| {
            const S = @field(branches, f.name);
            if (@TypeOf(S) != type or isWorkflow(S) or isParallel(S)) errors.fail("z.step.parallel: `.{s}` must be a step type (workflows and nested parallel groups aren't supported inside parallel in v1)", .{f.name});
            if (!@hasDecl(S, "Input")) errors.fail("z.step.parallel: `.{s}` ({s}) is not a step", .{ f.name, @typeName(S) });
            if (S.Input != First.Input) errors.fail("z.step.parallel: every branch must accept the same Input; `.{s}` takes {s}, but `.{s}` takes {s}", .{
                f.name, @typeName(S.Input), fields[0].name, @typeName(First.Input),
            });
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
