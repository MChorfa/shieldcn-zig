//! Build module: a real Dagger module that builds a Zig project and
//! returns a Container.
//!
//! Usage:
//!   cd examples/build-module
//!   dagger develop
//!   dagger call build --src=../..
//!   dagger call build --src=../.. | stdout
//!
//! This exercises the full module path:
//!   - Returns dagger.Container (OBJECT_KIND, Dagger-native handle)
//!   - Takes a dagger.Directory argument (OBJECT_KIND, hydrated from ID)
//!   - Uses the generated API surface (container.from, withWorkdir, etc.)

const std = @import("std");
const dagger = @import("dagger_sdk");

const BuildModule = struct {
    /// Build the Zig SDK library inside a container and return the
    /// resulting container. The caller can then export, run, or inspect it.
    pub fn build(
        self: *const BuildModule,
        ctx: *dagger.module.Context,
        src: dagger.Directory,
    ) !dagger.Container {
        _ = self;

        // Get the Dagger client from the module context.
        const dag = ctx.dag();

        // Start from a base image with Zig installed.
        const base = try dag.container();
        const ctr = try base.from("alpine:3.20");

        // Install build dependencies.
        const with_deps = try ctr.withExec(&.{
            "apk", "add", "--no-cache", "zig", "git", "curl",
        }, null, null, null, null, null, null, null, null, null, null);

        // Mount the source directory.
        const with_src = try with_deps
            .withMountedDirectory("/src", src)
            .withWorkdir("/src", null);

        // Run the build.
        const built = try with_src.withExec(&.{
            "zig", "build",
        }, null, null, null, null, null, null, null, null, null, null);

        return built;
    }

    /// Build and return the stdout of the build command as a string.
    /// Demonstrates returning a scalar (STRING_KIND).
    pub fn buildLog(
        self: *const BuildModule,
        ctx: *dagger.module.Context,
        src: dagger.Directory,
    ) ![]const u8 {
        _ = self;
        const dag = ctx.dag();

        const ctr = try dag.container();
        const base = try ctr.from("alpine:3.20");
        const with_deps = try base.withExec(&.{
            "apk", "add", "--no-cache", "zig",
        }, null, null, null, null, null, null, null, null, null, null);
        const with_src = try with_deps
            .withMountedDirectory("/src", src)
            .withWorkdir("/src", null);

        const built = try with_src.withExec(&.{ "zig", "build" }, null, null, null, null, null, null, null, null, null, null);
        return try built.stdout();
    }
};

pub fn main(init: std.process.Init) !void {
    return dagger.module.serve(init, BuildModule{});
}
