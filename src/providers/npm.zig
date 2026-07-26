const std = @import("std");
const types = @import("../core/types.zig");
const fetch = @import("fetch.zig");
const fmt = @import("../util/format.zig");

/// shieldcn-zig — providers/npm.zig
/// npm registry API client: version, downloads, license.
pub fn getNpmVersion(allocator: std.mem.Allocator, pkg: []const u8, tag: ?[]const u8, io: std.Io) !?types.BadgeData {
    const dist = tag orelse "latest";
    const encoded = try percentEncodeComponent(allocator, pkg);
    defer allocator.free(encoded);

    const url = try std.fmt.allocPrint(allocator, "https://registry.npmjs.org/{s}/{s}", .{ encoded, dist });
    defer allocator.free(url);

    const body = try fetch.providerFetch(allocator, "npm", url, 3600, null, io);
    defer allocator.free(body);

    const parsed = std.json.parseFromSlice(std.json.Value, allocator, body, .{}) catch |err| {
        std.log.err("npm version JSON parse failed for {s}: {}", .{ pkg, err });
        return null;
    };
    defer parsed.deinit();

    const version = parsed.value.object.get("version") orelse {
        std.log.err("npm version response for {s} missing version field", .{pkg});
        return null;
    };
    if (version != .string) {
        std.log.err("npm version field for {s} is not a string", .{pkg});
        return null;
    }

    const link = try std.fmt.allocPrint(allocator, "https://www.npmjs.com/package/{s}", .{pkg});

    return types.BadgeData{
        .label = "npm",
        .value = try std.fmt.allocPrint(allocator, "v{s}", .{version.string}),
        .link = link,
    };
}

pub fn getNpmDownloads(allocator: std.mem.Allocator, pkg: []const u8, period: []const u8, io: std.Io) !?types.BadgeData {
    const encoded = try percentEncodeComponent(allocator, pkg);
    defer allocator.free(encoded);

    const url = try std.fmt.allocPrint(allocator, "https://api.npmjs.org/downloads/point/{s}/{s}", .{ period, encoded });
    defer allocator.free(url);

    const body = try fetch.providerFetch(allocator, "npm", url, 3600, null, io);
    defer allocator.free(body);

    const parsed = try std.json.parseFromSlice(std.json.Value, allocator, body, .{});
    defer parsed.deinit();

    const downloads = parsed.value.object.get("downloads") orelse return null;
    if (downloads != .integer) return null;

    const count = @as(u64, @intCast(downloads.integer));
    var buf: [64]u8 = undefined;
    const formatted = fmt.formatCount(count, &buf);

    const suffix = if (std.mem.eql(u8, period, "last-week")) "/week" else if (std.mem.eql(u8, period, "last-month")) "/month" else if (std.mem.eql(u8, period, "last-year")) "/year" else "";

    const link = try std.fmt.allocPrint(allocator, "https://www.npmjs.com/package/{s}", .{pkg});

    return types.BadgeData{
        .label = "downloads",
        .value = try std.fmt.allocPrint(allocator, "{s}{s}", .{ formatted, suffix }),
        .link = link,
    };
}

pub fn getNpmLicense(allocator: std.mem.Allocator, pkg: []const u8, io: std.Io) !?types.BadgeData {
    const encoded = try percentEncodeComponent(allocator, pkg);
    defer allocator.free(encoded);

    const url = try std.fmt.allocPrint(allocator, "https://registry.npmjs.org/{s}/latest", .{encoded});
    defer allocator.free(url);

    const body = try fetch.providerFetch(allocator, "npm", url, 3600, null, io);
    defer allocator.free(body);

    const parsed = try std.json.parseFromSlice(std.json.Value, allocator, body, .{});
    defer parsed.deinit();

    const license = parsed.value.object.get("license") orelse return null;
    const license_str = switch (license) {
        .string => license.string,
        .object => license.object.get("type").?.string,
        else => return null,
    };

    const link = try std.fmt.allocPrint(allocator, "https://www.npmjs.com/package/{s}", .{pkg});

    return types.BadgeData{
        .label = "license",
        .value = try allocator.dupe(u8, license_str),
        .link = link,
    };
}

const HEX_UPPER = "0123456789ABCDEF";

fn percentEncodeComponent(allocator: std.mem.Allocator, input: []const u8) ![]const u8 {
    var result: std.ArrayList(u8) = .empty;
    errdefer result.deinit(allocator);

    for (input) |c| {
        if (std.ascii.isAlphanumeric(c) or c == '-' or c == '_' or c == '.' or c == '~') {
            try result.append(allocator, c);
        } else {
            try result.append(allocator, '%');
            try result.append(allocator, HEX_UPPER[c >> 4]);
            try result.append(allocator, HEX_UPPER[c & 0x0F]);
        }
    }

    return try result.toOwnedSlice(allocator);
}
