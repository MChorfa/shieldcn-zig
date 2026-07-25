const std = @import("std");

/// shieldcn-zig — util/audit.zig
/// Structured audit logging — one line per request to stderr.
///
/// Two output paths:
///
/// 1. **flushPending** — emits a compact space-delimited line via
///    `std.log.info` (the runtime path used by the HTTP server):
///      info: <ts_ns> <method> <path> <status> <latency_us>
///
/// 2. **formatRecord** — formats a full JSON line into a caller-provided
///    buffer (the programmatic path, used by tests and available for
///    future file-based or structured logging):
///      {"ts_ns":<i128>,"method":"GET","path":"/npm/react.svg",
///       "provider":"npm","format":"svg","status":200,
///       "latency_us":<u64>,"cache_hit":false}
///
/// Architecture:
/// - `handleClient` calls `storePending` in a defer; the `listen` loop
///   calls `flushPending` after `handleClient` returns. Deferring the
///   write to a shallower stack frame avoids stack-pressure issues when
///   the 4096-byte `read_buf` is still live.
/// - `flushPending` uses `std.log.info` with inline format args. In Zig
///   0.16 debug builds, `std.c.write` fails silently on stack buffers
///   larger than ~50 bytes, and `std.debug.lockStderr` produces no
///   visible output from this call site. `std.log.info` with inline
///   args (not a pre-formatted `{s}` buffer) is the only mechanism that
///   works reliably for all request types and across multiple calls.
/// - Time is read via `clock_gettime(CLOCK.MONOTONIC)` directly because
///   Zig 0.16 removed `std.time.nanoTimestamp` from the stdlib.
pub const AuditRecord = struct {
    method: []const u8,
    path: []const u8,
    provider: []const u8 = "",
    format: []const u8 = "",
    status: u16 = 200,
    latency_us: u64 = 0,
    cache_hit: bool = false,
};

/// Monotonic nanoseconds since an arbitrary epoch.
/// Suitable for latency measurement; not wall-clock time.
pub fn monoNs() i128 {
    var ts: std.c.timespec = undefined;
    _ = std.c.clock_gettime(std.c.CLOCK.MONOTONIC, &ts);
    return @as(i128, ts.sec) * 1_000_000_000 + @as(i128, ts.nsec);
}

/// Compute elapsed microseconds between a start (from monoNs) and now.
pub fn elapsedUs(start_ns: i128) u64 {
    const now_ns = monoNs();
    const delta = now_ns - start_ns;
    if (delta <= 0) return 0;
    return @intCast(@divTrunc(delta, 1000));
}

var pending: ?AuditRecord = null;

/// Store an audit record to be flushed later by flushPending().
pub fn storePending(rec: AuditRecord) void {
    pending = rec;
}

/// Flush the pending audit record (if any) to stderr.
/// Called from the listen loop (shallow stack frame) after handleClient
/// returns. Emits a compact space-delimited line:
///   info: <ts_ns> <method> <path> <status> <latency_us>
///
/// provider, format, and cache_hit are omitted from the log line to
/// stay within std.log.info's content limit. They are available via
/// formatRecord() for programmatic JSON access.
pub fn flushPending() void {
    const rec = pending orelse return;
    pending = null;
    std.log.info("{d} {s} {s} {d} {d}", .{ monoNs(), rec.method, rec.path, rec.status, rec.latency_us });
}

/// Format an audit record as a single JSON line (without trailing newline)
/// into `buf`. Returns the slice written, or null if it does not fit.
pub fn formatRecord(buf: []u8, rec: AuditRecord) ?[]const u8 {
    var pos: usize = 0;

    const prefix = std.fmt.bufPrint(buf[pos..], "{{\"ts_ns\":{d},\"method\":\"", .{monoNs()}) catch return null;
    pos += prefix.len;

    if (!appendJson(buf, &pos, rec.method)) return null;
    if (!appendLiteral(buf, &pos, "\",\"path\":\"")) return null;
    if (!appendJson(buf, &pos, rec.path)) return null;
    if (!appendLiteral(buf, &pos, "\",\"provider\":\"")) return null;
    if (!appendJson(buf, &pos, rec.provider)) return null;
    if (!appendLiteral(buf, &pos, "\",\"format\":\"")) return null;
    if (!appendJson(buf, &pos, rec.format)) return null;

    const suffix = std.fmt.bufPrint(buf[pos..], "\",\"status\":{d},\"latency_us\":{d},\"cache_hit\":{}}}", .{ rec.status, rec.latency_us, rec.cache_hit }) catch return null;
    pos += suffix.len;

    return buf[0..pos];
}

fn appendLiteral(buf: []u8, pos: *usize, s: []const u8) bool {
    if (pos.* + s.len > buf.len) return false;
    @memcpy(buf[pos.*..][0..s.len], s);
    pos.* += s.len;
    return true;
}

fn appendJson(buf: []u8, pos: *usize, s: []const u8) bool {
    for (s) |c| {
        switch (c) {
            '"' => if (!appendLiteral(buf, pos, "\\\"")) return false,
            '\\' => if (!appendLiteral(buf, pos, "\\\\")) return false,
            '\n' => if (!appendLiteral(buf, pos, "\\n")) return false,
            '\r' => if (!appendLiteral(buf, pos, "\\r")) return false,
            '\t' => if (!appendLiteral(buf, pos, "\\t")) return false,
            0...8, 11, 12, 14...31 => {
                var hexbuf: [6]u8 = undefined;
                const hex = std.fmt.bufPrint(&hexbuf, "\\u{x:0>4}", .{c}) catch return false;
                if (!appendLiteral(buf, pos, hex)) return false;
            },
            else => {
                if (pos.* >= buf.len) return false;
                buf[pos.*] = c;
                pos.* += 1;
            },
        }
    }
    return true;
}

// ------------------------------------------------------------------
// Tests
// ------------------------------------------------------------------

test "formatRecord produces valid JSON line" {
    var buf: [1024]u8 = undefined;
    const line = formatRecord(&buf, .{
        .method = "GET",
        .path = "/npm/react.svg",
        .provider = "npm",
        .format = "svg",
        .status = 200,
        .latency_us = 42,
        .cache_hit = false,
    }) orelse return error.FormatFailed;

    try std.testing.expect(std.mem.startsWith(u8, line, "{\"ts_ns\":"));
    try std.testing.expect(std.mem.endsWith(u8, line, "}"));
    try std.testing.expect(std.mem.indexOf(u8, line, "\"method\":\"GET\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, line, "\"path\":\"/npm/react.svg\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, line, "\"provider\":\"npm\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, line, "\"format\":\"svg\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, line, "\"status\":200") != null);
    try std.testing.expect(std.mem.indexOf(u8, line, "\"latency_us\":42") != null);
    try std.testing.expect(std.mem.indexOf(u8, line, "\"cache_hit\":false") != null);
    // No trailing newline from formatRecord
    try std.testing.expect(!std.mem.endsWith(u8, line, "\n"));
}

test "formatRecord escapes special chars" {
    var buf: [1024]u8 = undefined;
    const line = formatRecord(&buf, .{
        .method = "GET",
        .path = "/badge/a\"b\\c",
        .provider = "badge",
        .format = "svg",
        .status = 200,
    }) orelse return error.FormatFailed;

    try std.testing.expect(std.mem.indexOf(u8, line, "\\\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, line, "\\\\") != null);
}

test "elapsedUs is non-negative" {
    const start = monoNs();
    const us = elapsedUs(start);
    try std.testing.expect(us >= 0);
}
