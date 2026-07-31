//! Build pipeline: demonstrates the full chain — base image, workdir, env,
//! cache volume, exec, stdout capture.

const std = @import("std");
const dagger = @import("dagger_sdk");

pub fn main(init: std.process.Init) !void {
    const gpa = init.gpa;
    const io = init.io;

    var client = try dagger.connect(gpa, io, .{});
    defer client.close();

    const q = client.dag();
    const cache = try q.cacheVolume("zig-global-cache", null, null, null);
    var cache_id = try cache.id();
    defer cache_id.deinit(gpa);

    const ctr = try q.container(null);
    const ctr2 = try ctr.from("alpine:3.20", null);
    const ctr3 = try ctr2.withWorkdir("/work", null);
    const ctr4 = try ctr3.withEnvVariable("HELLO", "from dagger-zig", null);
    const ctr5 = try ctr4.withMountedCache("/var/cache/zig", cache_id.value, null, null, null, null);
    const ctr6 = try ctr5.withExec(&.{ "sh", "-c", "echo ${HELLO}; date" }, null, null, null, null, null, null, null, null, null, null);

    const out = try ctr6.stdout();
    defer gpa.free(out);

    var stdout_file = std.Io.File.stdout();
    defer stdout_file.close(io);
    try stdout_file.writeStreamingAll(io, out);
}
