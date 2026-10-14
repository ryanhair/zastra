//! expect: z.App(...) config has unknown option `.agnets` (did you mean 'agents'?)
const std = @import("std");
const z = @import("zastra");
const Ctx = struct { db: u32 = 0 };
const App = z.App(.{ .ctx = Ctx, .agnets = .{} });
comptime { _ = App.required_env; }
