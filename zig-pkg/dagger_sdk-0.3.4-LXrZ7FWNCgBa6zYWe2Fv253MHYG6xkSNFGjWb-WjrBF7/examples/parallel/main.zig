//! Parallel pipelines across 5 base images, concurrently.
//!
//! This showcases a genuine Zig 0.16 advantage: `io.async` + `Io.Group`
//! lets us fan out N engine queries with zero threading boilerplate. In
//! `-fsingle-threaded` mode the Io backend schedules cooperatively; in
//! multi-threaded mode they run in parallel. Either way, user code is
//! identical.
//!
//! Each task gets its own `client.branch()` — sharing one client across
//! concurrent tasks would race on its per-query state. Branches reuse the
//! same engine session (no extra subprocess).
//!
//! If any one pipeline fails, `group.await` surfaces the first error; the
//! others are automatically cancelled by the defer-cancel pattern.
//!
//! Run:
//!
//!   dagger run -- zig build run-parallel

const std = @import("std");
const dagger = @import("dagger_sdk");

const Images = [_][]const u8{
    "alpine:3.20",
    "debian:bookworm-slim",
    "ubuntu:24.04",
    "fedora:41",
    "archlinux:latest",
};

const Result = struct {
    image: []const u8,
    output: []u8, // owned
};

fn fetchVersion(
    io: std.Io,
    client: *dagger.Client,
    image: []const u8,
    out: *Result,
) std.Io.Cancelable!void {
    _ = io;
    out.image = image;
    const ctr = client.dag().container(null) catch return error.Canceled;
    const ctr2 = ctr.from(image, null) catch return error.Canceled;
    const ctr3 = ctr2.withExec(&.{ "sh", "-c", "cat /etc/os-release | grep -E '^PRETTY_NAME' || uname -a" }, null, null, null, null, null, null, null, null, null, null) catch return error.Canceled;
    out.output = ctr3.stdout() catch return error.Canceled;
}

pub fn main(init: std.process.Init) !void {
    const gpa = init.gpa;
    const io = init.io;

    var client = try dagger.connect(gpa, io, .{});
    defer client.close();

    // One independent client per task. Sharing `client` across the concurrent
    // tasks below would race on its per-query state; branches share the engine
    // session but have their own. Each branch is closed on the way out.
    var branches: [Images.len]dagger.Client = undefined;
    var made: usize = 0;
    defer for (branches[0..made]) |*b| b.close();
    while (made < Images.len) : (made += 1) {
        branches[made] = try client.branch();
    }

    // Allocate one Result slot per image. The Group writes into these
    // concurrently; the indices are disjoint so no locking is needed.
    var results: [Images.len]Result = undefined;

    var group: std.Io.Group = .init;
    // defer-cancel: if any task fails or we return early, cancel every
    // outstanding task and free its resources.
    defer group.cancel(io);

    for (Images, 0..) |image, i| {
        group.async(io, fetchVersion, .{ io, &branches[i], image, &results[i] });
    }

    try group.await(io);

    // Now print the results. Freed as we go.
    var stdout_file = std.Io.File.stdout();
    defer stdout_file.close(io);
    for (&results) |*r| {
        defer gpa.free(r.output);
        const line = try std.fmt.allocPrint(gpa, "{s}:\n{s}\n---\n", .{ r.image, r.output });
        defer gpa.free(line);
        try stdout_file.writeStreamingAll(io, line);
    }
}
