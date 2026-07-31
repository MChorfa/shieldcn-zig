//! Zig type → Dagger TypeDef mapping.
//!
//! At module registration time, the engine asks our module "what are your
//! functions, and what are their signatures?" We answer with a tree of
//! TypeDef values — the Dagger IR for types.
//!
//! This file converts a Zig type, known at comptime, into a TypeDef
//! (runtime value). The mapping is:
//!
//!   Zig                            Dagger TypeDef
//!   ────────────────────────────   ────────────────────
//!   void                           VOID_KIND
//!   bool                           BOOLEAN_KIND
//!   iN / uN  (any int)             INTEGER_KIND
//!   f32 / f64                      (not yet — Dagger has no FLOAT_KIND)
//!   []const u8                     STRING_KIND
//!   []T                            LIST_KIND of T
//!   ?T                             T with optional=true
//!   api.Container / .Directory /   OBJECT_KIND with name
//!     .File / .Secret / .Service /
//!     .CacheVolume
//!   user struct                    INPUT_KIND with fields (when arg) /
//!                                  OBJECT_KIND (when return)
//!   user enum                      ENUM_KIND with values
//!   anyerror!T                     T (errors are out-of-band in Dagger)
//!
//! All mapping happens at comptime. A type that can't be mapped produces
//! a comptime error with a clear message pointing at the offending field.

const std = @import("std");
const api = @import("../gen.zig");

/// Tag matching Dagger's GraphQL TypeDefKind enum.
pub const Kind = enum {
    string,
    integer,
    boolean,
    void_kind,
    list,
    object, // Dagger-native object (Container, Directory, etc.)
    input, // user-defined struct, as a function argument
    enum_kind,

    pub fn graphqlName(self: Kind) []const u8 {
        return switch (self) {
            .string => "STRING_KIND",
            .integer => "INTEGER_KIND",
            .boolean => "BOOLEAN_KIND",
            .void_kind => "VOID_KIND",
            .list => "LIST_KIND",
            .object => "OBJECT_KIND",
            .input => "INPUT_KIND",
            .enum_kind => "ENUM_KIND",
        };
    }
};

/// A runtime representation of a Dagger TypeDef. All strings are static
/// (either string literals or interned comptime-generated names), so
/// there's no deinit to run.
pub const TypeDef = struct {
    kind: Kind,
    optional: bool = false,

    // Populated based on `kind`:
    /// Set for .list — the element type.
    element: ?*const TypeDef = null,
    /// Set for .object — the Dagger object name (e.g. "Container").
    object_name: ?[]const u8 = null,
    /// Set for .object when it's a user-defined object (not a Dagger-native
    /// handle). Carries the field definitions the engine needs to register.
    object_def: ?ObjectDef = null,
    /// Set for .input — the user struct's name + field list.
    input: ?InputDef = null,
    /// Set for .enum_kind — enum name + values.
    enum_def: ?EnumDef = null,

    pub const InputDef = struct {
        name: []const u8,
        fields: []const FieldDef,
    };

    pub const ObjectDef = struct {
        name: []const u8,
        fields: []const FieldDef,
    };

    pub const FieldDef = struct {
        name: []const u8,
        type_def: TypeDef,
        description: []const u8 = "",
        default_json: ?[]const u8 = null, // pre-serialised JSON literal
    };

    pub const EnumDef = struct {
        name: []const u8,
        values: []const []const u8,
    };
};

/// Comptime: map a Zig type to a Dagger TypeDef.
/// Fails at comptime with a clear @compileError on unmapped types.
pub fn ofZig(comptime T: type) TypeDef {
    return ofZigInContext(T, .asArg);
}

/// Like ofZig, but maps user structs as OBJECT_KIND (with fields) instead
/// of INPUT_KIND. Use this for function return types so the engine
/// registers the struct as a queryable object.
pub fn ofZigAsReturn(comptime T: type) TypeDef {
    return ofZigInContext(T, .asReturn);
}

const StructContext = enum { asArg, asReturn };

fn ofZigInContext(comptime T: type, comptime ctx: StructContext) TypeDef {
    const info = @typeInfo(T);
    return switch (info) {
        .void => .{ .kind = .void_kind },

        .bool => .{ .kind = .boolean },

        .int => .{ .kind = .integer },

        .optional => |opt| blk: {
            var inner = ofZigInContext(opt.child, ctx);
            inner.optional = true;
            break :blk inner;
        },

        // Special-case []const u8 as STRING — the most common case.
        // Other slices fall through to LIST.
        .pointer => |ptr| pointerMapping(T, ptr),

        .array => |arr| blk: {
            const elem_def = comptime blk2: {
                const ed = ofZigInContext(arr.child, ctx);
                break :blk2 ed;
            };
            break :blk .{
                .kind = .list,
                .element = &elem_def,
            };
        },

        .@"struct" => mapStruct(T, ctx),

        .@"enum" => mapEnum(T),

        .error_union => |eu| ofZigInContext(eu.payload, ctx),

        else => @compileError("dagger-zig: cannot map Zig type `" ++ @typeName(T) ++
            "` to a Dagger TypeDef. Supported: void, bool, integers, []const u8, " ++
            "slices, arrays, optionals, Dagger API types, and user structs/enums."),
    };
}

fn pointerMapping(comptime T: type, comptime ptr: std.builtin.Type.Pointer) TypeDef {
    // `[]const u8` → STRING
    if (ptr.size == .slice and ptr.child == u8 and ptr.is_const) {
        return .{ .kind = .string };
    }
    // Other slices → LIST<element>
    if (ptr.size == .slice) {
        const elem_def = comptime ofZig(ptr.child);
        return .{
            .kind = .list,
            .element = &elem_def,
        };
    }
    // Single-item pointers to Dagger objects (e.g. *Container) should be
    // passed by value in user function signatures; we don't support them.
    @compileError("dagger-zig: single-item pointer type `" ++ @typeName(T) ++
        "` is not supported as a module argument. Pass by value.");
}

fn mapStruct(comptime T: type, comptime ctx: StructContext) TypeDef {
    // Is this one of the Dagger API handles? If so, it's an OBJECT_KIND.
    if (T == api.Container) return .{ .kind = .object, .object_name = "Container" };
    if (T == api.Directory) return .{ .kind = .object, .object_name = "Directory" };
    if (T == api.File) return .{ .kind = .object, .object_name = "File" };
    if (T == api.Secret) return .{ .kind = .object, .object_name = "Secret" };
    if (T == api.CacheVolume) return .{ .kind = .object, .object_name = "CacheVolume" };
    if (T == api.Service) return .{ .kind = .object, .object_name = "Service" };
    if (T == api.Socket) return .{ .kind = .object, .object_name = "Socket" };
    if (T == api.GitRef) return .{ .kind = .object, .object_name = "GitRef" };
    if (T == api.GitRepository) return .{ .kind = .object, .object_name = "GitRepository" };
    if (T == api.Host) return .{ .kind = .object, .object_name = "Host" };

    // User-defined struct. When used as a return type, register it as
    // OBJECT_KIND so the engine creates a queryable GraphQL object. When
    // used as an argument, register it as INPUT_KIND.
    const info = @typeInfo(T).@"struct";
    comptime var fields: [info.fields.len]TypeDef.FieldDef = undefined;
    comptime {
        for (info.fields, 0..) |f, i| {
            fields[i] = .{
                .name = f.name,
                .type_def = ofZigInContext(f.type, ctx),
                .default_json = extractDefaultJson(T, f),
            };
        }
    }
    const fields_const = fields;
    const name = shortTypeName(T);

    if (ctx == .asReturn) {
        return .{
            .kind = .object,
            .object_name = name,
            .object_def = .{
                .name = name,
                .fields = &fields_const,
            },
        };
    }

    return .{
        .kind = .input,
        .input = .{
            .name = name,
            .fields = &fields_const,
        },
    };
}

fn mapEnum(comptime T: type) TypeDef {
    const info = @typeInfo(T).@"enum";
    comptime var names: [info.fields.len][]const u8 = undefined;
    comptime {
        for (info.fields, 0..) |f, i| names[i] = f.name;
    }
    const names_const = names;
    return .{
        .kind = .enum_kind,
        .enum_def = .{
            .name = shortTypeName(T),
            .values = &names_const,
        },
    };
}

fn extractDefaultJson(comptime T: type, comptime f: std.builtin.Type.StructField) ?[]const u8 {
    _ = T;
    if (f.default_value_ptr == null) return null;
    // Emit a JSON literal for the default. Keep it simple: handle the
    // common scalar cases that actually appear in Dagger module args.
    const info = @typeInfo(f.type);
    return switch (info) {
        .bool => blk: {
            const ptr: *const bool = @ptrCast(@alignCast(f.default_value_ptr.?));
            break :blk if (ptr.*) "true" else "false";
        },
        .int => blk: {
            const ptr: *const f.type = @ptrCast(@alignCast(f.default_value_ptr.?));
            break :blk std.fmt.comptimePrint("{d}", .{ptr.*});
        },
        else => null, // string and complex defaults: emit manually via description
    };
}

fn shortTypeName(comptime T: type) []const u8 {
    // @typeName returns "root.foo.MyStruct" — trim to the final segment.
    const full = @typeName(T);
    if (std.mem.lastIndexOfScalar(u8, full, '.')) |i| return full[i + 1 ..];
    return full;
}

/// A function's signature as Dagger TypeDefs.
pub const FunctionDef = struct {
    name: []const u8,
    description: []const u8 = "",
    args: []const ArgDef,
    return_type: TypeDef,

    pub const ArgDef = struct {
        name: []const u8,
        type_def: TypeDef,
        description: []const u8 = "",
        optional: bool = false,
        default_json: ?[]const u8 = null,
    };
};

/// Comptime: extract a FunctionDef from a method on a user module type.
///
/// The method MUST have the signature:
///
///   pub fn name(self: *const Self, ctx: *Context, arg1: T1, arg2: T2, ...) !R
///
/// The first parameter (`self`) and second (`ctx: *Context`) are consumed
/// by the dispatcher and don't appear in the Dagger type def.
pub fn functionOfMethod(
    comptime M: type,
    comptime method_name: []const u8,
) FunctionDef {
    const method = @field(M, method_name);
    const fn_info = @typeInfo(@TypeOf(method)).@"fn";

    // Require at least two params: self + ctx.
    if (fn_info.params.len < 2) {
        @compileError("dagger-zig: module method `" ++ method_name ++
            "` must take at least (self, ctx) parameters");
    }

    // param[0] = self: *const M  — we don't validate the exact const-pointer
    // shape because Zig's comptime type info for method receivers is fiddly;
    // the dispatcher validates concretely when it calls via the shim.

    // param[1] = ctx: *Context  — we don't import Context here to avoid a
    // circular import (context.zig imports this file). The shim in
    // dispatch.zig checks the actual type.

    // The remaining parameters are the user-facing args.
    const user_arg_count = fn_info.params.len - 2;
    comptime var args: [user_arg_count]FunctionDef.ArgDef = undefined;
    comptime var i: usize = 0;
    comptime {
        while (i < user_arg_count) : (i += 1) {
            const p = fn_info.params[i + 2];
            if (p.type == null) @compileError("dagger-zig: param " ++
                std.fmt.comptimePrint("{d}", .{i}) ++ " of `" ++
                method_name ++ "` has no type (generic params not supported)");

            const T = p.type.?;
            const is_optional = @typeInfo(T) == .optional;
            var td = ofZig(T);
            td.optional = is_optional;

            // Without runtime param names in zig.Type.Fn.Param, we encode
            // positional names "arg0", "arg1", ... and let the CLI handle
            // them positionally. A future version reads names via build-time
            // source analysis (or Zig exposes param names — proposal open).
            const arg_name = std.fmt.comptimePrint("arg{d}", .{i});
            args[i] = .{
                .name = arg_name,
                .type_def = td,
                .optional = is_optional,
            };
        }
    }
    const args_const = args;

    const ret_type = fn_info.return_type orelse
        @compileError("dagger-zig: method `" ++ method_name ++ "` has no declared return type");
    const ret_def = ofZigAsReturn(ret_type);

    return .{
        .name = method_name,
        .args = &args_const,
        .return_type = ret_def,
    };
}

// ─────────────────────────── tests ──────────────────────────────────────

const testing = std.testing;

test "primitive mappings" {
    try testing.expectEqual(@as(Kind, .void_kind), ofZig(void).kind);
    try testing.expectEqual(@as(Kind, .boolean), ofZig(bool).kind);
    try testing.expectEqual(@as(Kind, .integer), ofZig(i64).kind);
    try testing.expectEqual(@as(Kind, .integer), ofZig(u32).kind);
    try testing.expectEqual(@as(Kind, .string), ofZig([]const u8).kind);
}

test "optional wraps inner type" {
    const td = ofZig(?i64);
    try testing.expectEqual(@as(Kind, .integer), td.kind);
    try testing.expect(td.optional);
}

test "slice becomes list" {
    const td = ofZig([]const i64);
    try testing.expectEqual(@as(Kind, .list), td.kind);
    try testing.expect(td.element != null);
    try testing.expectEqual(@as(Kind, .integer), td.element.?.kind);
}

test "Dagger handle types become object kind" {
    const td = ofZig(api.Container);
    try testing.expectEqual(@as(Kind, .object), td.kind);
    try testing.expectEqualStrings("Container", td.object_name.?);

    const td2 = ofZig(api.Directory);
    try testing.expectEqualStrings("Directory", td2.object_name.?);
}

test "user struct becomes input with field list" {
    const BuildOpts = struct {
        target: []const u8,
        race: bool = false,
        parallelism: u32 = 4,
    };
    const td = ofZig(BuildOpts);
    try testing.expectEqual(@as(Kind, .input), td.kind);
    try testing.expect(td.input != null);
    try testing.expectEqual(@as(usize, 3), td.input.?.fields.len);
    try testing.expectEqualStrings("target", td.input.?.fields[0].name);
    try testing.expectEqualStrings("race", td.input.?.fields[1].name);
    // Default_json extracted where possible.
    try testing.expectEqualStrings("false", td.input.?.fields[1].default_json.?);
    try testing.expectEqualStrings("4", td.input.?.fields[2].default_json.?);
}

test "user struct as return becomes object with field list" {
    const BuildResult = struct {
        image: []const u8,
        digest: []const u8,
        size: u64,
    };
    const td = ofZigAsReturn(BuildResult);
    try testing.expectEqual(@as(Kind, .object), td.kind);
    try testing.expect(td.object_name != null);
    try testing.expectEqualStrings("BuildResult", td.object_name.?);
    try testing.expect(td.object_def != null);
    try testing.expectEqual(@as(usize, 3), td.object_def.?.fields.len);
    try testing.expectEqualStrings("image", td.object_def.?.fields[0].name);
    try testing.expectEqualStrings("digest", td.object_def.?.fields[1].name);
    try testing.expectEqualStrings("size", td.object_def.?.fields[2].name);
}

test "user enum becomes enum_kind" {
    const Stage = enum { build, test_, deploy };
    const td = ofZig(Stage);
    try testing.expectEqual(@as(Kind, .enum_kind), td.kind);
    try testing.expect(td.enum_def != null);
    try testing.expectEqual(@as(usize, 3), td.enum_def.?.values.len);
    try testing.expectEqualStrings("build", td.enum_def.?.values[0]);
    try testing.expectEqualStrings("test_", td.enum_def.?.values[1]);
}

test "error union passes through" {
    const td = ofZig(anyerror![]const u8);
    try testing.expectEqual(@as(Kind, .string), td.kind);
}

test "functionOfMethod extracts args and return" {
    const M = struct {
        pub fn build(self: *const @This(), ctx: *anyopaque, source: []const u8, parallelism: u32) ![]const u8 {
            _ = self;
            _ = ctx;
            _ = source;
            _ = parallelism;
            return "";
        }
    };
    const fd = functionOfMethod(M, "build");
    try testing.expectEqualStrings("build", fd.name);
    try testing.expectEqual(@as(usize, 2), fd.args.len);
    try testing.expectEqual(@as(Kind, .string), fd.args[0].type_def.kind);
    try testing.expectEqual(@as(Kind, .integer), fd.args[1].type_def.kind);
    try testing.expectEqual(@as(Kind, .string), fd.return_type.kind);
}
