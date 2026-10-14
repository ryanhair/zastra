//! expect: agent 'a' uses MCP server 'dcos', but z.App(...) has no `.mcp.dcos` (did you mean 'docs'?)
const std = @import("std");
const z = @import("zastra");
const Ctx = struct { db: u32 = 0 };
const A = z.Agent(Ctx, .{ .name = "a", .model = "anthropic/claude-sonnet-5-5", .tools = .{z.mcp.tools(.dcos, .{})} });
const App = z.App(.{ .ctx = Ctx, .agents = .{A}, .mcp = .{ .docs = z.mcp.stdio(&.{"x"}) } });
comptime { _ = App.required_env; }
