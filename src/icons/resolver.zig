const std = @import("std");
const embedded = @import("embedded.zig");

/// shieldcn-zig — icons/resolver.zig
/// Icon resolution using embedded developer-icons data.
/// - Auto dark/light variant selection based on badge mode
/// - Wordmark variant support
/// - SVG path extraction with viewBox preservation
/// - Zero runtime file I/O — all icons baked into the binary
pub const IconVariant = enum {
    default,
    dark,
    light,
    wordmark,
    wordmark_dark,
    wordmark_light,
};

pub const IconInfo = struct {
    name: []const u8,
    data: []const u8,
    view_box: ?[]const u8,
    fill: ?[]const u8,
    stroke: ?[]const u8,
    variant: IconVariant,
};

/// Resolve an icon slug to embedded SVG bytes, considering dark/light mode.
/// Returns null if no matching icon is found.
pub fn resolveIcon(slug: []const u8, dark_mode: bool) ?[]const u8 {
    // Direct match first
    if (embedded.getEmbeddedIcon(slug)) |data| return data;

    // Try mode-specific variant
    const suffix = if (dark_mode) "-dark" else "-light";
    var buf: [64]u8 = undefined;
    if (slug.len + suffix.len < buf.len) {
        @memcpy(buf[0..slug.len], slug);
        @memcpy(buf[slug.len .. slug.len + suffix.len], suffix);
        const variant_slug = buf[0 .. slug.len + suffix.len];
        if (embedded.getEmbeddedIcon(variant_slug)) |data| return data;
    }

    // Try wordmark if requested (slug ends with -wordmark)
    if (std.mem.endsWith(u8, slug, "-wordmark")) {
        const base = slug[0 .. slug.len - 9];
        const wordmark_suffix = if (dark_mode) "-wordmark-dark" else "-wordmark-light";
        if (base.len + wordmark_suffix.len < buf.len) {
            @memcpy(buf[0..base.len], base);
            @memcpy(buf[base.len .. base.len + wordmark_suffix.len], wordmark_suffix);
            const wordmark_slug = buf[0 .. base.len + wordmark_suffix.len];
            if (embedded.getEmbeddedIcon(wordmark_slug)) |data| return data;
        }
    }

    return null;
}

/// Extract SVG path data and viewBox from raw SVG string
pub fn parseSvgPaths(allocator: std.mem.Allocator, svg_raw: []const u8) !ParsedSvg {
    var result = ParsedSvg{
        .view_box = null,
        .paths = std.ArrayList(SvgPath).empty,
    };
    errdefer result.deinit(allocator);

    // Extract viewBox
    if (std.mem.indexOf(u8, svg_raw, "viewBox=\"")) |start| {
        const vb_start = start + 9; // "viewBox="" is 9 chars
        if (std.mem.indexOfScalar(u8, svg_raw[vb_start..], '"')) |end| {
            const view_box = svg_raw[vb_start .. vb_start + end];
            result.view_box = try allocator.dupe(u8, view_box);
        }
    }

    // Extract path elements
    var i: usize = 0;
    while (i < svg_raw.len) {
        if (std.mem.indexOfPos(u8, svg_raw, i, "<path")) |path_start| {
            // Find fill attribute
            var fill: ?[]const u8 = null;
            if (std.mem.indexOfPos(u8, svg_raw, path_start, "fill=\"")) |fill_start| {
                const fs = fill_start + 6;
                if (std.mem.indexOfScalar(u8, svg_raw[fs..], '"')) |fill_end| {
                    const fill_val = svg_raw[fs .. fs + fill_end];
                    if (!std.mem.eql(u8, fill_val, "none")) {
                        fill = try allocator.dupe(u8, fill_val);
                    }
                }
            }

            // Find stroke attribute
            var stroke: ?[]const u8 = null;
            if (std.mem.indexOfPos(u8, svg_raw, path_start, "stroke=\"")) |stroke_start| {
                const ss = stroke_start + 7;
                if (std.mem.indexOfScalar(u8, svg_raw[ss..], '"')) |stroke_end| {
                    const stroke_val = svg_raw[ss .. ss + stroke_end];
                    if (!std.mem.eql(u8, stroke_val, "none")) {
                        stroke = try allocator.dupe(u8, stroke_val);
                    }
                }
            }

            // Find d attribute
            if (std.mem.indexOfPos(u8, svg_raw, path_start, "d=\"")) |d_start| {
                const ds = d_start + 3;
                if (std.mem.indexOfScalar(u8, svg_raw[ds..], '"')) |d_end| {
                    const path_data = svg_raw[ds .. ds + d_end];
                    const path = try allocator.dupe(u8, path_data);
                    try result.paths.append(allocator, .{
                        .d = path,
                        .fill = fill,
                        .stroke = stroke,
                    });
                    i = ds + d_end;
                    continue;
                }
            }
            i = path_start + 5;
        } else {
            break;
        }
    }

    return result;
}

pub const SvgPath = struct {
    d: []const u8,
    fill: ?[]const u8,
    stroke: ?[]const u8,
};

pub const ParsedSvg = struct {
    view_box: ?[]const u8,
    paths: std.ArrayList(SvgPath),

    pub fn deinit(self: *ParsedSvg, allocator: std.mem.Allocator) void {
        if (self.view_box) |vb| allocator.free(vb);
        for (self.paths.items) |path| {
            allocator.free(path.d);
            if (path.fill) |f| allocator.free(f);
            if (path.stroke) |s| allocator.free(s);
        }
        self.paths.deinit(allocator);
    }
};

// ------------------------------------------------------------------
// Tests
// ------------------------------------------------------------------

test "resolveIcon direct match returns embedded SVG" {
    const data = resolveIcon("reactjs", true);
    try std.testing.expect(data != null);
    try std.testing.expect(std.mem.startsWith(u8, data.?, "<svg"));
}

test "resolveIcon dark mode fallback returns embedded SVG" {
    // github has no generic, but has dark variant
    const dark = resolveIcon("github", true);
    try std.testing.expect(dark != null);
    try std.testing.expect(std.mem.startsWith(u8, dark.?, "<svg"));

    const light = resolveIcon("github", false);
    try std.testing.expect(light != null);
    try std.testing.expect(std.mem.startsWith(u8, light.?, "<svg"));
}

test "resolveIcon unknown returns null" {
    try std.testing.expectEqual(null, resolveIcon("nonexistent-icon-12345", true));
}

test "parseSvgPaths extracts viewBox and paths" {
    const allocator = std.testing.allocator;
    const svg = "<svg xmlns=\"http://www.w3.org/2000/svg\" viewBox=\"0 0 100 100\"><path fill=\"#61DAFB\" d=\"M50 50\"/></svg>";
    var parsed = try parseSvgPaths(allocator, svg);
    defer parsed.deinit(allocator);

    try std.testing.expectEqualStrings("0 0 100 100", parsed.view_box.?);
    try std.testing.expectEqual(@as(usize, 1), parsed.paths.items.len);
    try std.testing.expectEqualStrings("M50 50", parsed.paths.items[0].d);
    try std.testing.expectEqualStrings("#61DAFB", parsed.paths.items[0].fill.?);
}
