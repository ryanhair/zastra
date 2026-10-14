//! expect: zastra: 'Triage.constraints' names `urgncy`, which is not a field of Triage (did you mean 'urgency'?)
const z = @import("zastra");
const Triage = struct {
    urgency: u8,
    pub const constraints = .{ .urgncy = .{ .min = 1 } };
};
comptime {
    _ = z.schema.of(Triage);
}
