//! Build script for dagger-zig.
//!
//! Zig 0.16+ build system. Key API changes from 0.15 we account for:
//!   - addExecutable/addTest/addLibrary take `.root_module` (a created Module)
//!     instead of `.root_source_file` (a LazyPath).
//!   - Modules declare their own target/optimize/imports.
//!
//! Steps:
//!   zig build                      — build the library module
//!   zig build test                 — run offline unit tests
//!   zig build test-integration     — run against a live engine
//!   zig build codegen              — regenerate src/gen.zig; pass `-- --out PATH`
//!   zig build c-lib                — build libdagger.{a,so,dylib} + install headers
//!   zig build run-first-pipeline   — example: alpine echo hello
//!   zig build run-build-app        — example: chained container ops
//!   zig build run-parallel         — example: Io.Group concurrent pipelines
//!   zig build run-hello-c          — C-ABI smoke test

const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // ── feature flags ────────────────────────────────────────────────────
    const spiffe_experimental = b.option(bool, "spiffe-experimental", "Enable experimental SPIFFE/SPIRE workload identity support (default: false)") orelse false;

    // Create options module for feature flags
    const spiffe_options = b.addOptions();
    spiffe_options.addOption(bool, "spiffe_enabled", spiffe_experimental);

    // ── library module (the public import: `@import("dagger_sdk")`) ─────
    const dagger_mod = b.addModule("dagger_sdk", .{
        .root_source_file = b.path("sdk/lib/src/root.zig"),
        .target = target,
        .optimize = optimize,
    });
    dagger_mod.addOptions("spiffe_options", spiffe_options);

    const ci_mod = b.createModule(.{
        .root_source_file = b.path("ci/pipeline.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
        .imports = &.{.{ .name = "dagger_sdk", .module = dagger_mod }},
    });
    const ci_module = b.addExecutable(.{
        .name = "module",
        .root_module = ci_mod,
    });
    const ci_runtime_install = b.addInstallArtifact(ci_module, .{});
    const ci_runtime_step = b.step("module-runtime", "Install the Dagger CI module runtime");
    ci_runtime_step.dependOn(&ci_runtime_install.step);

    // ── unit tests ──────────────────────────────────────────────────────
    const unit_mod = b.createModule(.{
        .root_source_file = b.path("sdk/lib/src/root.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    unit_mod.addOptions("spiffe_options", spiffe_options);
    const unit_tests = b.addTest(.{ .root_module = unit_mod });
    const run_unit = b.addRunArtifact(unit_tests);
    const test_step = b.step("test", "Run offline unit tests");
    test_step.dependOn(&run_unit.step);

    // ── integration tests ───────────────────────────────────────────────
    const integ_mod = b.createModule(.{
        .root_source_file = b.path("tests/integration.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
        .imports = &.{.{ .name = "dagger_sdk", .module = dagger_mod }},
    });
    const integ_tests = b.addTest(.{ .root_module = integ_mod });
    const run_integ = b.addRunArtifact(integ_tests);
    const integ_step = b.step("test-integration", "Run integration tests against a live Dagger engine");
    integ_step.dependOn(&run_integ.step);

    // ── benchmarks (offline; no live engine required) ───────────────────
    const bench_mod = b.createModule(.{
        .root_source_file = b.path("benches/querybuilder.zig"),
        .target = target,
        .optimize = .ReleaseFast, // benchmarks are meaningless in Debug
        .link_libc = true,
        .imports = &.{.{ .name = "dagger_sdk", .module = dagger_mod }},
    });
    const bench_exe = b.addExecutable(.{ .name = "bench", .root_module = bench_mod });
    // Install the binary (zig-out/bin/bench) so it can be profiled with an
    // external sampling profiler, e.g. `samply record -- ./zig-out/bin/bench`.
    const bench_install = b.addInstallArtifact(bench_exe, .{});
    const run_bench = b.addRunArtifact(bench_exe);
    run_bench.step.dependOn(&bench_install.step);
    if (b.args) |args| run_bench.addArgs(args);
    const bench_step = b.step("bench", "Run offline performance benchmarks (query builder, serialization)");
    bench_step.dependOn(&run_bench.step);

    // ── flamegraph (external profiler; renders an SVG from the bench binary) ──
    // Zig has no built-in profiler. This step builds the bench binary, then
    // drives `flamegraph` (cargo install flamegraph) to render a CPU flamegraph.
    // Fails loudly with install instructions if no profiler is present.
    const flamegraph = b.addSystemCommand(&.{ "bash", "scripts/bench-flamegraph.sh" });
    flamegraph.step.dependOn(&bench_install.step); // ensure zig-out/bin/bench exists first
    if (b.args) |args| flamegraph.addArgs(args);
    const flamegraph_step = b.step("flamegraph", "Render a CPU flamegraph SVG of the benchmarks (requires `flamegraph`; see benches/README.md)");
    flamegraph_step.dependOn(&flamegraph.step);

    // ── module E2E test (offline, proves comptime plumbing) ─────────────
    const mod_e2e_mod = b.createModule(.{
        .root_source_file = b.path("tests/module_e2e.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
        .imports = &.{.{ .name = "dagger_sdk", .module = dagger_mod }},
    });
    const mod_e2e = b.addTest(.{ .root_module = mod_e2e_mod });
    const run_mod_e2e = b.addRunArtifact(mod_e2e);
    const mod_e2e_step = b.step("test-module", "Offline: prove module runtime comptime plumbing");
    mod_e2e_step.dependOn(&run_mod_e2e.step);

    // ── comprehensive test suite ───────────────────────────────────────
    const test_suite_mod = b.createModule(.{
        .root_source_file = b.path("sdk/lib/src/test_suite.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
        .imports = &.{.{ .name = "dagger_sdk", .module = dagger_mod }},
    });
    const test_suite = b.addTest(.{ .root_module = test_suite_mod });
    const run_test_suite = b.addRunArtifact(test_suite);
    const test_suite_step = b.step("test-suite", "Run comprehensive test suite (platform, telemetry, performance)");
    test_suite_step.dependOn(&run_test_suite.step);

    // ── downstream smoke regression ────────────────────────────────────
    const downstream_smoke = b.addSystemCommand(&.{ "bash", "scripts/downstream-smoke-verify.sh" });
    const downstream_smoke_step = b.step("downstream-verify", "Verify the downstream Zig module smoke fixture still loads and runs");
    downstream_smoke_step.dependOn(&downstream_smoke.step);

    // ── full CI proof ──────────────────────────────────────────────────
    const full_ci = b.addSystemCommand(&.{ "bash", "scripts/ci-pipeline-verify.sh" });
    const full_ci_step = b.step("ci-verify", "Verify the full CI pipeline runs through the repository SDK");
    full_ci_step.dependOn(&full_ci.step);

    // ── codegen tool ────────────────────────────────────────────────────
    const codegen_mod = b.createModule(.{
        .root_source_file = b.path("codegen/src/main.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
        .imports = &.{.{ .name = "dagger_sdk", .module = dagger_mod }},
    });
    const codegen_exe = b.addExecutable(.{
        .name = "dagger-codegen",
        .root_module = codegen_mod,
    });
    b.installArtifact(codegen_exe);
    const run_codegen = b.addRunArtifact(codegen_exe);
    if (b.args) |args| run_codegen.addArgs(args);
    const codegen_step = b.step("codegen", "Regenerate src/gen.zig from the live engine schema");
    codegen_step.dependOn(&run_codegen.step);

    // ── examples ────────────────────────────────────────────────────────
    addExample(b, dagger_mod, target, optimize, "first-pipeline", "examples/first-pipeline/main.zig");
    addExample(b, dagger_mod, target, optimize, "build-app", "examples/build-app/main.zig");
    addExample(b, dagger_mod, target, optimize, "parallel", "examples/parallel/main.zig");
    addExample(b, dagger_mod, target, optimize, "secrets", "examples/secrets/main.zig");
    addExample(b, dagger_mod, target, optimize, "cache", "examples/cache/main.zig");
    addExample(b, dagger_mod, target, optimize, "multi-stage-build", "examples/multi-stage-build/main.zig");
    addExample(b, dagger_mod, target, optimize, "service-containers", "examples/service-containers/main.zig");

    // ── C shared + static libraries ─────────────────────────────────────
    // NOTE: C API remains experimental and disabled by default while the
    // public SDK line stays Zig-first. Re-enable only when the ABI story is
    // ready to be shipped and documented end-to-end.
    //
    // const c_api_mod = b.createModule(.{
    //     .root_source_file = b.path("sdk/lib/src/c_api.zig"),
    //     .target = target,
    //     .optimize = optimize,
    //     .link_libc = true,
    // });
    //
    // const c_lib_shared = b.addLibrary(.{
    //     .name = "dagger",
    //     .root_module = c_api_mod,
    //     .linkage = .dynamic,
    // });
    // c_lib_shared.installHeader(b.path("include/dagger.h"), "dagger.h");
    // b.installArtifact(c_lib_shared);
    //
    // const c_lib_static = b.addLibrary(.{
    //     .name = "dagger",
    //     .root_module = c_api_mod,
    //     .linkage = .static,
    // });
    // b.installArtifact(c_lib_static);
    //
    // const c_lib_step = b.step("c-lib", "Build libdagger (shared + static) and install headers");
    // c_lib_step.dependOn(&c_lib_shared.step);
    // c_lib_step.dependOn(&c_lib_static.step);
    // c_lib_step.dependOn(b.getInstallStep());

    // ── C example ───────────────────────────────────────────────────────
    // Disabled until the Zig 0.16 C source-file API is reworked for this SDK.
    // const c_example_mod = b.createModule(.{
    //     .target = target,
    //     .optimize = optimize,
    // });
    // const c_example = b.addExecutable(.{
    //     .name = "hello-c",
    //     .root_module = c_example_mod,
    // });
    // c_example.addCSourceFiles(...);
    // c_example.addIncludePath(b.path("include"));
    // c_example.linkLibrary(c_lib_static);
    // c_example.linkSystemLibrary("c");
    // b.installArtifact(c_example);
    // const run_c = b.addRunArtifact(c_example);
    // run_c.step.dependOn(b.getInstallStep());
    // b.step("run-hello-c", "Run the C client example").dependOn(&run_c.step);
}

fn addExample(
    b: *std.Build,
    mod: *std.Build.Module,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
    name: []const u8,
    src: []const u8,
) void {
    const ex_mod = b.createModule(.{
        .root_source_file = b.path(src),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
        .imports = &.{.{ .name = "dagger_sdk", .module = mod }},
    });
    const exe = b.addExecutable(.{ .name = name, .root_module = ex_mod });
    b.installArtifact(exe);

    const run = b.addRunArtifact(exe);
    run.step.dependOn(b.getInstallStep());
    const step_name = std.fmt.allocPrint(b.allocator, "run-{s}", .{name}) catch @panic("OOM");
    const step_desc = std.fmt.allocPrint(b.allocator, "Run the {s} example", .{name}) catch @panic("OOM");
    b.step(step_name, step_desc).dependOn(&run.step);
}
