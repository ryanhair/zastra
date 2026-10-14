//! expect: `.agents` must be a tuple of agent types
const std = @import("std");
const z = @import("zastra");
const Ctx = struct { db: u32 = 0 };
const App = z.App(.{ .ctx = Ctx, .agents = 5 });
comptime { _ = App.required_env; }
