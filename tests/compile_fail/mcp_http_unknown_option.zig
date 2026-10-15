//! expect: zastra: z.mcp.http(...) options has unknown option `.bearer`; valid options are 'bearer_env', 'headers', 'url_env', 'optional'
const z = @import("zastra");
comptime { _ = z.mcp.http("https://mcp.example.com/mcp", .{ .bearer = "TOKEN" }); }
