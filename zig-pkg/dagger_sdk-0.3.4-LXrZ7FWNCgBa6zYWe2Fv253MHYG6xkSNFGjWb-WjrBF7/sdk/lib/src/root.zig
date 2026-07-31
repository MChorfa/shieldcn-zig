//! # dagger-zig
//!
//! Zig SDK for the Dagger programmable CI/CD engine. Targets Zig 0.16+.
//!
//! ## Quick start (client only — calling existing modules)
//!
//! ```zig
//! const std = @import("std");
//! const dagger = @import("dagger_sdk");
//!
//! pub fn main(init: std.process.Init) !void {
//!     var client = try dagger.connect(init.gpa, init.io, .{});
//!     defer client.close();
//!
//!     const out = try client.dag()
//!         .container()
//!         .from("alpine:latest")
//!         .withExec(&.{ "echo", "hello from zig" })
//!         .stdout();
//!     defer init.gpa.free(out);
//!
//!     std.debug.print("{s}", .{out});
//! }
//! ```
//!
//! ## Authoring a module (v0.1 headline feature)
//!
//! ```zig
//! const std = @import("std");
//! const dagger = @import("dagger_sdk");
//!
//! const MyModule = struct {
//!     pub fn build(
//!         self: *MyModule,
//!         ctx: *dagger.Context,
//!         source: dagger.Directory,
//!     ) !dagger.Container {
//!         _ = self;
//!         return ctx.container()
//!             .from("golang:1.23-alpine")
//!             .withDirectory("/src", source)
//!             .withWorkdir("/src")
//!             .withExec(&.{ "go", "build", "-o", "/app", "./..." });
//!     }
//! };
//!
//! pub fn main(init: std.process.Init) !void {
//!     return dagger.module.serve(init, MyModule);
//! }
//! ```
//!
//! See `docs/ARCHITECTURE.md` for the full design.

const std = @import("std");

// Feature flags from build options
const spiffe_options = @import("spiffe_options");

pub const errors = @import("errors.zig");
pub const querybuilder = @import("querybuilder.zig");
pub const core = struct {
    pub const connect_params = @import("core/connect_params.zig");
    pub const config = @import("core/config.zig");
    pub const engine = @import("core/engine.zig");
    pub const graphql_client = @import("core/graphql_client.zig");
    pub const cli_session = @import("core/cli_session.zig");
    pub const version = @import("core/version.zig");
};

/// Module authoring subsystem. See `src/module/` for the dispatch,
/// TypeDef builder, server loop, and (de)serialization.
pub const module = @import("module/mod.zig");

/// Parallelism helpers — concurrent fan-out over `std.Io.Group`. See
/// `src/parallel.zig`. Pair with `Client.branch()` so each task has its own
/// client (sharing a client across tasks races; see `Client`).
pub const parallel = @import("parallel.zig");

/// OpenTelemetry-compatible tracing for SDK operations.
pub const tracing = @import("tracing.zig");

/// SPIFFE/SPIRE subsystem — Workload API client, SVID types, and helpers
/// for authenticating to external services (Vault, registries, etc.) with
/// short-lived workload identities. See `src/spiffe/mod.zig`.
///
/// ⚠️ EXPERIMENTAL: Enable with `-Dspiffe-experimental` build flag.
/// API is unstable and may change in future releases.
///
/// The shellout backend works today; the native Workload API remains a
/// skeleton behind the experimental SPIFFE flag. The public surface stays
/// stable across both so call sites do not have to change.
pub const spiffe = if (spiffe_options.spiffe_enabled)
    @import("spiffe/mod.zig")
else
    struct {};

/// Opt-in SPIFFE-to-Dagger glue (`spiffeRegistryAuth`, Vault cert-auth
/// provider). Separate from `spiffe` to keep the SPIFFE client usable as
/// a standalone library without pulling in the Dagger core dep graph.
///
/// ⚠️ EXPERIMENTAL: Enable with `-Dspiffe-experimental` build flag.
pub const spiffe_integration = if (spiffe_options.spiffe_enabled)
    @import("spiffe/integration.zig")
else
    struct {};

pub const Config = core.config.Config;
pub const Logger = core.config.Logger;
pub const StdLogger = core.config.StdLogger;

// Re-export the introspection-generated API.
pub const api = @import("gen.zig");

/// Engine-side API used by the module runtime: `currentFunctionCall`,
/// handle loaders (`loadContainerFromID`, etc.). Advanced users can call
/// these directly; typical module authors don't need to.
pub const module_api = @import("module_api.zig");

pub const Query = api.Query;
pub const Context = module.Context;
pub const Container = api.Container;
pub const Directory = api.Directory;
pub const File = api.File;
pub const Secret = api.Secret;
pub const CacheVolume = api.CacheVolume;
pub const Service = api.Service;
pub const GitRepository = api.GitRepository;
pub const GitRef = api.GitRef;
pub const Host = api.Host;
pub const Socket = api.Socket;
pub const ContainerID = api.ContainerID;
pub const DirectoryID = api.DirectoryID;
pub const FileID = api.FileID;
pub const SecretID = api.SecretID;
pub const CacheVolumeID = api.CacheVolumeID;
pub const ServiceID = api.ServiceID;
pub const GitRepositoryID = api.GitRepositoryID;
pub const GitRefID = api.GitRefID;
pub const HostID = api.HostID;
pub const SocketID = api.SocketID;

/// A live Dagger client. Holds:
///   - the subprocess (if we spawned one)
///   - the GraphQL HTTP client (carries the user's Io)
///   - an arena for the selection chain
///
/// Concurrency: a `Client` carries per-query mutable state (the last domain
/// error, the circuit breaker, an in-progress flag) that is NOT synchronized.
/// Do NOT share one client across concurrent tasks — under the multi-threaded
/// `Io` backend that is a data race. To fan out, give each task its own
/// `branch()` (cheap; shares the engine session, no new subprocess) and drive
/// them with `io.async`/`std.Io.Group` or the `dagger.parallel` helpers.
pub const Client = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    params: core.connect_params.ConnectParams,
    session: ?core.cli_session.SessionProc,
    gql: core.graphql_client.GraphQLClient,
    arena: std.heap.ArenaAllocator,
    /// False for clients created via `branch()`: they borrow the parent's
    /// connection params and never own the session, so `close()` must not
    /// free those.
    owns_connection: bool = true,

    /// Get the root `Query` for building pipelines.
    pub fn dag(self: *Client) Query {
        return .{
            .allocator = self.allocator,
            .arena = self.arena.allocator(),
            .selection = &querybuilder.Selection.root,
            .gql = &self.gql,
        };
    }

    /// Create an independent client for one concurrent fan-out task.
    ///
    /// The branch reuses the parent's engine session (same port and token — no
    /// new subprocess) but has its own per-query mutable state and selection
    /// arena, so branches can run on different threads without racing. A branch
    /// borrows the parent's connection: it must not outlive the parent, and
    /// `close()` on a branch frees only the branch's own gql + arena (it does
    /// not shut down the session or free the shared connection params).
    pub fn branch(self: *Client) !Client {
        return .{
            .allocator = self.allocator,
            .io = self.io,
            .params = self.params, // borrowed; freed by the parent only
            .session = null, // a branch never owns the session
            .gql = try self.gql.fork(),
            .arena = std.heap.ArenaAllocator.init(self.allocator),
            .owns_connection = false,
        };
    }

    /// Tear down the client. Idempotent. On a `branch()` this frees only the
    /// branch's own gql + arena; on a parent it also shuts down the session
    /// and frees the connection params.
    pub fn close(self: *Client) void {
        if (self.session) |*s| {
            s.shutdown() catch |e| {
                std.debug.print("dagger: session shutdown failed: {s}\n", .{@errorName(e)});
            };
            self.session = null;
        }
        self.gql.deinit();
        if (self.owns_connection) self.params.deinit(self.allocator);
        self.arena.deinit();
    }

    /// Reset the internal arena, reclaiming memory while retaining the buffer capacity.
    /// Call this periodically for long-running clients to prevent unbounded memory growth.
    /// Returns error.QueryInProgress if a query is currently active.
    pub fn resetArena(self: *Client) error{QueryInProgress}!void {
        if (self.gql.query_in_progress) {
            return error.QueryInProgress;
        }
        _ = self.arena.reset(.retain_capacity);
    }
};

/// Connect to a Dagger engine using the caller-supplied allocator and Io.
///
/// `io` must outlive the returned client. Typically you pass `init.io` from
/// `std.process.Init` (Juicy Main).
pub fn connect(
    allocator: std.mem.Allocator,
    io: std.Io,
    cfg: Config,
) !Client {
    const start = try core.engine.start(allocator, io, cfg);
    var gql = try core.graphql_client.GraphQLClient.init(allocator, io, start.params, cfg);
    errdefer gql.deinit();

    return .{
        .allocator = allocator,
        .io = io,
        .params = start.params,
        .session = start.session,
        .gql = gql,
        .arena = std.heap.ArenaAllocator.init(allocator),
    };
}

test {
    // Always test core SDK
    std.testing.refAllDecls(@This());

    // Only test SPIFFE when experimental flag is enabled
    if (spiffe_options.spiffe_enabled) {
        std.testing.refAllDecls(@import("spiffe/mod.zig"));
        std.testing.refAllDecls(@import("spiffe/integration.zig"));
    }
}
