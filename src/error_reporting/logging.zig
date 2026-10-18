//! Error Reporting logs under the scope `.gcp_error_reporting`: methods,
//! paths, statuses, counts and timings. Never a token, a stack trace or a
//! user. core's logging module says how tests capture what would have been
//! logged.

const scoped = @import("core").logging.Scoped(.gcp_error_reporting);

pub const debug = scoped.debug;
pub const warn = scoped.warn;
pub const capture = scoped.capture;
