test {
    _ = @import("provider_test.zig");
    _ = @import("agent_test.zig");
    _ = @import("model_test.zig");
    _ = @import("partial_output_test.zig");
    _ = @import("approval_test.zig");
    _ = @import("memory_migration_test.zig");
    _ = @import("mcp_test.zig");
    _ = @import("workflow_test.zig");
    _ = @import("workflow_approval_test.zig");
    _ = @import("workflow_loop_test.zig");
    _ = @import("otlp_test.zig");
    _ = @import("arbitrary_test.zig");
    _ = @import("fuzz_tool_test.zig");
    _ = @import("dev_serve_test.zig");
}
