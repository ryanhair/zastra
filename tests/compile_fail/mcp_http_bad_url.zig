//! expect: zastra: z.mcp.http("mcp.linear.app/mcp", ...): the URL must start with https:// (or http:// for a local server)
const z = @import("zastra");
comptime { _ = z.mcp.http("mcp.linear.app/mcp", .{}); }
