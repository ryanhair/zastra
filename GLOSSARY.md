# zastra

An agent framework for Zig: agents, tools, workflows, memory, MCP and tracing, declared at compile time and run against hosted model APIs.

## Models and providers

**Provider**:
The vendor named before the slash in a model string such as `"anthropic/claude-sonnet-5-5"`. One provider can be reached through more than one API.
_Avoid_: vendor, backend

**API**:
One wire protocol a model is called through: Anthropic Messages, OpenAI Responses, or Chat Completions (OpenAI-compatible servers). Every model has exactly one.
_Avoid_: endpoint, provider (when the protocol is meant)

**Wire module**:
The part of zastra that speaks one API: it writes that API's requests and reads its streamed responses into zastra's events and messages.
_Avoid_: adapter, provider module, dialect, driver

**Capabilities**:
What an API can express, such as whether reasoning takes a token budget or how it is turned off, as declared by its wire module. Distinct from what one model accepts, which comes from the catalog.
_Avoid_: features, supports (that is the per-model catalog entry)

**Schema dialect**:
The variant of JSON Schema an API accepts for tool inputs or structured output; a type renders differently in each.
_Avoid_: dialect (alone), wire format

**Prefix**:
The part of a request that is fixed for an agent (model, settings, instructions, tool definitions), precomputed so prompt caches hit and saved runs can be matched to the agent version that made them.
_Avoid_: header, template

## Runs

**Saved run**:
The stored record of one agent or workflow run: who owns it, its status, and enough state to resume it. Workflow runs are always saved; agent runs only once they suspend for approval.
_Avoid_: snapshot (that is only the saved state), checkpoint

**Child run**:
A saved agent run started by a workflow step, named after the workflow run and step so a replay finds it again.
_Avoid_: sub-run, nested run

**Operations**:
The JSON-in, JSON-out way to start, resume, cancel and inspect an App's runs, shared by the C ABI, `dev serve` and the dev CLI.
_Avoid_: handlers, endpoints

## Testing

**Cassette**:
A recorded or hand-written provider response in the API's real wire format, replayed in tests instead of calling the provider.
_Avoid_: fixture, mock response
