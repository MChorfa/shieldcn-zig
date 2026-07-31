//! C ABI layer for dagger-zig.
//!
//! Exports `extern "C"` symbols. C callers don't know about `std.Io`, so we
//! construct a default `std.Io.Threaded` internally on the first
//! `dagger_connect` call and stash it on the client. Single-threaded callers
//! get correctness; multi-threaded callers get parallelism for free because
//! Io.Threaded schedules across OS threads when not in single-threaded build.
//!
//! ## Design rules (unchanged from original; restated after 0.16 migration)
//!
//!   1. NO Zig errors cross the FFI boundary — caught, mapped to codes.
//!   2. NO panics cross the boundary — defensive NULL checks on every pointer.
//!   3. Ownership explicit — caller frees via dagger_string_free / _array_free.
//!   4. Handle lifetime tied to the owning client — post-close use is UB.
//!   5. Strings IN are copied into the client arena immediately.

const std = @import("std");
const dagger = @import("root.zig");
const errors = @import("errors.zig");

const ArenaAllocator = std.heap.ArenaAllocator;

// ─────────────────────────── thread-local error slot ─────────────────────

threadlocal var last_error_buf: [1024]u8 = undefined;
threadlocal var last_error_len: usize = 0;

fn setLastError(comptime fmt: []const u8, args: anytype) void {
    const written = std.fmt.bufPrint(&last_error_buf, fmt, args) catch {
        const msg = "error message truncated";
        @memcpy(last_error_buf[0..msg.len], msg);
        last_error_len = msg.len;
        return;
    };
    last_error_len = written.len;
}

fn clearLastError() void {
    last_error_len = 0;
}

fn reportError(err: anyerror) c_int {
    setLastError("{s}", .{@errorName(err)});
    return switch (err) {
        error.OutOfMemory => DAGGER_ERR_ALLOC,
        error.TransportFailed => DAGGER_ERR_TRANSPORT,
        error.HttpStatus => DAGGER_ERR_HTTP_STATUS,
        error.DomainError => DAGGER_ERR_DOMAIN,
        error.MalformedResponse,
        error.InvalidEnvelope,
        error.TooManyNestedObjects,
        error.DeserializeFailed,
        => DAGGER_ERR_MALFORMED,
        error.SpawnFailed,
        error.CliExited,
        error.HandshakeFailed,
        error.DownloadFailed,
        error.InvalidEnv,
        => DAGGER_ERR_CONNECT,
        error.ShutdownFailed => DAGGER_ERR_SHUTDOWN,
        else => DAGGER_ERR_INTERNAL,
    };
}

const DAGGER_OK: c_int = 0;
const DAGGER_ERR_ALLOC: c_int = -1;
const DAGGER_ERR_CONNECT: c_int = -2;
const DAGGER_ERR_TRANSPORT: c_int = -3;
const DAGGER_ERR_HTTP_STATUS: c_int = -4;
const DAGGER_ERR_DOMAIN: c_int = -5;
const DAGGER_ERR_MALFORMED: c_int = -6;
const DAGGER_ERR_BUILD: c_int = -7;
const DAGGER_ERR_NULL_ARG: c_int = -8;
const DAGGER_ERR_SHUTDOWN: c_int = -9;
const DAGGER_ERR_INTERNAL: c_int = -99;

// ─────────────────────────── global GPA ──────────────────────────────────

var gpa_instance: std.heap.DebugAllocator(.{}) = .init;
fn gpa() std.mem.Allocator {
    return gpa_instance.allocator();
}

// ─────────────────────────── handle wrappers ─────────────────────────────

/// Lives for the duration of the client. Owns the default Io.Threaded so it
/// can be torn down on close without affecting other clients.
const ClientHandle = struct {
    io_impl: std.Io.Threaded,
    inner: dagger.Client,
    query_handle: QueryHandle,
    handles_arena: ArenaAllocator,
};

const QueryHandle = struct { client: *ClientHandle };
const ContainerHandle = struct { client: *ClientHandle, inner: dagger.Container };
const DirectoryHandle = struct { client: *ClientHandle, inner: dagger.Directory };
const FileHandle = struct { client: *ClientHandle, inner: dagger.File };
const SecretHandle = struct { client: *ClientHandle, inner: dagger.Secret };
const CacheVolHandle = struct { client: *ClientHandle, inner: dagger.CacheVolume };

fn newContainerHandle(client: *ClientHandle, c: dagger.Container) !*ContainerHandle {
    const h = try client.handles_arena.allocator().create(ContainerHandle);
    h.* = .{ .client = client, .inner = c };
    return h;
}
fn newDirectoryHandle(client: *ClientHandle, d: dagger.Directory) !*DirectoryHandle {
    const h = try client.handles_arena.allocator().create(DirectoryHandle);
    h.* = .{ .client = client, .inner = d };
    return h;
}
fn newFileHandle(client: *ClientHandle, f: dagger.File) !*FileHandle {
    const h = try client.handles_arena.allocator().create(FileHandle);
    h.* = .{ .client = client, .inner = f };
    return h;
}
fn newSecretHandle(client: *ClientHandle, s: dagger.Secret) !*SecretHandle {
    const h = try client.handles_arena.allocator().create(SecretHandle);
    h.* = .{ .client = client, .inner = s };
    return h;
}
fn newCacheVolHandle(client: *ClientHandle, cv: dagger.CacheVolume) !*CacheVolHandle {
    const h = try client.handles_arena.allocator().create(CacheVolHandle);
    h.* = .{ .client = client, .inner = cv };
    return h;
}

fn cStrOr(p: ?[*:0]const u8) ?[]const u8 {
    if (p) |ptr| return std.mem.span(ptr);
    return null;
}

fn dupToC(s: []const u8) ![*:0]u8 {
    const buf = try gpa().allocSentinel(u8, s.len, 0);
    @memcpy(buf[0..s.len], s);
    return buf.ptr;
}

// ─────────────────────────── lifecycle ───────────────────────────────────

export fn dagger_connect() ?*ClientHandle {
    clearLastError();
    const h = gpa().create(ClientHandle) catch {
        setLastError("allocation failed", .{});
        return null;
    };

    // Initialize all fields atomically to avoid partial state
    h.* = .{
        .io_impl = std.Io.Threaded.init(gpa(), undefined),
        .inner = undefined,
        .query_handle = undefined,
        .handles_arena = ArenaAllocator.init(gpa()),
    };
    const io = h.io_impl.io();

    h.inner = dagger.connect(gpa(), io, .{}) catch |e| {
        _ = reportError(e);
        h.io_impl.deinit();
        h.handles_arena.deinit();
        gpa().destroy(h);
        return null;
    };
    h.query_handle = .{ .client = h };
    return h;
}

export fn dagger_client_close(client: ?*ClientHandle) void {
    clearLastError();
    if (client) |c| {
        c.inner.close();
        c.io_impl.deinit();
        c.handles_arena.deinit();
        gpa().destroy(c);
    }
}

export fn dagger_client_reset_arena(client: ?*ClientHandle) c_int {
    clearLastError();
    if (client) |c| {
        c.inner.resetArena() catch |err| {
            setLastError("{s}", .{@errorName(err)});
            return DAGGER_ERR_INTERNAL;
        };
    }
    return DAGGER_OK;
}

export fn dagger_client_dag(client: ?*ClientHandle) ?*QueryHandle {
    clearLastError();
    if (client) |c| return &c.query_handle;
    return null;
}

// ─────────────────────────── root queries ────────────────────────────────

export fn dagger_query_container(q: ?*QueryHandle) ?*ContainerHandle {
    clearLastError();
    const qh = q orelse return null;
    const ctr = qh.client.inner.dag().container() catch |e| {
        _ = reportError(e);
        return null;
    };
    return newContainerHandle(qh.client, ctr) catch |e| {
        _ = reportError(e);
        return null;
    };
}

export fn dagger_query_directory(q: ?*QueryHandle) ?*DirectoryHandle {
    clearLastError();
    const qh = q orelse return null;
    const d = qh.client.inner.dag().directory() catch |e| {
        _ = reportError(e);
        return null;
    };
    return newDirectoryHandle(qh.client, d) catch |e| {
        _ = reportError(e);
        return null;
    };
}

export fn dagger_query_cache_volume(q: ?*QueryHandle, key: ?[*:0]const u8) ?*CacheVolHandle {
    clearLastError();
    const qh = q orelse return null;
    const k = cStrOr(key) orelse {
        setLastError("key is null", .{});
        return null;
    };
    const cv = qh.client.inner.dag().cacheVolume(k) catch |e| {
        _ = reportError(e);
        return null;
    };
    return newCacheVolHandle(qh.client, cv) catch |e| {
        _ = reportError(e);
        return null;
    };
}

export fn dagger_query_set_secret(q: ?*QueryHandle, name: ?[*:0]const u8, plaintext: ?[*:0]const u8) ?*SecretHandle {
    clearLastError();
    const qh = q orelse return null;
    const n = cStrOr(name) orelse return null;
    const p = cStrOr(plaintext) orelse return null;
    const s = qh.client.inner.dag().setSecret(n, p) catch |e| {
        _ = reportError(e);
        return null;
    };
    return newSecretHandle(qh.client, s) catch |e| {
        _ = reportError(e);
        return null;
    };
}

// ─────────────────────────── Container ───────────────────────────────────

export fn dagger_container_from(c: ?*ContainerHandle, address: ?[*:0]const u8) ?*ContainerHandle {
    clearLastError();
    const ch = c orelse return null;
    const addr = cStrOr(address) orelse return null;
    const new_ctr = ch.inner.from(addr) catch |e| {
        _ = reportError(e);
        return null;
    };
    return newContainerHandle(ch.client, new_ctr) catch |e| {
        _ = reportError(e);
        return null;
    };
}

export fn dagger_container_with_workdir(c: ?*ContainerHandle, path: ?[*:0]const u8) ?*ContainerHandle {
    clearLastError();
    const ch = c orelse return null;
    const p = cStrOr(path) orelse return null;
    const new_ctr = ch.inner.withWorkdir(p) catch |e| {
        _ = reportError(e);
        return null;
    };
    return newContainerHandle(ch.client, new_ctr) catch |e| {
        _ = reportError(e);
        return null;
    };
}

export fn dagger_container_with_env_variable(c: ?*ContainerHandle, name: ?[*:0]const u8, value: ?[*:0]const u8) ?*ContainerHandle {
    clearLastError();
    const ch = c orelse return null;
    const n = cStrOr(name) orelse return null;
    const v = cStrOr(value) orelse return null;
    const new_ctr = ch.inner.withEnvVariable(n, v) catch |e| {
        _ = reportError(e);
        return null;
    };
    return newContainerHandle(ch.client, new_ctr) catch |e| {
        _ = reportError(e);
        return null;
    };
}

export fn dagger_container_with_exec(c: ?*ContainerHandle, argv: ?[*]const [*:0]const u8, argv_len: usize) ?*ContainerHandle {
    clearLastError();
    const ch = c orelse return null;
    const av = argv orelse if (argv_len == 0) return ch else return null;

    const slice = ch.client.handles_arena.allocator().alloc([]const u8, argv_len) catch |e| {
        _ = reportError(e);
        return null;
    };
    var i: usize = 0;
    while (i < argv_len) : (i += 1) slice[i] = std.mem.span(av[i]);

    const new_ctr = ch.inner.withExec(slice) catch |e| {
        _ = reportError(e);
        return null;
    };
    return newContainerHandle(ch.client, new_ctr) catch |e| {
        _ = reportError(e);
        return null;
    };
}

export fn dagger_container_with_mounted_cache(c: ?*ContainerHandle, path: ?[*:0]const u8, cache: ?*CacheVolHandle) ?*ContainerHandle {
    clearLastError();
    const ch = c orelse return null;
    const cv = cache orelse return null;
    const p = cStrOr(path) orelse return null;
    const new_ctr = ch.inner.withMountedCache(p, cv.inner) catch |e| {
        _ = reportError(e);
        return null;
    };
    return newContainerHandle(ch.client, new_ctr) catch |e| {
        _ = reportError(e);
        return null;
    };
}

export fn dagger_container_stdout(c: ?*ContainerHandle, out: ?*?[*:0]u8) c_int {
    clearLastError();
    const ch = c orelse return DAGGER_ERR_NULL_ARG;
    const out_ptr = out orelse return DAGGER_ERR_NULL_ARG;
    out_ptr.* = null;
    const s = ch.inner.stdout() catch |e| return reportError(e);
    defer gpa().free(s);
    out_ptr.* = dupToC(s) catch |e| return reportError(e);
    return DAGGER_OK;
}

export fn dagger_container_stderr(c: ?*ContainerHandle, out: ?*?[*:0]u8) c_int {
    clearLastError();
    const ch = c orelse return DAGGER_ERR_NULL_ARG;
    const out_ptr = out orelse return DAGGER_ERR_NULL_ARG;
    out_ptr.* = null;
    const s = ch.inner.stderr() catch |e| return reportError(e);
    defer gpa().free(s);
    out_ptr.* = dupToC(s) catch |e| return reportError(e);
    return DAGGER_OK;
}

export fn dagger_container_sync(c: ?*ContainerHandle, out: ?*?[*:0]u8) c_int {
    clearLastError();
    const ch = c orelse return DAGGER_ERR_NULL_ARG;
    const out_ptr = out orelse return DAGGER_ERR_NULL_ARG;
    out_ptr.* = null;
    var id = ch.inner.sync() catch |e| return reportError(e);
    defer id.deinit(gpa());
    out_ptr.* = dupToC(id.value) catch |e| return reportError(e);
    return DAGGER_OK;
}

export fn dagger_container_publish(c: ?*ContainerHandle, address: ?[*:0]const u8, out: ?*?[*:0]u8) c_int {
    clearLastError();
    const ch = c orelse return DAGGER_ERR_NULL_ARG;
    const out_ptr = out orelse return DAGGER_ERR_NULL_ARG;
    const addr = cStrOr(address) orelse return DAGGER_ERR_NULL_ARG;
    out_ptr.* = null;
    const digest = ch.inner.publish(addr) catch |e| return reportError(e);
    defer gpa().free(digest);
    out_ptr.* = dupToC(digest) catch |e| return reportError(e);
    return DAGGER_OK;
}

// ─────────────────────────── Directory / File ────────────────────────────

export fn dagger_directory_file(d: ?*DirectoryHandle, path: ?[*:0]const u8) ?*FileHandle {
    clearLastError();
    const dh = d orelse return null;
    const p = cStrOr(path) orelse return null;
    const f = dh.inner.file(p) catch |e| {
        _ = reportError(e);
        return null;
    };
    return newFileHandle(dh.client, f) catch |e| {
        _ = reportError(e);
        return null;
    };
}

export fn dagger_directory_entries(d: ?*DirectoryHandle, out: ?*?[*]?[*:0]u8, out_len: ?*usize) c_int {
    clearLastError();
    const dh = d orelse return DAGGER_ERR_NULL_ARG;
    const out_ptr = out orelse return DAGGER_ERR_NULL_ARG;
    const len_ptr = out_len orelse return DAGGER_ERR_NULL_ARG;
    out_ptr.* = null;
    len_ptr.* = 0;

    const entries = dh.inner.entries() catch |e| return reportError(e);
    defer {
        for (entries) |e| gpa().free(e);
        gpa().free(entries);
    }

    const arr = gpa().alloc(?[*:0]u8, entries.len) catch |e| return reportError(e);
    for (entries, 0..) |e, i| {
        arr[i] = dupToC(e) catch |err| {
            var j: usize = 0;
            while (j < i) : (j += 1) if (arr[j]) |p| gpa().free(std.mem.span(p));
            gpa().free(arr);
            return reportError(err);
        };
    }
    out_ptr.* = arr.ptr;
    len_ptr.* = arr.len;
    return DAGGER_OK;
}

export fn dagger_file_contents(f: ?*FileHandle, out: ?*?[*:0]u8) c_int {
    clearLastError();
    const fh = f orelse return DAGGER_ERR_NULL_ARG;
    const out_ptr = out orelse return DAGGER_ERR_NULL_ARG;
    out_ptr.* = null;
    const s = fh.inner.contents() catch |e| return reportError(e);
    defer gpa().free(s);
    out_ptr.* = dupToC(s) catch |e| return reportError(e);
    return DAGGER_OK;
}

// ─────────────────────────── error + memory ──────────────────────────────

export fn dagger_last_error() [*:0]const u8 {
    if (last_error_len < last_error_buf.len) {
        last_error_buf[last_error_len] = 0;
    } else {
        last_error_buf[last_error_buf.len - 1] = 0;
    }
    return @ptrCast(&last_error_buf);
}

export fn dagger_string_free(s: ?[*:0]u8) void {
    if (s) |p| gpa().free(std.mem.span(p));
}

export fn dagger_string_array_free(arr: ?[*]?[*:0]u8, len: usize) void {
    if (arr) |a| {
        var i: usize = 0;
        while (i < len) : (i += 1) if (a[i]) |p| gpa().free(std.mem.span(p));
        gpa().free(a[0..len]);
    }
}

// ─────────────────────────── metadata ────────────────────────────────────

export fn dagger_sdk_version() [*:0]const u8 {
    return dagger.core.version.sdk_version.ptr;
}
export fn dagger_engine_version() [*:0]const u8 {
    return dagger.core.version.engine_version.ptr;
}
export fn dagger_abi_version() c_int {
    return 1;
}

// ─────────────────────────── tests ───────────────────────────────────────

const testing = std.testing;

test "reportError maps well-known errors" {
    try testing.expectEqual(DAGGER_ERR_ALLOC, reportError(error.OutOfMemory));
    try testing.expectEqual(DAGGER_ERR_TRANSPORT, reportError(error.TransportFailed));
    try testing.expectEqual(DAGGER_ERR_DOMAIN, reportError(error.DomainError));
    try testing.expectEqual(DAGGER_ERR_CONNECT, reportError(error.SpawnFailed));
}

test "setLastError / dagger_last_error round-trip" {
    setLastError("something broke: {d}", .{42});
    const p = dagger_last_error();
    try testing.expectEqualStrings("something broke: 42", std.mem.span(p));
}
