//! expect: doesn't accept a custom `.temperature`
const std = @import("std");
const z = @import("zastra");
const Ctx = struct { db: u32 = 0 };
const A = z.Agent(Ctx, .{ .name = "a", .model = "anthropic/claude-opus-5-5", .temperature = 0.2 });
comptime { _ = A.prefix; }
