# zastra — Plan

A Mastra-style agent framework for Zig. It covers agents, tools, workflows, memory, MCP and tracing, designed around Zig's strengths: comptime, small portable static binaries, and a C ABI.

> Status: **v1 implemented** (M0–M7). See §16 for what was verified, and how.
> The API sketch in `sketch/` is the source of truth for the consumer-facing
> API; `examples/support` is the sketch made real. This document is the source
> of truth for scope, architecture, milestones and decisions. When they
> disagree, fix one of them and note the decision in §13.

---

## 1. Goals and non-goals

### Goals (v1)

1. **A best-in-class consumer experience** for building LLM agents in Zig. Most mistakes should be compile errors with clear messages.
2. **Feature parity with Mastra's core:**
   - model routing (`provider/model` strings)
   - typed tools
   - agents (generate, stream, multi-step tool loop, structured output, human approval)
   - memory (history plus typed working memory)
   - workflows (`then`, `branch`, `parallel`, suspend/resume)
   - an MCP client
   - tracing
3. **Zig-native strengths, as headline features:**
   - comptime-derived schemas, prompts, request prefixes and workflow graphs
   - binaries that contain only what the App uses
   - one App that produces an executable, a dev CLI, a C library with a generated header, and a test harness
4. **Providers:** Anthropic Messages, the OpenAI Responses API for catalog OpenAI models (v1.1, D35), and OpenAI-compatible Chat Completions, which also covers OpenRouter, Groq, Together, Ollama and vLLM.

### Non-goals (v1)

These are explicitly deferred; see §14.

RAG and vector stores, semantic recall, an evals runner, a Studio web UI, an HTTP server framework, auth, channels (Slack, WhatsApp and so on), sandboxes, browser automation, voice, a hosted platform, and the harness/Factory layer.

### Success criteria for v1

- The support-ticket example in `sketch/` compiles and runs against real Anthropic and OpenAI endpoints.
- `zig build -Dtarget=aarch64-linux-musl -Doptimize=ReleaseSmall` on that example produces a static binary under **3 MB**. The stretch target is under 2 MB.
- Every compile-time check listed in §5 has a compile-fail test asserting its error message.
- The C example in `sketch/examples/embed.c` builds and runs against `libsupport`.

---

## 2. Design principles

These are binding. If a feature can't satisfy them, redesign the feature.

1. **Declarations are comptime; execution is runtime.**
   - Tools, agents, workflows and the App are *types*.
   - Nothing in a declaration allocates or does I/O.
2. **Plain Zig types are the schema.**
   - There is no schema DSL.
   - Metadata Zig can't express lives in well-known declarations next to the type: `docs`, `constraints`, `examples`, `error_messages`.
3. **Duck-typed declarations with opt-in features.**
   - A tool is any type with `description`, `Input`, `Output` and `execute`.
   - Declarations like `needsApproval`, `ModelErrors`, `effects`, `retry`, `Suspend`/`Resume` and `needs` each unlock a feature.
   - Unknown declarations that look like typos of known ones produce a compile error (§5.14).
4. **Typed context, not a context bag.**
   - The user's `Ctx` struct is injected into every tool and step.
   - Reusable tools declare `Requires`, and the App checks that `Ctx` satisfies it.
5. **Explicit allocation and I/O.**
   - Every runtime call takes a caller-owned allocator, usually an arena, and uses the App's `std.Io`.
   - There are no hidden globals.
   - Results never outlive the allocator they were given.
6. **Exhaustive unions everywhere a set can grow.** This covers stream events, tool calls, approval requests, workflow suspension points and workflow results. Growth must break call sites at compile time.
7. **Recoverable vs. fatal errors are visible in the type.**
   - `ModelErrors` go back to the model.
   - Everything else aborts the run and reaches user code.
8. **Size follows usage.**
   - No feature flags in `build.zig`.
   - Code paths for providers, storage backends, MCP and streaming are only referenced when the App uses them, so Zig's lazy analysis compiles them out.
9. **Error-message quality is a feature.**
   - Every comptime check emits a hand-written `@compileError`: what is wrong, where, and a "did you mean" suggestion when one is plausible.
   - Generic instantiation noise is a bug.
10. **Pin the toolchain.**
    - Target Zig **0.16.x** only.
    - Use the `std.Io` model (`std.process.Init`, `io.async`, `io.concurrent`, `Future.await` and `Future.cancel`).
    - Assume `std.Io.Threaded`. Do not depend on `std.Io.Evented`.

---

## 3. Public API overview

The full example lives in `sketch/`:

| File | What it shows |
|---|---|
| `sketch/src/app.zig` | Declarations: `Ctx`, domain types, tools, agents, steps, workflows, the `App`, and a test using the scripted-model harness. |
| `sketch/src/main.zig` | Runtime use: `App.init`, typed `generate`, `stream` with exhaustive events and approvals, workflow start/suspend/resume, and the raw model escape hatch. |
| `sketch/build.zig` | Wiring: one App module feeding the executable, `z.addDev` (dev CLI), `z.addCLib` (C library + header) and tests. |
| `sketch/examples/embed.c` | Consuming the generated C ABI. |

### 3.1 Public surface (`@import("zastra")`, conventionally `const z`)

**Declarations (comptime)**
- `z.Agent(Ctx, config) type`
- `z.Workflow(Ctx, name, Input)`, a builder with `.then`, `.branch`, `.commit`
- `z.step.agent(Agent, .{ .input, .prompt })`
- `z.step.parallel(.{ .key = Step, ... })`
- `z.initial(T)` (the workflow input, usable in `needs`; D21) and `z.otherwise` (the default branch arm)
- `z.App(.{ .ctx, .agents, .workflows, .mcp, .storage })`
- `z.mcp.stdio(argv)` and `z.mcp.tools(server_key, .{ .allow })`
- `z.Retry`, `z.Suspendable(Step)`, `z.Partial(T)`, `z.custom(model_spec)`

**Contexts passed to user code**
- `z.ToolCtx(Ctx)` with fields `ctx`, `arena`, `io`, `run_id`, `trace`
- `z.StepCtx(Ctx, Step)` with fields `ctx`, `arena`, `io`, `run_id`, `needs`, `resumed`, plus `fmt(comptime f, args)` (formats into `arena`) and `agent(A)`
  - `w.agent(A).generate(input, opts)` takes no allocator: results live in the step's `arena`. Its memory scoping follows D17.
- `arena` is private to one tool call or one step execution. Parallel tools and parallel branches never share an arena (§6.4, §6.6).

**Utilities**
- `z.fmt.json(value)`, a `{f}` formatter that writes any schema-compatible value as JSON

**Runtime**
- `App.init(gpa, io, opts)` returns a runtime `rt`; `rt.deinit()`
- `rt.agent(A)`: `.generate(alloc, input, opts)` and `.stream(alloc, input, opts)`
- `rt.workflow(W)`: `.start(alloc, input, opts)` and `.resumeStep(Step, alloc, run_id, resume_value)`
- `rt.model(comptime "provider/id")`: `.generate(alloc, messages, opts)` and `.stream(...)`. The model string is comptime so the catalog lookup and provider selection stay comptime (§5.6, D15).

**Testing**
- `z.testing.harness(App, opts)`, `h.script(Agent, steps)`, `h.workflow(W)`, `z.testing.expectSuspended(result, .step_tag)`, `z.testing.arbitrary(T)` (v1.1)

**Build helpers** (exported from the package's `build.zig`)
- `z.addDev(b, opts)` and `z.addCLib(b, opts)`

### 3.2 Naming conventions

- Tool name: `snake_case(@typeName(T))`, minus the module path. It can be overridden with `pub const name = "..."`.
- Agent IDs come from the required `.name` in the agent config (D20). Workflow IDs come from the name string in `z.Workflow(Ctx, "name", Input)`. Both are unique within an App, which is checked at comptime.
- Step IDs: `snake_case(@typeName(T))` for step structs, overridable with `pub const name`; `z.step.agent` steps default to the agent's name (override with `.name`); `z.step.parallel` steps default to `parallel_<key>_<key>...`.
- Generated C identifiers: `<lib>_agent_<id>`, `SUPPORT_AGENT_<ID>`, and so on (§9).

---

## 4. Architecture

### 4.1 Repository layout (zastra package)

```
zastra/
  build.zig, build.zig.zon         # exports module "zastra" + build helpers
  src/
    root.zig                       # public API re-exports only
    app.zig                        # z.App: registry, derived metadata, runtime init
    meta/                          # comptime reflection utilities
      reflect.zig                  # decl lookup, typo detection, type walking
      errors.zig                   # @compileError formatting helpers, did-you-mean
      fingerprint.zig              # structural type hashing
    schema/
      json_schema.zig              # Zig type → canonical JSON Schema (comptime)
      dialect_anthropic.zig        # lowering for Anthropic tool/input schemas
      dialect_openai.zig           # lowering for OpenAI strict mode
      constraints.zig              # docs/constraints decls → schema + runtime validation
      partial.zig                  # z.Partial(T)
      parse.zig                    # validated parse of model JSON into T
      stream_parse.zig             # incremental parser producing Partial(T)
    catalog/
      models.zig                   # GENERATED model capability + pricing table
      catalog.zig                  # lookup, did-you-mean, capability checks
    message.zig                    # internal message/content-block model
    provider/
      provider.zig                 # shared types (Request, Event, Builder, Diagnostic) + comptime selection
      stream.zig                   # SseStream(Wire): the request and event stream every wire module shares (D53)
      http.zig                     # std.http.Client wrapper, retries, timeouts, CA bundle (D12)
      sse.zig                      # Server-Sent Events parser
      anthropic.zig
      openai_responses.zig         # catalog OpenAI models (D35)
      openai_compat.zig            # Chat Completions servers
    prompt/
      template.zig                 # comptime-checked "{field}" templates
      prefix.zig                   # comptime request-prefix serialization
    tool.zig                       # tool validation, erasure, dispatch table
    agent/
      agent.zig                    # z.Agent type function
      loop.zig                     # multi-step tool loop
      events.zig                   # generated event unions
      stream.zig                   # Stream iterator, respond(), cancel()
      structured.zig               # structured output strategies + repair
    memory/
      memory.zig                   # history window, thread/resource scoping
      working.zig                  # typed working memory + update tool
    storage/
      storage.zig                  # Storage interface (comptime-selected)
      sqlite.zig                   # vendored SQLite amalgamation via build.zig.zon
      memory_store.zig
      migrations/
    workflow/
      builder.zig                  # comptime builder
      graph.zig                    # comptime graph IR + analysis
      state.zig                    # generated run-state struct
      runner.zig                   # execution, retries, parallel
      snapshot.zig                 # persist/restore, fingerprint checks
      mermaid.zig                  # comptime diagram emission
    mcp/
      jsonrpc.zig
      stdio.zig                    # child-process transport
      client.zig                   # initialize, tools/list, tools/call
    trace/
      trace.zig                    # span API
      jsonl.zig                    # JSONL exporter
    testing/
      harness.zig
      scripted_model.zig           # typed scripted provider
      cassette.zig                 # record/replay HTTP fixtures (internal tests)
    capi/
      erased.zig                   # JSON-in/JSON-out erased entry points
      export.zig                   # `export fn` generation
  build/
    dev.zig                        # z.addDev implementation (dev CLI main())
    clib.zig                       # z.addCLib implementation + header generation
    manifest.zig                   # App → JSON manifest (feeds header + future codegen)
  tools/
    models-update/                 # regenerates src/catalog/models.zig
  tests/
    compile_fail/                  # one .zig per compile-time check + expected stderr
    golden/                        # schema, prefix and header golden files
    cassettes/                     # recorded provider responses
  examples/
    support/                       # the sketch, made real
```

### 4.2 Data flow for an agent call

```
rt.agent(A).stream(alloc, input, opts)
  │
  ├─ comptime: A.prefix_bytes (system + tools + examples, provider dialect),
  │            A.ToolCall union, A.Event union, A.dispatch table
  │
  ├─ memory.load(thread, resource)       → history messages + working memory
  ├─ provider.request(prefix_bytes ++ dynamic suffix)
  │     http.zig → sse.zig → provider delta normalizer → Event
  ├─ loop.zig: accumulate tool calls → validate args (schema/parse.zig)
  │     → approval gate → io.async per tool → results → next step
  ├─ memory.save(...)
  └─ trace spans emitted throughout
```

### 4.3 Type erasure boundary

Typed APIs are the primary interface. The dev CLI, the C ABI, workflow agent-steps, and dynamic needs require a uniform shape. For each agent and workflow, `z.App` therefore generates an **erased entry** at comptime:

```zig
const ErasedAgent = struct {
    id: []const u8,
    manifest_json: []const u8,          // comptime-serialized metadata
    generate_json: *const fn (rt: *Runtime, alloc, input_json: []const u8, opts_json: ?[]const u8) anyerror!Result,
    stream_json:   *const fn (rt: *Runtime, alloc, input_json, opts_json, cb: EventCallback) anyerror!Result,
};
```

The App exposes `App.erased_agents` and `App.erased_workflows` as comptime arrays. Only the dev CLI, the C ABI and tests reference these, so apps that use neither don't pay for them.

---

## 5. Comptime features

Each item states its **behavior**, **acceptance criteria**, and **milestone**. The v1 picks are 5.1–5.9. Items 5.10–5.16 are cheap to add once the reflection machinery exists; v1 should take them where noted.

### 5.1 Type → JSON Schema

**Milestone: M1**

**Behavior.** `schema.of(T)` returns a comptime `[]const u8` holding the canonical JSON Schema.

Type mappings:

| Zig type | JSON Schema |
|---|---|
| `bool` | `boolean` |
| integers | `integer`, with min/max from bit width unless constrained |
| floats | `number` |
| `[]const u8` | `string` |
| enum | `string` + `enum` of tag names |
| `?T` | optional field. Canonical form omits it from `required`; the dialect decides the final form. |
| `[]const T` and `[N]T` | `array`, with `minItems`/`maxItems` for arrays |
| struct | `object` with `properties`, `required` and `additionalProperties: false` |
| `union(enum)` | `oneOf` with a `"type"` discriminator property set to the tag name |
| `z.Json` | arbitrary JSON, the escape hatch |

Field defaults:
- Fields with defaults are not required.
- The default is emitted as `default` when it's representable.

Descriptions:
- `pub const docs = .{ .field = "..." }` emits `description`.
- A type-level `pub const description` applies to the object itself.

**Rejected with a compile error:** pointers other than slices, untagged unions, error unions, functions, `anyopaque`, and recursive types. Recursion is deferred, with a message that points at `z.Json`.

**Acceptance.** Golden tests cover every mapping, and compile-fail tests cover every rejection.

### 5.2 Constraints and validated parsing

**Milestone: M1**

**Behavior.** `pub const constraints = .{ .field = .{ ... } }` supports:
- `min` and `max` (numbers)
- `min_len`, `max_len` and `pattern` (strings; `pattern` is validated with a small comptime-checked regex subset, or emitted only)
- `min_items` and `max_items` (arrays)
- `one_of` (strings)

Constraints are emitted into the schema and enforced by `schema.parse(T, alloc, json)`. A violation produces a structured `ValidationError` with a JSON path and a message suitable for sending back to the model.

**Acceptance.**
- Constraint keys referencing nonexistent fields fail to compile, with did-you-mean.
- A constraint whose kind doesn't fit the field's type fails to compile. Example: `min_len` on a `u8`.

### 5.3 Per-provider schema dialects

**Milestone: M2**

**Behavior.** `dialect_anthropic` and `dialect_openai` transform the canonical schema at comptime.

OpenAI strict mode:
- every property is required
- optionals become a `["T","null"]` type union
- `additionalProperties: false` on every object
- unsupported keywords are dropped

Validation:
- Tool names must match `^[a-zA-Z0-9_-]{1,64}$`.
- Constructs a provider can't represent fail to compile, naming the provider and the field path.

**Acceptance.** Golden tests per dialect, and compile-fail tests for invalid names and unrepresentable constructs.

### 5.4 Model catalog

**Milestone: M2**

**Behavior.** `catalog/models.zig` is a generated comptime table. Each entry has:
- `provider`, `id`, `context_window` and `max_output`
- `supports`: `tools`, `structured_output` (native or not), `vision`, `reasoning`, `parallel_tools`, `prompt_caching`
- pricing per million tokens: input, output, cache read and cache write

`.model = "provider/id"` is resolved at comptime. The following fail to compile:
- an unknown provider or model, with did-you-mean. For an unknown model under a known provider, the message also suggests `z.custom` (D19).
- `.output` set on a model with neither native structured output nor tool support
- image input on a non-vision model
- `max_tokens` above `max_output`

Escape hatch: `.model = z.custom(.{ .provider = .openai_compat, .id = "...", .base_url = "...", .supports = .{...} })`.

Supporting tooling:
- `tools/models-update` regenerates the table from a checked-in source list of provider docs, maintained by hand at first.
- The generated file carries a date. `zastra dev models --stale` warns when the table is older than 90 days.

**Acceptance.**
- Compile-fail tests for each capability mismatch.
- Usage results include `cost_usd`, computed from the catalog.

### 5.5 Precomputed request prefix

**Milestone: M3**

**Behavior.** For each agent, comptime produces `A.prefix_bytes`: the provider-specific JSON fragment containing the model, system prompt, tool definitions (in dialect) and few-shot examples, in a fixed key order. At runtime, only the dynamic suffix (memory, history, user input, per-call options) is serialized and concatenated.

Additional constants:
- `A.prefix_hash`, a 64-bit hash, exposed for tracing and caching.
- For Anthropic, `cache_control` breakpoints are placed after the tools and system prompt when the model's catalog entry supports prompt caching.

**Acceptance.**
- Golden test: the prefix bytes for the example agents are stable across builds.
- Runtime test: two calls produce byte-identical prefixes.
- A recorded cassette shows cache-read tokens on the second call (manual verification in M3; automated with cassettes later).

### 5.6 Size follows usage

**Milestone: M2 onward; verified in M7**

**Behavior.**
- Provider modules are referenced only through a comptime `switch` over the set of providers the App's models use.
- The storage backend is chosen in `z.App(.{ .storage = .sqlite | .memory })`.
- MCP code is referenced only if `.mcp` is non-empty.
- Streaming machinery is referenced only if some call site uses `.stream`. This one is best-effort, since `generate` may be built on the stream internals; measure before optimizing.

**Acceptance.** An M7 size-budget CI job builds three variants and asserts upper bounds:
1. anthropic-only, memory storage, no MCP
2. both providers, sqlite
3. the full example

### 5.7 Workflow graph analysis

**Milestone: M5**

**Behavior.** `.commit()` builds a comptime graph IR (nodes are steps; edges are sequence, branch and parallel) and checks:
- type flow: each step's `Input` equals its predecessor's `Output`; branch arms agree on `Output`; parallel branches share an `Input`
- `needs`: every referenced step dominates the consumer on all paths, or the reference is `z.initial`
- no duplicate step IDs within a workflow (nested workflows are namespaced)

`needs` across nesting (D13):
- A step inside a nested workflow may need a step from an enclosing workflow (e.g. `DraftReply` in `AnswerPath` needs `Classify` from `HandleTicket`).
- `.commit()` resolves what it can. If some `needs` reference steps not in its graph, it produces an **open** workflow: one that can be embedded with `.then`/`.branch` but cannot run on its own.
- The enclosing `.commit()` resolves the open references against its own graph, with the same dominance rule over the flattened graph. Unresolved references propagate outward.
- At the outermost workflow, every reference must be resolved. Registering an open workflow in `z.App(.{ .workflows })` or calling `rt.workflow()` on it fails to compile:
  ```
  error: zastra: workflow 'answer' can't run on its own: step 'draft_reply' needs 'classify',
         which only exists in an enclosing workflow. Register the enclosing workflow instead.
  ```
- `z.initial` always means the input of the innermost workflow that contains the step.
- the graph is acyclic; repetition is an explicit `z.step.loop` with a required comptime bound (§18.3)

It also derives:
- `W.Suspended`, a `union(enum)` of every reachable step with `Suspend`/`Resume`
- `W.Result`, equal to `union(enum) { completed: Output, suspended: SuspendInfo, failed: Failure }`
- `W.mermaid`, a comptime string

**Acceptance.** Compile-fail tests for each check, and a golden test for `mermaid`.

### 5.8 Generated run state and snapshot fingerprint

**Milestone: M5**

**Behavior.**
- `W.State` is a generated struct with one `?Output` field per step, plus the workflow input and a cursor.
- A snapshot is `std.json` of `W.State` plus metadata `{ run_id, workflow_id, fingerprint, suspended_at, created_at }`.
- `W.fingerprint` is a structural hash of the graph shape and all step Input/Output/Suspend/Resume types. It is computed in `meta/fingerprint.zig` from field names, types and order, not `@typeName`.

On resume:
- If the fingerprints match, resume.
- If they differ, look for `pub const migrations = .{ .{ .from = 0x..., .migrate = fn } }` on the workflow.
- Otherwise fail with `error.SnapshotIncompatible`, which includes both fingerprints.

**Acceptance.**
- Changing any step type changes the fingerprint (tested).
- An unrelated code change does not change it (tested).

### 5.9 Comptime-checked prompt templates

**Milestone: M3**

**Behavior.** `z.step.agent(A, .{ .input = T, .prompt = "...{field}..." })` and `z.prompt.render(T, "...")` parse the template at comptime:
- `{field}` must name a field of `T`, with did-you-mean.
- `{field.sub}` paths are allowed.
- `{{` and `}}` escape literal braces.
- Non-string fields are formatted via JSON.

**Acceptance.** Compile-fail tests for unknown fields and malformed braces.

### 5.10 Typed few-shot examples

**Milestone: M3 (v1)**

**Behavior.** `.examples = &.{ .{ .in = <Input-or-string>, .out = <Output value> } }` on an agent with `.output`. The values are type-checked and serialized into the prefix at comptime. Renaming a field breaks every example that used it.

### 5.11 Exhaustive error mapping

**Milestone: M3 (v1)**

**Behavior.** If a tool declares `ModelErrors`, then `error_messages` must have exactly one entry per error in the set. A missing or extra entry fails to compile.

### 5.12 Effects and permissions

**Milestone: M4 (v1)**

**Behavior.**
- A tool declares `pub const effects = .{ .reads, .writes, .network, .spends_money, .destructive }`. The default is `.{ .reads }`.
- An agent declares `.allow = .{ ... }`. The default allows everything; the strict form is opt-in.
- A tool with a disallowed effect fails to compile.
- Approval-policy default: tools with `.spends_money` or `.destructive` require approval unless they declare `needs_approval = false` or `needsApproval`. Recommended default; see §13.

### 5.13 Reusable tool packages via `Requires`

**Milestone: M4 (v1)**

**Behavior.**
- A tool may be generic over context: `execute(t: anytype, in: Input)` together with `pub const Requires = struct { http: *z.Http }`.
- The App checks that `Ctx` has each required field with a compatible type.
- The tool receives `t.ctx` typed as the App's `Ctx`. It may also use `t.require(.http)` for a narrowed view.

**Acceptance.** The example imports one tool from a separate package module.

### 5.14 Declaration typo detection

**Milestone: M1 (v1)**

**Behavior.** On a tool, step or agent config, any `pub` declaration within edit distance 2 of a known declaration name fails to compile with a did-you-mean.
- Examples: `needApproval`, `ModelError`, `contraints`.
- Known tool declarations: `description`, `Input`, `Output`, `execute`, `name`, `docs`, `ModelErrors`, `error_messages`, `needsApproval`, `needs_approval`, `effects`, `Requires`, `parallel`. Known step declarations: `Input`, `Output`, `run`, `Suspend`, `Resume`, `needs`, `retry`, `retry_on`, `timeout_ms`.
- Unknown declarations that aren't near-misses are allowed, since users may add their own helpers.

### 5.15 `z.Partial(T)` and schema-specialized streaming parse

**Milestone: M6 (stretch for v1; else v1.1).** v1 ships `z.Partial(T)` and its merge (used by working memory). The incremental `stream_parse` and `.output_partial` events shipped in v1.1b (§18.4, opt-in with `.partial_output = true`).

**Behavior.**
- `z.Partial(T)` is `T` with every field optional, applied recursively.
- `stream_parse` consumes JSON deltas and emits `.output_partial: Partial(T)` events as fields complete.
- Strings stream as they grow if the field declares `pub const stream_strings = .{ .field }`.

### 5.16 App manifest

**Milestone: M7 (v1, minimal)**

**Behavior.** A comptime JSON manifest of the App: agents, tools, schemas, workflows, graph, fingerprints and required environment variables. It feeds the C header generator and the dev CLI.

Future consumers (v2):
- TypeScript, Swift and Dart type generation
- an OpenAPI spec for `dev serve`
- an MCP server exposing agents and workflows (§14)

---

## 6. Runtime components

### 6.1 Message model (`message.zig`)

```zig
pub const Role = enum { system, user, assistant, tool };
pub const Block = union(enum) {
    text: []const u8,
    image: struct { media_type: []const u8, data: union(enum) { base64: []const u8, url: []const u8 } },
    tool_use: struct { id: []const u8, name: []const u8, input_json: []const u8 },
    tool_result: struct { id: []const u8, name: []const u8, content: []const u8, is_error: bool }, // content is the JSON result
    reasoning: struct { text: []const u8, opaque_signature: ?[]const u8 },
    provider_opaque: struct { provider: Provider.Tag, json: []const u8 }, // must round-trip
};
pub const Message = struct { role: Role, content: []const Block };
```

Rules:
- Providers normalize to and from this model at the edges.
- Reasoning signatures and other opaque blocks must round-trip unchanged across tool-loop steps and persistence.

### 6.2 Provider interface (`provider/`)

There is no runtime provider interface. Each API is a **wire module** (`anthropic.zig`, `openai_responses.zig`, `openai_compat.zig`), selected at comptime from the model's `catalog.Spec.api` through `provider.Impl(api)`. An App that only uses Anthropic models never references the OpenAI modules (§5.6). Since R1 (D53, §19.0):

```zig
// What callers see (agent loop, rt.model, tests): unchanged by R1.
const Impl = provider.Impl(spec.api);
const prefix = comptime Impl.buildPrefix(parts);           // §5.5
var s = try Impl.Stream.open(arena, &http, request);       // = stream.SseStream(Impl)
defer s.close();
while (try s.next()) |ev| switch (ev) { .delta => ..., .finish => ... };

// What a wire module supplies.
pub const name = "anthropic";
pub const path = "/v1/messages";
pub const capabilities = .{ ... };                         // comptime facts, see below
pub fn buildPrefix(comptime PrefixParts) Prefix;
pub fn writeBody(*Writer, Request) !void;
pub fn writeToolDef(*Writer, name, description, schema_json) !void;   // MCP tools
pub fn auth(arena, api_key) ![]const std.http.Header;
pub const State = struct { ... };                          // per-stream parse state
pub fn onEvent(*State, sse.Event, data: std.json.Value, out: *Out) Error!void;
```

`stream.SseStream(Wire)` (`stream.zig`) owns everything the APIs share:
- the URL (`base_url ++ Wire.path`), headers (`accept`, `Wire.auth`, the request's header map) and the POST
- non-2xx status: the error mapping and one diagnostic format, `"<name> <status> <type or code>: <message>"`
- body read and idle-timeout errors, and `error.StreamInterrupted` when the body ends before a finish event
- parsing each SSE event's data into JSON, the per-event scratch arena, and the `done` state
- an event queue. `onEvent` pushes any number of events (`out.push`), or the final one (`out.finish`). The scratch arena resets only once the queue is drained, so delta slices stay valid until the next `next()` call.

`Out` carries `.builder` (the assistant message being accumulated), `.scratch`, `.diag`, `.push(Event)` and `.finish(Finish)`. An `onEvent` that returns an error after writing `out.diag` reports a mid-stream provider error.

**Capabilities.** Each wire module declares what its API can express, as comptime data:
- the tool and structured-output schema dialects (§5.3), and whether native structured output can carry `z.Json`
- how reasoning is turned on (adaptive or budget, an effort level, or only the model's default), how it's turned off (a disabled setting, effort `"none"`, or not at all), whether a token budget exists, and whether `.temperature` combines with reasoning
- an optional hint appended to the `.show_reasoning` error

`agent.zig` checks an agent's settings against these first (what the API can express), then against the model's `supports.reasoning_modes` from the catalog (what this model accepts), so a compile error says which of the two is the obstacle. All the error wording stays in `agent.zig` (§7). Nothing outside the wire modules switches on `spec.api`, except the scripted test model's encoders (`testing/scripted.zig`, D29).

`http.zig` (built on `std.http.Client`; see D12 and the M0 spike notes in §11):
- one shared `std.http.Client` per runtime
- per-request timeout. `std.http` has none, so the request runs in `io.concurrent` raced against an `io.sleep`, and the loser is cancelled.
- idle timeout while reading the body (`.http.idle_timeout_ms`, default 300 s, 0 disables it). Every network read the body reader makes is raced against a timer the same way; reads served from already-buffered bytes skip the race. A stalled stream fails with `error.Timeout` and a diagnostic. The default is generous because OpenAI-compatible servers can stay silent while a reasoning model thinks; Anthropic sends `ping` events.
- retry with jittered exponential backoff on 429, 5xx, and connection reset
  - **Only before the first response-body byte.** A stream that fails after emitting events is never retried transparently, since that would duplicate deltas. It fails with `error.StreamInterrupted`.
- `Retry-After` is respected
- cancellation via `Future.cancel`. A cancelled read surfaces from `std.http` as `error.ReadFailed`, so `http.zig` checks the cancel state and maps it to `error.Canceled`.
- CA certificates, loaded once in `App.init`, not lazily on the first request:
  - `.ca_bundle = .system` (default): scan the OS store. If it finds no certificates, `App.init` fails with a diagnostic suggesting `.pem`. This is the common failure in `FROM scratch` containers.
  - `.ca_bundle = .{ .pem = @embedFile("cacert.pem") }`: embedded, for fully static deployments
  - `.ca_bundle = .{ .path = "..." }`
- proxies: `HTTPS_PROXY`/`HTTP_PROXY` from the env map, via `std.http.Client`'s proxy support

`sse.zig`:
- line-based parser handling `event:`, `data:` (multi-line), `id:` and `retry:`, plus comments
- a test suite with chunk boundaries split at every byte offset

Anthropic:
- Messages API with streaming events: `message_start`, `content_block_start`/`_delta`/`_stop`, `message_delta`, `message_stop`
- `input_json_delta` accumulation for tool use
- thinking blocks with signatures
- `cache_control`

OpenAI-compatible:
- Chat Completions streaming
- `tool_calls[].function.arguments` delta accumulation keyed by index
- `response_format: json_schema` (strict) when the model supports it
- configurable `base_url` and header map, for OpenRouter and other compatible services
- known limitation: Chat Completions doesn't return reasoning items for OpenAI reasoning models, so they can't round-trip across tool steps. Since v1.1, catalog OpenAI models use the Responses API instead (§17.2, D35).

Configuration:
- Environment variables per provider: `ANTHROPIC_API_KEY`, `OPENAI_API_KEY`, `OPENAI_BASE_URL`. A per-model override is allowed via `z.custom`.
- `App.init` checks that every required variable is present and returns `error.MissingApiKey` with a diagnostic naming each missing one.

### 6.3 Tools (`tool.zig`)

Validation at comptime:
- required declarations
- `execute` signature: `fn (*z.ToolCtx(Ctx), Input) !Output`, or `anytype` for the first parameter when `Requires` is used
- name uniqueness within an agent
- dialect validity

Erasure:
- Generated per agent: a dispatch `switch` on the tool-name hash and a `ToolCall` union (one variant per tool plus `.mcp`).
- Execution: parse args → on a parse or validation failure, return an error result to the model → `execute` → serialize `Output` as the tool result.
- Errors in `ModelErrors` become `is_error` results carrying the mapped message. Other errors propagate and abort the run.

### 6.4 Agent loop (`agent/loop.zig`)

Each step:
1. Build the request: prefix plus memory plus the conversation so far.
2. Stream it, forwarding events.
3. On `tool_use` blocks:
   - Run approval checks; any pending approval pauses the stream.
   - Execute approved tools with `io.async`, one per tool, so they can run in parallel.
     - Each call gets its **own arena** (a child of the run's allocator). `std.heap.ArenaAllocator` is not thread-safe, and `std.Io.Threaded` may run the tasks on different threads.
     - Tools in the same step may run concurrently, so anything reachable through `Ctx` must be safe to use from several threads. This is documented on `ToolCtx`. A tool can opt out with `pub const parallel = false`, which makes the step run its calls sequentially.
   - Await all of them. Tool results are copied into the run's arena before the per-call arenas are freed.
   - Append the results.
4. Repeat until a stop condition holds: no tool calls, `max_steps` reached, a stop reason of `end_turn`/`stop`, a user-provided `stop_when` predicate, or cancellation.

Structured output, used when `.output = T`:
1. Use native structured output if the catalog says the model supports it.
2. Otherwise force a synthetic `final_answer` tool whose input schema is `T`.
3. On a parse or validation failure, make **one** repair attempt that includes the validation error. If that also fails, return `error.OutputInvalid` with the raw text attached.

Approvals:
- `stream.respond(id, .approve | .{ .deny = reason })` resumes the run.
- In `generate` (non-streaming), an agent with gated tools returns `.suspended` with the pending calls, after saving the run (v1.1, D31; v1 returned `error.ApprovalRequired`). Alternatively, `opts.on_approval` can supply a callback.
- Approval state is held in memory only in v1. Persisting a paused agent run is v1.1; workflows already persist.
- An agent with approval-gated tools inside a workflow step suspends the workflow (v1.1, D34; v1 made it a compile error, D18). `z.step.agent(A, ...)` does it automatically; a custom step declares `Suspend = z.Approvals(A)` and `Resume = z.Decisions(A)` and calls `w.agent(A).run(...)`. `w.agent(A).generate` on such an agent, or one inside `z.step.parallel`, is still a compile error:
  ```
  error: zastra: step 'draft_reply' calls `w.agent(support).generate`, but agent 'support' has
         approval-gated tool 'issue_refund'. Use `w.agent(support).run(...)` and declare
         `pub const Suspend = z.Approvals(support);` and `pub const Resume = z.Decisions(support);` ...
  ```

Results:
- `GenerateResult(A)` holds `text`, `output` (when `.output` is set), `steps`, `usage` (input, output, cache tokens, `cost_usd`), `finish_reason`, and `messages` (when `opts.include_messages` is set).

Events (`agent/events.zig`):
- `text_delta`, `reasoning_delta`
- `tool_call: A.ToolCall`, `tool_result`
- `approval_request: { id, call: A.ApprovalCall }`, where `ApprovalCall` contains only the approval-gated tools
- `output_partial` (5.15)
- `step_finish`, `finish`

### 6.5 Memory (`memory/`)

Concepts:
- A **thread** scopes message history.
- A **resource** scopes working memory, e.g. a customer.

`.memory.history`:
- `.last_messages = N` loads the last N messages of the thread.
- Tool-use and tool-result pairs are never split.

`.memory.working = T`:
- Adds an `update_working_memory` tool whose input is `z.Partial(T)`, with merge semantics.
- Injects the current value into the system suffix (not the prefix, which keeps the prefix cacheable).
- Persists per resource.

Agents called from workflow steps (D17):
- `thread` defaults to `"<run_id>/<step_id>"`, so history survives suspend/resume of that run but doesn't leak between runs.
- `resource` defaults to the `resource` passed in `wf.start(alloc, input, .{ .resource = ... })`, or none.
- Both can be overridden per call in `opts`.

SQLite schema (v1):

```sql
threads(id TEXT PRIMARY KEY, resource TEXT, created_at INTEGER, updated_at INTEGER)
messages(id INTEGER PRIMARY KEY, thread_id TEXT, seq INTEGER, role TEXT, content_json TEXT, created_at INTEGER)
working_memory(resource TEXT, agent_id TEXT, value_json TEXT, fingerprint INTEGER, updated_at INTEGER,
               PRIMARY KEY(resource, agent_id))
runs(run_id TEXT PRIMARY KEY, kind TEXT, owner_id TEXT, fingerprint INTEGER, status TEXT,
     suspended_at TEXT, state_json TEXT, created_at INTEGER, updated_at INTEGER)
schema_version(version INTEGER)
```

(v1 named the runs table `workflow_runs`, with `workflow_id` and no `kind`; migration 0002 renames it, D32.)

- Migrations are embedded with `@embedFile` and applied in `App.init`.
- A working-memory fingerprint mismatch (because `T` changed) is migrated through `T.migrations` (`z.migrate(Old, f)`, §18.2); without a matching migration it resets to the default and logs a warning.

### 6.6 Workflows (`workflow/`)

Builder:
- `z.Workflow(Ctx, "name", Input)` returns a comptime builder; `.then(Step)`, `.branch(.{ .{ pred, StepOrWorkflow }, ... })`, `.commit()`.
- `.commit()` returns a type that also satisfies the step interface, so workflows nest.

Steps:
- A step type has `Input`, `Output` and `run(w: *z.StepCtx(Ctx, @This()), in: Input) !Output`.
- Steps with `Suspend`/`Resume` return `z.Suspendable(@This())`, a union of `done: Output` and `suspended: Suspend`.
- Optional declarations: `retry: z.Retry`, `needs`, and `timeout_ms`.

Branches:
- Predicates are `fn (Input) bool`, evaluated in order. `z.otherwise` must be last if present.
- If no arm matches and there is no `z.otherwise`, the run fails with `error.NoBranchMatched`.

Parallel:
- `z.step.parallel(.{ .a = A, .b = B })` runs its branches with `io.async`.
- Its Output is a struct with fields `a: A.Output` and `b: B.Output`.
- Each branch gets its own arena; outputs are copied into the run's arena on join (same reason as §6.4).
- If any branch fails, the others are canceled and the step fails with the earliest failure in time (D47, §18.1). Branches observe cancellation at `std.Io` cancellation points (HTTP, sleeps, storage).
- Steps inside a parallel group can't suspend (compile error), and nested workflows can't be parallel branches in v1.

Runner:
- Executes the graph and writes a snapshot after each step. Only state is snapshotted; there are no continuations.
- **Steps run at least once** (D16). If the process dies mid-step, the step re-runs from the last snapshot, and a resumed step re-runs from the top with `w.resumed` set. Side effects that must not repeat (refunds, emails) should be idempotent, e.g. keyed on `w.run_id` and the step ID. This is stated in the `StepCtx` docs and the Getting Started guide.
- On suspend: persist and return `.suspended`.
- `resumeStep(Step, alloc, run_id, value)`:
  - checks the fingerprint (§5.8)
  - checks that the run is suspended at `Step`; otherwise `error.NotSuspendedAtStep`
  - sets `w.resumed = value` and re-runs that step

Retries:
- Per-step `z.Retry{ .attempts, .backoff }`.
- A retryable error set can be declared: `pub const retry_on = error{...}`. The default retries all errors except `ModelErrors`-style validation errors.

### 6.7 MCP client (`mcp/`)

(v1 is described below: stdio, `initialize`, fixed tool lists. v1.1 adds the 2026-07-28 protocol, Streamable HTTP and tool list refresh; see §17.5.)

- Transport: stdio child process in v1. Streamable HTTP is v1.1.
- Protocol: JSON-RPC 2.0, `initialize`, `tools/list`, `tools/call`, and `notifications/tools/list_changed` (logged; tool lists are fixed at App init in v1).
- MCP tool schemas arrive at runtime, so MCP tools are **runtime-typed**:
  - They appear as the `.mcp` variant in `ToolCall`, carrying `server`, `tool` and `args_json`.
  - Arguments are validated against the server-provided schema with a small runtime JSON Schema validator (subset).
- `z.mcp.tools(.server, .{ .allow = &.{...} })` filters tools by name. Unknown names fail at `App.init`, not at comptime.
- Evaluate `mcp.zig` (muhammad-fiaz) during M4. Adopt it if it is solid on 0.16; otherwise implement directly (estimated 2–3 days for this subset).

### 6.8 Tracing (`trace/`)

Span model:
- `{ trace_id, span_id, parent_id, name, kind, start_ns, end_ns, attrs, status }`
- Kinds: `agent_run`, `agent_step`, `model_call`, `tool_call`, `workflow_run`, `workflow_step`, `mcp_call`
- Attributes include model, tokens, cost, `prefix_hash`, tool name, and the error message.

Exporters:
- `.jsonl(writer)` (v1), `.off`, and `.otlp(url)` (v1.1)
- Prompt and response bodies are excluded by default; `.include_content = true` adds them.

The dev CLI's `trace <run_id>` reads the JSONL and prints a tree.

### 6.9 Storage interface

```zig
pub const Storage = struct { // comptime-selected backend, reached through a small vtable
    pub fn appendMessages(...) !void;
    pub fn loadHistory(...) ![]Message;
    pub fn getWorkingMemory(...) !?[]const u8;
    pub fn putWorkingMemory(...) !void;
    pub fn saveRun(...) !void;
    pub fn loadRun(...) !?RunRecord;
    pub fn listRuns(filter) ![]RunSummary;
};
```

- Backends: `.memory` (tests and scripts) and `.sqlite` (the vendored amalgamation, compiled through the build system as C).
- Only the backend named in `z.App` is compiled into the runtime. Agent and workflow code is generic over the agent/workflow (not the App), so it reaches storage through a 7-entry vtable; the cost is one indirect call per storage operation.
- The SQLite amalgamation is always compiled into a static library, but its objects are linked only when `sqlite3_*` symbols are referenced, i.e. only for Apps with `.storage = .sqlite`.
- Concurrency: one connection per runtime, guarded by a `std.Io.Mutex`, in WAL mode.

---

## 7. Errors and diagnostics

### Compile-time

Style guide, enforced in review and covered by compile-fail tests:

```
error: zastra: tool 'IssueRefund' declares `needApproval`; did you mean `needsApproval`?
error: zastra: workflow 'handle_ticket': step 'notify_customer' expects Input `Resolution`,
       but previous step 'classify' outputs `Triage`
error: zastra: agent 'support' model "antropic/claude-sonnet-4-6": unknown provider 'antropic'
       (did you mean 'anthropic'?)
```

Requirements:
- Every message starts with `zastra:`.
- It names the user's declaration, not zastra internals.
- It gives one actionable sentence.
- It includes a did-you-mean suggestion when the edit distance is 2 or less.

### Runtime

Each subsystem has an explicit error set. Diagnostics carry details, without allocation surprises. `rt.lastDiagnostic()` returns:
- a provider error body, truncated
- a validation path
- the names of missing environment variables

---

## 8. Dev CLI (`z.addDev`)

Generated `main()` for the App. It is built on the erased entries (§4.3), uses comptime command discovery in the zcli style, and is invoked as `zig build dev -- <cmd>`.

| Command | Purpose |
|---|---|
| `agents` | List agents, models, tools and effects |
| `schema <agent> [--dialect openai]` | Print tool and output schemas |
| `prefix <agent>` | Print the precomputed request prefix and its hash |
| `chat <agent> [--thread t] [--resource r]` | REPL with streaming, tool logs, and interactive approvals |
| `run <workflow> @input.json` | Start a workflow |
| `runs [--suspended]` | List runs |
| `resume <run_id> @resume.json` | Resume a suspended run |
| `graph <workflow>` | Print Mermaid |
| `trace <run_id>` | Pretty-print the span tree |
| `models [--stale]` | Show catalog entries the App uses |

`dev serve` (an HTTP + SSE API exposing the same commands, for a future web UI) is v1.1.

---

## 9. C ABI (`z.addCLib`)

Design: **JSON at the edges.** Inputs and outputs cross as UTF-8 JSON validated against the comptime schemas. Zig callers never use this path.

Generated header (`<lib>.h`):
- `<lib>_app_new(config_json, *err)` and `<lib>_app_free(app)`
- `<lib>_agent_generate(app, AGENT_ID, input, opts_json, *err)` returns `*zastra_result`. For an agent with gated tools that can be `{"status":"suspended","run_id",...}`; `<lib>_agent_resume` continues it (ABI v2, §17.3).
- `<lib>_agent_stream(app, AGENT_ID, input, opts_json, *err)` returns `*zastra_stream`
- Streaming is **pull-based**, mirroring Zig's `stream.next()` (D14):
  - `zastra_stream_next(s, *zastra_event) → zastra_status`: `ZASTRA_OK` with an event, `ZASTRA_DONE`, or an error code. `zastra_event { zastra_event_kind kind; const char *json; size_t len; const char *approval_id; }`; its pointers stay valid until the next `next` call.
  - `zastra_stream_respond(s, approval_id, decision_json, *err)`. While an approval is pending, `next` returns `ZASTRA_ERR_APPROVAL_PENDING` without blocking. The handle can be held as long as the caller likes, e.g. while a UI waits for a human.
  - `zastra_stream_cancel(s)`, safe from any thread; `next` then returns `ZASTRA_ERR_CANCELED`
  - `zastra_stream_result(s)` after `ZASTRA_DONE`, then `zastra_stream_free(s)`
- `<lib>_workflow_start(app, WORKFLOW_ID, input_json, *err)` and `<lib>_workflow_resume(app, run_id, step_id, resume_json, *err)`
- `zastra_result_json(r)` and `zastra_result_free(r)`
- `zastra_error { int code; char message[512]; }`
- Generated constants: `SUPPORT_AGENT_<ID>`, `SUPPORT_WORKFLOW_<ID>`, `SUPPORT_<TYPE>_SCHEMA` (JSON Schema string literals), and `SUPPORT_MANIFEST_FINGERPRINT`
- The event kind enum `zastra_event_kind`

Why pull instead of callbacks: no reentrancy rules, no deadlock between a blocked callback and `respond`, and FFI from Dart, Swift and Python handles a pull loop more easily than C callbacks crossing threads.

Rules:
- **Ownership.** Strings passed in are borrowed for the duration of the call. Results and streams are owned by the caller and freed with `zastra_result_free` / `zastra_stream_free`.
- **Threading.** An app handle is safe to use from multiple threads, and separate streams run independently. A single stream must not be used from two threads at once, except for `zastra_stream_cancel`.
- **ABI versioning.**
  - `zastra_abi_version()` reports the ABI version.
  - The header embeds the manifest fingerprint.
  - `app_new` fails if the library and header disagree; in C this check is via a macro passed at compile time.
- **Linkage.** `.dynamic` or `.static`. The static library is the iOS and Flutter-FFI path.

---

## 10. Testing strategy

- **Unit tests** per module (`zig build test`).
- **Golden tests** (`tests/golden/`) cover schemas (canonical and per dialect), prefix bytes, Mermaid output, the manifest, and the generated C header. They update with `zig build golden -- --update`.
- **Compile-fail tests** (`tests/compile_fail/`):
  - Each case is a small `.zig` file plus an expected-stderr substring.
  - A build step runs `zig build-obj` on each case and asserts both the failure and the message.
  - Every compile-time check in §5 needs at least one case. **This is a release gate.**
- **Cassette tests** (`tests/cassettes/`): recorded HTTP/SSE exchanges per provider, replayed through `http.zig`. They are recorded with real keys behind `-Drecord`.
- **SSE fuzzing**: Zig's built-in fuzzer on `sse.zig`, `schema/parse.zig` and `stream_parse.zig`.
- **Harness tests** (user-facing):
  - `z.testing.harness` with `h.script(Agent, steps)`, and `h.scriptModel("provider/id", steps)` for `rt.model` (through `h.model("provider/id")`).
  - Scripted steps are typed:
    - `.tool(LookupOrder, .{ .order_id = "X" })`
    - `.output(Triage{...})`
    - `.text("...")`
  - Scripting a call with the wrong argument type fails to compile.
  - The harness uses a fake clock and memory storage.
- **Example as integration test**: `examples/support` runs in CI against cassettes.
- **Size budget job** (§5.6) and a **cross-compile matrix**: x86_64-linux-musl, aarch64-linux-musl, aarch64-macos, x86_64-windows.

---

## 11. Milestones

Estimates assume one experienced Zig developer working focused time. The total is roughly **8–10 weeks** for v1. Each milestone ends with its acceptance criteria green.

### M0. Skeleton (2–3 days)
- `git init`; repo, `build.zig`/`build.zig.zon` pinned to Zig 0.16
- Module layout from §4.1 with stubs
- HTTP spike: **done** (2026-10-14, Zig 0.16.0, `std.http.Client`):
  - TLS plus POST to `api.anthropic.com` and `api.openai.com`: OK (401 JSON with an invalid key)
  - incremental read of a chunked TLS body: OK (bytes arrive as sent, no buffering)
  - `Future.cancel` on a blocked read: returns immediately, but as `error.ReadFailed` (mapped in `http.zig`, §6.2)
  - gaps to fill in `http.zig`: per-request timeout, retry policy, CA bundle loading
- CI (build, test, cross-compile matrix)
- Compile-fail test harness working on one trivial case
- `meta/errors.zig` (did-you-mean, message formatting)

### M1. Reflection and schemas (1 week)
- 5.1 type→schema, 5.2 constraints and validated parse, 5.14 typo detection
- `meta/reflect.zig`, `meta/fingerprint.zig`
- Exit: golden schemas for every type in `sketch/src/app.zig`; compile-fail cases for all rejections.

### M2. Providers and catalog (1.5–2 weeks)
- `message.zig`, `http.zig`, `sse.zig`, Anthropic and OpenAI-compatible providers with streaming and tool-call accumulation
- 5.3 dialects, 5.4 catalog plus `tools/models-update` (manual source list), 5.6 comptime provider selection
- `rt.model(...)` raw generate and stream
- Internal test infrastructure, needed by M3–M5: `testing/cassette.zig` (record/replay) and `testing/scripted_model.zig` as an untyped scripted provider (scripted events in, no network)
- Exit: cassette tests for text, tool use and streaming on both providers; an anthropic-only build contains no OpenAI symbols (check with `nm`).

### M3. Tools and agent loop (1.5 weeks)
- `tool.zig`, `agent/*`, structured output with one repair attempt
- 5.5 prefix, 5.9 templates, 5.10 examples, 5.11 error mapping
- Events, `stream.respond`, approvals, parallel tools via `io.async`, cancellation
- Tracing (JSONL) wired through
- Exit: the `TriageAgent` and `Support` examples work against both providers, with streaming, approvals and typed output.

### M4. Memory, storage, MCP (1–1.5 weeks)
- Storage interface, memory and SQLite backends, migrations
- History and working memory (with `Partial(T)` merge, 5.15 type only)
- MCP stdio client (evaluate `mcp.zig` first)
- 5.12 effects, 5.13 `Requires`
- Exit: a `Support` conversation persists across process restarts, and MCP tools appear in the `ToolCall.mcp` variant.

### M5. Workflows (1.5–2 weeks)
- Builder, graph IR and analysis (5.7), run state and fingerprint (5.8)
- Runner, retries, parallel, branch, nesting, suspend/resume, snapshots, Mermaid
- `z.step.agent`
- Exit: `HandleTicket` runs end to end, suspends, survives a restart, and resumes. A fingerprint mismatch is detected.

### M6. Testing harness and DX polish (1 week)
- `z.testing.harness`: the user-facing, typed layer over the M2 scripted provider (`h.script` typed against tools and outputs, fake clock, memory storage, `expectSuspended`)
- Audit every compile-error message against the §7 style guide
- 5.15 streaming partial parse (stretch)
- Exit: the sketch's test passes, and the compile-fail suite covers all §5 checks.

### M7. Dev CLI, C ABI, size (1 week)
- `z.addDev` (commands from §8 except `serve`)
- `z.addCLib` plus header generation from the manifest (5.16)
- Size-budget CI job
- Docs: README, a "Getting started" guide, and API reference generated via `zig build docs`
- Exit: all v1 success criteria from §1 are met.

---

## 12. Risks

| Risk | Impact | Mitigation |
|---|---|---|
| Comptime cost (compile time, eval branch quota) as Apps grow | Slow builds; quota errors that confuse users | Keep reflection linear; set `@setEvalBranchQuota` inside zastra with headroom; measure compile time of the example in CI against v1.0.0 built on the same runner (fresh caches) and fail above 1.5×; keep large data out of comptime. |
| Compile-error quality | The main DX promise fails | Compile-fail tests are a release gate; message style guide (§7). |
| Zig std churn (0.16 → 0.17) | Breakage | Pin 0.16; isolate `std.http` and `std.Io` usage behind `provider/http.zig` and a thin `io` shim; schedule a migration milestone after 0.17. |
| `std.http.Client` / TLS gaps with provider endpoints | Blocks M2 | **Retired by the M0 spike** (§11): TLS and streaming work against both providers on 0.16.0. The remaining gaps (timeouts, retries, CA loading) are ours to build in `http.zig`. If a provider later needs something `std.http` can't do, the fallback is a C library behind `http.zig`; the interface doesn't change. |
| Missing CA certificates in minimal containers | TLS fails at runtime in `FROM scratch` images | Load the CA bundle in `App.init` and fail there with a clear diagnostic; support an embedded PEM (§6.2). |
| Concurrency in user code (parallel tools and steps share `Ctx`) | Data races in user code | Per-task arenas inside zastra; documented thread-safety requirement on `Ctx`; `pub const parallel = false` opt-out on tools (§6.4). |
| `std.Io.Evented` not shipped | No io_uring performance | Design only against the `std.Io` interface; `Threaded` is adequate for I/O-bound agent workloads. |
| Model catalog staleness | False compile errors on new models | `z.custom` escape hatch; dated table with a stale warning; easy regeneration. |
| Provider semantic drift (new block types, stream events) | Runtime parse failures | `provider_opaque` block that round-trips unknown content; unknown stream events are logged and skipped, not fatal. |
| SQLite adds C to the build | Cross-compile friction | It's the amalgamation compiled by Zig (cross-compiles cleanly); `.memory` backend for zero-C builds. |
| Snapshot compatibility across deploys | Stuck runs | Fingerprints plus explicit migrations (5.8); `dev runs --suspended` shows mismatches. |

---

## 13. Decisions and open questions

Decisions made so far, with the recommended default for each open item. Revise them here.

| # | Question | Status / default |
|---|---|---|
| D1 | Name | **zastra**, conventional import alias `z`. |
| D2 | Agents as types vs. values | **Types** (`z.Agent(Ctx, cfg)`), for comptime checks. A runtime `z.DynamicAgent` (runtime model string, instructions, subset of tools, JSON-typed output) is **v1.1**. Open: is it needed in v1 for any known use case? |
| D3 | Workflow syntax | **Chained builder** (`.then().branch().commit()`), for Mastra familiarity. Revisit if compile errors from chained generics prove hard to make readable in M5; the fallback is a declarative `.steps = .{...}` form. |
| D4 | Snapshot versioning | **Structural fingerprint plus optional explicit migrations** (5.8). |
| D5 | C ABI shape | **JSON at the edges** (§9). Struct-level C API deferred. |
| D6 | Storage backend selection | **Comptime**, in `z.App(.{ .storage = ... })`, so unused backends are compiled out. The path/DSN is a runtime option. |
| D7 | Feature flags in build.zig | **None**; size follows usage (5.6). |
| D8 | Approval default for `.spends_money`/`.destructive` effects | **Require approval by default.** Open: is this too opinionated? The alternative is effects that are informational only. |
| D9 | Agent-run persistence while awaiting approval | **In memory only in v1**; workflows are the durable path. v1.1: persisted agent runs. |
| D10 | MCP dependency | **Evaluate `mcp.zig` in M4**; own the stdio subset if it doesn't fit. |
| D11 | Allocation model for results | **Caller-provided allocator per call** (usually an arena); the runtime owns only long-lived state (HTTP client, storage, MCP processes). |
| D12 | HTTP stack | **`std.http.Client` behind `provider/http.zig`.** `httpx.zig` (muhammad-fiaz) was evaluated on 2026-10-14 and rejected: its latest release (0.2.2) requires Zig 0.17; its client buffers the entire response body, so SSE token streaming isn't possible through it; it ships its own TLS 1.3 engine instead of `std.crypto.tls`; and it is about 77k lines with 6 eagerly fetched dependencies, which conflicts with D7 and §5.6. The M0 spike showed that `std.http` covers what we need (§11). |
| D13 | `needs` across nested workflows | **Resolved at the outermost commit.** An inner `.commit()` with unresolved references yields an open workflow that can be embedded but not run or registered (§5.7). Forbidding cross-nesting `needs` was rejected: it forces threading data through every intermediate `Input`. |
| D14 | C streaming and approvals | **Pull-based `zastra_stream` handle** (`next`/`respond`/`cancel`/`free`), mirroring Zig's `stream.next()` (§9). Rejected: callbacks plus `respond` (reentrancy and deadlock rules) and callbacks plus a "paused" return code (two control-flow styles in one API; awkward over FFI). |
| D15 | `rt.model` argument | **Comptime string.** A runtime string would pull the whole catalog and every provider into every binary. Runtime-chosen models belong to `z.DynamicAgent` (v1.1). |
| D16 | Step execution guarantee | **At least once.** A crash or resume re-runs the step from the top. Idempotency is the step author's job; `w.run_id` plus the step ID is the recommended key (§6.6). |
| D17 | Memory for agents called from workflow steps | `thread` = `"<run_id>/<step_id>"`, `resource` = the workflow's `start` option; both can be overridden per call (§6.5). |
| D20 | Agent IDs | **Required `.name` in `z.Agent` config.** A type returned by a function is named after the call (`zastra.Agent(...)`), not the declaration it is assigned to, so the ID can't be derived from `pub const Support = ...`. Missing `.name` is a compile error that explains this. Mastra also requires agent names. |
| D21 | `needs` on the workflow input | **`z.initial(T)`**, not a bare `z.initial`. A step's `StepCtx(Ctx, Step)` is fixed by its own signature, but one step can appear in workflows with different inputs, so `w.needs.<key>` needs its type written down. `.commit()` checks `T` against the innermost workflow's Input with a clear error. |
| D22 | Workflow `Result` shape | `W.Result` has a `.suspended` arm only when some step in the graph can suspend, the same "only what this workflow can do" rule as agent `Event` unions. Switches stay exhaustive and minimal. |
| D23 | Workflow snapshot migrations | Declared on the builder: `.migration(OldWorkflow.fingerprint_value, migrateFn)` before `.commit()`, since a committed workflow is a generated type and can't carry user declarations. |
| D24 | Resume semantics | Resuming (and crash recovery) **replays the graph from the top**, skipping steps whose outputs are in the snapshot and re-taking recorded branch decisions. No continuations are stored. Branch predicates therefore must be pure functions of their input. |
| D25 | Tool results in the message model | `tool_result.content` is the result as a string (the tool's Output as JSON, or the error message), not nested blocks. Both providers take a string; nested blocks can come back in v1.1 if image results are needed. |
| D26 | Agent and workflow results with nothing to report | Agents without tools have no `tool_call`/`tool_result` events, and agents without gated tools have no `approval_request` (same rule as D22). |
| D27 | `pattern` constraints | Emitted into canonical and Anthropic tool schemas; **not** enforced client-side in v1 (no regex engine). Strict dialects drop them. |
| D28 | Dev CLI and C library context | The app module exports `pub const App`, and `pub fn createContext(gpa, io) !*Ctx` (optional `destroyContext`) when `Ctx` can't be default-initialized. |
| D29 | Cassettes | Provider tests replay hand-written SSE in each provider's documented wire format (`tests/cassettes`), and the test harness renders scripted turns in the same format. `App.init(.{ .http = .{ .record_dir = "..." } })` records real traffic into new cassettes. |
| D30 | Thinking blocks in persisted history | Passed back unchanged **within** a run (required for tool loops). Dropped from history **loaded** at the start of a later run: newer Claude models bind thinking blocks to the exact earlier prefix, which the history window and the working-memory suffix change between runs, so replaying them would be rejected. Dropping them is the documented recovery and costs only that turn's earlier reasoning. |
| D31 | Saved approvals API | An agent with approval-gated tools returns `union { completed, suspended }` from `generate`; resume by id with `resumeRun` / `resumeStream`, like workflows. Replaces `error.ApprovalRequired`. Agents without gated tools are unchanged. (§17.3) |
| D32 | Agent run storage | One `runs` table with `kind` (migration 0002); atomic `claimRun` compare-and-set before every resume, for agents and workflows (fixes a v1 double-resume race). (§17.3) |
| D33 | Partial approval decisions | Allowed: decided ids are saved, the run stays suspended with the rest. (§17.3) |
| D34 | Gated agents in workflow steps | `z.step.agent` with a gated agent becomes suspendable automatically (`z.Approvals(A)` / `z.Decisions(A)`); custom steps use `w.agent(A).run`, which resumes the saved agent run on replay. Parallel branches still can't suspend. Supersedes D18's compile error. (§17.4) |
| D35 | OpenAI API | Catalog `openai/*` models use the Responses API, with `store: false`; `openai_compat` (Chat Completions) remains for third-party servers. (§17.2) |
| D36 | OpenAI reasoning items | Round-tripped within a run as opaque blocks; dropped from history loaded across runs, like D30, until live evidence says otherwise. (§17.2) |
| D37 | Reasoning control | `.reasoning` = `.default`, `.on`, `.off` or `.{ .budget = N }` and `.show_reasoning`, mapped per model at comptime from catalog capabilities; impossible combinations are compile errors. On OpenAI Responses, `.on` is an effort (`.effort` or `medium`), `.off` is effort `none`, `.show_reasoning` is `summary: "auto"`, and `.effort = .xhigh`/`.max` send `xhigh` only where the catalog says the model accepts it. (§17.1, §17.2) |
| D38 | MCP client era and auth | Dual-era: 2026-07-28 first, falling back to 2025-11-25 `initialize` on stdio and HTTP; HTTP+SSE (2024-11-05) unsupported. No sampling/elicitation/roots (`InputRequiredResult` becomes a tool error). HTTP auth is static headers and a bearer token from the env; OAuth deferred. (§17.5) |
| D39 | MCP tool list refresh | Via `subscriptions/listen`, legacy `list_changed` notifications, or `ttlMs`; applied at the next run start, tools sorted for stable prefixes. (§17.5) |
| D40 | MCP schema validation | Adds local `$ref`, `allOf`, conditionals and `prefixItems` with depth/size bounds; unsupported schemas skip validation with a warning instead of hiding the tool. (§17.5) |
| D41 | Suspending a live stream | `s.suspendRun()`, not `s.suspend()`: `suspend` is still a Zig keyword. The C ABI matches with `zastra_stream_suspend`, and adds `<lib>_agent_cancel`; every agent result JSON now has `"status"`. (§17.3) |
| D42 | Optional MCP servers and URL overrides | `z.mcp.http(..., .{ .optional = true })` starts the App without an unreachable server's tools (logged); `.url_env` replaces the URL when that variable is set. (§17.5) |
| D43 | Partial output events | Opt-in `.partial_output = true` adds `.output_partial: z.Partial(Output)` (the whole value so far) and `.output_partial_reset` (after a repair). Without the flag, neither is compiled. Partial values are unvalidated. (§18.4) |
| D44 | Partial output parsing | A byte scanner finds field boundaries; at each one, the buffered prefix is closed and parsed leniently. It isn't a full incremental parser. (§18.4) |
| D45 | Loops | `z.step.loop(Body, .{ .until, .max, .on_limit })`: do-until over a `T → T` body, with a required comptime `.max`. `.on_limit` defaults to `.fail` (`error.LoopLimit`). (§18.3) |
| D46 | Loop state and ids | The slot holds `{ iter, value }`. Body slots are cleared each iteration, in the same save that advances `iter`. Saved agent-run ids get `@<iter>`. The default agent thread doesn't, so loops keep their history. Steps after the loop can't need body steps. (§18.3) |
| D47 | Parallel failure | The first branch failure cancels its siblings. The step reports the earliest real failure in time (v1: first in declaration order, after all finished). Branches no longer share the run's failure state or diagnostic. (§18.1) |
| D48 | Working-memory migrations | Typed: `pub const migrations = .{ z.migrate(Old, f) }` on the working-memory type, checked as a chain at comptime. A failing migration fails the run. No match still resets, with a better warning. Also applied when restoring saved agent runs. (§18.2) |
| D49 | OTLP exporter | OTLP/HTTP with JSON encoding, no protobuf or gRPC. Referenced through a vtable from `z.trace.otlp` only, so other Apps link none of it. Its own HTTP client. Bounded queue and a background sender; export failures never fail runs. Trace ids widen to 128 bits everywhere, with no compatibility path (no outside users yet). GenAI semantic-convention attribute names. (§19.1) |
| D50 | `dev serve` | A library function (`z.dev.serve`) behind the dev CLI. SSE events use the C ABI's event JSON. Approvals suspend the run and close the stream; clients resume over a new request. Loopback by default, `Host`/`Origin` checks, a bearer token required off loopback. (§19.2) |
| D51 | `z.testing.arbitrary(T)` | Values valid by construction for `schema.parse`, edge-biased, from `std.Random` or `std.testing.Smith`. `pattern` isn't generated (D27); a type can override with `pub fn arbitrary`. (§19.3) |
| D52 | `z.testing.fuzzTool` | Valid and hostile inputs along the model's tool-call path. Effectful tools need `.allow_effects` at compile time. Failures print a reproducing seed. (§19.4) |
| D53 | Provider modules | One shared `stream.SseStream(Wire)` owns the request, error mapping, SSE and JSON parsing and an unbounded event queue. Each API is a wire module supplying `path`, `auth`, `State`, `onEvent` and comptime `capabilities`. `agent.zig` reads the capabilities instead of switching on `spec.api`, and keeps all the error wording (§7). There is no runtime provider vtable: the raw `rt.model` path is comptime too (D15). Rejected: a `resolveReasoning` per wire module, which would scatter §7 wording over four files. (§6.2, §19.0) |
| D54 | Opening model streams | `runtime.State.openStream` is the only place that turns a spec into a provider request, for the agent loop and `rt.model` alike. Under the harness, requests carry a routing tag (`x-zastra-agent`: the agent id, or `model:<provider>/<id>` for `rt.model`) *plus* the spec's headers. `h.scriptModel` scripts `rt.model`. Spans stay with the callers. (§19.0b) |
| O1 | Should `generate` on an approval-gated agent default to returning `error.ApprovalRequired`, or require `on_approval` at comptime? | **v1:** return the error. **v1.1:** superseded by D31 (it suspends). |
| O2 | Tool name default: snake_case of type name vs. explicit `name` required | **Implemented default:** derived, with `pub const name` override. |
| O3 | Should `z.Json` exist in v1 (an untyped escape hatch in schemas)? | **Implemented:** yes (`z.Json{ .raw = ... }`). Tools using it skip OpenAI strict mode. |
| D18 | Approval-gated agents inside workflow steps | **Superseded in v1.1 by D34.** **v1: compile error** when `w.agent(A)` or `z.step.agent(A, ...)` uses an agent that has any approval-gated tool (§6.4). The message names the tool and points at `Suspend`/`Resume` steps. **v1.1:** with persisted agent runs (D9), the step suspends the workflow instead. Rejected: auto-denying gated calls at runtime, which is silent and surprising. |
| D19 | Unknown model ID under a known provider | **Compile error** with did-you-mean and a hint to use `z.custom` (§5.4). Revisit based on user feedback; the alternative is to accept it with conservative capabilities and no pricing. |

---

## 14. Deferred (v1.1 / v2)

**v1.1** (everything deferred to v1.1 elsewhere in this plan, in one place; §17 orders it into releases and plans v1.1a in detail)

Agents and providers
- persisted agent runs while awaiting approval (D9); then approval-gated agents inside workflow steps suspend the workflow instead of being a compile error (D18)
- incremental structured-output streaming: `stream_parse` and `.output_partial` events (§5.15)
- OpenAI Responses API as a third dialect, so OpenAI reasoning items round-trip across tool steps (§6.2)
- nested tool-result blocks, if image results are needed (D25)

Workflows
- `z.step.loop` with a comptime- or runtime-bounded iteration count (§5.7)
- cancel sibling branches early when one parallel branch fails (§6.6)

Memory
- working-memory migrations; today a changed `T` resets to the default (§6.5)

MCP
- Streamable HTTP transport (§6.7)
- refresh tool lists on `notifications/tools/list_changed`; today they're fixed at `App.init` (§6.7)

Tracing and tooling
- OTLP exporter (§6.8)
- `dev serve`: HTTP + SSE over the dev CLI commands (§8)
- `z.testing.arbitrary(T)` plus fuzzing of tools (§3)

From the live test
- first-class reasoning control on agents (done in N1, §17.1). It used to be reachable only through `provider_options`. On 5.x models thinking is on by default with `display: "omitted"`, so `.reasoning_delta` never fired without `display: "summarized"`.
- `models-update` reads Anthropic capabilities from `GET /v1/models` when a key is available, instead of hand-copied flags (done in N1, §17.1)

Candidates, not committed
- client-side `pattern` enforcement; needs a small regex engine (D27)

**v2**
- `z.DynamicAgent` (runtime model string, instructions, tool subset, JSON-typed output; D2, D15), only if a use case appears
- semantic recall and a vector store interface (sqlite-vec first)
- RAG utilities
- evals runner (`z.eval(Agent, cases, scorers)` as test blocks; datasets via `@embedFile`, type-checked)
- Studio web UI on `dev serve`
- **MCP server export** (expose an App's agents and workflows as MCP tools)
- multi-language bindings from the manifest (TypeScript, Swift, Dart)
- an OpenAPI spec
- subagents
- more providers (Gemini, Bedrock)
- voice

---

## 15. References

- Mastra docs: https://mastra.ai/docs (feature surface and API shape to mirror)
- Mastra repo: https://github.com/mastra-ai/mastra
- Zig 0.16 `std.Io` overview: https://www.youngju.dev/blog/2026-07-16-zig-016-io-interface.en
- Zig cookbook, `std.Io`: https://cookbook.ziglang.cc/16-io/
- mcp.zig: https://muhammad-fiaz.github.io/mcp.zig
- MCP specification: https://modelcontextprotocol.io
- Anthropic Messages API (streaming, tool use, prompt caching): https://docs.claude.com
- OpenAI Chat Completions / structured outputs: https://platform.openai.com/docs

---

## 16. v1 status and verification (2026-10-14)

All milestones M0–M7 are implemented. What was verified, and how:

| Area | Verification |
|---|---|
| Schemas, constraints, validated parse (§5.1–5.3) | Unit tests; golden schemas for every sketch type in 4 dialects; fuzzed parser |
| Catalog (§5.4) | Generated from `tools/models-update/sources.json` (Anthropic: claude-api reference, cached 2026-10-06; OpenAI: pricing page and `GET /v1/models`, 2026-10-14) |
| Request prefix (§5.5) | Golden prefixes for the example's agents; tests that every request starts with the comptime prefix byte-for-byte |
| Size follows usage (§5.6) | `zig build size`: anthropic-only/memory **648 KB**, both providers + SQLite **1.51 MB**, everything **1.56 MB** (aarch64-linux-musl, ReleaseSmall, static); the anthropic-only binary contains no `provider.openai_compat` code. The full support example is **1.5 MB**, under the 2 MB stretch target. |
| Workflows (§5.7, §5.8) | Integration tests: the sketch's refund flow (suspend → persist → resume), the `otherwise` path with parallel + nested `needs` + an agent in a step, retries, failures as values, fingerprint mismatch, migration, resume after a process restart with SQLite; golden Mermaid |
| Compile-time checks (§7) | 117 compile-fail cases, each asserting its `zastra:` message |
| Providers (§6.2) | Replay tests for streaming text, thinking + signatures, tool use, redacted/opaque blocks, parallel tool calls, cached-token usage and error bodies on both providers. Live: TLS + request + error handling against api.anthropic.com and api.openai.com (401/429 paths, real diagnostics). |
| Agent loop (§6.4) | Harness tests: tool loop, ModelErrors, typed streaming events, approvals (approve/deny/pending/ApprovalRequired), parallel tools, native structured output + repair, final_answer fallback, history, working memory, D8 default |
| MCP (§6.7) | Against a real stdio server subprocess: discovery with pagination, allow-lists, schema validation, structured content |
| Dev CLI (§8) | All commands run against `examples/support`, including a live workflow run, `runs` and `trace` |
| C ABI (§9) | `zig build embed`: `embed.c` builds, links `libsupport`, and runs (with fake keys, exercising the error paths) |
| Cross-compile matrix (§10) | x86_64-linux-musl, aarch64-linux-musl, aarch64-macos, x86_64-windows all build |

**Live verification (2026-10-14, Anthropic):** passed. Covered:
- the dev CLI chat with the tool loop and the approval prompt
- native structured output (Sonnet 5.5) and the `final_answer` fallback
- a streamed tool loop with summarized thinking, its signatures sent back within the run
- history across runs with thinking blocks dropped (D30), with no 400
- prompt-cache reads on later steps
- `embed.c` streaming through the C ABI

It also found two bugs, both fixed:
- The catalog marked Opus 4.7, Opus 4.6 and Sonnet 4.6 as lacking native structured output; `GET /v1/models` says they have it.
- The dev CLI's "in" token count left out cached tokens.

**Not verified live:** OpenAI. The development key has no credits (`insufficient_quota`); the request, TLS and error paths were exercised.

**Known v1 limitations:** no incremental `output_partial` streaming (§5.15, v1.1); parallel workflow branches don't cancel siblings early (§6.6); `pattern` constraints aren't enforced client-side (D27); MCP tool lists are fixed at `App.init`. The full v1.1 list is in §14.

**After v1 (2026-10-14):** added the body idle timeout (§6.2), tested against a local server that sends one event and goes silent.

---

## 17. v1.1 plan

v1.1 ships in three releases. **v1.1a** (this section, in detail) fixes what production use needs first. **v1.1b** (developer experience) is planned in §18. **v1.1c** (tooling) is planned in §19.

| Release | Scope |
|---|---|
| v1.1a | Thinking control and catalog capabilities (N1), the OpenAI Responses API (N2), saved agent runs and approvals (N3), approval-gated agents in workflows (N4), an MCP client for the 2026-07-28 spec with Streamable HTTP (N5), release (N6) |
| v1.1b | `output_partial` streaming, `z.step.loop`, early sibling cancellation, working-memory migrations |
| v1.1c | OTLP exporter, `dev serve`, `z.testing.arbitrary` and tool fuzzing |

Out of v1.1: `z.DynamicAgent` (v2, only if a use case appears), nested tool-result blocks, client-side `pattern` enforcement, MCP OAuth (D38).

### 17.0 Before starting

- Tag `v1.0.0` on the current `main`.
- Push to a remote so CI runs at least once on Linux, macOS and Windows. Fix whatever it finds before N1.
- OpenAI credits are needed to verify N2 live. Without them N2 can be built but can't be released (§17.7).

### 17.1 N1: thinking control and catalog capabilities

**Problem.** Thinking is only reachable through `provider_options` today. Its defaults differ by model:
- Claude 5.x models think by default, but return no thinking text (`display: "omitted"`).
- Sonnet 4.6 doesn't think unless asked.
- Older models need `budget_tokens`.
- Some models can't turn thinking off: Opus 5.5 can't, and Sonnet 5.5 returns 400 on `disabled`.

**API (D37).** Two agent fields, next to the existing `.effort`. They're named "reasoning" to match `.reasoning_delta` and the message model:

```zig
pub const Planner = z.Agent(Ctx, .{
    .name = "planner",
    .model = "anthropic/claude-sonnet-5-5",
    .reasoning = .on,           // .default (send nothing) | .on | .off | .{ .budget = 8_000 }
    .show_reasoning = true,     // stream readable reasoning as .reasoning_delta
    .effort = .high,
});
```

Mapping is done at comptime from catalog capabilities:

| zastra | Anthropic | OpenAI Responses |
|---|---|---|
| `.default` | omit `thinking` | omit `reasoning.effort` |
| `.on` | `{type:"adaptive"}`; on budget-only models, a compile error asking for `.{ .budget = N }` | model default (reasoning models think) |
| `.off` | `{type:"disabled"}` where supported, else a compile error naming the model and suggesting `.effort = .low` | `reasoning.effort = "none"` where supported, else a compile error |
| `.{ .budget = N }` | `{type:"enabled", budget_tokens: N}` where supported, else a compile error; `N < max_tokens` is checked | compile error (no budgets) |
| `.show_reasoning = true` | `display: "summarized"` on models with `display` (4.7+); 4.6 and older return summaries anyway | `reasoning.summary = "auto"` |

**Catalog.** `Supports` gains `reasoning_modes` (`catalog.ReasoningModes`):
- `adaptive`, `budget` and `disable`: what the request accepts
- `disable_only_up_to_high`: turning it off is rejected at effort `xhigh` and `max`
- `default_on`: the model reasons when the request says nothing
- `visible`: readable reasoning can be streamed
- `display_param`: readability is opt-in through `display: "summarized"`

`.reasoning_delta` is in an agent's event union only when `.show_reasoning = true` (D26 style). Without it, reasoning text that arrives anyway (4.6 and older) is dropped; the blocks still go back to the provider within the run.

**Implemented (N1):**
- `catalog.ReasoningModes` per model: `adaptive`, `budget`, `disable`, `disable_only_up_to_high`, `default_on`, `visible`, `display_param`.
- 15 compile-fail cases.
- Golden prefixes for ten mappings (`tests/golden/prefix/reasoning_modes.txt`).
- A runtime check that a per-run `max_tokens` exceeds the budget.
- Scripted steps can carry reasoning: `.withReasoning("...", .text("..."))`.
- `zig build dev -- models` shows each model's reasoning modes.
- Did-you-mean ties now go to the candidate sharing the longest prefix (`.of` suggests `off`).
- Live (2026-10-15, requests captured by a logging proxy), each agent running a three-step tool loop: Sonnet 5.5 default and `.on` + `.effort = .high` with `.show_reasoning` (`adaptive` + `display: "summarized"`), Sonnet 4.6 `.on` (`adaptive`), Haiku 4.5 `.{ .budget = 2048 }` (`enabled`) all streamed `.reasoning_delta`, and each thinking block went back with its signature in the next step. Sonnet 5 `.off` at `.effort = .high` (`disabled`) streamed none. Adaptive models sometimes skip thinking on a step; then nothing is sent back. `models-update` against `GET /v1/models` found no drift.

**`models-update`.** With `ANTHROPIC_API_KEY` set, it reads `GET /v1/models` for:
- `structured_outputs`
- the thinking types
- `max_input_tokens` and `max_tokens`

It writes them over `sources.json`, prints a diff, and fails if a field disagrees with a hand-pinned value marked `"pin": true`. Pricing stays hand-maintained, since no API publishes it.

**Exit criteria:**
- Golden prefixes for each thinking mode on 4.6, 5.5 and an OpenAI reasoning model.
- Compile-fail cases for every compile error in the table.
- A live run with `.show_reasoning` on Sonnet 5.5 that produces `.reasoning_delta`.

### 17.2 N2: OpenAI Responses API (D35, D36)

**Problem.** Chat Completions doesn't return reasoning items, so OpenAI reasoning models lose their reasoning between tool steps. Responses is OpenAI's recommended API. Chat Completions stays supported.

**Live finding (2026-10-15).** On Chat Completions, gpt-5.4, gpt-5.4-mini, gpt-5.4-nano and gpt-5.5 reject function tools combined with `reasoning_effort` with a 400: "Function tools with reasoning_effort are not supported for {model} in /v1/chat/completions. To use function tools, use /v1/responses or set reasoning_effort to 'none'." gpt-5-mini and gpt-5.2 accept it. So in v1, an agent with `.tools` and `.effort` on a newer OpenAI model fails at runtime. N2 fixes this by moving catalog `openai/*` models to Responses. Everything else passed live on OpenAI: native and fallback structured output, and a streamed tool loop with memory across turns.

**Design:**
- **Dialect.** New file `provider/openai_responses.zig`, a third `api` alongside `anthropic` and `openai_compat`, behind the same `Impl` interface.
- **Which models use it.** Catalog `openai/*` models switch to it. `openai_compat` stays for `z.custom` third-party servers (Groq, OpenRouter, Ollama, vLLM). `z.custom(.{ .provider = .openai_responses, ... })` is allowed.
- **Prefix.** Comptime, in the same style:
  - `instructions` comes from the system prompt.
  - Tools are flat, `{type:"function", name, description, parameters, strict}`. Strict is on for zastra tools (openai dialect schemas) and off for MCP tools, whose schemas can't be made strict.
  - Structured output goes in `text.format = {type:"json_schema", name, schema, strict:true}`.
  - `store: false`, `stream: true`, and `parallel_tool_calls` from capabilities.
- **`prompt_cache_key`** is the agent id plus the prefix hash, so requests that share a prefix hit the same cache shard.
- **Messages map to input items:**
  - user and assistant text become `message` items
  - a tool use becomes a `function_call` with its `call_id`
  - a tool result becomes `function_call_output`
  - reasoning items (with `encrypted_content`) are `provider_opaque` blocks, passed back unchanged within a run
- **Across runs (D36),** reasoning items are dropped from loaded history, like D30. That is safe on every provider, and it costs only earlier turns' reasoning. Revisit once there's live evidence that keeping them works and helps.
- **Events.** `response.output_text.delta` becomes `.text`. Reasoning-summary text deltas become `.reasoning`. Function-call argument deltas accumulate per `item_id`. `response.completed` gives usage (cached input tokens, reasoning tokens counted as output) and the finish reason. `response.incomplete` maps to `max_tokens` or a content filter. `response.failed` and `error` events map to `ProviderError` with a diagnostic. The exact event and field names are pinned against recorded cassettes, not memory.
- **Size.** An OpenAI-only app now compiles the Responses dialect instead of Chat Completions. An app that uses both catalog OpenAI models and a `z.custom` compat server compiles both. Budgets are re-measured.

**Exit criteria:**
- Hand-written cassettes for text, tool loops, reasoning round-trip, structured output, refusal, incomplete and error, then replaced by recorded ones.
- Golden prefixes and the support example's tests passing.
- A live run on a catalog OpenAI reasoning model with a two-step tool loop, showing reasoning items sent back.

**Implemented (N2, 2026-10-15):**
- `provider/openai_responses.zig`; `catalog.Api.openai_responses`; the catalog's `openai` provider uses it. `z.custom(.{ .provider = .openai_responses })` defaults `base_url` to OpenAI.
- Reasoning items become `.reasoning` blocks: summary text as `text`, `encrypted_content` as `signature`, taken from `output_item.done` (the copy in `output_item.added` differs and doesn't round-trip). Blocks without encrypted content aren't sent. D36 falls out of D30's existing filter.
- Tools are always sent with an explicit `strict`, since Responses defaults it to true. `max_output_tokens` is clamped to the API's minimum of 16. `prompt_cache_key` is `zastra-<prefix hash>`. The working-memory suffix is a `developer` message.
- `catalog.ReasoningModes.xhigh_effort`. OpenAI `reasoning_modes` were probed live for every catalog model: gpt-5.1 to gpt-5.4 default to effort `none` (so `default_on = false`); gpt-5.1 and later except gpt-6-astra and gpt-6.1-sol accept `none`; gpt-5.2 and later accept `xhigh`; gpt-5, gpt-5-mini, gpt-5-nano, o3 and o4-mini accept neither.
- Cassettes recorded from the live API (text, tool step and its follow-up, summaries, structured output, incomplete, 400 error), trimmed; refusal and `response.failed` are hand-written, since neither could be triggered on demand.
- An agent test for D36 on OpenAI, 7 OpenAI golden prefixes, 2 new compile-fail cases (`.off` with `.effort`; `.show_reasoning` on a model that reasons only when asked). Fixed on the way: `z.custom(.{ .supports = .{ .reasoning_modes = .{...} } })` didn't compile.
- Live (gpt-5.4-mini through zastra, requests captured by a logging proxy): native and fallback structured output; a streamed three-step tool loop at `.effort = .medium` with `.show_reasoning`, where both steps' reasoning items went back and the next run's request had none; tools with `.effort` (the Chat Completions 400 above) now work; prompt caching reported 4096 and 2048 cached tokens on a longer prompt, including across runs.
- Size: `both_sqlite` 1,511,712 B, `full` 1,559,496 B (slightly smaller than with Chat Completions).

### 17.3 N3: saved agent runs and approvals (D9, D31–D33)

**API (D31).** An agent with approval-gated tools gets a two-armed result, mirroring workflows. Agents without gated tools keep the plain struct; that is D22, nothing changes for them.

```zig
const r = try rt.agent(Support).generate(arena, "Refund ORD-1042", .{ .thread = "t1" });
switch (r) {
    .completed => |c| print("{s}", .{c.text}),
    .suspended => |s| for (s.requests) |req| switch (req.call) {     // typed per tool, as today
        .issue_refund => |in| try queueForReview(s.run_id, req.id, in),
    },
}

// Later, in any process with the same storage:
const r2 = try rt.agent(Support).resumeRun(arena, run_id, &.{
    .{ .id = req_id, .decision = .approve },               // or .{ .deny = "over limit" }
});
// Streaming variant, e.g. a UI that reconnects:
var s = try rt.agent(Support).resumeStream(arena, run_id, decisions);
```

**Semantics:**
- `generate` no longer returns `error.ApprovalRequired`. It returns `.suspended` after saving a snapshot. `.on_approval` still decides inline and never suspends.
- In a live stream, `s.respond(id, decision)` is unchanged. `s.suspendRun()` saves the snapshot and returns the `Suspended` value, so a UI can stop waiting (D41).
- **Partial decisions (D33).** `resumeRun` with only some ids decided saves them and returns `.suspended` with the rest. An unknown id is `error.UnknownApproval`, with the pending ids in the diagnostic.
- **What a snapshot holds:**
  - the run's messages so far (including the assistant turn with the tool uses and its thinking blocks, which stay valid because the run continues)
  - each call's id, name, input JSON and decision
  - step, usage and `repair_used`
  - working memory and its dirty flag
  - `thread`, `resource`, `max_steps` and the trace id

  History is still appended once, when the run finishes.
- **Fingerprint.** It is the hash of the agent's prefix and its tool schemas. A mismatch on resume is `error.SnapshotIncompatible`, and the diagnostic names what changed. There are no migrations for agent runs; the remedy is to deny and restart.
- **Abandoning a run.** `rt.agent(A).cancelRun(run_id)` marks it `canceled`. Suspended runs never expire on their own; `dev runs --status suspended` lists them.

**Storage (D32).** Migration `0002`:
- renames `workflow_runs` to `runs`
- adds `kind` (`agent` | `workflow`)
- renames `workflow_id` to `owner_id`

The memory backend matches. The vtable gains `claimRun(run_id, from_status, to_status) !bool`, an atomic compare-and-set. It is a single `UPDATE ... WHERE status = ?` in SQLite. Every resume, for agents and workflows alike, claims the run first; losing the claim is `error.RunBusy`. This closes a v1 race where two resumes of one workflow run could both execute.

**C ABI (version 2):**
- `<lib>_agent_generate` can return `{"status":"suspended","run_id":...,"requests":[{"id","tool","input"}]}`.
- New `<lib>_agent_resume(app, agent_id, run_id, decisions_json, err)` and `<lib>_agent_resume_stream(...)`.
- `ZASTRA_ERR_APPROVAL_REQUIRED` is removed.
- `ZASTRA_ABI_VERSION` becomes 2; the manifest fingerprint already catches header/library mismatch.

**Dev CLI.** `chat` saves and exits on `s` at an approval prompt. `resume <run_id> <decisions>` handles agent runs. `runs` shows both kinds.

**Exit criteria:**
- Harness tests: suspend → restart (SQLite) → resume; partial decisions; deny; a double resume returning `RunBusy`; a fingerprint mismatch.
- A compile-fail for switching on `.suspended` for an agent without gated tools.
- `embed.c` covers suspend and resume.
- A live suspend/resume across two processes.

**Implemented (N3, 2026-10-15):**
- `run.Result(A)` / `RunResult(A)` / `Suspended(A)`, `ApprovalDecision`; `resumeRun`, `resumeStream` (re-emits pending `approval_request` events), `cancelRun` and `s.suspendRun()`. Calling the run methods on an agent without gated tools is a hand-written compile error.
- Snapshot: messages (with loaded history and `new_from`), each call's id and approval state (calls are rebuilt from the last assistant turn), step, usage, `repair_used`, working memory, thread, resource, `max_steps`, `max_tokens`, trace id. Once saved, a run's final status (`completed`, `failed`, `canceled`) is recorded too.
- Fingerprint: the request prefix hash, plus per-tool hashes in the snapshot so the diagnostic says "tool 'issue_refund' changed" (or added/removed, or "instructions, model or settings changed").
- Decision ids are all checked before the run is claimed, so `UnknownApproval` changes nothing. A run that is `running` reports `RunBusy`; finished ones `NotSuspended`.
- Storage: migration 0002 (verified on a real v1 database), `RunKind`, `RunFilter.kind`/`.owner_id`, `claimRun` on both backends; workflow `resumeStep` claims too (`error.RunBusy`).
- C ABI v2: suspended results, `_agent_resume`, `_agent_resume_stream`, `_agent_cancel`, `zastra_stream_suspend`; `APPROVAL_REQUIRED` (-5) retired.
- Dev CLI: `s` at a chat approval prompt saves and exits; `resume <run_id> approve | deny[:reason] | <json>` for agent runs; `runs` shows kind and owner.
- Tests: 6 harness tests (`tests/approval_test.zig`, including a SQLite restart that carries a thinking block's signature across it), the migration on a v1-shaped table, `claimRun`, 2 compile-fail cases. `embed.c` suspends and resumes when keys are real; CI exercises its error paths with fake keys.
- Live (gpt-5.4-mini, SQLite): process 1 looked the order up and suspended at `issue_refund`; process 2 approved, the refund ran once and the run completed (3 steps); a second resume got `NotSuspended`.

### 17.4 N4: approval-gated agents in workflows (D34; supersedes the D18 compile error)

**`z.step.agent(A, ...)`** with a gated agent becomes a suspendable step automatically:
- `Suspend = z.Approvals(A)` (the run id is internal; this holds the typed requests)
- `Resume = z.Decisions(A)`

The workflow's `Suspended` union gets the arm, and the C header and manifest describe it.

```zig
.then(z.step.agent(Support, .{ .input = Ticket, .prompt = "..." }))
// ...
.suspended => |s| switch (s.at) {
    .support => |approvals| for (approvals.requests) |req| ...,
},
_ = try rt.workflow(HandleTicket).resumeStep(z.step.agentOf(Support), arena, run_id, decisions);
```

**Custom steps.** A step declares `pub const Suspend = z.Approvals(A); pub const Resume = z.Decisions(A);` and calls `w.agent(A).run(input, opts)`. That returns `union { done: Result, suspended: z.Approvals(A) }`, and the step returns `.{ .suspended = a }`. On resume, the replayed step (D24) calls `w.agent(A).run` again. zastra sees the agent run already saved under the deterministic id `<wf_run_id>/<step_path>#<n>` and resumes it with `w.resumed`, so the step code has no resume branch.

`w.agent(A).generate` on a gated agent stays a compile error, now pointing at `.run` and the two declarations.

**Still a compile error:** a gated agent inside `z.step.parallel`, because parallel branches can't suspend (§6.6).

**Fingerprint.** The step's agent fingerprint (N3) is folded into the workflow fingerprint, so changing a gated agent's tools invalidates old snapshots instead of failing later.

**Exit criteria:**
- The sketch's refund flow rewritten with a gated agent step and no hand-written Approve step: suspend, restart, resume.
- A custom step with two gated agent calls.
- Compile-fail cases for the remaining D18 cases.
- Golden Mermaid shows the suspend point.

**Implemented (N4, 2026-10-15):**
- `z.Approvals(A)` (typed `requests`), `z.Decisions(A)` = `.{ .approve = &.{id}, .deny = &.{.{ .id, .reason }} }` (one shared struct, so it serializes to JSON and C as-is), `z.step.agentOf(A)` for `resumeStep`.
- `w.agent(A).run(...)` saves each call as an agent run with id `<wf_run_id>/<step_path>#<n>` and `keep_result`, so a finished call's result is stored with it. On replay, finished calls return their stored result without a model request or tool execution; the first suspended call gets the step's decisions (`w.resumed`) and continues; later calls run normally.
- Approvals of a step left undecided keep the workflow suspended with the same requests. Resuming a workflow run that another process is resuming is `error.RunBusy`.
- The gated agent's `run_fingerprint` is folded into the workflow fingerprint.
- Compile errors: `w.agent(A).generate` on a gated agent (points at `.run` and the declarations), `.run` without the declarations, `.run` on an ungated agent, `z.Approvals` of an ungated agent, a gated agent step inside `z.step.parallel`.
- The sketch and the support example: `Refunder` agent plus `Refund = z.step.agent(Refunder, ...)` replace `FetchOrder → ApproveRefund` in the refund path; their test suspends, reopens the SQLite file in a second harness, and resumes with `z.step.agentOf(Refunder)`. Golden Mermaid shows `refunder ⏸`; the header has `SUPPORT_REFUNDER_RESUME_SCHEMA`.
- Tests (`tests/workflow_approval_test.zig`): restart and resume, an undecided resume, deny, two gated calls in one custom step (the first isn't repeated), `RunBusy`, the fingerprint fold.

### 17.5 N5: MCP client for the 2026-07-28 spec (D38–D40)

**Problem.** The MCP 2026-07-28 revision makes the protocol stateless:
- There is no `initialize` handshake. Every request carries `_meta` with `io.modelcontextprotocol/protocolVersion`, `clientCapabilities` and `clientInfo`.
- `server/discover` is new.
- Results carry `resultType`.
- Server-to-client requests become `InputRequiredResult` (MRTR).
- List changes arrive on a `subscriptions/listen` stream.
- Lists carry `ttlMs`.

Streamable HTTP drops sessions, the GET stream and resumability. It adds the `Mcp-Method` and `Mcp-Name` headers and `x-mcp-header` parameter mirroring. Today's client speaks only the legacy `initialize` era over stdio.

**Declarations (D38):**

```zig
.mcp = .{
    .docs = z.mcp.stdio(&.{"docs-mcp-server"}),
    .linear = z.mcp.http("https://mcp.linear.app/mcp", .{
        .bearer_env = "LINEAR_MCP_TOKEN",            // Authorization: Bearer <env value>, checked at App.init
        .headers = &.{.{ "X-Team", "acme" }},
    }),
},
```

The transport is chosen at comptime, so an App with only stdio servers compiles no MCP HTTP code (§5.6).

**Dual-era client** (per the spec's compatibility rules):
- **stdio.** Probe with `server/discover`. On a non-modern error or a 5 s timeout, fall back to `initialize` (2025-11-25).
- **HTTP.** Send a modern request first. On a 4xx without a recognized modern error body, fall back to `initialize` and the 2025-11-25 Streamable HTTP rules: `Mcp-Session-Id` and DELETE on shutdown. The deprecated 2024-11-05 HTTP+SSE transport isn't supported; the diagnostic says so.
- The era is cached per server for the App's lifetime.
- **Requests.**
  - Modern requests mirror `MCP-Protocol-Version`, `Mcp-Method` and `Mcp-Name` (Base64 sentinel encoding where needed).
  - `x-mcp-header` parameters go out as `Mcp-Param-*`. Tools whose annotations are invalid are excluded with a warning, as the spec requires.
  - Both `application/json` and per-request SSE responses are read, the latter with the §6.2 idle timeout.
- **No client features.** zastra advertises no sampling, elicitation or roots. An `InputRequiredResult` becomes a tool error for the model ("the server needs input zastra can't provide: ...") and is logged.
- **Auth.** Static headers and a bearer token from the environment only. A 401 with `WWW-Authenticate` gets a diagnostic naming the server and the env var. The OAuth 2.1 flow (protected-resource discovery, PKCE, client ID metadata documents) needs a browser and token storage, so it's deferred. A later `.token = fn (ctx) ![]const u8` hook lets apps supply tokens from their own OAuth.

**Tool list refresh (D39):**
- **Sources.** Modern servers that advertise `listChanged` get a `subscriptions/listen` stream (`toolsListChanged`), run as a background `io.concurrent` task. Legacy stdio and session HTTP use `notifications/tools/list_changed`. Lists are also re-fetched after `ttlMs`, read lazily at run start.
- **When it applies.** A refresh rebuilds the affected agents' runtime prefixes (MCP tools are inserted at `tools_insert_at`). It applies at the **next run start**; a running agent keeps its tool list for its whole run. Old prefixes are freed at `App.deinit`; that is bounded, one per change.
- **Caching.** Tools are sorted by name so unchanged lists produce byte-identical prefixes and keep the prompt cache.

**Schemas (D40).** The 2026-07-28 revision allows any JSON Schema 2020-12 keywords. The validator adds:
- local `$ref` / `$defs`
- `allOf`
- `if`/`then`/`else`
- `prefixItems`

It has bounds: depth 64 and 10k nodes visited per validation. Unknown keywords stay ignored (permissive). A schema the validator can't handle doesn't block the tool; only argument validation is skipped, with a warning at init.

**Tests.** `tests/fake_mcp_server.zig` gains three modes: `--modern` (stdio, `server/discover`), `--http` (an in-process `std.Io.net` server) and `--legacy-http` (sessions). Tests cover:
- era detection both ways
- header mirroring, including Base64 and `x-mcp-header` rejection
- SSE responses and `InputRequiredResult`
- list refresh via the listen stream and via `ttlMs`
- a 401 diagnostic

**Exit criteria:**
- All of the above pass.
- The support example adds an HTTP server.
- A live check against one public modern MCP server and one legacy server.

**Implemented (N5, 2026-10-15):**
- `src/mcp/protocol.zig` (framing for both eras, reply classification, header value encoding with the Base64 sentinel, `x-mcp-header` validation and extraction), `stdio.zig` (a background reader routes replies by id; `server/discover` probe with a 5 s timeout, `App.init(.{ .mcp = .{ .probe_timeout_ms } })`), `streamable.zig` (modern POSTs with mirrored headers, JSON or SSE replies, a `subscriptions/listen` task; legacy `initialize`, `Mcp-Session-Id` and DELETE), and the manager, generic over the declared transports.
- `z.mcp.http(url, .{ .bearer_env, .headers, .url_env, .optional })`. `url_env` overrides the URL at init (per deploy; tests use it for random ports). `optional` (D42) starts the App without an unreachable server's tools, so the support example and its CI don't need the server running. Bearer env vars join the App's required environment.
- `InputRequiredResult`: with `inputRequests`, a tool error naming the requested methods (and a log line); with only `requestState`, retried up to three times. `HeaderMismatch` re-lists the server's tools at the next run. Unrecognized `resultType` is an error; a missing one means `complete`.
- Refresh (D39): the manager rebuilds an agent's prefix only when a server's tool generation changed; runs take their prefix at start (`Stream.prefix`), so a run keeps its list. Old prefixes are freed at deinit.
- Validator (D40): local `$ref`/`$defs`/`definitions`, `allOf`, `if`/`then`/`else`, `prefixItems`, `false` schemas; depth 64 and 10k nodes, past which arguments are accepted; `supported()` skips validation (with a warning) for remote `$ref` or `$dynamicRef`.
- The HTTP client gained response headers, other methods (DELETE) and per-request idle timeout and retries. Fixed on the way: a double free of the HTTP client when `App.init` failed after MCP startup; the harness now works outside tests (it only falls back to `std.testing` there).
- Size: MCP HTTP code is absent from stdio-only Apps (checked in the `full` binary). `full` is 1,594,200 B (+29 KB, the stdio reader, protocol and validator).
- Tests: the fake stdio server gained `--modern` and `--silent-probe`; `tests/fake_mcp_http.zig` is an in-process HTTP server (modern, legacy sessions, 401). Covered: era detection both ways on both transports, the Base64 and `x-mcp-header` rules (unit tests use the spec's own examples), an invalid annotation excluding a tool, SSE replies with interleaved notifications, both `InputRequiredResult` shapes, refresh via the listen stream on both transports, legacy session id and DELETE, the 401 diagnostic. The support example adds `status-mcp-server` (Streamable HTTP, `x-mcp-header`) and a test that runs it.
- Live (no API key: a scripted model drives real MCP calls): Cloudflare docs (2026-07-28, `listChanged`, `ttlMs: 0`), Context7 (2026-07-28, no `resultType`) and DeepWiki (2025-11-25 sessions; it rejects the probe with `-32600`) together: all 7 tools discovered and sorted, one call to each succeeded; `App.init` took 1.2 s.
- Not done: the legacy GET stream, so legacy HTTP servers' list changes are only seen when they arrive on a response stream.

### 17.6 N6: release v1.1.0

- Update `sketch/` and the docs for every API change above, in the same commits as the code (CLAUDE.md).
- Re-measure size budgets. Target: anthropic-only + memory stays under 700 KB; the full example stays under 2 MB.
- Compile time stays within 25% of v1's. Measured 2026-10-15 with fresh caches on one machine: HEAD 27 s, v1.0.0 28 s (with only the local cache fresh: 26 s vs 24 s, +8%). A fixed baseline in seconds failed CI on slower runners (52 s), so CI now builds v1.0.0 on the same runner and compares.
- CI green on all four targets.
- Live runs on both providers.
- Write a CHANGELOG with the breaking changes: the gated-agent result union, C ABI v2, the storage migration, and catalog OpenAI models moving to Responses.
- Tag `v1.1.0`.

**Done (N6, 2026-10-15):** CI green on all targets (3b4ad27); compile time +7% vs v1.0.0 on the same runner; size budgets pass (anthropic-only 657 KB, full 1.59 MB); live runs: OpenAI (structured output, tool loops with reasoning, two-process suspend/resume) and MCP (three public servers) on the release code, Anthropic on dc12eb9 (`anthropic.zig` unchanged since; the shared HTTP client and run loop were exercised live through OpenAI and MCP); CHANGELOG written; tagged `v1.1.0`. Also fixed during N6: a Windows build error (stdio MCP shutdown) and MCP test servers that hung on small CI runners.

### 17.7 Order, dependencies and risks

Order: N1, then N2, then N3, then N4, then N5.
- N2 needs N1's catalog capabilities for reasoning settings.
- N4 needs N3.
- N5 is independent and could run in parallel, but goes last because it's the largest and the spec is newest.

| Risk | Mitigation |
|---|---|
| No OpenAI credits: N2 can't be verified live | Build against hand-written cassettes from the API reference; block the release, not the work, on a live run |
| Responses event details differ from the docs | Pin with recorded cassettes (`.http.record_dir`) as soon as credits exist; the parser ignores unknown events |
| Third-party servers are slow to adopt the 2026-07-28 MCP spec | The dual-era fallback is part of N5's scope, not an extra |
| Breaking changes in a minor release | Pre-1.0-adoption project; each break is a compile error with a `zastra:` message pointing at the fix, never a silent change |
| `claimRun` semantics on the memory backend | A mutex-guarded compare-and-set; the same tests run against both backends |
| Prefix rebuild on MCP refresh breaks prompt caching | Sorted tools; refresh only between runs; a trace attribute when a prefix changes |

---

## 18. v1.1b plan (developer experience; release v1.2.0)

v1.1b is the four developer-experience items from §17's table. It changes no wire formats and no storage schema. The one behavior change is in parallel failure (N7). It ships as **v1.2.0**: v1.1a was tagged v1.1.0, and these are new features, so they take a minor version.

| Milestone | Scope | Size |
|---|---|---|
| N7 | Early sibling cancellation in `z.step.parallel`, and a fix for its shared-state race | small |
| N8 | Working-memory migrations | small |
| N9 | `z.step.loop` | large |
| N10 | `.output_partial` streaming | large |
| N11 | Release v1.2.0 | small |

### 18.1 N7: early sibling cancellation (D47)

**Problem.**
- When one branch of `z.step.parallel` fails, the step still waits for every other branch to finish. A failed lookup waits on a slow agent call that will be thrown away.
- **v1 race, found while planning this:** a failing branch calls `x.fail`, which writes `failed_step`/`failed_err`/`failed_msg` and allocates from the run's arena. Two branches failing at once race on those fields and on the arena, which isn't thread-safe. Branches also share `x.st.diag`.

**Change.**
- Branches start with `Group.concurrent`. If concurrency isn't available, they fall back to `Group.async`, which runs a branch inline on small machines. The first branch failure cancels the group (`group.cancel`).
- Branches observe cancellation at `std.Io` cancellation points: HTTP reads, sleeps (retry backoff) and storage. A canceled branch ends with `error.Canceled`. It is never reported as the step's failure.
- The step fails with the **earliest** real failure in time, not the first in declaration order. The other branches are recorded as canceled in the trace (`canceled_by = <branch>`).
- Each branch's failure goes into its own slot: step id, error, message (allocated in the slot's arena) and a diagnostic copy. Only the joining code calls `x.fail`, after `await`. Branches no longer touch `X` or `x.st.diag` directly; the diagnostic becomes per-branch.
- No opt-out flag. Waiting for every branch to finish has no use once the step's result is already a failure.

**Exit criteria:**
- With a fast failing branch and a slow branch (a scripted model that sleeps 5 s), the step fails in under 1 s, and the slow branch's span is marked canceled.
- Two branches failing at the same moment: no data race (run under the thread sanitizer on Linux), and exactly one is reported.
- Tests pass with the async limit forced to 1 (the inline path), as the MCP tests do.
- CHANGELOG notes the reporting change (earliest failure instead of declaration order).

**Implemented (N7, 2026-10-15):**
- Branches start with `Group.concurrent`. When concurrency is unavailable, they run inline and the remaining branches are skipped after a failure. A shared join (mutex, event, remaining count, first failure) wakes the joiner on the first failure or the last finish. The joiner then calls `group.cancel` or `group.await`.
- Each branch runs on a copy of `X` with its own arena, so `x.fail` writes only to that branch's slot. The joiner copies the winning failure into the run, duplicating the message into the run's arena.
- Errors from a branch canceled by a sibling are ignored.
- `error.Canceled` is never retried. Without this, a canceled step under `z.Retry` re-ran: Io reports cancellation once.
- The diagnostic is read under its mutex (`State.diagCopy`). It stays App-wide, not per branch: per-branch diagnostics would need agent API changes for little gain, since only the winning branch's message is reported.
- Not done: a `canceled_by` trace attribute. Canceled branches' spans fail with `Canceled`, which is enough.
- Tests (`tests/workflow_test.zig`): a fast failure cancels a 5 s sibling (the run takes under 1 s, and the sibling never finishes); the earliest failure wins over the first declared; simultaneous failures report exactly one. The same tests run with `concurrent_limit = .nothing` (inline).
- The integration suite passes under ThreadSanitizer on macOS (`sanitize_thread` set temporarily in `build.zig`). The v1 runner failed the new tests, but ThreadSanitizer didn't report its race in that run, so the race fix rests on the code change, not on a sanitizer finding.

### 18.2 N8: working-memory migrations (D48)

**Problem.** Today, when `T` in `.memory.working = T` changes shape, every customer's stored notes reset to the default and a warning is logged. Adding a field to a struct shouldn't throw away what the agent learned.

**API.** Migrations are declared on the working-memory type itself. Unlike committed workflows (D23), `T` is a user type and can carry declarations. They are typed, not hex fingerprints plus JSON:

```zig
const NotesV1 = struct { name: ?[]const u8 = null, contact: ?[]const u8 = null };

pub const CustomerNotes = struct {
    name: ?[]const u8 = null,
    preferred_contact: ?Contact = null,
    open_issues: []const []const u8 = &.{},

    pub const Contact = enum { email, sms };
    pub const migrations = .{
        z.migrate(NotesV1, fromV1),
    };
    fn fromV1(arena: std.mem.Allocator, old: NotesV1) !CustomerNotes {
        _ = arena;
        const contact = if (old.contact) |c| std.meta.stringToEnum(Contact, c) else null;
        return .{ .name = old.name, .preferred_contact = contact };
    }
};
```

- `z.migrate(Old, f)` records `fingerprint(Old)` at comptime, plus a wrapper that parses `Old` and calls `f`. `f` is `fn (Allocator, Old) !New`, where `New` is the next version.
- **Chains:**
  - The newest type lists every step: `z.migrate(V1, v1ToV2)`, `z.migrate(V2, v2ToV3)`.
  - Each step's output must be the input of the next step, or `T` for the last one. This is checked at comptime, with a `zastra:` error naming the broken link.
  - On load, zastra finds the stored fingerprint in the chain and applies every step from there.
- **Default without a matching migration:** unchanged from v1. The value resets to the default, with a warning that now says "add `z.migrate(<old shape>, ...)` to keep it".
- **Failed migration:** a migration function that returns an error fails the run with `error.MigrationFailed` and a diagnostic. It does not silently reset: data loss should be loud once the user has asked for a migration.
- A migrated value is saved back, with the new fingerprint, at the next working-memory save. A read-only run doesn't save. Migrated values are not written eagerly.

**Saved agent runs (N3).** A suspended run's snapshot stores `working_json`, and `run_fingerprint` covers `T`, so changing `T` currently makes old suspended runs fail with `SnapshotIncompatible`. N8 applies the same chain during `restore` before checking the remaining fingerprint. To make that possible, `run_fingerprint` is split into a working-memory part and the rest. Workflow snapshots don't contain working memory, so they're unaffected.

**Exit criteria:**
- V1 → V2 → V3 chain test on both storage backends; the migrated value is saved with V3's fingerprint.
- A failing migration surfaces as `MigrationFailed`.
- A suspended agent run saved under V1 resumes under V3.
- Compile-fail cases:
  - a broken chain (an output type that doesn't match the next input)
  - a migration whose `Old` has the same fingerprint as `T`
  - a non-function second argument
  - `migrations` that isn't a tuple
- Sketch: `CustomerNotes` gains one migration; the support example has a test that loads V1 notes.

**Implemented (N8, 2026-10-15):**
- `src/schema/migrate.zig`: `z.migrate(Old, f)` returns a type recording `From`, `To` and `fingerprint.of(Old)`. `check` validates the chain when the agent is declared. `run` parses the stored JSON as the matching `From` and carries the value through the remaining steps, each typed.
- **Load:** a migrated value marks working memory dirty, so it's saved with the new fingerprint when the run ends. This replaces "read-only runs don't save": migrating once and storing the result is simpler than migrating on every load.
- **Old JSON that doesn't parse** as the shape it claims is logged and reset, like a current-shape parse failure. Only an error returned by `f` fails the run.
- **Saved runs:**
  - Every agent with working memory has `run_core_fingerprint`: the prefix hash with the working-memory tool's schema left out. It's computed for every such agent because the version that saves a run usually has no migrations yet.
  - Snapshots record it, plus the working-memory fingerprint, as hex.
  - `resumeRun` accepts a run whose full fingerprint differs when the core matches and the saved working-memory shape is in the chain. `restore` then migrates `working_json`.
  - v1.1.0 snapshots lack these fields, so they still need an exact match.
- New error `MigrationFailed` in the agent run error set.
- Tests (`tests/memory_migration_test.zig`):
  - V1 → V2 → V3 and V2 → V3 on both backends, each saved back with V3's fingerprint
  - a failing migration leaves the stored value untouched
  - an unknown fingerprint resets
  - a run suspended under V1 (sqlite) resumes under V3 with the migrated value in the request
- Compile-fail cases: a broken chain, the same shape as `T`, a non-function, migrations that aren't a tuple.
- The support example and the sketch: `CustomerNotes` migrates from `CustomerNotesV1` (string contact to enum), with an example test.

### 18.3 N9: `z.step.loop` (D45, D46)

**API.**

```zig
.then(z.step.loop(Refine, .{ .until = goodEnough, .max = 5 }))
.then(z.step.loop(Refine, .{ .until = goodEnough, .max = 5, .on_limit = .finish }))
```

- `Body` is a step or a committed workflow with `Input == Output` (`T → T`). The loop's Input and Output are `T`. Anything else is a compile error that shows both types and suggests wrapping the body in a workflow with an adapter step.
- `.until: fn (T) bool` is checked after each iteration; the loop is do-until, so the body always runs at least once. Like branch predicates (D24), it must be pure.
- `.max: comptime_int` is required. An unbounded loop isn't expressible, so every run terminates. A runtime bound is expressed in `.until` (for example, by carrying a counter in `T`).
- `.on_limit = .fail` (the default) fails the run with `error.LoopLimit` and names the loop. `.finish` returns the last value instead.
- One iteration counts as one execution of the body, including that body's own retries.

**What a body may contain.** Any step: agents, gated agents, suspendable steps, nested workflows, parallel groups and branches. A loop can't be a branch of `z.step.parallel` (same rule as nested workflows, §6.6). Loops can nest.

**State and resume (D46).**
- The loop's slot in `W.State` is `{ iter: u32, value: ?T }`: the number of finished iterations and the latest value.
- The body's own step slots hold only the current iteration's state. They are cleared when an iteration finishes, and that clear goes into the same snapshot save that advances `iter`, so the change is atomic.
- Replay (D24) runs in two stages. Reaching the loop, the runner uses the stored `value` as the iteration's input and continues at `iter`. Inside the body, finished steps are skipped as usual.
- A suspend inside iteration k resumes inside iteration k.

**Ids that must differ per iteration.**
- Step paths are comptime strings today; iterations need a runtime part.
- The runner keeps an iteration stack for nested loops and appends it to:
  - saved agent-run ids: `<run>/<path>@<i>#<n>` instead of `<run>/<path>#<n>`. Without this, iteration 2 would resume iteration 1's finished agent run (N4).
  - the default agent thread `"<run_id>/<step_id>"`: deliberately **not** extended. A looping agent should see its earlier iterations' history, which is what refine loops want. The `thread` option still overrides it.
  - trace span names: the `iteration` attribute.
- `suspended_at` stays the comptime path, and the iteration lives in the state. `resumeStep(S, ...)` works unchanged.

**`needs`.**
- Steps inside the body may need steps that dominate the loop, and steps earlier in the same iteration.
- Steps after the loop may need the loop, but not steps inside its body: their slots are cleared. That is a compile error naming the loop and suggesting carrying the value in `T`.

**Fingerprint and Mermaid.**
- The loop and its body are part of the shape. `.max`, `.until` and `.on_limit` are not, so tuning them keeps snapshots valid.
- Mermaid draws the body as a subgraph with a back edge labeled `until goodEnough (max 5)`.

**Exit criteria:**
- A refine loop with an agent step that ends by `until`; one that hits `.max` with each `on_limit` value.
- A gated agent inside the loop: suspend in iteration 2, restart the process, resume. Iteration 1's agent run is not replayed into iteration 2.
- Crash recovery mid-iteration: a test that kills after a body step's save.
- A nested loop, and a parallel group inside a loop body.
- Compile-fail cases:
  - Input ≠ Output
  - a missing `.max`
  - `.max = 0`
  - a loop inside parallel
  - `needs` on a body step from after the loop
  - an `until` with the wrong signature
- Golden Mermaid for a loop; a fingerprint test showing that `.max` doesn't change it.
- Sketch and the support example: `DraftReply` becomes a loop over draft → critique with `.max = 3`.

**Implemented (N9, 2026-10-15):**
- `z.step.loop(Body, .{ .until, .max, .on_limit, .name })` returns a step-like type: `zastra_loop`, `body`, `until`, `max`, `limit`, and `Progress = struct { iter, value }`. The default id is `loop_<body id>`.
- **Analysis:** the body is analyzed under the loop's path. The loop adds two slots: `<path>#` (`Progress`) and `<path>` (`Done(Output)`). The shape is `loop(<path>:<body shape>)`.
- **`needs`:** a step that needs a body step from outside the loop is a compile error naming the loop.
- **Runner (`execLoop`):**
  - Reads the progress slot, then checks `until` and the limit before every iteration after the first.
  - Runs the body through `execStep`.
  - Then clears every slot under `<path>.`, writes progress and saves once.
  - Checking `until` at the top means a replay after a crash between the body's save and the progress save neither repeats the body nor runs an extra iteration.
- **Iteration ids:**
  - `X.iteration` holds `"@i"` per loop level and is copied into `StepCtx.iteration`.
  - Saved agent-run ids are `<run>/<path>@<i>#<n>`.
  - Step spans get an `iteration` attribute. The default agent thread is unchanged.
- **Mermaid:** the body sits in a subgraph with a dashed `repeat, max N` back edge. The predicate's name isn't available at comptime, so the label doesn't include it.
- **Tests (`tests/workflow_loop_test.zig`):**
  - `until` ends the loop; the limit fails or finishes
  - an agent step inside a loop
  - a gated agent that finishes in iteration 1 and suspends in iteration 2, then resumes after a restart; a mutation check confirms iteration 1's run isn't reused without the `@i` suffix
  - a workflow body with a nested loop, a parallel group and a suspend mid-iteration, where steps before the suspend point don't re-run
  - Mermaid and fingerprint stability under changes to `.max`, `.until` and `.on_limit`
  - Crash recovery between the two saves: zastra has no API that recovers a crashed `running` run (resuming one reports `RunBusy`), so there is no process to kill and restart. The test (v1.2.1) instead rewrites a suspended snapshot into the state such a crash leaves (every body step saved, progress not advanced) and resumes it: the replayed iteration's steps don't re-run, and the loop runs exactly one more iteration.
- Compile-fail cases: Input ≠ Output, a missing `.max`, `.max = 0`, a wrong `until` signature, a loop inside parallel, `needs` on a body step from after the loop.
- **The support example and the sketch:**
  - `DraftReply` now produces a `Draft`.
  - `Polish = z.step.loop(ReviseReply, .{ .until = approved, .max = 3, .on_limit = .finish })` runs a new `ReplyCritic` agent and revises with `ReplyWriter`.
  - `Answer` turns the `Draft` into a `Resolution`.
  - The example test scripts one rejection and one approval.
  - Goldens updated (Mermaid, manifest, header).

### 18.4 N10: `.output_partial` streaming (D43, D44)

**API.**
- `z.Agent(Ctx, .{ .output = Triage, .partial_output = true })` adds `.output_partial: z.Partial(Triage)` to the agent's `Event` union.
- **Opt-in:** without the flag, neither the event arm nor the incremental parser is compiled (§5.6). Asking for it without `.output` is a compile error.
- Each event carries the whole partial value so far, not a diff. UIs re-render it, and dropping events loses nothing.
- Events fire when a top-level field's value completes, or when a nested struct's field completes. Arrays grow by completed elements.
- **Strings:** a field listed in `pub const stream_strings = .{ .summary }` on the output type also fires as its string grows (§5.15). Without that, strings appear only once complete.
- Enums, numbers and bools appear only once complete, so they're never shown truncated.
- The final `Result.output` is unchanged: validated, with one repair attempt. Partial values are **unvalidated**, and the docs say so. If a repair happens, the partial stream restarts: a second run of partial events follows a `.output_partial_reset` marker. That marker is the only extra event arm.

**Where the JSON comes from.**
- **Native structured output:** the text deltas. `.text_delta` still fires with the raw JSON, so existing code doesn't change.
- **Forced `final_answer` tool:** `tool_call_args` deltas whose `tool_call_start` named `final_answer`. Every provider already emits those deltas: Anthropic `input_json_delta`, Responses `function_call_arguments.delta`, Chat Completions `tool_calls[].function.arguments`.

**Parser (D44).** The parser isn't a full incremental JSON parser.
- A small byte-level scanner keeps depth, in-string and escape state: O(1) per byte, O(n) per stream. It reports boundaries:
  - a value ended at depth 1 or 2
  - a growing string for `stream_strings` fields, throttled to at most one event per 64 bytes or per delta chunk, whichever is larger
- At a boundary, zastra takes the buffered prefix, closes it (drops the dangling key or token, then closes the open string, arrays and objects) and parses it leniently into `Partial(T)`: missing fields become null, and fields that fail to parse are left null rather than failing the event.
- Cost: O(boundaries × n). The outputs this is for are a few KB with tens of fields.
- `z.Partial` gains: arrays of structs become `[]const Partial(Elem)`, and the last element is included only once complete. Today `Partial` recurses into structs only; working memory keeps using it and isn't affected by array elements.

**C ABI and dev CLI.**
- The stream emits `{"type":"output_partial","value":{...}}` and `{"type":"output_partial_reset"}`.
- The manifest records `partial_output`.
- `dev run` re-renders the partial output in place on a TTY and prints only the final value otherwise.

**Exit criteria:**
- Cassette tests for all three dialects in both modes (native and `final_answer`). Each asserts the sequence of partial values, including a nested struct, an array of structs and a `stream_strings` field.
- A repair cassette shows the reset.
- Property test: for every prefix of N recorded outputs, the closed prefix parses (no `ProtocolError`) and each partial value is a field-wise prefix of the final value.
- Size: the anthropic-only + memory example without `.partial_output` is byte-identical before and after. With it, the cost is recorded in N11.
- One live run per provider showing partial events from a real stream.
- Compile-fail cases: `.partial_output` without `.output`; `stream_strings` naming a missing field or a non-string field.

**Implemented (N10, 2026-10-15):**
- `src/schema/stream_parse.zig`: `Parser(T)` (the scanner, boundaries, closing, `lenient`) and `streamStrings(T)` (comptime checks).
  - Boundaries are values ending at depth 1 or 2. Below that, every open container holds only complete values, so closing the prefix never invents a value.
  - One event per delta at most. A streamed string emits once it has grown by 64 bytes, cut at a character boundary (escapes, `\u` sequences and UTF-8).
  - Values live in a scratch arena that is reset at the next emission, so an event lasts until the next `next()`.
- **Changed from the plan:** `z.Partial` is unchanged. Arrays hold only complete elements, so their element type stays `Elem`, and working memory is unaffected.
- **Agent:**
  - `.partial_output = true` adds `output_partial: z.Partial(Output)` and `output_partial_reset: void`.
  - The run's partial state is one field, void without the flag. Separate void fields cost 40 bytes in the anthropic-only binary; one field is byte-identical (656,904 B).
  - `generate` turns partial parsing off.
  - Native mode feeds text deltas. Fallback mode feeds `tool_call_args` for the `final_answer` call's index.
  - When a new turn starts after partial values that didn't become the output (a repair, a retried `final_answer`, JSON before tool calls), it first emits `output_partial_reset`.
- **Bug fixed on the way:** the Chat Completions stream returned only the first event of a chunk. A chunk that started a tool call and carried its first arguments lost those argument bytes from the event stream (the final message was always complete). Every event of a chunk is now queued.
- **Scripted models:** `.chunked(n, step)` streams text and tool arguments in `n`-byte deltas on all three APIs.
- **C ABI:** `ZASTRA_EVENT_OUTPUT_PARTIAL = 7` (JSON) and `ZASTRA_EVENT_OUTPUT_PARTIAL_RESET = 8` (`{}`). The ABI version is unchanged because the change is additive. The manifest has `"partial_output":true`.
- `dev run` doesn't render partial values. Native mode already shows the JSON as text deltas, and in-place TTY rendering wasn't worth its code.
- **Tests:**
  - Unit tests: field order, nested structs, arrays, `stream_strings` growth, escapes and multibyte characters split at every chunk size from 1 to 7, every prefix of an output stays parseable, non-JSON text.
  - `tests/partial_output_test.zig`: all six combinations of API and mode, with field-wise prefix checks, the last partial equal to the output, a growing summary, one-item arrays and a half-filled nested struct; a reset after a repair; a reset after a retried `final_answer`; `generate`; no partial arms without the flag.
  - Compile-fail cases: the three listed above.
- **Cost:**
  - A 47 KB output in 20-byte deltas produced 802 partial values in 53 ms (ReleaseFast, M-series).
  - Turning it on for the size suite's full app adds 2.8 KB (1,596,808 → 1,599,608 B).
- The support example's and the sketch's `TriageAgent` use `.partial_output = true` with `stream_strings = .{.summary}`. Goldens updated.
- **Not done yet:** the live run per provider (needs keys, N11).

### 18.5 N11: release v1.2.0

- Update `sketch/`, `docs/getting-started.md`, the PLAN sections and the manifest in the same commits as the code (CLAUDE.md).
- Size budgets unchanged: anthropic-only + memory under 700 KB, the full example under 2 MB. Record the `.partial_output` cost.
- Compile time within 25% of v1.0.0 on the same CI runner (the N6 check).
- CI green on all four targets.
- Live runs: partial output on both providers; a loop with a real agent; a gated agent inside a loop with a two-process resume.
- CHANGELOG. There's one behavior change: parallel failures report the earliest branch failure. Everything else is additive. Then tag `v1.2.0`.

**Done (N11, 2026-10-16):** CI green on all targets (ceaf826, after GitHub billing blocked the N9 run; the repo is now public under MIT); compile time 31 s vs v1.0.0's 29 s on the same runner (+7%); size budgets pass (anthropic-only + memory 656,904 B, full 1,596,808 B, +2.8 KB with `.partial_output`). Live runs on the release code:
- Partial output on six paths: native structured output and the `final_answer` tool on Anthropic (claude-sonnet-5-5, claude-haiku-5-5), OpenAI Responses and Chat Completions (gpt-5.4-mini). Each streamed 15–21 partial values with `summary` growing in 9–16 steps (586–1,073 chars); the last partial equaled the final output; no resets. First partial after 0.8–3.4 s.
- A loop around a real agent (gpt-5.4-mini) ran three iterations and stopped on `until`.
- A gated agent in a loop (claude-sonnet-5-5), three processes: process 1 suspended in iteration 0; process 2 approved, the tool ran once, and iteration 1 suspended; process 3 approved and the run completed. Saved runs `<run>/loop_gated_reviser.gated_reviser@0#0` and `@1#0` both `completed`; a repeated resume got `NotSuspendedAtStep`.
- Note for users: Chat Completions on api.openai.com rejects `max_tokens` for current models; `z.custom` there needs `.max_tokens_field = .max_completion_tokens` (catalog models use Responses and set it already).

### 18.6 Order, dependencies and risks

Order: N7, then N8, then N9, then N10.
- N7 goes first because N9's bodies can contain parallel groups, and the shared-state race should be gone first.
- N8 is independent and small.
- N9 and N10 are independent of each other. N10 goes last because it touches every provider's delta path.

| Risk | Mitigation |
|---|---|
| `Group.cancel` doesn't interrupt a branch blocked outside `std.Io` (CPU work, a C library) | Document it; the earliest failure is still reported; the branch is awaited, never leaked |
| Loop iteration ids leak into the comptime-path assumptions all over the runner | Keep paths comptime; the iteration stack is runtime state appended only where ids are minted (agent runs, spans) |
| Clearing body slots and advancing `iter` must be one save | Done in one state mutation followed by one `x.save`; crash test after each body step |
| Partial parse cost on large outputs | Boundary-only reparse; a benchmark with a 50 KB output in the N10 tests, with a budget |
| Providers interleave `final_answer` args with other tool calls | Deltas are keyed by tool index; only the `final_answer` index feeds the scanner |
| A migration chain grows forever | Old types can be deleted once no stored values use them; the warning names the fingerprint, so it's clear when it's safe |

---

## 19. v1.1c plan (tooling; release v1.3.0)

v1.1c is the tooling row of §17's table. It ships as **v1.3.0**. One public type changes: trace ids widen to 128 bits (N12). zastra has no outside users yet, so this is done without a compatibility path (D49). Nothing else changes a wire format or storage schema, and none of it adds code to an App binary that doesn't use it.

| Milestone | Scope | Size |
|---|---|---|
| R1 | Provider stream deepening (internal; two compat fixes) | medium |
| R2 | One way to open a model stream; scripted `rt.model` | small |
| N12 | OTLP trace exporter | medium |
| N13 | `dev serve`: the dev CLI over HTTP + SSE | large |
| N14 | `z.testing.arbitrary(T)` | medium |
| N15 | `z.testing.fuzzTool` | small |
| N16 | Release v1.3.0 | small |

`models-update` reading `GET /v1/models` (listed in §14) shipped in N1 (§17.1), so it isn't here.

### 19.0 R1: provider stream deepening (D53)

**Problem.**
- **Copied plumbing.** The three wire modules each carry their own copy of the request opening (URL, headers, POST, status check), the error-body parser, the start of the `next()` loop (scratch reset, SSE read, body errors, JSON parse) and the `Stream` struct. Compat's and Responses' `errorMessage` are byte-identical. Adding a fourth API means copying all of it again.
- **One event per call.** `next()` returns at most one event per SSE event. Compat works around this with a fixed `pending: [16]Event` array whose `add` silently drops events past 16. Since N10, partial output reads `tool_call_args` deltas, so a dropped delta corrupts `.output_partial`.
- **Compat tool-call id.** Compat's `tool_call_start` delta reports `id = ""` when the server sends none, while the builder stores the synthesized `call_N`.
- **Provider decisions outside the providers.**
  - `agent.zig` switches on `spec.api` for the schema dialects, the native-output rule and every branch of `resolveReasoning`.
  - The dev CLI does the same for its reasoning column.
  - Responses' `buildPrefix` has `.budget => unreachable`, which depends on a check in another file.
- **`max_tokens_field` is ignored on two APIs.** Only compat reads it, so on the other two providers `z.custom(.{ .max_tokens_field = ... })` does nothing, and nothing says so.

**Design** (§6.2):
- **`stream.zig`.** `SseStream(Wire)` owns the shared request and stream handling. Each wire module supplies `name`, `path`, `auth`, `State`, `onEvent` and `capabilities`, and keeps `buildPrefix`, `writeBody` and `writeToolDef` unchanged.
  - The queue is unbounded and lives in the scratch arena.
  - Error bodies use one format for all three APIs: the error's `type`, falling back to its `code`.
- **Callers are unchanged.** `Impl(api).Stream` keeps `open(arena, http, Request)`, `next() !?Event` and `close()`. `agent/run.zig`, `model.zig`, `testing/scripted.zig` and the cassette tests don't change.
- **Capabilities** (§6.2) replace every `spec.api ==` in `agent.zig` and `build/dev.zig`.
  - `resolveReasoning` checks the API's capabilities first, then the model's `supports.reasoning_modes`.
  - The existing `reasoning_*` compile-fail tests pass unmodified, so the wording is unchanged.
  - The catalog doesn't change; the default base URLs in `z.custom` stay there.
- **`max_tokens_field`** stays on `Request`, documented as Chat-Completions-only. `z.custom` with `.provider = .anthropic` or `.openai_responses` and `.max_tokens_field` is a compile error (§7), with a compile-fail test.
- **Compat fixes.** Every event of a chunk is delivered, in order. `tool_call_start` carries the same id as the final `tool_use` block.

**Out of scope:**
- one shared function to open a model stream for the agent loop and `rt.model`
- a session-memory module out of `agent/run.zig`
- moving the scripted encoders into the wire modules

The last one becomes simpler after R1.

**Tests.** Everything goes through the `Stream` interface with `http.Replay`, like `tests/provider_test.zig` today. There are no unit tests of `onEvent` directly. New cassettes:
- a compat chunk carrying reasoning, content and more than 16 tool-call events: every delta arrives, in order
- a compat tool call without an id: the `tool_call_start` id equals the final `tool_use.id`
- a non-2xx error body per API: the shared diagnostic format
- a body that ends mid-stream: `error.StreamInterrupted`, tested once

**Commits**, each green on `zig build test` and `zig build size`:
1. this plan, D53, the §6.2 rewrite, `GLOSSARY.md`
2. `stream.zig`, the three wire modules on it, the compat fixes and new cassettes
3. capabilities, `agent.zig`, `build/dev.zig`, the `z.custom` check and its compile-fail test
4. CHANGELOG: "Fixed" for the two compat bugs, "Internal" for the rest

**Exit criteria:**
- All existing tests pass unmodified (cassettes, goldens, compile-fail), plus the new ones.
- `zig build size`: no budget grows. Record the before and after numbers here.
- No `spec.api ==` outside `src/provider/` and `src/testing/scripted.zig`.
- No `unreachable` in a wire module that depends on a check made elsewhere.

**Status: done.** `zig build size` (ReleaseSmall, stripped), before → after:

| App | Before | After | Budget |
|---|---|---|---|
| anthropic_memory | 656,904 | 658,856 (+1,952) | 1,000,000 |
| both_sqlite | 1,517,960 | 1,518,768 (+808) | 2,000,000 |
| full | 1,596,808 | 1,598,256 (+1,448) | 3,000,000 |

The growth (0.3% at most) hasn't been broken down by symbol. The size check's symbol patterns now name `provider.stream.SseStream(provider.anthropic)`, and they also check that `provider.openai_responses` is absent from the Anthropic-only App.

### 19.0b R2: one way to open a model stream (D54)

**Problem.** The agent loop (`agent/run.zig`, `openRequest`) and `rt.model` (`model.zig`, `stream`) each check the API key, resolve the base URL and build a `provider.Request`. The two copies have drifted apart:
- **Custom headers dropped in tests.** Under the test harness, the agent loop sends only the `x-zastra-agent` routing header and drops `spec.headers` (OpenRouter attribution and the like). No harness test can see them.
- **`rt.model` can't be scripted.** It sends no routing header, so the harness can't answer it, and no test calls `rt.model` at all.
- **Different wording for a missing key.** The agent loop prefixes the diagnostic with `agent '<id>':`; `rt.model` has no prefix.

**Design.**
- `runtime.State.openStream(comptime spec, comptime who, arena, parts) !Impl(spec.api).Stream` handles both callers. `parts` holds the prefix, system suffix, messages, max tokens, routing tag and diagnostic.
  - It owns the API-key check (skipped under the harness), the base URL, `max_tokens_field`, and the request headers.
  - Under the harness, the headers are the routing tag *plus* `spec.headers`. The merged list is built only when tagging is on, so production requests still pass `spec.headers` unchanged.
  - `who` prefixes the missing-key diagnostic: `agent 'support'` (unchanged wording) or `rt.model("anthropic/claude-haiku-4-5")`.
- **Spans stay with the callers.** The agent loop keeps its `model_call` spans. `rt.model` stays untraced (noted in N12).
- **Diagnostics are unchanged.** `openStream` writes only the caller's diagnostic. `rt.model` still copies it to the runtime with `setDiag`, and the agent loop keeps its own flow.
- **`rt.model` gets a routing tag:** `model:<provider>/<id>`. The prefix can't collide with an agent id.
- **New harness API** (§10):
  - `h.scriptModel("anthropic/claude-haiku-4-5", &.{ .text("Hi"), .withReasoning("...", .text("...")) })` queues turns for `rt.model`.
  - `h.model("...")` returns a handle whose `generate`/`stream` use the harness arena, like `h.agent(A)`.
  - Steps are the same `z.testing.Step` constructors, for a model with no tools and no output. Using `.tool`/`.tools`/`.output` there is a compile error.

**Tests**, all through the harness and the public interface:
- An agent on a `z.custom` model with `.headers` sends those headers and the routing tag. The harness records the headers of each request.
- `h.scriptModel` with `h.model(...).generate` returns the scripted text and reasoning on Anthropic and OpenAI Responses.
- Outside the harness, `rt.model` without its API key gives `error.MissingApiKey` with the new wording.
- A compile-fail test for `.tool(...)` in `h.scriptModel`.
- The sketch and the support example gain a test of `h.scriptModel`.

**Exit criteria:** existing tests pass unmodified; no size budget grows.

### 19.1 N12: OTLP exporter (D49)

**Problem.** Spans only go to a JSONL file. Production users want them in the collector they already run (OpenTelemetry Collector, Jaeger, Honeycomb, Grafana Tempo, Langfuse, Phoenix).

**API.**

```zig
.tracing = z.trace.otlp(.{
    .endpoint = "http://localhost:4318",      // default: OTEL_EXPORTER_OTLP_ENDPOINT, then this
    .headers = &.{.{ "x-honeycomb-team", .{ .env = "HONEYCOMB_API_KEY" } }}, // default: OTEL_EXPORTER_OTLP_HEADERS
    .service_name = "support",                // default: OTEL_SERVICE_NAME, then the App's name
    .include_content = false,
}),
```

**Design:**
- **Protocol:** OTLP/HTTP with the JSON encoding, `POST <endpoint>/v1/traces` (or `OTEL_EXPORTER_OTLP_TRACES_ENDPOINT` used as is). Every collector named above accepts it. No protobuf or gRPC: that would mean a protobuf encoder for one message type, and HTTP/JSON is a required part of the spec.
- **Size follows usage:** `trace.Config` gains an `.exporter` variant holding a pointer to a vtable (`push`, `flush`, `deinit`). `z.trace.otlp` is the only thing that references the OTLP code, so Apps that use `.jsonl` or `.off` link none of it. JSONL stays an inline variant, unchanged.
- **Batching:** `Span.end` copies the finished span into a bounded queue (2,048 spans) under the tracer's mutex. A background task started with `Io.Group.concurrent` (inline fallback: flush on the ending thread once the batch is full) sends a batch every 512 spans or 2 s. `rt.deinit()` cancels the task and flushes what's left, with a 5 s limit. When the queue is full, the oldest spans are dropped and counted; the count goes out as a log warning, not an error.
- **Failures never fail a run.** The exporter retries 429/5xx and connection errors twice with backoff (the provider HTTP client's policy), then drops the batch and logs one warning per minute at most.
- **HTTP:** the runtime's existing client (TLS, CA bundle, timeouts). Nothing new is linked for `https` endpoints.
- **Ids:** trace ids widen from 64 to 128 bits everywhere: `[32]u8` hex in `GenerateOptions.trace_id` and the span types, the JSONL `trace_id` field, and agent-run snapshots. OTLP and W3C `traceparent` both use 128-bit trace ids, so ids pass through unchanged. Span ids stay 64-bit, as in OTLP. No compatibility path: old 16-character trace ids in JSONL files and snapshots aren't read. `dev trace` reports them as an old format.
- **Attributes:** the OpenTelemetry GenAI semantic conventions where one exists (`gen_ai.operation.name`, `gen_ai.provider.name`, `gen_ai.request.model`, `gen_ai.usage.input_tokens`, `gen_ai.usage.output_tokens`, `gen_ai.tool.name`, `gen_ai.agent.name`). Everything else stays under `zastra.*` (`zastra.cost_usd`, `zastra.prefix_hash`, `zastra.iteration`). JSONL keeps today's keys. `model_call` and `mcp_call` spans are `SPAN_KIND_CLIENT`; the rest are `INTERNAL`. Failed spans get `STATUS_CODE_ERROR` and the message. `rt.model` calls make no spans yet (R2 left tracing to the callers); N12 adds a `model_call` root span for them.
- **Content:** with `.include_content`, prompts and responses go into `gen_ai.input.messages` and `gen_ai.output.messages` as JSON strings. They're off by default, as in JSONL.

**Exit criteria:**
- A fake collector in the tests (like `tests/fake_mcp_http.zig`): the exact JSON body for one agent run with a tool call (golden), batching by count and by time, the flush at `rt.deinit()`, a full queue dropping the oldest spans, a 503 retried and then dropped without failing the run, and environment-variable defaults.
- Size: with `.jsonl`, the size suite's anthropic-only App changes only by the wider trace id; record the cost of `.otlp`.
- Trace ids: a test that every span of a run, the JSONL line and the agent-run snapshot carry the same 32-character id.
- Live: the support example exporting to a local Jaeger (`jaegertracing/all-in-one`, OTLP on 4318). The span tree, GenAI attributes and errors show up in the UI.
- Docs: a tracing section in `docs/getting-started.md`; the sketch's `.tracing` comment becomes real code.

**Implemented (N12, 2026-10-17):**
- `src/trace/otlp.zig`. `trace.Config` gains `.otlp`, holding the options and a pointer to `start`; only `z.trace.otlp` takes that pointer. `App.init` starts the exporter and `rt.deinit()` stops it first.
- **Changes from the design above:**
  - The exporter has its **own HTTP client**, not the runtime's: under the test harness the runtime's client replays scripted responses, and a separate client keeps the exporter's retries and 10 s timeout apart from model calls. It loads CA certificates only for `https://` endpoints (new `Http.initPlain`), using the App's `ca_bundle`.
  - The default service name is `OTEL_SERVICE_NAME`, then `"zastra"`: Apps have no name.
  - Shutdown: `rt.deinit()` wakes the sender, waits up to `shutdown_timeout_ms` for its final flush, then cancels it. Without concurrency, a full batch is sent from `Span.end` and the rest at `rt.deinit()`; there's no time-based flush.
  - The batch size, interval, queue size, timeouts and retries are options (tests use small values).
  - `finish_reason` becomes `gen_ai.response.finish_reasons` (an array). Span names are `<operation> <name>`: `invoke_agent support`, `chat anthropic/claude-sonnet-4-6`, `execute_tool lookup_order`; spans without a GenAI operation use their kind (`workflow_run classify_ticket`).
- **`include_content` now works.** It was declared on `.jsonl` but nothing read it. Model spans (agent and `rt.model`) get `input_messages` and `output_messages` (`gen_ai.input.messages`/`gen_ai.output.messages` in OTLP). A JSONL span too big for its 8 KB line drops these first, then the other attributes.
- **`rt.model`** calls get a root `model_call` span: model, tokens, cost, finish reason, and the error message on failure.
- **Trace ids** are `trace.TraceId` (`[32]u8`), span ids `trace.SpanId` (`[16]u8`). Snapshots store the id as is. `dev trace` skips 16-character ids and says how many it skipped.
- Harness: `.tracing` option.
- Tests (`tests/otlp_test.zig`, `tests/fake_otlp.zig`): the body for an agent run with a tool call (golden `tests/golden/otlp/agent_run.json`, ids and times normalized; nothing sent before `rt.deinit()`), batching by count and by time, the queue dropping the oldest spans, a 503 retried once and dropped while the run succeeds, `OTEL_*` defaults including a percent-encoded header, explicit and env headers, the inline path with concurrency disabled, content (agent and `rt.model`), and one trace id across spans, JSONL and a suspended run's snapshot, before and after its resume.
- **Size** (`zig build size`): anthropic_memory 658,664 → 662,200 B (+3,536). 672 B are the wider ids and exporter dispatch; 2,864 B are content serialization, linked whenever tracing could be on, since the tracing config is a runtime value. Using `.otlp` adds 13,440 B (675,640 B).
- **Live (2026-10-17):** a local Jaeger (`jaegertracing/all-in-one`, under Colima) received a scripted agent run with a tool call, a run whose tool failed, a workflow and an `rt.model` call: one trace each, nesting and span kinds correct, GenAI attributes and content present, failed spans marked as errors with the message. Not yet run with real provider calls (no keys at the time); the export path doesn't depend on them.
- Not in the C ABI: its config JSON still takes only `"trace": "<path>"`. Adding OTLP there would link the exporter into every C library.

### 19.2 N13: `dev serve` (D50)

**Problem.** The dev CLI is one process per command. A web UI (the v2 Studio) and scripts in other languages need the same commands over HTTP, with streaming.

**API.** `zig build dev -- serve [--port 4111] [--host 127.0.0.1] [--token-env NAME] [--trace-file zastra-trace.jsonl]`. The server is a library function, `z.dev.serve(App, *Runtime, opts)`, which the dev binary calls. That makes it testable against a harness runtime with scripted models.

**Endpoints** (JSON in and out; streaming responses are `text/event-stream`):

| Method and path | Same as |
|---|---|
| `GET /api/agents`, `GET /api/agents/{id}` (tools, schemas, effects, prefix hash) | `agents`, `schema`, `prefix` |
| `POST /api/agents/{id}/generate` `{input, thread?, resource?}` | one-shot `chat` |
| `POST /api/agents/{id}/stream` | `chat`, streamed |
| `GET /api/workflows`, `GET /api/workflows/{id}/graph` | `graph` |
| `POST /api/workflows/{id}/start` `{input, resource?}` | `run` |
| `GET /api/runs?kind=&status=`, `GET /api/runs/{id}` | `runs` |
| `POST /api/runs/{id}/resume` `{decisions}` or `{step, value}`; `.../resume/stream` for agent runs | `resume` |
| `POST /api/runs/{id}/cancel` | |
| `GET /api/traces/{trace_or_run_id}` | `trace` |
| `GET /api/models` | `models` |

**Design:**
- **One event encoding.** SSE events are the C ABI's event JSON (`event: <kind>`, `data: <the C ABI's JSON>`), so a client written against one works against the other. The manifest (§5.16) describes both.
- **Approvals over SSE.** SSE is one-way. When a stream reaches an approval request, the server suspends the run (`s.suspendRun()`), sends `approval_request` events and a final `suspended` event with the run id, and closes the stream. The client continues it with `POST /api/runs/{id}/resume/stream`. This is the D31 flow over HTTP; the server keeps no session state.
- **Concurrency.** Each connection runs on its own task (`Io.Group.concurrent`). The runtime is already safe for concurrent runs. A client disconnecting cancels its run's task. The run's saved state follows the usual rules: a stream canceled mid-step isn't resumable unless it was suspended.
- **Security.** The server can spend money on your API keys, so:
  - It binds to `127.0.0.1` by default.
  - A non-loopback `--host` requires `--token-env`; requests must then send `Authorization: Bearer <token>`.
  - Every request's `Host` must be a loopback name or the bound host, and a request with an `Origin` header must come from a loopback origin. This blocks DNS rebinding and cross-site requests from a browser.
  - No CORS headers by default. `--allow-origin <url>` adds one exact origin, for a local UI on another port.
  - Request bodies are capped at 1 MiB.
- **Errors.** `{"error": {"code": "<zastra error name>", "message": "<diagnostic>"}}` with 400 (bad input), 404, 409 (`RunBusy`, `NotSuspended`) or 502 (provider errors).
- **No OpenAPI spec yet** (§14 lists it for v2). `docs/dev-serve.md` documents the endpoints, and a golden test pins every response shape.

**Exit criteria:**
- Tests against a harness runtime, using a real socket and `std.http.Client`: every endpoint, an SSE stream with tool and partial-output events, a suspend over SSE followed by resume/stream, a concurrent second request, a client disconnecting mid-stream, and each security rule (wrong `Host`, a foreign `Origin`, a missing token, an oversized body).
- `dev serve` on the support example, driven by `curl` in CI (`tests/dev_serve_smoke.sh`), with fake keys covering the error paths.
- Live: the support example, `curl -N` streaming a chat with an approval, then resuming it.
- App binaries don't change size; `dev serve` lives only in the dev binary.

**Implemented (2026-10-17).**
- `src/dev/serve.zig`: `z.dev.serve(App, &rt, opts)` and `z.dev.Server(App)` (`init`, `start`, `port`, `acceptLoop`, `deinit`). The dev CLI's `serve` command takes `--port`, `--host`, `--token-env`, `--allow-origin` and the global `--db`; the trace file is the CLI's `zastra-trace.jsonl`.
- **One encoding.** The C ABI's result and event JSON moved to `capi/encode.zig`, used by both. The manifest now has per-agent and per-workflow JSON (`manifest.agentJson`, `workflowJson`) and lists tool `effects`, so `GET /api/agents` and the manifest are the same objects.
- **Stream ends.** After `finish` a stream sends `result` (the C library's `result()` JSON). A failure sends `error` with the error JSON. An approval sends `suspended` (`suspendedJson`).
- **Resume decisions** are an array, as in the C ABI. Workflow resume takes `{value, step?}`; `step` is only checked against where the run is suspended.
- **Workflow cancel** marks a suspended run `canceled` through `claimRun`. There's no workflow cancel API in the runtime; agent runs use `cancelRun`.
- **Responses before the body is read** (security rejections, 413) close the connection. `std.http.Server.respond` would otherwise read the whole body to keep the connection alive.
- **Disconnect detection** happens at the next event write, so a run blocked in a long model call or tool notices when that returns.
- **Shared diagnostic.** Error messages use `rt.lastDiagnostic()`, which is shared by the runtime, so concurrent failures can mix messages. Streams use their own diagnostic.
- **Tests.** `tests/dev_serve_test.zig` covers every endpoint, SSE with tool, partial-output and multi-line text events, suspend then resume/stream, a concurrent request while a stream is blocked in a tool, a client disconnecting (the rest of its script isn't consumed), and each security rule. `tests/golden/dev_serve/session.txt` pins every response shape, with volatile ids and times scrubbed; refresh it with `ZASTRA_UPDATE_GOLDEN=1 zig build test`. `tests/dev_serve_smoke.sh` runs in CI on Linux and macOS.
- **Live check still open:** `curl -N` against the support example with real keys, an approval, then a resume. It needs API keys and is part of N16.

### 19.3 N14: `z.testing.arbitrary(T)` (D51)

**Problem.** Tests hand-write tool inputs and outputs. Edge cases (empty strings, boundary numbers, unicode, missing optionals) are only tested if someone thinks of them.

**API.**

```zig
var prng: std.Random.DefaultPrng = .init(seed);
const order = try z.testing.arbitrary(LookupOrder.Input, arena, prng.random());
// or, inside std.testing.fuzz, a coverage-guided source:
const order = try z.testing.arbitrary(LookupOrder.Input, arena, smith);
```

**Design:**
- **Sources.** `std.Random` (seeded, deterministic, runs in a normal `zig build test`) or `*std.testing.Smith` (coverage-guided under `zig build test --fuzz`). One generator is written against a small internal interface both satisfy.
- **Valid by construction.** Every value is one that `schema.parse(T, ...)` accepts: integer bit widths, `min`/`max`, `min_len`/`max_len`, `one_of`, `min_items`/`max_items`, every enum tag and union variant, optionals sometimes null, defaulted fields sometimes omitted. `z.Json` gets small random JSON.
- **`pattern` isn't generated.** zastra doesn't enforce `pattern` (D27), and generating strings from a regex needs the engine D27 deferred. A field with a `pattern` gets strings within its length bounds. A type can override generation with `pub fn arbitrary(gen: *z.testing.Gen) !T`, also used for values the schema can't express.
- **Edge bias.** About a quarter of picks are boundaries: `min`, `max`, 0, the empty string, maximum-length strings, quotes and backslashes, control characters, multi-byte and invalid-looking (but valid) UTF-8, empty and maximum-length arrays.
- **Bounds.** Default `max_len` 64 and `max_items` 8 where the schema has none, overridable with `.{ .max_len, .max_items }`. Recursive types are already rejected by §5.1.
- **Round-trip check, used on zastra's own types:** for every generated value, `parse(T, stringify(v))` succeeds and equals `v`, and the JSON validates against `json_schema.of(T)` with the N5 validator. This runs over the test suite's types and the support example's types.

**Exit criteria:**
- Unit tests per mapping and per constraint, each confirming every generated value parses.
- The round-trip property over at least 30 types, 500 values each, in normal `zig build test`.
- The same property under `zig build test --fuzz` for a minute in local runs, not in CI.
- Compile-fail: an `arbitrary` override with the wrong signature.

**Implemented (2026-10-17).**
- `z.testing.arbitrary(T, arena, source)`, `z.testing.Gen` (`.init(arena, source, .{ .max_len, .max_items })`, `value`, `int`, `float`, `string`, `boolean`, `chance`, `index`) in `src/testing/arbitrary.zig`. Overrides apply to structs, unions and enums, at any depth.
- Added `z.testing.expectRoundTrip(T, .{ .seed, .count = 500 })` and `z.testing.roundTrip(T, arena, v)` (for fuzz bodies), so apps can run the round-trip property on their own types; the support example does.
- Two details the plan didn't name: an optional field with a non-null default is never generated as null (null is omitted from JSON and reads back as the default), and `?z.Json` never holds JSON `null` (it reads back as null).
- The property found two bugs, both fixed: `[N]u8` was written as a JSON string while the schema and the parser use an array of integers, and the MCP validator rejected integers beyond i64 (a large `u64`) as non-integers.
- 35 types × 500 values in `tests/arbitrary_test.zig` (about 5 s in Debug), plus 200 random-byte Smith inputs over all of them. Three compile-fail cases: wrong override parameter, wrong return type, wrong source type.
- **Not met: `zig build test --fuzz`.** Zig 0.16.0's test runner doesn't compile in fuzz mode (`lib/compiler/test_runner.zig:566`, `*builtin.StackTrace` passed where `*const debug.StackTrace` is expected), so no fuzz test can run on 0.16.0. The `std.testing.fuzz` test is in place and runs its single empty input in normal tests; the random-byte Smith test covers the Smith path until a Zig release fixes the runner.

### 19.4 N15: `z.testing.fuzzTool` (D52)

**API.**

```zig
test "lookup_order survives arbitrary input" {
    var ctx = try TestCtx.init();
    try z.testing.fuzzTool(app.App, LookupOrder, .{ .ctx = &ctx, .iterations = 300, .seed = 1 });
}
```

**Design.** Each iteration takes the path a model's tool call takes: arguments JSON, `schema.parse`, `execute`, output serialization. Two modes run in each call:
- **Valid inputs:** `arbitrary(Input)`. A failure is a panic, a leak (the call's arena is backed by `std.testing.allocator`, so memory the tool keeps outside it through `ctx` shows up), an output that doesn't validate against `Output`'s schema, or an error the tool doesn't map through `error_messages` when `.mapped_errors_only = true`. Returning a mapped error is fine, because models see it as a tool result.
- **Hostile arguments:** valid JSON for `Input` mutated (wrong types, missing and extra fields, out-of-range numbers, truncated text, deep nesting). `parse` must return a validation issue with a message, never crash, and `execute` must never see the input. This tests zastra's parser as much as the tool.
- **Effects gate (§5.12).** A tool declaring `.writes`, `.network`, `.spends_money` or `.destructive` is refused at compile time unless the call passes `.allow_effects = .{ ... }` naming them. Fuzzing a refund tool against a real payment API should never happen by accident.
- **Reporting.** The first failure prints the seed, the iteration and the input JSON, so `.seed` and `.iterations = 1` reproduce it. Under `--fuzz` it uses the Smith source and the fuzzer's corpus.
- Tools run with a `z.ToolCtx` built from the given `ctx`, with no model or agent run: `run_id` and `tool_call_id` are fixed test values and `trace` is a disabled span.

**Exit criteria:**
- Self-tests with planted bugs: a tool that leaks through `ctx`, one that returns invalid output, one that panics on the empty string (run as a child process, expecting the crash and the printed seed), and a parser gap, if one turns up.
- The support example fuzzes `lookup_order` and `faq_search`, and `issue_refund` with `.allow_effects`, against a test database.
- Compile-fail: an effectful tool without `.allow_effects`, and an `.allow_effects` that names an effect the tool doesn't have.

**Implemented (2026-10-17).**
- `z.testing.fuzzTool` in `src/testing/fuzz_tool.zig`. Options: `.ctx` (required), `.iterations` (300), `.seed`, `.mapped_errors_only`, `.allow_effects`, `.hostile` (default true), `.gen`, `.smith`, `.quiet`. Unknown options are a compile error. Iteration `i` uses seed `.seed + i` alone, so the printed seed with `.iterations = 1` reproduces it.
- **Parser checks.** The arguments are also validated against the tool's JSON Schema with the N5 validator. A failure is: the parser accepts what the canonical and the OpenAI strict schema both reject, or rejects what the canonical schema accepts, or rejects without a message. Strict mode allows `null` for optionals and drops bounds, so when only it accepts, the case is skipped.
- **Crashes.** Before each call the case is written to a static buffer, and a SIGABRT handler (installed for the duration of the call, posix only) prints it after the panic's stack trace. This is the one process-global in zastra; signal handlers can't take a context. The child-process self-test runs a test binary built by `build.zig` (`tests/fuzz_crash.zig`).
- **Leaks.** fuzzTool can't attribute a leak to an iteration. Leaks surface through the allocators in `ctx` (`std.testing.allocator` fails the test). The self-test counts with a `DebugAllocator` so the planted leak doesn't fail the suite.
- **`.quiet`** exists because the build runner fails a test that writes to stderr, so the self-tests of failing tools can't print their reports.
- **Found by sweeping 20,000 hostile cases:**
  - **A crash.** `std.json.Stringify` asserts a nesting depth of at most 256 in safe builds. zastra stringified untrusted `std.json.Value`s in seven places: `parse` for `z.Json` fields (model output and tool arguments), Anthropic opaque content blocks, MCP results, request state, tool schemas and JSON-RPC ids. Deeper JSON from a model or an MCP server panicked the process. All seven now go through `json.stringifyValueAlloc`, which returns `error.TooDeep`. That becomes a validation issue, a protocol error, or an error result for the model, depending on the caller.
  - **Imprecise validator bounds.** The MCP validator compared integer bounds as f64, so `u64`/`i64` bounds plus or minus one passed. Integers now compare exactly.
- **Support example.** The example has no `faq_search` tool (FAQ search is a workflow step), so it fuzzes `lookup_order` and `issue_refund`. `IssueRefund` now declares `effects = .{ .reads, .writes, .spends_money }`, which it should have had all along, so its fuzz test needs `.allow_effects`.

### 19.5 N16: release v1.3.0

- Update `sketch/`, `docs/`, the PLAN sections and the manifest in the same commits as the code (CLAUDE.md).
- Size budgets unchanged. Record the `.otlp` cost; everything else adds nothing to App binaries.
- Compile time within 25% of v1.0.0 on the same CI runner.
- CI green on all four targets.
- Live: OTLP into Jaeger; `dev serve` with a streamed approval and resume on both providers.
- CHANGELOG, with the trace-id widening under breaking changes, then tag `v1.3.0`.

### 19.6 Order, dependencies and risks

Order: R1, R2, N12, N14, N15, N13.
- R1 and R2 first: they are internal (R2 adds two harness methods), and it is easier to land before N13 adds new code that streams agent events.
- N14 before N15 (fuzzing generates inputs with `arbitrary`).
- N13 last: it's the largest, and `GET /api/traces` reads the JSONL format, which N12 leaves alone but touches nearby.
- N12 is independent.

| Risk | Mitigation |
|---|---|
| A slow or unreachable collector backs up span export and stalls runs | `Span.end` only copies into a bounded queue; sending happens on the background task; drops are counted, never blocking |
| The exporter's background task outlives `rt.deinit()` or loses the last spans | `deinit` cancels the task, then flushes once with a time limit; a test checks the last span arrives |
| The dev server is reachable from a browser tab on a malicious site | Loopback bind, `Host` and `Origin` checks, no CORS by default, token required off loopback |
| A disconnected SSE client leaves a run executing and spending tokens | Disconnect cancels the run's task; a test checks the scripted model gets no further requests |
| `std.testing.Smith` is new in 0.16 and may change | The generator is written against an internal interface; Smith is one adapter |
| `arbitrary` makes values the parser rejects (bugs in either) | The round-trip property is the main test of both; a disagreement fails loudly with the value |
| Fuzzing effectful tools by accident | Compile-time effects gate |
