//! Comptime Mermaid flowchart for a workflow (PLAN.md §5.7).

const std = @import("std");
const step = @import("step.zig");

pub fn render(comptime W: type) []const u8 {
    comptime {
        @setEvalBranchQuota(10_000_000);
        var out: []const u8 = "flowchart TD\n";
        out = out ++ "    start([" ++ W.id ++ "])\n";
        const r = nodes(W.nodes, "", &.{"start"});
        out = out ++ r.text;
        for (r.tails) |t| out = out ++ "    " ++ t ++ " --> finish([end])\n";
        return out;
    }
}

const R = struct { text: []const u8, tails: []const []const u8 };

fn nodeId(comptime path: []const u8) []const u8 {
    comptime {
        var out: [path.len]u8 = undefined;
        for (path, 0..) |c, i| out[i] = if (c == '.') '_' else c;
        const final = out;
        return &final;
    }
}

fn edges(comptime from: []const []const u8, comptime to: []const u8, comptime label: []const u8) []const u8 {
    comptime {
        var out: []const u8 = "";
        for (from) |f| out = out ++ "    " ++ f ++ " -->" ++ (if (label.len > 0) "|" ++ label ++ "|" else "") ++ " " ++ to ++ "\n";
        return out;
    }
}

fn nodes(comptime ns: anytype, comptime prefix: []const u8, comptime heads: []const []const u8) R {
    comptime {
        var text: []const u8 = "";
        var tails = heads;
        for (ns) |n| switch (n.kind) {
            .step => {
                const r = one(n.T, prefix, tails, "");
                text = text ++ r.text;
                tails = r.tails;
            },
            .branch => {
                const bid = nodeId((if (prefix.len > 0) prefix ++ "." else "") ++ std.fmt.comptimePrint("branch_{d}", .{n.index}));
                text = text ++ "    " ++ bid ++ "{branch}\n" ++ edges(tails, bid, "");
                var all_tails: []const []const u8 = &.{};
                for (n.arms, 0..) |arm, i| {
                    const label = if (arm.Pred == step.otherwise) "otherwise" else std.fmt.comptimePrint("arm {d}", .{i});
                    const r = one(arm.T, prefix, &.{bid}, label);
                    text = text ++ r.text;
                    all_tails = all_tails ++ r.tails;
                }
                tails = all_tails;
            },
        };
        return .{ .text = text, .tails = tails };
    }
}

fn one(comptime T: type, comptime prefix: []const u8, comptime from: []const []const u8, comptime label: []const u8) R {
    comptime {
        const path = (if (prefix.len > 0) prefix ++ "." else "") ++ step.idOf(T);
        const id = nodeId(path);
        if (step.isWorkflow(T)) {
            const sub_start = id ++ "_start";
            var text: []const u8 = "    subgraph " ++ id ++ "_sub [" ++ T.id ++ "]\n" ++ "    " ++ sub_start ++ "((" ++ T.id ++ "))\n";
            const r = nodes(T.nodes, path, &.{sub_start});
            text = text ++ r.text ++ "    end\n" ++ edges(from, sub_start, label);
            return .{ .text = text, .tails = r.tails };
        }
        if (step.isLoop(T)) {
            // The body inside a subgraph, with a dashed edge back to its start.
            const head = id ++ "_start";
            var text: []const u8 = "    subgraph " ++ id ++ "_sub [" ++ step.idOf(T) ++ "]\n" ++ "    " ++ head ++ "((loop))\n";
            const r = one(T.body, path, &.{head}, "");
            text = text ++ r.text ++ "    end\n" ++ edges(from, head, label);
            const back = std.fmt.comptimePrint("repeat, max {d}", .{T.max});
            for (r.tails) |tl| text = text ++ "    " ++ tl ++ " -.->|" ++ back ++ "| " ++ head ++ "\n";
            return .{ .text = text, .tails = r.tails };
        }
        if (step.isParallel(T)) {
            const fork = id ++ "_fork";
            var text: []const u8 = "    " ++ fork ++ "[/" ++ step.idOf(T) ++ "/]\n" ++ edges(from, fork, label);
            const join = id ++ "_join";
            text = text ++ "    " ++ join ++ "[\\join\\]\n";
            for (std.meta.fields(@TypeOf(T.steps))) |f| {
                const cid = id ++ "_" ++ f.name;
                text = text ++ "    " ++ cid ++ "[" ++ step.idOf(@field(T.steps, f.name)) ++ "]\n" ++
                    "    " ++ fork ++ " --> " ++ cid ++ "\n    " ++ cid ++ " --> " ++ join ++ "\n";
            }
            return .{ .text = text, .tails = &.{join} };
        }
        const shape = if (step.isSuspendable(T)) "[[" ++ step.idOf(T) ++ " ⏸]]" else "[" ++ step.idOf(T) ++ "]";
        return .{ .text = "    " ++ id ++ shape ++ "\n" ++ edges(from, id, label), .tails = &.{id} };
    }
}
