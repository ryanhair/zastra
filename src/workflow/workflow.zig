//! `z.Workflow(Ctx, "name", Input)`: the comptime builder (PLAN.md §5.7, §5.8,
//! §6.6, D13).
//!
//!     z.Workflow(Ctx, "handle_ticket", Ticket)
//!         .then(Classify)
//!         .branch(.{ .{ wantsRefund, RefundPath }, .{ z.otherwise, AnswerPath } })
//!         .then(NotifyCustomer)
//!         .commit();
//!
//! `.commit()` returns a type. It checks type flow as the chain is built, and
//! derives the graph analysis (`needs` dominance, suspension points), the run
//! state struct, the fingerprint and a Mermaid diagram.

const std = @import("std");
const errors = @import("../meta/errors.zig");
const reflect = @import("../meta/reflect.zig");
const make = @import("../meta/make.zig");
const fingerprint = @import("../meta/fingerprint.zig");
const step = @import("step.zig");
const Allocator = std.mem.Allocator;

pub const Node = struct {
    kind: enum { step, branch },
    /// `.step`: a step type, a committed workflow, or a parallel group.
    T: type = void,
    arms: []const Arm = &.{},
    /// `.branch`: index among this workflow's branches (for state and ids).
    index: usize = 0,
};

pub const Arm = struct {
    /// A wrapper type with `pub const f = predicate`, or `z.otherwise`.
    Pred: type,
    T: type,
};

pub const Migration = struct {
    from: u64,
    migrate: *const fn (arena: Allocator, state_json: []const u8) anyerror![]const u8,
};

pub fn Workflow(comptime Ctx: type, comptime name: []const u8, comptime Input: type) Builder(Ctx, name, Input, &.{}, Input, &.{}) {
    if (comptime !@import("../tool.zig").validName(name)) errors.fail("workflow name \"{s}\" must match ^[a-zA-Z0-9_-]{{1,64}}$", .{name});
    return .{};
}

fn asType(comptime wf: []const u8, comptime S: anytype) type {
    if (@TypeOf(S) != type) errors.fail("workflow '{s}': `.then(...)` takes a step type, got a value of type {s}", .{ wf, @typeName(@TypeOf(S)) });
    return S;
}

fn describe(comptime T: type) []const u8 {
    return reflect.shortTypeName(T);
}

/// Validate `S` as the next node after a node producing `Cur`; return S.Output.
fn checkThen(comptime Ctx: type, comptime wf: []const u8, comptime nodes: []const Node, comptime Cur: type, comptime S: type) type {
    comptime {
        if (@TypeOf(S) != type) errors.fail("workflow '{s}': `.then(...)` takes a step type, got a value of type {s}", .{ wf, @typeName(@TypeOf(S)) });
        checkNode(Ctx, wf, S);
        if (S.Input != Cur) {
            const prev = if (nodes.len == 0) "the workflow input" else "previous step '" ++ lastId(nodes) ++ "'";
            errors.fail("workflow '{s}': step '{s}' expects Input `{s}`, but {s} outputs `{s}`", .{ wf, step.idOf(S), describe(S.Input), prev, describe(Cur) });
        }
        return S.Output;
    }
}

/// Validate a step, nested workflow, parallel group or loop against `Ctx`.
fn checkNode(comptime Ctx: type, comptime wf: []const u8, comptime S: type) void {
    comptime {
        if (step.isWorkflow(S)) {
            if (S.Ctx != Ctx) errors.fail("workflow '{s}': nested workflow '{s}' uses context {s}, not {s}", .{ wf, S.id, @typeName(S.Ctx), @typeName(Ctx) });
        } else if (step.isLoop(S)) {
            checkNode(Ctx, wf, S.body);
        } else if (step.isParallel(S)) {
            for (reflect.fields(@TypeOf(S.steps))) |f| step.checkStep(@field(S.steps, f.name), Ctx);
        } else {
            step.checkStep(S, Ctx);
        }
    }
}

fn lastId(comptime nodes: []const Node) []const u8 {
    const n = nodes[nodes.len - 1];
    return if (n.kind == .step) step.idOf(n.T) else std.fmt.comptimePrint("branch_{d}", .{n.index});
}

fn branchCount(comptime nodes: []const Node) usize {
    var n: usize = 0;
    for (nodes) |x| if (x.kind == .branch) {
        n += 1;
    };
    return n;
}

fn Builder(comptime Ctx: type, comptime wf: []const u8, comptime In: type, comptime nodes: []const Node, comptime Cur: type, comptime migs: []const Migration) type {
    return struct {
        pub fn then(_: @This(), comptime S: anytype) Builder(Ctx, wf, In, nodes ++ &[_]Node{.{ .kind = .step, .T = asType(wf, S) }}, checkThen(Ctx, wf, nodes, Cur, asType(wf, S)), migs) {
            return .{};
        }

        pub fn branch(_: @This(), comptime arms: anytype) Builder(Ctx, wf, In, nodes ++ &[_]Node{.{ .kind = .branch, .arms = armsOf(arms), .index = branchCount(nodes) }}, checkBranch(Ctx, wf, nodes, Cur, arms), migs) {
            return .{};
        }

        /// Accept snapshots taken with fingerprint `from` by rewriting their
        /// state JSON (PLAN.md §5.8).
        pub fn migration(_: @This(), comptime from: u64, comptime f: fn (Allocator, []const u8) anyerror![]const u8) Builder(Ctx, wf, In, nodes, Cur, migs ++ &[_]Migration{.{ .from = from, .migrate = f }}) {
            return .{};
        }

        pub fn commit(_: @This()) type {
            if (nodes.len == 0) errors.fail("workflow '{s}' has no steps; add `.then(Step)` before `.commit()`", .{wf});
            return Committed(Ctx, wf, In, nodes, Cur, migs);
        }
    };
}

fn armsOf(comptime arms: anytype) []const Arm {
    comptime {
        const A = @TypeOf(arms);
        if (!reflect.isTuple(A)) errors.fail("`.branch(...)` takes a tuple of arms: `.{{ .{{ predicate, Step }}, .{{ z.otherwise, Other }} }}`", .{});
        var out: []const Arm = &.{};
        for (0..reflect.fields(A).len) |i| {
            const arm = arms[i];
            if (!reflect.isTuple(@TypeOf(arm)) or reflect.fields(@TypeOf(arm)).len != 2)
                errors.fail("`.branch(...)` arm {d} must be `.{{ predicate, Step }}`", .{i});
            const p = arm[0];
            const Pred = if (@TypeOf(p) == type and p == step.otherwise) step.otherwise else struct {
                pub const f = p;
            };
            out = out ++ &[_]Arm{.{ .Pred = Pred, .T = arm[1] }};
        }
        return out;
    }
}

fn checkBranch(comptime Ctx: type, comptime wf: []const u8, comptime nodes: []const Node, comptime Cur: type, comptime arms: anytype) type {
    comptime {
        const list = armsOf(arms);
        if (list.len == 0) errors.fail("workflow '{s}': `.branch(...)` needs at least one arm", .{wf});
        var Out: ?type = null;
        var first_id: []const u8 = "";
        for (list, 0..) |arm, i| {
            const T = arm.T;
            _ = checkThen(Ctx, wf, nodes, Cur, T);
            if (arm.Pred == step.otherwise) {
                if (i != list.len - 1) errors.fail("workflow '{s}': `z.otherwise` must be the last branch arm", .{wf});
            } else {
                const F = @TypeOf(arm.Pred.f);
                if (@typeInfo(F) != .@"fn" or @typeInfo(F).@"fn".param_types.len != 1 or @typeInfo(F).@"fn".return_type != bool or @typeInfo(F).@"fn".param_types[0] != Cur)
                    errors.fail("workflow '{s}': branch arm {d}'s predicate must be `fn ({s}) bool`", .{ wf, i, describe(Cur) });
            }
            if (Out) |O| {
                if (T.Output != O) errors.fail("workflow '{s}': branch arms must agree on Output: '{s}' outputs `{s}`, but '{s}' outputs `{s}`", .{
                    wf, step.idOf(T), describe(T.Output), first_id, describe(O),
                });
            } else {
                Out = T.Output;
                first_id = step.idOf(T);
            }
        }
        return Out.?;
    }
}

// ── analysis ─────────────────────────────────────────────────────────────────

/// A step (by type) whose output is available, and where it lives in state.
const Avail = struct { T: type, path: []const u8 };

/// One stored slot of run state.
pub const Slot = struct {
    path: []const u8,
    /// The stored type (a step's Output wrapped in `Done`, or a branch arm index).
    T: type,
    /// The step type (for steps) or void (branches).
    S: type,
};

/// One unresolved `needs` entry (an open workflow).
pub const OpenNeed = struct { consumer: []const u8, key: []const u8, T: type };

/// A completed step's stored output. Wrapping keeps "not run" (null) distinct
/// from a step whose Output is itself optional.
pub fn Done(comptime T: type) type {
    return struct { value: T };
}

const Analysis = struct {
    slots: []const Slot,
    open: []const OpenNeed,
    suspendable: []const type,
    agents: []const type,
    shape: []const u8,
};

fn join(comptime prefix: []const u8, comptime id: []const u8) []const u8 {
    return if (prefix.len == 0) id else prefix ++ "." ++ id;
}

/// Walk `nodes` in order, threading the set of steps that dominate the
/// current point. Nested workflows are walked inline with their own initial
/// input; branch arms see only what was available before the branch.
fn analyze(comptime wf: []const u8, comptime In: type, comptime nodes: []const Node, comptime prefix: []const u8, comptime avail_in: []const Avail, comptime all: []const type) Analysis {
    comptime {
        var avail = avail_in;
        var out: Analysis = .{ .slots = &.{}, .open = &.{}, .suspendable = &.{}, .agents = &.{}, .shape = "" };
        for (nodes) |n| switch (n.kind) {
            .step => {
                const r = analyzeStep(wf, In, n.T, prefix, avail, all);
                merge(&out, r);
                avail = avail ++ &[_]Avail{.{ .T = n.T, .path = join(prefix, step.idOf(n.T)) }};
            },
            .branch => {
                const bpath = join(prefix, std.fmt.comptimePrint("branch_{d}", .{n.index}));
                out.slots = out.slots ++ &[_]Slot{.{ .path = bpath, .T = u8, .S = void }};
                out.shape = out.shape ++ "branch(";
                for (n.arms) |arm| {
                    const r = analyzeStep(wf, In, arm.T, prefix, avail, all);
                    merge(&out, r);
                    out.shape = out.shape ++ "|";
                }
                out.shape = out.shape ++ ")";
            },
        };
        return out;
    }
}

fn merge(comptime out: *Analysis, comptime r: Analysis) void {
    out.slots = out.slots ++ r.slots;
    out.open = out.open ++ r.open;
    out.suspendable = out.suspendable ++ r.suspendable;
    for (r.agents) |A| {
        var seen = false;
        for (out.agents) |B| if (A == B) {
            seen = true;
        };
        if (!seen) out.agents = out.agents ++ &[_]type{A};
    }
    out.shape = out.shape ++ r.shape;
}

fn analyzeStep(comptime wf: []const u8, comptime In: type, comptime S: type, comptime prefix: []const u8, comptime avail: []const Avail, comptime all: []const type) Analysis {
    comptime {
        const path = join(prefix, step.idOf(S));
        var out: Analysis = .{ .slots = &.{}, .open = &.{}, .suspendable = &.{}, .agents = &.{}, .shape = "" };
        for (all) |other| if (other != S and std.mem.eql(u8, join(prefix, step.idOf(other)), path)) {
            errors.fail("workflow '{s}' has two different steps with id '{s}' ({s} and {s}); give one a `pub const name`", .{ wf, path, @typeName(S), @typeName(other) });
        };
        if (step.isWorkflow(S)) {
            const r = analyze(S.id, S.Input, S.nodes, path, avail, S.all_steps);
            merge(&out, r);
            // The nested workflow's own output gets a slot too, so later steps
            // can `need` it.
            out.slots = out.slots ++ &[_]Slot{.{ .path = path, .T = Done(S.Output), .S = S }};
            out.shape = "wf(" ++ S.id ++ ":" ++ r.shape ++ ")";
            return out;
        }
        if (step.isLoop(S)) {
            // The body's slots hold the current iteration only; `<path>#`
            // holds the iteration count and latest value (D46). `.max`,
            // `.until` and `.on_limit` stay out of the shape, so tuning them
            // keeps snapshots valid.
            const r = analyzeStep(wf, In, S.body, path, avail, &.{S.body});
            merge(&out, r);
            out.slots = out.slots ++ &[_]Slot{
                .{ .path = path ++ "#", .T = S.Progress, .S = void },
                .{ .path = path, .T = Done(S.Output), .S = S },
            };
            out.shape = "loop(" ++ path ++ ":" ++ r.shape ++ ")";
            return out;
        }
        out.slots = &[_]Slot{.{ .path = path, .T = Done(S.Output), .S = S }};
        out.shape = "step(" ++ path ++ ":" ++ fingerprint.describe(S.Input) ++ "->" ++ fingerprint.describe(S.Output) ++
            (if (step.isSuspendable(S)) ";susp:" ++ fingerprint.describe(S.Suspend) ++ "/" ++ fingerprint.describe(S.Resume) else "") ++
            // A gated agent's saved runs only resume under the same agent
            // version, so its fingerprint is part of the workflow's (D34).
            (if (step.isSuspendable(S) and @hasDecl(S.Suspend, "zastra_approvals_of")) std.fmt.comptimePrint(";agent:{x}", .{S.Suspend.zastra_approvals_of.run_fingerprint}) else "") ++ ")";
        if (step.isSuspendable(S)) out.suspendable = &[_]type{S};
        if (@hasDecl(S, "zastra_agent_step")) out.agents = &[_]type{S.zastra_agent_step};
        const members: []const type = if (step.isParallel(S)) blk: {
            var m: []const type = &.{};
            for (reflect.fields(@TypeOf(S.steps))) |f| m = m ++ &[_]type{@field(S.steps, f.name)};
            break :blk m;
        } else &[_]type{S};
        for (members) |M| {
            if (@hasDecl(M, "zastra_agent_step")) out.agents = out.agents ++ &[_]type{M.zastra_agent_step};
            if (!@hasDecl(M, "needs")) continue;
            for (reflect.fields(@TypeOf(M.needs))) |f| {
                const R = @field(M.needs, f.name);
                if (step.isInitial(R)) {
                    if (R.Type != In) errors.fail("step '{s}' needs the workflow input as `{s}`, but workflow '{s}' takes `{s}`", .{ step.idOf(M), describe(R.Type), wf, describe(In) });
                    continue;
                }
                const found = for (avail) |a| {
                    if (a.T == R) break true;
                } else false;
                if (!found) for (all) |L| if (step.isLoop(L) and inLoopBody(L, R))
                    errors.fail("step '{s}' needs '{s}', which runs inside loop '{s}'; its output only lasts one iteration. Carry the value in the loop's `{s}` and need the loop instead", .{ step.idOf(M), step.idOf(R), L.name, describe(L.Output) });
                if (!found) out.open = out.open ++ &[_]OpenNeed{.{ .consumer = step.idOf(M), .key = f.name, .T = R }};
            }
        }
        return out;
    }
}

/// Every step type reachable in `nodes`, for duplicate-id checks.
fn allSteps(comptime nodes: []const Node) []const type {
    comptime {
        var out: []const type = &.{};
        for (nodes) |n| switch (n.kind) {
            .step => out = out ++ &[_]type{n.T},
            .branch => for (n.arms) |a| {
                out = out ++ &[_]type{a.T};
            },
        };
        return out;
    }
}

fn inLoopBody(comptime L: type, comptime T: type) bool {
    const B = L.body;
    if (B == T) return true;
    if (step.isWorkflow(B)) return contains(B.nodes, T);
    if (step.isLoop(B)) return inLoopBody(B, T);
    if (step.isParallel(B)) for (reflect.fields(@TypeOf(B.steps))) |f| {
        if (@field(B.steps, f.name) == T) return true;
    };
    return false;
}

/// Does `T` appear anywhere in this graph (including nested workflows)?
fn contains(comptime nodes: []const Node, comptime T: type) bool {
    for (nodes) |n| switch (n.kind) {
        .step => {
            if (n.T == T) return true;
            if (step.isWorkflow(n.T) and contains(n.T.nodes, T)) return true;
            if (step.isLoop(n.T) and inLoopBody(n.T, T)) return true;
        },
        .branch => for (n.arms) |a| {
            if (a.T == T) return true;
            if (step.isWorkflow(a.T) and contains(a.T.nodes, T)) return true;
        },
    };
    return false;
}

fn Committed(comptime Ctx_: type, comptime wf: []const u8, comptime In: type, comptime nodes_: []const Node, comptime Out: type, comptime migs: []const Migration) type {
    comptime {
        @setEvalBranchQuota(20_000_000);
        const all = allSteps(nodes_);
        const a = analyze(wf, In, nodes_, "", &.{}, all);

        // State: the input, then one slot per step and branch.
        var names: []const []const u8 = &.{"input"};
        var types: []const type = &.{In};
        for (a.slots) |s| {
            names = names ++ &[_][]const u8{s.path};
            types = types ++ &[_]type{s.T};
        }
        const StateT = make.OptionalStruct(names[1..], types[1..]);
        const Full = struct {
            input: In,
            steps: StateT = .{},
            /// Set while resuming: where, and the resume value as JSON.
            resume_at: ?[]const u8 = null,
            resume_json: ?[]const u8 = null,
            /// The retry attempt the suspended step was on: a resume
            /// replays that attempt, so it finds its agent runs (D63).
            suspended_attempt: u32 = 0,
        };

        // Suspended union: one variant per suspendable step id.
        var s_names: []const []const u8 = &.{};
        var s_types: []const type = &.{};
        for (a.suspendable) |S| {
            for (s_names) |n| if (std.mem.eql(u8, n, step.idOf(S)))
                errors.fail("workflow '{s}' has two suspendable steps with id '{s}'; give one a `pub const name`", .{ wf, n });
            s_names = s_names ++ &[_][]const u8{step.idOf(S)};
            s_types = s_types ++ &[_]type{S.Suspend};
        }
        const SuspendedT = make.TaggedUnion(s_names, s_types);

        const fp = fingerprint.hash(wf ++ "|" ++ fingerprint.describe(In) ++ "|" ++ a.shape);
        const slots_final = a.slots;
        const open_final = a.open;
        const agents_final = a.agents;
        const susp_final = a.suspendable;

        return struct {
            pub const zastra_workflow = true;
            pub const id = wf;
            pub const Ctx = Ctx_;
            pub const Input = In;
            pub const Output = Out;
            pub const nodes = nodes_;
            pub const all_steps = all;
            pub const slots = slots_final;
            /// `needs` this workflow can't resolve on its own (D13). Non-empty
            /// means it's open: embeddable, not runnable.
            pub const open_needs = open_final;
            pub const agents = agents_final;
            pub const suspendable_steps = susp_final;
            pub const State = Full;
            pub const Suspended = SuspendedT;
            pub const fingerprint_value: u64 = fp;
            pub const migrations = migs;

            pub const SuspendInfo = struct {
                run_id: []const u8,
                at: Suspended,
            };
            pub const Failure = struct {
                step: []const u8,
                err: anyerror,
                message: []const u8,
            };
            /// Whether any step can suspend. Without one, `Result` has no
            /// `.suspended` arm, so switches stay exhaustive and minimal.
            pub const can_suspend = susp_final.len > 0;
            pub const Result = if (can_suspend) union(enum) {
                completed: Output,
                suspended: SuspendInfo,
                failed: Failure,
            } else union(enum) {
                completed: Output,
                failed: Failure,
            };

            /// Mermaid flowchart of the graph (PLAN.md §5.7).
            pub const mermaid = @import("mermaid.zig").render(@This());
        };
    }
}

/// `z.App` and `rt.workflow` accept only closed workflows (D13).
pub fn checkRegistrable(comptime W: type, comptime Ctx: type) void {
    comptime {
        if (@TypeOf(W) != type or !step.isWorkflow(W)) errors.fail("z.App(...): `.workflows` entries must be workflows (`z.Workflow(...).then(...).commit()`)", .{});
        if (W.Ctx != Ctx) errors.fail("z.App(...): workflow '{s}' uses context {s}, but the App's `.ctx` is {s}", .{ W.id, @typeName(W.Ctx), @typeName(Ctx) });
        if (W.open_needs.len > 0) {
            const n = W.open_needs[0];
            if (contains(W.nodes, n.T)) {
                errors.fail("workflow '{s}': step '{s}' needs '{s}' (as `.{s}`), which doesn't run before it on every path", .{ W.id, n.consumer, step.idOf(n.T), n.key });
            }
            errors.fail("workflow '{s}' can't run on its own: step '{s}' needs '{s}', which only exists in an enclosing workflow. Register the enclosing workflow instead.", .{ W.id, n.consumer, step.idOf(n.T) });
        }
    }
}
