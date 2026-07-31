//! SVID types: X509SVID, JWTSVID, and TrustBundle.
//!
//! An SVID (SPIFFE Verifiable Identity Document) is the cryptographic proof
//! of a SPIFFE ID. Two forms:
//!
//!   - X509-SVID: a short-lived X.509 certificate whose URI SAN contains the
//!     SPIFFE ID. Used for mTLS. Paired with its private key.
//!   - JWT-SVID: a JWT signed by the trust domain's key, with the SPIFFE ID
//!     as the `sub` claim and audiences in `aud`. Used when mTLS isn't
//!     feasible (e.g., authenticating to an HTTP API).
//!
//! Both are short-lived (typically 1 hour, rotated before expiry).

const std = @import("std");
const SpiffeID = @import("spiffe_id.zig").SpiffeID;
const errs = @import("errors.zig");

/// An X.509-SVID: cert chain + private key + the peer trust bundle needed to
/// verify counterparties in this trust domain.
pub const X509SVID = struct {
    id: SpiffeID,
    /// Leaf cert first, intermediates following. DER-encoded.
    cert_chain_der: [][]const u8,
    /// Private key corresponding to the leaf cert. DER/PKCS#8.
    private_key_der: []const u8,
    /// Expiration of the leaf cert, as seconds since Unix epoch.
    expires_at_unix: i64,
    /// Allocator that owns all backing slices above. Used by deinit.
    allocator: std.mem.Allocator,

    pub fn deinit(self: *X509SVID) void {
        self.id.deinit(self.allocator);
        for (self.cert_chain_der) |c| self.allocator.free(c);
        self.allocator.free(self.cert_chain_der);
        self.allocator.free(self.private_key_der);
    }

    pub fn isExpired(self: X509SVID, now_unix: i64) bool {
        return now_unix >= self.expires_at_unix;
    }

    /// Time remaining until expiry, in seconds. Negative if already expired.
    pub fn ttlSeconds(self: X509SVID, now_unix: i64) i64 {
        return self.expires_at_unix - now_unix;
    }
};

/// A JWT-SVID: an opaque JWT string plus its parsed claims.
pub const JWTSVID = struct {
    id: SpiffeID,
    /// The full JWT, three base64url segments separated by '.'.
    token: []const u8,
    /// Audiences the token is valid for (aud claim).
    audiences: []const []const u8,
    /// Expiration from the exp claim.
    expires_at_unix: i64,
    allocator: std.mem.Allocator,

    pub fn deinit(self: *JWTSVID) void {
        self.id.deinit(self.allocator);
        self.allocator.free(self.token);
        for (self.audiences) |a| self.allocator.free(a);
        self.allocator.free(self.audiences);
    }

    pub fn isExpired(self: JWTSVID, now_unix: i64) bool {
        return now_unix >= self.expires_at_unix;
    }

    pub fn hasAudience(self: JWTSVID, aud: []const u8) bool {
        for (self.audiences) |a| if (std.mem.eql(u8, a, aud)) return true;
        return false;
    }
};

/// A trust bundle for an X.509 trust domain: the set of CA certs that sign
/// SVIDs in that domain. Used to verify peer SVIDs.
pub const TrustBundle = struct {
    /// The trust domain this bundle belongs to.
    trust_domain: []const u8,
    /// DER-encoded CA certs.
    ca_certs_der: [][]const u8,
    /// When the bundle's signing material was last refreshed (informational).
    refreshed_at_unix: i64,
    allocator: std.mem.Allocator,

    pub fn deinit(self: *TrustBundle) void {
        self.allocator.free(self.trust_domain);
        for (self.ca_certs_der) |c| self.allocator.free(c);
        self.allocator.free(self.ca_certs_der);
    }
};

// ─────────────────────────── tests ──────────────────────────────────────

const testing = std.testing;

test "X509SVID ttl math" {
    const a = testing.allocator;
    var id = try SpiffeID.parse(a, "spiffe://example.org/w");
    const svid: X509SVID = .{
        .id = id,
        .cert_chain_der = &.{},
        .private_key_der = &.{},
        .expires_at_unix = 1_000_000_000,
        .allocator = a,
    };
    _ = &id;
    try testing.expect(svid.isExpired(1_000_000_001));
    try testing.expect(!svid.isExpired(999_999_999));
    try testing.expectEqual(@as(i64, 100), svid.ttlSeconds(999_999_900));

    // Manually free since we constructed the SVID with empty slices.
    // (In real code, X509SVID.deinit would handle everything.)
    var id2 = svid.id;
    id2.deinit(a);
}

test "JWTSVID audience matching" {
    const a = testing.allocator;
    var id = try SpiffeID.parse(a, "spiffe://example.org/w");
    defer id.deinit(a);

    const token = try a.dupe(u8, "aaa.bbb.ccc");
    defer a.free(token);
    const auds_raw = [_][]const u8{ "https://vault.internal", "https://registry.internal" };
    const auds = try a.alloc([]const u8, 2);
    defer a.free(auds);
    for (auds_raw, 0..) |r, i| auds[i] = try a.dupe(u8, r);
    defer for (auds) |s| a.free(s);

    const jwt = JWTSVID{
        .id = id,
        .token = token,
        .audiences = auds,
        .expires_at_unix = 0,
        .allocator = a,
    };

    try testing.expect(jwt.hasAudience("https://vault.internal"));
    try testing.expect(!jwt.hasAudience("https://other"));
}
