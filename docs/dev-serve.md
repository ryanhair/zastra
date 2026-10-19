# `dev serve`

`zig build dev -- serve` serves your App's dev commands over HTTP: list agents and workflows, run them, stream events, and resume or cancel saved runs. It's meant for a local UI or for scripts in other languages. It isn't meant to face the internet.

```sh
zig build dev -- serve                      # http://127.0.0.1:4111
zig build dev -- serve --port 8080 --db runs.sqlite
API_TOKEN=... zig build dev -- serve --host 0.0.0.0 --token-env API_TOKEN
zig build dev -- serve --allow-origin http://localhost:5173
```

The server is also a library function, `z.dev.serve(App, &rt, .{ ... })`. `z.dev.Server(App)` lets you start it on a background task, which is how the tests drive it.

## Security

The server spends money on your API keys, so:
- It binds to `127.0.0.1` by default. A non-loopback `--host` requires `--token-env NAME`. Every request must then send `Authorization: Bearer <value of NAME>`.
- The `Host` header must be a loopback name (`localhost`, `127.x.x.x`, `::1`) or the bound host. This blocks DNS rebinding.
- A request with an `Origin` header must come from a loopback origin, or from the one origin given with `--allow-origin`. Only that origin gets CORS headers. This blocks cross-site requests from a browser.
- Request bodies are limited to 1 MiB.

Rejected requests get 401, 403 or 413, and the connection is closed.

## Responses

The JSON is the same as the C library's (the header `z.addCLib` generates documents it), so a client written against one works against the other.

Errors are JSON:

```json
{"error": {"code": "RunNotFound", "message": "no run 'run_123'"}}
```

| Status | Meaning |
|---|---|
| 400 | Bad input: `InvalidInput`, `UnknownApproval` |
| 404 | `NotFound`, `UnknownAgent`, `UnknownWorkflow`, `RunNotFound`, `TraceNotFound`, `NoStorage`, `NoTraceFile` |
| 409 | `RunBusy`, `NotSuspended`, `NotSuspendedAtStep`, `WrongOwner`, `SnapshotIncompatible` |
| 502 | The provider failed: `Unauthorized`, `RateLimited`, `ProviderError`, `MissingApiKey`, `OutputInvalid`, ... |
| 500 | Anything else |

## Endpoints

| Method and path | Body | Response |
|---|---|---|
| `GET /api/agents` | | Every agent: id, model, prefix hash, tools with schemas, approval and effects, MCP servers, output schema |
| `GET /api/agents/{id}` | | One agent |
| `POST /api/agents/{id}/generate` | `{"input", "thread"?, "resource"?, "max_steps"?, "max_tokens"?}` | `{"status":"completed",...}`, or `{"status":"suspended","run_id","requests"}` for an agent with gated tools |
| `POST /api/agents/{id}/stream` | same | SSE |
| `GET /api/workflows` | | Every workflow: id, fingerprint, schemas, suspendable steps |
| `GET /api/workflows/{id}/graph` | | `{"id","mermaid"}` |
| `POST /api/workflows/{id}/start` | `{"input", "resource"?}` | `{"status":"completed","output"}`, `{"status":"suspended","run_id","at","payload"}` or `{"status":"failed","step","error","message"}` |
| `GET /api/runs?kind=&status=&owner=&limit=` | | Saved runs, newest first |
| `GET /api/runs/{id}` | | One run, with its saved `state` |
| `POST /api/runs/{id}/resume` | Agent runs: `{"decisions":[{"id","approve":true}, {"id","deny":"reason"}]}`. Workflow runs: `{"value", "step"?}` | Like `generate` or `start` |
| `POST /api/runs/{id}/resume/stream` | Agent runs, as above | SSE |
| `POST /api/runs/{id}/cancel` | | `{"status":"canceled"}`; only suspended runs |
| `GET /api/traces/{run_or_trace_id}` | | The spans of the run's traces from the dev trace file, as an array |
| `GET /api/models` | | Catalog entries the App's agents use |

`input` is a string or an array of messages, e.g. `[{"role":"user","content":{"type":"text","value":"Hi"}}]`.

## Streams

Streams are server-sent events. Each event has the stream event's name and its C library payload:

```
event: tool_call
data: {"type":"lookup_order","order_id":"ORD-1042"}

event: text_delta
data: Your order shipped

event: finish
data: {"reason":"end_turn","steps":2,"usage":{...}}

event: result
data: {"status":"completed","text":"Your order shipped yesterday.",...}
```

The events are `text_delta` and `reasoning_delta` (raw text; a multi-line delta uses several `data:` lines, joined with `\n`), `tool_call`, `tool_result`, `approval_request`, `step_finish`, `output_partial`, `output_partial_reset`, `finish`, then `result`. A failure ends the stream with `event: error` and the error JSON.

**Approvals.** SSE only goes one way, so a stream that reaches an approval saves the run. It sends the `approval_request` events, then `suspended` with the run id and the pending requests, and ends. Continue with `POST /api/runs/{id}/resume/stream` and the decisions:

```sh
curl -N localhost:4111/api/agents/support/stream -d '{"input":"Refund ORD-1042"}'
# ... event: suspended / data: {"status":"suspended","run_id":"run_ab12...","requests":[{"id":"toolu_1",...}]}
curl -N localhost:4111/api/runs/run_ab12.../resume/stream -d '{"decisions":[{"id":"toolu_1","approve":true}]}'
```

The server keeps no session state between the two requests. The run is in storage, so any process with the same database can resume it.

**Disconnects.** If the client goes away, the run is canceled at its next event. A run canceled mid-step can't be resumed; only suspended runs can.

**Concurrency.** Each connection runs on its own task, so a long stream doesn't block other requests. The diagnostic in an error message comes from the shared runtime, so under concurrent failures it can describe another request's error.
