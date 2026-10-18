//! Zig type → JSON Schema, at comptime (PLAN.md §5.1–5.3).
//!
//! `of(T)` renders the canonical schema. `render(T, dialect)` lowers it for a
//! provider: Anthropic uses `anyOf` for unions; OpenAI strict mode makes every
//! property required, turns optionals into `anyOf [T, null]` and drops
//! `default`.

const std = @import("std");
const errors = @import("../meta/errors.zig");
const reflect = @import("../meta/reflect.zig");
const Json = @import("json.zig").Json;

pub const Dialect = enum {
    /// The full schema, with every constraint (golden files, docs, the C header).
    canonical,
    /// Anthropic tool `input_schema`: full schema, `anyOf` for unions.
    anthropic,
    /// Anthropic structured output (`output_config.format`): constrained
    /// decoding doesn't accept numeric/string/array constraints, so they're
    /// dropped and enforced client-side by `parse`.
    anthropic_output,
    /// OpenAI strict mode (tools and `response_format`): every property
    /// required, optionals as `anyOf [T, null]`, constraints and `default`
    /// dropped (enforced client-side).
    openai,

    fn strict(d: Dialect) bool {
        return d == .openai or d == .anthropic_output;
    }
};

pub fn of(comptime T: type) []const u8 {
    return render(T, .canonical);
}

pub fn render(comptime T: type, comptime d: Dialect) []const u8 {
    comptime {
        @setEvalBranchQuota(10_000_000);
        return node(T, d, .{}, &.{}, reflect.shortTypeName(T));
    }
}

/// Per-position metadata that comes from the containing struct's decls.
const Meta = struct {
    description: ?[]const u8 = null,
    constraints: ?type = null, // the type of the constraints literal for this field
    constraints_holder: ?type = null, // struct whose `constraints` decl holds them
    field: []const u8 = "",
    default_json: ?[]const u8 = null,
};

/// Quote and escape a comptime string as a JSON string literal.
pub fn str(comptime s: []const u8) []const u8 {
    comptime {
        var out: []const u8 = "\"";
        for (s) |c| {
            out = out ++ switch (c) {
                '"' => "\\\"",
                '\\' => "\\\\",
                '\n' => "\\n",
                '\r' => "\\r",
                '\t' => "\\t",
                0...8, 11, 12, 14...0x1f => std.fmt.comptimePrint("\\u{x:0>4}", .{c}),
                else => &[_]u8{c},
            };
        }
        return out ++ "\"";
    }
}

fn num(comptime v: anytype) []const u8 {
    return std.fmt.comptimePrint("{d}", .{v});
}

fn inStack(comptime stack: []const type, comptime T: type) bool {
    for (stack) |S| if (S == T) return true;
    return false;
}

/// Path used in error messages, e.g. "Triage.urgency".
fn where(comptime path: []const u8) []const u8 {
    return path;
}

/// Does `T` contain `z.Json` anywhere? (OpenAI strict mode can't express it.)
pub fn containsJson(comptime T: type) bool {
    return comptime containsJsonImpl(T, &.{});
}

fn containsJsonImpl(comptime T: type, comptime stack: []const type) bool {
    if (T == Json) return true;
    for (stack) |S| if (S == T) return false;
    const next = stack ++ &[_]type{T};
    return switch (@typeInfo(T)) {
        .optional => |o| containsJsonImpl(o.child, next),
        .pointer => |p| containsJsonImpl(p.child, next),
        .array => |a| containsJsonImpl(a.child, next),
        .@"struct" => |s| for (s.field_types) |FT| {
            if (containsJsonImpl(FT, next)) break true;
        } else false,
        .@"union" => |u| for (u.field_types) |FT| {
            if (containsJsonImpl(FT, next)) break true;
        } else false,
        else => false,
    };
}

pub fn isStringType(comptime T: type) bool {
    return switch (@typeInfo(T)) {
        .pointer => |p| p.size == .slice and p.child == u8,
        else => false,
    };
}

fn node(comptime T: type, comptime d: Dialect, comptime meta: Meta, comptime stack: []const type, comptime path: []const u8) []const u8 {
    comptime {
        const desc = if (meta.description) |s| ",\"description\":" ++ str(s) else "";
        const default = if (!d.strict()) (if (meta.default_json) |j| ",\"default\":" ++ j else "") else "";
        const tail = desc ++ default;

        if (T == Json) return "{" ++ (if (tail.len > 0) tail[1..] else "") ++ "}";

        switch (@typeInfo(T)) {
            .bool => {
                checkConstraints(T, meta, &.{}, path);
                return "{\"type\":\"boolean\"" ++ tail ++ "}";
            },
            .int => |info| {
                checkConstraints(T, meta, &.{ "min", "max" }, path);
                const lo = if (constraint(meta, "min")) |v| v else std.math.minInt(T);
                const hi = if (constraint(meta, "max")) |v| v else std.math.maxInt(T);
                if (info.bits > 64) errors.fail("'{s}' is a {s}; integers wider than 64 bits can't be represented in JSON Schema", .{ path, @typeName(T) });
                if (d.strict()) return "{\"type\":\"integer\"" ++ tail ++ "}";
                return "{\"type\":\"integer\",\"minimum\":" ++ num(lo) ++ ",\"maximum\":" ++ num(hi) ++ tail ++ "}";
            },
            .float => {
                checkConstraints(T, meta, &.{ "min", "max" }, path);
                const lo = if (d.strict()) "" else if (constraint(meta, "min")) |v| ",\"minimum\":" ++ num(v) else "";
                const hi = if (d.strict()) "" else if (constraint(meta, "max")) |v| ",\"maximum\":" ++ num(v) else "";
                return "{\"type\":\"number\"" ++ lo ++ hi ++ tail ++ "}";
            },
            .@"enum" => |info| {
                checkConstraints(T, meta, &.{}, path);
                var tags: []const u8 = "";
                for (info.field_names, 0..) |name, i| tags = tags ++ (if (i == 0) "" else ",") ++ str(name);
                return "{\"type\":\"string\",\"enum\":[" ++ tags ++ "]" ++ tail ++ "}";
            },
            .optional => |info| {
                // Optionals outside a struct field position: T or null.
                const inner = node(info.child, d, .{ .constraints = meta.constraints, .constraints_holder = meta.constraints_holder, .field = meta.field }, stack, path);
                return "{\"anyOf\":[" ++ inner ++ ",{\"type\":\"null\"}]" ++ tail ++ "}";
            },
            .pointer => |p| {
                if (p.size == .slice and p.child == u8) {
                    checkConstraints(T, meta, &.{ "min_len", "max_len", "pattern", "one_of" }, path);
                    var extra: []const u8 = "";
                    if (!d.strict()) {
                        if (constraint(meta, "min_len")) |v| extra = extra ++ ",\"minLength\":" ++ num(v);
                        if (constraint(meta, "max_len")) |v| extra = extra ++ ",\"maxLength\":" ++ num(v);
                        if (constraint(meta, "pattern")) |v| extra = extra ++ ",\"pattern\":" ++ str(v);
                    }
                    if (constraint(meta, "one_of")) |v| {
                        var vals: []const u8 = "";
                        for (0..v.len) |i| vals = vals ++ (if (i == 0) "" else ",") ++ str(v[i]);
                        extra = extra ++ ",\"enum\":[" ++ vals ++ "]";
                    }
                    return "{\"type\":\"string\"" ++ extra ++ tail ++ "}";
                }
                if (p.size == .slice) {
                    checkConstraints(T, meta, &.{ "min_items", "max_items" }, path);
                    var extra: []const u8 = "";
                    if (!d.strict()) {
                        if (constraint(meta, "min_items")) |v| extra = extra ++ ",\"minItems\":" ++ num(v);
                        if (constraint(meta, "max_items")) |v| extra = extra ++ ",\"maxItems\":" ++ num(v);
                    }
                    return "{\"type\":\"array\",\"items\":" ++ node(p.child, d, .{}, stack, path ++ "[]") ++ extra ++ tail ++ "}";
                }
                if (@typeInfo(p.child) == .@"fn") errors.fail("'{s}' is a function pointer; schema types describe data, not behavior", .{path});
                errors.fail("'{s}' has pointer type {s}; schema types can use slices (`[]const T`) but not other pointers", .{ path, @typeName(T) });
            },
            .array => |a| {
                checkConstraints(T, meta, &.{}, path);
                const bounds = if (d.strict()) "" else ",\"minItems\":" ++ num(a.len) ++ ",\"maxItems\":" ++ num(a.len);
                return "{\"type\":\"array\",\"items\":" ++ node(a.child, d, .{}, stack, path ++ "[]") ++ bounds ++ tail ++ "}";
            },
            .@"struct" => |s| {
                if (s.is_tuple) errors.fail("'{s}' is a tuple; schema types must be structs with named fields", .{path});
                if (inStack(stack, T)) errors.fail("'{s}' is recursive ({s}); recursive schema types aren't supported yet. Use `z.Json` for the recursive part", .{ path, @typeName(T) });
                checkConstraints(T, meta, &.{}, path);
                const obj_desc = if (meta.description == null and reflect.hasDecl(T, "description") and reflect.isString(@TypeOf(T.description)))
                    ",\"description\":" ++ str(T.description)
                else
                    "";
                const body = objectBody(T, d, stack ++ &[_]type{T}, path, "", "");
                return "{\"type\":\"object\"," ++ body ++ obj_desc ++ tail ++ "}";
            },
            .@"union" => |u| {
                if (u.tag_type == null) errors.fail("'{s}' is an untagged union; use `union(enum)` so the variant can be identified", .{path});
                if (inStack(stack, T)) errors.fail("'{s}' is recursive ({s}); recursive schema types aren't supported yet. Use `z.Json` for the recursive part", .{ path, @typeName(T) });
                checkConstraints(T, meta, &.{}, path);
                const kw = if (d == .canonical) "oneOf" else "anyOf";
                var arms: []const u8 = "";
                for (reflect.fields(T), 0..) |f, i| {
                    const tag_prop = "\"type\":{\"type\":\"string\",\"enum\":[" ++ str(f.name) ++ "]}";
                    const arm_path = path ++ "." ++ f.name;
                    const arm = switch (@typeInfo(f.type)) {
                        .void => "{\"type\":\"object\",\"properties\":{" ++ tag_prop ++ "},\"required\":[\"type\"],\"additionalProperties\":false}",
                        .@"struct" => |ps| blk: {
                            if (ps.is_tuple) errors.fail("'{s}' payload is a tuple; use a struct with named fields", .{arm_path});
                            for (ps.field_names) |pname| if (std.mem.eql(u8, pname, "type"))
                                errors.fail("'{s}' payload has a field named `type`, which collides with the union discriminator; rename the field", .{arm_path});
                            break :blk "{\"type\":\"object\"," ++ objectBody(f.type, d, stack ++ &[_]type{ T, f.type }, arm_path, tag_prop, "\"type\"") ++ "}";
                        },
                        else => "{\"type\":\"object\",\"properties\":{" ++ tag_prop ++ ",\"value\":" ++
                            node(f.type, d, .{}, stack ++ &[_]type{T}, arm_path) ++
                            "},\"required\":[\"type\",\"value\"],\"additionalProperties\":false}",
                    };
                    arms = arms ++ (if (i == 0) "" else ",") ++ arm;
                }
                return "{\"" ++ kw ++ "\":[" ++ arms ++ "]" ++ tail ++ "}";
            },
            .error_union => errors.fail("'{s}' is an error union ({s}); schema types describe data, so use a plain type", .{ path, @typeName(T) }),
            .@"fn" => errors.fail("'{s}' is a function type; schema types describe data", .{path}),
            .@"opaque" => errors.fail("'{s}' is opaque ({s}); schema types must be fully known. Use `z.Json` for untyped data", .{ path, @typeName(T) }),
            else => errors.fail("'{s}' has type {s}, which has no JSON Schema mapping. Use bool, integers, floats, []const u8, enums, structs, union(enum), slices, arrays, optionals or z.Json", .{ path, @typeName(T) }),
        }
    }
}

/// `"properties":{...},"required":[...],"additionalProperties":false`
fn objectBody(
    comptime S: type,
    comptime d: Dialect,
    comptime stack: []const type,
    comptime path: []const u8,
    comptime leading_prop: []const u8,
    comptime leading_req: []const u8,
) []const u8 {
    comptime {
        const fields = reflect.fields(S);
        const names = reflect.fieldNames(S);
        validateFieldDecl(S, "docs", names, path);
        validateFieldDecl(S, "constraints", names, path);

        var props: []const u8 = leading_prop;
        var req: []const u8 = leading_req;
        for (fields) |f| {
            const fpath = path ++ "." ++ f.name;
            const description: ?[]const u8 = if (reflect.hasDecl(S, "docs") and @hasField(@TypeOf(S.docs), f.name)) @field(S.docs, f.name) else null;
            const ctype: ?type = if (reflect.hasDecl(S, "constraints") and @hasField(@TypeOf(S.constraints), f.name)) @TypeOf(@field(S.constraints, f.name)) else null;
            const is_opt = @typeInfo(f.type) == .optional;
            const has_default = f.default_value_ptr != null;
            const meta: Meta = .{
                .description = description,
                .constraints = ctype,
                .constraints_holder = if (ctype != null) S else null,
                .field = f.name,
                .default_json = if (has_default and !is_opt) defaultJson(f) else null,
            };
            const schema = if (is_opt and d != .openai)
                node(@typeInfo(f.type).optional.child, d, meta, stack, fpath)
            else
                node(f.type, d, meta, stack, fpath);
            props = props ++ (if (props.len == 0) "" else ",") ++ str(f.name) ++ ":" ++ schema;
            const required = d == .openai or (!is_opt and !has_default);
            if (required) req = req ++ (if (req.len == 0) "" else ",") ++ str(f.name);
        }
        return "\"properties\":{" ++ props ++ "},\"required\":[" ++ req ++ "],\"additionalProperties\":false";
    }
}

/// `docs` / `constraints` keys must name real fields.
fn validateFieldDecl(comptime S: type, comptime decl: []const u8, comptime names: []const []const u8, comptime path: []const u8) void {
    comptime {
        if (!reflect.hasDecl(S, decl)) return;
        const D = @TypeOf(@field(S, decl));
        if (@typeInfo(D) != .@"struct") errors.fail("'{s}.{s}' must be a struct literal like `.{{ .field = ... }}`", .{ path, decl });
        for (reflect.fields(D)) |k| {
            var found = false;
            for (names) |n| if (std.mem.eql(u8, n, k.name)) {
                found = true;
            };
            if (!found) errors.fail("'{s}.{s}' names `{s}`, which is not a field of {s}{s}", .{
                path, decl, k.name, reflect.shortTypeName(S), errors.didYouMean(k.name, names),
            });
        }
    }
}

fn constraint(comptime meta: Meta, comptime key: []const u8) ?ConstraintValue(meta, key) {
    comptime {
        const C = meta.constraints orelse return null;
        if (!@hasField(C, key)) return null;
        return @field(@field(meta.constraints_holder.?.constraints, meta.field), key);
    }
}

fn ConstraintValue(comptime meta: Meta, comptime key: []const u8) type {
    const C = meta.constraints orelse return void;
    if (!@hasField(C, key)) return void;
    return @TypeOf(@field(@field(meta.constraints_holder.?.constraints, meta.field), key));
}

const all_constraint_kinds = [_][]const u8{ "min", "max", "min_len", "max_len", "pattern", "one_of", "min_items", "max_items" };

fn checkConstraints(comptime T: type, comptime meta: Meta, comptime allowed: []const []const u8, comptime path: []const u8) void {
    comptime {
        const C = meta.constraints orelse return;
        for (reflect.fields(C)) |k| {
            var ok = false;
            for (allowed) |a| if (std.mem.eql(u8, a, k.name)) {
                ok = true;
            };
            if (ok) continue;
            var known = false;
            for (all_constraint_kinds) |a| if (std.mem.eql(u8, a, k.name)) {
                known = true;
            };
            if (!known) errors.fail("constraint `{s}` on '{s}' is not a known constraint{s}; known constraints are {s}", .{
                k.name, path, errors.didYouMean(k.name, &all_constraint_kinds), errors.list(&all_constraint_kinds),
            });
            errors.fail("constraint `{s}` doesn't apply to '{s}', which is a {s}{s}", .{
                k.name, path, @typeName(T),
                if (allowed.len == 0) "" else "; constraints for this type are " ++ errors.list(allowed),
            });
        }
    }
}

fn defaultJson(comptime f: reflect.Field) ?[]const u8 {
    comptime {
        const v = f.defaultValue() orelse return null;
        return switch (@typeInfo(f.type)) {
            .bool => if (v) "true" else "false",
            .int, .float => num(v),
            .@"enum" => str(@tagName(v)),
            .pointer => |p| if (p.size == .slice and p.child == u8) str(v) else if (p.size == .slice and v.len == 0) "[]" else null,
            else => null,
        };
    }
}

// ── tests ────────────────────────────────────────────────────────────────────

test "primitive mappings" {
    try std.testing.expectEqualStrings("{\"type\":\"boolean\"}", comptime of(bool));
    try std.testing.expectEqualStrings("{\"type\":\"integer\",\"minimum\":0,\"maximum\":255}", comptime of(u8));
    try std.testing.expectEqualStrings("{\"type\":\"number\"}", comptime of(f64));
    try std.testing.expectEqualStrings("{\"type\":\"string\"}", comptime of([]const u8));
    try std.testing.expectEqualStrings("{\"type\":\"string\",\"enum\":[\"a\",\"b\"]}", comptime of(enum { a, b }));
    try std.testing.expectEqualStrings("{}", comptime of(Json));
}

test "struct with docs, constraints, optional and default" {
    const T = struct {
        urgency: u8,
        note: ?[]const u8 = null,
        mode: enum { fast, slow } = .fast,
        pub const docs = .{ .urgency = "1-5" };
        pub const constraints = .{ .urgency = .{ .min = 1, .max = 5 }, .note = .{ .max_len = 10 } };
    };
    try std.testing.expectEqualStrings(
        "{\"type\":\"object\",\"properties\":{" ++
            "\"urgency\":{\"type\":\"integer\",\"minimum\":1,\"maximum\":5,\"description\":\"1-5\"}," ++
            "\"note\":{\"type\":\"string\",\"maxLength\":10}," ++
            "\"mode\":{\"type\":\"string\",\"enum\":[\"fast\",\"slow\"],\"default\":\"fast\"}" ++
            "},\"required\":[\"urgency\"],\"additionalProperties\":false}",
        comptime of(T),
    );
    try std.testing.expectEqualStrings(
        "{\"type\":\"object\",\"properties\":{" ++
            "\"urgency\":{\"type\":\"integer\",\"description\":\"1-5\"}," ++
            "\"note\":{\"anyOf\":[{\"type\":\"string\"},{\"type\":\"null\"}]}," ++
            "\"mode\":{\"type\":\"string\",\"enum\":[\"fast\",\"slow\"]}" ++
            "},\"required\":[\"urgency\",\"note\",\"mode\"],\"additionalProperties\":false}",
        comptime render(T, .openai),
    );
}

test "tagged union" {
    const U = union(enum) { none, n: u8, p: struct { x: bool } };
    try std.testing.expectEqualStrings(
        "{\"oneOf\":[" ++
            "{\"type\":\"object\",\"properties\":{\"type\":{\"type\":\"string\",\"enum\":[\"none\"]}},\"required\":[\"type\"],\"additionalProperties\":false}," ++
            "{\"type\":\"object\",\"properties\":{\"type\":{\"type\":\"string\",\"enum\":[\"n\"]},\"value\":{\"type\":\"integer\",\"minimum\":0,\"maximum\":255}},\"required\":[\"type\",\"value\"],\"additionalProperties\":false}," ++
            "{\"type\":\"object\",\"properties\":{\"type\":{\"type\":\"string\",\"enum\":[\"p\"]},\"x\":{\"type\":\"boolean\"}},\"required\":[\"type\",\"x\"],\"additionalProperties\":false}" ++
            "]}",
        comptime of(U),
    );
}
