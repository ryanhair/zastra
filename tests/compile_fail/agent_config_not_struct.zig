//! expect: config must be a struct literal
const std = @import("std");
const z = @import("zastra");
const Ctx = struct { db: u32 = 0 };
const A = z.Agent(Ctx, 5);
comptime { _ = A.prefix; }
