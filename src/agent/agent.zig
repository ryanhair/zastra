//! `z.Agent(Ctx, config)` (PLAN.md §3, §6.4). Everything here is comptime:
//! config validation, catalog capability checks, the tool table, the
//! generated `ToolCall` / `ApprovalCall` / `Event` unions and the request
//! prefix.

const std = @import("std");
const errors = @import("../meta/errors.zig");
const reflect = @import("../meta/reflect.zig");
const make = @import("../meta/make.zig");
const fingerprint = @import("../meta/fingerprint.zig");
const catalog = @import("../catalog/catalog.zig");
const tool = @import("../tool.zig");
const json_schema = @import("../schema/json_schema.zig");
const comptime_json = @import("../schema/comptime_json.zig");
const partial = @import("../schema/partial.zig");
const provider = @import("../provider/provider.zig");
const mcp = @import("../mcp/mcp.zig");
const ev = @import("events.zig");

pub const known_config = [_][]const u8{
    "name",        "model",    "instructions", "tools",            "output",   "memory",
    "max_steps",   "max_tokens", "temperature", "effort",          "provider_options", "examples",
    "allow",       "description",
};

const known_memory = [_][]const u8{ "history", "working" };
const known_history = [_][]const u8{"last_messages"};

pub const final_answer_tool = "final_answer";
pub const working_memory_tool = "update_working_memory";

pub fn isAgent(comptime T: type) bool {
    return @TypeOf(T) == type and reflect.isContainer(T) and @hasDecl(T, "zastra_agent");
}

pub fn Agent(comptime Ctx_: type, comptime cfg: anytype) type {
    comptime {
        @setEvalBranchQuota(20_000_000);
        const C = @TypeOf(cfg);
        if (@typeInfo(C) != .@"struct") errors.fail("z.Agent(Ctx, config): config must be a struct literal like `.{{ .name = \"support\", .model = \"anthropic/claude-sonnet-5-5\" }}`", .{});
        reflect.checkConfigFields(C, &known_config, "z.Agent(...) config");
        if (!@hasField(C, "name")) errors.fail("z.Agent(...) config is missing `.name`. Agents are types returned by a function, so zastra can't see the name of the declaration; add `.name = \"support\"` (PLAN.md D20)", .{});
        const agent_name: []const u8 = cfg.name;
        if (!tool.validName(agent_name)) errors.fail("agent name \"{s}\" must match ^[a-zA-Z0-9_-]{{1,64}}$", .{agent_name});
        const who = "agent '" ++ agent_name ++ "'";
        if (!@hasField(C, "model")) errors.fail("{s} is missing `.model`, e.g. `.model = \"anthropic/claude-sonnet-5-5\"`", .{who});
        const spec = catalog.resolve(cfg.model, who);

        // ── tools ────────────────────────────────────────────────────────
        var user_tools: []const type = &.{};
        var mcp_sets: []const type = &.{};
        if (@hasField(C, "tools")) {
            const TT = @TypeOf(cfg.tools);
            if (!reflect.isTuple(TT)) errors.fail("{s}: `.tools` must be a tuple of tool types, like `.{{ LookupOrder, IssueRefund }}`", .{who});
            for (0..std.meta.fields(TT).len) |i| {
                const x = cfg.tools[i];
                if (@TypeOf(x) != type) errors.fail("{s}: `.tools` entry {d} is a value of type {s}, not a tool type", .{ who, i, @typeName(@TypeOf(x)) });
                if (mcp.isToolSet(x)) {
                    mcp_sets = mcp_sets ++ &[_]type{x};
                } else {
                    user_tools = user_tools ++ &[_]type{tool.Info(x, Ctx_, agent_name)};
                }
            }
        }
        for (user_tools, 0..) |a, i| for (user_tools[0..i]) |b| if (std.mem.eql(u8, a.name, b.name))
            errors.fail("{s}: two tools are named '{s}' ({s} and {s}); set `pub const name` on one of them", .{ who, a.name, b.type_name, a.type_name });
        for (user_tools) |t| if (std.mem.eql(u8, t.name, final_answer_tool) or std.mem.eql(u8, t.name, working_memory_tool))
            errors.fail("{s}: tool name '{s}' is reserved by zastra; set `pub const name` on {s}", .{ who, t.name, t.type_name });
        if ((user_tools.len > 0 or mcp_sets.len > 0) and !spec.supports.tools)
            errors.fail("{s}: model \"{s}\" doesn't support tool use, but the agent declares `.tools`", .{ who, spec.fullName() });

        // ── effects (§5.12) ──────────────────────────────────────────────
        if (@hasField(C, "allow")) {
            var allowed = tool.Effects.initEmpty();
            const AT = @TypeOf(cfg.allow);
            if (!reflect.isTuple(AT)) errors.fail("{s}: `.allow` must be a tuple of effects like `.{{ .reads, .network }}`", .{who});
            for (0..std.meta.fields(AT).len) |i| {
                const tag = @tagName(cfg.allow[i]);
                const e = std.meta.stringToEnum(tool.Effect, tag) orelse errors.fail("{s}: `.allow` has unknown effect `.{s}`{s}", .{ who, tag, errors.didYouMean(tag, reflect.fieldNames(tool.Effect)) });
                allowed.insert(e);
            }
            for (user_tools) |t| {
                var it = t.effect_set.iterator();
                while (it.next()) |e| if (!allowed.contains(e))
                    errors.fail("{s} doesn't allow effect `.{s}`, but tool '{s}' declares it; add `.{s}` to the agent's `.allow` or remove the tool", .{ who, @tagName(e), t.type_name, @tagName(e) });
            }
        }

        // ── output ───────────────────────────────────────────────────────
        const has_output = @hasField(C, "output");
        const Output_ = if (has_output) cfg.output else void;
        if (has_output) {
            if (@TypeOf(cfg.output) != type) errors.fail("{s}: `.output` must be a type, e.g. `.output = Triage`", .{who});
            if (@typeInfo(Output_) != .@"struct") errors.fail("{s}: `.output` must be a struct type (structured output is a JSON object); got {s}", .{ who, @typeName(Output_) });
            _ = json_schema.of(Output_); // surface schema errors here, against the user's type
            if (!spec.supports.structured_output and !spec.supports.tools)
                errors.fail("{s}: model \"{s}\" supports neither structured output nor tool use, so `.output` can't be enforced", .{ who, spec.fullName() });
        }
        const native_output = has_output and spec.supports.structured_output and
            !(spec.api == .openai_compat and json_schema.containsJson(Output_));

        // ── memory ───────────────────────────────────────────────────────
        var history_limit: u32 = 0;
        var Working_: type = void;
        if (@hasField(C, "memory")) {
            const M = @TypeOf(cfg.memory);
            reflect.checkConfigFields(M, &known_memory, who ++ " `.memory`");
            if (@hasField(M, "history")) {
                reflect.checkConfigFields(@TypeOf(cfg.memory.history), &known_history, who ++ " `.memory.history`");
                history_limit = if (@hasField(@TypeOf(cfg.memory.history), "last_messages")) cfg.memory.history.last_messages else 20;
            }
            if (@hasField(M, "working")) {
                if (@TypeOf(cfg.memory.working) != type or @typeInfo(cfg.memory.working) != .@"struct")
                    errors.fail("{s}: `.memory.working` must be a struct type", .{who});
                Working_ = cfg.memory.working;
                for (std.meta.fields(Working_)) |f| if (f.default_value_ptr == null)
                    errors.fail("{s}: working memory field `{s}.{s}` needs a default value (working memory starts empty)", .{ who, reflect.shortTypeName(Working_), f.name });
                if (!spec.supports.tools) errors.fail("{s}: working memory needs a model with tool use", .{who});
            }
        }
        const has_working = Working_ != void;

        // ── limits & options ─────────────────────────────────────────────
        const max_tokens: u32 = if (@hasField(C, "max_tokens")) cfg.max_tokens else @min(16_000, spec.max_output);
        if (max_tokens > spec.max_output) errors.fail("{s}: `.max_tokens = {d}` exceeds model \"{s}\"'s maximum output of {d} tokens", .{ who, max_tokens, spec.fullName(), spec.max_output });
        const has_tools = user_tools.len > 0 or mcp_sets.len > 0;
        const max_steps: u32 = if (@hasField(C, "max_steps")) cfg.max_steps else if (has_tools or has_working or (has_output and !native_output)) 10 else 2;
        if (max_steps == 0) errors.fail("{s}: `.max_steps` must be at least 1", .{who});
        const temperature: ?f64 = if (@hasField(C, "temperature")) cfg.temperature else null;
        if (temperature != null and !spec.supports.temperature)
            errors.fail("{s}: model \"{s}\" doesn't accept a custom `.temperature`; remove it (use `.effort` to trade quality for speed)", .{ who, spec.fullName() });
        const effort: ?provider.Effort = if (@hasField(C, "effort")) blk: {
            const tag = @tagName(cfg.effort);
            break :blk std.meta.stringToEnum(provider.Effort, tag) orelse errors.fail("{s}: unknown `.effort = .{s}`{s}", .{ who, tag, errors.didYouMean(tag, reflect.fieldNames(provider.Effort)) });
        } else null;

        // ── instructions & examples (§5.10) ──────────────────────────────
        var system: []const u8 = if (@hasField(C, "instructions")) cfg.instructions else "";
        if (@hasField(C, "examples")) {
            if (!has_output) errors.fail("{s}: `.examples` need `.output` (each example's `.out` is checked against the output type)", .{who});
            const E = @TypeOf(cfg.examples);
            const n = switch (@typeInfo(E)) {
                .pointer => cfg.examples.len,
                else => std.meta.fields(E).len,
            };
            var text: []const u8 = "\n\nExamples:";
            for (0..n) |i| {
                const ex = cfg.examples[i];
                if (!@hasField(@TypeOf(ex), "in") or !@hasField(@TypeOf(ex), "out")) errors.fail("{s}: example {d} needs `.in` and `.out`", .{ who, i });
                const out: Output_ = ex.out; // a renamed field breaks here, at compile time
                const in_text = if (reflect.isString(@TypeOf(ex.in))) ex.in else comptime_json.of(@TypeOf(ex.in), ex.in);
                text = text ++ "\n\nInput: " ++ in_text ++ "\nOutput: " ++ comptime_json.of(Output_, out);
            }
            system = system ++ text;
        }
        if (has_output and !native_output)
            system = system ++ (if (system.len > 0) "\n\n" else "") ++ "When you have the final answer, call the `" ++ final_answer_tool ++ "` tool with it. Do not answer in plain text.";

        // ── tool definitions (comptime, provider dialect) ───────────────
        const tool_dialect: json_schema.Dialect = if (spec.api == .anthropic) .anthropic else .openai;
        const output_dialect: json_schema.Dialect = if (spec.api == .anthropic) .anthropic_output else .openai;
        var defs: []const provider.ToolDef = &.{};
        for (user_tools) |t| defs = defs ++ &[_]provider.ToolDef{.{
            .name = t.name,
            .description = t.description,
            .schema = json_schema.render(t.Input, tool_dialect),
            .strict_ok = !json_schema.containsJson(t.Input),
        }};
        const WorkingPatch = if (has_working) partial.Partial(Working_) else void;
        if (has_working) defs = defs ++ &[_]provider.ToolDef{.{
            .name = working_memory_tool,
            .description = "Update what you remember about this user across conversations. Only set the fields that changed; omitted fields keep their current value.",
            .schema = json_schema.render(WorkingPatch, tool_dialect),
            .strict_ok = false,
        }};
        if (has_output and !native_output) defs = defs ++ &[_]provider.ToolDef{.{
            .name = final_answer_tool,
            .description = "Submit the final answer.",
            .schema = json_schema.render(Output_, tool_dialect),
            .strict_ok = !json_schema.containsJson(Output_),
        }};

        const parts: provider.PrefixParts = .{
            .spec = spec,
            .system = if (system.len > 0) system else null,
            .tools = defs,
            .output = if (native_output) .{ .name = reflect.snakeCase(reflect.shortTypeName(Output_)), .schema = json_schema.render(Output_, output_dialect) } else null,
            .temperature = temperature,
            .effort = effort,
            .extra = if (@hasField(C, "provider_options")) cfg.provider_options else null,
            .dynamic_tools = mcp_sets.len > 0,
        };
        const prefix_ = provider.Impl(spec.api).buildPrefix(parts);

        // ── generated unions ─────────────────────────────────────────────
        var call_names: []const []const u8 = &.{};
        var call_types: []const type = &.{};
        var appr_names: []const []const u8 = &.{};
        var appr_types: []const type = &.{};
        for (user_tools) |t| {
            call_names = call_names ++ &[_][]const u8{t.name};
            call_types = call_types ++ &[_]type{t.Input};
            if (t.approval_kind != .never) {
                appr_names = appr_names ++ &[_][]const u8{t.name};
                appr_types = appr_types ++ &[_]type{t.Input};
            }
        }
        if (mcp_sets.len > 0) {
            call_names = call_names ++ &[_][]const u8{"mcp"};
            call_types = call_types ++ &[_]type{ev.McpCall};
        }
        const ToolCall_ = make.TaggedUnion(call_names, call_types);
        const ApprovalCall_ = make.TaggedUnion(appr_names, appr_types);

        var ev_names: []const []const u8 = &.{ "text_delta", "reasoning_delta" };
        var ev_types: []const type = &.{ []const u8, []const u8 };
        if (has_tools) {
            ev_names = ev_names ++ &[_][]const u8{ "tool_call", "tool_result" };
            ev_types = ev_types ++ &[_]type{ ToolCall_, ev.ToolResult };
        }
        if (appr_names.len > 0) {
            ev_names = ev_names ++ &[_][]const u8{"approval_request"};
            ev_types = ev_types ++ &[_]type{ev.ApprovalRequest(ApprovalCall_)};
        }
        ev_names = ev_names ++ &[_][]const u8{ "step_finish", "finish" };
        ev_types = ev_types ++ &[_]type{ ev.StepFinish, ev.Finish };
        const Event_ = make.TaggedUnion(ev_names, ev_types);

        const tools_tuple = user_tools;
        const has_approvals_ = appr_names.len > 0;
        const history_limit_final = history_limit;
        const Working_final = Working_;
        const defs_final = defs;
        const mcp_tuple = mcp_sets;
        const final_system = system;
        const desc: []const u8 = if (@hasField(C, "description")) cfg.description else "";

        return struct {
            pub const zastra_agent = true;
            pub const id = agent_name;
            pub const description = desc;
            pub const Ctx = Ctx_;
            pub const model = spec;
            pub const instructions = final_system;
            /// `tool.Info` types for the agent's own tools, in declaration order.
            pub const tools = tools_tuple;
            /// `z.mcp.tools(...)` sets.
            pub const mcp_tools = mcp_tuple;
            pub const Output = Output_;
            pub const has_output_type = has_output;
            /// Structured output uses the provider's native JSON-schema mode
            /// (otherwise a synthetic `final_answer` tool).
            pub const native_structured_output = native_output;
            pub const Working = Working_final;
            pub const WorkingUpdate = WorkingPatch;
            pub const has_working_memory = has_working;
            pub const working_fingerprint: u64 = if (has_working) fingerprint.of(Working_final) else 0;
            pub const history_messages = history_limit_final;
            pub const max_steps_default = max_steps;
            pub const max_tokens_default = max_tokens;
            pub const prefix = prefix_;
            pub const prefix_hash = prefix_.hash;
            pub const tool_defs = defs_final;
            pub const ToolCall = ToolCall_;
            pub const ApprovalCall = ApprovalCall_;
            pub const has_approvals = has_approvals_;
            pub const has_tool_events = has_tools;
            pub const Event = Event_;
        };
    }
}
