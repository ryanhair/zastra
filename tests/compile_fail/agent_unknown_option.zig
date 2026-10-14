//! expect: z.Agent(...) config has unknown option `.instuctions` (did you mean 'instructions'?)
const std = @import("std");
const z = @import("zastra");
const Ctx = struct { db: u32 = 0 };
const A = z.Agent(Ctx, .{ .name = "a", .model = "anthropic/claude-sonnet-5-5", .instuctions = "x" });
comptime { _ = A.prefix; }
