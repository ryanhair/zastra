//! expect: example 0's `.out` has field `urgncy`, which is not a field of T (did you mean 'urgency'?)
const std = @import("std");
const z = @import("zastra");
const Ctx = struct { db: u32 = 0 };
const T = struct { urgency: u8 };
const A = z.Agent(Ctx, .{ .name = "a", .model = "anthropic/claude-sonnet-5-5", .output = T, .examples = .{ .{ .in = "x", .out = .{ .urgncy = 1 } } } });
comptime { _ = A.prefix; }
