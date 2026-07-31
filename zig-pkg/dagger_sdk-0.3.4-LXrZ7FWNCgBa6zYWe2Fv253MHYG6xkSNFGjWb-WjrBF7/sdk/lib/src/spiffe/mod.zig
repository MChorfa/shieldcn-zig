//! SPIFFE subsystem — public surface.
//!
//! ```zig
//! const spiffe = @import("dagger_sdk").spiffe;
//!
//! // Use the shellout backend when SPIFFE is enabled
//! var shell = try spiffe.ShelloutSource.init(gpa, io, .{}, null);
//! defer shell.deinit();
//!
//! const src = shell.source(); // a SvidSource
//! var svid = try src.fetchX509SVID(gpa);
//! defer svid.deinit();
//! ```
//!
//! Swap `ShelloutSource` for `NativeWorkloadAPISource` when the native Workload
//! API is ready. The public `SvidSource` interface stays the same.
//!
//! See `docs/spiffe.md` for integration patterns (Vault cert-auth, registry
//! credentials, etc.) and the SPIFFE source files for the native backend.

pub const SpiffeID = @import("spiffe_id.zig").SpiffeID;
pub const X509SVID = @import("svid.zig").X509SVID;
pub const JWTSVID = @import("svid.zig").JWTSVID;
pub const TrustBundle = @import("svid.zig").TrustBundle;

pub const source = @import("source.zig");
pub const SvidSource = source.SvidSource;
pub const SocketConfig = source.SocketConfig;
pub const Options = source.Options;

pub const ShelloutSource = @import("shellout.zig").ShelloutSource;
pub const NativeWorkloadAPISource = @import("native.zig").NativeWorkloadAPISource;

// Note: `integration.zig` (which wires SPIFFE SVIDs into Dagger
// Container.withRegistryAuth via Vault cert-auth) is deliberately NOT
// re-exported here. That file imports `../root.zig` and would pull the
// whole Dagger client into the SPIFFE graph — users who need it import
// it explicitly:
//
//     const spiffe_dagger = @import("dagger_sdk").spiffe_integration;

pub const errors = @import("errors.zig");
pub const SpiffeError = errors.SpiffeError;
//
// Keeps the core SPIFFE client usable as a standalone workload-identity
// library with zero Dagger coupling.
