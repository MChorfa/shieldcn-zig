const std = @import("std");

/// shieldcn-zig — db/token_pool.zig
/// GitHub OAuth token pool for distributing API requests across
/// user-donated tokens to stay under rate limits.
///
/// Each token tracks:
///   - remaining requests (from X-RateLimit-Remaining)
///   - reset timestamp (from X-RateLimit-Reset)
///   - last used time
///   - failure count (for backoff)
///
/// Selection strategy: round-robin weighted by remaining quota.

pub const Token = struct {
    value: []const u8, // "ghp_..." token string
    remaining: u32 = 5000,
    reset_at: i64 = 0, // unix seconds
    last_used: i64 = 0,
    failures: u32 = 0,
};

pub const TokenPool = struct {
    allocator: std.mem.Allocator,
    tokens: std.ArrayList(Token),
    current_index: usize = 0,

    pub fn init(allocator: std.mem.Allocator) TokenPool {
        return .{
            .allocator = allocator,
            .tokens = std.ArrayList(Token).empty,
        };
    }

    pub fn deinit(self: *TokenPool) void {
        for (self.tokens.items) |token| {
            self.allocator.free(token.value);
        }
        self.tokens.deinit(self.allocator);
    }

    /// Add a new token to the pool. Value is copied.
    pub fn add(self: *TokenPool, value: []const u8) !void {
        const owned = try self.allocator.dupe(u8, value);
        errdefer self.allocator.free(owned);
        try self.tokens.append(self.allocator, .{ .value = owned });
    }

    /// Get the next available token with quota remaining.
    /// Returns null if all tokens are exhausted or expired.
    pub fn next(self: *TokenPool) ?*Token {
        if (self.tokens.items.len == 0) return null;

        const now = nowSeconds();
        var best: ?*Token = null;
        var best_remaining: u32 = 0;
        var checked: usize = 0;

        // Start from current index and wrap around
        var idx = self.current_index;
        while (checked < self.tokens.items.len) : (checked += 1) {
            const token = &self.tokens.items[idx];

            // Reset quota if window has passed
            if (token.reset_at > 0 and now > token.reset_at) {
                token.remaining = 5000;
                token.reset_at = 0;
                token.failures = 0;
            }

            // Skip tokens with zero remaining or too many failures
            if (token.remaining > 0 and token.failures < 3) {
                if (token.remaining > best_remaining) {
                    best = token;
                    best_remaining = token.remaining;
                }
            }

            idx = (idx + 1) % self.tokens.items.len;
        }

        if (best) |b| {
            self.current_index = (idx + 1) % self.tokens.items.len;
            b.last_used = now;
        }

        return best;
    }

    /// Update rate limit metadata from response headers.
    pub fn updateRateLimit(
        self: *TokenPool,
        token_value: []const u8,
        remaining: u32,
        reset_at: i64,
    ) void {
        for (self.tokens.items) |*token| {
            if (std.mem.eql(u8, token.value, token_value)) {
                token.remaining = remaining;
                token.reset_at = reset_at;
                break;
            }
        }
    }

    /// Mark a token as failed (e.g. 401/403 response).
    pub fn markFailed(self: *TokenPool, token_value: []const u8) void {
        for (self.tokens.items) |*token| {
            if (std.mem.eql(u8, token.value, token_value)) {
                token.failures += 1;
                break;
            }
        }
    }

    /// Total remaining quota across all tokens.
    pub fn totalRemaining(self: *TokenPool) u32 {
        var total: u32 = 0;
        for (self.tokens.items) |token| {
            if (token.failures < 3) {
                total += token.remaining;
            }
        }
        return total;
    }

    /// Serialize pool state for persistence.
    pub fn serialize(self: *TokenPool, allocator: std.mem.Allocator) ![]const u8 {
        var list: std.ArrayList(u8) = .empty;
        errdefer list.deinit(allocator);

        try list.appendSlice(allocator, "[\n");
        for (self.tokens.items, 0..) |token, i| {
            try list.print(allocator, "  {{\"value\":\"{s}\",\"remaining\":{d},\"failures\":{d}}}", .{
                token.value,
                token.remaining,
                token.failures,
            });
            if (i + 1 < self.tokens.items.len) {
                try list.appendSlice(allocator, ",\n");
            } else {
                try list.appendSlice(allocator, "\n");
            }
        }
        try list.appendSlice(allocator, "]");
        return try list.toOwnedSlice(allocator);
    }
};

fn nowSeconds() i64 {
    var tv: std.c.timeval = undefined;
    _ = std.c.gettimeofday(&tv, null);
    return @intCast(tv.sec);
}

// ------------------------------------------------------------------
// Tests
// ------------------------------------------------------------------

test "TokenPool add and next" {
    const allocator = std.testing.allocator;
    var pool = TokenPool.init(allocator);
    defer pool.deinit();

    try pool.add("ghp_test_token_1");
    try pool.add("ghp_test_token_2");

    try std.testing.expectEqual(@as(usize, 2), pool.tokens.items.len);

    const token = pool.next().?;
    try std.testing.expectEqualStrings("ghp_test_token_1", token.value);
}

test "TokenPool marks failed" {
    const allocator = std.testing.allocator;
    var pool = TokenPool.init(allocator);
    defer pool.deinit();

    try pool.add("ghp_test_token_1");
    pool.markFailed("ghp_test_token_1");

    try std.testing.expectEqual(@as(u32, 1), pool.tokens.items[0].failures);
}

test "TokenPool totalRemaining" {
    const allocator = std.testing.allocator;
    var pool = TokenPool.init(allocator);
    defer pool.deinit();

    try pool.add("ghp_test_token_1");
    try pool.add("ghp_test_token_2");
    pool.tokens.items[0].remaining = 100;
    pool.tokens.items[1].remaining = 200;

    try std.testing.expectEqual(@as(u32, 300), pool.totalRemaining());
}

test "TokenPool serialize" {
    const allocator = std.testing.allocator;
    var pool = TokenPool.init(allocator);
    defer pool.deinit();

    try pool.add("ghp_test");
    pool.tokens.items[0].remaining = 4000;
    pool.tokens.items[0].failures = 1;

    const json = try pool.serialize(allocator);
    defer allocator.free(json);

    try std.testing.expect(std.mem.indexOf(u8, json, "ghp_test") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "4000") != null);
}
