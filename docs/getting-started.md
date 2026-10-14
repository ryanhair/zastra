# Getting started with zastra

This guide builds a small support agent, step by step. [`examples/support`](../examples/support) is the finished version of it.

## 1. Add the dependency

```sh
zig fetch --save git+https://github.com/<you>/zastra
```

In `build.zig`:

```zig
const z = @import("zastra");

const zastra_dep = b.dependency("zastra", .{ .target = target, .optimize = optimize });
const app_mod = b.createModule(.{
    .root_source_file = b.path("src/app.zig"),
    .target = target,
    .optimize = optimize,
    .imports = &.{.{ .name = "zastra", .module = zastra_dep.module("zastra") }},
});
```

There are no feature flags. Code for a provider, storage backend or MCP is compiled in only if your App uses it.

## 2. Declare a context, a type and a tool

Declarations are comptime; nothing in them allocates or does I/O. Your `Ctx` is injected, fully typed, into every tool and step.

```zig
const std = @import("std");
const z = @import("zastra");

pub const Ctx = struct { db: *OrderDb };

pub const Order = struct {
    id: []const u8,
    status: enum { pending, shipped, delivered },
    total_cents: u32,
};

pub const LookupOrder = struct {
    pub const description = "Look up an order by its ID.";
    pub const Input = struct {
        order_id: []const u8,
        pub const docs = .{ .order_id = "Order ID, e.g. ORD-1042" };
    };
    pub const Output = Order;

    // Errors in ModelErrors go back to the model; anything else aborts the run.
    pub const ModelErrors = error{OrderNotFound};
    pub const error_messages = .{ .OrderNotFound = "No order exists with that ID." };

    pub fn execute(t: *z.ToolCtx(Ctx), in: Input) !Output {
        return try t.ctx.db.find(t.arena, in.order_id) orelse error.OrderNotFound;
    }
};
```

The plain Zig types are the schema. `[]const u8` maps to string, an enum to a string with `enum`, `?T` to an optional field, a struct to an object, and `union(enum)` to `oneOf` with a `"type"` field. Add descriptions with `docs`. Add bounds with `constraints` (`min`, `max`, `min_len`, `max_len`, `min_items`, `max_items`, `one_of`, `pattern`); they go into the schema and are enforced when the model's JSON is parsed.

## 3. Declare an agent and the App

```zig
pub const Support = z.Agent(Ctx, .{
    .name = "support",
    .model = "anthropic/claude-sonnet-5-5",
    .instructions = "You are Acme's support agent. Look up orders before discussing them.",
    .tools = .{LookupOrder},
    .memory = .{ .history = .{ .last_messages = 30 } },
});

pub const App = z.App(.{
    .ctx = Ctx,
    .agents = .{Support},
    .storage = .sqlite, // or .memory
});
```

`.name` is required: zastra can't see the name of the declaration that holds a type returned by a function. Model strings are checked against the catalog at compile time. For a model the catalog doesn't know, use `z.custom(.{ .provider = .openai_compat, .id = "...", .base_url = "...", .api_key_env = "...", .supports = .{ ... } })`.

## 4. Run it

```zig
pub fn main(init: std.process.Init) !void {
    var db = OrderDb.init();
    var ctx: Ctx = .{ .db = &db };
    var rt = App.init(init.gpa, init.io, .{ .ctx = &ctx, .env = init.environ_map }) catch |err| {
        std.log.err("{t}: {s}", .{ err, App.initDiagnostic() }); // e.g. a missing ANTHROPIC_API_KEY
        return err;
    };
    defer rt.deinit();

    var arena: std.heap.ArenaAllocator = .init(init.gpa);
    defer arena.deinit();
    const r = try rt.agent(Support).generate(arena.allocator(), "Where is ORD-1042?", .{ .thread = "t1" });
    std.debug.print("{s}\n(${d:.4})\n", .{ r.text, r.usage.cost_usd });
}
```

`App.init` checks, once, everything that can only be known at runtime: the API keys your models need, CA certificates, storage migrations and MCP servers. If a call fails, `rt.lastDiagnostic()` explains why, for example the provider's error body.

Results are allocated with the allocator you pass, usually an arena. Nothing outlives it.

## 5. Typed output, streaming and approvals

```zig
pub const Triage = struct {
    category: enum { refund, shipping, other },
    urgency: u8,
    pub const constraints = .{ .urgency = .{ .min = 1, .max = 5 } };
};
pub const TriageAgent = z.Agent(Ctx, .{ .name = "triage", .model = "openai/gpt-5-mini", .output = Triage });

const t = try rt.agent(TriageAgent).generate(arena, "My blender arrived smashed", .{});
// t.output is a Triage
```

To gate a tool behind human approval, declare `pub fn needsApproval(t: *z.ToolCtx(Ctx), in: Input) bool`, or `pub const needs_approval = true`. Tools whose `effects` include `.spends_money` or `.destructive` require approval by default. Then stream:

```zig
var s = try rt.agent(Support).stream(arena, "Refund ORD-1042", .{});
defer s.deinit();
while (try s.next()) |event| switch (event) {
    .text_delta => |d| print("{s}", .{d}),
    .approval_request => |req| switch (req.call) {
        .issue_refund => |in| try s.respond(req.id, if (in.amount_cents < 100_00) .approve else .{ .deny = "Too large" }),
    },
    else => {},
};
```

`generate` on an agent with approval-gated tools returns `error.ApprovalRequired`, unless you pass `.on_approval`.

## 6. Workflows

```zig
const Approve = struct {
    pub const Input = ?Order;
    pub const Output = Resolution;
    pub const Suspend = struct { order_id: []const u8, amount_cents: u32 };
    pub const Resume = struct { approved: bool };
    pub const needs = .{ .ticket = z.initial(Ticket) }; // the workflow input

    pub fn run(w: *z.StepCtx(Ctx, @This()), in: Input) !z.Suspendable(@This()) {
        const order = in orelse return .{ .done = .{ .kind = .escalated } };
        const decision = w.resumed orelse return .{ .suspended = .{ .order_id = order.id, .amount_cents = order.total_cents } };
        // ...
    }
};

pub const HandleTicket = z.Workflow(Ctx, "handle_ticket", Ticket)
    .then(z.step.agent(TriageAgent, .{ .input = Ticket, .prompt = "Subject: {subject}\n\n{body}" }))
    .branch(.{ .{ wantsRefund, RefundPath }, .{ z.otherwise, AnswerPath } })
    .then(NotifyCustomer)
    .commit();
```

`.commit()` checks type flow between steps, branch outputs and `needs` dominance. Prompt templates are checked against their input type. The workflow then gets a `Suspended` union, a `Result` union, a fingerprint and a Mermaid diagram. A run is snapshotted after every step:

```zig
const r = try rt.workflow(HandleTicket).start(arena, ticket, .{});
switch (r) {
    .completed => |out| ...,
    .suspended => |s| switch (s.at) { .approve => |p| ... }, // persist s.run_id
    .failed => |f| ...,
}
// later, even in another process:
_ = try rt.workflow(HandleTicket).resumeStep(Approve, arena, run_id, .{ .approved = true });
```

A step runs **at least once**: after a crash, or on resume, it is re-run from the top. Make side effects idempotent, for example keyed on `w.run_id`.

## 7. Test without a network

```zig
test "refund flow" {
    var h = try z.testing.harness(App, .{ .ctx = &ctx });
    defer h.deinit();
    h.script(TriageAgent, &.{ .output(.{ .category = .refund, .urgency = 3 }) });
    h.script(Support, &.{ .tool(LookupOrder, .{ .order_id = "ORD-1" }), .text("Found it.") });
    const r = try h.agent(Support).generate("Where's ORD-1?", .{});
}
```

Scripted turns are typed against your tools, so scripting a call with the wrong arguments fails to compile. They are rendered in the real provider wire format, which means the actual parsers and agent loop are exercised.

## 8. The dev CLI and the C library

```zig
const dev = z.addDev(b, .{ .app = app_mod, .zastra = zastra_dep });
if (b.args) |args| dev.run.addArgs(args);
b.step("dev", "zastra dev CLI").dependOn(&dev.run.step);

const lib = z.addCLib(b, .{ .name = "support", .app = app_mod, .zastra = zastra_dep });
```

`zig build dev -- agents | schema | prefix | chat | run | runs | resume | graph | trace | models`. Your app module must export `pub const App`. If your `Ctx` has fields without defaults, it must also export `pub fn createContext(gpa, io) !*Ctx`.

The C library takes and returns JSON, and streams are pulled (`zastra_stream_next`, `zastra_stream_respond`). See [`examples/support/embed.c`](../examples/support/embed.c).
