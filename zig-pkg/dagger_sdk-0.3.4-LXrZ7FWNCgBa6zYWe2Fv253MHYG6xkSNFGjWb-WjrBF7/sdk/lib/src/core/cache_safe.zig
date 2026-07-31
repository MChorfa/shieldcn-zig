//! Cache fail-safe mechanisms for Dagger SDK.
//!
//! Implements graceful degradation when caching is unavailable or fails:
//!   - Automatic fallback to uncached builds on cache errors
//!   - Cache health monitoring with circuit breaker pattern
//!   - Cache bypass modes for debugging and recovery
//!   - Evidence-native logging of cache hit/miss/failure rates
//!
//! Cache failures should NEVER break a build — they should only slow it down.

const std = @import("std");
const errs = @import("../errors.zig");
const resilience = @import("resilience.zig");

/// Cache policy configuration.
pub const CachePolicy = enum {
    /// Use cache if available, fall back to uncached on any error.
    /// Default behavior for production.
    auto,

    /// Always use cache; fail the build if cache is unavailable.
    /// Use only in environments with guaranteed cache availability.
    required,

    /// Never use cache; always rebuild.
    /// Useful for debugging or when cache corruption is suspected.
    disabled,

    /// Read from cache but don't write back.
    /// Useful for CI jobs that should benefit from cached deps but not pollute cache.
    read_only,
};

/// Cache health state.
pub const CacheHealth = enum {
    /// Cache is operational.
    healthy,

    /// Cache is experiencing degraded performance (slow responses).
    degraded,

    /// Cache is unavailable; fall back to uncached builds.
    unavailable,
};

/// Cache fail-safe configuration.
pub const CacheConfig = struct {
    /// Cache policy to use
    policy: CachePolicy = .auto,

    /// Circuit breaker for cache failures
    breaker: resilience.CircuitBreaker = .{
        .failure_threshold = 3,
        .skip_requests = 10, // Skip 10 requests before retry
        .success_threshold = 2,
    },

    /// Maximum time to wait for cache operations (milliseconds)
    timeout_ms: u32 = 30000,

    /// Log cache events for observability
    enable_logging: bool = true,

    /// Metrics for evidence-native observability
    metrics: CacheMetrics = .{},
};

/// Metrics for cache observability.
pub const CacheMetrics = struct {
    /// Total cache lookup attempts
    lookups: u64 = 0,

    /// Successful cache hits
    hits: u64 = 0,

    /// Cache misses (not an error — just not in cache)
    misses: u64 = 0,

    /// Cache lookup failures (network, auth, etc)
    failures: u64 = 0,

    /// Fallback to uncached builds due to failures
    fallbacks: u64 = 0,

    /// Time spent waiting for cache (total milliseconds)
    total_wait_ms: u64 = 0,

    pub fn hitRate(self: CacheMetrics) f64 {
        if (self.lookups == 0) return 0.0;
        return @as(f64, @floatFromInt(self.hits)) / @as(f64, @floatFromInt(self.lookups));
    }

    pub fn failureRate(self: CacheMetrics) f64 {
        if (self.lookups == 0) return 0.0;
        return @as(f64, @floatFromInt(self.failures)) / @as(f64, @floatFromInt(self.lookups));
    }
};

/// Cache fail-safe manager.
pub const CacheFailSafe = struct {
    config: CacheConfig,
    allocator: std.mem.Allocator,
    io: std.Io,
    logger: ?*const Logger,

    const Self = @This();

    pub const Logger = struct {
        ctx: *anyopaque,
        log: *const fn (ctx: *anyopaque, level: Level, message: []const u8) void,

        pub const Level = enum {
            debug,
            info,
            warn,
            err,
        };
    };

    pub fn init(
        allocator: std.mem.Allocator,
        io: std.Io,
        config: CacheConfig,
        logger: ?*const Logger,
    ) Self {
        return .{
            .config = config,
            .allocator = allocator,
            .io = io,
            .logger = logger,
        };
    }

    /// Check if cache should be used for this operation.
    pub fn shouldUseCache(self: *Self) bool {
        switch (self.config.policy) {
            .disabled => return false,
            .required, .auto, .read_only => {
                // Check circuit breaker
                return self.config.breaker.allow();
            },
        }
    }

    /// Check if cache writes should be performed.
    pub fn shouldWriteCache(self: Self) bool {
        return switch (self.config.policy) {
            .disabled, .read_only => false,
            .auto, .required => true,
        };
    }

    /// Execute a cache operation with fail-safe handling.
    /// If the operation fails and policy is .auto, returns null (fall back to uncached).
    /// If policy is .required, propagates the error.
    pub fn executeLookup(
        self: *Self,
        comptime T: type,
        operation: *const fn () anyerror!?T,
    ) anyerror!?T {
        if (!self.shouldUseCache()) {
            self.log(.debug, "Cache lookup skipped (policy or circuit breaker)");
            return null;
        }

        self.config.metrics.lookups += 1;
        const result = operation();
        // Note: Timing metrics require Io.Timestamp which needs io instance
        // For now, we track operation counts without latency measurements

        if (result) |value| {
            if (value) |v| {
                self.config.metrics.hits += 1;
                self.config.breaker.recordSuccess();
                self.log(.debug, "Cache hit");
                return v;
            } else {
                self.config.metrics.misses += 1;
                self.config.breaker.recordSuccess();
                self.log(.debug, "Cache miss");
                return null;
            }
        } else |err| {
            self.config.metrics.failures += 1;
            self.config.breaker.recordFailure();

            self.logf(.warn, "Cache failure: {s}", .{@errorName(err)});

            switch (self.config.policy) {
                .auto, .read_only => {
                    self.config.metrics.fallbacks += 1;
                    self.log(.info, "Falling back to uncached build due to cache failure");
                    return null;
                },
                .required => return err,
                .disabled => {
                    // Should not reach here since shouldUseCache() returns false for .disabled
                    // This is defensive programming against future enum additions
                    self.log(.err, "Cache executeLookup called with disabled policy (internal error)");
                    return null;
                },
            }
        }
    }

    /// Record a successful cache write.
    pub fn recordWriteSuccess(self: *Self) void {
        self.config.breaker.recordSuccess();
        self.log(.debug, "Cache write successful");
    }

    /// Record a failed cache write (non-fatal).
    pub fn recordWriteFailure(self: *Self, err: anyerror) void {
        self.config.breaker.recordFailure();
        self.logf(.warn, "Cache write failed (non-fatal): {s}", .{@errorName(err)});
    }

    /// Get current health status.
    pub fn health(self: Self) CacheHealth {
        const failure_rate = self.config.metrics.failureRate();

        return switch (self.config.breaker.state) {
            .open => .unavailable,
            .half_open => .degraded,
            .closed => if (failure_rate > 0.1) .degraded else .healthy,
        };
    }

    /// Reset the circuit breaker (useful for manual recovery).
    pub fn resetCircuit(self: *Self) void {
        self.config.breaker.state = .closed;
        self.config.breaker.failure_count = 0;
        self.config.breaker.success_count = 0;
        self.log(.info, "Cache circuit breaker manually reset");
    }

    fn log(self: Self, level: Logger.Level, message: []const u8) void {
        if (!self.config.enable_logging) return;
        if (self.logger) |l| {
            l.log(l.ctx, level, message);
        }
    }

    fn logf(self: Self, level: Logger.Level, comptime fmt: []const u8, args: anytype) void {
        if (!self.config.enable_logging) return;
        if (self.logger) |l| {
            const message = std.fmt.allocPrint(self.allocator, fmt, args) catch return;
            defer self.allocator.free(message);
            l.log(l.ctx, level, message);
        }
    }
};

/// Builder for cache-friendly container configurations.
/// This is a placeholder — actual cache volume integration would come
/// from the generated Dagger API (CacheVolume type).
pub const CacheHints = struct {
    /// Cache volumes to mount
    volumes: []const CacheVolumeHint = &.{},

    /// Environment variables to treat as cache keys
    cache_env_vars: []const []const u8 = &.{},

    /// File paths to include in cache key calculation
    cache_files: []const []const u8 = &.{},

    pub const CacheVolumeHint = struct {
        /// Path in the container
        path: []const u8,
        /// Cache volume identifier
        key: []const u8,
    };
};

// ─────────────────────────── tests ──────────────────────────────────────────

const testing = std.testing;

test "CacheFailSafe auto policy falls back on failure" {
    const allocator = testing.allocator;
    var io_impl: std.Io.Threaded = .init(allocator, undefined);
    defer io_impl.deinit();
    const io = io_impl.io();

    var cfs = CacheFailSafe.init(allocator, io, .{
        .policy = .auto,
    }, null);

    // Test that auto policy allows cache usage
    try testing.expect(cfs.shouldUseCache());

    // Simulate a failing cache operation - should return null (fallback)
    const result = cfs.executeLookup(u32, struct {
        pub fn op() anyerror!?u32 {
            return error.OutOfMemory; // Simulate cache failure
        }
    }.op);

    // Auto policy should return null on failure, not error
    try testing.expectEqual(@as(?u32, null), result);
    try testing.expectEqual(@as(u64, 1), cfs.config.metrics.fallbacks);
}

test "CacheFailSafe required policy propagates errors" {
    const allocator = testing.allocator;
    var io_impl: std.Io.Threaded = .init(allocator, undefined);
    defer io_impl.deinit();
    const io = io_impl.io();

    var cfs = CacheFailSafe.init(allocator, io, .{
        .policy = .required,
    }, null);

    // Test that required policy allows cache usage
    try testing.expect(cfs.shouldUseCache());

    // Simulate a failing cache operation - should propagate error
    const result = cfs.executeLookup(u32, struct {
        pub fn op() anyerror!?u32 {
            return error.OutOfMemory; // Simulate cache failure
        }
    }.op);

    // Required policy should propagate the error
    try testing.expectError(error.OutOfMemory, result);
}

test "CacheFailSafe disabled policy skips cache" {
    const allocator = testing.allocator;
    var io_impl: std.Io.Threaded = .init(allocator, undefined);
    defer io_impl.deinit();
    const io = io_impl.io();

    var cfs = CacheFailSafe.init(allocator, io, .{
        .policy = .disabled,
    }, null);

    try testing.expect(!cfs.shouldUseCache());
    try testing.expect(!cfs.shouldWriteCache());
}

test "CacheMetrics hit rate calculation" {
    var metrics: CacheMetrics = .{};
    try testing.expectEqual(@as(f64, 0.0), metrics.hitRate());

    metrics.lookups = 100;
    metrics.hits = 75;
    metrics.misses = 25;
    try testing.expectApproxEqAbs(@as(f64, 0.75), metrics.hitRate(), 0.001);
}
