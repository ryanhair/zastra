//! expect: z.testing.arbitrary: the source must be a `std.Random` or a `*std.testing.Smith`, got
const std = @import("std");
const z = @import("zastra");
export fn run() void {
    var prng: std.Random.DefaultPrng = .init(0);
    _ = z.testing.arbitrary(u8, std.heap.page_allocator, &prng) catch {};
}
