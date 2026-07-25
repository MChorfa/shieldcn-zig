const std = @import("std");

/// shieldcn-zig — cache/lru.zig
/// In-memory LRU cache for provider responses (Tier 1).
pub const CacheEntry = struct {
    data: []const u8,
    timestamp: i64,
};

fn nowMillis() i64 {
    var tv: std.c.timeval = undefined;
    _ = std.c.gettimeofday(&tv, null);
    return @as(i64, tv.sec) * 1000 + @divTrunc(@as(i64, tv.usec), 1000);
}

pub const LruCache = struct {
    allocator: std.mem.Allocator,
    map: std.StringHashMap(CacheEntry),
    max_entries: usize,
    ttl_ms: i64,

    pub fn init(allocator: std.mem.Allocator, max_entries: usize, ttl_ms: i64) LruCache {
        return .{
            .allocator = allocator,
            .map = std.StringHashMap(CacheEntry).init(allocator),
            .max_entries = max_entries,
            .ttl_ms = ttl_ms,
        };
    }

    pub fn deinit(self: *LruCache) void {
        var it = self.map.iterator();
        while (it.next()) |entry| {
            self.allocator.free(entry.key_ptr.*);
            self.allocator.free(entry.value_ptr.data);
        }
        self.map.deinit();
    }

    pub fn get(self: *LruCache, key: []const u8) ?[]const u8 {
        const entry = self.map.getPtr(key) orelse return null;
        if (nowMillis() - entry.timestamp > self.ttl_ms) {
            _ = self.map.remove(key);
            return null;
        }
        return entry.data;
    }

    pub fn put(self: *LruCache, key: []const u8, data: []const u8) !void {
        // Evict oldest if at capacity
        while (self.map.count() >= self.max_entries) {
            var it = self.map.iterator();
            if (it.next()) |entry| {
                self.allocator.free(entry.key_ptr.*);
                self.allocator.free(entry.value_ptr.data);
                _ = self.map.remove(entry.key_ptr.*);
            }
        }

        const owned_key = try self.allocator.dupe(u8, key);
        const owned_data = try self.allocator.dupe(u8, data);
        errdefer {
            self.allocator.free(owned_key);
            self.allocator.free(owned_data);
        }

        const gop = try self.map.getOrPut(owned_key);
        if (gop.found_existing) {
            self.allocator.free(gop.key_ptr.*);
            self.allocator.free(gop.value_ptr.data);
        }
        gop.key_ptr.* = owned_key;
        gop.value_ptr.* = .{ .data = owned_data, .timestamp = nowMillis() };
    }
};

// ------------------------------------------------------------------
// Tests
// ------------------------------------------------------------------

test "LRU put and get" {
    var cache = LruCache.init(std.testing.allocator, 10, 60_000);
    defer cache.deinit();

    try cache.put("npm:react", "v18.0.0");
    const val = cache.get("npm:react").?;
    try std.testing.expectEqualStrings("v18.0.0", val);
}

test "LRU miss" {
    var cache = LruCache.init(std.testing.allocator, 10, 60_000);
    defer cache.deinit();

    try std.testing.expectEqual(null, cache.get("missing"));
}
