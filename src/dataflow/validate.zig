//! What the client checks before sending, so a bad name costs no request.

const std = @import("std");

/// A location id as Dataflow takes them (`us-central1`). Lowercase
/// letters, digits and `-`, one path segment. Dataflow has no `-`
/// sweep; the aggregated list is the cross-region read. Production
/// answered a made-up region with us-central1's jobs rather than a
/// refusal (measured 2026-10-20), so the charset is the only check.
pub fn isLocation(id: []const u8) bool {
    if (id.len == 0 or id.len > 64) return false;
    for (id) |c| switch (c) {
        'a'...'z', '0'...'9', '-' => {},
        else => return false,
    };
    return true;
}

/// A job id goes into the path as one segment. The server assigns them
/// (`2026-10-20_07_09_34-8524524531325271694` when measured); held to
/// visible ASCII without `/` so an unexpected form still reaches the
/// server's own answer.
pub fn isJobId(id: []const u8) bool {
    if (id.len == 0 or id.len > 1024) return false;
    for (id) |c| if (c <= ' ' or c >= 0x7f or c == '/') return false;
    return true;
}

/// The `name` filter travels as a query parameter. Job names are
/// documented as `[a-z]([-a-z0-9]{0,1022}[a-z0-9])?`; held to visible
/// ASCII, the regex production's to enforce.
pub fn isJobName(name: []const u8) bool {
    if (name.len == 0 or name.len > 1024) return false;
    for (name) |c| if (c <= ' ' or c >= 0x7f) return false;
    return true;
}

/// A page token travels as a query parameter; production's are opaque
/// base64 ("encrypted and only guaranteed ... for 72 hours").
pub fn isPageToken(token: []const u8) bool {
    if (token.len == 0) return false;
    for (token) |c| if (c <= ' ' or c >= 0x7f) return false;
    return true;
}

/// A user agent goes into a header, so it must be printable ASCII.
pub fn isUserAgent(agent: []const u8) bool {
    if (agent.len == 0) return false;
    for (agent) |c| if (c < ' ' or c >= 0x7f) return false;
    return true;
}

const testing = std.testing;

test "locations, job ids, names, tokens and agents" {
    try testing.expect(isLocation("us-central1"));
    try testing.expect(!isLocation(""));
    try testing.expect(!isLocation("US-central1"));
    try testing.expect(!isLocation("us central1"));
    try testing.expect(isJobId("2026-10-20_07_09_34-8524524531325271694"));
    try testing.expect(isJobId("0.oe0ehmpm95z2"));
    try testing.expect(!isJobId(""));
    try testing.expect(!isJobId("a/b"));
    try testing.expect(!isJobId("a b"));
    try testing.expect(isJobName("zigps-df-05373"));
    try testing.expect(!isJobName("a b"));
    try testing.expect(!isJobName(""));
    try testing.expect(isPageToken("CicyMDI2LTEwLTIw="));
    try testing.expect(!isPageToken("a b"));
    try testing.expect(!isPageToken(""));
    try testing.expect(isUserAgent("zig-gcp-dataflow/0.54"));
    try testing.expect(!isUserAgent("a\nb"));
}
