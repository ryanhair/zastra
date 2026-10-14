//! Event payload types shared by every agent's generated `Event` union
//! (PLAN.md §6.4).

const std = @import("std");
const msg = @import("../message.zig");

pub const ToolResult = struct {
    id: []const u8,
    tool: []const u8,
    /// The result as sent to the model: the tool's Output as JSON, or the
    /// error message for `ModelErrors`, parse failures and denials.
    content: []const u8,
    is_error: bool,
    elapsed_ms: u64,

    pub fn name(r: ToolResult) []const u8 {
        return r.tool;
    }
};

pub fn ApprovalRequest(comptime Call: type) type {
    return struct {
        /// Pass to `stream.respond`.
        id: []const u8,
        call: Call,
    };
}

pub const StepFinish = struct {
    index: u32,
    reason: msg.FinishReason,
    usage: msg.Usage,
};

pub const Finish = struct {
    reason: msg.FinishReason,
    steps: u32,
    usage: msg.Usage,
};

/// A call to a runtime-typed MCP tool (§6.7).
pub const McpCall = struct {
    server: []const u8,
    tool: []const u8,
    args_json: []const u8,
};

pub const Decision = union(enum) {
    approve,
    deny: []const u8,
};
