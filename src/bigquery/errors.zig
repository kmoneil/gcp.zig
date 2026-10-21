//! `Error`: every error a BigQuery call can return. The API statuses,
//! their mapping and `Diagnostics` live in core; BigQuery's own reasons
//! (`errors[].reason` in a refusal's body) refine a few of them here.

const core = @import("core");

/// Every error a client call can return.
pub const Error = core.rpc.Error || error{
    /// An id, location, page token or filter this client will not put in
    /// a request: nothing is sent.
    InvalidName,
    /// A success response could not be decoded. Never retried.
    InvalidResponse,
    /// Options out of range: a retry policy or a user agent no call could
    /// use.
    InvalidOptions,
    /// A query BigQuery refused as written, its reason `invalidQuery`: a
    /// syntax error ("Syntax error: Unexpected keyword WHERE at [2:3]"),
    /// an unknown name, or an error as it ran ("division by zero: 1 / 0"),
    /// all measured as a 400 from `jobs.query` itself. `Diagnostics` keeps
    /// the words; `errorPosition` reads the `at [line:column]`.
    InvalidQuery,
    /// A query that would bill more than its `maximumBytesBilled`, refused
    /// before it ran and without a charge: "Query exceeded limit for bytes
    /// billed: 1000. 10485760 or higher required." (measured).
    BytesBilledLimitExceeded,
    /// A result row too large to return (`responseTooLarge`).
    ResultTooLarge,
    /// A quota met (`quotaExceeded`): BigQuery says to wait ten minutes or
    /// more, so it is not retried.
    QuotaExceeded,
};
