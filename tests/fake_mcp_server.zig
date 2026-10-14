//! A minimal MCP server over stdio for tests: tools `search_docs` and `add`,
//! paginated `tools/list`.

const std = @import("std");

pub fn main(init: std.process.Init) !void {
    const io = init.io;
    const a = init.arena.allocator();
    var in_buf: [64 * 1024]u8 = undefined;
    var out_buf: [64 * 1024]u8 = undefined;
    var in = std.Io.File.stdin().readerStreaming(io, &in_buf);
    var out = std.Io.File.stdout().writerStreaming(io, &out_buf);
    const w = &out.interface;
    while (true) {
        const line = in.interface.takeDelimiter('\n') catch return orelse return;
        const v = std.json.parseFromSliceLeaky(std.json.Value, a, line, .{}) catch continue;
        const method = v.object.get("method").?.string;
        const id = v.object.get("id") orelse continue; // notification
        if (std.mem.eql(u8, method, "initialize")) {
            try w.print("{{\"jsonrpc\":\"2.0\",\"id\":{d},\"result\":{{\"protocolVersion\":\"2025-06-18\",\"capabilities\":{{\"tools\":{{}}}},\"serverInfo\":{{\"name\":\"fake\",\"version\":\"1\"}}}}}}\n", .{id.integer});
        } else if (std.mem.eql(u8, method, "tools/list")) {
            const params = v.object.get("params").?;
            const page2 = params.object.get("cursor") != null;
            // A notification interleaved before the response.
            try w.writeAll("{\"jsonrpc\":\"2.0\",\"method\":\"notifications/message\",\"params\":{}}\n");
            if (!page2) {
                try w.print("{{\"jsonrpc\":\"2.0\",\"id\":{d},\"result\":{{\"tools\":[{{\"name\":\"search_docs\",\"description\":\"Search the docs.\",\"inputSchema\":{{\"type\":\"object\",\"properties\":{{\"query\":{{\"type\":\"string\",\"minLength\":2}}}},\"required\":[\"query\"]}}}}],\"nextCursor\":\"p2\"}}}}\n", .{id.integer});
            } else {
                try w.print("{{\"jsonrpc\":\"2.0\",\"id\":{d},\"result\":{{\"tools\":[{{\"name\":\"add\",\"description\":\"Add.\",\"inputSchema\":{{\"type\":\"object\",\"properties\":{{\"a\":{{\"type\":\"number\"}},\"b\":{{\"type\":\"number\"}}}},\"required\":[\"a\",\"b\"]}}}}]}}}}\n", .{id.integer});
            }
        } else if (std.mem.eql(u8, method, "tools/call")) {
            const params = v.object.get("params").?;
            const name = params.object.get("name").?.string;
            const args = params.object.get("arguments").?;
            if (std.mem.eql(u8, name, "search_docs")) {
                try w.print("{{\"jsonrpc\":\"2.0\",\"id\":{d},\"result\":{{\"content\":[{{\"type\":\"text\",\"text\":\"Refunds take 5 days. (query: {s})\"}}],\"isError\":false}}}}\n", .{ id.integer, args.object.get("query").?.string });
            } else {
                const x = args.object.get("a").?.integer + args.object.get("b").?.integer;
                try w.print("{{\"jsonrpc\":\"2.0\",\"id\":{d},\"result\":{{\"content\":[],\"structuredContent\":{{\"sum\":{d}}}}}}}\n", .{ id.integer, x });
            }
        } else {
            try w.print("{{\"jsonrpc\":\"2.0\",\"id\":{d},\"error\":{{\"code\":-32601,\"message\":\"no such method\"}}}}\n", .{id.integer});
        }
        try w.flush();
    }
}
