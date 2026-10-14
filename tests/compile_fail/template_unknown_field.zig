//! expect: prompt template placeholder '{subjet}' names `subjet`, which is not a field of Ticket (did you mean 'subject'?)
const std = @import("std");
const z = @import("zastra");
const Ctx = struct { db: u32 = 0 };
const Ticket = struct { subject: []const u8 };
comptime { z.prompt.check(Ticket, "S: {subjet}", "test"); }
