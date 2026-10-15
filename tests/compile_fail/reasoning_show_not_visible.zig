//! expect: zastra: agent 'a': model "custom/qwq" doesn't return readable reasoning; remove `.show_reasoning` (for a server that streams `reasoning_content`, set `.supports.reasoning_modes.visible = true`)
const z = @import("zastra");
const Ctx = struct {};
const M = z.custom(.{ .provider = .openai_compat, .id = "qwq", .base_url = "http://localhost:8000/v1", .supports = .{ .reasoning = true, .reasoning_modes = .{ .default_on = true } } });
const A = z.Agent(Ctx, .{ .name = "a", .model = M, .show_reasoning = true });
comptime { _ = A; }
