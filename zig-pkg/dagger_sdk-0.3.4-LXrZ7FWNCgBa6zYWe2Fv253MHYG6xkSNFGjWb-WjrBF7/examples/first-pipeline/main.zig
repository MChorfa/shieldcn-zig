//! First pipeline: pull alpine, run echo hello, print stdout.
//!
//! Run under a Dagger session:
//!
//!   dagger run -- zig build run-first-pipeline
//!
//! …or, if DAGGER_SESSION_PORT is already set:
//!
//!   zig build run-first-pipeline

const std = @import("std");
const dagger = @import("dagger_sdk");

pub fn main(init: std.process.Init) !void {
    const gpa = init.gpa;
    const io = init.io;

    var client = try dagger.connect(gpa, io, .{});
    defer client.close();

    const ctr = try client.dag().container(null);
    const ctr1 = try ctr.from("alpine:latest", null);
    const ctr2 = try ctr1.withExec(&.{ "echo", "hello from zig" }, null, null, null, null, null, null, null, null, null, null);

    const out = try ctr2.stdout();
    defer gpa.free(out);

    // 0.16: std.Io.Writer based stdout; init.io gives us the process's stdout.
    var stdout_file = std.Io.File.stdout();
    defer stdout_file.close(io);
    try stdout_file.writeStreamingAll(io, out);
}
