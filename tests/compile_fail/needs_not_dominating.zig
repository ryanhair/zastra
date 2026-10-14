//! expect: workflow 'w': step 'n' needs 'to_b' (as `.x`), which doesn't run before it on every path
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
    pub const Input = A;
    pub const Output = A;
    pub const needs = .{ .x = ToB };
    pub fn run(w: *z.StepCtx(Ctx, @This()), in: Input) !Output { _ = w; return in; }
};
const Arm = z.Workflow(Ctx, "arm", A).then(ToB).then(Back).commit();
const Back = struct {
    pub const Input = B;
    pub const Output = A;
    pub fn run(w: *z.StepCtx(Ctx, @This()), in: Input) !Output { _ = w; return .{ .x = in.y }; }
};
const W = z.Workflow(Ctx, "w", A).branch(.{ .{ yes, Arm }, .{ z.otherwise, ToA } }).then(N).commit();
const App = z.App(.{ .ctx = Ctx, .workflows = .{W} });
comptime { _ = App.workflows; }
