//! expect: agent 'a': `.model` must be a "provider/model" string or `z.custom(...)`
const std = @import("std");
const z = @import("zastra");
const Ctx = struct { db: u32 = 0 };
const A = z.Agent(Ctx, .{ .name = "a", .model = 5 });
comptime { _ = A.prefix; }
