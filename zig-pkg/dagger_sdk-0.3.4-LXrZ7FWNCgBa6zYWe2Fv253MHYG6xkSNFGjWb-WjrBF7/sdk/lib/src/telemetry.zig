//! OpenTelemetry tracing and observability for dagger-zig.
//!
//! Provides:
//! - Automatic span creation for Dagger operations
//! - Progress streaming support
//! - Request/response logging
//! - Metrics collection

const std = @import("std");
const gql = @import("core/graphql_client.zig");

pub fn nowMs() i64 {
    var ts: std.c.timespec = undefined;
    _ = std.c.clock_gettime(std.c.CLOCK.MONOTONIC, &ts);
    const sec_ms: i64 = @intCast(ts.sec);
    const nsec_ms: i64 = @intCast(@divTrunc(ts.nsec, std.time.ns_per_ms));
    return sec_ms * std.time.ms_per_s + nsec_ms;
}

/// Tracing configuration
pub const Config = struct {
    /// Enable tracing
    enabled: bool = false,
    /// Export to console (for debugging)
    console_exporter: bool = true,
    /// OTLP endpoint (optional)
    otlp_endpoint: ?[]const u8 = null,
    /// Service name for traces
    service_name: []const u8 = "dagger-zig",
    /// Sample rate (1.0 = all traces)
    sample_rate: f32 = 1.0,
};

/// Span kind
pub const SpanKind = enum {
    internal,
    server,
    client,
    producer,
    consumer,
};

/// Span status
pub const SpanStatus = enum {
    unset,
    ok,
    err,
};

/// A trace span
pub const Span = struct {
    name: []const u8,
    kind: SpanKind,
    start_time: i64,
    attributes: std.StringHashMap([]const u8),
    parent_id: ?u64,
    id: u64,
    status: SpanStatus = .unset,
    status_message: ?[]const u8 = null,

    const Self = @This();

    pub fn init(allocator: std.mem.Allocator, name: []const u8, kind: SpanKind) Self {
        return .{
            .name = name,
            .kind = kind,
            .start_time = nowMs(),
            .attributes = std.StringHashMap([]const u8).init(allocator),
            .parent_id = current_span_id,
            .id = @as(u64, @intCast(nowMs())),
        };
    }

    /// Set an attribute
    pub fn setAttribute(self: *Self, key: []const u8, value: []const u8) !void {
        try self.attributes.put(key, value);
    }

    /// Set span status
    pub fn setStatus(self: *Self, status: SpanStatus, message: ?[]const u8) void {
        self.status = status;
        self.status_message = message;
    }

    /// End the span and export it
    pub fn end(self: *Self, config: Config) void {
        if (!config.enabled) return;

        const duration = nowMs() - self.start_time;

        if (config.console_exporter) {
            std.log.info("[TRACE] {s} - {s} ({d}ms)", .{
                @tagName(self.kind),
                self.name,
                duration,
            });

            if (config.enabled and config.console_exporter) {
                var it = self.attributes.iterator();
                while (it.next()) |entry| {
                    std.log.debug("  {s}: {s}", .{ entry.key_ptr.*, entry.value_ptr.* });
                }
            }
        }

        // OTLP export is deferred until a backend and schema contract are wired.
        // if (config.otlp_endpoint) |endpoint| {
        //     exportToOTLP(self, endpoint);
        // }

        self.attributes.deinit();
    }
};

threadlocal var current_span_id: ?u64 = null;

/// Tracer for creating spans
pub const Tracer = struct {
    config: Config,
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator, config: Config) Tracer {
        return .{
            .config = config,
            .allocator = allocator,
        };
    }

    /// Start a new span
    pub fn startSpan(self: *Tracer, name: []const u8, kind: SpanKind) Span {
        return Span.init(self.allocator, name, kind);
    }

    /// Create a span around a function call
    pub fn withSpan(
        self: *Tracer,
        name: []const u8,
        kind: SpanKind,
        comptime ReturnType: type,
        comptime func: fn () ReturnType,
    ) ReturnType {
        if (!self.config.enabled) {
            return func();
        }

        var span = self.startSpan(name, kind);
        defer span.end(self.config);

        const prev_span = current_span_id;
        current_span_id = span.id;
        defer current_span_id = prev_span;

        return func();
    }
};

/// Progress tracking for long-running operations
pub const Progress = struct {
    allocator: std.mem.Allocator,
    operation: []const u8,
    total_steps: ?u32,
    current_step: u32 = 0,
    start_time: i64,

    pub fn init(allocator: std.mem.Allocator, operation: []const u8, total_steps: ?u32) Progress {
        return .{
            .allocator = allocator,
            .operation = operation,
            .total_steps = total_steps,
            .start_time = nowMs(),
        };
    }

    /// Report progress update
    pub fn update(self: *Progress, step: u32, message: []const u8) void {
        self.current_step = step;
        const elapsed = nowMs() - self.start_time;

        if (self.total_steps) |total| {
            const percent = @as(f32, @floatFromInt(step)) / @as(f32, @floatFromInt(total)) * 100.0;
            std.log.info("[PROGRESS] {s}: {d}/{d} ({d:.1}%) - {s} [{d}ms]", .{
                self.operation,
                step,
                total,
                percent,
                message,
                elapsed,
            });
        } else {
            std.log.info("[PROGRESS] {s}: step {d} - {s} [{d}ms]", .{
                self.operation,
                step,
                message,
                elapsed,
            });
        }
    }

    /// Mark operation as complete
    pub fn complete(self: *Progress) void {
        const elapsed = nowMs() - self.start_time;
        std.log.info("[PROGRESS] {s}: complete [{d}ms]", .{ self.operation, elapsed });
    }
};

/// Request/response logging wrapper
pub const LoggingMiddleware = struct {
    config: Config,

    pub fn init(config: Config) LoggingMiddleware {
        return .{ .config = config };
    }

    /// Log a GraphQL query
    pub fn logQuery(self: *LoggingMiddleware, query: []const u8) void {
        if (!self.config.enabled) return;

        // Truncate long queries for readability
        const max_len = 200;
        if (query.len > max_len) {
            std.log.debug("[GRAPHQL] {s}... (truncated)", .{query[0..max_len]});
        } else {
            std.log.debug("[GRAPHQL] {s}", .{query});
        }
    }

    /// Log a GraphQL response
    pub fn logResponse(self: *LoggingMiddleware, response: []const u8, duration_ms: i64) void {
        if (!self.config.enabled) return;

        std.log.debug("[GRAPHQL] response [{d}ms]: {s}", .{
            duration_ms,
            if (response.len > 100) "..." else response,
        });
    }
};

/// Metrics collection
pub const Metrics = struct {
    request_count: std.atomic.Value(u64) = .init(0),
    request_duration_ms: std.atomic.Value(u64) = .init(0),
    error_count: std.atomic.Value(u64) = .init(0),

    pub fn recordRequest(self: *Metrics, duration_ms: u64, success: bool) void {
        _ = self.request_count.fetchAdd(1, .monotonic);
        _ = self.request_duration_ms.fetchAdd(duration_ms, .monotonic);
        if (!success) {
            _ = self.error_count.fetchAdd(1, .monotonic);
        }
    }

    pub fn getStats(self: *Metrics) Stats {
        const count = self.request_count.load(.acquire);
        const duration = self.request_duration_ms.load(.acquire);
        const errors = self.error_count.load(.acquire);

        return .{
            .total_requests = count,
            .avg_duration_ms = if (count > 0) duration / count else 0,
            .error_rate = if (count > 0) @as(f32, @floatFromInt(errors)) / @as(f32, @floatFromInt(count)) else 0.0,
        };
    }
};

pub const Stats = struct {
    total_requests: u64,
    avg_duration_ms: u64,
    error_rate: f32,
};

/// Global metrics instance
pub var global_metrics: Metrics = .{};

/// Initialize telemetry with configuration
pub fn init(config: Config) void {
    if (config.enabled) {
        std.log.info("Telemetry enabled: service={s}, console={}", .{
            config.service_name,
            config.console_exporter,
        });
        if (config.otlp_endpoint) |ep| {
            std.log.info("OTLP endpoint: {s}", .{ep});
        }
    }
}
