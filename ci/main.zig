const std = @import("std");
const dagger = @import("dagger_sdk");

/// shieldcn-zig — ci/main.zig
/// Dagger module for building, testing, and packaging the shieldcn server.
const zig_version = "0.16.0";
const base_image = "kassany/alpine-ziglang:" ++ zig_version;
const runtime_image = "alpine:3.20";

const ShieldcnModule = struct {
    /// Build the project for x86_64-linux-musl.
    pub fn build(
        self: *const ShieldcnModule,
        ctx: *dagger.module.Context,
    ) !dagger.Directory {
        _ = self;
        return buildForTarget(ctx, "x86_64-linux-musl");
    }

    /// Build the project for aarch64-linux-musl.
    pub fn buildAarch64(
        self: *const ShieldcnModule,
        ctx: *dagger.module.Context,
    ) !dagger.Directory {
        _ = self;
        return buildForTarget(ctx, "aarch64-linux-musl");
    }

    /// Run `zig build check` to validate compilation and tests.
    pub fn @"test"(
        self: *const ShieldcnModule,
        ctx: *dagger.module.Context,
    ) ![]const u8 {
        _ = self;
        const ctr = try buildContainer(ctx, null);
        _ = try ctr.sync();
        return "tests passed (check mode)";
    }

    /// Alias for `test` — kept for CI symmetry.
    pub fn lint(
        self: *const ShieldcnModule,
        ctx: *dagger.module.Context,
    ) ![]const u8 {
        _ = self;
        const ctr = try buildContainer(ctx, null);
        _ = try ctr.sync();
        return "lint passed";
    }

    /// Build a runnable Alpine container with the compiled binary.
    /// arch: "amd64" or "aarch64".
    pub fn container(
        self: *const ShieldcnModule,
        ctx: *dagger.module.Context,
        arch: []const u8,
    ) !dagger.Container {
        _ = self;
        const target = if (std.mem.eql(u8, arch, "amd64"))
            "x86_64-linux-musl"
        else if (std.mem.eql(u8, arch, "aarch64"))
            "aarch64-linux-musl"
        else
            return error.InvalidArch;

        const build_out = try buildForTarget(ctx, target);
        const binary = try (try build_out.file("./bin/shieldcn")).id();

        const alpine = try ctx.dag().container(null);
        const base = try alpine.from(runtime_image, null);

        const with_bin = try base.withFile(
            "/usr/bin/shieldcn",
            binary.value,
            null,
            null,
            null,
        );
        const with_deps = try with_bin.withExec(&.{
            "apk",
            "add",
            "--no-cache",
            "freetype",
            "sqlite-libs",
        }, null, null, null, null, null, null, null, null, null, null);
        const with_entry = try with_deps.withEntrypoint(&.{"/usr/bin/shieldcn"}, null);

        return with_entry;
    }
};

/// Build for a musl target and return the `zig-out` directory.
fn buildForTarget(ctx: *dagger.module.Context, target: []const u8) !dagger.Directory {
    const ctr = try buildContainer(ctx, target);
    const out = try ctr.directory("./zig-out", null);
    return out;
}

/// Return a container that has the source mounted and the build step executed.
/// Pass `null` for target to run `zig build check` instead.
fn buildContainer(ctx: *dagger.module.Context, target: ?[]const u8) !dagger.Container {
    const current_module = try ctx.dag().currentModule();
    const src = try current_module.source();
    const src_id = (try src.id()).value;

    const base_ctr = try ctx.dag().container(null);
    const base = try base_ctr.from(base_image, null);

    const with_src = try base.withDirectory("/src-ro", src_id, null, null, null, null, null, null);
    const workdir = try with_src.withWorkdir("/src-ro", null);

    const prep = try workdir.withExec(&.{
        "sh",
        "-c",
        "mkdir -p /tmp/build && cd /src-ro && tar cf - . | (cd /tmp/build && tar xf -) && rm -rf /tmp/build/zig-out && echo copied",
    }, null, null, null, null, null, null, null, null, null, null);
    const build_src = try prep.withWorkdir("/tmp/build", null);

    const args: []const []const u8 = if (target) |t| b: {
        const target_arg = try std.fmt.allocPrint(ctx.allocator(), "-Dtarget={s}", .{t});
        break :b &.{
            "zig",
            "build",
            "-Doptimize=ReleaseFast",
            target_arg,
        };
    } else &.{
        "zig",
        "build",
        "check",
    };

    return build_src.withExec(args, null, null, null, null, null, null, null, null, null, null);
}

pub fn main(init: std.process.Init) !void {
    return dagger.module.serve(init, ShieldcnModule{});
}
