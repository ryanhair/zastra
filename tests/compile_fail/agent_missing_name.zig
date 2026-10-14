//! expect: config is missing `.name`. Agents are types returned by a function
const std = @import("std");
const z = @import("zastra");
const Ctx = struct { db: u32 = 0 };
const A = z.Agent(Ctx, .{ .model = "anthropic/claude-sonnet-5-5" });
comptime { _ = A.prefix; }
