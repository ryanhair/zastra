//! expect: step 'gated' uses agent 'gated', which has approval-gated tools
const std = @import("std");
const z = @import("zastra");
const Ctx = struct {};
const A = struct { x: u8 };
const B = struct { y: u8 };
const ToA = struct {
    pub const Input = A;
    pub const Output = A;
    pub fn run(w: *z.StepCtx(Ctx, @This()), in: Input) !Output { _ = w; return in; }
};
const ToB = struct {
    pub const Input = A;
    pub const Output = B;
    pub fn run(w: *z.StepCtx(Ctx, @This()), in: Input) !Output { _ = w; return .{ .y = in.x }; }
};
const FromB = struct {
    pub const Input = B;
    pub const Output = B;
    pub fn run(w: *z.StepCtx(Ctx, @This()), in: Input) !Output { _ = w; return in; }
};
fn yes(_: A) bool { return true; }
const T = struct {
    pub const description = "d";
    pub const Input = struct { x: u8 };
    pub const Output = struct { y: u8 };
    pub const needs_approval = true;
    pub fn execute(_: *z.ToolCtx(Ctx), in: Input) !Output { return .{ .y = in.x }; }
};
const Ag = z.Agent(Ctx, .{ .name = "gated", .model = "anthropic/claude-sonnet-5-5", .tools = .{T} });
const S = z.step.agent(Ag, .{ .input = A, .prompt = "{x}" });
comptime { _ = S.Output; }
