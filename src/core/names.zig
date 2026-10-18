//! Google resource names: the id rules more than one service needs. A rule
//! only one service has (a secret id) stays with that module.

const std = @import("std");
const test_util = @import("testing.zig");

/// Project ids and numbers, including legacy domain-scoped ids such as
/// `example.com:my-project`. Checked loosely, only so the id is safe in a
/// URL and a JSON string; the server decides whether it exists.
pub fn isProjectId(id: []const u8) bool {
    if (id.len == 0 or id.len > 100) return false;
    for (id) |c| switch (c) {
        'A'...'Z', 'a'...'z', '0'...'9', '-', '.', ':', '_' => {},
        else => return false,
    };
    return true;
}

/// Pub/Sub topic and subscription ids: 3 to 255 characters from
/// `[A-Za-z0-9-_.~+%]`, starting with a letter, and not starting with
/// "goog" in any case (the emulator allows "GOOG"; production does not).
/// Pub/Sub names its own; Cloud Storage's notifications name a topic.
pub fn isPubSubId(id: []const u8) bool {
    if (id.len < 3 or id.len > 255) return false;
    if (!std.ascii.isAlphabetic(id[0])) return false;
    if (std.ascii.startsWithIgnoreCase(id, "goog")) return false;
    for (id) |c| switch (c) {
        'A'...'Z', 'a'...'z', '0'...'9', '-', '_', '.', '~', '+', '%' => {},
        else => return false,
    };
    return true;
}

/// A Cloud KMS key's full name, `projects/P/locations/L/keyRings/R/cryptoKeys/K`,
/// or one of its versions', the same with `/cryptoKeyVersions/V` after it,
/// split into its parts. Cloud Storage and Secret Manager name a key for
/// their encryption; the `kms` module names keys and versions.
pub const KmsKeyName = struct {
    project: []const u8,
    location: []const u8,
    key_ring: []const u8,
    key: []const u8,
    /// Null for a key's name.
    version: ?[]const u8 = null,

    /// The parts of `name`, which point into it, or null when it is of
    /// neither form or a part is empty. What each part may hold is left to
    /// the caller, each service having its own rule.
    pub fn parse(name: []const u8) ?KmsKeyName {
        var parts = std.mem.splitScalar(u8, name, '/');
        var values: [5][]const u8 = undefined;
        const fixed = [_][]const u8{ "projects", "locations", "keyRings", "cryptoKeys", "cryptoKeyVersions" };
        for (fixed, 0..) |literal, i| {
            const word = parts.next() orelse return if (i == 4) .{
                .project = values[0],
                .location = values[1],
                .key_ring = values[2],
                .key = values[3],
            } else null;
            if (!std.mem.eql(u8, word, literal)) return null;
            const value = parts.next() orelse return null;
            if (value.len == 0) return null;
            values[i] = value;
        }
        if (parts.next() != null) return null;
        return .{ .project = values[0], .location = values[1], .key_ring = values[2], .key = values[3], .version = values[4] };
    }
};

const testing = std.testing;

test "KmsKeyName: a key's name and a version's, every part non-empty, nothing after" {
    const key = KmsKeyName.parse("projects/p/locations/us-central1/keyRings/r-1/cryptoKeys/k_1").?;
    try testing.expectEqualStrings("p", key.project);
    try testing.expectEqualStrings("us-central1", key.location);
    try testing.expectEqualStrings("r-1", key.key_ring);
    try testing.expectEqualStrings("k_1", key.key);
    try testing.expectEqual(null, key.version);

    const version = KmsKeyName.parse("projects/p/locations/global/keyRings/r/cryptoKeys/k/cryptoKeyVersions/12").?;
    try testing.expectEqualStrings("global", version.location);
    try testing.expectEqualStrings("k", version.key);
    try testing.expectEqualStrings("12", version.version.?);

    for ([_][]const u8{
        "",
        "projects/p/locations/l/keyRings/r/cryptoKeys",
        "projects/p/locations/l/keyRings/r/cryptoKeys/",
        "projects/p/locations/l/keyRings/r/cryptoKeys/k/",
        "projects/p/locations/l/keyRings/r/cryptoKeys/k/cryptoKeyVersions",
        "projects/p/locations/l/keyRings/r/cryptoKeys/k/cryptoKeyVersions/",
        "projects/p/locations/l/keyRings/r/cryptoKeys/k/cryptoKeyVersions/1/x",
        "projects/p/locations/l/keyRings/r/cryptoKeys/k/versions/1",
        "projects//locations/l/keyRings/r/cryptoKeys/k",
        "/projects/p/locations/l/keyRings/r/cryptoKeys/k",
        "Projects/p/locations/l/keyRings/r/cryptoKeys/k",
        "projects/p/locations/l/keyrings/r/cryptoKeys/k",
        "projects/p/locations/l/keyRings/r",
    }) |name| try testing.expectEqual(null, KmsKeyName.parse(name));
}

fn kmsKeyNameProperty(_: void, input: []const u8) !void {
    const parsed = KmsKeyName.parse(input) orelse return;
    // A name that parses is its parts joined again, exactly.
    var buf: [4096]u8 = undefined;
    var w: std.Io.Writer = .fixed(&buf);
    w.print("projects/{s}/locations/{s}/keyRings/{s}/cryptoKeys/{s}", .{ parsed.project, parsed.location, parsed.key_ring, parsed.key }) catch return;
    if (parsed.version) |v| w.print("/cryptoKeyVersions/{s}", .{v}) catch return;
    try testing.expectEqualStrings(input, w.buffered());
    for ([_][]const u8{ parsed.project, parsed.location, parsed.key_ring, parsed.key, parsed.version orelse "v" }) |part| {
        try testing.expect(part.len > 0);
        try testing.expect(std.mem.indexOfScalar(u8, part, '/') == null);
    }
}

test "fuzz KmsKeyName: a name that parses is its parts, and every part is one segment" {
    try test_util.fuzzBytes({}, kmsKeyNameProperty, .{ .corpus = &.{
        "projects/p/locations/l/keyRings/r/cryptoKeys/k",
        "projects/p/locations/l/keyRings/r/cryptoKeys/k/cryptoKeyVersions/1",
        "projects/p/locations/l/keyRings/r/cryptoKeys//cryptoKeyVersions/1",
    } });
}

test "Pub/Sub ids: the documented rules at their boundaries" {
    try testing.expect(isPubSubId("abc"));
    try testing.expect(!isPubSubId("ab"));
    try testing.expect(isPubSubId(test_util.repeat("a", 255)));
    try testing.expect(!isPubSubId(test_util.repeat("a", 256)));
    try testing.expect(isPubSubId("a.b~c_d-e+f%41"));
    try testing.expect(isPubSubId("gooXfoo"));
    try testing.expect(isPubSubId("xgoog"));
    try testing.expect(!isPubSubId("googfoo"));
    try testing.expect(!isPubSubId("goog"));
    // Production rejects any case; the emulator accepts this one.
    try testing.expect(!isPubSubId("GOOGfoo"));
    try testing.expect(!isPubSubId("GoOgle-topic"));
    try testing.expect(!isPubSubId("1abc"));
    try testing.expect(!isPubSubId("-abc"));
    try testing.expect(!isPubSubId("ab/c"));
    try testing.expect(!isPubSubId("ab c"));
    try testing.expect(!isPubSubId("mi-t\xc3\xb3pico"));
    try testing.expect(!isPubSubId(""));
}

test "project ids" {
    try testing.expect(isProjectId("test"));
    try testing.expect(isProjectId("my-project-123"));
    try testing.expect(isProjectId("123456789123"));
    try testing.expect(isProjectId("example.com:my-project"));
    try testing.expect(!isProjectId(""));
    try testing.expect(!isProjectId("a/b"));
    try testing.expect(!isProjectId("a b"));
    try testing.expect(!isProjectId("a\"b"));
    try testing.expect(!isProjectId(test_util.repeat("x", 101)));
}

fn projectIdProperty(_: void, input: []const u8) !void {
    // The rule, stated independently of the implementation.
    var allowed = input.len > 0 and input.len <= 100;
    for (input) |c| allowed = allowed and (std.ascii.isAlphanumeric(c) or
        c == '-' or c == '.' or c == ':' or c == '_');
    try testing.expectEqual(allowed, isProjectId(input));
    // So an accepted id cannot redirect a URL or break out of a JSON string.
    if (isProjectId(input)) {
        try testing.expect(std.mem.indexOfAny(u8, input, "/?#\\\"") == null);
        for (input) |c| try testing.expect(c > ' ' and c < 0x7f);
    }
}

test "fuzz project ids: accepts exactly what is safe in a path and a body" {
    try test_util.fuzzBytes({}, projectIdProperty, .{ .corpus = &.{
        "my-project-123",
        "example.com:my-project",
        "",
        "a/b",
        test_util.repeat("x", 101),
        "pro\xc3\xa9ject",
    } });
}
