//! zastra: a Mastra-style agent framework for Zig.
//!
//! Conventionally imported as `const z = @import("zastra");`. This file only
//! re-exports; see PLAN.md §3.1 for the public surface.

const std = @import("std");

pub const schema = struct {
    const json_schema = @import("schema/json_schema.zig");
    const parse_mod = @import("schema/parse.zig");
    pub const Dialect = json_schema.Dialect;
    pub const of = json_schema.of;
    pub const render = json_schema.render;
    pub const parse = parse_mod.parse;
    pub const fromValue = parse_mod.fromValue;
    pub const Issue = parse_mod.Issue;
    pub const stringifyAlloc = @import("schema/json.zig").stringifyAlloc;
    pub const write = @import("schema/json.zig").write;
};

pub const Json = @import("schema/json.zig").Json;

const message = @import("message.zig");
pub const Message = message.Message;
pub const Block = message.Block;
pub const Usage = message.Usage;
pub const FinishReason = message.FinishReason;

pub const catalog = @import("catalog/catalog.zig");
pub const custom = catalog.custom;

// ── declarations ─────────────────────────────────────────────────────────────
pub const Agent = @import("agent/agent.zig").Agent;
pub const App = @import("app.zig").App;
/// `rt.agent(A)`: `.Result`, `.Options`, `.Stream` and the run methods.
pub const AgentHandle = @import("app.zig").AgentHandle;
pub const ToolCtx = @import("context.zig").ToolCtx;
pub const Partial = @import("schema/partial.zig").Partial;
/// `z.migrate(Old, f)`: a working-memory migration step, listed in
/// `pub const migrations = .{ ... }` on the working-memory type (D48).
pub const migrate = @import("schema/migrate.zig").migrate;
pub const mcp = struct {
    pub const stdio = @import("mcp/mcp.zig").stdio;
    pub const http = @import("mcp/mcp.zig").http;
    pub const tools = @import("mcp/mcp.zig").tools;
};
pub const prompt = struct {
    pub const render = @import("prompt/template.zig").render;
    pub const renderAlloc = @import("prompt/template.zig").renderAlloc;
    pub const check = @import("prompt/template.zig").check;
};
pub const trace = struct {
    const t = @import("trace/trace.zig");
    pub const jsonl = t.jsonl;
    pub const otlp = t.otlp;
    pub const OtlpOptions = t.OtlpOptions;
    pub const TraceId = t.TraceId;
    pub const SpanId = t.SpanId;
    pub const Config = t.Config;
    pub const Span = t.Span;
    pub const off: Config = .off;
};
/// `rt.runs()` (PLAN.md §6.9): saved runs of every agent and workflow.
pub const RunInfo = @import("runs.zig").Info;
pub const RunStatus = @import("runs.zig").Status;
pub const RunKind = @import("runs.zig").Kind;
pub const RunFilter = @import("runs.zig").Filter;
pub const Decision = @import("agent/events.zig").Decision;
/// One decision for `resumeRun`/`resumeStream`: `.{ .id = req.id, .decision = .approve }`.
pub const ApprovalDecision = @import("agent/run.zig").ApprovalDecision;

// ── workflows ────────────────────────────────────────────────────────────────
pub const Workflow = @import("workflow/workflow.zig").Workflow;
pub const StepCtx = @import("workflow/step.zig").StepCtx;
pub const Suspendable = @import("workflow/step.zig").Suspendable;
/// `Suspend` for a step that runs an agent with approval-gated tools (D34).
pub const Approvals = @import("workflow/step.zig").Approvals;
/// `Resume` for such a step: `.{ .approve = &.{id}, .deny = &.{.{ .id = id, .reason = "..." }} }`.
pub const Decisions = @import("workflow/step.zig").Decisions;
pub const Retry = @import("workflow/step.zig").Retry;
pub const Backoff = @import("workflow/step.zig").Backoff;
pub const initial = @import("workflow/step.zig").initial;
pub const otherwise = @import("workflow/step.zig").otherwise;
pub const step = struct {
    pub const agent = @import("workflow/step.zig").agentStep;
    pub const parallel = @import("workflow/step.zig").parallel;
    /// `z.step.loop(Body, .{ .until, .max, .on_limit })` (D45).
    pub const loop = @import("workflow/step.zig").loop;
    /// Names a `z.step.agent(A, ...)` step in `resumeStep`.
    pub const agentOf = @import("workflow/step.zig").agentOf;
};

pub const testing = struct {
    const h = @import("testing/harness.zig");
    pub const harness = h.harness;
    pub const Harness = h.Harness;
    pub const Step = h.Step;
    pub const expectSuspended = h.expectSuspended;
    /// The saved-run id of a workflow step's `n`th agent call (D63).
    pub const childRunId = @import("runs.zig").childId;
    const arb = @import("testing/arbitrary.zig");
    pub const arbitrary = arb.arbitrary;
    pub const Gen = arb.Gen;
    pub const GenOptions = arb.Options;
    pub const expectRoundTrip = arb.expectRoundTrip;
    pub const RoundTripOptions = arb.RoundTripOptions;
    pub const roundTrip = arb.roundTrip;
    pub const fuzzTool = @import("testing/fuzz_tool.zig").fuzzTool;
};
pub const ToolResult = @import("agent/events.zig").ToolResult;
pub const StepFinish = @import("agent/events.zig").StepFinish;
pub const Finish = @import("agent/events.zig").Finish;
pub const McpCall = @import("agent/events.zig").McpCall;

/// The provider layer. Most apps never touch it directly; it's public for
/// `rt.model(...)`-style raw use, custom transports and tests.
pub const provider = struct {
    const p = @import("provider/provider.zig");
    pub const Impl = p.Impl;
    pub const Request = p.Request;
    pub const Prefix = p.Prefix;
    pub const PrefixParts = p.PrefixParts;
    pub const ToolDef = p.ToolDef;
    pub const Event = p.Event;
    pub const Delta = p.Delta;
    pub const Finish = p.Finish;
    pub const Diagnostic = p.Diagnostic;
    pub const Error = p.Error;
    pub const anthropic = @import("provider/anthropic.zig");
    pub const openai_responses = @import("provider/openai_responses.zig");
    pub const openai_compat = @import("provider/openai_compat.zig");
    pub const http = @import("provider/http.zig");
    pub const sse = @import("provider/sse.zig");
};

/// `dev serve` (PLAN.md §19.2): the dev CLI's commands over HTTP.
pub const dev = struct {
    const s = @import("dev/serve.zig");
    pub const serve = s.serve;
    pub const Server = s.Server;
    pub const ServeOptions = s.Options;
};

pub const fmt = struct {
    pub const json = @import("schema/json.zig").fmt;
};

/// The C ABI and App manifest (used by `z.addCLib` and the dev CLI).
pub const capi = struct {
    pub const exportAll = @import("capi/capi.zig").exportAll;
    pub const header = @import("capi/header.zig");
    pub const manifest = @import("capi/manifest.zig");
};

/// Internal: comptime reflection and error helpers (stable for zastra's own
/// build helpers, not part of the public API).
pub const meta = struct {
    pub const errors = @import("meta/errors.zig");
    pub const reflect = @import("meta/reflect.zig");
    pub const fingerprint = @import("meta/fingerprint.zig");
};

test {
    std.testing.refAllDecls(@This());
    _ = @import("meta/errors.zig");
    _ = @import("meta/reflect.zig");
    _ = @import("meta/fingerprint.zig");
    _ = @import("schema/json_schema.zig");
    _ = @import("schema/json.zig");
    _ = @import("schema/parse.zig");
    _ = @import("schema/parse_test.zig");
    _ = @import("message.zig");
    _ = @import("catalog/catalog.zig");
    _ = @import("provider/sse.zig");
    _ = @import("provider/http.zig");
    _ = @import("provider/provider.zig");
    _ = @import("tool.zig");
    _ = @import("trace/trace.zig");
    _ = @import("prompt/template.zig");
    _ = @import("meta/make.zig");
    _ = @import("schema/partial.zig");
    _ = @import("schema/migrate.zig");
    _ = @import("schema/stream_parse.zig");
    _ = @import("schema/comptime_json.zig");
    _ = @import("dev/serve.zig");
    _ = @import("storage/memory_store.zig");
    _ = @import("storage/sqlite.zig");
    _ = @import("storage/conformance_test.zig");
    _ = @import("runs.zig");
    _ = @import("mcp/protocol.zig");
    _ = @import("mcp/validate.zig");
}
