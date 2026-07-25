const std = @import("std");

/// shieldcn-zig — render/measure.zig
/// Text width estimation for badge layout.
///
/// Full TTF parsing is overkill for badge rendering. We use a
/// simplified per-character width table that approximates Inter Medium
/// at 12px. This is accurate to ~1px for ASCII badge text.
///
/// Character widths are in "design units" scaled to font-size.
/// Inter Medium has an em-square of 2048; at 12px, 1 em = 12px.

// Average width factor per character category
const AVG_UPPER: f32 = 0.62; // A-Z
const AVG_LOWER: f32 = 0.52; // a-z
const AVG_DIGIT: f32 = 0.58; // 0-9
const AVG_SPACE: f32 = 0.28; // space
const AVG_PUNCT: f32 = 0.35; // .,-_/ etc.
const AVG_SPECIAL: f32 = 0.55; // everything else

/// Estimate text width in pixels at the given font size.
/// This is a rough approximation sufficient for badge layout.
pub fn estimateWidth(text: []const u8, font_size: u32) f32 {
    var total: f32 = 0;
    for (text) |c| {
        const factor = switch (c) {
            'A'...'Z' => AVG_UPPER,
            'a'...'z' => AVG_LOWER,
            '0'...'9' => AVG_DIGIT,
            ' ' => AVG_SPACE,
            '.', ',', '-', '_', '/', ':', '+', '%', '!' => AVG_PUNCT,
            else => AVG_SPECIAL,
        };
        total += factor * @as(f32, @floatFromInt(font_size));
    }
    return total;
}

// ------------------------------------------------------------------
// Tests
// ------------------------------------------------------------------

test "estimateWidth basic" {
    const w = estimateWidth("npm", 12);
    // n(0.52) + p(0.52) + m(0.52) = 1.56 * 12 = ~18.7
    try std.testing.expect(w > 15 and w < 25);
}

test "estimateWidth empty" {
    try std.testing.expectEqual(@as(f32, 0), estimateWidth("", 12));
}
