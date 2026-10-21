//! What the client checks before sending, so a bad name costs no request.

const std = @import("std");

/// A location id as v1's `locations.list` answers them (`us-central1`),
/// or `-`, which Cloud Run takes for "every region" on a services or
/// revisions list (measured 2026-10-19, though the issue expected a
/// refusal). Lowercase letters, digits and `-`, one path segment, which
/// `-` alone already is.
pub fn isLocation(id: []const u8) bool {
    if (id.len == 0 or id.len > 64) return false;
    for (id) |c| switch (c) {
        'a'...'z', '0'...'9', '-' => {},
        else => return false,
    };
    return true;
}

/// A service or revision id goes into the path as one segment. Google
/// documents lowercase RFC 1035 names; held to visible ASCII without `/`
/// so an unexpected form still reaches the server's own answer. `-` is
/// taken too: Cloud Run reads `services/-` as every service.
pub fn isResourceId(id: []const u8) bool {
    if (id.len == 0 or id.len > 500) return false;
    for (id) |c| if (c <= ' ' or c >= 0x7f or c == '/') return false;
    return true;
}

/// A page token travels as a query parameter; production's are opaque.
pub fn isPageToken(token: []const u8) bool {
    if (token.len == 0) return false;
    for (token) |c| if (c <= ' ' or c >= 0x7f) return false;
    return true;
}

/// An etag as Cloud Run sends it: printable ASCII, quote characters
/// included (`"CM_g2.../cHJv..."`), passed back as read. Empty is refused:
/// production takes a traffic change without one unguarded.
pub fn isEtag(etag: []const u8) bool {
    if (etag.len == 0 or etag.len > 1024) return false;
    for (etag) |c| if (c < ' ' or c >= 0x7f) return false;
    return true;
}

/// A user agent goes into a header, so it must be printable ASCII.
pub fn isUserAgent(agent: []const u8) bool {
    if (agent.len == 0) return false;
    for (agent) |c| if (c < ' ' or c >= 0x7f) return false;
    return true;
}

const testing = std.testing;

test "locations, resource ids, tokens and agents" {
    try testing.expect(isLocation("us-central1"));
    try testing.expect(isLocation("-"));
    try testing.expect(!isLocation(""));
    try testing.expect(!isLocation("US-central1"));
    try testing.expect(!isLocation("us central1"));
    try testing.expect(isResourceId("zigps-a12c61"));
    try testing.expect(isResourceId("zigps-a12c61-00002-qmv"));
    try testing.expect(isResourceId("-"));
    try testing.expect(!isResourceId(""));
    try testing.expect(!isResourceId("a/b"));
    try testing.expect(!isResourceId("a b"));
    try testing.expect(isPageToken("CsAB=="));
    try testing.expect(!isPageToken("a b"));
    try testing.expect(!isPageToken(""));
    try testing.expect(isUserAgent("zig-gcp-run/0.53"));
    try testing.expect(!isUserAgent("a\nb"));
}
