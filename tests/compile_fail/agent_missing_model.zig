//! expect: agent 'a' is missing `.model`
const std = @import("std");
const z = @import("zastra");
const Ctx = struct { db: u32 = 0 };
const A = z.Agent(Ctx, .{ .name = "a" });
comptime { _ = A.prefix; }
