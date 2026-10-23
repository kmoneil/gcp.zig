//! What the client checks before sending, so a bad name costs no request.

const std = @import("std");

/// `jobs.list` refuses a pageSize over this: "ListJobsRequest.pageSize
/// must be less than or equal to 500", measured 2026-10-19. Unset, the
/// page size is this maximum, the document says.
pub const max_page_size = 500;

/// A location id as `locations.list` answers them: `us-central1`,
/// `asia-northeast3`. Lowercase letters, digits and `-`, as one path
/// segment.
pub fn isLocation(id: []const u8) bool {
    if (id.len == 0 or id.len > 64) return false;
    for (id) |c| switch (c) {
        'a'...'z', '0'...'9', '-' => {},
        else => return false,
    };
    return true;
}

/// A job id goes into the path as one segment. Google documents letters,
/// digits, hyphens and underscores, up to 500 characters; held to visible
/// ASCII without `/` so an unexpected form still reaches the server's own
/// answer.
pub fn isJobId(id: []const u8) bool {
    if (id.len == 0 or id.len > 500) return false;
    for (id) |c| if (c <= ' ' or c >= 0x7f or c == '/') return false;
    return true;
}

/// A page token travels as a query parameter; production's are base64-ish
/// and opaque.
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

test "locations, job ids, tokens and agents" {
    try testing.expect(isLocation("us-central1"));
    try testing.expect(isLocation("asia-northeast3"));
    try testing.expect(!isLocation(""));
    try testing.expect(!isLocation("US-central1"));
    try testing.expect(!isLocation("us central1"));
    try testing.expect(isJobId("zigps-399f5c-http"));
    try testing.expect(isJobId("a_b-C.4"));
    try testing.expect(!isJobId(""));
    try testing.expect(!isJobId("a/b"));
    try testing.expect(!isJobId("a b"));
    try testing.expect(isPageToken("CsABCq8BU1BB=="));
    try testing.expect(!isPageToken("a b"));
    try testing.expect(!isPageToken(""));
    try testing.expect(isUserAgent("zig-gcp-scheduler/0.57"));
    try testing.expect(!isUserAgent("a\nb"));
}
