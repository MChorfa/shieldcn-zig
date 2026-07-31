const std = @import("std");
const types = @import("../core/types.zig");
const hex_util = @import("../util/hex.zig");
const glyphs = @import("glyphs.zig");

/// shieldcn-zig — render/svg.zig
/// Pure SVG XML builder for single badges and badge groups.
///
/// Text is vectorized: each character is emitted as a `<path>` glyph
/// extracted from an embedded font table (see `glyphs.zig`), matching
/// upstream shieldcn's Satori-style output. This makes badges
/// font-independent — they render identically everywhere (GitHub, browsers,
/// image viewers) without relying on the viewer having Inter installed.
///
/// `renderBadgeSvg` emits a complete `<svg>` document for one badge.
/// `renderBadgeInner` emits the clip path + clipped content for one badge
/// wrapped in a `<g transform="translate(0,y)">`, with a caller-supplied
/// `id_suffix` so multiple badges can share one SVG document without
/// `clipPath id` collisions. `renderBadgeGroupSvg` composes N inner badges
/// into a single stacked `<svg>` (see `group.zig`).

// ------------------------------------------------------------------
// Layout
// ------------------------------------------------------------------

const Layout = struct {
    total_w: f32,
    total_h: f32,
    h: u32,
    fs: u32,
    r: u32,
    pad_x: u32,
    icon_sz: u32,
    gap: u32,
    label_gap: u32,
    label_section_w: f32,
    value_section_w: f32,
    mid_gap: f32,
    left_padding: f32,
    icon_block_w: f32,
    has_icon: bool,
};

fn computeLayout(config: types.BadgeConfig) Layout {
    _ = types.getSizePreset(config.size);
    const h = config.height;
    const fs = config.font_size;
    const r = config.radius;
    const pad_x = config.pad_x;
    const icon_sz = config.icon_size;
    const gap = config.gap;
    const label_gap = config.label_gap;

    // Use glyph-based width measurement for accurate layout matching
    // the vectorized text output. Falls back to estimate for non-ASCII.
    const label_w = measureGlyphWidth(config.label, fs);
    const value_w = measureGlyphWidth(config.value, fs);

    const has_icon = config.icon != null;
    const icon_block_w: f32 = if (has_icon) @as(f32, @floatFromInt(icon_sz)) + @as(f32, @floatFromInt(gap)) else 0;

    const label_content_w = label_w;
    const value_content_w = value_w;

    const left_padding: f32 = @floatFromInt(pad_x);
    const mid_gap: f32 = @floatFromInt(label_gap);
    const right_padding: f32 = @floatFromInt(pad_x);

    const label_section_w = left_padding + icon_block_w + label_content_w + mid_gap / 2;
    const value_section_w = mid_gap / 2 + value_content_w + right_padding;

    const total_w = label_section_w + value_section_w;
    const total_h: f32 = @floatFromInt(h);

    return .{
        .total_w = total_w,
        .total_h = total_h,
        .h = h,
        .fs = fs,
        .r = r,
        .pad_x = pad_x,
        .icon_sz = icon_sz,
        .gap = gap,
        .label_gap = label_gap,
        .label_section_w = label_section_w,
        .value_section_w = value_section_w,
        .mid_gap = mid_gap,
        .left_padding = left_padding,
        .icon_block_w = icon_block_w,
        .has_icon = has_icon,
    };
}

/// Total badge width in SVG user units (float).
pub fn badgeWidth(config: types.BadgeConfig) f32 {
    return computeLayout(config).total_w;
}

/// Total badge height in pixels.
pub fn badgeHeight(config: types.BadgeConfig) u32 {
    return config.height;
}

// ------------------------------------------------------------------
// Glyph-based text rendering (vectorized text, no <text> elements)
// ------------------------------------------------------------------

/// Render a text string as vectorized `<path>` glyphs.
/// Each character is looked up in the embedded glyph table and emitted
/// as a `<path>` with a translate transform. This matches upstream
/// shieldcn's Satori-style output — badges are font-independent.
///
/// `x` is the starting X position (left edge of first glyph).
/// `y` is the text baseline in SVG coordinates.
/// `font_size` is the desired pixel size.
/// `fill` is the fill color.
/// `opacity` is the fill-opacity (0.0–1.0), or null for no opacity.
pub fn renderGlyphText(
    list: *std.ArrayList(u8),
    allocator: std.mem.Allocator,
    text: []const u8,
    x: f32,
    y: f32,
    font_size: u32,
    fill: []const u8,
    opacity: ?f32,
) !void {
    const scale = @as(f32, @floatFromInt(font_size)) / @as(f32, @floatFromInt(glyphs.units_per_em));
    var pen_x = x;

    // Upstream emits a bare <g> with no attributes; fill/opacity live on each <path>.
    // Format opacity as ".X" matching upstream (e.g. ".7" not "0.70").
    var op_str: []const u8 = "";
    var op_buf: [8]u8 = undefined;
    if (opacity) |op| {
        if (op < 1.0) {
            const s = std.fmt.bufPrint(&op_buf, "{d:.1}", .{op}) catch "0.7";
            op_str = if (s.len > 0 and s[0] == '0') s[1..] else s;
        }
    }

    for (text) |c| {
        const glyph = glyphs.getGlyph(c) orelse {
            // Unknown char: use space advance
            pen_x += @as(f32, @floatFromInt(font_size)) * 0.3;
            continue;
        };

        if (glyph.path.len > 0) {
            // Emit glyph path with fill/opacity on the path itself (matching upstream).
            if (op_str.len > 0) {
                try list.print(
                    allocator,
                    "<path fill=\"{s}\" fill-opacity=\"{s}\" d=\"{s}\" transform=\"translate({d:.1},{d:.1}) scale({d:.4})\"/>",
                    .{ fill, op_str, glyph.path, pen_x, y, scale },
                );
            } else {
                try list.print(
                    allocator,
                    "<path fill=\"{s}\" d=\"{s}\" transform=\"translate({d:.1},{d:.1}) scale({d:.4})\"/>",
                    .{ fill, glyph.path, pen_x, y, scale },
                );
            }
        }

        // Advance pen by the glyph's advance width
        pen_x += @as(f32, @floatFromInt(glyph.advance_width)) * scale;
    }
}

/// Measure the width of a text string using glyph advance widths.
/// This replaces the heuristic estimateWidth for more accurate layout
/// when using vectorized text.
pub fn measureGlyphWidth(text: []const u8, font_size: u32) f32 {
    const scale = @as(f32, @floatFromInt(font_size)) / @as(f32, @floatFromInt(glyphs.units_per_em));
    var width: f32 = 0;
    for (text) |c| {
        const glyph = glyphs.getGlyph(c) orelse {
            width += @as(f32, @floatFromInt(font_size)) * 0.3;
            continue;
        };
        width += @as(f32, @floatFromInt(glyph.advance_width)) * scale;
    }
    return width;
}

/// Compute the text baseline Y position for vertically centered text.
/// Uses the font's baseline offset ratio for accurate centering.
pub fn computeBaselineY(height: u32, font_size: u32) f32 {
    return @as(f32, @floatFromInt(height)) / 2 + @as(f32, @floatFromInt(font_size)) * glyphs.baseline_offset_ratio;
}

// ------------------------------------------------------------------
// Inner badge render: clip path + clipped content inside a translated
// <g>. Caller picks `id_suffix` (unique per SVG document) and `y_offset`
// (vertical position within the document).
// ------------------------------------------------------------------

pub fn renderBadgeInner(
    allocator: std.mem.Allocator,
    config: types.BadgeConfig,
    id_suffix: []const u8,
    y_offset: u32,
) ![]const u8 {
    const L = computeLayout(config);
    var list: std.ArrayList(u8) = .empty;
    errdefer list.deinit(allocator);

    // Only emit transform wrapper when y_offset > 0 (group rendering).
    // For single badges, flatten structure to match upstream.
    const has_transform = y_offset > 0;
    if (has_transform) {
        try list.print(allocator, "<g transform=\"translate(0,{d})\">", .{y_offset});
    }

    const colors = config.colors;

    if (config.split) {
        // Split mode: two background rects clipped to the rounded shape.
        // Upstream uses a rounded <path> clipPath + a <mask> element.
        // Structure: clipPath, mask, label bg, <g>label text</g>, value bg, <g>value text</g>
        const w = L.total_w;
        const h: f32 = @floatFromInt(L.h);
        const r: f32 = @floatFromInt(L.r);
        const wr = if (w - r < r) r else w - r;
        const hr = if (h - r < r) r else h - r;

        // clipPath with rounded path geometry (matches non-split background path).
        try list.print(
            allocator,
            "<clipPath id=\"satori_cp-id{s}\"><path d=\"M{d:.0} 0H{d:.0}A{d:.0} {d:.0} 0 0 1 {d:.0} {d:.0}V{d:.0}A{d:.0} {d:.0} 0 0 1 {d:.0} {d:.0}H{d:.0}A{d:.0} {d:.0} 0 0 1 0 {d:.0}V{d:.0}A{d:.0} {d:.0} 0 0 1 {d:.0} 0\"/></clipPath>",
            .{
                id_suffix,
                r, wr, r, r, w, r,
                hr, r, r, wr, h,
                r, r, r, hr,
                r, r, r, r,
            },
        );
        // mask element covering the full badge area.
        try list.print(
            allocator,
            "<mask id=\"satori_om-id{s}\"><path fill=\"#fff\" d=\"M0 0H{d:.0}V{d:.0}H0z\"/></mask>",
            .{ id_suffix, w, h },
        );

        // Label section background rect (clipped + masked).
        try list.print(
            allocator,
            "<path fill=\"{s}\" d=\"M0 0H{d:.0}V{d:.0}H0z\" clip-path=\"url(#satori_cp-id{s})\" mask=\"url(#satori_om-id{s})\"/>",
            .{ colors.label_bg, L.label_section_w, h, id_suffix, id_suffix },
        );
        // Open group for label text (clipped + masked).
        try list.print(
            allocator,
            "<g clip-path=\"url(#satori_cp-id{s})\" mask=\"url(#satori_om-id{s})\">",
            .{ id_suffix, id_suffix },
        );
        // NOTE: label text + icon rendered below; value bg + text after label group close.
    } else if (config.style == .outline) {
        // Outline variant: fill="none" with 2px stroke, clipPath for rounded corners.
        // Upstream uses <defs><clipPath id="satori_bc-id"> + inset stroke path.
        const w = L.total_w;
        const h: f32 = @floatFromInt(L.h);
        const r: f32 = @floatFromInt(L.r);
        const wr = if (w - r < r) r else w - r;
        const hr = if (h - r < r) r else h - r;
        const inset: f32 = 1.8; // half of stroke-width=2, approximately

        // clipPath with standard rounded path geometry.
        try list.print(
            allocator,
            "<defs><clipPath id=\"satori_bc-id{s}\"><path d=\"M{d:.0} 0H{d:.0}A{d:.0} {d:.0} 0 0 1 {d:.0} {d:.0}V{d:.0}A{d:.0} {d:.0} 0 0 1 {d:.0} {d:.0}H{d:.0}A{d:.0} {d:.0} 0 0 1 0 {d:.0}V{d:.0}A{d:.0} {d:.0} 0 0 1 {d:.0} 0\"/></clipPath></defs>",
            .{
                id_suffix,
                r, wr, r, r, w, r,
                hr, r, r, wr, h,
                r, r, r, hr,
                r, r, r, r,
            },
        );
        // Stroke path: inset by 1.8px, with clip-path.
        try list.print(
            allocator,
            "<path fill=\"none\" stroke=\"{s}\" stroke-width=\"2\" d=\"M{d:.1} {d:.1}A{d:.0} {d:.0} 0 0 1 {d:.0} 0H{d:.0}A{d:.0} {d:.0} 0 0 1 {d:.0} {d:.0}V{d:.0}A{d:.0} {d:.0} 0 0 1 {d:.0} {d:.0}H{d:.0}A{d:.0} {d:.0} 0 0 1 0 {d:.0}V{d:.0}A{d:.0} {d:.0} 0 0 1 {d:.1} {d:.1}\" clip-path=\"url(#satori_bc-id{s})\"/>",
            .{
                colors.border orelse "#3f3f46",
                inset, inset,
                r, r, r,
                wr, r, r, w, r,
                hr, r, r, wr, h,
                r, r, r, hr,
                r, r, r,
                inset, inset, id_suffix,
            },
        );
    } else if (config.style == .ghost) {
        // Ghost variant: no background path at all — text renders directly.
    } else {
        // Single-surface: one rounded <path> directly under svg (no clipPath).
        // Matches upstream shieldcn geometry: <path fill="..." d="M6 0H...A6 6..."/>
        const w = L.total_w;
        const h: f32 = @floatFromInt(L.h);
        const r: f32 = @floatFromInt(L.r);
        const wr = if (w - r < r) r else w - r;
        const hr = if (h - r < r) r else h - r;
        try list.print(
            allocator,
            "<path fill=\"{s}\" d=\"M{d:.0} 0H{d:.0}A{d:.0} {d:.0} 0 0 1 {d:.0} {d:.0}V{d:.0}A{d:.0} {d:.0} 0 0 1 {d:.0} {d:.0}H{d:.0}A{d:.0} {d:.0} 0 0 1 0 {d:.0}V{d:.0}A{d:.0} {d:.0} 0 0 1 {d:.0} 0\"",
            .{
                colors.label_bg,
                r,    // M r
                wr,   // H (W-r)
                r, r, // A r r
                w,    // W
                r,    // r
                hr,   // V (H-r)
                r, r, // A r r
                wr,   // (W-r)
                h,    // H
                r,    // H r
                r, r, // A r r
                hr,   // 0 (H-r)
                r,    // V r
                r, r, // A r r
                r,    // r
            },
        );
        if (colors.border) |b| {
            try list.print(allocator, " stroke=\"{s}\" stroke-width=\"1\"", .{b});
        }
        try list.appendSlice(allocator, "/>");
    }

    // Status dot (if enabled)
    var current_x = L.left_padding;
    if (config.status_dot) {
        const dot_color = config.status_color orelse "#22c55e";
        const dot_r = @as(f32, @floatFromInt(L.fs)) * 0.25;
        const dot_cy = L.total_h / 2;
        try list.print(
            allocator,
            "<circle cx=\"{d:.1}\" cy=\"{d:.1}\" r=\"{d:.1}\" fill=\"{s}\"/>",
            .{ current_x + dot_r, dot_cy, dot_r, dot_color },
        );
        current_x += dot_r * 2 + @as(f32, @floatFromInt(L.gap));
    }

    // Icon (if present) — upstream places icons at x=12, not pad_x=16.
    // Multi-path embedded icons render each path with its own fill.
    if (config.icon_paths) |paths| {
        const icon_x: f32 = if (config.status_dot) current_x else 12.0;
        const icon_y = (L.total_h - @as(f32, @floatFromInt(L.icon_sz))) / 2;
        const icon_scale = @as(f32, @floatFromInt(L.icon_sz)) / config.icon_viewbox_size;
        for (paths) |p| {
            const fill = p.fill orelse config.icon_fill orelse colors.label_fg;
            if (config.icon_fill_opacity) |op| {
                try list.print(
                    allocator,
                    "<path d=\"{s}\" fill=\"{s}\" fill-opacity=\".{d}\" transform=\"translate({d:.0} {d:.0})scale({d:.5})\"/>",
                    .{ p.d, fill, @as(u32, @intFromFloat(op * 100)), icon_x, icon_y, icon_scale },
                );
            } else {
                try list.print(
                    allocator,
                    "<path d=\"{s}\" fill=\"{s}\" transform=\"translate({d:.0} {d:.0})scale({d:.5})\"/>",
                    .{ p.d, fill, icon_x, icon_y, icon_scale },
                );
            }
        }
        current_x += @as(f32, @floatFromInt(L.icon_sz)) + @as(f32, @floatFromInt(L.gap));
    } else if (config.icon) |icon_path| {
        const icon_x: f32 = if (config.status_dot) current_x else 12.0;
        const icon_y = (L.total_h - @as(f32, @floatFromInt(L.icon_sz))) / 2;
        const icon_fill = config.icon_fill orelse colors.label_fg;
        const icon_scale = @as(f32, @floatFromInt(L.icon_sz)) / config.icon_viewbox_size;
        if (config.icon_fill_opacity) |op| {
            try list.print(
                allocator,
                "<path d=\"{s}\" fill=\"{s}\" fill-opacity=\".{d}\" transform=\"translate({d:.0} {d:.0})scale({d:.5})\"/>",
                .{ icon_path, icon_fill, @as(u32, @intFromFloat(op * 100)), icon_x, icon_y, icon_scale },
            );
        } else {
            try list.print(
                allocator,
                "<path d=\"{s}\" fill=\"{s}\" transform=\"translate({d:.0} {d:.0})scale({d:.5})\"/>",
                .{ icon_path, icon_fill, icon_x, icon_y, icon_scale },
            );
        }
        current_x += @as(f32, @floatFromInt(L.icon_sz)) + @as(f32, @floatFromInt(L.gap));
    }

    // Label text — vectorized as <path> glyphs (font-independent)
    // In split mode, upstream always uses #fafafa for label text (muted foreground).
    const label_fg = blk: {
        if (config.label_text_color) |c| break :blk c;
        if (config.split) break :blk "#fafafa";
        break :blk colors.label_fg;
    };
    // Baseline position: vertically center the text using actual font metrics.
    // baseline_y = badge_center + font_size * (ascent - descent) / (2 * upem)
    const baseline_y = L.total_h / 2 + @as(f32, @floatFromInt(L.fs)) * glyphs.baseline_offset_ratio;
    // Non-split mode wraps label text in <g>; split mode's <g> already open above.
    if (!config.split) {
        try list.appendSlice(allocator, "<g>");
    }
    try renderGlyphText(&list, allocator, config.label, current_x, baseline_y, L.fs, label_fg, config.label_opacity);
    if (!config.split) {
        try list.appendSlice(allocator, "</g>");
    } else {
        // Split mode: close the clip/mask group.
        try list.appendSlice(allocator, "</g>");
    }

    // Value text — vectorized as <path> glyphs
    const value_x = L.label_section_w + L.mid_gap / 2;
    const value_fg = config.value_color orelse colors.value_fg;
    // In split mode, emit value bg before value text group.
    if (config.split) {
        const w = L.total_w;
        const h: f32 = @floatFromInt(L.h);
        try list.print(
            allocator,
            "<path fill=\"{s}\" d=\"M{d:.0} 0H{d:.0}V{d:.0}H{d:.0}z\" clip-path=\"url(#satori_cp-id{s})\" mask=\"url(#satori_om-id{s})\"/>",
            .{ colors.value_bg, L.label_section_w, w, h, L.label_section_w, id_suffix, id_suffix },
        );
        // Open group for value text (clipped + masked).
        try list.print(
            allocator,
            "<g clip-path=\"url(#satori_cp-id{s})\" mask=\"url(#satori_om-id{s})\">",
            .{ id_suffix, id_suffix },
        );
    } else {
        try list.appendSlice(allocator, "<g>");
    }
    try renderGlyphText(&list, allocator, config.value, value_x, baseline_y, L.fs, value_fg, null);
    // Close value group (both split and non-split).
    try list.appendSlice(allocator, "</g>");

    // Close transform group (if present)
    if (has_transform) {
        try list.appendSlice(allocator, "</g>");
    }

    return try list.toOwnedSlice(allocator);
}

// ------------------------------------------------------------------
// Single badge render: emit SVG XML into an ArrayList(u8)
// ------------------------------------------------------------------

pub fn renderBadgeSvg(
    allocator: std.mem.Allocator,
    config: types.BadgeConfig,
) ![]const u8 {
    const L = computeLayout(config);
    var list: std.ArrayList(u8) = .empty;
    errdefer list.deinit(allocator);

    // SVG header — minimal, matching upstream shieldcn structure.
    // No role/aria-label/title (upstream doesn't include them).
    try list.print(
        allocator,
        "<svg xmlns=\"http://www.w3.org/2000/svg\" width=\"{d:.0}\" height=\"{d}\" viewBox=\"0 0 {d:.0} {d}\">",
        .{ L.total_w, L.h, L.total_w, L.h },
    );

    const inner = try renderBadgeInner(allocator, config, "", 0);
    defer allocator.free(inner);
    try list.appendSlice(allocator, inner);

    try list.appendSlice(allocator, "</svg>");

    return try list.toOwnedSlice(allocator);
}

// ------------------------------------------------------------------
// Convenience: render from resolved colors directly
// ------------------------------------------------------------------

pub fn renderSimple(
    allocator: std.mem.Allocator,
    label: []const u8,
    value: []const u8,
    colors: types.ResolvedColors,
) ![]const u8 {
    const config = types.BadgeConfig{
        .label = label,
        .value = value,
        .colors = colors,
    };
    return try renderBadgeSvg(allocator, config);
}

// ------------------------------------------------------------------
// Tests
// ------------------------------------------------------------------

test "renderSimple produces valid SVG" {
    const allocator = std.testing.allocator;
    const colors = types.ResolvedColors{
        .label_bg = "#27272a",
        .label_fg = "#fafafa",
        .value_bg = "#27272a",
        .value_fg = "#fafafa",
        .border = null,
    };
    const svg = try renderSimple(allocator, "npm", "v1.0.0", colors);
    defer allocator.free(svg);

    try std.testing.expect(std.mem.startsWith(u8, svg, "<svg"));
    // Text is vectorized as <path> glyphs — check for path elements, not text
    try std.testing.expect(std.mem.indexOf(u8, svg, "<path") != null);
    try std.testing.expect(std.mem.indexOf(u8, svg, "<text") == null);
    // viewBox should be present
    try std.testing.expect(std.mem.indexOf(u8, svg, "viewBox") != null);
    // Single-surface mode: no clipPath (background is a rounded path)
    try std.testing.expect(std.mem.indexOf(u8, svg, "clipPath") == null);
    // No accessibility attributes (matching upstream)
    try std.testing.expect(std.mem.indexOf(u8, svg, "role=") == null);
    try std.testing.expect(std.mem.indexOf(u8, svg, "aria-label=") == null);
    try std.testing.expect(std.mem.indexOf(u8, svg, "<title>") == null);
}

test "renderBadgeSvg with split mode" {
    const allocator = std.testing.allocator;
    const colors = types.ResolvedColors{
        .label_bg = "#27272a",
        .label_fg = "#a1a1aa",
        .value_bg = "#22c55e",
        .value_fg = "#ffffff",
        .border = null,
    };
    const config = types.BadgeConfig{
        .label = "build",
        .value = "passing",
        .colors = colors,
        .split = true,
        .status_color = "#22c55e",
        .status_dot = true,
    };
    const svg = try renderBadgeSvg(allocator, config);
    defer allocator.free(svg);

    try std.testing.expect(std.mem.indexOf(u8, svg, "clip-path") != null);
    try std.testing.expect(std.mem.indexOf(u8, svg, "circle") != null);
}

test "renderBadgeInner uses unique clip id in split mode" {
    const allocator = std.testing.allocator;
    const colors = types.ResolvedColors{
        .label_bg = "#27272a",
        .label_fg = "#fafafa",
        .value_bg = "#27272a",
        .value_fg = "#fafafa",
        .border = null,
    };
    const config = types.BadgeConfig{
        .label = "a",
        .value = "b",
        .colors = colors,
        .split = true,
    };
    const inner = try renderBadgeInner(allocator, config, "_2", 40);
    defer allocator.free(inner);

    // Split mode uses clipPath with satori naming for rounded corners
    try std.testing.expect(std.mem.indexOf(u8, inner, "id=\"satori_cp-id_2\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, inner, "url(#satori_cp-id_2)") != null);
    try std.testing.expect(std.mem.indexOf(u8, inner, "satori_om-id_2") != null);
    // y_offset > 0 emits transform wrapper
    try std.testing.expect(std.mem.indexOf(u8, inner, "translate(0,40)") != null);
}

test "renderBadgeInner single-surface has no clipPath" {
    const allocator = std.testing.allocator;
    const colors = types.ResolvedColors{
        .label_bg = "#16a34a",
        .label_fg = "#fff",
        .value_bg = "#16a34a",
        .value_fg = "#fff",
        .border = null,
    };
    const config = types.BadgeConfig{
        .label = "build",
        .value = "passing",
        .colors = colors,
    };
    const inner = try renderBadgeInner(allocator, config, "", 0);
    defer allocator.free(inner);

    // Single-surface mode: no clipPath, no transform wrapper group
    try std.testing.expect(std.mem.indexOf(u8, inner, "clipPath") == null);
    try std.testing.expect(std.mem.indexOf(u8, inner, "clip-path") == null);
    // No wrapper <g transform="translate(0,...)"> (glyph paths still use transform)
    try std.testing.expect(std.mem.indexOf(u8, inner, "<g transform=\"translate(0,") == null);
    // Background path should be directly present
    try std.testing.expect(std.mem.indexOf(u8, inner, "<path fill=\"#16a34a\"") != null);
}
