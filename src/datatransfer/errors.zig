//! `Error`: every error a Data Transfer call can return. The API
//! statuses, their mapping and `Diagnostics` live in core.

const core = @import("core");

/// Every error a client call can return.
pub const Error = core.rpc.Error || error{
    /// A name, location, data source id or page token this client will
    /// not put in a request: nothing is sent.
    InvalidName,
    /// A success response could not be decoded. Never retried.
    InvalidResponse,
    /// Options out of range: a retry policy or a user agent no call could
    /// use, or a call the client's scope cannot make.
    InvalidOptions,
};
