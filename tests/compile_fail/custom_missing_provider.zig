//! expect: z.custom(...) needs `.provider`
const std = @import("std");
const z = @import("zastra");
const Ctx = struct { db: u32 = 0 };
comptime { _ = z.custom(.{ .id = "m" }); }
