//! expect: supports neither structured output nor tool use, so `.output` can't be enforced
const std = @import("std");
const z = @import("zastra");
const Ctx = struct { db: u32 = 0 };
const A = z.Agent(Ctx, .{ .name = "a", .model = z.custom(.{ .provider = .openai_compat, .id = "m", .base_url = "http://x", .supports = .{ .tools = false } }), .output = struct { x: u8 } });
comptime { _ = A.prefix; }
