//! expect: zastra: agent 'support' model "antropic/claude-sonnet-4-6": unknown provider 'antropic' (did you mean 'anthropic'?)
const std = @import("std");
const z = @import("zastra");
const Ctx = struct { db: u32 = 0 };
const A = z.Agent(Ctx, .{ .name = "support", .model = "antropic/claude-sonnet-4-6" });
comptime { _ = A.prefix; }
