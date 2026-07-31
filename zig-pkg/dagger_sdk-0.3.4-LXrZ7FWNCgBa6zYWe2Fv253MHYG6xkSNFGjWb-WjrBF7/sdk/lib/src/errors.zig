//! Typed errors for the Dagger SDK.
//!
//! We separate concerns so callers can match precisely:
//!   - `QueryError`     → GraphQL wire-level failures (HTTP, transport, shape)
//!   - `DaggerError`    → domain errors from the engine (resolver returned an error)
//!   - `ConnectError`   → engine bring-up failures (CLI spawn, handshake, shutdown)
//!   - `BuildError`     → client-side errors (JSON encode, alloc, bad input)
//!
//! This mirrors the Rust SDK's `errors.rs` split but uses Zig error sets,
//! which are zero-cost at the call site.

const std = @import("std");

pub const BuildError = error{
    OutOfMemory,
    JsonEncodeFailed,
    InvalidUtf8,
    /// A Selection had no `prev` — caller tried to build an empty query.
    EmptySelection,
    /// Argument value was not serializable (e.g. unsupported type).
    UnserializableArg,
    /// Secret already registered under this name.
    SecretAlreadyExists,
    /// Secret exceeds maximum allowed length (1MB).
    SecretTooLong,
    /// Input exceeds maximum allowed size for scrubbing (10MB).
    InputTooLarge,
    /// Async query group was already executed.
    AlreadyExecuted,
    /// Async query group is empty.
    EmptyGroup,
    /// Maximum retry attempts exceeded.
    RetryExceeded,
    /// Selection chain exceeded maximum depth limit.
    SelectionTooDeep,
    /// Too many arguments in a single selection.
    TooManyArguments,
};

pub const QueryError = error{
    OutOfMemory,
    /// Transport-level failure: socket closed, DNS, TLS, etc.
    TransportFailed,
    /// Server replied with a non-2xx status.
    HttpStatus,
    /// Response body was not valid JSON.
    MalformedResponse,
    /// Response shape did not match GraphQL envelope `{data: ..., errors: ...}`.
    InvalidEnvelope,
    /// GraphQL returned an `errors` array — see DomainError for details.
    DomainError,
    /// Unpacking the response: the nested object had more than one key.
    TooManyNestedObjects,
    /// Unpacking the response: could not deserialise into expected type.
    DeserializeFailed,
    /// Circuit breaker is open — service appears unhealthy, request rejected.
    CircuitOpen,
};

pub const ConnectError = error{
    OutOfMemory,
    /// Could not spawn the dagger CLI.
    SpawnFailed,
    /// CLI exited before emitting connect params.
    CliExited,
    /// CLI output was not parseable as ConnectParams JSON.
    HandshakeFailed,
    /// Env vars looked like a session but were malformed.
    InvalidEnv,
    /// Could not download the dagger CLI binary.
    DownloadFailed,
    /// Shutdown of the session subprocess failed.
    ShutdownFailed,
    /// User-provided context future returned an error.
    UserCallbackFailed,
};

/// A GraphQL domain error carried alongside `QueryError.DomainError`.
/// The caller inspects `last_error()` on the client after a failed query.
pub const DomainError = struct {
    message: []const u8,
    /// Optional structured extensions from the GraphQL error object.
    path: ?[]const []const u8 = null,
    locations: ?[]const Location = null,
    extensions_json: ?[]const u8 = null,

    pub const Location = struct { line: u32, column: u32 };

    pub fn deinit(self: *DomainError, allocator: std.mem.Allocator) void {
        allocator.free(self.message);
        if (self.path) |p| {
            for (p) |seg| allocator.free(seg);
            allocator.free(p);
        }
        if (self.locations) |l| allocator.free(l);
        if (self.extensions_json) |e| allocator.free(e);
    }
};

/// Platform-specific errors for cross-platform abstractions.
pub const PlatformError = error{
    OutOfMemory,
    /// Socket connection failed (platform-specific reason).
    ConnectionFailed,
    /// Socket read operation failed.
    ReadError,
    /// Socket write operation failed.
    WriteError,
    /// Socket close operation failed.
    CloseError,
    /// Platform feature not supported on this OS.
    NotSupported,
    /// Windows-specific: Named pipe operation failed.
    NamedPipeError,
    /// Windows-specific: AF_UNIX not available (requires Windows 10 1803+).
    AfUnixNotAvailable,
};
