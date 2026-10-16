//! This module's own events go to `std.log` under the scope `.gcp_logging`:
//! methods, paths, statuses, counts and timings. Never a token, a filter's
//! text or an entry's contents. The file is not `logging.zig`, as in the
//! other modules, because here that name reads as the API. core's logging
//! module says how tests capture what would have been logged.

const scoped = @import("core").logging.Scoped(.gcp_logging);

pub const debug = scoped.debug;
pub const warn = scoped.warn;
pub const capture = scoped.capture;
