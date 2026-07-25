const std = @import("std");
const types = @import("../core/types.zig");
const svg = @import("svg.zig");

/// shieldcn-zig — render/group.zig
/// Badge group rendering — stacks N badges vertically into a single SVG
/// document. Each badge is emitted via `svg.renderBadgeInner` with a
/// unique `clipPath` id suffix and a cumulative y offset, so there are no
/// `id` collisions and no nested `<svg>` documents.
///
/// The outer SVG width is the max badge width; height is the sum of badge
/// heights plus `gap` pixels between consecutive badges.
pub const GroupOptions = struct {
    /// Vertical gap between badges in pixels.
    gap: u32 = 4,
};

/// Render a group of badges into one SVG document.
/// `configs` must be non-empty.
pub fn renderBadgeGroupSvg(
    allocator: std.mem.Allocator,
    configs: []const types.BadgeConfig,
    opts: GroupOptions,
) ![]const u8 {
    if (configs.len == 0) return error.EmptyGroup;

    // Compute layout: max width + total height with gaps between badges.
    var max_w: f32 = 0;
    var total_h: u32 = 0;
    var i: usize = 0;
    while (i < configs.len) : (i += 1) {
        const w = svg.badgeWidth(configs[i]);
        if (w > max_w) max_w = w;
        total_h += svg.badgeHeight(configs[i]);
        if (i + 1 < configs.len) total_h += opts.gap;
    }

    var list: std.ArrayList(u8) = .empty;
    errdefer list.deinit(allocator);

    try list.print(
        allocator,
        "<svg xmlns=\"http://www.w3.org/2000/svg\" width=\"{d:.0}\" height=\"{d}\" role=\"img\" aria-label=\"badge group\">\n",
        .{ max_w, total_h },
    );
    try list.appendSlice(allocator, "  <title>badge group</title>\n");

    var y_offset: u32 = 0;
    var idx_buf: [16]u8 = undefined;
    i = 0;
    while (i < configs.len) : (i += 1) {
        const suffix = std.fmt.bufPrint(&idx_buf, "_{d}", .{i}) catch "_x";
        const inner = try svg.renderBadgeInner(allocator, configs[i], suffix, y_offset);
        defer allocator.free(inner);
        try list.appendSlice(allocator, inner);

        y_offset += svg.badgeHeight(configs[i]);
        if (i + 1 < configs.len) y_offset += opts.gap;
    }

    try list.appendSlice(allocator, "</svg>");
    return try list.toOwnedSlice(allocator);
}

// ------------------------------------------------------------------
// Tests
// ------------------------------------------------------------------

fn resolvedColors() types.ResolvedColors {
    return .{
        .label_bg = "#27272a",
        .label_fg = "#fafafa",
        .value_bg = "#27272a",
        .value_fg = "#fafafa",
        .border = null,
    };
}

test "renderBadgeGroupSvg stacks two badges" {
    const allocator = std.testing.allocator;
    const configs = [_]types.BadgeConfig{
        .{ .label = "build", .value = "passing", .colors = resolvedColors() },
        .{ .label = "coverage", .value = "92%", .colors = resolvedColors() },
    };
    const out = try renderBadgeGroupSvg(allocator, &configs, .{ .gap = 4 });
    defer allocator.free(out);

    try std.testing.expect(std.mem.startsWith(u8, out, "<svg"));
    try std.testing.expect(std.mem.endsWith(u8, out, "</svg>"));
    // Two unique clip ids
    try std.testing.expect(std.mem.indexOf(u8, out, "id=\"r_0\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "id=\"r_1\"") != null);
    // Second badge translated by height + gap (28 + 4 = 32)
    try std.testing.expect(std.mem.indexOf(u8, out, "translate(0,32)") != null);
    // Both badges' content present
    try std.testing.expect(std.mem.indexOf(u8, out, "passing") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "coverage") != null);
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

test "renderBadgeGroupSvg single badge still composes" {
    const allocator = std.testing.allocator;
    const configs = [_]types.BadgeConfig{
        .{ .label = "a", .value = "b", .colors = resolvedColors() },
    };
    const out = try renderBadgeGroupSvg(allocator, &configs, .{});
    defer allocator.free(out);

    try std.testing.expect(std.mem.indexOf(u8, out, "id=\"r_0\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "translate(0,0)") != null);
}
