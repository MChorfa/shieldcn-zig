const std = @import("std");
const types = @import("../core/types.zig");
const fetch = @import("fetch.zig");
const fmt = @import("../util/format.zig");

/// shieldcn-zig — providers/gitlab.zig
/// GitLab API client: stars, forks, issues, merge requests, pipeline status.
///
/// URL patterns:
///   /gitlab/stars/{owner}/{repo}.svg
///   /gitlab/forks/{owner}/{repo}.svg
///   /gitlab/issues/{owner}/{repo}.svg
///   /gitlab/merge-requests/{owner}/{repo}.svg
///   /gitlab/pipeline/{owner}/{repo}/{branch}.svg
pub fn getGitLabStars(
    allocator: std.mem.Allocator,
    owner: []const u8,
    repo: []const u8,
    token: ?[]const u8,
    io: std.Io,
) !?types.BadgeData {
    const url = try std.fmt.allocPrint(
        allocator,
        "https://gitlab.com/api/v4/projects/{s}%2F{s}",
        .{ owner, repo },
    );
    defer allocator.free(url);

    const body = try fetch.providerFetch(allocator, "gitlab", url, 3600, token, io);
    defer allocator.free(body);

    const parsed = try std.json.parseFromSlice(std.json.Value, allocator, body, .{});
    defer parsed.deinit();

    const stars = parsed.value.object.get("star_count") orelse return null;
    if (stars != .integer) return null;

    const link = try std.fmt.allocPrint(allocator, "https://gitlab.com/{s}/{s}", .{ owner, repo });

    var buf: [64]u8 = undefined;
    const formatted = fmt.formatCount(@intCast(stars.integer), &buf);

    return types.BadgeData{
        .label = "stars",
        .value = try allocator.dupe(u8, formatted),
        .link = link,
    };
}

pub fn getGitLabForks(
    allocator: std.mem.Allocator,
    owner: []const u8,
    repo: []const u8,
    token: ?[]const u8,
    io: std.Io,
) !?types.BadgeData {
    const url = try std.fmt.allocPrint(
        allocator,
        "https://gitlab.com/api/v4/projects/{s}%2F{s}",
        .{ owner, repo },
    );
    defer allocator.free(url);

    const body = try fetch.providerFetch(allocator, "gitlab", url, 3600, token, io);
    defer allocator.free(body);

    const parsed = try std.json.parseFromSlice(std.json.Value, allocator, body, .{});
    defer parsed.deinit();

    const forks = parsed.value.object.get("forks_count") orelse return null;
    if (forks != .integer) return null;

    const link = try std.fmt.allocPrint(allocator, "https://gitlab.com/{s}/{s}", .{ owner, repo });

    var buf: [64]u8 = undefined;
    const formatted = fmt.formatCount(@intCast(forks.integer), &buf);

    return types.BadgeData{
        .label = "forks",
        .value = try allocator.dupe(u8, formatted),
        .link = link,
    };
}

pub fn getGitLabIssues(
    allocator: std.mem.Allocator,
    owner: []const u8,
    repo: []const u8,
    token: ?[]const u8,
    io: std.Io,
) !?types.BadgeData {
    const url = try std.fmt.allocPrint(
        allocator,
        "https://gitlab.com/api/v4/projects/{s}%2F{s}/issues_statistics?state=all",
        .{ owner, repo },
    );
    defer allocator.free(url);

    const body = try fetch.providerFetch(allocator, "gitlab", url, 3600, token, io);
    defer allocator.free(body);

    const parsed = try std.json.parseFromSlice(std.json.Value, allocator, body, .{});
    defer parsed.deinit();

    const stats = parsed.value.object.get("statistics") orelse return null;
    if (stats != .object) return null;
    const counts = stats.object.get("counts") orelse return null;
    if (counts != .object) return null;
    const all = counts.object.get("all") orelse return null;
    if (all != .integer) return null;

    const link = try std.fmt.allocPrint(
        allocator,
        "https://gitlab.com/{s}/{s}/-/issues",
        .{ owner, repo },
    );

    var buf: [64]u8 = undefined;
    const formatted = fmt.formatCount(@intCast(all.integer), &buf);

    return types.BadgeData{
        .label = "issues",
        .value = try allocator.dupe(u8, formatted),
        .link = link,
    };
}

pub fn getGitLabMergeRequests(
    allocator: std.mem.Allocator,
    owner: []const u8,
    repo: []const u8,
    token: ?[]const u8,
    io: std.Io,
) !?types.BadgeData {
    const url = try std.fmt.allocPrint(
        allocator,
        "https://gitlab.com/api/v4/projects/{s}%2F{s}/merge_requests?state=all&per_page=1",
        .{ owner, repo },
    );
    defer allocator.free(url);

    const body = try fetch.providerFetch(allocator, "gitlab", url, 3600, token, io);
    defer allocator.free(body);

    const parsed = try std.json.parseFromSlice(std.json.Value, allocator, body, .{});
    defer parsed.deinit();

    if (parsed.value != .array) return null;
    const x_total = parsed.value.array.items.len;

    const link = try std.fmt.allocPrint(
        allocator,
        "https://gitlab.com/{s}/{s}/-/merge_requests",
        .{ owner, repo },
    );

    var buf: [64]u8 = undefined;
    const formatted = fmt.formatCount(@intCast(x_total), &buf);

    return types.BadgeData{
        .label = "merge requests",
        .value = try allocator.dupe(u8, formatted),
        .link = link,
    };
}

pub fn getGitLabPipeline(
    allocator: std.mem.Allocator,
    owner: []const u8,
    repo: []const u8,
    branch: []const u8,
    token: ?[]const u8,
    io: std.Io,
) !?types.BadgeData {
    const encoded_branch = try percentEncodeComponent(allocator, branch);
    defer allocator.free(encoded_branch);

    const url = try std.fmt.allocPrint(
        allocator,
        "https://gitlab.com/api/v4/projects/{s}%2F{s}/pipelines?ref={s}&per_page=1",
        .{ owner, repo, encoded_branch },
    );
    defer allocator.free(url);

    const body = try fetch.providerFetch(allocator, "gitlab", url, 3600, token, io);
    defer allocator.free(body);

    const parsed = try std.json.parseFromSlice(std.json.Value, allocator, body, .{});
    defer parsed.deinit();

    if (parsed.value != .array or parsed.value.array.items.len == 0) return null;
    const first = parsed.value.array.items[0];
    if (first != .object) return null;
    const status = first.object.get("status") orelse return null;
    if (status != .string) return null;

    const link = try std.fmt.allocPrint(
        allocator,
        "https://gitlab.com/{s}/{s}/-/pipelines",
        .{ owner, repo },
    );

    return types.BadgeData{
        .label = "pipeline",
        .value = try allocator.dupe(u8, status.string),
        .link = link,
        .color = pipelineColor(status.string),
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

fn pipelineColor(status: []const u8) ?[]const u8 {
    if (std.mem.eql(u8, status, "success")) return "22c55e";
    if (std.mem.eql(u8, status, "failed")) return "ef4444";
    if (std.mem.eql(u8, status, "running")) return "3b82f6";
    if (std.mem.eql(u8, status, "pending")) return "f59e0b";
    if (std.mem.eql(u8, status, "canceled")) return "6b7280";
    if (std.mem.eql(u8, status, "skipped")) return "9ca3af";
    return null;
}
