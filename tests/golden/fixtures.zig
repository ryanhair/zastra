//! Types from sketch/src/app.zig, plus a few that exercise every mapping.

const z = @import("zastra");

pub const Order = struct {
    id: []const u8,
    status: enum { pending, shipped, delivered, cancelled },
    total_cents: u32,
    items: []const Item,

    pub const Item = struct { sku: []const u8, qty: u16 };
};

pub const Ticket = struct {
    customer_id: []const u8,
    subject: []const u8,
    body: []const u8,
};

pub const Triage = struct {
    category: enum { refund, shipping, product_question, other },
    urgency: u8,
    order_id: ?[]const u8 = null,
    summary: []const u8,

    pub const docs = .{
        .urgency = "1 = can wait a week, 5 = customer is blocked right now",
        .order_id = "Order ID if the customer mentioned one, e.g. ORD-1042",
        .summary = "One sentence, no customer PII",
    };
    pub const constraints = .{
        .urgency = .{ .min = 1, .max = 5 },
        .summary = .{ .max_len = 200 },
    };
};

pub const Resolution = struct {
    kind: enum { refunded, answered, escalated },
    message: []const u8,
};

pub const CustomerNotes = struct {
    name: ?[]const u8 = null,
    preferred_contact: ?enum { email, sms } = null,
    open_issues: []const []const u8 = &.{},
};

pub const IssueRefundInput = struct {
    order_id: []const u8,
    amount_cents: u32,
    reason: enum { damaged, late, wrong_item, other },
    pub const docs = .{ .amount_cents = "Must not exceed the order total" };
};

/// Every mapping in PLAN.md §5.1 in one type.
pub const Shapes = struct {
    flag: bool = false,
    small: i8,
    ratio: f32,
    label: []const u8 = "none",
    fixed: [2]u16,
    maybe_list: ?[]const u8,
    choice: union(enum) { nothing, count: u32, point: struct { x: f64, y: f64 } },
    anything: z.Json,
    code: []const u8,

    pub const description = "A type exercising every schema mapping.";
    pub const constraints = .{
        .ratio = .{ .min = 0, .max = 1 },
        .code = .{ .min_len = 3, .max_len = 8, .pattern = "^[A-Z]+$" },
        .label = .{ .one_of = .{ "none", "some" } },
    };
};

/// One agent per reasoning mapping (PLAN.md D37): the golden file shows the
/// `thinking` member (or its absence) each one sends.
pub const reasoning_agents = struct {
    const Ctx = struct {};
    pub const sonnet46_default = z.Agent(Ctx, .{ .name = "sonnet46_default", .model = "anthropic/claude-sonnet-4-6" });
    pub const sonnet46_on = z.Agent(Ctx, .{ .name = "sonnet46_on", .model = "anthropic/claude-sonnet-4-6", .reasoning = .on, .show_reasoning = true });
    pub const sonnet46_budget = z.Agent(Ctx, .{ .name = "sonnet46_budget", .model = "anthropic/claude-sonnet-4-6", .reasoning = .{ .budget = 4_000 } });
    pub const sonnet46_off = z.Agent(Ctx, .{ .name = "sonnet46_off", .model = "anthropic/claude-sonnet-4-6", .reasoning = .off });
    pub const sonnet55_default = z.Agent(Ctx, .{ .name = "sonnet55_default", .model = "anthropic/claude-sonnet-5-5" });
    pub const sonnet55_show = z.Agent(Ctx, .{ .name = "sonnet55_show", .model = "anthropic/claude-sonnet-5-5", .show_reasoning = true });
    pub const sonnet55_on = z.Agent(Ctx, .{ .name = "sonnet55_on", .model = "anthropic/claude-sonnet-5-5", .reasoning = .on, .effort = .high });
    pub const sonnet5_off = z.Agent(Ctx, .{ .name = "sonnet5_off", .model = "anthropic/claude-sonnet-5", .reasoning = .off, .effort = .high });
    pub const haiku45_budget = z.Agent(Ctx, .{ .name = "haiku45_budget", .model = "anthropic/claude-haiku-4-5", .reasoning = .{ .budget = 2_048 }, .show_reasoning = true });
    pub const gpt5mini_on = z.Agent(Ctx, .{ .name = "gpt5mini_on", .model = "openai/gpt-5-mini", .reasoning = .on, .effort = .low });
    pub const gpt5mini_show = z.Agent(Ctx, .{ .name = "gpt5mini_show", .model = "openai/gpt-5-mini", .show_reasoning = true });
    pub const gpt54mini_default = z.Agent(Ctx, .{ .name = "gpt54mini_default", .model = "openai/gpt-5.4-mini" });
    pub const gpt54mini_on = z.Agent(Ctx, .{ .name = "gpt54mini_on", .model = "openai/gpt-5.4-mini", .reasoning = .on, .show_reasoning = true });
    pub const gpt55_off = z.Agent(Ctx, .{ .name = "gpt55_off", .model = "openai/gpt-5.5", .reasoning = .off });
    pub const gpt55_max = z.Agent(Ctx, .{ .name = "gpt55_max", .model = "openai/gpt-5.5", .effort = .max });
    pub const gpt51_max = z.Agent(Ctx, .{ .name = "gpt51_max", .model = "openai/gpt-5.1", .effort = .max });
};
