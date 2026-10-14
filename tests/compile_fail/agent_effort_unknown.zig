//! expect: unknown `.effort = .hgih` (did you mean 'high'?)
const std = @import("std");
const z = @import("zastra");
const Ctx = struct { db: u32 = 0 };
const A = z.Agent(Ctx, .{ .name = "a", .model = "anthropic/claude-opus-5-5", .effort = .hgih });
comptime { _ = A.prefix; }
