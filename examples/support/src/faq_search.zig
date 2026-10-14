//! A tiny keyword search over the embedded FAQ. Plain user code: workflow
//! steps don't have to involve a model.

const std = @import("std");

pub fn search(comptime Hit: type, arena: std.mem.Allocator, faq_json: []const u8, query: []const u8, limit: usize) ![]const Hit {
    const all = try std.json.parseFromSliceLeaky([]const Hit, arena, faq_json, .{ .allocate = .alloc_always });
    const Scored = struct { hit: Hit, score: usize };
    var scored: std.ArrayList(Scored) = .empty;
    for (all) |h| {
        var score: usize = 0;
        var it = std.mem.tokenizeAny(u8, query, " ,.?!:;\n\t");
        while (it.next()) |word| {
            if (word.len < 4) continue;
            if (containsIgnoreCase(h.question, word) or containsIgnoreCase(h.answer, word)) score += 1;
        }
        if (score > 0) try scored.append(arena, .{ .hit = h, .score = score });
    }
    std.mem.sort(Scored, scored.items, {}, struct {
        fn lt(_: void, a: Scored, b: Scored) bool {
            return a.score > b.score;
        }
    }.lt);
    const n = @min(limit, scored.items.len);
    const out = try arena.alloc(Hit, n);
    for (scored.items[0..n], 0..) |s, i| out[i] = s.hit;
    return out;
}

fn containsIgnoreCase(haystack: []const u8, needle: []const u8) bool {
    if (needle.len > haystack.len) return false;
    var i: usize = 0;
    while (i + needle.len <= haystack.len) : (i += 1) {
        if (std.ascii.eqlIgnoreCase(haystack[i .. i + needle.len], needle)) return true;
    }
    return false;
}
