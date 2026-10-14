//! Shared runtime state behind `App.init` (PLAN.md §4.2). Agent and workflow
//! code is generic over the agent/workflow type and reaches the App's
//! long-lived resources through this struct.

const std = @import("std");
const Http = @import("provider/http.zig").Http;
const provider = @import("provider/provider.zig");
const trace = @import("trace/trace.zig");
const Storage = @import("storage/storage.zig").Storage;
const catalog = @import("catalog/catalog.zig");
const Allocator = std.mem.Allocator;
const Io = std.Io;

pub const State = struct {
    gpa: Allocator,
    io: Io,
    http: Http,
    env: ?*const std.process.Environ.Map,
    /// The App's `*Ctx`, type-erased.
    ctx: *anyopaque,
    tracer: trace.Tracer,
    storage: ?Storage = null,
    /// MCP client manager (§6.7), when the App declares servers.
    mcp: ?*anyopaque = null,
    mcp_vtable: ?*const McpVTable = null,
    /// Prefixes completed at init with runtime-discovered (MCP) tools, keyed
    /// by agent id.
    prefixes: std.StringHashMapUnmanaged(provider.Prefix) = .empty,
    /// Overrides the wall clock (test harness).
    clock_ms: ?*const fn () i64 = null,
    diag_mutex: Io.Mutex = .init,
    diag: provider.Diagnostic = .{},
    /// Requests carry `x-zastra-agent` so the test harness can route
    /// scripted responses; never set outside tests.
    tag_requests: bool = false,

    pub fn apiKey(s: *const State, spec: catalog.Spec) ?[]const u8 {
        const name = spec.api_key_env orelse return null;
        const env = s.env orelse return null;
        return env.get(name);
    }

    pub fn baseUrl(s: *const State, spec: catalog.Spec) []const u8 {
        return provider.baseUrl(spec, s.env);
    }

    pub fn setDiag(s: *State, d: *const provider.Diagnostic) void {
        s.diag_mutex.lockUncancelable(s.io);
        defer s.diag_mutex.unlock(s.io);
        s.diag = d.*;
    }

    pub fn diagPrint(s: *State, comptime fmt: []const u8, args: anytype) void {
        s.diag_mutex.lockUncancelable(s.io);
        defer s.diag_mutex.unlock(s.io);
        s.diag.print(0, fmt, args);
    }

    pub fn nowMs(s: *const State) i64 {
        if (s.clock_ms) |f| return f();
        return @intCast(@divFloor(Io.Clock.real.now(s.io).nanoseconds, std.time.ns_per_ms));
    }

    /// Like `newId`, into a caller buffer (at least prefix.len + 17 bytes).
    pub fn newIdInto(s: *const State, buf: []u8, comptime prefix: []const u8) ![]const u8 {
        var raw: [8]u8 = undefined;
        s.io.random(&raw);
        return std.fmt.bufPrint(buf, prefix ++ "_{x:0>16}", .{std.mem.readInt(u64, &raw, .little)});
    }

    /// A random id like "run_3f9a0c1d2e4b5a69".
    pub fn newId(s: *const State, arena: Allocator, comptime prefix: []const u8) Allocator.Error![]const u8 {
        var raw: [8]u8 = undefined;
        s.io.random(&raw);
        return std.fmt.allocPrint(arena, prefix ++ "_{x:0>16}", .{std.mem.readInt(u64, &raw, .little)});
    }
};

/// What agents need from the MCP manager, type-erased.
pub const McpVTable = struct {
    /// Tool definitions for `server` filtered by `allow`, as provider JSON.
    call: *const fn (ptr: *anyopaque, arena: Allocator, server: []const u8, tool: []const u8, args_json: []const u8) anyerror!McpResult,
};

pub const McpResult = struct { content: []const u8, is_error: bool };
