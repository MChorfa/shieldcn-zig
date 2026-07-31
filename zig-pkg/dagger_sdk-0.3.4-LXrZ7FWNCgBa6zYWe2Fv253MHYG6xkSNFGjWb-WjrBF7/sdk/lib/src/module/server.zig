//! `serve` — the module runtime entry point.
//!
//! Protocol (from the Dagger engine's perspective):
//!
//!   1. Engine spawns the module binary with DAGGER_SESSION_PORT +
//!      DAGGER_SESSION_TOKEN set. We are the client in this session; the
//!      engine is serving its GraphQL API for us to query.
//!   2. Module connects to the engine via `dagger.connect`.
//!   3. Module queries `currentFunctionCall` to learn why it was invoked:
//!        - name == ""  → introspection mode: return the schema.
//!        - name != ""  → dispatch mode: run the named function.
//!   4. Module writes the result back via `currentFunctionCall.returnValue`.
//!   5. Module exits.
//!
//! All errors during dispatch surface as GraphQL errors the engine relays
//! to the caller of `dagger call`. Errors during introspection fail the
//! module load and prevent any invocations.

const std = @import("std");
const dagger = @import("../root.zig");
const qb = @import("../querybuilder.zig");
const dispatch = @import("dispatch.zig");
const td_mod = @import("typedef.zig");
const serde = @import("serde.zig");
const Context = @import("context.zig").Context;
const module_api = @import("../module_api.zig");

pub const ServeError = error{
    NotInvokedByEngine,
    UnknownFunction,
    BadArgs,
    SchemaRegistrationFailed,
} || anyerror;

/// Serve the given module instance for one engine invocation.
pub fn serve(init: std.process.Init, module_instance: anytype) ServeError!void {
    const M = @TypeOf(module_instance);
    const table = comptime dispatch.build(M);

    // Comptime check: at least one eligible method, or the module is useless.
    if (comptime table.len == 0) {
        @compileError("dagger-zig: module type `" ++ @typeName(M) ++
            "` has no eligible methods. A module method must be `pub fn name(self: *const Self, ctx: *Context, ...)`.");
    }

    const gpa = init.gpa;
    const io = init.io;

    // Connect to the engine. If the env vars aren't set, we aren't being
    // invoked by the engine — report and exit.
    var client = dagger.connect(gpa, io, .{}) catch |e| switch (e) {
        error.InvalidEnv => return error.NotInvokedByEngine,
        else => return e,
    };
    defer client.close();

    // Per-dispatch arena — everything we allocate while handling THIS
    // invocation goes here and is freed on return.
    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var ctx: Context = .{
        .client = &client,
        .arena = arena,
        .io = io,
        .spiffe_source = null,
    };

    const mq = module_api.moduleQuery(client.dag());
    const call = mq.currentFunctionCall() catch |err| {
        std.debug.print("dagger-zig: currentFunctionCall failed: {s}\n", .{@errorName(err)});
        return err;
    };
    const parent_name = call.parentName() catch |err| {
        std.debug.print("dagger-zig: parentName query failed: {s}\n", .{@errorName(err)});
        return err;
    };
    defer gpa.free(parent_name);

    if (parent_name.len == 0) {
        runIntrospection(M, &ctx, &call, table) catch |err| {
            const msg = try std.fmt.allocPrint(arena, "introspection failed: {s}", .{@errorName(err)});
            const engine_error = try mq.newEngineError(msg);
            _ = call.returnError(engine_error) catch {};
            return err;
        };
        return;
    }

    const fn_name = call.name() catch |err| {
        std.debug.print("dagger-zig: name query failed: {s}\n", .{@errorName(err)});
        return err;
    };
    defer gpa.free(fn_name);

    return runDispatch(M, &module_instance, &ctx, &call, fn_name, table);
}

// ─────────────────────────── introspection ──────────────────────────────

/// Build the module's schema and return it as a module ID.
///
/// The Dagger schema builder API wires object references together by ID.
/// We therefore construct TypeDefs first, then Functions, then the module
/// object itself.
fn runIntrospection(
    comptime M: type,
    ctx: *Context,
    call: *const module_api.FunctionCall,
    table: []const dispatch.Entry(M),
) !void {
    const module_name = try resolveModuleName(M, ctx);
    const object_id = try buildModuleObjectID(M, ctx, table, module_name);
    var module = try qb.Selection.root.select(ctx.arena, "module");
    module = try module.select(ctx.arena, "withObject");
    module = try module.arg(ctx.arena, "object", .{
        .eager = try qb.serializeString(ctx.arena, object_id),
    });

    const id = try executeLeafString(ctx, try module.select(ctx.arena, "id"));

    // Now hand the ID back to the engine via returnValue.
    const id_json = try std.fmt.allocPrint(ctx.arena, "\"{s}\"", .{id});
    try call.returnValue(id_json);
}

fn buildModuleObjectID(
    comptime M: type,
    ctx: *Context,
    table: []const dispatch.Entry(M),
    object_name: []const u8,
) ![]const u8 {
    var object_sel = try newTypeDefSelection(ctx.arena);
    object_sel = try withObjectSelection(object_sel, ctx.arena, object_name);

    for (table) |entry| {
        const function_id = try buildFunctionID(ctx, entry.def);
        object_sel = try object_sel.select(ctx.arena, "withFunction");
        object_sel = try object_sel.arg(ctx.arena, "function", .{
            .eager = try qb.serializeString(ctx.arena, function_id),
        });
    }

    const object_type_id = try executeLeafString(ctx, try object_sel.select(ctx.arena, "id"));
    const constructor_id = try buildConstructorID(ctx, object_name, object_type_id);
    object_sel = try withConstructorSelection(object_sel, ctx.arena, constructor_id);

    return executeLeafString(ctx, try object_sel.select(ctx.arena, "id"));
}

fn buildConstructorID(
    ctx: *Context,
    name: []const u8,
    return_type_id: []const u8,
) ![]const u8 {
    const function_sel = try newFunctionSelection(ctx.arena, name, return_type_id);
    return executeLeafString(ctx, try function_sel.select(ctx.arena, "id"));
}

fn buildFunctionID(
    ctx: *Context,
    def: td_mod.FunctionDef,
) ![]const u8 {
    const return_type_id = try buildTypeDefID(ctx, def.return_type);
    var function_sel = try newFunctionSelection(ctx.arena, def.name, return_type_id);

    for (def.args) |arg| {
        const arg_type_id = try buildTypeDefID(ctx, arg.type_def);
        function_sel = try withFunctionArgSelection(function_sel, ctx.arena, arg.name, arg_type_id);
    }

    return executeLeafString(ctx, try function_sel.select(ctx.arena, "id"));
}

fn buildTypeDefID(
    ctx: *Context,
    def: td_mod.TypeDef,
) ![]const u8 {
    var type_sel = try newTypeDefSelection(ctx.arena);

    switch (def.kind) {
        .string, .integer, .boolean, .void_kind => {
            type_sel = try withKindSelection(type_sel, ctx.arena, def.kind);
        },
        .list => {
            const element_id = try buildTypeDefID(ctx, def.element.?.*);
            type_sel = try withListSelection(type_sel, ctx.arena, element_id);
        },
        .object => {
            type_sel = try withObjectSelection(type_sel, ctx.arena, def.object_name.?);
            // User-defined objects carry field definitions that the engine
            // needs to register so callers can query individual fields.
            if (def.object_def) |obj_def| {
                for (obj_def.fields) |f| {
                    const field_type_id = try buildTypeDefID(ctx, f.type_def);
                    type_sel = try withFieldSelection(type_sel, ctx.arena, f.name, field_type_id);
                }
            }
        },
        .input => {
            type_sel = try withInputSelection(type_sel, ctx.arena, def.input.?.name);
            for (def.input.?.fields) |f| {
                const field_type_id = try buildTypeDefID(ctx, f.type_def);
                type_sel = try withFieldSelection(type_sel, ctx.arena, f.name, field_type_id);
            }
        },
        .enum_kind => {
            type_sel = try withEnumSelection(type_sel, ctx.arena, def.enum_def.?.name);
            for (def.enum_def.?.values) |v| {
                type_sel = try withEnumMemberSelection(type_sel, ctx.arena, v);
            }
        },
    }

    if (def.optional) type_sel = try withOptionalSelection(type_sel, ctx.arena);

    return executeLeafString(ctx, try type_sel.select(ctx.arena, "id"));
}

fn newTypeDefSelection(arena: std.mem.Allocator) !*qb.Selection {
    return qb.Selection.root.select(arena, "typeDef");
}

fn withKindSelection(
    selection: *qb.Selection,
    arena: std.mem.Allocator,
    kind: td_mod.Kind,
) !*qb.Selection {
    var sel = try selection.select(arena, "withKind");
    sel = try sel.arg(arena, "kind", .{ .eager = kind.graphqlName() });
    return sel;
}

fn withListSelection(
    selection: *qb.Selection,
    arena: std.mem.Allocator,
    element_type_id: []const u8,
) !*qb.Selection {
    var sel = try selection.select(arena, "withListOf");
    sel = try sel.arg(arena, "elementType", .{
        .eager = try qb.serializeString(arena, element_type_id),
    });
    return sel;
}

fn withObjectSelection(
    selection: *qb.Selection,
    arena: std.mem.Allocator,
    name: []const u8,
) !*qb.Selection {
    var sel = try selection.select(arena, "withObject");
    sel = try sel.argStr(arena, "name", name);
    return sel;
}

fn withInputSelection(
    selection: *qb.Selection,
    arena: std.mem.Allocator,
    name: []const u8,
) !*qb.Selection {
    var sel = try selection.select(arena, "withInput");
    sel = try sel.argStr(arena, "name", name);
    return sel;
}

fn withFieldSelection(
    selection: *qb.Selection,
    arena: std.mem.Allocator,
    name: []const u8,
    type_id: []const u8,
) !*qb.Selection {
    var sel = try selection.select(arena, "withField");
    sel = try sel.argStr(arena, "name", name);
    sel = try sel.arg(arena, "typeDef", .{ .eager = try qb.serializeString(arena, type_id) });
    return sel;
}

fn withEnumSelection(
    selection: *qb.Selection,
    arena: std.mem.Allocator,
    name: []const u8,
) !*qb.Selection {
    var sel = try selection.select(arena, "withEnum");
    sel = try sel.argStr(arena, "name", name);
    return sel;
}

fn withEnumMemberSelection(
    selection: *qb.Selection,
    arena: std.mem.Allocator,
    name: []const u8,
) !*qb.Selection {
    var sel = try selection.select(arena, "withEnumMember");
    sel = try sel.argStr(arena, "name", name);
    return sel;
}

fn withOptionalSelection(
    selection: *qb.Selection,
    arena: std.mem.Allocator,
) !*qb.Selection {
    var sel = try selection.select(arena, "withOptional");
    sel = try sel.arg(arena, "optional", .{ .eager = "true" });
    return sel;
}

fn newFunctionSelection(
    arena: std.mem.Allocator,
    name: []const u8,
    return_type_id: []const u8,
) !*qb.Selection {
    var sel = try qb.Selection.root.select(arena, "function");
    sel = try sel.argStr(arena, "name", name);
    sel = try sel.arg(arena, "returnType", .{
        .eager = try qb.serializeString(arena, return_type_id),
    });
    return sel;
}

fn withFunctionArgSelection(
    selection: *qb.Selection,
    arena: std.mem.Allocator,
    name: []const u8,
    type_id: []const u8,
) !*qb.Selection {
    var sel = try selection.select(arena, "withArg");
    sel = try sel.argStr(arena, "name", name);
    sel = try sel.arg(arena, "typeDef", .{ .eager = try qb.serializeString(arena, type_id) });
    return sel;
}

fn withConstructorSelection(
    selection: *qb.Selection,
    arena: std.mem.Allocator,
    function_id: []const u8,
) !*qb.Selection {
    var sel = try selection.select(arena, "withConstructor");
    sel = try sel.arg(arena, "function", .{
        .eager = try qb.serializeString(arena, function_id),
    });
    return sel;
}

fn executeLeafString(ctx: *Context, selection: *const qb.Selection) ![]const u8 {
    const query_str = try selection.build(ctx.arena);
    const body = try ctx.client.gql.query(query_str);
    defer ctx.client.allocator.free(body);

    const parsed = try std.json.parseFromSlice(std.json.Value, ctx.arena, body, .{});
    defer parsed.deinit();

    if (parsed.value.object.get("errors")) |errs_val| {
        if (errs_val == .array and errs_val.array.items.len > 0) {
            const first = errs_val.array.items[0];
            if (first == .object) {
                if (first.object.get("message")) |msg_val| {
                    if (msg_val == .string) {
                        std.debug.print("dagger-zig: graphql error: {s}\n", .{msg_val.string});
                    }
                }
            }
        }
    }

    const root = parsed.value.object.get("data") orelse return error.SchemaRegistrationFailed;
    return walkToString(root) orelse error.SchemaRegistrationFailed;
}

fn resolveModuleName(comptime M: type, ctx: *Context) ![]const u8 {
    var current_module = try qb.Selection.root.select(ctx.arena, "currentModule");
    const current_name = executeLeafString(ctx, try current_module.select(ctx.arena, "name")) catch null;
    if (current_name) |name| {
        if (name.len != 0) return name;
    }

    return shortTypeName(M);
}

fn resolveModuleEngineVersion(ctx: *Context) ![]const u8 {
    var module_source = try qb.Selection.root.select(ctx.arena, "moduleSource");
    module_source = try module_source.argStr(ctx.arena, "refString", ".");
    return executeLeafString(ctx, try module_source.select(ctx.arena, "engineVersion")) catch "";
}

fn resolveModuleSDKSource(ctx: *Context) ![]const u8 {
    var module_source = try qb.Selection.root.select(ctx.arena, "moduleSource");
    module_source = try module_source.argStr(ctx.arena, "refString", ".");

    const sdk = try module_source.select(ctx.arena, "sdk");
    return executeLeafString(ctx, try sdk.select(ctx.arena, "source")) catch "";
}

fn resolveModuleSourceSubpath(ctx: *Context) ![]const u8 {
    var module_source = try qb.Selection.root.select(ctx.arena, "moduleSource");
    module_source = try module_source.argStr(ctx.arena, "refString", ".");
    return executeLeafString(ctx, try module_source.select(ctx.arena, "sourceSubpath")) catch "";
}

fn shortTypeName(comptime T: type) []const u8 {
    const full = @typeName(T);
    if (std.mem.lastIndexOfScalar(u8, full, '.')) |index| return full[index + 1 ..];
    return full;
}

fn walkToString(v: std.json.Value) ?[]const u8 {
    return switch (v) {
        .string => |s| s,
        .object => |o| blk: {
            if (o.count() != 1) break :blk null;
            var it = o.iterator();
            const entry = it.next() orelse break :blk null;
            break :blk walkToString(entry.value_ptr.*);
        },
        else => null,
    };
}

// ─────────────────────────── dispatch ───────────────────────────────────

fn runDispatch(
    comptime M: type,
    module_instance: *const M,
    ctx: *Context,
    call: *const module_api.FunctionCall,
    fn_name: []const u8,
    table: []const dispatch.Entry(M),
) !void {
    if (fn_name.len == 0) {
        return runConstructor(module_instance, ctx, call);
    }

    // Find the entry for this function.
    const entry = for (table) |e| {
        if (std.mem.eql(u8, e.name, fn_name)) break e;
    } else {
        return error.UnknownFunction;
    };

    // Collect args into a single JSON object the serde layer can parse.
    const args_json = try assembleArgsJson(ctx.arena, call);

    // Build a Zig-stdlib writer we can pass into the shim for the return.
    // We use an ArrayList-backed writer; the final bytes become the JSON we
    // pass to returnValue().
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(ctx.arena);

    var aw: std.Io.Writer.Allocating = .fromArrayList(ctx.arena, &buf);
    entry.invoke(module_instance, ctx, args_json, &aw.writer) catch |e| {
        const engine_error = try module_api.moduleQuery(ctx.client.dag()).newEngineError(@errorName(e));
        try call.returnError(engine_error);
        return e;
    };
    buf = aw.toArrayList();

    try call.returnValue(buf.items);
}

fn runConstructor(
    module_instance: anytype,
    ctx: *Context,
    call: *const module_api.FunctionCall,
) !void {
    std.debug.print("dagger-zig: constructor dispatch start\n", .{});

    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(ctx.arena);

    var aw: std.Io.Writer.Allocating = .fromArrayList(ctx.arena, &buf);
    serde.serializeReturn(@TypeOf(module_instance.*), module_instance.*, &aw.writer) catch |err| {
        std.debug.print("dagger-zig: constructor serializeReturn failed: {s}\n", .{@errorName(err)});
        const msg = try std.fmt.allocPrint(ctx.arena, "constructor serializeReturn failed: {s}", .{@errorName(err)});
        const engine_error = try module_api.moduleQuery(ctx.client.dag()).newEngineError(msg);
        try call.returnError(engine_error);
        return err;
    };
    buf = aw.toArrayList();

    std.debug.print("dagger-zig: constructor return payload bytes={d}\n", .{buf.items.len});
    call.returnValue(buf.items) catch |err| {
        std.debug.print("dagger-zig: constructor returnValue failed: {s}\n", .{@errorName(err)});
        const msg = try std.fmt.allocPrint(ctx.arena, "constructor returnValue failed: {s}", .{@errorName(err)});
        const engine_error = try module_api.moduleQuery(ctx.client.dag()).newEngineError(msg);
        try call.returnError(engine_error);
        return err;
    };
}

/// Pull every inputArg from the FunctionCall and stitch them into a single
/// JSON object: `{"arg0": <value_json>, "arg1": <value_json>, ...}`.
/// Matches the arg-name convention the comptime shim uses in dispatch.zig.
fn assembleArgsJson(
    a: std.mem.Allocator,
    call: *const module_api.FunctionCall,
) ![]const u8 {
    const args = try call.inputArgs();
    defer {
        for (args) |*arg| arg.deinit();
        a.free(args);
    }

    var buf: std.ArrayList(u8) = .empty;
    errdefer buf.deinit(a);

    try buf.append(a, '{');
    for (args, 0..) |arg, i| {
        if (i > 0) try buf.append(a, ',');
        var name_aw: std.Io.Writer.Allocating = .fromArrayList(a, &buf);
        try std.json.Stringify.value(arg.name, .{}, &name_aw.writer);
        buf = name_aw.toArrayList();
        try buf.append(a, ':');
        // arg.value_json is already a JSON literal; copy verbatim.
        try buf.appendSlice(a, arg.value_json);
    }
    try buf.append(a, '}');
    return buf.toOwnedSlice(a);
}

// ─────────────────────────── tests ──────────────────────────────────────

const testing = std.testing;

test "comptime: module with no eligible methods fails to compile" {
    // We can't actually @compileError-check in a test, but we can verify
    // that a well-formed module passes the dispatch build. The negative
    // case is covered at compile time by the @compileError in serve().
    const OK = struct {
        pub fn run(self: *const @This(), ctx: *Context) !void {
            _ = self;
            _ = ctx;
        }
    };
    const table = comptime dispatch.build(OK);
    try testing.expectEqual(@as(usize, 1), table.len);
    try testing.expectEqualStrings("run", table[0].name);
}

test "newTypeDefSelection emits expected fragments" {
    const a = testing.allocator;
    var scalar_sel = try newTypeDefSelection(a);
    scalar_sel = try withKindSelection(scalar_sel, a, .string);
    const scalar_query = try (try scalar_sel.select(a, "id")).build(a);
    defer a.free(scalar_query);
    try testing.expectEqualStrings("query{typeDef{withKind(kind:STRING_KIND){id}}}", scalar_query);

    var optional_sel = try newTypeDefSelection(a);
    optional_sel = try withKindSelection(optional_sel, a, .boolean);
    optional_sel = try withOptionalSelection(optional_sel, a);
    const optional_query = try (try optional_sel.select(a, "id")).build(a);
    defer a.free(optional_query);
    try testing.expectEqualStrings(
        "query{typeDef{withKind(kind:BOOLEAN_KIND){withOptional(optional:true){id}}}}",
        optional_query,
    );

    var object_sel = try newTypeDefSelection(a);
    object_sel = try withObjectSelection(object_sel, a, "Container");
    const object_query = try (try object_sel.select(a, "id")).build(a);
    defer a.free(object_query);
    try testing.expectEqualStrings(
        "query{typeDef{withObject(name:\"Container\"){id}}}",
        object_query,
    );

    var list_sel = try newTypeDefSelection(a);
    list_sel = try withListSelection(list_sel, a, "typedef-id");
    const list_query = try (try list_sel.select(a, "id")).build(a);
    defer a.free(list_query);
    try testing.expectEqualStrings(
        "query{typeDef{withListOf(elementType:\"typedef-id\"){id}}}",
        list_query,
    );
}

test "newFunctionSelection emits function + withArg chain" {
    const a = testing.allocator;
    var function_sel = try newFunctionSelection(a, "build", "return-id");
    function_sel = try withFunctionArgSelection(function_sel, a, "target", "string-id");
    function_sel = try withFunctionArgSelection(function_sel, a, "parallelism", "integer-id");

    const function_query = try (try function_sel.select(a, "id")).build(a);
    defer a.free(function_query);
    try testing.expectEqualStrings(
        "query{function(name:\"build\", returnType:\"return-id\"){withArg(name:\"target\", typeDef:\"string-id\"){withArg(name:\"parallelism\", typeDef:\"integer-id\"){id}}}}",
        function_query,
    );
}
