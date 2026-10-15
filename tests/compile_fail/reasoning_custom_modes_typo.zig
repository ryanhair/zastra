//! expect: zastra: z.custom(...).supports.reasoning_modes has unknown option `.visable` (did you mean 'visible'?)
const z = @import("zastra");
const Ctx = struct {};
const M = z.custom(.{ .provider = .anthropic, .id = "claude-next", .supports = .{ .reasoning_modes = .{ .visable = true } } });
comptime { _ = M; }
