const std = @import("std");
const types = @import("../core/types.zig");
const hex_util = @import("../util/hex.zig");
const measure = @import("measure.zig");

/// shieldcn-zig — render/svg.zig
/// Pure SVG XML builder for single badges and badge groups. No Satori —
/// direct XML emission.
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

    const label_w = measure.estimateWidth(config.label, fs);
    const value_w = measure.estimateWidth(config.value, fs);

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

    try list.print(allocator, "  <g transform=\"translate(0,{d})\">\n", .{y_offset});

    // Clip path for rounded rect (unique id per badge)
    try list.print(
        allocator,
        "    <clipPath id=\"r{s}\">\n      <rect width=\"{d:.0}\" height=\"{d}\" rx=\"{d}\" fill=\"#fff\"/>\n    </clipPath>\n",
        .{ id_suffix, L.total_w, L.h, L.r },
    );

    // Main group with clip
    try list.appendSlice(allocator, "    <g clip-path=\"url(#r");
    try list.appendSlice(allocator, id_suffix);
    try list.appendSlice(allocator, ")\">\n");

    const colors = config.colors;

    if (config.split) {
        // Split mode: two background rects
        try list.print(
            allocator,
            "    <rect width=\"{d:.0}\" height=\"{d}\" fill=\"{s}\"/>\n",
            .{ L.label_section_w, L.h, colors.label_bg },
        );
        try list.print(
            allocator,
            "    <rect x=\"{d:.0}\" width=\"{d:.0}\" height=\"{d}\" fill=\"{s}\"/>\n",
            .{ L.label_section_w, L.value_section_w, L.h, colors.value_bg },
        );
        // Divider line — subtle dark separator that works on any background
        try list.print(
            allocator,
            "    <rect x=\"{d:.0}\" width=\"1\" height=\"{d}\" fill=\"#000000\" opacity=\"0.15\"/>\n",
            .{ L.label_section_w, L.h },
        );
        // Border around entire badge (for outline variant in split mode)
        if (colors.border) |b| {
            try list.print(
                allocator,
                "    <rect width=\"{d:.0}\" height=\"{d}\" fill=\"none\" stroke=\"{s}\" stroke-width=\"1\" rx=\"{d}\"/>\n",
                .{ L.total_w, L.h, b, L.r },
            );
        }
    } else {
        // Single background
        try list.print(
            allocator,
            "    <rect width=\"{d:.0}\" height=\"{d}\" fill=\"{s}\" rx=\"{d}\"",
            .{ L.total_w, L.h, colors.label_bg, L.r },
        );
        if (colors.border) |b| {
            try list.print(allocator, " stroke=\"{s}\" stroke-width=\"1\"", .{b});
        }
        try list.appendSlice(allocator, "/>\n");
    }

    // Status dot (if enabled)
    var current_x = L.left_padding;
    if (config.status_dot) {
        const dot_color = config.status_color orelse "#22c55e";
        const dot_r = @as(f32, @floatFromInt(L.fs)) * 0.25;
        const dot_cy = L.total_h / 2;
        try list.print(
            allocator,
            "    <circle cx=\"{d:.1}\" cy=\"{d:.1}\" r=\"{d:.1}\" fill=\"{s}\"/>\n",
            .{ current_x + dot_r, dot_cy, dot_r, dot_color },
        );
        current_x += dot_r * 2 + @as(f32, @floatFromInt(L.gap));
    }

    // Icon (if present)
    if (config.icon) |icon_path| {
        const icon_y = (L.total_h - @as(f32, @floatFromInt(L.icon_sz))) / 2;
        const icon_fill = config.icon_fill orelse colors.label_fg;
        try list.print(
            allocator,
            "    <path d=\"{s}\" fill=\"{s}\" transform=\"translate({d:.1},{d:.1}) scale({d:.2})\"/>\n",
            .{ icon_path, icon_fill, current_x, icon_y, @as(f32, @floatFromInt(L.icon_sz)) / 24.0 },
        );
        current_x += @as(f32, @floatFromInt(L.icon_sz)) + @as(f32, @floatFromInt(L.gap));
    }

    // Label text
    const label_fg = config.label_text_color orelse colors.label_fg;
    const label_y = L.total_h / 2 + @as(f32, @floatFromInt(L.fs)) * 0.35;
    try list.print(
        allocator,
        "    <text x=\"{d:.1}\" y=\"{d:.1}\" fill=\"{s}\" font-family=\"Inter, sans-serif\" font-size=\"{d}\" font-weight=\"500\" opacity=\"{d:.2}\">",
        .{ current_x, label_y, label_fg, L.fs, config.label_opacity },
    );
    try escapeXmlAppend(&list, allocator, config.label);
    try list.appendSlice(allocator, "</text>\n");

    // Value text
    const value_x = L.label_section_w + L.mid_gap / 2;
    const value_fg = config.value_color orelse colors.value_fg;
    try list.print(
        allocator,
        "    <text x=\"{d:.1}\" y=\"{d:.1}\" fill=\"{s}\" font-family=\"Inter, sans-serif\" font-size=\"{d}\" font-weight=\"500\">",
        .{ value_x, label_y, value_fg, L.fs },
    );
    try escapeXmlAppend(&list, allocator, config.value);
    try list.appendSlice(allocator, "</text>\n");

    try list.appendSlice(allocator, "    </g>\n");
    try list.appendSlice(allocator, "  </g>\n");

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

    // SVG header
    try list.print(
        allocator,
        "<svg xmlns=\"http://www.w3.org/2000/svg\" width=\"{d:.0}\" height=\"{d}\" role=\"img\" aria-label=\"{s} {s}\">\n",
        .{ L.total_w, L.h, config.label, config.value },
    );

    // Title for accessibility
    try list.print(allocator, "  <title>{s} {s}</title>\n", .{ config.label, config.value });

    const inner = try renderBadgeInner(allocator, config, "", 0);
    defer allocator.free(inner);
    try list.appendSlice(allocator, inner);

    try list.appendSlice(allocator, "</svg>");

    return try list.toOwnedSlice(allocator);
}

// ------------------------------------------------------------------
// XML escape helper (appends to ArrayList)
// ------------------------------------------------------------------

fn escapeXmlAppend(list: *std.ArrayList(u8), allocator: std.mem.Allocator, text: []const u8) !void {
    for (text) |c| {
        switch (c) {
            '&' => try list.appendSlice(allocator, "&amp;"),
            '<' => try list.appendSlice(allocator, "&lt;"),
            '>' => try list.appendSlice(allocator, "&gt;"),
            '"' => try list.appendSlice(allocator, "&quot;"),
            else => try list.append(allocator, c),
        }
    }
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
    try std.testing.expect(std.mem.indexOf(u8, svg, "npm") != null);
    try std.testing.expect(std.mem.indexOf(u8, svg, "v1.0.0") != null);
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

test "renderBadgeInner uses unique clip id" {
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
    };
    const inner = try renderBadgeInner(allocator, config, "_2", 40);
    defer allocator.free(inner);

    try std.testing.expect(std.mem.indexOf(u8, inner, "id=\"r_2\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, inner, "url(#r_2)") != null);
    try std.testing.expect(std.mem.indexOf(u8, inner, "translate(0,40)") != null);
}

test "escapeXml handles special chars" {
    var list: std.ArrayList(u8) = .empty;
    defer list.deinit(std.testing.allocator);
    try escapeXmlAppend(&list, std.testing.allocator, "a & b < c > d");
    try std.testing.expectEqualStrings("a &amp; b &lt; c &gt; d", list.items);
}
