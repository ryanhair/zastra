//! expect: `.max_steps` must be at least 1
const std = @import("std");
const z = @import("zastra");
const Ctx = struct { db: u32 = 0 };
const A = z.Agent(Ctx, .{ .name = "a", .model = "anthropic/claude-sonnet-5-5", .max_steps = 0 });
comptime { _ = A.prefix; }
