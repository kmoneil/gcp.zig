//! `Error`: every error a Compute Engine call can return. The API
//! statuses, their mapping and `Diagnostics` live in core.
//!
//! Compute answers in the older JSON error shape: a list of errors whose
//! `reason` ("notFound", "conditionNotMet") stands in for a status, and
//! the HTTP code picks the error: 404 `error.NotFound`, 409
//! `error.AlreadyExists`, 412 `error.FailedPrecondition` (a stale
//! fingerprint), 400 `error.InvalidArgument`. What Compute only finds out
//! while acting is not an error at all: the call succeeds, and its
//! operation ends DONE with `Operation.failure` set.

const core = @import("core");

/// Every error a client call can return. The reads are GETs, retried as
/// any idempotent call is; so is the wait on an operation.
pub const Error = core.rpc.Error || error{
    /// A zone, name, project, page token or guest attribute path this
    /// client will not put in a request: nothing is sent.
    InvalidName,
    /// A success response could not be decoded. Never retried.
    InvalidResponse,
    /// Options out of range: a retry policy, a user agent or a page size
    /// no call could use, a serial port other than 1 to 4, or a list
    /// asked for a filter and an order together, which Compute refuses.
    InvalidOptions,
};
