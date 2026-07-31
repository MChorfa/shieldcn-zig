//! NativeWorkloadAPISource — native SPIFFE Workload API skeleton.
//!
//! Will be a pure-Zig SPIFFE Workload API client over Unix domain socket:
//!   - Minimal HTTP/2 framing (SETTINGS, HEADERS, DATA, GOAWAY, WINDOW_UPDATE)
//!   - gRPC length-prefix framing + status trailers
//!   - Hand-transcribed protobuf codec for the 9 Workload API messages
//!   - Streaming FetchX509SVID/FetchJWTBundles; unary FetchJWTSVID
//!   - X.509 cert chain + PKCS#8 key parsing via std.crypto.Certificate
//!
//! The types and vtable are fully defined so callers can write code against
//! this API today. Every network operation currently returns
//! `error.NotImplementedInV010`.
//!
//! User-visible migration path: no code changes. Bump dependency, rebuild.
//!
//! Implementation spec:
//!   See docs/SPIFFE_IMPL.md for the detailed wire-level spec, HTTP/2
//!   subset, protobuf field tags, and test-vector layout.

const std = @import("std");
const source_mod = @import("source.zig");
const SvidSource = source_mod.SvidSource;
const Options = source_mod.Options;
const svid_mod = @import("svid.zig");
const X509SVID = svid_mod.X509SVID;
const JWTSVID = svid_mod.JWTSVID;
const TrustBundle = svid_mod.TrustBundle;
const errs = @import("errors.zig");

pub const NativeWorkloadAPISource = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    options: Options,
    socket_path: []const u8,
    closed: bool = false,

    /// Placeholder for the gRPC connection state.
    /// Intentionally absent until the native client is implemented.
    _unused_conn: ?*anyopaque = null,

    pub fn init(
        allocator: std.mem.Allocator,
        io: std.Io,
        options: Options,
    ) errs.SpiffeError!NativeWorkloadAPISource {
        const socket = try options.socket.resolve(allocator);
        errdefer allocator.free(socket);

        return .{
            .allocator = allocator,
            .io = io,
            .options = options,
            .socket_path = socket,
        };
    }

    pub fn deinit(self: *NativeWorkloadAPISource) void {
        self.allocator.free(self.socket_path);
        self.closed = true;
    }

    pub fn source(self: *NativeWorkloadAPISource) SvidSource {
        return .{ .ptr = self, .vtable = &vtable };
    }

    // ─── vtable ────────────────────────────────────────────────────────

    const vtable: SvidSource.VTable = .{
        .fetch_x509_svid = vFetchX509,
        .fetch_jwt_svid = vFetchJWT,
        .fetch_x509_bundle = vFetchBundle,
        .close = vClose,
    };

    fn vFetchX509(ptr: *anyopaque, allocator: std.mem.Allocator) errs.SpiffeError!X509SVID {
        const self: *NativeWorkloadAPISource = @ptrCast(@alignCast(ptr));
        if (self.closed) return error.AlreadyClosed;
        _ = allocator;
        return error.NotImplementedInV010;
    }

    fn vFetchJWT(ptr: *anyopaque, allocator: std.mem.Allocator, audiences: []const []const u8) errs.SpiffeError!JWTSVID {
        const self: *NativeWorkloadAPISource = @ptrCast(@alignCast(ptr));
        if (self.closed) return error.AlreadyClosed;
        _ = allocator;
        _ = audiences;
        return error.NotImplementedInV010;
    }

    fn vFetchBundle(ptr: *anyopaque, allocator: std.mem.Allocator) errs.SpiffeError!TrustBundle {
        const self: *NativeWorkloadAPISource = @ptrCast(@alignCast(ptr));
        if (self.closed) return error.AlreadyClosed;
        _ = allocator;
        return error.NotImplementedInV010;
    }

    fn vClose(ptr: *anyopaque) void {
        const self: *NativeWorkloadAPISource = @ptrCast(@alignCast(ptr));
        self.closed = true;
    }
};

// ─────────────────────────── tests ──────────────────────────────────────

const testing = std.testing;

test "all network ops return NotImplementedInV010" {
    var io_impl: std.Io.Threaded = .init(std.testing.allocator);
    defer io_impl.deinit();
    const io = io_impl.io();

    var n = try NativeWorkloadAPISource.init(
        testing.allocator,
        io,
        .{ .socket = .{ .explicit = "/tmp/x.sock" } },
    );
    defer n.deinit();

    const src = n.source();

    try testing.expectError(
        error.NotImplementedInV010,
        src.fetchX509SVID(testing.allocator),
    );
    try testing.expectError(
        error.NotImplementedInV010,
        src.fetchJWTSVID(testing.allocator, &.{"aud"}),
    );
    try testing.expectError(
        error.NotImplementedInV010,
        src.fetchX509Bundle(testing.allocator),
    );
}

test "close marks source closed" {
    var io_impl: std.Io.Threaded = .init(std.testing.allocator);
    defer io_impl.deinit();
    const io = io_impl.io();

    var n = try NativeWorkloadAPISource.init(
        testing.allocator,
        io,
        .{ .socket = .{ .explicit = "/tmp/x.sock" } },
    );
    defer n.deinit();

    n.source().close();
    try testing.expect(n.closed);

    try testing.expectError(
        error.AlreadyClosed,
        n.source().fetchX509SVID(testing.allocator),
    );
}
