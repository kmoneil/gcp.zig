//! `Error`: every error a Cloud Logging call can return. The API statuses,
//! their mapping and `Diagnostics` live in core.

const core = @import("core");

/// Every error a client call can return.
pub const Error = core.rpc.Error || error{
    /// A scope, bucket or view name breaks the naming rules, or a query
    /// names none or more than 100.
    InvalidScope,
    /// A clause value the query language could not be trusted to read back
    /// (a control character, text that is not UTF-8), a joined filter over
    /// 20,000 characters, or the server's "Unparseable filter", whose
    /// message `Diagnostics` keeps.
    InvalidFilter,
    /// The server's "page_token doesn't match arguments from the request":
    /// a token from another query. A `Query` sends the same request for
    /// every page, so only a token carried across queries gets this.
    InvalidPageToken,
    /// `Payload.parse` on a text payload, or on none.
    NotJson,
    /// A success response could not be decoded. Never retried.
    InvalidResponse,
    /// Options out of range: a page size, a time range, a retry policy, a
    /// user agent, a read count.
    InvalidOptions,
};
