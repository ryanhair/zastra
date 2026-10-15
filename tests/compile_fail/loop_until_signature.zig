//! expect: z.step.loop(to_a, ...): `.until` must be `fn (A) bool`
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
fn bad(_: B) bool { return true; }
const L = z.step.loop(ToA, .{ .until = bad, .max = 2 });
comptime { _ = L; }
