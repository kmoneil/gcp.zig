//! `Error`: every error an Error Reporting call can return. The API
//! statuses, their mapping and `Diagnostics` live in core.

const core = @import("core");

/// Every error a client call can return.
pub const Error = core.rpc.Error || error{
    /// A page token the server refused ("Error while unescaping page_token
    /// in request."), or one this client would not send. A query sends the
    /// same request for every page, so only a token carried across
    /// queries gets this.
    InvalidPageToken,
    /// The project charged for the call has the Error Reporting API off:
    /// "Error Reporting API has not been used in project N before or it is
    /// disabled". `Client.lastConsumerRefusal` names the project and the
    /// link that turns the API on.
    ServiceDisabled,
    /// The quota project sent as `x-goog-user-project` may not be used by
    /// this caller, or does not exist. `Client.lastConsumerRefusal` names it.
    QuotaProjectDenied,
    /// A project, location, group id or service filter this client will not
    /// put in a request: nothing is sent.
    InvalidName,
    /// A success response could not be decoded. Never retried.
    InvalidResponse,
    /// Options out of range, or refused by the server for its own reasons:
    /// buckets too narrow for the period ("'timed_count_duration' is too
    /// short for the requested period"), a page size or bucket width of 0,
    /// a retry policy, a user agent.
    InvalidOptions,
};
