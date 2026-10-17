//! app.zig: everything an app *declares*.
//!
//! Rule of thumb for this API: declarations are comptime, execution is runtime.
//! Nothing in this file allocates or does I/O. Tools, agents and workflows are
//! *types*; their JSON Schemas, prompts, tool tables and step graphs are built
//! and checked by the compiler and baked into the binary.
//!
//! Working name for the library: `zastra`. (Hypothetical API, Zig 0.16 idioms.)

const std = @import("std");
const z = @import("zastra");

// ─────────────────────────────────────────────────────────────────────────────
// 1. Context: your dependencies, injected (typed) into every tool and step.
//    Mastra's untyped `requestContext` becomes a compile-time-checked struct.
// ─────────────────────────────────────────────────────────────────────────────

pub const Ctx = struct {
    db: *OrderDb,
    /// Refunds at or below this are auto-approved; above it, a human decides.
    auto_refund_limit_cents: u32 = 50_00,
};

// ─────────────────────────────────────────────────────────────────────────────
// 2. Domain types. These ARE the schemas: no Zod, no separate schema DSL.
//    zastra walks @typeInfo at comptime and emits JSON Schema:
//      []const u8 → string, enum → string+enum, ?T → optional, struct → object,
//      []const T → array, union(enum) → oneOf with a "type" discriminator.
//    Zig has no field annotations, so docs/constraints live in decls.
// ─────────────────────────────────────────────────────────────────────────────

pub const Order = struct {
    id: []const u8,
    status: enum { pending, shipped, delivered, cancelled },
    total_cents: u32,
    items: []const Item,

    pub const Item = struct { sku: []const u8, qty: u16 };
};

pub const Ticket = struct {
    customer_id: []const u8,
    subject: []const u8,
    body: []const u8,
};

pub const Triage = struct {
    category: enum { refund, shipping, product_question, other },
    urgency: u8,
    order_id: ?[]const u8 = null,
    summary: []const u8,

    pub const docs = .{
        .urgency = "1 = can wait a week, 5 = customer is blocked right now",
        .order_id = "Order ID if the customer mentioned one, e.g. ORD-1042",
        .summary = "One sentence, no customer PII",
    };
    // `summary` also streams as it grows in `.output_partial` events.
    pub const stream_strings = .{.summary};
    // Emitted into the schema AND enforced when parsing the model's output.
    // A violation is fed back to the model for one repair attempt.
    pub const constraints = .{
        .urgency = .{ .min = 1, .max = 5 },
        .summary = .{ .max_len = 200 },
    };
};

pub const Resolution = struct {
    kind: enum { refunded, answered, escalated },
    message: []const u8,
};

// ─────────────────────────────────────────────────────────────────────────────
// 3. Tools: a tool is any type with `description`, `Input`, `Output`, `execute`.
//    The tool name defaults to snake_case(@typeName) → "lookup_order".
// ─────────────────────────────────────────────────────────────────────────────

pub const LookupOrder = struct {
    pub const description = "Look up an order by its ID.";

    pub const Input = struct {
        order_id: []const u8,
        pub const docs = .{ .order_id = "Order ID, e.g. ORD-1042" };
    };
    pub const Output = Order;

    /// Errors in `ModelErrors` are *recoverable*: they go back to the model as
    /// a tool error so it can retry or ask the user. Any other error aborts the
    /// run and surfaces to your code. That split is visible in the type.
    pub const ModelErrors = error{OrderNotFound};
    pub const error_messages = .{ .OrderNotFound = "No order exists with that ID." };

    pub fn execute(t: *z.ToolCtx(Ctx), in: Input) !Output {
        // t.ctx: *Ctx   t.arena: run-scoped allocator   t.io: std.Io
        return try t.ctx.db.findOrder(t.arena, in.order_id) orelse error.OrderNotFound;
    }
};

pub const IssueRefund = struct {
    pub const description = "Refund all or part of an order.";

    pub const Input = struct {
        order_id: []const u8,
        amount_cents: u32,
        reason: enum { damaged, late, wrong_item, other },
        pub const docs = .{ .amount_cents = "Must not exceed the order total" };
    };
    pub const Output = struct { refund_id: []const u8 };
    /// What the tool can do (§5.12). Agents must `.allow` these, and
    /// `z.testing.fuzzTool` refuses to fuzz it unless the test opts in.
    pub const effects = .{ .reads, .writes, .spends_money };

    /// Presence of this decl makes the tool approval-gated. Return false to
    /// auto-run. (Or `pub const needs_approval = true;` to always ask.)
    /// When it returns true, the agent run pauses and your stream receives an
    /// `.approval_request` event carrying the typed Input.
    pub fn needsApproval(t: *z.ToolCtx(Ctx), in: Input) bool {
        return in.amount_cents > t.ctx.auto_refund_limit_cents;
    }

    pub fn execute(t: *z.ToolCtx(Ctx), in: Input) !Output {
        const id = try t.ctx.db.refund(t.arena, in.order_id, in.amount_cents);
        return .{ .refund_id = id };
    }
};

// ─────────────────────────────────────────────────────────────────────────────
// 4. Agents: `z.Agent(Ctx, config)` returns a type. Everything in the config
//    is comptime, so mistakes are compile errors, not 2am runtime surprises:
//
//      .model = "antropic/claude-sonnet-4-6"
//        → error: unknown provider 'antropic' (did you mean 'anthropic'?)
//      .tools = .{ LookupOrder, NotATool }
//        → error: NotATool is not a tool: missing `pub const Input`
// ─────────────────────────────────────────────────────────────────────────────

/// Typed working memory. zastra gives the agent an `update_working_memory` tool
/// whose schema is derived from this struct, injects the current value into
/// the system prompt, and persists it per resource (customer).
pub const CustomerNotes = struct {
    name: ?[]const u8 = null,
    preferred_contact: ?Contact = null,
    open_issues: []const []const u8 = &.{},

    pub const Contact = enum { email, sms };

    /// Notes saved before `preferred_contact` became an enum are converted
    /// when they're loaded, instead of resetting to the defaults. List one
    /// `z.migrate(OldShape, f)` per earlier version, oldest first.
    pub const migrations = .{z.migrate(CustomerNotesV1, fromV1)};

    fn fromV1(_: std.mem.Allocator, old: CustomerNotesV1) !CustomerNotes {
        const contact: ?Contact = if (old.contact) |c| std.meta.stringToEnum(Contact, c) else null;
        return .{ .name = old.name, .preferred_contact = contact, .open_issues = old.open_issues };
    }
};

/// The first version of CustomerNotes, kept for its migration.
const CustomerNotesV1 = struct {
    name: ?[]const u8 = null,
    contact: ?[]const u8 = null,
    open_issues: []const []const u8 = &.{},
};

pub const Support = z.Agent(Ctx, .{
    .name = "support", // agents are returned by a function, so they need a name
    .model = "anthropic/claude-sonnet-4-6",
    .instructions = @embedFile("prompts/support.md"), // prompts ship in the binary
    // Reasoning is checked against the model at compile time: `.off` on a model
    // that can't stop thinking, or `.on` on one that needs `.{ .budget = N }`,
    // is a compile error. `.show_reasoning` adds `.reasoning_delta` events.
    .reasoning = .on,
    .show_reasoning = true,
    .tools = .{ LookupOrder, IssueRefund, z.mcp.tools(.docs, .{ .allow = &.{"search_docs"} }), z.mcp.tools(.status, .{}) },
    .memory = .{
        .history = .{ .last_messages = 30 },
        .working = CustomerNotes,
    },
    .max_steps = 8,
});

/// An agent with a fixed `.output` type: generate() returns a `Triage`, not text.
/// The schema goes to the provider's native structured-output mode when it has
/// one, and falls back to a forced tool call when it doesn't.
pub const TriageAgent = z.Agent(Ctx, .{
    .name = "triage",
    .model = "openai/gpt-5-mini", // catalog OpenAI models use the Responses API
    .instructions = "Classify the support ticket. Be conservative with urgency.",
    .output = Triage,
    // `.output_partial` events while streaming: the Triage so far, field by
    // field (a `z.Partial(Triage)`). Without this, the parser isn't compiled in.
    .partial_output = true,
});

/// Handles the refund branch of the workflow. IssueRefund is approval-gated,
/// so when it needs a human the whole workflow pauses (see `Refund` below).
pub const Refunder = z.Agent(Ctx, .{
    .name = "refunder",
    .model = "anthropic/claude-sonnet-4-6",
    .instructions = @embedFile("prompts/refund.md"),
    .tools = .{ LookupOrder, IssueRefund },
    .output = Resolution,
});

/// A reply-only agent for use inside workflows.
pub const ReplyWriter = z.Agent(Ctx, .{
    .name = "reply_writer",
    .model = "anthropic/claude-sonnet-4-6",
    .instructions = @embedFile("prompts/reply.md"),
    .tools = .{LookupOrder},
});

/// Reviews a draft reply before it goes out.
pub const ReplyCritic = z.Agent(Ctx, .{
    .name = "reply_critic",
    .model = "anthropic/claude-sonnet-4-6",
    .instructions = "Review a customer support reply. Approve it if it answers the question politely and accurately; otherwise say what to fix.",
    .output = Review,
});

pub const Review = struct { approved: bool, feedback: []const u8 };

// ─────────────────────────────────────────────────────────────────────────────
// 5. Workflow steps: a step is a type with `Input`, `Output`, `run`.
//    Optional decls unlock features:
//      `needs`              typed access to earlier results (checked at commit)
//      `Suspend`, `Resume`  human-in-the-loop pause/resume
//      `retry`              per-step retry policy
// ─────────────────────────────────────────────────────────────────────────────

/// An agent as a step. The prompt template is checked against `Ticket` at
/// comptime: a typo like "{subjet}" is a compile error.
const Classify = z.step.agent(TriageAgent, .{
    .input = Ticket,
    .prompt = "Subject: {subject}\n\n{body}",
});

const FetchOrder = struct {
    pub const Input = Triage;
    pub const Output = ?Order;
    pub const retry = z.Retry{ .attempts = 3, .backoff = .{ .exponential = 200 } };

    pub fn run(w: *z.StepCtx(Ctx, @This()), in: Input) !Output {
        const id = in.order_id orelse return null;
        return try w.ctx.db.findOrder(w.arena, id);
    }
};

/// An agent with approval-gated tools as a step (PLAN.md D34). When
/// IssueRefund needs a human, the workflow suspends with the typed requests
/// (`Suspend = z.Approvals(Refunder)`) and resumes with the decisions
/// (`Resume = z.Decisions(Refunder)`). There's no resume branch to write: on
/// resume the step replays and picks the saved agent run back up, so the
/// refund tool runs once, after approval.
pub const Refund = z.step.agent(Refunder, .{
    .input = Triage,
    .prompt = "Refund request: {summary}\nOrder: {order_id}",
});

const SearchFaq = struct {
    pub const Input = Triage;
    pub const Output = []const FaqHit;
    pub const FaqHit = struct { question: []const u8, answer: []const u8 };

    const faq = @embedFile("data/faq.json"); // ships in the binary

    pub fn run(w: *z.StepCtx(Ctx, @This()), in: Input) !Output {
        // Plain user code: steps don't have to involve a model at all.
        return @import("faq_search.zig").search(FaqHit, w.arena, faq, in.summary, 3);
    }
};

/// Parallel fan-out as a named step type. Output is a struct whose fields
/// match the keys: `struct { order: ?Order, faq: []const FaqHit }`.
/// Every branch must accept the same Input, or it fails to compile.
const Gather = z.step.parallel(.{ .order = FetchOrder, .faq = SearchFaq });

/// A reply in progress: the loop below revises it until the critic approves.
const Draft = struct { message: []const u8, approved: bool = false, rounds: u8 = 0 };

const DraftReply = struct {
    pub const Input = Gather.Output;
    pub const Output = Draft;
    // Typed access to Classify's output. Classify lives in the enclosing
    // HandleTicket workflow, not in AnswerPath, so AnswerPath commits as an
    // *open* workflow: it can be embedded, but not run or registered on its
    // own. HandleTicket's `.commit()` resolves the reference (PLAN.md D13).
    pub const needs = .{ .ticket = Classify };

    pub fn run(w: *z.StepCtx(Ctx, @This()), in: Input) !Output {
        // Agents can be called inside steps; tracing and the run's memory
        // thread carry through automatically.
        const reply = try w.agent(ReplyWriter).generate(
            try w.fmt("Ticket summary: {s}\nRelevant FAQ: {f}\nOrder: {f}", .{
                w.needs.ticket.summary, z.fmt.json(in.faq), z.fmt.json(in.order),
            }),
            .{},
        );
        return .{ .message = reply.text };
    }
};

/// One round of review: the critic approves the draft, or the writer revises
/// it with the critic's feedback. Input and Output are the same type, so it
/// can be a loop body.
const ReviseReply = struct {
    pub const Input = Draft;
    pub const Output = Draft;

    pub fn run(w: *z.StepCtx(Ctx, @This()), in: Input) !Output {
        const review = try w.agent(ReplyCritic).generate(in.message, .{});
        if (review.output.approved) return .{ .message = in.message, .approved = true, .rounds = in.rounds + 1 };
        // The writer's thread for this step spans the loop's iterations, so
        // it sees its earlier drafts.
        const revised = try w.agent(ReplyWriter).generate(
            try w.fmt("Revise your reply. Feedback: {s}", .{review.output.feedback}),
            .{},
        );
        return .{ .message = revised.text, .rounds = in.rounds + 1 };
    }
};

fn approved(d: Draft) bool {
    return d.approved;
}

/// A loop: run ReviseReply until `approved`, at most 3 times. The bound is
/// required; `.on_limit = .finish` sends the last draft instead of failing.
/// Each iteration is saved, so a restart picks up at the current round.
const Polish = z.step.loop(ReviseReply, .{ .until = approved, .max = 3, .on_limit = .finish });

const Answer = struct {
    pub const Input = Draft;
    pub const Output = Resolution;
    pub fn run(_: *z.StepCtx(Ctx, @This()), in: Input) !Output {
        return .{ .kind = .answered, .message = in.message };
    }
};

const NotifyCustomer = struct {
    pub const Input = Resolution;
    pub const Output = struct { sent: bool };
    pub const needs = .{ .ticket = z.initial(Ticket) };

    pub fn run(w: *z.StepCtx(Ctx, @This()), in: Input) !Output {
        std.log.info("notify {s}: {s}", .{ w.needs.ticket.customer_id, in.message });
        return .{ .sent = true };
    }
};

fn wantsRefund(t: Triage) bool {
    return t.category == .refund;
}

// ─────────────────────────────────────────────────────────────────────────────
// 6. Workflows: a comptime builder over types. Each `.then` checks that the
//    previous Output == the next Input. Workflows are steps, so they compose.
//
//      .then(NotifyCustomer)  after a step whose Output is Triage
//        → error: step 'notify_customer' expects Resolution, got Triage
//      .branch arms with different Outputs
//        → error: branch arms must agree on Output: Resolution vs ?Order
// ─────────────────────────────────────────────────────────────────────────────

const RefundPath = z.Workflow(Ctx, "refund", Triage)
    .then(Refund)
    .commit();

const AnswerPath = z.Workflow(Ctx, "answer", Triage)
    .then(Gather)
    .then(DraftReply)
    .then(Polish)
    .then(Answer)
    .commit();

pub const HandleTicket = z.Workflow(Ctx, "handle_ticket", Ticket)
    .then(Classify) //                          Ticket     → Triage
    .branch(.{ //                               Triage     → Resolution
        .{ wantsRefund, RefundPath },
        .{ z.otherwise, AnswerPath },
    })
    .then(NotifyCustomer) //                    Resolution → { sent }
    .commit();

// Because the whole graph is known at comptime, zastra derives:
//   HandleTicket.Suspended = union(enum) { refunder: z.Approvals(Refunder) }
// so handling a paused run is an exhaustive `switch`. Add a new suspendable
// step and every call site that doesn't handle it stops compiling.

// ─────────────────────────────────────────────────────────────────────────────
// 7. The App: the single registry. From this one type zastra derives the runtime,
//    the dev CLI, the C ABI, and the set of API keys required at startup.
// ─────────────────────────────────────────────────────────────────────────────

pub const App = z.App(.{
    .ctx = Ctx,
    .agents = .{ Support, TriageAgent, Refunder, ReplyWriter, ReplyCritic },
    .workflows = .{HandleTicket},
    // Comptime choice so unused backends are never compiled in.
    .storage = .sqlite, // .sqlite | .memory
    .mcp = .{
        .docs = z.mcp.stdio(&.{ "docs-mcp-server", "--stdio" }),
        // Streamable HTTP, protocol 2026-07-28. `url_env` overrides the URL
        // per deploy; `optional` starts the App without its tools if it's down.
        .status = z.mcp.http("http://127.0.0.1:8931/mcp", .{ .url_env = "STATUS_MCP_URL", .optional = true }),
    },
});

// ─────────────────────────────────────────────────────────────────────────────
// Tests: scripted models are typed against your tools, so a test that scripts
// a call with the wrong arguments fails to compile.
// ─────────────────────────────────────────────────────────────────────────────

test "large refunds pause for approval and resume after a restart" {
    var db = OrderDb.fake(&.{.{ .id = "ORD-1", .status = .delivered, .total_cents = 90_00, .items = &.{} }});
    var ctx: Ctx = .{ .db = &db };
    const path = "zastra-example-restart.sqlite";
    inline for (.{ "", "-wal", "-shm" }) |sfx| std.Io.Dir.cwd().deleteFile(std.testing.io, path ++ sfx) catch {};
    defer inline for (.{ "", "-wal", "-shm" }) |sfx| std.Io.Dir.cwd().deleteFile(std.testing.io, path ++ sfx) catch {};

    var run_id_buf: [64]u8 = undefined;
    var req_id_buf: [64]u8 = undefined;
    var run_id: []const u8 = "";
    var req_id: []const u8 = "";
    {
        var h = try z.testing.harness(App, .{ .ctx = &ctx, .storage_path = path });
        defer h.deinit();
        h.script(TriageAgent, &.{
            .output(Triage{ .category = .refund, .urgency = 3, .order_id = "ORD-1", .summary = "Broken item" }),
        });
        h.script(Refunder, &.{
            .tool(LookupOrder, .{ .order_id = "ORD-1" }),
            .tool(IssueRefund, .{ .order_id = "ORD-1", .amount_cents = 90_00, .reason = .damaged }),
        });
        const ticket: Ticket = .{ .customer_id = "c-42", .subject = "Broken", .body = "Arrived cracked. ORD-1" };
        const paused = try z.testing.expectSuspended(try h.workflow(HandleTicket).start(ticket), .refunder);
        // The pending call is typed: `.issue_refund` carries IssueRefund.Input.
        switch (paused.payload.requests[0].call) {
            .issue_refund => |in| try std.testing.expectEqual(90_00, in.amount_cents),
        }
        try std.testing.expectEqual(0, db.refundCount());
        run_id = try std.fmt.bufPrint(&run_id_buf, "{s}", .{paused.run_id});
        req_id = try std.fmt.bufPrint(&req_id_buf, "{s}", .{paused.payload.requests[0].id});
    }

    // A new process with the same database picks the run up.
    var h = try z.testing.harness(App, .{ .ctx = &ctx, .storage_path = path });
    defer h.deinit();
    h.script(Refunder, &.{.output(Resolution{ .kind = .refunded, .message = "Your refund is on its way." })});
    const done = try h.workflow(HandleTicket).resumeStep(z.step.agentOf(Refunder), run_id, .{ .approve = &.{req_id} });
    try std.testing.expect(done.completed.sent);
    try std.testing.expectEqual(1, db.refundCount());
}

test "schema types round-trip, and lookup survives arbitrary input" {
    // 500 random values each: written as JSON, parsed back, compared, and
    // validated against the schema the model sees.
    try z.testing.expectRoundTrip(Triage, .{});
    try z.testing.expectRoundTrip(IssueRefund.Input, .{});

    var db = OrderDb.fake(&.{});
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    var prng: std.Random.DefaultPrng = .init(1);
    for (0..100) |_| {
        const in = try z.testing.arbitrary(LookupOrder.Input, arena.allocator(), prng.random());
        _ = try db.findOrder(arena.allocator(), in.order_id);
    }
}

test "tools survive arbitrary and hostile arguments" {
    // Each iteration takes a model tool call's path: arguments JSON, parse,
    // execute, output. Valid inputs must not crash, leak or produce output
    // that breaks the schema; mutated arguments must be rejected with a
    // message before execute sees them. A failure prints its seed.
    var db = try OrderDb.open(std.testing.allocator, std.testing.io, "");
    defer db.close();
    var ctx: Ctx = .{ .db = &db };
    try z.testing.fuzzTool(App, LookupOrder, .{ .ctx = &ctx, .iterations = 300, .mapped_errors_only = true });
    // Refunds write and spend money: without `.allow_effects` this is a
    // compile error.
    try z.testing.fuzzTool(App, IssueRefund, .{ .ctx = &ctx, .iterations = 300, .allow_effects = .{ .writes, .spends_money } });
}

test "rt.model's escape hatch can be scripted too" {
    var db = OrderDb.fake(&.{});
    var ctx: Ctx = .{ .db = &db };
    var h = try z.testing.harness(App, .{ .ctx = &ctx });
    defer h.deinit();
    h.scriptModel("anthropic/claude-haiku-4-5", &.{.text("Hi there, nice to meet.")});
    const r = try h.model("anthropic/claude-haiku-4-5").generate(&.{.user("Say hi in five words.")}, .{ .max_tokens = 32 });
    try std.testing.expectEqualStrings("Hi there, nice to meet.", r.text);
}

test "the HTTP status server's tools show up when it's running" {
    var db = OrderDb.fake(&.{});
    var ctx: Ctx = .{ .db = &db };

    // Start the 2026-07-28 Streamable HTTP server on a free port.
    const io = std.testing.io;
    var child = try std.process.spawn(io, .{ .argv = &.{ "zig-out/bin/status-mcp-server", "0" }, .stdout = .pipe });
    defer child.kill(io);
    var buf: [256]u8 = undefined;
    var out = child.stdout.?.readerStreaming(io, &buf);
    const url = (try out.interface.takeDelimiter('\n')).?;
    var env: std.process.Environ.Map = .init(std.testing.allocator);
    defer env.deinit();
    try env.put("STATUS_MCP_URL", url);

    var h = try z.testing.harness(App, .{ .ctx = &ctx, .env = &env });
    defer h.deinit();
    h.script(Support, &.{
        .tools(&.{.{ .mcp = .{ .server = "status", .tool = "service_status", .args_json = "{\"service\":\"shipping\"}" } }}),
        .text("Shipping is running 1-2 days late in the EU."),
    });
    const r = try h.agent(Support).generate("Where's my parcel?", .{ .include_messages = true });
    const result = r.completed.messages[2].content.blocks[0].tool_result;
    try std.testing.expectEqualStrings("shipping: degraded: carrier delays in the EU, 1-2 extra days", result.content);
}

const OrderDb = @import("order_db.zig").OrderDb;
