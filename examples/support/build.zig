//! build.zig: one App, several outputs (see sketch/build.zig).
//!
//!   zig build                 → zig-out/bin/support (and the docs MCP server)
//!   zig build dev -- agents   → the zastra dev CLI against this App
//!   zig build lib             → libsupport + support.h (C ABI)
//!   zig build embed           → builds and runs embed.c against libsupport
//!   zig build test            → harness tests (scripted models, no network)
//!   zig build -Dtarget=aarch64-linux-musl -Doptimize=small
//!                             → a small static binary

const std = @import("std");
const z = @import("zastra");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const zastra_dep = b.dependency("zastra", .{ .target = target, .optimize = optimize });
    const zastra = zastra_dep.module("zastra");

    // A reusable tool package (§5.13). No target: it inherits the importer's.
    const notify = b.createModule(.{ .root_source_file = b.path("pkgs/notify/notify.zig") });

    const app_mod = b.createModule(.{
        .root_source_file = b.path("src/app.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "zastra", .module = zastra },
            .{ .name = "notify", .module = notify },
        },
    });

    // 1. The program.
    const exe = b.addExecutable(.{
        .name = "support",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "zastra", .module = zastra },
                .{ .name = "app", .module = app_mod },
                .{ .name = "notify", .module = notify },
            },
        }),
    });
    b.installArtifact(exe);

    // The docs MCP server the App launches (`.mcp.docs`).
    const docs = b.addExecutable(.{
        .name = "docs-mcp-server",
        .root_module = b.createModule(.{
            .root_source_file = b.path("tools/docs_server.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    const install_docs = b.addInstallArtifact(docs, .{});
    b.getInstallStep().dependOn(&install_docs.step);

    // The service-status MCP server (`.mcp.status`, Streamable HTTP). The
    // App treats it as optional; run `zig-out/bin/status-mcp-server` to add it.
    const status = b.addExecutable(.{
        .name = "status-mcp-server",
        .root_module = b.createModule(.{
            .root_source_file = b.path("tools/status_server.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    const install_status = b.addInstallArtifact(status, .{});
    b.getInstallStep().dependOn(&install_status.step);

    // 2. Dev CLI.
    const dev = z.addDev(b, .{ .app = app_mod, .zastra = zastra_dep });
    dev.run.step.dependOn(&install_docs.step);
    dev.run.addPassthruArgs();
    b.step("dev", "Run the zastra dev CLI against this App").dependOn(&dev.run.step);

    // 3. C ABI.
    const lib = z.addCLib(b, .{ .name = "support", .app = app_mod, .zastra = zastra_dep, .linkage = .dynamic });
    const lib_step = b.step("lib", "Build libsupport + support.h");
    lib_step.dependOn(&b.addInstallArtifact(lib.artifact, .{}).step);
    lib_step.dependOn(&b.addInstallHeaderFile(lib.header, "support.h").step);

    // The C example, linked against the library.
    const embed = b.addExecutable(.{
        .name = "embed",
        .root_module = b.createModule(.{ .target = target, .optimize = optimize, .link_libc = true }),
    });
    embed.root_module.addCSourceFile(.{ .file = b.path("embed.c") });
    embed.root_module.addIncludePath(lib.header.dirname());
    embed.root_module.linkLibrary(lib.artifact);
    const run_embed = b.addRunArtifact(embed);
    run_embed.step.dependOn(&install_docs.step);
    b.step("embed", "Build and run embed.c against libsupport").dependOn(&run_embed.step);

    // Tests: scripted models, fake clock. The App launches the docs MCP server.
    const tests = b.addTest(.{ .root_module = app_mod });
    const run_tests = b.addRunArtifact(tests);
    run_tests.step.dependOn(&install_docs.step);
    run_tests.step.dependOn(&install_status.step);
    b.step("test", "Run tests").dependOn(&run_tests.step);
}
