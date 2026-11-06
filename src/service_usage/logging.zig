//! The service_usage module logs under the scope `.gcp_service_usage`:
//! methods, paths, statuses, counts and timings. Never a token. core's
//! logging module says how tests capture what would have been logged.

const scoped = @import("core").logging.Scoped(.gcp_service_usage);

pub const debug = scoped.debug;
pub const warn = scoped.warn;
pub const capture = scoped.capture;
