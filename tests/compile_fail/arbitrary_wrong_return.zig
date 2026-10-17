//! expect: Point.arbitrary returns
const std = @import("std");
const z = @import("zastra");
const Point = struct {
    x: i32,
    pub fn arbitrary(g: *z.testing.Gen) !i32 {
        return g.int(i32, 0, 1);
    }
};
export fn run() void {
    var prng: std.Random.DefaultPrng = .init(0);
    _ = z.testing.arbitrary(Point, std.heap.page_allocator, prng.random()) catch {};
}
