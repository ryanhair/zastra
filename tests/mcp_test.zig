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
