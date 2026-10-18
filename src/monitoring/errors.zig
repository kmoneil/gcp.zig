//! `Error`: every error a Cloud Monitoring call can return. The API
//! statuses, their mapping and `Diagnostics` live in core.

const core = @import("core");

/// Every error a client call can return. A write whose points the server
/// answered about is a `WriteResult`, not one of these, however many it
/// refused.
pub const Error = core.rpc.Error || error{
    /// A metric type this client will not send: empty, past 512 characters,
    /// with a character outside letters, digits and `._:-/`, without a
    /// domain and a path, or with an empty path element.
    InvalidMetricType,
    /// A label key that is not a letter then letters, digits and `_`, or
    /// is past 100 bytes; a value past 1,024 bytes; more than 30 labels on
    /// a metric.
    InvalidLabel,
    /// A point the server would refuse: an interval its kind does not
    /// allow, a string past 1,024 bytes, a distribution that breaks its
    /// rules, or a kind or value type `custom.googleapis.com/` does not take.
    InvalidPoint,
    /// A resource type name or label this client will not send, such as a
    /// `project_id`, which the server fills in.
    InvalidResource,
    /// No series in a write, or more than 200.
    TooManySeries,
    /// Two series with the same metric type, metric labels and resource in
    /// one write: production writes the first and refuses the second.
    DuplicateSeries,
    /// A project, resource type or page token this client will not put in
    /// a request: nothing is sent.
    InvalidName,
    /// A success response, or a write's summary, could not be decoded.
    /// Never retried.
    InvalidResponse,
    /// Options out of range: a retry policy, a user agent, a page size.
    InvalidOptions,
};
