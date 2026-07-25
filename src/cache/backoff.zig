const std = @import("std");

/// shieldcn-zig — cache/backoff.zig
/// Per-provider exponential backoff for rate-limited upstreams.
const MAX_BACKOFF_MS = 5 * 60 * 1000; // 5 minutes

fn nowMillis() i64 {
    var tv: std.c.timeval = undefined;
    _ = std.c.gettimeofday(&tv, null);
    return @as(i64, tv.sec) * 1000 + @divTrunc(@as(i64, tv.usec), 1000);
}

pub const BackoffState = struct {
    until: i64,
    count: u32,
};

var backoff_map: std.StringHashMap(BackoffState) = undefined;
var gpa: std.mem.Allocator = undefined;
var initialized = false;

pub fn init(allocator: std.mem.Allocator) void {
    if (initialized) return;
    gpa = allocator;
    backoff_map = std.StringHashMap(BackoffState).init(allocator);
    initialized = true;
}

pub fn deinit() void {
    if (!initialized) return;
    backoff_map.deinit();
    initialized = false;
}

/// Check if a provider is currently in backoff.
pub fn isBackedOff(provider: []const u8) bool {
    if (!initialized) return false;
    const state = backoff_map.get(provider) orelse return false;
    if (nowMillis() >= state.until) {
        _ = backoff_map.remove(provider);
        return false;
    }
    return true;
}

/// Record a rate limit or server error. Exponential backoff: 15s, 30s, 60s, 120s, 300s.
pub fn recordBackoff(provider: []const u8) void {
    if (!initialized) return;
    const state = backoff_map.get(provider);
    const count = if (state) |s| s.count + 1 else 1;
    const delay = @min(15000 * std.math.pow(u64, 2, count - 1), MAX_BACKOFF_MS);
    backoff_map.put(provider, .{
        .until = nowMillis() + @as(i64, @intCast(delay)),
        .count = count,
    }) catch {};
}

/// Clear backoff on successful request.
pub fn clearBackoff(provider: []const u8) void {
    if (!initialized) return;
    _ = backoff_map.remove(provider);
}

// ------------------------------------------------------------------
// Tests
// ------------------------------------------------------------------

test "backoff lifecycle" {
    init(std.testing.allocator);
    defer deinit();

    try std.testing.expect(!isBackedOff("npm"));
    recordBackoff("npm");
    try std.testing.expect(isBackedOff("npm"));
    clearBackoff("npm");
    try std.testing.expect(!isBackedOff("npm"));
}
