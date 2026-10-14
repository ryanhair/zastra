//! expect: `.allow` has unknown effect `.raeds` (did you mean 'reads'?)
const std = @import("std");
const z = @import("zastra");
const Ctx = struct { db: u32 = 0 };
const A = z.Agent(Ctx, .{ .name = "a", .model = "anthropic/claude-sonnet-5-5", .allow = .{.raeds} });
comptime { _ = A.prefix; }
