//! MCP stdio client against a fake server (PLAN.md §6.7).

const std = @import("std");
const z = @import("zastra");
const opts = @import("test_options");
const t = std.testing;

const Ctx = struct {};

const Docs = z.Agent(Ctx, .{
    .name = "docs",
    .model = "anthropic/claude-sonnet-5-5",
    .tools = .{z.mcp.tools(.docs, .{ .allow = &.{"search_docs"} })},
});
const Everything = z.Agent(Ctx, .{
    .name = "everything",
    .model = "openai/gpt-5-mini",
    .tools = .{z.mcp.tools(.docs, .{})},
});

const App = z.App(.{
    .ctx = Ctx,
    .agents = .{ Docs, Everything },
    .mcp = .{ .docs = z.mcp.stdio(&.{opts.fake_mcp_server}) },
});

test "MCP tools: discovered at init, spliced into the prefix, called at runtime" {
    var ctx: Ctx = .{};
    var h = try z.testing.harness(App, .{ .ctx = &ctx });
    defer h.deinit();
    h.script(Docs, &.{
        .tools(&.{.{ .mcp = .{ .server = "docs", .tool = "search_docs", .args_json = "{\"query\":\"refunds\"}" } }}),
        .text("Refunds take 5 days."),
    });
    var s = try h.agent(Docs).stream("How long do refunds take?", .{});
    defer s.deinit();
    var saw_call = false;
    var result: []const u8 = "";
    while (try s.next()) |e| switch (e) {
        .tool_call => |c| switch (c) {
            .mcp => |m| {
                try t.expectEqualStrings("docs", m.server);
                try t.expectEqualStrings("search_docs", m.tool);
                saw_call = true;
            },
        },
        .tool_result => |r| result = try h.arena.allocator().dupe(u8, r.content),
        else => {},
    };
    try t.expect(saw_call);
    try t.expectEqualStrings("Refunds take 5 days. (query: refunds)", result);
    // Only the allowed tool is offered.
    const first = h.requests()[0];
    try t.expect(std.mem.indexOf(u8, first, "\"name\":\"docs__search_docs\"") != null);
    try t.expect(std.mem.indexOf(u8, first, "docs__add") == null);
}

test "MCP: arguments are validated against the server schema; pagination; structured content" {
    var ctx: Ctx = .{};
    var h = try z.testing.harness(App, .{ .ctx = &ctx });
    defer h.deinit();
    h.script(Everything, &.{
        .tools(&.{
            .{ .mcp = .{ .server = "docs", .tool = "search_docs", .args_json = "{\"query\":\"x\"}" } },
            .{ .mcp = .{ .server = "docs", .tool = "add", .args_json = "{\"a\":2,\"b\":3}" } },
        }),
        .text("ok"),
    });
    const r = try h.agent(Everything).generate("go", .{ .include_messages = true });
    const results = r.messages[2].content.blocks;
    try t.expect(results[0].tool_result.is_error);
    try t.expect(std.mem.indexOf(u8, results[0].tool_result.content, "$.query: must be at least 2 characters") != null);
    try t.expectEqualStrings("{\"sum\":5}", results[1].tool_result.content);
    // Both pages of tools/list were read.
    try t.expect(std.mem.indexOf(u8, h.requests()[0], "docs__add") != null);
}

// ── 2026-07-28 (PLAN.md §17.5) ───────────────────────────────────────────────

const FakeHttp = @import("fake_mcp_http.zig").Fake;

const ModernDocs = z.Agent(Ctx, .{
    .name = "modern_docs",
    .model = "anthropic/claude-sonnet-5-5",
    .tools = .{z.mcp.tools(.docs, .{})},
});
const ModernApp = z.App(.{
    .ctx = Ctx,
    .agents = .{ModernDocs},
    .mcp = .{ .docs = z.mcp.stdio(&.{ opts.fake_mcp_server, "--modern" }) },
});


test "MCP 2026-07-28 over stdio: discover, sorted tools, input-required results, list changes" {
    // This test expects zastra warnings (skipped tools, unanswerable input requests).
    t.log_level = .err;
    defer t.log_level = .warn;
    var ctx: Ctx = .{};
    var h = try z.testing.harness(ModernApp, .{ .ctx = &ctx });
    defer h.deinit();
    h.script(ModernDocs, &.{
        .tools(&.{
            .{ .mcp = .{ .server = "docs", .tool = "search_docs", .args_json = "{\"query\":\"refunds\"}" } },
            .{ .mcp = .{ .server = "docs", .tool = "ask", .args_json = "{}" } },
            .{ .mcp = .{ .server = "docs", .tool = "stateful", .args_json = "{}" } },
            .{ .mcp = .{ .server = "docs", .tool = "grow", .args_json = "{}" } },
        }),
        .text("ok"),
        .text("again"),
    });
    const r = try h.agent(ModernDocs).generate("go", .{ .include_messages = true });
    const results = r.messages[2].content.blocks;
    try t.expectEqualStrings("Refunds take 5 days. (query: refunds)", results[0].tool_result.content);
    try t.expect(results[1].tool_result.is_error);
    try t.expect(std.mem.indexOf(u8, results[1].tool_result.content, "needs input zastra can't provide (elicitation/create)") != null);
    try t.expectEqualStrings("done after a retry", results[2].tool_result.content);
    try t.expectEqualStrings("grown", results[3].tool_result.content);

    // Tools are sorted by name, so the prefix is stable.
    const first = h.requests()[0];
    const ask = std.mem.indexOf(u8, first, "docs__ask").?;
    const grow = std.mem.indexOf(u8, first, "docs__grow").?;
    const search = std.mem.indexOf(u8, first, "docs__search_docs").?;
    try t.expect(ask < grow and grow < search);
    // The running agent kept its tool list; the next run sees the new tool.
    try t.expect(std.mem.indexOf(u8, h.requests()[1], "docs__grown") == null);
    _ = try h.agent(ModernDocs).generate("again", .{});
    try t.expect(std.mem.indexOf(u8, h.requests()[2], "docs__grown") != null);
}

const SilentApp = z.App(.{
    .ctx = Ctx,
    .agents = .{Docs},
    .mcp = .{ .docs = z.mcp.stdio(&.{ opts.fake_mcp_server, "--silent-probe" }) },
});

test "MCP over stdio: a legacy server that ignores the probe falls back to initialize" {
    var ctx: Ctx = .{};
    var h = try z.testing.harness(SilentApp, .{ .ctx = &ctx, .mcp = .{ .probe_timeout_ms = 200 } });
    defer h.deinit();
    h.script(Docs, &.{
        .tools(&.{.{ .mcp = .{ .server = "docs", .tool = "search_docs", .args_json = "{\"query\":\"refunds\"}" } }}),
        .text("ok"),
    });
    const r = try h.agent(Docs).generate("go", .{ .include_messages = true });
    try t.expectEqualStrings("Refunds take 5 days. (query: refunds)", r.messages[2].content.blocks[0].tool_result.content);
}

const Web = z.Agent(Ctx, .{
    .name = "web",
    .model = "anthropic/claude-sonnet-5-5",
    .tools = .{z.mcp.tools(.web, .{})},
});
const HttpApp = z.App(.{
    .ctx = Ctx,
    .agents = .{Web},
    .mcp = .{ .web = z.mcp.http("https://mcp.example.invalid/mcp", .{ .url_env = "FAKE_MCP_URL", .bearer_env = "WEB_TOKEN", .headers = &.{.{ "X-Team", "acme" }} }) },
});

fn fakeEnv(env: *std.process.Environ.Map, url: []const u8) !void {
    try env.put("FAKE_MCP_URL", url);
    try env.put("WEB_TOKEN", "t0k");
}

test "MCP 2026-07-28 over HTTP: mirrored headers, Base64, x-mcp-header rules, SSE replies, listen stream" {
    // This test expects zastra warnings (skipped tools, unanswerable input requests).
    t.log_level = .err;
    defer t.log_level = .warn;
    const fake = try FakeHttp.start(t.allocator, t.io, .modern);
    defer fake.stop();
    var env: std.process.Environ.Map = .init(t.allocator);
    defer env.deinit();
    try fakeEnv(&env, fake.url);
    var ctx: Ctx = .{};
    var h = try z.testing.harness(HttpApp, .{ .ctx = &ctx, .env = &env });
    defer h.deinit();

    // The tool with an x-mcp-header on a `number` was excluded.
    h.script(Web, &.{
        .tools(&.{
            .{ .mcp = .{ .server = "web", .tool = "lookup", .args_json = "{\"city\":\"Zürich\",\"limit\":3}" } },
            .{ .mcp = .{ .server = "web", .tool = "grow", .args_json = "{}" } },
        }),
        .text("ok"),
    });
    const r = try h.agent(Web).generate("weather?", .{ .include_messages = true });
    try t.expectEqualStrings("sunny", r.messages[2].content.blocks[0].tool_result.content);
    try t.expect(std.mem.indexOf(u8, h.requests()[0], "web__lookup") != null);
    try t.expect(std.mem.indexOf(u8, h.requests()[0], "web__bad_header") == null);

    const call = for (fake.requests()) |x| {
        if (std.mem.eql(u8, x.mcp_name, "lookup")) break x;
    } else return error.TestUnexpectedResult;
    try t.expectEqualStrings("POST", call.method);
    try t.expectEqualStrings("2026-07-28", call.protocol_version);
    try t.expectEqualStrings("lookup", call.mcp_name);
    try t.expectEqualStrings("Bearer t0k", call.authorization);
    try t.expectEqualStrings("City==?base64?WsO8cmljaA==?=;Limit=3;", call.params);
    // No sessions in 2026-07-28.
    for (fake.requests()) |s| try t.expectEqualStrings("", s.session);

    // `grow` changed the tool list; the listen stream says so, and the next
    // run picks it up.
    var tries: u32 = 0;
    while (tries < 200) : (tries += 1) {
        h.script(Web, &.{.text("again")});
        _ = try h.agent(Web).generate("again", .{});
        const last = h.requests()[h.requests().len - 1];
        if (std.mem.indexOf(u8, last, "web__grown") != null) break;
        try t.io.sleep(.fromMilliseconds(10), .awake);
    } else return error.TestUnexpectedResult;
    try t.expect(fake.find("subscriptions/listen") != null);
}

test "MCP over HTTP: a 2025-11-25 server gets initialize, its session id, and a DELETE" {
    const fake = try FakeHttp.start(t.allocator, t.io, .legacy);
    var env: std.process.Environ.Map = .init(t.allocator);
    defer env.deinit();
    try fakeEnv(&env, fake.url);
    var ctx: Ctx = .{};
    {
        var h = try z.testing.harness(HttpApp, .{ .ctx = &ctx, .env = &env });
        defer h.deinit();
        h.script(Web, &.{
            .tools(&.{.{ .mcp = .{ .server = "web", .tool = "wiki", .args_json = "{\"q\":\"x\"}" } }}),
            .text("ok"),
        });
        const r = try h.agent(Web).generate("ask", .{ .include_messages = true });
        try t.expectEqualStrings("legacy answer", r.messages[2].content.blocks[0].tool_result.content);
        const call = fake.find("tools/call").?;
        try t.expectEqualStrings("sess-1", call.session);
        try t.expectEqualStrings("2025-11-25", call.protocol_version);
    }
    try t.expect(fake.deleted.load(.acquire));
    fake.stop();
}

test "MCP over HTTP: a 401 names the server and the token variable" {
    const fake = try FakeHttp.start(t.allocator, t.io, .unauthorized);
    defer fake.stop();
    var env: std.process.Environ.Map = .init(t.allocator);
    defer env.deinit();
    try fakeEnv(&env, fake.url);
    var ctx: Ctx = .{};
    try t.expectError(error.McpFailed, z.testing.harness(HttpApp, .{ .ctx = &ctx, .env = &env }));
    try t.expectEqualStrings("MCP server 'web' rejected the token in WEB_TOKEN (401: Bearer realm=\"fake\")", HttpApp.initDiagnostic());
}
