//! expect: prompt template placeholder '{subjet}' names `subjet`, which is not a field of Ticket (did you mean 'subject'?)
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
const Ticket = struct { subject: []const u8 };
const Ag = z.Agent(Ctx, .{ .name = "t", .model = "anthropic/claude-sonnet-5-5" });
const S = z.step.agent(Ag, .{ .input = Ticket, .prompt = "{subjet}" });
comptime { _ = S.Output; }
