//! SPIFFE ↔ Dagger integration helpers.
//!
//! These are the "glue" APIs that make SPIFFE identities usable inside
//! Dagger pipelines. Kept in a separate file (not pulled into the core
//! SDK) so users who don't need SPIFFE don't pay for its dep graph.
//!
//! Two core helpers:
//!
//!   - `spiffeRegistryAuth` — exchange a SPIFFE SVID for a registry
//!     credential (typically via Vault cert-auth), then attach it to a
//!     Container with `withRegistryAuth`. Short-lived: each call produces
//!     a fresh credential.
//!
//!   - `VaultCertAuthProvider` — pluggable `CredentialProvider` that uses
//!     Vault's `cert` auth method. Swap for `OIDCProvider`, `AwsIamProvider`,
//!     etc. in users' own code.
//!
//! # Example
//!
//! ```zig
//! var shell = try spiffe.ShelloutSource.init(gpa, io, .{}, null);
//! defer shell.deinit();
//!
//! const ctr = try client.dag().container().from("registry.internal/tool:v1");
//! const authed = try integration.spiffeRegistryAuth(
//!     ctr, client, shell.source(),
//!     .{ .registry = "registry.internal", .vault_addr = "https://vault.internal" },
//! );
//! const digest = try authed.publish("registry.internal/output:v1");
//! ```

const std = @import("std");
const spiffe = @import("mod.zig");
const X509SVID = spiffe.X509SVID;
const JWTSVID = spiffe.JWTSVID;
const SvidSource = spiffe.SvidSource;
const SpiffeError = spiffe.SpiffeError;

const dagger = @import("../root.zig");

/// A provider produces a transient registry credential (username + secret)
/// given an SVID. Implementations wrap a specific secret store.
pub const CredentialProvider = struct {
    ptr: *anyopaque,
    vtable: *const VTable,

    pub const VTable = struct {
        /// Given an SVID, produce registry credentials. Caller owns both
        /// returned strings and frees via the passed allocator.
        issue_credentials: *const fn (
            ptr: *anyopaque,
            allocator: std.mem.Allocator,
            svid: X509SVID,
            registry: []const u8,
        ) CredentialProviderError!Credentials,
    };

    pub fn issueCredentials(
        self: CredentialProvider,
        allocator: std.mem.Allocator,
        svid: X509SVID,
        registry: []const u8,
    ) !Credentials {
        return self.vtable.issue_credentials(self.ptr, allocator, svid, registry);
    }
};

pub const CredentialProviderError = error{
    AuthFailed,
    ProviderUnavailable,
    InvalidResponse,
    OutOfMemory,
} || anyerror;

pub const Credentials = struct {
    username: []const u8, // owned
    password: []const u8, // owned; treat as sensitive
    allocator: std.mem.Allocator,

    pub fn deinit(self: *Credentials) void {
        self.allocator.free(self.username);
        // Overwrite before free — belt-and-suspenders for secret hygiene.
        // Zig doesn't guarantee the compiler won't optimize this out; a
        // future version can use @memset with volatile semantics when
        // available.
        const mutable = @constCast(self.password);
        @memset(mutable, 0);
        self.allocator.free(self.password);
    }
};

// ─────────────────────────── Vault cert-auth provider ─────────────────────

/// Exchange a SPIFFE X.509-SVID for short-lived registry credentials via
/// HashiCorp Vault's `cert` auth method + the Docker secrets engine.
///
/// ## Current status
///
/// The Vault HTTP integration itself is deferred: Vault's API is simple but
/// correct implementation requires TLS + JSON plumbing + error-code mapping
/// that we deliberately don't gold-plate until the native SPIFFE client is
/// ready. It shares the TLS layer with the SPIFFE client. For now,
/// `issueCredentials` returns `error.NotImplementedInV010`.
pub const VaultCertAuthProvider = struct {
    allocator: std.mem.Allocator,
    vault_addr: []const u8,
    role: []const u8,

    pub fn init(allocator: std.mem.Allocator, vault_addr: []const u8, role: []const u8) !VaultCertAuthProvider {
        return .{
            .allocator = allocator,
            .vault_addr = try allocator.dupe(u8, vault_addr),
            .role = try allocator.dupe(u8, role),
        };
    }

    pub fn deinit(self: *VaultCertAuthProvider) void {
        self.allocator.free(self.vault_addr);
        self.allocator.free(self.role);
    }

    pub fn provider(self: *VaultCertAuthProvider) CredentialProvider {
        return .{ .ptr = self, .vtable = &vtable };
    }

    const vtable: CredentialProvider.VTable = .{
        .issue_credentials = vIssue,
    };

    fn vIssue(
        ptr: *anyopaque,
        allocator: std.mem.Allocator,
        svid: X509SVID,
        registry: []const u8,
    ) CredentialProviderError!Credentials {
        const self: *VaultCertAuthProvider = @ptrCast(@alignCast(ptr));
        _ = self;
        _ = allocator;
        _ = svid;
        _ = registry;
        return error.NotImplementedInV010;
    }
};

// ─────────────────────────── the main sugar call ────────────────────────

pub const RegistryAuthOptions = struct {
    /// The registry hostname (e.g., "registry.internal").
    registry: []const u8,
    /// The credential provider. Default: VaultCertAuthProvider if both
    /// `vault_addr` and `vault_role` are set; error otherwise.
    provider: ?CredentialProvider = null,

    /// Convenience fields for the default provider. Ignored if `provider`
    /// is explicitly set.
    vault_addr: ?[]const u8 = null,
    vault_role: ?[]const u8 = null,
};

/// Attach SPIFFE-derived registry credentials to a Container. Fetches the
/// current X.509-SVID, exchanges it for registry credentials via the
/// configured provider, and calls `container.withRegistryAuth`.
///
/// Note: the credential is materialized as a one-shot `Secret` using
/// `dag.setSecret`. Rotation before the credential expires is the caller's
/// job (typical pattern: re-run this before each `publish`).
pub fn spiffeRegistryAuth(
    ctr: dagger.Container,
    client: *dagger.Client,
    source: SvidSource,
    opts: RegistryAuthOptions,
) !dagger.Container {
    _ = ctr;
    _ = opts;

    // Get the current SVID from the SPIFFE source.
    var svid = try source.fetchX509SVID(client.allocator);
    defer svid.deinit();

    // The current path can't proceed past here because
    // VaultCertAuthProvider.issue returns NotImplementedInV010. We surface
    // the same error through the integration layer so callers get a
    // consistent signal.
    return error.NotImplementedInV010;
}

// ─────────────────────────── tests ──────────────────────────────────────

const testing = std.testing;

test "VaultCertAuthProvider init/deinit" {
    var p = try VaultCertAuthProvider.init(
        testing.allocator,
        "https://vault.internal",
        "dagger-zig-ci",
    );
    defer p.deinit();

    const prov = p.provider();
    _ = prov; // just make sure vtable wires up
}

test "Credentials.deinit zeroes password" {
    const a = testing.allocator;
    const pw = try a.dupe(u8, "secret");
    var creds: Credentials = .{
        .username = try a.dupe(u8, "u"),
        .password = pw,
        .allocator = a,
    };
    // Can't check zeroing after free (UAF); but we can exercise the path.
    creds.deinit();
}
