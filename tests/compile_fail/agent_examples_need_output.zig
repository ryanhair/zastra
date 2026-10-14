//! expect: `.examples` need `.output`
const std = @import("std");
const z = @import("zastra");
const Ctx = struct { db: u32 = 0 };
const A = z.Agent(Ctx, .{ .name = "a", .model = "anthropic/claude-sonnet-5-5", .examples = .{ .{ .in = "x", .out = 1 } } });
comptime { _ = A.prefix; }
