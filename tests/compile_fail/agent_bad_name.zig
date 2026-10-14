//! expect: agent name "a b" must match
const std = @import("std");
const z = @import("zastra");
const Ctx = struct { db: u32 = 0 };
const A = z.Agent(Ctx, .{ .name = "a b", .model = "anthropic/claude-sonnet-5-5" });
comptime { _ = A.prefix; }
