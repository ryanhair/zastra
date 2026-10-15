//! app.zig: everything an app *declares*.
//!
//! Rule of thumb for this API: declarations are comptime, execution is runtime.
//! Nothing in this file allocates or does I/O. Tools, agents and workflows are
//! *types*; their JSON Schemas, prompts, tool tables and step graphs are built
//! and checked by the compiler and baked into the binary.
//!
//! This is `sketch/src/app.zig`, made real.

const std = @import("std");
const z = @import("zastra");
const notify = @import("notify"); // a reusable tool package (PLAN.md §5.13)

// ─────────────────────────────────────────────────────────────────────────────
// 1. Context: your dependencies, injected (typed) into every tool and step.
//    Mastra's untyped `requestContext` becomes a compile-time-checked struct.
// ─────────────────────────────────────────────────────────────────────────────

pub const Ctx = struct {
    db: *OrderDb,
    /// Required by `notify.SendEmail` (checked at comptime).
    mailer: *notify.Mailer,
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
    preferred_contact: ?enum { email, sms } = null,
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
    .tools = .{ LookupOrder, IssueRefund, notify.SendEmail, z.mcp.tools(.docs, .{ .allow = &.{"search_docs"} }) },
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
});

/// A reply-only agent for use inside workflows. It has no approval-gated tools:
/// an agent in a workflow step can't pause for approval in v1, so using
/// `Support` (which has IssueRefund) there would be a compile error. Approvals
/// in workflows are modeled as `Suspend`/`Resume` steps (see ApproveRefund).
pub const ReplyWriter = z.Agent(Ctx, .{
    .name = "reply_writer",
    .model = "anthropic/claude-sonnet-4-6",
    .instructions = @embedFile("prompts/reply.md"),
    .tools = .{LookupOrder},
});

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

pub const ApproveRefund = struct {
    pub const Input = ?Order;
    pub const Output = Resolution;

    /// What the workflow persists and hands back to you when it pauses...
    pub const Suspend = struct { order_id: []const u8, amount_cents: u32 };
    /// ...and what you must provide to resume it. Both are typed end to end.
    pub const Resume = struct { approved: bool, approver: []const u8 };

    /// Declared dependencies on earlier data. `z.initial(T)` is the workflow
    /// input (its type is checked at `.commit()`). Naming a step that doesn't
    /// run before this one in every path is a compile error.
    pub const needs = .{ .triage = z.initial(Triage) };

    pub fn run(w: *z.StepCtx(Ctx, @This()), in: Input) !z.Suspendable(@This()) {
        const order = in orelse return .{ .done = .{
            .kind = .escalated,
            .message = "Couldn't find the order; routing to a human.",
        } };

        if (order.total_cents > w.ctx.auto_refund_limit_cents) {
            // w.resumed: ?Resume. Null on first run, set after resume.
            const decision = w.resumed orelse return .{ .suspended = .{
                .order_id = order.id,
                .amount_cents = order.total_cents,
            } };
            if (!decision.approved) return .{ .done = .{
                .kind = .escalated,
                .message = try w.fmt("Refund declined by {s}.", .{decision.approver}),
            } };
        }

        // Steps run at least once: a crash or a resume re-runs this function
        // from the top. Make side effects idempotent, e.g. keyed on the run.
        _ = try w.ctx.db.refundOnce(w.arena, w.run_id, order.id, order.total_cents);
        return .{ .done = .{ .kind = .refunded, .message = "Your refund is on its way." } };
    }
};

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

const DraftReply = struct {
    pub const Input = Gather.Output;
    pub const Output = Resolution;
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
        return .{ .kind = .answered, .message = reply.text };
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
    .then(FetchOrder)
    .then(ApproveRefund)
    .commit();

const AnswerPath = z.Workflow(Ctx, "answer", Triage)
    .then(Gather)
    .then(DraftReply)
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
//   HandleTicket.Suspended = union(enum) { approve_refund: ApproveRefund.Suspend }
// so handling a paused run is an exhaustive `switch`. Add a new suspendable
// step and every call site that doesn't handle it stops compiling.

// ─────────────────────────────────────────────────────────────────────────────
// 7. The App: the single registry. From this one type zastra derives the runtime,
//    the dev CLI, the C ABI, and the set of API keys required at startup.
// ─────────────────────────────────────────────────────────────────────────────

pub const App = z.App(.{
    .ctx = Ctx,
    .agents = .{ Support, TriageAgent, ReplyWriter },
    .workflows = .{HandleTicket},
    // Comptime choice so unused backends are never compiled in.
    .storage = .sqlite, // .sqlite | .memory
    .mcp = .{
        // Built by this example's build.zig; run the app from examples/support.
        .docs = z.mcp.stdio(&.{"zig-out/bin/docs-mcp-server"}),
    },
});

// ─────────────────────────────────────────────────────────────────────────────
// Tests: scripted models are typed against your tools, so a test that scripts
// a call with the wrong arguments fails to compile.
// ─────────────────────────────────────────────────────────────────────────────

/// Used by the dev CLI (`zig build dev`) and the C library to build a context.
pub fn createContext(gpa: std.mem.Allocator, io: std.Io) !*Ctx {
    const db = try gpa.create(OrderDb);
    db.* = try OrderDb.open(gpa, io, "orders.sqlite");
    const mailer = try gpa.create(notify.Mailer);
    mailer.* = .{};
    const ctx = try gpa.create(Ctx);
    ctx.* = .{ .db = db, .mailer = mailer };
    return ctx;
}

pub fn destroyContext(gpa: std.mem.Allocator, ctx: *Ctx) void {
    ctx.db.close();
    gpa.destroy(ctx.db);
    gpa.destroy(ctx.mailer);
    gpa.destroy(ctx);
}

test "large refunds pause for approval and resume" {
    var db = OrderDb.fake(&.{.{ .id = "ORD-1", .status = .delivered, .total_cents = 90_00, .items = &.{} }});
    defer db.close();
    var mailer: notify.Mailer = .{};
    var ctx: Ctx = .{ .db = &db, .mailer = &mailer };

    var h = try z.testing.harness(App, .{ .ctx = &ctx });
    defer h.deinit();

    h.script(TriageAgent, &.{
        .output(Triage{ .category = .refund, .urgency = 3, .order_id = "ORD-1", .summary = "Broken item" }),
    });

    const ticket: Ticket = .{ .customer_id = "c-42", .subject = "Broken", .body = "Arrived cracked. ORD-1" };
    const first = try h.workflow(HandleTicket).start(ticket);
    const paused = try z.testing.expectSuspended(first, .approve_refund);
    try std.testing.expectEqual(90_00, paused.payload.amount_cents);

    const done = try h.workflow(HandleTicket).resumeStep(ApproveRefund, paused.run_id, .{
        .approved = true,
        .approver = "ryan",
    });
    try std.testing.expect(done.completed.sent);
    try std.testing.expectEqual(1, db.refundCount());
}

pub const OrderDb = @import("order_db.zig").OrderDb;
