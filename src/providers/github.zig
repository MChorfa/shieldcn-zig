const std = @import("std");
const types = @import("../core/types.zig");
const fetch = @import("fetch.zig");
const fmt = @import("../util/format.zig");

/// shieldcn-zig — providers/github.zig
/// GitHub API client: stars, forks, issues, pulls, release, commits, contributors.
///
/// URL patterns:
///   /github/stars/{owner}/{repo}.svg
///   /github/forks/{owner}/{repo}.svg
///   /github/issues/{owner}/{repo}.svg
///   /github/pulls/{owner}/{repo}.svg
///   /github/release/{owner}/{repo}.svg
///   /github/commits/{owner}/{repo}.svg
///   /github/contributors/{owner}/{repo}.svg
pub fn getGitHubStars(
    allocator: std.mem.Allocator,
    owner: []const u8,
    repo: []const u8,
    token: ?[]const u8,
    io: std.Io,
) !?types.BadgeData {
    const url = try std.fmt.allocPrint(
        allocator,
        "https://api.github.com/repos/{s}/{s}",
        .{ owner, repo },
    );
    defer allocator.free(url);

    const body = try fetch.providerFetch(allocator, "github", url, 3600, token, io);
    defer allocator.free(body);

    const parsed = try std.json.parseFromSlice(std.json.Value, allocator, body, .{});
    defer parsed.deinit();

    const stars = parsed.value.object.get("stargazers_count") orelse return null;
    if (stars != .integer) return null;

    const link = try std.fmt.allocPrint(allocator, "https://github.com/{s}/{s}/stargazers", .{ owner, repo });

    var buf: [64]u8 = undefined;
    const formatted = fmt.formatCount(@intCast(stars.integer), &buf);

    return types.BadgeData{
        .label = "stars",
        .value = try allocator.dupe(u8, formatted),
        .link = link,
        .allocator = allocator,
        .owned_value = true,
        .owned_link = true,
    };
}

pub fn getGitHubForks(
    allocator: std.mem.Allocator,
    owner: []const u8,
    repo: []const u8,
    token: ?[]const u8,
    io: std.Io,
) !?types.BadgeData {
    const url = try std.fmt.allocPrint(
        allocator,
        "https://api.github.com/repos/{s}/{s}",
        .{ owner, repo },
    );
    defer allocator.free(url);

    const body = try fetch.providerFetch(allocator, "github", url, 3600, token, io);
    defer allocator.free(body);

    const parsed = try std.json.parseFromSlice(std.json.Value, allocator, body, .{});
    defer parsed.deinit();

    const forks = parsed.value.object.get("forks_count") orelse return null;
    if (forks != .integer) return null;

    const link = try std.fmt.allocPrint(allocator, "https://github.com/{s}/{s}/network/members", .{ owner, repo });

    var buf: [64]u8 = undefined;
    const formatted = fmt.formatCount(@intCast(forks.integer), &buf);

    return types.BadgeData{
        .label = "forks",
        .value = try allocator.dupe(u8, formatted),
        .link = link,
        .allocator = allocator,
        .owned_value = true,
        .owned_link = true,
    };
}

pub fn getGitHubIssues(
    allocator: std.mem.Allocator,
    owner: []const u8,
    repo: []const u8,
    token: ?[]const u8,
    io: std.Io,
) !?types.BadgeData {
    const url = try std.fmt.allocPrint(
        allocator,
        "https://api.github.com/repos/{s}/{s}",
        .{ owner, repo },
    );
    defer allocator.free(url);

    const body = try fetch.providerFetch(allocator, "github", url, 3600, token, io);
    defer allocator.free(body);

    const parsed = try std.json.parseFromSlice(std.json.Value, allocator, body, .{});
    defer parsed.deinit();

    const issues = parsed.value.object.get("open_issues_count") orelse return null;
    if (issues != .integer) return null;

    const link = try std.fmt.allocPrint(allocator, "https://github.com/{s}/{s}/issues", .{ owner, repo });

    var buf: [64]u8 = undefined;
    const formatted = fmt.formatCount(@intCast(issues.integer), &buf);

    return types.BadgeData{
        .label = "issues",
        .value = try allocator.dupe(u8, formatted),
        .link = link,
        .allocator = allocator,
        .owned_value = true,
        .owned_link = true,
    };
}

pub fn getGitHubPulls(
    allocator: std.mem.Allocator,
    owner: []const u8,
    repo: []const u8,
    token: ?[]const u8,
    io: std.Io,
) !?types.BadgeData {
    const url = try std.fmt.allocPrint(
        allocator,
        "https://api.github.com/repos/{s}/{s}",
        .{ owner, repo },
    );
    defer allocator.free(url);

    const body = try fetch.providerFetch(allocator, "github", url, 3600, token, io);
    defer allocator.free(body);

    const parsed = try std.json.parseFromSlice(std.json.Value, allocator, body, .{});
    defer parsed.deinit();

    const pulls = parsed.value.object.get("open_issues") orelse return null;
    if (pulls != .integer) return null;

    const link = try std.fmt.allocPrint(allocator, "https://github.com/{s}/{s}/pulls", .{ owner, repo });

    var buf: [64]u8 = undefined;
    const formatted = fmt.formatCount(@intCast(pulls.integer), &buf);

    return types.BadgeData{
        .label = "pulls",
        .value = try allocator.dupe(u8, formatted),
        .link = link,
        .allocator = allocator,
        .owned_value = true,
        .owned_link = true,
    };
}

pub fn getGitHubRelease(
    allocator: std.mem.Allocator,
    owner: []const u8,
    repo: []const u8,
    token: ?[]const u8,
    io: std.Io,
) !?types.BadgeData {
    const url = try std.fmt.allocPrint(
        allocator,
        "https://api.github.com/repos/{s}/{s}/releases/latest",
        .{ owner, repo },
    );
    defer allocator.free(url);

    const body = try fetch.providerFetch(allocator, "github", url, 3600, token, io);
    defer allocator.free(body);

    const parsed = try std.json.parseFromSlice(std.json.Value, allocator, body, .{});
    defer parsed.deinit();

    const tag_name = parsed.value.object.get("tag_name") orelse return null;
    if (tag_name != .string) return null;

    const html_url = parsed.value.object.get("html_url") orelse return null;
    if (html_url != .string) return null;

    return types.BadgeData{
        .label = "release",
        .value = try allocator.dupe(u8, tag_name.string),
        .link = try allocator.dupe(u8, html_url.string),
        .allocator = allocator,
        .owned_value = true,
        .owned_link = true,
    };
}

pub fn getGitHubCommits(
    allocator: std.mem.Allocator,
    owner: []const u8,
    repo: []const u8,
    token: ?[]const u8,
    io: std.Io,
) !?types.BadgeData {
    const url = try std.fmt.allocPrint(
        allocator,
        "https://api.github.com/repos/{s}/{s}",
        .{ owner, repo },
    );
    defer allocator.free(url);

    const body = try fetch.providerFetch(allocator, "github", url, 3600, token, io);
    defer allocator.free(body);

    const parsed = try std.json.parseFromSlice(std.json.Value, allocator, body, .{});
    defer parsed.deinit();

    const commits = parsed.value.object.get("pushed_at") orelse return null;
    if (commits != .string) return null;

    // Parse the date and show relative time or just the date
    const date = commits.string;

    const link = try std.fmt.allocPrint(allocator, "https://github.com/{s}/{s}/commits", .{ owner, repo });

    return types.BadgeData{
        .label = "commits",
        .value = try allocator.dupe(u8, date),
        .link = link,
        .allocator = allocator,
        .owned_value = true,
        .owned_link = true,
    };
}

pub fn getGitHubContributors(
    allocator: std.mem.Allocator,
    owner: []const u8,
    repo: []const u8,
    token: ?[]const u8,
    io: std.Io,
) !?types.BadgeData {
    const url = try std.fmt.allocPrint(
        allocator,
        "https://api.github.com/repos/{s}/{s}/contributors?per_page=1",
        .{ owner, repo },
    );
    defer allocator.free(url);

    const body = try fetch.providerFetch(allocator, "github", url, 3600, token, io);
    defer allocator.free(body);

    const parsed = try std.json.parseFromSlice(std.json.Value, allocator, body, .{});
    defer parsed.deinit();

    if (parsed.value != .array) return null;

    const count = parsed.value.array.items.len;

    const link = try std.fmt.allocPrint(allocator, "https://github.com/{s}/{s}/graphs/contributors", .{ owner, repo });

    var buf: [64]u8 = undefined;
    const formatted = fmt.formatCount(@intCast(count), &buf);

    return types.BadgeData{
        .label = "contributors",
        .value = try allocator.dupe(u8, formatted),
        .link = link,
        .allocator = allocator,
        .owned_value = true,
        .owned_link = true,
    };
}
