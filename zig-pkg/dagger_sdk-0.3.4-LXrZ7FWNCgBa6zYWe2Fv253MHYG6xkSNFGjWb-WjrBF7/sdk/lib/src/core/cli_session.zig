//! Manages the lifecycle of a `dagger session` subprocess.
//!
//! Targets Zig 0.16:
//!   - `std.process.spawn(io, .{...})` replaces `Child.init` + `.spawn()`.
//!   - Pipe reads go through `std.Io.Reader`, threaded through `io`.
//!   - Stdout/stderr drainage uses `io.async` + `Future.cancel` instead of a
//!     raw `std.Thread` — simpler, cancellable, and works in single-threaded
//!     mode.
//!
//! Protocol:
//!   1. Spawn `dagger session [--workdir X] [--project Y] --label ...`.
//!   2. Read ONE JSON line on stdout: `{"port":N,"session_token":"..."}`.
//!   3. Keep the process alive; drain stdout/stderr into the configured logger
//!      via async tasks that run until shutdown.
//!   4. On shutdown: signal cancellation, wait for the process to exit.

const std = @import("std");
const errs = @import("../errors.zig");
const ConnectParams = @import("connect_params.zig").ConnectParams;
const Config = @import("config.zig").Config;
const config_mod = @import("config.zig");
const version = @import("version.zig");

pub const SessionProc = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    child: std.process.Child,
    /// Futures for the two drain tasks. Cancelled on shutdown.
    stdout_drain: ?std.Io.Future(void) = null,
    stderr_drain: ?std.Io.Future(void) = null,

    pub fn shutdown(self: *SessionProc) errs.ConnectError!void {
        // Cancel drain tasks first so they release pipe handles.
        if (self.stdout_drain) |*f| {
            f.cancel(self.io);
            self.stdout_drain = null;
        }
        if (self.stderr_drain) |*f| {
            f.cancel(self.io);
            self.stderr_drain = null;
        }

        // Close stdin so the CLI sees EOF and exits.
        if (self.child.stdin) |stdin_file| {
            stdin_file.close(self.io);
            self.child.stdin = null;
        }

        const term = self.child.wait(self.io) catch return error.ShutdownFailed;
        switch (term) {
            .exited => |code| if (code != 0) return error.ShutdownFailed,
            else => return error.ShutdownFailed,
        }
    }
};

/// Spawn the CLI, perform the handshake, return the live subprocess.
///
/// Caller must call `session.shutdown()` when done.
pub fn connect(
    allocator: std.mem.Allocator,
    io: std.Io,
    cfg: Config,
    cli_path: []const u8,
) errs.ConnectError!struct { params: ConnectParams, session: SessionProc } {
    // Build argv.
    var args: std.ArrayList([]const u8) = .empty;
    defer args.deinit(allocator);

    args.append(allocator, cli_path) catch return error.OutOfMemory;
    args.append(allocator, "session") catch return error.OutOfMemory;

    if (cfg.workdir_path) |w| {
        args.append(allocator, "--workdir") catch return error.OutOfMemory;
        args.append(allocator, w) catch return error.OutOfMemory;
    }
    if (cfg.config_path) |p| {
        args.append(allocator, "--project") catch return error.OutOfMemory;
        args.append(allocator, p) catch return error.OutOfMemory;
    }
    if (cfg.load_workspace_modules) {
        args.append(allocator, "--load-workspace-modules") catch return error.OutOfMemory;
    }

    const sdk_name_label = std.fmt.allocPrint(
        allocator,
        "dagger.io/sdk.name:{s}",
        .{version.sdk_name},
    ) catch return error.OutOfMemory;
    defer allocator.free(sdk_name_label);
    args.append(allocator, "--label") catch return error.OutOfMemory;
    args.append(allocator, sdk_name_label) catch return error.OutOfMemory;

    const sdk_ver_label = std.fmt.allocPrint(
        allocator,
        "dagger.io/sdk.version:{s}",
        .{version.sdk_version},
    ) catch return error.OutOfMemory;
    defer allocator.free(sdk_ver_label);
    args.append(allocator, "--label") catch return error.OutOfMemory;
    args.append(allocator, sdk_ver_label) catch return error.OutOfMemory;

    // 0.16: std.process.spawn takes Io and a single options struct.
    var child = std.process.spawn(io, .{
        .argv = args.items,
        .stdin = .pipe,
        .stdout = .pipe,
        .stderr = .pipe,
    }) catch return error.SpawnFailed;
    errdefer {
        child.kill(io);
    }

    // Handshake: read ONE JSON line from stdout. The CLI may emit progress
    // lines before the handshake, so we loop.
    const stdout = child.stdout orelse return error.HandshakeFailed;
    var reader_buf: [4096]u8 = undefined;
    var file_reader = stdout.readerStreaming(io, &reader_buf);
    const reader = &file_reader.interface;

    var line_buf: std.ArrayList(u8) = .empty;
    defer line_buf.deinit(allocator);

    const params = blk: while (true) {
        line_buf.clearRetainingCapacity();
        // Note: Zig 0.16 streamDelimiter requires std.Io.Writer from ArrayList
        // which has API differences. Using byte-by-byte reading as stable workaround.
        while (true) {
            const b = reader.takeByte() catch |e| switch (e) {
                error.EndOfStream => return error.CliExited,
                else => return error.HandshakeFailed,
            };
            if (b == '\n') break;
            line_buf.append(allocator, b) catch return error.OutOfMemory;
        }

        if (line_buf.items.len == 0) continue;

        const p = ConnectParams.parseJsonLine(allocator, line_buf.items) catch {
            if (cfg.logger) |lg| lg.stdout(line_buf.items);
            continue;
        };
        break :blk p;
    };

    var sess: SessionProc = .{
        .allocator = allocator,
        .io = io,
        .child = child,
    };

    // Spawn drain tasks via io.async. These run until cancelled on shutdown.
    // Using async instead of std.Thread means this works on -fsingle-threaded
    // too (the Io backend decides how to schedule).
    sess.stdout_drain = io.async(drainPipe, .{ io, allocator, stdout, cfg.logger, .stdout });
    if (child.stderr) |stderr| {
        sess.stderr_drain = io.async(drainPipe, .{ io, allocator, stderr, cfg.logger, .stderr });
    }

    return .{ .params = params, .session = sess };
}

const DrainSide = enum { stdout, stderr };

fn drainPipe(
    io: std.Io,
    alloc: std.mem.Allocator,
    file: std.Io.File,
    logger: ?*const config_mod.Logger,
    side: DrainSide,
) void {
    var buf: [4096]u8 = undefined;
    var fr = file.readerStreaming(io, &buf);
    const reader = &fr.interface;

    var line: std.ArrayList(u8) = .empty;
    defer line.deinit(alloc);

    while (true) {
        line.clearRetainingCapacity();
        // Note: Zig 0.16 streamDelimiter requires std.Io.Writer from ArrayList
        // which has API differences. Using byte-by-byte reading as stable workaround.
        while (true) {
            const b = reader.takeByte() catch |e| switch (e) {
                error.EndOfStream => return,
                error.ReadFailed => return,
            };
            if (b == '\n') break;
            line.append(alloc, b) catch return;
        }

        if (logger) |lg| switch (side) {
            .stdout => lg.stdout(line.items),
            .stderr => lg.stderr(line.items),
        };
    }
}
