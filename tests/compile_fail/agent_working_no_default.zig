//! expect: working memory field `W.name` needs a default value
const std = @import("std");
const z = @import("zastra");
const Ctx = struct { db: u32 = 0 };
const W = struct { name: []const u8 };
const A = z.Agent(Ctx, .{ .name = "a", .model = "anthropic/claude-sonnet-5-5", .memory = .{ .working = W } });
comptime { _ = A.prefix; }
