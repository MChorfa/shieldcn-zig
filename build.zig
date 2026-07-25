const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // ── Main executable ───────────────────────────
    const zigimg = b.dependency("zigimg", .{
        .target = target,
        .optimize = optimize,
    });

    const exe_mod = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    exe_mod.addImport("zigimg", zigimg.module("zigimg"));

    const exe = b.addExecutable(.{
        .name = "shieldcn",
        .root_module = exe_mod,
    });
    b.installArtifact(exe);

    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| {
        run_cmd.addArgs(args);
    }

    const run_step = b.step("run", "Run shieldcn server");
    run_step.dependOn(&run_cmd.step);

    // ── Unit tests ────────────────────────────────
    const test_mod = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    test_mod.addImport("zigimg", zigimg.module("zigimg"));

    const unit_tests = b.addTest(.{
        .name = "unit-tests",
        .root_module = test_mod,
    });

    const run_unit_tests = b.addRunArtifact(unit_tests);
    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&run_unit_tests.step);

    // ── Check (fast compile for CI) ───────────────
    const check_exe = b.addExecutable(.{
        .name = "shieldcn-check",
        .root_module = exe_mod,
    });
    const check_step = b.step("check", "Check compilation");
    check_step.dependOn(&check_exe.step);

    // ── Fuzz target placeholder ───────────────────
    const fuzz_step = b.step("fuzz", "Run fuzz tests (placeholder)");
    _ = fuzz_step;

    // ── Dagger CI Module ─────────────────────────
    const dagger_sdk = b.dependency("dagger_sdk", .{
        .target = target,
        .optimize = optimize,
    });

    const ci_mod = b.createModule(.{
        .root_source_file = b.path("ci/main.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    ci_mod.addImport("dagger_sdk", dagger_sdk.module("dagger_sdk"));

    const ci_exe = b.addExecutable(.{
        .name = "module",
        .root_module = ci_mod,
    });
    b.installArtifact(ci_exe);
}
