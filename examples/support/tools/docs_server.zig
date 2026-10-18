//! The example's docs MCP server: one tool, `search_docs`, over the FAQ.
//! Speaks MCP (JSON-RPC 2.0) over stdio.

const std = @import("std");
const faq = @embedFile("faq.json");

pub fn main(init: std.process.Init) !void {
    const io = init.io;
    const a = init.arena.allocator();
    var in_buf: [64 * 1024]u8 = undefined;
    var out_buf: [64 * 1024]u8 = undefined;
    var in = std.Io.File.stdin().readerStreaming(io, &in_buf);
    var out = std.Io.File.stdout().writerStreaming(io, &out_buf);
    const w = &out.interface;
    const Hit = struct { question: []const u8, answer: []const u8 };
    const hits = try std.json.parseFromSliceLeaky([]const Hit, a, faq, .{});

    while (in.interface.takeDelimiter('\n') catch null) |line| {
        const v = std.json.parseFromSliceLeaky(std.json.Value, a, line, .{}) catch continue;
        const id = v.object.get("id") orelse continue;
        const method = v.object.get("method").?.string;
        if (std.mem.eql(u8, method, "initialize")) {
            try w.print("{{\"jsonrpc\":\"2.0\",\"id\":{d},\"result\":{{\"protocolVersion\":\"2025-06-18\",\"capabilities\":{{\"tools\":{{}}}},\"serverInfo\":{{\"name\":\"acme-docs\",\"version\":\"1.0\"}}}}}}\n", .{id.integer});
        } else if (std.mem.eql(u8, method, "tools/list")) {
            try w.print("{{\"jsonrpc\":\"2.0\",\"id\":{d},\"result\":{{\"tools\":[{{\"name\":\"search_docs\",\"description\":\"Search Acme's help center (shipping, refunds, warranty).\",\"inputSchema\":{{\"type\":\"object\",\"properties\":{{\"query\":{{\"type\":\"string\",\"description\":\"What to search for\"}}}},\"required\":[\"query\"]}}}}]}}}}\n", .{id.integer});
        } else if (std.mem.eql(u8, method, "tools/call")) {
            const q = v.object.get("params").?.object.get("arguments").?.object.get("query").?.string;
            var text: std.Io.Writer.Allocating = .init(a);
            for (hits) |h| {
                var it = std.mem.tokenizeScalar(u8, q, ' ');
                while (it.next()) |word| {
                    if (word.len >= 4 and (std.ascii.findIgnoreCase(h.question, word) != null or std.ascii.findIgnoreCase(h.answer, word) != null)) {
                        try text.writer.print("Q: {s}\nA: {s}\n\n", .{ h.question, h.answer });
                        break;
                    }
                }
            }
            if (text.written().len == 0) try text.writer.writeAll("No matching articles.");
            try w.print("{{\"jsonrpc\":\"2.0\",\"id\":{d},\"result\":{{\"content\":[{{\"type\":\"text\",\"text\":{f}}}]}}}}\n", .{ id.integer, std.json.fmt(text.written(), .{}) });
        } else {
            try w.print("{{\"jsonrpc\":\"2.0\",\"id\":{d},\"error\":{{\"code\":-32601,\"message\":\"method not found\"}}}}\n", .{id.integer});
        }
        try w.flush();
    }
}
