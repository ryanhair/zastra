//! zastra: a Mastra-style agent framework for Zig.
//!
//! Conventionally imported as `const z = @import("zastra");`. This file only
//! re-exports; see PLAN.md §3.1 for the public surface.

const std = @import("std");

pub const schema = struct {
    const json_schema = @import("schema/json_schema.zig");
    const parse_mod = @import("schema/parse.zig");
    pub const Dialect = json_schema.Dialect;
    pub const of = json_schema.of;
    pub const render = json_schema.render;
    pub const parse = parse_mod.parse;
    pub const fromValue = parse_mod.fromValue;
    pub const Issue = parse_mod.Issue;
    pub const stringifyAlloc = @import("schema/json.zig").stringifyAlloc;
    pub const write = @import("schema/json.zig").write;
};

pub const Json = @import("schema/json.zig").Json;

pub const fmt = struct {
    pub const json = @import("schema/json.zig").fmt;
};

/// Internal: comptime reflection and error helpers (stable for zastra's own
/// build helpers, not part of the public API).
pub const meta = struct {
    pub const errors = @import("meta/errors.zig");
    pub const reflect = @import("meta/reflect.zig");
    pub const fingerprint = @import("meta/fingerprint.zig");
};

test {
    std.testing.refAllDecls(@This());
    _ = @import("meta/errors.zig");
    _ = @import("meta/reflect.zig");
    _ = @import("meta/fingerprint.zig");
    _ = @import("schema/json_schema.zig");
    _ = @import("schema/json.zig");
    _ = @import("schema/parse.zig");
    _ = @import("schema/parse_test.zig");
}
