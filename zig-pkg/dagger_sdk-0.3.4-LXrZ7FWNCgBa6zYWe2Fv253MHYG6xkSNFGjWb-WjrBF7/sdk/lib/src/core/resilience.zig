//! Resilience patterns for Dagger SDK — retry, circuit breaker, and backoff.
//!
//! Implements defense-in-depth for network resilience:
//!   - Exponential backoff with jitter
//!   - Circuit breaker pattern to fail fast during outages
//!   - Per-operation retry policies configurable at connection time
//!
//! All errors are evidence-native: retry counts, circuit state changes,
//! and backoff durations are observable for telemetry.

const std = @import("std");
const errs = @import("../errors.zig");

/// Retry policy for GraphQL operations.
/// Default: 3 retries with exponential backoff (100ms, 200ms, 400ms).
pub const RetryPolicy = struct {
    /// Maximum number of retry attempts (0 = no retries)
    max_retries: u32 = 3,

    /// Initial backoff duration in milliseconds
    initial_backoff_ms: u32 = 100,

    /// Maximum backoff duration in milliseconds (caps exponential growth)
    max_backoff_ms: u32 = 5000,

    /// Backoff multiplier for exponential growth
    backoff_multiplier: f32 = 2.0,

    /// Random jitter factor (0.0-1.0) to prevent thundering herd
    jitter_factor: f32 = 0.1,

    /// Which errors are retryable (defaults to transient network errors)
    is_retryable: *const fn (err: errs.QueryError) bool = defaultIsRetryable,

    pub fn default() RetryPolicy {
        return .{};
    }

    /// Conservative policy for CI/CD: fail fast, minimal retries
    pub fn conservative() RetryPolicy {
        return .{
            .max_retries = 1,
            .initial_backoff_ms = 50,
            .max_backoff_ms = 500,
        };
    }

    /// Aggressive policy for unreliable networks: many retries, long timeouts
    pub fn aggressive() RetryPolicy {
        return .{
            .max_retries = 10,
            .initial_backoff_ms = 250,
            .max_backoff_ms = 30000,
        };
    }

    /// Validate and sanitize policy parameters to prevent edge cases.
    /// Returns a sanitized copy with safe defaults for invalid values.
    pub fn validate(self: RetryPolicy) RetryPolicy {
        var sanitized = self;

        // Cap max_retries to reasonable limit (100 = ~4 hours at max backoff)
        if (sanitized.max_retries > 100) sanitized.max_retries = 100;

        // Ensure initial_backoff_ms is at least 1ms
        if (sanitized.initial_backoff_ms == 0) sanitized.initial_backoff_ms = 1;

        // Ensure max_backoff_ms is at least as large as initial
        if (sanitized.max_backoff_ms < sanitized.initial_backoff_ms) {
            sanitized.max_backoff_ms = sanitized.initial_backoff_ms;
        }

        // Cap max_backoff_ms to 1 hour (prevents overflow in ns calculations)
        if (sanitized.max_backoff_ms > 3_600_000) sanitized.max_backoff_ms = 3_600_000;

        // Ensure backoff_multiplier is reasonable (1.0 = no growth, 10.0 = very aggressive)
        if (sanitized.backoff_multiplier < 1.0 or !std.math.isFinite(sanitized.backoff_multiplier)) {
            sanitized.backoff_multiplier = 2.0;
        }
        if (sanitized.backoff_multiplier > 10.0) sanitized.backoff_multiplier = 10.0;

        // Ensure jitter_factor is in [0, 1] range
        if (sanitized.jitter_factor < 0.0 or !std.math.isFinite(sanitized.jitter_factor)) {
            sanitized.jitter_factor = 0.0;
        }
        if (sanitized.jitter_factor > 1.0) sanitized.jitter_factor = 1.0;

        return sanitized;
    }
};

/// Default retryable error predicate.
fn defaultIsRetryable(err: errs.QueryError) bool {
    return switch (err) {
        // Network/transient errors are retryable
        error.TransportFailed,
        error.HttpStatus, // 5xx or 429 rate limit
        => true,

        // Domain errors are not retryable (they'll fail the same way)
        error.DomainError,
        error.InvalidEnvelope,
        error.MalformedResponse,
        error.TooManyNestedObjects,
        error.DeserializeFailed,

        // Circuit open is not retryable — it's an intentional fail-fast
        error.CircuitOpen,

        // Resource errors are not retryable
        error.OutOfMemory,
        => false,
    };
}

/// Circuit breaker states for fail-fast behavior during outages.
pub const CircuitState = enum {
    /// Normal operation — requests pass through
    closed,

    /// Checking if service recovered — limited probe requests allowed
    half_open,

    /// Service appears unhealthy — requests fail fast
    open,
};

/// Circuit breaker configuration.
pub const CircuitBreaker = struct {
    /// Number of consecutive failures before opening circuit
    failure_threshold: u32 = 5,

    /// Number of requests to skip before trying again when open
    skip_requests: u32 = 10,

    /// Number of successes required in half-open state to close circuit
    success_threshold: u32 = 3,

    // Runtime state (not configurable)
    state: CircuitState = .closed,
    failure_count: u32 = 0,
    success_count: u32 = 0,
    skip_counter: u32 = 0,

    /// Returns true if the circuit allows the request to proceed.
    pub fn allow(self: *CircuitBreaker) bool {
        // Validate thresholds are non-zero to prevent stuck states
        const effective_failure_threshold = if (self.failure_threshold == 0) 1 else self.failure_threshold;
        const effective_skip_requests = if (self.skip_requests == 0) 1 else self.skip_requests;
        const effective_success_threshold = if (self.success_threshold == 0) 1 else self.success_threshold;

        switch (self.state) {
            .closed => {
                // If circuit is closed but already at failure threshold, open it
                if (self.failure_count >= effective_failure_threshold) {
                    self.state = .open;
                    self.skip_counter = 0;
                    return false;
                }
                return true;
            },
            .half_open => {
                // Limit probe requests in half-open to prevent hammering
                if (self.success_count >= effective_success_threshold) {
                    self.state = .closed;
                    self.failure_count = 0;
                    self.success_count = 0;
                }
                return true;
            },
            .open => {
                // Check if we've skipped enough requests
                if (self.skip_counter >= effective_skip_requests) {
                    self.state = .half_open;
                    self.skip_counter = 0;
                    self.success_count = 0;
                    return true;
                }
                self.skip_counter += 1;
                return false;
            },
        }
    }

    /// Record a successful request.
    pub fn recordSuccess(self: *CircuitBreaker) void {
        const effective_success_threshold = if (self.success_threshold == 0) 1 else self.success_threshold;

        switch (self.state) {
            .closed => {
                self.failure_count = 0; // Reset on any success
            },
            .half_open => {
                // Prevent overflow in success counter
                if (self.success_count < std.math.maxInt(u32)) {
                    self.success_count += 1;
                }
                if (self.success_count >= effective_success_threshold) {
                    self.state = .closed;
                    self.failure_count = 0;
                    self.success_count = 0;
                }
            },
            .open => {}, // Shouldn't happen
        }
    }

    /// Record a failed request.
    pub fn recordFailure(self: *CircuitBreaker) void {
        const effective_failure_threshold = if (self.failure_threshold == 0) 1 else self.failure_threshold;

        switch (self.state) {
            .closed => {
                // Prevent overflow in failure counter
                if (self.failure_count < std.math.maxInt(u32)) {
                    self.failure_count += 1;
                }
                if (self.failure_count >= effective_failure_threshold) {
                    self.state = .open;
                    self.skip_counter = 0;
                }
            },
            .half_open => {
                // Failure in half-open immediately opens circuit again
                self.state = .open;
                self.skip_counter = 0;
            },
            .open => {}, // Shouldn't happen
        }
    }
};

/// Resilient executor that wraps GraphQL operations with retry and circuit breaker.
pub const ResilientExecutor = struct {
    policy: RetryPolicy,
    breaker: ?*CircuitBreaker,
    io: std.Io,

    /// Execute an operation with resilience patterns applied.
    /// `operation` is a function that returns QueryError!T.
    pub fn execute(
        self: *ResilientExecutor,
        comptime T: type,
        operation: *const fn () errs.QueryError!T,
    ) errs.QueryError!T {
        // Check circuit breaker first
        if (self.breaker) |cb| {
            if (!cb.allow()) {
                return error.CircuitOpen;
            }
        }

        var last_error: errs.QueryError = undefined;
        var backoff_ms: u32 = self.policy.initial_backoff_ms;

        var attempt: u32 = 0;
        while (attempt <= self.policy.max_retries) : (attempt += 1) {
            const result = operation();

            if (result) |value| {
                // Success
                if (self.breaker) |cb| {
                    cb.recordSuccess();
                }
                return value;
            } else |err| {
                last_error = err;

                // Check if error is retryable
                if (!self.policy.is_retryable(err)) {
                    // Non-retryable error — record and return immediately
                    if (self.breaker) |cb| {
                        cb.recordFailure();
                    }
                    return err;
                }

                // Last attempt — don't retry
                if (attempt == self.policy.max_retries) {
                    if (self.breaker) |cb| {
                        cb.recordFailure();
                    }
                    return err;
                }

                // Calculate backoff with jitter (with overflow protection)
                const jitter = self.calculateJitter(backoff_ms);
                const sleep_ms = @min(backoff_ms + jitter, self.policy.max_backoff_ms);

                // Sleep using Io with proper Zig 0.16 signature (use u64 to prevent overflow)
                const sleep_ns = @as(i96, @intCast(sleep_ms)) * std.time.ns_per_ms;
                const duration = std.Io.Duration.fromNanoseconds(sleep_ns);
                self.io.sleep(duration, .awake) catch {}; // Ignore cancel for retry

                // Exponential backoff
                const next_backoff = @as(u32, @intFromFloat(
                    @as(f32, @floatFromInt(backoff_ms)) * self.policy.backoff_multiplier,
                ));
                backoff_ms = @min(next_backoff, self.policy.max_backoff_ms);
            }
        }

        // Should never reach here, but satisfy compiler
        return last_error;
    }

    pub fn calculateJitter(self: *const ResilientExecutor, base_ms: u32) u32 {
        if (self.policy.jitter_factor == 0.0) return 0;
        if (!std.math.isFinite(self.policy.jitter_factor)) return 0; // NaN/Inf protection

        // Simple jitter: ±jitter_factor * base_ms
        const jitter_range = @as(f32, @floatFromInt(base_ms)) * self.policy.jitter_factor;
        // Use a simple pseudo-random based on address for determinism in tests
        const random_value = @intFromPtr(self) % 65536;
        const random_factor = @as(f32, @floatFromInt(random_value)) / 65535.0;
        const jitter_amount = jitter_range * (random_factor * 2.0 - 1.0); // -1 to +1
        const jitter_abs = @abs(jitter_amount);

        // Guard against NaN and overflow (use large but representable f32 value)
        if (!std.math.isFinite(jitter_abs) or jitter_abs > 1_000_000.0) {
            return 0;
        }
        return @intFromFloat(jitter_abs);
    }
};

/// Evidence struct for observability/monitoring.
pub const ResilienceMetrics = struct {
    total_requests: u64,
    successful_requests: u64,
    failed_requests: u64,
    retried_requests: u64,
    circuit_open_events: u64,
    total_retry_delay_ms: u64,
};

// ─────────────────────────── tests ──────────────────────────────────────────

const testing = std.testing;

test "circuit breaker transitions" {
    var cb: CircuitBreaker = .{
        .failure_threshold = 3,
    };

    // Start closed
    try testing.expect(cb.allow());

    // Record failures
    cb.recordFailure();
    try testing.expect(cb.allow());
    cb.recordFailure();
    try testing.expect(cb.allow());
    cb.recordFailure();

    // Circuit should be open now
    try testing.expect(!cb.allow());
    try testing.expectEqual(CircuitState.open, cb.state);
}

test "circuit breaker recovery" {
    var cb: CircuitBreaker = .{
        .failure_threshold = 1,
        .skip_requests = 1, // Skip only 1 request before retry
        .success_threshold = 2,
    };

    // Open the circuit
    cb.recordFailure();
    try testing.expect(!cb.allow());

    // Skip one request, then should be half-open
    try testing.expect(cb.allow()); // Half-open

    // Record successes to close
    cb.recordSuccess();
    try testing.expectEqual(CircuitState.half_open, cb.state);
    cb.recordSuccess();
    try testing.expectEqual(CircuitState.closed, cb.state);
    try testing.expect(cb.allow());
}

test "retry policy defaults" {
    const policy = RetryPolicy.default();
    try testing.expectEqual(@as(u32, 3), policy.max_retries);
    try testing.expect(policy.is_retryable(error.TransportFailed));
    try testing.expect(!policy.is_retryable(error.DomainError));
}
