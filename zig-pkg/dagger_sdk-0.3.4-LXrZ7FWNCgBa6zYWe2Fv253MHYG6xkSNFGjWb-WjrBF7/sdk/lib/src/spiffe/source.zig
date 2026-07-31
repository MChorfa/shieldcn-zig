//! SvidSource: the abstraction every SVID backend implements.
//!
//! Two backends are modeled in the SPIFFE layer:
//!   - ShelloutSource: calls `spire-agent api fetch` in a subprocess.
//!     Works today, requires the binary.
//!   - NativeWorkloadAPISource: pure-Zig gRPC client. Streams, no
//!     subprocess, zero external binary dep.
//!
//! Users code against the `SvidSource` vtable; swapping backends is a
//! one-line change at construction.
//!
//! ## Current surface
//!
//!   - `fetchX509SVID(allocator)` — one-shot X.509-SVID, caller owns.
//!   - `fetchJWTSVID(allocator, audiences)` — one-shot JWT-SVID.
//!   - `fetchX509Bundle(allocator)` — current trust bundle.
//!   - `close()` — tear down.
//!
//! Rotation via streaming (`watchX509SVID` returning a `Future<X509SVID>`)
//! is deferred alongside the native gRPC backend — it would require the
//! Future-of-error-union pattern which needs more validation against the
//! final 0.16 std.Io shape. For now, callers poll.

const std = @import("std");
const SpiffeID = @import("spiffe_id.zig").SpiffeID;
const svid_mod = @import("svid.zig");
const X509SVID = svid_mod.X509SVID;
const JWTSVID = svid_mod.JWTSVID;
const TrustBundle = svid_mod.TrustBundle;
const errs = @import("errors.zig");

/// How to locate the Workload API socket.
pub const SocketConfig = union(enum) {
    /// Use this exact path; error if unreachable.
    explicit: []const u8,

    /// Read $SPIFFE_ENDPOINT_SOCKET; error if unset.
    env_only,

    /// Try $SPIFFE_ENDPOINT_SOCKET, then /run/spire/sockets/agent.sock.
    env_then_default,

    /// Caller-provided resolver. Useful for Kubernetes Downward API,
    /// Consul service discovery, etc.
    custom: *const fn (std.mem.Allocator) anyerror![]const u8,

    pub const default_socket_path = "/run/spire/sockets/agent.sock";

    /// Resolve to a concrete path. Caller owns the returned slice.
    ///
    /// ## Zig 0.16 note
    ///
    /// 0.16 recommends calling `std.process.getEnvVarOwned` only from `main()`
    /// and threading values into library code. The `.env_only` and
    /// `.env_then_default` variants invoke it inside library code — this
    /// works (the API is still present in the stdlib) but libraries that
    /// want strict 0.16 compliance should resolve the env var at
    /// `main()`-level and pass `.explicit` or `.custom` here instead.
    ///
    /// v0.2 may deprecate `.env_only` / `.env_then_default` in favour of
    /// a callback-only design.
    pub fn resolve(self: SocketConfig, allocator: std.mem.Allocator) errs.SpiffeError![]const u8 {
        return switch (self) {
            .explicit => |p| allocator.dupe(u8, p) catch error.OutOfMemory,
            .env_only => std.process.getEnvVarOwned(allocator, "SPIFFE_ENDPOINT_SOCKET") catch {
                return error.SocketUnreachable;
            },
            .env_then_default => blk: {
                if (std.process.getEnvVarOwned(allocator, "SPIFFE_ENDPOINT_SOCKET")) |p| {
                    break :blk p;
                } else |_| {}
                break :blk allocator.dupe(u8, default_socket_path) catch error.OutOfMemory;
            },
            .custom => |f| f(allocator) catch error.SocketUnreachable,
        };
    }
};

/// Options passed to any SvidSource implementation at init.
pub const Options = struct {
    socket: SocketConfig = .env_then_default,

    /// If set, assert that every returned SVID has this trust domain.
    /// Mismatch = `error.TrustDomainMismatch`. This is the single biggest
    /// operational footgun in SPIFFE adoption: a misconfigured agent hands
    /// out the wrong domain and everyone authenticates to the wrong mesh.
    /// Set this in production.
    expected_trust_domain: ?[]const u8 = null,

    /// Interval between connectivity retries on initial connect failure.
    retry_interval_ms: u32 = 1000,

    /// How long to wait for the first SVID when starting up.
    initial_svid_timeout_ms: u32 = 30_000,
};

/// The SvidSource vtable. Implementations fill this in.
pub const SvidSource = struct {
    ptr: *anyopaque,
    vtable: *const VTable,

    pub const VTable = struct {
        /// Return the current X509-SVID (first in the list if multiple
        /// identities are registered; most common case is one).
        fetch_x509_svid: *const fn (ptr: *anyopaque, allocator: std.mem.Allocator) errs.SpiffeError!X509SVID,

        /// Request a JWT-SVID bound to the given audiences (OR semantics —
        /// the token is valid for any of them).
        fetch_jwt_svid: *const fn (ptr: *anyopaque, allocator: std.mem.Allocator, audiences: []const []const u8) errs.SpiffeError!JWTSVID,

        /// Fetch the X.509 trust bundle for our own trust domain.
        /// Multi-domain (federation) trust bundles are a future extension.
        fetch_x509_bundle: *const fn (ptr: *anyopaque, allocator: std.mem.Allocator) errs.SpiffeError!TrustBundle,

        /// Tear down. After close, all other calls return `error.AlreadyClosed`.
        close: *const fn (ptr: *anyopaque) void,
    };

    // Streaming rotation is deferred alongside the native gRPC backend.
    // Until then, callers who want rotation poll `fetchX509SVID` at their
    // preferred interval. The streaming API will land as `Future(X509SVID)`
    // (non-erroring; stream errors surface via a separate status channel)
    // to avoid the Future-of-error-union ambiguity.

    pub fn fetchX509SVID(self: SvidSource, allocator: std.mem.Allocator) errs.SpiffeError!X509SVID {
        return self.vtable.fetch_x509_svid(self.ptr, allocator);
    }

    pub fn fetchJWTSVID(self: SvidSource, allocator: std.mem.Allocator, audiences: []const []const u8) errs.SpiffeError!JWTSVID {
        return self.vtable.fetch_jwt_svid(self.ptr, allocator, audiences);
    }

    pub fn fetchX509Bundle(self: SvidSource, allocator: std.mem.Allocator) errs.SpiffeError!TrustBundle {
        return self.vtable.fetch_x509_bundle(self.ptr, allocator);
    }

    pub fn close(self: SvidSource) void {
        self.vtable.close(self.ptr);
    }
};

// ─────────────────────────── tests ──────────────────────────────────────

const testing = std.testing;

test "SocketConfig.explicit resolves to dup of input" {
    const cfg: SocketConfig = .{ .explicit = "/tmp/agent.sock" };
    const p = try cfg.resolve(testing.allocator);
    defer testing.allocator.free(p);
    try testing.expectEqualStrings("/tmp/agent.sock", p);
}

test "SocketConfig.env_then_default falls back" {
    // Unless SPIFFE_ENDPOINT_SOCKET is set in the test env (rare), we get the default.
    const cfg: SocketConfig = .env_then_default;
    const p = try cfg.resolve(testing.allocator);
    defer testing.allocator.free(p);
    // Either the env value (if someone set it) or the default. Both are valid.
    try testing.expect(p.len > 0);
}
