//! Compute Engine logs under the scope `.gcp_compute`: methods, paths,
//! statuses, counts and timings. Never a token or a body. core's logging
//! module says how tests capture what would have been logged.

const scoped = @import("core").logging.Scoped(.gcp_compute);

pub const debug = scoped.debug;
pub const warn = scoped.warn;
pub const capture = scoped.capture;
