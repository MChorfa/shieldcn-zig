const std = @import("std");
const resolver = @import("resolver.zig");

/// shieldcn-zig — icons/auto.zig
/// Auto-icon resolution: maps (provider, topic) → icon slug or inline path.
///
/// When no `?logo=` query param is present, the engine picks a sensible
/// default icon based on the route:
///   /npm/{pkg}        → npm logo
///   /github/stars/... → star icon
///   /github/forks/... → fork icon
///   /github/issues/...→ issue icon
///   /github/license/..→ scale icon
///   /github/ci/...    → check icon
///   /github/last-commit → commit icon
///   /github/contributors → people icon
///   /gitlab/...       → gitlab logo
///
/// Icons not in the embedded developer-icons set (star, fork, issue, etc.)
/// are provided as inline 24×24 viewBox fill paths below.

pub const InlineIcon = struct {
    slug: []const u8,
    /// SVG path d-string, designed for a 24×24 viewBox, fill-based.
    path: []const u8,
};

/// Inline icons for GitHub metrics (Octicon-derived, MIT licensed).
/// These are not in the developer-icons set.
pub const inline_icons = [_]InlineIcon{
    .{ .slug = "star", .path = "M12.7.7 15.7 6.9 22.6 7.9A1 1 0 0 1 23 9L18 14 19.2 20.8A1 1 0 0 1 18.2 21.6L12 18.3 5.9 21.6A.8.8 0 0 1 4.8 20.8L6 14 1 9A1 1 0 0 1 1.4 8L8.3 6.9 11.3.7A.8.8 0 0 1 12.7.7" },
    .{ .slug = "fork", .path = "M5 5.372v.878c0 .414.336.75.75.75h4.5a.75.75 0 0 0 .75-.75v-.878a2.25 2.25 0 1 1 1.5 0v.878a2.25 2.25 0 0 1-2.25 2.25h-1.5v2.128a2.251 2.251 0 1 1-1.5 0V8.5h-1.5A2.25 2.25 0 0 1 3.5 6.25v-.878a2.25 2.25 0 1 1 1.5 0ZM5 3.25a.75.75 0 1 0-1.5 0 .75.75 0 0 0 1.5 0Zm6.75.75a.75.75 0 1 0 0-1.5.75.75 0 0 0 0 1.5Zm-3 8.75a.75.75 0 1 0-1.5 0 .75.75 0 0 0 1.5 0Z" },
    .{ .slug = "issue", .path = "M12 9.5a1.5 1.5 0 1 0 0-3 1.5 1.5 0 0 0 0 3ZM12 0a8 8 0 1 1 0 16A8 8 0 0 1 12 0ZM1.5 8a6.5 6.5 0 1 0 13 0 6.5 6.5 0 0 0-13 0Z" },
    .{ .slug = "scale", .path = "M8 1.5c-.966 0-1.75.784-1.75 1.75v.5H4.5A1.5 1.5 0 0 0 3 5.25v1.5a1.5 1.5 0 0 0 1.5 1.5h.585l1.586 4.243a.75.75 0 0 0 1.414-.486L6.47 8.25h3.06l-1.115 2.982a.75.75 0 0 0 1.414.486l1.586-4.243h.585a1.5 1.5 0 0 0 1.5-1.5v-1.5a1.5 1.5 0 0 0-1.5-1.5h-1.75v-.5c0-.966-.784-1.75-1.75-1.75h-1Z M12 13.5a.75.75 0 0 0 0 1.5h.25a.75.75 0 0 0 0-1.5H12Z" },
    .{ .slug = "check", .path = "M9.999 16.219a.75.75 0 0 1-1.06 0l-3.5-3.5a.75.75 0 1 1 1.06-1.06l2.97 2.97 7.5-7.5a.75.75 0 1 1 1.06 1.06l-8.03 8.03Z M12 1a11 11 0 1 0 0 22 11 11 0 0 0 0-22ZM3.25 12a8.75 8.75 0 1 1 17.5 0 8.75 8.75 0 0 1-17.5 0Z" },
    .{ .slug = "commit", .path = "M15.5 11.75a3.5 3.5 0 1 1-7 0 3.5 3.5 0 0 1 7 0Z M12 0a.75.75 0 0 1 .75.75v4.5a.75.75 0 0 1-1.5 0v-4.5A.75.75 0 0 1 12 0Z M12 18a.75.75 0 0 1 .75.75v4.5a.75.75 0 0 1-1.5 0v-4.5A.75.75 0 0 1 12 18Z M3 11.25a.75.75 0 0 1 .75-.75h4.5a.75.75 0 0 1 0 1.5h-4.5a.75.75 0 0 1-.75-.75Z M15.75 11.25a.75.75 0 0 1 .75-.75h4.5a.75.75 0 0 1 0 1.5h-4.5a.75.75 0 0 1-.75-.75Z" },
    .{ .slug = "people", .path = "M5.5 3.5a2 2 0 1 1 0 4 2 2 0 0 1 0-4Z M2 9a2.5 2.5 0 0 1 2.5-2.5h2A2.5 2.5 0 0 1 9 9v.5a.5.5 0 0 1-.5.5h-5a.5.5 0 0 1-.5-.5V9Z M14.5 3.5a2 2 0 1 1 0 4 2 2 0 0 1 0-4Z M11 9a2.5 2.5 0 0 1 2.5-2.5h2A2.5 2.5 0 0 1 18 9v.5a.5.5 0 0 1-.5.5h-5a.5.5 0 0 1-.5-.5V9Z M8 14a3 3 0 0 1 3-3h2a3 3 0 0 1 3 3v.5a.5.5 0 0 1-.5.5h-7a.5.5 0 0 1-.5-.5V14Z" },
    .{ .slug = "zig", .path = "M23.5 1 15.8 4.5H8.8L5.8 7.9H13L.5 23 8.2 19.5H15.2L18.2 15.9H11zM0 4.5V19.4H1.9L4.9 15.9H3.5V8H4.4L7.2 4.5zM22.1 4.5 19.1 8H20.5V15.9H19.6L16.6 19.4H24V4.4z" },
    .{ .slug = "dagger", .path = "M12 2L8 6v4l4-2 4 2V6l-4-4Z M8 12v6l4 4 4-4v-6l-4 2-4-2Z" },
    .{ .slug = "lock", .path = "M6 10V8a6 6 0 1 1 12 0v2h1a2 2 0 0 1 2 2v8a2 2 0 0 1-2 2H5a2 2 0 0 1-2-2v-8a2 2 0 0 1 2-2h1Z M8 8a4 4 0 1 1 8 0v2H8V8Z M12 15a2 2 0 0 0-1 3.732V21a1 1 0 1 0 2 0v-2.268A2 2 0 0 0 12 15Z" },
    .{ .slug = "shield", .path = "M12 1L3 5v6c0 5.55 3.84 10.74 9 12 5.16-1.26 9-6.45 9-12V5l-9-4Z M12 3.18l6 2.67v5.15c0 4.5-2.98 8.42-6 9.35-3.02-.93-6-4.85-6-9.35V5.85l6-2.67Z" },
    .{ .slug = "offline", .path = "M12 2C6.48 2 2 6.48 2 12s4.48 10 10 10 10-4.48 10-10S17.52 2 12 2Z M12 4c4.41 0 8 3.59 8 8 0 1.85-.63 3.55-1.69 4.9L7.1 5.69C8.45 4.63 10.15 4 12 4Z M5.69 7.1L16.9 18.31C15.55 19.37 13.85 20 12 20c-4.41 0-8-3.59-8-8 0-1.85.63-3.55 1.69-4.9Z" },
};

/// Look up an inline icon by slug.
pub fn getInlineIcon(slug: []const u8) ?[]const u8 {
    for (inline_icons) |icon| {
        if (std.mem.eql(u8, icon.slug, slug)) return icon.path;
    }
    return null;
}

/// Resolve an auto-icon for a given provider and optional topic.
/// Returns the icon slug to use (for embedded lookup) or an inline path.
/// Returns null if no auto-icon is appropriate.
pub const AutoIconResult = struct {
    /// Slug for embedded icon lookup (e.g. "npm", "github", "gitlab")
    embedded_slug: ?[]const u8 = null,
    /// Slug for inline icon lookup (e.g. "star", "fork", "issue")
    inline_slug: ?[]const u8 = null,
};

pub fn resolveAutoIcon(provider: []const u8, topic: ?[]const u8) ?AutoIconResult {
    // Provider-level auto-icons (no topic needed)
    if (std.mem.eql(u8, provider, "npm")) {
        return .{ .embedded_slug = "npm" };
    }
    if (std.mem.eql(u8, provider, "gitlab")) {
        return .{ .embedded_slug = "gitlab" };
    }
    if (std.mem.eql(u8, provider, "github")) {
        // GitHub provider: use github icon by default, or topic-specific icon
        if (topic) |t| {
            if (std.mem.eql(u8, t, "stars")) return .{ .inline_slug = "star" };
            if (std.mem.eql(u8, t, "forks")) return .{ .inline_slug = "fork" };
            if (std.mem.eql(u8, t, "issues")) return .{ .inline_slug = "issue" };
            if (std.mem.eql(u8, t, "license")) return .{ .inline_slug = "scale" };
            if (std.mem.eql(u8, t, "ci")) return .{ .inline_slug = "check" };
            if (std.mem.eql(u8, t, "last-commit")) return .{ .inline_slug = "commit" };
            if (std.mem.eql(u8, t, "contributors")) return .{ .inline_slug = "people" };
            if (std.mem.eql(u8, t, "watchers")) return .{ .inline_slug = "people" };
            if (std.mem.eql(u8, t, "releases")) return .{ .inline_slug = "check" };
            if (std.mem.eql(u8, t, "downloads")) return .{ .inline_slug = "check" };
        }
        return .{ .embedded_slug = "github" };
    }
    return null;
}

/// Full resolution: given provider, topic, and user-supplied logo param,
/// return the SVG path data for the icon (or null if no icon).
/// `dark_mode` controls which embedded variant to try.
pub fn resolveIconPath(
    provider: []const u8,
    topic: ?[]const u8,
    user_logo: ?[]const u8,
    dark_mode: bool,
) ?[]const u8 {
    // 1. User-supplied logo takes precedence
    if (user_logo) |logo| {
        // Try embedded first
        if (resolver.resolveIcon(logo, dark_mode)) |_| {
            // Caller will handle embedded SVG extraction; return the slug
            // so the caller knows to use the embedded path.
            // For now, return the inline path if it exists, else null
            // (embedded icons need SVG parsing which is handled elsewhere).
            if (getInlineIcon(logo)) |path| return path;
            return null; // embedded — handled by caller
        }
        // Try inline
        if (getInlineIcon(logo)) |path| return path;
        return null;
    }

    // 2. Auto-icon based on provider/topic
    if (resolveAutoIcon(provider, topic)) |result| {
        if (result.inline_slug) |slug| {
            if (getInlineIcon(slug)) |path| return path;
        }
        // embedded_slug is handled by the caller (needs SVG path extraction)
        return null;
    }

    return null;
}

// ------------------------------------------------------------------
// Tests
// ------------------------------------------------------------------

test "getInlineIcon star" {
    const path = getInlineIcon("star");
    try std.testing.expect(path != null);
    try std.testing.expect(std.mem.startsWith(u8, path.?, "M12.7"));
}

test "getInlineIcon unknown returns null" {
    try std.testing.expectEqual(null, getInlineIcon("nonexistent"));
}

test "resolveAutoIcon github stars" {
    const result = resolveAutoIcon("github", "stars");
    try std.testing.expect(result != null);
    try std.testing.expectEqualStrings("star", result.?.inline_slug.?);
}

test "resolveAutoIcon npm" {
    const result = resolveAutoIcon("npm", null);
    try std.testing.expect(result != null);
    try std.testing.expectEqualStrings("npm", result.?.embedded_slug.?);
}

test "resolveAutoIcon unknown provider" {
    try std.testing.expectEqual(null, resolveAutoIcon("unknown", null));
}
