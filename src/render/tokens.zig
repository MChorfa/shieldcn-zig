const std = @import("std");
const hex = @import("../util/hex.zig");

/// shieldcn-zig — render/tokens.zig
/// Exact shadcn Button design tokens resolved to hex values.
/// Dark mode is default (README badges on dark backgrounds).

// ------------------------------------------------------------------
// Mode color palettes
// ------------------------------------------------------------------

pub const ModeColors = struct {
    primary: []const u8,
    primary_foreground: []const u8,
    secondary: []const u8,
    secondary_foreground: []const u8,
    destructive: []const u8,
    destructive_foreground: []const u8,
    accent: []const u8,
    accent_foreground: []const u8,
    background: []const u8,
    foreground: []const u8,
    border: []const u8,
    input: []const u8,
    muted: []const u8,
    muted_foreground: []const u8,
};

pub const dark_mode: ModeColors = .{
    .primary = "#fafafa",
    .primary_foreground = "#18181b",
    .secondary = "#27272a",
    .secondary_foreground = "#fafafa",
    .destructive = "#dc2626",
    .destructive_foreground = "#ffffff",
    .accent = "#27272a",
    .accent_foreground = "#fafafa",
    .background = "#09090b",
    .foreground = "#fafafa",
    .border = "#27272a",
    .input = "#27272a",
    .muted = "#27272a",
    .muted_foreground = "#a1a1aa",
};

pub const light_mode: ModeColors = .{
    .primary = "#18181b",
    .primary_foreground = "#fafafa",
    .secondary = "#f4f4f5",
    .secondary_foreground = "#18181b",
    .destructive = "#dc2626",
    .destructive_foreground = "#ffffff",
    .accent = "#f4f4f5",
    .accent_foreground = "#18181b",
    .background = "#fafafa",
    .foreground = "#18181b",
    .border = "#e4e4e7",
    .input = "#e4e4e7",
    .muted = "#f4f4f5",
    .muted_foreground = "#71717a",
};

// ------------------------------------------------------------------
// Button style: resolved bg/fg/border per variant
// ------------------------------------------------------------------

pub const ButtonStyle = struct {
    bg: []const u8,
    fg: []const u8,
    border: ?[]const u8,
    border_radius: u32,
};

/// Resolve button style from variant + mode.
/// For outline/ghost + custom color: label text uses mode-aware fg,
/// NOT the color-derived fg. Custom color is for border and value text only.
pub fn getButtonStyle(variant: []const u8, mode: []const u8, custom_color: ?[]const u8) ButtonStyle {
    const is_dark = std.mem.eql(u8, mode, "light") == false;
    const mc = if (is_dark) dark_mode else light_mode;

    const radius: u32 = 6;

    if (std.mem.eql(u8, variant, "default")) {
        return .{ .bg = mc.primary, .fg = mc.primary_foreground, .border = null, .border_radius = radius };
    } else if (std.mem.eql(u8, variant, "secondary")) {
        return .{ .bg = mc.secondary, .fg = mc.secondary_foreground, .border = null, .border_radius = radius };
    } else if (std.mem.eql(u8, variant, "outline")) {
        const border_col = if (custom_color) |cc| cc else mc.border;
        return .{ .bg = mc.background, .fg = mc.foreground, .border = border_col, .border_radius = radius };
    } else if (std.mem.eql(u8, variant, "ghost")) {
        return .{ .bg = "transparent", .fg = if (custom_color) |cc| cc else mc.foreground, .border = null, .border_radius = radius };
    } else if (std.mem.eql(u8, variant, "destructive")) {
        return .{ .bg = mc.destructive, .fg = mc.destructive_foreground, .border = null, .border_radius = radius };
    } else if (std.mem.eql(u8, variant, "branded")) {
        const brand = custom_color orelse mc.primary;
        const brand_rgb = hex.parseHex(brand) orelse hex.parseHex("#27272a").?;
        const is_light_brand = hex.isLight(brand_rgb);
        const brand_fg = if (is_light_brand) "#18181b" else "#ffffff";
        return .{ .bg = brand, .fg = brand_fg, .border = null, .border_radius = radius };
    }

    // fallback to default
    return .{ .bg = mc.primary, .fg = mc.primary_foreground, .border = null, .border_radius = radius };
}

// ------------------------------------------------------------------
// Status colors (green/amber/red for CI-style badges)
// ------------------------------------------------------------------

pub const status_colors = .{
    .green = "#22c55e",
    .amber = "#f59e0b",
    .red = "#ef4444",
};

// ------------------------------------------------------------------
// Tests
// ------------------------------------------------------------------

test "getButtonStyle default dark" {
    const style = getButtonStyle("default", "dark", null);
    try std.testing.expectEqualStrings("#fafafa", style.bg);
    try std.testing.expectEqualStrings("#18181b", style.fg);
}

test "getButtonStyle outline dark" {
    const style = getButtonStyle("outline", "dark", null);
    try std.testing.expectEqualStrings("#09090b", style.bg);
    try std.testing.expectEqualStrings("#fafafa", style.fg);
    try std.testing.expectEqualStrings("#27272a", style.border.?);
}

test "getButtonStyle branded with color" {
    const style = getButtonStyle("branded", "dark", "#ff6b6b");
    try std.testing.expectEqualStrings("#ff6b6b", style.bg);
    try std.testing.expectEqualStrings("#ffffff", style.fg);
}

test "getButtonStyle branded light color gets dark fg" {
    const style = getButtonStyle("branded", "dark", "#fafafa");
    try std.testing.expectEqualStrings("#fafafa", style.bg);
    try std.testing.expectEqualStrings("#18181b", style.fg);
}
