//! What the client checks before sending, so a bad name costs no request.

const std = @import("std");

/// A dataset id as BigQuery takes one: letters, digits and underscores, at
/// most 1,024 of them.
pub fn isDatasetId(id: []const u8) bool {
    if (id.len == 0 or id.len > 1024) return false;
    for (id) |c| switch (c) {
        'a'...'z', 'A'...'Z', '0'...'9', '_' => {},
        else => return false,
    };
    return true;
}

/// A table id: Unicode letters, marks, numbers, connectors, dashes and
/// spaces, at most 1,024 bytes, so held to valid UTF-8 without control
/// characters, `/`, or the characters that would make it no id at all;
/// production refuses what its rule refuses, in its words. A partition
/// decorator (`t$20190123`) is taken.
pub fn isTableId(id: []const u8) bool {
    if (id.len == 0 or id.len > 1024) return false;
    if (!std.unicode.utf8ValidateSlice(id)) return false;
    for (id) |c| if (c < ' ' or c == 0x7f or c == '/') return false;
    return true;
}

/// A job id: letters, digits, underscores and dashes, at most 1,024.
pub fn isJobId(id: []const u8) bool {
    if (id.len == 0 or id.len > 1024) return false;
    for (id) |c| switch (c) {
        'a'...'z', 'A'...'Z', '0'...'9', '_', '-' => {},
        else => return false,
    };
    return true;
}

/// A location: `US`, `EU`, or a region such as `us-central1`: letters,
/// digits and dashes, one segment.
pub fn isLocation(location: []const u8) bool {
    if (location.len == 0 or location.len > 64) return false;
    for (location) |c| switch (c) {
        'a'...'z', 'A'...'Z', '0'...'9', '-' => {},
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

/// A label filter (`labels.team:data labels.active`): printable ASCII, spaces
/// between terms.
pub fn isLabelFilter(filter: []const u8) bool {
    if (filter.len == 0 or filter.len > 1024) return false;
    for (filter) |c| if (c < ' ' or c >= 0x7f) return false;
    return true;
}

/// A user agent goes into a header, so it must be printable ASCII.
pub fn isUserAgent(agent: []const u8) bool {
    if (agent.len == 0) return false;
    for (agent) |c| if (c < ' ' or c >= 0x7f) return false;
    return true;
}

const testing = std.testing;

test "ids, locations and tokens: what goes into a request" {
    try testing.expect(isDatasetId("samples"));
    try testing.expect(isDatasetId("zigps_828161"));
    try testing.expect(!isDatasetId("zigps-828161"));
    try testing.expect(!isDatasetId(""));
    try testing.expect(!isDatasetId(@import("core").testing.repeat("a", 1025)));
    try testing.expect(isTableId("shakespeare"));
    try testing.expect(isTableId("events$20261021"));
    try testing.expect(isTableId("ventas 2026 é"));
    try testing.expect(!isTableId("a/b"));
    try testing.expect(!isTableId("a\nb"));
    try testing.expect(!isTableId("\xff"));
    try testing.expect(isJobId("job_DvNFJ2rNqDLzTWHXLPb1Uult0LcS"));
    try testing.expect(isJobId("bqjob_r1_2-3"));
    try testing.expect(!isJobId("job x"));
    try testing.expect(!isJobId("US.job"));
    try testing.expect(isLocation("US"));
    try testing.expect(isLocation("us-central1"));
    try testing.expect(!isLocation("us central1"));
    try testing.expect(!isLocation(""));
    try testing.expect(isPageToken("BFXQ3DHYNTAA"));
    try testing.expect(!isPageToken("a b"));
    try testing.expect(isLabelFilter("labels.team:data labels.active"));
    try testing.expect(!isLabelFilter("labels.a\n"));
    try testing.expect(isUserAgent("zig-gcp-bigquery/0.55"));
    try testing.expect(!isUserAgent("a\x00"));
}
