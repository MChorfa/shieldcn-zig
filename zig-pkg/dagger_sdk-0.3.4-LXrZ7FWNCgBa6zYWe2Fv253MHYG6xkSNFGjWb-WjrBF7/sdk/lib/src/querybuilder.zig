//! Query builder for the Dagger GraphQL API.
//!
//! Mirrors the Rust SDK's `querybuilder.rs`: an immutable singly-linked list of
//! `Selection` nodes (name, alias, args, prev). Nothing executes until a
//! terminal operation calls `build()` and submits the resulting query.
//!
//! ## Memory model
//!
//! All Selections live in an arena owned by the client. This is safe because:
//!   1. Selections are immutable — `.select()` and `.arg()` return *new* nodes
//!      that reference the previous node; they never mutate.
//!   2. The entire chain is discarded together when the session closes.
//!   3. Chained builders never outlive the client.
//!
//! This avoids refcounting and matches Dagger's session-scoped semantics.
//!
//! ## GraphQL input serialization
//!
//! Dagger uses GraphQL input-value literal syntax (not JSON) for arguments:
//!
//!   - Strings  : `"hello"`           (JSON-escaped)
//!   - Integers : `42`                (decimal)
//!   - Floats   : `3.14`
//!   - Booleans : `true` / `false`
//!   - Null     : `null`
//!   - Lists    : `[a, b, c]`
//!   - Objects  : `{key:value,k2:v2}`  ← keys are UNQUOTED, unlike JSON
//!   - Enums    : bare identifier
//!
//! `serializeArg` emits this dialect directly.

const std = @import("std");
const errors = @import("errors.zig");

// ─────────────────────────── Safety Limits ───────────────────────────

/// Maximum depth of selection chain to prevent stack overflow.
const MAX_SELECTION_DEPTH = 100;

/// Maximum number of arguments per selection.
const MAX_ARGS_PER_SELECTION = 50;

/// Maximum serialized argument size in bytes.
const MAX_ARG_SIZE_BYTES = 1024 * 1024; // 1MB

/// A lazy argument resolver. Used for values that depend on an awaited ID
/// (e.g. when you pass `Directory` as an arg, it must be resolved to its
/// opaque `DirectoryId` first, which may require a round-trip to the engine).
///
/// `resolve` returns a newly-allocated string that the caller owns.
pub const LazyArg = struct {
    ctx: *anyopaque,
    resolve_fn: *const fn (ctx: *anyopaque, allocator: std.mem.Allocator) errors.BuildError![]u8,

    pub fn resolve(self: LazyArg, allocator: std.mem.Allocator) errors.BuildError![]u8 {
        return self.resolve_fn(self.ctx, allocator);
    }
};

pub const ArgValue = union(enum) {
    /// Pre-serialized GraphQL input literal.
    eager: []const u8,
    /// Resolved at `build()` time.
    lazy: LazyArg,

    pub fn materialize(self: ArgValue, allocator: std.mem.Allocator) errors.BuildError![]u8 {
        return switch (self) {
            .eager => |s| allocator.dupe(u8, s),
            .lazy => |l| l.resolve(allocator),
        };
    }
};

const Arg = struct {
    name: []const u8, // interned in arena, no ownership
    value: ArgValue,
};

/// An immutable node in the selection chain. Allocation is arena-backed by
/// the `SelectionArena` passed to every mutating method.
pub const Selection = struct {
    name: ?[]const u8,
    alias: ?[]const u8,
    args: []const Arg,
    prev: ?*const Selection,

    /// Root selection. All chains start here.
    pub const root: Selection = .{
        .name = null,
        .alias = null,
        .args = &.{},
        .prev = null,
    };

    /// Calculate the depth of this selection chain.
    fn depth(self: *const Selection) usize {
        var d: usize = 0;
        var current: ?*const Selection = self;
        while (current) |c| {
            d += 1;
            current = c.prev;
        }
        return d;
    }

    /// Select a field by name. Returns a pointer to a new Selection allocated
    /// in `arena`. Caller guarantees `arena` outlives all derived Selections.
    pub fn select(
        self: *const Selection,
        arena: std.mem.Allocator,
        name: []const u8,
    ) !*Selection {
        // Safety check: prevent excessive chain depth
        if (self.depth() >= MAX_SELECTION_DEPTH) {
            return error.SelectionTooDeep;
        }

        const node = try arena.create(Selection);
        node.* = .{
            .name = try arena.dupe(u8, name),
            .alias = null,
            .args = &.{},
            .prev = self,
        };
        return node;
    }

    /// Select a field with a GraphQL alias (`alias: fieldName`).
    pub fn selectWithAlias(
        self: *const Selection,
        arena: std.mem.Allocator,
        alias: []const u8,
        name: []const u8,
    ) !*Selection {
        const node = try arena.create(Selection);
        node.* = .{
            .name = try arena.dupe(u8, name),
            .alias = try arena.dupe(u8, alias),
            .args = &.{},
            .prev = self,
        };
        return node;
    }

    /// Add an argument. Returns a new Selection; the receiver is not mutated.
    ///
    /// `value` must be a pre-serialized GraphQL input literal. Use
    /// `serializeArg` helpers to produce one.
    pub fn arg(
        self: *const Selection,
        arena: std.mem.Allocator,
        name: []const u8,
        value: ArgValue,
    ) !*Selection {
        // Safety check: prevent too many arguments
        if (self.args.len >= MAX_ARGS_PER_SELECTION) {
            return error.TooManyArguments;
        }

        const node = try arena.create(Selection);
        const new_args = try arena.alloc(Arg, self.args.len + 1);
        @memcpy(new_args[0..self.args.len], self.args);
        new_args[self.args.len] = .{
            .name = try arena.dupe(u8, name),
            .value = value,
        };
        node.* = .{
            .name = self.name,
            .alias = self.alias,
            .args = new_args,
            .prev = self.prev,
        };
        return node;
    }

    /// Eager-string sugar: `sel.argStr(arena, "ref", "alpine")`.
    pub fn argStr(
        self: *const Selection,
        arena: std.mem.Allocator,
        name: []const u8,
        value: []const u8,
    ) !*Selection {
        const serialized = try serializeString(arena, value);
        return self.arg(arena, name, .{ .eager = serialized });
    }

    /// Walk from the root down to `self`, producing an ordered list.
    /// Excludes the implicit root (which has `name == null`).
    fn path(self: *const Selection, arena: std.mem.Allocator) ![]*const Selection {
        var list: std.ArrayList(*const Selection) = .empty;
        defer list.deinit(arena);

        var cur: ?*const Selection = self;
        while (cur) |c| {
            if (c.name == null) break; // root sentinel
            try list.append(arena, c);
            cur = c.prev;
        }
        // Reverse in place.
        const slice = try list.toOwnedSlice(arena);
        std.mem.reverse(*const Selection, slice);
        return slice;
    }

    /// Build the final GraphQL query string. Caller owns the returned slice.
    ///
    /// Produces exactly the Rust SDK's format:
    ///   `query{a(arg:"v"){b{c}}}`
    pub fn build(self: *const Selection, allocator: std.mem.Allocator) ![]u8 {
        if (self.name == null) return error.EmptySelection;

        var scratch = std.heap.ArenaAllocator.init(allocator);
        defer scratch.deinit();
        const sa = scratch.allocator();

        const nodes = try self.path(sa);

        var fields: std.ArrayList([]const u8) = .empty;
        try fields.append(sa, "query");

        for (nodes) |node| {
            var piece: std.ArrayList(u8) = .empty;
            if (node.alias) |a| {
                try piece.appendSlice(sa, a);
                try piece.append(sa, ':');
            }
            try piece.appendSlice(sa, node.name.?);
            if (node.args.len > 0) {
                try piece.append(sa, '(');
                for (node.args, 0..) |a, i| {
                    if (i > 0) try piece.appendSlice(sa, ", ");
                    try piece.appendSlice(sa, a.name);
                    try piece.append(sa, ':');
                    const mat = try a.value.materialize(sa);
                    try piece.appendSlice(sa, mat);
                }
                try piece.append(sa, ')');
            }
            try fields.append(sa, try piece.toOwnedSlice(sa));
        }

        // Join with '{' and close with N '}'
        var out: std.ArrayList(u8) = .empty;
        for (fields.items, 0..) |f, i| {
            if (i > 0) try out.append(allocator, '{');
            try out.appendSlice(allocator, f);
        }
        // closing braces: one per selection node (path length, not fields.len).
        var i: usize = 0;
        while (i < fields.items.len - 1) : (i += 1) {
            try out.append(allocator, '}');
        }
        return out.toOwnedSlice(allocator);
    }
};

// ─────────────────────────── serialization helpers ───────────────────────────

/// Serialize a Zig string as a GraphQL quoted string literal.
/// Escapes `\`, `"`, and control characters per the GraphQL spec.
pub fn serializeString(allocator: std.mem.Allocator, s: []const u8) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);
    try out.append(allocator, '"');
    for (s) |c| {
        switch (c) {
            '"' => try out.appendSlice(allocator, "\\\""),
            '\\' => try out.appendSlice(allocator, "\\\\"),
            '\n' => try out.appendSlice(allocator, "\\n"),
            '\r' => try out.appendSlice(allocator, "\\r"),
            '\t' => try out.appendSlice(allocator, "\\t"),
            0x08 => try out.appendSlice(allocator, "\\b"),
            0x0C => try out.appendSlice(allocator, "\\f"),
            0...0x07, 0x0B, 0x0E...0x1F => {
                var buf: [6]u8 = undefined;
                const n = std.fmt.bufPrint(&buf, "\\u{x:0>4}", .{c}) catch unreachable;
                try out.appendSlice(allocator, n);
            },
            else => try out.append(allocator, c),
        }
    }
    try out.append(allocator, '"');
    return out.toOwnedSlice(allocator);
}

/// Serialize a list of strings as a GraphQL list literal.
pub fn serializeStringList(allocator: std.mem.Allocator, items: []const []const u8) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);
    try out.append(allocator, '[');
    for (items, 0..) |it, i| {
        if (i > 0) try out.append(allocator, ',');
        const q = try serializeString(allocator, it);
        defer allocator.free(q);
        try out.appendSlice(allocator, q);
    }
    try out.append(allocator, ']');
    return out.toOwnedSlice(allocator);
}

/// Serialize a signed integer.
pub fn serializeInt(allocator: std.mem.Allocator, n: i64) ![]u8 {
    return std.fmt.allocPrint(allocator, "{d}", .{n});
}

/// Serialize a boolean.
pub fn serializeBool(allocator: std.mem.Allocator, b: bool) ![]u8 {
    return allocator.dupe(u8, if (b) "true" else "false");
}

/// Serialize an enum-like bare identifier (no quotes).
pub fn serializeEnum(allocator: std.mem.Allocator, name: []const u8) ![]u8 {
    return allocator.dupe(u8, name);
}

// ─────────────────────────── tests ───────────────────────────────────────────

const testing = std.testing;

test "simple chain" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const root = &Selection.root;
    const core = try root.select(a, "core");
    const img = try core.select(a, "image");
    const img2 = try img.argStr(a, "ref", "alpine");
    const file = try img2.select(a, "file");
    const file2 = try file.argStr(a, "path", "/etc/alpine-release");

    const q = try file2.build(testing.allocator);
    defer testing.allocator.free(q);

    try testing.expectEqualStrings(
        \\query{core{image(ref:"alpine"){file(path:"/etc/alpine-release")}}}
    , q);
}

test "alias" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const root = &Selection.root;
    const s1 = try root.select(a, "core");
    const s2 = try s1.select(a, "image");
    const s3 = try s2.argStr(a, "ref", "alpine");
    const s4 = try s3.selectWithAlias(a, "foo", "file");
    const s5 = try s4.argStr(a, "path", "/etc/alpine-release");

    const q = try s5.build(testing.allocator);
    defer testing.allocator.free(q);

    try testing.expectEqualStrings(
        \\query{core{image(ref:"alpine"){foo:file(path:"/etc/alpine-release")}}}
    , q);
}

test "arg collision does not conflate" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const root = &Selection.root;
    const s1 = try root.select(a, "a");
    const s2 = try s1.argStr(a, "arg", "one");
    const s3 = try s2.select(a, "b");
    const s4 = try s3.argStr(a, "arg", "two");

    const q = try s4.build(testing.allocator);
    defer testing.allocator.free(q);
    try testing.expectEqualStrings(
        \\query{a(arg:"one"){b(arg:"two")}}
    , q);
}

test "vec arg (string list)" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const items: []const []const u8 = &.{"some-string"};
    const lit = try serializeStringList(a, items);

    const root = &Selection.root;
    const s1 = try root.select(a, "a");
    const s2 = try s1.arg(a, "arg", .{ .eager = lit });

    const q = try s2.build(testing.allocator);
    defer testing.allocator.free(q);
    try testing.expectEqualStrings(
        \\query{a(arg:["some-string"])}
    , q);
}

test "field immutability - sibling branches share prefix" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const root = &Selection.root;
    const test_sel = try root.select(a, "test");

    const aa = try test_sel.select(a, "a");
    const qa = try aa.build(testing.allocator);
    defer testing.allocator.free(qa);
    try testing.expectEqualStrings("query{test{a}}", qa);

    const bb = try test_sel.select(a, "b");
    const qb = try bb.build(testing.allocator);
    defer testing.allocator.free(qb);
    try testing.expectEqualStrings("query{test{b}}", qb);
}

test "int and bool args" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const i_lit = try serializeInt(a, 42);
    const b_lit = try serializeBool(a, true);

    const s = try (&Selection.root)
        .select(a, "f");
    const s2 = try s.arg(a, "n", .{ .eager = i_lit });
    const s3 = try s2.arg(a, "b", .{ .eager = b_lit });

    const q = try s3.build(testing.allocator);
    defer testing.allocator.free(q);
    try testing.expectEqualStrings("query{f(n:42, b:true)}", q);
}

test "string escape" {
    const a = testing.allocator;
    const s = try serializeString(a, "he said \"hi\"\nnext");
    defer a.free(s);
    try testing.expectEqualStrings("\"he said \\\"hi\\\"\\nnext\"", s);
}

test "empty selection is rejected" {
    try testing.expectError(error.EmptySelection, Selection.root.build(testing.allocator));
}
