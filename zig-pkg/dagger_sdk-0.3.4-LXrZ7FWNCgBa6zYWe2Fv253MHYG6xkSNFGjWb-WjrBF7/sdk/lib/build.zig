//! Consumer-facing build script for the dagger-zig SDK library.
//!
//! This file lives at `sdk/lib/build.zig` and is what Zig executes when a
//! user module declares `dagger_sdk` as a dependency:
//!
//!   b.dependency("dagger_sdk", .{ .target = target, .optimize = optimize })
//!
//! It exposes the `dagger_sdk` module rooted at `src/root.zig`.
//!
//! This is NOT the repo-root `build.zig` — that one drives repo-level
//! development (tests, examples, codegen, CI). This one is the minimal
//! package entry point that ships inside the SDK module so external
//! consumers can import the library.

const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // SPIFFE is off by default for consumer modules. Users who need it
    // can pass .spiffe_experimental = true via dependency options in a
    // future version; for now the flag is fixed to false.
    const spiffe_options = b.addOptions();
    spiffe_options.addOption(bool, "spiffe_enabled", false);

    const dagger_mod = b.addModule("dagger_sdk", .{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = optimize,
    });
    dagger_mod.addOptions("spiffe_options", spiffe_options);
}
