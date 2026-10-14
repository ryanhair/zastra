//! expect: `.tools` must be a tuple of tool types
const std = @import("std");
const z = @import("zastra");
const Ctx = struct { db: u32 = 0 };
const A = z.Agent(Ctx, .{ .name = "a", .model = "anthropic/claude-sonnet-5-5", .tools = 5 });
comptime { _ = A.prefix; }
