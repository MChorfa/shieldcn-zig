const std = @import("std");
const types = @import("../core/types.zig");
const hex_util = @import("../util/hex.zig");
const zigimg = @import("zigimg");

/// shieldcn-zig — render/png.zig
/// PNG rasterization pipeline: SVG badge → bitmap → PNG bytes.
/// Phase 8 implementation using z2d + zigimg (pure Zig stack).
///
/// Architecture:
///   1. Render badge to intermediate RGBA surface (z2d or manual)
///   2. Encode surface to PNG bytes (zigimg)
pub const RgbaSurface = struct {
    width: u32,
    height: u32,
    pixels: []u8, // RGBA interleaved

    pub fn init(allocator: std.mem.Allocator, width: u32, height: u32) !RgbaSurface {
        const pixels = try allocator.alloc(u8, width * height * 4);
        @memset(pixels, 0);
        return .{
            .width = width,
            .height = height,
            .pixels = pixels,
        };
    }

    pub fn deinit(self: *RgbaSurface, allocator: std.mem.Allocator) void {
        allocator.free(self.pixels);
    }

    pub fn setPixel(self: *RgbaSurface, x: u32, y: u32, r: u8, g: u8, b: u8, a: u8) void {
        if (x >= self.width or y >= self.height) return;
        const idx = (y * self.width + x) * 4;
        self.pixels[idx + 0] = r;
        self.pixels[idx + 1] = g;
        self.pixels[idx + 2] = b;
        self.pixels[idx + 3] = a;
    }
};

/// Render a badge config to a raw RGBA surface.
/// Pixel-perfect rounded rects, split sections, text bars, status dot, borders.
pub fn renderBadgeToSurface(
    allocator: std.mem.Allocator,
    config: types.BadgeConfig,
) !RgbaSurface {
    // Estimate text widths (heuristic: char ~ font_size * 0.6)
    const char_w = config.font_size * 6 / 10;
    const label_w: u32 = @intCast(@max(1, config.label.len) * char_w);
    const value_w: u32 = @intCast(@max(1, config.value.len) * char_w);
    const icon_w: u32 = if (config.icon != null) config.icon_size + config.gap else 0;
    const status_w: u32 = if (config.status_dot) config.gap + 8 else 0;

    const h: u32 = config.height;
    const pad: u32 = config.pad_x;
    const radius: u32 = config.radius;

    // Total width
    const split_gap: u32 = if (config.split) 1 else 0;
    const w = pad + icon_w + label_w + config.label_gap + split_gap + value_w + status_w + pad;

    var surface = try RgbaSurface.init(allocator, w, h);
    errdefer surface.deinit(allocator);

    // Parse colors
    const bg = parseColor(config.colors.label_bg);
    const fg = parseColor(config.colors.label_fg);
    const val_bg = parseColor(config.colors.value_bg);
    const val_fg = parseColor(config.colors.value_fg);
    const border_color = if (config.colors.border) |b| parseColor(b) else null;

    // Fill background (transparent for ghost, border color for outline, otherwise bg)
    if (config.style == .outline and border_color != null) {
        fillRoundedRect(&surface, 0, 0, w, h, radius, border_color.?);
        // Inner fill with background
        const bw: u32 = 1; // border width
        fillRoundedRect(&surface, bw, bw, w - 2 * bw, h - 2 * bw, if (radius > bw) radius - bw else 0, bg);
    } else if (config.style == .ghost) {
        // Transparent background — fill with nothing, just text bars later
    } else {
        fillRoundedRect(&surface, 0, 0, w, h, radius, bg);
    }

    if (config.split) {
        // Split badge: left half (label), right half (value)
        const mid = pad + icon_w + label_w + config.label_gap / 2;

        // Left rounded rect (label side)
        fillRoundedRectLeft(&surface, 0, 0, mid, h, radius, bg);

        // Right rounded rect (value side)
        fillRoundedRectRight(&surface, mid + 1, 0, w - mid - 1, h, radius, val_bg);

        // Draw label text bar
        const ly = (h - config.font_size) / 2;
        const lx = pad + icon_w;
        drawTextBar(&surface, lx, ly, label_w, config.font_size, fg);

        // Draw value text bar
        const vx = mid + 1 + pad;
        const vy = (h - config.font_size) / 2;
        drawTextBar(&surface, vx, vy, value_w, config.font_size, val_fg);
    } else {
        // Single-section badge
        const content_x = pad + icon_w;
        const content_y = (h - config.font_size) / 2;
        const total_text_w = label_w + config.label_gap + value_w;
        drawTextBar(&surface, content_x, content_y, total_text_w, config.font_size, fg);
    }

    // Status dot
    if (config.status_dot) {
        const dot_r: u32 = 4;
        const dot_x = w - pad - dot_r;
        const dot_y = h / 2;
        const dot_color = if (config.status_color) |c| parseColor(c) else Rgb{ .r = 0x22, .g = 0xc5, .b = 0x5e };
        fillCircle(&surface, dot_x, dot_y, dot_r, dot_color);
    }

    return surface;
}

fn drawTextBar(surface: *RgbaSurface, x: u32, y: u32, bar_w: u32, bar_h: u32, color: Rgb) void {
    // Placeholder: draw a rounded bar representing text
    const r: u32 = @min(bar_h / 2, 3);
    fillRoundedRect(surface, x, y, bar_w, bar_h, r, color);
}

fn fillRect(surface: *RgbaSurface, x: u32, y: u32, w: u32, h: u32, color: Rgb) void {
    const x1 = @min(x, surface.width);
    const y1 = @min(y, surface.height);
    const x2 = @min(x + w, surface.width);
    const y2 = @min(y + h, surface.height);
    for (y1..y2) |py| {
        for (x1..x2) |px| {
            surface.setPixel(@intCast(px), @intCast(py), color.r, color.g, color.b, 0xFF);
        }
    }
}

fn fillRoundedRect(surface: *RgbaSurface, x: u32, y: u32, w: u32, h: u32, r: u32, color: Rgb) void {
    if (r == 0) {
        fillRect(surface, x, y, w, h, color);
        return;
    }
    const x1 = @min(x, surface.width);
    const y1 = @min(y, surface.height);
    const x2 = @min(x + w, surface.width);
    const y2 = @min(y + h, surface.height);
    const rr = @min(r, w / 2, h / 2);

    for (y1..y2) |py| {
        for (x1..x2) |px| {
            const dx = if (px < x1 + rr) (x1 + rr) - px else if (px >= x2 - rr) px - (x2 - rr - 1) else 0;
            const dy = if (py < y1 + rr) (y1 + rr) - py else if (py >= y2 - rr) py - (y2 - rr - 1) else 0;
            const d2 = dx * dx + dy * dy;
            if (d2 <= rr * rr) {
                surface.setPixel(@intCast(px), @intCast(py), color.r, color.g, color.b, 0xFF);
            }
        }
    }
}

fn fillRoundedRectLeft(surface: *RgbaSurface, x: u32, y: u32, w: u32, h: u32, r: u32, color: Rgb) void {
    if (r == 0) {
        fillRect(surface, x, y, w, h, color);
        return;
    }
    const x1 = @min(x, surface.width);
    const y1 = @min(y, surface.height);
    const x2 = @min(x + w, surface.width);
    const y2 = @min(y + h, surface.height);
    const rr = @min(r, w / 2, h / 2);

    for (y1..y2) |py| {
        for (x1..x2) |px| {
            const dx = if (px < x1 + rr) (x1 + rr) - px else 0;
            const dy = if (py < y1 + rr) (y1 + rr) - py else if (py >= y2 - rr) py - (y2 - rr - 1) else 0;
            if (dx * dx + dy * dy <= rr * rr) {
                surface.setPixel(@intCast(px), @intCast(py), color.r, color.g, color.b, 0xFF);
            } else if (px >= x1 + rr) {
                surface.setPixel(@intCast(px), @intCast(py), color.r, color.g, color.b, 0xFF);
            }
        }
    }
}

fn fillRoundedRectRight(surface: *RgbaSurface, x: u32, y: u32, w: u32, h: u32, r: u32, color: Rgb) void {
    if (r == 0) {
        fillRect(surface, x, y, w, h, color);
        return;
    }
    const x1 = @min(x, surface.width);
    const y1 = @min(y, surface.height);
    const x2 = @min(x + w, surface.width);
    const y2 = @min(y + h, surface.height);
    const rr = @min(r, w / 2, h / 2);

    for (y1..y2) |py| {
        for (x1..x2) |px| {
            const dx = if (px >= x2 - rr) px - (x2 - rr - 1) else 0;
            const dy = if (py < y1 + rr) (y1 + rr) - py else if (py >= y2 - rr) py - (y2 - rr - 1) else 0;
            if (dx * dx + dy * dy <= rr * rr) {
                surface.setPixel(@intCast(px), @intCast(py), color.r, color.g, color.b, 0xFF);
            } else if (px < x2 - rr) {
                surface.setPixel(@intCast(px), @intCast(py), color.r, color.g, color.b, 0xFF);
            }
        }
    }
}

fn fillCircle(surface: *RgbaSurface, cx: u32, cy: u32, r: u32, color: Rgb) void {
    const x1 = if (cx > r) cx - r else 0;
    const y1 = if (cy > r) cy - r else 0;
    const x2 = @min(cx + r + 1, surface.width);
    const y2 = @min(cy + r + 1, surface.height);
    const rr = r * r;
    for (y1..y2) |py| {
        for (x1..x2) |px| {
            const dx = if (px > cx) px - cx else cx - px;
            const dy = if (py > cy) py - cy else cy - py;
            if (dx * dx + dy * dy <= rr) {
                surface.setPixel(@intCast(px), @intCast(py), color.r, color.g, color.b, 0xFF);
            }
        }
    }
}

const Rgb = struct { r: u8, g: u8, b: u8 };

fn parseColor(hex: []const u8) Rgb {
    if (std.mem.eql(u8, hex, "transparent")) return .{ .r = 0, .g = 0, .b = 0 };
    if (hex_util.parseHex(hex)) |rgb| return .{ .r = rgb.r, .g = rgb.g, .b = rgb.b };
    return .{ .r = 0x27, .g = 0x27, .b = 0x2a };
}

/// Encode an RGBA surface to PNG bytes using zigimg.
pub fn encodePng(
    allocator: std.mem.Allocator,
    surface: RgbaSurface,
) ![]const u8 {
    var image = try zigimg.Image.create(
        allocator,
        surface.width,
        surface.height,
        .rgba32,
    );
    defer image.deinit(allocator);

    // Copy RGBA pixels into zigimg Image
    const rgba_pixels = image.pixels.rgba32;
    for (rgba_pixels, 0..) |*pixel, i| {
        const idx = i * 4;
        pixel.r = surface.pixels[idx + 0];
        pixel.g = surface.pixels[idx + 1];
        pixel.b = surface.pixels[idx + 2];
        pixel.a = surface.pixels[idx + 3];
    }

    var write_buffer: [4096]u8 = undefined;
    const encoder_options = zigimg.Image.EncoderOptions{ .png = .{} };
    const png_bytes = try image.writeToMemory(allocator, &write_buffer, encoder_options);

    // writeToMemory returns a slice from its internal buffer, not allocator-owned.
    // Copy into a fresh heap allocation for the caller.
    const result = try allocator.dupe(u8, png_bytes);
    return result;
}

/// Write an RGBA surface to a PNG file using zigimg.
pub fn writeToPNGFile(
    allocator: std.mem.Allocator,
    surface: RgbaSurface,
    path: []const u8,
    io: std.Io,
) !void {
    var image = try zigimg.Image.create(
        allocator,
        surface.width,
        surface.height,
        .rgba32,
    );
    defer image.deinit(allocator);

    // Copy RGBA pixels into zigimg Image
    const rgba_pixels = image.pixels.rgba32;
    for (rgba_pixels, 0..) |*pixel, i| {
        const idx = i * 4;
        pixel.r = surface.pixels[idx + 0];
        pixel.g = surface.pixels[idx + 1];
        pixel.b = surface.pixels[idx + 2];
        pixel.a = surface.pixels[idx + 3];
    }

    var write_buffer: [4096]u8 = undefined;
    const encoder_options = zigimg.Image.EncoderOptions{ .png = .{} };
    try image.writeToFilePath(allocator, io, path, &write_buffer, encoder_options);
}

/// Convenience: render badge directly to PNG bytes.
pub fn renderBadgePng(
    allocator: std.mem.Allocator,
    config: types.BadgeConfig,
) ![]const u8 {
    var surface = try renderBadgeToSurface(allocator, config);
    defer surface.deinit(allocator);
    return try encodePng(allocator, surface);
}

// ------------------------------------------------------------------
// Tests
// ------------------------------------------------------------------

test "RgbaSurface init and setPixel" {
    const allocator = std.testing.allocator;
    var surface = try RgbaSurface.init(allocator, 4, 4);
    defer surface.deinit(allocator);

    surface.setPixel(1, 1, 0xFF, 0x00, 0x00, 0xFF);
    try std.testing.expectEqual(@as(u8, 0xFF), surface.pixels[20]); // (1,1) * 4 + 0
}

test "encodePng produces valid PNG" {
    const allocator = std.testing.allocator;
    var surface = try RgbaSurface.init(allocator, 2, 2);
    defer surface.deinit(allocator);

    // Set some pixels so the image has content
    surface.setPixel(0, 0, 0xFF, 0x00, 0x00, 0xFF);
    surface.setPixel(1, 1, 0x00, 0xFF, 0x00, 0xFF);

    const png = try encodePng(allocator, surface);
    defer allocator.free(png);

    // PNG magic signature
    try std.testing.expect(std.mem.startsWith(u8, png, &[_]u8{ 0x89, 'P', 'N', 'G' }));
    // Should be a reasonable size for a 2x2 PNG
    try std.testing.expect(png.len > 30);
}
