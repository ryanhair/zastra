//! A minimal MCP server over stdio for tests.
//!
//! - no flag: a legacy (2025-06-18) server: `initialize`, tools `search_docs`
//!   and `add`, paginated `tools/list`; unknown methods get -32601.
//! - `--silent-probe`: legacy, and ignores requests it doesn't know (so the
//!   client's `server/discover` probe times out).
//! - `--modern`: a 2026-07-28 server: `server/discover`, `_meta` on every
//!   request, `resultType`, `subscriptions/listen`, and tools that exercise
//!   input-required results and list changes.

const std = @import("std");

pub fn main(init: std.process.Init) !void {
    const io = init.io;
    const a = init.arena.allocator();
    const args = try init.minimal.args.toSlice(a);
    const modern = args.len > 1 and std.mem.eql(u8, args[1], "--modern");
    const silent = args.len > 1 and std.mem.eql(u8, args[1], "--silent-probe");
    var in_buf: [64 * 1024]u8 = undefined;
    var out_buf: [64 * 1024]u8 = undefined;
    var in = std.Io.File.stdin().readerStreaming(io, &in_buf);
    var out = std.Io.File.stdout().writerStreaming(io, &out_buf);
    const w = &out.interface;
    var listen_id: ?i64 = null;
    var grown = false;
    while (true) {
        const line = in.interface.takeDelimiter('\n') catch return orelse return;
        const v = std.json.parseFromSliceLeaky(std.json.Value, a, line, .{}) catch continue;
        const method = v.object.get("method").?.string;
        const id = v.object.get("id") orelse continue; // notification
        const params = v.object.get("params") orelse .null;
        if (modern) {
            const version = blk: {
                if (params != .object) break :blk "";
                const meta = params.object.get("_meta") orelse break :blk "";
                const pv = meta.object.get("io.modelcontextprotocol/protocolVersion") orelse break :blk "";
                break :blk pv.string;
            };
            if (!std.mem.eql(u8, version, "2026-07-28")) {
                try w.print("{{\"jsonrpc\":\"2.0\",\"id\":{d},\"error\":{{\"code\":-32022,\"message\":\"Unsupported protocol version\",\"data\":{{\"supported\":[\"2026-07-28\"],\"requested\":\"{s}\"}}}}}}\n", .{ id.integer, version });
            } else if (std.mem.eql(u8, method, "server/discover")) {
                try w.print("{{\"jsonrpc\":\"2.0\",\"id\":{d},\"result\":{{\"resultType\":\"complete\",\"supportedVersions\":[\"2026-07-28\"],\"capabilities\":{{\"tools\":{{\"listChanged\":true}}}}}}}}\n", .{id.integer});
            } else if (std.mem.eql(u8, method, "subscriptions/listen")) {
                listen_id = id.integer;
                try w.print("{{\"jsonrpc\":\"2.0\",\"method\":\"notifications/subscriptions/acknowledged\",\"params\":{{\"_meta\":{{\"io.modelcontextprotocol/subscriptionId\":{d}}},\"notifications\":{{\"toolsListChanged\":true}}}}}}\n", .{id.integer});
            } else if (std.mem.eql(u8, method, "tools/list")) {
                // Deliberately unsorted: the client sorts.
                try w.print("{{\"jsonrpc\":\"2.0\",\"id\":{d},\"result\":{{\"resultType\":\"complete\",\"tools\":[" ++
                    "{{\"name\":\"search_docs\",\"description\":\"Search the docs.\",\"inputSchema\":{{\"type\":\"object\",\"properties\":{{\"query\":{{\"type\":\"string\"}}}},\"required\":[\"query\"]}}}}," ++
                    "{{\"name\":\"ask\",\"description\":\"Needs elicitation.\",\"inputSchema\":{{\"type\":\"object\"}}}}," ++
                    "{{\"name\":\"grow\",\"description\":\"Adds a tool.\",\"inputSchema\":{{\"type\":\"object\"}}}}," ++
                    "{{\"name\":\"stateful\",\"description\":\"Needs one retry.\",\"inputSchema\":{{\"type\":\"object\"}}}}{s}]}}}}\n", .{
                    id.integer,
                    if (grown) ",{\"name\":\"grown\",\"description\":\"Added later.\",\"inputSchema\":{\"type\":\"object\"}}" else "",
                });
            } else if (std.mem.eql(u8, method, "tools/call")) {
                const name = params.object.get("name").?.string;
                if (std.mem.eql(u8, name, "search_docs")) {
                    const q = params.object.get("arguments").?.object.get("query").?.string;
                    try w.print("{{\"jsonrpc\":\"2.0\",\"id\":{d},\"result\":{{\"resultType\":\"complete\",\"content\":[{{\"type\":\"text\",\"text\":\"Refunds take 5 days. (query: {s})\"}}]}}}}\n", .{ id.integer, q });
                } else if (std.mem.eql(u8, name, "ask")) {
                    try w.print("{{\"jsonrpc\":\"2.0\",\"id\":{d},\"result\":{{\"resultType\":\"input_required\",\"inputRequests\":{{\"who\":{{\"method\":\"elicitation/create\",\"params\":{{\"mode\":\"form\",\"message\":\"Name?\",\"requestedSchema\":{{\"type\":\"object\"}}}}}}}}}}}}\n", .{id.integer});
                } else if (std.mem.eql(u8, name, "stateful")) {
                    const st = params.object.get("requestState");
                    if (st != null and std.mem.eql(u8, st.?.string, "s1")) {
                        try w.print("{{\"jsonrpc\":\"2.0\",\"id\":{d},\"result\":{{\"resultType\":\"complete\",\"content\":[{{\"type\":\"text\",\"text\":\"done after a retry\"}}]}}}}\n", .{id.integer});
                    } else {
                        try w.print("{{\"jsonrpc\":\"2.0\",\"id\":{d},\"result\":{{\"resultType\":\"input_required\",\"requestState\":\"s1\"}}}}\n", .{id.integer});
                    }
                } else if (std.mem.eql(u8, name, "grow")) {
                    grown = true;
                    if (listen_id) |lid| try w.print("{{\"jsonrpc\":\"2.0\",\"method\":\"notifications/tools/list_changed\",\"params\":{{\"_meta\":{{\"io.modelcontextprotocol/subscriptionId\":{d}}}}}}}\n", .{lid});
                    try w.print("{{\"jsonrpc\":\"2.0\",\"id\":{d},\"result\":{{\"resultType\":\"complete\",\"content\":[{{\"type\":\"text\",\"text\":\"grown\"}}]}}}}\n", .{id.integer});
                } else {
                    try w.print("{{\"jsonrpc\":\"2.0\",\"id\":{d},\"error\":{{\"code\":-32602,\"message\":\"Unknown tool\"}}}}\n", .{id.integer});
                }
            } else {
                try w.print("{{\"jsonrpc\":\"2.0\",\"id\":{d},\"error\":{{\"code\":-32601,\"message\":\"no such method\"}}}}\n", .{id.integer});
            }
            try w.flush();
            continue;
        }

        if (std.mem.eql(u8, method, "initialize")) {
            try w.print("{{\"jsonrpc\":\"2.0\",\"id\":{d},\"result\":{{\"protocolVersion\":\"2025-06-18\",\"capabilities\":{{\"tools\":{{}}}},\"serverInfo\":{{\"name\":\"fake\",\"version\":\"1\"}}}}}}\n", .{id.integer});
        } else if (std.mem.eql(u8, method, "tools/list")) {
            const page2 = params.object.get("cursor") != null;
            // A notification interleaved before the response.
            try w.writeAll("{\"jsonrpc\":\"2.0\",\"method\":\"notifications/message\",\"params\":{}}\n");
            if (!page2) {
                try w.print("{{\"jsonrpc\":\"2.0\",\"id\":{d},\"result\":{{\"tools\":[{{\"name\":\"search_docs\",\"description\":\"Search the docs.\",\"inputSchema\":{{\"type\":\"object\",\"properties\":{{\"query\":{{\"type\":\"string\",\"minLength\":2}}}},\"required\":[\"query\"]}}}}],\"nextCursor\":\"p2\"}}}}\n", .{id.integer});
            } else {
                try w.print("{{\"jsonrpc\":\"2.0\",\"id\":{d},\"result\":{{\"tools\":[{{\"name\":\"add\",\"description\":\"Add.\",\"inputSchema\":{{\"type\":\"object\",\"properties\":{{\"a\":{{\"type\":\"number\"}},\"b\":{{\"type\":\"number\"}}}},\"required\":[\"a\",\"b\"]}}}}]}}}}\n", .{id.integer});
            }
        } else if (std.mem.eql(u8, method, "tools/call")) {
            const name = params.object.get("name").?.string;
            const targs = params.object.get("arguments").?;
            if (std.mem.eql(u8, name, "search_docs")) {
                try w.print("{{\"jsonrpc\":\"2.0\",\"id\":{d},\"result\":{{\"content\":[{{\"type\":\"text\",\"text\":\"Refunds take 5 days. (query: {s})\"}}],\"isError\":false}}}}\n", .{ id.integer, targs.object.get("query").?.string });
            } else {
                const x = targs.object.get("a").?.integer + targs.object.get("b").?.integer;
                try w.print("{{\"jsonrpc\":\"2.0\",\"id\":{d},\"result\":{{\"content\":[],\"structuredContent\":{{\"sum\":{d}}}}}}}\n", .{ id.integer, x });
            }
        } else if (silent) {
            continue; // a legacy server that ignores what it doesn't know
        } else {
            try w.print("{{\"jsonrpc\":\"2.0\",\"id\":{d},\"error\":{{\"code\":-32601,\"message\":\"no such method\"}}}}\n", .{id.integer});
        }
        try w.flush();
    }
}
