# Changelog

## Unreleased

### Breaking changes
- Trace ids are 128-bit: 32 hex characters (`z.trace.TraceId`) in spans, JSONL, `.trace_id` and saved runs. `dev trace` skips older 16-character ids.

### Added
- **OTLP export:** `z.trace.otlp(.{ .endpoint, .headers, .service_name, .include_content })` sends spans as OTLP/HTTP JSON to any OpenTelemetry collector, in batches from a background task, with `OTEL_*` environment defaults and GenAI semantic-convention attribute names (D49).
- `rt.model` calls are traced as `model_call` spans.
- `z.testing.harness(App, .{ .tracing = ... })`.
- A test for a crash between a loop body's last save and the loop's progress save.
- `docs/getting-started.md`: `.max_tokens_field = .max_completion_tokens` for `z.custom` models on OpenAI's Chat Completions endpoint.
- `h.scriptModel("provider/id", steps)` and `h.model("provider/id")`: script and call `rt.model` under the test harness. `h.requestHeaders()` returns the headers of each model request (D54).

### Changed
- The missing-API-key diagnostic from `rt.model` names the call: `rt.model("openai/gpt-5-mini"): OPENAI_API_KEY is not set (...)`.
- `z.custom(.{ .max_tokens_field = ... })` with `.provider = .anthropic` or `.openai_responses` is a compile error; those APIs ignored it.
- Provider error responses use one diagnostic format for every API: `"<provider> <status> <type or code>: <message>"`. Anthropic bodies that carry only a `code` now show it.

### Fixed
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
