//! Comptime dispatch table.
//!
//! For each public method on the user's module struct, we generate:
//!   (a) a FunctionDef describing its signature (→ typedef.zig)
//!   (b) an "invoker shim" — a specialised fn pointer that knows how to
//!       deserialise that specific method's args from JSON, call the method,
//!       and serialise the return value.
//!
//! The set of (name, FunctionDef, invoker) is the dispatch table. When the
//! engine invokes us with `fn_name="build", args_json="..."`, we look up
//! the entry by name and call its invoker.
//!
//! Why specialised shims instead of one generic dispatcher?
//!
//!   1. Zero-cost abstraction. Each shim's body is a straight-line call
//!      with concrete types — no runtime type inspection.
//!   2. Type safety. Every deserialiser is generated for a specific type
//!      signature; mismatched schema = compile error, not runtime error.
//!   3. Binary size. Only shims for methods the user actually exposes
//!      compile in.
//!
//! Cost: comptime work scales with the number of methods × number of args.
//! In practice this is 3–10 methods × 1–5 args, so the compile-time budget
//! is trivial.

const std = @import("std");
const td_mod = @import("typedef.zig");
const serde = @import("serde.zig");
const context_mod = @import("context.zig");
const Context = context_mod.Context;

/// A dispatch table entry.
pub fn Entry(comptime M: type) type {
    return struct {
        name: []const u8,
        def: td_mod.FunctionDef,
        invoke: *const fn (
            module: *const M,
            ctx: *Context,
            args_json: []const u8,
            out_writer: *std.Io.Writer,
        ) anyerror!void,
    };
}

/// Build the dispatch table for module type M.
/// Returns a const slice of entries, one per eligible method.
pub fn build(comptime M: type) []const Entry(M) {
    const info = @typeInfo(M);
    if (info != .@"struct") {
        @compileError("dagger-zig: module type must be a struct, got " ++ @typeName(M));
    }

    // Count eligible methods first (decls don't expose method-ness directly).
    comptime var count: usize = 0;
    comptime {
        for (info.@"struct".decls) |decl| {
            if (isEligibleMethod(M, decl.name)) count += 1;
        }
    }

    comptime var entries: [count]Entry(M) = undefined;
    comptime var idx: usize = 0;
    comptime {
        for (info.@"struct".decls) |decl| {
            if (!isEligibleMethod(M, decl.name)) continue;
            entries[idx] = .{
                .name = decl.name,
                .def = td_mod.functionOfMethod(M, decl.name),
                .invoke = makeInvoker(M, decl.name),
            };
            idx += 1;
        }
    }

    // Move to a const slice the caller can reference at runtime.
    const frozen = entries;
    return &frozen;
}

/// A decl is an eligible method if:
///   - it is a function
///   - it takes at least 2 params
///   - its first param's type is `*const M` or `M`
///   - its second param's type is `*Context`
///
/// We don't require `pub` because `@typeInfo` exposes both public and
/// private decls; however, the user's convention is still to write `pub
/// fn` — we just don't enforce it, since non-public methods being
/// callable from outside the module is a Zig visibility thing, not ours.
fn isEligibleMethod(comptime M: type, comptime decl_name: []const u8) bool {
    if (!@hasDecl(M, decl_name)) return false;
    const T = @TypeOf(@field(M, decl_name));
    const info = @typeInfo(T);
    if (info != .@"fn") return false;
    const fn_info = info.@"fn";
    if (fn_info.params.len < 2) return false;

    const p0_type = fn_info.params[0].type orelse return false;
    const p0_is_self = (p0_type == *const M) or (p0_type == *M) or (p0_type == M);
    if (!p0_is_self) return false;

    const p1_type = fn_info.params[1].type orelse return false;
    // Context is in a sibling file; resolve at usage site to avoid circular.
    if (p1_type != *Context) return false;

    // Skip lifecycle methods if the user named them the conventional way.
    if (std.mem.eql(u8, decl_name, "init")) return false;
    if (std.mem.eql(u8, decl_name, "deinit")) return false;
    if (std.mem.eql(u8, decl_name, "default")) return false;

    return true;
}

/// Generate the specialised invoker shim for one method.
fn makeInvoker(
    comptime M: type,
    comptime method_name: []const u8,
) *const fn (module: *const M, ctx: *Context, args_json: []const u8, out_writer: *std.Io.Writer) anyerror!void {
    const method = @field(M, method_name);
    const fn_info = @typeInfo(@TypeOf(method)).@"fn";
    const user_arg_count = fn_info.params.len - 2;

    // Build a tuple type for the user-visible args.
    const ArgsTuple = comptime blk: {
        var types: [user_arg_count]type = undefined;
        for (0..user_arg_count) |i| {
            types[i] = fn_info.params[i + 2].type orelse
                @compileError("dagger-zig: method `" ++ method_name ++
                    "` has a param with no declared type");
        }
        break :blk std.meta.Tuple(&types);
    };

    const Shim = struct {
        fn invoke(module: *const M, ctx: *Context, args_json: []const u8, out_writer: *std.Io.Writer) anyerror!void {
            var args: ArgsTuple = undefined;

            // Deserialise each user-facing arg in turn. The engine sends us
            // a JSON object `{"arg0": ..., "arg1": ...}` — we look up each
            // field by name.
            inline for (0..user_arg_count) |i| {
                const arg_name = std.fmt.comptimePrint("arg{d}", .{i});
                const ArgT = fn_info.params[i + 2].type.?;
                args[i] = try serde.deserializeArg(ArgT, ctx, args_json, arg_name);
            }

            // Build the complete argument tuple: self, ctx, then user args.
            // We can't splat tuples into call() cleanly, so we switch on arity.
            const result = switch (user_arg_count) {
                0 => @call(.auto, method, .{ module, ctx }),
                1 => @call(.auto, method, .{ module, ctx, args[0] }),
                2 => @call(.auto, method, .{ module, ctx, args[0], args[1] }),
                3 => @call(.auto, method, .{ module, ctx, args[0], args[1], args[2] }),
                4 => @call(.auto, method, .{ module, ctx, args[0], args[1], args[2], args[3] }),
                5 => @call(.auto, method, .{ module, ctx, args[0], args[1], args[2], args[3], args[4] }),
                6 => @call(.auto, method, .{ module, ctx, args[0], args[1], args[2], args[3], args[4], args[5] }),
                else => @compileError("dagger-zig: method `" ++ method_name ++
                    "` has more than 6 user-facing arguments; wrap them in a struct"),
            };

            // Unwrap error union if present, then serialize.
            const return_type = fn_info.return_type.?;
            const return_info = @typeInfo(return_type);
            const unwrapped = switch (return_info) {
                .error_union => try result,
                else => result,
            };

            try serde.serializeReturn(@TypeOf(unwrapped), unwrapped, out_writer);
        }
    };
    return Shim.invoke;
}

// ─────────────────────────── tests ──────────────────────────────────────

const testing = std.testing;

test "isEligibleMethod accepts valid shape, rejects init/deinit" {
    const M = struct {
        pub fn build(self: *const @This(), ctx: *Context) !void {
            _ = self;
            _ = ctx;
        }
        pub fn init() @This() {
            return .{};
        }
        pub fn deinit(self: *@This()) void {
            _ = self;
        }
        pub fn helperNoCtx(self: *const @This()) void {
            _ = self;
        }
    };
    try testing.expect(isEligibleMethod(M, "build"));
    try testing.expect(!isEligibleMethod(M, "init"));
    try testing.expect(!isEligibleMethod(M, "deinit"));
    try testing.expect(!isEligibleMethod(M, "helperNoCtx"));
}

test "build returns one entry per eligible method" {
    const M = struct {
        pub fn build(self: *const @This(), ctx: *Context) !void {
            _ = self;
            _ = ctx;
        }
        pub fn runTests(self: *const @This(), ctx: *Context, race: bool) ![]const u8 {
            _ = self;
            _ = ctx;
            _ = race;
            return "";
        }
        pub fn init() @This() {
            return .{};
        }
    };
    const table = build(M);
    try testing.expectEqual(@as(usize, 2), table.len);
    try testing.expectEqualStrings("build", table[0].name);
    try testing.expectEqualStrings("runTests", table[1].name);
}
