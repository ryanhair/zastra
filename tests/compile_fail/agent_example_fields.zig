//! expect: example 0 needs `.in` and `.out`
const std = @import("std");
const z = @import("zastra");
const Ctx = struct { db: u32 = 0 };
const A = z.Agent(Ctx, .{ .name = "a", .model = "anthropic/claude-sonnet-5-5", .output = struct { x: u8 }, .examples = .{ .{ .input = "x" } } });
comptime { _ = A.prefix; }
