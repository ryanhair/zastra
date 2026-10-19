//! `z.App(...)`: the registry, and `App.init` → the runtime (PLAN.md §3, §4).

const std = @import("std");
const errors = @import("meta/errors.zig");
const reflect = @import("meta/reflect.zig");
const agent_mod = @import("agent/agent.zig");
const run = @import("agent/run.zig");
const runtime = @import("runtime.zig");
const provider = @import("provider/provider.zig");
const http = @import("provider/http.zig");
const trace = @import("trace/trace.zig");
const storage = @import("storage/storage.zig");
const catalog = @import("catalog/catalog.zig");
const msg = @import("message.zig");
const mcp_decl = @import("mcp/mcp.zig");
const model_mod = @import("model.zig");
const Allocator = std.mem.Allocator;

const known_config = [_][]const u8{ "ctx", "agents", "workflows", "storage", "mcp" };

pub fn isApp(comptime T: type) bool {
    return @TypeOf(T) == type and reflect.isContainer(T) and @hasDecl(T, "zastra_app");
}

pub fn App(comptime cfg: anytype) type {
    comptime {
        @setEvalBranchQuota(10_000_000);
        const C = @TypeOf(cfg);
        reflect.checkConfigFields(C, &known_config, "z.App(...) config");
        if (!@hasField(C, "ctx")) errors.fail("z.App(...) needs `.ctx = YourCtx` (use `.ctx = struct {{}}` if you have no dependencies)", .{});
        const Ctx = cfg.ctx;
        if (@TypeOf(Ctx) != type) errors.fail("z.App(...): `.ctx` must be a type", .{});

        // ── agents ───────────────────────────────────────────────────────
        var agent_list: []const type = &.{};
        if (@hasField(C, "agents")) {
            const T = @TypeOf(cfg.agents);
            if (!reflect.isTuple(T)) errors.fail("z.App(...): `.agents` must be a tuple of agent types, like `.{{ Support, TriageAgent }}`", .{});
            for (0..reflect.fields(T).len) |i| {
                const A = cfg.agents[i];
                if (@TypeOf(A) != type or !agent_mod.isAgent(A)) errors.fail("z.App(...): `.agents` entry {d} is not an agent; create agents with `z.Agent(Ctx, .{{ ... }})`", .{i});
                if (A.Ctx != Ctx) errors.fail("z.App(...): agent '{s}' was declared with context {s}, but the App's `.ctx` is {s}", .{ A.id, @typeName(A.Ctx), @typeName(Ctx) });
                for (agent_list) |B| if (std.mem.eql(u8, A.id, B.id)) errors.fail("z.App(...): two agents are named '{s}'", .{A.id});
                agent_list = agent_list ++ &[_]type{A};
            }
        }

        // ── workflows ────────────────────────────────────────────────────
        var workflow_list: []const type = &.{};
        if (@hasField(C, "workflows")) {
            const T = @TypeOf(cfg.workflows);
            if (!reflect.isTuple(T)) errors.fail("z.App(...): `.workflows` must be a tuple of workflow types", .{});
            const wf = @import("workflow/workflow.zig");
            for (0..reflect.fields(T).len) |i| {
                const W = cfg.workflows[i];
                wf.checkRegistrable(W, Ctx);
                for (workflow_list) |V| if (std.mem.eql(u8, W.id, V.id)) errors.fail("z.App(...): two workflows are named '{s}'", .{W.id});
                workflow_list = workflow_list ++ &[_]type{W};
                // Agents used by workflow agent-steps count as registered.
                for (W.agents) |A| {
                    var found = false;
                    for (agent_list) |B| if (A == B) {
                        found = true;
                    };
                    if (!found) agent_list = agent_list ++ &[_]type{A};
                }
            }
        }

        // ── storage & mcp ────────────────────────────────────────────────
        const storage_kind: storage.Kind = if (@hasField(C, "storage")) cfg.storage else .memory;
        var mcp_names: []const []const u8 = &.{};
        var mcp_transports: []const mcp_decl.Transport = &.{};
        if (@hasField(C, "mcp")) {
            for (reflect.fields(@TypeOf(cfg.mcp))) |f| {
                mcp_names = mcp_names ++ &[_][]const u8{f.name};
                mcp_transports = mcp_transports ++ &[_]mcp_decl.Transport{@field(cfg.mcp, f.name)};
            }
        }
        for (agent_list) |A| for (A.mcp_tools) |set| {
            var ok = false;
            for (mcp_names) |n| if (std.mem.eql(u8, n, set.server_name)) {
                ok = true;
            };
            if (!ok) errors.fail("agent '{s}' uses MCP server '{s}', but z.App(...) has no `.mcp.{s}`{s}", .{
                A.id, set.server_name, set.server_name, errors.didYouMean(set.server_name, mcp_names),
            });
        };

        // ── environment variables the models need ────────────────────────
        var env: []const []const u8 = &.{};
        for (agent_list) |A| if (A.model.api_key_env) |k| {
            var seen = false;
            for (env) |e| if (std.mem.eql(u8, e, k)) {
                seen = true;
            };
            if (!seen) env = env ++ &[_][]const u8{k};
        };
        // ...and the MCP servers' bearer tokens.
        for (mcp_transports) |t| switch (t) {
            .http => |d| if (d.bearer_env) |k| {
                var seen = false;
                for (env) |e| if (std.mem.eql(u8, e, k)) {
                    seen = true;
                };
                if (!seen) env = env ++ &[_][]const u8{k};
            },
            .stdio => {},
        };

        const agents_final = agent_list;
        const workflows_final = workflow_list;
        const env_final = env;
        const mcp_names_final = mcp_names;
        const mcp_transports_final = mcp_transports;

        return struct {
            pub const zastra_app = true;
            pub const Context = Ctx;
            pub const agents = agents_final;
            pub const workflows = workflows_final;
            pub const storage_backend = storage_kind;
            pub const required_env = env_final;
            pub const mcp_servers = mcp_names_final;
            pub const mcp_server_transports = mcp_transports_final;
            /// The MCP manager, with only the declared transports compiled in.
            pub const McpManager = @import("mcp/manager.zig").Manager(@import("mcp/manager.zig").kindsOf(mcp_transports_final));

            pub const InitOptions = struct {
                ctx: *Ctx,
                /// Usually `init.environ_map`. API keys and base URLs come from here.
                env: ?*const std.process.Environ.Map = null,
                /// Path of the SQLite database (`.storage = .sqlite`).
                storage_path: []const u8 = "zastra.sqlite",
                tracing: trace.Config = .off,
                ca_bundle: http.CaBundle = .system,
                http: struct {
                    timeout_ms: u32 = 120_000,
                    /// Time allowed between bytes of a streaming response; 0 disables it.
                    idle_timeout_ms: u32 = 300_000,
                    max_retries: u8 = 2,
                    /// Save response bodies here, to build test cassettes.
                    record_dir: ?[]const u8 = null,
                } = .{},
                mcp: @import("mcp/manager.zig").Options = .{},
                /// Test harness hooks. Not for production use.
                testing: ?Testing = null,

                pub const Testing = struct {
                    replay: *http.Replay,
                    clock_ms: ?*const fn () i64 = null,
                };
            };

            pub const Error = error{ OutOfMemory, MissingApiKey, StorageFailed, McpFailed } || http.Error;

            const Self = @This();
            pub const Runtime = RuntimeOf(Self);

            /// Validate everything that is only knowable at runtime, once:
            /// API keys (derived from the models at comptime), CA
            /// certificates, storage migrations and MCP servers.
            pub fn init(gpa: Allocator, io: std.Io, opts: InitOptions) Error!Runtime {
                const st = try gpa.create(runtime.State);
                errdefer gpa.destroy(st);
                st.* = .{
                    .gpa = gpa,
                    .io = io,
                    .http = undefined,
                    .env = opts.env,
                    .ctx = @ptrCast(opts.ctx),
                    .tracer = .{ .io = io, .config = opts.tracing },
                    .clock_ms = if (opts.testing) |t| t.clock_ms else null,
                    .tag_requests = opts.testing != null,
                };
                if (opts.testing) |t| {
                    st.http = .initReplay(gpa, io, t.replay);
                } else {
                    var missing: [required_env.len][]const u8 = undefined;
                    var n: usize = 0;
                    for (required_env) |k| {
                        const v = if (opts.env) |e| e.get(k) else null;
                        if (v == null or v.?.len == 0) {
                            missing[n] = k;
                            n += 1;
                        }
                    }
                    if (n > 0) {
                        var buf: [512]u8 = undefined;
                        var w: std.Io.Writer = .fixed(&buf);
                        w.writeAll("missing environment variable") catch {};
                        if (n > 1) w.writeAll("s") catch {};
                        w.writeAll(": ") catch {};
                        for (missing[0..n], 0..) |k, i| {
                            if (i > 0) w.writeAll(", ") catch {};
                            w.writeAll(k) catch {};
                        }
                        if (opts.env == null) w.writeAll(" (pass `.env = init.environ_map` to App.init)") catch {};
                        st.diag.set(0, w.buffered());
                        lastInitDiag().* = st.diag;
                        return error.MissingApiKey;
                    }
                    st.http = http.Http.init(gpa, io, .{
                        .ca_bundle = opts.ca_bundle,
                        .timeout_ms = opts.http.timeout_ms,
                        .idle_timeout_ms = opts.http.idle_timeout_ms,
                        .max_retries = opts.http.max_retries,
                        .record_dir = opts.http.record_dir,
                    }, opts.env) catch |err| {
                        if (err == error.NoCaCertificates) st.diag.set(0, "no CA certificates found in the system store; pass `.ca_bundle = .{ .pem = @embedFile(\"cacert.pem\") }` to App.init (common in FROM scratch containers)");
                        if (err == error.CaBundleInvalid) st.diag.set(0, "the CA bundle given to App.init couldn't be parsed");
                        lastInitDiag().* = st.diag;
                        return err;
                    };
                }
                errdefer st.http.deinit();

                if (opts.tracing == .otlp) {
                    const o = opts.tracing.otlp;
                    st.tracer.exporter = o.start(gpa, io, opts.env, opts.ca_bundle, o.options) catch |err| {
                        if (err == error.NoCaCertificates) st.diag.set(0, "OTLP exporter: no CA certificates found in the system store");
                        if (err == error.CaBundleInvalid) st.diag.set(0, "OTLP exporter: the CA bundle given to App.init couldn't be parsed");
                        lastInitDiag().* = st.diag;
                        return err;
                    };
                }
                errdefer if (st.tracer.exporter) |e| e.vtable.deinit(e.ptr);

                const backend = try gpa.create(Backend);
                errdefer gpa.destroy(backend);
                backend.* = Backend.open(gpa, io, opts.storage_path) catch |err| {
                    st.diag.print(0, "opening storage '{s}': {t}", .{ opts.storage_path, err });
                    lastInitDiag().* = st.diag;
                    return error.StorageFailed;
                };
                errdefer backend.close();
                st.storage = backend.storageIface();

                if (mcp_servers.len > 0) {
                    const Mcp = McpManager;
                    const m = Mcp.start(gpa, io, st, mcp_servers, mcp_server_transports, opts.mcp) catch |err| {
                        lastInitDiag().* = st.diag;
                        return err;
                    };
                    st.mcp = m;
                    st.mcp_vtable = &Mcp.vtable;
                    inline for (agents) |A| if (A.mcp_tools.len > 0) {
                        m.register(A) catch |err| {
                            if (err != error.McpUnknownTool) st.diag.print(0, "agent '{s}': MCP tools: {t}", .{ A.id, err });
                            lastInitDiag().* = st.diag;
                            m.stop();
                            return error.McpFailed;
                        };
                    };
                }
                return .{ .st = st, .backend = backend };
            }

            fn BackendOf(comptime k: storage.Kind) type {
                return switch (k) {
                    .memory => @import("storage/memory_store.zig").MemoryStore,
                    .sqlite => @import("storage/sqlite.zig").SqliteStore,
                };
            }

            pub const Backend = BackendOf(storage_kind);

            /// The diagnostic for the last failed `App.init`.
            pub fn initDiagnostic() []const u8 {
                return lastInitDiag().message();
            }

            fn lastInitDiag() *provider.Diagnostic {
                const S = struct {
                    threadlocal var d: provider.Diagnostic = .{};
                };
                return &S.d;
            }

            pub fn hasAgent(comptime A: type) bool {
                for (agents) |B| if (A == B) return true;
                return false;
            }
        };
    }
}

fn RuntimeOf(comptime AppT: type) type {
    return struct {
        const Self = @This();
        st: *runtime.State,
        backend: *AppT.Backend,

        pub fn deinit(rt: *Self) void {
            const gpa = rt.st.gpa;
            // First: the last batch goes out while the runtime is intact.
            if (rt.st.tracer.exporter) |e| e.vtable.deinit(e.ptr);
            if (AppT.mcp_servers.len > 0) if (rt.st.mcp) |m| {
                @as(*AppT.McpManager, @ptrCast(@alignCast(m))).stop();
            };
            rt.backend.close();
            gpa.destroy(rt.backend);
            rt.st.http.deinit();
            gpa.destroy(rt.st);
        }

        /// Typed handle for an agent registered in the App.
        pub fn agent(rt: *Self, comptime A: type) AgentHandle(A) {
            if (!comptime AppT.hasAgent(A)) @compileError("zastra: rt.agent(...): agent '" ++ A.id ++ "' isn't registered in z.App(.{ .agents = ... })");
            return .{ .st = rt.st };
        }

        /// Raw model access, no agent: `rt.model("anthropic/claude-haiku-4-5")`.
        pub fn model(rt: *Self, comptime spec: anytype) model_mod.Model(catalog.resolve(spec, "rt.model(...)")) {
            return .{ .st = rt.st };
        }

        /// Typed handle for a workflow registered in the App.
        pub fn workflow(rt: *Self, comptime W: type) @import("workflow/runner.zig").Handle(W) {
            comptime var found = false;
            inline for (AppT.workflows) |V| {
                if (V == W) found = true;
            }
            if (!found) @compileError("zastra: rt.workflow(...): workflow '" ++ W.id ++ "' isn't registered in z.App(.{ .workflows = ... })");
            return .{ .st = rt.st };
        }

        /// Saved runs of every agent and workflow: `list`, `get`, `cancel`.
        pub fn runs(rt: *Self) @import("runs.zig").Handle(AppT) {
            return .{ .st = rt.st };
        }

        /// Details of the last failure: a provider error body, a validation
        /// path, missing environment variables.
        pub fn lastDiagnostic(rt: *Self) []const u8 {
            return rt.st.diag.message();
        }

        /// The runtime state, for zastra's own build helpers (dev CLI, C ABI).
        pub fn state(rt: *Self) *runtime.State {
            return rt.st;
        }
    };
}

pub fn AgentHandle(comptime A: type) type {
    return struct {
        st: *runtime.State,

        /// `union { completed, suspended }` for an agent with approval-gated
        /// tools, otherwise the plain result struct (PLAN.md D31, D22).
        pub const Result = run.Result(A);
        pub const Options = run.Options(A);
        pub const Stream = run.Stream(A);

        /// Run to completion. `input` is a prompt string or messages.
        pub fn generate(h: @This(), arena: Allocator, input: anytype, opts: Options) run.Error!Result {
            const msgs = try run.toMessages(arena, input);
            return run.generate(A, h.st, arena, msgs, opts);
        }

        /// Stream events: `while (try stream.next()) |event| switch (event) { ... }`.
        pub fn stream(h: @This(), arena: Allocator, input: anytype, opts: Options) run.Error!*Stream {
            const msgs = try run.toMessages(arena, input);
            return Stream.init(h.st, arena, msgs, opts);
        }

        /// Continue a suspended run with decisions for some or all of its
        /// pending approvals. Works in any process with the same storage.
        pub fn resumeRun(h: @This(), arena: Allocator, run_id: []const u8, decisions: []const run.ApprovalDecision) run.Error!run.RunResult(gated()) {
            return run.resumeRun(A, h.st, arena, run_id, decisions);
        }

        /// Like `resumeRun`, as a stream. Approvals still pending are emitted
        /// again first.
        pub fn resumeStream(h: @This(), arena: Allocator, run_id: []const u8, decisions: []const run.ApprovalDecision) run.Error!*run.Stream(gated()) {
            return run.resumeStream(A, h.st, arena, run_id, decisions);
        }

        /// Abandon a suspended run (marked `canceled`).
        pub fn cancelRun(h: @This(), arena: Allocator, run_id: []const u8) run.Error!void {
            _ = gated();
            return run.cancelRun(A, h.st, arena, run_id);
        }

        fn gated() type {
            if (!A.has_approvals) @import("meta/errors.zig").fail("agent '{s}' has no approval-gated tools, so its runs never suspend; there is nothing to resume or cancel", .{A.id});
            return A;
        }
    };
}
