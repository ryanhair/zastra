//! expect: with `.provider = .openai_compat` needs `.base_url`
const std = @import("std");
const z = @import("zastra");
const Ctx = struct { db: u32 = 0 };
comptime { _ = z.custom(.{ .provider = .openai_compat, .id = "m" }); }
