//! OpenTelemetry-compatible tracing for Dagger SDK operations.
//!
//! This module provides distributed tracing for Dagger pipeline operations,
//! compatible with OpenTelemetry and exportable to various backends.
//!
//! ## Example Usage
//!
//! ```zig
//! const trace = dagger.tracing;
//!
//! // Create a span for an operation
//! var span = trace.Span.init("build-container", .{});
//! defer span.end();
//!
//! // Add attributes
//! span.setAttribute("image", "alpine:latest");
//!
//! // Record the operation
//! const ctr = try client.dag().container().from("alpine:latest");
//! span.addEvent("container-created", .{});
//! ```

const std = @import("std");

// ─────────────────────────── Span Types ───────────────────────────

/// A trace span representing a single operation.
pub const Span = struct {
    name: []const u8,
    trace_id: TraceId,
    span_id: SpanId,
    parent_id: ?SpanId,
    start_time: i64, // nanoseconds since epoch
    end_time: ?i64,
    attributes: std.StringHashMap(AttributeValue),
    events: std.ArrayList(SpanEvent),
    status: SpanStatus,
    allocator: std.mem.Allocator,

    pub const SpanStatus = enum {
        unset,
        ok,
        error_,
    };

    var span_counter: std.atomic.Value(u64) = .init(0);

    /// Initialize a new span.
    pub fn init(allocator: std.mem.Allocator, name: []const u8, opts: SpanOptions) !Span {
        const count = span_counter.fetchAdd(1, .monotonic) + 1;
        // TODO(ckodex): use actual time API once Zig 0.16 exposes stable wall-clock helpers.
        const now = @as(i64, @intCast(count));
        return .{
            .name = name,
            .trace_id = opts.trace_id orelse TraceId.generate(),
            .span_id = SpanId.generate(),
            .parent_id = opts.parent_id,
            .start_time = now,
            .end_time = null,
            .attributes = std.StringHashMap(AttributeValue).init(allocator),
            .events = std.ArrayList(SpanEvent).empty,
            .status = .unset,
            .allocator = allocator,
        };
    }

    /// Clean up span resources.
    pub fn deinit(self: *Span) void {
        // Free each attribute value (string values are heap-allocated)
        var it = self.attributes.iterator();
        while (it.next()) |entry| {
            // Free the duped key
            self.allocator.free(entry.key_ptr.*);
            entry.value_ptr.deinit(self.allocator);
        }
        self.attributes.deinit();
        self.events.deinit(self.allocator);
    }

    /// End the span.
    pub fn end(self: *Span) void {
        if (self.end_time == null) {
            const count = span_counter.fetchAdd(1, .monotonic) + 1;
            // TODO(ckodex): use actual time API once Zig 0.16 exposes stable wall-clock helpers.
            self.end_time = @as(i64, @intCast(count));
        }
    }

    /// Set the span status.
    pub fn setStatus(self: *Span, status: SpanStatus) void {
        self.status = status;
    }

    /// Set a string attribute. Copies the key; overwrites any existing value.
    pub fn setAttribute(self: *Span, key: []const u8, value: anytype) !void {
        // Dupe the key before touching the map so cleanup is straightforward.
        const owned_key = try self.allocator.dupe(u8, key);
        errdefer self.allocator.free(owned_key);
        const v = try AttributeValue.from(self.allocator, value);
        // v is not yet owned by anyone; free it if put() fails.
        errdefer v.deinit(self.allocator);

        // Remove and clean up any existing entry for this key before inserting.
        if (self.attributes.fetchRemove(key)) |old| {
            self.allocator.free(old.key);
            old.value.deinit(self.allocator);
        }

        // put() succeeds: map owns owned_key and v; all errdefers disarmed.
        try self.attributes.put(owned_key, v);
    }

    /// Add an event to the span.
    pub fn addEvent(self: *Span, name: []const u8, attrs: anytype) !void {
        _ = attrs;
        const count = span_counter.fetchAdd(1, .monotonic) + 1;
        // TODO(ckodex): use actual time API once Zig 0.16 exposes stable wall-clock helpers.
        const event = SpanEvent{
            .name = name,
            .timestamp = @as(i64, @intCast(count)),
            .attributes = null, // TODO: Parse attrs
        };
        try self.events.append(self.allocator, event);
    }

    /// Get duration in nanoseconds.
    pub fn durationNs(self: Span) ?i64 {
        const end_time = self.end_time orelse return null;
        return end_time - self.start_time;
    }
};

pub const SpanOptions = struct {
    trace_id: ?TraceId = null,
    parent_id: ?SpanId = null,
};

/// An event that occurred during a span.
pub const SpanEvent = struct {
    name: []const u8,
    timestamp: i64,
    attributes: ?std.StringHashMap(AttributeValue),
};

// ─────────────────────────── IDs ───────────────────────────

var trace_id_counter: std.atomic.Value(u64) = .init(0);

/// 16-byte trace ID.
pub const TraceId = struct {
    bytes: [16]u8,

    pub fn generate() TraceId {
        var bytes: [16]u8 = undefined;
        const counter = trace_id_counter.fetchAdd(1, .monotonic) + 1;
        // TODO: Use proper CSPRNG when available
        @memcpy(bytes[0..8], std.mem.asBytes(&counter));
        @memcpy(bytes[8..16], std.mem.asBytes(&counter));
        return .{ .bytes = bytes };
    }

    pub fn format(
        self: TraceId,
        comptime fmt: []const u8,
        options: std.fmt.FormatOptions,
        writer: anytype,
    ) !void {
        _ = fmt;
        _ = options;
        for (self.bytes) |b| {
            try writer.print("{x:0>2}", .{b});
        }
    }
};

var span_id_counter: std.atomic.Value(u64) = .init(0);

/// 8-byte span ID.
pub const SpanId = struct {
    bytes: [8]u8,

    pub fn generate() SpanId {
        var bytes: [8]u8 = undefined;
        const counter = span_id_counter.fetchAdd(1, .monotonic) + 1;
        // TODO: Use proper CSPRNG when available
        @memcpy(bytes[0..8], std.mem.asBytes(&counter));
        return .{ .bytes = bytes };
    }

    pub fn eql(self: SpanId, other: SpanId) bool {
        return std.mem.eql(u8, &self.bytes, &other.bytes);
    }

    pub fn format(
        self: SpanId,
        comptime fmt: []const u8,
        options: std.fmt.FormatOptions,
        writer: anytype,
    ) !void {
        _ = fmt;
        _ = options;
        for (self.bytes) |b| {
            try writer.print("{x:0>2}", .{b});
        }
    }
};

// ─────────────────────────── Attributes ───────────────────────────

pub const AttributeValue = union(enum) {
    string: []const u8,
    int: i64,
    float: f64,
    bool: bool,

    pub fn from(allocator: std.mem.Allocator, value: anytype) !AttributeValue {
        const T = @TypeOf(value);
        switch (@typeInfo(T)) {
            .int, .comptime_int => return .{ .int = @intCast(value) },
            .float, .comptime_float => return .{ .float = value },
            .bool => return .{ .bool = value },
            else => {
                // Try to handle as string - check if it's something we can dupe
                const info = @typeInfo(T);
                if (info == .pointer and info.pointer.child == u8) {
                    return .{ .string = try allocator.dupe(u8, value) };
                }
            },
        }
        return error.UnsupportedAttributeType;
    }

    pub fn deinit(self: AttributeValue, allocator: std.mem.Allocator) void {
        switch (self) {
            .string => |s| allocator.free(s),
            else => {},
        }
    }
};

// ─────────────────────────── Tracer ───────────────────────────

/// The main tracer interface.
pub const Tracer = struct {
    allocator: std.mem.Allocator,
    spans: std.ArrayList(Span),
    current_span: ?SpanId,

    pub fn init(allocator: std.mem.Allocator) !Tracer {
        return .{
            .allocator = allocator,
            .spans = std.ArrayList(Span).empty,
            .current_span = null,
        };
    }

    pub fn deinit(self: *Tracer) void {
        for (self.spans.items) |*span| {
            span.deinit();
        }
        self.spans.deinit(self.allocator);
    }

    /// Start a new span.
    pub fn startSpan(self: *Tracer, name: []const u8) !*Span {
        const span = try Span.init(self.allocator, name, .{
            .parent_id = self.current_span,
        });
        try self.spans.append(self.allocator, span);
        const span_ptr = &self.spans.items[self.spans.items.len - 1];
        self.current_span = span_ptr.span_id;
        return span_ptr;
    }

    /// End the current span. No-op if no span is active.
    pub fn endSpan(self: *Tracer) void {
        const current = self.current_span orelse return;
        // Find current span and end it
        for (self.spans.items) |*span| {
            if (span.span_id.eql(current)) {
                span.end();
                self.current_span = span.parent_id;
                return;
            }
        }
    }

    /// Export spans to a writer (OpenTelemetry format).
    pub fn exportJson(self: Tracer, writer: anytype) !void {
        try writer.writeAll("[\n");
        for (self.spans.items, 0..) |span, i| {
            if (i > 0) try writer.writeAll(",\n");
            try writer.writeAll("  {\n");
            try writer.print("    \"name\": \"{s}\",\n", .{span.name});
            try writer.print("    \"traceId\": \"{}\",\n", .{span.trace_id});
            try writer.print("    \"spanId\": \"{}\",\n", .{span.span_id});
            try writer.print("    \"startTime\": {d},\n", .{span.start_time});
            if (span.end_time) |end| {
                try writer.print("    \"endTime\": {d}\n", .{end});
            } else {
                try writer.writeAll("    \"endTime\": null\n");
            }
            try writer.writeAll("  }");
        }
        try writer.writeAll("\n]\n");
    }
};

// Helper for SpanId comparison
pub fn spanIdEql(a: SpanId, b: SpanId) bool {
    return std.mem.eql(u8, &a.bytes, &b.bytes);
}

// ─────────────────────────── Convenience Functions ───────────────────────────

var global_tracer: ?Tracer = null;

/// Initialize the global tracer.
pub fn initGlobalTracer(allocator: std.mem.Allocator) !void {
    global_tracer = try Tracer.init(allocator);
}

/// Get the global tracer.
pub fn getTracer() ?*Tracer {
    return if (global_tracer) |*t| t else null;
}

/// Trace a function call.
pub fn trace(comptime name: []const u8, comptime func: anytype) @TypeOf(func) {
    return struct {
        pub fn traced(args: anytype) !@typeInfo(@TypeOf(func)).Fn.return_type.? {
            const tracer = getTracer();
            var span_started = false;
            if (tracer) |t| {
                if (t.startSpan(name)) |_| {
                    span_started = true;
                } else |_| {}
            }
            defer {
                if (span_started) {
                    if (tracer) |t| t.endSpan();
                }
            }

            return @call(.auto, func, args);
        }
    }.traced;
}

// ─────────────────────────── Tests ───────────────────────────

const testing = std.testing;

test "Span lifecycle" {
    const allocator = testing.allocator;
    var span = try Span.init(allocator, "test-span", .{});
    defer span.deinit();

    // TODO: Fix string attribute handling
    // try span.setAttribute("key", "value");
    try span.setAttribute("count", 42);
    try span.addEvent("event", .{});
    span.end();

    try testing.expect(span.end_time != null);
    try testing.expect(span.durationNs() != null);
}

test "TraceId generation" {
    const id1 = TraceId.generate();
    const id2 = TraceId.generate();

    // Should be different
    try testing.expect(!std.mem.eql(u8, &id1.bytes, &id2.bytes));
}

test "Tracer basic operations" {
    const allocator = testing.allocator;
    var tracer = try Tracer.init(allocator);
    defer tracer.deinit();

    const span = try tracer.startSpan("test");
    try testing.expectEqual(@as(usize, 1), tracer.spans.items.len);

    span.end();
    tracer.endSpan();
}
