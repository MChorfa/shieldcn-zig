const std = @import("std");
const types = @import("../core/types.zig");
const params = @import("params.zig");

/// shieldcn-zig — server/router.zig
/// URL path parsing: /{provider}/{...params}.svg → provider + slug segments.
pub const Route = struct {
    provider: []const u8,
    segments: [][]const u8,
    format: []const u8, // "svg", "png", "json"
    query: params.BadgeParams,

    pub fn deinit(self: *Route, allocator: std.mem.Allocator) void {
        for (self.segments) |s| allocator.free(s);
        allocator.free(self.segments);
        allocator.free(self.provider);
        allocator.free(self.format);
        if (self.query.logo) |l| allocator.free(l);
        if (self.query.logo_color) |l| allocator.free(l);
        if (self.query.color) |l| allocator.free(l);
        if (self.query.label_color) |l| allocator.free(l);
        if (self.query.value_color) |l| allocator.free(l);
        if (self.query.label_text_color) |l| allocator.free(l);
        if (self.query.label) |l| allocator.free(l);
        if (self.query.gradient) |l| allocator.free(l);
        if (self.query.theme) |l| allocator.free(l);
        if (self.query.tag) |l| allocator.free(l);
        if (self.query.period) |l| allocator.free(l);
    }
};

/// Parse a badge request path like "/npm/react.svg?variant=branded"
/// Returns Route with allocated strings; caller must call route.deinit().
pub fn parseBadgePath(
    allocator: std.mem.Allocator,
    path_with_query: []const u8,
) !Route {
    // Split path and query
    const qmark = std.mem.indexOfScalar(u8, path_with_query, '?');
    const raw_path = if (qmark) |qm| path_with_query[0..qm] else path_with_query;
    const raw_query = if (qmark) |qm| path_with_query[qm + 1 ..] else "";

    // Parse query params
    const query_params = try params.parseQueryString(allocator, raw_query);

    // Trim leading slash
    const path = if (raw_path.len > 0 and raw_path[0] == '/') raw_path[1..] else raw_path;

    // Split path segments
    var seg_iter = std.mem.splitScalar(u8, path, '/');
    var seg_list: std.ArrayList([]const u8) = .empty;
    errdefer {
        for (seg_list.items) |s| allocator.free(s);
        seg_list.deinit(allocator);
    }

    while (seg_iter.next()) |seg| {
        if (seg.len == 0) continue;
        const decoded = try decodePathSegment(allocator, seg);
        try seg_list.append(allocator, decoded);
    }

    if (seg_list.items.len == 0) {
        seg_list.deinit(allocator);
        return error.InvalidPath;
    }

    const segments = try seg_list.toOwnedSlice(allocator);

    // Last segment contains the format extension
    const last = segments[segments.len - 1];
    const dot = std.mem.lastIndexOfScalar(u8, last, '.');
    const format: []const u8 = if (dot) |d|
        try allocator.dupe(u8, last[d + 1 ..])
    else
        try allocator.dupe(u8, "svg");

    // Strip extension from last segment: dupe stripped version first, then free old
    if (dot) |d| {
        const stripped = try allocator.dupe(u8, last[0..d]);
        allocator.free(segments[segments.len - 1]);
        segments[segments.len - 1] = stripped;
    }

    const provider = try allocator.dupe(u8, segments[0]);

    return Route{
        .provider = provider,
        .segments = segments,
        .format = format,
        .query = query_params,
    };
}

/// Percent-decode a URL path segment (e.g. %25 → %, %20 → space).
/// Unlike query decoding, '+' is treated as a literal plus, not a space.
fn decodePathSegment(allocator: std.mem.Allocator, input: []const u8) ![]const u8 {
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
        } else {
            try result.append(allocator, input[i]);
        }
    }

    return try result.toOwnedSlice(allocator);
}

// ------------------------------------------------------------------
// Tests
// ------------------------------------------------------------------

test "parseBadgePath npm" {
    const allocator = std.testing.allocator;
    var route = try parseBadgePath(allocator, "/npm/react.svg?variant=branded");
    defer route.deinit(allocator);

    try std.testing.expectEqualStrings("npm", route.provider);
    try std.testing.expectEqualStrings("react", route.segments[1]);
    try std.testing.expectEqualStrings("svg", route.format);
    try std.testing.expectEqual(types.BadgeStyle.branded, route.query.variant);
}

test "parseBadgePath github stars" {
    const allocator = std.testing.allocator;
    var route = try parseBadgePath(allocator, "/github/stars/vercel/next.js.png");
    defer route.deinit(allocator);

    try std.testing.expectEqualStrings("github", route.provider);
    try std.testing.expectEqualStrings("stars", route.segments[1]);
    try std.testing.expectEqualStrings("vercel", route.segments[2]);
    try std.testing.expectEqualStrings("next.js", route.segments[3]);
    try std.testing.expectEqualStrings("png", route.format);
}

test "parseBadgePath static badge" {
    const allocator = std.testing.allocator;
    var route = try parseBadgePath(allocator, "/badge/build-passing-green.svg");
    defer route.deinit(allocator);

    try std.testing.expectEqualStrings("badge", route.provider);
    try std.testing.expectEqualStrings("build-passing-green", route.segments[1]);
}

test "parseBadgePath URL-decodes percent" {
    const allocator = std.testing.allocator;
    var route = try parseBadgePath(allocator, "/badge/coverage-92%25-blue.svg");
    defer route.deinit(allocator);

    try std.testing.expectEqualStrings("badge", route.provider);
    try std.testing.expectEqualStrings("coverage-92%-blue", route.segments[1]);
}
