//! main.zig: everything an app *does* at runtime.
//!
//! The runtime surface is small on purpose: create the App, then call
//! generate / stream / start / resume. Allocation and I/O are explicit, the
//! same way they are everywhere else in Zig.

const std = @import("std");
const z = @import("zastra");
const app = @import("app.zig");

pub fn main(init: std.process.Init) !void {
    const gpa = init.gpa;
    const io = init.io;

    var db = try @import("order_db.zig").OrderDb.open(gpa, io, "orders.sqlite");
    defer db.close();
    var ctx: app.Ctx = .{ .db = &db };

    // ── Startup ──────────────────────────────────────────────────────────────
    // App.init validates once, up front, everything that is only knowable at
    // runtime: the provider keys this App needs (derived at comptime from the
    // models it uses), storage migrations, and MCP servers it must launch.
    // Missing ANTHROPIC_API_KEY fails here with a clear message, not on the
    // first customer request.
    var rt = try app.App.init(gpa, io, .{
        .ctx = &ctx,
        .env = init.environ_map,
        .storage_path = "zastra.sqlite", // backend is chosen in z.App (comptime)
        .tracing = z.trace.jsonl(std.Io.File.stderr()), // or .otlp(url), or .off
        // CA certificates are loaded here, not on the first request. `.system`
        // is the default; embed a PEM for `FROM scratch` containers.
        .ca_bundle = .system, // or .{ .pem = @embedFile("cacert.pem") }
    });
    defer rt.deinit();

    // ── 1. One-shot generate ─────────────────────────────────────────────────
    // Every call takes a caller-owned arena for its result. Results never
    // outlive what you hand in; there is no hidden global heap.
    {
        var arena: std.heap.ArenaAllocator = .init(gpa);
        defer arena.deinit();

        // Typed agent → typed result. `triage` is an `app.Triage`, not JSON.
        const triage = try rt.agent(app.TriageAgent).generate(arena.allocator(),
            "My order ORD-1042 arrived smashed and I need it for Friday!", .{});

        std.debug.print("category={t} urgency={d} order={?s}\n", .{
            triage.output.category, triage.output.urgency, triage.output.order_id,
        });
        std.debug.print("tokens in={d} out={d} cost≈${d:.4}\n", .{
            triage.usage.input_tokens, triage.usage.output_tokens, triage.usage.cost_usd,
        });
    }

    // ── 2. Streaming chat with memory + human approval ───────────────────────
    // `thread` scopes history; `resource` scopes working memory (CustomerNotes).
    {
        var arena: std.heap.ArenaAllocator = .init(gpa);
        defer arena.deinit();

        var stream = try rt.agent(app.Support).stream(arena.allocator(),
            "Please refund ORD-1042, it was broken.", .{
                .thread = "ticket-8812",
                .resource = "customer-42",
            });
        defer stream.deinit();

        // `next()` yields a tagged union. Switches are exhaustive, so a new
        // event kind in a future zastra version is a compile error, not a silently
        // dropped message.
        while (try stream.next()) |event| switch (event) {
            .text_delta => |t| try stdoutWrite(io, t),
            .reasoning_delta => {}, // opt-in to show thinking

            // Tool events are typed per tool: `.tool_call` carries a union
            // generated from the agent's tool set, so this is a real switch.
            .tool_call => |call| switch (call) {
                .lookup_order => |in| std.log.info("→ lookup {s}", .{in.order_id}),
                .issue_refund => |in| std.log.info("→ refund {d}¢", .{in.amount_cents}),
                .mcp => |m| std.log.info("→ mcp {s}.{s}", .{ m.server, m.tool }),
            },
            .tool_result => |r| std.log.info("← {s} ({d}ms)", .{ r.name(), r.elapsed_ms }),

            // IssueRefund.needsApproval returned true. The run is paused; the
            // pending call is typed, so you see `amount_cents` as a u32.
            // `req.call` only has variants for approval-gated tools (comptime-
            // known), so this switch is exhaustive with no `else`.
            .approval_request => |req| switch (req.call) {
                .issue_refund => |in| {
                    const ok = try askOperator(io, "Approve {d}¢ refund on {s}?", .{ in.amount_cents, in.order_id });
                    try stream.respond(req.id, if (ok) .approve else .{ .deny = "Over limit; escalate." });
                },
            },

            .step_finish => |s| std.log.debug("step {d}: {t}", .{ s.index, s.reason }),
            .finish => |f| std.log.info("\ndone: {t}, {d} steps", .{ f.reason, f.steps }),
        };
    }

    // ── 3. Workflow: start, suspend, persist, resume (possibly days later) ───
    {
        var arena: std.heap.ArenaAllocator = .init(gpa);
        defer arena.deinit();
        const wf = rt.workflow(app.HandleTicket);

        const result = try wf.start(arena.allocator(), .{
            .customer_id = "customer-42",
            .subject = "Broken blender",
            .body = "ORD-1042 arrived cracked, I'd like my money back.",
        }, .{});

        switch (result) {
            .completed => |out| std.log.info("sent={}", .{out.sent}),

            // `Suspended` is the comptime-derived union of every suspendable
            // step in the graph. Exhaustive: add a new one, this stops compiling.
            .suspended => |s| switch (s.at) {
                .approve_refund => |p| {
                    // The snapshot is already in storage. You can exit the
                    // process; `s.run_id` is all you need to come back.
                    std.log.info("needs approval: {d}¢ on {s} (run {s})", .{ p.amount_cents, p.order_id, s.run_id });

                    // ...later, e.g. from an HTTP handler or a CLI command:
                    const resumed = try wf.resumeStep(app.ApproveRefund, arena.allocator(), s.run_id, .{
                        .approved = true,
                        .approver = "ryan",
                    });
                    std.debug.assert(resumed == .completed);
                },
            },

            .failed => |f| std.log.err("step {s} failed: {t}", .{ f.step, f.err }),
        }
    }

    // ── 4. Escape hatch: raw model call, no agent ────────────────────────────
    // Same provider layer, for when you just want a completion. The model
    // string is comptime, so only the providers you name are compiled in.
    {
        var arena: std.heap.ArenaAllocator = .init(gpa);
        defer arena.deinit();
        const haiku = try rt.model("anthropic/claude-haiku-4-5")
            .generate(arena.allocator(), &.{.user("Say hi in five words.")}, .{ .max_tokens = 32 });
        std.debug.print("{s}\n", .{haiku.text});
    }
}

fn stdoutWrite(io: std.Io, bytes: []const u8) !void {
    try std.Io.File.stdout().writeStreamingAll(io, bytes);
}

fn askOperator(io: std.Io, comptime fmt: []const u8, args: anytype) !bool {
    _ = io;
    std.debug.print(fmt ++ " [y/N] ", args);
    return false; // stdin prompt elided
}
