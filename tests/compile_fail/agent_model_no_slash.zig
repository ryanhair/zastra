//! expect: expected "provider/model"
const std = @import("std");
const z = @import("zastra");
const Ctx = struct { db: u32 = 0 };
const A = z.Agent(Ctx, .{ .name = "a", .model = "claude" });
comptime { _ = A.prefix; }
