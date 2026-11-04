//! `Error`: every error a Cloud Billing Catalog call can return. The API
//! statuses, their mapping and `Diagnostics` live in core.

const core = @import("core");

/// Every error a client call can return. Every call is a read, retried as
/// any idempotent call is. While the Cloud Billing API is off in the
/// token's project, every call is `error.PermissionDenied` (production's
/// 403 `SERVICE_DISABLED`, whose message `Diagnostics` keeps).
pub const Error = core.rpc.Error || error{
    /// A service id, page token or currency code this client will not put
    /// in a request: nothing is sent.
    InvalidName,
    /// A success response could not be decoded. Never retried.
    InvalidResponse,
    /// Options out of range: a page size over 5000, a time range the
    /// catalog refuses, a retry policy, a user agent. Nothing is sent.
    InvalidOptions,
};
