//! Cloud KMS logs under the scope `.gcp_kms`: methods, paths, statuses and
//! timings. Never a token, plaintext, ciphertext, a signature or a MAC.
//! core's logging module says how tests capture what would have been
//! logged.

const scoped = @import("core").logging.Scoped(.gcp_kms);

pub const debug = scoped.debug;
pub const warn = scoped.warn;
pub const capture = scoped.capture;
