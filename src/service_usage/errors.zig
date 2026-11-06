//! `Error`: every error a Service Usage call can return. The API statuses,
//! their mapping and `Diagnostics` live in core.

const core = @import("core");

/// Every error a client call can return. Every call is a read, retried as
/// any idempotent call is. A service production does not know, or will
/// not show this project, is `error.PermissionDenied`, as production
/// answers it ("Not found or permission denied for service(s): ..."): it
/// cannot say which.
pub const Error = core.rpc.Error || error{
    /// A service name or page token this client will not put in a
    /// request: nothing is sent, and `Diagnostics` say what is wrong with
    /// it.
    InvalidName,
    /// A success response could not be decoded. Never retried.
    InvalidResponse,
    /// Options out of range: a page size over 200, no names or more than
    /// 30 for `getServices`, a retry policy, a user agent. Nothing is sent.
    InvalidOptions,
};
