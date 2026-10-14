//! expect: unknown anthropic model 'claude-sonet-4-6' (did you mean 'claude-sonnet-4-6'?)
const std = @import("std");
const z = @import("zastra");
const Ctx = struct { db: u32 = 0 };
const A = z.Agent(Ctx, .{ .name = "a", .model = "anthropic/claude-sonet-4-6" });
comptime { _ = A.prefix; }
