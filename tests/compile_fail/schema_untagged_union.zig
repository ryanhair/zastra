//! expect: zastra: 'Bad.u' is an untagged union; use `union(enum)`
const z = @import("zastra");
const Bad = struct { u: union { a: u8, b: bool } };
comptime {
    _ = z.schema.of(Bad);
}
