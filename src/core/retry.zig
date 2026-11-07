//! Which failures Google's APIs may be retried on: rest-core's transport
//! failures, and the retryable API statuses. How long to wait in between is
//! rest-core's `RetryPolicy`.

const std = @import("std");
const rest_core = @import("rest_core");

pub const RetryPolicy = rest_core.RetryPolicy;

/// Whether a failed attempt may be retried: the retryable API statuses
/// (RESOURCE_EXHAUSTED, INTERNAL, BAD_GATEWAY and UNAVAILABLE, both mapped to
/// `Unavailable`, and DEADLINE_EXCEEDED) and connections that dropped, timed
/// out or could not be made (`rest_core.isRetryable`). Everything else is
/// returned as is.
pub fn isRetryable(err: anyerror) bool {
    return switch (err) {
        error.ResourceExhausted,
        error.Internal,
        error.Unavailable,
        error.DeadlineExceeded,
        => true,
        else => rest_core.isRetryable(err),
    };
}

test "retryable errors are exactly the transient ones" {
    for ([_]anyerror{
        error.ResourceExhausted, error.Internal,           error.Unavailable,
        error.DeadlineExceeded,  error.ConnectionRefused,  error.ConnectionResetByPeer,
        error.TimedOut,          error.ConnectionTimedOut, error.NetworkUnreachable,
        error.NameServerFailure, error.TlsFailure,
    }) |err| {
        try std.testing.expect(isRetryable(err));
    }
    for ([_]anyerror{
        error.NotFound,           error.PermissionDenied,       error.InvalidArgument,
        error.FailedPrecondition, error.Unauthenticated,        error.AlreadyExists,
        error.OutOfMemory,        error.ConcurrencyUnavailable, error.HttpProtocolError,
    }) |err| {
        try std.testing.expect(!isRetryable(err));
    }
}
