//! The limits and naming rules the client checks before sending, from the
//! v1 protos and Google's documentation as read on 2026-10-18 (the KMS
//! spec, section 11). Each check returns why a value fails, or null.

const std = @import("std");
const core = @import("core");
const types = @import("types.zig");

/// Key ring, key and import job ids: `[a-zA-Z0-9_-]{1,63}`.
pub const max_id_len = 63;
/// Labels a key may carry.
pub const max_labels = 64;
/// A label key or value, in characters.
pub const max_label_chars = 63;
/// A label key or value, in bytes, as production held Secret Manager's.
pub const max_label_bytes = 128;
/// The shortest and longest time a destroyed version stays restorable.
pub const min_destroy_delay_s: u32 = 24 * std.time.s_per_hour;
pub const max_destroy_delay_s: u32 = 120 * std.time.s_per_day;
/// The shortest and longest automatic rotation period: a day, and 876,000
/// hours (100 years).
pub const min_rotation_s: u32 = 24 * std.time.s_per_hour;
pub const max_rotation_s: u32 = 876_000 * std.time.s_per_hour;
/// The longest filter or order this client sends.
pub const max_query_text = 2048;
/// Plaintext, AAD, data to sign and data to MAC: at most 64 KiB each. HSM
/// keys take 8 KiB of plaintext and AAD together, which the server checks.
pub const max_payload = 64 * 1024;
/// Random bytes come 8 to 1,024 at a time.
pub const min_random_bytes = 8;
pub const max_random_bytes = 1024;

pub fn isProject(id: []const u8) bool {
    return core.names.isProjectId(id);
}

/// A location: a region ("us-central1"), a multi-region ("us", "nam4"),
/// or "global". Checked loosely, so it is safe in a path.
pub fn isLocation(text: []const u8) bool {
    if (text.len == 0 or text.len > 63) return false;
    for (text) |c| switch (c) {
        'a'...'z', '0'...'9', '-' => {},
        else => return false,
    };
    return true;
}

/// A key ring or key id: 1 to 63 letters, digits, `_` and `-`.
pub fn isId(id: []const u8) bool {
    if (id.len == 0 or id.len > max_id_len) return false;
    for (id) |c| switch (c) {
        'A'...'Z', 'a'...'z', '0'...'9', '_', '-' => {},
        else => return false,
    };
    return true;
}

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

/// Why a filter or an order cannot be sent, or null: valid UTF-8, no
/// control characters, at most `max_query_text` bytes. What it says is the
/// server's to judge.
pub fn queryTextProblem(text: []const u8) ?[]const u8 {
    if (text.len > max_query_text) return "a filter or an order is at most 2,048 bytes";
    if (!std.unicode.utf8ValidateSlice(text)) return "a filter or an order is valid UTF-8";
    for (text) |c| if (c < 0x20 or c == 0x7f) return "a filter or an order has no control characters";
    return null;
}

/// Why `key` cannot be a label key, or null when it can. Google holds keys
/// to `[\p{Ll}\p{Lo}][\p{Ll}\p{Lo}\p{N}_-]{0,62}` and 128 bytes. ASCII is
/// checked exactly; beyond ASCII the Unicode classes are the server's to
/// judge, so any such character passes here.
pub fn labelKeyProblem(key: []const u8) ?[]const u8 {
    if (key.len == 0) return "a label key is at least one character";
    if (labelTextProblem(key)) |p| return p;
    if (key[0] < 0x80 and !std.ascii.isLower(key[0])) return "a label key starts with a lowercase letter";
    return null;
}

/// Why `value` cannot be a label value, or null when it can: 0 to 63
/// characters of the key's alphabet, any of them first.
pub fn labelValueProblem(value: []const u8) ?[]const u8 {
    return labelTextProblem(value);
}

fn labelTextProblem(text: []const u8) ?[]const u8 {
    if (text.len > max_label_bytes) return "a label key or value holds at most 128 bytes";
    const view = std.unicode.Utf8View.init(text) catch return "labels must be valid UTF-8";
    var it = view.iterator();
    var chars: usize = 0;
    while (it.nextCodepoint()) |cp| : (chars += 1) {
        if (cp >= 0x80) continue;
        switch (cp) {
            'a'...'z', '0'...'9', '_', '-' => {},
            else => return "labels hold lowercase letters, digits, '_' and '-'",
        }
    }
    if (chars > max_label_chars) return "a label key or value is at most 63 characters";
    return null;
}

pub fn labelsProblem(labels: []const types.Label) ?[]const u8 {
    if (labels.len > max_labels) return "a key carries at most 64 labels";
    for (labels, 0..) |l, i| {
        if (labelKeyProblem(l.key)) |p| return p;
        if (labelValueProblem(l.value)) |p| return p;
        for (labels[0..i]) |earlier| if (std.mem.eql(u8, earlier.key, l.key)) return "a label key is named once";
    }
    return null;
}

pub fn rotationProblem(r: types.Rotation) ?[]const u8 {
    if (r.period_s < min_rotation_s or r.period_s > max_rotation_s) return "a rotation period is 1 day to 876,000 hours";
    if (!core.timestamp.inRange(r.next)) return "a rotation's next time is between the years 1 and 9999";
    return null;
}

/// Why a key cannot be created as `config` says, or null.
pub fn keyConfigProblem(config: types.KeyConfig) ?[]const u8 {
    if (config.purpose == .unknown) return "a key's purpose cannot be .unknown, which stands for one the server sent";
    if (config.protection_level == .unknown) return "a key's protection level cannot be .unknown, which stands for one the server sent";
    if (config.algorithm) |a| {
        if (a == .unknown) return "a key's algorithm cannot be .unknown, which stands for one the server sent";
        if (a.purpose() != config.purpose) return "the algorithm is not of the key's purpose";
    } else if (config.purpose != .encrypt_decrypt) {
        return "a key of this purpose names its algorithm; only .encrypt_decrypt implies one";
    }
    if (config.destroy_delay_s) |d| if (d < min_destroy_delay_s or d > max_destroy_delay_s) {
        return "a destroy delay is 1 to 120 days";
    };
    if (config.rotation) |r| {
        if (config.purpose != .encrypt_decrypt) return "only .encrypt_decrypt keys rotate by themselves";
        if (rotationProblem(r)) |p| return p;
    }
    return labelsProblem(config.labels);
}

/// Why `update` cannot be sent, or null. An update that changes nothing is
/// refused: the server would need an empty mask.
pub fn keyUpdateProblem(update: types.KeyUpdate) ?[]const u8 {
    if (update.labels == .keep and update.rotation == .keep and update.algorithm == null) return "an update changes at least one thing";
    switch (update.labels) {
        .set => |labels| if (labelsProblem(labels)) |p| return p,
        else => {},
    }
    switch (update.rotation) {
        .set => |r| if (rotationProblem(r)) |p| return p,
        else => {},
    }
    if (update.algorithm) |a| if (a == .unknown) return "an algorithm cannot be .unknown, which stands for one the server sent";
    return null;
}

const testing = std.testing;
const repeat = core.testing.repeat;

test "ids, locations, tokens and user agents at their boundaries" {
    for ([_][]const u8{ "a", "zigps-kms", "Key_1", repeat("a", 63) }) |ok| try testing.expect(isId(ok));
    for ([_][]const u8{ "", repeat("a", 64), "a b", "a/b", "a.b", "a%41", "\xc3\xa9" }) |bad| try testing.expect(!isId(bad));
    for ([_][]const u8{ "global", "us-central1", "nam-eur-asia1", "us" }) |ok| try testing.expect(isLocation(ok));
    for ([_][]const u8{ "", "US", "us central1", "us/central1", repeat("a", 64) }) |bad| try testing.expect(!isLocation(bad));
    try testing.expect(isPageToken("CgRrZXkx"));
    try testing.expect(!isPageToken("a b"));
    try testing.expect(isUserAgent("zig-gcp-kms/0.52"));
    try testing.expect(!isUserAgent("a\nb"));
}

test "filters and orders: UTF-8, no control characters, 2,048 bytes" {
    try testing.expectEqual(null, queryTextProblem("labels.team=alpha AND state != DESTROYED"));
    try testing.expectEqual(null, queryTextProblem("name:\"zigps-\""));
    try testing.expectEqual(null, queryTextProblem(repeat("a", 2048)));
    try testing.expect(queryTextProblem(repeat("a", 2049)) != null);
    try testing.expect(queryTextProblem("a\x00b") != null);
    try testing.expect(queryTextProblem("a\x7fb") != null);
    try testing.expect(queryTextProblem("\xff") != null);
}

test "labels: Google's alphabet, 63 characters, 64 of them, each key once" {
    try testing.expectEqual(null, labelsProblem(&.{ .{ .key = "team", .value = "alpha" }, .{ .key = "x-1_y", .value = "" } }));
    try testing.expect(labelsProblem(&.{.{ .key = "Team", .value = "a" }}) != null);
    try testing.expect(labelsProblem(&.{.{ .key = "1team", .value = "a" }}) != null);
    try testing.expect(labelsProblem(&.{.{ .key = "", .value = "a" }}) != null);
    try testing.expect(labelsProblem(&.{.{ .key = "a", .value = "B" }}) != null);
    try testing.expect(labelsProblem(&.{.{ .key = repeat("a", 64), .value = "" }}) != null);
    try testing.expectEqual(null, labelsProblem(&.{.{ .key = repeat("a", 63), .value = repeat("b", 63) }}));
    try testing.expect(labelsProblem(&.{ .{ .key = "a", .value = "1" }, .{ .key = "a", .value = "2" } }) != null);
    var labels: [65]types.Label = undefined;
    var keys: [65][3]u8 = undefined;
    for (&labels, &keys, 0..) |*l, *k, i| {
        k.* = .{ 'k', '0' + @as(u8, @intCast(i / 10)), '0' + @as(u8, @intCast(i % 10)) };
        l.* = .{ .key = k, .value = "" };
    }
    try testing.expectEqual(null, labelsProblem(labels[0..64]));
    try testing.expect(labelsProblem(&labels) != null);
}

test "key configs: each check refuses only its own fault" {
    const ok: types.KeyConfig = .{ .purpose = .encrypt_decrypt };
    try testing.expectEqual(null, keyConfigProblem(ok));
    try testing.expectEqual(null, keyConfigProblem(.{ .purpose = .asymmetric_sign, .algorithm = .ec_sign_p256_sha256, .destroy_delay_s = 86_400 }));
    try testing.expectEqual(null, keyConfigProblem(.{ .purpose = .encrypt_decrypt, .rotation = .{ .period_s = 86_400, .next = .{ .nanoseconds = 0 } }, .destroy_delay_s = 120 * 86_400 }));
    const refused = [_]types.KeyConfig{
        .{ .purpose = .unknown, .algorithm = .ec_sign_p256_sha256 },
        .{ .purpose = .encrypt_decrypt, .protection_level = .unknown },
        .{ .purpose = .asymmetric_sign },
        .{ .purpose = .asymmetric_sign, .algorithm = .unknown },
        .{ .purpose = .asymmetric_sign, .algorithm = .hmac_sha256 },
        .{ .purpose = .encrypt_decrypt, .destroy_delay_s = 86_399 },
        .{ .purpose = .encrypt_decrypt, .destroy_delay_s = 120 * 86_400 + 1 },
        .{ .purpose = .mac, .algorithm = .hmac_sha256, .rotation = .{ .period_s = 86_400, .next = .{ .nanoseconds = 0 } } },
        .{ .purpose = .encrypt_decrypt, .rotation = .{ .period_s = 86_399, .next = .{ .nanoseconds = 0 } } },
        .{ .purpose = .encrypt_decrypt, .labels = &.{.{ .key = "A", .value = "" }} },
    };
    for (refused) |config| try testing.expect(keyConfigProblem(config) != null);
}

test "key updates: something to change, each part checked" {
    try testing.expect(keyUpdateProblem(.{}) != null);
    try testing.expectEqual(null, keyUpdateProblem(.{ .labels = .clear }));
    try testing.expectEqual(null, keyUpdateProblem(.{ .rotation = .clear }));
    try testing.expectEqual(null, keyUpdateProblem(.{ .algorithm = .google_symmetric_encryption }));
    try testing.expect(keyUpdateProblem(.{ .labels = .{ .set = &.{.{ .key = "A", .value = "" }} } }) != null);
    try testing.expect(keyUpdateProblem(.{ .rotation = .{ .set = .{ .period_s = 3600, .next = .{ .nanoseconds = 0 } } } }) != null);
    try testing.expect(keyUpdateProblem(.{ .algorithm = .unknown }) != null);
}
