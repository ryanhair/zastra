//! z.testing.fuzzTool (PLAN.md §19.4, D52), with planted bugs.

const std = @import("std");
const z = @import("zastra");
const options = @import("test_options");
const t = std.testing;

const Ctx = struct {
    gpa: std.mem.Allocator = t.allocator,
    calls: u32 = 0,
    kept: std.ArrayList([]u8) = .empty,
};

const Kind = enum { book, game, other };

/// A well-behaved tool with a varied input.
const Search = struct {
    pub const description = "Search the catalog.";
    pub const Input = struct {
        query: []const u8,
        kind: ?Kind = null,
        limit: u8 = 10,
        tags: []const []const u8 = &.{},
        filter: union(enum) { none, price: struct { max_cents: u32 }, ids: []const u32 } = .none,
        pub const constraints = .{
            .query = .{ .min_len = 1, .max_len = 40 },
            .limit = .{ .min = 1, .max = 50 },
            .tags = .{ .max_items = 3 },
        };
    };
    pub const Output = struct {
        hits: []const []const u8,
        pub const constraints = .{ .hits = .{ .max_items = 50 } };
    };
    pub const ModelErrors = error{NoResults};
    pub const error_messages = .{ .NoResults = "Nothing matched." };
    pub fn execute(tc: *z.ToolCtx(Ctx), in: Input) !Output {
        tc.ctx.calls += 1;
        if (std.mem.indexOfScalar(u8, in.query, '!') != null) return error.NoResults;
        const hits = try tc.arena.alloc([]const u8, in.limit);
        for (hits, 0..) |*h, i| h.* = try tc.fmt("{s}-{d}", .{ in.query, i });
        return .{ .hits = hits };
    }
};

/// Returns more items than its Output schema allows.
const TooMany = struct {
    pub const description = "d";
    pub const Input = struct { n: u8 };
    pub const Output = struct {
        items: []const u16,
        pub const constraints = .{ .items = .{ .max_items = 4 } };
    };
    pub fn execute(tc: *z.ToolCtx(Ctx), in: Input) !Output {
        const items = try tc.arena.alloc(u16, in.n);
        @memset(items, 0);
        return .{ .items = items };
    }
};

/// Fails with an error the model never hears about.
const Unmapped = struct {
    pub const description = "d";
    pub const Input = struct { n: u8 };
    pub const Output = struct { ok: bool };
    pub const ModelErrors = error{TooBig};
    pub const error_messages = .{ .TooBig = "Too big." };
    pub fn execute(_: *z.ToolCtx(Ctx), in: Input) !Output {
        if (in.n > 200) return error.TooBig;
        if (in.n == 0) return error.DatabaseDown;
        return .{ .ok = true };
    }
};

/// Keeps memory from the context's allocator and never frees it.
const Leaky = struct {
    pub const description = "d";
    pub const Input = struct { note: []const u8 };
    pub const Output = struct { ok: bool };
    pub fn execute(tc: *z.ToolCtx(Ctx), in: Input) !Output {
        try tc.ctx.kept.append(tc.ctx.gpa, try tc.ctx.gpa.dupe(u8, in.note));
        return .{ .ok = true };
    }
};

/// Effectful: fuzzing needs `.allow_effects`.
const Refund = struct {
    pub const description = "d";
    pub const Input = struct { order_id: []const u8, cents: u32 };
    pub const Output = struct { refund_id: []const u8 };
    pub const effects = .{ .reads, .writes, .spends_money };
    pub fn execute(tc: *z.ToolCtx(Ctx), in: Input) !Output {
        tc.ctx.calls += 1;
        return .{ .refund_id = try tc.fmt("R-{d}", .{in.cents}) };
    }
};

const Agent = z.Agent(Ctx, .{
    .name = "a",
    .model = "anthropic/claude-sonnet-4-6",
    .tools = .{ Search, TooMany, Unmapped, Leaky, Refund },
    .allow = .{ .reads, .writes, .spends_money },
});
const App = z.App(.{ .ctx = Ctx, .agents = .{Agent} });

test "a well-behaved tool survives valid and hostile arguments" {
    var ctx: Ctx = .{};
    try z.testing.fuzzTool(App, Search, .{ .ctx = &ctx, .iterations = 300, .seed = 1, .mapped_errors_only = true });
    // Valid inputs always reach execute; hostile ones only when they still parse.
    try t.expect(ctx.calls >= 300);
}

test "an output that breaks Output's schema is reported" {
    var ctx: Ctx = .{};
    try t.expectError(error.ToolFuzzFailed, z.testing.fuzzTool(App, TooMany, .{ .ctx = &ctx, .iterations = 50, .quiet = true }));
}

test "unmapped errors fail only with .mapped_errors_only" {
    var ctx: Ctx = .{};
    try z.testing.fuzzTool(App, Unmapped, .{ .ctx = &ctx, .iterations = 300 });
    try t.expectError(error.ToolFuzzFailed, z.testing.fuzzTool(App, Unmapped, .{ .ctx = &ctx, .iterations = 300, .mapped_errors_only = true, .quiet = true }));
}

test "a tool that keeps memory through ctx shows up as a leak" {
    // With `std.testing.allocator` in the ctx, the test fails with a leak
    // report; this counts instead, so the planted leak doesn't fail the suite.
    var debug: std.heap.DebugAllocator(.{ .enable_memory_limit = true }) = .init;
    var ctx: Ctx = .{ .gpa = debug.allocator() };
    try z.testing.fuzzTool(App, Leaky, .{ .ctx = &ctx, .iterations = 10, .hostile = false });
    try t.expect(debug.total_requested_bytes > 0);
    for (ctx.kept.items) |k| ctx.gpa.free(k);
    ctx.kept.deinit(ctx.gpa);
    try t.expectEqual(.ok, debug.deinit());
}

test "effectful tools run with .allow_effects" {
    var ctx: Ctx = .{};
    try z.testing.fuzzTool(App, Refund, .{ .ctx = &ctx, .iterations = 20, .allow_effects = .{ .writes, .spends_money } });
    try t.expect(ctx.calls >= 20);
}

test "a failure reproduces from the printed seed" {
    var ctx: Ctx = .{};
    // Unmapped fails only on n == 0: find the first failing seed.
    var seed: u64 = 0;
    while (true) : (seed += 1) {
        z.testing.fuzzTool(App, Unmapped, .{ .ctx = &ctx, .iterations = 1, .seed = seed, .hostile = false, .mapped_errors_only = true, .quiet = true }) catch break;
    }
    try t.expect(seed > 0);
    // The run that found it, and the one-iteration rerun the report suggests.
    try z.testing.fuzzTool(App, Unmapped, .{ .ctx = &ctx, .iterations = seed, .seed = 0, .hostile = false, .mapped_errors_only = true, .quiet = true });
    try t.expectError(error.ToolFuzzFailed, z.testing.fuzzTool(App, Unmapped, .{ .ctx = &ctx, .iterations = seed + 1, .seed = 0, .hostile = false, .mapped_errors_only = true, .quiet = true }));
    try t.expectError(error.ToolFuzzFailed, z.testing.fuzzTool(App, Unmapped, .{ .ctx = &ctx, .iterations = 1, .seed = seed, .hostile = false, .mapped_errors_only = true, .quiet = true }));
}

test "a panicking tool prints its seed before the crash" {
    // The crash note is a SIGABRT handler.
    if (@import("builtin").os.tag == .windows) return error.SkipZigTest;
    const io = t.io;
    const r = try std.process.run(t.allocator, io, .{ .argv = &.{options.fuzz_crash} });
    defer t.allocator.free(r.stdout);
    defer t.allocator.free(r.stderr);
    try t.expect(r.term != .exited or r.term.exited != 0);
    try t.expect(std.mem.indexOf(u8, r.stderr, "z.testing.fuzzTool(echo): crashed at seed ") != null);
    try t.expect(std.mem.indexOf(u8, r.stderr, "reproduce with .seed = ") != null);
    try t.expect(std.mem.indexOf(u8, r.stderr, "\"text\":\"\"") != null);
}
