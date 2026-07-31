//! JSON ↔ Zig marshalling for module function arguments and return values.
//!
//! The engine serializes everything as JSON when it invokes our module.
//! Opaque handle types (Container, Directory, etc.) arrive as their opaque
//! IDs; we hydrate them into live handle values using the client's query
//! root. Scalar types use direct std.json round-tripping.
//!
//! For return values, it's the mirror: opaque handles must be resolved to
//! their IDs first (which may itself make an engine round-trip), then we
//! emit the ID as the return value. Scalars serialize directly.

const std = @import("std");
const context_mod = @import("context.zig");
const Context = context_mod.Context;
const api = @import("../gen.zig");
const module_api = @import("../module_api.zig");

/// Deserialise argument `arg_name` from `args_json` into a value of type T.
pub fn deserializeArg(
    comptime T: type,
    ctx: *Context,
    args_json: []const u8,
    arg_name: []const u8,
) !T {
    // Parse the full args object once and look up the named field.
    // For v0.1, simple & correct: parse-per-arg. v0.2 can cache the parse.
    const parsed = try std.json.parseFromSlice(std.json.Value, ctx.arena, args_json, .{});
    defer parsed.deinit();

    const obj = switch (parsed.value) {
        .object => |o| o,
        else => return error.MalformedArgs,
    };
    const field_value = obj.get(arg_name) orelse {
        // Optionals default to null; required args are an error.
        if (@typeInfo(T) == .optional) return @as(T, null);
        return error.MissingArg;
    };

    return deserializeJsonValue(T, ctx, field_value);
}

fn deserializeJsonValue(comptime T: type, ctx: *Context, v: std.json.Value) !T {
    const info = @typeInfo(T);
    return switch (info) {
        .bool => switch (v) {
            .bool => |b| b,
            else => error.TypeMismatch,
        },
        .int => switch (v) {
            .integer => |n| @intCast(n),
            else => error.TypeMismatch,
        },
        .float => switch (v) {
            .float => |f| @floatCast(f),
            .integer => |n| @floatFromInt(n),
            else => error.TypeMismatch,
        },
        .optional => |opt| switch (v) {
            .null => null,
            else => @as(T, try deserializeJsonValue(opt.child, ctx, v)),
        },
        .pointer => |ptr| if (ptr.size == .slice and ptr.child == u8 and ptr.is_const) blk: {
            // String
            const s = switch (v) {
                .string => |s| s,
                else => return error.TypeMismatch,
            };
            break :blk try ctx.arena.dupe(u8, s);
        } else if (ptr.size == .slice) blk: {
            // List
            const arr = switch (v) {
                .array => |a| a,
                else => return error.TypeMismatch,
            };
            const out = try ctx.arena.alloc(ptr.child, arr.items.len);
            for (arr.items, 0..) |item, i| {
                out[i] = try deserializeJsonValue(ptr.child, ctx, item);
            }
            break :blk out;
        } else @compileError("dagger-zig: unsupported pointer shape for argument"),
        .@"struct" => deserializeStruct(T, ctx, v),
        .@"enum" => deserializeEnum(T, v),
        .error_union => |eu| try deserializeJsonValue(eu.payload, ctx, v),
        else => @compileError("dagger-zig: unsupported argument type " ++ @typeName(T)),
    };
}

fn deserializeStruct(comptime T: type, ctx: *Context, v: std.json.Value) !T {
    // Dagger handle types arrive as strings (their opaque ID).
    if (T == api.Container) return hydrateHandle(api.Container, ctx, v);
    if (T == api.Directory) return hydrateHandle(api.Directory, ctx, v);
    if (T == api.File) return hydrateHandle(api.File, ctx, v);
    if (T == api.Secret) return hydrateHandle(api.Secret, ctx, v);
    if (T == api.CacheVolume) return hydrateHandle(api.CacheVolume, ctx, v);
    if (T == api.Service) return hydrateHandle(api.Service, ctx, v);
    if (T == api.Socket) return hydrateHandle(api.Socket, ctx, v);
    if (T == api.GitRef) return hydrateHandle(api.GitRef, ctx, v);
    if (T == api.GitRepository) return hydrateHandle(api.GitRepository, ctx, v);
    if (T == api.Host) return hydrateHandle(api.Host, ctx, v);

    // User struct: recurse per field.
    const info = @typeInfo(T).@"struct";
    const obj = switch (v) {
        .object => |o| o,
        else => return error.TypeMismatch,
    };
    var out: T = undefined;
    inline for (info.fields) |f| {
        if (obj.get(f.name)) |fv| {
            @field(out, f.name) = try deserializeJsonValue(f.type, ctx, fv);
        } else if (f.default_value_ptr) |dp| {
            const typed: *const f.type = @ptrCast(@alignCast(dp));
            @field(out, f.name) = typed.*;
        } else if (@typeInfo(f.type) == .optional) {
            @field(out, f.name) = null;
        } else {
            return error.MissingArg;
        }
    }
    return out;
}

fn deserializeEnum(comptime T: type, v: std.json.Value) !T {
    const s = switch (v) {
        .string => |s| s,
        else => return error.TypeMismatch,
    };
    return std.meta.stringToEnum(T, s) orelse error.UnknownEnumValue;
}

/// Hydrate an opaque handle ID (a string) into a live handle by loading it
/// through the client's query root.
fn hydrateHandle(comptime Handle: type, ctx: *Context, v: std.json.Value) !Handle {
    const id_str = switch (v) {
        .string => |s| s,
        else => return error.TypeMismatch,
    };

    const mq = module_api.moduleQuery(ctx.dag());
    if (Handle == api.Container) return mq.loadContainerFromID(id_str);
    if (Handle == api.Directory) return mq.loadDirectoryFromID(id_str);
    if (Handle == api.File) return mq.loadFileFromID(id_str);
    if (Handle == api.Secret) return mq.loadSecretFromID(id_str);
    if (Handle == api.CacheVolume) return mq.loadCacheVolumeFromID(id_str);
    if (Handle == api.Service) return mq.loadServiceFromID(id_str);
    if (Handle == api.Socket) return mq.loadSocketFromID(id_str);
    if (Handle == api.GitRef) return mq.loadGitRefFromID(id_str);
    if (Handle == api.GitRepository) return mq.loadGitRepositoryFromID(id_str);
    if (Handle == api.Host) return mq.loadHostFromID(id_str);

    @compileError("dagger-zig: unknown handle type " ++ @typeName(Handle));
}

/// Serialise a return value as the JSON payload of the response.
pub fn serializeReturn(comptime T: type, value: T, w: *std.Io.Writer) !void {
    try serializeJsonValue(T, value, w);
}

fn serializeJsonValue(comptime T: type, value: T, w: *std.Io.Writer) !void {
    const info = @typeInfo(T);
    switch (info) {
        .void => try w.writeAll("null"),
        .bool => try w.writeAll(if (value) "true" else "false"),
        .int => try w.print("{d}", .{value}),
        .float => try w.print("{d}", .{value}),
        .optional => if (value) |v| try serializeJsonValue(@TypeOf(v), v, w) else try w.writeAll("null"),
        .pointer => |ptr| if (ptr.size == .slice and ptr.child == u8 and ptr.is_const) {
            try std.json.Stringify.value(value, .{}, w);
        } else if (ptr.size == .slice) {
            try w.writeAll("[");
            for (value, 0..) |item, i| {
                if (i > 0) try w.writeAll(",");
                try serializeJsonValue(ptr.child, item, w);
            }
            try w.writeAll("]");
        } else @compileError("dagger-zig: unsupported pointer shape in return"),
        .@"struct" => try serializeStruct(T, value, w),
        .@"enum" => {
            try w.writeAll("\"");
            try w.writeAll(@tagName(value));
            try w.writeAll("\"");
        },
        .error_union => @compileError("dagger-zig: error_union reached serializer; unwrap before calling"),
        else => @compileError("dagger-zig: unsupported return type " ++ @typeName(T)),
    }
}

fn serializeStruct(comptime T: type, value: T, w: *std.Io.Writer) !void {
    // Dagger handle types: emit their ID.
    if (comptime isDaggerHandle(T)) {
        var v = value;
        const id = try v.id();
        try std.json.Stringify.value(id.value, .{}, w);
        return;
    }

    // User struct: emit as JSON object.
    const info = @typeInfo(T).@"struct";
    try w.writeAll("{");
    inline for (info.fields, 0..) |f, i| {
        if (i > 0) try w.writeAll(",");
        try std.json.Stringify.value(f.name, .{}, w);
        try w.writeAll(":");
        try serializeJsonValue(f.type, @field(value, f.name), w);
    }
    try w.writeAll("}");
}

/// Returns true if T is one of the Dagger API handle structs.
fn isDaggerHandle(comptime T: type) bool {
    return T == api.Container or
        T == api.Directory or
        T == api.File or
        T == api.Secret or
        T == api.CacheVolume or
        T == api.Service or
        T == api.Socket or
        T == api.GitRef or
        T == api.GitRepository or
        T == api.Host;
}

// ─────────────────────────── tests ──────────────────────────────────────

const testing = std.testing;

test "deserialize primitive scalars from json value" {
    // Build a per-dispatch context by hand.
    var io_impl: std.Io.Threaded = .init(std.testing.allocator);
    defer io_impl.deinit();
    const io = io_impl.io();

    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();

    // We don't need a real client for deserialiseJsonValue on scalars.
    var ctx: Context = .{
        .client = undefined,
        .arena = arena_state.allocator(),
        .io = io,
    };

    // bool
    const t = try deserializeJsonValue(bool, &ctx, .{ .bool = true });
    try testing.expect(t);

    // int
    const n = try deserializeJsonValue(i64, &ctx, .{ .integer = 42 });
    try testing.expectEqual(@as(i64, 42), n);

    // string (goes through arena)
    const s = try deserializeJsonValue([]const u8, &ctx, .{ .string = "hello" });
    try testing.expectEqualStrings("hello", s);

    // optional null
    const opt_null = try deserializeJsonValue(?i64, &ctx, .null);
    try testing.expect(opt_null == null);

    // optional present
    const opt_val = try deserializeJsonValue(?i64, &ctx, .{ .integer = 7 });
    try testing.expectEqual(@as(?i64, 7), opt_val);
}

test "deserialize user struct with defaults" {
    const BuildOpts = struct {
        target: []const u8,
        race: bool = false,
        parallelism: u32 = 4,
    };

    var io_impl: std.Io.Threaded = .init(std.testing.allocator);
    defer io_impl.deinit();
    const io = io_impl.io();
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    var ctx: Context = .{
        .client = undefined,
        .arena = arena_state.allocator(),
        .io = io,
    };

    // Parse a partial JSON — target only; defaults fill the rest.
    const parsed = try std.json.parseFromSlice(
        std.json.Value,
        testing.allocator,
        "{\"target\":\"linux\"}",
        .{},
    );
    defer parsed.deinit();

    const v = try deserializeStruct(BuildOpts, &ctx, parsed.value);
    try testing.expectEqualStrings("linux", v.target);
    try testing.expectEqual(false, v.race);
    try testing.expectEqual(@as(u32, 4), v.parallelism);
}

test "deserialize enum from string" {
    const Stage = enum { build, test_, deploy };

    var io_impl: std.Io.Threaded = .init(std.testing.allocator);
    defer io_impl.deinit();
    const io = io_impl.io();
    _ = io;

    try testing.expectEqual(Stage.build, try deserializeEnum(Stage, .{ .string = "build" }));
    try testing.expectEqual(Stage.test_, try deserializeEnum(Stage, .{ .string = "test_" }));
    try testing.expectError(
        error.UnknownEnumValue,
        deserializeEnum(Stage, .{ .string = "bogus" }),
    );
}
