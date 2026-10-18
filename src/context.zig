//! Contexts handed to user code: `z.ToolCtx(Ctx)` for tools (PLAN.md §3.1).
//! `z.StepCtx` lives in workflow/step_ctx.zig.

const std = @import("std");
const trace = @import("trace/trace.zig");
const Allocator = std.mem.Allocator;

pub fn ToolCtx(comptime Ctx: type) type {
    return struct {
        const Self = @This();

        /// The App's context. Tools in one step may run concurrently, so
        /// anything reachable from here must be safe to use from several
        /// threads (or set `pub const parallel = false` on the tool).
        ctx: *Ctx,
        /// Private to this tool call; freed after the result is recorded.
        arena: Allocator,
        io: std.Io,
        run_id: []const u8,
        tool_call_id: []const u8,
        trace: *trace.Span,

        /// Narrowed access to one context field, for tools that declare
        /// `Requires` (§5.13): `t.require(.http)`.
        pub fn require(t: *Self, comptime field: @EnumLiteral()) @FieldType(Ctx, @tagName(field)) {
            return @field(t.ctx, @tagName(field));
        }

        /// Format into `arena`.
        pub fn fmt(t: *Self, comptime f: []const u8, args: anytype) Allocator.Error![]u8 {
            return t.arena.print(f, args);
        }
    };
}
