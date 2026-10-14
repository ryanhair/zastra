//! expect: zastra: 'Triage.docs' names `sumary`, which is not a field of Triage (did you mean 'summary'?)
const z = @import("zastra");
const Triage = struct {
    summary: []const u8,
    pub const docs = .{ .sumary = "One sentence" };
};
comptime {
    _ = z.schema.of(Triage);
}
