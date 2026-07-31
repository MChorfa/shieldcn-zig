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
// Implementation based on the APCA W3 specification (Myndex/Silver).
// Reference: https://github.com/Myndex/apca-w3
// ------------------------------------------------------------------

/// APCA W3 contrast value (Lc).
/// Positive = dark text on light bg (good for reading).
/// Negative = light text on dark bg (good for reading).
/// Zero = no perceptible contrast.
/// |Lc| thresholds (WCAG 3.0 draft):
///   >= 90: excellent, best for small text
///   >= 75: preferred for body text
///   >= 65: large text (18pt+ / 24px+ bold)
///   >= 60: minimum for non-body text / UI labels
///   >= 50: UI components minimum
///   >= 15: non-text (decorative only)
pub fn apca(bg: hex.Rgb, fg: hex.Rgb) f32 {
    const Ybg = relativeLuminance(bg);
    const Yfg = relativeLuminance(fg);

    // Soft black clamp (noise floor)
    const loClip: f32 = 0.022;
    const bgClamped = if (Ybg < loClip) loClip else Ybg;
    const fgClamped = if (Yfg < loClip) loClip else Yfg;

    // Delta Y minimum
    const deltaYmin: f32 = 0.0005;
    const deltaY = bgClamped - fgClamped;
    if (@abs(deltaY) < deltaYmin) return 0.0;

    // APCA W3 main math
    // Exponents differ based on polarity (dark-on-light vs light-on-dark)
    const scale: f32 = 1.014;

    var lc: f32 = 0.0;
    if (bgClamped > fgClamped) {
        // Dark text on light background: positive Lc
        lc = (std.math.pow(f32, bgClamped, 0.56) - std.math.pow(f32, fgClamped, 0.57)) * scale * 100.0;
    } else {
        // Light text on dark background: negative Lc
        lc = (std.math.pow(f32, bgClamped, 0.56) - std.math.pow(f32, fgClamped, 0.57)) * scale * 100.0;
    }

    // Soft clamp near zero
    if (@abs(lc) < 10.0) {
        return 0.0;
    } else if (@abs(lc) < 20.0) {
        lc = lc - 10.0 * (if (lc > 0) @as(f32, 1.0) else -1.0);
    } else if (@abs(lc) >= 20.0) {
        lc = lc - 10.0 * (if (lc > 0) @as(f32, 1.0) else -1.0);
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

/// WCAG 3.0 APCA threshold constants for common text sizes.
pub const APCA_THRESHOLD = struct {
    pub const excellent: f32 = 90.0; // best for small text
    pub const body_text: f32 = 75.0; // preferred for body text
    pub const large_text: f32 = 65.0; // 18pt+ / 24px+ bold
    pub const non_body: f32 = 60.0; // minimum for non-body / UI labels
    pub const ui_components: f32 = 50.0; // UI components minimum
    pub const non_text: f32 = 15.0; // decorative only
};

// ------------------------------------------------------------------
// Auto-foreground: pick black or white based on contrast
// ------------------------------------------------------------------

/// Return "#ffffff" or "#18181b" for text on the given background.
/// Matches upstream shieldcn behavior: colored/saturated badge backgrounds
/// always get white text (a design choice, not pure WCAG optimization).
/// Only very light backgrounds (near-white) get dark text.
pub fn autoForeground(bg: hex.Rgb) []const u8 {
    // Use relative luminance threshold: if the background is very light
    // (luminance > 0.6, e.g. #fafafa, #f4f4f5), use dark text.
    // Otherwise, use white text — matching upstream's consistent white-on-color look.
    const bg_lum = relativeLuminance(bg);
    return if (bg_lum > 0.6) "#18181b" else "#fff";
}

/// APCA-based auto-foreground (WCAG 3.0 mode).
/// Picks white or dark text based on which has higher absolute APCA Lc.
/// Returns "#fff" or "#18181b".
pub fn autoForegroundApca(bg: hex.Rgb) []const u8 {
    const white = hex.Rgb{ .r = 255, .g = 255, .b = 255 };
    const dark = hex.Rgb{ .r = 24, .g = 24, .b = 27 };
    const lc_white = apcaAbs(bg, white);
    const lc_dark = apcaAbs(bg, dark);
    return if (lc_white > lc_dark) "#fff" else "#18181b";
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
    // APCA W3 gives ~80 for white-on-black (high contrast, positive = dark text on light bg)
    try std.testing.expect(lc > 75.0);
}

test "apca light text on dark bg is negative" {
    const dark_bg = hex.parseHex("#18181b").?;
    const white = hex.Rgb{ .r = 255, .g = 255, .b = 255 };
    const lc = apca(dark_bg, white);
    try std.testing.expect(lc < 0.0); // light text on dark bg = negative
    try std.testing.expect(@abs(lc) > 70.0); // should be high contrast
}

test "autoForeground picks white on dark" {
    const dark_bg = hex.parseHex("#18181b").?;
    try std.testing.expectEqualStrings("#fff", autoForeground(dark_bg));
}

test "autoForeground picks white on saturated colors" {
    // Upstream shieldcn always uses white on colored backgrounds
    const green = hex.parseHex("#16a34a").?;
    try std.testing.expectEqualStrings("#fff", autoForeground(green));
    const orange = hex.parseHex("#ea580c").?;
    try std.testing.expectEqualStrings("#fff", autoForeground(orange));
}

test "autoForeground picks dark on light" {
    const light_bg = hex.parseHex("#fafafa").?;
    try std.testing.expectEqualStrings("#18181b", autoForeground(light_bg));
}

// WCAG 3.0 compliance tests — shade-800 colors must meet |Lc| >= 60

test "WCAG 3.0: shade-800 green passes APCA non-body threshold" {
    const green800 = hex.parseHex("#166534").?;
    const white = hex.Rgb{ .r = 255, .g = 255, .b = 255 };
    try std.testing.expect(apcaMeetsThreshold(green800, white, APCA_THRESHOLD.non_body));
}

test "WCAG 3.0: shade-800 blue passes APCA non-body threshold" {
    const blue800 = hex.parseHex("#1e40af").?;
    const white = hex.Rgb{ .r = 255, .g = 255, .b = 255 };
    try std.testing.expect(apcaMeetsThreshold(blue800, white, APCA_THRESHOLD.non_body));
}

test "WCAG 3.0: shade-800 red passes APCA non-body threshold" {
    const red800 = hex.parseHex("#991b1b").?;
    const white = hex.Rgb{ .r = 255, .g = 255, .b = 255 };
    try std.testing.expect(apcaMeetsThreshold(red800, white, APCA_THRESHOLD.non_body));
}

test "WCAG 3.0: shade-800 orange passes APCA non-body threshold" {
    const orange800 = hex.parseHex("#9a3412").?;
    const white = hex.Rgb{ .r = 255, .g = 255, .b = 255 };
    try std.testing.expect(apcaMeetsThreshold(orange800, white, APCA_THRESHOLD.non_body));
}

test "WCAG 3.0: shade-800 yellow passes APCA non-body threshold" {
    const yellow800 = hex.parseHex("#92400e").?;
    const white = hex.Rgb{ .r = 255, .g = 255, .b = 255 };
    try std.testing.expect(apcaMeetsThreshold(yellow800, white, APCA_THRESHOLD.non_body));
}

test "WCAG 3.0: shade-800 purple passes APCA non-body threshold" {
    const purple800 = hex.parseHex("#6b21a8").?;
    const white = hex.Rgb{ .r = 255, .g = 255, .b = 255 };
    try std.testing.expect(apcaMeetsThreshold(purple800, white, APCA_THRESHOLD.non_body));
}

test "WCAG 3.0: shade-800 gray passes APCA non-body threshold" {
    const gray800 = hex.parseHex("#1f2937").?;
    const white = hex.Rgb{ .r = 255, .g = 255, .b = 255 };
    try std.testing.expect(apcaMeetsThreshold(gray800, white, APCA_THRESHOLD.non_body));
}

test "WCAG 3.0: shade-600 green FAILS APCA non-body threshold" {
    // This documents why wcag=3 mode exists — shade-600 doesn't pass
    const green600 = hex.parseHex("#16a34a").?;
    const white = hex.Rgb{ .r = 255, .g = 255, .b = 255 };
    try std.testing.expect(!apcaMeetsThreshold(green600, white, APCA_THRESHOLD.non_body));
}

test "autoForegroundApca picks white on shade-800 colors" {
    const green800 = hex.parseHex("#166534").?;
    try std.testing.expectEqualStrings("#fff", autoForegroundApca(green800));
    const blue800 = hex.parseHex("#1e40af").?;
    try std.testing.expectEqualStrings("#fff", autoForegroundApca(blue800));
}

test "autoForegroundApca picks dark on light" {
    const light_bg = hex.parseHex("#fafafa").?;
    try std.testing.expectEqualStrings("#18181b", autoForegroundApca(light_bg));
}
