const std = @import("std");

/// shieldcn-zig — db/memo.zig
/// Memo badge storage: key-value persistence for static/dynamic badges.
/// Phase 7: SQLite-backed with optional SQLCipher encryption.
///
/// Schema:
///   CREATE TABLE IF NOT EXISTS memo_badges (
///     key TEXT PRIMARY KEY,         -- e.g. "npm/react"
///     label TEXT NOT NULL,
///     value TEXT NOT NULL,
///     color TEXT,
///     link TEXT,
///     created_at INTEGER NOT NULL,  -- unix seconds
///     expires_at INTEGER            -- null = never
///   );
///
/// For now: in-memory HashMap fallback. SQLite C bindings added
/// when dependency management is wired.
pub const MemoEntry = struct {
    key: []const u8,
    label: []const u8,
    value: []const u8,
    color: ?[]const u8,
    link: ?[]const u8,
    created_at: i64,
    expires_at: ?i64,
};

pub const MemoStore = struct {
    allocator: std.mem.Allocator,
    entries: std.StringHashMap(MemoEntry),

    pub fn init(allocator: std.mem.Allocator) MemoStore {
        return .{
            .allocator = allocator,
            .entries = std.StringHashMap(MemoEntry).init(allocator),
        };
    }

    pub fn deinit(self: *MemoStore) void {
        // Collect all entries first, then clear HashMap, then free
        var to_free = std.ArrayList(MemoEntry).empty;
        defer to_free.deinit(self.allocator);
        var it = self.entries.valueIterator();
        while (it.next()) |entry| {
            to_free.append(self.allocator, entry.*) catch {};
        }
        self.entries.clearRetainingCapacity();
        for (to_free.items) |entry| {
            self.allocator.free(entry.key);
            self.allocator.free(entry.label);
            self.allocator.free(entry.value);
            if (entry.color) |c| self.allocator.free(c);
            if (entry.link) |l| self.allocator.free(l);
        }
        self.entries.deinit();
    }

    /// Insert or replace a memo badge.
    pub fn set(
        self: *MemoStore,
        key: []const u8,
        label: []const u8,
        value: []const u8,
        color: ?[]const u8,
        link: ?[]const u8,
        ttl_seconds: ?u32,
    ) !void {
        // Remove existing entry from HashMap first, then free old strings
        if (self.entries.get(key)) |old| {
            _ = self.entries.remove(key);
            self.allocator.free(old.key);
            self.allocator.free(old.label);
            self.allocator.free(old.value);
            if (old.color) |c| self.allocator.free(c);
            if (old.link) |l| self.allocator.free(l);
        }

        const now = nowSeconds();
        const expires = if (ttl_seconds) |ttl| now + ttl else null;

        const owned_key = try self.allocator.dupe(u8, key);
        errdefer self.allocator.free(owned_key);
        const owned_label = try self.allocator.dupe(u8, label);
        errdefer self.allocator.free(owned_label);
        const owned_value = try self.allocator.dupe(u8, value);
        errdefer self.allocator.free(owned_value);
        const owned_color = if (color) |c| try self.allocator.dupe(u8, c) else null;
        errdefer if (owned_color) |c| self.allocator.free(c);
        const owned_link = if (link) |l| try self.allocator.dupe(u8, l) else null;
        errdefer if (owned_link) |l| self.allocator.free(l);

        try self.entries.put(owned_key, .{
            .key = owned_key,
            .label = owned_label,
            .value = owned_value,
            .color = owned_color,
            .link = owned_link,
            .created_at = now,
            .expires_at = expires,
        });
    }

    /// Get a memo badge. Returns null if not found or expired.
    pub fn get(self: *MemoStore, key: []const u8) ?MemoEntry {
        const entry = self.entries.get(key) orelse return null;

        if (entry.expires_at) |exp| {
            if (nowSeconds() >= exp) {
                // Expired: remove from HashMap first, then free
                _ = self.entries.remove(key);
                self.allocator.free(entry.key);
                self.allocator.free(entry.label);
                self.allocator.free(entry.value);
                if (entry.color) |c| self.allocator.free(c);
                if (entry.link) |l| self.allocator.free(l);
                return null;
            }
        }

        return entry;
    }

    /// Delete a memo badge by key.
    pub fn delete(self: *MemoStore, key: []const u8) void {
        const entry = self.entries.get(key) orelse return;
        _ = self.entries.remove(key);
        self.allocator.free(entry.key);
        self.allocator.free(entry.label);
        self.allocator.free(entry.value);
        if (entry.color) |c| self.allocator.free(c);
        if (entry.link) |l| self.allocator.free(l);
    }

    /// Prune all expired entries.
    pub fn prune(self: *MemoStore) void {
        const now = nowSeconds();
        var keys_to_remove: std.ArrayList([]const u8) = .empty;
        defer keys_to_remove.deinit(self.allocator);

        var it = self.entries.iterator();
        while (it.next()) |kv| {
            if (kv.value_ptr.expires_at) |exp| {
                if (now > exp) {
                    const k = self.allocator.dupe(u8, kv.key_ptr.*) catch continue;
                    keys_to_remove.append(self.allocator, k) catch continue;
                }
            }
        }

        for (keys_to_remove.items) |key| {
            self.delete(key);
            self.allocator.free(key);
        }
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

test "MemoStore set and get" {
    const allocator = std.testing.allocator;
    var store = MemoStore.init(allocator);
    defer store.deinit();

    try store.set("npm/react", "npm", "v18.2.0", "22c55e", null, null);

    const entry = store.get("npm/react").?;
    try std.testing.expectEqualStrings("npm", entry.label);
    try std.testing.expectEqualStrings("v18.2.0", entry.value);
}

test "MemoStore expiration" {
    const allocator = std.testing.allocator;
    var store = MemoStore.init(allocator);
    defer store.deinit();

    // Set with TTL of 0 (immediately expired)
    try store.set("test/expired", "test", "expired", null, null, 0);

    const entry = store.get("test/expired");
    try std.testing.expectEqual(null, entry);
}

test "MemoStore delete" {
    const allocator = std.testing.allocator;
    var store = MemoStore.init(allocator);
    defer store.deinit();

    try store.set("npm/react", "npm", "v18.2.0", null, null, null);
    store.delete("npm/react");

    try std.testing.expectEqual(null, store.get("npm/react"));
}
