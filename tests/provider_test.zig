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
