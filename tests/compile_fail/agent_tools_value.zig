//! expect: `.tools` entry 0 is a value of type
const std = @import("std");
const z = @import("zastra");
const Ctx = struct { db: u32 = 0 };
const A = z.Agent(Ctx, .{ .name = "a", .model = "anthropic/claude-sonnet-5-5", .tools = .{5} });
comptime { _ = A.prefix; }
