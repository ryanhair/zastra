//! `dev serve` (PLAN.md §19.2, D50): the dev CLI's commands over HTTP, with
//! SSE streaming, for local UIs and scripts in other languages.
//!
//! `z.dev.serve(App, &rt, .{})` blocks serving `127.0.0.1:4111`. Tests use
//! `z.dev.Server(App)` directly: `init`, `start` (accepts on a background
//! task), `port`, `deinit`.
//!
//! Responses use the C ABI's JSON (`capi/encode.zig`); SSE events are
//! `event: <kind>` with the C ABI's event payload as `data`. Errors are
//! `{"error":{"code":"<name>","message":"<diagnostic>"}}`.

const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;
const json = @import("../schema/json.zig");
const parse = @import("../schema/parse.zig");
const msg = @import("../message.zig");
const run = @import("../agent/run.zig");
const encode = @import("../capi/encode.zig");
const manifest = @import("../capi/manifest.zig");
const step = @import("../workflow/step.zig");
const storage = @import("../storage/storage.zig");

pub const Options = struct {
    host: []const u8 = "127.0.0.1",
    /// 0 picks a free port (see `Server.port`).
    port: u16 = 4111,
    /// Required for a non-loopback `host`; requests must then send
    /// `Authorization: Bearer <token>`.
    token: ?[]const u8 = null,
    /// One exact origin allowed to call the API from a browser (CORS), e.g.
    /// a local UI on another port.
    allow_origin: ?[]const u8 = null,
    /// The JSONL trace file `GET /api/traces/{id}` reads.
    trace_file: ?[]const u8 = null,
    /// Request bodies larger than this get 413.
    max_body: usize = 1 << 20,
};

pub const InitError = error{ NeedsToken, InvalidHost } || Io.net.IpAddress.ListenError || Allocator.Error;

/// Serve until the task is canceled. Startup problems are returned; request
/// problems are answered over HTTP.
pub fn serve(comptime App: type, rt: *App.Runtime, opts: Options) !void {
    const s = try Server(App).init(rt.state().gpa, rt.state().io, rt, opts);
    defer s.deinit();
    s.acceptLoop();
}

pub fn Server(comptime App: type) type {
    return struct {
        const Self = @This();

        gpa: Allocator,
        io: Io,
        rt: *App.Runtime,
        opts: Options,
        listener: Io.net.Server,
        group: Io.Group = .init,
        accept_task: ?Io.Future(void) = null,

        pub fn init(gpa: Allocator, io: Io, rt: *App.Runtime, opts: Options) InitError!*Self {
            const addr = Io.net.IpAddress.parse(opts.host, opts.port) catch return error.InvalidHost;
            if (!isLoopbackAddress(addr) and opts.token == null) return error.NeedsToken;
            const s = try gpa.create(Self);
            errdefer gpa.destroy(s);
            s.* = .{ .gpa = gpa, .io = io, .rt = rt, .opts = opts, .listener = try addr.listen(io, .{ .reuse_address = true }) };
            return s;
        }

        /// The bound port (useful with `.port = 0`).
        pub fn port(s: *const Self) u16 {
            return s.listener.socket.address.getPort();
        }

        /// Accept on a background task; `deinit` stops it.
        pub fn start(s: *Self) !void {
            s.accept_task = try s.io.concurrent(acceptLoop, .{s});
        }

        pub fn deinit(s: *Self) void {
            if (s.accept_task) |*t| t.cancel(s.io);
            s.group.cancel(s.io);
            s.listener.deinit(s.io);
            s.gpa.destroy(s);
        }

        pub fn acceptLoop(s: *Self) void {
            while (true) {
                const conn = s.listener.accept(s.io) catch |err| switch (err) {
                    error.Canceled => return,
                    else => continue,
                };
                s.group.concurrent(s.io, handleConnection, .{ s, conn }) catch handleConnection(s, conn);
            }
        }

        fn handleConnection(s: *Self, conn: Io.net.Stream) void {
            defer conn.close(s.io);
            var rbuf: [16 * 1024]u8 = undefined;
            var wbuf: [16 * 1024]u8 = undefined;
            var r = conn.reader(s.io, &rbuf);
            var w = conn.writer(s.io, &wbuf);
            var http: std.http.Server = .init(&r.interface, &w.interface);
            while (true) {
                var req = http.receiveHead() catch return;
                var arena: std.heap.ArenaAllocator = .init(s.gpa);
                defer arena.deinit();
                const keep = s.handle(arena.allocator(), &req) catch return;
                if (!keep) return;
            }
        }

        // ── requests ──────────────────────────────────────────────────────

        const Ctx = struct {
            s: *Self,
            arena: Allocator,
            req: *std.http.Server.Request,
            cors: ?[]const u8,
            body: []const u8 = "",
            /// Answer and close the connection without reading the body.
            close: bool = false,

            fn headers(c: *const Ctx, extra: []const std.http.Header) []const std.http.Header {
                var out = c.arena.alloc(std.http.Header, extra.len + 2) catch return extra;
                var n: usize = 0;
                for (extra) |h| {
                    out[n] = h;
                    n += 1;
                }
                if (c.cors) |o| {
                    out[n] = .{ .name = "access-control-allow-origin", .value = o };
                    out[n + 1] = .{ .name = "vary", .value = "origin" };
                    n += 2;
                }
                return out[0..n];
            }

            fn send(c: *const Ctx, status: std.http.Status, body: []const u8) !void {
                try c.req.respond(body, .{ .status = status, .keep_alive = !c.close, .extra_headers = c.headers(&.{.{ .name = "content-type", .value = "application/json" }}) });
            }

            fn fail(c: *const Ctx, status: std.http.Status, code: []const u8, comptime fmt: []const u8, args: anytype) !void {
                var aw: Io.Writer.Allocating = .init(c.arena);
                const w = &aw.writer;
                try w.writeAll("{\"error\":{\"code\":");
                try json.writeString(code, w);
                try w.writeAll(",\"message\":");
                try json.writeString(try c.arena.print(fmt, args), w);
                try w.writeAll("}}");
                try c.send(status, aw.written());
            }

            /// A zastra error from a run, with the runtime's diagnostic.
            fn failErr(c: *const Ctx, err: anyerror, diag: []const u8) !void {
                try c.fail(statusOf(err), @errorName(err), "{s}", .{if (diag.len > 0) diag else @errorName(err)});
            }
        };

        /// Returns whether the connection can serve another request.
        fn handle(s: *Self, arena: Allocator, req: *std.http.Server.Request) !bool {
            // Read what we need from the head before the body invalidates it.
            var host: ?[]const u8 = null;
            var origin: ?[]const u8 = null;
            var auth: ?[]const u8 = null;
            var it = req.iterateHeaders();
            while (it.next()) |h| {
                if (std.ascii.eqlIgnoreCase(h.name, "host")) host = try arena.dupe(u8, h.value);
                if (std.ascii.eqlIgnoreCase(h.name, "origin")) origin = try arena.dupe(u8, h.value);
                if (std.ascii.eqlIgnoreCase(h.name, "authorization")) auth = try arena.dupe(u8, h.value);
            }
            const target = try arena.dupe(u8, req.head.target);
            const method = req.head.method;
            var c: Ctx = .{ .s = s, .arena = arena, .req = req, .cors = null, .close = true };

            // Security (§19.2): Host and Origin against DNS rebinding and
            // cross-site requests, then the token.
            if (host == null or !s.hostAllowed(host.?)) {
                try c.fail(.forbidden, "ForbiddenHost", "the Host header must name this server ({s} or a loopback name)", .{s.opts.host});
                return false;
            }
            if (origin) |o| {
                if (s.opts.allow_origin != null and std.mem.eql(u8, o, s.opts.allow_origin.?)) {
                    c.cors = s.opts.allow_origin;
                } else if (!isLoopbackOrigin(o)) {
                    try c.fail(.forbidden, "ForbiddenOrigin", "requests from {s} aren't allowed; pass --allow-origin to allow one origin", .{o});
                    return false;
                }
            }
            if (method == .OPTIONS) {
                try req.respond("", .{ .status = .no_content, .keep_alive = false, .extra_headers = c.headers(&.{
                    .{ .name = "access-control-allow-methods", .value = "GET, POST" },
                    .{ .name = "access-control-allow-headers", .value = "authorization, content-type" },
                }) });
                return true;
            }
            if (s.opts.token) |token| {
                c.close = true;
                const want = try arena.print("Bearer {s}", .{token});
                const got = auth orelse "";
                if (got.len != want.len or !constantTimeEql(got, want)) {
                    try c.fail(.unauthorized, "Unauthorized", "send `Authorization: Bearer <token>`", .{});
                    return false;
                }
            }
            c.close = method != .GET and method != .POST;

            if (method == .POST) {
                c.close = true;
                if (req.head.content_length) |len| if (len > s.opts.max_body) {
                    try c.fail(.payload_too_large, "BodyTooLarge", "request bodies are limited to {d} bytes", .{s.opts.max_body});
                    return false;
                };
                var body_buf: [4096]u8 = undefined;
                const br = req.readerExpectContinue(&body_buf) catch return false;
                c.body = br.allocRemaining(arena, .limited(s.opts.max_body)) catch |err| switch (err) {
                    error.StreamTooLong => {
                        try c.fail(.payload_too_large, "BodyTooLarge", "request bodies are limited to {d} bytes", .{s.opts.max_body});
                        return false;
                    },
                    else => return false,
                };
                c.close = false;
            } else if (method != .GET) {
                try c.fail(.method_not_allowed, "MethodNotAllowed", "use GET or POST", .{});
                return false;
            }

            const q = std.mem.indexOfScalar(u8, target, '?');
            const path = target[0 .. q orelse target.len];
            const query = if (q) |i| target[i + 1 ..] else "";
            var parts: [6][]const u8 = undefined;
            var n: usize = 0;
            var pit = std.mem.tokenizeScalar(u8, path, '/');
            while (pit.next()) |p| {
                if (n == parts.len) break;
                parts[n] = try percentDecode(arena, p);
                n += 1;
            }
            try s.route(&c, method, parts[0..n], query);
            return true;
        }

        fn route(s: *Self, c: *Ctx, method: std.http.Method, p: []const []const u8, query: []const u8) !void {
            if (p.len < 2 or !std.mem.eql(u8, p[0], "api")) return c.fail(.not_found, "NotFound", "no route; see docs/dev-serve.md", .{});
            const get = method == .GET;
            const what = p[1];
            if (std.mem.eql(u8, what, "agents")) {
                if (get and p.len == 2) return c.send(.ok, comptime agentsJson());
                if (get and p.len == 3) return s.getAgent(c, p[2]);
                if (!get and p.len == 4 and std.mem.eql(u8, p[3], "generate")) return s.agentGenerate(c, p[2]);
                if (!get and p.len == 4 and std.mem.eql(u8, p[3], "stream")) return s.agentStream(c, p[2]);
            } else if (std.mem.eql(u8, what, "workflows")) {
                if (get and p.len == 2) return c.send(.ok, comptime workflowsJson());
                if (get and p.len == 4 and std.mem.eql(u8, p[3], "graph")) return s.workflowGraph(c, p[2]);
                if (!get and p.len == 4 and std.mem.eql(u8, p[3], "start")) return s.workflowStart(c, p[2]);
            } else if (std.mem.eql(u8, what, "runs")) {
                if (get and p.len == 2) return s.listRuns(c, query);
                if (get and p.len == 3) return s.getRun(c, p[2]);
                if (!get and p.len == 4 and std.mem.eql(u8, p[3], "resume")) return s.resumeRun(c, p[2], false);
                if (!get and p.len == 5 and std.mem.eql(u8, p[3], "resume") and std.mem.eql(u8, p[4], "stream")) return s.resumeRun(c, p[2], true);
                if (!get and p.len == 4 and std.mem.eql(u8, p[3], "cancel")) return s.cancelRun(c, p[2]);
            } else if (std.mem.eql(u8, what, "traces")) {
                if (get and p.len == 3) return s.getTrace(c, p[2]);
            } else if (std.mem.eql(u8, what, "models")) {
                if (get and p.len == 2) return c.send(.ok, comptime modelsJson());
            }
            return c.fail(.not_found, "NotFound", "no route for {t} /{s}", .{ method, try std.mem.join(c.arena, "/", p) });
        }

        // ── agents ────────────────────────────────────────────────────────

        fn agentsJson() []const u8 {
            comptime {
                @setEvalBranchQuota(50_000_000);
                var s: []const u8 = "[";
                for (App.agents, 0..) |A, i| s = s ++ (if (i == 0) "" else ",") ++ manifest.agentJson(A);
                return s ++ "]";
            }
        }

        fn getAgent(_: *Self, c: *Ctx, id: []const u8) !void {
            inline for (App.agents) |A| if (std.mem.eql(u8, A.id, id)) return c.send(.ok, comptime manifest.agentJson(A));
            return c.fail(.not_found, "UnknownAgent", "no agent '{s}'", .{id});
        }

        const AgentBody = struct {
            input: std.json.Value = .null,
            thread: ?[]const u8 = null,
            resource: ?[]const u8 = null,
            max_steps: ?u32 = null,
            max_tokens: ?u32 = null,
        };

        /// `input` is a string or an array of messages.
        fn agentInput(c: *Ctx) !?struct { body: AgentBody, messages: []const msg.Message } {
            const body = std.json.parseFromSliceLeaky(AgentBody, c.arena, c.body, .{ .ignore_unknown_fields = true, .allocate = .alloc_always }) catch {
                try c.fail(.bad_request, "InvalidInput", "the body must be JSON like {{\"input\":\"...\",\"thread\":\"...\"}}", .{});
                return null;
            };
            const messages: []const msg.Message = switch (body.input) {
                .string => |text| try run.toMessages(c.arena, text),
                .array => blk: {
                    var issue: parse.Issue = .{};
                    break :blk parse.fromValue([]const msg.Message, c.arena, body.input, &issue) catch {
                        try c.fail(.bad_request, "InvalidInput", "input{s}: {s}", .{ issue.path[1..], issue.message });
                        return null;
                    };
                },
                else => {
                    try c.fail(.bad_request, "InvalidInput", "`input` must be a string or an array of messages", .{});
                    return null;
                },
            };
            return .{ .body = body, .messages = messages };
        }

        fn agentGenerate(s: *Self, c: *Ctx, id: []const u8) !void {
            inline for (App.agents) |A| if (std.mem.eql(u8, A.id, id)) {
                const in = (try agentInput(c)) orelse return;
                const r = run.generate(A, s.rt.state(), c.arena, in.messages, .{
                    .thread = in.body.thread,
                    .resource = in.body.resource,
                    .max_steps = in.body.max_steps,
                    .max_tokens = in.body.max_tokens,
                }) catch |err| return c.failErr(err, s.rt.lastDiagnostic());
                return c.send(.ok, try encode.runResultJson(A, c.arena, r));
            };
            return c.fail(.not_found, "UnknownAgent", "no agent '{s}'", .{id});
        }

        fn agentStream(s: *Self, c: *Ctx, id: []const u8) !void {
            inline for (App.agents) |A| if (std.mem.eql(u8, A.id, id)) {
                const in = (try agentInput(c)) orelse return;
                const st = run.Stream(A).init(s.rt.state(), c.arena, in.messages, .{
                    .thread = in.body.thread,
                    .resource = in.body.resource,
                    .max_steps = in.body.max_steps,
                    .max_tokens = in.body.max_tokens,
                }) catch |err| return c.failErr(err, s.rt.lastDiagnostic());
                return streamEvents(A, c, st);
            };
            return c.fail(.not_found, "UnknownAgent", "no agent '{s}'", .{id});
        }

        /// Send a stream's events as SSE. At an approval the run is
        /// suspended: `approval_request` events, then `suspended` with the
        /// run id; the client continues with `POST /api/runs/{id}/resume/stream`.
        fn streamEvents(comptime A: type, c: *Ctx, st: *run.Stream(A)) !void {
            defer st.deinit();
            var buf: [8 * 1024]u8 = undefined;
            var bw = try c.req.respondStreaming(&buf, .{ .respond_options = .{ .extra_headers = c.headers(&.{
                .{ .name = "content-type", .value = "text/event-stream" },
                .{ .name = "cache-control", .value = "no-cache" },
            }) } });
            var scratch: std.heap.ArenaAllocator = .init(c.s.gpa);
            defer scratch.deinit();
            while (true) {
                _ = scratch.reset(.retain_capacity);
                const sa = scratch.allocator();
                const e = st.next() catch |err| {
                    if (comptime A.has_approvals) if (err == error.ApprovalPending) {
                        const su = st.suspendRun() catch |e2| return endWithError(&bw, sa, e2, st.diag.message());
                        sendEvent(&bw, "suspended", try encode.suspendedJson(A, sa, su)) catch return st.cancel();
                        return bw.end();
                    };
                    return endWithError(&bw, sa, err, st.diag.message());
                } orelse break;
                switch (e) {
                    inline else => |_, tag| {
                        // A failed write means the client went away: cancel the run.
                        sendEvent(&bw, @tagName(tag), try encode.eventJson(sa, e)) catch {
                            st.cancel();
                            return;
                        };
                    },
                }
            }
            if (st.result()) |r| {
                sendEvent(&bw, "result", try encode.agentResultJson(A, scratch.allocator(), r)) catch return;
            } else |_| {}
            try bw.end();
        }

        fn endWithError(bw: *std.http.BodyWriter, arena: Allocator, err: anyerror, diag: []const u8) !void {
            var aw: Io.Writer.Allocating = .init(arena);
            const w = &aw.writer;
            try w.print("{{\"error\":{{\"code\":\"{t}\",\"message\":", .{err});
            try json.writeString(if (diag.len > 0) diag else @errorName(err), w);
            try w.writeAll("}}");
            sendEvent(bw, "error", aw.written()) catch return;
            try bw.end();
        }

        // ── workflows ─────────────────────────────────────────────────────

        fn workflowsJson() []const u8 {
            comptime {
                @setEvalBranchQuota(50_000_000);
                var s: []const u8 = "[";
                for (App.workflows, 0..) |W, i| s = s ++ (if (i == 0) "" else ",") ++ manifest.workflowJson(W);
                return s ++ "]";
            }
        }

        fn workflowGraph(_: *Self, c: *Ctx, id: []const u8) !void {
            inline for (App.workflows) |W| if (std.mem.eql(u8, W.id, id)) {
                return c.send(.ok, comptime graphJson(W));
            };
            return c.fail(.not_found, "UnknownWorkflow", "no workflow '{s}'", .{id});
        }

        fn graphJson(comptime W: type) []const u8 {
            comptime {
                @setEvalBranchQuota(50_000_000);
                const str = @import("../schema/json_schema.zig").str;
                return "{\"id\":" ++ str(W.id) ++ ",\"mermaid\":" ++ str(W.mermaid) ++ "}";
            }
        }

        fn workflowStart(s: *Self, c: *Ctx, id: []const u8) !void {
            inline for (App.workflows) |W| if (std.mem.eql(u8, W.id, id)) {
                const Body = struct { input: std.json.Value = .null, resource: ?[]const u8 = null };
                const body = std.json.parseFromSliceLeaky(Body, c.arena, c.body, .{ .ignore_unknown_fields = true, .allocate = .alloc_always }) catch
                    return c.fail(.bad_request, "InvalidInput", "the body must be JSON like {{\"input\":{{...}}}}", .{});
                var issue: parse.Issue = .{};
                const input = parse.fromValue(W.Input, c.arena, body.input, &issue) catch
                    return c.fail(.bad_request, "InvalidInput", "input{s}: {s}", .{ issue.path[1..], issue.message });
                const r = s.rt.workflow(W).start(c.arena, input, .{ .resource = body.resource }) catch |err|
                    return c.failErr(err, s.rt.lastDiagnostic());
                return c.send(.ok, try encode.workflowResultJson(W, c.arena, r));
            };
            return c.fail(.not_found, "UnknownWorkflow", "no workflow '{s}'", .{id});
        }

        // ── runs ──────────────────────────────────────────────────────────

        fn store(s: *Self, c: *Ctx) !?storage.Storage {
            return s.rt.state().storage orelse {
                try c.fail(.not_found, "NoStorage", "this App runs without storage, so there are no saved runs", .{});
                return null;
            };
        }

        fn writeRun(w: *Io.Writer, r: storage.RunRecord, with_state: bool) !void {
            try w.writeAll("{\"run_id\":");
            try json.writeString(r.run_id, w);
            try w.print(",\"kind\":\"{t}\",\"owner_id\":", .{r.kind});
            try json.writeString(r.owner_id, w);
            try w.writeAll(",\"status\":");
            try json.writeString(r.status, w);
            if (r.suspended_at) |at| {
                try w.writeAll(",\"suspended_at\":");
                try json.writeString(at, w);
            }
            try w.print(",\"resumable\":{},\"created_at\":{d},\"updated_at\":{d}", .{ std.mem.eql(u8, r.status, "suspended") and current(r), r.created_at, r.updated_at });
            if (with_state and r.state_json.len > 0) {
                try w.writeAll(",\"state\":");
                try w.writeAll(r.state_json);
            }
            try w.writeByte('}');
        }

        /// Whether the run was saved by this version of its agent or workflow.
        fn current(r: storage.RunRecord) bool {
            switch (r.kind) {
                .workflow => inline for (App.workflows) |W| if (std.mem.eql(u8, W.id, r.owner_id)) return r.fingerprint == W.fingerprint_value,
                .agent => inline for (App.agents) |A| if (std.mem.eql(u8, A.id, r.owner_id)) return r.fingerprint == A.run_fingerprint,
            }
            return false;
        }

        fn listRuns(s: *Self, c: *Ctx, query: []const u8) !void {
            const st = (try s.store(c)) orelse return;
            var filter: storage.RunFilter = .{};
            var it = std.mem.tokenizeScalar(u8, query, '&');
            while (it.next()) |kv| {
                const eq = std.mem.indexOfScalar(u8, kv, '=') orelse continue;
                const k = kv[0..eq];
                const v = try percentDecode(c.arena, kv[eq + 1 ..]);
                if (std.mem.eql(u8, k, "status")) filter.status = v;
                if (std.mem.eql(u8, k, "owner")) filter.owner_id = v;
                if (std.mem.eql(u8, k, "kind")) filter.kind = std.meta.stringToEnum(storage.RunKind, v) orelse
                    return c.fail(.bad_request, "InvalidInput", "kind must be 'agent' or 'workflow'", .{});
                if (std.mem.eql(u8, k, "limit")) filter.limit = std.fmt.parseInt(u32, v, 10) catch
                    return c.fail(.bad_request, "InvalidInput", "limit must be a number", .{});
            }
            const runs = st.listRuns(c.arena, filter) catch |err| return c.failErr(err, "");
            var aw: Io.Writer.Allocating = .init(c.arena);
            try aw.writer.writeByte('[');
            for (runs, 0..) |r, i| {
                if (i > 0) try aw.writer.writeByte(',');
                try writeRun(&aw.writer, r, false);
            }
            try aw.writer.writeByte(']');
            return c.send(.ok, aw.written());
        }

        fn getRun(s: *Self, c: *Ctx, id: []const u8) !void {
            const st = (try s.store(c)) orelse return;
            const r = (st.loadRun(c.arena, id) catch |err| return c.failErr(err, "")) orelse
                return c.fail(.not_found, "RunNotFound", "no run '{s}'", .{id});
            var aw: Io.Writer.Allocating = .init(c.arena);
            try writeRun(&aw.writer, r, true);
            return c.send(.ok, aw.written());
        }

        /// Agent runs: `{"decisions":[{"id":"...","approve":true}]}`. Workflow runs: `{"value":...}`, with an
        /// optional `"step"` that must match where the run is suspended.
        fn resumeRun(s: *Self, c: *Ctx, id: []const u8, streaming: bool) !void {
            const st = (try s.store(c)) orelse return;
            const rec = (st.loadRun(c.arena, id) catch |err| return c.failErr(err, "")) orelse
                return c.fail(.not_found, "RunNotFound", "no run '{s}'", .{id});
            const body = std.json.parseFromSliceLeaky(std.json.Value, c.arena, if (c.body.len == 0) "{}" else c.body, .{}) catch
                return c.fail(.bad_request, "InvalidInput", "the body must be a JSON object", .{});
            if (body != .object) return c.fail(.bad_request, "InvalidInput", "the body must be a JSON object", .{});

            if (rec.kind == .agent) {
                inline for (App.agents) |A| if (comptime A.has_approvals) if (std.mem.eql(u8, A.id, rec.owner_id)) {
                    const decisions = (try parseDecisions(c, body.object.get("decisions"))) orelse return;
                    if (streaming) {
                        const stream = run.resumeStream(A, s.rt.state(), c.arena, id, decisions) catch |err|
                            return c.failErr(err, s.rt.lastDiagnostic());
                        return streamEvents(A, c, stream);
                    }
                    const r = run.resumeRun(A, s.rt.state(), c.arena, id, decisions) catch |err|
                        return c.failErr(err, s.rt.lastDiagnostic());
                    return c.send(.ok, try encode.runResultJson(A, c.arena, r));
                };
                return c.fail(.conflict, "WrongAgent", "run '{s}' belongs to agent '{s}', which isn't in this App or has no approval-gated tools", .{ id, rec.owner_id });
            }
            if (streaming) return c.fail(.bad_request, "InvalidInput", "resume/stream is for agent runs; resume workflow runs with POST /api/runs/{{id}}/resume", .{});
            const at = rec.suspended_at orelse return c.fail(.conflict, "NotSuspended", "run '{s}' is {s}, not suspended", .{ id, rec.status });
            if (body.object.get("step")) |sv| if (sv != .string or !std.mem.eql(u8, sv.string, at))
                return c.fail(.conflict, "NotSuspendedAtStep", "run '{s}' is suspended at '{s}'", .{ id, at });
            inline for (App.workflows) |W| if (std.mem.eql(u8, W.id, rec.owner_id)) {
                inline for (W.slots) |slot| if (comptime slot.S != void and isSuspendable(slot.S)) {
                    if (std.mem.eql(u8, slot.path, at)) {
                        var issue: parse.Issue = .{};
                        const value = parse.fromValue(slot.S.Resume, c.arena, body.object.get("value") orelse .null, &issue) catch
                            return c.fail(.bad_request, "InvalidInput", "value{s}: {s}", .{ issue.path[1..], issue.message });
                        const r = s.rt.workflow(W).resumeStep(slot.S, c.arena, id, value) catch |err|
                            return c.failErr(err, s.rt.lastDiagnostic());
                        return c.send(.ok, try encode.workflowResultJson(W, c.arena, r));
                    }
                };
                return c.fail(.conflict, "SnapshotIncompatible", "run '{s}' is suspended at '{s}', which isn't a suspendable step of the current '{s}'", .{ id, at, W.id });
            };
            return c.fail(.conflict, "WrongWorkflow", "run '{s}' belongs to workflow '{s}', which isn't in this App", .{ id, rec.owner_id });
        }

        /// `[{"id":"...","approve":true}, {"id":"...","deny":"reason"}]`, as
        /// in the C ABI. Missing: decide nothing (a stream shows the pending
        /// approvals again).
        fn parseDecisions(c: *Ctx, v: ?std.json.Value) !?[]const run.ApprovalDecision {
            const d = v orelse return &.{};
            const D = struct { id: []const u8, approve: ?bool = null, deny: ?[]const u8 = null };
            const ds = std.json.parseFromValueLeaky([]const D, c.arena, d, .{ .ignore_unknown_fields = true }) catch {
                try c.fail(.bad_request, "InvalidInput", "decisions must be an array like [{{\"id\":\"...\",\"approve\":true}}] or [{{\"id\":\"...\",\"deny\":\"reason\"}}]", .{});
                return null;
            };
            const out = try c.arena.alloc(run.ApprovalDecision, ds.len);
            for (ds, out) |x, *o| o.* = .{ .id = x.id, .decision = if (x.deny) |r| .{ .deny = r } else if (x.approve orelse false) .approve else .{ .deny = "Denied." } };
            return out;
        }

        fn cancelRun(s: *Self, c: *Ctx, id: []const u8) !void {
            const st = (try s.store(c)) orelse return;
            const rec = (st.loadRun(c.arena, id) catch |err| return c.failErr(err, "")) orelse
                return c.fail(.not_found, "RunNotFound", "no run '{s}'", .{id});
            if (!std.mem.eql(u8, rec.status, "suspended")) return c.fail(.conflict, "NotSuspended", "run '{s}' is {s}; only suspended runs can be canceled", .{ id, rec.status });
            if (rec.kind == .agent) {
                inline for (App.agents) |A| if (comptime A.has_approvals) if (std.mem.eql(u8, A.id, rec.owner_id)) {
                    run.cancelRun(A, s.rt.state(), c.arena, id) catch |err| return c.failErr(err, s.rt.lastDiagnostic());
                    return c.send(.ok, "{\"status\":\"canceled\"}");
                };
            }
            const now: i64 = @intCast(@divFloor(Io.Clock.real.now(s.io).nanoseconds, std.time.ns_per_ms));
            const ok = st.claimRun(id, "suspended", "canceled", now) catch |err| return c.failErr(err, "");
            if (!ok) return c.fail(.conflict, "RunBusy", "run '{s}' changed while canceling", .{id});
            return c.send(.ok, "{\"status\":\"canceled\"}");
        }

        // ── traces and models ─────────────────────────────────────────────

        /// Every span of the traces that contain `id` as a trace id or as a
        /// span's `run_id`, as a JSON array in file order.
        fn getTrace(s: *Self, c: *Ctx, id: []const u8) !void {
            const path = s.opts.trace_file orelse return c.fail(.not_found, "NoTraceFile", "start the server with a trace file to read traces", .{});
            const text = Io.Dir.cwd().readFileAlloc(s.io, path, c.arena, .limited(256 << 20)) catch
                return c.fail(.not_found, "NoTraceFile", "can't read {s}", .{path});
            const Head = struct { trace_id: []const u8 = "", attrs: ?std.json.Value = null };
            var traces: std.StringHashMapUnmanaged(void) = .empty;
            if (id.len == 32) try traces.put(c.arena, id, {});
            var lines = std.mem.splitScalar(u8, text, '\n');
            while (lines.next()) |line| {
                const h = std.json.parseFromSliceLeaky(Head, c.arena, line, .{ .ignore_unknown_fields = true }) catch continue;
                if (h.attrs) |a| if (a == .object) if (a.object.get("run_id")) |rid| if (rid == .string and std.mem.eql(u8, rid.string, id))
                    try traces.put(c.arena, h.trace_id, {});
            }
            if (traces.count() == 0) return c.fail(.not_found, "TraceNotFound", "no spans for '{s}' in {s}", .{ id, path });
            var aw: Io.Writer.Allocating = .init(c.arena);
            try aw.writer.writeByte('[');
            var first = true;
            lines = std.mem.splitScalar(u8, text, '\n');
            while (lines.next()) |line| {
                const h = std.json.parseFromSliceLeaky(Head, c.arena, line, .{ .ignore_unknown_fields = true }) catch continue;
                if (!traces.contains(h.trace_id)) continue;
                if (!first) try aw.writer.writeByte(',');
                first = false;
                try aw.writer.writeAll(std.mem.trim(u8, line, " \r"));
            }
            try aw.writer.writeByte(']');
            return c.send(.ok, aw.written());
        }

        fn modelsJson() []const u8 {
            comptime {
                @setEvalBranchQuota(50_000_000);
                const str = @import("../schema/json_schema.zig").str;
                var s: []const u8 = "[";
                var seen: []const []const u8 = &.{};
                for (App.agents) |A| {
                    const name = A.model.fullName();
                    var dup = false;
                    for (seen) |x| if (std.mem.eql(u8, x, name)) {
                        dup = true;
                    };
                    if (dup) continue;
                    seen = seen ++ &[_][]const u8{name};
                    const m = A.model;
                    s = s ++ (if (seen.len == 1) "" else ",") ++ "{\"model\":" ++ str(name) ++
                        std.fmt.comptimePrint(",\"context_window\":{d},\"max_output\":{d}", .{ m.context_window, m.max_output });
                    if (m.pricing) |p| s = s ++ std.fmt.comptimePrint(",\"pricing\":{{\"input\":{d},\"output\":{d},\"cache_read\":{d},\"cache_write\":{d}}}", .{ p.input, p.output, p.cache_read, p.cache_write });
                    s = s ++ std.fmt.comptimePrint(",\"supports\":{{\"tools\":{},\"structured_output\":{},\"vision\":{},\"reasoning\":{},\"prompt_caching\":{}}}}}", .{
                        m.supports.tools, m.supports.structured_output, m.supports.vision, m.supports.reasoning, m.supports.prompt_caching,
                    });
                }
                return s ++ "]";
            }
        }

        // ── security ──────────────────────────────────────────────────────

        fn hostAllowed(s: *const Self, host_header: []const u8) bool {
            const name = hostName(host_header);
            return isLoopbackName(name) or std.ascii.eqlIgnoreCase(name, hostName(s.opts.host));
        }
    };
}

fn isSuspendable(comptime S: type) bool {
    return @typeInfo(S) == .@"struct" and @hasDecl(S, "Suspend") and @hasDecl(S, "Resume");
}

pub fn statusOf(err: anyerror) std.http.Status {
    const name = @errorName(err);
    const table = [_]struct { []const u8, std.http.Status }{
        .{ "RunNotFound", .not_found },
        .{ "RunBusy", .conflict },
        .{ "NotSuspended", .conflict },
        .{ "NotSuspendedAtStep", .conflict },
        .{ "WrongAgent", .conflict },
        .{ "WrongWorkflow", .conflict },
        .{ "SnapshotIncompatible", .conflict },
        .{ "UnknownApproval", .bad_request },
        .{ "ConnectionFailed", .bad_gateway },
        .{ "Timeout", .bad_gateway },
        .{ "StreamInterrupted", .bad_gateway },
        .{ "Unauthorized", .bad_gateway },
        .{ "RateLimited", .bad_gateway },
        .{ "BadRequest", .bad_gateway },
        .{ "ProviderError", .bad_gateway },
        .{ "ProtocolError", .bad_gateway },
        .{ "MissingApiKey", .bad_gateway },
        .{ "OutputInvalid", .bad_gateway },
        .{ "McpFailed", .bad_gateway },
    };
    for (table) |row| if (std.mem.eql(u8, row[0], name)) return row[1];
    return .internal_server_error;
}

/// `event: <kind>` and one `data:` line per line of `data`.
fn sendEvent(bw: *std.http.BodyWriter, kind: []const u8, data: []const u8) !void {
    const w = &bw.writer;
    try w.print("event: {s}\n", .{kind});
    var lines = std.mem.splitScalar(u8, data, '\n');
    while (lines.next()) |line| try w.print("data: {s}\n", .{line});
    try w.writeByte('\n');
    // Drain the body buffer into the connection, then send it.
    try w.flush();
    try bw.flush();
}

/// "host:port" or "[v6]:port" → the host part, without brackets.
fn hostName(h: []const u8) []const u8 {
    if (h.len > 0 and h[0] == '[') {
        const end = std.mem.indexOfScalar(u8, h, ']') orelse return h;
        return h[1..end];
    }
    const colon = std.mem.lastIndexOfScalar(u8, h, ':') orelse return h;
    if (std.mem.indexOfScalar(u8, h[0..colon], ':') != null) return h; // bare IPv6
    return h[0..colon];
}

fn isLoopbackName(name: []const u8) bool {
    return std.ascii.eqlIgnoreCase(name, "localhost") or std.mem.eql(u8, name, "::1") or std.mem.startsWith(u8, name, "127.");
}

fn isLoopbackAddress(addr: Io.net.IpAddress) bool {
    return switch (addr) {
        .ip4 => |a| a.bytes[0] == 127,
        .ip6 => |a| std.mem.eql(u8, &a.bytes, &(@as([15]u8, @splat(0)) ++ [_]u8{1})),
    };
}

/// `http://localhost:5173` and friends.
fn isLoopbackOrigin(origin: []const u8) bool {
    const rest = if (std.mem.startsWith(u8, origin, "http://"))
        origin[7..]
    else if (std.mem.startsWith(u8, origin, "https://"))
        origin[8..]
    else
        return false;
    return isLoopbackName(hostName(rest));
}

fn constantTimeEql(a: []const u8, b: []const u8) bool {
    var d: u8 = 0;
    for (a, b) |x, y| d |= x ^ y;
    return d == 0;
}

fn percentDecode(arena: Allocator, s: []const u8) ![]const u8 {
    if (std.mem.indexOfScalar(u8, s, '%') == null and std.mem.indexOfScalar(u8, s, '+') == null) return s;
    var out: std.ArrayList(u8) = .empty;
    var i: usize = 0;
    while (i < s.len) : (i += 1) {
        if (s[i] == '%' and i + 2 < s.len) {
            if (std.fmt.parseInt(u8, s[i + 1 .. i + 3], 16)) |b| {
                try out.append(arena, b);
                i += 2;
                continue;
            } else |_| {}
        }
        try out.append(arena, if (s[i] == '+') ' ' else s[i]);
    }
    return out.items;
}

test hostName {
    try std.testing.expectEqualStrings("localhost", hostName("localhost:4111"));
    try std.testing.expectEqualStrings("::1", hostName("[::1]:4111"));
    try std.testing.expectEqualStrings("127.0.0.1", hostName("127.0.0.1"));
    try std.testing.expect(isLoopbackOrigin("http://localhost:5173"));
    try std.testing.expect(isLoopbackOrigin("http://[::1]:3000"));
    try std.testing.expect(!isLoopbackOrigin("http://evil.example"));
    try std.testing.expect(!isLoopbackOrigin("http://localhost.evil.example"));
    try std.testing.expect(!isLoopbackOrigin("null"));
}
