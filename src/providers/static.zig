const std = @import("std");
const types = @import("../core/types.zig");

/// shieldcn-zig — providers/static.zig
/// Static badge: /badge/{label}-{message}-{color}.svg
/// Shields.io-compatible URL pattern.
pub fn parseStaticBadge(allocator: std.mem.Allocator, segments: [][]const u8) !types.BadgeData {
    if (segments.len < 2) return error.InvalidPath;

    const content = segments[1];

    const last_dash = std.mem.lastIndexOfScalar(u8, content, '-') orelse {
        return types.BadgeData{ .label = "badge", .value = "invalid" };
    };

    const second_last_dash = std.mem.lastIndexOfScalar(u8, content[0..last_dash], '-') orelse {
        return types.BadgeData{ .label = "badge", .value = "invalid" };
    };

    const label = content[0..second_last_dash];
    const message = content[second_last_dash + 1 .. last_dash];
    const color = content[last_dash + 1 ..];

    return types.BadgeData{
        .label = try replaceUnderscoresAlloc(allocator, label),
        .value = try replaceUnderscoresAlloc(allocator, message),
        .color = try allocator.dupe(u8, color),
    };
}

fn replaceUnderscoresAlloc(allocator: std.mem.Allocator, input: []const u8) ![]const u8 {
    const out = try allocator.alloc(u8, input.len);
    for (input, 0..) |c, i| {
        out[i] = if (c == '_') ' ' else c;
    }
    return out;
}

// ------------------------------------------------------------------
// Tests
// ------------------------------------------------------------------

test "parseStaticBadge basic" {
    const allocator = std.testing.allocator;
    var segs = [_][]const u8{ "badge", "build-passing-green" };
    const data = try parseStaticBadge(allocator, &segs);
    defer allocator.free(data.label);
    defer allocator.free(data.value);
    defer allocator.free(data.color.?);
    try std.testing.expectEqualStrings("build", data.label);
    try std.testing.expectEqualStrings("passing", data.value);
    try std.testing.expectEqualStrings("green", data.color.?);
}

test "parseStaticBadge with underscores" {
    const allocator = std.testing.allocator;
    var segs = [_][]const u8{ "badge", "hello_world-message_here-blue" };
    const data = try parseStaticBadge(allocator, &segs);
    defer allocator.free(data.label);
    defer allocator.free(data.value);
    defer allocator.free(data.color.?);
    try std.testing.expectEqualStrings("hello world", data.label);
    try std.testing.expectEqualStrings("message here", data.value);
}
