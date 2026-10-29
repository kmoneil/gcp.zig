//! What the client checks before sending: the names it puts in a path or a
//! header, and the limits of a query and a walk. Each limit is one
//! production measured on 2026-10-17, or the reason it has none.

const std = @import("std");
const core = @import("core");

/// The longest query sent. Production refused a value over 1,000
/// characters and more than about 10 terms itself, in JSON, up to 8,000
/// bytes; a 20,000-byte query drew an HTML 400 from Google's front end.
pub const max_query_bytes = 8_000;

/// The most pages a walk may read.
pub const max_walk_pages = 10_000;

/// The longest pause a walk may take between pages.
pub const max_page_interval_ms = 60_000;

/// A project as `getProject` takes it: a project number (digits that fit a
/// u64), or a project id, which is 6 to 30 lowercase letters, digits and
/// hyphens for a new project and may be older, such as the domain-scoped
/// `example.com:my-project`. Checked loosely, so the name is safe as one
/// path segment; the server decides whether it exists.
pub fn isProjectRef(ref: []const u8) bool {
    if (ref.len == 0 or ref.len > 100) return false;
    if (isNumber(ref)) return true;
    if (!std.ascii.isLower(ref[0]) and !std.ascii.isDigit(ref[0])) return false;
    for (ref) |c| switch (c) {
        'a'...'z', '0'...'9', '-', '.', ':' => {},
        else => return false,
    };
    return true;
}

/// Digits that fit a u64, as project numbers do.
pub fn isNumber(text: []const u8) bool {
    if (text.len == 0) return false;
    for (text) |c| if (!std.ascii.isDigit(c)) return false;
    _ = std.fmt.parseInt(u64, text, 10) catch return false;
    return true;
}

/// A quota project as `QuotaProject.project` takes it, held to core's rule
/// for the header.
pub fn isQuotaProject(id: []const u8) bool {
    return core.names.isProjectId(id);
}

/// Why `query` will not be sent, or null.
pub fn queryProblem(query: []const u8) ?[]const u8 {
    if (query.len > max_query_bytes) return "invalid query: at most 8000 bytes; past that Google's front end answers in HTML";
    if (!std.unicode.utf8ValidateSlice(query)) return "invalid query: not UTF-8";
    for (query) |c| if ((c < 0x20 and c != '\t') or c == 0x7f) return "invalid query: a control character";
    return null;
}

/// A user agent goes into a header, so it must be printable ASCII.
pub fn isUserAgent(agent: []const u8) bool {
    if (agent.len == 0) return false;
    for (agent) |c| if (c < 0x20 or c > 0x7e) return false;
    return true;
}

const testing = std.testing;
const repeat = core.testing.repeat;

test "isProjectRef: numbers, ids old and new; nothing a path would read otherwise" {
    for ([_][]const u8{ "82150720798", "18446744073709551615", "extractctl", "my-project-1", "example.com:my-project", "a" }) |ok|
        try testing.expect(isProjectRef(ok));
    for ([_][]const u8{ "", "Bad_Id!", "Extractctl", "a/b", "a b", "a%41", "a?b", "-a", ".a", "a_b", "é" }) |bad|
        try testing.expect(!isProjectRef(bad));
    // 18446744073709551616 does not fit a number; as an id it starts
    // with a digit, which no id does but a number.
    try testing.expect(isProjectRef("18446744073709551616"));
    try testing.expect(!isNumber("18446744073709551616"));
    try testing.expect(isProjectRef(repeat("a", 100)));
    try testing.expect(!isProjectRef(repeat("a", 101)));
}

test "queryProblem: each refusal, and a tab is a separator" {
    try testing.expectEqual(null, queryProblem(""));
    try testing.expectEqual(null, queryProblem("projectId:extractctl\tstate:ACTIVE"));
    try testing.expectEqual(null, queryProblem("name:été"));
    try testing.expectEqual(null, queryProblem(repeat("x", max_query_bytes)));
    try testing.expect(std.mem.indexOf(u8, queryProblem(repeat("x", max_query_bytes + 1)).?, "8000 bytes") != null);
    try testing.expect(std.mem.indexOf(u8, queryProblem("\xff").?, "UTF-8") != null);
    try testing.expect(std.mem.indexOf(u8, queryProblem("a\nb").?, "control") != null);
    try testing.expect(std.mem.indexOf(u8, queryProblem("a\x7fb").?, "control") != null);
}

test "isUserAgent" {
    try testing.expect(isUserAgent("gcp-zig-resource_manager/0.40"));
    try testing.expect(!isUserAgent(""));
    try testing.expect(!isUserAgent("a\r\nb"));
    try testing.expect(!isUserAgent("é"));
}
