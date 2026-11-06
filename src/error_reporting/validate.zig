//! The limits and naming rules the client checks before sending. A name
//! that would read as something else inside a URL path is never sent.

const std = @import("std");
const core = @import("core");

/// The most calls a minute a client's budget may count: Error Reporting's
/// per-user quotas are 60 a minute each, for event data (group stats and
/// events) and for group metadata (a group's read and update).
pub const max_calls_per_minute = 60;

/// The longest service filter value this client sends.
pub const max_filter_bytes = 1024;

/// The largest request body production takes, measured exactly on
/// 2026-11-06: 1,048,576 bytes taken, one more refused ("Request payload
/// size exceeds the limit: 1048576 bytes."), whitespace counted. Only a
/// group's update sends a body.
pub const max_body_bytes = 1_048_576;

/// A project as the API names it: a project number, or a project id, which
/// is 6 to 30 lowercase letters, digits and hyphens for a new project and
/// may be older, such as the domain-scoped `example.com:my-project`.
/// Checked loosely, so the name is safe as one path segment; the server
/// decides whether it exists.
pub fn isProject(ref: []const u8) bool {
    if (ref.len == 0 or ref.len > 100) return false;
    if (!std.ascii.isLower(ref[0]) and !std.ascii.isDigit(ref[0])) return false;
    for (ref) |c| switch (c) {
        'a'...'z', '0'...'9', '-', '.', ':' => {},
        else => return false,
    };
    return true;
}

/// A group id as Error Reporting assigns them: base64url characters,
/// "CNDdw-bLr_rPjQE" when measured. An id that names no group is the
/// server's to refuse.
pub fn isGroupId(id: []const u8) bool {
    if (id.len == 0 or id.len > 256) return false;
    for (id) |c| switch (c) {
        'A'...'Z', 'a'...'z', '0'...'9', '-', '_' => {},
        else => return false,
    };
    return true;
}

/// A location: a region such as `us-central1`, `global`, or `-` for group
/// stats from every region.
pub fn isLocation(location: []const u8) bool {
    if (std.mem.eql(u8, location, "-")) return true;
    if (location.len == 0 or location.len > 63 or !std.ascii.isLower(location[0])) return false;
    for (location) |c| switch (c) {
        'a'...'z', '0'...'9', '-' => {},
        else => return false,
    };
    return true;
}

/// Why a service filter value will not be sent, or null. It travels in a
/// query string, escaped, so only what no service name holds is refused.
pub fn filterProblem(value: []const u8) ?[]const u8 {
    if (value.len == 0) return "invalid service filter: an empty value; leave it null to match any";
    if (value.len > max_filter_bytes) return "invalid service filter: at most 1024 bytes";
    if (!std.unicode.utf8ValidateSlice(value)) return "invalid service filter: not UTF-8";
    for (value) |c| if (c < 0x20 or c == 0x7f) return "invalid service filter: a control character";
    return null;
}

/// Why a tracking issue's URL will not be sent, or null. Production stores
/// any string as one (measured 2026-11-06: `javascript:` links, newlines,
/// no scheme, an empty one), so this client sends only web links: an
/// absolute `http` or `https` URL with a host, in the characters RFC 3986
/// allows, anything else percent-encoded.
pub fn trackingIssueProblem(url: []const u8) ?[]const u8 {
    for (url, 0..) |c, i| {
        if (!isUriChar(c)) return "a character a URL must percent-encode (RFC 3986): a space, a control character, non-ASCII, or one of \"<>\\^`{|}";
        if (c == '%' and (i + 2 >= url.len or !std.ascii.isHex(url[i + 1]) or !std.ascii.isHex(url[i + 2]))) return "a % not followed by two hex digits";
    }
    const web_link = "expected an absolute http or https URL with a host";
    const uri = std.Uri.parse(url) catch return web_link;
    if (!std.ascii.eqlIgnoreCase(uri.scheme, "http") and !std.ascii.eqlIgnoreCase(uri.scheme, "https")) return web_link;
    // std.Uri gives a host only when there is one: `https://:443/` and
    // `https://user@/` are no URL to it.
    if (uri.host == null) return web_link;
    return null;
}

/// The characters RFC 3986 writes a URI in: unreserved, reserved and `%`.
fn isUriChar(c: u8) bool {
    return switch (c) {
        'A'...'Z', 'a'...'z', '0'...'9', '-', '.', '_', '~' => true,
        ':', '/', '?', '#', '[', ']', '@' => true,
        '!', '$', '&', '\'', '(', ')', '*', '+', ',', ';', '=' => true,
        '%' => true,
        else => false,
    };
}

/// A quota project, held to core's rule for the header.
pub fn isQuotaProject(id: []const u8) bool {
    return core.names.isProjectId(id);
}

/// A page token as production writes them: printable ASCII.
pub fn isPageToken(token: []const u8) bool {
    if (token.len == 0) return false;
    for (token) |c| if (c <= ' ' or c >= 0x7f) return false;
    return true;
}

/// A user agent goes into a header, so it must be printable ASCII.
pub fn isUserAgent(agent: []const u8) bool {
    if (agent.len == 0) return false;
    for (agent) |c| if (c < 0x20 or c > 0x7e) return false;
    return true;
}

const testing = std.testing;
const repeat = core.testing.repeat;

test "isProject: numbers, ids old and new; nothing a path would read otherwise" {
    for ([_][]const u8{ "82150720798", "extractctl", "my-project-1", "example.com:my-project", "a" }) |ok| try testing.expect(isProject(ok));
    for ([_][]const u8{ "", "Bad_Id!", "Extractctl", "a/b", "a b", "a%41", "a?b", "-a", ".a", "a_b", "é" }) |bad| try testing.expect(!isProject(bad));
    try testing.expect(isProject(repeat("a", 100)));
    try testing.expect(!isProject(repeat("a", 101)));
}

test "isGroupId: base64url, as production's are" {
    for ([_][]const u8{ "CNDdw-bLr_rPjQE", "COiYvODSyMz2Bg", "a" }) |ok| try testing.expect(isGroupId(ok));
    for ([_][]const u8{ "", "a/b", "a b", "a%2F", "a.b", "a+b", "a=" }) |bad| try testing.expect(!isGroupId(bad));
    try testing.expect(isGroupId(repeat("A", 256)));
    try testing.expect(!isGroupId(repeat("A", 257)));
}

test "isLocation: a region, global, or every region" {
    for ([_][]const u8{ "-", "global", "us-central1", "europe-west3" }) |ok| try testing.expect(isLocation(ok));
    for ([_][]const u8{ "", "--", "US", "us/central", "1us", "us central", repeat("a", 64) }) |bad| try testing.expect(!isLocation(bad));
}

test "filterProblem" {
    try testing.expectEqual(null, filterProblem("checkout"));
    try testing.expectEqual(null, filterProblem("v1.2 (é)"));
    try testing.expectEqual(null, filterProblem(repeat("x", max_filter_bytes)));
    try testing.expect(std.mem.indexOf(u8, filterProblem("").?, "empty") != null);
    try testing.expect(std.mem.indexOf(u8, filterProblem(repeat("x", max_filter_bytes + 1)).?, "1024") != null);
    try testing.expect(std.mem.indexOf(u8, filterProblem("\xff").?, "UTF-8") != null);
    try testing.expect(std.mem.indexOf(u8, filterProblem("a\tb").?, "control") != null);
    try testing.expect(std.mem.indexOf(u8, filterProblem("a\x7f").?, "control") != null);
}

test "trackingIssueProblem: web links only, as RFC 3986 writes them" {
    for ([_][]const u8{
        "https://example.com/issues/1",
        "http://example.com",
        "HTTPS://EXAMPLE.COM/Issues/ZIGPS-313",
        "https://tracker.example.com:8443/browse/BUG-1?focus=comments#c2",
        "https://example.com/issues?id=313&x=a%20b#c",
        "https://user@example.com/a",
        "http://[2001:db8::1]/issue/7",
        "https://example.com/%C3%A9",
        "https://example.com/a(b)!$&'*+,;=:@~._-",
    }) |ok| {
        if (trackingIssueProblem(ok)) |p| {
            std.debug.print("{s}: {s}\n", .{ ok, p });
            return error.TestUnexpectedResult;
        }
    }
    const scheme = "expected an absolute http or https URL with a host";
    const chars = "a character a URL must percent-encode";
    const cases = [_]struct { []const u8, []const u8 }{
        .{ "", scheme },
        .{ "zigps-not-a-url", scheme },
        .{ "example.com/issues/1", scheme },
        .{ "/issues/1", scheme },
        .{ "javascript:alert(313)", scheme },
        .{ "mailto:zigps@example.com", scheme },
        .{ "ftp://example.com/issues/1", scheme },
        .{ "https://", scheme },
        .{ "https:///issues/1", scheme },
        .{ "https:example.com", scheme },
        .{ "https://:443/", scheme },
        .{ "https://user@/a", scheme },
        .{ "https://example.com:port/", scheme },
        .{ " https://example.com", chars },
        .{ "https://example.com/a b", chars },
        .{ "https://example.com/a\nb", chars },
        .{ "https://example.com/a\tb", chars },
        .{ "https://example.com/a\x7f", chars },
        .{ "https://example.com/\xc3\xa9", chars },
        .{ "https://example.com/\"><script>", chars },
        .{ "https://example.com/a\\b", chars },
        .{ "https://example.com/{a}|^`", chars },
        .{ "https://example.com/%", "a % not followed by two hex digits" },
        .{ "https://example.com/%2", "a % not followed by two hex digits" },
        .{ "https://example.com/%zz", "a % not followed by two hex digits" },
    };
    for (cases) |case| {
        const p = trackingIssueProblem(case[0]) orelse {
            std.debug.print("taken: {s}\n", .{case[0]});
            return error.TestUnexpectedResult;
        };
        try testing.expect(std.mem.startsWith(u8, p, case[1]));
    }
}

test "isPageToken and isUserAgent" {
    try testing.expect(isPageToken("EicxMDEwODQxMzg5NjIwNDQ3NzQwNjE3OTIyOTA5Nzg3MzUzMjgwODQ="));
    try testing.expect(!isPageToken(""));
    try testing.expect(!isPageToken("a b"));
    try testing.expect(!isPageToken("é"));
    try testing.expect(isUserAgent("gcp-zig-error_reporting/0.42"));
    try testing.expect(!isUserAgent(""));
    try testing.expect(!isUserAgent("a\r\nb"));
}
