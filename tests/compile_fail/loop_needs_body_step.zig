//! expect: step 'n' needs 'to_a', which runs inside loop 'loop_to_a'; its output only lasts one iteration. Carry the value in the loop's `A` and need the loop instead
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
fn done(_: A) bool { return true; }
const N = struct {
    pub const Input = A;
    pub const Output = A;
    pub const needs = .{ .x = ToA };
    pub fn run(w: *z.StepCtx(Ctx, @This()), in: Input) !Output { _ = w; return in; }
};
const W = z.Workflow(Ctx, "w", A).then(z.step.loop(ToA, .{ .until = done, .max = 2 })).then(N).commit();
const App = z.App(.{ .ctx = Ctx, .workflows = .{W} });
comptime { _ = App.workflows; }
