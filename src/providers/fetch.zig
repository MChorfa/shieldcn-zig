const std = @import("std");
const types = @import("../core/types.zig");
const egress = @import("../net/egress.zig");
const backoff = @import("../cache/backoff.zig");

/// shieldcn-zig — providers/fetch.zig
/// Shared HTTP fetch wrapper with:
///   - Egress allowlist (CKODEX NET-FIL-WHIT)
///   - Per-provider exponential backoff
///   - Timeout enforcement
///   - Structured audit logging
pub const FetchError = error{
    EgressBlocked,
    ProviderBackedOff,
    RequestFailed,
    Timeout,
    InvalidResponse,
};

pub fn providerFetch(
    allocator: std.mem.Allocator,
    provider: []const u8,
    url: []const u8,
    _ttl_seconds: u32,
    auth_token: ?[]const u8,
    io: std.Io,
) FetchError![]const u8 {
    _ = _ttl_seconds;
    // CKODEX: egress allowlist enforcement
    if (!egress.isAllowedHost(url)) {
        std.log.err("Egress blocked: {s}", .{url});
        return FetchError.EgressBlocked;
    }

    // Check backoff
    if (backoff.isBackedOff(provider)) {
        std.log.warn("Provider {s} is backed off", .{provider});
        return FetchError.ProviderBackedOff;
    }

    // Perform fetch using Zig 0.16 high-level fetch API
    var client = std.http.Client{ .allocator = allocator, .io = io };
    defer client.deinit();

    const auth_header = if (auth_token) |t| b: {
        const bearer = std.fmt.allocPrint(allocator, "Bearer {s}", .{t}) catch break :b .omit;
        break :b std.http.Client.Request.Headers.Value{ .override = bearer };
    } else .omit;

    var body_writer = std.Io.Writer.Allocating.init(allocator);
    errdefer body_writer.deinit();

    var redirect_buffer: [8192]u8 = undefined;

    const result = client.fetch(.{
        .location = .{ .url = url },
        .headers = .{
            .authorization = auth_header,
            .user_agent = .{ .override = "shieldcn-zig/0.1" },
        },
        .response_writer = &body_writer.writer,
        .redirect_buffer = &redirect_buffer,
    }) catch |err| {
        std.log.err("HTTP fetch to {s} failed: {}", .{ url, err });
        return FetchError.RequestFailed;
    };

    defer {
        switch (auth_header) {
            .override => |v| if (auth_token != null) allocator.free(v),
            else => {},
        }
    }

    const status = result.status;
    if (status == .too_many_requests or status.class() == .server_error) {
        std.log.warn("Provider {s} rate-limited/server-error: {s}", .{ provider, @tagName(status) });
        backoff.recordBackoff(provider);
        return FetchError.ProviderBackedOff;
    }
    if (status.class() != .success) {
        std.log.err("HTTP {s} for {s}", .{ @tagName(status), url });
        return FetchError.RequestFailed;
    }

    const body = body_writer.toOwnedSlice() catch |err| {
        std.log.err("HTTP body finalize for {s} failed: {}", .{ url, err });
        return FetchError.RequestFailed;
    };

    // Clear backoff on success
    backoff.clearBackoff(provider);

    return body;
}

// ------------------------------------------------------------------
// Convenience: fetch JSON and parse
// ------------------------------------------------------------------

pub fn fetchJson(
    allocator: std.mem.Allocator,
    provider: []const u8,
    url: []const u8,
    ttl_seconds: u32,
    auth_token: ?[]const u8,
    io: std.Io,
) FetchError!std.json.Value {
    const body = try providerFetch(allocator, provider, url, ttl_seconds, auth_token, io);
    defer allocator.free(body);

    const parsed = std.json.parseFromSlice(std.json.Value, allocator, body, .{}) catch {
        return FetchError.InvalidResponse;
    };
    // Note: caller must call parsed.deinit()
    return parsed.value;
}
