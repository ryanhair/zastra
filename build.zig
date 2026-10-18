const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const mod = b.addModule("zastra", .{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = optimize,
    });

    // SQLite, compiled from the vendored amalgamation as a static library.
    // Its objects are only linked into binaries that reference sqlite3_*
    // symbols, which only happens for Apps with `.storage = .sqlite` (§5.6).
    const sqlite_dep = b.dependency("sqlite", .{});
    const sqlite = b.addLibrary(.{
        .name = "zastra_sqlite",
        .linkage = .static,
        .root_module = b.createModule(.{ .target = target, .optimize = optimize, .link_libc = true }),
    });
    sqlite.root_module.addCSourceFile(.{
        .file = sqlite_dep.path("sqlite3.c"),
        .flags = &.{
            "-DSQLITE_DQS=0",
            "-DSQLITE_THREADSAFE=1",
            "-DSQLITE_DEFAULT_MEMSTATUS=0",
            "-DSQLITE_OMIT_LOAD_EXTENSION",
            "-DSQLITE_OMIT_DEPRECATED",
            "-DSQLITE_OMIT_SHARED_CACHE",
            "-DSQLITE_OMIT_PROGRESS_CALLBACK",
            "-DSQLITE_OMIT_TRACE",
            "-DSQLITE_OMIT_UTF16",
            "-DSQLITE_OMIT_COMPLETE",
            "-DSQLITE_OMIT_TCL_VARIABLE",
            "-DSQLITE_LIKE_DOESNT_MATCH_BLOBS",
            "-DSQLITE_MAX_EXPR_DEPTH=0",
            "-DSQLITE_USE_ALLOCA",
        },
    });
    mod.linkLibrary(sqlite);

    const test_step = b.step("test", "Run unit, golden and compile-fail tests");

    // Unit tests.
    const unit = b.addTest(.{ .root_module = mod });
    test_step.dependOn(&b.addRunArtifact(unit).step);

    // Integration tests (tests/*.zig): providers against cassettes, agents
    // and workflows against the scripted model.
    const fake_mcp = b.addExecutable(.{
        .name = "fake-mcp-server",
        .root_module = b.createModule(.{
            .root_source_file = b.path("tests/fake_mcp_server.zig"),
            .target = b.graph.host,
            .optimize = .debug,
        }),
    });
    // A test binary that crashes inside z.testing.fuzzTool; fuzz_tool_test
    // runs it and checks the crash note.
    const fuzz_crash = b.addTest(.{ .root_module = b.createModule(.{
        .root_source_file = b.path("tests/fuzz_crash.zig"),
        .target = b.graph.host,
        .optimize = .debug,
        .imports = &.{.{ .name = "zastra", .module = mod }},
    }) });
    const test_options = b.addOptions();
    test_options.addOptionPath("fake_mcp_server", fake_mcp.getEmittedBin());
    test_options.addOptionPath("fuzz_crash", fuzz_crash.getEmittedBin());
    const integration = b.addTest(.{ .root_module = b.createModule(.{
        .root_source_file = b.path("tests/integration.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "zastra", .module = mod },
            .{ .name = "test_options", .module = test_options.createModule() },
        },
    }) });
    test_step.dependOn(&b.addRunArtifact(integration).step);

    // The support example's App, for golden prefixes, Mermaid, manifest and header.
    const notify = b.createModule(.{ .root_source_file = b.path("examples/support/pkgs/notify/notify.zig") });
    const support_app = b.createModule(.{
        .root_source_file = b.path("examples/support/src/app.zig"),
        .target = b.graph.host,
        .imports = &.{
            .{ .name = "zastra", .module = mod },
            .{ .name = "notify", .module = notify },
        },
    });

    // Golden tests: tests/golden/main.zig renders every golden artifact and
    // compares it with the checked-in file. `zig build golden -- --update`
    // rewrites the files instead.
    const golden_exe = b.addExecutable(.{
        .name = "golden",
        .root_module = b.createModule(.{
            .root_source_file = b.path("tests/golden/main.zig"),
            .target = b.graph.host,
            .optimize = .debug,
            .imports = &.{
                .{ .name = "zastra", .module = mod },
                .{ .name = "support_app", .module = support_app },
            },
        }),
    });
    const golden_check = b.addRunArtifact(golden_exe);
    golden_check.setCwd(b.path("."));
    golden_check.has_side_effects = true;
    test_step.dependOn(&golden_check.step);

    const golden_update = b.addRunArtifact(golden_exe);
    golden_update.setCwd(b.path("."));
    golden_update.has_side_effects = true;
    golden_update.addPassthruArgs();
    b.step("golden", "Check golden files (-- --update to rewrite them)").dependOn(&golden_update.step);

    // Compile-fail tests.
    addCompileFailTests(b, test_step);

    // Size budget (PLAN.md §5.6, M7): three variants, cross-compiled for
    // aarch64-linux-musl at `small` (ReleaseSmall), with upper bounds. Variant 1 is also
    // built unstripped to check that it contains no OpenAI provider code.
    addSizeChecks(b, mod, sqlite_dep);

    // API reference: `zig build docs` → zig-out/docs.
    const docs_lib = b.addLibrary(.{ .name = "zastra", .linkage = .static, .root_module = mod });
    const install_docs = b.addInstallDirectory(.{ .source_dir = docs_lib.getEmittedDocs(), .install_dir = .prefix, .install_subdir = "docs" });
    b.step("docs", "Generate the API reference into zig-out/docs").dependOn(&install_docs.step);

    // Model catalog regeneration (PLAN.md §5.4).
    const models_update = b.addExecutable(.{
        .name = "models-update",
        .root_module = b.createModule(.{
            .root_source_file = b.path("tools/models-update/main.zig"),
            .target = b.graph.host,
            .optimize = .debug,
        }),
    });
    const models_run = b.addRunArtifact(models_update);
    models_run.setCwd(b.path("."));
    models_run.has_side_effects = true;
    b.step("models-update", "Regenerate src/catalog/models.zig from tools/models-update/sources.json").dependOn(&models_run.step);
    const models_update_tests = b.addTest(.{ .root_module = models_update.root_module });
    test_step.dependOn(&b.addRunArtifact(models_update_tests).step);
}

fn addSizeChecks(b: *std.Build, host_mod: *std.Build.Module, sqlite_dep: *std.Build.Dependency) void {
    _ = host_mod;
    const step = b.step("size", "Check binary-size budgets (aarch64-linux-musl, -Doptimize=small)");
    const target = b.resolveTargetQuery(.{ .cpu_arch = .aarch64, .os_tag = .linux, .abi = .musl });
    const checker = b.addExecutable(.{
        .name = "size-check",
        .root_module = b.createModule(.{ .root_source_file = b.path("tools/size_check.zig"), .target = b.graph.host }),
    });
    const Variant = struct { name: []const u8, budget: u64 };
    const variants = [_]Variant{
        .{ .name = "anthropic_memory", .budget = 1_000_000 },
        .{ .name = "both_sqlite", .budget = 2_000_000 },
        .{ .name = "full", .budget = 3_000_000 },
    };
    for (variants) |v| for ([_]bool{ true, false }) |strip| {
        if (!strip and !std.mem.eql(u8, v.name, "anthropic_memory")) continue;
        const z = b.createModule(.{ .root_source_file = b.path("src/root.zig"), .target = target, .optimize = .small });
        const sqlite = b.addLibrary(.{
            .name = "zastra_sqlite",
            .linkage = .static,
            .root_module = b.createModule(.{ .target = target, .optimize = .small, .link_libc = true }),
        });
        sqlite.root_module.addCSourceFile(.{ .file = sqlite_dep.path("sqlite3.c"), .flags = &.{ "-DSQLITE_DQS=0", "-DSQLITE_THREADSAFE=1", "-DSQLITE_OMIT_LOAD_EXTENSION", "-DSQLITE_OMIT_DEPRECATED", "-DSQLITE_DEFAULT_MEMSTATUS=0" } });
        z.linkLibrary(sqlite);
        const exe = b.addExecutable(.{
            .name = b.fmt("{s}{s}", .{ v.name, if (strip) "" else "-symbols" }),
            .root_module = b.createModule(.{
                .root_source_file = b.path(b.fmt("tests/size/{s}.zig", .{v.name})),
                .target = target,
                .optimize = .small,
                .strip = strip,
                .imports = &.{.{ .name = "zastra", .module = z }},
            }),
        });
        const run = b.addRunArtifact(checker);
        run.addArtifactArg(exe);
        if (strip) {
            run.addArg(b.fmt("{d}", .{v.budget}));
        } else {
            run.addArgs(&.{ "100000000", "--absent", "provider.openai_compat", "--absent", "provider.openai_responses", "--present", "provider.stream.SseStream(provider.anthropic)" });
        }
        run.has_side_effects = true;
        step.dependOn(&run.step);
    };
}

/// Every `tests/compile_fail/*.zig` must fail to compile, and its stderr must
/// contain each `//! expect: <text>` line from the top of the file.
fn addCompileFailTests(b: *std.Build, test_step: *std.Build.Step) void {
    const io = b.graph.io;
    const step = b.step("compile-fail", "Run compile-fail tests only");
    test_step.dependOn(step);

    // The case list and each case's expect lines are read while configuring.
    b.dependOnDirectoryContents(b.path("tests/compile_fail"));
    var dir = b.root.openDir(io, "tests/compile_fail", .{ .iterate = true }) catch |err| {
        std.debug.panic("zastra: can't open tests/compile_fail: {t}", .{err});
    };
    defer dir.close(io);

    var it = dir.iterate();
    while (it.next(io) catch |err| std.debug.panic("zastra: listing tests/compile_fail: {t}", .{err})) |entry| {
        if (entry.kind != .file or !std.mem.endsWith(u8, entry.name, ".zig")) continue;
        const name = b.dupe(entry.name);
        b.dependOnFileContents(b.path(b.fmt("tests/compile_fail/{s}", .{name})));
        const src = dir.readFileAlloc(io, name, b.allocator, .limited(1 << 20)) catch |err| {
            std.debug.panic("zastra: reading compile-fail case {s}: {t}", .{ name, err });
        };

        const run = b.addSystemCommand(&.{ b.graph.zig_exe, "build-obj", "-fno-emit-bin", "--dep", "zastra" });
        run.addPrefixedFileArg("-Mroot=", b.path(b.fmt("tests/compile_fail/{s}", .{name})));
        run.addPrefixedFileArg("-Mzastra=", b.path("src/root.zig"));
        run.setName(b.fmt("compile-fail {s}", .{name}));
        run.has_side_effects = true;
        run.expectExitCode(1);

        var expects: usize = 0;
        var lines = std.mem.splitScalar(u8, src, '\n');
        while (lines.next()) |line| {
            const prefix = "//! expect: ";
            if (!std.mem.startsWith(u8, line, prefix)) continue;
            run.expectStdErrMatch(std.mem.trimEnd(u8, line[prefix.len..], "\r"));
            expects += 1;
        }
        if (expects == 0) std.debug.panic("zastra: compile-fail case {s} has no `//! expect:` line", .{name});
        step.dependOn(&run.step);
    }
}

// ── build helpers for apps (`const z = @import("zastra");` in your build.zig) ──

pub const DevOptions = struct {
    /// The module that declares `pub const App = z.App(...)`.
    app: *std.Build.Module,
    /// `b.dependency("zastra", ...)`.
    zastra: *std.Build.Dependency,
};

pub const Dev = struct {
    exe: *std.Build.Step.Compile,
    run: *std.Build.Step.Run,
};

/// The dev CLI for an App (PLAN.md §8): `zig build dev -- <command>`.
pub fn addDev(b: *std.Build, opts: DevOptions) Dev {
    const exe = b.addExecutable(.{
        .name = "zastra-dev",
        .root_module = b.createModule(.{
            .root_source_file = opts.zastra.path("build/dev.zig"),
            .target = opts.app.resolved_target orelse b.graph.host,
            .optimize = opts.app.optimize orelse .debug,
            .imports = &.{
                .{ .name = "zastra", .module = opts.zastra.module("zastra") },
                .{ .name = "app", .module = opts.app },
            },
        }),
    });
    const run = b.addRunArtifact(exe);
    run.stdio = .inherit;
    return .{ .exe = exe, .run = run };
}

pub const CLibOptions = struct {
    /// Library and symbol prefix: "support" → libsupport, support_app_new, support.h.
    name: []const u8,
    app: *std.Build.Module,
    zastra: *std.Build.Dependency,
    linkage: std.lang.LinkMode = .dynamic,
};

pub const CLib = struct {
    artifact: *std.Build.Step.Compile,
    /// The generated header.
    header: std.Build.LazyPath,
};

/// The App as a C library with a generated header (PLAN.md §9).
pub fn addCLib(b: *std.Build, opts: CLibOptions) CLib {
    const options = b.addOptions();
    options.addOption([]const u8, "name", opts.name);
    const target = opts.app.resolved_target orelse b.graph.host;
    const lib = b.addLibrary(.{
        .name = opts.name,
        .linkage = opts.linkage,
        .root_module = b.createModule(.{
            .root_source_file = opts.zastra.path("build/clib.zig"),
            .target = target,
            .optimize = opts.app.optimize orelse .debug,
            .link_libc = true,
            .imports = &.{
                .{ .name = "zastra", .module = opts.zastra.module("zastra") },
                .{ .name = "app", .module = opts.app },
                .{ .name = "zastra_clib_options", .module = options.createModule() },
            },
        }),
    });

    // The header is rendered by a small host program that evaluates the App
    // at comptime. When cross-compiling, the app module is re-created for the
    // host with the same imports.
    const host = b.graph.host;
    const same_target = target.result.cpu.arch == host.result.cpu.arch and target.result.os.tag == host.result.os.tag and target.result.abi == host.result.abi;
    const host_zastra = if (same_target) opts.zastra.module("zastra") else b.createModule(.{
        .root_source_file = opts.zastra.path("src/root.zig"),
        .target = host,
    });
    const host_app = if (same_target) opts.app else blk: {
        const m = b.createModule(.{ .root_source_file = opts.app.root_source_file.?, .target = host });
        var it = opts.app.import_table.iterator();
        while (it.next()) |e| m.addImport(e.key_ptr.*, if (std.mem.eql(u8, e.key_ptr.*, "zastra")) host_zastra else e.value_ptr.*);
        break :blk m;
    };
    const gen = b.addExecutable(.{
        .name = b.fmt("{s}-header", .{opts.name}),
        .root_module = b.createModule(.{
            .root_source_file = opts.zastra.path("build/header.zig"),
            .target = host,
            .imports = &.{
                .{ .name = "zastra", .module = host_zastra },
                .{ .name = "app", .module = host_app },
                .{ .name = "zastra_clib_options", .module = options.createModule() },
            },
        }),
    });
    const run = b.addRunArtifact(gen);
    const header = run.captureStdOut(.{ .basename = b.fmt("{s}.h", .{opts.name}) });
    return .{ .artifact = lib, .header = header };
}
