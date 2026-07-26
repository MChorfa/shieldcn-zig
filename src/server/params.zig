const std = @import("std");
const types = @import("../core/types.zig");

/// shieldcn-zig — server/params.zig
/// Query string normalization and badge param extraction.
pub const BadgeParams = struct {
    variant: types.BadgeStyle = .default,
    size: types.BadgeSize = .sm,
    mode: types.ColorMode = .dark,
    font: types.BadgeFont = .inter,
    split: bool = false,
    status_dot: bool = false,
    logo: ?[]const u8 = null,
    logo_color: ?[]const u8 = null,
    color: ?[]const u8 = null,
    label_color: ?[]const u8 = null,
    value_color: ?[]const u8 = null,
    label_text_color: ?[]const u8 = null,
    label: ?[]const u8 = null,
    label_opacity: f32 = 0.85,
    gradient: ?[]const u8 = null,
    height: ?u32 = null,
    font_size: ?u32 = null,
    radius: ?u32 = null,
    pad_x: ?u32 = null,
    icon_size: ?u32 = null,
    gap: ?u32 = null,
    label_gap: ?u32 = null,
    theme: ?[]const u8 = null,
    tag: ?[]const u8 = null,
    period: ?[]const u8 = null,
};

/// Parse query string into BadgeParams. Keys are compared case-insensitively.
pub fn parseQueryString(allocator: std.mem.Allocator, query: []const u8) !BadgeParams {
    var params = BadgeParams{};

    var pairs = std.mem.splitScalar(u8, query, '&');
    while (pairs.next()) |pair| {
        if (pair.len == 0) continue;

        const eq = std.mem.indexOfScalar(u8, pair, '=') orelse continue;
        const key = pair[0..eq];
        const val = if (eq + 1 < pair.len) pair[eq + 1 ..] else "";

        const decoded = try decodeUrlComponent(allocator, val);
        errdefer allocator.free(decoded);

        if (eqlIgnoreCase(key, "variant")) {
            if (types.BadgeStyle.fromString(decoded)) |v| params.variant = v;
            allocator.free(decoded);
        } else if (eqlIgnoreCase(key, "size")) {
            if (types.BadgeSize.fromString(decoded)) |v| params.size = v;
            allocator.free(decoded);
        } else if (eqlIgnoreCase(key, "mode")) {
            if (types.ColorMode.fromString(decoded)) |v| params.mode = v;
            allocator.free(decoded);
        } else if (eqlIgnoreCase(key, "font")) {
            if (types.BadgeFont.fromString(decoded)) |v| params.font = v;
            allocator.free(decoded);
        } else if (eqlIgnoreCase(key, "split")) {
            params.split = eqlIgnoreCase(decoded, "true");
            allocator.free(decoded);
        } else if (eqlIgnoreCase(key, "statusDot")) {
            params.status_dot = eqlIgnoreCase(decoded, "true");
            allocator.free(decoded);
        } else if (eqlIgnoreCase(key, "logo")) {
            params.logo = decoded;
        } else if (eqlIgnoreCase(key, "logoColor")) {
            params.logo_color = decoded;
        } else if (eqlIgnoreCase(key, "color")) {
            params.color = decoded;
        } else if (eqlIgnoreCase(key, "labelColor")) {
            params.label_color = decoded;
        } else if (eqlIgnoreCase(key, "valueColor")) {
            params.value_color = decoded;
        } else if (eqlIgnoreCase(key, "labelTextColor")) {
            params.label_text_color = decoded;
        } else if (eqlIgnoreCase(key, "label")) {
            params.label = decoded;
        } else if (eqlIgnoreCase(key, "labelOpacity")) {
            params.label_opacity = std.fmt.parseFloat(f32, decoded) catch params.label_opacity;
            allocator.free(decoded);
        } else if (eqlIgnoreCase(key, "gradient")) {
            params.gradient = decoded;
        } else if (eqlIgnoreCase(key, "height")) {
            params.height = std.fmt.parseInt(u32, decoded, 10) catch null;
            allocator.free(decoded);
        } else if (eqlIgnoreCase(key, "fontSize")) {
            params.font_size = std.fmt.parseInt(u32, decoded, 10) catch null;
            allocator.free(decoded);
        } else if (eqlIgnoreCase(key, "radius")) {
            params.radius = std.fmt.parseInt(u32, decoded, 10) catch null;
            allocator.free(decoded);
        } else if (eqlIgnoreCase(key, "padX")) {
            params.pad_x = std.fmt.parseInt(u32, decoded, 10) catch null;
            allocator.free(decoded);
        } else if (eqlIgnoreCase(key, "iconSize")) {
            params.icon_size = std.fmt.parseInt(u32, decoded, 10) catch null;
            allocator.free(decoded);
        } else if (eqlIgnoreCase(key, "gap")) {
            params.gap = std.fmt.parseInt(u32, decoded, 10) catch null;
            allocator.free(decoded);
        } else if (eqlIgnoreCase(key, "labelGap")) {
            params.label_gap = std.fmt.parseInt(u32, decoded, 10) catch null;
            allocator.free(decoded);
        } else if (eqlIgnoreCase(key, "theme")) {
            params.theme = decoded;
        } else if (eqlIgnoreCase(key, "tag")) {
            params.tag = decoded;
        } else if (eqlIgnoreCase(key, "period")) {
            params.period = decoded;
        } else {
            allocator.free(decoded);
        }
    }

    return params;
}

fn eqlIgnoreCase(a: []const u8, b: []const u8) bool {
    if (a.len != b.len) return false;
    for (a, b) |ca, cb| {
        const la = std.ascii.toLower(ca);
        const lb = std.ascii.toLower(cb);
        if (la != lb) return false;
    }
    return true;
}

/// Simple percent-decode for URL query values.
fn decodeUrlComponent(allocator: std.mem.Allocator, input: []const u8) ![]const u8 {
    var result: std.ArrayList(u8) = .empty;
    errdefer result.deinit(allocator);

    var i: usize = 0;
    while (i < input.len) : (i += 1) {
        if (input[i] == '%' and i + 2 < input.len) {
            const hi = input[i + 1];
            const lo = input[i + 2];
            const byte = std.fmt.parseInt(u8, &[_]u8{ hi, lo }, 16) catch {
                try result.append(allocator, input[i]);
                continue;
            };
            try result.append(allocator, byte);
            i += 2;
        } else if (input[i] == '+') {
            try result.append(allocator, ' ');
        } else {
            try result.append(allocator, input[i]);
        }
    }

    return try result.toOwnedSlice(allocator);
}

// ------------------------------------------------------------------
// Tests
// ------------------------------------------------------------------

test "parseQueryString basic params" {
    const allocator = std.testing.allocator;
    const params = try parseQueryString(allocator, "variant=branded&color=ff6b6b&split=true");
    defer {
        if (params.logo) |l| allocator.free(l);
        if (params.logo_color) |l| allocator.free(l);
        if (params.color) |l| allocator.free(l);
        if (params.label_color) |l| allocator.free(l);
        if (params.value_color) |l| allocator.free(l);
        if (params.label_text_color) |l| allocator.free(l);
        if (params.label) |l| allocator.free(l);
        if (params.gradient) |l| allocator.free(l);
        if (params.theme) |l| allocator.free(l);
        if (params.tag) |l| allocator.free(l);
        if (params.period) |l| allocator.free(l);
    }

    try std.testing.expectEqual(types.BadgeStyle.branded, params.variant);
    try std.testing.expectEqualStrings("ff6b6b", params.color.?);
    try std.testing.expect(params.split);
}

test "decodeUrlComponent" {
    const allocator = std.testing.allocator;
    const decoded = try decodeUrlComponent(allocator, "hello%20world%21");
    defer allocator.free(decoded);
    try std.testing.expectEqualStrings("hello world!", decoded);
}
