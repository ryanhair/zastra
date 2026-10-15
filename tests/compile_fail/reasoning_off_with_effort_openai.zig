//! expect: zastra: agent 'a': `.reasoning = .off` sets OpenAI's reasoning effort to "none"; remove `.effort`
const z = @import("zastra");
const Ctx = struct {};
const A = z.Agent(Ctx, .{ .name = "a", .model = "openai/gpt-5.5", .reasoning = .off, .effort = .low });
comptime { _ = A; }
