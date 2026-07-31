const std = @import("std");

/// shieldcn-zig — util/hex.zig
/// Hex color parsing, luminance, contrast, and manipulation.

// ------------------------------------------------------------------
// RGB struct
// ------------------------------------------------------------------

pub const Rgb = struct {
    r: u8,
    g: u8,
    b: u8,

    pub fn toHex(self: Rgb, buf: []u8) []const u8 {
        std.debug.assert(buf.len >= 7);
        _ = std.fmt.bufPrint(buf, "#{x:0>2}{x:0>2}{x:0>2}", .{ self.r, self.g, self.b }) catch unreachable;
        return buf[0..7];
    }
};

// ------------------------------------------------------------------
// Parse hex color (with or without #)
// ------------------------------------------------------------------

pub fn parseHex(hex_str: []const u8) ?Rgb {
    const h = if (hex_str.len > 0 and hex_str[0] == '#') hex_str[1..] else hex_str;
    if (h.len == 6) {
        const r = std.fmt.parseInt(u8, h[0..2], 16) catch return null;
        const g = std.fmt.parseInt(u8, h[2..4], 16) catch return null;
        const b = std.fmt.parseInt(u8, h[4..6], 16) catch return null;
        return .{ .r = r, .g = g, .b = b };
    }
    if (h.len == 3) {
        // Expand 3-digit hex: #4c1 -> #44cc11
        const r = std.fmt.parseInt(u4, h[0..1], 16) catch return null;
        const g = std.fmt.parseInt(u4, h[1..2], 16) catch return null;
        const b = std.fmt.parseInt(u4, h[2..3], 16) catch return null;
        return .{ .r = @as(u8, r) * 17, .g = @as(u8, g) * 17, .b = @as(u8, b) * 17 };
    }
    return null;
}

// ------------------------------------------------------------------
// Luminance (0 = black, 1 = white)
// ------------------------------------------------------------------

pub fn luminance(rgb: Rgb) f32 {
    const rf = @as(f32, @floatFromInt(rgb.r)) / 255.0;
    const gf = @as(f32, @floatFromInt(rgb.g)) / 255.0;
    const bf = @as(f32, @floatFromInt(rgb.b)) / 255.0;
    return 0.299 * rf + 0.587 * gf + 0.114 * bf;
}

// ------------------------------------------------------------------
// Is light color? (threshold 0.6)
// ------------------------------------------------------------------

pub fn isLight(rgb: Rgb) bool {
    return luminance(rgb) > 0.6;
}

// ------------------------------------------------------------------
// Darken a color by mixing toward black
// amount: 0 = unchanged, 1 = fully black
// ------------------------------------------------------------------

pub fn darken(rgb: Rgb, amount: f32) Rgb {
    const clamped = std.math.clamp(amount, 0.0, 1.0);
    const factor = 1.0 - clamped;
    return .{
        .r = @intFromFloat(@round(@as(f32, @floatFromInt(rgb.r)) * factor)),
        .g = @intFromFloat(@round(@as(f32, @floatFromInt(rgb.g)) * factor)),
        .b = @intFromFloat(@round(@as(f32, @floatFromInt(rgb.b)) * factor)),
    };
}

// ------------------------------------------------------------------
// Ensure light-mode contrast: darken colors that are too light
// ------------------------------------------------------------------

pub fn ensureLightModeContrast(rgb: Rgb) Rgb {
    if (!isLight(rgb)) return rgb;
    return darken(rgb, 0.35);
}

// ------------------------------------------------------------------
// Gradient foreground: average luminance across stops
// ------------------------------------------------------------------

pub fn gradientFg(gradient_stops: []const Rgb) []const u8 {
    if (gradient_stops.len == 0) return "#ffffff";
    var total: f32 = 0;
    for (gradient_stops) |stop| {
        total += luminance(stop);
    }
    const avg = total / @as(f32, @floatFromInt(gradient_stops.len));
    return if (avg > 0.7) "#18181b" else "#ffffff";
}

// ------------------------------------------------------------------
// Tests
// ------------------------------------------------------------------

test "parseHex valid" {
    const rgb = parseHex("#27272a").?;
    try std.testing.expectEqual(@as(u8, 39), rgb.r);
    try std.testing.expectEqual(@as(u8, 39), rgb.g);
    try std.testing.expectEqual(@as(u8, 42), rgb.b);
}

test "parseHex without hash" {
    const rgb = parseHex("fafafa").?;
    try std.testing.expectEqual(@as(u8, 250), rgb.r);
}

test "parseHex invalid" {
    try std.testing.expectEqual(null, parseHex("zzz"));
    try std.testing.expectEqual(null, parseHex("#gggggg"));
}

test "luminance" {
    const white = parseHex("#ffffff").?;
    const black = parseHex("#000000").?;
    try std.testing.expect(luminance(white) > 0.99);
    try std.testing.expect(luminance(black) < 0.01);
}

test "isLight threshold" {
    try std.testing.expect(isLight(parseHex("#fafafa").?));
    try std.testing.expect(!isLight(parseHex("#18181b").?));
}

test "darken" {
    const red = parseHex("#ff0000").?;
    const dark_red = darken(red, 0.5);
    try std.testing.expectEqual(@as(u8, 128), dark_red.r);
    try std.testing.expectEqual(@as(u8, 0), dark_red.g);
}

test "Rgb.toHex" {
    var buf: [8]u8 = undefined;
    const hex = (Rgb{ .r = 39, .g = 39, .b = 42 }).toHex(&buf);
    try std.testing.expectEqualStrings("#27272a", hex);
}
