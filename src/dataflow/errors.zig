//! `Error`: every error a Dataflow call can return. The API statuses,
//! their mapping and `Diagnostics` live in core.

const core = @import("core");

/// Every error a client call can return. Each call is retried as any
/// idempotent call is: the reads are GETs, and a cancel or a drain landing
/// twice changes nothing. A cancel of a job still pending, or of one that
/// has ended, is `error.FailedPrecondition`; a drain of a batch job is
/// `error.InvalidArgument`; a job nobody has, or a real region it is not
/// in, is `error.NotFound`.
pub const Error = core.rpc.Error || error{
    /// A location, job id, name filter, page token or full name this
    /// client will not put in a request: nothing is sent.
    InvalidName,
    /// A success response could not be decoded. Never retried.
    InvalidResponse,
    /// Options out of range: a retry policy or a user agent no call
    /// could use.
    InvalidOptions,
};
