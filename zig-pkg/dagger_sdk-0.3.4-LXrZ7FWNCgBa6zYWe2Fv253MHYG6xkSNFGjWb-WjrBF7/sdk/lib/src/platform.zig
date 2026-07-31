//! Platform-specific abstractions for cross-platform compatibility.
//!
//! This module provides:
//! - Path separator normalization
//! - Shell execution wrappers
//! - File system operations that vary by OS

const std = @import("std");

/// Platform detection
pub const is_windows = @import("builtin").os.tag == .windows;
pub const is_posix = !is_windows;

/// Path separator for the current platform
pub const path_sep = if (is_windows) '\\' else '/';
pub const path_sep_str = if (is_windows) "\\" else "/";

/// Normalize a path string to use platform-native separators
pub fn normalizePath(allocator: std.mem.Allocator, path: []const u8) ![]u8 {
    if (is_posix) {
        // POSIX: just return a copy, forward slashes are native
        return allocator.dupe(u8, path);
    }

    // Windows: convert forward slashes to backslashes
    const normalized = try allocator.alloc(u8, path.len);
    for (path, 0..) |c, i| {
        normalized[i] = if (c == '/') '\\' else c;
    }
    return normalized;
}

/// Get the user's home directory
pub fn homeDir(allocator: std.mem.Allocator) ?[]u8 {
    if (is_windows) {
        const home = std.process.getEnvVarOwned(allocator, "USERPROFILE") catch return null;
        return home;
    } else {
        const home = std.process.getEnvVarOwned(allocator, "HOME") catch return null;
        return home;
    }
}

/// Get the default Dagger config directory
pub fn daggerConfigDir(allocator: std.mem.Allocator) !?[]u8 {
    const home = homeDir(allocator) orelse return null;
    defer allocator.free(home);

    const subdir = if (is_windows) "\\.dagger" else "/.dagger";
    const path = try std.fmt.allocPrint(allocator, "{s}{s}", .{ home, subdir });

    // Ensure directory exists
    std.fs.makeDirAbsolute(path) catch |err| switch (err) {
        error.PathAlreadyExists => {},
        else => return err,
    };

    return path;
}

/// Shell command wrapper - handles platform differences
pub const Shell = struct {
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator) Shell {
        return .{ .allocator = allocator };
    }

    /// Execute a command and return output
    pub fn exec(self: Shell, cmd: []const []const u8) ![]u8 {
        if (is_windows) {
            // On Windows, use cmd.exe /c
            var args = std.ArrayList([]const u8).init(self.allocator);
            defer args.deinit();

            try args.append("cmd.exe");
            try args.append("/c");
            for (cmd) |arg| {
                try args.append(arg);
            }

            const result = try std.process.Child.run(.{
                .allocator = self.allocator,
                .argv = args.items,
            });

            if (result.term.Exited != 0) {
                self.allocator.free(result.stderr);
                self.allocator.free(result.stdout);
                return error.CommandFailed;
            }

            self.allocator.free(result.stderr);
            return result.stdout;
        } else {
            // POSIX: execute directly
            const result = try std.process.Child.run(.{
                .allocator = self.allocator,
                .argv = cmd,
            });

            if (result.term.Exited != 0) {
                self.allocator.free(result.stderr);
                self.allocator.free(result.stdout);
                return error.CommandFailed;
            }

            self.allocator.free(result.stderr);
            return result.stdout;
        }
    }
};

/// Environment variable name normalization
pub fn envVarName(comptime name: []const u8) []const u8 {
    // Windows is case-insensitive, but we preserve case
    // This function allows for platform-specific env var names if needed
    return name;
}

/// Get the platform-specific null device
pub const null_device = if (is_windows) "NUL" else "/dev/null";

/// Check if a file is executable (considers .exe extension on Windows)
pub fn isExecutable(path: []const u8) bool {
    if (is_windows) {
        const ext = std.fs.path.extension(path);
        return std.mem.eql(u8, ext, ".exe") or
            std.mem.eql(u8, ext, ".bat") or
            std.mem.eql(u8, ext, ".cmd");
    } else {
        // On POSIX, check execute permission via access
        std.posix.access(path, std.posix.X_OK) catch return false;
        return true;
    }
}

/// Join paths using platform separator
pub fn joinPath(allocator: std.mem.Allocator, parts: []const []const u8) ![]u8 {
    return try std.fs.path.join(allocator, parts);
}

// ─────────────────────────── Socket Abstractions ───────────────────────────

/// Platform-specific socket handle
pub const Socket = struct {
    fd: i32, // Unix: file descriptor, Windows: SOCKET (cast)

    /// Socket operation errors.
    /// Note: public methods return inferred error sets (POSIX errors plus
    /// error.NotSupported). This type alias is kept for documentation purposes.
    pub const Error = @import("errors.zig").PlatformError;

    /// Connect to a Unix domain socket (POSIX) or named pipe (Windows)
    pub fn connectUnix(path: []const u8) !Socket {
        if (is_windows) {
            // Windows: Use AF_UNIX if available (Windows 10 1803+), else named pipe
            return connectWindowsSocket(path);
        } else {
            // POSIX: Standard Unix domain socket
            return connectPosixSocket(path);
        }
    }

    fn connectPosixSocket(path: []const u8) !Socket {
        const fd = try std.posix.socket(std.posix.AF.UNIX, std.posix.SOCK.STREAM, 0);
        errdefer std.posix.close(fd);

        var addr: std.posix.sockaddr.un = undefined;
        addr.family = std.posix.AF.UNIX;

        const path_len = @min(path.len, addr.path.len - 1);
        @memcpy(addr.path[0..path_len], path[0..path_len]);
        addr.path[path_len] = 0;

        const addr_len = @offsetOf(std.posix.sockaddr.un, "path") + path_len + 1;
        try std.posix.connect(fd, @ptrCast(&addr), @intCast(addr_len));

        return Socket{ .fd = fd };
    }

    fn connectWindowsSocket(path: []const u8) !Socket {
        // Windows socket support is still a planned compatibility path.
        // Windows 10 1803+ has AF_UNIX support, or use named pipes.
        _ = path;

        std.log.warn("Windows socket support is not yet implemented. Use WSL2 or a supported Unix-like host.", .{});
        return error.NotSupported;
    }

    /// Read from socket
    pub fn read(self: Socket, buffer: []u8) !usize {
        if (is_windows) {
            std.log.warn("Socket.read(fd={}, buf_len={}) is not supported on Windows yet", .{ self.fd, buffer.len });
            return error.NotSupported;
        } else {
            return std.posix.read(self.fd, buffer);
        }
    }

    /// Write to socket
    pub fn write(self: Socket, data: []const u8) !void {
        if (is_windows) {
            std.log.warn("Socket.write(fd={}, data_len={}) is not supported on Windows yet", .{ self.fd, data.len });
            return error.NotSupported;
        } else {
            const n = try std.posix.write(self.fd, data);
            if (n < data.len) return error.WriteError;
        }
    }

    /// Close socket
    pub fn close(self: Socket) void {
        if (is_windows) {
            std.log.warn("Socket.close(fd={}) is not implemented on Windows yet", .{self.fd});
        } else {
            std.posix.close(self.fd);
        }
    }
};

// ─────────────────────────── Async I/O Helpers ───────────────────────────

/// Platform-specific async I/O capabilities
pub const AsyncIo = struct {
    /// Check if the platform supports true async I/O
    ///
    /// Linux/macOS are the primary supported paths; Windows remains a
    /// planned compatibility target and may return `error.NotSupported`.
    pub fn supportsAsync() bool {
        return !is_windows; // Windows support is still a planned path
    }

    /// Get the optimal async strategy for the platform
    pub fn strategy() AsyncStrategy {
        if (is_windows) {
            // Windows currently uses the threaded fallback.
            return .threaded;
        } else if (@import("builtin").os.tag == .linux) {
            return .io_uring;
        } else {
            // macOS, BSD, and other POSIX platforms use kqueue
            return .kqueue;
        }
    }
};

pub const AsyncStrategy = enum {
    io_uring, // Linux native
    kqueue, // macOS/BSD
    threaded, // Fallback using std.Thread
    io_completion, // Reserved for future Windows IOCP support.
};

// ─────────────────────────── Process Management ───────────────────────────

/// Platform-specific process signal handling.
///
/// POSIX signals are supported; Windows signal handling remains a
/// compatibility gap.
pub fn sendTermSignal(pid: i32) void {
    if (is_windows) {
        std.log.warn("sendTermSignal() is not implemented on Windows yet. PID {} not signaled.", .{pid});
    } else {
        // POSIX: SIGTERM
        std.posix.kill(@intCast(pid), std.posix.SIG.TERM) catch |err| {
            std.log.warn("Failed to send SIGTERM to PID {}: {}", .{ pid, err });
        };
    }
}

/// Get the platform-specific temporary directory
pub fn tempDir(allocator: std.mem.Allocator) ![]u8 {
    if (is_windows) {
        const tmp = std.process.getEnvVarOwned(allocator, "TEMP") catch
            std.process.getEnvVarOwned(allocator, "TMP") catch
            return allocator.dupe(u8, "C:\\Temp");
        return tmp;
    } else {
        const tmp = std.process.getEnvVarOwned(allocator, "TMPDIR") catch
            std.process.getEnvVarOwned(allocator, "TMP") catch
            return allocator.dupe(u8, "/tmp");
        return tmp;
    }
}
