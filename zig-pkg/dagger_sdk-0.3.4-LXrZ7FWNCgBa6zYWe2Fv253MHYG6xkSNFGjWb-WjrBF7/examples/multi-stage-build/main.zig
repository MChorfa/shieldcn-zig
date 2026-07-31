//! Multi-stage build example: demonstrate Docker multi-stage equivalent.
//!
//! Run under a Dagger session:
//!
//!   dagger run -- zig build run-multi-stage-build
//!
//! This example shows how to:
//!   - Build in one container (build stage)
//!   - Copy artifacts to another (runtime stage)
//!   - Minimize final image size
//!   - Separate build and runtime dependencies

const std = @import("std");
const dagger = @import("dagger_sdk");

pub fn main(init: std.process.Init) !void {
    const gpa = init.gpa;
    const io = init.io;

    var client = try dagger.connect(gpa, io, .{});
    defer client.close();

    // Stage 1: Build environment
    const build_ctr_raw = try client.dag().container(null);
    const build_ctr = try build_ctr_raw.from("golang:1.22-alpine", null);

    // Add build dependencies
    const build_with_deps = try build_ctr
        .withExec(&.{ "apk", "add", "--no-cache", "git" }, null, null, null, null, null, null, null, null, null, null);

    // Simulate a Go build (creating a simple binary)
    const build_with_code = try build_with_deps
        .withExec(&.{ "sh", "-c", "mkdir -p /src && echo 'package main; import \"fmt\"; func main() { fmt.Println(\"Hello from multi-stage!\") }' > /src/main.go" }, null, null, null, null, null, null, null, null, null, null);

    // Build the binary
    const build_wd = try build_with_code.withWorkdir("/src", null);
    const build_output = try build_wd.withExec(&.{ "go", "build", "-o", "app", "main.go" }, null, null, null, null, null, null, null, null, null, null);

    // Export the binary
    const binary = try build_output.file("/src/app", null);
    var binary_id = try binary.id();
    defer binary_id.deinit(gpa);

    // Stage 2: Runtime environment (minimal)
    const runtime_ctr_raw = try client.dag().container(null);
    const runtime_ctr = try runtime_ctr_raw.from("alpine:latest", null);

    // Only copy the binary, not the full Go toolchain
    const runtime_with_app = try runtime_ctr
        .withFile("/app", binary_id.value, null, null, null);

    // Make it executable and run
    const final = try runtime_with_app
        .withExec(&.{ "chmod", "+x", "/app" }, null, null, null, null, null, null, null, null, null, null);

    // Test the application
    const final_test = try final.withExec(&.{"/app"}, null, null, null, null, null, null, null, null, null, null);
    const out = try final_test.stdout();
    defer gpa.free(out);

    // Show size comparison
    const size_check = try final.withExec(&.{ "sh", "-c", "echo 'Final image size:' && du -sh / | tail -1" }, null, null, null, null, null, null, null, null, null, null);
    const size_info = try size_check.stdout();
    defer gpa.free(size_info);

    var stdout_file = std.Io.File.stdout();
    defer stdout_file.close(io);

    try stdout_file.writeStreamingAll(io, "=== Application Output ===\n");
    try stdout_file.writeStreamingAll(io, out);
    try stdout_file.writeStreamingAll(io, "\n=== Size Info ===\n");
    try stdout_file.writeStreamingAll(io, size_info);

    std.log.info("Multi-stage build complete! Final image contains only the binary.", .{});
}
