# Changelog

## v1.1.0 (unreleased)

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
