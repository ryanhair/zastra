//! expect: rt.workflow(...): workflow 'other' isn't registered
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
const W = z.Workflow(Ctx, "w", A).then(ToA).commit();
const O = z.Workflow(Ctx, "other", A).then(ToA).commit();
const App = z.App(.{ .ctx = Ctx, .workflows = .{W} });
export fn f(rt: *App.Runtime) void { _ = rt.workflow(O); }
