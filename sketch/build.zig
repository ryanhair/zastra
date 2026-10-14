//! build.zig: one App, three outputs.
//!
//!   zig build                 → ./zig-out/bin/support      (your program)
//!   zig build dev             → runs the zastra dev CLI against your App
//!   zig build lib             → libsupport.{a,so,dylib} + support.h  (C ABI)
//!   zig build -Dtarget=aarch64-linux-musl -Doptimize=ReleaseSmall
//!                             → ~1–2 MB static binary for a Pi or a container
//!                               `FROM scratch` (embed a CA bundle; see main.zig)

const std = @import("std");
const z = @import("zastra");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const zastra_dep = b.dependency("zastra", .{
        .target = target,
        .optimize = optimize,
        // No feature flags needed: Zig only analyzes code that is referenced,
        // and zastra's provider/storage/MCP code is only referenced when the
        // App uses it. An App whose models are all `anthropic/...` contains
        // no OpenAI code; an App with `.storage = .memory` links no SQLite.
    });

    // The App module: your declarations. Shared by all three outputs below.
    const app_mod = b.createModule(.{
        .root_source_file = b.path("src/app.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{.{ .name = "zastra", .module = zastra_dep.module("zastra") }},
    });

    // 1. Your program.
    const exe = b.addExecutable(.{
        .name = "support",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "zastra", .module = zastra_dep.module("zastra") },
                .{ .name = "app", .module = app_mod },
            },
        }),
    });
    b.installArtifact(exe);

    // 2. Dev CLI: `z.addDev` generates a main() for your App type, built with
    //    zcli-style comptime command discovery:
    //
    //      zig build dev -- agents                      list agents, models, tools
    //      zig build dev -- schema support              print tool JSON Schemas
    //      zig build dev -- chat support --thread t1    REPL with streaming + approvals
    //      zig build dev -- run handle_ticket @t.json   run a workflow from JSON
    //      zig build dev -- runs --suspended            list paused runs
    //      zig build dev -- resume <run_id> @r.json     resume one
    //      zig build dev -- trace <run_id>              pretty-print a trace tree
    //
    //    Studio-lite (v1.1): `dev serve` exposes the same commands over a tiny HTTP+SSE
    //    API, so a web UI can be layered on later without changing the App.
    const dev = z.addDev(b, .{ .app = app_mod, .zastra = zastra_dep });
    const dev_step = b.step("dev", "Run the zastra dev CLI against this App");
    dev_step.dependOn(&dev.run.step);
    if (b.args) |args| dev.run.addArgs(args);

    // 3. C ABI: the same App exported as a library with a generated header.
    //    `z.addCLib` emits `export fn` wrappers and support.h from the App's
    //    comptime metadata: agent/workflow IDs, and JSON Schemas for every
    //    input/output type so non-Zig callers get the contract too.
    const lib = z.addCLib(b, .{
        .name = "support",
        .app = app_mod,
        .zastra = zastra_dep,
        .linkage = .dynamic, // .static for iOS / embedding in a single binary
    });
    const lib_step = b.step("lib", "Build libsupport + support.h");
    lib_step.dependOn(&b.addInstallArtifact(lib.artifact, .{}).step);
    lib_step.dependOn(&b.addInstallHeaderFile(lib.header, "support.h").step);

    // Tests: scripted models, fake clock, in-memory storage. No network.
    const tests = b.addTest(.{ .root_module = app_mod });
    b.step("test", "Run tests").dependOn(&b.addRunArtifact(tests).step);
}
