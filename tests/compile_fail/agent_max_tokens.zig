//! expect: `.max_tokens = 999999` exceeds model "anthropic/claude-haiku-4-5"'s maximum output of 64000 tokens
const std = @import("std");
const z = @import("zastra");
const Ctx = struct { db: u32 = 0 };
const A = z.Agent(Ctx, .{ .name = "a", .model = "anthropic/claude-haiku-4-5", .max_tokens = 999999 });
comptime { _ = A.prefix; }
