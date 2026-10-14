//! The size-budget check (PLAN.md §5.6, M7):
//!   size_check <bin> <max_bytes> [--absent <substring>] [--present <substring>] ...
//! Fails if the file is larger than the budget, or if a symbol-name
//! substring that must be absent (e.g. the OpenAI provider in an
//! Anthropic-only build) appears in the binary, or one that must be present
//! doesn't.

const std = @import("std");

pub fn main(init: std.process.Init) !u8 {
    const io = init.io;
    const args = try init.minimal.args.toSlice(init.arena.allocator());
    if (args.len < 3) {
        std.debug.print("usage: size_check <bin> <max_bytes> [--absent s] [--present s]...\n", .{});
        return 2;
    }
    const bytes = try std.Io.Dir.cwd().readFileAlloc(io, args[1], init.gpa, .limited(256 << 20));
    defer init.gpa.free(bytes);
    const max = try std.fmt.parseInt(usize, args[2], 10);
    var ok = true;
    std.debug.print("{s}: {d} bytes (budget {d})\n", .{ std.fs.path.basename(args[1]), bytes.len, max });
    if (bytes.len > max) {
        std.debug.print("  FAIL: over budget by {d} bytes\n", .{bytes.len - max});
        ok = false;
    }
    var i: usize = 3;
    while (i + 1 < args.len) : (i += 2) {
        const found = std.mem.indexOf(u8, bytes, args[i + 1]) != null;
        if (std.mem.eql(u8, args[i], "--absent") and found) {
            std.debug.print("  FAIL: contains \"{s}\"\n", .{args[i + 1]});
            ok = false;
        } else if (std.mem.eql(u8, args[i], "--present") and !found) {
            std.debug.print("  FAIL: doesn't contain \"{s}\"\n", .{args[i + 1]});
            ok = false;
        }
    }
    return if (ok) 0 else 1;
}
