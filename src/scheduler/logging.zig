//! Cloud Scheduler logs under the scope `.gcp_scheduler`: methods, paths,
//! statuses, counts and timings. Never a token or a target's body. core's
//! logging module says how tests capture what would have been logged.

const scoped = @import("core").logging.Scoped(.gcp_scheduler);

pub const debug = scoped.debug;
pub const warn = scoped.warn;
pub const capture = scoped.capture;
