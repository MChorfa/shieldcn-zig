const std = @import("std");
const dagger = @import("dagger_sdk");

/// shieldcn-zig — ci/main.zig
/// Dagger module for building, testing, and packaging the shieldcn server.
const zig_version = "0.16.0";
const base_image = "alpine:3.20";
const runtime_image = "alpine:3.20";

const ShieldcnModule = struct {
    /// Build the project for x86_64-linux-musl.
    pub fn build(
        self: *const ShieldcnModule,
        ctx: *dagger.module.Context,
        src: dagger.Directory,
    ) !dagger.Directory {
        _ = self;
        return buildForTarget(ctx, src, "x86_64-linux-musl");
    }

    /// Build the project for aarch64-linux-musl.
    pub fn buildAarch64(
        self: *const ShieldcnModule,
        ctx: *dagger.module.Context,
        src: dagger.Directory,
    ) !dagger.Directory {
        _ = self;
        return buildForTarget(ctx, src, "aarch64-linux-musl");
    }

    /// Run `zig build check` to validate compilation.
    pub fn lint(
        self: *const ShieldcnModule,
        ctx: *dagger.module.Context,
        src: dagger.Directory,
    ) ![]const u8 {
        _ = self;
        const ctr = try buildContainer(ctx, src, null);
        _ = try ctr.sync();
        return "lint passed";
    }

    /// Alias for `lint` — kept for CI symmetry.
    pub fn @"test"(
        self: *const ShieldcnModule,
        ctx: *dagger.module.Context,
        src: dagger.Directory,
    ) ![]const u8 {
        _ = self;
        const ctr = try buildContainer(ctx, src, null);
        _ = try ctr.sync();
        return "tests passed (check mode)";
    }

    /// Build a runnable Alpine container with the compiled binary.
    pub fn container(
        self: *const ShieldcnModule,
        ctx: *dagger.module.Context,
        src: dagger.Directory,
        arch: []const u8,
    ) !dagger.Container {
        _ = self;

        const target = if (std.mem.eql(u8, arch, "amd64"))
            "x86_64-linux-musl"
        else if (std.mem.eql(u8, arch, "aarch64"))
            "aarch64-linux-musl"
        else
            return error.InvalidArch;

        const build_out = try buildForTarget(ctx, src, target);
        const binary = try build_out.file("./bin/shieldcn");

        var base = try ctx.container();
        base = try base.from(runtime_image, null);
        base = try mountFile(base, "/usr/bin/shieldcn", binary);
        base = try exec(base, &.{
            "apk",
            "add",
            "--no-cache",
            "freetype",
            "sqlite-libs",
        });
        base = try base.withEntrypoint(&.{"/usr/bin/shieldcn"}, null);

        return base;
    }
};

fn exec(ctr: dagger.Container, args: []const []const u8) !dagger.Container {
    return ctr.withExec(args, null, null, null, null, null, null, null, null, null, null);
}

fn mountDir(ctr: dagger.Container, path: []const u8, dir: dagger.Directory) !dagger.Container {
    const dir_id = try dir.id();
    return ctr.withDirectory(path, dir_id.value, null, null, null, null, null, null);
}

fn mountFile(ctr: dagger.Container, path: []const u8, file: dagger.File) !dagger.Container {
    const file_id = try file.id();
    return ctr.withFile(path, file_id.value, null, null, null);
}

/// Build for a musl target and return the `zig-out` directory.
fn buildForTarget(
    ctx: *dagger.module.Context,
    src: dagger.Directory,
    target: []const u8,
) !dagger.Directory {
    const ctr = try buildContainer(ctx, src, target);
    return ctr.directory("./zig-out", null);
}

/// Return a container that has the source mounted and the build step executed.
/// Pass `null` for target to run `zig build check` instead.
fn buildContainer(
    ctx: *dagger.module.Context,
    src: dagger.Directory,
    target: ?[]const u8,
) !dagger.Container {
    var ctr = try ctx.container();
    ctr = try ctr.from(base_image, null);

    ctr = try exec(ctr, &.{
        "sh",
        "-c",
        "apk add --no-cache curl tar xz git ca-certificates && " ++
        "ARCH=$(uname -m) && " ++
        "if [ \"$ARCH\" = \"x86_64\" ]; then ZIG_ARCH=\"x86_64\"; " ++
        "elif [ \"$ARCH\" = \"aarch64\" ]; then ZIG_ARCH=\"aarch64\"; " ++
        "else echo \"Unsupported architecture: $ARCH\" && exit 1; " ++
        "fi && " ++
        "curl -L https://ziglang.org/download/" ++ zig_version ++ "/zig-${ZIG_ARCH}-linux-" ++ zig_version ++ ".tar.xz | tar -xJ -C /usr/local && " ++
        "ln -s /usr/local/zig-${ZIG_ARCH}-linux-" ++ zig_version ++ "/zig /usr/local/bin/zig && " ++
        "zig version",
    });

    ctr = try mountDir(ctr, "/src-ro", src);
    ctr = try ctr.withWorkdir("/src-ro", null);

    ctr = try exec(ctr, &.{
        "sh",
        "-c",
        "mkdir -p /tmp/build && cd /src-ro && tar cf - . | (cd /tmp/build && tar xf -) && rm -rf /tmp/build/zig-out && echo copied",
    });
    ctr = try ctr.withWorkdir("/tmp/build", null);

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

    return exec(ctr, args);
}

pub fn main(init: std.process.Init) !void {
    return dagger.module.serve(init, ShieldcnModule{});
}
