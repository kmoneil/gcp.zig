//! What the client checks before sending, so a bad name costs no request.

const std = @import("std");

/// A location: `us`, `europe` or a region such as `us-east1` (production
/// takes `US` too, measured): letters, digits and dashes, one segment.
/// `-` is refused: production has no "every location" for configs
/// ("does not yet support location: unknown", measured).
pub fn isLocation(location: []const u8) bool {
    if (location.len == 0 or location.len > 64) return false;
    if (std.mem.eql(u8, location, "-")) return false;
    for (location) |c| switch (c) {
        'a'...'z', 'A'...'Z', '0'...'9', '-' => {},
        else => return false,
    };
    return true;
}

/// A config's or a run's id: production's are UUIDs. Letters, digits,
/// `-` and `_`, at most 256: one path segment that needs no escaping.
pub fn isResourceId(id: []const u8) bool {
    if (id.len == 0 or id.len > 256) return false;
    for (id) |c| switch (c) {
        'a'...'z', 'A'...'Z', '0'...'9', '-', '_' => {},
        else => return false,
    };
    return true;
}

/// A data source id such as `scheduled_query`: lower case letters,
/// digits, `_` and `-`.
pub fn isDataSourceId(id: []const u8) bool {
    if (id.len == 0 or id.len > 128) return false;
    for (id) |c| switch (c) {
        'a'...'z', '0'...'9', '_', '-' => {},
        else => return false,
    };
    return true;
}

/// A page token travels as a query parameter; production's are opaque.
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

test "locations, ids, data sources and tokens: what goes into a request" {
    try testing.expect(isLocation("us"));
    try testing.expect(isLocation("US"));
    try testing.expect(isLocation("europe"));
    try testing.expect(isLocation("us-east1"));
    try testing.expect(!isLocation("-"));
    try testing.expect(!isLocation(""));
    try testing.expect(!isLocation("us east1"));
    try testing.expect(!isLocation("us/east1"));
    try testing.expect(isResourceId("6ad99c4e-0000-2bb7-b042-14223bbd2862"));
    try testing.expect(isResourceId("zigps_x-1"));
    try testing.expect(!isResourceId(""));
    try testing.expect(!isResourceId("a/b"));
    try testing.expect(!isResourceId("a:b"));
    try testing.expect(!isResourceId(@import("core").testing.repeat("a", 257)));
    try testing.expect(isDataSourceId("scheduled_query"));
    try testing.expect(isDataSourceId("google_cloud_storage"));
    try testing.expect(!isDataSourceId("Scheduled"));
    try testing.expect(!isDataSourceId(""));
    try testing.expect(isPageToken("CgwI"));
    try testing.expect(!isPageToken("a b"));
    try testing.expect(isUserAgent("gcp-zig-datatransfer/0.60"));
    try testing.expect(!isUserAgent("a\n"));
}
