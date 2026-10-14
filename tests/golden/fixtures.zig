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
