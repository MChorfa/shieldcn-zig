//! Cache example: demonstrate CacheVolume usage for build acceleration.
//!
//! Run under a Dagger session:
//!
//!   dagger run -- zig build run-cache
//!
//! This example shows how to:
//!   - Create named cache volumes
//!   - Mount caches in containers
//!   - Share caches across pipeline runs
//!   - Use for package managers (npm, pip, cargo, etc.)

const std = @import("std");
const dagger = @import("dagger_sdk");

pub fn main(init: std.process.Init) !void {
    const gpa = init.gpa;
    const io = init.io;

    var client = try dagger.connect(gpa, io, .{});
    defer client.close();

    // Create a cache volume for npm packages
    const npm_cache = try client.dag().cacheVolume("npm-cache-v1", null, null, null);
    var npm_cache_id = try npm_cache.id();
    defer npm_cache_id.deinit(gpa);

    // Simulate a Node.js build with caching
    const ctr_raw = try client.dag().container(null);
    const ctr = try ctr_raw.from("node:20-alpine", null);

    // Mount the cache at npm's cache directory
    const ctr_with_cache = try ctr
        .withMountedCache("/root/.npm", npm_cache_id.value, null, null, null, null);

    // Add package.json (in real use, use withDirectory to copy source)
    const ctr_with_pkg = try ctr_with_cache
        .withExec(&.{ "sh", "-c", "echo '{\"name\": \"demo\", \"dependencies\": {\"lodash\": \"^4.17.21\"}}' > package.json" }, null, null, null, null, null, null, null, null, null, null);

    // Install dependencies - will use cache
    const ctr_install = try ctr_with_pkg
        .withExec(&.{ "npm", "install", "--prefer-offline" }, null, null, null, null, null, null, null, null, null, null);

    // Show cache hit information
    const ctr_info = try ctr_install
        .withExec(&.{ "sh", "-c", "du -sh /root/.npm && echo 'Cache contents:' && ls /root/.npm" }, null, null, null, null, null, null, null, null, null, null);
    const out = try ctr_info.stdout();
    defer gpa.free(out);

    var stdout_file = std.Io.File.stdout();
    defer stdout_file.close(io);
    try stdout_file.writeStreamingAll(io, out);

    std.log.info("Cache example complete. Next run will be faster!", .{});
}
