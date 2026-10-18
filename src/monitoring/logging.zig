//! Cloud Monitoring logs under the scope `.gcp_monitoring`: methods, paths,
//! statuses, counts and timings. Never a token, a label value or a point.
//! core's logging module says how tests capture what would have been
//! logged.

const scoped = @import("core").logging.Scoped(.gcp_monitoring);

pub const debug = scoped.debug;
pub const warn = scoped.warn;
pub const capture = scoped.capture;
