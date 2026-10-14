//! The list of golden artifacts. Each case renders a string; the runner
//! compares it with `tests/golden/<file>`.

const std = @import("std");
const z = @import("zastra");
const fx = @import("fixtures.zig");

pub const Case = struct {
    file: []const u8,
    render: fn (std.mem.Allocator) anyerror![]const u8,
    owned: bool = false,
};

fn schemaCase(comptime T: type, comptime name: []const u8, comptime d: z.schema.Dialect) Case {
    return .{
        .file = "schema/" ++ name ++ "." ++ @tagName(d) ++ ".json",
        .render = struct {
            fn f(_: std.mem.Allocator) anyerror![]const u8 {
                return comptime z.schema.render(T, d) ++ "\n";
            }
        }.f,
    };
}

fn schemaCases(comptime T: type, comptime name: []const u8) [4]Case {
    return .{ schemaCase(T, name, .canonical), schemaCase(T, name, .anthropic), schemaCase(T, name, .anthropic_output), schemaCase(T, name, .openai) };
}

pub const all = schemaCases(fx.Order, "order") ++
    schemaCases(fx.Ticket, "ticket") ++
    schemaCases(fx.Triage, "triage") ++
    schemaCases(fx.Resolution, "resolution") ++
    schemaCases(fx.CustomerNotes, "customer_notes") ++
    schemaCases(fx.IssueRefundInput, "issue_refund_input") ++
    schemaCases(fx.Shapes, "shapes");
