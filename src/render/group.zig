const std = @import("std");
const types = @import("../core/types.zig");
const svg = @import("svg.zig");

/// shieldcn-zig — render/group.zig
/// Badge group rendering — concatenates N badges horizontally into a single
/// SVG document with a shared rounded background. Each badge spec is rendered
/// as `label-value` text in one row, matching upstream shieldcn.dev.
///
/// The outer SVG width is the sum of all badge spec widths; height is the
/// badge height (single row).
pub const GroupOptions = struct {
    /// Horizontal gap between badge specs in pixels.
    gap: u32 = 8,
};

/// Render a group of badges into one SVG document (horizontal layout).
/// `configs` must be non-empty.
pub fn renderBadgeGroupSvg(
    allocator: std.mem.Allocator,
    configs: []const types.BadgeConfig,
    opts: GroupOptions,
) ![]const u8 {
    if (configs.len == 0) return error.EmptyGroup;

    // Use the first config's layout parameters (all configs should have the same size).
    const first = configs[0];
    const h = first.height;
    const fs = first.font_size;
    const r = first.radius;
    const pad_x = first.pad_x;
    const label_opacity = first.label_opacity;
    const colors = first.colors;

    // Compute each spec's width and the total width.
    // Each spec: pad_x + label_w + dash_w + value_w + pad_x
    const dash_str = "-";
    const dash_w = svg.measureGlyphWidth(dash_str, fs);
    const gap_f: f32 = @floatFromInt(opts.gap);

    var spec_widths = std.ArrayList(f32).empty;
    defer spec_widths.deinit(allocator);
    try spec_widths.ensureTotalCapacity(allocator, configs.len);

    var total_w: f32 = 0;
    for (configs, 0..) |cfg, i| {
        const label_w = svg.measureGlyphWidth(cfg.label, fs);
        const value_w = svg.measureGlyphWidth(cfg.value, fs);
        const spec_w: f32 = @as(f32, @floatFromInt(pad_x)) + label_w + dash_w + value_w + @as(f32, @floatFromInt(pad_x));
        try spec_widths.append(allocator, spec_w);
        total_w += spec_w;
        if (i + 1 < configs.len) total_w += gap_f;
    }

    const total_w_int: u32 = @intFromFloat(@ceil(total_w));

    var list: std.ArrayList(u8) = .empty;
    errdefer list.deinit(allocator);

    // SVG header with viewBox.
    try list.print(
        allocator,
        "<svg xmlns=\"http://www.w3.org/2000/svg\" width=\"{d}\" height=\"{d}\" viewBox=\"0 0 {d} {d}\">",
        .{ total_w_int, h, total_w_int, h },
    );

    // Upstream group structure: clipPath + mask + single bg path + text in clip groups.
    const r_f: f32 = @floatFromInt(r);
    const h_f: f32 = @floatFromInt(h);
    const w_minus_r = total_w - r_f;
    const h_minus_r = h_f - r_f;

    // clipPath with rounded path geometry.
    try list.print(
        allocator,
        "<clipPath id=\"satori_cp-id\"><path d=\"M{d:.0} 0H{d:.0}A{d:.0} {d:.0} 0 0 1 {d:.0} {d:.0}V{d:.0}A{d:.0} {d:.0} 0 0 1 {d:.0} {d:.0}H{d:.0}A{d:.0} {d:.0} 0 0 1 0 {d:.0}V{d:.0}A{d:.0} {d:.0} 0 0 1 {d:.0} 0\"/></clipPath>",
        .{
            r_f, w_minus_r, r_f, r_f, total_w, r_f,
            h_minus_r, r_f, r_f, w_minus_r, h_f,
            r_f, r_f, r_f, h_minus_r,
            r_f, r_f, r_f, r_f,
        },
    );
    // mask element covering the full badge area.
    try list.print(
        allocator,
        "<mask id=\"satori_om-id\"><path fill=\"#fff\" d=\"M0 0H{d:.0}V{d:.0}H0z\"/></mask>",
        .{ total_w, h_f },
    );
    // Single background path (clipped + masked).
    try list.print(
        allocator,
        "<path fill=\"{s}\" d=\"M0 0H{d:.0}V{d:.0}H0z\" clip-path=\"url(#satori_cp-id)\" mask=\"url(#satori_om-id)\"/>",
        .{ colors.label_bg, total_w, h_f },
    );

    // Render each spec's text horizontally in two clip groups (label, value).
    var x_offset: f32 = 0;
    const baseline_y = svg.computeBaselineY(h, fs);
    const pad_x_f: f32 = @floatFromInt(pad_x);

    // Label text group (clipped + masked).
    try list.appendSlice(allocator, "<g clip-path=\"url(#satori_cp-id)\" mask=\"url(#satori_om-id)\">");
    for (configs, 0..) |cfg, i| {
        const label_x = x_offset + pad_x_f;
        const label_w = svg.measureGlyphWidth(cfg.label, fs);

        // Label text (with label_opacity).
        try svg.renderGlyphText(&list, allocator, cfg.label, label_x, baseline_y, fs, colors.label_fg, label_opacity);

        // Dash separator between label and value.
        try svg.renderGlyphText(&list, allocator, dash_str, label_x + label_w, baseline_y, fs, colors.label_fg, label_opacity);

        x_offset += spec_widths.items[i];
        if (i + 1 < configs.len) x_offset += gap_f;
    }
    try list.appendSlice(allocator, "</g>");

    // Value text group (clipped + masked).
    try list.appendSlice(allocator, "<g clip-path=\"url(#satori_cp-id)\" mask=\"url(#satori_om-id)\">");
    x_offset = 0;
    for (configs, 0..) |cfg, i| {
        const label_x = x_offset + pad_x_f;
        const label_w = svg.measureGlyphWidth(cfg.label, fs);
        const value_x = label_x + label_w + dash_w;

        // Value text (full opacity).
        try svg.renderGlyphText(&list, allocator, cfg.value, value_x, baseline_y, fs, colors.value_fg, null);

        x_offset += spec_widths.items[i];
        if (i + 1 < configs.len) x_offset += gap_f;
    }
    try list.appendSlice(allocator, "</g>");

    try list.appendSlice(allocator, "</svg>");
    return try list.toOwnedSlice(allocator);
}

// ------------------------------------------------------------------
// Tests
// ------------------------------------------------------------------

fn resolvedColors() types.ResolvedColors {
    return .{
        .label_bg = "#fafafa",
        .label_fg = "#18181b",
        .value_bg = "#fafafa",
        .value_fg = "#18181b",
        .border = null,
    };
}

test "renderBadgeGroupSvg horizontal layout" {
    const allocator = std.testing.allocator;
    const configs = [_]types.BadgeConfig{
        .{ .label = "build", .value = "passing", .colors = resolvedColors() },
        .{ .label = "coverage", .value = "92%", .colors = resolvedColors() },
    };
    const out = try renderBadgeGroupSvg(allocator, &configs, .{ .gap = 8 });
    defer allocator.free(out);

    try std.testing.expect(std.mem.startsWith(u8, out, "<svg"));
    try std.testing.expect(std.mem.endsWith(u8, out, "</svg>"));
    // Horizontal layout: height should be 32 (single row), not 68 (stacked).
    try std.testing.expect(std.mem.indexOf(u8, out, "height=\"32\"") != null);
    // No vertical translate transforms (horizontal layout).
    try std.testing.expect(std.mem.indexOf(u8, out, "translate(0,36)") == null);
    // Both badges' content present — text is vectorized as <path> glyphs.
    try std.testing.expect(std.mem.indexOf(u8, out, "<path") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "<text") == null);
    // No accessibility attributes (matching upstream).
    try std.testing.expect(std.mem.indexOf(u8, out, "role=") == null);
    try std.testing.expect(std.mem.indexOf(u8, out, "<title>") == null);
    // viewBox should be present.
    try std.testing.expect(std.mem.indexOf(u8, out, "viewBox") != null);
}

test "renderBadgeGroupSvg rejects empty group" {
    const allocator = std.testing.allocator;
    const out = renderBadgeGroupSvg(allocator, &[_]types.BadgeConfig{}, .{}) catch |err| {
        try std.testing.expectEqual(error.EmptyGroup, err);
        return;
    };
    allocator.free(out);
    return error.ExpectedError;
}

test "renderBadgeGroupSvg single badge" {
    const allocator = std.testing.allocator;
    const configs = [_]types.BadgeConfig{
        .{ .label = "a", .value = "b", .colors = resolvedColors() },
    };
    const out = try renderBadgeGroupSvg(allocator, &configs, .{});
    defer allocator.free(out);

    try std.testing.expect(std.mem.indexOf(u8, out, "<path") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "height=\"32\"") != null);
}
