//! `Error`: every error a Cloud Scheduler call can return. The API
//! statuses, their mapping and `Diagnostics` live in core.

const core = @import("core");

/// Every error a client call can return. The reads, a pause and a resume
/// are retried as any idempotent call is; `Client.runJob` says what a run
/// repeats. A run of a paused job is `error.FailedPrecondition`.
pub const Error = core.rpc.Error || error{
    /// A location, job id, page token or full name this client will not
    /// put in a request: nothing is sent. Another project's full name is
    /// one.
    InvalidName,
    /// A success response could not be decoded. Never retried.
    InvalidResponse,
    /// Options out of range: a retry policy, a user agent, a page size
    /// production documents as refused.
    InvalidOptions,
};
