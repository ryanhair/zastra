//! MCP declarations (PLAN.md §6.7, §17.5): `z.mcp.stdio(argv)` and
//! `z.mcp.http(url, opts)` for App servers, and
//! `z.mcp.tools(.server, .{ .allow = ... })` inside an agent's `.tools`.

const std = @import("std");
const errors = @import("../meta/errors.zig");
const reflect = @import("../meta/reflect.zig");

pub const Transport = union(enum) {
    stdio: []const []const u8,
    http: @import("streamable.zig").Decl,
};

/// A stdio MCP server: zastra spawns `argv` at `App.init`.
pub fn stdio(comptime argv: []const []const u8) Transport {
    if (argv.len == 0) errors.fail("z.mcp.stdio(argv): argv must have at least the program name", .{});
    return .{ .stdio = argv };
}

/// A Streamable HTTP MCP server (2026-07-28, or 2025-11-25 sessions):
///
///     .linear = z.mcp.http("https://mcp.linear.app/mcp", .{
///         .bearer_env = "LINEAR_MCP_TOKEN", // Authorization: Bearer <value>, checked at App.init
///         .headers = &.{.{ "X-Team", "acme" }},
///         .url_env = "LINEAR_MCP_URL", // optional: overrides the URL when set
///         .optional = true, // optional: start without its tools if it's unreachable
///     }),
///
/// OAuth isn't supported yet (PLAN.md D38): pass a token you obtained.
pub fn http(comptime url: []const u8, comptime opts: anytype) Transport {
    comptime {
        reflect.checkConfigFields(@TypeOf(opts), &.{ "bearer_env", "headers", "url_env", "optional" }, "z.mcp.http(...) options");
        if (!std.mem.startsWith(u8, url, "https://") and !std.mem.startsWith(u8, url, "http://"))
            errors.fail("z.mcp.http(\"{s}\", ...): the URL must start with https:// (or http:// for a local server)", .{url});
        return .{ .http = .{
            .url = url,
            .bearer_env = if (@hasField(@TypeOf(opts), "bearer_env")) opts.bearer_env else null,
            .url_env = if (@hasField(@TypeOf(opts), "url_env")) opts.url_env else null,
            .optional = if (@hasField(@TypeOf(opts), "optional")) opts.optional else false,
            .headers = if (@hasField(@TypeOf(opts), "headers")) opts.headers else &.{},
        } };
    }
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
