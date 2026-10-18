//! `.output_partial` streaming (PLAN.md §18.4, D43, D44).

const std = @import("std");
const z = @import("zastra");
const t = std.testing;

const Ctx = struct {};

const Item = struct { sku: []const u8, qty: u32 };
const Report = struct {
    category: enum { refund, other },
    summary: []const u8,
    items: []const Item,
    meta: struct { lang: []const u8, score: u8 },

    pub const stream_strings = .{.summary};
};

fn agent(comptime name: []const u8, comptime model: anytype) type {
    return z.Agent(Ctx, .{ .name = name, .model = model, .output = Report, .partial_output = true });
}

// Native structured output on each API, and the `final_answer` tool fallback.
const NativeAnthropic = agent("native_anthropic", "anthropic/claude-sonnet-4-6");
const NativeResponses = agent("native_responses", "openai/gpt-5-mini");
const NativeCompat = agent("native_compat", z.custom(.{ .provider = .openai_compat, .id = "m", .base_url = "http://localhost:1/v1", .supports = .{ .structured_output = true } }));
const ToolAnthropic = agent("tool_anthropic", z.custom(.{ .provider = .anthropic, .id = "m", .supports = .{ .structured_output = false } }));
const ToolResponses = agent("tool_responses", z.custom(.{ .provider = .openai_responses, .id = "m", .supports = .{ .structured_output = false } }));
const ToolCompat = agent("tool_compat", z.custom(.{ .provider = .openai_compat, .id = "m", .base_url = "http://localhost:1/v1", .supports = .{ .structured_output = false } }));

const Plain = z.Agent(Ctx, .{ .name = "plain", .model = "anthropic/claude-sonnet-4-6", .output = Report });

const all = .{ NativeAnthropic, NativeResponses, NativeCompat, ToolAnthropic, ToolResponses, ToolCompat };
const App = z.App(.{ .ctx = Ctx, .agents = all ++ .{Plain} });

const summary = "The customer received a cracked mug and a dented kettle; both were packed loosely. They want a refund for the mug and a replacement kettle.";
const report: Report = .{
    .category = .refund,
    .summary = summary,
    .items = &.{ .{ .sku = "MUG-1", .qty = 1 }, .{ .sku = "KET-2", .qty = 1 } },
    .meta = .{ .lang = "en", .score = 4 },
};

/// Stream `A`, returning each partial value as JSON, and "RESET" for resets.
fn partials(comptime A: type, h: anytype, gpa: std.mem.Allocator) !std.ArrayList([]const u8) {
    var out: std.ArrayList([]const u8) = .empty;
    const s = try h.agent(A).stream("Summarize the ticket.", .{});
    defer s.deinit();
    while (try s.next()) |e| switch (e) {
        .output_partial => |v| try out.append(gpa, try gpa.print("{f}", .{z.fmt.json(v)})),
        .output_partial_reset => try out.append(gpa, try gpa.dupe(u8, "RESET")),
        else => {},
    };
    const r = try s.result();
    try t.expectEqualStrings(summary, r.output.summary);
    return out;
}

fn freeAll(gpa: std.mem.Allocator, list: *std.ArrayList([]const u8)) void {
    for (list.items) |x| gpa.free(x);
    list.deinit(gpa);
}

test "partial output on every API, natively and through final_answer" {
    const gpa = t.allocator;
    var ctx: Ctx = .{};
    var h = try z.testing.harness(App, .{ .ctx = &ctx });
    defer h.deinit();
    const full = try gpa.print("{f}", .{z.fmt.json(report)});
    defer gpa.free(full);
    inline for (all) |A| {
        h.script(A, &.{.chunked(7, .output(report))});
        var got = try partials(A, h, gpa);
        defer freeAll(gpa, &got);
        errdefer for (got.items) |g| std.debug.print("{s}: {s}\n", .{ A.id, g });

        try t.expect(got.items.len >= 5);
        // The last partial value is the whole output.
        try t.expectEqualStrings(full, got.items[got.items.len - 1]);
        var saw_growing_summary = false;
        var saw_one_item = false;
        var saw_meta_lang_only = false;
        for (got.items) |g| {
            // Every partial value is unvalidated but never made up: each field
            // is null or a prefix of the final one.
            var parsed = try std.json.parseFromSlice(std.json.Value, gpa, g, .{});
            defer parsed.deinit();
            const o = parsed.value.object;
            const sm = (o.get("summary") orelse .null);
            if (sm == .string) {
                try t.expect(std.mem.startsWith(u8, summary, sm.string));
                if (sm.string.len < summary.len and sm.string.len >= 64) saw_growing_summary = true;
            }
            const cat = (o.get("category") orelse .null);
            if (cat == .string) try t.expectEqualStrings("refund", cat.string);
            const items = (o.get("items") orelse .null);
            if (items == .array and items.array.items.len == 1) saw_one_item = true;
            const meta = (o.get("meta") orelse .null);
            if (meta == .object and meta.object.get("score") == null and meta.object.get("lang") != null) saw_meta_lang_only = true;
        }
        try t.expect(saw_growing_summary);
        try t.expect(saw_one_item);
        try t.expect(saw_meta_lang_only);
        try t.expectEqual(@as(usize, 0), h.remaining(A));
    }
}

test "a repair restarts the partial stream after a reset" {
    const gpa = t.allocator;
    var ctx: Ctx = .{};
    var h = try z.testing.harness(App, .{ .ctx = &ctx });
    defer h.deinit();
    h.script(NativeAnthropic, &.{
        .chunked(5, .raw("{\"category\":\"refund\",\"summary\":\"short\"}")),
        .chunked(9, .output(report)),
    });
    var got = try partials(NativeAnthropic, h, gpa);
    defer freeAll(gpa, &got);
    var resets: usize = 0;
    var reset_at: usize = 0;
    for (got.items, 0..) |g, i| if (std.mem.eql(u8, g, "RESET")) {
        resets += 1;
        reset_at = i;
    };
    try t.expectEqual(@as(usize, 1), resets);
    try t.expect(reset_at > 0 and reset_at < got.items.len - 1);
    // Before the reset: the invalid attempt's partial values.
    try t.expect(std.mem.indexOf(u8, got.items[reset_at - 1], "\"summary\":\"short\"") != null);
}

test "a retried final_answer call resets too" {
    const gpa = t.allocator;
    var ctx: Ctx = .{};
    var h = try z.testing.harness(App, .{ .ctx = &ctx });
    defer h.deinit();
    h.script(ToolAnthropic, &.{
        .chunked(5, .call("final_answer", "{\"category\":\"refund\",\"summary\":\"short\"}")),
        .chunked(9, .output(report)),
    });
    var got = try partials(ToolAnthropic, h, gpa);
    defer freeAll(gpa, &got);
    var resets: usize = 0;
    for (got.items) |g| {
        if (std.mem.eql(u8, g, "RESET")) resets += 1;
    }
    try t.expectEqual(@as(usize, 1), resets);
}

test "generate doesn't parse partial output; agents without the flag have no partial events" {
    var ctx: Ctx = .{};
    var h = try z.testing.harness(App, .{ .ctx = &ctx });
    defer h.deinit();
    h.script(NativeAnthropic, &.{.chunked(3, .output(report))});
    const r = try h.agent(NativeAnthropic).generate("Summarize.", .{});
    try t.expectEqualStrings(summary, r.output.summary);
    comptime {
        for (@typeInfo(Plain.Event).@"union".field_names) |name| if (std.mem.startsWith(u8, name, "output_partial")) @compileError("Plain has partial events");
    }
}
