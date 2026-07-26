const std = @import("std");
const dagger = @import("dagger_sdk");

const ShieldcnModule = struct {
    fn getSource(ctx: *dagger.module.Context) !dagger.Directory {
        const host = try ctx.dag().host();
        return host.directory(".", null, null, null, null);
    }

    pub fn build(
        self: *const ShieldcnModule,
        ctx: *dagger.module.Context,
    ) !dagger.Directory {
        _ = self;

        const zig_version = "0.16.0";
        const source = try getSource(ctx);

        // Create a build container with Zig
        const base_ctr = try ctx.dag().container(null);
        const base = try base_ctr.from("kassany/alpine-ziglang:" ++ zig_version, null);

        // Mount source code to read-only path
        const base_with_dir = try base.withDirectory("/src-ro", (try source.id()).value, null, null, null, null, null, null);
        const src = try base_with_dir.withWorkdir("/src-ro", null);

        // Copy source to writable /tmp/build
        const prep = try src.withExec(&.{ "sh", "-c", "mkdir -p /tmp/build && cd /src-ro && tar cf - . | (cd /tmp/build && tar xf -) && rm -rf /tmp/build/.zig-cache /tmp/build/zig-out && echo copied" }, null, null, null, null, null, null, null, null, null, null);
        const build_src = try prep.withWorkdir("/tmp/build", null);

        // Build the project for x86_64-linux-musl
        const build_run = try build_src.withExec(&.{
            "zig",
            "build",
            "-Doptimize=ReleaseFast",
            "-Dtarget=x86_64-linux-musl",
        }, null, null, null, null, null, null, null, null, null, null);

        // Export the build output directory
        const out_dir = try build_run.directory("./zig-out", null);
        return out_dir;
    }

    pub fn buildAarch64(
        self: *const ShieldcnModule,
        ctx: *dagger.module.Context,
    ) !dagger.Directory {
        _ = self;

        const zig_version = "0.16.0";
        const source = try getSource(ctx);

        // Create a build container with Zig
        const base_ctr = try ctx.dag().container(null);
        const base = try base_ctr.from("kassany/alpine-ziglang:" ++ zig_version, null);

        // Mount source code to read-only path
        const base_with_dir = try base.withDirectory("/src-ro", (try source.id()).value, null, null, null, null, null, null);
        const src = try base_with_dir.withWorkdir("/src-ro", null);

        // Copy source to writable /tmp/build
        const prep = try src.withExec(&.{ "sh", "-c", "mkdir -p /tmp/build && cd /src-ro && tar cf - . | (cd /tmp/build && tar xf -) && rm -rf /tmp/build/.zig-cache /tmp/build/zig-out && echo copied" }, null, null, null, null, null, null, null, null, null, null);
        const build_src = try prep.withWorkdir("/tmp/build", null);

        // Build the project for aarch64-linux-musl
        const build_run = try build_src.withExec(&.{
            "zig",
            "build",
            "-Doptimize=ReleaseFast",
            "-Dtarget=aarch64-linux-musl",
        }, null, null, null, null, null, null, null, null, null, null);

        // Export the build output directory
        const out_dir = try build_run.directory("./zig-out", null);
        return out_dir;
    }

    pub fn @"test"(
        self: *const ShieldcnModule,
        ctx: *dagger.module.Context,
    ) ![]const u8 {
        _ = self;

        const zig_version = "0.16.0";
        const source = try getSource(ctx);

        // Create a build container with Zig
        const base_ctr = try ctx.dag().container(null);
        const base = try base_ctr.from("kassany/alpine-ziglang:" ++ zig_version, null);

        // Mount source code to read-only path
        const base_with_dir = try base.withDirectory("/src-ro", (try source.id()).value, null, null, null, null, null, null);
        const src = try base_with_dir.withWorkdir("/src-ro", null);

        // Copy source to writable /tmp/build
        const prep = try src.withExec(&.{ "sh", "-c", "mkdir -p /tmp/build && cd /src-ro && tar cf - . | (cd /tmp/build && tar xf -) && rm -rf /tmp/build/.zig-cache /tmp/build/zig-out && echo copied" }, null, null, null, null, null, null, null, null, null, null);
        const build_src = try prep.withWorkdir("/tmp/build", null);

        // Run tests
        const test_run = try build_src.withExec(&.{
            "zig",
            "build",
            "test",
        }, null, null, null, null, null, null, null, null, null, null);

        return test_run.stdout();
    }

    pub fn lint(
        self: *const ShieldcnModule,
        ctx: *dagger.module.Context,
    ) ![]const u8 {
        _ = self;

        const zig_version = "0.16.0";
        const source = try getSource(ctx);

        // Create a build container with Zig
        const base_ctr = try ctx.dag().container(null);
        const base = try base_ctr.from("kassany/alpine-ziglang:" ++ zig_version, null);

        // Mount source code to read-only path
        const base_with_dir = try base.withDirectory("/src-ro", (try source.id()).value, null, null, null, null, null, null);
        const src = try base_with_dir.withWorkdir("/src-ro", null);

        // Copy source to writable /tmp/build
        const prep = try src.withExec(&.{ "sh", "-c", "mkdir -p /tmp/build && cd /src-ro && tar cf - . | (cd /tmp/build && tar xf -) && rm -rf /tmp/build/.zig-cache /tmp/build/zig-out && echo copied" }, null, null, null, null, null, null, null, null, null, null);
        const build_src = try prep.withWorkdir("/tmp/build", null);

        // Run check
        const check = try build_src.withExec(&.{
            "zig",
            "build",
            "check",
        }, null, null, null, null, null, null, null, null, null, null);

        return check.stdout();
    }

    pub fn container(
        self: *const ShieldcnModule,
        ctx: *dagger.module.Context,
        arch: []const u8,
    ) !dagger.Container {
        _ = self;

        const zig_version = "0.16.0";
        const target_option = if (std.mem.eql(u8, arch, "amd64")) "-Dtarget=x86_64-linux-musl" else "-Dtarget=aarch64-linux-musl";
        const source = try getSource(ctx);

        // Create a build container with Zig
        const base_ctr = try ctx.dag().container(null);
        const base = try base_ctr.from("kassany/alpine-ziglang:" ++ zig_version, null);

        // Mount source code to read-only path
        const base_with_dir = try base.withDirectory("/src-ro", (try source.id()).value, null, null, null, null, null, null);
        const src = try base_with_dir.withWorkdir("/src-ro", null);

        // Copy source to writable /tmp/build
        const prep = try src.withExec(&.{ "sh", "-c", "mkdir -p /tmp/build && cd /src-ro && tar cf - . | (cd /tmp/build && tar xf -) && rm -rf /tmp/build/.zig-cache /tmp/build/zig-out && echo copied" }, null, null, null, null, null, null, null, null, null, null);
        const build_src = try prep.withWorkdir("/tmp/build", null);

        // Build the project
        const build_run = try build_src.withExec(&.{
            "zig",
            "build",
            "-Doptimize=ReleaseFast",
            target_option,
        }, null, null, null, null, null, null, null, null, null, null);

        // Create Alpine-based container
        const alpine_ctr = try ctx.dag().container(null);
        const alpine = try alpine_ctr.from("alpine:3.20", null);

        // Copy binary
        const ctr = try alpine.withFile(
            "/usr/bin/shieldcn",
            (try (try build_run.file("./zig-out/bin/shieldcn", null)).id()).value,
            null,
            null,
            null,
        );

        // Install runtime dependencies
        const ctr2 = try ctr.withExec(&.{
            "apk",
            "add",
            "--no-cache",
            "freetype",
            "sqlite-libs",
        }, null, null, null, null, null, null, null, null, null, null);

        // Set entrypoint
        const ctr3 = try ctr2.withEntrypoint(&.{"/usr/bin/shieldcn"}, null);

        return ctr3;
    }
};

pub fn main(init: std.process.Init) !void {
    return dagger.module.serve(init, ShieldcnModule{});
}
