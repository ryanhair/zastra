//! expect: z.step.parallel: `.l` must be a step type (workflows, loops and nested parallel groups aren't supported inside parallel)
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
const P = z.step.parallel(.{ .l = z.step.loop(ToA, .{ .until = done, .max = 2 }), .b = ToB });
comptime { _ = P; }
