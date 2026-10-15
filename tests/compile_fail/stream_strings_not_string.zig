//! expect: Report.stream_strings names `.score`, which is u8; only string fields can stream as they grow
const std = @import("std");
const z = @import("zastra");
const Ctx = struct {};
const Report = struct {
    score: u8,
    pub const stream_strings = .{.score};
};
const A = z.Agent(Ctx, .{ .name = "a", .model = "anthropic/claude-sonnet-5-5", .output = Report, .partial_output = true });
comptime { _ = A.prefix; }
