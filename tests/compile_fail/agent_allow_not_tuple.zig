//! expect: `.allow` must be a tuple of effects
const std = @import("std");
const z = @import("zastra");
const Ctx = struct { db: u32 = 0 };
const A = z.Agent(Ctx, .{ .name = "a", .model = "anthropic/claude-sonnet-5-5", .allow = .reads });
comptime { _ = A.prefix; }
