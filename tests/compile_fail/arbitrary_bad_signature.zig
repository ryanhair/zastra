//! expect: Point.arbitrary must take one `*z.testing.Gen` parameter: `pub fn arbitrary(gen: *z.testing.Gen) !Point`
const std = @import("std");
const z = @import("zastra");
const Point = struct {
    x: i32,
    pub fn arbitrary(r: std.Random) Point {
        return .{ .x = r.int(i32) };
    }
};
export fn run() void {
    var prng: std.Random.DefaultPrng = .init(0);
    _ = z.testing.arbitrary(Point, std.heap.page_allocator, prng.random()) catch {};
}
