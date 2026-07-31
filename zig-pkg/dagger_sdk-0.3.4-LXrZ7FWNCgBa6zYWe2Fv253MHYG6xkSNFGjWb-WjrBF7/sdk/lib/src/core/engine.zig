//! Engine bring-up orchestrator.
//!
//! Tries three strategies in order:
//!   1. In-module / in-session runtime: `DAGGER_SESSION_PORT` +
//!      `DAGGER_SESSION_TOKEN` are set by the engine when the SDK is running
//!      inside a module or under `dagger run`.
//!   2. Dev override: `_EXPERIMENTAL_DAGGER_CLI_BIN` points at a local CLI.
//!   3. Installed CLI: whatever `dagger` resolves to on PATH.
//!
//! v0.1 does NOT download the CLI. Users in MChorfa/CortAIx environments
//! pre-install it via the base runner image — download-on-first-run is
//! an anti-pattern there and adds a TLS + signature-verification surface
//! we don't need.

const std = @import("std");
const errs = @import("../errors.zig");
const ConnectParams = @import("connect_params.zig").ConnectParams;
const Config = @import("config.zig").Config;
const cli_session = @import("cli_session.zig");
const SessionProc = cli_session.SessionProc;

pub const StartResult = struct {
    params: ConnectParams,
    /// Null when we're running inside an existing session (env-var mode).
    /// Non-null when we spawned a subprocess — caller must shut it down.
    session: ?SessionProc,
};

pub fn start(
    allocator: std.mem.Allocator,
    io: std.Io,
    cfg: Config,
) errs.ConnectError!StartResult {
    // Strategy 1: already inside a session.
    if (fromSessionEnv(allocator)) |p| {
        return .{ .params = p, .session = null };
    } else |_| {}

    // Strategy 2: dev override.
    if (std.c.getenv("_EXPERIMENTAL_DAGGER_CLI_BIN")) |bin_ptr| {
        const bin = std.mem.sliceTo(bin_ptr, 0);
        const bin_copy = try allocator.dupe(u8, bin);
        defer allocator.free(bin_copy);
        const r = try cli_session.connect(allocator, io, cfg, bin_copy);
        return .{ .params = r.params, .session = r.session };
    }

    // Strategy 3: CLI on PATH.
    const r = try cli_session.connect(allocator, io, cfg, "dagger");
    return .{ .params = r.params, .session = r.session };
}

fn fromSessionEnv(allocator: std.mem.Allocator) errs.ConnectError!ConnectParams {
    const port_str_ptr = std.c.getenv("DAGGER_SESSION_PORT") orelse {
        return error.InvalidEnv;
    };
    const port_str = std.mem.sliceTo(port_str_ptr, 0);
    const port_copy = try allocator.dupe(u8, port_str);
    defer allocator.free(port_copy);

    const token_ptr = std.c.getenv("DAGGER_SESSION_TOKEN") orelse {
        return error.InvalidEnv;
    };
    const token = std.mem.sliceTo(token_ptr, 0);
    const token_copy = try allocator.dupe(u8, token);
    errdefer allocator.free(token_copy);

    const port = std.fmt.parseInt(u16, port_copy, 10) catch return error.InvalidEnv;

    return .{ .port = port, .session_token = token_copy };
}
