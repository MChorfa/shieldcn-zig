//! `dagger-codegen` — runs the introspection query against a live engine and
//! writes `src/gen.zig`.
//!
//! Usage:
//!   dagger run -- zig build codegen -- --out src/gen.zig

const std = @import("std");
const dagger = @import("dagger_sdk");
const intro = @import("introspection.zig");
const emit = @import("emit.zig");

pub fn main(init: std.process.Init) !void {
    const gpa = init.gpa;
    const io = init.io;
    const arena = init.arena.allocator();

    const args = try init.minimal.args.toSlice(arena);

    var out_path: ?[]const u8 = null;
    var i: usize = 1;
    while (i < args.len) : (i += 1) {
        if (std.mem.eql(u8, args[i], "--out") and i + 1 < args.len) {
            out_path = args[i + 1];
            i += 1;
        } else if (std.mem.eql(u8, args[i], "--help") or std.mem.eql(u8, args[i], "-h")) {
            var stdout = std.Io.File.stdout();
            defer stdout.close(io);
            try stdout.writeStreamingAll(io,
                \\dagger-codegen — Zig SDK code generator
                \\
                \\Usage:
                \\  dagger-codegen [--out PATH]
                \\
                \\Requires a running Dagger engine.
                \\
            );
            return;
        }
    }

    var client = try dagger.connect(gpa, io, .{});
    defer client.close();

    const body = try client.gql.query(intro.query);
    defer gpa.free(body);

    var parsed = try intro.parse(gpa, body);
    defer parsed.deinit();

    var emitter = emit.Emitter.init(gpa);
    defer emitter.deinit();

    try emitter.emitAll(parsed.value);

    if (out_path) |p| {
        var cwd = std.Io.Dir.cwd();
        var f = try cwd.createFile(io, p, .{});
        defer f.close(io);
        try f.writeStreamingAll(io, emitter.source());
        std.debug.print("codegen: wrote {d} bytes to {s}\n", .{ emitter.source().len, p });
    } else {
        var stdout = std.Io.File.stdout();
        defer stdout.close(io);
        try stdout.writeStreamingAll(io, emitter.source());
    }
}
