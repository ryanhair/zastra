//! expect: z.custom(...).supports has unknown option `.vison` (did you mean 'vision'?)
const std = @import("std");
const z = @import("zastra");
const Ctx = struct { db: u32 = 0 };
comptime { _ = z.custom(.{ .provider = .anthropic, .id = "m", .supports = .{ .vison = true } }); }
