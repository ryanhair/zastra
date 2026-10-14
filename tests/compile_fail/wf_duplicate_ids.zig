//! expect: has two different steps with id 'dup'
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
const D1 = struct {
    pub const Input = A;
    pub const Output = A;
    pub const name = "dup";
    pub fn run(w: *z.StepCtx(Ctx, @This()), in: Input) !Output { _ = w; return in; }
};
const D2 = struct {
    pub const Input = A;
    pub const Output = A;
    pub const name = "dup";
    pub fn run(w: *z.StepCtx(Ctx, @This()), in: Input) !Output { _ = w; return in; }
};
const W = z.Workflow(Ctx, "w", A).then(D1).then(D2).commit();
comptime { _ = W.fingerprint_value; }
