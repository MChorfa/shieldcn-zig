const std = @import("std");

/// shieldcn-zig — core/types.zig
/// Shared badge configuration and data types.

// ------------------------------------------------------------------
// Visual variants (shadcn Button variants)
// ------------------------------------------------------------------

pub const BadgeStyle = enum {
    default,
    secondary,
    outline,
    ghost,
    destructive,
    branded,

    pub fn fromString(str: []const u8) ?BadgeStyle {
        if (std.mem.eql(u8, str, "default")) return .default;
        if (std.mem.eql(u8, str, "secondary")) return .secondary;
        if (std.mem.eql(u8, str, "outline")) return .outline;
        if (std.mem.eql(u8, str, "ghost")) return .ghost;
        if (std.mem.eql(u8, str, "destructive")) return .destructive;
        if (std.mem.eql(u8, str, "branded")) return .branded;
        return null;
    }

    pub fn toString(self: BadgeStyle) []const u8 {
        return switch (self) {
            .default => "default",
            .secondary => "secondary",
            .outline => "outline",
            .ghost => "ghost",
            .destructive => "destructive",
            .branded => "branded",
        };
    }
};

// ------------------------------------------------------------------
// Badge sizes
// ------------------------------------------------------------------

pub const BadgeSize = enum {
    xs,
    sm,
    default,
    lg,

    pub fn fromString(str: []const u8) ?BadgeSize {
        if (std.mem.eql(u8, str, "xs")) return .xs;
        if (std.mem.eql(u8, str, "sm")) return .sm;
        if (std.mem.eql(u8, str, "default")) return .default;
        if (std.mem.eql(u8, str, "lg")) return .lg;
        return null;
    }
};

// ------------------------------------------------------------------
// Color mode
// ------------------------------------------------------------------

pub const ColorMode = enum {
    dark,
    light,

    pub fn fromString(str: []const u8) ?ColorMode {
        if (std.mem.eql(u8, str, "dark")) return .dark;
        if (std.mem.eql(u8, str, "light")) return .light;
        return null;
    }
};

// ------------------------------------------------------------------
// Font family
// ------------------------------------------------------------------

pub const BadgeFont = enum {
    inter,
    geist,
    geist_mono,

    pub fn fromString(str: []const u8) ?BadgeFont {
        if (std.mem.eql(u8, str, "inter")) return .inter;
        if (std.mem.eql(u8, str, "geist")) return .geist;
        if (std.mem.eql(u8, str, "geist-mono")) return .geist_mono;
        return null;
    }
};

// ------------------------------------------------------------------
// Resolved hex colors
// ------------------------------------------------------------------

pub const ResolvedColors = struct {
    label_bg: []const u8, // e.g. "#27272a"
    label_fg: []const u8,
    value_bg: []const u8,
    value_fg: []const u8,
    border: ?[]const u8,
};

// ------------------------------------------------------------------
// Full badge render configuration
// ------------------------------------------------------------------

pub const BadgeConfig = struct {
    label: []const u8,
    value: []const u8,
    icon: ?[]const u8 = null,
    icon_view_box: ?[]const u8 = null,
    icon_fill: ?[]const u8 = null,
    icon_paths: ?[][]const u8 = null,
    icon_is_stroke: bool = false,
    icon_stroke_width: f32 = 2.0,
    style: BadgeStyle = .default,
    size: BadgeSize = .sm,
    colors: ResolvedColors,
    status_color: ?[]const u8 = null,
    status_dot: bool = false,
    value_color: ?[]const u8 = null,
    label_text_color: ?[]const u8 = null,
    label_opacity: f32 = 0.85,
    height: u32 = 28,
    font_size: u32 = 12,
    radius: u32 = 6,
    pad_x: u32 = 10,
    icon_size: u32 = 14,
    gap: u32 = 5,
    label_gap: u32 = 6,
    split: bool = false,
    mode: ColorMode = .dark,
    brand_color: ?[]const u8 = null,
    font: BadgeFont = .inter,
    gradient: ?[]const u8 = null,
};

// ------------------------------------------------------------------
// Raw badge data from providers
// ------------------------------------------------------------------

pub const BadgeData = struct {
    label: []const u8,
    value: []const u8,
    color: ?[]const u8 = null,
    link: ?[]const u8 = null,
    allocator: ?std.mem.Allocator = null,
    owned_label: bool = false,
    owned_value: bool = false,
    owned_color: bool = false,
    owned_link: bool = false,

    pub fn deinit(self: BadgeData) void {
        const allocator = self.allocator orelse return;
        if (self.owned_label) allocator.free(self.label);
        if (self.owned_value) allocator.free(self.value);
        if (self.owned_color) if (self.color) |c| allocator.free(c);
        if (self.owned_link) if (self.link) |l| allocator.free(l);
    }
};

// ------------------------------------------------------------------
// Size presets
// ------------------------------------------------------------------

pub const SizePreset = struct {
    height: u32,
    font_size: u32,
    radius: u32,
    pad_x: u32,
    icon_size: u32,
    gap: u32,
    label_gap: u32,
};

pub fn getSizePreset(size: BadgeSize) SizePreset {
    return switch (size) {
        .xs => .{ .height = 20, .font_size = 10, .radius = 4, .pad_x = 6, .icon_size = 10, .gap = 3, .label_gap = 4 },
        .sm => .{ .height = 28, .font_size = 12, .radius = 6, .pad_x = 10, .icon_size = 14, .gap = 5, .label_gap = 6 },
        .default => .{ .height = 32, .font_size = 13, .radius = 6, .pad_x = 12, .icon_size = 16, .gap = 6, .label_gap = 7 },
        .lg => .{ .height = 40, .font_size = 14, .radius = 8, .pad_x = 16, .icon_size = 18, .gap = 7, .label_gap = 8 },
    };
}

// ------------------------------------------------------------------
// Tests
// ------------------------------------------------------------------

test "BadgeStyle parse roundtrip" {
    try std.testing.expectEqual(BadgeStyle.default, BadgeStyle.fromString("default").?);
    try std.testing.expectEqual(BadgeStyle.branded, BadgeStyle.fromString("branded").?);
    try std.testing.expectEqual(null, BadgeStyle.fromString("unknown"));
}

test "getSizePreset returns expected values" {
    const sm = getSizePreset(.sm);
    try std.testing.expectEqual(@as(u32, 28), sm.height);
    try std.testing.expectEqual(@as(u32, 12), sm.font_size);
}
