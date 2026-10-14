//! expect: `.memory` has unknown option `.histroy` (did you mean 'history'?)
const std = @import("std");
const z = @import("zastra");
const Ctx = struct { db: u32 = 0 };
const A = z.Agent(Ctx, .{ .name = "a", .model = "anthropic/claude-sonnet-5-5", .memory = .{ .histroy = .{} } });
comptime { _ = A.prefix; }
