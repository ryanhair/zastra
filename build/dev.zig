//! The zastra dev CLI (PLAN.md §8), generated for an App by `z.addDev`.
//!
//!   zig build dev -- agents
//!   zig build dev -- schema <agent> [--dialect canonical|anthropic|anthropic_output|openai]
//!   zig build dev -- prefix <agent>
//!   zig build dev -- chat <agent> [--thread t] [--resource r]
//!   zig build dev -- run <workflow> <json | @file.json> [--resource r]
//!   zig build dev -- runs [--suspended]
//!   zig build dev -- resume <run_id> <json | @file.json>
//!   zig build dev -- graph <workflow>
//!   zig build dev -- trace <run_id>
//!   zig build dev -- models [--stale]
//!
//! The app module must export `pub const App`. If its Ctx can't be
//! default-initialized, it must also export
//! `pub fn createContext(gpa, io) !*Ctx` (and optionally `destroyContext`).

const std = @import("std");
const z = @import("zastra");
const app = @import("app");
const App = app.App;
const Allocator = std.mem.Allocator;
const Io = std.Io;

const trace_file = "zastra-trace.jsonl";
const db_default = "zastra.sqlite";

comptime {
    if (!@hasDecl(app, "App")) @compileError("zastra dev: the app module must export `pub const App = z.App(...)`");
}

const usage =
    \\usage: zig build dev -- <command> [args]
    \\
    \\  agents                                  list agents, models, tools and effects
    \\  schema <agent> [--dialect <d>]          print tool and output JSON Schemas
    \\  prefix <agent>                          print the precomputed request prefix and its hash
    \\  chat <agent> [--thread t] [--resource r]  chat with streaming, tool logs and approvals
    \\  run <workflow> <json|@file>             start a workflow
    \\  runs [--suspended]                      list workflow runs
    \\  resume <run_id> <json|@file>            resume a suspended run
    \\  graph <workflow>                        print the workflow as Mermaid
    \\  trace <run_id>                          print the span tree of a run
    \\  models [--stale]                        catalog entries this App uses
    \\
    \\options: --db <path> (default zastra.sqlite)
    \\
;

const Out = struct {
    w: *Io.Writer,
    fn print(o: Out, comptime f: []const u8, args: anytype) void {
        o.w.print(f, args) catch {};
    }
    fn write(o: Out, s: []const u8) void {
        o.w.writeAll(s) catch {};
    }
    fn flush(o: Out) void {
        o.w.flush() catch {};
    }
};

pub fn main(init: std.process.Init) !u8 {
    const gpa = init.gpa;
    const io = init.io;
    const arena = init.arena.allocator();
    const argv = try init.minimal.args.toSlice(arena);
    var out_buf: [8192]u8 = undefined;
    var stdout = Io.File.stdout().writerStreaming(io, &out_buf);
    const out: Out = .{ .w = &stdout.interface };
    defer out.flush();

    var args: std.ArrayList([]const u8) = .empty;
    var db_path: []const u8 = db_default;
    var i: usize = 1;
    while (i < argv.len) : (i += 1) {
        if (std.mem.eql(u8, argv[i], "--db") and i + 1 < argv.len) {
            db_path = argv[i + 1];
            i += 1;
        } else try args.append(arena, argv[i]);
    }
    if (args.items.len == 0) {
        out.write(usage);
        return 2;
    }
    const cmd = args.items[0];
    const rest = args.items[1..];

    if (std.mem.eql(u8, cmd, "agents")) return cmdAgents(out);
    if (std.mem.eql(u8, cmd, "schema")) return cmdSchema(out, rest);
    if (std.mem.eql(u8, cmd, "prefix")) return cmdPrefix(out, rest);
    if (std.mem.eql(u8, cmd, "graph")) return cmdGraph(out, rest);
    if (std.mem.eql(u8, cmd, "models")) return cmdModels(out, io, rest);
    if (std.mem.eql(u8, cmd, "trace")) return cmdTrace(out, io, arena, rest);
    if (std.mem.eql(u8, cmd, "chat") or std.mem.eql(u8, cmd, "run") or std.mem.eql(u8, cmd, "runs") or std.mem.eql(u8, cmd, "resume")) {
        return withRuntime(gpa, io, arena, out, init.environ_map, db_path, cmd, rest);
    }
    out.print("unknown command '{s}'\n\n", .{cmd});
    out.write(usage);
    return 2;
}

fn flag(rest: []const []const u8, name: []const u8) ?[]const u8 {
    for (rest, 0..) |a, i| if (std.mem.eql(u8, a, name) and i + 1 < rest.len) return rest[i + 1];
    return null;
}

fn has(rest: []const []const u8, name: []const u8) bool {
    for (rest) |a| if (std.mem.eql(u8, a, name)) return true;
    return false;
}

fn unknownName(out: Out, kind: []const u8, name: []const u8, comptime list: []const []const u8) u8 {
    out.print("no {s} named '{s}'", .{ kind, name });
    if (z.meta.errors.closest(name, list)) |near| out.print(" (did you mean '{s}'?)", .{near});
    out.write("; known: ");
    inline for (list, 0..) |n, i| out.print("{s}{s}", .{ if (i == 0) "" else ", ", n });
    out.write("\n");
    return 1;
}

const agent_ids = blk: {
    var ids: [App.agents.len][]const u8 = undefined;
    for (App.agents, 0..) |A, i| ids[i] = A.id;
    const final = ids;
    break :blk &final;
};
const workflow_ids = blk: {
    var ids: [App.workflows.len][]const u8 = undefined;
    for (App.workflows, 0..) |W, i| ids[i] = W.id;
    const final = ids;
    break :blk &final;
};

// ── static commands ──────────────────────────────────────────────────────────

fn cmdAgents(out: Out) u8 {
    inline for (App.agents) |A| {
        out.print("{s}  ({s})\n", .{ A.id, comptime A.model.fullName() });
        if (A.description.len > 0) out.print("  {s}\n", .{A.description});
        if (A.has_output_type) out.print("  output: {s}{s}\n", .{ @typeName(A.Output), if (A.native_structured_output) " (native structured output)" else " (final_answer tool)" });
        if (A.history_messages > 0) out.print("  memory: last {d} messages\n", .{A.history_messages});
        if (A.has_working_memory) out.print("  working memory: {s}\n", .{@typeName(A.Working)});
        inline for (A.tools) |TI| {
            out.print("  tool {s}", .{TI.name});
            var it = TI.effect_set.iterator();
            out.write(" [");
            var first = true;
            while (it.next()) |e| {
                out.print("{s}{t}", .{ if (first) "" else ",", e });
                first = false;
            }
            out.write("]");
            switch (TI.approval_kind) {
                .never => {},
                .always => out.write(" approval: always"),
                .dynamic => out.write(" approval: needsApproval"),
            }
            out.write("\n");
        }
        inline for (A.mcp_tools) |set| out.print("  mcp server {s}{s}\n", .{ set.server_name, if (set.allow != null) " (filtered)" else "" });
    }
    if (App.workflows.len > 0) out.write("\nworkflows:\n");
    inline for (App.workflows) |W| out.print("  {s}  ({s} -> {s}){s}\n", .{ W.id, @typeName(W.Input), @typeName(W.Output), if (W.can_suspend) "  suspendable" else "" });
    if (App.required_env.len > 0) {
        out.write("\nenvironment:");
        inline for (App.required_env) |e| out.print(" {s}", .{e});
        out.write("\n");
    }
    return 0;
}

fn cmdSchema(out: Out, rest: []const []const u8) u8 {
    if (rest.len == 0) {
        out.write("usage: schema <agent> [--dialect canonical|anthropic|anthropic_output|openai]\n");
        return 2;
    }
    const d_name = flag(rest, "--dialect") orelse "canonical";
    const dialect = std.meta.stringToEnum(z.schema.Dialect, d_name) orelse {
        out.print("unknown dialect '{s}'\n", .{d_name});
        return 2;
    };
    inline for (App.agents) |A| if (std.mem.eql(u8, A.id, rest[0])) {
        inline for (A.tools) |TI| {
            out.print("tool {s}: {s}\n", .{ TI.name, TI.description });
            switch (dialect) {
                inline else => |d| out.print("{s}\n\n", .{comptime z.schema.render(TI.Input, d)}),
            }
        }
        if (A.has_output_type) switch (dialect) {
            inline else => |d| out.print("output {s}:\n{s}\n", .{ @typeName(A.Output), comptime z.schema.render(A.Output, d) }),
        };
        return 0;
    };
    return unknownName(out, "agent", rest[0], agent_ids);
}

fn cmdPrefix(out: Out, rest: []const []const u8) u8 {
    if (rest.len == 0) {
        out.write("usage: prefix <agent>\n");
        return 2;
    }
    inline for (App.agents) |A| if (std.mem.eql(u8, A.id, rest[0])) {
        out.print("hash: 0x{x:0>16}\nbytes: {d}{s}\n\n{s}\n", .{
            A.prefix_hash, A.prefix.json.len, if (A.mcp_tools.len > 0) " (MCP tools are added at App.init)" else "", A.prefix.json,
        });
        return 0;
    };
    return unknownName(out, "agent", rest[0], agent_ids);
}

fn cmdGraph(out: Out, rest: []const []const u8) u8 {
    if (rest.len == 0) {
        out.write("usage: graph <workflow>\n");
        return 2;
    }
    inline for (App.workflows) |W| if (std.mem.eql(u8, W.id, rest[0])) {
        out.write(W.mermaid);
        return 0;
    };
    return unknownName(out, "workflow", rest[0], workflow_ids);
}

fn cmdModels(out: Out, io: Io, rest: []const []const u8) u8 {
    const now_s: i64 = @intCast(@divFloor(Io.Clock.real.now(io).nanoseconds, std.time.ns_per_s));
    const age = z.catalog.ageDays(now_s);
    out.print("catalog generated {s} ({d} days ago)\n\n", .{ z.catalog.generated, age });
    comptime var seen: []const []const u8 = &.{};
    inline for (App.agents) |A| {
        const name = comptime A.model.fullName();
        comptime var dup = false;
        inline for (seen) |s| {
            if (comptime std.mem.eql(u8, s, name)) dup = true;
        }
        if (!dup) {
            seen = seen ++ &[_][]const u8{name};
            const m = A.model;
            out.print("{s}\n  context {d}, max output {d}\n", .{ name, m.context_window, m.max_output });
            if (m.pricing) |p| out.print("  $/MTok: in {d}, out {d}, cache read {d}, cache write {d}\n", .{ p.input, p.output, p.cache_read, p.cache_write });
            out.print("  supports: tools={} structured_output={} vision={} reasoning={} caching={}\n", .{
                m.supports.tools, m.supports.structured_output, m.supports.vision, m.supports.reasoning, m.supports.prompt_caching,
            });
            if (m.supports.reasoning) {
                const r = m.supports.reasoning_modes;
                out.print("  reasoning: {s} by default; .on={s} .off={s} budget={s} show_reasoning={s}{s}\n", .{
                    if (r.default_on) "on" else "off",
                    if (r.adaptive) "adaptive" else if (m.api == .openai_responses) "effort" else if (r.default_on) "yes" else "no",
                    if (!r.disable) "no" else if (r.disable_only_up_to_high) "at effort <= high" else "yes",
                    if (r.budget) "yes" else "no",
                    if (!r.visible) "no" else if (r.display_param) "summaries" else "yes",
                    if (m.api != .openai_responses) "" else if (r.xhigh_effort) "; effort up to xhigh" else "; effort up to high",
                });
            }
        }
    }
    if (has(rest, "--stale")) {
        if (age > 90) {
            out.print("\nwarning: the model catalog is {d} days old; run `zig build models-update` in zastra (or use z.custom for new models)\n", .{age});
            return 1;
        }
        out.write("\ncatalog is fresh\n");
    }
    return 0;
}

fn cmdTrace(out: Out, io: Io, arena: Allocator, rest: []const []const u8) u8 {
    if (rest.len == 0) {
        out.write("usage: trace <run_id>\n");
        return 2;
    }
    const text = Io.Dir.cwd().readFileAlloc(io, trace_file, arena, .limited(256 << 20)) catch {
        out.print("no {s} in the current directory (the dev CLI writes it during chat/run/resume)\n", .{trace_file});
        return 1;
    };
    const Span = struct {
        trace_id: []const u8,
        span_id: []const u8,
        parent_id: ?[]const u8,
        name: []const u8,
        kind: []const u8,
        start_ns: i128,
        end_ns: i128,
        status: []const u8,
        @"error": ?[]const u8 = null,
        attrs: std.json.Value,
    };
    var spans: std.ArrayList(Span) = .empty;
    var traces: std.StringHashMapUnmanaged(void) = .empty;
    var lines = std.mem.splitScalar(u8, text, '\n');
    while (lines.next()) |line| {
        if (line.len == 0) continue;
        const s = std.json.parseFromSliceLeaky(Span, arena, line, .{ .ignore_unknown_fields = true }) catch continue;
        spans.append(arena, s) catch return 1;
        if (s.attrs == .object) if (s.attrs.object.get("run_id")) |rid| if (rid == .string and std.mem.eql(u8, rid.string, rest[0])) {
            traces.put(arena, s.trace_id, {}) catch return 1;
        };
    }
    if (traces.count() == 0) {
        out.print("no spans for run '{s}' in {s}\n", .{ rest[0], trace_file });
        return 1;
    }
    // Print each root, then children depth-first, ordered by start time.
    std.mem.sort(Span, spans.items, {}, struct {
        fn lt(_: void, a: Span, b: Span) bool {
            return a.start_ns < b.start_ns;
        }
    }.lt);
    for (spans.items) |s| {
        if (!traces.contains(s.trace_id)) continue;
        const is_root = if (s.parent_id) |p| blk: {
            for (spans.items) |o| if (std.mem.eql(u8, o.span_id, p)) break :blk false;
            break :blk true;
        } else true;
        if (is_root) printSpan(out, Span, spans.items, s, 0);
    }
    return 0;
}

fn printSpan(out: Out, comptime Span: type, all: []const Span, s: Span, depth: usize) void {
    for (0..depth) |_| out.write("  ");
    const ms = @as(f64, @floatFromInt(s.end_ns - s.start_ns)) / 1e6;
    out.print("{s} {s}  {d:.1}ms", .{ s.kind, s.name, ms });
    if (s.attrs == .object) {
        const a = s.attrs.object;
        if (a.get("input_tokens")) |v| if (v == .integer) out.print("  in={d}", .{v.integer});
        if (a.get("output_tokens")) |v| if (v == .integer) out.print(" out={d}", .{v.integer});
        if (a.get("cost_usd")) |v| switch (v) {
            .float => |f| out.print(" ${d:.5}", .{f}),
            else => {},
        };
    }
    if (!std.mem.eql(u8, s.status, "ok")) out.print("  ERROR {s}", .{s.@"error" orelse ""});
    out.write("\n");
    for (all) |c| if (c.parent_id) |p| if (std.mem.eql(u8, p, s.span_id)) printSpan(out, Span, all, c, depth + 1);
}

// ── commands that need a runtime ─────────────────────────────────────────────

fn makeContext(gpa: Allocator, io: Io) !*App.Context {
    if (@hasDecl(app, "createContext")) return app.createContext(gpa, io);
    const Ctx = App.Context;
    inline for (std.meta.fields(Ctx)) |f| if (f.default_value_ptr == null)
        @compileError("zastra dev: App's Ctx field `" ++ f.name ++ "` has no default, so the dev CLI can't build a context. Export `pub fn createContext(gpa: std.mem.Allocator, io: std.Io) !*Ctx` from the app module.");
    const c = try gpa.create(Ctx);
    c.* = .{};
    return c;
}

fn freeContext(gpa: Allocator, c: *App.Context) void {
    if (@hasDecl(app, "destroyContext")) return app.destroyContext(gpa, c);
    gpa.destroy(c);
}

fn readInput(io: Io, arena: Allocator, arg: []const u8) ![]const u8 {
    if (arg.len > 0 and arg[0] == '@') return Io.Dir.cwd().readFileAlloc(io, arg[1..], arena, .limited(16 << 20));
    return arg;
}

fn withRuntime(gpa: Allocator, io: Io, arena: Allocator, out: Out, env: *const std.process.Environ.Map, db_path: []const u8, cmd: []const u8, rest: []const []const u8) !u8 {
    const ctx = try makeContext(gpa, io);
    defer freeContext(gpa, ctx);
    var tf = try Io.Dir.cwd().createFile(io, trace_file, .{ .truncate = false });
    defer tf.close(io);
    var rt = App.init(gpa, io, .{
        .ctx = ctx,
        .env = env,
        .storage_path = db_path,
        .tracing = .{ .jsonl = .{ .file = tf, .append = true } },
    }) catch |err| {
        out.print("startup failed: {t}: {s}\n", .{ err, App.initDiagnostic() });
        return 1;
    };
    defer rt.deinit();

    if (std.mem.eql(u8, cmd, "chat")) return chat(&rt, gpa, io, out, rest);
    if (std.mem.eql(u8, cmd, "run")) return runWorkflow(&rt, io, arena, out, rest);
    if (std.mem.eql(u8, cmd, "runs")) return listRuns(&rt, arena, out, rest);
    if (std.mem.eql(u8, cmd, "resume")) return resumeRun(&rt, io, arena, out, rest);
    return 2;
}

fn chat(rt: *App.Runtime, gpa: Allocator, io: Io, out: Out, rest: []const []const u8) !u8 {
    if (rest.len == 0) {
        out.write("usage: chat <agent> [--thread t] [--resource r]\n");
        return 2;
    }
    inline for (App.agents) |A| if (std.mem.eql(u8, A.id, rest[0])) {
        return chatWith(A, rt, gpa, io, out, flag(rest, "--thread"), flag(rest, "--resource"));
    };
    return unknownName(out, "agent", rest[0], agent_ids);
}

fn chatWith(comptime A: type, rt: *App.Runtime, gpa: Allocator, io: Io, out: Out, thread_flag: ?[]const u8, resource: ?[]const u8) !u8 {
    var in_buf: [16 * 1024]u8 = undefined;
    var stdin = Io.File.stdin().readerStreaming(io, &in_buf);
    var thread_buf: [64]u8 = undefined;
    const thread: ?[]const u8 = if (A.history_messages > 0) (thread_flag orelse try rt.state().newIdInto(&thread_buf, "chat")) else thread_flag;
    out.print("chatting with '{s}' ({s}){s}{s}. Ctrl-D to exit.\n", .{ A.id, comptime A.model.fullName(), if (thread != null) ", thread " else "", thread orelse "" });
    while (true) {
        out.write("\n> ");
        out.flush();
        const line = stdin.interface.takeDelimiter('\n') catch break orelse break;
        const text = std.mem.trim(u8, line, " \r\t");
        if (text.len == 0) continue;
        var arena: std.heap.ArenaAllocator = .init(gpa);
        defer arena.deinit();
        var s = rt.agent(A).stream(arena.allocator(), try arena.allocator().dupe(u8, text), .{ .thread = thread, .resource = resource }) catch |err| {
            out.print("error: {t}: {s}\n", .{ err, rt.lastDiagnostic() });
            continue;
        };
        defer s.deinit();
        while (true) {
            const ev = s.next() catch |err| {
                out.print("\nerror: {t}: {s}\n", .{ err, rt.lastDiagnostic() });
                break;
            } orelse break;
            switch (ev) {
                inline else => |payload, tag| {
                    const t = @tagName(tag);
                    if (comptime std.mem.eql(u8, t, "text_delta")) {
                        out.write(payload);
                        out.flush();
                    } else if (comptime std.mem.eql(u8, t, "tool_call")) {
                        out.print("\n  → {f}\n", .{z.fmt.json(payload)});
                    } else if (comptime std.mem.eql(u8, t, "tool_result")) {
                        out.print("  ← {s} ({d}ms){s}: {s}\n", .{ payload.tool, payload.elapsed_ms, if (payload.is_error) " error" else "", truncate(payload.content, 300) });
                    } else if (comptime std.mem.eql(u8, t, "approval_request")) {
                        out.print("\n  approve {f}? [y/N] ", .{z.fmt.json(payload.call)});
                        out.flush();
                        const ans = stdin.interface.takeDelimiter('\n') catch null;
                        const yes = if (ans) |a| (a.len > 0 and (a[0] == 'y' or a[0] == 'Y')) else false;
                        try s.respond(payload.id, if (yes) .approve else .{ .deny = "Denied by the operator." });
                    } else if (comptime std.mem.eql(u8, t, "finish")) {
                        const u = payload.usage;
                        out.print("\n  [{t}, {d} steps, {d} in ({d} cached) / {d} out tokens, ${d:.5}]\n", .{ payload.reason, payload.steps, u.totalInput(), u.cache_read_tokens, u.output_tokens, u.cost_usd });
                    }
                },
            }
        }
    }
    return 0;
}

fn truncate(s: []const u8, n: usize) []const u8 {
    return if (s.len <= n) s else s[0..n];
}

fn printResult(comptime W: type, out: Out, r: W.Result) void {
    switch (r) {
        inline else => |payload, tag| {
            const t = @tagName(tag);
            if (comptime std.mem.eql(u8, t, "completed")) {
                out.print("{{\"status\":\"completed\",\"output\":{f}}}\n", .{z.fmt.json(payload)});
            } else if (comptime std.mem.eql(u8, t, "suspended")) {
                switch (payload.at) {
                    inline else => |p, at| out.print("{{\"status\":\"suspended\",\"run_id\":\"{s}\",\"at\":\"{s}\",\"payload\":{f}}}\n", .{ payload.run_id, @tagName(at), z.fmt.json(p) }),
                }
            } else {
                out.print("{{\"status\":\"failed\",\"step\":\"{s}\",\"error\":\"{t}\",\"message\":{f}}}\n", .{ payload.step, payload.err, z.fmt.json(payload.message) });
            }
        },
    }
}

fn runWorkflow(rt: *App.Runtime, io: Io, arena: Allocator, out: Out, rest: []const []const u8) !u8 {
    if (rest.len < 2) {
        out.write("usage: run <workflow> <json | @file.json> [--resource r]\n");
        return 2;
    }
    const text = try readInput(io, arena, rest[1]);
    inline for (App.workflows) |W| if (std.mem.eql(u8, W.id, rest[0])) {
        var issue: z.schema.Issue = .{};
        const input = z.schema.parse(W.Input, arena, text, &issue) catch {
            out.print("invalid input for '{s}': {f}\n", .{ W.id, issue });
            return 1;
        };
        const r = rt.workflow(W).start(arena, input, .{ .resource = flag(rest, "--resource") }) catch |err| {
            out.print("error: {t}: {s}\n", .{ err, rt.lastDiagnostic() });
            return 1;
        };
        printResult(W, out, r);
        return if (r == .failed) 1 else 0;
    };
    return unknownName(out, "workflow", rest[0], workflow_ids);
}

fn listRuns(rt: *App.Runtime, arena: Allocator, out: Out, rest: []const []const u8) !u8 {
    const store = rt.state().storage orelse return 1;
    const runs = try store.listRuns(arena, .{ .status = if (has(rest, "--suspended")) "suspended" else null });
    if (runs.len == 0) out.write("no runs\n");
    for (runs) |r| {
        var current = false;
        inline for (App.workflows) |W| if (std.mem.eql(u8, W.id, r.workflow_id)) {
            current = r.fingerprint == W.fingerprint_value;
        };
        out.print("{s}  {s}  {s}{s}{s}{s}\n", .{
            r.run_id,                 r.workflow_id, r.status, if (r.suspended_at != null) " at " else "", r.suspended_at orelse "",
            if (current) "" else "  (snapshot from a different workflow shape)",
        });
    }
    return 0;
}

fn resumeRun(rt: *App.Runtime, io: Io, arena: Allocator, out: Out, rest: []const []const u8) !u8 {
    if (rest.len < 2) {
        out.write("usage: resume <run_id> <json | @file.json>\n");
        return 2;
    }
    const store = rt.state().storage orelse return 1;
    const rec = (try store.loadRun(arena, rest[0])) orelse {
        out.print("no run '{s}'\n", .{rest[0]});
        return 1;
    };
    const text = try readInput(io, arena, rest[1]);
    const at = rec.suspended_at orelse {
        out.print("run '{s}' is {s}, not suspended\n", .{ rest[0], rec.status });
        return 1;
    };
    inline for (App.workflows) |W| if (std.mem.eql(u8, W.id, rec.workflow_id)) {
        inline for (W.slots) |slot| {
            if (comptime slot.S != void and isSusp(slot.S)) {
                if (std.mem.eql(u8, slot.path, at)) {
                    var issue: z.schema.Issue = .{};
                    const value = z.schema.parse(slot.S.Resume, arena, text, &issue) catch {
                        out.print("invalid resume value for '{s}': {f}\n", .{ at, issue });
                        return 1;
                    };
                    const r = rt.workflow(W).resumeStep(slot.S, arena, rest[0], value) catch |err| {
                        out.print("error: {t}: {s}\n", .{ err, rt.lastDiagnostic() });
                        return 1;
                    };
                    printResult(W, out, r);
                    return if (r == .failed) 1 else 0;
                }
            }
        }
        out.print("run '{s}' is suspended at '{s}', which isn't a suspendable step of the current '{s}'\n", .{ rest[0], at, W.id });
        return 1;
    };
    out.print("run '{s}' belongs to workflow '{s}', which isn't in this App\n", .{ rest[0], rec.workflow_id });
    return 1;
}

fn isSusp(comptime S: type) bool {
    return @typeInfo(S) == .@"struct" and @hasDecl(S, "Suspend") and @hasDecl(S, "Resume");
}
