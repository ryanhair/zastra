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

`.name` is required: zastra can't see the name of the declaration that holds a type returned by a function. Model strings are checked against the catalog at compile time. For a model the catalog doesn't know, use `z.custom(.{ .provider = .openai_compat, .id = "...", .base_url = "...", .api_key_env = "...", .supports = .{ ... } })`. `.provider` is `.anthropic`, `.openai_responses` (OpenAI's Responses API) or `.openai_compat` (Chat Completions servers). Chat Completions servers differ in the name of the output limit: `.max_tokens_field` (`.openai_compat` only; a compile error elsewhere) is `.max_tokens` by default, and Chat Completions on api.openai.com needs `.max_completion_tokens` (it rejects `max_tokens` for current models).

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

To show the output while it's generated, add `.partial_output = true`. Streams then include `.output_partial` events, each carrying the whole value so far as a `z.Partial(Triage)` (every field optional):

```zig
var s = try rt.agent(TriageAgent).stream(arena, "My blender arrived smashed", .{});
defer s.deinit();
while (try s.next()) |event| switch (event) {
    .output_partial => |p| if (p.category) |c| print("category: {t}\n", .{c}),
    .output_partial_reset => {}, // a repair attempt starts over: discard what you showed
    else => {},
};
const triage = (try s.result()).output; // validated, as with generate
```

- A field appears once its value is complete. Arrays grow one complete element at a time.
- String fields listed in `pub const stream_strings = .{.summary};` on the output type also appear while they grow.
- Partial values aren't validated; the final `output` is.
- Each value lasts until the next call to `next()`.

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

Approvals don't have to be decided while the stream is open. `generate` on an agent with approval-gated tools returns a union: `.completed`, or `.suspended` once the run is saved to storage with its pending calls. Decide later, in any process with the same storage:

```zig
const r = try rt.agent(Support).generate(arena, "Refund ORD-1042", .{ .thread = "t1" });
switch (r) {
    .completed => |c| print("{s}", .{c.text}),
    .suspended => |s| for (s.requests) |req| switch (req.call) {
        .issue_refund => |in| try queueForReview(s.run_id, req.id, in),
    },
}

// Later:
const r2 = try rt.agent(Support).resumeRun(arena, run_id, &.{
    .{ .id = req_id, .decision = .approve }, // or .{ .deny = "over limit" }
});
```

Deciding only some requests keeps the run suspended with the rest. A live stream can save itself with `s.suspendRun()`, and `resumeStream` continues a run as a stream, showing its pending requests again first. Each run can be resumed once: a second resume gets `error.RunBusy` or `error.NotSuspended`, never a second refund. A run saved by a different version of the agent (changed prompt, model or tools) fails with `error.SnapshotIncompatible`; `cancelRun` abandons it. Pass `.on_approval` to decide inline instead of suspending. `zig build dev -- runs --suspended` lists waiting runs, and `zig build dev -- resume <run_id> approve` decides them.

### Reasoning

Models differ in whether they think by default, whether thinking can be turned off, and whether you can see it. zastra checks your choice against the model at compile time:

```zig
pub const Planner = z.Agent(Ctx, .{
    .name = "planner",
    .model = "anthropic/claude-sonnet-5-5",
    .reasoning = .on,        // .default (the model's own behaviour), .on, .off, or .{ .budget = N } on older models
    .show_reasoning = true,  // adds `.reasoning_delta` events with readable summaries
});
```

`.reasoning = .off` on a model that can't stop thinking, `.on` on one that needs a budget, or `.show_reasoning` where nothing readable comes back are all compile errors that name the fix. `zig build dev -- models` lists what each model your App uses supports. You pay for reasoning tokens whether or not they're shown.

On OpenAI models, reasoning is an effort level: `.reasoning = .on` uses your `.effort` (or `medium`), `.off` sends effort `none` on models that accept it, and `.show_reasoning` streams the summaries OpenAI writes of its reasoning. Some models (gpt-5.1 to gpt-5.4) don't reason unless asked; `.effort` or `.reasoning = .on` turns it on. Within a run, reasoning is passed back between tool steps so the model doesn't lose its train of thought.

### MCP servers

Declare servers on the App and hand their tools to agents:

```zig
pub const Support = z.Agent(Ctx, .{
    .name = "support",
    .model = "anthropic/claude-sonnet-5-5",
    .tools = .{ LookupOrder, z.mcp.tools(.docs, .{ .allow = &.{"search_docs"} }), z.mcp.tools(.linear, .{}) },
});

pub const App = z.App(.{
    .ctx = Ctx,
    .agents = .{Support},
    .mcp = .{
        .docs = z.mcp.stdio(&.{"docs-mcp-server"}),
        .linear = z.mcp.http("https://mcp.linear.app/mcp", .{
            .bearer_env = "LINEAR_MCP_TOKEN", // Authorization: Bearer <value>
            .headers = &.{.{ "X-Team", "acme" }},
            .url_env = "LINEAR_MCP_URL", // overrides the URL when set
            .optional = true, // start without these tools if the server is down
        }),
    },
});
```

zastra speaks MCP 2026-07-28 and falls back to `initialize`-based servers (2025-11-25 and earlier) on its own: on stdio it probes with `server/discover`; over HTTP it reads the first error response. The model sees tools as `<server>__<tool>`, sorted by name, and their arguments are validated against the server's schema before the call. When a server says its tools changed, or their `ttlMs` runs out, the new list applies from the next run; a running agent keeps its list. zastra declares no client capabilities (sampling, elicitation, roots): a server that asks for one gets a tool error the model can read. OAuth isn't supported yet; pass a token with `.bearer_env`.

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

An agent with approval-gated tools can be a step too. The workflow suspends when one of its calls needs a human, and resumes with the decisions:

```zig
const Refund = z.step.agent(Refunder, .{ .input = Triage, .prompt = "Refund request: {summary}" });
// ...
.suspended => |s| switch (s.at) {
    .refunder => |approvals| for (approvals.requests) |req| ..., // typed per tool
},
_ = try rt.workflow(HandleTicket).resumeStep(z.step.agentOf(Refunder), arena, run_id, .{ .approve = &.{req_id} });
```

The agent run is saved with the workflow run, so its tools run once, after approval. In a custom step, declare `pub const Suspend = z.Approvals(Refunder);` and `pub const Resume = z.Decisions(Refunder);` and call `w.agent(Refunder).run(...)`. There's no resume branch to write: on replay, finished calls return their saved results. Gated agents can't run inside `z.step.parallel`.

To repeat a step, wrap it in `z.step.loop`. The body's Input and Output must be the same type, because each iteration's output is the next one's input:

```zig
fn approved(d: Draft) bool {
    return d.approved;
}
const Polish = z.step.loop(ReviseReply, .{ .until = approved, .max = 3, .on_limit = .finish });
```

- The body runs at least once. `until` is checked after each iteration.
- `.max` is required. When the limit is reached, the run fails with `error.LoopLimit`, unless `.on_limit = .finish` returns the last value instead.
- Every iteration is saved, so a restart continues at the current iteration.
- A body can be a workflow, so a loop can contain suspendable steps and approval-gated agents.

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

### Random inputs

`z.testing.arbitrary(T, arena, source)` makes a random `T` that the model-facing parser accepts: integers and floats inside `min`/`max`, strings inside `min_len`/`max_len` or from `one_of`, slices inside `min_items`/`max_items`, every enum tag and union variant, optionals sometimes null. About a quarter of picks are boundaries: the bounds themselves, 0, empty and maximum-length strings and lists, quotes, backslashes, control characters and multi-byte UTF-8. `source` is a seeded `std.Random` or a `*std.testing.Smith`.

```zig
test "lookup survives odd order ids" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    var prng: std.Random.DefaultPrng = .init(1);
    for (0..200) |_| {
        const in = try z.testing.arbitrary(LookupOrder.Input, arena.allocator(), prng.random());
        _ = db.findOrder(arena.allocator(), in.order_id) catch {};
    }
}

test "schema types round-trip" {
    try z.testing.expectRoundTrip(Triage, .{}); // 500 values: write, parse back, compare, validate
}
```

Strings with a `pattern` get any characters within their length bounds (zastra doesn't enforce `pattern`). Unbounded strings are at most 64 characters and unbounded slices at most 8 items; `z.testing.Gen.init(arena, source, .{ .max_len, .max_items })` changes that. A type that needs values its schema can't describe declares `pub fn arbitrary(gen: *z.testing.Gen) !T` and builds them with `gen.int`, `gen.float`, `gen.string`, `gen.chance`, `gen.index` and `gen.value(Part)`.

## 8. Tracing

Every agent run, step, model call, tool call and workflow step is a span. Pass `.tracing` to `App.init`:

```zig
.tracing = z.trace.jsonl(file),                     // JSON lines; `zig build dev -- trace <run_id>` prints a tree
.tracing = z.trace.otlp(.{ .service_name = "support" }), // OTLP/HTTP to an OpenTelemetry collector
```

`z.trace.otlp` sends OTLP/HTTP with the JSON encoding to `<endpoint>/v1/traces`. That works with the OpenTelemetry Collector, Jaeger, Grafana Tempo, Honeycomb, Langfuse and Phoenix.
- The endpoint, headers and service name default to `OTEL_EXPORTER_OTLP_ENDPOINT` (then `http://localhost:4318`), `OTEL_EXPORTER_OTLP_HEADERS` and `OTEL_SERVICE_NAME`. `OTEL_EXPORTER_OTLP_TRACES_ENDPOINT` is used as is.
- Explicit headers can come from the environment: `.headers = &.{.{ "x-honeycomb-team", .{ .env = "HONEYCOMB_API_KEY" } }}`.
- Attributes follow the OpenTelemetry GenAI conventions (`gen_ai.request.model`, `gen_ai.usage.input_tokens`, `gen_ai.tool.name`, ...); zastra's own are under `zastra.*`.
- Spans are queued and sent in batches (512 spans or every 2 s) by a background task. `rt.deinit()` sends what's left, waiting up to 5 s. A collector that's down never fails a run: zastra retries twice, then drops the batch with a warning.
- Prompts and responses are left out unless `.include_content = true`.

To try it locally: `docker run -p 16686:16686 -p 4318:4318 jaegertracing/all-in-one`, set `OTEL_EXPORTER_OTLP_ENDPOINT=http://localhost:4318`, and open http://localhost:16686.

Trace ids are 128-bit (32 hex characters), as in OTLP and W3C `traceparent`. Pass one in with `.trace_id` on `generate`/`stream` to put a run's spans into an existing trace.

## 9. The dev CLI and the C library

```zig
const dev = z.addDev(b, .{ .app = app_mod, .zastra = zastra_dep });
if (b.args) |args| dev.run.addArgs(args);
b.step("dev", "zastra dev CLI").dependOn(&dev.run.step);

const lib = z.addCLib(b, .{ .name = "support", .app = app_mod, .zastra = zastra_dep });
```

`zig build dev -- agents | schema | prefix | chat | run | runs | resume | graph | trace | models`. Your app module must export `pub const App`. If your `Ctx` has fields without defaults, it must also export `pub fn createContext(gpa, io) !*Ctx`.

The C library takes and returns JSON, and streams are pulled (`zastra_stream_next`, `zastra_stream_respond`). See [`examples/support/embed.c`](../examples/support/embed.c).
