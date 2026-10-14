//! expect: zastra: 'Bad.f' is a function pointer; schema types describe data
const z = @import("zastra");
const Bad = struct { f: *const fn () void };
comptime {
    _ = z.schema.of(Bad);
}
