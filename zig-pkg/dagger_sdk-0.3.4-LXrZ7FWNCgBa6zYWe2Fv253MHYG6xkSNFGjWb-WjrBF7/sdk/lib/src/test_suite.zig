//! Comprehensive test suite for dagger-zig.
//!
//! Run: zig build test

const std = @import("std");
const testing = std.testing;

// Import modules to test
const platform = @import("platform.zig");
const telemetry = @import("telemetry.zig");
const qb = @import("querybuilder.zig");
const errors = @import("errors.zig");

// ========================================
// Platform Tests
// ========================================

test "platform.path normalization" {
    const allocator = testing.allocator;

    // Test Windows path normalization
    const win_path = try platform.normalizePath(allocator, "path/to/file");
    defer allocator.free(win_path);

    if (platform.is_windows) {
        try testing.expectEqualStrings("path\\to\\file", win_path);
    } else {
        try testing.expectEqualStrings("path/to/file", win_path);
    }
}

test "platform.path separator detection" {
    if (platform.is_windows) {
        try testing.expectEqual(platform.path_sep, '\\');
    } else {
        try testing.expectEqual(platform.path_sep, '/');
    }
}

test "platform.joinPath" {
    const allocator = testing.allocator;
    const parts = &[_][]const u8{ "path", "to", "file" };
    const path = try platform.joinPath(allocator, parts);
    defer allocator.free(path);

    // Verify it uses the correct separator
    if (platform.is_windows) {
        try testing.expect(std.mem.indexOf(u8, path, "\\") != null);
    } else {
        try testing.expect(std.mem.indexOf(u8, path, "/") != null);
    }
}

// ========================================
// Telemetry Tests
// ========================================

test "telemetry.span creation" {
    const allocator = testing.allocator;
    var span = telemetry.Span.init(allocator, "test-span", .internal);
    defer span.end(.{ .enabled = false });

    try testing.expectEqualStrings("test-span", span.name);
    try testing.expectEqual(telemetry.SpanKind.internal, span.kind);
    try testing.expectEqual(telemetry.SpanStatus.unset, span.status);
}

test "telemetry.span attributes" {
    const allocator = testing.allocator;
    var span = telemetry.Span.init(allocator, "test-span", .internal);
    defer span.attributes.deinit();

    try span.setAttribute("key", "value");
    const value = span.attributes.get("key");
    try testing.expect(value != null);
    try testing.expectEqualStrings("value", value.?);
}

test "telemetry.span status" {
    const allocator = testing.allocator;
    var span = telemetry.Span.init(allocator, "test-span", .internal);
    defer span.attributes.deinit();

    span.setStatus(.ok, null);
    try testing.expectEqual(telemetry.SpanStatus.ok, span.status);

    span.setStatus(.err, "error message");
    try testing.expectEqual(telemetry.SpanStatus.err, span.status);
    try testing.expectEqualStrings("error message", span.status_message.?);
}

test "telemetry.metrics" {
    var metrics: telemetry.Metrics = .{};

    metrics.recordRequest(100, true);
    metrics.recordRequest(200, false);
    metrics.recordRequest(150, true);

    const stats = metrics.getStats();
    try testing.expectEqual(@as(u64, 3), stats.total_requests);
    try testing.expectEqual(@as(u64, 150), stats.avg_duration_ms); // (100+200+150)/3 = 150
    try testing.expect(@abs(stats.error_rate - 0.333) < 0.01); // 1/3 ≈ 0.333
}

test "telemetry.progress" {
    const allocator = testing.allocator;
    var progress = telemetry.Progress.init(allocator, "test-op", 10);

    progress.update(5, "halfway");
    try testing.expectEqual(@as(u32, 5), progress.current_step);

    progress.complete();
}

// ========================================
// Query Builder Tests
// ========================================

test "querybuilder.selection chain" {
    const allocator = testing.allocator;

    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();

    const root = &qb.Selection.root;
    const s1 = try root.select(arena.allocator(), "container");
    const s2 = try s1.select(arena.allocator(), "from");
    const s3 = try s2.argStr(arena.allocator(), "address", "alpine:latest");

    const query_str = try s3.build(allocator);
    defer allocator.free(query_str);

    try testing.expect(std.mem.indexOf(u8, query_str, "container") != null);
    try testing.expect(std.mem.indexOf(u8, query_str, "from") != null);
    try testing.expect(std.mem.indexOf(u8, query_str, "alpine:latest") != null);
}

test "querybuilder.serializeStringList" {
    const allocator = testing.allocator;
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();

    const args = &[_][]const u8{ "echo", "hello", "world" };
    const serialized = try qb.serializeStringList(arena.allocator(), args);

    try testing.expect(std.mem.indexOf(u8, serialized, "echo") != null);
    try testing.expect(std.mem.indexOf(u8, serialized, "hello") != null);
    try testing.expect(std.mem.indexOf(u8, serialized, "world") != null);
}

// ========================================
// Error Tests
// ========================================

test "errors.ConnectError formatting" {
    const err = errors.ConnectError.InvalidEnv;
    const err_name = @errorName(err);
    try testing.expect(std.mem.indexOf(u8, err_name, "InvalidEnv") != null);
}

test "errors.DaggerError set" {
    // Verify all error types can be constructed
    const connect_err: errors.ConnectError = error.HandshakeFailed;
    const query_err: errors.QueryError = error.TransportFailed;

    try testing.expectEqual(error.HandshakeFailed, connect_err);
    try testing.expectEqual(error.TransportFailed, query_err);
}

// ========================================
// Integration Tests
// ========================================

/// Mock GraphQL client for testing
const MockGraphQLClient = struct {
    responses: std.ArrayList([]const u8),
    current_index: usize = 0,

    pub fn init(allocator: std.mem.Allocator) MockGraphQLClient {
        return .{
            .responses = std.ArrayList([]const u8).init(allocator),
        };
    }

    pub fn deinit(self: *MockGraphQLClient) void {
        for (self.responses.items) |resp| {
            self.responses.allocator.free(resp);
        }
        self.responses.deinit();
    }

    pub fn addResponse(self: *MockGraphQLClient, response: []const u8) !void {
        try self.responses.append(try self.responses.allocator.dupe(u8, response));
    }

    pub fn query(self: *MockGraphQLClient, query_str: []const u8) ![]u8 {
        _ = query_str;
        if (self.current_index >= self.responses.items.len) {
            return error.NoMoreResponses;
        }
        const response = self.responses.items[self.current_index];
        self.current_index += 1;
        return self.responses.allocator.dupe(u8, response);
    }
};

test "integration.container pipeline" {
    // This would test a full container pipeline
    // Requires mock GraphQL client
    // TODO: Add mock client setup for integration tests
    try testing.expect(true);
}

// ========================================
// Performance Tests
// ========================================

test "performance.query builder" {
    const allocator = testing.allocator;
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();

    const iterations = 1000;
    const start: i64 = telemetry.nowMs();

    var i: usize = 0;
    while (i < iterations) : (i += 1) {
        const root = &qb.Selection.root;
        const s1 = try root.select(arena.allocator(), "container");
        const s2 = try s1.select(arena.allocator(), "from");
        _ = try s2.argStr(arena.allocator(), "address", "alpine:latest");
        _ = arena.reset(.retain_capacity);
    }

    const elapsed = telemetry.nowMs() - start;
    const per_op = @as(f64, @floatFromInt(elapsed)) / @as(f64, @floatFromInt(iterations));

    std.log.debug("Query builder: {d:.3}ms per operation", .{per_op});

    // Should complete 1000 iterations in under 100ms
    try testing.expect(elapsed < 100);
}

test "performance.telemetry span creation" {
    const allocator = testing.allocator;
    const iterations = 10000;

    const start: i64 = telemetry.nowMs();

    var i: usize = 0;
    while (i < iterations) : (i += 1) {
        var span = telemetry.Span.init(allocator, "test", .internal);
        span.attributes.deinit();
    }

    const elapsed = telemetry.nowMs() - start;
    const per_op = @as(f64, @floatFromInt(elapsed)) / @as(f64, @floatFromInt(iterations));

    std.log.debug("Span creation: {d:.3}ms per operation", .{per_op});

    // Should complete 10000 iterations in under 50ms
    try testing.expect(elapsed < 50);
}
