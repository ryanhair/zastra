//! expect: 'b' is not a struct field path
const std = @import("std");
const z = @import("zastra");
const Ctx = struct { db: u32 = 0 };
const T = struct { a: u8 };
comptime { z.prompt.check(T, "{a.b}", "test"); }
