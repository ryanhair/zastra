//! MCP declarations (PLAN.md §6.7): `z.mcp.stdio(argv)` for App servers and
//! `z.mcp.tools(.server, .{ .allow = ... })` inside an agent's `.tools`.

const std = @import("std");
const errors = @import("../meta/errors.zig");
const reflect = @import("../meta/reflect.zig");

pub const Transport = union(enum) {
    stdio: []const []const u8,
};

/// A stdio MCP server: zastra spawns `argv` at `App.init`.
pub fn stdio(comptime argv: []const []const u8) Transport {
    if (argv.len == 0) errors.fail("z.mcp.stdio(argv): argv must have at least the program name", .{});
    return .{ .stdio = argv };
}

/// The tools of one MCP server, as an entry in an agent's `.tools`.
pub fn tools(comptime server: @EnumLiteral(), comptime opts: anytype) type {
    reflect.checkConfigFields(@TypeOf(opts), &.{"allow"}, "z.mcp.tools(...) options");
    return struct {
        pub const zastra_mcp_tools = true;
        pub const server_name = @tagName(server);
        pub const allow: ?[]const []const u8 = if (@hasField(@TypeOf(opts), "allow")) opts.allow else null;
    };
}

pub fn isToolSet(comptime T: type) bool {
    return @TypeOf(T) == type and reflect.isContainer(T) and @hasDecl(T, "zastra_mcp_tools");
}
