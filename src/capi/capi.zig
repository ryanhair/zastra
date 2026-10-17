//! The C ABI (PLAN.md §9, D14): JSON at the edges, pull-based streams.
//! `exportAll(App, app_module, "support")` emits `support_*` functions plus
//! the shared `zastra_*` ones. Used by `z.addCLib`.

const std = @import("std");
const json = @import("../schema/json.zig");
const parse = @import("../schema/parse.zig");
const msg = @import("../message.zig");
const run = @import("../agent/run.zig");
const ev = @import("../agent/events.zig");
const trace = @import("../trace/trace.zig");
const manifest = @import("manifest.zig");
const header = @import("header.zig");
const runner = @import("../workflow/runner.zig");
const step = @import("../workflow/step.zig");
const encode = @import("encode.zig");
const runResultJson = encode.runResultJson;
const suspendedJson = encode.suspendedJson;
const agentResultJson = encode.agentResultJson;
const workflowResultJson = encode.workflowResultJson;
const Allocator = std.mem.Allocator;

const Status = enum(c_int) {
    ok = 0,
    done = 1,
    err = -1,
    approval_pending = -2,
    canceled = -3,
    invalid_input = -4,
    // -5 was APPROVAL_REQUIRED in ABI v1; gated agents now suspend instead.
    abi_mismatch = -6,
};

pub const Error = extern struct {
    code: c_int,
    message: [512]u8,
};

pub const Event = extern struct {
    kind: c_int,
    json: [*]const u8,
    len: usize,
    approval_id: ?[*:0]const u8,
};

fn setErr(err: ?*Error, code: Status, comptime fmt: []const u8, args: anytype) void {
    const e = err orelse return;
    e.code = @intFromEnum(code);
    const s = std.fmt.bufPrint(e.message[0 .. e.message.len - 1], fmt, args) catch e.message[0 .. e.message.len - 1];
    e.message[s.len] = 0;
}

fn clearErr(err: ?*Error) void {
    const e = err orelse return;
    e.code = 0;
    e.message[0] = 0;
}

fn span(s: ?[*:0]const u8) ?[]const u8 {
    return if (s) |p| std.mem.span(p) else null;
}

/// A result handed to C: NUL-terminated JSON owned by the library.
pub const Result = struct {
    json: [:0]u8,
};

const gpa = std.heap.c_allocator;

fn makeResult(bytes: []const u8) ?*Result {
    const r = gpa.create(Result) catch return null;
    r.json = gpa.dupeZ(u8, bytes) catch {
        gpa.destroy(r);
        return null;
    };
    return r;
}

/// Type-erased stream: one implementation per agent type.
const StreamObj = struct {
    ptr: *anyopaque,
    vt: *const VT,
    arena: std.heap.ArenaAllocator,
    /// Reset on every next(); holds the current event's JSON.
    scratch: std.heap.ArenaAllocator,
    canceled: std.atomic.Value(bool) = .init(false),
    done: bool = false,
    /// Why the last next() failed, NUL-terminated.
    last_error: [512:0]u8 = @splat(0),

    const VT = struct {
        next: *const fn (s: *StreamObj, out: *Event) Status,
        respond: *const fn (s: *StreamObj, id: []const u8, d: ev.Decision) Status,
        /// Save the run while approvals are pending; the suspended result JSON.
        @"suspend": *const fn (s: *StreamObj) ?[]const u8,
        result: *const fn (s: *StreamObj) ?[]const u8,
        diag: *const fn (s: *StreamObj) []const u8,
        deinit: *const fn (s: *StreamObj) void,
    };
};

pub fn exportAll(comptime App: type, comptime app_mod: type, comptime lib: []const u8) void {
    const Impl = struct {
        const AppHandle = struct {
            rt: App.Runtime,
            threaded: std.Io.Threaded,
            env: std.process.Environ.Map,
            ctx: *App.Context,
            trace_file: ?std.Io.File = null,
            config_arena: std.heap.ArenaAllocator,
        };

        const Config = struct {
            storage: ?struct { sqlite: ?[]const u8 = null } = null,
            env: ?std.json.ArrayHashMap([]const u8) = null,
            trace: ?[]const u8 = null,
        };

        fn appNew(config_json: ?[*:0]const u8, fp: u64, err: ?*Error) callconv(.c) ?*AppHandle {
            clearErr(err);
            if (fp != manifest.fingerprint(App)) {
                setErr(err, .abi_mismatch, "{s}.h doesn't match lib{s} (manifest fingerprint 0x{x:0>16} vs 0x{x:0>16}); regenerate the header and rebuild", .{ lib, lib, fp, manifest.fingerprint(App) });
                return null;
            }
            const h = gpa.create(AppHandle) catch return oom(err);
            h.trace_file = null;
            h.config_arena = .init(gpa);
            const ca = h.config_arena.allocator();
            const cfg: Config = if (span(config_json)) |text| std.json.parseFromSliceLeaky(Config, ca, text, .{ .ignore_unknown_fields = true }) catch |e| {
                setErr(err, .invalid_input, "config_json: {t}", .{e});
                h.config_arena.deinit();
                gpa.destroy(h);
                return null;
            } else .{};

            h.threaded = .init(gpa, .{});
            const io = h.threaded.io();
            // Environment: the variables this App needs, from the config or the process.
            h.env = .init(gpa);
            const names = App.required_env ++ [_][]const u8{ "OPENAI_BASE_URL", "ANTHROPIC_BASE_URL", "HTTPS_PROXY", "HTTP_PROXY", "https_proxy", "http_proxy", "NO_PROXY", "no_proxy" };
            inline for (names) |n| {
                const v: ?[]const u8 = if (cfg.env) |e| e.map.get(n) else null;
                if (v orelse getenv(n)) |val| h.env.put(n, val) catch return oom(err);
            }
            h.ctx = makeContext(io) catch |e| {
                setErr(err, .err, "creating the App context: {t}", .{e});
                return null;
            };
            var tracing: trace.Config = .off;
            if (cfg.trace) |path| {
                h.trace_file = std.Io.Dir.cwd().createFile(io, path, .{ .truncate = false }) catch null;
                if (h.trace_file) |f| tracing = .{ .jsonl = .{ .file = f, .append = true } };
            }
            h.rt = App.init(gpa, io, .{
                .ctx = h.ctx,
                .env = &h.env,
                .storage_path = if (cfg.storage) |s| (s.sqlite orelse "zastra.sqlite") else "zastra.sqlite",
                .tracing = tracing,
            }) catch |e| {
                setErr(err, .err, "{t}: {s}", .{ e, App.initDiagnostic() });
                freeContext(h.ctx);
                h.env.deinit();
                h.threaded.deinit();
                h.config_arena.deinit();
                gpa.destroy(h);
                return null;
            };
            return h;
        }

        fn getenv(comptime name: []const u8) ?[]const u8 {
            const p = std.c.getenv(name ++ "") orelse return null;
            return std.mem.span(p);
        }

        fn makeContext(io: std.Io) !*App.Context {
            if (@hasDecl(app_mod, "createContext")) return app_mod.createContext(gpa, io);
            const Ctx = App.Context;
            inline for (std.meta.fields(Ctx)) |f| if (f.default_value_ptr == null)
                @compileError("zastra C library: App's Ctx field `" ++ f.name ++ "` has no default. Export `pub fn createContext(gpa: std.mem.Allocator, io: std.Io) !*Ctx` from the app module.");
            const c = try gpa.create(Ctx);
            c.* = .{};
            return c;
        }

        fn freeContext(c: *App.Context) void {
            if (@hasDecl(app_mod, "destroyContext")) return app_mod.destroyContext(gpa, c);
            gpa.destroy(c);
        }

        fn oom(err: ?*Error) ?*AppHandle {
            setErr(err, .err, "out of memory", .{});
            return null;
        }

        fn appFree(h: ?*AppHandle) callconv(.c) void {
            const a = h orelse return;
            a.rt.deinit();
            if (a.trace_file) |f| f.close(a.threaded.io());
            freeContext(a.ctx);
            a.env.deinit();
            a.threaded.deinit();
            a.config_arena.deinit();
            gpa.destroy(a);
        }

        const Opts = struct {
            thread: ?[]const u8 = null,
            resource: ?[]const u8 = null,
            max_steps: ?u32 = null,
            max_tokens: ?u32 = null,
        };

        fn parseInput(arena: Allocator, input: []const u8) ![]const msg.Message {
            const trimmed = std.mem.trim(u8, input, " \t\r\n");
            if (trimmed.len > 0 and trimmed[0] == '[') {
                var issue: parse.Issue = .{};
                return parse.parse([]const msg.Message, arena, trimmed, &issue);
            }
            return run.toMessages(arena, input);
        }

        fn agentGenerate(h: ?*AppHandle, agent_id: c_int, input: ?[*:0]const u8, opts_json: ?[*:0]const u8, err: ?*Error) callconv(.c) ?*Result {
            clearErr(err);
            const a = h orelse return null;
            inline for (App.agents, 0..) |A, i| if (i == agent_id) {
                var arena: std.heap.ArenaAllocator = .init(gpa);
                defer arena.deinit();
                const aa = arena.allocator();
                const o = parseOpts(aa, opts_json, err) orelse return null;
                const msgs = parseInput(aa, span(input) orelse "") catch {
                    setErr(err, .invalid_input, "input must be text or a JSON array of messages", .{});
                    return null;
                };
                const r = run.generate(A, a.rt.state(), aa, msgs, .{ .thread = o.thread, .resource = o.resource, .max_steps = o.max_steps, .max_tokens = o.max_tokens }) catch |e| {
                    setErr(err, .err, "{t}: {s}", .{ e, a.rt.lastDiagnostic() });
                    return null;
                };
                return makeResult(runResultJson(A, aa, r) catch return null);
            };
            setErr(err, .invalid_input, "no agent with id {d}", .{agent_id});
            return null;
        }

        fn parseOpts(arena: Allocator, opts_json: ?[*:0]const u8, err: ?*Error) ?Opts {
            const text = span(opts_json) orelse return .{};
            return std.json.parseFromSliceLeaky(Opts, arena, text, .{ .ignore_unknown_fields = true }) catch |e| {
                setErr(err, .invalid_input, "opts_json: {t}", .{e});
                return null;
            };
        }

        /// decisions_json: `[{"id":"...","approve":true}, {"id":"...","deny":"reason"}]`.
        fn parseDecisions(arena: Allocator, text: []const u8, err: ?*Error) ?[]const run.ApprovalDecision {
            const D = struct { id: []const u8, approve: ?bool = null, deny: ?[]const u8 = null };
            const ds = std.json.parseFromSliceLeaky([]const D, arena, text, .{ .ignore_unknown_fields = true }) catch {
                setErr(err, .invalid_input, "decisions_json must be an array like [{{\"id\":\"...\",\"approve\":true}}] or [{{\"id\":\"...\",\"deny\":\"reason\"}}]", .{});
                return null;
            };
            const out = arena.alloc(run.ApprovalDecision, ds.len) catch return null;
            for (ds, out) |d, *o| o.* = .{ .id = d.id, .decision = if (d.deny) |r| .{ .deny = r } else if (d.approve orelse false) .approve else .{ .deny = "Denied." } };
            return out;
        }

        fn agentResume(h: ?*AppHandle, agent_id: c_int, run_id: ?[*:0]const u8, decisions_json: ?[*:0]const u8, err: ?*Error) callconv(.c) ?*Result {
            clearErr(err);
            const a = h orelse return null;
            inline for (App.agents, 0..) |A, i| if (i == agent_id) {
                if (comptime !A.has_approvals) {
                    setErr(err, .invalid_input, "agent '{s}' has no approval-gated tools; its runs never suspend", .{A.id});
                    return null;
                }
                var arena: std.heap.ArenaAllocator = .init(gpa);
                defer arena.deinit();
                const aa = arena.allocator();
                const ds = parseDecisions(aa, span(decisions_json) orelse "[]", err) orelse return null;
                const r = run.resumeRun(A, a.rt.state(), aa, span(run_id) orelse "", ds) catch |e| {
                    setErr(err, .err, "{t}: {s}", .{ e, a.rt.lastDiagnostic() });
                    return null;
                };
                return makeResult(runResultJson(A, aa, r) catch return null);
            };
            setErr(err, .invalid_input, "no agent with id {d}", .{agent_id});
            return null;
        }

        fn agentResumeStream(h: ?*AppHandle, agent_id: c_int, run_id: ?[*:0]const u8, decisions_json: ?[*:0]const u8, err: ?*Error) callconv(.c) ?*StreamObj {
            clearErr(err);
            const a = h orelse return null;
            inline for (App.agents, 0..) |A, i| if (i == agent_id) {
                if (comptime !A.has_approvals) {
                    setErr(err, .invalid_input, "agent '{s}' has no approval-gated tools; its runs never suspend", .{A.id});
                    return null;
                }
                return Streams(A).reopen(a, span(run_id) orelse "", span(decisions_json) orelse "[]", err);
            };
            setErr(err, .invalid_input, "no agent with id {d}", .{agent_id});
            return null;
        }

        fn agentCancel(h: ?*AppHandle, agent_id: c_int, run_id: ?[*:0]const u8, err: ?*Error) callconv(.c) c_int {
            clearErr(err);
            const a = h orelse return @intFromEnum(Status.err);
            inline for (App.agents, 0..) |A, i| if (i == agent_id) {
                if (comptime !A.has_approvals) {
                    setErr(err, .invalid_input, "agent '{s}' has no approval-gated tools; its runs never suspend", .{A.id});
                    return @intFromEnum(Status.invalid_input);
                }
                var arena: std.heap.ArenaAllocator = .init(gpa);
                defer arena.deinit();
                run.cancelRun(A, a.rt.state(), arena.allocator(), span(run_id) orelse "") catch |e| {
                    setErr(err, .err, "{t}: {s}", .{ e, a.rt.lastDiagnostic() });
                    return @intFromEnum(Status.err);
                };
                return @intFromEnum(Status.ok);
            };
            setErr(err, .invalid_input, "no agent with id {d}", .{agent_id});
            return @intFromEnum(Status.invalid_input);
        }

        fn agentStream(h: ?*AppHandle, agent_id: c_int, input: ?[*:0]const u8, opts_json: ?[*:0]const u8, err: ?*Error) callconv(.c) ?*StreamObj {
            clearErr(err);
            const a = h orelse return null;
            inline for (App.agents, 0..) |A, i| if (i == agent_id) return Streams(A).open(a, input, opts_json, err);
            setErr(err, .invalid_input, "no agent with id {d}", .{agent_id});
            return null;
        }

        fn Streams(comptime A: type) type {
            return struct {
                const S = run.Stream(A);

                fn open(a: *AppHandle, input: ?[*:0]const u8, opts_json: ?[*:0]const u8, err: ?*Error) ?*StreamObj {
                    const so = gpa.create(StreamObj) catch return null;
                    so.* = .{ .ptr = undefined, .vt = &vt, .arena = .init(gpa), .scratch = .init(gpa) };
                    const aa = so.arena.allocator();
                    const o = parseOpts(aa, opts_json, err) orelse return fail(so);
                    const msgs = parseInput(aa, span(input) orelse "") catch {
                        setErr(err, .invalid_input, "input must be text or a JSON array of messages", .{});
                        return fail(so);
                    };
                    const s = S.init(a.rt.state(), aa, msgs, .{ .thread = o.thread, .resource = o.resource, .max_steps = o.max_steps, .max_tokens = o.max_tokens }) catch return fail(so);
                    so.ptr = s;
                    return so;
                }

                fn reopen(a: *AppHandle, run_id: []const u8, decisions_json: []const u8, err: ?*Error) ?*StreamObj {
                    const so = gpa.create(StreamObj) catch return null;
                    so.* = .{ .ptr = undefined, .vt = &vt, .arena = .init(gpa), .scratch = .init(gpa) };
                    const aa = so.arena.allocator();
                    const ds = parseDecisions(aa, decisions_json, err) orelse return fail(so);
                    const s = run.resumeStream(A, a.rt.state(), aa, aa.dupe(u8, run_id) catch return fail(so), ds) catch |e| {
                        setErr(err, .err, "{t}: {s}", .{ e, a.rt.lastDiagnostic() });
                        return fail(so);
                    };
                    so.ptr = s;
                    return so;
                }

                fn fail(so: *StreamObj) ?*StreamObj {
                    so.arena.deinit();
                    so.scratch.deinit();
                    gpa.destroy(so);
                    return null;
                }

                const vt: StreamObj.VT = .{ .next = nextImpl, .respond = respondImpl, .@"suspend" = suspendImpl, .result = resultImpl, .diag = diagImpl, .deinit = deinitImpl };

                fn suspendImpl(so: *StreamObj) ?[]const u8 {
                    if (comptime !A.has_approvals) return null;
                    const su = st(so).suspendRun() catch return null;
                    so.done = true;
                    return suspendedJson(A, so.arena.allocator(), su) catch null;
                }

                fn st(so: *StreamObj) *S {
                    return @ptrCast(@alignCast(so.ptr));
                }

                fn nextImpl(so: *StreamObj, out: *Event) Status {
                    _ = so.scratch.reset(.retain_capacity);
                    const sa = so.scratch.allocator();
                    if (so.canceled.load(.acquire)) st(so).cancel();
                    const e = (st(so).next() catch |e| {
                        const m = std.fmt.bufPrint(so.last_error[0 .. so.last_error.len - 1], "{t}: {s}", .{ e, st(so).diag.message() }) catch so.last_error[0..0];
                        so.last_error[m.len] = 0;
                        return switch (e) {
                            error.ApprovalPending => .approval_pending,
                            error.Canceled => .canceled,
                            else => .err,
                        };
                    }) orelse {
                        so.done = true;
                        return .done;
                    };
                    out.approval_id = null;
                    const bytes = encode.eventJson(sa, e) catch return .err;
                    const z_bytes = sa.dupeZ(u8, bytes) catch return .err;
                    out.json = z_bytes.ptr;
                    out.len = bytes.len;
                    switch (e) {
                        inline else => |payload, tag| {
                            const kind = comptime encode.eventKind(@tagName(tag));
                            out.kind = kind;
                            if (comptime kind == 4) out.approval_id = (sa.dupeZ(u8, payload.id) catch return .err).ptr;
                            if (comptime kind == 6) so.done = true;
                        },
                    }
                    return .ok;
                }

                fn respondImpl(so: *StreamObj, id: []const u8, d: ev.Decision) Status {
                    st(so).respond(id, d) catch return .invalid_input;
                    return .ok;
                }

                fn resultImpl(so: *StreamObj) ?[]const u8 {
                    const r = st(so).result() catch return null;
                    return agentResultJson(A, so.arena.allocator(), r) catch null;
                }

                fn diagImpl(so: *StreamObj) []const u8 {
                    return st(so).st.diag.message();
                }

                fn deinitImpl(so: *StreamObj) void {
                    st(so).deinit();
                }
            };
        }

        fn workflowStart(h: ?*AppHandle, workflow_id: c_int, input_json: ?[*:0]const u8, err: ?*Error) callconv(.c) ?*Result {
            clearErr(err);
            const a = h orelse return null;
            inline for (App.workflows, 0..) |W, i| if (i == workflow_id) {
                var arena: std.heap.ArenaAllocator = .init(gpa);
                defer arena.deinit();
                const aa = arena.allocator();
                var issue: parse.Issue = .{};
                const input = parse.parse(W.Input, aa, span(input_json) orelse "null", &issue) catch {
                    setErr(err, .invalid_input, "input_json for workflow '{s}': {s}: {s}", .{ W.id, issue.path, issue.message });
                    return null;
                };
                const r = a.rt.workflow(W).start(aa, input, .{}) catch |e| {
                    setErr(err, .err, "{t}: {s}", .{ e, a.rt.lastDiagnostic() });
                    return null;
                };
                return makeResult(workflowResultJson(W, aa, r) catch return null);
            };
            setErr(err, .invalid_input, "no workflow with id {d}", .{workflow_id});
            return null;
        }

        fn workflowResume(h: ?*AppHandle, run_id: ?[*:0]const u8, step_id: ?[*:0]const u8, resume_json: ?[*:0]const u8, err: ?*Error) callconv(.c) ?*Result {
            clearErr(err);
            const a = h orelse return null;
            var arena: std.heap.ArenaAllocator = .init(gpa);
            defer arena.deinit();
            const aa = arena.allocator();
            const rid = span(run_id) orelse "";
            const sid = span(step_id) orelse "";
            const store = a.rt.state().storage orelse return null;
            const rec = (store.loadRun(aa, rid) catch null) orelse {
                setErr(err, .invalid_input, "no run '{s}'", .{rid});
                return null;
            };
            inline for (App.workflows) |W| if (rec.kind == .workflow and std.mem.eql(u8, W.id, rec.owner_id)) {
                inline for (W.suspendable_steps) |S| if (std.mem.eql(u8, step.idOf(S), sid)) {
                    var issue: parse.Issue = .{};
                    const value = parse.parse(S.Resume, aa, span(resume_json) orelse "null", &issue) catch {
                        setErr(err, .invalid_input, "resume_json for step '{s}': {s}: {s}", .{ sid, issue.path, issue.message });
                        return null;
                    };
                    const r = a.rt.workflow(W).resumeStep(S, aa, rid, value) catch |e| {
                        setErr(err, .err, "{t}: {s}", .{ e, a.rt.lastDiagnostic() });
                        return null;
                    };
                    return makeResult(workflowResultJson(W, aa, r) catch return null);
                };
                setErr(err, .invalid_input, "workflow '{s}' has no suspendable step '{s}'", .{ W.id, sid });
                return null;
            };
            setErr(err, .invalid_input, "run '{s}' belongs to {t} '{s}', which isn't a workflow in this library", .{ rid, rec.kind, rec.owner_id });
            return null;
        }
    };

    @export(&Impl.appNew, .{ .name = lib ++ "_app_new_checked" });
    @export(&Impl.appFree, .{ .name = lib ++ "_app_free" });
    @export(&Impl.agentGenerate, .{ .name = lib ++ "_agent_generate" });
    @export(&Impl.agentStream, .{ .name = lib ++ "_agent_stream" });
    @export(&Impl.agentResume, .{ .name = lib ++ "_agent_resume" });
    @export(&Impl.agentResumeStream, .{ .name = lib ++ "_agent_resume_stream" });
    @export(&Impl.agentCancel, .{ .name = lib ++ "_agent_cancel" });
    @export(&Impl.workflowStart, .{ .name = lib ++ "_workflow_start" });
    @export(&Impl.workflowResume, .{ .name = lib ++ "_workflow_resume" });
    @export(&abiVersion, .{ .name = "zastra_abi_version" });
    @export(&streamNext, .{ .name = "zastra_stream_next" });
    @export(&streamRespond, .{ .name = "zastra_stream_respond" });
    @export(&streamCancel, .{ .name = "zastra_stream_cancel" });
    @export(&streamSuspend, .{ .name = "zastra_stream_suspend" });
    @export(&streamResult, .{ .name = "zastra_stream_result" });
    @export(&streamFree, .{ .name = "zastra_stream_free" });
    @export(&streamError, .{ .name = "zastra_stream_error" });
    @export(&resultJson, .{ .name = "zastra_result_json" });
    @export(&resultFree, .{ .name = "zastra_result_free" });
}

fn abiVersion() callconv(.c) u32 {
    return header.abi_version;
}

fn streamNext(s: ?*StreamObj, out: ?*Event) callconv(.c) c_int {
    const so = s orelse return @intFromEnum(Status.err);
    const o = out orelse return @intFromEnum(Status.err);
    return @intFromEnum(so.vt.next(so, o));
}

fn streamRespond(s: ?*StreamObj, approval_id: ?[*:0]const u8, decision_json: ?[*:0]const u8, err: ?*Error) callconv(.c) c_int {
    clearErr(err);
    const so = s orelse return @intFromEnum(Status.err);
    const id = span(approval_id) orelse "";
    const text = span(decision_json) orelse "";
    const D = struct { approve: ?bool = null, deny: ?[]const u8 = null };
    var buf: [4096]u8 = undefined;
    var fba: std.heap.FixedBufferAllocator = .init(&buf);
    const d = std.json.parseFromSliceLeaky(D, fba.allocator(), text, .{ .ignore_unknown_fields = true }) catch {
        setErr(err, .invalid_input, "decision_json must be {{\"approve\":true}} or {{\"deny\":\"reason\"}}", .{});
        return @intFromEnum(Status.invalid_input);
    };
    const decision: ev.Decision = if (d.deny) |r| .{ .deny = r } else if (d.approve orelse false) .approve else .{ .deny = "Denied." };
    const st = so.vt.respond(so, id, decision);
    if (st != .ok) setErr(err, st, "no pending approval '{s}'", .{id});
    return @intFromEnum(st);
}

fn streamCancel(s: ?*StreamObj) callconv(.c) void {
    const so = s orelse return;
    so.canceled.store(true, .release);
}

fn streamSuspend(s: ?*StreamObj, err: ?*Error) callconv(.c) ?*Result {
    clearErr(err);
    const so = s orelse return null;
    const bytes = so.vt.@"suspend"(so) orelse {
        setErr(err, .err, "{s}", .{so.vt.diag(so)});
        return null;
    };
    return makeResult(bytes);
}

fn streamResult(s: ?*StreamObj, err: ?*Error) callconv(.c) ?*Result {
    clearErr(err);
    const so = s orelse return null;
    const bytes = so.vt.result(so) orelse {
        setErr(err, .err, "{s}", .{so.vt.diag(so)});
        return null;
    };
    return makeResult(bytes);
}

fn streamError(s: ?*StreamObj) callconv(.c) [*:0]const u8 {
    const so = s orelse return "";
    return &so.last_error;
}

fn streamFree(s: ?*StreamObj) callconv(.c) void {
    const so = s orelse return;
    so.vt.deinit(so);
    so.scratch.deinit();
    so.arena.deinit();
    gpa.destroy(so);
}

fn resultJson(r: ?*const Result) callconv(.c) ?[*:0]const u8 {
    const x = r orelse return null;
    return x.json.ptr;
}

fn resultFree(r: ?*Result) callconv(.c) void {
    const x = r orelse return;
    gpa.free(x.json);
    gpa.destroy(x);
}
