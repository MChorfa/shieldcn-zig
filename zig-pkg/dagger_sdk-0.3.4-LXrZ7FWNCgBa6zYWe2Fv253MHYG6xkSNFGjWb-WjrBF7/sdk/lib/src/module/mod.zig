//! Module authoring subsystem — public surface.
//!
//! ```zig
//! const std = @import("std");
//! const dagger = @import("dagger_sdk");
//!
//! const MyModule = struct {
//!     tenant: []const u8 = "default",
//!
//!     pub fn build(
//!         self: *const MyModule,
//!         ctx: *dagger.module.Context,
//!         source: dagger.Directory,
//!     ) !dagger.Container {
//!         _ = self;
//!         return ctx.dag().container()
//!             .from("golang:1.23-alpine")
//!             .withDirectory("/src", source);
//!     }
//! };
//!
//! pub fn main(init: std.process.Init) !void {
//!     return dagger.module.serve(init, MyModule{ .tenant = "acme" });
//! }
//! ```

const std = @import("std");

pub const typedef = @import("typedef.zig");
pub const dispatch = @import("dispatch.zig");
pub const serde = @import("serde.zig");
pub const context_mod = @import("context.zig");

pub const Context = context_mod.Context;
pub const TypeDef = typedef.TypeDef;
pub const FunctionDef = typedef.FunctionDef;
pub const Kind = typedef.Kind;

/// `serve(init, module_instance)` — to be filled in next turn by
/// `src/module/server.zig`. Declared here so the public surface is stable.
pub const serve = @import("server.zig").serve;
