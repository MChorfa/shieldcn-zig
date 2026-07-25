const std = @import("std");
const hex = @import("hex.zig");

/// shieldcn-zig — util/contrast.zig
/// WCAG 2.1 and WCAG 3.0 (APCA) contrast calculations.
///
/// WCAG 2.1 levels:
///   AA normal:  4.5:1
///   AA large:   3.0:1
///   AAA normal: 7.0:1
///   AAA large:  4.5:1
///
/// WCAG 3.0 APCA (Accessible Perceptual Contrast Algorithm):
///   Uses non-linear lightness response for better perceptual accuracy.
///   Lc values (absolute, not ratio):
///   |Lc| >= 60:  preferred for body text
///   |Lc| >= 75:  best for small text
///   |Lc| >= 90:  excellent, max readability
///   |Lc| <= 15:  non-text (decorative only)

// ------------------------------------------------------------------
// WCAG 2.1 luminance contrast ratio
// ------------------------------------------------------------------

/// Relative luminance per WCAG 2.1 (sRGB to linear RGB conversion)
pub fn relativeLuminance(rgb: hex.Rgb) f32 {
    const srgbToLinear = struct {
        pub fn f(c: f32) f32 {
            if (c <= 0.03928) return c / 12.92;
            return std.math.pow(f32, (c + 0.055) / 1.055, 2.4);
        }
    }.f;

    const rf = srgbToLinear(@as(f32, @floatFromInt(rgb.r)) / 255.0);
    const gf = srgbToLinear(@as(f32, @floatFromInt(rgb.g)) / 255.0);
    const bf = srgbToLinear(@as(f32, @floatFromInt(rgb.b)) / 255.0);

    return 0.2126 * rf + 0.7152 * gf + 0.0722 * bf;
}

/// Contrast ratio between two colors (larger value = more contrast)
pub fn contrastRatio(bg: hex.Rgb, fg: hex.Rgb) f32 {
    const lum1 = relativeLuminance(bg);
    const lum2 = relativeLuminance(fg);
    const lighter = @max(lum1, lum2);
    const darker = @min(lum1, lum2);
    return (lighter + 0.05) / (darker + 0.05);
}

/// Check if two colors meet a specific WCAG 2.1 level.
pub fn meetsLevel(bg: hex.Rgb, fg: hex.Rgb, level: WcagLevel) bool {
    const ratio = contrastRatio(bg, fg);
    return switch (level) {
        .aa_normal => ratio >= 4.5,
        .aa_large => ratio >= 3.0,
        .aaa_normal => ratio >= 7.0,
        .aaa_large => ratio >= 4.5,
    };
}

pub const WcagLevel = enum {
    aa_normal,
    aa_large,
    aaa_normal,
    aaa_large,
};

// ------------------------------------------------------------------
// WCAG 3.0 APCA (Accessible Perceptual Contrast Algorithm)
// Simplified implementation based on the Silver/APG specification.
// ------------------------------------------------------------------

/// APCA contrast value (Lc). Positive = dark text on light bg.
/// Negative = light text on dark bg. Zero = no contrast.
pub fn apca(bg: hex.Rgb, fg: hex.Rgb) f32 {
    const Ybg = relativeLuminance(bg);
    const Yfg = relativeLuminance(fg);

    // Clamp to valid range
    const clamped_bg = std.math.clamp(Ybg, 0.0, 1.0);
    const clamped_fg = std.math.clamp(Yfg, 0.0, 1.0);

    // APCA constants (simplified Myndex/Silver formula)
    const bgExp: f32 = 0.56;
    const fgExp: f32 = 0.57;
    const scale: f32 = 106.0;
    const loClip: f32 = 0.027;
    const deltaYmin: f32 = 0.0005;

    // Soft black clamp
    const bgClamped = if (clamped_bg < loClip) loClip else clamped_bg;
    const fgClamped = if (clamped_fg < loClip) loClip else clamped_fg;

    const deltaY = bgClamped - fgClamped;
    if (@abs(deltaY) < deltaYmin) return 0.0;

    // Determine polarity
    const is_dark_text = bgClamped > fgClamped;

    var lc: f32 = 0.0;
    if (is_dark_text) {
        // Dark text on light background: positive Lc
        lc = (std.math.pow(f32, bgClamped, bgExp) - std.math.pow(f32, fgClamped, fgExp)) * scale;
    } else {
        // Light text on dark background: negative Lc
        lc = (std.math.pow(f32, bgClamped, bgExp) - std.math.pow(f32, fgClamped, fgExp)) * scale;
    }

    return lc;
}

/// Absolute APCA value for threshold checks.
pub fn apcaAbs(bg: hex.Rgb, fg: hex.Rgb) f32 {
    return @abs(apca(bg, fg));
}

/// Check APCA against WCAG 3.0 recommended thresholds.
pub fn apcaMeetsThreshold(bg: hex.Rgb, fg: hex.Rgb, threshold: f32) bool {
    return apcaAbs(bg, fg) >= threshold;
}

// ------------------------------------------------------------------
// Auto-foreground: pick black or white based on contrast
// ------------------------------------------------------------------

/// Return "#ffffff" or "#18181b" whichever has better contrast against bg.
pub fn autoForeground(bg: hex.Rgb) []const u8 {
    const white = hex.Rgb{ .r = 255, .g = 255, .b = 255 };
    const dark = hex.Rgb{ .r = 24, .g = 24, .b = 27 };
    const ratio_white = contrastRatio(bg, white);
    const ratio_dark = contrastRatio(bg, dark);
    return if (ratio_white > ratio_dark) "#ffffff" else "#18181b";
}

/// Same using APCA (WCAG 3.0)
pub fn autoForegroundApca(bg: hex.Rgb) []const u8 {
    const white = hex.Rgb{ .r = 255, .g = 255, .b = 255 };
    const dark = hex.Rgb{ .r = 24, .g = 24, .b = 27 };
    const lc_white = apcaAbs(bg, white);
    const lc_dark = apcaAbs(bg, dark);
    return if (lc_white > lc_dark) "#ffffff" else "#18181b";
}

// ------------------------------------------------------------------
// Tests
// ------------------------------------------------------------------

test "contrastRatio white vs black" {
    const white = hex.Rgb{ .r = 255, .g = 255, .b = 255 };
    const black = hex.Rgb{ .r = 0, .g = 0, .b = 0 };
    const ratio = contrastRatio(white, black);
    try std.testing.expectApproxEqAbs(@as(f32, 21.0), ratio, 0.1);
}

test "contrastRatio same color is 1.0" {
    const gray = hex.Rgb{ .r = 128, .g = 128, .b = 128 };
    try std.testing.expectApproxEqAbs(@as(f32, 1.0), contrastRatio(gray, gray), 0.01);
}

test "meetsLevel AA normal" {
    const white = hex.Rgb{ .r = 255, .g = 255, .b = 255 };
    const dark_gray = hex.Rgb{ .r = 64, .g = 64, .b = 64 };
    try std.testing.expect(meetsLevel(white, dark_gray, .aa_normal));
}

test "apca white vs black" {
    const white = hex.Rgb{ .r = 255, .g = 255, .b = 255 };
    const black = hex.Rgb{ .r = 0, .g = 0, .b = 0 };
    const lc = apca(white, black);
    try std.testing.expect(lc > 90.0); // near-maximum contrast
}

test "autoForeground picks white on dark" {
    const dark_bg = hex.parseHex("#18181b").?;
    try std.testing.expectEqualStrings("#ffffff", autoForeground(dark_bg));
}

test "autoForeground picks dark on light" {
    const light_bg = hex.parseHex("#fafafa").?;
    try std.testing.expectEqualStrings("#18181b", autoForeground(light_bg));
}
