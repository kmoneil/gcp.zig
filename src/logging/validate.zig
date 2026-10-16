//! The limits and naming rules the client checks before sending anything.
//! Ids are checked by character so a name is safe in a URL path and a JSON
//! string and cannot reach another resource; whether it exists is the
//! server's to say.

const std = @import("std");
const core = @import("core");
const types = @import("types.zig");

/// Scopes in one `entries.list`: "A maximum of 100 resources may be
/// specified in a single request."
pub const max_scopes = 100;
/// "The maximum length of a filter is 20,000 characters", comments
/// included. Counted in characters, as the docs say, on the filter as sent.
pub const max_filter_chars = 20_000;
/// The proto and gcloud say 1000, but production served 1001 and 2000 on
/// 2026-10-16, and the API overview allows an int32. The response limit
/// bounds a large page instead.
pub const max_page_size = std.math.maxInt(i32);
/// Bucket and view ids: "limited to 100 characters".
pub const max_id_len = 100;
/// The read count's array holds one time per call.
pub const max_read_calls_per_minute = 1024;

/// Project ids and numbers, as every module checks them.
pub const isProjectId = core.names.isProjectId;

/// Folder and organization ids are decimal numbers.
pub fn isNumericId(id: []const u8) bool {
    if (id.len == 0 or id.len > 32) return false;
    for (id) |c| if (!std.ascii.isDigit(c)) return false;
    return true;
}

/// Billing account ids: three groups of six letters or digits, joined by
/// hyphens, such as "012345-567890-ABCDEF".
pub fn isBillingAccountId(id: []const u8) bool {
    if (id.len != 20) return false;
    for (id, 0..) |c, i| {
        if (i == 6 or i == 13) {
            if (c != '-') return false;
        } else if (!std.ascii.isAlphanumeric(c)) return false;
    }
    return true;
}

pub fn isParent(parent: types.Parent) bool {
    return switch (parent) {
        .project => |id| isProjectId(id),
        .folder, .organization => |id| isNumericId(id),
        .billing_account => |id| isBillingAccountId(id),
    };
}

/// Locations: "global", or a region such as "europe-west1": lowercase
/// letters, digits and hyphens.
pub fn isLocation(text: []const u8) bool {
    if (text.len == 0 or text.len > 63) return false;
    for (text) |c| switch (c) {
        'a'...'z', '0'...'9', '-' => {},
        else => return false,
    };
    // "-" alone is the wildcard of a bucket list, never a location.
    return !std.mem.eql(u8, text, "-");
}

/// Bucket ids: letters, digits, `_`, `-` and `.`, up to 100, as
/// "_Default" and "_Required" are.
pub fn isBucketId(id: []const u8) bool {
    if (id.len == 0 or id.len > max_id_len) return false;
    for (id) |c| switch (c) {
        'A'...'Z', 'a'...'z', '0'...'9', '_', '-', '.' => {},
        else => return false,
    };
    return true;
}

/// View ids: "up to 100 characters of letters, digits, `_` and `-`".
pub fn isViewId(id: []const u8) bool {
    if (id.len == 0 or id.len > max_id_len) return false;
    for (id) |c| switch (c) {
        'A'...'Z', 'a'...'z', '0'...'9', '_', '-' => {},
        else => return false,
    };
    return true;
}

pub fn isBucketName(name: types.BucketName) bool {
    return isParent(name.parent) and isLocation(name.location) and isBucketId(name.bucket);
}

pub fn isViewName(name: types.ViewName) bool {
    return isParent(name.parent) and isLocation(name.location) and isBucketId(name.bucket) and isViewId(name.view);
}

pub fn isScope(scope: types.Scope) bool {
    return switch (scope) {
        .parent => |p| isParent(p),
        .view => |v| isViewName(v),
    };
}

/// A value the module writes into a filter: UTF-8, with no control
/// character but a tab. Production read `\"`, `\\`, `\t` and `é` on
/// 2026-10-16; other control characters were not tried.
pub fn isClauseValue(text: []const u8) bool {
    if (!std.unicode.utf8ValidateSlice(text)) return false;
    for (text) |c| if ((c < ' ' and c != '\t') or c == 0x7f) return false;
    return true;
}

/// Characters, as the filter limit counts them. `text` is valid UTF-8.
pub fn charCount(text: []const u8) usize {
    var n: usize = 0;
    for (text) |c| {
        // Every byte but a continuation byte starts a character.
        if (c & 0xC0 != 0x80) n += 1;
    }
    return n;
}

pub fn isUserAgent(text: []const u8) bool {
    if (text.len == 0) return false;
    for (text) |c| if (c < ' ' or c >= 0x7f) return false;
    return true;
}

const testing = std.testing;
const repeat = core.testing.repeat;

test "parents" {
    try testing.expect(isParent(.{ .project = "my-project" }));
    try testing.expect(isParent(.{ .project = "example.com:my-project" }));
    try testing.expect(!isParent(.{ .project = "a/b" }));
    try testing.expect(!isParent(.{ .project = "" }));
    try testing.expect(isParent(.{ .folder = "123456789012" }));
    try testing.expect(!isParent(.{ .folder = "12a" }));
    try testing.expect(!isParent(.{ .folder = "" }));
    try testing.expect(!isParent(.{ .organization = repeat("1", 33) }));
    try testing.expect(isParent(.{ .organization = repeat("1", 32) }));
    try testing.expect(isParent(.{ .billing_account = "012345-567890-ABCDEF" }));
    try testing.expect(!isParent(.{ .billing_account = "012345-567890-ABCDE" }));
    try testing.expect(!isParent(.{ .billing_account = "012345_567890-ABCDEF" }));
    try testing.expect(!isParent(.{ .billing_account = "012345-567890/ABCDEF" }));
    try testing.expect(!isParent(.{ .billing_account = "01234--567890-ABCDEF" }));
}

test "locations, buckets and views" {
    try testing.expect(isLocation("global"));
    try testing.expect(isLocation("europe-west1"));
    try testing.expect(!isLocation("-"));
    try testing.expect(!isLocation("Europe"));
    try testing.expect(!isLocation("eu/x"));
    try testing.expect(!isLocation(""));
    try testing.expect(!isLocation(repeat("a", 64)));
    try testing.expect(isLocation(repeat("a", 63)));
    try testing.expect(isBucketId("_Default"));
    try testing.expect(isBucketId("my.bucket-1"));
    try testing.expect(!isBucketId("a/b"));
    try testing.expect(!isBucketId(""));
    try testing.expect(isBucketId(repeat("b", 100)));
    try testing.expect(!isBucketId(repeat("b", 101)));
    try testing.expect(isViewId("_AllLogs"));
    try testing.expect(!isViewId("a.b"));
    try testing.expect(!isViewId(repeat("v", 101)));
    try testing.expect(isViewId(repeat("v", 100)));
    try testing.expect(isScope(.{ .view = .{ .parent = .{ .project = "p" }, .location = "global", .bucket = "_Default", .view = "_AllLogs" } }));
    try testing.expect(!isScope(.{ .view = .{ .parent = .{ .project = "p" }, .location = "global", .bucket = "_Default", .view = "a b" } }));
    try testing.expect(!isScope(.{ .view = .{ .parent = .{ .project = "p" }, .location = "-", .bucket = "_Default", .view = "v" } }));
}

test "clause values and character counts" {
    try testing.expect(isClauseValue("run.googleapis.com/stderr"));
    try testing.expect(isClauseValue("caf\u{e9} \"quoted\" \\"));
    try testing.expect(isClauseValue(""));
    try testing.expect(isClauseValue("a\tb"));
    try testing.expect(!isClauseValue("a\nb"));
    try testing.expect(!isClauseValue("a\x01b"));
    try testing.expect(!isClauseValue("a\x7fb"));
    try testing.expect(!isClauseValue("\xff"));
    try testing.expectEqual(4, charCount("caf\u{e9}"));
    try testing.expectEqual(1, charCount("\u{1F600}"));
    try testing.expectEqual(0, charCount(""));
}
