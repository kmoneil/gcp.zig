//! `Error`: every error a Resource Manager call can return. The API
//! statuses, their mapping and `Diagnostics` live in core.

const core = @import("core");

/// Every error a client call can return.
pub const Error = core.rpc.Error || error{
    /// A query the server refused, its words in `Diagnostics` ("field
    /// [query] has issue [invalid syntax]"), or one this client would not
    /// send: a control character but tab, text that is not UTF-8, or more
    /// than 8,000 bytes, past which Google's front end answers in HTML.
    InvalidQuery,
    /// A page token the server refused: production says only "Request
    /// contains an invalid argument." of one it did not issue. A `Search`
    /// sends the same request for every page, so only a token carried
    /// across searches, or kept too long, gets this.
    InvalidPageToken,
    /// The project charged for the call has the Resource Manager API off:
    /// "Cloud Resource Manager API has not been used in project N before or
    /// it is disabled". `Client.lastConsumerRefusal` names the project and
    /// the link that turns the API on.
    ServiceDisabled,
    /// The quota project sent as `x-goog-user-project` may not be used by
    /// this caller (it lacks `serviceusage.services.use`), or does not
    /// exist. `Client.lastConsumerRefusal` names it.
    QuotaProjectDenied,
    /// A project id or number, or a quota project id, that breaks the
    /// naming rules: nothing is sent.
    InvalidName,
    /// A success response could not be decoded: a project with no number
    /// in its name, a field of the wrong type, a page token sent back again.
    /// Never retried.
    InvalidResponse,
    /// Options out of range: a walk's page limit or pause, a retry policy,
    /// a user agent.
    InvalidOptions,
};
