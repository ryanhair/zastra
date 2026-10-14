//! Compile-error formatting and did-you-mean suggestions (PLAN.md §7).
//!
//! Every comptime check in zastra reports through `fail`, so every message
//! starts with `zastra:` and reads as one actionable sentence.

const std = @import("std");

/// Emit a zastra compile error. `fmt` is formatted with `std.fmt.comptimePrint`.
pub inline fn fail(comptime fmt: []const u8, comptime args: anytype) noreturn {
    @compileError("zastra: " ++ std.fmt.comptimePrint(fmt, args));
}

/// Levenshtein distance. Strings longer than 64 bytes are treated as "far".
pub fn editDistance(a: []const u8, b: []const u8) usize {
    const max = 64;
    if (a.len > max or b.len > max) return std.math.maxInt(usize);
    var prev: [max + 1]usize = undefined;
    var cur: [max + 1]usize = undefined;
    for (0..b.len + 1) |j| prev[j] = j;
    for (a, 0..) |ca, i| {
        cur[0] = i + 1;
        for (b, 0..) |cb, j| {
            const cost: usize = if (std.ascii.toLower(ca) == std.ascii.toLower(cb)) 0 else 1;
            cur[j + 1] = @min(@min(prev[j + 1] + 1, cur[j] + 1), prev[j] + cost);
        }
        @memcpy(prev[0 .. b.len + 1], cur[0 .. b.len + 1]);
    }
    return prev[b.len];
}

/// The closest candidate within edit distance 2, if any (and not identical).
pub fn closest(name: []const u8, candidates: []const []const u8) ?[]const u8 {
    @setEvalBranchQuota(100_000);
    var best: ?[]const u8 = null;
    var best_d: usize = 3;
    for (candidates) |c| {
        if (std.mem.eql(u8, c, name)) continue;
        const d = editDistance(name, c);
        if (d < best_d) {
            best_d = d;
            best = c;
        }
    }
    return best;
}

/// " (did you mean 'x'?)" or "" — for appending to a message.
pub fn didYouMean(comptime name: []const u8, comptime candidates: []const []const u8) []const u8 {
    comptime {
        const c = closest(name, candidates) orelse return "";
        return " (did you mean '" ++ c ++ "'?)";
    }
}

/// "'a', 'b', 'c'" — for listing the valid options in a message.
pub fn list(comptime items: []const []const u8) []const u8 {
    comptime {
        var out: []const u8 = "";
        for (items, 0..) |it, i| out = out ++ (if (i == 0) "" else ", ") ++ "'" ++ it ++ "'";
        return out;
    }
}

test editDistance {
    try std.testing.expectEqual(0, editDistance("abc", "abc"));
    try std.testing.expectEqual(1, editDistance("needApproval", "needsApproval"));
    try std.testing.expectEqual(1, editDistance("antropic", "anthropic"));
    try std.testing.expectEqual(3, editDistance("kitten", "sitting"));
}

test closest {
    const c = &[_][]const u8{ "anthropic", "openai" };
    try std.testing.expectEqualStrings("anthropic", closest("antropic", c).?);
    try std.testing.expect(closest("zzzz", c) == null);
    try std.testing.expectEqualStrings(" (did you mean 'openai'?)", comptime didYouMean("opnai", c));
}
