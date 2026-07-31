//! End-to-end example: a real Dagger module authored in Zig.
//!
//! This module exercises the full ModuleRuntime path that was broken
//! before the sdk/lib fix:
//!   dagger develop  → Codegen emits build.zig + build.zig.zon + dagger.gen.zig
//!   dagger call hello → ModuleRuntime builds this file, runs it, returns "hello"
//!
//! Unlike the other examples (first-pipeline, build-app, parallel), this one
//! has its own dagger.json and is a standalone Dagger module — not a client
//! script run via `dagger run -- zig build run-...`.
//!
//! Usage:
//!   cd examples/e2e-module
//!   dagger develop
//!   dagger call hello
//!   dagger call echo --msg="custom message"

const std = @import("std");
const dagger = @import("dagger_sdk");

const E2eModule = struct {
    pub fn hello(self: *const E2eModule, ctx: *dagger.module.Context) ![]const u8 {
        _ = self;
        _ = ctx;
        return "hello from dagger-zig module";
    }

    pub fn echo(
        self: *const E2eModule,
        ctx: *dagger.module.Context,
        msg: []const u8,
    ) ![]const u8 {
        _ = self;
        _ = ctx;
        return msg;
    }
};

pub fn main(init: std.process.Init) !void {
    return dagger.module.serve(init, E2eModule{});
}
