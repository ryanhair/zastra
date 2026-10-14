//! expect: recursive schema types aren't supported yet. Use `z.Json`
const z = @import("zastra");
const Node = struct { children: []const Node };
comptime {
    _ = z.schema.of(Node);
}
