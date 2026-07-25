const std = @import("std");
const http_server = @import("server/http.zig");

/// shieldcn-zig — main.zig
/// CLI entry point for the clean-room badge engine.
pub fn main(init: std.process.Init) !void {
    const allocator = init.gpa;

    var args_it = init.minimal.args.iterate();
    defer args_it.deinit();

    // Skip program name
    _ = args_it.skip();

    const command = args_it.next() orelse {
        printUsage();
        return;
    };

    if (std.mem.eql(u8, command, "serve")) {
        var host: []const u8 = "127.0.0.1";
        var port: u16 = 5335;

        while (args_it.next()) |arg| {
            if (std.mem.eql(u8, arg, "--host")) {
                host = args_it.next() orelse host;
            } else if (std.mem.eql(u8, arg, "--port")) {
                const port_arg = args_it.next() orelse break;
                port = std.fmt.parseInt(u16, port_arg, 10) catch 5335;
            }
        }

        var server = try http_server.Server.init(allocator, init.io, host, port);
        defer server.deinit();
        try server.listen();
    } else if (std.mem.eql(u8, command, "help") or std.mem.eql(u8, command, "--help") or std.mem.eql(u8, command, "-h")) {
        printUsage();
    } else {
        std.debug.print("Unknown command: {s}\n", .{command});
        printUsage();
    }
}

fn printUsage() void {
    std.debug.print(
        \\Usage: shieldcn <command> [options]
        \\
        \\Commands:
        \\  serve                      Start the badge HTTP server
        \\    --host <ip>              Bind address (default: 127.0.0.1)
        \\    --port <num>             Port (default: 5335)
        \\  help                     Show this help message
        \\
    , .{});
}

// ------------------------------------------------------------------
// Test root: import all modules so tests are discovered
// ------------------------------------------------------------------

test {
    _ = @import("core/types.zig");
    _ = @import("util/hex.zig");
    _ = @import("util/contrast.zig");
    _ = @import("util/format.zig");
    _ = @import("render/tokens.zig");
    _ = @import("render/themes.zig");
    _ = @import("render/measure.zig");
    _ = @import("render/svg.zig");
    _ = @import("render/png.zig");
    _ = @import("render/group.zig");
    _ = @import("server/params.zig");
    _ = @import("server/router.zig");
    _ = @import("server/http.zig");
    _ = @import("providers/static.zig");
    _ = @import("providers/npm.zig");
    _ = @import("providers/gitlab.zig");
    _ = @import("providers/fetch.zig");
    _ = @import("cache/backoff.zig");
    _ = @import("cache/lru.zig");
    _ = @import("net/egress.zig");
    _ = @import("icons/resolver.zig");
    _ = @import("icons/embedded.zig");
    _ = @import("db/memo.zig");
    _ = @import("db/token_pool.zig");
    _ = @import("util/audit.zig");
}
