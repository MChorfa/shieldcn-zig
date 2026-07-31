//! Service containers example: demonstrate database + app integration.
//!
//! Run under a Dagger session:
//!
//!   dagger run -- zig build run-service-containers
//!
//! This example shows how to:
//!   - Start a service container (Redis database)
//!   - Connect your app to the service
//!   - Use service bindings in pipelines
//!   - Test against real dependencies

const std = @import("std");
const dagger = @import("dagger_sdk");

pub fn main(init: std.process.Init) !void {
    const gpa = init.gpa;
    const io = init.io;

    var client = try dagger.connect(gpa, io, .{});
    defer client.close();

    // Start Redis as a service
    const redis_ctr = try client.dag().container(null);
    const redis_from = try redis_ctr.from("redis:7-alpine", null);
    const redis = try redis_from.withExposedPort(6379, null, null, null);

    // Convert to service and start
    const redis_svc = try redis.asService(null, null, null, null, null, null);
    _ = try redis_svc.up(null, null);

    // Get the service endpoint
    const redis_endpoint = try redis_svc.endpoint(null, null);
    defer gpa.free(redis_endpoint);

    std.log.info("Redis service started at: {s}", .{redis_endpoint});

    // Build an app container that uses Redis
    const app_ctr_raw = try client.dag().container(null);
    const app_ctr = try app_ctr_raw.from("alpine:latest", null);

    // Install redis-cli and test connectivity
    const app_with_tools = try app_ctr
        .withExec(&.{ "apk", "add", "--no-cache", "redis" }, null, null, null, null, null, null, null, null, null, null);

    // Set a value in Redis
    const app_set = try app_with_tools
        .withExec(&.{ "sh", "-c", std.fmt.allocPrint(gpa, "redis-cli -h {s} SET test_key 'hello from dagger-zig'", .{redis_endpoint}) catch unreachable }, null, null, null, null, null, null, null, null, null, null);

    // Get the value back
    const app_get = try app_set
        .withExec(&.{ "sh", "-c", std.fmt.allocPrint(gpa, "redis-cli -h {s} GET test_key", .{redis_endpoint}) catch unreachable }, null, null, null, null, null, null, null, null, null, null);

    const result = try app_get.stdout();
    defer gpa.free(result);

    var stdout_file = std.Io.File.stdout();
    defer stdout_file.close(io);

    try stdout_file.writeStreamingAll(io, "=== Redis Test Result ===\n");
    try stdout_file.writeStreamingAll(io, result);

    std.log.info("Service container example complete!", .{});
}
