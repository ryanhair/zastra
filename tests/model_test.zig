//! `rt.model` and how model requests are opened (PLAN.md §19.0b, D54).

const std = @import("std");
const z = @import("zastra");
const t = std.testing;

const Ctx = struct {};

const Routed = z.Agent(Ctx, .{
    .name = "routed",
    .model = z.custom(.{
        .provider = .anthropic,
        .id = "claude-haiku-4-5",
        .headers = &.{ .{ "http-referer", "https://example.com" }, .{ "x-title", "zastra tests" } },
    }),
    .instructions = "Be brief.",
});

const App = z.App(.{ .ctx = Ctx, .agents = .{Routed} });

fn header(hs: []const std.http.Header, name: []const u8) ?[]const u8 {
    for (hs) |hd| if (std.ascii.eqlIgnoreCase(hd.name, name)) return hd.value;
    return null;
}

test "under the harness, requests carry the spec's headers as well as the routing tag" {
    var ctx: Ctx = .{};
    var h = try z.testing.harness(App, .{ .ctx = &ctx });
    defer h.deinit();
    h.script(Routed, &.{.text("Hi.")});
    _ = try h.agent(Routed).generate("Hello", .{});

    const hs = h.requestHeaders()[0];
    try t.expectEqualStrings("routed", header(hs, "x-zastra-agent").?);
    try t.expectEqualStrings("https://example.com", header(hs, "http-referer").?);
    try t.expectEqualStrings("zastra tests", header(hs, "x-title").?);
}

test "h.scriptModel scripts rt.model, with reasoning, on Anthropic and OpenAI Responses" {
    var ctx: Ctx = .{};
    var h = try z.testing.harness(App, .{ .ctx = &ctx });
    defer h.deinit();
    h.scriptModel("anthropic/claude-haiku-4-5", &.{.withReasoning("Five words.", .text("Hello there, nice to meet."))});
    h.scriptModel("openai/gpt-5-mini", &.{ .text("First."), .chunked(3, .withReasoning("Short.", .text("Second reply."))) });

    const a = try h.model("anthropic/claude-haiku-4-5").generate(&.{.user("Say hi in five words.")}, .{ .max_tokens = 32 });
    try t.expectEqualStrings("Hello there, nice to meet.", a.text);
    try t.expectEqualStrings("Five words.", a.message.content.blocks[0].reasoning.text);
    try t.expectEqualStrings("model:anthropic/claude-haiku-4-5", header(h.requestHeaders()[0], "x-zastra-agent").?);

    const o1 = try h.model("openai/gpt-5-mini").generate(&.{.user("One")}, .{});
    try t.expectEqualStrings("First.", o1.text);
    const o2 = try h.model("openai/gpt-5-mini").generate(&.{.user("Two")}, .{});
    try t.expectEqualStrings("Second reply.", o2.text);
    try t.expectEqualStrings("Short.", o2.message.content.blocks[0].reasoning.text);
}

test "rt.model without its API key names the call in the diagnostic" {
    var ctx: Ctx = .{};
    var rt = try App.init(t.allocator, t.io, .{ .ctx = &ctx });
    defer rt.deinit();
    var arena: std.heap.ArenaAllocator = .init(t.allocator);
    defer arena.deinit();
    try t.expectError(error.MissingApiKey, rt.model("openai/gpt-5-mini").generate(arena.allocator(), &.{.user("Hi")}, .{}));
    try t.expectEqualStrings("rt.model(\"openai/gpt-5-mini\"): OPENAI_API_KEY is not set (needed for model openai/gpt-5-mini)", rt.lastDiagnostic());
}
