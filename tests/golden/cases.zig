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

const support = @import("support_app");

fn text(comptime file: []const u8, comptime body: []const u8) Case {
    return .{
        .file = file,
        .render = struct {
            fn f(_: std.mem.Allocator) anyerror![]const u8 {
                return body;
            }
        }.f,
    };
}

const example = [_]Case{
    text("prefix/support.anthropic.json", support.Support.prefix.json ++ "\n"),
    text("prefix/triage.openai.json", support.TriageAgent.prefix.json ++ "\n"),
    text("prefix/reply_writer.anthropic.json", support.ReplyWriter.prefix.json ++ "\n"),
    text("mermaid/handle_ticket.mmd", support.HandleTicket.mermaid),
    text("manifest/support.json", z.capi.manifest.json(support.App) ++ "\n"),
    text("header/support.h", z.capi.header.render(support.App, "support")),
};

fn reasoningPrefixes() []const u8 {
    comptime {
        var out: []const u8 = "";
        for (@typeInfo(fx.reasoning_agents).@"struct".decl_names) |name| {
            const A = @field(fx.reasoning_agents, name);
            out = out ++ name ++ (if (A.show_reasoning) " (reasoning_delta)" else "") ++ ":\n" ++ A.prefix.json ++ "\n\n";
        }
        return out;
    }
}

const reasoning = [_]Case{text("prefix/reasoning_modes.txt", reasoningPrefixes())};

pub const all = example ++ reasoning ++ schemaCases(fx.Order, "order") ++
    schemaCases(fx.Ticket, "ticket") ++
    schemaCases(fx.Triage, "triage") ++
    schemaCases(fx.Resolution, "resolution") ++
    schemaCases(fx.CustomerNotes, "customer_notes") ++
    schemaCases(fx.IssueRefundInput, "issue_refund_input") ++
    schemaCases(fx.Shapes, "shapes");
