//! expect: zastra: 'Bad.p' has pointer type *u8; schema types can use slices
const z = @import("zastra");
const Bad = struct { p: *u8 };
comptime {
    _ = z.schema.of(Bad);
}
