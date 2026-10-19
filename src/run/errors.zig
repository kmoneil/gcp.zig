//! `Error`: every error a Cloud Run call can return. The API
//! statuses, their mapping and `Diagnostics` live in core.

const core = @import("core");

/// Every error a client call can return. The module reads only, so each
/// call is a GET, retried as any idempotent call is.
pub const Error = core.rpc.Error || error{
    /// A location, service or revision id, page token or full name this
    /// client will not put in a request: nothing is sent. Another
    /// project's full name is one.
    InvalidName,
    /// A success response could not be decoded. Never retried.
    InvalidResponse,
    /// Options out of range: a retry policy or a user agent no call
    /// could use.
    InvalidOptions,
};
