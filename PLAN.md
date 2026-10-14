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
4. **Two providers:** Anthropic Messages and OpenAI-compatible Chat Completions. The second also covers OpenRouter, Groq, Together, Ollama and vLLM.

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
      provider.zig                 # Provider interface + comptime selection
      http.zig                     # std.http.Client wrapper, retries, timeouts, CA bundle (D12)
      sse.zig                      # Server-Sent Events parser
      anthropic.zig
      openai_compat.zig
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
- the graph is acyclic (loops arrive in v1.1 as an explicit `z.step.loop` with a comptime-bounded or runtime-bounded iteration count)

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

**Milestone: M6 (stretch for v1; else v1.1).** v1 ships `z.Partial(T)` and its merge (used by working memory). The incremental `stream_parse` and `.output_partial` events are **v1.1**.

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

```zig
pub const Provider = struct {
    ptr: *anyopaque,
    vtable: *const struct {
        stream: *const fn (ptr, alloc, req: Request, sink: *EventSink) anyerror!Finish,
    },
};
```

Notes:
- Only `stream` is required; `generate` is stream-and-collect.
- Concrete providers are selected at comptime per model, so the vtable exists only for the raw `rt.model("...")` path and the erased APIs.

`http.zig` (built on `std.http.Client`; see D12 and the M0 spike notes in §11):
- one shared `std.http.Client` per runtime
- per-request timeout. `std.http` has none, so the request runs in `io.concurrent` raced against an `io.sleep`, and the loser is cancelled.
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
- known limitation: Chat Completions doesn't return reasoning items for OpenAI reasoning models, so they can't round-trip across tool steps. The Responses API is a candidate third dialect in v1.1.

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
- In `generate` (non-streaming), an approval request returns `error.ApprovalRequired` with the pending call. Alternatively, `opts.on_approval` can supply a callback.
- Approval state is held in memory only in v1. Persisting a paused agent run is v1.1; workflows already persist.
- An agent called from a workflow step (`w.agent(A)` or `z.step.agent`) can't pause for approval in v1, because the paused agent run can't be persisted in the workflow snapshot. Using an agent with any approval-gated tool there fails to compile (D18):
  ```
  error: zastra: step 'draft_reply' calls agent 'support', which has approval-gated tool
         'issue_refund'. Agents in workflow steps can't pause for approval in v1; move the
         approval into a step with `Suspend`/`Resume`, or use an agent without gated tools.
  ```
  This check needs a compile-fail test like every other §5 check.

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
workflow_runs(run_id TEXT PRIMARY KEY, workflow_id TEXT, fingerprint INTEGER, status TEXT,
              suspended_at TEXT, state_json TEXT, created_at INTEGER, updated_at INTEGER)
schema_version(version INTEGER)
```

- Migrations are embedded with `@embedFile` and applied in `App.init`.
- A working-memory fingerprint mismatch (because `T` changed) resets to the default and logs a warning. v1.1 adds migrations.

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
- If any branch fails, the step fails with the first error (in declaration order) after all branches finish. Cancelling siblings early is v1.1 (branches only observe cancellation at `std.Io` cancellation points anyway).
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
- `<lib>_agent_generate(app, AGENT_ID, input, opts_json, *err)` returns `*zastra_result`. If an approval is needed it fails with `ZASTRA_ERR_APPROVAL_REQUIRED`; use the stream API for approval-gated agents.
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
  - `z.testing.harness` with `h.script(Agent, steps)`.
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
| Comptime cost (compile time, eval branch quota) as Apps grow | Slow builds; quota errors that confuse users | Keep reflection linear; set `@setEvalBranchQuota` inside zastra with headroom; measure compile time of the example in CI and fail on 2× regressions; keep large data out of comptime. |
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
| O1 | Should `generate` on an approval-gated agent default to returning `error.ApprovalRequired`, or require `on_approval` at comptime? | **Implemented default:** return the error (with a diagnostic naming the tool). |
| O2 | Tool name default: snake_case of type name vs. explicit `name` required | **Implemented default:** derived, with `pub const name` override. |
| O3 | Should `z.Json` exist in v1 (an untyped escape hatch in schemas)? | **Implemented:** yes (`z.Json{ .raw = ... }`). Tools using it skip OpenAI strict mode. |
| D18 | Approval-gated agents inside workflow steps | **v1: compile error** when `w.agent(A)` or `z.step.agent(A, ...)` uses an agent that has any approval-gated tool (§6.4). The message names the tool and points at `Suspend`/`Resume` steps. **v1.1:** with persisted agent runs (D9), the step suspends the workflow instead. Rejected: auto-denying gated calls at runtime, which is silent and surprising. |
| D19 | Unknown model ID under a known provider | **Compile error** with did-you-mean and a hint to use `z.custom` (§5.4). Revisit based on user feedback; the alternative is to accept it with conservative capabilities and no pricing. |

---

## 14. Deferred (v1.1 / v2)

**v1.1**
- `z.DynamicAgent`
- `z.step.loop`
- persisted agent approvals
- MCP Streamable HTTP
- OTLP exporter
- `dev serve` (HTTP+SSE)
- working-memory migrations
- `z.testing.arbitrary(T)` plus fuzzing of tools

**v2**
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

**Not verified:** a successful live completion. No Anthropic key was available, and the OpenAI key in the development environment had no credits (`insufficient_quota`). The live paths up to the provider's response were exercised; full live runs are the first thing to do with working keys (`zig build dev -- chat support`).

**Known v1 limitations:** no incremental `output_partial` streaming (§5.15, v1.1); parallel workflow branches don't cancel siblings early (§6.6); `pattern` constraints aren't enforced client-side (D27); MCP tool lists are fixed at `App.init`; idle timeouts during a streaming response aren't implemented (only time-to-headers).
