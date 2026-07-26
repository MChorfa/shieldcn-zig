const std = @import("std");
const types = @import("../core/types.zig");
const router = @import("router.zig");
const memo = @import("../db/memo.zig");
const token_pool = @import("../db/token_pool.zig");
const static_provider = @import("../providers/static.zig");
const npm = @import("../providers/npm.zig");
const github = @import("../providers/github.zig");
const gitlab = @import("../providers/gitlab.zig");

/// shieldcn-zig — server/providers.zig
/// Provider dispatch registry. Keeps the HTTP handler focused on I/O and
/// lets each provider own its own path/metric parsing.
pub const Context = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    memo_store: *memo.MemoStore,
    token_pool: *token_pool.TokenPool,
};

pub const ResolveError = error{OutOfMemory};

/// Resolve a parsed badge route to a BadgeData. The returned BadgeData may own
/// allocated strings; callers must call badge.deinit() when done.
pub fn resolveBadge(ctx: Context, route: router.Route) ResolveError!?types.BadgeData {
    if (std.mem.eql(u8, route.provider, "badge")) {
        return static_provider.parseStaticBadge(ctx.allocator, route.segments) catch .{
            .label = "badge",
            .value = "invalid",
        };
    }

    if (std.mem.eql(u8, route.provider, "memo")) {
        const key = if (route.segments.len > 1) route.segments[1] else "default";
        const entry = ctx.memo_store.get(key) orelse return .{
            .label = "memo",
            .value = "not found",
        };
        return types.BadgeData{
            .label = try ctx.allocator.dupe(u8, entry.label),
            .value = try ctx.allocator.dupe(u8, entry.value),
            .color = if (entry.color) |c| try ctx.allocator.dupe(u8, c) else null,
            .link = if (entry.link) |l| try ctx.allocator.dupe(u8, l) else null,
            .allocator = ctx.allocator,
            .owned_label = true,
            .owned_value = true,
            .owned_color = entry.color != null,
            .owned_link = entry.link != null,
        };
    }

    if (std.mem.eql(u8, route.provider, "npm")) {
        if (route.segments.len < 2) return .{ .label = "npm", .value = "invalid path" };
        const metric = if (route.segments.len >= 3) route.segments[1] else "version";
        const pkg = route.segments[route.segments.len - 1];

        if (std.mem.eql(u8, metric, "version")) {
            return npm.getNpmVersion(ctx.allocator, pkg, route.query.tag, ctx.io) catch null;
        } else if (std.mem.eql(u8, metric, "downloads")) {
            const period = route.query.period orelse "last-month";
            return npm.getNpmDownloads(ctx.allocator, pkg, period, ctx.io) catch null;
        } else if (std.mem.eql(u8, metric, "license")) {
            return npm.getNpmLicense(ctx.allocator, pkg, ctx.io) catch null;
        }
        return .{ .label = "npm", .value = metric };
    }

    if (std.mem.eql(u8, route.provider, "github")) {
        if (route.segments.len < 4) return .{ .label = "github", .value = "invalid path" };
        const metric = route.segments[1];
        const owner = route.segments[2];
        const repo = route.segments[3];
        const token = if (ctx.token_pool.next()) |t| t.value else null;

        var result: ?types.BadgeData = null;
        if (std.mem.eql(u8, metric, "stars")) {
            result = github.getGitHubStars(ctx.allocator, owner, repo, token, ctx.io) catch null;
        } else if (std.mem.eql(u8, metric, "forks")) {
            result = github.getGitHubForks(ctx.allocator, owner, repo, token, ctx.io) catch null;
        } else if (std.mem.eql(u8, metric, "issues")) {
            result = github.getGitHubIssues(ctx.allocator, owner, repo, token, ctx.io) catch null;
        } else if (std.mem.eql(u8, metric, "pulls")) {
            result = github.getGitHubPulls(ctx.allocator, owner, repo, token, ctx.io) catch null;
        } else if (std.mem.eql(u8, metric, "release")) {
            result = github.getGitHubRelease(ctx.allocator, owner, repo, token, ctx.io) catch null;
        } else if (std.mem.eql(u8, metric, "commits")) {
            result = github.getGitHubCommits(ctx.allocator, owner, repo, token, ctx.io) catch null;
        } else if (std.mem.eql(u8, metric, "contributors")) {
            result = github.getGitHubContributors(ctx.allocator, owner, repo, token, ctx.io) catch null;
        }
        return result orelse .{ .label = "github", .value = metric };
    }

    if (std.mem.eql(u8, route.provider, "gitlab")) {
        if (route.segments.len < 4) return .{ .label = "gitlab", .value = "invalid path" };
        const metric = route.segments[1];
        const owner = route.segments[2];
        const repo = route.segments[3];
        const token = if (ctx.token_pool.next()) |t| t.value else null;

        var result: ?types.BadgeData = null;
        if (std.mem.eql(u8, metric, "stars")) {
            result = gitlab.getGitLabStars(ctx.allocator, owner, repo, token, ctx.io) catch null;
        } else if (std.mem.eql(u8, metric, "forks")) {
            result = gitlab.getGitLabForks(ctx.allocator, owner, repo, token, ctx.io) catch null;
        } else if (std.mem.eql(u8, metric, "issues")) {
            result = gitlab.getGitLabIssues(ctx.allocator, owner, repo, token, ctx.io) catch null;
        } else if (std.mem.eql(u8, metric, "merge-requests")) {
            result = gitlab.getGitLabMergeRequests(ctx.allocator, owner, repo, token, ctx.io) catch null;
        } else if (std.mem.eql(u8, metric, "pipeline")) {
            const branch = if (route.segments.len > 4) route.segments[4] else "main";
            result = gitlab.getGitLabPipeline(ctx.allocator, owner, repo, branch, token, ctx.io) catch null;
        }
        return result orelse .{ .label = "gitlab", .value = metric };
    }

    return .{ .label = route.provider, .value = "n/a" };
}
