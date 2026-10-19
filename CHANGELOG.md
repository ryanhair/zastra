# Changelog

## Unreleased

### Breaking changes
- `error.WrongAgent` and `error.WrongWorkflow` are now `error.WrongOwner` (agents, workflows and `dev serve`'s error codes).
- A saved run's status is an enum, `z.RunStatus`, not a string. Storage backends store its tag name, so existing databases keep working.
- A workflow step's agent runs are saved as `<run>/<step><iteration>~<attempt>#<n>` (was `...#<n>`). A workflow run saved by an earlier version while suspended in a gated agent step doesn't find its agent run when resumed: the agent runs again and asks for its approvals again.

### Added
- `rt.runs()`: `list`, `get` and `cancel` over every saved run, returning `z.RunInfo` (with `resumable`). `z.RunFilter` and `z.RunKind` are public too (D63).
- `rt.workflow(W).cancelRun(arena, run_id)`, and `<lib>_run_cancel` in the C ABI, for runs of any agent or workflow.
- `z.testing.childRunId(...)`, the harness's `h.runs()` and `h.claimRun(run_id)`, which claims a run the way another process's resume would.
- A storage conformance suite that runs against both backends.

### Fixed
- A step with `retry` that calls `w.agent(A).run` reused the wrong saved agent run after a resume: retries were numbered past the first attempt's ids, a replay started again from `#0`, found the failed attempt's run and returned `NotSuspended`. Each attempt now has its own ids, and a resume replays the attempt that suspended.
- Resuming a workflow run that is being resumed elsewhere reports `RunBusy` even when the snapshot is also from another version. It used to report `SnapshotIncompatible`.
- `dev serve` canceled workflow runs with the wall clock, not the runtime's clock.
- The memory store listed runs in insertion order and replaced a run's owner and kind when it was saved again. It now matches sqlite.

## v1.4.0 (2026-10-18)

### Breaking changes
- **Zig 0.17.x is required** (was 0.16.x). The API is unchanged. Apps need the usual 0.17 build-script changes, e.g. `run.addPassthruArgs()` instead of `if (b.args) |args| run.addArgs(args)` (D55).

### Added
- Coverage-guided fuzzing works: `zig build fuzz --fuzz` runs the parser, the round-trip property and `z.testing.fuzzTool` (with `.smith`) under the fuzzer. CI runs 10K iterations per fuzz test.

### Changed
- The Zig version for working on zastra is pinned in `mise.toml` (`mise install`); CI reads it too.

### Fixed
- OTLP export: a full batch could go out followed by a partial one with the spans that arrived while it was sent. Partial batches now wait for `interval_ms` or shutdown.

## v1.3.0 (2026-10-17)

### Breaking changes
- Trace ids are 128-bit: 32 hex characters (`z.trace.TraceId`) in spans, JSONL, `.trace_id` and saved runs. `dev trace` skips older 16-character ids.

### Added
- **`dev serve`:** `zig build dev -- serve` offers the dev commands over HTTP with server-sent events, using the C library's JSON. Approvals suspend the stream and `POST /api/runs/{id}/resume/stream` continues it. It binds to loopback, checks `Host` and `Origin`, needs a token for other hosts, and caps bodies at 1 MiB. The server is also a library function, `z.dev.serve` / `z.dev.Server`. See `docs/dev-serve.md` (D50).
- The App manifest lists each tool's `effects`.
- **OTLP export:** `z.trace.otlp(.{ .endpoint, .headers, .service_name, .include_content })` sends spans as OTLP/HTTP JSON to any OpenTelemetry collector, in batches from a background task, with `OTEL_*` environment defaults and GenAI semantic-convention attribute names (D49).
- `rt.model` calls are traced as `model_call` spans.
- `z.testing.harness(App, .{ .tracing = ... })`.
- A test for a crash between a loop body's last save and the loop's progress save.
- `docs/getting-started.md`: `.max_tokens_field = .max_completion_tokens` for `z.custom` models on OpenAI's Chat Completions endpoint.
- `z.testing.arbitrary(T, arena, source)`: random values of a schema type that the parser accepts, edge-biased, from a `std.Random` or a `std.testing.Smith`. Types can override generation with `pub fn arbitrary(gen: *z.testing.Gen) !T`. `z.testing.expectRoundTrip(T, .{})` checks that values survive JSON and match the schema (D51).
- `z.testing.fuzzTool(App, Tool, .{ .ctx, .iterations, .seed })`: runs a tool on arbitrary valid inputs and mutated arguments, checking output schemas, unmapped errors, parser behavior and crashes, with a printed seed to reproduce. Effectful tools need `.allow_effects` (D52).
- The support example's `IssueRefund` declares `effects = .{ .reads, .writes, .spends_money }`.
- `h.scriptModel("provider/id", steps)` and `h.model("provider/id")`: script and call `rt.model` under the test harness. `h.requestHeaders()` returns the headers of each model request (D54).

### Changed
- The missing-API-key diagnostic from `rt.model` names the call: `rt.model("openai/gpt-5-mini"): OPENAI_API_KEY is not set (...)`.
- `z.custom(.{ .max_tokens_field = ... })` with `.provider = .anthropic` or `.openai_responses` is a compile error; those APIs ignored it.
- Provider error responses use one diagnostic format for every API: `"<provider> <status> <type or code>: <message>"`. Anthropic bodies that carry only a `code` now show it.

### Fixed
- `[N]u8` fields were written as JSON strings, while the schema and the parser expect an array of integers. They're written as arrays now.
- JSON nested more than 256 levels deep crashed debug and ReleaseSafe builds (a `std.json.Stringify` assertion). This applied to a `z.Json` field in model output or tool arguments, an Anthropic content block, or an MCP server result, schema or request state. It's now a validation issue or an error result.
- MCP argument validation compared integer bounds as floating point, so values one past an i64/u64 bound passed.
- MCP argument validation rejected integers beyond the i64 range (e.g. a large `u64`) as not being integers.
- `.include_content = true` on JSONL tracing did nothing; model spans now carry the request and response messages.
- Chat Completions (`openai_compat`): a chunk carrying more than 16 events (reasoning, content and many parallel tool calls) dropped the rest from the event stream. Every event now arrives, in order.
- Under the test harness, agent requests dropped a model's `.headers` (only the routing header was sent).
- Chat Completions: `tool_call_start` events had an empty id when the server sent none, while the final message used a made-up `call_N`. Both now carry the same id.

### Internal
- R2 (D54): `runtime.State.openStream` opens every model request, for agents and `rt.model`.
- R1 (D53): one shared `SseStream(Wire)` handles requests, errors and SSE parsing for every API; each wire module declares its `capabilities`, which agent checks read instead of switching on the API.

## v1.2.0 (2026-10-16)

### Added
- **Partial structured output:** `.partial_output = true` on an agent with `.output` adds `.output_partial` events (the value so far as `z.Partial(T)`) and `.output_partial_reset`. Fields listed in `pub const stream_strings` stream as they grow. C ABI event kinds 7 and 8 (D43, D44).
- `z.testing` scripts can stream in small deltas: `.chunked(n, step)`.
- **`z.step.loop(Body, .{ .until, .max, .on_limit })`:** repeat a step, parallel group or workflow until a predicate holds, with a required bound. Iterations are saved and resume like steps, and gated agents inside a loop keep one saved run per iteration (D45, D46).
- **Working-memory migrations:** `pub const migrations = .{ z.migrate(OldNotes, f) }` on the working-memory type converts values saved with older shapes instead of resetting them. Migrations chain, and they also apply when resuming saved agent runs (D48).

### Changed
- **`z.step.parallel` failures:** the first failing branch cancels the others instead of waiting for them, and the step reports the earliest failure in time rather than the first in declaration order (D47).
- The agent run error set gains `MigrationFailed`.

### Fixed
- Chat Completions (`openai_compat`) streams dropped the first argument bytes of a tool call from the event stream when one chunk started the call and carried arguments. The final message was unaffected.
- Two parallel branches failing at the same moment raced on the run's failure fields and arena.
- A step canceled mid-run was retried under its `z.Retry` policy; cancellation is no longer retried.

## v1.1.0 (2026-10-15)

### Breaking changes
- **Agents with approval-gated tools** return `union { completed, suspended }` from `generate` instead of failing with `error.ApprovalRequired`; resume with `resumeRun` / `resumeStream` (D31).
- **C ABI v2** (`ZASTRA_ABI_VERSION 2`): agent results carry `"status"`; `ZASTRA_ERR_APPROVAL_REQUIRED` is gone; new `<lib>_agent_resume`, `<lib>_agent_resume_stream`, `<lib>_agent_cancel`, `zastra_stream_suspend`.
- **Storage migration 0002**: `workflow_runs` becomes `runs` with `kind` and `owner_id` (applied automatically at `App.init`).
- **Catalog OpenAI models use the Responses API** (D35); Chat Completions remains for `z.custom(.{ .provider = .openai_compat })` servers.
- `provider.Reasoning.adaptive` is renamed `.on`.

### Added
- `.reasoning` / `.show_reasoning` on agents, checked per model at compile time (N1).
- OpenAI Responses provider with reasoning carried across tool steps (N2).
- Saved agent runs: suspend, resume from any process, partial decisions, `cancelRun`, `RunBusy` on concurrent resumes (N3).
- Approval-gated agents inside workflow steps: `z.Approvals(A)`, `z.Decisions(A)`, `w.agent(A).run`, `z.step.agentOf` (N4).
- MCP 2026-07-28 with Streamable HTTP and legacy fallback, `z.mcp.http(url, .{ .bearer_env, .headers, .url_env, .optional })`, tool list refresh, a broader schema validator (N5).

### Fixed
- Two resumes of one workflow run could both execute.
- Double free of the HTTP client when `App.init` failed after starting MCP servers.
