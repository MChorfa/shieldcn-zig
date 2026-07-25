const std = @import("std");
const types = @import("../core/types.zig");
const tokens = @import("tokens.zig");
const hex_util = @import("../util/hex.zig");
const contrast = @import("../util/contrast.zig");

/// shieldcn-zig — render/themes.zig
/// Comprehensive theme system: built-in (dark/light/high-contrast) +
/// enterprise/custom themes with WCAG 3.0 contrast validation.
///
/// Every badge goes through resolve() → one render function.

// ------------------------------------------------------------------
// Theme definition
// ------------------------------------------------------------------

pub const ThemeName = enum {
    dark,
    light,
    high_contrast,
    enterprise,
    custom,

    pub fn fromString(str: []const u8) ?ThemeName {
        if (std.mem.eql(u8, str, "dark")) return .dark;
        if (std.mem.eql(u8, str, "light")) return .light;
        if (std.mem.eql(u8, str, "high-contrast")) return .high_contrast;
        if (std.mem.eql(u8, str, "highcontrast")) return .high_contrast;
        if (std.mem.eql(u8, str, "enterprise")) return .enterprise;
        if (std.mem.eql(u8, str, "custom")) return .custom;
        return null;
    }
};

/// A full color palette for a theme.
/// Enterprise/custom themes can override any subset of these.
pub const ThemePalette = struct {
    primary: []const u8 = "#fafafa",
    primary_foreground: []const u8 = "#18181b",
    secondary: []const u8 = "#27272a",
    secondary_foreground: []const u8 = "#fafafa",
    destructive: []const u8 = "#dc2626",
    destructive_foreground: []const u8 = "#ffffff",
    accent: []const u8 = "#27272a",
    accent_foreground: []const u8 = "#fafafa",
    background: []const u8 = "#09090b",
    foreground: []const u8 = "#fafafa",
    border: []const u8 = "#27272a",
    input: []const u8 = "#27272a",
    muted: []const u8 = "#27272a",
    muted_foreground: []const u8 = "#a1a1aa",
};

// ------------------------------------------------------------------
// Built-in themes
// ------------------------------------------------------------------

pub const dark_theme: ThemePalette = .{
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

pub const light_theme: ThemePalette = .{
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

/// High-contrast theme: WCAG AAA compliant for all combinations.
/// Uses pure black/white extremes and saturated accents.
pub const high_contrast_theme: ThemePalette = .{
    .primary = "#ffffff",
    .primary_foreground = "#000000",
    .secondary = "#000000",
    .secondary_foreground = "#ffffff",
    .destructive = "#990000",
    .destructive_foreground = "#ffffff",
    .accent = "#ffff00",
    .accent_foreground = "#000000",
    .background = "#000000",
    .foreground = "#ffffff",
    .border = "#ffffff",
    .input = "#ffffff",
    .muted = "#333333",
    .muted_foreground = "#ffffff",
};

fn getPalette(theme: ThemeName) ThemePalette {
    return switch (theme) {
        .dark => dark_theme,
        .light => light_theme,
        .high_contrast => high_contrast_theme,
        .enterprise, .custom => dark_theme, // base; caller merges overrides
    };
}

// ------------------------------------------------------------------
// Enterprise theme builder
// ------------------------------------------------------------------

pub const EnterpriseOverrides = struct {
    primary: ?[]const u8 = null,
    primary_foreground: ?[]const u8 = null,
    secondary: ?[]const u8 = null,
    secondary_foreground: ?[]const u8 = null,
    destructive: ?[]const u8 = null,
    destructive_foreground: ?[]const u8 = null,
    accent: ?[]const u8 = null,
    accent_foreground: ?[]const u8 = null,
    background: ?[]const u8 = null,
    foreground: ?[]const u8 = null,
    border: ?[]const u8 = null,
    input: ?[]const u8 = null,
    muted: ?[]const u8 = null,
    muted_foreground: ?[]const u8 = null,
};

/// Merge enterprise overrides onto a base palette.
pub fn buildEnterpriseTheme(base: ThemePalette, overrides: EnterpriseOverrides) ThemePalette {
    return .{
        .primary = overrides.primary orelse base.primary,
        .primary_foreground = overrides.primary_foreground orelse base.primary_foreground,
        .secondary = overrides.secondary orelse base.secondary,
        .secondary_foreground = overrides.secondary_foreground orelse base.secondary_foreground,
        .destructive = overrides.destructive orelse base.destructive,
        .destructive_foreground = overrides.destructive_foreground orelse base.destructive_foreground,
        .accent = overrides.accent orelse base.accent,
        .accent_foreground = overrides.accent_foreground orelse base.accent_foreground,
        .background = overrides.background orelse base.background,
        .foreground = overrides.foreground orelse base.foreground,
        .border = overrides.border orelse base.border,
        .input = overrides.input orelse base.input,
        .muted = overrides.muted orelse base.muted,
        .muted_foreground = overrides.muted_foreground orelse base.muted_foreground,
    };
}

// ------------------------------------------------------------------
// WCAG 3.0 / contrast validation
// ------------------------------------------------------------------

/// Validate that all foreground/background pairs in a palette meet
/// the given WCAG 2.1 level. Returns the first failing pair, or null if all pass.
pub fn validatePalette(palette: ThemePalette, level: contrast.WcagLevel) ?[]const u8 {
    if (checkPair(palette.primary, palette.primary_foreground, level)) return "primary";
    if (checkPair(palette.secondary, palette.secondary_foreground, level)) return "secondary";
    if (checkPair(palette.destructive, palette.destructive_foreground, level)) return "destructive";
    if (checkPair(palette.accent, palette.accent_foreground, level)) return "accent";
    if (checkPair(palette.background, palette.foreground, level)) return "background/foreground";
    return null;
}

fn checkPair(bg_hex: []const u8, fg_hex: []const u8, level: contrast.WcagLevel) bool {
    const bg = hex_util.parseHex(bg_hex) orelse return false;
    const fg = hex_util.parseHex(fg_hex) orelse return false;
    return !contrast.meetsLevel(bg, fg, level);
}

/// Auto-correct a palette to meet WCAG AA by adjusting foreground colors.
/// Mutates the palette in-place.
pub fn autoCorrectPalette(palette: *ThemePalette) void {
    correctFg(&palette.primary_foreground, palette.primary);
    correctFg(&palette.secondary_foreground, palette.secondary);
    correctFg(&palette.destructive_foreground, palette.destructive);
    correctFg(&palette.accent_foreground, palette.accent);
    correctFg(&palette.foreground, palette.background);
}

fn correctFg(fg_ptr: *[]const u8, bg_hex: []const u8) void {
    const bg = hex_util.parseHex(bg_hex) orelse return;
    const fg = hex_util.parseHex(fg_ptr.*) orelse return;
    if (!contrast.meetsLevel(bg, fg, .aa_normal)) {
        fg_ptr.* = contrast.autoForeground(bg);
    }
}

// ------------------------------------------------------------------
// Resolve badge colors
// ------------------------------------------------------------------

pub fn resolveTheme(
    variant: types.BadgeStyle,
    mode: types.ColorMode,
    theme_name: ?[]const u8,
    color_override: ?[]const u8,
    label_color_override: ?[]const u8,
    value_color_override: ?[]const u8,
) types.ResolvedColors {
    const theme: ThemeName = if (theme_name) |t|
        ThemeName.fromString(t) orelse .dark
    else switch (mode) {
        .dark => .dark,
        .light => .light,
    };
    const palette = getPalette(theme);

    // Branded variant: use explicit color or brand color
    const custom_hex = if (variant == .branded) color_override else null;

    const style = resolveButtonStyle(variant, &palette, custom_hex);

    var result: types.ResolvedColors = .{
        .label_bg = style.bg,
        .label_fg = label_color_override orelse style.fg,
        .value_bg = style.bg,
        .value_fg = value_color_override orelse style.fg,
        .border = style.border,
    };

    // For outline variant, ensure bg is the mode background
    if (variant == .outline) {
        result.label_bg = palette.background;
        result.value_bg = palette.background;
    }

    // For ghost variant, transparent background
    if (variant == .ghost) {
        result.label_bg = "transparent";
        result.value_bg = "transparent";
    }

    // Light mode contrast adjustment (keep legacy behavior)
    if (mode == .light) {
        if (color_override) |co| {
            if (hex_util.parseHex(co)) |rgb| {
                const adjusted = hex_util.ensureLightModeContrast(rgb);
                var buf: [8]u8 = undefined;
                const adjusted_hex = adjusted.toHex(&buf);
                if (value_color_override == null) {
                    result.value_fg = adjusted_hex;
                }
            }
        }
    }

    return result;
}

/// Resolve button style from variant + palette (replaces tokens.getButtonStyle)
fn resolveButtonStyle(variant: types.BadgeStyle, palette: *const ThemePalette, custom_color: ?[]const u8) tokens.ButtonStyle {
    const radius: u32 = 6;

    return switch (variant) {
        // default: standard gray badge (shields.io convention)
        .default => .{
            .bg = palette.secondary,
            .fg = palette.secondary_foreground,
            .border = null,
            .border_radius = radius,
        },
        // secondary: high-contrast inverted badge (shadcn primary button)
        .secondary => .{
            .bg = palette.primary,
            .fg = palette.primary_foreground,
            .border = null,
            .border_radius = radius,
        },
        .outline => .{
            .bg = palette.background,
            .fg = palette.foreground,
            .border = custom_color orelse palette.border,
            .border_radius = radius,
        },
        .ghost => .{
            .bg = "transparent",
            .fg = custom_color orelse palette.foreground,
            .border = null,
            .border_radius = radius,
        },
        .destructive => .{
            .bg = palette.destructive,
            .fg = palette.destructive_foreground,
            .border = null,
            .border_radius = radius,
        },
        .branded => blk: {
            const brand = custom_color orelse palette.primary;
            const brand_rgb = hex_util.parseHex(brand) orelse hex_util.parseHex("#27272a").?;
            const is_light_brand = hex_util.isLight(brand_rgb);
            const brand_fg = if (is_light_brand) "#18181b" else "#ffffff";
            break :blk .{
                .bg = brand,
                .fg = brand_fg,
                .border = null,
                .border_radius = radius,
            };
        },
    };
}

// ------------------------------------------------------------------
// Convenience: resolve with defaults
// ------------------------------------------------------------------

pub fn resolveDefault(variant: types.BadgeStyle, mode: types.ColorMode) types.ResolvedColors {
    return resolveTheme(variant, mode, null, null, null, null);
}

// ------------------------------------------------------------------
// Tests
// ------------------------------------------------------------------

test "resolveDefault default dark" {
    const colors = resolveDefault(.default, .dark);
    try std.testing.expectEqualStrings("#27272a", colors.label_bg);
    try std.testing.expectEqualStrings("#fafafa", colors.label_fg);
}

test "resolveDefault secondary dark" {
    const colors = resolveDefault(.secondary, .dark);
    try std.testing.expectEqualStrings("#fafafa", colors.label_bg);
    try std.testing.expectEqualStrings("#18181b", colors.label_fg);
}

test "resolveDefault outline dark" {
    const colors = resolveDefault(.outline, .dark);
    try std.testing.expectEqualStrings("#09090b", colors.label_bg);
    try std.testing.expectEqualStrings("#27272a", colors.border.?);
}

test "resolveDefault branded with color" {
    const colors = resolveTheme(.branded, .dark, null, "#ff6b6b", null, null);
    try std.testing.expectEqualStrings("#ff6b6b", colors.label_bg);
    try std.testing.expectEqualStrings("#ffffff", colors.label_fg);
}

test "resolveDefault light mode" {
    const colors = resolveDefault(.default, .light);
    try std.testing.expectEqualStrings("#f4f4f5", colors.label_bg);
    try std.testing.expectEqualStrings("#18181b", colors.label_fg);
}

test "high-contrast theme meets AAA" {
    const fail = validatePalette(high_contrast_theme, .aaa_normal);
    try std.testing.expectEqual(null, fail);
}

test "enterprise theme builder" {
    const overrides = EnterpriseOverrides{
        .primary = "#0052cc",
        .primary_foreground = "#ffffff",
    };
    const enterprise = buildEnterpriseTheme(dark_theme, overrides);
    try std.testing.expectEqualStrings("#0052cc", enterprise.primary);
    try std.testing.expectEqualStrings("#ffffff", enterprise.primary_foreground);
    try std.testing.expectEqualStrings("#27272a", enterprise.secondary);
}

test "autoCorrect fixes low contrast" {
    var palette = ThemePalette{
        .primary = "#eeeeee",
        .primary_foreground = "#ffffff",
    };
    autoCorrectPalette(&palette);
    const bg = hex_util.parseHex("#eeeeee").?;
    const fg = hex_util.parseHex(palette.primary_foreground).?;
    try std.testing.expect(contrast.meetsLevel(bg, fg, .aa_normal));
}
