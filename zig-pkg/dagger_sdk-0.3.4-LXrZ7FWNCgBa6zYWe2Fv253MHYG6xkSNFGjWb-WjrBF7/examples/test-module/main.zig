//! Test module: a real Dagger module that runs tests and returns a
//! Directory containing test results.
//!
//! Usage:
//!   cd examples/test-module
//!   dagger develop
//!   dagger call test --src=../..
//!   dagger call test --src=../.. export --path=./test-results
//!
//! This exercises:
//!   - Returns dagger.Directory (OBJECT_KIND, Dagger-native handle)
//!   - Takes a dagger.Directory argument (OBJECT_KIND, hydrated from ID)
//!   - Uses container.withExec, container.stdout, directory.withNewFile

const std = @import("std");
const dagger = @import("dagger_sdk");

const TestModule = struct {
    /// Run tests on the source directory and return a Directory containing
    /// the test results as files.
    pub fn @"test"(
        self: *const TestModule,
        ctx: *dagger.module.Context,
        src: dagger.Directory,
    ) !dagger.Directory {
        _ = self;
        const dag = ctx.dag();

        // Run tests inside a container.
        const ctr = try dag.container();
        const base = try ctr.from("alpine:3.20");
        const with_deps = try base.withExec(&.{
            "apk", "add", "--no-cache", "zig",
        }, null, null, null, null, null, null, null, null, null, null);
        const with_src = try with_deps
            .withMountedDirectory("/src", src)
            .withWorkdir("/src", null);

        // Run the test suite and capture stdout.
        const tested = try with_src.withExec(&.{
            "zig", "build", "test",
        }, null, null, null, null, null, null, null, null, null, null);
        const output = try tested.stdout();

        // Write the test output to a file in a new directory.
        var results = try dag.directory();
        results = try results.withNewFile("test-output.txt", output);

        // Also capture the exit code info.
        const exit_code = try tested.exitCode();
        const exit_msg = try std.fmt.allocPrint(ctx.arena, "Exit code: {d}\n", .{exit_code});
        results = try results.withNewFile("exit-code.txt", exit_msg);

        return results;
    }

    /// Run tests and return pass/fail as a boolean.
    /// Demonstrates returning a scalar (BOOLEAN_KIND).
    pub fn testPasses(
        self: *const TestModule,
        ctx: *dagger.module.Context,
        src: dagger.Directory,
    ) !bool {
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

        const tested = try with_src.withExec(&.{
            "zig", "build", "test",
        }, null, null, null, null, null, null, null, null, null, null);
        const code = try tested.exitCode();
        return code == 0;
    }
};

pub fn main(init: std.process.Init) !void {
    return dagger.module.serve(init, TestModule{});
}
