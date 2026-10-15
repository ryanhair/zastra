//! Scripted models (PLAN.md §10): typed script steps rendered into the
//! provider's own SSE wire format, so tests run the real provider parser and
//! agent loop without network access.

const std = @import("std");
const json = @import("../schema/json.zig");
const catalog = @import("../catalog/catalog.zig");
const agent_mod = @import("../agent/agent.zig");
const Allocator = std.mem.Allocator;
const Writer = std.Io.Writer;

pub const max_calls_per_step = 8;

/// One scripted model turn for agent `A`.
pub fn Step(comptime A: type) type {
    const has_calls = @typeInfo(A.ToolCall).@"union".fields.len > 0;
    const Calls = if (has_calls) struct { buf: [max_calls_per_step]A.ToolCall = undefined, len: usize = 0 } else void;
    return struct {
        const Self = @This();

        kind: Kind,
        /// Reasoning the model streams before the step's content.
        reasoning: ?[]const u8 = null,

        pub const Kind = union(enum) {
            reply: []const u8,
            calls: Calls,
            output_value: A.Output,
            raw_text: []const u8,
            raw_call: struct { name: []const u8, args_json: []const u8 },
        };

        /// The model answers with text.
        pub fn text(t: []const u8) Self {
            return .{ .kind = .{ .reply = t } };
        }

        /// `step`, preceded by reasoning (Anthropic thinking with a signature,
        /// an OpenAI reasoning item with a summary and encrypted content, or
        /// `reasoning_content` on OpenAI-compatible servers).
        pub fn withReasoning(r: []const u8, step: Self) Self {
            var s = step;
            s.reasoning = r;
            return s;
        }

        /// The model calls tool `T` with `input`. The input is typed against
        /// the tool, so a wrong argument fails to compile.
        pub fn tool(comptime T: type, input: T.Input) Self {
            const name = comptime toolName(T);
            var s: Self = .{ .kind = .{ .calls = .{} } };
            s.kind.calls.buf[0] = @unionInit(A.ToolCall, name, input);
            s.kind.calls.len = 1;
            return s;
        }

        /// Several tool calls in one turn (parallel tool use).
        pub fn tools(calls: []const A.ToolCall) Self {
            var s: Self = .{ .kind = .{ .calls = .{} } };
            for (calls, 0..) |c, i| s.kind.calls.buf[i] = c;
            s.kind.calls.len = calls.len;
            return s;
        }

        /// The model produces the agent's typed output.
        pub fn output(v: A.Output) Self {
            return .{ .kind = .{ .output_value = v } };
        }

        /// The model calls a tool by name with raw JSON arguments, including
        /// zastra's internal tools (`update_working_memory`, `final_answer`).
        pub fn call(name: []const u8, args_json: []const u8) Self {
            return .{ .kind = .{ .raw_call = .{ .name = name, .args_json = args_json } } };
        }

        /// The model answers with raw text (e.g. malformed JSON, to test repair).
        pub fn raw(t: []const u8) Self {
            return .{ .kind = .{ .raw_text = t } };
        }

        fn toolName(comptime T: type) []const u8 {
            inline for (A.tools) |TI| if (TI.Tool == T) return TI.name;
            @compileError("zastra: h.script(" ++ A.id ++ ", ...): " ++ @import("../meta/reflect.zig").shortTypeName(T) ++ " is not a tool of agent '" ++ A.id ++ "'");
        }
    };
}

/// Render one step as an SSE response body for `A`'s provider.
pub fn render(comptime A: type, gpa: Allocator, step: Step(A), n: usize) ![]u8 {
    var tmp: std.heap.ArenaAllocator = .init(gpa);
    defer tmp.deinit();
    const scratch = tmp.allocator();
    var aw: Writer.Allocating = .init(gpa);
    errdefer aw.deinit();
    const w = &aw.writer;
    const Blocks = struct { text: ?[]const u8 = null, tools: []const Tool = &.{} };
    var tool_buf: [max_calls_per_step]Tool = undefined;
    var b: Blocks = .{};
    switch (step.kind) {
        .reply, .raw_text => |t| b.text = t,
        .raw_call => |c| {
            tool_buf[0] = .{ .name = c.name, .args = c.args_json };
            b.tools = tool_buf[0..1];
        },
        .output_value => |v| {
            const j = try json.stringifyAlloc(scratch, v);
            if (A.native_structured_output) b.text = j else {
                tool_buf[0] = .{ .name = agent_mod.final_answer_tool, .args = j };
                b.tools = tool_buf[0..1];
            }
        },
        .calls => |c| if (@TypeOf(c) != void) {
            for (c.buf[0..c.len], 0..) |call, i| {
                switch (call) {
                    inline else => |input, tag| {
                        if (comptime std.mem.eql(u8, @tagName(tag), "mcp")) {
                            tool_buf[i] = .{ .name = try std.fmt.allocPrint(scratch, "{s}__{s}", .{ input.server, input.tool }), .args = input.args_json };
                        } else {
                            tool_buf[i] = .{ .name = @tagName(tag), .args = try json.stringifyAlloc(scratch, input) };
                        }
                    },
                }
            }
            b.tools = tool_buf[0..c.len];
        },
    }
    switch (A.model.api) {
        .anthropic => try anthropic(w, step.reasoning, b.text, b.tools, n),
        .openai_responses => try responses(w, step.reasoning, b.text, b.tools, n),
        .openai_compat => try openai(w, step.reasoning, b.text, b.tools, n),
    }
    return aw.toOwnedSlice();
}

const Tool = struct { name: []const u8, args: []const u8 };

fn data(w: *Writer, event: ?[]const u8, comptime fmt: []const u8, args: anytype) !void {
    if (event) |e| try w.print("event: {s}\n", .{e});
    try w.writeAll("data: ");
    try w.print(fmt, args);
    try w.writeAll("\n\n");
}

fn anthropic(w: *Writer, reasoning: ?[]const u8, text: ?[]const u8, tools: []const Tool, n: usize) !void {
    try data(w, "message_start", "{{\"type\":\"message_start\",\"message\":{{\"id\":\"msg_scripted_{d}\",\"type\":\"message\",\"role\":\"assistant\",\"content\":[],\"usage\":{{\"input_tokens\":10,\"output_tokens\":1}}}}}}", .{n});
    var idx: usize = 0;
    if (reasoning) |r| {
        try data(w, "content_block_start", "{{\"type\":\"content_block_start\",\"index\":{d},\"content_block\":{{\"type\":\"thinking\",\"thinking\":\"\"}}}}", .{idx});
        try w.print("event: content_block_delta\ndata: {{\"type\":\"content_block_delta\",\"index\":{d},\"delta\":{{\"type\":\"thinking_delta\",\"thinking\":", .{idx});
        try json.writeString(r, w);
        try w.writeAll("}}\n\n");
        try data(w, "content_block_delta", "{{\"type\":\"content_block_delta\",\"index\":{d},\"delta\":{{\"type\":\"signature_delta\",\"signature\":\"sig_scripted_{d}\"}}}}", .{ idx, n });
        try data(w, "content_block_stop", "{{\"type\":\"content_block_stop\",\"index\":{d}}}", .{idx});
        idx += 1;
    }
    if (text) |t| {
        try data(w, "content_block_start", "{{\"type\":\"content_block_start\",\"index\":{d},\"content_block\":{{\"type\":\"text\",\"text\":\"\"}}}}", .{idx});
        try w.print("event: content_block_delta\ndata: {{\"type\":\"content_block_delta\",\"index\":{d},\"delta\":{{\"type\":\"text_delta\",\"text\":", .{idx});
        try json.writeString(t, w);
        try w.writeAll("}}\n\n");
        try data(w, "content_block_stop", "{{\"type\":\"content_block_stop\",\"index\":{d}}}", .{idx});
        idx += 1;
    }
    for (tools, 0..) |t, i| {
        try w.print("event: content_block_start\ndata: {{\"type\":\"content_block_start\",\"index\":{d},\"content_block\":{{\"type\":\"tool_use\",\"id\":\"toolu_scripted_{d}_{d}\",\"name\":", .{ idx, n, i });
        try json.writeString(t.name, w);
        try w.writeAll(",\"input\":{}}}\n\n");
        try w.print("event: content_block_delta\ndata: {{\"type\":\"content_block_delta\",\"index\":{d},\"delta\":{{\"type\":\"input_json_delta\",\"partial_json\":", .{idx});
        try json.writeString(t.args, w);
        try w.writeAll("}}\n\n");
        try data(w, "content_block_stop", "{{\"type\":\"content_block_stop\",\"index\":{d}}}", .{idx});
        idx += 1;
    }
    try data(w, "message_delta", "{{\"type\":\"message_delta\",\"delta\":{{\"stop_reason\":\"{s}\"}},\"usage\":{{\"output_tokens\":5}}}}", .{if (tools.len > 0) "tool_use" else "end_turn"});
    try data(w, "message_stop", "{{\"type\":\"message_stop\"}}", .{});
}

fn openai(w: *Writer, reasoning: ?[]const u8, text: ?[]const u8, tools: []const Tool, n: usize) !void {
    _ = n;
    if (reasoning) |r| {
        try w.writeAll("data: {\"choices\":[{\"index\":0,\"delta\":{\"role\":\"assistant\",\"reasoning_content\":");
        try json.writeString(r, w);
        try w.writeAll("},\"finish_reason\":null}]}\n\n");
    }
    if (text) |t| {
        try w.writeAll("data: {\"choices\":[{\"index\":0,\"delta\":{\"role\":\"assistant\",\"content\":");
        try json.writeString(t, w);
        try w.writeAll("},\"finish_reason\":null}]}\n\n");
    }
    for (tools, 0..) |t, i| {
        try w.print("data: {{\"choices\":[{{\"index\":0,\"delta\":{{\"tool_calls\":[{{\"index\":{d},\"id\":\"call_scripted_{d}\",\"type\":\"function\",\"function\":{{\"name\":", .{ i, i });
        try json.writeString(t.name, w);
        try w.writeAll(",\"arguments\":");
        try json.writeString(t.args, w);
        try w.writeAll("}}]},\"finish_reason\":null}]}\n\n");
    }
    try w.print("data: {{\"choices\":[{{\"index\":0,\"delta\":{{}},\"finish_reason\":\"{s}\"}}]}}\n\n", .{if (tools.len > 0) "tool_calls" else "stop"});
    try w.writeAll("data: {\"choices\":[],\"usage\":{\"prompt_tokens\":10,\"completion_tokens\":5}}\n\n");
    try w.writeAll("data: [DONE]\n\n");
}

fn responses(w: *Writer, reasoning: ?[]const u8, text: ?[]const u8, tools: []const Tool, n: usize) !void {
    try data(w, "response.created", "{{\"type\":\"response.created\",\"response\":{{\"id\":\"resp_scripted_{d}\",\"status\":\"in_progress\",\"output\":[]}}}}", .{n});
    var idx: usize = 0;
    if (reasoning) |r| {
        try data(w, "response.output_item.added", "{{\"type\":\"response.output_item.added\",\"output_index\":{d},\"item\":{{\"id\":\"rs_scripted_{d}\",\"type\":\"reasoning\",\"summary\":[]}}}}", .{ idx, n });
        try data(w, "response.reasoning_summary_part.added", "{{\"type\":\"response.reasoning_summary_part.added\",\"output_index\":{d},\"summary_index\":0}}", .{idx});
        try w.print("event: response.reasoning_summary_text.delta\ndata: {{\"type\":\"response.reasoning_summary_text.delta\",\"output_index\":{d},\"summary_index\":0,\"delta\":", .{idx});
        try json.writeString(r, w);
        try w.writeAll("}\n\n");
        try data(w, "response.output_item.done", "{{\"type\":\"response.output_item.done\",\"output_index\":{d},\"item\":{{\"id\":\"rs_scripted_{d}\",\"type\":\"reasoning\",\"encrypted_content\":\"enc_scripted_{d}\"}}}}", .{ idx, n, n });
        idx += 1;
    }
    if (text) |t| {
        try data(w, "response.output_item.added", "{{\"type\":\"response.output_item.added\",\"output_index\":{d},\"item\":{{\"id\":\"msg_scripted_{d}\",\"type\":\"message\",\"role\":\"assistant\",\"content\":[]}}}}", .{ idx, n });
        try w.print("event: response.output_text.delta\ndata: {{\"type\":\"response.output_text.delta\",\"output_index\":{d},\"content_index\":0,\"delta\":", .{idx});
        try json.writeString(t, w);
        try w.writeAll("}\n\n");
        try data(w, "response.output_item.done", "{{\"type\":\"response.output_item.done\",\"output_index\":{d},\"item\":{{\"type\":\"message\"}}}}", .{idx});
        idx += 1;
    }
    for (tools, 0..) |t, i| {
        try w.print("event: response.output_item.added\ndata: {{\"type\":\"response.output_item.added\",\"output_index\":{d},\"item\":{{\"type\":\"function_call\",\"call_id\":\"call_scripted_{d}_{d}\",\"arguments\":\"\",\"name\":", .{ idx, n, i });
        try json.writeString(t.name, w);
        try w.writeAll("}}\n\n");
        try w.print("event: response.function_call_arguments.delta\ndata: {{\"type\":\"response.function_call_arguments.delta\",\"output_index\":{d},\"delta\":", .{idx});
        try json.writeString(t.args, w);
        try w.writeAll("}\n\n");
        try data(w, "response.output_item.done", "{{\"type\":\"response.output_item.done\",\"output_index\":{d},\"item\":{{\"type\":\"function_call\"}}}}", .{idx});
        idx += 1;
    }
    try data(w, "response.completed", "{{\"type\":\"response.completed\",\"response\":{{\"id\":\"resp_scripted_{d}\",\"status\":\"completed\",\"usage\":{{\"input_tokens\":10,\"input_tokens_details\":{{\"cached_tokens\":0}},\"output_tokens\":5}}}}}}", .{n});
}
