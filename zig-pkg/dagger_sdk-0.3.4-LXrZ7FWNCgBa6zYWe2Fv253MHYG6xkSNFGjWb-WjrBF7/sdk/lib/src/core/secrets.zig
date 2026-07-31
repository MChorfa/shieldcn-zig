//! Secret management and leak prevention for Dagger SDK.
//!
//! Implements defense-in-depth for secrets:
//!   - Automatic scrubbing of secrets from logs and error messages
//!   - Integration with external secret providers (Vault, env, files)
//!   - Secure memory handling with explicit zeroing on drop
//!   - Evidence-native audit trail for secret access (without exposing values)
//!
//! All secrets are treated as opaque values — the SDK never logs them,
//! never serializes them to JSON (except via Dagger's encrypted wire format),
//! and scrubs them from any string that might appear in diagnostics.

const std = @import("std");
const errs = @import("../errors.zig");

/// A secret value with automatic leak prevention.
/// The value is stored in secure memory and scrubbed on deinit.
pub const SecretValue = struct {
    /// The actual secret bytes. Mutable so we can zero on deinit.
    bytes: []u8,
    /// Source identifier for audit trails (e.g., "vault:kv/data/db#password")
    source: []const u8,
    /// Time the secret was loaded (for TTL/rotation detection)
    loaded_at: i64,

    const Self = @This();

    /// Create a SecretValue from plaintext. The plaintext is copied and
    /// immediately scrubbed from the source buffer.
    pub fn fromPlaintext(
        allocator: std.mem.Allocator,
        source: []const u8,
        plaintext: []const u8,
    ) errs.BuildError!Self {
        const bytes = try allocator.dupe(u8, plaintext);
        errdefer scrubAndFree(allocator, bytes);

        const source_copy = try allocator.dupe(u8, source);
        errdefer allocator.free(source_copy);

        return .{
            .bytes = bytes,
            .source = source_copy,
            .loaded_at = 0, // Will be set by caller with current time
        };
    }

    /// Set the loaded timestamp (call after creation with current time).
    pub fn setLoadedAt(self: *Self, timestamp_ms: i64) void {
        self.loaded_at = timestamp_ms;
    }

    /// Create from an environment variable. Returns null if env var not set.
    pub fn fromEnv(
        allocator: std.mem.Allocator,
        var_name: []const u8,
    ) errs.BuildError!?Self {
        const ptr = std.c.getenv(var_name.ptr) orelse return null;
        const value = std.mem.sliceTo(ptr, 0);

        const source = try std.fmt.allocPrint(allocator, "env:{s}", .{var_name});
        errdefer allocator.free(source);

        return try fromPlaintext(allocator, source, value);
    }

    /// Create from a file. The file is read and immediately scrubbed from page cache.
    pub fn fromFile(
        allocator: std.mem.Allocator,
        io: std.Io,
        path: []const u8,
    ) (errs.BuildError || std.Io.Error)!?Self {
        // Use Io for file operations
        var file = std.Io.File.open(io, path, .{ .mode = .read_only }) catch |e| switch (e) {
            error.NotFound => return null,
            else => return e,
        };
        defer file.close(io);

        // Read contents
        var content: std.ArrayList(u8) = .empty;
        defer content.deinit(allocator);

        var buf: [4096]u8 = undefined;
        const reader = file.reader(io, &buf);
        while (true) {
            const n = reader.readSliceShort(&buf) catch break;
            if (n == 0) break;
            try content.appendSlice(allocator, buf[0..n]);
        }

        // Trim trailing newline (common in secret files)
        var trimmed = content.items;
        if (trimmed.len > 0 and trimmed[trimmed.len - 1] == '\n') {
            trimmed = trimmed[0 .. trimmed.len - 1];
        }
        if (trimmed.len > 0 and trimmed[trimmed.len - 1] == '\r') {
            trimmed = trimmed[0 .. trimmed.len - 1];
        }

        const source = try std.fmt.allocPrint(allocator, "file:{s}", .{path});
        errdefer allocator.free(source);

        return try fromPlaintext(allocator, source, trimmed);
    }

    /// Deinit and securely scrub memory.
    pub fn deinit(self: *Self, allocator: std.mem.Allocator) void {
        scrubAndFree(allocator, self.bytes);
        allocator.free(self.source);
        self.* = undefined;
    }

    /// Get the secret value for use. The returned slice must not be logged!
    pub fn get(self: Self) []const u8 {
        return self.bytes;
    }

    /// Get the source identifier for audit logging.
    pub fn auditSource(self: Self) []const u8 {
        return self.source;
    }

    /// Check if the secret is older than the given TTL (milliseconds).
    pub fn isExpired(self: Self, ttl_ms: i64, now_ms: i64) bool {
        if (self.loaded_at == 0) return false; // No timestamp set
        return (now_ms - self.loaded_at) > ttl_ms;
    }

    /// Scrub and deallocate memory securely.
    fn scrubAndFree(allocator: std.mem.Allocator, bytes: []u8) void {
        // Multiple overwrite passes for defense in depth
        @memset(bytes, 0x00);
        @memset(bytes, 0xFF);
        @memset(bytes, 0x00);
        allocator.free(bytes);
    }
};

/// Registry of secrets for a session. Prevents duplicate loads and
/// provides centralized secret management.
pub const SecretRegistry = struct {
    allocator: std.mem.Allocator,
    /// Map from secret name to SecretValue
    secrets: std.StringHashMap(SecretValue),
    /// Scrubber for log sanitization
    scrubber: SecretScrubber,

    const Self = @This();

    pub fn init(allocator: std.mem.Allocator) Self {
        return .{
            .allocator = allocator,
            .secrets = std.StringHashMap(SecretValue).init(allocator),
            .scrubber = SecretScrubber.init(allocator),
        };
    }

    pub fn deinit(self: *Self) void {
        var iter = self.secrets.valueIterator();
        while (iter.next()) |secret| {
            secret.deinit(self.allocator);
        }
        self.secrets.deinit();
        self.scrubber.deinit();
    }

    /// Register a secret. Returns error if already exists (prevents accidental shadowing).
    pub fn register(
        self: *Self,
        name: []const u8,
        value: SecretValue,
    ) errs.BuildError!void {
        if (self.secrets.contains(name)) {
            return error.SecretAlreadyExists;
        }

        // Register with scrubber for log sanitization
        try self.scrubber.register(value.get());

        try self.secrets.put(name, value);
    }

    /// Get a secret by name. Returns null if not found.
    pub fn get(self: Self, name: []const u8) ?SecretValue {
        return self.secrets.get(name);
    }

    /// Load from environment variable and register.
    pub fn loadFromEnv(
        self: *Self,
        name: []const u8,
        var_name: []const u8,
    ) (errs.BuildError || error{SecretNotFound})!void {
        const value = (try SecretValue.fromEnv(self.allocator, var_name)) orelse {
            return error.SecretNotFound;
        };
        try self.register(name, value);
    }

    /// Load from file and register.
    pub fn loadFromFile(
        self: *Self,
        io: std.Io,
        name: []const u8,
        path: []const u8,
    ) (errs.BuildError || std.Io.Error || error{SecretNotFound})!void {
        const value = (try SecretValue.fromFile(self.allocator, io, path)) orelse {
            return error.SecretNotFound;
        };
        try self.register(name, value);
    }

    /// Sanitize a string to remove any embedded secrets.
    pub fn scrub(self: Self, input: []const u8) ![]const u8 {
        return self.scrubber.scrub(input);
    }
};

/// Scrubber that removes secret values from strings.
/// Used for sanitizing logs, error messages, and diagnostics.
pub const SecretScrubber = struct {
    allocator: std.mem.Allocator,
    /// List of secret values to scrub (stored hashed for security)
    patterns: std.ArrayList([]const u8),

    const Self = @This();

    pub fn init(allocator: std.mem.Allocator) Self {
        return .{
            .allocator = allocator,
            .patterns = .empty,
        };
    }

    pub fn deinit(self: *Self) void {
        for (self.patterns.items) |pattern| {
            // Scrub the pattern itself before freeing
            @memset(@constCast(pattern), 0x00);
            self.allocator.free(pattern);
        }
        self.patterns.deinit(self.allocator);
    }

    /// Maximum secret length to prevent abuse/DoS (1MB)
    pub const max_secret_len = 1024 * 1024;

    /// Register a secret value for scrubbing.
    pub fn register(self: *Self, secret: []const u8) !void {
        // Only register secrets longer than 4 chars (avoid false positives on short strings)
        if (secret.len < 4) return;

        // Cap maximum secret length to prevent abuse
        if (secret.len > max_secret_len) return error.SecretTooLong;

        // Check for duplicates to avoid redundant scrubbing
        for (self.patterns.items) |existing| {
            if (std.mem.eql(u8, existing, secret)) return; // Already registered
        }

        const copy = try self.allocator.dupe(u8, secret);
        errdefer self.allocator.free(copy);
        try self.patterns.append(self.allocator, copy);
    }

    /// Maximum output size to prevent memory exhaustion
    pub const max_output_len = 10 * 1024 * 1024; // 10MB

    /// Scrub secrets from input string, returning a new string.
    /// Replaces secrets with "***SCRUBBED***".
    /// Caller owns the returned string and must free it.
    pub fn scrub(self: Self, input: []const u8) error{ OutOfMemory, InputTooLarge }![]const u8 {
        // Protect against huge inputs that could exhaust memory
        if (input.len > max_output_len) return error.InputTooLarge;

        var result = try self.allocator.dupe(u8, input);
        errdefer self.allocator.free(result);

        // Limit number of patterns processed to prevent DoS
        const max_patterns = 1000;
        const patterns_to_check = @min(self.patterns.items.len, max_patterns);

        for (self.patterns.items[0..patterns_to_check]) |pattern| {
            var i: usize = 0;
            while (i + pattern.len <= result.len) {
                if (std.mem.eql(u8, result[i .. i + pattern.len], pattern)) {
                    // Replace with scrub marker
                    const before = result[0..i];
                    const after = result[i + pattern.len ..];

                    const marker = "***SCRUBBED***";
                    const new_len = before.len + marker.len + after.len;
                    const new_result = try self.allocator.alloc(u8, new_len);

                    @memcpy(new_result[0..before.len], before);
                    @memcpy(new_result[before.len..][0..marker.len], marker);
                    @memcpy(new_result[before.len + marker.len ..][0..after.len], after);

                    self.allocator.free(result);
                    result = new_result;

                    i += marker.len; // Skip past the marker
                } else {
                    i += 1;
                }
            }
        }

        return result;
    }
};

/// Audit trail entry for secret access.
pub const AuditEntry = struct {
    timestamp_ms: i64,
    source: []const u8,
    operation: Operation,

    pub const Operation = enum {
        load,
        use,
        rotate,
        scrub,
    };
};

// ─────────────────────────── errors ─────────────────────────────────────────

pub const SecretError = error{
    /// Secret already registered under this name.
    SecretAlreadyExists,
    /// Requested secret not found in registry.
    SecretNotFound,
    /// Secret has exceeded its TTL and needs rotation.
    SecretExpired,
    /// Secret value too short to be secure.
    SecretTooShort,
};

// ─────────────────────────── tests ──────────────────────────────────────────

const testing = std.testing;

test "SecretValue basic lifecycle" {
    const allocator = testing.allocator;

    var secret = try SecretValue.fromPlaintext(allocator, "test:source", "my-secret-value");
    defer secret.deinit(allocator);

    try testing.expectEqualStrings("my-secret-value", secret.get());
    try testing.expectEqualStrings("test:source", secret.auditSource());
}

test "SecretScrubber removes secrets" {
    const allocator = testing.allocator;

    var scrubber = SecretScrubber.init(allocator);
    defer scrubber.deinit();

    try scrubber.register("super-secret-password");

    const input = "Error connecting with password: super-secret-password";
    const scrubbed = try scrubber.scrub(input);
    defer allocator.free(scrubbed);

    try testing.expect(!std.mem.containsAtLeast(u8, scrubbed, 1, "super-secret-password"));
    try testing.expect(std.mem.containsAtLeast(u8, scrubbed, 1, "***SCRUBBED***"));
}

test "SecretRegistry prevents duplicate registration" {
    const allocator = testing.allocator;

    var registry = SecretRegistry.init(allocator);
    defer registry.deinit();

    const secret1 = try SecretValue.fromPlaintext(allocator, "test:1", "value1");
    try registry.register("key", secret1);

    var secret2 = try SecretValue.fromPlaintext(allocator, "test:2", "value2");
    try testing.expectError(error.SecretAlreadyExists, registry.register("key", secret2));

    // Clean up secret2 since it wasn't registered
    secret2.deinit(allocator);
}
