//! Regenerates src/catalog/models.zig from tools/models-update/sources.json.
//!
//!   zig build models-update
//!
//! sources.json is maintained by hand from the providers' published model and
//! pricing pages (PLAN.md §5.4). Its `sources` object records where each
//! provider's numbers came from.
//!
//! With ANTHROPIC_API_KEY set, Anthropic rows are first checked against
//! `GET /v1/models` (PLAN.md §17.1): context window, max output, structured
//! output and the thinking types the API reports are written back into
//! sources.json, and every change is printed. A field listed in a row's
//! `pinned` array is never overwritten; if the API disagrees with it, the
//! run fails so a person can decide. Pricing and the reasoning details the
//! API doesn't report (defaults, `display`, effort limits) stay hand-written.

const std = @import("std");
const Allocator = std.mem.Allocator;

const ReasoningModes = struct {
    adaptive: bool = false,
    budget: bool = false,
    disable: bool = false,
    disable_only_up_to_high: bool = false,
    default_on: bool = false,
    visible: bool = false,
    display_param: bool = false,
    xhigh_effort: bool = false,
};

const Supports = struct {
    tools: bool,
    structured_output: bool,
    vision: bool,
    reasoning: bool,
    parallel_tools: bool,
    prompt_caching: bool,
    forced_tool_choice: bool,
    temperature: bool,
    reasoning_modes: ?ReasoningModes = null,
};

const Pricing = struct { input: f64, output: f64, cache_read: f64, cache_write: f64 };

const Model = struct {
    provider: []const u8,
    id: []const u8,
    context_window: u32,
    max_output: u32,
    supports: Supports,
    pricing: Pricing,
    /// Fields the API sync must not change, e.g. "max_output" or
    /// "supports.structured_output".
    pinned: ?[]const []const u8 = null,
};

const ProviderInfo = struct {
    api: []const u8,
    base_url: []const u8,
    api_key_env: []const u8,
    base_url_env: []const u8,
};

const Sources = struct {
    generated: []const u8,
    sources: std.json.ArrayHashMap([]const u8),
    providers: std.json.ArrayHashMap(ProviderInfo),
    models: []Model,
};

const sources_path = "tools/models-update/sources.json";

pub fn main(init: std.process.Init) !void {
    const io = init.io;
    const arena = init.arena.allocator();
    const cwd = std.Io.Dir.cwd();

    const text = try cwd.readFileAlloc(io, sources_path, arena, .limited(1 << 22));
    var src = try std.json.parseFromSliceLeaky(Sources, arena, text, .{});

    if (init.environ_map.get("ANTHROPIC_API_KEY")) |key| {
        const conflicts = try syncAnthropic(arena, io, init.environ_map, key, &src);
        var aw: std.Io.Writer.Allocating = .init(arena);
        try std.json.Stringify.value(src, .{ .whitespace = .indent_1, .emit_null_optional_fields = false }, &aw.writer);
        try aw.writer.writeByte('\n');
        if (!std.mem.eql(u8, aw.written(), text)) {
            try cwd.writeFile(io, .{ .sub_path = sources_path, .data = aw.written() });
            std.debug.print("models-update: updated {s} from GET /v1/models\n", .{sources_path});
        }
        if (conflicts > 0) {
            std.debug.print("models-update: {d} pinned field(s) disagree with the API; fix or unpin them in {s}\n", .{ conflicts, sources_path });
            std.process.exit(1);
        }
    } else {
        std.debug.print("models-update: ANTHROPIC_API_KEY not set; using {s} as is\n", .{sources_path});
    }

    try cwd.writeFile(io, .{ .sub_path = "src/catalog/models.zig", .data = try render(arena, src) });
    std.debug.print("models-update: wrote {d} models to src/catalog/models.zig\n", .{src.models.len});
}

const ApiModel = struct {
    id: []const u8,
    max_input_tokens: ?u32 = null,
    max_tokens: ?u32 = null,
    capabilities: ?std.json.Value = null,
};

const ApiList = struct {
    data: []const ApiModel,
    has_more: bool = false,
    last_id: ?[]const u8 = null,
};

/// Update Anthropic rows from the Models API. Returns how many pinned
/// fields disagree with it.
fn syncAnthropic(arena: Allocator, io: std.Io, env: *const std.process.Environ.Map, key: []const u8, src: *Sources) !u32 {
    var client: std.http.Client = .{ .allocator = arena, .io = io };
    defer client.deinit();
    var proxy_arena: std.heap.ArenaAllocator = .init(arena);
    client.initDefaultProxies(proxy_arena.allocator(), env) catch {};

    var api: std.ArrayList(ApiModel) = .empty;
    var after: ?[]const u8 = null;
    while (true) {
        const url = if (after) |a|
            try arena.print("https://api.anthropic.com/v1/models?limit=1000&after_id={s}", .{a})
        else
            "https://api.anthropic.com/v1/models?limit=1000";
        var body: std.Io.Writer.Allocating = .init(arena);
        const res = try client.fetch(.{
            .location = .{ .url = url },
            .extra_headers = &.{
                .{ .name = "x-api-key", .value = key },
                .{ .name = "anthropic-version", .value = "2023-06-01" },
            },
            .response_writer = &body.writer,
        });
        if (res.status != .ok) {
            std.debug.print("models-update: GET /v1/models returned {d}: {s}\n", .{ @backingInt(res.status), body.written() });
            return error.ModelsApiFailed;
        }
        const page = try std.json.parseFromSliceLeaky(ApiList, arena, body.written(), .{ .ignore_unknown_fields = true });
        try api.appendSlice(arena, page.data);
        if (!page.has_more or page.last_id == null) break;
        after = page.last_id;
    }

    var conflicts: u32 = 0;
    for (src.models) |*m| {
        if (!std.mem.eql(u8, m.provider, "anthropic")) continue;
        const a = findApi(api.items, m.id) orelse {
            std.debug.print("  {s}: not listed by GET /v1/models\n", .{m.id});
            continue;
        };
        var u: Updater = .{ .m = m, .conflicts = &conflicts };
        if (a.max_input_tokens) |v| u.int("context_window", &m.context_window, v);
        if (a.max_tokens) |v| u.int("max_output", &m.max_output, v);
        const caps = a.capabilities orelse continue;
        if (capability(caps, &.{"structured_outputs"})) |v| u.boolean("supports.structured_output", &m.supports.structured_output, v);
        if (capability(caps, &.{ "thinking", "types", "adaptive" })) |adaptive| {
            var rm = m.supports.reasoning_modes orelse ReasoningModes{};
            u.boolean("supports.reasoning_modes.adaptive", &rm.adaptive, adaptive);
            if (capability(caps, &.{ "thinking", "types", "enabled" })) |v| u.boolean("supports.reasoning_modes.budget", &rm.budget, v);
            if (capability(caps, &.{ "thinking", "types", "disabled" })) |v| u.boolean("supports.reasoning_modes.disable", &rm.disable, v);
            m.supports.reasoning_modes = rm;
        }
    }
    for (api.items) |a| {
        const known = for (src.models) |m| {
            if (std.mem.eql(u8, m.provider, "anthropic") and matches(a.id, m.id)) break true;
        } else false;
        if (!known) std.debug.print("  new model {s}: add it to {s} with its pricing\n", .{ a.id, sources_path });
    }
    return conflicts;
}

/// Catalog ids are aliases ("claude-haiku-4-5"); the API may list the
/// dated id ("claude-haiku-4-5-20251001").
fn matches(api_id: []const u8, id: []const u8) bool {
    if (std.mem.eql(u8, api_id, id)) return true;
    if (!std.mem.startsWith(u8, api_id, id) or api_id.len != id.len + 9) return false;
    const rest = api_id[id.len..];
    if (rest[0] != '-') return false;
    for (rest[1..]) |c| if (!std.ascii.isDigit(c)) return false;
    return true;
}

fn findApi(api: []const ApiModel, id: []const u8) ?ApiModel {
    for (api) |a| if (std.mem.eql(u8, a.id, id)) return a;
    for (api) |a| if (matches(a.id, id)) return a;
    return null;
}

/// `capabilities.<path...>.supported`, if present.
fn capability(caps: std.json.Value, path: []const []const u8) ?bool {
    var v = caps;
    for (path) |k| {
        if (v != .object) return null;
        v = v.object.get(k) orelse return null;
    }
    if (v != .object) return null;
    const s = v.object.get("supported") orelse return null;
    return if (s == .bool) s.bool else null;
}

const Updater = struct {
    m: *Model,
    conflicts: *u32,

    fn pinned(u: Updater, field: []const u8) bool {
        for (u.m.pinned orelse &.{}) |p| if (std.mem.eql(u8, p, field)) return true;
        return false;
    }

    fn int(u: Updater, field: []const u8, dst: *u32, v: u32) void {
        if (dst.* == v) return;
        if (u.pinned(field)) {
            std.debug.print("  {s}.{s}: pinned to {d}, API says {d}\n", .{ u.m.id, field, dst.*, v });
            u.conflicts.* += 1;
            return;
        }
        std.debug.print("  {s}.{s}: {d} -> {d}\n", .{ u.m.id, field, dst.*, v });
        dst.* = v;
    }

    fn boolean(u: Updater, field: []const u8, dst: *bool, v: bool) void {
        if (dst.* == v) return;
        if (u.pinned(field)) {
            std.debug.print("  {s}.{s}: pinned to {}, API says {}\n", .{ u.m.id, field, dst.*, v });
            u.conflicts.* += 1;
            return;
        }
        std.debug.print("  {s}.{s}: {} -> {}\n", .{ u.m.id, field, dst.*, v });
        dst.* = v;
    }
};

fn render(arena: Allocator, src: Sources) ![]const u8 {
    var aw: std.Io.Writer.Allocating = .init(arena);
    const w = &aw.writer;
    try w.print(
        \\//! GENERATED by `zig build models-update` from tools/models-update/sources.json.
        \\//! Do not edit by hand.
        \\
        \\const Model = @import("catalog.zig").Model;
        \\
        \\pub const generated = "{s}";
        \\
        \\pub const providers = [_]@import("catalog.zig").ProviderInfo{{
        \\
    , .{src.generated});
    for (src.providers.map.keys(), src.providers.map.values()) |name, p| {
        try w.print(
            \\    .{{ .name = "{s}", .api = .{s}, .base_url = "{s}", .api_key_env = "{s}", .base_url_env = "{s}" }},
            \\
        , .{ name, p.api, p.base_url, p.api_key_env, p.base_url_env });
    }
    try w.writeAll("};\n\npub const models = [_]Model{\n");
    for (src.models) |m| {
        const s = m.supports;
        try w.print(
            \\    .{{
            \\        .provider = "{s}",
            \\        .id = "{s}",
            \\        .context_window = {d},
            \\        .max_output = {d},
            \\        .supports = .{{
            \\            .tools = {}, .structured_output = {}, .vision = {}, .reasoning = {}, .parallel_tools = {}, .prompt_caching = {}, .forced_tool_choice = {}, .temperature = {},
            \\
        , .{
            m.provider,        m.id,                m.context_window, m.max_output,
            s.tools,           s.structured_output, s.vision,                  s.reasoning,
            s.parallel_tools,  s.prompt_caching,    s.forced_tool_choice,      s.temperature,
        });
        if (s.reasoning_modes) |r| try w.print(
            \\            .reasoning_modes = .{{ .adaptive = {}, .budget = {}, .disable = {}, .disable_only_up_to_high = {}, .default_on = {}, .visible = {}, .display_param = {}, .xhigh_effort = {} }},
            \\
        , .{ r.adaptive, r.budget, r.disable, r.disable_only_up_to_high, r.default_on, r.visible, r.display_param, r.xhigh_effort });
        try w.print(
            \\        }},
            \\        .pricing = .{{ .input = {d}, .output = {d}, .cache_read = {d}, .cache_write = {d} }},
            \\    }},
            \\
        , .{ m.pricing.input, m.pricing.output, m.pricing.cache_read, m.pricing.cache_write });
    }
    try w.writeAll("};\n");
    return aw.written();
}

test "sources.json round-trips byte for byte, so a sync only diffs what changed" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const text = @embedFile("sources.json");
    const src = try std.json.parseFromSliceLeaky(Sources, arena.allocator(), text, .{});
    var aw: std.Io.Writer.Allocating = .init(arena.allocator());
    try std.json.Stringify.value(src, .{ .whitespace = .indent_1, .emit_null_optional_fields = false }, &aw.writer);
    try aw.writer.writeByte('\n');
    try std.testing.expectEqualStrings(text, aw.written());
}

test "dated API ids match catalog aliases" {
    try std.testing.expect(matches("claude-haiku-4-5-20251001", "claude-haiku-4-5"));
    try std.testing.expect(matches("claude-opus-5", "claude-opus-5"));
    try std.testing.expect(!matches("claude-opus-5-5", "claude-opus-5"));
    try std.testing.expect(!matches("claude-haiku-4-5-2025100x", "claude-haiku-4-5"));
}

test "capability lookup" {
    const v = try std.json.parseFromSlice(std.json.Value, std.testing.allocator,
        \\{"structured_outputs":{"supported":true},"thinking":{"supported":true,"types":{"adaptive":{"supported":false}}}}
    , .{});
    defer v.deinit();
    try std.testing.expectEqual(@as(?bool, true), capability(v.value, &.{"structured_outputs"}));
    try std.testing.expectEqual(@as(?bool, false), capability(v.value, &.{ "thinking", "types", "adaptive" }));
    try std.testing.expectEqual(@as(?bool, null), capability(v.value, &.{ "thinking", "types", "enabled" }));
}
