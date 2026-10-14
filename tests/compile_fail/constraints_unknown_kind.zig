//! expect: zastra: constraint `maxlen` on 'Triage.summary' is not a known constraint (did you mean 'max_len'?)
const z = @import("zastra");
const Triage = struct {
    summary: []const u8,
    pub const constraints = .{ .summary = .{ .maxlen = 200 } };
};
comptime {
    _ = z.schema.of(Triage);
}
