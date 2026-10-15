//! `z.testing.harness(App, opts)` (PLAN.md §10): run an App's agents and
//! workflows against scripted models, with a fake clock and no network.
//!
//!     var h = try z.testing.harness(App, .{ .ctx = &ctx });
//!     defer h.deinit();
//!     h.script(TriageAgent, &.{ .output(Triage{ ... }) });
//!     const r = try h.agent(TriageAgent).generate("...", .{});

const std = @import("std");
const builtin = @import("builtin");
const http = @import("../provider/http.zig");
const scripted = @import("scripted.zig");
const run = @import("../agent/run.zig");
const Allocator = std.mem.Allocator;

pub const Step = scripted.Step;

pub fn Options(comptime Ctx: type) type {
    return struct {
        ctx: *Ctx,
        gpa: ?Allocator = null,
        io: ?std.Io = null,
        env: ?*const std.process.Environ.Map = null,
        /// For `.storage = .sqlite` Apps: a file path lets a second harness
        /// reopen the same database (a "restart").
        storage_path: []const u8 = ":memory:",
        mcp: @import("../mcp/manager.zig").Options = .{},
    };
}

pub fn harness(comptime AppT: type, opts: Options(AppT.Context)) !*Harness(AppT) {
    const gpa = opts.gpa orelse if (builtin.is_test) std.testing.allocator else @panic("zastra harness: pass `.gpa` outside tests");
    const h = try gpa.create(Harness(AppT));
    errdefer gpa.destroy(h);
    h.* = .{
        .gpa = gpa,
        .arena = .init(gpa),
        .replay = .init(gpa, &.{}),
        .rt = undefined,
    };
    h.replay.responder = .{ .ctx = h, .respond = Harness(AppT).respond };
    h.rt = try AppT.init(gpa, opts.io orelse if (builtin.is_test) std.testing.io else @panic("zastra harness: pass `.io` outside tests"), .{
        .ctx = opts.ctx,
        .env = opts.env,
        .storage_path = opts.storage_path,
        .mcp = opts.mcp,
        .testing = .{ .replay = &h.replay, .clock_ms = fakeClock },
    });
    return h;
}

var fake_now = std.atomic.Value(i64).init(1_700_000_000_000);

fn fakeClock() i64 {
    return fake_now.fetchAdd(1000, .monotonic);
}

pub fn Harness(comptime AppT: type) type {
    return struct {
        const Self = @This();

        gpa: Allocator,
        /// Results and inputs live here until `deinit`.
        arena: std.heap.ArenaAllocator,
        replay: http.Replay,
        rt: AppT.Runtime,
        queues: std.StringHashMapUnmanaged(std.ArrayList([]u8)) = .empty,
        turns: usize = 0,
        consumed: std.ArrayList([]u8) = .empty,

        pub fn deinit(h: *Self) void {
            h.rt.deinit();
            var it = h.queues.valueIterator();
            while (it.next()) |q| {
                for (q.items) |b| h.gpa.free(b);
                q.deinit(h.gpa);
            }
            h.queues.deinit(h.gpa);
            for (h.consumed.items) |b| h.gpa.free(b);
            h.consumed.deinit(h.gpa);
            h.replay.deinit();
            h.arena.deinit();
            h.gpa.destroy(h);
        }

        /// Queue scripted model turns for agent `A`, consumed in order.
        pub fn script(h: *Self, comptime A: type, steps: []const scripted.Step(A)) void {
            const gop = h.queues.getOrPut(h.gpa, A.id) catch @panic("OOM");
            if (!gop.found_existing) gop.value_ptr.* = .empty;
            for (steps) |s| {
                h.turns += 1;
                const body = scripted.render(A, h.gpa, s, h.turns) catch @panic("OOM");
                gop.value_ptr.append(h.gpa, body) catch @panic("OOM");
            }
        }

        /// Scripted turns not yet consumed by agent `A`.
        pub fn remaining(h: *Self, comptime A: type) usize {
            const q = h.queues.get(A.id) orelse return 0;
            return q.items.len;
        }

        /// Request bodies sent so far, oldest first.
        pub fn requests(h: *Self) []const []const u8 {
            return h.replay.requests.items;
        }

        fn respond(ctx: *anyopaque, url: []const u8, headers: []const std.http.Header, body: []const u8) ?http.Interaction {
            _ = url;
            _ = body;
            const h: *Self = @ptrCast(@alignCast(ctx));
            var agent_id: []const u8 = "";
            for (headers) |hd| if (std.ascii.eqlIgnoreCase(hd.name, "x-zastra-agent")) {
                agent_id = hd.value;
            };
            const q = h.queues.getPtr(agent_id) orelse {
                std.debug.print("zastra harness: agent '{s}' made a model request, but nothing is scripted for it (use h.script)\n", .{agent_id});
                return null;
            };
            if (q.items.len == 0) {
                std.debug.print("zastra harness: agent '{s}' made more model requests than were scripted\n", .{agent_id});
                return null;
            }
            const b = q.orderedRemove(0);
            h.consumed.append(h.gpa, b) catch return null;
            return .{ .url_suffix = "", .body = b };
        }

        pub fn agent(h: *Self, comptime A: type) AgentHandle(A) {
            return .{ .h = h, .inner = h.rt.agent(A) };
        }

        pub fn workflow(h: *Self, comptime W: type) WorkflowHandle(W) {
            return .{ .h = h, .inner = h.rt.workflow(W) };
        }

        pub fn AgentHandle(comptime A: type) type {
            return struct {
                h: *Self,
                inner: @import("../app.zig").AgentHandle(A),

                pub fn generate(a: @This(), input: anytype, opts: run.Options(A)) !run.Result(A) {
                    return a.inner.generate(a.h.arena.allocator(), input, opts);
                }

                pub fn stream(a: @This(), input: anytype, opts: run.Options(A)) !*run.Stream(A) {
                    return a.inner.stream(a.h.arena.allocator(), input, opts);
                }

                pub fn resumeRun(a: @This(), run_id: []const u8, decisions: []const run.ApprovalDecision) !run.RunResult(A) {
                    return a.inner.resumeRun(a.h.arena.allocator(), run_id, decisions);
                }

                pub fn resumeStream(a: @This(), run_id: []const u8, decisions: []const run.ApprovalDecision) !*run.Stream(A) {
                    return a.inner.resumeStream(a.h.arena.allocator(), run_id, decisions);
                }

                pub fn cancelRun(a: @This(), run_id: []const u8) !void {
                    return a.inner.cancelRun(a.h.arena.allocator(), run_id);
                }
            };
        }

        pub fn WorkflowHandle(comptime W: type) type {
            const Inner = @import("../workflow/runner.zig").Handle(W);
            return struct {
                h: *Self,
                inner: Inner,

                pub fn start(wh: @This(), input: W.Input) !W.Result {
                    return wh.inner.start(wh.h.arena.allocator(), input, .{});
                }

                pub fn resumeStep(wh: @This(), comptime S: type, run_id: []const u8, value: Inner.ResumeOf(S)) !W.Result {
                    return wh.inner.resumeStep(S, wh.h.arena.allocator(), run_id, value);
                }
            };
        }
    };
}

/// Assert a workflow result is suspended at `step` and return its payload.
pub fn expectSuspended(result: anytype, comptime step: anytype) !SuspendedAt(@TypeOf(result), step) {
    switch (result) {
        .suspended => |s| switch (s.at) {
            inline else => |payload, tag| {
                if (comptime std.mem.eql(u8, @tagName(tag), @tagName(step))) {
                    if (@TypeOf(payload) == @FieldType(@TypeOf(s.at), @tagName(step)))
                        return .{ .run_id = s.run_id, .payload = payload };
                }
                std.debug.print("expected the workflow to be suspended at '{s}', but it is suspended at '{s}'\n", .{ @tagName(step), @tagName(tag) });
                return error.TestUnexpectedResult;
            },
        },
        else => |_, tag| {
            std.debug.print("expected the workflow to be suspended at '{s}', but it is {s}\n", .{ @tagName(step), @tagName(tag) });
            if (result == .failed) std.debug.print("  failure: step '{s}': {t}\n", .{ result.failed.step, result.failed.err });
            return error.TestUnexpectedResult;
        },
    }
}

pub fn SuspendedAt(comptime R: type, comptime step: anytype) type {
    const Susp = @FieldType(R, "suspended");
    const At = @FieldType(Susp, "at");
    return struct {
        run_id: []const u8,
        payload: @FieldType(At, @tagName(step)),
    };
}
