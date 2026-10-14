//! expect: declare it with `z.custom(.{ .provider = .anthropic, .id = "claude-next", ... })`
const std = @import("std");
const z = @import("zastra");
const Ctx = struct { db: u32 = 0 };
const A = z.Agent(Ctx, .{ .name = "a", .model = "anthropic/claude-next" });
comptime { _ = A.prefix; }
