//! The model catalog (PLAN.md §5.4): comptime lookup of "provider/id" strings,
//! capability checks, pricing, and the `z.custom` escape hatch.

const std = @import("std");
const errors = @import("../meta/errors.zig");
const reflect = @import("../meta/reflect.zig");
const table = @import("models.zig");

/// Wire protocol a model speaks.
pub const Api = enum { anthropic, openai_compat };

pub const ProviderInfo = struct {
    name: []const u8,
    api: Api,
    base_url: []const u8,
    api_key_env: []const u8,
    base_url_env: []const u8,
};

pub const Supports = struct {
    tools: bool = true,
    /// Native JSON-schema-constrained output.
    structured_output: bool = false,
    vision: bool = false,
    reasoning: bool = false,
    parallel_tools: bool = true,
    prompt_caching: bool = false,
    /// `tool_choice` forcing a specific tool. Some newer models reject it.
    forced_tool_choice: bool = true,
    /// Accepts a non-default `temperature`.
    temperature: bool = true,
    /// How the agent's `.reasoning` and `.show_reasoning` map onto this
    /// model (PLAN.md D37).
    reasoning_modes: ReasoningModes = .{},
};

/// What a model's request accepts for controlling its reasoning.
pub const ReasoningModes = struct {
    /// Anthropic `thinking: {type: "adaptive"}`.
    adaptive: bool = false,
    /// Anthropic `thinking: {type: "enabled", budget_tokens: N}`.
    budget: bool = false,
    /// Reasoning can be turned off.
    disable: bool = false,
    /// Turning reasoning off is rejected at effort `xhigh` and `max`.
    disable_only_up_to_high: bool = false,
    /// The model reasons when the request doesn't mention it.
    default_on: bool = false,
    /// Readable reasoning can be streamed (Anthropic summaries, or
    /// `reasoning_content` from OpenAI-compatible servers).
    visible: bool = false,
    /// Readable reasoning is opt-in through `display: "summarized"`;
    /// without it, thinking blocks arrive with empty text.
    display_param: bool = false,
};

/// USD per million tokens.
pub const Pricing = struct {
    input: f64,
    output: f64,
    cache_read: f64 = 0,
    cache_write: f64 = 0,
};

/// A catalog row (see models.zig).
pub const Model = struct {
    provider: []const u8,
    id: []const u8,
    context_window: u32,
    max_output: u32,
    supports: Supports,
    pricing: ?Pricing = null,
};

pub const MaxTokensField = enum { max_tokens, max_completion_tokens };

/// A fully resolved model: everything a provider needs, known at comptime.
pub const Spec = struct {
    provider: []const u8,
    api: Api,
    id: []const u8,
    base_url: []const u8,
    api_key_env: ?[]const u8,
    base_url_env: ?[]const u8 = null,
    context_window: u32,
    max_output: u32,
    supports: Supports,
    pricing: ?Pricing,
    max_tokens_field: MaxTokensField,
    /// Extra request headers (OpenRouter attribution and the like).
    headers: []const [2][]const u8 = &.{},

    /// "anthropic/claude-sonnet-4-6"
    pub fn fullName(comptime s: Spec) []const u8 {
        return s.provider ++ "/" ++ s.id;
    }

    pub fn costUsd(s: Spec, u: anytype) f64 {
        const p = s.pricing orelse return 0;
        const m = 1_000_000.0;
        return @as(f64, @floatFromInt(u.input_tokens)) * p.input / m +
            @as(f64, @floatFromInt(u.output_tokens)) * p.output / m +
            @as(f64, @floatFromInt(u.cache_read_tokens)) * p.cache_read / m +
            @as(f64, @floatFromInt(u.cache_write_tokens)) * p.cache_write / m;
    }
};

pub const generated = table.generated;

fn providerNames() []const []const u8 {
    comptime {
        var names: [table.providers.len][]const u8 = undefined;
        for (table.providers, 0..) |p, i| names[i] = p.name;
        const final = names;
        return &final;
    }
}

fn modelIds(comptime provider: []const u8) []const []const u8 {
    comptime {
        var names: []const []const u8 = &.{};
        for (table.models) |m| if (std.mem.eql(u8, m.provider, provider)) {
            names = names ++ &[_][]const u8{m.id};
        };
        return names;
    }
}

/// Resolve a model given in an agent config: a "provider/id" string or a
/// `z.custom(...)` spec. `who` names the declaration for error messages,
/// e.g. "agent 'support'".
pub fn resolve(comptime m: anytype, comptime who: []const u8) Spec {
    comptime {
        @setEvalBranchQuota(1_000_000);
        const T = @TypeOf(m);
        if (T == Spec) return m;
        if (!reflect.isString(T)) errors.fail("{s}: `.model` must be a \"provider/model\" string or `z.custom(...)`, not {s}", .{ who, @typeName(T) });
        const s: []const u8 = m;
        const slash = std.mem.indexOfScalar(u8, s, '/') orelse
            errors.fail("{s} model \"{s}\": expected \"provider/model\", e.g. \"anthropic/claude-sonnet-5-5\"", .{ who, s });
        const provider = s[0..slash];
        const id = s[slash + 1 ..];
        const info = for (table.providers) |p| {
            if (std.mem.eql(u8, p.name, provider)) break p;
        } else errors.fail("{s} model \"{s}\": unknown provider '{s}'{s}; known providers are {s}. For other OpenAI-compatible services use `z.custom(...)`", .{
            who, s, provider, errors.didYouMean(provider, providerNames()), errors.list(providerNames()),
        });
        const row = for (table.models) |r| {
            if (std.mem.eql(u8, r.provider, provider) and std.mem.eql(u8, r.id, id)) break r;
        } else errors.fail("{s} model \"{s}\": unknown {s} model '{s}'{s}. If it's newer than zastra's catalog (dated {s}), declare it with `z.custom(.{{ .provider = .{s}, .id = \"{s}\", ... }})`", .{
            who, s, provider, id, errors.didYouMean(id, modelIds(provider)), table.generated, @tagName(info.api), id,
        });
        return .{
            .provider = provider,
            .api = info.api,
            .id = id,
            .base_url = info.base_url,
            .api_key_env = info.api_key_env,
            .base_url_env = info.base_url_env,
            .context_window = row.context_window,
            .max_output = row.max_output,
            .supports = row.supports,
            .pricing = row.pricing,
            .max_tokens_field = if (info.api == .openai_compat) .max_completion_tokens else .max_tokens,
        };
    }
}

/// `z.custom(...)`: a model the catalog doesn't know.
///
///     .model = z.custom(.{
///         .provider = .openai_compat,
///         .id = "llama-3.3-70b",
///         .base_url = "https://api.groq.com/openai/v1",
///         .api_key_env = "GROQ_API_KEY",
///         .supports = .{ .structured_output = true },
///     })
pub fn custom(comptime opts: anytype) Spec {
    comptime {
        const O = @TypeOf(opts);
        reflect.checkConfigFields(O, &.{
            "provider", "id",         "base_url", "api_key_env", "name", "supports", "context_window",
            "max_output", "pricing", "max_tokens_field", "headers",
        }, "z.custom(...)");
        if (!@hasField(O, "provider")) errors.fail("z.custom(...) needs `.provider` (.anthropic or .openai_compat)", .{});
        if (!@hasField(O, "id")) errors.fail("z.custom(...) needs `.id`, the model ID sent to the API", .{});
        const api: Api = opts.provider;
        const base_url: []const u8 = if (@hasField(O, "base_url")) opts.base_url else switch (api) {
            .anthropic => "https://api.anthropic.com",
            .openai_compat => errors.fail("z.custom(...) with `.provider = .openai_compat` needs `.base_url`, e.g. \"https://api.groq.com/openai/v1\"", .{}),
        };
        var supports: Supports = .{};
        if (@hasField(O, "supports")) {
            reflect.checkConfigFields(@TypeOf(opts.supports), reflect.fieldNames(Supports), "z.custom(...).supports");
            if (@hasField(@TypeOf(opts.supports), "reasoning_modes"))
                reflect.checkConfigFields(@TypeOf(opts.supports.reasoning_modes), reflect.fieldNames(ReasoningModes), "z.custom(...).supports.reasoning_modes");
            for (std.meta.fields(@TypeOf(opts.supports))) |f| @field(supports, f.name) = @field(opts.supports, f.name);
        }
        return .{
            .provider = if (@hasField(O, "name")) opts.name else "custom",
            .api = api,
            .id = opts.id,
            .base_url = base_url,
            .api_key_env = if (@hasField(O, "api_key_env")) opts.api_key_env else null,
            .context_window = if (@hasField(O, "context_window")) opts.context_window else 128_000,
            .max_output = if (@hasField(O, "max_output")) opts.max_output else 16_384,
            .supports = supports,
            .pricing = if (@hasField(O, "pricing")) opts.pricing else null,
            .max_tokens_field = if (@hasField(O, "max_tokens_field")) opts.max_tokens_field else .max_tokens,
            .headers = if (@hasField(O, "headers")) opts.headers else &.{},
        };
    }
}

/// Days since the catalog was generated, for `zastra dev models --stale`.
pub fn ageDays(now_unix_s: i64) i64 {
    const g = generated;
    const y = std.fmt.parseInt(u16, g[0..4], 10) catch return 0;
    const mo = std.fmt.parseInt(u8, g[5..7], 10) catch return 0;
    const d = std.fmt.parseInt(u8, g[8..10], 10) catch return 0;
    const days = daysFromCivil(y, mo, d);
    return @divFloor(now_unix_s, 86_400) - days;
}

fn daysFromCivil(y_in: i64, m: i64, d: i64) i64 {
    const y = if (m <= 2) y_in - 1 else y_in;
    const era = @divFloor(y, 400);
    const yoe = y - era * 400;
    const mp = @mod(m + 9, 12);
    const doy = @divFloor(153 * mp + 2, 5) + d - 1;
    const doe = yoe * 365 + @divFloor(yoe, 4) - @divFloor(yoe, 100) + doy;
    return era * 146_097 + doe - 719_468;
}

test resolve {
    const s = comptime resolve("anthropic/claude-sonnet-4-6", "test");
    try std.testing.expectEqual(Api.anthropic, s.api);
    try std.testing.expectEqualStrings("ANTHROPIC_API_KEY", s.api_key_env.?);
    const o = comptime resolve("openai/gpt-5-mini", "test");
    try std.testing.expect(o.supports.structured_output);
    try std.testing.expectEqual(MaxTokensField.max_completion_tokens, o.max_tokens_field);
    const c = comptime custom(.{ .provider = .openai_compat, .id = "llama3", .base_url = "http://localhost:11434/v1", .supports = .{ .tools = true } });
    try std.testing.expectEqualStrings("custom/llama3", comptime c.fullName());
    try std.testing.expectEqual(@as(i64, 0), daysFromCivil(1970, 1, 1));
}
