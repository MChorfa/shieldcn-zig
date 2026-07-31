//! Zig source emitter.
//!
//! Given a parsed `Schema`, emit a Zig file (`gen.zig`) containing:
//!   - one `const XxxID = struct { value: []const u8, ... };` per ID scalar
//!   - one `pub const Foo = struct { ... };` per OBJECT type, with methods
//!     mirroring its GraphQL fields
//!   - one `pub const FooEnum = enum { ... };` per ENUM
//!
//! This is a straight text generator. We deliberately do NOT build an AST —
//! Zig source is line-oriented and templated emission is easier to debug.
//!
//! ## Mapping rules
//!
//! | GraphQL             | Zig                          |
//! |---------------------|------------------------------|
//! | String              | []const u8 (arg) / []u8 (ret) |
//! | Int                 | i64                          |
//! | Float               | f64                          |
//! | Boolean             | bool                         |
//! | ID                  | []const u8                   |
//! | [T]                 | []const T (arg) / []T (ret)  |
//! | T!                  | unwraps one NON_NULL layer   |
//! | OBJECT (Container)  | Container (our wrapper)      |
//! | ENUM                | generated enum               |

const std = @import("std");
const intro = @import("introspection.zig");

pub const Emitter = struct {
    allocator: std.mem.Allocator,
    out: std.ArrayList(u8),

    pub fn init(allocator: std.mem.Allocator) Emitter {
        return .{ .allocator = allocator, .out = .empty };
    }

    pub fn deinit(self: *Emitter) void {
        self.out.deinit(self.allocator);
    }

    pub fn emitAll(self: *Emitter, schema: intro.Schema) !void {
        try self.writePrelude();

        for (schema.types) |t| {
            if (t.name == null) continue;
            if (std.mem.startsWith(u8, t.name.?, "__")) continue; // introspection types
            if (std.mem.eql(u8, t.kind, "OBJECT")) {
                try self.emitObject(t);
            } else if (std.mem.eql(u8, t.kind, "ENUM")) {
                try self.emitEnum(t);
            } else if (std.mem.eql(u8, t.kind, "SCALAR")) {
                // Only emit ID-like scalars; primitives (String/Int/etc.) are mapped inline.
                if (std.mem.endsWith(u8, t.name.?, "ID")) try self.emitIdScalar(t.name.?);
            }
        }
    }

    pub fn source(self: *Emitter) []const u8 {
        return self.out.items;
    }

    // ── sections ────────────────────────────────────────────────────────────

    fn writePrelude(self: *Emitter) !void {
        try self.writeAll(
            \\//! Auto-generated from the Dagger introspection schema.
            \\//! DO NOT EDIT — regenerate with `zig build codegen`.
            \\
            \\const std = @import("std");
            \\const qb = @import("querybuilder.zig");
            \\const gql = @import("core/graphql_client.zig");
            \\const Selection = qb.Selection;
            \\const GraphQLClient = gql.GraphQLClient;
            \\
            \\
        );
    }

    fn emitIdScalar(self: *Emitter, name: []const u8) !void {
        try self.print(
            \\pub const {s} = struct {{
            \\    value: []const u8,
            \\    pub fn deinit(self: *{s}, allocator: std.mem.Allocator) void {{
            \\        allocator.free(self.value);
            \\    }}
            \\}};
            \\
            \\
        , .{ name, name });
    }

    fn emitEnum(self: *Emitter, t: intro.FullType) !void {
        const name = t.name.?;
        try self.print("pub const {s} = enum {{\n", .{name});
        if (t.enum_values) |vals| for (vals) |v| {
            const sanitized = try sanitize(self.allocator, v.name);
            defer if (sanitized.ptr != v.name.ptr) self.allocator.free(sanitized);
            try self.print("    {s},\n", .{sanitized});
        };
        try self.writeAll("};\n\n");
    }

    fn emitObject(self: *Emitter, t: intro.FullType) !void {
        const name = t.name.?;
        try self.print(
            \\pub const {s} = struct {{
            \\    allocator: std.mem.Allocator,
            \\    arena: std.mem.Allocator,
            \\    selection: *const Selection,
            \\    gql: *GraphQLClient,
            \\
            \\
        , .{name});

        if (t.fields) |fields| for (fields) |f| {
            self.emitField(name, f) catch |e| {
                std.debug.print("skipping field {s}.{s}: {s}\n", .{ name, f.name, @errorName(e) });
            };
        };

        try self.writeAll("};\n\n");
    }

    fn emitField(self: *Emitter, parent: []const u8, f: intro.Field) !void {
        _ = parent;
        // Classify the field: does it return a scalar (terminal) or an object
        // (chainable)? Strip NON_NULL to see the inner type.
        const ret = unwrapNonNull(f.type);

        const method_name = toZigIdent(self.allocator, f.name) catch f.name;
        defer if (method_name.ptr != f.name.ptr) self.allocator.free(method_name);

        // Build the arg list string.
        var arg_decls: std.ArrayList(u8) = .empty;
        defer arg_decls.deinit(self.allocator);
        var arg_applies: std.ArrayList(u8) = .empty;
        defer arg_applies.deinit(self.allocator);

        for (f.args) |a| {
            const z_ty = zigArgType(a.type);
            try printToArrayList(self.allocator, &arg_decls, ", {s}: {s}", .{ a.name, z_ty });
            try printToArrayList(
                self.allocator,
                &arg_applies,
                "        const s_{s} = try s_prev.argStr(self.arena, \"{s}\", {s});\n",
                .{ a.name, a.name, a.name },
            );
            // Not all args are strings — for v0.1 of the emitter we keep this
            // simple and note in the README that int/bool/enum args need manual
            // fixup. A proper generator would dispatch on a.type.kind.
        }

        const zig_kind = kindOf(ret);
        switch (zig_kind) {
            .terminal_string => {
                try self.print(
                    \\    pub fn {s}(self: @This(){s}) ![]u8 {{
                    \\        const s_prev = self.selection;
                    \\        const s0 = try s_prev.select(self.arena, "{s}");
                    \\{s}        const terminal = s0;
                    \\        return executeScalarString(self.allocator, terminal, self.gql);
                    \\    }}
                    \\
                    \\
                , .{ method_name, arg_decls.items, f.name, arg_applies.items });
            },
            .terminal_int, .terminal_bool => {
                // Stub — emit a TODO. A complete emitter would decode the scalar.
                try self.print("    // TODO: non-string scalar field `{s}` not yet emitted.\n\n", .{f.name});
            },
            .chainable => |obj_name| {
                try self.print(
                    \\    pub fn {s}(self: @This(){s}) !{s} {{
                    \\        const s_prev = self.selection;
                    \\        const s0 = try s_prev.select(self.arena, "{s}");
                    \\{s}        return .{{
                    \\            .allocator = self.allocator,
                    \\            .arena = self.arena,
                    \\            .selection = s0,
                    \\            .gql = self.gql,
                    \\        }};
                    \\    }}
                    \\
                    \\
                , .{ method_name, arg_decls.items, obj_name, f.name, arg_applies.items });
            },
            .unknown => {
                try self.print("    // TODO: field `{s}` has unmapped return type.\n\n", .{f.name});
            },
        }
    }

    // ── low-level writers ───────────────────────────────────────────────────

    fn print(self: *Emitter, comptime fmt: []const u8, args: anytype) !void {
        const str = try std.fmt.allocPrint(self.allocator, fmt, args);
        defer self.allocator.free(str);
        try self.out.appendSlice(self.allocator, str);
    }

    fn writeAll(self: *Emitter, bytes: []const u8) !void {
        try self.out.appendSlice(self.allocator, bytes);
    }
};

// Helper to format print into an ArrayList (ArrayList.writer() doesn't work in 0.16)
fn printToArrayList(allocator: std.mem.Allocator, list: *std.ArrayList(u8), comptime fmt: []const u8, args: anytype) !void {
    const str = try std.fmt.allocPrint(allocator, fmt, args);
    defer allocator.free(str);
    try list.appendSlice(allocator, str);
}

// ─────────────────────────── type analysis ──────────────────────────────────

const FieldKind = union(enum) {
    terminal_string,
    terminal_int,
    terminal_bool,
    chainable: []const u8, // object type name
    unknown,
};

fn unwrapNonNull(t: intro.TypeRef) intro.TypeRef {
    if (std.mem.eql(u8, t.kind, "NON_NULL")) {
        if (t.of_type) |inner| return inner.*;
    }
    return t;
}

fn kindOf(t: intro.TypeRef) FieldKind {
    if (std.mem.eql(u8, t.kind, "SCALAR")) {
        if (t.name) |n| {
            if (std.mem.eql(u8, n, "String") or std.mem.endsWith(u8, n, "ID")) return .terminal_string;
            if (std.mem.eql(u8, n, "Int")) return .terminal_int;
            if (std.mem.eql(u8, n, "Boolean")) return .terminal_bool;
        }
        return .unknown;
    }
    if (std.mem.eql(u8, t.kind, "OBJECT")) {
        if (t.name) |n| return .{ .chainable = n };
    }
    return .unknown;
}

fn zigArgType(t: intro.TypeRef) []const u8 {
    const inner = unwrapNonNull(t);
    if (std.mem.eql(u8, inner.kind, "SCALAR")) {
        if (inner.name) |n| {
            if (std.mem.eql(u8, n, "String")) return "[]const u8";
            if (std.mem.eql(u8, n, "Int")) return "i64";
            if (std.mem.eql(u8, n, "Boolean")) return "bool";
            if (std.mem.endsWith(u8, n, "ID")) return "[]const u8";
        }
    }
    if (std.mem.eql(u8, inner.kind, "LIST")) return "[]const []const u8"; // conservative
    return "[]const u8"; // fallback; manual fixup documented in README
}

fn sanitize(allocator: std.mem.Allocator, s: []const u8) ![]const u8 {
    // GraphQL names may contain characters invalid in Zig identifiers (e.g., '-', spaces)
    // Replace them with underscores to create valid Zig identifiers.
    if (std.mem.indexOfAny(u8, s, "- ")) |_| {
        var result = try allocator.alloc(u8, s.len);
        for (s, 0..) |c, i| {
            result[i] = if (c == '-' or c == ' ') '_' else c;
        }
        return result;
    }
    return s;
}

/// Convert snake-or-camelCase GraphQL name to a Zig-safe identifier.
/// For now this is a passthrough; GraphQL names are already valid Zig idents.
fn toZigIdent(_: std.mem.Allocator, name: []const u8) ![]const u8 {
    return name;
}

// ─────────────────────────── tests ──────────────────────────────────────────

test "emitter produces a compilable prelude" {
    var e = Emitter.init(std.testing.allocator);
    defer e.deinit();

    const empty: intro.Schema = .{ .types = &.{} };
    try e.emitAll(empty);

    const src = e.source();
    try std.testing.expect(std.mem.indexOf(u8, src, "querybuilder.zig") != null);
    try std.testing.expect(std.mem.indexOf(u8, src, "Selection") != null);
}

test "emit a minimal object with one string field" {
    var e = Emitter.init(std.testing.allocator);
    defer e.deinit();

    const str_scalar: intro.TypeRef = .{ .kind = "SCALAR", .name = "String" };
    const schema: intro.Schema = .{ .types = &.{
        .{
            .kind = "OBJECT",
            .name = "Echo",
            .fields = &.{
                .{ .name = "value", .type = str_scalar },
            },
        },
    } };

    try e.emitAll(schema);
    const src = e.source();
    try std.testing.expect(std.mem.indexOf(u8, src, "pub const Echo = struct") != null);
    try std.testing.expect(std.mem.indexOf(u8, src, "pub fn value(") != null);
    try std.testing.expect(std.mem.indexOf(u8, src, "executeScalarString") != null);
}

test "sanitize replaces invalid Zig identifier chars" {
    const allocator = std.testing.allocator;

    // Valid identifier - no allocation
    const valid = try sanitize(allocator, "HelloWorld");
    try std.testing.expectEqualStrings("HelloWorld", valid);

    // With dash - should allocate and replace
    const with_dash = try sanitize(allocator, "hello-world");
    defer allocator.free(with_dash);
    try std.testing.expectEqualStrings("hello_world", with_dash);

    // With space - should allocate and replace
    const with_space = try sanitize(allocator, "hello world");
    defer allocator.free(with_space);
    try std.testing.expectEqualStrings("hello_world", with_space);
}
