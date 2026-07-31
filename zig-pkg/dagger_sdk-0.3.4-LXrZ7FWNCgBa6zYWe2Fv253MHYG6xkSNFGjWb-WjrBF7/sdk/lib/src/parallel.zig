//! Concurrent fan-out helpers over `std.Io.Group`.
//!
//! Thin, correct wrappers around Zig 0.16's `std.Io.Group`: schedule one task
//! per item and wait for all of them. Under the multi-threaded `Io` backend the
//! tasks run in parallel; under `-fsingle-threaded` the backend schedules them
//! cooperatively. User code is identical either way.
//!
//! Pair these with `dagger.Client.branch()`: give each task its own client.
//! Sharing one client across concurrent tasks is a data race — the client's
//! per-query error/breaker state is not synchronized.
//!
//! `std.Io.Group.await` surfaces only cancellation, so task functions return
//! `std.Io.Cancelable!void` and report real results (and errors) through their
//! output slot. This is the canonical std pattern, not a limitation of these
//! helpers.

const std = @import("std");

/// Run `op` concurrently over every item, for its side effects.
///
/// `op` must have the shape
/// `fn(std.Io, @TypeOf(context), Item) std.Io.Cancelable!void`.
/// If any task cancels, the returned error surfaces it and the rest are
/// cancelled by the deferred `group.cancel`.
pub fn forEach(
    io: std.Io,
    items: anytype,
    context: anytype,
    comptime op: anytype,
) std.Io.Cancelable!void {
    var group: std.Io.Group = .init;
    defer group.cancel(io);
    for (items) |item| {
        group.async(io, op, .{ io, context, item });
    }
    return group.await(io);
}

/// Concurrently apply `op` to each input, writing each result into the matching
/// slot of `results` (`results[i]` ← op over `inputs[i]`). Indices are
/// disjoint, so no locking is needed.
///
/// `op` must have the shape
/// `fn(std.Io, @TypeOf(context), In, *Out) std.Io.Cancelable!void`.
/// `inputs` and `results` must have the same length.
pub fn map(
    io: std.Io,
    inputs: anytype,
    results: anytype,
    context: anytype,
    comptime op: anytype,
) std.Io.Cancelable!void {
    if (inputs.len != results.len) @panic("parallel.map requires inputs and results to have the same length");
    var group: std.Io.Group = .init;
    defer group.cancel(io);
    for (inputs, results) |in, *out| {
        group.async(io, op, .{ io, context, in, out });
    }
    return group.await(io);
}

// ─────────────────────────── tests ──────────────────────────────────────────

const testing = std.testing;

fn squareInto(io: std.Io, _: void, n: u32, out: *u64) std.Io.Cancelable!void {
    _ = io;
    out.* = @as(u64, n) * @as(u64, n);
}

test "map writes each result into its disjoint slot" {
    var io_impl: std.Io.Threaded = .init(testing.allocator, .{});
    defer io_impl.deinit();
    const io = io_impl.io();

    const inputs = [_]u32{ 1, 2, 3, 4, 5, 6, 7, 8 };
    var results: [inputs.len]u64 = undefined;

    try map(io, &inputs, &results, {}, squareInto);

    for (inputs, results) |n, r| {
        try testing.expectEqual(@as(u64, n) * @as(u64, n), r);
    }
}

fn bumpCounter(io: std.Io, counter: *std.atomic.Value(u32), _: u32) std.Io.Cancelable!void {
    _ = io;
    _ = counter.fetchAdd(1, .monotonic);
}

test "forEach runs op exactly once per item" {
    var io_impl: std.Io.Threaded = .init(testing.allocator, .{});
    defer io_impl.deinit();
    const io = io_impl.io();

    var counter = std.atomic.Value(u32).init(0);
    const items = [_]u32{ 0, 0, 0, 0, 0, 0 };

    try forEach(io, &items, &counter, bumpCounter);

    try testing.expectEqual(@as(u32, items.len), counter.load(.monotonic));
}
