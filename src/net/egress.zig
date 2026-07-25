const std = @import("std");

/// shieldcn-zig — net/egress.zig
/// CKODEX NET-FIL-WHIT: egress allowlist enforcement.
/// Only known provider API hostnames are permitted.
const ALLOWED_HOSTS = [_][]const u8{
    "registry.npmjs.org",
    "api.npmjs.org",
    "github.com",
    "api.github.com",
    "gitlab.com",
    "pypi.org",
    "crates.io",
    "hub.docker.com",
};

pub fn isAllowedHost(url: []const u8) bool {
    for (ALLOWED_HOSTS) |host| {
        if (std.mem.indexOf(u8, url, host) != null) return true;
    }
    return false;
}

// ------------------------------------------------------------------
// Tests
// ------------------------------------------------------------------

test "isAllowedHost permits npm" {
    try std.testing.expect(isAllowedHost("https://registry.npmjs.org/react/latest"));
}

test "isAllowedHost blocks unknown" {
    try std.testing.expect(!isAllowedHost("https://evil.com/data"));
}
