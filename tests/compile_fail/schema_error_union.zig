//! expect: zastra: 'Bad.e' is an error union
const z = @import("zastra");
const Bad = struct { e: anyerror!u8 };
comptime {
    _ = z.schema.of(Bad);
}
