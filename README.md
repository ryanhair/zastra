# zastra

A Mastra-style agent framework for Zig: agents, typed tools, workflows, memory, MCP and tracing. It is built around comptime, small static binaries, and a C ABI.

```zig
const Support = z.Agent(Ctx, .{
    .name = "support",
    .model = "anthropic/claude-sonnet-5-5",
    .instructions = @embedFile("prompts/support.md"),
    .tools = .{ LookupOrder, IssueRefund, z.mcp.tools(.docs, .{}) },
    .memory = .{ .history = .{ .last_messages = 30 }, .working = CustomerNotes },
});

var stream = try rt.agent(Support).stream(arena, "Please refund ORD-1042", .{ .thread = "t1", .resource = "c42" });
while (try stream.next()) |event| switch (event) {
    .text_delta => |t| print("{s}", .{t}),
    .tool_call => |call| switch (call) { .lookup_order => ..., .issue_refund => ..., .mcp => ... },
    .approval_request => |req| try stream.respond(req.id, .approve),
    // ...exhaustive: a new event kind is a compile error, not a dropped message
};
```

## What you get

- **Typed everything, checked at compile time.** Tools, agents and workflows are types. JSON Schemas, prompt templates, tool tables, request prefixes and workflow graphs are built by the compiler. Mistakes are compile errors with a `zastra:` message and a did-you-mean:
  ```
  error: zastra: agent 'support' model "antropic/claude-sonnet-4-6": unknown provider 'antropic' (did you mean 'anthropic'?)
  error: zastra: workflow 'handle_ticket': step 'notify_customer' expects Input `Resolution`, but previous step 'classify' outputs `Triage`
  error: zastra: tool 'IssueRefund' declares `needApproval`; did you mean `needsApproval`?
  ```
- **Anthropic and OpenAI.** Anthropic Messages, the OpenAI Responses API for OpenAI's own models (reasoning carried across tool steps), and OpenAI-compatible Chat Completions for OpenRouter, Groq, Together, Ollama and vLLM through `z.custom(...)`. Model capabilities and pricing come from a catalog, so `usage.cost_usd` is computed for you.
- **Agents.** `generate` and `stream`, a multi-step tool loop with parallel tool calls, typed structured output (native JSON-schema mode or a `final_answer` tool, with one repair attempt), reasoning control checked per model (`.reasoning`, `.show_reasoning`), human approval, and memory: history plus typed working memory.
- **Workflows.** `.then`, `.branch`, `z.step.parallel`, nested workflows, typed `needs`, retries and timeouts, plus suspend/resume that survives restarts. A structural fingerprint catches incompatible snapshots, and `.migration(...)` handles old ones.
- **MCP client** over stdio and Streamable HTTP, for the 2026-07-28 protocol and older `initialize`-based servers alike. Tool lists refresh when a server changes them, and arguments are validated against each server's schema.
- **Tracing** as JSON lines, and a dev CLI that prints a run as a tree.
- **Size follows usage.** There are no feature flags. An Anthropic-only app with memory storage is about 650 KB, static, for aarch64-linux-musl. The full support example, with both providers, SQLite, MCP and workflows, is about 1.6 MB.
- **One App, many outputs:** your program, a dev CLI (`z.addDev`), and a C library with a generated header (`z.addCLib`). The C API pulls events from a stream, so it works well over FFI from Swift, Dart and Python.
- **A test harness** with scripted models that are typed against your tools. It needs no network.

## Requirements

Zig **0.16.x**. zastra uses the `std.Io` model throughout (`std.process.Init`, `io.async`, `Future.cancel`).

## Getting started

See [docs/getting-started.md](docs/getting-started.md). [`examples/support`](examples/support) is a complete app: agents, tools, MCP, a suspendable workflow, the dev CLI and the C library.

```sh
cd examples/support
zig build test                       # scripted-model tests, no network
zig build dev -- agents              # what the App declares
zig build dev -- graph handle_ticket # Mermaid
ANTHROPIC_API_KEY=... OPENAI_API_KEY=... zig build dev -- chat support
zig build lib                        # libsupport + support.h
zig build -Dtarget=aarch64-linux-musl -Doptimize=ReleaseSmall
```

## Developing zastra

```sh
zig build test                  # unit, integration, golden and compile-fail tests
zig build golden -- --update    # refresh golden files
zig build compile-fail          # compile-fail tests only
zig build size                  # binary-size budgets (aarch64-linux-musl, ReleaseSmall)
zig build models-update         # regenerate the model catalog from tools/models-update/sources.json
zig build docs                  # API reference into zig-out/docs
```

`PLAN.md` holds the scope, architecture and decisions. `sketch/` is the consumer-facing API.

## License

MIT. See [LICENSE](LICENSE).
