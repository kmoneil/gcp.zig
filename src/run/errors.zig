//! `Error`: every error a Cloud Run call can return. The API
//! statuses, their mapping and `Diagnostics` live in core.

const core = @import("core");

/// Every error a client call can return. The reads are GETs, retried as
/// any idempotent call is; each write says how it is retried, and a
/// traffic change whose etag is stale is `error.Aborted`.
pub const Error = core.rpc.Error || error{
    /// A location, service or revision id, page token or full name this
    /// client will not put in a request: nothing is sent. Another
    /// project's full name is one.
    InvalidName,
    /// A success response could not be decoded. Never retried.
    InvalidResponse,
    /// Options out of range: a retry policy or a user agent no call
    /// could use, a write on a client whose scope is `.read_only`, or a
    /// traffic change without an etag.
    InvalidOptions,
};
