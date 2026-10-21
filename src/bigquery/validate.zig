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

/// A query's text: UTF-8, and not empty. Its length is the server's to
/// refuse, in its words.
pub fn isQuery(text: []const u8) bool {
    return text.len > 0 and std.unicode.utf8ValidateSlice(text);
}

/// A request id: at most 36 ASCII characters, as BigQuery takes one;
/// printable, so it travels in JSON as it is.
pub fn isRequestId(id: []const u8) bool {
    if (id.len == 0 or id.len > max_request_id_len) return false;
    for (id) |c| if (c <= ' ' or c >= 0x7f) return false;
    return true;
}

pub const max_request_id_len = 36;
/// The most labels a job takes.
pub const max_labels = 64;
/// The most characters in a label's key or value.
pub const max_label_len = 63;

/// A label key or value as BigQuery takes one: lowercase letters, digits,
/// `_`, `-` and any non-ASCII letter, at most 63 characters; a key not
/// empty and starting with a letter.
pub fn isLabelText(text: []const u8, is_key: bool) bool {
    if (!std.unicode.utf8ValidateSlice(text)) return false;
    const chars = std.unicode.utf8CountCodepoints(text) catch return false;
    if (chars > max_label_len) return false;
    if (is_key and (text.len == 0 or !(std.ascii.isLower(text[0]) or text[0] >= 0x80))) return false;
    for (text) |c| switch (c) {
        'a'...'z', '0'...'9', '_', '-', 0x80...0xff => {},
        else => return false,
    };
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

test "queries, request ids and labels" {
    try testing.expect(isQuery("SELECT 1"));
    try testing.expect(isQuery("SELECT 'é'"));
    try testing.expect(!isQuery(""));
    try testing.expect(!isQuery("SELECT '\xff'"));
    try testing.expect(isRequestId("2f1c6a52-1b4e-4c3d-9a0b-6e5f4d3c2b1a"));
    try testing.expect(isRequestId("zigps-828161-rid"));
    try testing.expect(!isRequestId(@import("core").testing.repeat("a", 37)));
    try testing.expect(isRequestId(@import("core").testing.repeat("a", 36)));
    try testing.expect(!isRequestId("a b"));
    try testing.expect(!isRequestId(""));
    try testing.expect(isLabelText("team", true));
    try testing.expect(isLabelText("é-1_x", true));
    try testing.expect(isLabelText("", false));
    try testing.expect(isLabelText("1", false));
    try testing.expect(!isLabelText("", true));
    try testing.expect(!isLabelText("1x", true));
    try testing.expect(!isLabelText("_x", true));
    try testing.expect(!isLabelText("Team", true));
    try testing.expect(!isLabelText("a.b", false));
    try testing.expect(isLabelText(@import("core").testing.repeat("é", 63), false));
    try testing.expect(!isLabelText(@import("core").testing.repeat("a", 64), false));
    try testing.expect(!isLabelText("\xff", false));
}
