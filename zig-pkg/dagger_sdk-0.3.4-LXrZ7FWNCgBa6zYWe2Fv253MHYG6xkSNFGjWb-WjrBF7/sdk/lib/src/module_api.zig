//! Dagger engine API used by the module runtime.
//!
//! These wrappers cover the engine calls a module binary needs to do its job:
//!
//!   1. Query `currentFunctionCall` on startup to learn why we were invoked.
//!   2. In introspection mode, build a `ModuleSource` describing our schema
//!      and return its ID.
//!   3. In dispatch mode, read the function name + args, run the user's
//!      code, return the result as JSON via `returnValue(...)`.
//!   4. Hydrate handle-typed arguments: convert opaque IDs back into live
//!      Container/Directory/... handles (`loadContainerFromID`, etc.).
//!
//! Hand-written against the Dagger engine's GraphQL API (v0.18). When the
//! real codegen emitter (`src/gen.zig`) lands, this file is replaced by its
//! generated equivalents; for v0.1 it's the explicit floor we stand on.

const std = @import("std");
const qb = @import("querybuilder.zig");
const gql = @import("core/graphql_client.zig");
const api = @import("gen.zig");

const Selection = qb.Selection;
const GraphQLClient = gql.GraphQLClient;

// ─────────────────────────── FunctionCall ───────────────────────────────

pub const FunctionCall = struct {
    allocator: std.mem.Allocator,
    arena: std.mem.Allocator,
    selection: *const Selection,
    gql: *GraphQLClient,

    pub fn name(self: FunctionCall) ![]u8 {
        const s = try self.selection.select(self.arena, "name");
        return fetchScalarString(self.allocator, s, self.gql);
    }

    pub fn parentName(self: FunctionCall) ![]u8 {
        const s = try self.selection.select(self.arena, "parentName");
        return fetchScalarString(self.allocator, s, self.gql);
    }

    /// Parent state as a JSON string, for module types that hold state.
    pub fn parentJson(self: FunctionCall) ![]u8 {
        const s = try self.selection.select(self.arena, "parent");
        return fetchScalarString(self.allocator, s, self.gql);
    }

    /// Return all input args as pairs of (name, json_value_string).
    pub fn inputArgs(self: FunctionCall) ![]FunctionCallArgValue {
        // SELECT inputArgs { name, value }
        const s1 = try self.selection.select(self.arena, "inputArgs");
        const s2 = try s1.select(self.arena, "name");
        // We actually need both fields in one query; but our querybuilder
        // produces linear chains. We run two queries instead (v0.1
        // pragmatic choice — the alternative is a real multi-field selection
        // set which needs a querybuilder upgrade).
        _ = s2;
        return fetchArgList(self.allocator, self.selection, self.arena, self.gql);
    }

    /// Write the function's return value back to the engine.
    /// `json_value` must already be a valid JSON literal.
    pub fn returnValue(self: FunctionCall, json_value: []const u8) !void {
        const lit = try qb.serializeString(self.arena, json_value);
        const s1 = try self.selection.select(self.arena, "returnValue");
        const s2 = try s1.arg(self.arena, "value", .{ .eager = lit });
        // Scalar-void: the engine returns "Void" which we discard.
        const query_str = try s2.build(self.allocator);
        defer self.allocator.free(query_str);
        const body = try self.gql.query(query_str);
        self.allocator.free(body);
    }

    pub fn returnError(self: FunctionCall, engine_error: EngineError) !void {
        const error_id = try engine_error.id();
        defer self.allocator.free(error_id);

        const s1 = try self.selection.select(self.arena, "returnError");
        const s2 = try s1.arg(self.arena, "error", .{
            .eager = try qb.serializeString(self.arena, error_id),
        });

        const query_str = try s2.build(self.allocator);
        defer self.allocator.free(query_str);

        const body = try self.gql.query(query_str);
        self.allocator.free(body);
    }
};

pub const EngineError = struct {
    allocator: std.mem.Allocator,
    arena: std.mem.Allocator,
    selection: *const Selection,
    gql: *GraphQLClient,

    pub fn id(self: EngineError) ![]u8 {
        const s = try self.selection.select(self.arena, "id");
        return fetchScalarString(self.allocator, s, self.gql);
    }
};

pub const FunctionCallArgValue = struct {
    name: []const u8, // owned
    /// Raw JSON value as shipped by the engine (e.g., `"42"`, `"\"hello\""`, `"true"`, etc.).
    value_json: []const u8, // owned
    allocator: std.mem.Allocator,

    pub fn deinit(self: *FunctionCallArgValue) void {
        self.allocator.free(self.name);
        self.allocator.free(self.value_json);
    }
};

// ─────────────────────────── module-API root extensions ─────────────────

pub const ModuleQuery = struct {
    allocator: std.mem.Allocator,
    arena: std.mem.Allocator,
    selection: *const Selection,
    gql: *GraphQLClient,

    pub fn newEngineError(self: ModuleQuery, message: []const u8) !EngineError {
        const s1 = try self.selection.select(self.arena, "error");
        const s2 = try s1.argStr(self.arena, "message", message);
        return .{
            .allocator = self.allocator,
            .arena = self.arena,
            .selection = s2,
            .gql = self.gql,
        };
    }

    pub fn currentFunctionCall(self: ModuleQuery) !FunctionCall {
        const s = try self.selection.select(self.arena, "currentFunctionCall");
        return .{
            .allocator = self.allocator,
            .arena = self.arena,
            .selection = s,
            .gql = self.gql,
        };
    }

    /// Load a Container from its opaque ID. Used by the dispatcher to
    /// hydrate handle-typed arguments.
    pub fn loadContainerFromID(self: ModuleQuery, id: []const u8) !api.Container {
        const s1 = try self.selection.select(self.arena, "loadContainerFromID");
        const s2 = try s1.argStr(self.arena, "id", id);
        return .{
            .allocator = self.allocator,
            .arena = self.arena,
            .selection = s2,
            .gql = self.gql,
        };
    }

    pub fn loadDirectoryFromID(self: ModuleQuery, id: []const u8) !api.Directory {
        const s1 = try self.selection.select(self.arena, "loadDirectoryFromID");
        const s2 = try s1.argStr(self.arena, "id", id);
        return .{
            .allocator = self.allocator,
            .arena = self.arena,
            .selection = s2,
            .gql = self.gql,
        };
    }

    pub fn loadFileFromID(self: ModuleQuery, id: []const u8) !api.File {
        const s1 = try self.selection.select(self.arena, "loadFileFromID");
        const s2 = try s1.argStr(self.arena, "id", id);
        return .{
            .allocator = self.allocator,
            .arena = self.arena,
            .selection = s2,
            .gql = self.gql,
        };
    }

    pub fn loadSecretFromID(self: ModuleQuery, id: []const u8) !api.Secret {
        const s1 = try self.selection.select(self.arena, "loadSecretFromID");
        const s2 = try s1.argStr(self.arena, "id", id);
        return .{
            .allocator = self.allocator,
            .arena = self.arena,
            .selection = s2,
            .gql = self.gql,
        };
    }

    pub fn loadCacheVolumeFromID(self: ModuleQuery, id: []const u8) !api.CacheVolume {
        const s1 = try self.selection.select(self.arena, "loadCacheVolumeFromID");
        const s2 = try s1.argStr(self.arena, "id", id);
        return .{
            .allocator = self.allocator,
            .arena = self.arena,
            .selection = s2,
            .gql = self.gql,
        };
    }

    pub fn loadServiceFromID(self: ModuleQuery, id: []const u8) !api.Service {
        const s1 = try self.selection.select(self.arena, "loadServiceFromID");
        const s2 = try s1.argStr(self.arena, "id", id);
        return .{
            .allocator = self.allocator,
            .arena = self.arena,
            .selection = s2,
            .gql = self.gql,
        };
    }

    pub fn loadSocketFromID(self: ModuleQuery, id: []const u8) !api.Socket {
        const s1 = try self.selection.select(self.arena, "loadSocketFromID");
        const s2 = try s1.argStr(self.arena, "id", id);
        return .{
            .allocator = self.allocator,
            .arena = self.arena,
            .selection = s2,
            .gql = self.gql,
        };
    }

    pub fn loadGitRefFromID(self: ModuleQuery, id: []const u8) !api.GitRef {
        const s1 = try self.selection.select(self.arena, "loadGitRefFromID");
        const s2 = try s1.argStr(self.arena, "id", id);
        return .{
            .allocator = self.allocator,
            .arena = self.arena,
            .selection = s2,
            .gql = self.gql,
        };
    }

    pub fn loadGitRepositoryFromID(self: ModuleQuery, id: []const u8) !api.GitRepository {
        const s1 = try self.selection.select(self.arena, "loadGitRepositoryFromID");
        const s2 = try s1.argStr(self.arena, "id", id);
        return .{
            .allocator = self.allocator,
            .arena = self.arena,
            .selection = s2,
            .gql = self.gql,
        };
    }

    pub fn loadHostFromID(self: ModuleQuery, id: []const u8) !api.Host {
        const s1 = try self.selection.select(self.arena, "loadHostFromID");
        const s2 = try s1.argStr(self.arena, "id", id);
        return .{
            .allocator = self.allocator,
            .arena = self.arena,
            .selection = s2,
            .gql = self.gql,
        };
    }
};

/// Convert an ordinary api.Query into a ModuleQuery with the same selection
/// chain. They are structurally identical; the split is just for readability.
pub fn moduleQuery(q: api.Query) ModuleQuery {
    return .{
        .allocator = q.allocator,
        .arena = q.arena,
        .selection = q.selection,
        .gql = q.gql,
    };
}

// ─────────────────────────── helpers ────────────────────────────────────

fn fetchScalarString(
    allocator: std.mem.Allocator,
    sel: *const Selection,
    client: *GraphQLClient,
) ![]u8 {
    const query_str = try sel.build(allocator);
    defer allocator.free(query_str);

    const body = try client.query(query_str);
    defer allocator.free(body);

    const parsed = try std.json.parseFromSlice(std.json.Value, allocator, body, .{});
    defer parsed.deinit();

    const root = parsed.value.object.get("data") orelse return error.InvalidEnvelope;
    const leaf = walkToStringLeaf(root) orelse return error.InvalidEnvelope;
    return allocator.dupe(u8, leaf);
}

fn walkToStringLeaf(v: std.json.Value) ?[]const u8 {
    return switch (v) {
        .string => |s| s,
        .object => |o| blk: {
            if (o.count() != 1) break :blk null;
            var it = o.iterator();
            const entry = it.next() orelse break :blk null;
            break :blk walkToStringLeaf(entry.value_ptr.*);
        },
        else => null,
    };
}

/// Fetch the inputArgs list — pairs of {name, value} — in one query.
/// Because our Selection linked-list only supports linear chains, we use a
/// hand-crafted raw query string here. Upgrading the querybuilder to
/// support multi-field selection sets is on the v0.2 list.
fn fetchArgList(
    allocator: std.mem.Allocator,
    parent: *const Selection,
    arena: std.mem.Allocator,
    client: *GraphQLClient,
) ![]FunctionCallArgValue {
    _ = arena;
    // Build the base query up to currentFunctionCall, then append the
    // multi-field selection set manually.
    const base = try parent.build(allocator);
    defer allocator.free(base);

    // base is like: query{...currentFunctionCall}
    // Replace the terminal `}` we just get with `{inputArgs{name value}}}`.
    if (!std.mem.endsWith(u8, base, "}")) return error.MalformedQuery;
    const trimmed = base[0 .. base.len - 1];

    const query_str = try std.mem.concat(
        allocator,
        u8,
        &.{ trimmed, "{inputArgs{name value}}}" },
    );
    defer allocator.free(query_str);

    const body = try client.query(query_str);
    defer allocator.free(body);

    // Drill down to the inputArgs array.
    const parsed = try std.json.parseFromSlice(std.json.Value, allocator, body, .{});
    defer parsed.deinit();

    var cur = parsed.value.object.get("data") orelse return error.InvalidEnvelope;
    while (true) {
        switch (cur) {
            .object => |o| {
                if (o.get("inputArgs")) |ia| {
                    cur = ia;
                    break;
                }
                if (o.count() != 1) return error.InvalidEnvelope;
                var it = o.iterator();
                const entry = it.next() orelse return error.InvalidEnvelope;
                cur = entry.value_ptr.*;
            },
            else => return error.InvalidEnvelope,
        }
    }

    const arr = switch (cur) {
        .array => |a| a,
        else => return error.InvalidEnvelope,
    };

    const out = try allocator.alloc(FunctionCallArgValue, arr.items.len);
    errdefer allocator.free(out);

    var filled: usize = 0;
    errdefer {
        var i: usize = 0;
        while (i < filled) : (i += 1) out[i].deinit();
    }

    for (arr.items, 0..) |item, i| {
        const obj = switch (item) {
            .object => |o| o,
            else => return error.InvalidEnvelope,
        };
        const name_v = obj.get("name") orelse return error.InvalidEnvelope;
        const value_v = obj.get("value") orelse return error.InvalidEnvelope;

        const name_s = switch (name_v) {
            .string => |s| s,
            else => return error.InvalidEnvelope,
        };
        // value is itself a JSON-encoded scalar string; keep as raw JSON for serde.
        const value_s = switch (value_v) {
            .string => |s| s,
            else => return error.InvalidEnvelope,
        };

        out[i] = .{
            .name = try allocator.dupe(u8, name_s),
            .value_json = try allocator.dupe(u8, value_s),
            .allocator = allocator,
        };
        filled = i + 1;
    }
    return out;
}
