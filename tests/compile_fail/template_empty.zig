//! expect: prompt template has an empty placeholder '{}'
const std = @import("std");
const z = @import("zastra");
const Ctx = struct { db: u32 = 0 };
const T = struct { a: u8 };
comptime { z.prompt.check(T, "{}", "test"); }
