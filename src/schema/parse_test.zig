const std = @import("std");
const parse = @import("parse.zig");
const json = @import("json.zig");

const Triage = struct {
    category: enum { refund, shipping, product_question, other },
    urgency: u8,
    order_id: ?[]const u8 = null,
    summary: []const u8,
    tags: []const []const u8 = &.{},
    pub const constraints = .{
        .urgency = .{ .min = 1, .max = 5 },
        .summary = .{ .max_len = 20 },
        .tags = .{ .max_items = 2 },
    };
};

fn expectIssue(comptime T: type, text: []const u8, path: []const u8, msg_contains: []const u8) !void {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    var issue: parse.Issue = .{};
    if (parse.parse(T, arena.allocator(), text, &issue)) |_| {
        return error.TestExpectedError;
    } else |err| try std.testing.expectEqual(error.ValidationFailed, err);
    try std.testing.expectEqualStrings(path, issue.path);
    if (std.mem.indexOf(u8, issue.message, msg_contains) == null) {
        std.debug.print("message was: {s}\n", .{issue.message});
        return error.TestUnexpectedResult;
    }
}

test "valid parse round-trips" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    var issue: parse.Issue = .{};
    const t = try parse.parse(Triage, arena.allocator(),
        \\{"category":"refund","urgency":3,"summary":"Broken","order_id":"ORD-1"}
    , &issue);
    try std.testing.expectEqual(.refund, t.category);
    try std.testing.expectEqualStrings("ORD-1", t.order_id.?);
    const back = try json.stringifyAlloc(arena.allocator(), t);
    try std.testing.expectEqualStrings(
        \\{"category":"refund","urgency":3,"order_id":"ORD-1","summary":"Broken","tags":[]}
    , back);
}

test "validation issues carry a path and a model-facing message" {
    try expectIssue(Triage, "{\"category\":\"refund\",\"urgency\":9,\"summary\":\"x\"}", "$.urgency", "at most 5");
    try expectIssue(Triage, "{\"category\":\"refnd\",\"urgency\":1,\"summary\":\"x\"}", "$.category", "must be one of");
    try expectIssue(Triage, "{\"category\":\"refund\",\"urgency\":1}", "$.summary", "missing required field");
    try expectIssue(Triage, "{\"category\":\"refund\",\"urgency\":1,\"summary\":\"x\",\"urgncy\":2}", "$", "did you mean \"urgency\"");
    try expectIssue(Triage, "{\"category\":\"refund\",\"urgency\":1,\"summary\":\"this summary is far too long\"}", "$.summary", "at most 20");
    try expectIssue(Triage, "{\"category\":\"refund\",\"urgency\":1,\"summary\":\"x\",\"tags\":[\"a\",\"b\",\"c\"]}", "$.tags", "at most 2 items");
    try expectIssue(Triage, "{\"category\":\"refund\",\"urgency\":\"high\",\"summary\":\"x\"}", "$.urgency", "expected an integer");
    try expectIssue(Triage, "not json", "$", "invalid JSON");
}

test "unions" {
    const U = union(enum) { none, n: u8, p: struct { q: bool } };
    const W = struct { items: []const U };
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    var issue: parse.Issue = .{};
    const w = try parse.parse(W, arena.allocator(),
        \\{"items":[{"type":"none"},{"type":"n","value":4},{"type":"p","q":true}]}
    , &issue);
    try std.testing.expectEqual(@as(u8, 4), w.items[1].n);
    try std.testing.expect(w.items[2].p.q);
    try expectIssue(W, "{\"items\":[{\"type\":\"x\"}]}", "$.items[0]", "\"type\" must be one of");
}

test "fuzz: validated parse never crashes" {
    try std.testing.fuzz({}, struct {
        fn f(_: void, smith: *std.testing.Smith) anyerror!void {
            var buf: [512]u8 = undefined;
            const n = smith.slice(&buf);
            var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
            defer arena.deinit();
            var issue: parse.Issue = .{};
            _ = parse.parse(Triage, arena.allocator(), buf[0..n], &issue) catch {};
        }
    }.f, .{ .corpus = &.{
        "{\"category\":\"refund\",\"urgency\":3,\"summary\":\"x\"}",
        "{\"category\":\"shipping\",\"urgency\":9,\"summary\":\"y\",\"tags\":[\"a\"]}",
    } });
}

test "z.Json nested past the stringify limit is a validation issue, not a crash" {
    const T = struct { j: json.Json };
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const deep = 300;
    var text: std.ArrayList(u8) = .empty;
    try text.appendSlice(a, "{\"j\":");
    try text.appendNTimes(a, '[', deep);
    try text.appendNTimes(a, ']', deep);
    try text.append(a, '}');
    var issue: parse.Issue = .{};
    try std.testing.expectError(error.ValidationFailed, parse.parse(T, a, text.items, &issue));
    try std.testing.expectEqualStrings("$.j", issue.path);
    // At the limit it still works.
    const ok = "{\"j\":" ++ "[" ** 256 ++ "]" ** 256 ++ "}";
    _ = try parse.parse(T, a, ok, &issue);
}
