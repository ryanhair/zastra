const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const mod = b.addModule("zastra", .{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = optimize,
    });

    const test_step = b.step("test", "Run unit, golden and compile-fail tests");

    // Unit tests.
    const unit = b.addTest(.{ .root_module = mod });
    test_step.dependOn(&b.addRunArtifact(unit).step);

    // Integration tests (tests/*.zig): providers against cassettes, agents
    // and workflows against the scripted model.
    const integration = b.addTest(.{ .root_module = b.createModule(.{
        .root_source_file = b.path("tests/integration.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{.{ .name = "zastra", .module = mod }},
    }) });
    test_step.dependOn(&b.addRunArtifact(integration).step);

    // Golden tests: tests/golden/main.zig renders every golden artifact and
    // compares it with the checked-in file. `zig build golden -- --update`
    // rewrites the files instead.
    const golden_exe = b.addExecutable(.{
        .name = "golden",
        .root_module = b.createModule(.{
            .root_source_file = b.path("tests/golden/main.zig"),
            .target = b.graph.host,
            .optimize = .Debug,
            .imports = &.{.{ .name = "zastra", .module = mod }},
        }),
    });
    const golden_check = b.addRunArtifact(golden_exe);
    golden_check.setCwd(b.path("."));
    golden_check.has_side_effects = true;
    test_step.dependOn(&golden_check.step);

    const golden_update = b.addRunArtifact(golden_exe);
    golden_update.setCwd(b.path("."));
    golden_update.has_side_effects = true;
    if (b.args) |args| golden_update.addArgs(args);
    b.step("golden", "Check golden files (-- --update to rewrite them)").dependOn(&golden_update.step);

    // Compile-fail tests.
    addCompileFailTests(b, test_step);

    // Model catalog regeneration (PLAN.md §5.4).
    const models_update = b.addExecutable(.{
        .name = "models-update",
        .root_module = b.createModule(.{
            .root_source_file = b.path("tools/models-update/main.zig"),
            .target = b.graph.host,
            .optimize = .Debug,
        }),
    });
    const models_run = b.addRunArtifact(models_update);
    models_run.setCwd(b.path("."));
    models_run.has_side_effects = true;
    b.step("models-update", "Regenerate src/catalog/models.zig from tools/models-update/sources.json").dependOn(&models_run.step);
}

/// Every `tests/compile_fail/*.zig` must fail to compile, and its stderr must
/// contain each `//! expect: <text>` line from the top of the file.
fn addCompileFailTests(b: *std.Build, test_step: *std.Build.Step) void {
    const io = b.graph.io;
    const step = b.step("compile-fail", "Run compile-fail tests only");
    test_step.dependOn(step);

    var dir = b.build_root.handle.openDir(io, "tests/compile_fail", .{ .iterate = true }) catch |err| {
        std.debug.panic("zastra: can't open tests/compile_fail: {t}", .{err});
    };
    defer dir.close(io);

    var it = dir.iterate();
    while (it.next(io) catch |err| std.debug.panic("zastra: listing tests/compile_fail: {t}", .{err})) |entry| {
        if (entry.kind != .file or !std.mem.endsWith(u8, entry.name, ".zig")) continue;
        const name = b.dupe(entry.name);
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
