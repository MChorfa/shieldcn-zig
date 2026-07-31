//! GraphQL-over-HTTP client for the Dagger engine.
//!
//! Targets Zig 0.16's new `std.Io` interface and rewritten `std.http.Client`.
//!
//! The engine exposes exactly one endpoint: `POST http://127.0.0.1:{port}/query`
//! with `Authorization: Basic base64(session_token + ":")` and a JSON body of
//! the shape `{"query": "...", "variables": {...}}`.
//!
//! Responses use the standard GraphQL envelope:
//!   `{"data": {...}}` on success, or
//!   `{"errors": [{"message": "...", "path": [...], ...}]}` on domain error.
//!
//! ## Why Io propagates
//!
//! On 0.16, every operation that can block or touch OS state takes `Io`.
//! The client stores the `Io` the user supplied at `connect()` time and
//! passes it through every HTTP call. This gives the user three benefits
//! they can't get from any other Dagger SDK:
//!
//!   1. Concurrent queries via `io.async(client.query, .{...})` + `Group`.
//!   2. Cancellation: user can `cancel()` any in-flight pipeline; we see
//!      `error.Canceled` coming back through the transport error set.
//!   3. Single-threaded mode: the whole SDK works on `-fsingle-threaded`
//!      without any code changes, useful for WASM and constrained targets.

const std = @import("std");
const errs = @import("../errors.zig");
const ConnectParams = @import("connect_params.zig").ConnectParams;
const Config = @import("config.zig").Config;
const resilience = @import("resilience.zig");

pub const GraphQLClient = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    endpoint: []const u8, // owned
    endpoint_uri: std.Uri,
    auth_header: []const u8, // owned; pre-computed "Basic <b64>"
    connect_timeout_ms: u32,
    execute_timeout_ms: ?u32,

    /// Most recent domain error, if any. Owned by the client; reset per query.
    last_error: ?errs.DomainError = null,

    /// True while a query is executing. Used by Client.resetArena() to guard
    /// against use-after-free if the arena is reset during an active query.
    query_in_progress: bool = false,

    /// Resilience configuration for retries and circuit breaker.
    retry_policy: resilience.RetryPolicy,
    circuit_breaker: ?resilience.CircuitBreaker = null,

    pub fn init(
        allocator: std.mem.Allocator,
        io: std.Io,
        conn: ConnectParams,
        cfg: Config,
    ) !GraphQLClient {
        const endpoint = try conn.url(allocator);
        errdefer allocator.free(endpoint);

        // Basic auth: `<token>:` (empty password), base64-encoded.
        var pre_b64: std.ArrayList(u8) = .empty;
        defer pre_b64.deinit(allocator);
        try pre_b64.appendSlice(allocator, conn.session_token);
        try pre_b64.append(allocator, ':');

        const enc = std.base64.standard.Encoder;
        const b64_len = enc.calcSize(pre_b64.items.len);
        const b64_buf = try allocator.alloc(u8, b64_len);
        defer allocator.free(b64_buf);
        _ = enc.encode(b64_buf, pre_b64.items);

        const auth_header = try std.fmt.allocPrint(allocator, "Basic {s}", .{b64_buf});
        errdefer allocator.free(auth_header);

        // Parse URI last - it's a view into endpoint, so do this after all allocations succeed
        const uri = std.Uri.parse(endpoint) catch |e| {
            // Uri parsing shouldn't fail for valid URLs from conn.url(), but handle gracefully
            return e;
        };

        return .{
            .allocator = allocator,
            .io = io,
            .endpoint = endpoint,
            .endpoint_uri = uri,
            .auth_header = auth_header,
            .connect_timeout_ms = cfg.connect_timeout_ms,
            .execute_timeout_ms = cfg.execute_timeout_ms,
            .retry_policy = cfg.retry_policy,
            .circuit_breaker = if (cfg.enable_circuit_breaker) .{} else null,
        };
    }

    pub fn deinit(self: *GraphQLClient) void {
        self.allocator.free(self.endpoint);
        self.allocator.free(self.auth_header);
        if (self.last_error) |*e| e.deinit(self.allocator);
    }

    /// Create an independent client for a single concurrent fan-out task.
    ///
    /// The per-query mutable fields (`last_error`, `query_in_progress`, the
    /// circuit breaker) are NOT synchronized, so sharing one client across
    /// concurrent tasks races. A fork duplicates the (small, owned) connection
    /// strings and starts with fresh mutable state, so forks can run on
    /// different threads without racing. The caller owns the result and must
    /// `deinit()` it.
    pub fn fork(self: *const GraphQLClient) !GraphQLClient {
        const endpoint = try self.allocator.dupe(u8, self.endpoint);
        errdefer self.allocator.free(endpoint);
        const auth_header = try self.allocator.dupe(u8, self.auth_header);
        errdefer self.allocator.free(auth_header);
        // Re-parse so the Uri's component slices view the fork's own endpoint
        // copy, not the parent's.
        const uri = try std.Uri.parse(endpoint);
        return .{
            .allocator = self.allocator,
            .io = self.io,
            .endpoint = endpoint,
            .endpoint_uri = uri,
            .auth_header = auth_header,
            .connect_timeout_ms = self.connect_timeout_ms,
            .execute_timeout_ms = self.execute_timeout_ms,
            .last_error = null,
            .query_in_progress = false,
            .retry_policy = self.retry_policy,
            .circuit_breaker = if (self.circuit_breaker != null) .{} else null,
        };
    }

    /// Execute a GraphQL query with resilience patterns (retry, circuit breaker).
    /// Returns the full response body. Caller owns the returned slice.
    pub fn query(self: *GraphQLClient, query_str: []const u8) errs.QueryError![]u8 {
        if (self.last_error) |*e| {
            e.deinit(self.allocator);
            self.last_error = null;
        }

        self.query_in_progress = true;
        defer self.query_in_progress = false;

        // Build request body once
        const body = buildRequestBody(self.allocator, query_str) catch return error.OutOfMemory;
        defer self.allocator.free(body);

        // Create resilient executor with context stored in self for the closure
        var executor = resilience.ResilientExecutor{
            .policy = self.retry_policy,
            .breaker = if (self.circuit_breaker) |*cb| cb else null,
            .io = self.io,
        };

        // Execute with retry logic - use simple loop instead of closure for now
        const res = self.queryWithRetry(body, &executor) catch |err| {
            if (self.last_error) |le| {
                std.debug.print("DAGGER GRAPHQL ERROR: {s}\n", .{le.message});
            } else {
                std.debug.print("DAGGER GRAPHQL TRANSPORT ERROR: {}\n", .{err});
            }
            return err;
        };
        return res;
    }

    fn queryWithRetry(self: *GraphQLClient, body: []const u8, executor: *resilience.ResilientExecutor) errs.QueryError![]u8 {
        // Check circuit breaker
        if (executor.breaker) |cb| {
            if (!cb.allow()) {
                return error.CircuitOpen;
            }
        }

        var last_error: errs.QueryError = undefined;
        var backoff_ms: u32 = executor.policy.initial_backoff_ms;

        var attempt: u32 = 0;
        while (attempt <= executor.policy.max_retries) : (attempt += 1) {
            const result = self.queryOnce(body);

            if (result) |value| {
                if (executor.breaker) |cb| {
                    cb.recordSuccess();
                }
                return value;
            } else |err| {
                last_error = err;

                // Check if error is retryable
                if (!executor.policy.is_retryable(err)) {
                    if (executor.breaker) |cb| {
                        cb.recordFailure();
                    }
                    return err;
                }

                // Last attempt
                if (attempt == executor.policy.max_retries) {
                    if (executor.breaker) |cb| {
                        cb.recordFailure();
                    }
                    return err;
                }

                // Calculate backoff with jitter and sleep
                const jitter = executor.calculateJitter(backoff_ms);
                const sleep_ms = backoff_ms + jitter;
                const duration = std.Io.Duration.fromNanoseconds(sleep_ms * std.time.ns_per_ms);
                self.io.sleep(duration, .awake) catch {}; // Ignore cancel for retry

                // Exponential backoff
                const next_backoff = @as(u32, @intFromFloat(
                    @as(f32, @floatFromInt(backoff_ms)) * executor.policy.backoff_multiplier,
                ));
                backoff_ms = @min(next_backoff, executor.policy.max_backoff_ms);
            }
        }

        return last_error;
    }

    /// Execute a single GraphQL query attempt (no retry).
    fn queryOnce(self: *GraphQLClient, body: []const u8) errs.QueryError![]u8 {
        var http_client: std.http.Client = .{
            .allocator = self.allocator,
            .io = self.io,
        };
        defer http_client.deinit();

        const extra_headers = [_]std.http.Header{
            .{ .name = "Content-Type", .value = "application/json" },
            .{ .name = "Authorization", .value = self.auth_header },
        };

        var req = http_client.request(.POST, self.endpoint_uri, .{
            .extra_headers = &extra_headers,
        }) catch return error.TransportFailed;
        defer req.deinit();

        req.sendBodyComplete(@constCast(body)) catch return error.TransportFailed;

        var redirect_buffer: [4096]u8 = undefined;
        var resp = req.receiveHead(&redirect_buffer) catch return error.TransportFailed;

        if (@intFromEnum(resp.head.status) >= 400) {
            const err_body = self.readResponseBody(&resp) catch return error.HttpStatus;
            self.last_error = .{ .message = err_body };
            return error.HttpStatus;
        }

        const raw = self.readResponseBody(&resp) catch return error.OutOfMemory;

        if (hasTopLevelErrors(raw)) {
            self.extractDomainError(raw) catch {
                self.allocator.free(raw);
                return error.InvalidEnvelope;
            };
            self.allocator.free(raw);
            return error.DomainError;
        }

        return raw;
    }

    /// Drain the response body into a heap buffer. Cap at 64 MiB.
    fn readResponseBody(self: *GraphQLClient, resp: *std.http.Client.Response) ![]u8 {
        const max_bytes: usize = 64 * 1024 * 1024;
        var out: std.ArrayList(u8) = .empty;
        errdefer out.deinit(self.allocator);

        var read_buf: [16 * 1024]u8 = undefined;
        const reader = resp.reader(&read_buf);
        var buf: [16 * 1024]u8 = undefined;
        while (true) {
            if (out.items.len >= max_bytes) return error.MalformedResponse;
            const n = reader.readSliceShort(&buf) catch return error.TransportFailed;
            if (n == 0) break;
            try out.appendSlice(self.allocator, buf[0..n]);
        }
        return out.toOwnedSlice(self.allocator);
    }

    fn extractDomainError(self: *GraphQLClient, raw: []const u8) !void {
        const Outer = struct {
            errors: ?[]struct {
                message: []const u8,
            } = null,
        };
        const parsed = try std.json.parseFromSlice(Outer, self.allocator, raw, .{
            .ignore_unknown_fields = true,
        });
        defer parsed.deinit();
        if (parsed.value.errors) |list| if (list.len > 0) {
            self.last_error = .{
                .message = try self.allocator.dupe(u8, list[0].message),
            };
        };
    }
};

fn buildRequestBody(allocator: std.mem.Allocator, query_str: []const u8) ![]u8 {
    // First pass: calculate escaped length of the query string itself
    // (prefix and suffix already include the surrounding quotes)
    var escaped_len: usize = 0;
    for (query_str) |c| {
        escaped_len += switch (c) {
            '"', '\\' => 2, // These become \\ and \"
            0x00...0x1f => if (c == '\n' or c == '\r' or c == '\t' or c == 0x08 or c == 0x0c) 2 else 6,
            else => 1,
        };
    }

    const prefix = "{\"query\":\"";
    const suffix = "\"}";
    const total_len = prefix.len + escaped_len + suffix.len;
    const result = try allocator.alloc(u8, total_len);

    @memcpy(result[0..prefix.len], prefix);
    var i: usize = prefix.len;
    for (query_str) |c| {
        switch (c) {
            '"' => {
                result[i] = '\\';
                result[i + 1] = '"';
                i += 2;
            },
            '\\' => {
                result[i] = '\\';
                result[i + 1] = '\\';
                i += 2;
            },
            0x00...0x1f => {
                switch (c) {
                    0x08 => {
                        result[i] = '\\';
                        result[i + 1] = 'b';
                        i += 2;
                    },
                    0x0c => {
                        result[i] = '\\';
                        result[i + 1] = 'f';
                        i += 2;
                    },
                    '\n' => {
                        result[i] = '\\';
                        result[i + 1] = 'n';
                        i += 2;
                    },
                    '\r' => {
                        result[i] = '\\';
                        result[i + 1] = 'r';
                        i += 2;
                    },
                    '\t' => {
                        result[i] = '\\';
                        result[i + 1] = 't';
                        i += 2;
                    },
                    else => {
                        // Other control characters - use \uXXXX
                        const hex = "0123456789abcdef";
                        result[i] = '\\';
                        result[i + 1] = 'u';
                        result[i + 2] = '0';
                        result[i + 3] = '0';
                        result[i + 4] = hex[c >> 4];
                        result[i + 5] = hex[c & 0xf];
                        i += 6;
                    },
                }
            },
            else => {
                result[i] = c;
                i += 1;
            },
        }
    }
    @memcpy(result[i .. i + suffix.len], suffix);

    return result;
}

fn hasTopLevelErrors(body: []const u8) bool {
    return std.mem.indexOf(u8, body, "\"errors\"") != null;
}

// ─────────────────────────── tests ──────────────────────────────────────────

const testing = std.testing;

test "request body is valid JSON with escaped query" {
    const body = try buildRequestBody(testing.allocator, "query{a(x:\"hello\\n\")}");
    defer testing.allocator.free(body);

    const Parsed = struct { query: []const u8 };
    const p = try std.json.parseFromSlice(Parsed, testing.allocator, body, .{});
    defer p.deinit();
    try testing.expectEqualStrings("query{a(x:\"hello\\n\")}", p.value.query);
}

test "basic auth header format" {
    var io_impl: std.Io.Threaded = .init(std.testing.allocator, undefined);
    defer io_impl.deinit();
    const io = io_impl.io();

    const params: ConnectParams = .{ .port = 1234, .session_token = "secret" };
    var c = try GraphQLClient.init(testing.allocator, io, params, .{});
    defer c.deinit();

    try testing.expectEqualStrings("Basic c2VjcmV0Og==", c.auth_header);
    try testing.expectEqualStrings("http://127.0.0.1:1234/query", c.endpoint);
}

test "hasTopLevelErrors detects the key" {
    try testing.expect(hasTopLevelErrors("{\"errors\":[]}"));
    try testing.expect(!hasTopLevelErrors("{\"data\":{\"foo\":1}}"));
}

test "fork yields an independent client with shared connection" {
    var io_impl: std.Io.Threaded = .init(testing.allocator, .{});
    defer io_impl.deinit();
    const io = io_impl.io();

    const params: ConnectParams = .{ .port = 1234, .session_token = "secret" };
    var parent = try GraphQLClient.init(testing.allocator, io, params, .{});
    defer parent.deinit();

    var child = try parent.fork();
    defer child.deinit();

    // Same connection, but independently owned storage (no double-free, no
    // shared mutable state).
    try testing.expect(parent.endpoint.ptr != child.endpoint.ptr);
    try testing.expectEqualStrings(parent.endpoint, child.endpoint);
    try testing.expectEqualStrings(parent.auth_header, child.auth_header);
    try testing.expect(child.last_error == null);
    try testing.expect(!child.query_in_progress);
}
