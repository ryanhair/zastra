//! expect: z.custom(...) has unknown option `.baseurl` (did you mean 'base_url'?)
const std = @import("std");
const z = @import("zastra");
const Ctx = struct { db: u32 = 0 };
comptime { _ = z.custom(.{ .provider = .openai_compat, .id = "m", .baseurl = "x" }); }
