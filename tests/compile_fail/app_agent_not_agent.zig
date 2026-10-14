//! expect: `.agents` entry 0 is not an agent
const std = @import("std");
const z = @import("zastra");
const Ctx = struct { db: u32 = 0 };
const App = z.App(.{ .ctx = Ctx, .agents = .{u8} });
comptime { _ = App.required_env; }
