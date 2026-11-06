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

/// A request id as Compute takes one: a UUID, `8-4-4-4-12` hex digits,
/// not all zeros (the API's documented rule).
pub fn isRequestId(id: []const u8) bool {
    if (id.len != 36) return false;
    var nonzero = false;
    for (id, 0..) |c, i| switch (i) {
        8, 13, 18, 23 => if (c != '-') return false,
        else => {
            if (!std.ascii.isHex(c)) return false;
            if (c != '0') nonzero = true;
        },
    };
    return nonzero;
}

/// A fingerprint as Compute writes them, base64 (`rNhSjTzLR00=`): visible
/// ASCII, not empty.
pub fn isFingerprint(text: []const u8) bool {
    if (text.len == 0 or text.len > 128) return false;
    for (text) |c| if (c <= ' ' or c >= 0x7f) return false;
    return true;
}

/// A disk's device name on a VM: 1 to 63 letters, digits, `-` and `_`
/// (`persistent-disk-0`, `zigps-data`).
pub fn isDeviceName(text: []const u8) bool {
    if (text.len == 0 or text.len > 63) return false;
    for (text) |c| switch (c) {
        'a'...'z', 'A'...'Z', '0'...'9', '-', '_' => {},
        else => return false,
    };
    return true;
}

/// The smallest boot disk Compute makes, in GB.
pub const min_disk_gb = 10;
/// The longest metadata key, in bytes, and the largest value.
pub const max_metadata_key = 127;
pub const max_metadata_value = 256 * 1024;

/// A metadata key: `[a-zA-Z0-9-_]+`, under 128 bytes.
pub fn isMetadataKey(key: []const u8) bool {
    if (key.len == 0 or key.len > max_metadata_key) return false;
    for (key) |c| switch (c) {
        'a'...'z', 'A'...'Z', '0'...'9', '-', '_' => {},
        else => return false,
    };
    return true;
}

/// A label's key or value: lowercase letters, digits, `_`, `-` and any
/// non-ASCII letter, at most 63 characters; a key not empty and starting
/// with a lowercase letter.
pub fn isLabelText(text: []const u8, is_key: bool) bool {
    if (!std.unicode.utf8ValidateSlice(text)) return false;
    const chars = std.unicode.utf8CountCodepoints(text) catch return false;
    if (chars > 63) return false;
    if (is_key and (text.len == 0 or !(std.ascii.isLower(text[0]) or text[0] >= 0x80))) return false;
    for (text) |c| switch (c) {
        'a'...'z', '0'...'9', '_', '-', 0x80...0xff => {},
        else => return false,
    };
    return true;
}

/// A path or URL a body carries (an image, a network, a disk type), a
/// service account's email or an OAuth scope: visible ASCII, no spaces.
/// What it names is Compute's to judge.
pub fn isReference(text: []const u8) bool {
    if (text.len == 0 or text.len > 2048) return false;
    for (text) |c| if (c <= ' ' or c >= 0x7f) return false;
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
    try testing.expect(isUserAgent("gcp-zig-compute/0.68"));
    try testing.expect(!isUserAgent("a\nb"));
}

test "request ids, metadata keys, labels and references" {
    try testing.expect(isRequestId("8068f1b8-03fc-4f7f-a5bd-d5e775aa7212"));
    try testing.expect(isRequestId("8068F1B8-03FC-4F7F-A5BD-D5E775AA7212"));
    try testing.expect(!isRequestId("00000000-0000-0000-0000-000000000000"));
    try testing.expect(!isRequestId("8068f1b8-03fc-4f7f-a5bd-d5e775aa721"));
    try testing.expect(!isRequestId("8068f1b8x03fc-4f7f-a5bd-d5e775aa7212"));
    try testing.expect(!isRequestId("g068f1b8-03fc-4f7f-a5bd-d5e775aa7212"));
    try testing.expect(isMetadataKey("startup-script"));
    try testing.expect(isMetadataKey("enable_OS-login"));
    try testing.expect(!isMetadataKey("a.b"));
    try testing.expect(!isMetadataKey(""));
    var long: [128]u8 = undefined;
    @memset(&long, 'k');
    try testing.expect(!isMetadataKey(&long));
    try testing.expect(isMetadataKey(long[0..127]));
    try testing.expect(isLabelText("purpose", true));
    try testing.expect(isLabelText("gcp-zig-test", false));
    try testing.expect(isLabelText("", false));
    try testing.expect(!isLabelText("", true));
    try testing.expect(!isLabelText("Env", true));
    try testing.expect(!isLabelText("1env", true));
    try testing.expect(!isLabelText("a b", false));
    try testing.expect(isReference("projects/debian-cloud/global/images/family/debian-12"));
    try testing.expect(isReference("https://www.googleapis.com/auth/devstorage.read_write"));
    try testing.expect(!isReference("a b"));
    try testing.expect(!isReference(""));
}
