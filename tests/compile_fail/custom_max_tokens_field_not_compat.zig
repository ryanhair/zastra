//! expect: `.max_tokens_field` only applies to `.provider = .openai_compat`
const z = @import("zastra");
comptime {
    _ = z.custom(.{ .provider = .openai_responses, .id = "gpt-x", .max_tokens_field = .max_completion_tokens });
}
