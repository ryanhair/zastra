//! expect: zastra: workflow 'inner' can't run on its own: step 'n' needs 'to_b', which only exists in an enclosing workflow. Register the enclosing workflow instead.
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
const N = struct {
    pub const Input = B;
    pub const Output = B;
    pub const needs = .{ .x = ToB };
    pub fn run(w: *z.StepCtx(Ctx, @This()), in: Input) !Output { _ = w; return in; }
};
const Inner = z.Workflow(Ctx, "inner", B).then(N).commit();
const App = z.App(.{ .ctx = Ctx, .workflows = .{Inner} });
comptime { _ = App.workflows; }
