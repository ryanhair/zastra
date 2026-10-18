# zastra

A Mastra-style agent framework for Zig (agents, tools, workflows, memory, MCP, tracing), built around comptime, small static binaries, and a C ABI.

## Read first
- `PLAN.md` is the source of truth for scope, architecture, milestones and decisions (§13).
- `sketch/` is the source of truth for the consumer-facing API.
  - `sketch/src/app.zig`: declarations
  - `sketch/src/main.zig`: runtime use
  - `sketch/build.zig`: build integration
  - `sketch/examples/embed.c`: C ABI
- If the plan and the sketch disagree, fix one of them and record the decision in PLAN.md §13.

## Ground rules
- Zig **0.17.x** only. Use `std.Io` everywhere: `std.process.Init`, `io.async`, `Future.await`/`cancel`. Assume `std.Io.Threaded`.
- Declarations are comptime; execution is runtime. Nothing in a declaration allocates or does I/O.
- Results are allocated with the caller's allocator. No hidden globals.
- Every comptime check needs a hand-written `@compileError` that follows PLAN.md §7, plus a compile-fail test in `tests/compile_fail/`.
- No feature flags in build.zig. Size must follow usage (PLAN.md §5.6).
- Public API changes: update `sketch/` and the relevant PLAN.md section in the same change.

## Commands
- The toolchain is pinned in `mise.toml` (`mise install`); CI reads it too.
- `zig build test`: unit, integration, golden and compile-fail tests
- `zig build golden -- --update`: refresh golden files
- `zig build fuzz --fuzz[=N]`: coverage-guided fuzzing (LLVM-built tests; `zig build test` runs each fuzz test once)
- `zig build compile-fail`: compile-fail tests only (`tests/compile_fail/*.zig`, `//! expect:` lines)
- `zig build size`: binary-size budgets; `zig build models-update`: regenerate the catalog; `zig build docs`
- In `examples/support`: `zig build test`, `zig build dev -- <cmd>`, `zig build lib`, `zig build embed`
- Zig caches fetched packages in `zig-pkg/` (git-ignored).
