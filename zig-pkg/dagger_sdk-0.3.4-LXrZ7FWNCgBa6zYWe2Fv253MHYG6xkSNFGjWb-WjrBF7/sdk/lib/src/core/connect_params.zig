//! Handshake parameters published by `dagger session` to stdout as a single
//! JSON line, or set in the environment when running inside a module runtime.

const std = @import("std");

pub const ConnectParams = struct {
    port: u16,
    session_token: []const u8, // owned by caller

    pub fn deinit(self: *ConnectParams, allocator: std.mem.Allocator) void {
        allocator.free(self.session_token);
    }

    /// Build the `http://127.0.0.1:{port}/query` endpoint URL.
    /// Caller owns the returned slice.
    pub fn url(self: ConnectParams, allocator: std.mem.Allocator) ![]u8 {
        return std.fmt.allocPrint(allocator, "http://127.0.0.1:{d}/query", .{self.port});
    }

    /// Parse a single JSON line of the form:
    ///   `{"port":12345,"session_token":"..."}`
    pub fn parseJsonLine(allocator: std.mem.Allocator, line: []const u8) !ConnectParams {
        const Raw = struct {
            port: u16,
            session_token: []const u8,
        };
        const parsed = try std.json.parseFromSlice(Raw, allocator, line, .{
            .ignore_unknown_fields = true,
        });
        defer parsed.deinit();
        return .{
            .port = parsed.value.port,
            .session_token = try allocator.dupe(u8, parsed.value.session_token),
        };
    }
};

test "parse connect params json" {
    const line =
        \\{"port":44273,"session_token":"aaaa-bbbb","extra":"ignored"}
    ;
    var p = try ConnectParams.parseJsonLine(std.testing.allocator, line);
    defer p.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(u16, 44273), p.port);
    try std.testing.expectEqualStrings("aaaa-bbbb", p.session_token);
}

test "url formatting" {
    const p: ConnectParams = .{ .port = 8080, .session_token = "x" };
    const u = try p.url(std.testing.allocator);
    defer std.testing.allocator.free(u);
    try std.testing.expectEqualStrings("http://127.0.0.1:8080/query", u);
}
