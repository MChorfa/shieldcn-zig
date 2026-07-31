//! Context — what user module methods receive as their second parameter.
//!
//! ```zig
//! pub fn build(
//!     self: *const MyModule,
//!     ctx: *dagger.Context,
//!     source: dagger.Directory,
//! ) !dagger.Container {
//!     _ = self;
//!     return ctx.container()
//!         .from("golang:1.23-alpine")
//!         .withDirectory("/src", source);
//! }
//! ```
//!
//! The context carries:
//!   - a pointer to the per-process Dagger client
//!   - an allocator scoped to THIS dispatch (freed when the dispatch
//!     returns); use this for anything that doesn't need to outlive the
//!     function call
//!   - access to the SPIFFE workload identity, if the module is running
//!     in a SPIFFE-enabled environment

const std = @import("std");
const dagger = @import("../root.zig");
const Client = dagger.Client;
const spiffe_mod = @import("../spiffe/mod.zig");

pub const Context = struct {
    /// Per-process client, owned by the `serveModule` call.
    client: *Client,

    /// Per-dispatch arena. Lifetime: from the moment the dispatcher receives
    /// a function call until it returns. Use this for temporary allocations
    /// that don't need to escape the function.
    arena: std.mem.Allocator,

    /// The Io the client was connected with. Exposed for user code that
    /// wants to do its own `io.async` / `Io.Group` work.
    io: std.Io,

    /// SPIFFE source, if the module was configured with SPIFFE.
    /// Null when SPIFFE is unavailable or disabled.
    spiffe_source: ?spiffe_mod.SvidSource = null,

    /// Shortcut: the Dagger root Query.
    pub fn dag(self: *Context) dagger.Query {
        return self.client.dag();
    }

    /// Per-dispatch allocator for temporary results.
    pub fn allocator(self: *Context) std.mem.Allocator {
        return self.arena;
    }

    /// Convenience helper mirroring the documented module authoring API.
    pub fn container(self: *Context) !dagger.Container {
        return self.dag().container(null);
    }

    /// Convenience helper mirroring the documented module authoring API.
    pub fn directory(self: *Context) !dagger.Directory {
        return self.dag().directory();
    }

    /// Group subsequent operations under a logical pipeline label.
    /// The current SDK has no engine-side pipeline primitive yet, so this is a no-op.
    pub fn pipeline(self: *Context, name: []const u8) !*Context {
        _ = name;
        return self;
    }

    /// Fetch the current workload X509-SVID, if SPIFFE is configured.
    /// Returns `error.NotInitialized` if SPIFFE wasn't set up at serveModule time.
    pub fn svid(self: *Context) !spiffe_mod.X509SVID {
        const src = self.spiffe_source orelse return error.NotInitialized;
        return src.fetchX509SVID(self.arena);
    }

    /// Fetch a JWT-SVID bound to the given audiences.
    pub fn jwtSvid(self: *Context, audiences: []const []const u8) !spiffe_mod.JWTSVID {
        const src = self.spiffe_source orelse return error.NotInitialized;
        return src.fetchJWTSVID(self.arena, audiences);
    }
};
