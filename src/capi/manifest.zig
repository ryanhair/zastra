//! The App manifest (PLAN.md §5.16): a comptime JSON description of an App's
//! agents, tools, schemas, workflows, fingerprints and required environment.
//! It feeds the C header generator and the dev CLI.

const std = @import("std");
const json_schema = @import("../schema/json_schema.zig");
const str = json_schema.str;
const step = @import("../workflow/step.zig");

pub fn json(comptime App: type) []const u8 {
    comptime {
        @setEvalBranchQuota(50_000_000);
        var s: []const u8 = "{\"agents\":[";
        for (App.agents, 0..) |A, i| s = s ++ (if (i == 0) "" else ",") ++ agentJson(A);
        s = s ++ "],\"workflows\":[";
        for (App.workflows, 0..) |W, i| s = s ++ (if (i == 0) "" else ",") ++ workflowJson(W);
        s = s ++ "],\"env\":[";
        for (App.required_env, 0..) |e, i| s = s ++ (if (i == 0) "" else ",") ++ str(e);
        s = s ++ "]}";
        return s;
    }
}

/// One agent: id, model, prefix hash, tools (schemas, approval, effects),
/// MCP servers and output schema.
pub fn agentJson(comptime A: type) []const u8 {
    comptime {
        @setEvalBranchQuota(50_000_000);
        var s: []const u8 = "{\"id\":" ++ str(A.id) ++ ",\"model\":" ++ str(A.model.fullName()) ++
            std.fmt.comptimePrint(",\"prefix_hash\":\"0x{x:0>16}\"", .{A.prefix_hash}) ++ ",\"tools\":[";
        for (A.tools, 0..) |TI, j| {
            var effects: []const u8 = "";
            for (std.enums.values(@TypeOf(TI.effect_set).Key)) |e| if (TI.effect_set.contains(e)) {
                effects = effects ++ (if (effects.len == 0) "" else ",") ++ str(@tagName(e));
            };
            s = s ++ (if (j == 0) "" else ",") ++ "{\"name\":" ++ str(TI.name) ++ ",\"description\":" ++ str(TI.description) ++
                ",\"approval\":" ++ str(@tagName(TI.approval_kind)) ++ ",\"effects\":[" ++ effects ++ "]" ++
                ",\"input_schema\":" ++ json_schema.of(TI.Input) ++ ",\"output_schema\":" ++ json_schema.of(TI.Output) ++ "}";
        }
        s = s ++ "],\"mcp_servers\":[";
        for (A.mcp_tools, 0..) |set, j| s = s ++ (if (j == 0) "" else ",") ++ str(set.server_name);
        s = s ++ "]";
        if (A.has_output_type) s = s ++ ",\"output_schema\":" ++ json_schema.of(A.Output);
        if (A.partial_output) s = s ++ ",\"partial_output\":true";
        return s ++ "}";
    }
}

/// One workflow: id, fingerprint, schemas and suspendable steps.
pub fn workflowJson(comptime W: type) []const u8 {
    comptime {
        @setEvalBranchQuota(50_000_000);
        var s: []const u8 = "{\"id\":" ++ str(W.id) ++
            std.fmt.comptimePrint(",\"fingerprint\":\"0x{x:0>16}\"", .{W.fingerprint_value}) ++
            ",\"input_schema\":" ++ json_schema.of(W.Input) ++ ",\"output_schema\":" ++ json_schema.of(W.Output) ++ ",\"suspendable\":[";
        for (W.suspendable_steps, 0..) |S, j| {
            s = s ++ (if (j == 0) "" else ",") ++ "{\"step\":" ++ str(step.idOf(S)) ++ ",\"suspend_schema\":" ++ json_schema.of(S.Suspend) ++
                ",\"resume_schema\":" ++ json_schema.of(S.Resume) ++ "}";
        }
        return s ++ "]}";
    }
}

pub fn fingerprint(comptime App: type) u64 {
    return comptime fingerprintImpl(App);
}

fn fingerprintImpl(comptime App: type) u64 {
    @setEvalBranchQuota(50_000_000);
    return std.hash.Wyhash.hash(0, json(App));
}
