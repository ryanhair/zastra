//! Tool validation and metadata (PLAN.md §6.3, §5.11–5.14).
//!
//! A tool is any type with `description`, `Input`, `Output` and `execute`.
//! Optional declarations unlock features: `name`, `ModelErrors` +
//! `error_messages`, `needsApproval` / `needs_approval`, `effects`,
//! `Requires`, `parallel`.

const std = @import("std");
const errors = @import("meta/errors.zig");
const reflect = @import("meta/reflect.zig");
const json_schema = @import("schema/json_schema.zig");

pub const known_decls = [_][]const u8{
    "description",   "Input",          "Output",  "execute", "name",     "docs",
    "ModelErrors",   "error_messages", "needsApproval", "needs_approval", "effects",
    "Requires",      "parallel",
};

pub const Effect = enum { reads, writes, network, spends_money, destructive };
pub const Effects = std.EnumSet(Effect);

pub const Approval = enum { never, always, dynamic };

/// Tool names must match ^[a-zA-Z0-9_-]{1,64}$ for every provider (§5.3).
pub fn validName(comptime n: []const u8) bool {
    if (n.len == 0 or n.len > 64) return false;
    for (n) |c| if (!(std.ascii.isAlphanumeric(c) or c == '_' or c == '-')) return false;
    return true;
}

/// Everything zastra derives about a tool type `T`, checked at comptime.
pub fn Info(comptime T: type, comptime Ctx: type, comptime agent: []const u8) type {
    comptime {
        @setEvalBranchQuota(1_000_000);
        const short = reflect.shortTypeName(T);
        if (!reflect.isContainer(T)) errors.fail("agent '{s}': `.tools` entry {s} is not a tool: tools are struct types with `description`, `Input`, `Output` and `execute`", .{ agent, @typeName(T) });
        reflect.checkDeclTypos(T, &known_decls, "tool", short);
        for ([_][]const u8{ "description", "Input", "Output", "execute" }) |req| {
            if (!@hasDecl(T, req)) errors.fail("{s} is not a tool: missing `pub const {s}`{s}", .{
                short, req, if (std.mem.eql(u8, req, "execute")) " (use `pub fn execute(t: *z.ToolCtx(Ctx), in: Input) !Output`)" else "",
            });
        }
        if (!reflect.isString(@TypeOf(T.description))) errors.fail("tool '{s}': `description` must be a string", .{short});
        if (@TypeOf(T.Input) != type) errors.fail("tool '{s}': `Input` must be a type", .{short});
        if (@TypeOf(T.Output) != type) errors.fail("tool '{s}': `Output` must be a type", .{short});
        if (@typeInfo(T.Input) != .@"struct") errors.fail("tool '{s}': `Input` must be a struct (tool arguments are a JSON object); got {s}", .{ short, @typeName(T.Input) });

        const tool_name: []const u8 = if (@hasDecl(T, "name")) T.name else reflect.snakeCase(short);
        if (!validName(tool_name)) errors.fail("tool '{s}': name \"{s}\" must match ^[a-zA-Z0-9_-]{{1,64}}$ for every provider; set `pub const name = \"...\"`", .{ short, tool_name });

        // Requires (§5.13): the App's Ctx must have each field with that type.
        const generic = @hasDecl(T, "Requires");
        if (generic) checkRequires(T, Ctx, short);
        checkExecute(T, Ctx, short, generic);

        // ModelErrors / error_messages (§5.11)
        if (@hasDecl(T, "ModelErrors")) {
            if (@TypeOf(T.ModelErrors) != type or @typeInfo(T.ModelErrors) != .error_set)
                errors.fail("tool '{s}': `ModelErrors` must be an error set, e.g. `error{{OrderNotFound}}`", .{short});
            if (!@hasDecl(T, "error_messages")) errors.fail("tool '{s}' declares `ModelErrors` but no `error_messages`; add `pub const error_messages = .{{ .{s} = \"...\" }}`", .{ short, firstError(T.ModelErrors) });
            const set = @typeInfo(T.ModelErrors).error_set.error_names orelse errors.fail("tool '{s}': `ModelErrors` can't be `anyerror`", .{short});
            var names: [set.len][]const u8 = undefined;
            for (set, 0..) |name, i| names[i] = name;
            const M = @TypeOf(T.error_messages);
            for (set) |name| if (!@hasField(M, name))
                errors.fail("tool '{s}': `error_messages` has no entry for error.{s}; every error in `ModelErrors` needs a message for the model", .{ short, name });
            for (reflect.fields(M)) |f| {
                var ok = false;
                for (set) |name| if (std.mem.eql(u8, name, f.name)) {
                    ok = true;
                };
                if (!ok) errors.fail("tool '{s}': `error_messages` has an entry for `{s}`, which is not in `ModelErrors`{s}", .{ short, f.name, errors.didYouMean(f.name, &names) });
            }
        } else if (@hasDecl(T, "error_messages")) {
            errors.fail("tool '{s}' declares `error_messages` but no `ModelErrors`; add `pub const ModelErrors = error{{...}}`", .{short});
        }

        // Approval
        const effects = effectsOf(T, short);
        const approval: Approval = if (@hasDecl(T, "needsApproval")) blk: {
            const F = @TypeOf(T.needsApproval);
            if (@typeInfo(F) != .@"fn") errors.fail("tool '{s}': `needsApproval` must be a function `fn (t: *z.ToolCtx(Ctx), in: Input) bool`; for a constant use `needs_approval`", .{short});
            if (@typeInfo(F).@"fn".return_type != bool) errors.fail("tool '{s}': `needsApproval` must return bool", .{short});
            break :blk .dynamic;
        } else if (@hasDecl(T, "needs_approval")) blk: {
            if (@TypeOf(T.needs_approval) != bool) errors.fail("tool '{s}': `needs_approval` must be a bool", .{short});
            break :blk if (T.needs_approval) .always else .never;
        } else if (effects.contains(.spends_money) or effects.contains(.destructive)) .always else .never;

        if (@hasDecl(T, "parallel") and @TypeOf(T.parallel) != bool) errors.fail("tool '{s}': `parallel` must be a bool", .{short});

        return struct {
            pub const Tool = T;
            pub const Input = T.Input;
            pub const Output = T.Output;
            pub const name = tool_name;
            pub const type_name = short;
            pub const description = T.description;
            pub const approval_kind = approval;
            pub const effect_set = effects;
            pub const parallel = if (@hasDecl(T, "parallel")) T.parallel else true;
            pub const is_generic = generic;
            pub const ModelErrors = if (@hasDecl(T, "ModelErrors")) T.ModelErrors else error{};
        };
    }
}

fn firstError(comptime E: type) []const u8 {
    const set = @typeInfo(E).error_set.error_names orelse return "SomeError";
    return if (set.len > 0) set[0] else "SomeError";
}

fn effectsOf(comptime T: type, comptime short: []const u8) Effects {
    comptime {
        if (!@hasDecl(T, "effects")) return Effects.initOne(.reads);
        var set = Effects.empty;
        const E = @TypeOf(T.effects);
        if (!reflect.isTuple(E)) errors.fail("tool '{s}': `effects` must be a tuple like `.{{ .reads, .network }}`", .{short});
        const names = reflect.fieldNames(Effect);
        for (0..reflect.fields(E).len) |i| {
            const v = T.effects[i];
            if (@TypeOf(v) != @TypeOf(.enum_literal) and @TypeOf(v) != Effect)
                errors.fail("tool '{s}': `effects` entries must be effect names like `.network`", .{short});
            const tag = @tagName(v);
            const e = std.meta.stringToEnum(Effect, tag) orelse
                errors.fail("tool '{s}': unknown effect `.{s}`{s}; effects are {s}", .{ short, tag, errors.didYouMean(tag, names), errors.list(names) });
            set.insert(e);
        }
        return set;
    }
}

fn checkRequires(comptime T: type, comptime Ctx: type, comptime short: []const u8) void {
    comptime {
        if (@TypeOf(T.Requires) != type or @typeInfo(T.Requires) != .@"struct")
            errors.fail("tool '{s}': `Requires` must be a struct type listing the context fields it needs", .{short});
        const ctx_names = reflect.fieldNames(Ctx);
        for (reflect.fields(T.Requires)) |f| {
            if (!@hasField(Ctx, f.name)) errors.fail("tool '{s}' requires `ctx.{s}: {s}`, but the App's Ctx ({s}) has no field `{s}`{s}", .{
                short, f.name, @typeName(f.type), reflect.shortTypeName(Ctx), f.name, errors.didYouMean(f.name, ctx_names),
            });
            const Have = @FieldType(Ctx, f.name);
            if (Have != f.type) errors.fail("tool '{s}' requires `ctx.{s}: {s}`, but the App's Ctx has `{s}: {s}`", .{
                short, f.name, @typeName(f.type), f.name, @typeName(Have),
            });
        }
    }
}

fn checkExecute(comptime T: type, comptime Ctx: type, comptime short: []const u8, comptime generic: bool) void {
    comptime {
        const F = @TypeOf(T.execute);
        const sig = "`pub fn execute(t: *z.ToolCtx(Ctx), in: Input) !Output`";
        if (@typeInfo(F) != .@"fn") errors.fail("tool '{s}': `execute` must be a function: {s}", .{ short, sig });
        const info = @typeInfo(F).@"fn";
        if (info.param_types.len != 2) errors.fail("tool '{s}': `execute` takes {d} parameters; expected 2: {s}", .{ short, info.param_types.len, sig });
        const P0 = info.param_types[0];
        const ToolCtxT = @import("context.zig").ToolCtx(Ctx);
        if (P0 == null) {
            if (!generic) errors.fail("tool '{s}': `execute` takes `anytype` as its context; declare `pub const Requires = struct {{ ... }}` with the context fields it needs", .{short});
        } else if (P0.? != *ToolCtxT) {
            errors.fail("tool '{s}': `execute`'s first parameter is {s}; expected *z.ToolCtx({s})", .{ short, @typeName(P0.?), reflect.shortTypeName(Ctx) });
        }
        if (info.param_types[1]) |P1| if (P1 != T.Input)
            errors.fail("tool '{s}': `execute`'s second parameter is {s}; expected Input", .{ short, @typeName(P1) });
        if (!info.is_generic) {
            const R = info.return_type.?;
            const payload = switch (@typeInfo(R)) {
                .error_union => |eu| eu.payload,
                else => R,
            };
            if (payload != T.Output) errors.fail("tool '{s}': `execute` returns {s}; expected !Output ({s})", .{ short, @typeName(R), @typeName(T.Output) });
        }
    }
}

test validName {
    try std.testing.expect(validName("lookup_order"));
    try std.testing.expect(!validName("look up"));
    try std.testing.expect(!validName(""));
}
