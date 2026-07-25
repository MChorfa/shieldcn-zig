const std = @import("std");

/// shieldcn-zig — util/format.zig
/// Number formatting: 1,200 → 1.2k, 45,000,000 → 45M, etc.
pub fn formatCount(n: u64, buf: []u8) []const u8 {
    if (n >= 1_000_000_000) {
        return formatWithSuffix(n, 1_000_000_000, "B", buf);
    } else if (n >= 1_000_000) {
        return formatWithSuffix(n, 1_000_000, "M", buf);
    } else if (n >= 1_000) {
        return formatWithSuffix(n, 1_000, "k", buf);
    }
    return std.fmt.bufPrint(buf, "{d}", .{n}) catch unreachable;
}

fn formatWithSuffix(n: u64, div: u64, suffix: []const u8, buf: []u8) []const u8 {
    const val = @as(f64, @floatFromInt(n)) / @as(f64, @floatFromInt(div));
    return if (val == @round(val))
        std.fmt.bufPrint(buf, "{d:.0}{s}", .{ @as(u64, @intFromFloat(val)), suffix }) catch unreachable
    else
        std.fmt.bufPrint(buf, "{d:.1}{s}", .{ val, suffix }) catch unreachable;
}

// ------------------------------------------------------------------
// Tests
// ------------------------------------------------------------------

test "formatCount small" {
    var buf: [32]u8 = undefined;
    const s = formatCount(42, &buf);
    try std.testing.expectEqualStrings("42", s);
}

test "formatCount kilo" {
    var buf: [32]u8 = undefined;
    const s = formatCount(1_200, &buf);
    try std.testing.expectEqualStrings("1.2k", s);
}

test "formatCount mega" {
    var buf: [32]u8 = undefined;
    const s = formatCount(45_000_000, &buf);
    try std.testing.expectEqualStrings("45M", s);
}

test "formatCount giga" {
    var buf: [32]u8 = undefined;
    const s = formatCount(3_500_000_000, &buf);
    try std.testing.expectEqualStrings("3.5B", s);
}

test "formatCount exact kilo" {
    var buf: [32]u8 = undefined;
    const s = formatCount(5_000, &buf);
    try std.testing.expectEqualStrings("5k", s);
}
