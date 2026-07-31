//! Runtime configuration for a Dagger session. All fields are optional with
//! sensible defaults; callers should use the builder-style helpers to set
//! only what they need.
//!
//! Note on Io: the `Logger` interface is deliberately NOT Io-typed. Loggers
//! consume pre-formed strings — the blocking/nondeterministic part (reading
//! from pipes, stdout flushing) happens inside the `Io` the SDK already uses
//! elsewhere. A logger implementation that wants to do its own async I/O can
//! capture an Io in its `ctx` pointer.

const std = @import("std");
const resilience = @import("resilience.zig");
const cache_safe = @import("cache_safe.zig");
const secrets = @import("secrets.zig");

pub const Config = struct {
    /// Working directory for the CLI (mapped to `--workdir`).
    /// If null, the CLI uses the current process cwd.
    workdir_path: ?[]const u8 = null,

    /// Path to a dagger project config. Mapped to `--project`.
    config_path: ?[]const u8 = null,

    /// Load additional workspace modules. Mapped to `--load-workspace-modules`.
    load_workspace_modules: bool = false,

    /// HTTP connect timeout, milliseconds. Default 10s.
    connect_timeout_ms: u32 = 10_000,

    /// HTTP request-execute timeout, milliseconds. Null = no timeout.
    execute_timeout_ms: ?u32 = null,

    /// Where to write CLI stdout/stderr lines. If null, messages are dropped.
    logger: ?*const Logger = null,

    /// Engine version string used to pin the CLI download. Set by the SDK
    /// constants module; callers usually don't touch this.
    engine_version: []const u8 = @import("version.zig").engine_version,

    /// Retry policy for GraphQL operations.
    retry_policy: resilience.RetryPolicy = .{},

    /// Enable circuit breaker for GraphQL client.
    enable_circuit_breaker: bool = true,

    /// Cache configuration for fail-safe caching.
    cache_config: cache_safe.CacheConfig = .{},

    /// Secret registry for the session.
    secret_registry: ?*secrets.SecretRegistry = null,

    pub fn default() Config {
        return .{};
    }
};

/// Minimal logger interface for CLI output lines. Implementations are free to
/// forward to any logging framework; we stay out of that business.
pub const Logger = struct {
    ctx: *anyopaque,
    on_stdout: *const fn (ctx: *anyopaque, line: []const u8) void,
    on_stderr: *const fn (ctx: *anyopaque, line: []const u8) void,

    pub fn stdout(self: *const Logger, line: []const u8) void {
        self.on_stdout(self.ctx, line);
    }
    pub fn stderr(self: *const Logger, line: []const u8) void {
        self.on_stderr(self.ctx, line);
    }
};

/// Default stderr-forwarding logger. Safe to use in multi-threaded code —
/// `std.debug.print` holds its own mutex.
pub const StdLogger = struct {
    pub fn logger() Logger {
        return .{
            .ctx = undefined,
            .on_stdout = onOut,
            .on_stderr = onErr,
        };
    }
    fn onOut(_: *anyopaque, line: []const u8) void {
        std.debug.print("dagger: {s}\n", .{line});
    }
    fn onErr(_: *anyopaque, line: []const u8) void {
        std.debug.print("dagger[stderr]: {s}\n", .{line});
    }
};
