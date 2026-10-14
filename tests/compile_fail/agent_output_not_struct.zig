//! expect: `.output` must be a struct type (structured output is a JSON object); got u8
const std = @import("std");
const z = @import("zastra");
const Ctx = struct { db: u32 = 0 };
const A = z.Agent(Ctx, .{ .name = "a", .model = "anthropic/claude-sonnet-5-5", .output = u8 });
comptime { _ = A.prefix; }
