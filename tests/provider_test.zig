//! Providers against recorded/hand-written SSE cassettes (PLAN.md §10).

const std = @import("std");
const z = @import("zastra");
const P = z.provider;
const t = std.testing;

fn spec(comptime s: []const u8) z.catalog.Spec {
    return comptime z.catalog.resolve(s, "test");
}

const lookup_tool: P.ToolDef = .{
    .name = "lookup_order",
    .description = "Look up an order by its ID.",
    .schema = z.schema.render(struct { order_id: []const u8 }, .anthropic),
};

fn collect(comptime Api: type, arena: std.mem.Allocator, h: *P.http.Http, req: P.Request, text: *std.ArrayList(u8)) !P.Event {
    var s = try Api.Stream.open(arena, h, req);
    defer s.close();
    while (try s.next()) |ev| switch (ev) {
        .delta => |d| switch (d) {
            .text => |x| try text.appendSlice(arena, x),
            else => {},
        },
        .finish => return ev,
    };
    return error.NoFinish;
}

test "anthropic: streaming text" {
    var arena: std.heap.ArenaAllocator = .init(t.allocator);
    defer arena.deinit();
    var rp: P.http.Replay = .init(t.allocator, &.{.{ .url_suffix = "/v1/messages", .body = @embedFile("cassettes/anthropic_text.sse") }});
    defer rp.deinit();
    var h: P.http.Http = .initReplay(t.allocator, t.io, &rp);
    defer h.deinit();

    const prefix = comptime P.anthropic.buildPrefix(.{ .spec = spec("anthropic/claude-haiku-4-5"), .system = "Be brief." });
    var text: std.ArrayList(u8) = .empty;
    const ev = try collect(P.anthropic, arena.allocator(), &h, .{
        .base_url = "https://api.anthropic.com",
        .api_key = "k",
        .prefix = prefix,
        .messages = &.{.user("Hi")},
        .max_tokens = 100,
    }, &text);
    try t.expectEqualStrings("Hi there, friend.", text.items);
    try t.expectEqual(z.FinishReason.end_turn, ev.finish.reason);
    try t.expectEqual(@as(u64, 12), ev.finish.usage.input_tokens);
    try t.expectEqual(@as(u64, 6), ev.finish.usage.output_tokens);
    try t.expectEqualStrings(
        \\{"model":"claude-haiku-4-5","stream":true,"cache_control":{"type":"ephemeral"},"system":[{"type":"text","text":"Be brief.","cache_control":{"type":"ephemeral"}}],"max_tokens":100,"messages":[{"role":"user","content":"Hi"}]}
    , rp.requests.items[0]);
}

test "anthropic: thinking, tool use, opaque blocks and their round-trip" {
    var arena: std.heap.ArenaAllocator = .init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var rp: P.http.Replay = .init(t.allocator, &.{
        .{ .url_suffix = "/v1/messages", .body = @embedFile("cassettes/anthropic_tool.sse") },
        .{ .url_suffix = "/v1/messages", .body = @embedFile("cassettes/anthropic_text.sse") },
    });
    defer rp.deinit();
    var h: P.http.Http = .initReplay(t.allocator, t.io, &rp);
    defer h.deinit();

    const prefix = comptime P.anthropic.buildPrefix(.{ .spec = spec("anthropic/claude-sonnet-4-6"), .tools = &.{lookup_tool} });
    var text: std.ArrayList(u8) = .empty;
    const ev = try collect(P.anthropic, a, &h, .{
        .base_url = "https://api.anthropic.com",
        .api_key = "k",
        .prefix = prefix,
        .messages = &.{.user("Where is ORD-1042?")},
        .max_tokens = 100,
    }, &text);
    const m = ev.finish.message;
    try t.expectEqual(z.FinishReason.tool_use, ev.finish.reason);
    try t.expectEqual(@as(u64, 800), ev.finish.usage.cache_read_tokens);
    const bs = m.content.blocks;
    try t.expectEqual(@as(usize, 4), bs.len);
    try t.expectEqualStrings("Need the order.", bs[0].reasoning.text);
    try t.expectEqualStrings("EqQBCgIYAhIM", bs[0].reasoning.signature.?);
    try t.expectEqualStrings("Let me check.", bs[1].text);
    try t.expectEqualStrings("lookup_order", bs[2].tool_use.name);
    try t.expectEqualStrings("{\"order_id\": \"ORD-1042\"}", bs[2].tool_use.input_json);
    try t.expectEqualStrings("{\"type\":\"redacted_thinking\",\"data\":\"abc123\"}", bs[3].provider_opaque.json);

    // Second request: the assistant turn and a tool result go back unchanged.
    const result: z.Message = .{ .role = .tool, .content = .{ .blocks = &.{.{ .tool_result = .{ .id = "toolu_01", .content = "{\"status\":\"shipped\"}" } }} } };
    text.clearRetainingCapacity();
    _ = try collect(P.anthropic, a, &h, .{
        .base_url = "https://api.anthropic.com",
        .api_key = "k",
        .prefix = prefix,
        .messages = &.{ .user("Where is ORD-1042?"), m, result },
        .max_tokens = 100,
    }, &text);
    const body = rp.requests.items[1];
    try t.expect(std.mem.indexOf(u8, body,
        \\{"role":"assistant","content":[{"type":"thinking","thinking":"Need the order.","signature":"EqQBCgIYAhIM"},{"type":"text","text":"Let me check."},{"type":"tool_use","id":"toolu_01","name":"lookup_order","input":{"order_id": "ORD-1042"}},{"type":"redacted_thinking","data":"abc123"}]}
    ) != null);
    try t.expect(std.mem.indexOf(u8, body,
        \\{"role":"user","content":[{"type":"tool_result","tool_use_id":"toolu_01","content":"{\"status\":\"shipped\"}"}]}
    ) != null);
    // The prefix is byte-identical across requests.
    try t.expect(std.mem.startsWith(u8, rp.requests.items[0], prefix.json));
    try t.expect(std.mem.startsWith(u8, rp.requests.items[1], prefix.json));
}

test "anthropic: error response becomes a diagnostic" {
    var arena: std.heap.ArenaAllocator = .init(t.allocator);
    defer arena.deinit();
    var rp: P.http.Replay = .init(t.allocator, &.{.{ .url_suffix = "/v1/messages", .status = 400, .body = @embedFile("cassettes/anthropic_error.json") }});
    defer rp.deinit();
    var h: P.http.Http = .initReplay(t.allocator, t.io, &rp);
    defer h.deinit();
    var diag: P.Diagnostic = .{};
    const prefix = comptime P.anthropic.buildPrefix(.{ .spec = spec("anthropic/claude-haiku-4-5") });
    const r = P.anthropic.Stream.open(arena.allocator(), &h, .{
        .base_url = "https://api.anthropic.com",
        .api_key = "k",
        .prefix = prefix,
        .messages = &.{.user("Hi")},
        .max_tokens = 100,
        .diag = &diag,
    });
    try t.expectError(error.BadRequest, r);
    try t.expectEqualStrings("anthropic 400 invalid_request_error: max_tokens: Field required", diag.message());
}

test "openai: streaming text with cached-token usage" {
    var arena: std.heap.ArenaAllocator = .init(t.allocator);
    defer arena.deinit();
    var rp: P.http.Replay = .init(t.allocator, &.{.{ .url_suffix = "/chat/completions", .body = @embedFile("cassettes/openai_text.sse") }});
    defer rp.deinit();
    var h: P.http.Http = .initReplay(t.allocator, t.io, &rp);
    defer h.deinit();
    const sp = comptime spec("openai/gpt-5-mini");
    const prefix = comptime P.openai_compat.buildPrefix(.{ .spec = sp, .system = "Be brief." });
    var text: std.ArrayList(u8) = .empty;
    const ev = try collect(P.openai_compat, arena.allocator(), &h, .{
        .base_url = "https://api.openai.com/v1",
        .api_key = "k",
        .prefix = prefix,
        .messages = &.{.user("Hi")},
        .max_tokens = 100,
        .max_tokens_field = sp.max_tokens_field,
    }, &text);
    try t.expectEqualStrings("Hello world", text.items);
    try t.expectEqual(@as(u64, 12), ev.finish.usage.input_tokens);
    try t.expectEqual(@as(u64, 8), ev.finish.usage.cache_read_tokens);
    try t.expectEqualStrings(
        \\{"model":"gpt-5-mini","stream":true,"stream_options":{"include_usage":true},"messages":[{"role":"system","content":"Be brief."},{"role":"user","content":"Hi"}],"max_completion_tokens":100}
    , rp.requests.items[0]);
}

test "openai: parallel tool calls accumulate by index" {
    var arena: std.heap.ArenaAllocator = .init(t.allocator);
    defer arena.deinit();
    var rp: P.http.Replay = .init(t.allocator, &.{.{ .url_suffix = "/chat/completions", .body = @embedFile("cassettes/openai_tool.sse") }});
    defer rp.deinit();
    var h: P.http.Http = .initReplay(t.allocator, t.io, &rp);
    defer h.deinit();
    const prefix = comptime P.openai_compat.buildPrefix(.{ .spec = spec("openai/gpt-5-mini") });
    var text: std.ArrayList(u8) = .empty;
    const ev = try collect(P.openai_compat, arena.allocator(), &h, .{
        .base_url = "https://api.openai.com/v1",
        .api_key = "k",
        .prefix = prefix,
        .messages = &.{.user("Refund ORD-1042")},
        .max_tokens = 100,
    }, &text);
    const bs = ev.finish.message.content.blocks;
    try t.expectEqual(z.FinishReason.tool_use, ev.finish.reason);
    try t.expectEqual(@as(usize, 2), bs.len);
    try t.expectEqualStrings("call_abc", bs[0].tool_use.id);
    try t.expectEqualStrings("{\"order_id\":\"ORD-1042\"}", bs[0].tool_use.input_json);
    try t.expectEqualStrings("issue_refund", bs[1].tool_use.name);
}

test "openai: every event of one chunk arrives, in order, and made-up tool ids match" {
    var arena: std.heap.ArenaAllocator = .init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var rp: P.http.Replay = .init(t.allocator, &.{.{ .url_suffix = "/chat/completions", .body = @embedFile("cassettes/openai_one_chunk.sse") }});
    defer rp.deinit();
    var h: P.http.Http = .initReplay(t.allocator, t.io, &rp);
    defer h.deinit();
    const prefix = comptime P.openai_compat.buildPrefix(.{ .spec = spec("openai/gpt-5-mini") });
    var s = try P.openai_compat.Stream.open(a, &h, .{
        .base_url = "https://api.openai.com/v1",
        .api_key = "k",
        .prefix = prefix,
        .messages = &.{.user("Look up ORD-0 to ORD-9")},
        .max_tokens = 100,
    });
    defer s.close();

    // One chunk: reasoning, content, then a start and an args delta per tool call.
    var kinds: std.ArrayList(u8) = .empty;
    var start_ids: std.ArrayList([]const u8) = .empty;
    var args: [10]std.ArrayList(u8) = @splat(.empty);
    const fin = while (try s.next()) |ev| switch (ev) {
        .delta => |d| switch (d) {
            .reasoning => try kinds.append(a, 'r'),
            .text => try kinds.append(a, 't'),
            .tool_call_start => |c| {
                try kinds.append(a, 's');
                try start_ids.append(a, try a.dupe(u8, c.id));
            },
            .tool_call_args => |c| {
                try kinds.append(a, 'a');
                try args[c.index].appendSlice(a, c.json);
            },
        },
        .finish => |f| break f,
    } else return error.NoFinish;

    try t.expectEqualStrings("rt" ++ "sa" ** 10, kinds.items);
    const bs = fin.message.content.blocks;
    try t.expectEqual(z.FinishReason.tool_use, fin.reason);
    try t.expectEqual(@as(usize, 12), bs.len);
    for (bs[2..], 0..) |b, i| {
        try t.expectEqualStrings(b.tool_use.id, start_ids.items[i]);
        try t.expectEqualStrings(b.tool_use.input_json, args[i].items);
    }
    try t.expectEqualStrings("call_9", bs[11].tool_use.id);
}

test "openai: error response with only a code becomes a diagnostic" {
    var arena: std.heap.ArenaAllocator = .init(t.allocator);
    defer arena.deinit();
    var rp: P.http.Replay = .init(t.allocator, &.{
        .{ .url_suffix = "/chat/completions", .status = 404, .body = @embedFile("cassettes/openai_error.json") },
        .{ .url_suffix = "/chat/completions", .status = 502, .body = "Bad Gateway" },
    });
    defer rp.deinit();
    var h: P.http.Http = .initReplay(t.allocator, t.io, &rp);
    defer h.deinit();
    var diag: P.Diagnostic = .{};
    const prefix = comptime P.openai_compat.buildPrefix(.{ .spec = spec("openai/gpt-5-mini") });
    const req: P.Request = .{
        .base_url = "https://api.groq.com/openai/v1",
        .api_key = "k",
        .prefix = prefix,
        .messages = &.{.user("Hi")},
        .max_tokens = 100,
        .diag = &diag,
    };
    try t.expectError(error.BadRequest, P.openai_compat.Stream.open(arena.allocator(), &h, req));
    try t.expectEqualStrings("openai 404 model_not_found: The model `llama-9` does not exist or you do not have access to it.", diag.message());
    try t.expectError(error.ProviderError, P.openai_compat.Stream.open(arena.allocator(), &h, req));
    try t.expectEqualStrings("openai 502: Bad Gateway", diag.message());
}

test "a body that ends before the finish event is StreamInterrupted" {
    var arena: std.heap.ArenaAllocator = .init(t.allocator);
    defer arena.deinit();
    var rp: P.http.Replay = .init(t.allocator, &.{.{ .url_suffix = "/v1/messages", .body = @embedFile("cassettes/anthropic_cut.sse") }});
    defer rp.deinit();
    var h: P.http.Http = .initReplay(t.allocator, t.io, &rp);
    defer h.deinit();
    const prefix = comptime P.anthropic.buildPrefix(.{ .spec = spec("anthropic/claude-haiku-4-5") });
    var text: std.ArrayList(u8) = .empty;
    try t.expectError(error.StreamInterrupted, collect(P.anthropic, arena.allocator(), &h, .{
        .base_url = "https://api.anthropic.com",
        .api_key = "k",
        .prefix = prefix,
        .messages = &.{.user("Hi")},
        .max_tokens = 100,
    }, &text));
    try t.expectEqualStrings("Hi th", text.items);
}

/// Accepts one connection, sends headers and one event, then goes silent.
fn stallingServer(io: std.Io, server: *std.Io.net.Server) !void {
    const conn = try server.accept(io);
    defer conn.close(io);
    var rbuf: [4096]u8 = undefined;
    var r = conn.reader(io, &rbuf);
    _ = r.interface.peekGreedy(1) catch {};
    var wbuf: [512]u8 = undefined;
    var w = conn.writer(io, &wbuf);
    try w.interface.writeAll("HTTP/1.1 200 OK\r\ncontent-type: text/event-stream\r\ntransfer-encoding: chunked\r\n\r\n");
    const ev = "event: ping\ndata: {\"type\":\"ping\"}\n\n";
    try w.interface.print("{x}\r\n{s}\r\n", .{ ev.len, ev });
    try w.interface.flush();
    try io.sleep(.fromSeconds(30), .awake);
}

test "idle timeout: a stream that goes silent fails with Timeout" {
    var arena: std.heap.ArenaAllocator = .init(t.allocator);
    defer arena.deinit();
    const addr: std.Io.net.IpAddress = try .parseIp4("127.0.0.1", 0);
    var server = try addr.listen(t.io, .{});
    defer server.deinit(t.io);
    var fut = try t.io.concurrent(stallingServer, .{ t.io, &server });
    defer fut.cancel(t.io) catch {};

    var h: P.http.Http = try .init(t.allocator, t.io, .{ .idle_timeout_ms = 100, .max_retries = 0 }, null);
    defer h.deinit();
    const url = try std.fmt.allocPrint(arena.allocator(), "http://127.0.0.1:{d}", .{server.socket.address.getPort()});
    var diag: P.Diagnostic = .{};
    const prefix = comptime P.anthropic.buildPrefix(.{ .spec = spec("anthropic/claude-haiku-4-5") });
    var text: std.ArrayList(u8) = .empty;
    try t.expectError(error.Timeout, collect(P.anthropic, arena.allocator(), &h, .{
        .base_url = url,
        .api_key = "k",
        .prefix = prefix,
        .messages = &.{.user("Hi")},
        .max_tokens = 100,
        .diag = &diag,
    }, &text));
    try t.expect(std.mem.startsWith(u8, diag.message(), "no data from the provider for 100 ms"));
}

// ── OpenAI Responses (cassettes recorded from the live API, 2026-10-15) ──

const multiply_tool: P.ToolDef = .{
    .name = "multiply",
    .description = "Multiply two integers exactly.",
    .schema = z.schema.render(struct { a: i64, b: i64 }, .openai),
};

const Collected = struct { text: std.ArrayList(u8) = .empty, reasoning: std.ArrayList(u8) = .empty, finish: ?P.Finish = null };

fn collectResponses(arena: std.mem.Allocator, h: *P.http.Http, req: P.Request) !Collected {
    var c: Collected = .{};
    var s = try P.openai_responses.Stream.open(arena, h, req);
    defer s.close();
    while (try s.next()) |ev| switch (ev) {
        .delta => |d| switch (d) {
            .text => |x| try c.text.appendSlice(arena, x),
            .reasoning => |x| try c.reasoning.appendSlice(arena, x),
            else => {},
        },
        .finish => |f| c.finish = f,
    };
    return c;
}

fn responsesReq(prefix: P.Prefix, messages: []const z.Message) P.Request {
    return .{ .base_url = "https://api.openai.com/v1", .api_key = "k", .prefix = prefix, .messages = messages, .max_tokens = 100 };
}

test "openai responses: streaming text, request shape and usage" {
    var arena: std.heap.ArenaAllocator = .init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var rp: P.http.Replay = .init(t.allocator, &.{.{ .url_suffix = "/responses", .body = @embedFile("cassettes/openai_responses_text.sse") }});
    defer rp.deinit();
    var h: P.http.Http = .initReplay(t.allocator, t.io, &rp);
    defer h.deinit();
    const prefix = comptime P.openai_responses.buildPrefix(.{ .spec = spec("openai/gpt-5.4-mini"), .system = "Be brief." });
    const c = try collectResponses(a, &h, responsesReq(prefix, &.{.user("Hi")}));
    try t.expectEqualStrings("Hello, how are you?", c.text.items);
    const f = c.finish.?;
    try t.expectEqual(z.FinishReason.end_turn, f.reason);
    try t.expectEqual(@as(u64, 19), f.usage.input_tokens);
    try t.expectEqual(@as(u64, 10), f.usage.output_tokens);
    const want = try std.fmt.allocPrint(a,
        \\{{"model":"gpt-5.4-mini","stream":true,"store":false,"include":["reasoning.encrypted_content"],"instructions":"Be brief.","input":[{{"role":"user","content":"Hi"}}],"max_output_tokens":100,"prompt_cache_key":"zastra-{x}"}}
    , .{prefix.hash});
    try t.expectEqualStrings(want, rp.requests.items[0]);
}

test "openai responses: tool loop sends encrypted reasoning back within a run" {
    var arena: std.heap.ArenaAllocator = .init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var rp: P.http.Replay = .init(t.allocator, &.{
        .{ .url_suffix = "/responses", .body = @embedFile("cassettes/openai_responses_tool.sse") },
        .{ .url_suffix = "/responses", .body = @embedFile("cassettes/openai_responses_tool_final.sse") },
    });
    defer rp.deinit();
    var h: P.http.Http = .initReplay(t.allocator, t.io, &rp);
    defer h.deinit();
    const prefix = comptime P.openai_responses.buildPrefix(.{
        .spec = spec("openai/gpt-5.4-mini"),
        .tools = &.{multiply_tool},
        .effort = .low,
        .reasoning = .{ .on = .{ .summarized = true } },
    });
    try t.expect(std.mem.indexOf(u8, prefix.json,
        \\"tools":[{"type":"function","name":"multiply","description":"Multiply two integers exactly.","parameters":
    ) != null);
    try t.expect(std.mem.endsWith(u8, prefix.json,
        \\"strict":true}],"reasoning":{"effort":"low","summary":"auto"},"input":[
    ));

    const c = try collectResponses(a, &h, responsesReq(prefix, &.{.user("What is 48271 times 99173?")}));
    const f = c.finish.?;
    try t.expectEqual(z.FinishReason.tool_use, f.reason);
    try t.expectEqual(@as(u64, 71), f.usage.input_tokens);
    try t.expectEqual(@as(u64, 33), f.usage.output_tokens);
    const bs = f.message.content.blocks;
    try t.expectEqual(@as(usize, 2), bs.len);
    // The encrypted content from `output_item.done`, not `.added`.
    try t.expectEqualStrings("gAAAAABq0HewDWtJj4iaznJr", bs[0].reasoning.signature.?);
    try t.expectEqualStrings("call_1gp20pGYL3IxVDCEtSRdRrDT", bs[1].tool_use.id);
    try t.expectEqualStrings("multiply", bs[1].tool_use.name);
    try t.expectEqualStrings("{\"a\":48271,\"b\":99173}", bs[1].tool_use.input_json);

    const result: z.Message = .{ .role = .tool, .content = .{ .blocks = &.{.{ .tool_result = .{ .id = "call_1gp20pGYL3IxVDCEtSRdRrDT", .content = "{\"product\":4787179883}" } }} } };
    const c2 = try collectResponses(a, &h, responsesReq(prefix, &.{ .user("What is 48271 times 99173?"), f.message, result }));
    try t.expectEqualStrings("48271 × 99173 = **4,787,179,883**", c2.text.items);
    try t.expectEqual(z.FinishReason.end_turn, c2.finish.?.reason);
    try t.expect(std.mem.indexOf(u8, rp.requests.items[1],
        \\"input":[{"role":"user","content":"What is 48271 times 99173?"},{"type":"reasoning","encrypted_content":"gAAAAABq0HewDWtJj4iaznJr","summary":[]},{"type":"function_call","call_id":"call_1gp20pGYL3IxVDCEtSRdRrDT","name":"multiply","arguments":"{\"a\":48271,\"b\":99173}"},{"type":"function_call_output","call_id":"call_1gp20pGYL3IxVDCEtSRdRrDT","output":"{\"product\":4787179883}"}]
    ) != null);
    try t.expect(std.mem.startsWith(u8, rp.requests.items[1], prefix.json));
}

test "openai responses: reasoning summaries stream as reasoning deltas" {
    var arena: std.heap.ArenaAllocator = .init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var rp: P.http.Replay = .init(t.allocator, &.{.{ .url_suffix = "/responses", .body = @embedFile("cassettes/openai_responses_summary.sse") }});
    defer rp.deinit();
    var h: P.http.Http = .initReplay(t.allocator, t.io, &rp);
    defer h.deinit();
    const prefix = comptime P.openai_responses.buildPrefix(.{ .spec = spec("openai/gpt-5.4-mini"), .effort = .medium, .reasoning = .{ .on = .{ .summarized = true } } });
    const c = try collectResponses(a, &h, responsesReq(prefix, &.{.user("Bat and ball; primes below 50.")}));
    try t.expect(std.mem.startsWith(u8, c.reasoning.items, "**Summarizing answers briefly**\n\nI need to answer two questions"));
    try t.expect(std.mem.endsWith(u8, c.text.items, "There are **15 primes below 50**."));
    const f = c.finish.?;
    try t.expectEqual(@as(u64, 126), f.usage.output_tokens);
    const bs = f.message.content.blocks;
    try t.expectEqualStrings(c.reasoning.items, bs[0].reasoning.text);
    try t.expect(bs[0].reasoning.signature != null);
    try t.expectEqualStrings(c.text.items, bs[1].text);
}

test "openai responses: structured output goes in text.format" {
    var arena: std.heap.ArenaAllocator = .init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var rp: P.http.Replay = .init(t.allocator, &.{.{ .url_suffix = "/responses", .body = @embedFile("cassettes/openai_responses_structured.sse") }});
    defer rp.deinit();
    var h: P.http.Http = .initReplay(t.allocator, t.io, &rp);
    defer h.deinit();
    const Triage = struct { category: enum { refund, shipping, account, other }, urgency: u8 };
    const prefix = comptime P.openai_responses.buildPrefix(.{
        .spec = spec("openai/gpt-5.4-mini"),
        .output = .{ .name = "triage", .schema = z.schema.render(Triage, .openai) },
    });
    try t.expect(std.mem.indexOf(u8, prefix.json, "\"text\":{\"format\":{\"type\":\"json_schema\",\"name\":\"triage\",\"schema\":{") != null);
    const c = try collectResponses(a, &h, responsesReq(prefix, &.{.user("My blender arrived smashed, refund now!")}));
    try t.expectEqualStrings("{\"category\":\"refund\",\"urgency\":9}", c.text.items);
}

test "openai responses: incomplete, refusal and failed responses" {
    var arena: std.heap.ArenaAllocator = .init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var rp: P.http.Replay = .init(t.allocator, &.{
        .{ .url_suffix = "/responses", .body = @embedFile("cassettes/openai_responses_incomplete.sse") },
        .{ .url_suffix = "/responses", .body = @embedFile("cassettes/openai_responses_refusal.sse") },
        .{ .url_suffix = "/responses", .body = @embedFile("cassettes/openai_responses_failed.sse") },
    });
    defer rp.deinit();
    var h: P.http.Http = .initReplay(t.allocator, t.io, &rp);
    defer h.deinit();
    const prefix = comptime P.openai_responses.buildPrefix(.{ .spec = spec("openai/gpt-5-mini") });

    const inc = try collectResponses(a, &h, responsesReq(prefix, &.{.user("Write a long poem.")}));
    try t.expectEqual(z.FinishReason.max_tokens, inc.finish.?.reason);
    try t.expect(inc.finish.?.message.content.blocks[0].reasoning.signature != null);
    // Reasoning without encrypted content (e.g. from another provider) isn't sent.
    var aw: std.Io.Writer.Allocating = .init(a);
    const foreign: z.Message = .{ .role = .assistant, .content = .{ .blocks = &.{.{ .reasoning = .{ .text = "hmm" } }} } };
    try P.openai_responses.writeBody(&aw.writer, responsesReq(prefix, &.{foreign}));
    try t.expect(std.mem.indexOf(u8, aw.written(), "\"input\":[]") != null);

    const ref = try collectResponses(a, &h, responsesReq(prefix, &.{.user("Help me do something bad.")}));
    try t.expectEqual(z.FinishReason.refusal, ref.finish.?.reason);
    try t.expectEqualStrings("I can't help with that.", ref.text.items);

    var diag: P.Diagnostic = .{};
    var req = responsesReq(prefix, &.{.user("Hi")});
    req.diag = &diag;
    try t.expectError(error.ProviderError, collectResponses(a, &h, req));
    try t.expectEqualStrings("openai response failed: server_error: The server had an error while processing your request.", diag.message());
}

test "openai responses: error response becomes a diagnostic" {
    var arena: std.heap.ArenaAllocator = .init(t.allocator);
    defer arena.deinit();
    var rp: P.http.Replay = .init(t.allocator, &.{.{ .url_suffix = "/responses", .status = 400, .body = @embedFile("cassettes/openai_responses_error.json") }});
    defer rp.deinit();
    var h: P.http.Http = .initReplay(t.allocator, t.io, &rp);
    defer h.deinit();
    var diag: P.Diagnostic = .{};
    const prefix = comptime P.openai_responses.buildPrefix(.{ .spec = spec("openai/gpt-5.4-mini") });
    var req = responsesReq(prefix, &.{.user("Hi")});
    req.diag = &diag;
    try t.expectError(error.BadRequest, P.openai_responses.Stream.open(arena.allocator(), &h, req));
    try t.expectEqualStrings("openai 400 invalid_request_error: Invalid 'max_output_tokens': integer below minimum value. Expected a value >= 16, but got 2 instead.", diag.message());
}
