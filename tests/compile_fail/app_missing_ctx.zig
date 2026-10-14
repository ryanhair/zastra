//! expect: z.App(...) needs `.ctx = YourCtx`
const std = @import("std");
const z = @import("zastra");
const Ctx = struct { db: u32 = 0 };
const App = z.App(.{});
comptime { _ = App.required_env; }
