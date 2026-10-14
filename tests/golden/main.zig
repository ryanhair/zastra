//! Golden-file runner. Renders every golden artifact and compares it with the
//! checked-in file under tests/golden/. `--update` rewrites the files.

const std = @import("std");
const cases = @import("cases.zig");

pub fn main(init: std.process.Init) !void {
    const io = init.io;
    const gpa = init.gpa;
    var update = false;
    var args = try init.minimal.args.iterateAllocator(gpa);
    defer args.deinit();
    _ = args.skip();
    while (args.next()) |a| {
        if (std.mem.eql(u8, a, "--update")) update = true;
    }

    var dir = try std.Io.Dir.cwd().openDir(io, "tests/golden", .{});
    defer dir.close(io);

    var failed: usize = 0;
    inline for (cases.all) |c| {
        const actual: []const u8 = try c.render(gpa);
        defer if (c.owned) gpa.free(actual);
        if (update) {
            try dir.writeFile(io, .{ .sub_path = c.file, .data = actual });
        } else {
            const expected = dir.readFileAlloc(io, c.file, gpa, .limited(1 << 24)) catch |err| switch (err) {
                error.FileNotFound => blk: {
                    std.debug.print("golden: missing tests/golden/{s} (run `zig build golden -- --update`)\n", .{c.file});
                    failed += 1;
                    break :blk null;
                },
                else => return err,
            };
            if (expected) |e| {
                defer gpa.free(e);
                if (!std.mem.eql(u8, e, actual)) {
                    std.debug.print("golden: tests/golden/{s} differs (run `zig build golden -- --update` if intended)\n", .{c.file});
                    failed += 1;
                }
            }
        }
    }
    if (failed > 0) std.process.exit(1);
}
