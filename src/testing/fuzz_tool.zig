//! `z.testing.fuzzTool(App, Tool, .{ .ctx, .iterations, .seed })` (PLAN.md
//! §19.4, D52): run a tool the way a model's tool call runs it (arguments
//! JSON, `schema.parse`, `execute`, output serialization) on arbitrary valid
//! inputs and on hostile arguments.
//!
//! Each iteration `i` uses seed `.seed + i` and nothing else, so a failure
//! reported at seed `s` reproduces with `.seed = s, .iterations = 1`.

const std = @import("std");
const builtin = @import("builtin");
const errors = @import("../meta/errors.zig");
const reflect = @import("../meta/reflect.zig");
const tool_mod = @import("../tool.zig");
const ToolCtx = @import("../context.zig").ToolCtx;
const trace = @import("../trace/trace.zig");
const json = @import("../schema/json.zig");
const json_schema = @import("../schema/json_schema.zig");
const parse = @import("../schema/parse.zig");
const validate = @import("../mcp/validate.zig");
const arb = @import("arbitrary.zig");
const Allocator = std.mem.Allocator;
const Value = std.json.Value;

const known_options = [_][]const u8{ "ctx", "iterations", "seed", "mapped_errors_only", "allow_effects", "hostile", "gen", "smith", "quiet" };

/// Effects that make fuzzing a tool unsafe unless its context points at test
/// doubles (§5.12).
const gated = [_]tool_mod.Effect{ .writes, .network, .spends_money, .destructive };

pub fn fuzzTool(comptime AppT: type, comptime Tool: type, opts: anytype) !void {
    const Ctx = AppT.Context;
    const TI = tool_mod.Info(Tool, Ctx, "z.testing.fuzzTool");
    comptime checkOptions(TI, @TypeOf(opts));
    const O = @TypeOf(opts);
    const ctx: *Ctx = opts.ctx;
    const iterations: u64 = if (@hasField(O, "iterations")) opts.iterations else if (@hasField(O, "smith")) 1 else 300;
    const seed: u64 = if (@hasField(O, "seed")) opts.seed else 0;
    const run: Run(Ctx, TI) = .{
        .ctx = ctx,
        .io = std.testing.io,
        .mapped_errors_only = if (@hasField(O, "mapped_errors_only")) opts.mapped_errors_only else false,
        .hostile = if (@hasField(O, "hostile")) opts.hostile else true,
        .gen = if (@hasField(O, "gen")) opts.gen else .{},
        .quiet = if (@hasField(O, "quiet")) opts.quiet else false,
    };

    const crash = CrashNote.install();
    defer crash.restore();

    for (0..iterations) |i| {
        const s = seed +% i;
        var prng: std.Random.DefaultPrng = .init(s);
        const source: Source = if (@hasField(O, "smith")) .{ .smith = opts.smith } else .{ .random = prng.random() };
        try run.one(source, s);
    }
}

const Source = union(enum) { random: std.Random, smith: *std.testing.Smith };

fn Run(comptime Ctx: type, comptime TI: type) type {
    return struct {
        const Self = @This();
        const Input = TI.Input;
        const Output = TI.Output;

        ctx: *Ctx,
        io: std.Io,
        mapped_errors_only: bool,
        hostile: bool,
        gen: arb.Options,
        quiet: bool,

        fn one(r: Self, source: Source, seed: u64) !void {
            var arena_state: std.heap.ArenaAllocator = .init(std.testing.allocator);
            defer arena_state.deinit();
            const arena = arena_state.allocator();
            var g: arb.Gen = switch (source) {
                inline else => |s| .init(arena, s, r.gen),
            };

            // Valid input: the path a well-formed tool call takes.
            const valid = try json.stringifyAlloc(arena, try g.value(Input));
            try r.call(arena, valid, seed, "valid input");

            if (!r.hostile) return;
            // Hostile arguments: the same JSON, mutated.
            const bad = try mutate(&g, arena, valid);
            try r.call(arena, bad, seed, "hostile arguments");
        }

        /// What the agent loop does with a tool call's arguments.
        fn call(r: Self, arena: Allocator, args: []const u8, seed: u64, comptime mode: []const u8) !void {
            CrashNote.set(TI.name, seed, mode, args);
            defer CrashNote.clear();

            var issue: parse.Issue = .{};
            const input = parse.parse(Input, arena, args, &issue) catch |err| switch (err) {
                error.OutOfMemory => return error.OutOfMemory,
                error.ValidationFailed => {
                    if (issue.message.len == 0) return r.report(seed, mode, args, "the parser rejected the arguments without a message", .{});
                    if (try schemaAccepts(arena, args)) |accepted| if (accepted)
                        return r.report(seed, mode, args, "the parser rejected arguments that match the tool's schema: {f}", .{issue});
                    return;
                },
            };
            if (try schemaAccepts(arena, args)) |accepted| if (!accepted)
                return r.report(seed, mode, args, "the parser accepted arguments that the tool's schema rejects", .{});

            var tracer: trace.Tracer = .{ .io = r.io, .config = .off };
            var span = tracer.begin(.tool_call, TI.name, @splat('0'), null);
            defer span.end();
            var call_arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
            defer call_arena.deinit();
            var tctx: ToolCtx(Ctx) = .{
                .ctx = r.ctx,
                .arena = call_arena.allocator(),
                .io = r.io,
                .run_id = "fuzz_run",
                .tool_call_id = "fuzz_call",
                .trace = &span,
            };
            if (TI.Tool.execute(&tctx, input)) |out| {
                const text = try json.stringifyAlloc(arena, out);
                if (try outputIssue(arena, text)) |bad|
                    return r.report(seed, mode, args, "the output doesn't match Output's schema at {s}: {s}\n  output: {s}", .{ bad.path, bad.message, text });
            } else |err| {
                if (r.mapped_errors_only and !isModelError(err))
                    return r.report(seed, mode, args, "execute returned error.{t}, which isn't in ModelErrors", .{err});
            }
        }

        fn isModelError(err: anyerror) bool {
            const set = @typeInfo(TI.ModelErrors).error_set.error_names orelse return false;
            inline for (set) |name| if (std.mem.eql(u8, @errorName(err), name)) return true;
            return false;
        }

        /// Whether `args` is valid against the tool's input schema: true
        /// when the canonical schema accepts it, false when the strict-mode
        /// schema (OpenAI: optionals may be `null`, bounds dropped) rejects it
        /// too, null when they disagree or `args` isn't JSON.
        fn schemaAccepts(arena: Allocator, args: []const u8) !?bool {
            const doc = std.json.parseFromSliceLeaky(Value, arena, args, .{}) catch |err| switch (err) {
                error.OutOfMemory => return error.OutOfMemory,
                else => return null,
            };
            // Past its depth bound the validator accepts everything.
            if (depth(doc, 0) >= validate.max_depth) return null;
            const canonical = try std.json.parseFromSliceLeaky(Value, arena, comptime json_schema.of(Input), .{});
            if (try validate.validate(arena, canonical, doc) == null) return true;
            const strict = try std.json.parseFromSliceLeaky(Value, arena, comptime json_schema.render(Input, .openai), .{});
            if (try validate.validate(arena, strict, doc) == null) return null;
            return false;
        }

        fn outputIssue(arena: Allocator, text: []const u8) !?validate.Issue {
            const schema = try std.json.parseFromSliceLeaky(Value, arena, comptime json_schema.of(Output), .{});
            const doc = try std.json.parseFromSliceLeaky(Value, arena, text, .{});
            return validate.validate(arena, schema, doc);
        }

        fn report(r: Self, seed: u64, comptime mode: []const u8, args: []const u8, comptime fmt: []const u8, fargs: anytype) error{ToolFuzzFailed} {
            if (!r.quiet) std.debug.print(
                "z.testing.fuzzTool({s}): seed {d} (" ++ mode ++ "): " ++ fmt ++ "\n  arguments: {s}\n  reproduce with .seed = {d}, .iterations = 1\n",
                .{TI.name} ++ .{seed} ++ fargs ++ .{ args, seed },
            );
            return error.ToolFuzzFailed;
        }
    };
}

/// Mutate valid arguments JSON the ways a confused or adversarial model
/// might: wrong types, missing and extra fields, out-of-range numbers,
/// truncated text, deep nesting, bad escapes.
pub fn mutate(g: *arb.Gen, arena: Allocator, valid: []const u8) ![]const u8 {
    var root = try std.json.parseFromSliceLeaky(Value, arena, valid, .{});
    const kind = g.index(8);
    switch (kind) {
        // Text-level mutations.
        0 => return valid[0..g.index(valid.len)],
        1, 2 => {
            const marker = "__zastra_fuzz__";
            const slot = pick(g, &root);
            slot.* = .{ .string = marker };
            const text = try std.json.Stringify.valueAlloc(arena, root, .{});
            const replacement = if (kind == 1)
                try nested(arena, 1 + g.index(4000))
            else
                bad_strings[g.index(bad_strings.len)];
            return std.mem.replaceOwned(u8, arena, text, "\"" ++ marker ++ "\"", replacement);
        },
        // Value-level mutations.
        3 => {
            const slot = pick(g, &root);
            slot.* = wrongType(g, arena, slot.*);
        },
        4 => pick(g, &root).* = odd_numbers[g.index(odd_numbers.len)],
        5 => if (randomObject(g, &root)) |o| {
            if (o.count() > 0) _ = o.orderedRemove(o.keys()[g.index(o.count())]);
        },
        6 => if (randomObject(g, &root)) |o| try o.put(arena, if (o.count() > 0 and g.boolean()) try arena.print("{s}_", .{o.keys()[0]}) else "unexpected", .{ .integer = 1 }),
        else => root = wrongType(g, arena, root),
    }
    return std.json.Stringify.valueAlloc(arena, root, .{});
}

const odd_numbers = [_]Value{
    .{ .integer = -1 },                           .{ .integer = std.math.maxInt(i64) },
    .{ .integer = std.math.minInt(i64) },         .{ .float = 1.5 },
    .{ .float = 1e300 },                          .{ .float = -1e300 },
    .{ .float = 1e19 },                           .{ .number_string = "18446744073709551616" },
    .{ .number_string = "-9223372036854775809" }, .{ .number_string = "1e400" },
    .{ .integer = 0 },                            .{ .float = -0.0 },
};

const bad_strings = [_][]const u8{
    "\"\\ud800\"",  "\"\\udc00\\ud800\"", "\"\\u0000\"", "\"\\x41\"",
    "\"\xff\xfe\"", "\"\xc0\xaf\"",       "\"\\u12\"",   "\"unterminated",
    "1e999999",     "-",                  "01",          "NaN",
    "{\"type\":1}", "[]",                 "{}",          "true",
};

fn depth(v: Value, d: usize) usize {
    if (d >= validate.max_depth) return d;
    var max = d;
    switch (v) {
        .array => |a| for (a.items) |item| {
            max = @max(max, depth(item, d + 1));
        },
        .object => |o| for (o.values()) |item| {
            max = @max(max, depth(item, d + 1));
        },
        else => {},
    }
    return max;
}

fn nested(arena: Allocator, levels: usize) ![]const u8 {
    const out = try arena.alloc(u8, levels * 2);
    @memset(out[0..levels], '[');
    @memset(out[levels..], ']');
    return out;
}

fn wrongType(g: *arb.Gen, arena: Allocator, v: Value) Value {
    const options = [_]Value{ .null, .{ .bool = true }, .{ .integer = 7 }, .{ .float = 2.5 }, .{ .string = "x" }, .{ .array = .init(arena) }, .{ .object = .empty } };
    var i = g.index(options.len);
    // Something of a different kind than `v`.
    while (std.meta.activeTag(options[i]) == std.meta.activeTag(v)) i = (i + 1) % options.len;
    return options[i];
}

/// A random position in the tree (the root included).
fn pick(g: *arb.Gen, root: *Value) *Value {
    var cur = root;
    while (g.chance(2, 3)) {
        switch (cur.*) {
            .object => |*o| {
                if (o.count() == 0) break;
                cur = &o.values()[g.index(o.count())];
            },
            .array => |*a| {
                if (a.items.len == 0) break;
                cur = &a.items[g.index(a.items.len)];
            },
            else => break,
        }
    }
    return cur;
}

fn randomObject(g: *arb.Gen, root: *Value) ?*std.json.ObjectMap {
    for (0..8) |_| {
        const v = pick(g, root);
        if (v.* == .object) return &v.object;
    }
    return if (root.* == .object) &root.object else null;
}

fn checkOptions(comptime TI: type, comptime O: type) void {
    comptime {
        const who = "z.testing.fuzzTool(" ++ TI.type_name ++ ")";
        if (@typeInfo(O) != .@"struct") errors.fail("{s}: options must be a struct literal like `.{{ .ctx = &ctx, .iterations = 300 }}`", .{who});
        for (reflect.fields(O)) |f| {
            var known = false;
            for (known_options) |k| if (std.mem.eql(u8, k, f.name)) {
                known = true;
            };
            if (!known) errors.fail("{s}: unknown option `.{s}`{s}; options are {s}", .{ who, f.name, errors.didYouMean(f.name, &known_options), errors.list(&known_options) });
        }
        if (!@hasField(O, "ctx")) errors.fail("{s}: pass `.ctx = &ctx`, the context the tool runs with", .{who});

        const names = reflect.fieldNames(tool_mod.Effect);
        var allowed = tool_mod.Effects.empty;
        if (@hasField(O, "allow_effects")) {
            const A = @FieldType(O, "allow_effects");
            if (!reflect.isTuple(A)) errors.fail("{s}: `.allow_effects` must be a tuple of effects like `.{{ .writes }}`", .{who});
            const defaults = reflect.fields(A);
            for (defaults) |f| {
                if (f.type != @TypeOf(.enum_literal)) errors.fail("{s}: `.allow_effects` entries must be effect names like `.writes`", .{who});
                const tag = @tagName(f.defaultValue().?);
                const e = std.meta.stringToEnum(tool_mod.Effect, tag) orelse
                    errors.fail("{s}: unknown effect `.{s}` in `.allow_effects`{s}; effects are {s}", .{ who, tag, errors.didYouMean(tag, names), errors.list(names) });
                if (!TI.effect_set.contains(e)) errors.fail("{s}: `.allow_effects` names `.{s}`, but the tool doesn't declare it; remove it", .{ who, tag });
                allowed.insert(e);
            }
        }
        for (gated) |e| if (TI.effect_set.contains(e) and !allowed.contains(e))
            errors.fail("{s}: the tool declares `.{s}`, and fuzzing calls it hundreds of times; point its context at test doubles and pass `.allow_effects = .{{ .{s} }}`", .{ who, @tagName(e), @tagName(e) });
    }
}

/// On a crash (a panic, or a signal that ends in abort), print the case
/// that was running. Posix only; the handler state is process-global
/// because signal handlers can't take a context.
const CrashNote = struct {
    var buf: [4096]u8 = undefined;
    var len: std.atomic.Value(usize) = .init(0);
    const supported = builtin.os.tag != .windows and builtin.os.tag != .wasi;

    previous: if (supported) std.posix.Sigaction else void,

    fn install() CrashNote {
        if (!supported) return .{ .previous = {} };
        var old: std.posix.Sigaction = undefined;
        const act: std.posix.Sigaction = .{
            .handler = .{ .handler = onAbort },
            .mask = std.posix.sigemptyset(),
            .flags = 0,
        };
        std.posix.sigaction(.ABRT, &act, &old);
        return .{ .previous = old };
    }

    fn restore(c: CrashNote) void {
        if (!supported) return;
        std.posix.sigaction(.ABRT, &c.previous, null);
    }

    fn set(name: []const u8, seed: u64, comptime mode: []const u8, args: []const u8) void {
        if (!supported) return;
        len.store(0, .release);
        const s = std.fmt.bufPrint(&buf, "z.testing.fuzzTool({s}): crashed at seed {d} (" ++ mode ++ "); reproduce with .seed = {d}, .iterations = 1\n  arguments: {s}\n", .{ name, seed, seed, args }) catch blk: {
            const tail = "...\n";
            @memcpy(buf[buf.len - tail.len ..], tail);
            break :blk buf[0..];
        };
        len.store(s.len, .release);
    }

    fn clear() void {
        if (supported) len.store(0, .release);
    }

    fn onAbort(_: std.posix.SIG) callconv(.c) void {
        const n = len.load(.acquire);
        if (n > 0) _ = std.posix.system.write(2, &buf, n);
    }
};

test "hostile mutations parse or are rejected with a message" {
    const In = struct {
        query: []const u8,
        kind: ?enum { a, b } = null,
        limit: u8 = 10,
        tags: []const []const u8 = &.{},
        filter: union(enum) { none, price: struct { max_cents: u32 }, ids: []const u32 } = .none,
        pub const constraints = .{ .query = .{ .min_len = 1 }, .limit = .{ .min = 1, .max = 50 } };
    };
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    var prng: std.Random.DefaultPrng = .init(2);
    var g: arb.Gen = .init(arena.allocator(), prng.random(), .{});
    var rejected: usize = 0;
    for (0..2000) |_| {
        const valid = try json.stringifyAlloc(arena.allocator(), try g.value(In));
        const bad = try mutate(&g, arena.allocator(), valid);
        var issue: parse.Issue = .{};
        if (parse.parse(In, arena.allocator(), bad, &issue)) |_| {} else |err| {
            try std.testing.expectEqual(error.ValidationFailed, err);
            try std.testing.expect(issue.message.len > 0);
            rejected += 1;
        }
    }
    try std.testing.expect(rejected > 1500);
}
