//! What the client checks before sending, so a bad name costs no request.

const std = @import("std");
const core = @import("core");

/// The largest page Compute answers, and its default (measured
/// 2026-11-03: machine types and public images came 500 to a page).
pub const max_page_size = 500;

/// Serial ports a VM has: 1 to 4 (production refused 9, "Must be less
/// than or equal to 4").
pub const serial_ports = .{ .min = 1, .max = 4 };

/// A zone id, `us-central1-a`: lowercase letters, digits and `-`, one
/// path segment. Production answers a zone it does not have with 400
/// "Unknown zone.", which the client leaves to it.
pub fn isZone(id: []const u8) bool {
    if (id.len == 0 or id.len > 63) return false;
    if (id[0] < 'a' or id[0] > 'z') return false;
    for (id) |c| switch (c) {
        'a'...'z', '0'...'9', '-' => {},
        else => return false,
    };
    return true;
}

/// A resource name as Compute takes them, RFC 1035: a lowercase letter,
/// then up to 62 lowercase letters, digits and `-`, not ending in `-`
/// (production refused `Bad_Name` with this regex in its message).
/// Instances, machine types, images, families and operations all fit.
pub fn isName(name: []const u8) bool {
    if (name.len == 0 or name.len > 63) return false;
    if (name[0] < 'a' or name[0] > 'z') return false;
    if (name[name.len - 1] == '-') return false;
    for (name) |c| switch (c) {
        'a'...'z', '0'...'9', '-' => {},
        else => return false,
    };
    return true;
}

/// A project an image lives in, `debian-cloud`, or the client's own.
pub fn isProject(id: []const u8) bool {
    return core.names.isProjectId(id);
}

/// A page token travels as a query parameter; production's are opaque.
pub fn isPageToken(token: []const u8) bool {
    if (token.len == 0) return false;
    for (token) |c| if (c <= ' ' or c >= 0x7f) return false;
    return true;
}

/// A guest attribute query path, `namespace/` or `namespace/key`:
/// visible ASCII, no spaces. It travels as a query parameter.
pub fn isQueryPath(path: []const u8) bool {
    if (path.len == 0 or path.len > 512) return false;
    for (path) |c| if (c <= ' ' or c >= 0x7f) return false;
    return true;
}

/// A filter or an order travels percent-encoded, so any printable ASCII
/// will do; what it means is Compute's to judge.
pub fn isListExpression(text: []const u8) bool {
    if (text.len == 0 or text.len > 4096) return false;
    for (text) |c| if (c < ' ' or c >= 0x7f) return false;
    return true;
}

/// A user agent goes into a header, so it must be printable ASCII.
pub fn isUserAgent(agent: []const u8) bool {
    if (agent.len == 0) return false;
    for (agent) |c| if (c < ' ' or c >= 0x7f) return false;
    return true;
}

const testing = std.testing;

test "zones and names" {
    try testing.expect(isZone("us-central1-a"));
    try testing.expect(!isZone(""));
    try testing.expect(!isZone("US-central1-a"));
    try testing.expect(!isZone("1us"));
    try testing.expect(!isZone("us central1"));
    try testing.expect(!isZone("us-central1-a/x"));
    try testing.expect(isName("zigps-m0-11031830-a"));
    try testing.expect(isName("operation-1793730664860-65f63771a0c50-6411bc86-75804f1f"));
    try testing.expect(isName("e2-micro"));
    try testing.expect(!isName("Bad_Name"));
    try testing.expect(!isName("a-"));
    try testing.expect(!isName("-a"));
    try testing.expect(!isName("1a"));
    var long: [64]u8 = undefined;
    @memset(&long, 'a');
    try testing.expect(!isName(&long));
    try testing.expect(isName(long[0..63]));
}

test "projects, tokens, paths, expressions and agents" {
    try testing.expect(isProject("debian-cloud"));
    try testing.expect(!isProject("Debian Cloud"));
    try testing.expect(isPageToken("Cg5hMi1tZWdhZ3B1LTE2Zw=="));
    try testing.expect(!isPageToken(""));
    try testing.expect(!isPageToken("a b"));
    try testing.expect(isQueryPath("zigps/"));
    try testing.expect(isQueryPath("zigps/probe"));
    try testing.expect(!isQueryPath("a b"));
    try testing.expect(isListExpression("labels.tool = compute-m0"));
    try testing.expect(!isListExpression("a\nb"));
    try testing.expect(!isListExpression(""));
    try testing.expect(isUserAgent("gcp-zig-compute/0.62"));
    try testing.expect(!isUserAgent("a\nb"));
}
