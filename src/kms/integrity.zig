//! The checksums every crypto call carries (the KMS spec, section 7.6),
//! and what a failed one costs. Each request sends the CRC-32C of every
//! bytes field; each answer must say the server got them, its own
//! checksums must match its bytes, and the version it names must be the
//! one asked for. A check that fails, or the server's refusal of a request
//! checksum as not matching, is tried again like a 503, under the client's
//! retry policy, and past its attempts is `error.IntegrityCheckFailed`,
//! with which check in `Diagnostics`. No production report of one failing
//! was found; the fake fails each on request, so each is tested.

const std = @import("std");
const core = @import("core");

const Client = @import("Client.zig");
const logging = @import("logging.zig");
const rpc = @import("rpc.zig");
const Error = @import("errors.zig").Error;

/// The attempts of one crypto call.
pub const Attempts = struct {
    client: *Client,
    /// The call, for the log and `Diagnostics`: "encrypt".
    what: []const u8,
    attempt: u32 = 0,

    /// Starts an attempt.
    pub fn next(a: *Attempts) void {
        a.attempt += 1;
    }

    /// After a failed check, `reason`: waits and returns, to try again, or
    /// returns `error.IntegrityCheckFailed` when the attempts are spent.
    pub fn failed(a: *Attempts, reason: []const u8) Error!void {
        const c = a.client;
        const delay_ms = if (a.attempt < c.retry.max_attempts) rpc.waitMs(c, a.attempt) else null;
        if (delay_ms) |ms| {
            logging.warn("{s}: {s}; trying again in {d} ms (attempt {d} of {d})", .{ a.what, reason, ms, a.attempt + 1, c.retry.max_attempts });
            try c.io.sleep(.fromMilliseconds(ms), .awake);
            return;
        }
        if (c.diagnostics) |d| d.print("{s}: {s}, on attempt {d}", .{ a.what, reason, a.attempt });
        return error.IntegrityCheckFailed;
    }
};

/// Whether `crc` is there and is the CRC-32C of `bytes`.
pub fn matches(bytes: []const u8, crc: ?u32) bool {
    const want = crc orelse return false;
    return core.crc32c.hash(bytes) == want;
}

/// Why a refused request counts as an integrity failure: the server said a
/// checksum it was sent did not match.
pub const request_refused = "the server found a request checksum that did not match its bytes";

const testing = std.testing;

test "matches: present and equal, and nothing else" {
    try testing.expect(matches("hello", 2591144780));
    try testing.expect(matches("", 0));
    try testing.expect(!matches("hello", 2591144781));
    try testing.expect(!matches("hello", null));
    try testing.expect(!matches("", null));
    // The checksums Key.zig's tests write out.
    try testing.expect(matches("c1ph", 908558936));
    try testing.expect(matches("ctx", 2801377629));
    try testing.expect(matches("s3cr3t-plain", 866759889));
}
