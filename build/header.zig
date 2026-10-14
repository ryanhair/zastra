//! Prints the C header for the App in the "app" module (`z.addCLib`).

const std = @import("std");
const z = @import("zastra");
const app = @import("app");
const options = @import("zastra_clib_options");

pub fn main(init: std.process.Init) !void {
    const text = comptime z.capi.header.render(app.App, options.name);
    try std.Io.File.stdout().writeStreamingAll(init.io, text);
}
