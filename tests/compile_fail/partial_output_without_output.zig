//! expect: `.partial_output = true` needs `.output`: partial values are of the output type
const std = @import("std");
const z = @import("zastra");
const Ctx = struct {};
const A = z.Agent(Ctx, .{ .name = "a", .model = "anthropic/claude-sonnet-5-5", .partial_output = true });
comptime { _ = A.prefix; }
