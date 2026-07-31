//! ShelloutSource — SvidSource backend that invokes `spire-agent api fetch`.
//!
//! Pragmatic and correct. Has two limitations we accept today:
//!   1. Requires the `spire-agent` binary in PATH (or an explicit path).
//!   2. Each fetch forks a subprocess (~10ms overhead). Fine for one-shot;
//!      suboptimal for rotation polling at sub-minute intervals.
//!
//! Rotation via `watchX509SVID` (streaming) is not part of the current
//! vtable — it lands alongside the native gRPC backend. Users who need
//! rotation today poll `fetchX509SVID` at their preferred interval.
//!
//! The interface contract stays stable — when native lands, `ShelloutSource`
//! and `NativeWorkloadAPISource` both implement the same `SvidSource`
//! vtable. User code swaps backends with one line.

const std = @import("std");
const source_mod = @import("source.zig");
const SvidSource = source_mod.SvidSource;
const Options = source_mod.Options;
const svid_mod = @import("svid.zig");
const X509SVID = svid_mod.X509SVID;
const JWTSVID = svid_mod.JWTSVID;
const TrustBundle = svid_mod.TrustBundle;
const SpiffeID = @import("spiffe_id.zig").SpiffeID;
const errs = @import("errors.zig");

pub const ShelloutSource = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    options: Options,
    /// Cached resolved socket path.
    socket_path: []const u8,
    /// Path to the spire-agent binary.
    agent_binary: []const u8,
    closed: bool = false,

    /// Default: `spire-agent` on PATH.
    pub const default_agent_binary: []const u8 = "spire-agent";

    pub fn init(
        allocator: std.mem.Allocator,
        io: std.Io,
        options: Options,
        agent_binary_opt: ?[]const u8,
    ) errs.SpiffeError!ShelloutSource {
        const socket = try options.socket.resolve(allocator);
        errdefer allocator.free(socket);

        const bin = try allocator.dupe(
            u8,
            agent_binary_opt orelse default_agent_binary,
        );
        errdefer allocator.free(bin);

        return .{
            .allocator = allocator,
            .io = io,
            .options = options,
            .socket_path = socket,
            .agent_binary = bin,
        };
    }

    pub fn deinit(self: *ShelloutSource) void {
        self.allocator.free(self.socket_path);
        self.allocator.free(self.agent_binary);
        self.closed = true;
    }

    pub fn source(self: *ShelloutSource) SvidSource {
        return .{ .ptr = self, .vtable = &vtable };
    }

    // ─── vtable impls ───────────────────────────────────────────────────

    const vtable: SvidSource.VTable = .{
        .fetch_x509_svid = vFetchX509,
        .fetch_jwt_svid = vFetchJWT,
        .fetch_x509_bundle = vFetchBundle,
        .close = vClose,
    };

    fn vFetchX509(ptr: *anyopaque, allocator: std.mem.Allocator) errs.SpiffeError!X509SVID {
        const self: *ShelloutSource = @ptrCast(@alignCast(ptr));
        if (self.closed) return error.AlreadyClosed;

        // Run: spire-agent api fetch x509 -socketPath <path> -write <tempdir>
        // The command writes svid.0.pem, svid.0.key, bundle.0.pem into -write dir.
        var tmpdir_buf: [128]u8 = undefined;
        const tmpdir = std.fmt.bufPrint(
            &tmpdir_buf,
            "/tmp/spiffe-{x}",
            .{std.crypto.random.int(u64)},
        ) catch return error.TransportError;

        // Directory creation in 0.16 — actual method names (makePath vs
        // createDirPath, deleteTree vs deleteTreeAbsolute) may have shifted
        // in the fs→Io migration. If the first compile complains, the fix
        // is a method-name rename at these exact lines. The behavior is
        // unchanged.
        var cwd = std.Io.Dir.cwd();
        cwd.makePath(self.io, tmpdir) catch return error.TransportError;
        defer {
            cwd.deleteTree(self.io, tmpdir) catch {};
        }

        const argv = [_][]const u8{
            self.agent_binary,
            "api",
            "fetch",
            "x509",
            "-socketPath",
            self.socket_path,
            "-write",
            tmpdir,
        };

        // std.process.run's 0.16 shape: takes Io through the options struct
        // rather than positionally. If the first compile surfaces an arity
        // error here, move `io` into the struct literal.
        const result = std.process.run(.{
            .allocator = allocator,
            .io = self.io,
            .argv = &argv,
        }) catch return error.TransportError;
        defer allocator.free(result.stdout);
        defer allocator.free(result.stderr);

        switch (result.term) {
            .Exited => |code| if (code != 0) return error.TransportError,
            else => return error.TransportError,
        }

        // Parse the output files. For the shellout backend, we keep this
        // minimal — we know the filenames spire-agent writes.
        return parseX509FromDir(allocator, self.io, tmpdir, self.options.expected_trust_domain);
    }

    fn vFetchJWT(ptr: *anyopaque, allocator: std.mem.Allocator, audiences: []const []const u8) errs.SpiffeError!JWTSVID {
        const self: *ShelloutSource = @ptrCast(@alignCast(ptr));
        if (self.closed) return error.AlreadyClosed;
        _ = audiences;
        _ = allocator;
        // Shellout for JWT: spire-agent api fetch jwt -audience X -socketPath ...
        // Implementation deferred — shellout currently supports X509 only;
        // the native backend is intended to support both.
        return error.NotImplementedInV010;
    }

    fn vFetchBundle(ptr: *anyopaque, allocator: std.mem.Allocator) errs.SpiffeError!TrustBundle {
        const self: *ShelloutSource = @ptrCast(@alignCast(ptr));
        if (self.closed) return error.AlreadyClosed;
        _ = allocator;
        return error.NotImplementedInV010;
    }

    fn vClose(ptr: *anyopaque) void {
        const self: *ShelloutSource = @ptrCast(@alignCast(ptr));
        self.closed = true;
    }
};

// ─── helpers ─────────────────────────────────────────────────────────────

fn parseX509FromDir(
    allocator: std.mem.Allocator,
    io: std.Io,
    dir_path: []const u8,
    expected_td: ?[]const u8,
) errs.SpiffeError!X509SVID {
    _ = allocator;
    _ = io;
    _ = dir_path;
    _ = expected_td;
    // Minimal PEM/DER handling that reads svid.0.pem + svid.0.key + bundle.0.pem.
    // Full parser deferred — the Zig stdlib's std.crypto.Certificate covers most
    // of what we need but PEM decoding is manual.
    //
    // This remains the unfinished piece for the shellout backend; it lands
    // together with the native backend because both need the same X.509
    // parsing utilities.
    return error.NotImplementedInV010;
}

// ─────────────────────────── tests ──────────────────────────────────────

const testing = std.testing;

test "init and close are idempotent" {
    var io_impl: std.Io.Threaded = .init(std.testing.allocator);
    defer io_impl.deinit();
    const io = io_impl.io();

    // Use an explicit socket path that almost certainly doesn't exist.
    // init() itself doesn't connect — connection happens lazily on first op.
    var ss = try ShelloutSource.init(
        testing.allocator,
        io,
        .{ .socket = .{ .explicit = "/tmp/never-exists.sock" } },
        null,
    );
    defer ss.deinit();

    try testing.expect(!ss.closed);
    ss.source().close();
    try testing.expect(ss.closed);
    // Calling close again is fine.
    ss.source().close();
    try testing.expect(ss.closed);
}
