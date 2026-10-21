//! Data Transfer logs under the scope `.gcp_datatransfer`: methods,
//! paths, statuses, counts and timings. Never a token, a query's text or
//! a run's messages. core's logging module says how tests capture what
//! would have been logged.

const scoped = @import("core").logging.Scoped(.gcp_datatransfer);

pub const debug = scoped.debug;
pub const warn = scoped.warn;
pub const capture = scoped.capture;
