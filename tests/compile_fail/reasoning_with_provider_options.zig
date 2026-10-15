//! expect: zastra: agent 'a': set reasoning with `.reasoning` or with `"thinking"` in `.provider_options`, not both
const z = @import("zastra");
const Ctx = struct {};
const A = z.Agent(Ctx, .{ .name = "a", .model = "anthropic/claude-sonnet-4-6", .reasoning = .on, .provider_options = "\"thinking\":{\"type\":\"adaptive\"}" });
comptime { _ = A; }
