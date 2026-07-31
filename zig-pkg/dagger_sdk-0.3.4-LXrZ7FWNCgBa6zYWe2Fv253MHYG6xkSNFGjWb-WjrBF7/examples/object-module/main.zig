//! Object module: demonstrates returning a custom user-defined struct
//! as a Dagger object (OBJECT_KIND).
//!
//! Usage:
//!   cd examples/object-module
//!   dagger develop
//!   dagger call inspect --src=../..
//!   dagger call inspect --src=../.. image
//!   dagger call inspect --src=../.. digest
//!   dagger call inspect --src=../.. sizeBytes
//!
//! This exercises P0-2: user structs returned as OBJECT_KIND. The engine
//! registers the BuildInfo struct as a GraphQL object type, and the caller
//! can query individual fields on the returned value.

const std = @import("std");
const dagger = @import("dagger_sdk");

/// A user-defined struct returned from a module function.
/// The SDK registers this as OBJECT_KIND with fields: image, digest, sizeBytes.
const BuildInfo = struct {
    image: []const u8,
    digest: []const u8,
    size_bytes: i64,
};

const ObjectModule = struct {
    /// Inspect a source directory and return build metadata as a custom
    /// object. The caller can then query individual fields:
    ///
    ///   dagger call inspect --src=../.. image
    ///   dagger call inspect --src=../.. digest
    ///   dagger call inspect --src=../.. sizeBytes
    pub fn inspect(
        self: *const ObjectModule,
        ctx: *dagger.module.Context,
        src: dagger.Directory,
    ) !BuildInfo {
        _ = self;
        const dag = ctx.dag();

        // Build the source in a container.
        const ctr = try dag.container();
        const base = try ctr.from("alpine:3.20");
        const with_deps = try base.withExec(&.{
            "apk", "add", "--no-cache", "zig",
        }, null, null, null, null, null, null, null, null, null, null);
        const with_src = try with_deps
            .withMountedDirectory("/src", src)
            .withWorkdir("/src", null);

        const built = try with_src.withExec(&.{ "zig", "build" }, null, null, null, null, null, null, null, null, null, null);

        // Gather metadata.
        const image_ref = try base.id();
        const stdout = try built.stdout();

        // Return the user object. The SDK serializes it as JSON and the
        // engine stores it as an object reference, making each field
        // individually queryable by the caller.
        return .{
            .image = image_ref.value,
            .digest = stdout,
            .size_bytes = @intCast(stdout.len),
        };
    }

    /// Return a list of custom objects. Demonstrates LIST_KIND of
    /// OBJECT_KIND.
    pub fn layers(
        self: *const ObjectModule,
        ctx: *dagger.module.Context,
        src: dagger.Directory,
    ) ![]const BuildInfo {
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
        const output = try built.stdout();

        // Return a list with a single entry for demonstration.
        const result = try ctx.arena.alloc(BuildInfo, 1);
        result[0] = .{
            .image = "alpine:3.20",
            .digest = output,
            .size_bytes = @intCast(output.len),
        };
        return result;
    }
};

pub fn main(init: std.process.Init) !void {
    return dagger.module.serve(init, ObjectModule{});
}
