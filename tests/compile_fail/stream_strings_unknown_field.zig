//! expect: Report.stream_strings names `.sumary`, which isn't a field of Report (did you mean 'summary'?)
const std = @import("std");
const z = @import("zastra");
const Ctx = struct {};
const Report = struct {
    summary: []const u8,
    pub const stream_strings = .{.sumary};
};
const A = z.Agent(Ctx, .{ .name = "a", .model = "anthropic/claude-sonnet-5-5", .output = Report, .partial_output = true });
comptime { _ = A.prefix; }
