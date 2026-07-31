//! SPIFFE ID parsing and validation.
//!
//! Per the SPIFFE spec (https://github.com/spiffe/spiffe/blob/main/standards/SPIFFE-ID.md):
//!
//!   spiffe://<trust-domain>/<workload-identifier>
//!
//! Rules (strict, enforced here):
//!   - Scheme MUST be exactly "spiffe" (lowercase).
//!   - Trust domain: lowercase letters, digits, '.', '-', '_'. Length 1..255.
//!   - Path: a series of segments separated by '/'. Each segment is 1..n chars
//!     of ASCII letters, digits, '.', '-', '_'. A single '/' after the trust
//!     domain yields an empty path (trust-domain-only ID, legal).
//!   - No path segment may be "." or "..".
//!   - Total ID length MUST NOT exceed 2048 octets.
//!   - No userinfo, query, fragment, port. No percent-encoding allowed.
//!
//! We deliberately reject anything the spec says "MUST NOT" on, even if some
//! implementations are lenient. In a zero-trust setting, lenient parsing is a
//! vulnerability.

const std = @import("std");
const errs = @import("errors.zig");

pub const SpiffeID = struct {
    /// Backing storage for the raw spiffe:// URI. Owned.
    raw: []const u8,
    /// Offset into `raw` where the trust domain starts (always 9 for "spiffe://")
    td_start: usize,
    /// Offset into `raw` where the path starts (after the trust domain's '/').
    /// Equals raw.len if there is no path.
    path_start: usize,

    pub const max_length: usize = 2048;
    pub const max_trust_domain_length: usize = 255;

    /// Parse and validate a SPIFFE ID. Returns an owned SpiffeID (backing
    /// store is a duped copy of `input`).
    pub fn parse(allocator: std.mem.Allocator, input: []const u8) errs.SpiffeError!SpiffeID {
        if (input.len == 0) return error.EmptyId;
        if (input.len > max_length) return error.IdTooLong;

        const scheme_prefix = "spiffe://";
        if (!std.mem.startsWith(u8, input, scheme_prefix)) return error.BadScheme;

        // Find end of trust domain: first '/' after the prefix, or end of string.
        const td_start = scheme_prefix.len;
        var td_end: usize = input.len;
        for (input[td_start..], 0..) |c, i| {
            if (c == '/') {
                td_end = td_start + i;
                break;
            }
        }

        if (td_end == td_start) return error.EmptyTrustDomain;
        if (td_end - td_start > max_trust_domain_length) return error.TrustDomainTooLong;

        // Validate trust-domain chars.
        for (input[td_start..td_end]) |c| {
            if (!isTrustDomainChar(c)) return error.InvalidTrustDomainChar;
        }

        const path_start = if (td_end < input.len) td_end + 1 else input.len;

        // Validate path: segments separated by '/', no empty segments, no '.' or '..'.
        if (path_start < input.len) {
            var seg_start = path_start;
            var i = path_start;
            while (i <= input.len) : (i += 1) {
                const at_end = i == input.len;
                const is_sep = !at_end and input[i] == '/';
                if (at_end or is_sep) {
                    const seg = input[seg_start..i];
                    if (seg.len == 0) return error.EmptyPathSegment;
                    if (std.mem.eql(u8, seg, ".") or std.mem.eql(u8, seg, "..")) {
                        return error.InvalidPathSegment;
                    }
                    for (seg) |c| {
                        if (!isPathSegmentChar(c)) return error.InvalidPathChar;
                    }
                    seg_start = i + 1;
                }
            }
        }

        const raw = try allocator.dupe(u8, input);
        return .{
            .raw = raw,
            .td_start = td_start,
            .path_start = path_start,
        };
    }

    pub fn deinit(self: *SpiffeID, allocator: std.mem.Allocator) void {
        allocator.free(self.raw);
    }

    /// The trust domain slice, e.g. "example.org".
    pub fn trustDomain(self: SpiffeID) []const u8 {
        // td ends at path_start - 1 if path exists, else at end of raw.
        const td_end = if (self.path_start < self.raw.len) self.path_start - 1 else self.raw.len;
        return self.raw[self.td_start..td_end];
    }

    /// The path slice, e.g. "workloads/payments-svc". Empty if no path.
    pub fn path(self: SpiffeID) []const u8 {
        if (self.path_start >= self.raw.len) return "";
        return self.raw[self.path_start..];
    }

    pub fn eql(self: SpiffeID, other: SpiffeID) bool {
        return std.mem.eql(u8, self.raw, other.raw);
    }

    pub fn format(self: SpiffeID, writer: anytype) !void {
        try writer.writeAll(self.raw);
    }
};

fn isTrustDomainChar(c: u8) bool {
    return (c >= 'a' and c <= 'z') or
        (c >= '0' and c <= '9') or
        c == '.' or c == '-' or c == '_';
}

fn isPathSegmentChar(c: u8) bool {
    return (c >= 'a' and c <= 'z') or
        (c >= 'A' and c <= 'Z') or
        (c >= '0' and c <= '9') or
        c == '.' or c == '-' or c == '_';
}

// ─────────────────────────── tests ──────────────────────────────────────

const testing = std.testing;

test "parse valid trust-domain-only id" {
    var id = try SpiffeID.parse(testing.allocator, "spiffe://example.org");
    defer id.deinit(testing.allocator);
    try testing.expectEqualStrings("example.org", id.trustDomain());
    try testing.expectEqualStrings("", id.path());
}

test "parse id with multi-segment path" {
    var id = try SpiffeID.parse(testing.allocator, "spiffe://MChorfa.internal/cortaix/tenant/acme/module/ci");
    defer id.deinit(testing.allocator);
    try testing.expectEqualStrings("MChorfa.internal", id.trustDomain());
    try testing.expectEqualStrings("cortaix/tenant/acme/module/ci", id.path());
}

test "reject uppercase in trust domain" {
    try testing.expectError(
        error.InvalidTrustDomainChar,
        SpiffeID.parse(testing.allocator, "spiffe://Example.org/foo"),
    );
}

test "reject empty trust domain" {
    try testing.expectError(
        error.EmptyTrustDomain,
        SpiffeID.parse(testing.allocator, "spiffe:///foo"),
    );
}

test "reject wrong scheme" {
    try testing.expectError(
        error.BadScheme,
        SpiffeID.parse(testing.allocator, "https://example.org/foo"),
    );
}

test "reject dot segments" {
    try testing.expectError(
        error.InvalidPathSegment,
        SpiffeID.parse(testing.allocator, "spiffe://example.org/a/./b"),
    );
    try testing.expectError(
        error.InvalidPathSegment,
        SpiffeID.parse(testing.allocator, "spiffe://example.org/a/../b"),
    );
}

test "reject empty path segment (double slash)" {
    try testing.expectError(
        error.EmptyPathSegment,
        SpiffeID.parse(testing.allocator, "spiffe://example.org/a//b"),
    );
}

test "reject oversize id" {
    var big: [3000]u8 = undefined;
    @memcpy(big[0..9], "spiffe://");
    @memset(big[9..], 'a');
    try testing.expectError(
        error.IdTooLong,
        SpiffeID.parse(testing.allocator, &big),
    );
}

test "equality" {
    var a = try SpiffeID.parse(testing.allocator, "spiffe://example.org/foo");
    defer a.deinit(testing.allocator);
    var b = try SpiffeID.parse(testing.allocator, "spiffe://example.org/foo");
    defer b.deinit(testing.allocator);
    var c = try SpiffeID.parse(testing.allocator, "spiffe://example.org/bar");
    defer c.deinit(testing.allocator);
    try testing.expect(a.eql(b));
    try testing.expect(!a.eql(c));
}
