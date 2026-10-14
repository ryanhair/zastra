//! expect: zastra: constraint `min_len` doesn't apply to 'Triage.urgency', which is a u8; constraints for this type are 'min', 'max'
const z = @import("zastra");
const Triage = struct {
    urgency: u8,
    pub const constraints = .{ .urgency = .{ .min_len = 1 } };
};
comptime {
    _ = z.schema.of(Triage);
}
