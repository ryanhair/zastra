//! The internal message model (PLAN.md §6.1). Providers translate to and
//! from it at the edges; memory persists it as JSON.

const std = @import("std");
const json = @import("schema/json.zig");
const Allocator = std.mem.Allocator;

pub const Role = enum { system, user, assistant, tool };

pub const Image = struct {
    media_type: []const u8,
    source: union(enum) { base64: []const u8, url: []const u8 },
};

pub const ToolUse = struct {
    id: []const u8,
    name: []const u8,
    /// Complete JSON object text of the arguments.
    input_json: []const u8,
};

pub const ToolResult = struct {
    id: []const u8,
    /// Tool name; OpenAI doesn't need it, but it makes traces and history readable.
    name: []const u8 = "",
    /// JSON (or plain text) result body.
    content: []const u8,
    is_error: bool = false,
};

pub const Reasoning = struct {
    text: []const u8,
    /// Anthropic thinking signature; must round-trip unchanged.
    signature: ?[]const u8 = null,
};

/// Content a provider produced that zastra doesn't model (e.g. Anthropic
/// `redacted_thinking`). Sent back to the same provider verbatim.
pub const ProviderOpaque = struct {
    provider: []const u8,
    json: []const u8,
};

pub const Block = union(enum) {
    text: []const u8,
    image: Image,
    tool_use: ToolUse,
    tool_result: ToolResult,
    reasoning: Reasoning,
    provider_opaque: ProviderOpaque,
};

pub const Content = union(enum) {
    text: []const u8,
    blocks: []const Block,
};

pub const Message = struct {
    role: Role,
    content: Content,

    pub fn user(t: []const u8) Message {
        return .{ .role = .user, .content = .{ .text = t } };
    }
    pub fn assistant(t: []const u8) Message {
        return .{ .role = .assistant, .content = .{ .text = t } };
    }
    pub fn system(t: []const u8) Message {
        return .{ .role = .system, .content = .{ .text = t } };
    }

    /// Concatenated text of all text blocks.
    pub fn allText(m: Message, gpa: Allocator) ![]const u8 {
        return switch (m.content) {
            .text => |t| t,
            .blocks => |bs| blk: {
                var out: std.ArrayList(u8) = .empty;
                for (bs) |b| if (b == .text) try out.appendSlice(gpa, b.text);
                break :blk try out.toOwnedSlice(gpa);
            },
        };
    }

    /// Visit every block, treating `.text` content as one text block.
    pub fn forEachBlock(m: Message, ctx: anytype, comptime f: fn (@TypeOf(ctx), Block) anyerror!void) anyerror!void {
        switch (m.content) {
            .text => |t| try f(ctx, .{ .text = t }),
            .blocks => |bs| for (bs) |b| try f(ctx, b),
        }
    }

    /// Number of blocks of the given kind.
    pub fn count(m: Message, comptime tag: std.meta.Tag(Block)) usize {
        return switch (m.content) {
            .text => if (tag == .text) 1 else 0,
            .blocks => |bs| blk: {
                var n: usize = 0;
                for (bs) |b| if (b == tag) {
                    n += 1;
                };
                break :blk n;
            },
        };
    }
};

/// Deep-copy a message into `gpa`.
pub fn clone(gpa: Allocator, m: Message) Allocator.Error!Message {
    return .{
        .role = m.role,
        .content = switch (m.content) {
            .text => |t| .{ .text = try gpa.dupe(u8, t) },
            .blocks => |bs| .{ .blocks = try cloneBlocks(gpa, bs) },
        },
    };
}

pub fn cloneBlocks(gpa: Allocator, bs: []const Block) Allocator.Error![]const Block {
    const out = try gpa.alloc(Block, bs.len);
    for (bs, 0..) |b, i| out[i] = switch (b) {
        .text => |t| .{ .text = try gpa.dupe(u8, t) },
        .image => |im| .{ .image = .{ .media_type = try gpa.dupe(u8, im.media_type), .source = switch (im.source) {
            .base64 => |s| .{ .base64 = try gpa.dupe(u8, s) },
            .url => |s| .{ .url = try gpa.dupe(u8, s) },
        } } },
        .tool_use => |t| .{ .tool_use = .{ .id = try gpa.dupe(u8, t.id), .name = try gpa.dupe(u8, t.name), .input_json = try gpa.dupe(u8, t.input_json) } },
        .tool_result => |t| .{ .tool_result = .{ .id = try gpa.dupe(u8, t.id), .name = try gpa.dupe(u8, t.name), .content = try gpa.dupe(u8, t.content), .is_error = t.is_error } },
        .reasoning => |r| .{ .reasoning = .{ .text = try gpa.dupe(u8, r.text), .signature = if (r.signature) |s| try gpa.dupe(u8, s) else null } },
        .provider_opaque => |o| .{ .provider_opaque = .{ .provider = try gpa.dupe(u8, o.provider), .json = try gpa.dupe(u8, o.json) } },
    };
    return out;
}

// ── persistence ──────────────────────────────────────────────────────────────
// Messages are stored as JSON in the shape of `Message` itself (union blocks
// use the zastra "type" discriminator), so they round-trip through
// `schema/json.zig` and `schema/parse.zig`.

pub fn toJson(gpa: Allocator, m: Message) ![]u8 {
    return json.stringifyAlloc(gpa, m);
}

pub fn fromJson(arena: Allocator, text: []const u8) !Message {
    var issue: @import("schema/parse.zig").Issue = .{};
    return @import("schema/parse.zig").parse(Message, arena, text, &issue) catch |err| switch (err) {
        error.OutOfMemory => error.OutOfMemory,
        error.ValidationFailed => error.CorruptMessage,
    };
}

pub const Usage = struct {
    input_tokens: u64 = 0,
    output_tokens: u64 = 0,
    cache_read_tokens: u64 = 0,
    cache_write_tokens: u64 = 0,
    cost_usd: f64 = 0,

    pub fn add(a: *Usage, b: Usage) void {
        a.input_tokens += b.input_tokens;
        a.output_tokens += b.output_tokens;
        a.cache_read_tokens += b.cache_read_tokens;
        a.cache_write_tokens += b.cache_write_tokens;
        a.cost_usd += b.cost_usd;
    }
};

pub const FinishReason = enum {
    /// The model finished its turn.
    end_turn,
    /// The model wants tools run.
    tool_use,
    /// `max_tokens` reached.
    max_tokens,
    stop_sequence,
    /// The provider declined (safety classifier, content filter).
    refusal,
    /// The agent hit `max_steps`.
    max_steps,
    /// A `stop_when` predicate ended the run.
    stopped,
    canceled,
    other,
};

test "message JSON round-trip" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const m: Message = .{ .role = .assistant, .content = .{ .blocks = &.{
        .{ .reasoning = .{ .text = "", .signature = "sig" } },
        .{ .text = "hi" },
        .{ .tool_use = .{ .id = "t1", .name = "lookup", .input_json = "{\"a\":1}" } },
    } } };
    const s = try toJson(a, m);
    const back = try fromJson(a, s);
    try std.testing.expectEqualStrings("sig", back.content.blocks[0].reasoning.signature.?);
    try std.testing.expectEqualStrings("{\"a\":1}", back.content.blocks[2].tool_use.input_json);
    try std.testing.expectEqual(@as(usize, 1), back.count(.tool_use));
}
