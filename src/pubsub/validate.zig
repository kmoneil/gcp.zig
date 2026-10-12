//! Client-side checks, run before any request: the API's fixed limits, the
//! resource-name rules, and UTF-8 validity (JSON strings must be UTF-8, and
//! `std.json.Stringify` does not check). Only cheap, fixed rules are checked;
//! the server has the final word on everything else. A failed check fills
//! `Diagnostics` with the reason.
//!
//! Limits are from https://docs.cloud.google.com/pubsub/quotas and were
//! measured against production on 2026-09-18: several are stricter or more
//! precise than the documentation says, as noted below. They are fixed
//! limits, not adjustable quotas.

const std = @import("std");
const codec = @import("codec.zig");
const types = @import("types.zig");
const Diagnostics = @import("core").Diagnostics;
const timestamp = @import("core").timestamp;
const test_util = @import("test_util.zig");

pub const max_messages_per_publish = 1000;
/// The documented "10 MB" is the size of the HTTP request body, JSON and
/// base64 included (production: "Request payload size exceeds the limit:
/// 10485760 bytes"). Base64 grows data by a third, so over REST a single
/// message holds at most 7,864,299 bytes of raw data.
pub const max_publish_request_bytes = 10 * 1024 * 1024;
/// The documented per-message limit. Over REST the request limit is stricter.
pub const max_data_bytes = 10 * 1024 * 1024;
pub const max_attributes = 100;
pub const max_attribute_key_bytes = 256;
pub const max_attribute_value_bytes = 1024;
/// Undocumented; production rejects longer keys. Counted in UTF-8 bytes.
pub const max_ordering_key_bytes = 1024;
pub const max_pull_messages = 1000;
/// "512 KB" is 524,288 bytes of HTTP request body per acknowledge or
/// modifyAckDeadline call.
pub const max_ack_request_bytes = 512 * 1024;
/// Google's own clients send at most 2500 ack ids per request.
pub const max_ack_ids_per_request = 2500;
pub const min_ack_deadline_seconds = 10;
pub const max_ack_deadline_seconds = 600;
/// A subscription's filter, in bytes ("the maximum length of a filter
/// expression is 256 bytes"). The emulator takes longer ones.
pub const max_filter_bytes = 256;
/// Labels per topic or subscription, and characters per key or value.
pub const max_labels = 64;
pub const max_label_chars = 63;
/// A subscription's or a topic's message retention.
pub const min_message_retention: std.Io.Duration = .fromSeconds(10 * 60);
pub const max_message_retention: std.Io.Duration = .fromSeconds(31 * 24 * 60 * 60);
/// The shortest expiration ttl. The emulator takes shorter ones.
pub const min_expiration: std.Io.Duration = .fromSeconds(24 * 60 * 60);
/// Each bound of a retry policy's backoff.
pub const max_backoff: std.Io.Duration = .fromSeconds(600);
/// Resource Manager tags bound to one resource as it is made.
pub const max_tags = 50;
/// The transforms of a topic or a subscription that are not disabled.
/// Measured 2026-10-12: production and an emulator refuse a sixth.
pub const max_enabled_message_transforms = 5;
/// A JavaScript function's source. Measured 2026-10-12: production takes
/// 20,480 bytes and refuses 20,481; an emulator takes any.
pub const max_udf_code_bytes = 20 * 1024;
/// A dead-letter policy's deliveries before a message is forwarded.
pub const min_delivery_attempts = 5;
pub const max_delivery_attempts = 100;
/// A Cloud Storage subscription closes a file after 1 to 10 minutes...
pub const min_storage_duration: std.Io.Duration = .fromSeconds(60);
pub const max_storage_duration: std.Io.Duration = .fromSeconds(600);
/// ...or after 1,000 bytes to 10 GiB, or 1,000 messages or more, 0 meaning
/// no such limit. Production names these bounds in its refusals.
pub const min_storage_bytes = 1000;
pub const max_storage_bytes = 10 * 1024 * 1024 * 1024;
pub const min_storage_messages = 1000;
/// A Cloud Storage filename prefix and suffix together ("the maximum
/// allowed is 992", production, 2026-10-10).
pub const max_filename_chars = 992;
/// Documented as "300 KB". Measured on 2026-10-12: production takes a
/// definition of 307,200 bytes and refuses one of 307,201, in six words
/// that do not say why.
pub const max_schema_definition_bytes = 300 * 1024;

/// The exact size of the body `Topic.publish` would send, without encoding
/// anything. Callers splitting large batches can compare it with
/// `max_publish_request_bytes`.
pub fn publishRequestBytes(messages: []const types.Message, ordering_key: ?[]const u8) usize {
    return codec.publishBodyLen(messages, ordering_key);
}

/// Topic and subscription ids: 3 to 255 characters from `[A-Za-z0-9-_.~+%]`,
/// starting with a letter, and not starting with "goog" in any case.
/// Storage names topics too, so the rule lives in core with its tests.
pub const isResourceId = @import("core").names.isPubSubId;

/// Project ids and numbers, including legacy domain-scoped ids such as
/// `example.com:my-project`. Shared with the other service modules, so it
/// lives in core; the tests for it are there too.
pub const isProjectId = @import("core").names.isProjectId;

/// Checks a publish call: message count, per-message rules, UTF-8, and the
/// size of the encoded request.
pub fn publish(
    messages: []const types.Message,
    ordering_key: ?[]const u8,
    diag: ?*Diagnostics,
) error{InvalidMessage}!void {
    if (messages.len == 0) return reject(diag, "publish needs at least one message", .{});
    if (messages.len > max_messages_per_publish) {
        return reject(diag, "publish has {d} messages; the limit is {d}", .{ messages.len, max_messages_per_publish });
    }
    const key = ordering_key orelse "";
    if (!std.unicode.utf8ValidateSlice(key)) return reject(diag, "the ordering key is not valid UTF-8", .{});
    if (key.len > max_ordering_key_bytes) {
        return reject(diag, "the ordering key has {d} bytes; the limit is {d}", .{ key.len, max_ordering_key_bytes });
    }

    for (messages, 0..) |m, i| {
        if (m.data.len == 0 and m.attributes.len == 0) {
            return reject(diag, "message {d} has no data and no attributes", .{i});
        }
        if (m.data.len > max_data_bytes) {
            return reject(diag, "message {d} has {d} bytes of data; the limit is {d}", .{ i, m.data.len, max_data_bytes });
        }
        if (m.attributes.len > max_attributes) {
            return reject(diag, "message {d} has {d} attributes; the limit is {d}", .{ i, m.attributes.len, max_attributes });
        }
        for (m.attributes, 0..) |a, j| {
            // Production rejects these; the emulator does not.
            if (a.key.len == 0 or std.ascii.startsWithIgnoreCase(a.key, "goog")) {
                return reject(diag, "message {d}, attribute {d}: keys must be non-empty and not start with \"goog\"", .{ i, j });
            }
            if (a.key.len > max_attribute_key_bytes) {
                return reject(diag, "message {d}, attribute {d}: the key has {d} bytes; the limit is {d}", .{ i, j, a.key.len, max_attribute_key_bytes });
            }
            if (a.value.len > max_attribute_value_bytes) {
                return reject(diag, "message {d}, attribute {d}: the value has {d} bytes; the limit is {d}", .{ i, j, a.value.len, max_attribute_value_bytes });
            }
            if (!std.unicode.utf8ValidateSlice(a.key) or !std.unicode.utf8ValidateSlice(a.value)) {
                return reject(diag, "message {d}, attribute {d}: keys and values must be valid UTF-8", .{ i, j });
            }
            for (m.attributes[0..j]) |earlier| {
                if (std.mem.eql(u8, earlier.key, a.key)) {
                    return reject(diag, "message {d}, attribute {d}: the key repeats an earlier attribute", .{ i, j });
                }
            }
        }
    }
    const body_bytes = publishRequestBytes(messages, ordering_key);
    if (body_bytes > max_publish_request_bytes) {
        return reject(diag, "the publish request would be {d} bytes; the limit is {d}, and base64 grows data by a third", .{ body_bytes, max_publish_request_bytes });
    }
}

/// Ack ids are opaque, but they travel as JSON strings, so they must be UTF-8.
pub fn ackIds(ack_ids: []const []const u8, diag: ?*Diagnostics) error{InvalidArgument}!void {
    for (ack_ids, 0..) |id, i| {
        if (!std.unicode.utf8ValidateSlice(id)) {
            if (diag) |d| d.print("ack id {d} is not valid UTF-8", .{i});
            return error.InvalidArgument;
        }
    }
}

/// `modifyAckDeadline` accepts 0 (nack) to 600 seconds.
pub fn modifyDeadline(seconds: u32, diag: ?*Diagnostics) error{InvalidArgument}!void {
    if (seconds > max_ack_deadline_seconds) {
        if (diag) |d| d.print("ack deadline {d} s is over the {d} s limit", .{ seconds, max_ack_deadline_seconds });
        return error.InvalidArgument;
    }
}

/// A subscription's ack deadline is 10 to 600 seconds, or 0 for the default.
pub fn subscriptionDeadline(seconds: u32, diag: ?*Diagnostics) error{InvalidArgument}!void {
    if (seconds != 0 and (seconds < min_ack_deadline_seconds or seconds > max_ack_deadline_seconds)) {
        if (diag) |d| d.print("ack deadline {d} s is outside {d}..{d} s", .{ seconds, min_ack_deadline_seconds, max_ack_deadline_seconds });
        return error.InvalidArgument;
    }
}

pub fn clampPullMessages(max_messages: u32) u32 {
    return std.math.clamp(max_messages, 1, max_pull_messages);
}

/// Labels: at most 64, each key 1 to 63 characters and each value up to 63,
/// of lowercase ASCII letters, digits, `_` and `-`, with a key starting
/// with a lowercase letter. Non-ASCII characters, which Google allows as
/// "international characters", are passed through for the server to judge.
/// Keys must not repeat.
pub fn labels(list: []const types.Label, diag: ?*Diagnostics) error{InvalidArgument}!void {
    if (list.len > max_labels) return refuse(diag, "{d} labels; the limit is {d}", .{ list.len, max_labels });
    for (list, 0..) |l, i| {
        try labelText(l.key, true, i, diag);
        try labelText(l.value, false, i, diag);
        for (list[0..i]) |earlier| {
            if (std.mem.eql(u8, earlier.key, l.key)) return refuse(diag, "label {d}: the key repeats an earlier label's", .{i});
        }
    }
}

fn labelText(text: []const u8, is_key: bool, index: usize, diag: ?*Diagnostics) error{InvalidArgument}!void {
    const what = if (is_key) "key" else "value";
    const chars = std.unicode.utf8CountCodepoints(text) catch
        return refuse(diag, "label {d}: the {s} is not valid UTF-8", .{ index, what });
    if (is_key and chars == 0) return refuse(diag, "label {d}: the key is empty", .{index});
    if (chars > max_label_chars) return refuse(diag, "label {d}: the {s} has {d} characters; the limit is {d}", .{ index, what, chars, max_label_chars });
    for (text, 0..) |c, j| switch (c) {
        'a'...'z', 0x80...0xff => {},
        '0'...'9', '_', '-' => if (is_key and j == 0)
            return refuse(diag, "label {d}: a key starts with a lowercase letter", .{index}),
        else => return refuse(diag, "label {d}: the {s} holds byte 0x{x:0>2}; labels take lowercase letters, digits, '_' and '-'", .{ index, what, c }),
    };
}

/// A compression level: 1 to 9.
pub fn compression(c: types.Compression, diag: ?*Diagnostics) error{InvalidArgument}!void {
    if (c.level < 1 or c.level > 9) return refuse(diag, "compression level {d} is outside 1 to 9", .{c.level});
}

/// A subscription's filter: at most 256 bytes of UTF-8. Its grammar is the
/// server's to check.
pub fn filter(text: []const u8, diag: ?*Diagnostics) error{InvalidArgument}!void {
    if (text.len > max_filter_bytes) return refuse(diag, "the filter has {d} bytes; the limit is {d}", .{ text.len, max_filter_bytes });
    if (!std.unicode.utf8ValidateSlice(text)) return refuse(diag, "the filter is not valid UTF-8", .{});
}

/// A dead-letter policy: 5 to 100 attempts, and a topic id or a full topic
/// name.
pub fn deadLetterPolicy(policy: types.DeadLetterPolicy, diag: ?*Diagnostics) error{InvalidArgument}!void {
    if (policy.max_delivery_attempts < min_delivery_attempts or policy.max_delivery_attempts > max_delivery_attempts) {
        return refuse(diag, "max_delivery_attempts {d} is outside {d} to {d}", .{ policy.max_delivery_attempts, min_delivery_attempts, max_delivery_attempts });
    }
    if (isResourceId(policy.topic) or isTopicName(policy.topic)) return;
    return refuse(diag, "the dead-letter topic is neither a topic id nor projects/{{project}}/topics/{{id}}", .{});
}

/// `projects/{project}/topics/{id}`, with a valid project and topic id.
pub fn isTopicName(name: []const u8) bool {
    return isNameIn(name, "/topics/");
}

/// `projects/{project}/subscriptions/{id}`, with a valid project and
/// subscription id.
pub fn isSubscriptionName(name: []const u8) bool {
    return isNameIn(name, "/subscriptions/");
}

/// `projects/{project}/snapshots/{id}`, with a valid project and snapshot
/// id.
pub fn isSnapshotName(name: []const u8) bool {
    return isNameIn(name, "/snapshots/");
}

/// `projects/{project}/schemas/{id}`, with a valid project and schema id,
/// and no revision after it.
pub fn isSchemaName(name: []const u8) bool {
    return isNameIn(name, "/schemas/");
}

fn isNameIn(name: []const u8, comptime collection: []const u8) bool {
    const prefix = "projects/";
    if (!std.mem.startsWith(u8, name, prefix)) return false;
    const rest = name[prefix.len..];
    const cut = std.mem.indexOf(u8, rest, collection) orelse return false;
    return isProjectId(rest[0..cut]) and isResourceId(rest[cut + collection.len ..]);
}

/// A retry policy: each bound 0 to 600 seconds, the minimum no more than the
/// maximum.
pub fn backoff(b: types.Backoff, diag: ?*Diagnostics) error{InvalidArgument}!void {
    inline for (.{ .{ "minimum", b.minimum }, .{ "maximum", b.maximum } }) |bound| {
        const d: std.Io.Duration = bound[1];
        if (d.nanoseconds < 0 or d.nanoseconds > max_backoff.nanoseconds) {
            return refuse(diag, "the retry policy's " ++ bound[0] ++ " backoff is outside 0 to 600 s", .{});
        }
    }
    if (b.minimum.nanoseconds > b.maximum.nanoseconds) return refuse(diag, "the retry policy's minimum backoff is over its maximum", .{});
}

/// Message retention: 10 minutes to 31 days.
pub fn messageRetention(d: std.Io.Duration, diag: ?*Diagnostics) error{InvalidArgument}!void {
    if (d.nanoseconds < min_message_retention.nanoseconds or d.nanoseconds > max_message_retention.nanoseconds) {
        return refuse(diag, "message retention is outside 10 minutes to 31 days", .{});
    }
}

/// An expiration: a ttl of at least a day, and at least the retention.
pub fn expiration(e: types.Expiration, retention: ?std.Io.Duration, diag: ?*Diagnostics) error{InvalidArgument}!void {
    const ttl = switch (e) {
        .default, .never => return,
        .after => |ttl| ttl,
    };
    if (ttl.nanoseconds < min_expiration.nanoseconds) return refuse(diag, "the expiration ttl is under a day", .{});
    if (ttl.nanoseconds > @as(i96, @import("core").duration.max_seconds) * std.time.ns_per_s) {
        return refuse(diag, "the expiration ttl is out of range", .{});
    }
    if (retention) |r| if (ttl.nanoseconds < r.nanoseconds) return refuse(diag, "the expiration ttl is shorter than the message retention", .{});
}

/// A Cloud KMS key: `projects/{p}/locations/{l}/keyRings/{r}/cryptoKeys/{k}`,
/// each part non-empty.
pub fn kmsKeyName(name: []const u8, diag: ?*Diagnostics) error{InvalidArgument}!void {
    var parts = std.mem.splitScalar(u8, name, '/');
    for ([_][]const u8{ "projects", "", "locations", "", "keyRings", "", "cryptoKeys", "" }) |want| {
        const part = parts.next() orelse break;
        if (part.len == 0 or (want.len > 0 and !std.mem.eql(u8, part, want))) break;
    } else if (parts.next() == null and std.unicode.utf8ValidateSlice(name)) return;
    return refuse(diag, "the KMS key is not projects/{{p}}/locations/{{l}}/keyRings/{{r}}/cryptoKeys/{{k}}", .{});
}

/// A message storage policy: at least one region, none empty.
pub fn storagePolicy(policy: types.MessageStoragePolicy, diag: ?*Diagnostics) error{InvalidArgument}!void {
    if (policy.allowed_persistence_regions.len == 0) return refuse(diag, "a message storage policy needs at least one region", .{});
    for (policy.allowed_persistence_regions, 0..) |region, i| {
        if (region.len == 0 or !std.unicode.utf8ValidateSlice(region)) return refuse(diag, "region {d} is empty or not valid UTF-8", .{i});
    }
}

/// A subscription's delivery, by the rules measured in production on
/// 2026-10-10 (`_plan/zig-pubsub-delivery-settings-spec.md`, section 2).
/// The emulator checks almost none of them, so what passes it would still
/// fail in production without these.
pub fn delivery(d: types.Delivery, exactly_once: bool, emulator: bool, diag: ?*Diagnostics) error{InvalidArgument}!void {
    if (exactly_once and d != .pull) {
        return refuse(diag, "exactly-once delivery works only when the subscriber pulls; production refuses it beside any other kind", .{});
    }
    switch (d) {
        .pull => {},
        .push => |p| try pushConfig(p, emulator, diag),
        .bigquery => |b| try bigQueryConfig(b, diag),
        .cloud_storage => |s| try cloudStorageConfig(s, diag),
    }
}

/// A push config: an `https://` endpoint, or `http://` on an emulator
/// endpoint only, which is how a push is tested locally and what the
/// emulator's own page advises.
pub fn pushConfig(p: types.PushConfig, emulator: bool, diag: ?*Diagnostics) error{InvalidArgument}!void {
    if (!std.unicode.utf8ValidateSlice(p.endpoint)) return refuse(diag, "the push endpoint is not valid UTF-8", .{});
    const scheme: usize = if (std.mem.startsWith(u8, p.endpoint, "https://"))
        "https://".len
    else if (emulator and std.mem.startsWith(u8, p.endpoint, "http://"))
        "http://".len
    else if (emulator)
        return refuse(diag, "the push endpoint is not an http(s):// URL", .{})
    else
        return refuse(diag, "the push endpoint is not an https:// URL, which production requires", .{});
    if (p.endpoint.len == scheme) return refuse(diag, "the push endpoint has no host", .{});
    if (p.oidc_token) |t| {
        try serviceAccount(t.service_account_email, "the OIDC token's service account", diag);
        if (!std.unicode.utf8ValidateSlice(t.audience)) return refuse(diag, "the OIDC audience is not valid UTF-8", .{});
    }
}

/// A BigQuery config: a table of three parts, `project.dataset.table` or
/// `project:dataset.table`, each part non-empty. A project of the colon
/// form (`example.com:proj`) keeps its dots.
pub fn bigQueryConfig(b: types.BigQueryConfig, diag: ?*Diagnostics) error{InvalidArgument}!void {
    try bigQueryTable(b.table, diag);
    if (b.service_account_email) |email| try serviceAccount(email, "the config's service account", diag);
}

fn bigQueryTable(table: []const u8, diag: ?*Diagnostics) error{InvalidArgument}!void {
    const malformed = "the BigQuery table is not project.dataset.table or project:dataset.table";
    if (!std.unicode.utf8ValidateSlice(table)) return refuse(diag, "the BigQuery table is not valid UTF-8", .{});
    for (table) |c| if (c <= ' ' or c == 0x7f) return refuse(diag, malformed, .{});
    var rest = table;
    var parts_needed: usize = 3;
    if (std.mem.indexOfScalar(u8, table, ':')) |colon| {
        if (colon == 0) return refuse(diag, malformed, .{});
        rest = table[colon + 1 ..];
        if (std.mem.indexOfScalar(u8, rest, ':') != null) return refuse(diag, malformed, .{});
        parts_needed = 2;
    }
    var parts = std.mem.splitScalar(u8, rest, '.');
    var count: usize = 0;
    while (parts.next()) |part| : (count += 1) {
        if (part.len == 0) return refuse(diag, malformed, .{});
    }
    if (count < parts_needed) return refuse(diag, malformed, .{});
}

/// A Cloud Storage config: the bucket's shape (production answers a
/// malformed name as a 503 outage, which nothing in the answer explains),
/// the filename parts, and the batching bounds, each by production's
/// measured refusals.
pub fn cloudStorageConfig(s: types.CloudStorageConfig, diag: ?*Diagnostics) error{InvalidArgument}!void {
    if (s.bucket.len == 0) return refuse(diag, "the bucket is empty", .{});
    if (!std.unicode.utf8ValidateSlice(s.bucket)) return refuse(diag, "the bucket is not valid UTF-8", .{});
    for (s.bucket) |c| {
        if (c == '/') return refuse(diag, "the bucket is a name alone: no gs:// and no '/' (production answers one as an outage)", .{});
        if (c <= ' ' or c == 0x7f) return refuse(diag, "the bucket holds whitespace or a control character", .{});
    }
    const prefix_chars = try filenamePart(s.filename_prefix, "prefix", diag);
    const suffix_chars = try filenamePart(s.filename_suffix, "suffix", diag);
    if (std.mem.endsWith(u8, s.filename_suffix, "/")) {
        return refuse(diag, "the filename suffix ends with '/', which production refuses", .{});
    }
    if (prefix_chars + suffix_chars > max_filename_chars) {
        return refuse(diag, "the filename prefix and suffix hold {d} characters together; the limit is {d}", .{ prefix_chars + suffix_chars, max_filename_chars });
    }
    try filenameDatetimeFormat(s.filename_datetime_format, diag);
    if (s.max_duration) |d| {
        if (d.nanoseconds < min_storage_duration.nanoseconds or d.nanoseconds > max_storage_duration.nanoseconds) {
            return refuse(diag, "the file batching duration is outside 1 to 10 minutes", .{});
        }
    }
    if (s.max_bytes != 0 and (s.max_bytes < min_storage_bytes or s.max_bytes > max_storage_bytes)) {
        return refuse(diag, "the file batching bytes are outside {d} to {d}, with 0 for no such limit", .{ min_storage_bytes, max_storage_bytes });
    }
    if (s.max_messages != 0 and s.max_messages < min_storage_messages) {
        return refuse(diag, "the file batching messages are under {d}, with 0 for no such limit", .{min_storage_messages});
    }
    // The wire carries an int64; production took its maximum.
    if (s.max_messages > std.math.maxInt(i64)) {
        return refuse(diag, "the file batching messages are over the wire's int64", .{});
    }
    if (s.service_account_email) |email| try serviceAccount(email, "the config's service account", diag);
}

/// Counts a prefix or suffix in characters, refusing control characters,
/// which production refuses as "disallowed unicode characters".
fn filenamePart(text: []const u8, comptime what: []const u8, diag: ?*Diagnostics) error{InvalidArgument}!usize {
    const chars = std.unicode.utf8CountCodepoints(text) catch
        return refuse(diag, "the filename " ++ what ++ " is not valid UTF-8", .{});
    for (text) |c| if (c < ' ' or c == 0x7f) {
        return refuse(diag, "the filename " ++ what ++ " holds a control character", .{});
    };
    return chars;
}

/// Production's rules for the filename datetime format, measured
/// 2026-10-10: each of a year (`YYYY` or `YY`), `MM`, `DD`, `hh`, `mm` and
/// `ss` exactly once, in any order; at most one `T` and at most one of `Z`
/// and `+00:00`; between them only `-`, `_`, `:` and `/`. A space or a dot
/// is refused. Empty means Pub/Sub's default.
pub fn filenameDatetimeFormat(format: []const u8, diag: ?*Diagnostics) error{InvalidArgument}!void {
    if (format.len == 0) return;
    var counts: [8]u32 = @splat(0);
    const year = 0;
    const t_count = 6;
    const zone = 7;
    var i: usize = 0;
    while (i < format.len) {
        const rest = format[i..];
        const matchers = [_][]const u8{ "YYYY", "YY", "MM", "DD", "hh", "mm", "ss" };
        const which: [7]usize = .{ year, year, 1, 2, 3, 4, 5 };
        const matched = for (matchers, which) |matcher, slot| {
            if (std.mem.startsWith(u8, rest, matcher)) {
                counts[slot] += 1;
                i += matcher.len;
                break true;
            }
        } else false;
        if (matched) continue;
        if (std.mem.startsWith(u8, rest, "+00:00")) {
            counts[zone] += 1;
            i += "+00:00".len;
            continue;
        }
        switch (rest[0]) {
            'T' => counts[t_count] += 1,
            'Z' => counts[zone] += 1,
            '-', '_', ':', '/' => {},
            else => return refuse(diag, "the datetime format takes YYYY or YY, MM, DD, hh, mm, ss, T, Z, +00:00 and the separators '-', '_', ':' and '/'; byte 0x{x:0>2} is none of them", .{rest[0]}),
        }
        i += 1;
    }
    for (counts[0..6], [_][]const u8{ "year (YYYY or YY)", "MM", "DD", "hh", "mm", "ss" }) |count, name| {
        if (count != 1) return refuse(diag, "the datetime format needs each of a year (YYYY or YY), MM, DD, hh, mm and ss exactly once; {s} is there {d} times", .{ name, count });
    }
    if (counts[t_count] > 1) return refuse(diag, "the datetime format holds more than one T", .{});
    if (counts[zone] > 1) return refuse(diag, "the datetime format holds more than one of Z and +00:00", .{});
}

/// A service account for OIDC or for export: the shape of an address. The
/// server alone knows whether it exists and what it may do.
pub fn serviceAccount(email: []const u8, comptime what: []const u8, diag: ?*Diagnostics) error{InvalidArgument}!void {
    const malformed = what ++ " is not of the shape of an address";
    if (!std.unicode.utf8ValidateSlice(email)) return refuse(diag, malformed, .{});
    for (email) |c| if (c <= ' ' or c == 0x7f) return refuse(diag, malformed, .{});
    const at = std.mem.indexOfScalar(u8, email, '@') orelse return refuse(diag, malformed, .{});
    const domain = email[at + 1 ..];
    if (at == 0 or domain.len == 0) return refuse(diag, malformed, .{});
    if (std.mem.indexOfScalar(u8, domain, '@') != null) return refuse(diag, malformed, .{});
    const dot = std.mem.indexOfScalar(u8, domain, '.') orelse return refuse(diag, malformed, .{});
    if (dot == 0 or dot == domain.len - 1) return refuse(diag, malformed, .{});
}

/// Every setting of a new subscription, before anything is sent.
/// `emulator` relaxes only what testing against one needs: an `http://`
/// push endpoint.
pub fn subscriptionConfig(config: types.SubscriptionConfig, emulator: bool, diag: ?*Diagnostics) error{InvalidArgument}!void {
    try delivery(config.delivery, config.enable_exactly_once_delivery, emulator, diag);
    try subscriptionDeadline(config.ack_deadline_seconds, diag);
    try filter(config.filter, diag);
    if (config.dead_letter_policy) |p| try deadLetterPolicy(p, diag);
    if (config.retry_policy) |b| try backoff(b, diag);
    if (config.message_retention) |r| try messageRetention(r, diag);
    try expiration(config.expiration, config.message_retention, diag);
    try labels(config.labels, diag);
    try messageTransforms(config.message_transforms, diag);
    try tags(config.tags, diag);
}

/// Every setting of a new topic, before anything is sent.
pub fn topicConfig(config: types.TopicConfig, diag: ?*Diagnostics) error{InvalidArgument}!void {
    try labels(config.labels, diag);
    if (config.message_retention) |r| try messageRetention(r, diag);
    if (config.kms_key_name) |k| try kmsKeyName(k, diag);
    if (config.message_storage_policy) |p| try storagePolicy(p, diag);
    if (config.schema) |s| try schemaSettings(s, diag);
    try messageTransforms(config.message_transforms, diag);
    if (config.ingestion) |i| try ingestion(i, diag);
    try tags(config.tags, diag);
}

/// A subscription update: something to change, and every new value valid.
/// On an emulator a delivery can only be push or pull: the emulator
/// refuses the export kinds' mask paths as unknown fields.
pub fn subscriptionUpdate(u: types.SubscriptionUpdate, emulator: bool, diag: ?*Diagnostics) error{InvalidArgument}!void {
    if (u.delivery) |d| {
        if (emulator and d != .pull and d != .push) {
            return refuse(diag, "the emulator cannot change a subscription's delivery to a BigQuery or Cloud Storage config: it refuses their mask paths as unknown fields", .{});
        }
        try delivery(d, u.enable_exactly_once_delivery orelse false, emulator, diag);
    }
    if (u.ack_deadline_seconds) |s| {
        if (s < min_ack_deadline_seconds or s > max_ack_deadline_seconds) {
            return refuse(diag, "ack deadline {d} s is outside {d}..{d} s", .{ s, min_ack_deadline_seconds, max_ack_deadline_seconds });
        }
    }
    switch (u.dead_letter_policy) {
        .set => |p| try deadLetterPolicy(p, diag),
        else => {},
    }
    switch (u.retry_policy) {
        .set => |b| try backoff(b, diag),
        else => {},
    }
    const retention: ?std.Io.Duration = switch (u.message_retention) {
        .set => |r| r,
        else => null,
    };
    if (retention) |r| try messageRetention(r, diag);
    if (u.expiration) |e| try expiration(e, retention, diag);
    if (u.labels) |l| try labels(l, diag);
    if (u.message_transforms) |list| try messageTransforms(list, diag);
    const changes_something = u.delivery != null or u.ack_deadline_seconds != null or
        u.enable_exactly_once_delivery != null or u.dead_letter_policy != .keep or
        u.retry_policy != .keep or u.message_retention != .keep or
        u.retain_acked_messages != null or u.expiration != null or u.labels != null or
        u.message_transforms != null;
    if (!changes_something) return refuse(diag, "the update changes nothing", .{});
}

/// A topic update: something to change, and every new value valid.
pub fn topicUpdate(u: types.TopicUpdate, diag: ?*Diagnostics) error{InvalidArgument}!void {
    if (u.labels) |l| try labels(l, diag);
    switch (u.message_retention) {
        .set => |r| try messageRetention(r, diag),
        else => {},
    }
    switch (u.kms_key_name) {
        .set => |k| try kmsKeyName(k, diag),
        else => {},
    }
    switch (u.message_storage_policy) {
        .set => |p| try storagePolicy(p, diag),
        else => {},
    }
    switch (u.schema) {
        .set => |s| try schemaSettings(s, diag),
        else => {},
    }
    if (u.message_transforms) |list| try messageTransforms(list, diag);
    switch (u.ingestion) {
        .set => |i| try ingestion(i, diag),
        else => {},
    }
    const changes_something = u.labels != null or u.message_retention != .keep or
        u.kms_key_name != .keep or u.message_storage_policy != .keep or u.schema != .keep or
        u.message_transforms != null or u.ingestion != .keep;
    if (!changes_something) return refuse(diag, "the update changes nothing", .{});
}

/// A list of transforms, as a create or an update sends it whole: no kind
/// this client cannot write, at most five that are not disabled, and for
/// each JavaScript function a name no other has and code that is there, is
/// UTF-8 and is within the bound. An emulator checks the count alone, so
/// without these a list production refuses would pass every test against
/// one. Whether the code parses, and holds the function named, is the
/// server's to say.
pub fn messageTransforms(list: []const types.MessageTransform, diag: ?*Diagnostics) error{InvalidArgument}!void {
    var enabled: usize = 0;
    for (list, 0..) |transform, i| {
        if (!transform.disabled) enabled += 1;
        const udf = switch (transform.kind) {
            .javascript_udf => |udf| udf,
            .other => return refuse(diag, "message transform {d} is of a kind this client does not model: it can be read, and a list that holds it cannot be sent, since a list is replaced whole and would lose it", .{i}),
        };
        if (udf.function_name.len == 0) return refuse(diag, "message transform {d} has no function name", .{i});
        if (!std.unicode.utf8ValidateSlice(udf.function_name)) {
            return refuse(diag, "message transform {d} has a function name that is not valid UTF-8", .{i});
        }
        if (udf.code.len == 0) return refuse(diag, "message transform {d} has no code", .{i});
        if (udf.code.len > max_udf_code_bytes) {
            return refuse(diag, "message transform {d} has {d} bytes of code; the limit is {d}", .{ i, udf.code.len, max_udf_code_bytes });
        }
        if (!std.unicode.utf8ValidateSlice(udf.code)) {
            return refuse(diag, "message transform {d} has code that is not valid UTF-8", .{i});
        }
        // Production's words name no exception for a disabled one: "Each
        // JavaScript UDF must have a unique function name."
        for (list[0..i], 0..) |earlier, j| switch (earlier.kind) {
            .javascript_udf => |other| if (std.mem.eql(u8, other.function_name, udf.function_name)) {
                return refuse(diag, "message transforms {d} and {d} have the same function name", .{ j, i });
            },
            .other => {},
        };
    }
    if (enabled > max_enabled_message_transforms) {
        return refuse(diag, "{d} message transforms are not disabled; the limit is {d}", .{ enabled, max_enabled_message_transforms });
    }
}

/// An import topic's settings: every field its source requires is there
/// and is UTF-8, an ARN begins `arn:`, a service account has the shape of
/// an address, a text delimiter is one byte, and the severity is one this
/// client can name. Production
/// then connects to the source and says what it found; an emulator keeps
/// whatever it is given.
pub fn ingestion(i: types.Ingestion, diag: ?*Diagnostics) error{InvalidArgument}!void {
    if (i.log_severity == .unknown) return refuse(diag, "the log severity is .unknown, which is only ever read", .{});
    switch (i.source) {
        .aws_kinesis => |k| {
            try arn(k.stream_arn, "the Kinesis stream ARN", diag);
            try arn(k.consumer_arn, "the Kinesis consumer ARN", diag);
            try arn(k.aws_role_arn, "the AWS role ARN", diag);
            try serviceAccount(k.gcp_service_account, "the import topic's service account", diag);
        },
        .cloud_storage => |s| {
            try required(s.bucket, "the import topic's bucket", diag);
            // Production takes `gs://` before the name, and reads the
            // name back without it. A path after the name it refuses
            // ("not a valid resource name"), where an emulator keeps it
            // (measured 2026-10-12).
            const name = if (std.mem.startsWith(u8, s.bucket, "gs://")) s.bucket["gs://".len..] else s.bucket;
            if (name.len == 0 or std.mem.indexOfScalar(u8, name, '/') != null) {
                return refuse(diag, "the import topic's bucket is not a bucket's name alone: it holds a slash, or nothing after gs://", .{});
            }
            switch (s.format) {
                // Production takes one byte and no more: a bar, a tab,
                // even NUL, and neither `é` nor `\r\n` (measured
                // 2026-10-12). An emulator takes one character of any
                // width, so this is checked here.
                .text => |t| if (t.delimiter.len != 1 or t.delimiter[0] > 0x7f) {
                    return refuse(diag, "the text delimiter is not one character of one byte", .{});
                },
                .avro, .pubsub_avro => {},
            }
            if (s.minimum_object_create_time) |t| {
                if (!timestamp.inRange(t)) {
                    return refuse(diag, "the minimum object create time is outside 0001-01-01T00:00:00Z to 9999-12-31T23:59:59.999999999Z", .{});
                }
            }
            if (!std.unicode.utf8ValidateSlice(s.match_glob)) return refuse(diag, "the match glob is not valid UTF-8", .{});
        },
        .azure_event_hubs => |e| {
            try required(e.resource_group, "the Event Hubs resource group", diag);
            try required(e.namespace, "the Event Hubs namespace", diag);
            try required(e.event_hub, "the event hub", diag);
            try required(e.client_id, "the Event Hubs client id", diag);
            try required(e.tenant_id, "the Event Hubs tenant id", diag);
            try required(e.subscription_id, "the Event Hubs subscription id", diag);
            try serviceAccount(e.gcp_service_account, "the import topic's service account", diag);
        },
        .aws_msk => |m| {
            try arn(m.cluster_arn, "the MSK cluster ARN", diag);
            try required(m.topic, "the MSK topic", diag);
            try arn(m.aws_role_arn, "the AWS role ARN", diag);
            try serviceAccount(m.gcp_service_account, "the import topic's service account", diag);
        },
        .confluent_cloud => |c| {
            try required(c.bootstrap_server, "the Confluent Cloud bootstrap server", diag);
            try required(c.cluster_id, "the Confluent Cloud cluster id", diag);
            try required(c.topic, "the Confluent Cloud topic", diag);
            try required(c.identity_pool_id, "the Confluent Cloud identity pool id", diag);
            try serviceAccount(c.gcp_service_account, "the import topic's service account", diag);
        },
    }
}

/// Tags to bind as a resource is made: at most 50, no key twice, each of
/// a form production names, and a key and its value in the same form. An
/// emulator takes any key and any value,
/// and production answers a key of no known form only once deployed
/// against it. Whether the key and the value are there, and the caller
/// may use them, is the server's to say.
pub fn tags(list: []const types.Tag, diag: ?*Diagnostics) error{InvalidArgument}!void {
    if (list.len > max_tags) return refuse(diag, "{d} tags; the limit is {d}", .{ list.len, max_tags });
    for (list, 0..) |tag, i| {
        if (!isTagKey(tag.key)) {
            return refuse(diag, "tag {d} has a key that is neither {{organization id or project}}/{{key name}} nor tagKeys/{{id}}", .{i});
        }
        if (!isTagValue(tag.value)) {
            return refuse(diag, "tag {d} has a value that is neither a value's short name nor tagValues/{{id}}", .{i});
        }
        // Production takes both by name or both by id, and refuses one
        // of each: "Both TagKey and TagValue must be provided in the same
        // format." (measured 2026-10-12)
        if (std.mem.startsWith(u8, tag.key, "tagKeys/") != std.mem.startsWith(u8, tag.value, "tagValues/")) {
            return refuse(diag, "tag {d} names its key and its value in different forms: both go by name, or tagKeys/{{id}} goes with tagValues/{{id}}", .{i});
        }
        for (list[0..i], 0..) |earlier, j| {
            if (std.mem.eql(u8, earlier.key, tag.key)) return refuse(diag, "tags {d} and {d} have the same key", .{ j, i });
        }
    }
}

/// A tag key as production's refusal gives the format (2026-10-12): a
/// namespace, which is an organization's id or a project's name, then the
/// key's short name; or `tagKeys/` and an id. Either way two parts that
/// are there, around one slash, since no short name holds one.
pub fn isTagKey(key: []const u8) bool {
    if (!std.unicode.utf8ValidateSlice(key)) return false;
    const slash = std.mem.indexOfScalar(u8, key, '/') orelse return false;
    if (slash == 0 or slash == key.len - 1) return false;
    return std.mem.indexOfScalarPos(u8, key, slash + 1, '/') == null;
}

/// A tag value: its short name, which holds no slash, or `tagValues/` and
/// an id.
pub fn isTagValue(value: []const u8) bool {
    if (value.len == 0 or !std.unicode.utf8ValidateSlice(value)) return false;
    const slash = std.mem.indexOfScalar(u8, value, '/') orelse return true;
    const id = value[slash + 1 ..];
    return std.mem.eql(u8, value[0..slash], "tagValues") and id.len > 0 and std.mem.indexOfScalar(u8, id, '/') == null;
}

/// A field that must be there, and be UTF-8.
fn required(text: []const u8, comptime what: []const u8, diag: ?*Diagnostics) error{InvalidArgument}!void {
    if (text.len == 0) return refuse(diag, what ++ " is empty", .{});
    if (!std.unicode.utf8ValidateSlice(text)) return refuse(diag, what ++ " is not valid UTF-8", .{});
}

/// An Amazon resource name: there, UTF-8, and beginning `arn:`. The rest
/// is AWS's to judge, which production asks when the topic is made.
fn arn(text: []const u8, comptime what: []const u8, diag: ?*Diagnostics) error{InvalidArgument}!void {
    try required(text, what, diag);
    if (!std.mem.startsWith(u8, text, "arn:")) return refuse(diag, what ++ " does not begin arn:", .{});
}

/// A topic's schema settings: a schema named by its id or in full, with no
/// revision after it, an encoding this client can name, and revision ids,
/// where given, that are ones. What a topic reads once its schema is
/// deleted is not a schema to name.
pub fn schemaSettings(s: types.SchemaSettings, diag: ?*Diagnostics) error{InvalidArgument}!void {
    if (s.isDeleted()) {
        return refuse(diag, "the schema is _deleted-schema_, which a topic reads once its schema is deleted: name a schema that is there, or clear the settings", .{});
    }
    if (!isResourceId(s.schema) and !isSchemaName(s.schema)) {
        return refuse(diag, "the schema is neither a schema id nor projects/{{project}}/schemas/{{id}}", .{});
    }
    try schemaEncoding(s.encoding, diag);
    if (s.first_revision_id) |r| try revisionId(r, diag);
    if (s.last_revision_id) |r| try revisionId(r, diag);
}

/// A snapshot's settings: a subscription id or a full subscription name,
/// and labels by the rules for every label. The emulator keeps no labels,
/// so it cannot hold one to them.
pub fn snapshotConfig(config: types.SnapshotConfig, diag: ?*Diagnostics) error{InvalidArgument}!void {
    if (!isResourceId(config.subscription) and !isSubscriptionName(config.subscription)) {
        return refuse(diag, "the subscription is neither a subscription id nor projects/{{project}}/subscriptions/{{id}}", .{});
    }
    try labels(config.labels, diag);
    try tags(config.tags, diag);
}

/// A snapshot update: something to change, and the new labels valid.
pub fn snapshotUpdate(u: types.SnapshotUpdate, diag: ?*Diagnostics) error{InvalidArgument}!void {
    const l = u.labels orelse return refuse(diag, "the update changes nothing", .{});
    try labels(l, diag);
}

/// A seek's target: a time a `google.protobuf.Timestamp` can hold, or a
/// snapshot id or full snapshot name.
pub fn seekTarget(target: types.SeekTarget, diag: ?*Diagnostics) error{InvalidArgument}!void {
    switch (target) {
        .time => |t| if (!timestamp.inRange(t)) {
            return refuse(diag, "the seek time is outside 0001-01-01T00:00:00Z to 9999-12-31T23:59:59.999999999Z", .{});
        },
        .snapshot => |s| if (!isResourceId(s) and !isSnapshotName(s)) {
            return refuse(diag, "the snapshot is neither a snapshot id nor projects/{{project}}/snapshots/{{id}}", .{});
        },
    }
}

/// A schema as written: a type this client can name, and a definition that
/// is there, is UTF-8 and is within the bound. Whether it parses is the
/// server's to say.
pub fn schemaDefinition(d: types.SchemaDefinition, diag: ?*Diagnostics) error{InvalidArgument}!void {
    if (d.type == .unknown) return refuse(diag, "the schema type is .unknown, which is only ever read", .{});
    if (d.definition.len == 0) return refuse(diag, "the schema definition is empty", .{});
    if (d.definition.len > max_schema_definition_bytes) {
        return refuse(diag, "the schema definition is {d} bytes; the limit is {d}", .{ d.definition.len, max_schema_definition_bytes });
    }
    if (!std.unicode.utf8ValidateSlice(d.definition)) return refuse(diag, "the schema definition is not valid UTF-8", .{});
}

/// A revision id, which the client writes after an `@` in a path or a name:
/// not empty, and printable ASCII with none of `/`, `@`, `?`, `#` and `:`,
/// which would make the path another call's. Its length and alphabet are
/// Google's to change, so nothing more is asked.
pub fn revisionId(id: []const u8, diag: ?*Diagnostics) error{InvalidArgument}!void {
    if (isRevisionId(id)) return;
    return refuse(diag, "the revision id is empty, or holds a space, a control or non-ASCII character, or one of / @ ? # :", .{});
}

pub fn isRevisionId(id: []const u8) bool {
    if (id.len == 0) return false;
    for (id) |c| switch (c) {
        '/', '@', '?', '#', ':', ' ' => return false,
        else => if (!std.ascii.isPrint(c)) return false,
    };
    return true;
}

/// An encoding this client can name.
pub fn schemaEncoding(encoding: types.SchemaEncoding, diag: ?*Diagnostics) error{InvalidArgument}!void {
    if (encoding == .unknown) return refuse(diag, "the encoding is .unknown, which is only ever read", .{});
}

fn refuse(diag: ?*Diagnostics, comptime format: []const u8, args: anytype) error{InvalidArgument} {
    if (diag) |d| d.print(format, args);
    return error.InvalidArgument;
}

fn reject(diag: ?*Diagnostics, comptime format: []const u8, args: anytype) error{InvalidMessage} {
    if (diag) |d| d.print(format, args);
    return error.InvalidMessage;
}

const testing = std.testing;

fn expectRejected(messages: []const types.Message, ordering_key: ?[]const u8, want: []const u8) !void {
    var d: Diagnostics = .{};
    try testing.expectError(error.InvalidMessage, publish(messages, ordering_key, &d));
    if (std.mem.indexOf(u8, d.message(), want) == null) {
        std.debug.print("diagnostics \"{s}\" lacks \"{s}\"\n", .{ d.message(), want });
        return error.TestUnexpectedDiagnostics;
    }
}

test "publish limits: each at its boundary and one past it" {
    const gpa = testing.allocator;

    // Message count.
    const many = try gpa.alloc(types.Message, max_messages_per_publish + 1);
    defer gpa.free(many);
    @memset(many, .{ .data = "x" });
    try publish(many[0..max_messages_per_publish], null, null);
    try expectRejected(many, null, "1001 messages");
    try expectRejected(&.{}, null, "at least one");

    // Data size: the documented per-message limit is checked first...
    const big = try gpa.alloc(u8, max_data_bytes + 1);
    defer gpa.free(big);
    @memset(big, 'd');
    try expectRejected(&.{.{ .data = big }}, null, "bytes of data");
    // ...but over REST the encoded request is the real limit. Measured in
    // production: a 10,485,760-byte body is accepted, one more byte is not.
    // `{"messages":[{"data":""}]}` is 26 bytes; 7,864,299 bytes of data
    // encode to 10,485,732 bytes of base64.
    try testing.expectEqual(10_485_758, publishRequestBytes(&.{.{ .data = big[0..7_864_299] }}, null));
    try publish(&.{.{ .data = big[0..7_864_299] }}, null, null);
    try expectRejected(&.{.{ .data = big[0..7_864_300] }}, null, "the publish request would be 10485762 bytes");
    // The exact boundary: 7,864,284 bytes of data make a 10,485,738-byte
    // body, and `,"orderingKey":"abcde"` adds the last 22.
    try testing.expectEqual(10_485_760, publishRequestBytes(&.{.{ .data = big[0..7_864_284] }}, "abcde"));
    try publish(&.{.{ .data = big[0..7_864_284] }}, "abcde", null);
    try expectRejected(&.{.{ .data = big[0..7_864_284] }}, "abcdef", "10485761 bytes");

    // Attribute count, key size, value size.
    var attrs: [max_attributes + 1]types.Attribute = undefined;
    var names: [max_attributes + 1][4]u8 = undefined;
    for (&attrs, &names, 0..) |*a, *n, i| {
        n.* = .{ 'k', @intCast('0' + i / 100), @intCast('0' + i / 10 % 10), @intCast('0' + i % 10) };
        a.* = .{ .key = n, .value = "v" };
    }
    try publish(&.{.{ .attributes = attrs[0..max_attributes] }}, null, null);
    try expectRejected(&.{.{ .attributes = &attrs }}, null, "101 attributes");

    const key: [max_attribute_key_bytes + 1]u8 = @splat('k');
    try publish(&.{.{ .attributes = &.{.{ .key = key[0..max_attribute_key_bytes], .value = "" }} }}, null, null);
    try expectRejected(&.{.{ .attributes = &.{.{ .key = &key, .value = "" }} }}, null, "the key has 257 bytes");

    const value: [max_attribute_value_bytes + 1]u8 = @splat('v');
    try publish(&.{.{ .attributes = &.{.{ .key = "k", .value = value[0..max_attribute_value_bytes] }} }}, null, null);
    try expectRejected(&.{.{ .attributes = &.{.{ .key = "k", .value = &value }} }}, null, "the value has 1025 bytes");

    // Several messages share the request limit.
    try expectRejected(&.{ .{ .data = big[0..5_000_000] }, .{ .data = big[0..5_000_000] } }, null, "the publish request would be");

    // Ordering keys: at most 1024 UTF-8 bytes, measured in production.
    const long_key: [max_ordering_key_bytes + 1]u8 = @splat('o');
    try publish(&.{.{ .data = "x" }}, long_key[0..max_ordering_key_bytes], null);
    try expectRejected(&.{.{ .data = "x" }}, &long_key, "the ordering key has 1025 bytes");
    try publish(&.{.{ .data = "x" }}, test_util.repeat("é", 512), null);
    try expectRejected(&.{.{ .data = "x" }}, test_util.repeat("é", 513), "the ordering key has 1026 bytes");
}

test "publish rules: empty messages, duplicate keys, UTF-8" {
    try expectRejected(&.{ .{ .data = "x" }, .{} }, null, "message 1 has no data and no attributes");
    try publish(&.{.{ .attributes = &.{.{ .key = "k", .value = "" }} }}, null, null);
    try publish(&.{.{ .data = "\xff\xfe binary is fine" }}, "", null);
    try expectRejected(&.{.{ .attributes = &.{
        .{ .key = "a", .value = "1" },
        .{ .key = "b", .value = "2" },
        .{ .key = "a", .value = "3" },
    } }}, null, "attribute 2: the key repeats");
    try expectRejected(&.{.{ .attributes = &.{.{ .key = "\xff", .value = "" }} }}, null, "valid UTF-8");
    try expectRejected(&.{.{ .attributes = &.{.{ .key = "k", .value = "\xc3" }} }}, null, "valid UTF-8");
    try expectRejected(&.{.{ .data = "x" }}, "\xed\xa0\x80", "ordering key");
    try publish(&.{.{ .data = "x", .attributes = &.{.{ .key = "é", .value = "😀" }} }}, "ключ", null);
}

test "publish rules: attribute keys production rejects" {
    // The emulator accepts all of these; production answers INVALID_ARGUMENT.
    try expectRejected(&.{.{ .attributes = &.{.{ .key = "", .value = "v" }} }}, null, "keys must be non-empty");
    try expectRejected(&.{.{ .attributes = &.{.{ .key = "googfoo", .value = "v" }} }}, null, "not start with \"goog\"");
    try expectRejected(&.{.{ .attributes = &.{.{ .key = "GooGle", .value = "v" }} }}, null, "not start with \"goog\"");
    try expectRejected(&.{.{ .data = "x", .attributes = &.{ .{ .key = "ok", .value = "" }, .{ .key = "GOOG", .value = "" } } }}, null, "attribute 1");
    try publish(&.{.{ .attributes = &.{.{ .key = "xgoog", .value = "v" }} }}, null, null);
    try publish(&.{.{ .attributes = &.{.{ .key = "goo", .value = "v" }} }}, null, null);
}

test "ack ids and deadlines" {
    var d: Diagnostics = .{};
    try ackIds(&.{ "projects/p/subscriptions/s:1", "" }, &d);
    try testing.expectError(error.InvalidArgument, ackIds(&.{ "ok", "\x80" }, &d));
    try testing.expectEqualStrings("ack id 1 is not valid UTF-8", d.message());

    try modifyDeadline(0, null);
    try modifyDeadline(600, null);
    try testing.expectError(error.InvalidArgument, modifyDeadline(601, null));

    try subscriptionDeadline(0, null);
    try testing.expectError(error.InvalidArgument, subscriptionDeadline(9, null));
    try subscriptionDeadline(10, null);
    try subscriptionDeadline(600, null);
    try testing.expectError(error.InvalidArgument, subscriptionDeadline(601, null));

    try testing.expectEqual(1, clampPullMessages(0));
    try testing.expectEqual(10, clampPullMessages(10));
    try testing.expectEqual(1000, clampPullMessages(1000));
    try testing.expectEqual(1000, clampPullMessages(std.math.maxInt(u32)));
}

fn validatedIsEncodable(_: void, input: []const u8) !void {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    var g: test_util.ByteGen = .init(input);
    // Arbitrary bytes everywhere, including invalid UTF-8 and repeated keys.
    const messages = try a.alloc(types.Message, g.intRange(usize, 0, 3));
    for (messages) |*m| {
        const attrs = try a.alloc(types.Attribute, g.intRange(usize, 0, 3));
        for (attrs) |*attr| attr.* = .{ .key = g.slice(8), .value = g.slice(8) };
        m.* = .{ .data = g.slice(16), .attributes = attrs };
    }
    const ordering_key: ?[]const u8 = if (g.boolean()) g.slice(8) else null;

    publish(messages, ordering_key, null) catch return;
    // Whatever passes validation must encode to valid JSON within the limit.
    const body = try codec.encodePublish(a, messages, ordering_key);
    try testing.expect(std.unicode.utf8ValidateSlice(body));
    try testing.expect(body.len <= max_publish_request_bytes);
    _ = try std.json.parseFromSliceLeaky(std.json.Value, a, body, .{});
}

test "fuzz publish validation: what passes always encodes to valid JSON" {
    try test_util.fuzzBytes({}, validatedIsEncodable, .{ .corpus = &.{
        "\x01\x01\x02\xff\xfe\x01v\x03abc\x00",
        "\x01\x02\x01a\x01b\x01a\x01c\x00\x00",
        "\x00",
    } });
}

fn resourceIdProperty(_: void, input: []const u8) !void {
    // Accepted ids never need anything but the documented characters, so
    // they are safe in URLs once `%` and `+` are encoded.
    if (!isResourceId(input)) return;
    try testing.expect(input.len >= 3 and input.len <= 255);
    try testing.expect(std.ascii.isAlphabetic(input[0]));
    for (input) |c| try testing.expect(std.ascii.isAlphanumeric(c) or std.mem.indexOfScalar(u8, "-_.~+%", c) != null);
}

test "fuzz resource ids" {
    try test_util.fuzzBytes({}, resourceIdProperty, .{ .corpus = &.{ "abc", "googx", "a%41", "Zz9" } });
}

test "labels: the rules at their boundaries" {
    var d: Diagnostics = .{};
    const ok = [_][]const types.Label{
        &.{},
        &.{.{ .key = "a", .value = "" }},
        &.{.{ .key = "team", .value = "zig-gcp_1" }},
        &.{.{ .key = "k" ++ test_util.repeat("x", 62), .value = test_util.repeat("v", 63) }},
        // International characters go to the server to judge.
        &.{.{ .key = "équipe", .value = "zürich" }},
        &.{.{ .key = "日本", .value = "東京" }},
    };
    for (ok) |list| try labels(list, &d);
    const refused = [_]struct { []const types.Label, []const u8 }{
        .{ &.{.{ .key = "", .value = "v" }}, "the key is empty" },
        .{ &.{.{ .key = "Team", .value = "v" }}, "byte 0x54" },
        .{ &.{.{ .key = "team", .value = "Prod" }}, "byte 0x50" },
        .{ &.{.{ .key = "1team", .value = "v" }}, "starts with a lowercase letter" },
        .{ &.{.{ .key = "_team", .value = "v" }}, "starts with a lowercase letter" },
        .{ &.{.{ .key = "a b", .value = "v" }}, "byte 0x20" },
        .{ &.{.{ .key = "k" ++ test_util.repeat("x", 63), .value = "v" }}, "64 characters" },
        .{ &.{.{ .key = "k", .value = test_util.repeat("v", 64) }}, "64 characters" },
        .{ &.{.{ .key = "k", .value = "\xc0" }}, "not valid UTF-8" },
        .{ &.{ .{ .key = "k", .value = "1" }, .{ .key = "k", .value = "2" } }, "repeats" },
    };
    for (refused) |case| {
        try testing.expectError(error.InvalidArgument, labels(case[0], &d));
        try testing.expect(std.mem.indexOf(u8, d.message(), case[1]) != null);
    }
    var many: [max_labels + 1]types.Label = undefined;
    var keys: [max_labels + 1][4]u8 = undefined;
    for (&many, &keys, 0..) |*l, *k, i| l.* = .{ .key = std.fmt.bufPrint(k, "k{d}", .{i}) catch unreachable, .value = "" };
    try labels(many[0..max_labels], &d);
    try testing.expectError(error.InvalidArgument, labels(&many, &d));
}

test "subscription settings: each rule at its boundary" {
    var d: Diagnostics = .{};
    const base: types.SubscriptionConfig = .{ .topic_id = "t" };
    try subscriptionConfig(base, false, &d);

    var c = base;
    c.filter = test_util.repeat("x", max_filter_bytes);
    try subscriptionConfig(c, false, &d);
    c.filter = test_util.repeat("x", max_filter_bytes + 1);
    try testing.expectError(error.InvalidArgument, subscriptionConfig(c, false, &d));

    for ([_]u8{ 5, 100 }) |n| try deadLetterPolicy(.{ .topic = "dead", .max_delivery_attempts = n }, &d);
    for ([_]u8{ 0, 4, 101 }) |n| try testing.expectError(error.InvalidArgument, deadLetterPolicy(.{ .topic = "dead", .max_delivery_attempts = n }, &d));
    try deadLetterPolicy(.{ .topic = "projects/other-project/topics/dead" }, &d);
    for ([_][]const u8{ "de", "projects//topics/dead", "projects/p/topics/", "projects/p/subscriptions/dead", "goog-dead" }) |topic| {
        try testing.expectError(error.InvalidArgument, deadLetterPolicy(.{ .topic = topic }, &d));
    }

    try backoff(.{ .minimum = .zero, .maximum = .zero }, &d);
    try backoff(.{ .minimum = .fromSeconds(600), .maximum = .fromSeconds(600) }, &d);
    try testing.expectError(error.InvalidArgument, backoff(.{ .minimum = .fromMilliseconds(600_001) }, &d));
    try testing.expectError(error.InvalidArgument, backoff(.{ .minimum = .fromSeconds(20), .maximum = .fromSeconds(10) }, &d));
    try testing.expectError(error.InvalidArgument, backoff(.{ .minimum = .fromNanoseconds(-1) }, &d));

    try messageRetention(min_message_retention, &d);
    try messageRetention(max_message_retention, &d);
    try testing.expectError(error.InvalidArgument, messageRetention(.fromSeconds(599), &d));
    try testing.expectError(error.InvalidArgument, messageRetention(.fromSeconds(31 * 24 * 3600 + 1), &d));

    try expiration(.{ .after = min_expiration }, null, &d);
    try expiration(.never, .fromSeconds(99 * 24 * 3600), &d);
    try testing.expectError(error.InvalidArgument, expiration(.{ .after = .fromSeconds(24 * 3600 - 1) }, null, &d));
    // A ttl the wire format itself cannot carry.
    try testing.expectError(error.InvalidArgument, expiration(.{ .after = .fromSeconds(@as(i64, @import("core").duration.max_seconds) + 1) }, null, &d));
    try testing.expectEqualStrings("the expiration ttl is out of range", d.message());
    // No shorter than the retention it would outlive.
    try expiration(.{ .after = .fromSeconds(2 * 24 * 3600) }, .fromSeconds(2 * 24 * 3600), &d);
    try testing.expectError(error.InvalidArgument, expiration(.{ .after = .fromSeconds(2 * 24 * 3600) }, .fromSeconds(3 * 24 * 3600), &d));
    c = base;
    c.message_retention = .fromSeconds(3 * 24 * 3600);
    c.expiration = .{ .after = .fromSeconds(2 * 24 * 3600) };
    try testing.expectError(error.InvalidArgument, subscriptionConfig(c, false, &d));
    c = base;
    c.ack_deadline_seconds = 9;
    try testing.expectError(error.InvalidArgument, subscriptionConfig(c, false, &d));
}

test "topic settings: the KMS key's shape and the storage policy" {
    var d: Diagnostics = .{};
    try kmsKeyName("projects/p/locations/europe-west1/keyRings/ring/cryptoKeys/key", &d);
    for ([_][]const u8{
        "",
        "projects/p/locations/l/keyRings/r/cryptoKeys",
        "projects/p/locations/l/keyRings/r/cryptoKeys/",
        "projects/p/locations/l/keyRings/r/cryptoKeys/k/cryptoKeyVersions/1",
        "projects//locations/l/keyRings/r/cryptoKeys/k",
        "project/p/locations/l/keyRings/r/cryptoKeys/k",
        "projects/p/locations/l/keyrings/r/cryptoKeys/k",
    }) |name| try testing.expectError(error.InvalidArgument, kmsKeyName(name, &d));
    try storagePolicy(.{ .allowed_persistence_regions = &.{"europe-west1"} }, &d);
    try testing.expectError(error.InvalidArgument, storagePolicy(.{ .allowed_persistence_regions = &.{} }, &d));
    try testing.expectError(error.InvalidArgument, storagePolicy(.{ .allowed_persistence_regions = &.{""} }, &d));
    try testing.expectError(error.InvalidArgument, topicConfig(.{ .message_retention = .fromSeconds(60) }, &d));
    try topicConfig(.{}, &d);
}

test "updates: something must change, and what changes must be valid" {
    var d: Diagnostics = .{};
    try testing.expectError(error.InvalidArgument, subscriptionUpdate(.{}, false, &d));
    try testing.expectEqualStrings("the update changes nothing", d.message());
    try testing.expectError(error.InvalidArgument, topicUpdate(.{}, &d));
    try subscriptionUpdate(.{ .labels = &.{} }, false, &d);
    // Everything at once.
    try subscriptionUpdate(.{
        .ack_deadline_seconds = 10,
        .enable_exactly_once_delivery = true,
        .dead_letter_policy = .clear,
        .retry_policy = .{ .set = .{} },
        .message_retention = .clear,
        .retain_acked_messages = false,
        .expiration = .never,
        .labels = &.{},
    }, false, &d);
    try topicUpdate(.{ .labels = &.{}, .message_retention = .clear, .kms_key_name = .clear, .message_storage_policy = .clear }, &d);
    try subscriptionUpdate(.{ .retry_policy = .clear }, false, &d);
    try subscriptionUpdate(.{ .expiration = .default }, false, &d);
    // A delivery is a change on its own; exactly-once beside a kind in the
    // same update, and an export kind on an emulator, are refused.
    try subscriptionUpdate(.{ .delivery = .pull }, false, &d);
    try subscriptionUpdate(.{ .delivery = .pull }, true, &d);
    try subscriptionUpdate(.{ .delivery = .{ .push = .{ .endpoint = "https://e.x/h" } } }, true, &d);
    try subscriptionUpdate(.{ .delivery = .{ .bigquery = .{ .table = "p.d.t" } }, .enable_exactly_once_delivery = false }, false, &d);
    try testing.expectError(error.InvalidArgument, subscriptionUpdate(.{
        .delivery = .{ .push = .{ .endpoint = "https://e.x/h" } },
        .enable_exactly_once_delivery = true,
    }, false, &d));
    try testing.expectError(error.InvalidArgument, subscriptionUpdate(.{ .delivery = .{ .bigquery = .{ .table = "p.d.t" } } }, true, &d));
    try testing.expectEqualStrings("the emulator cannot change a subscription's delivery to a BigQuery or Cloud Storage config: it refuses their mask paths as unknown fields", d.message());
    try testing.expectError(error.InvalidArgument, subscriptionUpdate(.{ .delivery = .{ .cloud_storage = .{ .bucket = "b" } } }, true, &d));
    try testing.expectError(error.InvalidArgument, subscriptionUpdate(.{ .delivery = .{ .push = .{ .endpoint = "http://e.x/h" } } }, false, &d));
    try testing.expectError(error.InvalidArgument, subscriptionUpdate(.{ .ack_deadline_seconds = 0 }, false, &d));
    try testing.expectError(error.InvalidArgument, subscriptionUpdate(.{ .ack_deadline_seconds = 601 }, false, &d));
    try testing.expectError(error.InvalidArgument, subscriptionUpdate(.{ .dead_letter_policy = .{ .set = .{ .topic = "t", .max_delivery_attempts = 4 } } }, false, &d));
    try testing.expectError(error.InvalidArgument, subscriptionUpdate(.{
        .message_retention = .{ .set = .fromSeconds(5 * 24 * 3600) },
        .expiration = .{ .after = .fromSeconds(4 * 24 * 3600) },
    }, false, &d));
    try topicUpdate(.{ .kms_key_name = .clear }, &d);
    try testing.expectError(error.InvalidArgument, topicUpdate(.{ .kms_key_name = .{ .set = "nope" } }, &d));
    // The set arms of the other two topic fields, valid and not.
    try topicUpdate(.{ .message_retention = .{ .set = .fromSeconds(3600) } }, &d);
    try testing.expectError(error.InvalidArgument, topicUpdate(.{ .message_retention = .{ .set = .fromSeconds(1) } }, &d));
    try topicUpdate(.{ .message_storage_policy = .{ .set = .{ .allowed_persistence_regions = &.{"us-east1"} } } }, &d);
    try testing.expectError(error.InvalidArgument, topicUpdate(.{ .message_storage_policy = .{ .set = .{ .allowed_persistence_regions = &.{} } } }, &d));
}

test "snapshot settings: the subscription's two forms, labels, and an update that changes something" {
    var d: Diagnostics = .{};
    try snapshotConfig(.{ .subscription = "orders" }, &d);
    try snapshotConfig(.{ .subscription = "projects/other-project/subscriptions/orders", .labels = &.{.{ .key = "env", .value = "test" }} }, &d);
    try testing.expect(isSubscriptionName("projects/example.com:proj/subscriptions/a%41+b"));
    try testing.expectError(error.InvalidArgument, snapshotConfig(.{ .subscription = "" }, &d));
    try testing.expectEqualStrings("the subscription is neither a subscription id nor projects/{project}/subscriptions/{id}", d.message());
    // A topic's name, a snapshot's, half a name, and a bad id or project
    // inside a whole one are none.
    for ([_][]const u8{
        "projects/p/topics/orders",
        "projects/p/snapshots/orders",
        "subscriptions/orders",
        "projects/p/subscriptions/go",
        "projects//subscriptions/orders",
        "projects/p/subscriptions/orders/x",
    }) |bad| {
        try testing.expect(!isSubscriptionName(bad));
        try testing.expectError(error.InvalidArgument, snapshotConfig(.{ .subscription = bad }, &d));
    }
    // The split did not change what a topic's name is.
    try testing.expect(isTopicName("projects/p/topics/orders"));
    try testing.expect(!isTopicName("projects/p/subscriptions/orders"));

    try testing.expectError(error.InvalidArgument, snapshotConfig(.{ .subscription = "orders", .labels = &.{.{ .key = "UPPER", .value = "v" }} }, &d));
    try testing.expectError(error.InvalidArgument, snapshotUpdate(.{}, &d));
    try testing.expectEqualStrings("the update changes nothing", d.message());
    try snapshotUpdate(.{ .labels = &.{} }, &d);
    try snapshotUpdate(.{ .labels = &.{.{ .key = "env", .value = "prod" }} }, &d);
    try testing.expectError(error.InvalidArgument, snapshotUpdate(.{ .labels = &.{.{ .key = "Bad Key", .value = "v" }} }, &d));
}

test "delivery checks: the push endpoint by target, exactly-once beside a kind, and the OIDC account" {
    var d: Diagnostics = .{};
    const push: types.Delivery = .{ .push = .{ .endpoint = "https://example.com/hook" } };
    try delivery(push, false, false, &d);
    try delivery(push, false, true, &d);
    // Exactly-once works only with pull, on any target.
    try delivery(.pull, true, false, &d);
    try testing.expectError(error.InvalidArgument, delivery(push, true, false, &d));
    try testing.expectError(error.InvalidArgument, delivery(.{ .bigquery = .{ .table = "p.d.t" } }, true, false, &d));
    try testing.expectError(error.InvalidArgument, delivery(.{ .cloud_storage = .{ .bucket = "b" } }, true, true, &d));
    try testing.expect(std.mem.indexOf(u8, d.message(), "exactly-once") != null);
    var c: types.SubscriptionConfig = .{ .topic_id = "t", .delivery = push, .enable_exactly_once_delivery = true };
    try testing.expectError(error.InvalidArgument, subscriptionConfig(c, false, &d));
    c.enable_exactly_once_delivery = false;
    try subscriptionConfig(c, false, &d);

    // http:// is for the emulator alone; production holds push to https://.
    const insecure: types.Delivery = .{ .push = .{ .endpoint = "http://127.0.0.1:8085/hook" } };
    try delivery(insecure, false, true, &d);
    try testing.expectError(error.InvalidArgument, delivery(insecure, false, false, &d));
    try testing.expectEqualStrings("the push endpoint is not an https:// URL, which production requires", d.message());
    for ([_][]const u8{ "", "https://", "http://", "HTTPS://example.com", "ftp://example.com", "example.com/hook", "https:/example.com" }) |endpoint| {
        try testing.expectError(error.InvalidArgument, pushConfig(.{ .endpoint = endpoint }, true, &d));
        try testing.expectError(error.InvalidArgument, pushConfig(.{ .endpoint = endpoint }, false, &d));
    }
    try testing.expectError(error.InvalidArgument, pushConfig(.{ .endpoint = "https://e.x/\xff" }, false, &d));

    // The OIDC account needs the shape of an address, and its audience UTF-8.
    try pushConfig(.{ .endpoint = "https://e.x/h", .oidc_token = .{ .service_account_email = "sa@p.iam.gserviceaccount.com", .audience = "zigps" } }, false, &d);
    for ([_][]const u8{ "", "sa", "sa@", "@d.com", "sa@nodot", "sa@d.com@x.com", "sa @d.com", "sa@d.", "sa@.d", "s\xffa@d.com" }) |email| {
        try testing.expectError(error.InvalidArgument, pushConfig(.{ .endpoint = "https://e.x/h", .oidc_token = .{ .service_account_email = email } }, false, &d));
    }
    try testing.expectError(error.InvalidArgument, pushConfig(.{ .endpoint = "https://e.x/h", .oidc_token = .{ .service_account_email = "sa@p.d", .audience = "\xff" } }, false, &d));
}

test "BigQuery table names: production's verdicts, 2026-10-10" {
    var d: Diagnostics = .{};
    // Shapes production served (refusing them only at the missing table).
    for ([_][]const u8{ "extractctl.zigps_nope.t", "extractctl:zigps_nope.t", "a.b.c.d", "extractctl.zigps-nope.t", "example.com:p.d.t" }) |table| {
        try bigQueryConfig(.{ .table = table }, &d);
    }
    try testing.expectError(error.InvalidArgument, bigQueryConfig(.{ .table = "p.d.\xff" }, &d));
    try testing.expect(std.mem.indexOf(u8, d.message(), "not valid UTF-8") != null);
    // Shapes it refused as invalid, and a few of the same kind.
    for ([_][]const u8{ "zigps_nope.t", "extractctl.zigps_nope", "nonsense", ".zigps_nope.t", "extractctl..t", "", ":d.t", "p:d", "p:d.t:x", "p.d.t ", "p.d\t.t" }) |table| {
        try testing.expectError(error.InvalidArgument, bigQueryConfig(.{ .table = table }, &d));
    }
    try testing.expect(std.mem.indexOf(u8, d.message(), "project.dataset.table") != null);
    try testing.expectError(error.InvalidArgument, bigQueryConfig(.{ .table = "p.d.t", .service_account_email = "nope" }, &d));
}

test "Cloud Storage config: the bucket's shape, the filename parts and the batching bounds" {
    var d: Diagnostics = .{};
    try cloudStorageConfig(.{ .bucket = "zigps-b" }, &d);
    // Upper case passed production's checks: only the 503 trap is held here.
    try cloudStorageConfig(.{ .bucket = "UPPER.name" }, &d);
    for ([_][]const u8{ "", "gs://zigps-b", "zigps-b/logs", "b b", "b\nb", "\xff" }) |bucket| {
        try testing.expectError(error.InvalidArgument, cloudStorageConfig(.{ .bucket = bucket }, &d));
    }

    // Filename parts: a suffix must not end in '/', control characters are
    // refused, and prefix and suffix together hold at most 992 characters.
    try cloudStorageConfig(.{ .bucket = "b", .filename_prefix = "a/b/", .filename_suffix = ".txt" }, &d);
    try testing.expectError(error.InvalidArgument, cloudStorageConfig(.{ .bucket = "b", .filename_suffix = "logs/" }, &d));
    try testing.expectError(error.InvalidArgument, cloudStorageConfig(.{ .bucket = "b", .filename_prefix = "a\nb" }, &d));
    try testing.expectError(error.InvalidArgument, cloudStorageConfig(.{ .bucket = "b", .filename_suffix = "a\x7f" }, &d));
    try testing.expectError(error.InvalidArgument, cloudStorageConfig(.{ .bucket = "b", .filename_prefix = "\xc3" }, &d));
    try cloudStorageConfig(.{ .bucket = "b", .filename_prefix = test_util.repeat("x", 500), .filename_suffix = test_util.repeat("y", 492) }, &d);
    try testing.expectError(error.InvalidArgument, cloudStorageConfig(.{ .bucket = "b", .filename_prefix = test_util.repeat("x", 500), .filename_suffix = test_util.repeat("y", 493) }, &d));
    // Characters, not bytes, as production counts them.
    try cloudStorageConfig(.{ .bucket = "b", .filename_prefix = test_util.repeat("é", 992) }, &d);

    // Batching: the bounds production names, 0 meaning no such limit.
    try cloudStorageConfig(.{ .bucket = "b", .max_duration = .fromSeconds(60) }, &d);
    try cloudStorageConfig(.{ .bucket = "b", .max_duration = .fromSeconds(600) }, &d);
    try testing.expectError(error.InvalidArgument, cloudStorageConfig(.{ .bucket = "b", .max_duration = .fromMilliseconds(59_999) }, &d));
    try testing.expectError(error.InvalidArgument, cloudStorageConfig(.{ .bucket = "b", .max_duration = .fromSeconds(601) }, &d));
    try cloudStorageConfig(.{ .bucket = "b", .max_bytes = min_storage_bytes }, &d);
    try cloudStorageConfig(.{ .bucket = "b", .max_bytes = max_storage_bytes }, &d);
    try testing.expectError(error.InvalidArgument, cloudStorageConfig(.{ .bucket = "b", .max_bytes = min_storage_bytes - 1 }, &d));
    try testing.expectError(error.InvalidArgument, cloudStorageConfig(.{ .bucket = "b", .max_bytes = max_storage_bytes + 1 }, &d));
    try cloudStorageConfig(.{ .bucket = "b", .max_messages = min_storage_messages }, &d);
    // Production took an int64's maximum; more cannot travel.
    try cloudStorageConfig(.{ .bucket = "b", .max_messages = std.math.maxInt(i64) }, &d);
    try testing.expectError(error.InvalidArgument, cloudStorageConfig(.{ .bucket = "b", .max_messages = @as(u64, std.math.maxInt(i64)) + 1 }, &d));
    try testing.expectError(error.InvalidArgument, cloudStorageConfig(.{ .bucket = "b", .max_messages = min_storage_messages - 1 }, &d));
    try testing.expectError(error.InvalidArgument, cloudStorageConfig(.{ .bucket = "b", .service_account_email = "not an address" }, &d));
}

test "datetime format: production's verdict on every string measured, 2026-10-10" {
    // Passed production's checks (each stopped only at the missing bucket).
    const accepted = [_][]const u8{
        "YYYY-MM-DD/hh_mm_ssZ",
        "YYYYMMDDhhmmss",
        "YYYY-MM-DDThh:mm:ss+00:00",
        "YYYY-MM-DDThh:mm:ssZ",
        "YYYY/MM/DD/hh/mm/ss",
        "YYYY-MM-DD-hh-mm-ss-",
        "-YYYY-MM-DD-hh-mm-ss",
        "ssmmhhDDMMYYYY",
        "",
    };
    for (accepted) |format| try filenameDatetimeFormat(format, null);
    // Refused, with production's reason beside each.
    var d: Diagnostics = .{};
    const refused = [_][]const u8{
        "YY-MM-DD hh:mm:ss", // a space
        "YYYY-MM-DD", // no hh
        "hh:mm:ss", // no year
        "YYYY-MM-DD-hh-mm", // no ss
        "YYYY-YYYY-MM-DD-hh-mm-ss", // two years
        "YYYY-MM-DD-hh-mm-ss-ss", // two ss
        "YYYY.MM.DD.hh.mm.ss", // dots
        "yyyy-mm-dd-hh-mm-ss", // no year (lower case)
        "YYYY-MM-DDThh:mm:ssZZ", // two Z
        "YYYY-MM-DDTThh:mm:ss", // two T
        "YYYY-MM-DD_hh:mm:ss_x", // an x
        "YYYY-MM-DD hh:mm:ssZ+00:00", // two timezone offsets (and a space)
    };
    for (refused) |format| try testing.expectError(error.InvalidArgument, filenameDatetimeFormat(format, &d));
    // The documented short year, which the probe did not reach.
    try filenameDatetimeFormat("YY-MM-DDThh:mm:ssZ", null);
    try testing.expectError(error.InvalidArgument, filenameDatetimeFormat("YYY-MM-DDThh:mm:ssZ", &d));
}

/// An independent reading of the datetime rules: maximal runs of each
/// matcher letter, where only a run of exactly `YY` or `YYYY` is a year,
/// in place of the check's greedy scan. Verdicts must agree.
fn referenceDatetimeVerdict(format: []const u8) bool {
    if (format.len == 0) return true;
    var counts: [8]u32 = @splat(0); // year MM DD hh mm ss T zone
    var i: usize = 0;
    while (i < format.len) {
        const c = format[i];
        const slot: ?usize = switch (c) {
            'Y' => 0,
            'M' => 1,
            'D' => 2,
            'h' => 3,
            'm' => 4,
            's' => 5,
            else => null,
        };
        if (slot) |s| {
            var run: usize = 1;
            while (i + run < format.len and format[i + run] == c) run += 1;
            if (c == 'Y') {
                if (run != 2 and run != 4) return false;
                counts[0] += 1;
            } else {
                if (run % 2 != 0) return false;
                counts[s] += @intCast(run / 2);
            }
            i += run;
        } else if (std.mem.startsWith(u8, format[i..], "+00:00")) {
            counts[7] += 1;
            i += "+00:00".len;
        } else {
            switch (c) {
                'T' => counts[6] += 1,
                'Z' => counts[7] += 1,
                '-', '_', ':', '/' => {},
                else => return false,
            }
            i += 1;
        }
    }
    for (counts[0..6]) |n| if (n != 1) return false;
    return counts[6] <= 1 and counts[7] <= 1;
}

fn datetimeFormatProperty(_: void, input: []const u8) !void {
    var g: test_util.ByteGen = .init(input);
    const tokens = [_][]const u8{ "YYYY", "YY", "MM", "DD", "hh", "mm", "ss", "T", "Z", "+00:00", "-", "_", ":", "/", "Y", "M", "m", "x", " ", ".", "é", "\x00", "+00:0" };
    var buf: [128]u8 = undefined;
    var len: usize = 0;
    for (0..g.intRange(u8, 0, 14)) |_| {
        const token = g.pick([]const u8, &tokens);
        if (len + token.len > buf.len) break;
        @memcpy(buf[len..][0..token.len], token);
        len += token.len;
    }
    const format = buf[0..len];
    const accepted = if (filenameDatetimeFormat(format, null)) |_| true else |_| false;
    try testing.expectEqual(referenceDatetimeVerdict(format), accepted);
}

test "fuzz datetime format: the check agrees with a run-based reference" {
    try test_util.fuzzBytes({}, datetimeFormatProperty, .{ .corpus = &.{
        "",
        "\x0e\x00\x0a\x02\x0b\x03\x0c\x04\x0d\x05\x06\x07\x08\x09\x01",
        "\x05\x01\x01\x0a\x0a\x09",
    } });
}

test "a seek's target: a time a timestamp can hold, or a snapshot's id or full name" {
    var d: Diagnostics = .{};
    try seekTarget(.{ .time = .{ .nanoseconds = 0 } }, &d);
    try seekTarget(.{ .time = timestamp.min }, &d);
    try seekTarget(.{ .time = timestamp.max }, &d);
    try testing.expectError(error.InvalidArgument, seekTarget(.{ .time = .{ .nanoseconds = timestamp.max.nanoseconds + 1 } }, &d));
    try testing.expectEqualStrings("the seek time is outside 0001-01-01T00:00:00Z to 9999-12-31T23:59:59.999999999Z", d.message());
    try testing.expectError(error.InvalidArgument, seekTarget(.{ .time = .{ .nanoseconds = timestamp.min.nanoseconds - 1 } }, &d));

    try seekTarget(.{ .snapshot = "before-deploy" }, &d);
    try seekTarget(.{ .snapshot = "projects/other-project/snapshots/before-deploy" }, &d);
    try testing.expect(isSnapshotName("projects/example.com:proj/snapshots/a%41+b"));
    for ([_][]const u8{ "", "go", "projects/p/subscriptions/orders", "snapshots/before", "projects/p/snapshots/go", "projects/p/snapshots/a/b" }) |bad| {
        try testing.expect(!isSnapshotName(bad));
        try testing.expectError(error.InvalidArgument, seekTarget(.{ .snapshot = bad }, &d));
    }
    try testing.expectEqualStrings("the snapshot is neither a snapshot id nor projects/{project}/snapshots/{id}", d.message());
}

test "schemas: a definition that is there, UTF-8 and within the bound, of a type and in an encoding this client can name" {
    var d: Diagnostics = .{};
    try schemaDefinition(.{ .type = .avro, .definition = "{\"type\":\"record\",\"name\":\"M\",\"fields\":[]}" }, &d);
    try schemaDefinition(.{ .type = .protocol_buffer, .definition = "syntax = \"proto3\";\nmessage M { string caf\xc3\xa9 = 1; }\n" }, &d);

    try testing.expectError(error.InvalidArgument, schemaDefinition(.{ .type = .unknown, .definition = "{}" }, &d));
    try testing.expectEqualStrings("the schema type is .unknown, which is only ever read", d.message());
    try testing.expectError(error.InvalidArgument, schemaDefinition(.{ .type = .avro, .definition = "" }, &d));
    try testing.expectEqualStrings("the schema definition is empty", d.message());
    try testing.expectError(error.InvalidArgument, schemaDefinition(.{ .type = .avro, .definition = "\"caf\xe9\"" }, &d));
    try testing.expectEqualStrings("the schema definition is not valid UTF-8", d.message());

    // The bound, at its edge.
    const big = try testing.allocator.alloc(u8, max_schema_definition_bytes + 1);
    defer testing.allocator.free(big);
    @memset(big, ' ');
    try schemaDefinition(.{ .type = .avro, .definition = big[0..max_schema_definition_bytes] }, &d);
    try testing.expectError(error.InvalidArgument, schemaDefinition(.{ .type = .avro, .definition = big }, &d));
    try testing.expectEqualStrings("the schema definition is 307201 bytes; the limit is 307200", d.message());

    try schemaEncoding(.json, &d);
    try schemaEncoding(.binary, &d);
    try testing.expectError(error.InvalidArgument, schemaEncoding(.unknown, &d));
    try testing.expectEqualStrings("the encoding is .unknown, which is only ever read", d.message());
    // Without diagnostics the checks still refuse.
    try testing.expectError(error.InvalidArgument, schemaDefinition(.{ .type = .avro, .definition = "" }, null));
}

test "revision ids: what the server makes passes, and nothing that could turn a path into another call's" {
    var d: Diagnostics = .{};
    for ([_][]const u8{ "c7cfa2a8", "1b46a16a", "A", "a-b_c.d~e", "0123456789abcdef0123456789abcdef" }) |good| {
        try revisionId(good, &d);
    }
    for ([_][]const u8{ "", "c7cf a2a8", "c7cfa2a8:rollback", "a@b", "a/b", "a?view=FULL", "a#b", "c7cfa2a8\n", "caf\xc3\xa9", "\x7f", "\x00" }) |bad| {
        try testing.expect(!isRevisionId(bad));
        try testing.expectError(error.InvalidArgument, revisionId(bad, &d));
        try testing.expectEqualStrings("the revision id is empty, or holds a space, a control or non-ASCII character, or one of / @ ? # :", d.message());
    }
}

test "a topic's schema settings: the schema's two forms, an encoding, and revisions that are ones" {
    var d: Diagnostics = .{};
    try schemaSettings(.{ .schema = "order-v1", .encoding = .json }, &d);
    try schemaSettings(.{ .schema = "projects/other-project/schemas/a%41+b", .encoding = .binary, .first_revision_id = "1b46a16a", .last_revision_id = "6f0519a4" }, &d);
    try topicConfig(.{ .schema = .{ .schema = "order-v1", .encoding = .json } }, &d);
    try topicUpdate(.{ .schema = .{ .set = .{ .schema = "order-v1", .encoding = .json } } }, &d);
    // Taking the schema away is a change.
    try topicUpdate(.{ .schema = .clear }, &d);

    for ([_][]const u8{
        "",
        "go",
        "projects/p/topics/order-v1",
        "schemas/order-v1",
        "projects//schemas/order-v1",
        "projects/p/schemas/order-v1/x",
        // A revision is the range's to name, never the name's.
        "order-v1@1b46a16a",
        "projects/p/schemas/order-v1@1b46a16a",
    }) |bad| {
        try testing.expect(!isSchemaName(bad));
        try testing.expectError(error.InvalidArgument, schemaSettings(.{ .schema = bad, .encoding = .json }, &d));
        try testing.expectEqualStrings("the schema is neither a schema id nor projects/{project}/schemas/{id}", d.message());
    }
    try testing.expectError(error.InvalidArgument, schemaSettings(.{ .schema = "_deleted-schema_", .encoding = .json }, &d));
    try testing.expect(std.mem.startsWith(u8, d.message(), "the schema is _deleted-schema_"));
    try testing.expectError(error.InvalidArgument, schemaSettings(.{ .schema = "order-v1", .encoding = .unknown }, &d));
    try testing.expectEqualStrings("the encoding is .unknown, which is only ever read", d.message());
    try testing.expectError(error.InvalidArgument, schemaSettings(.{ .schema = "order-v1", .encoding = .json, .first_revision_id = "" }, &d));
    try testing.expectError(error.InvalidArgument, schemaSettings(.{ .schema = "order-v1", .encoding = .json, .last_revision_id = "a/b" }, &d));
    // Through a topic's settings and an update, the same refusals.
    try testing.expectError(error.InvalidArgument, topicConfig(.{ .schema = .{ .schema = "go", .encoding = .json } }, &d));
    try testing.expectError(error.InvalidArgument, topicUpdate(.{ .schema = .{ .set = .{ .schema = "order-v1", .encoding = .unknown } } }, &d));
}

fn js(name: []const u8, code: []const u8) types.MessageTransform {
    return .{ .kind = .{ .javascript_udf = .{ .function_name = name, .code = code } } };
}

test "message transforms: how many run, each function's name and code, and no kind this client cannot write" {
    var d: Diagnostics = .{};
    const code = "function f(m) { return m; }";
    try messageTransforms(&.{}, &d);
    try messageTransforms(&.{js("f", code)}, &d);

    // Five that run pass and a sixth is refused, as production and an
    // emulator refuse it. One that is disabled is not counted.
    var seven = [_]types.MessageTransform{ js("a", code), js("b", code), js("c", code), js("d", code), js("e", code), js("f", code), js("g", code) };
    try messageTransforms(seven[0..5], &d);
    try testing.expectError(error.InvalidArgument, messageTransforms(seven[0..6], &d));
    try testing.expectEqualStrings("6 message transforms are not disabled; the limit is 5", d.message());
    seven[5].disabled = true;
    try messageTransforms(seven[0..6], &d);
    try testing.expectError(error.InvalidArgument, messageTransforms(&seven, &d));
    seven[0].disabled = true;
    try messageTransforms(&seven, &d);

    // Production takes 20,480 bytes of code and refuses 20,481, counted
    // in bytes (measured 2026-10-12).
    var big: [max_udf_code_bytes + 1]u8 = @splat('x');
    try messageTransforms(&.{js("f", big[0..max_udf_code_bytes])}, &d);
    try testing.expectError(error.InvalidArgument, messageTransforms(&.{ js("f", code), js("g", &big) }, &d));
    try testing.expectEqualStrings("message transform 1 has 20481 bytes of code; the limit is 20480", d.message());
    @memcpy(big[max_udf_code_bytes - 2 ..], "\u{20ac}");
    try testing.expectError(error.InvalidArgument, messageTransforms(&.{js("f", &big)}, &d));
    @memcpy(big[max_udf_code_bytes - 3 .. max_udf_code_bytes], "\u{20ac}");
    try messageTransforms(&.{js("f", big[0..max_udf_code_bytes])}, &d);

    // A name and code that are there, and are UTF-8.
    try testing.expectError(error.InvalidArgument, messageTransforms(&.{js("", code)}, &d));
    try testing.expectEqualStrings("message transform 0 has no function name", d.message());
    try testing.expectError(error.InvalidArgument, messageTransforms(&.{ js("f", code), js("g", "") }, &d));
    try testing.expectEqualStrings("message transform 1 has no code", d.message());
    try testing.expectError(error.InvalidArgument, messageTransforms(&.{js("f\xff", code)}, &d));
    try testing.expectEqualStrings("message transform 0 has a function name that is not valid UTF-8", d.message());
    try testing.expectError(error.InvalidArgument, messageTransforms(&.{js("f", "return \xc3")}, &d));
    try testing.expectEqualStrings("message transform 0 has code that is not valid UTF-8", d.message());
    try messageTransforms(&.{js("\u{e9}t\u{e9}", "// \u{20ac}")}, &d);

    // No two functions of one name, whether or not either runs.
    try testing.expectError(error.InvalidArgument, messageTransforms(&.{ js("f", code), js("g", code), js("f", "function f() {}") }, &d));
    try testing.expectEqualStrings("message transforms 0 and 2 have the same function name", d.message());
    var twice = [_]types.MessageTransform{ js("g", code), js("g", code) };
    twice[0].disabled = true;
    try testing.expectError(error.InvalidArgument, messageTransforms(&twice, &d));
    try testing.expectEqualStrings("message transforms 0 and 1 have the same function name", d.message());
    try messageTransforms(&.{ js("f", code), js("F", code) }, &d);

    // A kind this client does not model is only ever read, disabled or not.
    try testing.expectError(error.InvalidArgument, messageTransforms(&.{ js("f", code), .{ .kind = .other } }, &d));
    try testing.expect(std.mem.startsWith(u8, d.message(), "message transform 1 is of a kind this client does not model"));
    try testing.expectError(error.InvalidArgument, messageTransforms(&.{.{ .kind = .other, .disabled = true }}, &d));
    try testing.expect(std.mem.startsWith(u8, d.message(), "message transform 0 is of a kind this client does not model"));

    // Through the settings and the updates of both resources. An empty
    // list in an update is a change: it clears.
    try topicConfig(.{ .message_transforms = &.{js("f", code)} }, &d);
    try subscriptionConfig(.{ .topic_id = "t", .message_transforms = &.{js("f", code)} }, false, &d);
    try topicUpdate(.{ .message_transforms = &.{js("f", code)} }, &d);
    try topicUpdate(.{ .message_transforms = &.{} }, &d);
    try subscriptionUpdate(.{ .message_transforms = &.{js("f", code)} }, false, &d);
    try subscriptionUpdate(.{ .message_transforms = &.{} }, true, &d);
    try testing.expectError(error.InvalidArgument, topicConfig(.{ .message_transforms = &.{js("", code)} }, &d));
    try testing.expectError(error.InvalidArgument, subscriptionConfig(.{ .topic_id = "t", .message_transforms = &.{js("f", "")} }, false, &d));
    try testing.expectError(error.InvalidArgument, topicUpdate(.{ .message_transforms = &.{.{ .kind = .other }} }, &d));
    seven[5].disabled = false;
    try testing.expectError(error.InvalidArgument, subscriptionUpdate(.{ .message_transforms = seven[1..7] }, false, &d));
    try testing.expectEqualStrings("6 message transforms are not disabled; the limit is 5", d.message());
}

test "an import topic's settings: each source's required fields, ARNs, a service account's shape, and a severity this client can name" {
    var d: Diagnostics = .{};
    const account = "importer@my-project.iam.gserviceaccount.com";
    const kinesis: types.AwsKinesis = .{
        .stream_arn = "arn:aws:kinesis:us-east-1:111111111111:stream/orders",
        .consumer_arn = "arn:aws:kinesis:us-east-1:111111111111:stream/orders/consumer/c:1",
        .aws_role_arn = "arn:aws:iam::111111111111:role/pubsub",
        .gcp_service_account = account,
    };
    const hubs: types.AzureEventHubs = .{
        .resource_group = "rg",
        .namespace = "ns",
        .event_hub = "eh",
        .client_id = "11111111-1111-1111-1111-111111111111",
        .tenant_id = "22222222-2222-2222-2222-222222222222",
        .subscription_id = "33333333-3333-3333-3333-333333333333",
        .gcp_service_account = account,
    };
    const msk: types.AwsMsk = .{
        .cluster_arn = "arn:aws:kafka:us-east-1:111111111111:cluster/orders/abc",
        .topic = "orders",
        .aws_role_arn = "arn:aws:iam::111111111111:role/pubsub",
        .gcp_service_account = account,
    };
    const confluent: types.ConfluentCloud = .{
        .bootstrap_server = "pkc-xxxx.us-east-1.aws.confluent.cloud:9092",
        .cluster_id = "lkc-xxxx",
        .topic = "orders",
        .identity_pool_id = "pool-xxxx",
        .gcp_service_account = account,
    };
    try ingestion(.{ .source = .{ .aws_kinesis = kinesis } }, &d);
    try ingestion(.{ .source = .{ .azure_event_hubs = hubs }, .log_severity = .debug }, &d);
    try ingestion(.{ .source = .{ .aws_msk = msk }, .log_severity = .info }, &d);
    try ingestion(.{ .source = .{ .confluent_cloud = confluent }, .log_severity = .@"error" }, &d);
    try ingestion(.{ .source = .{ .cloud_storage = .{ .bucket = "my-uploads" } }, .log_severity = .warning }, &d);
    // Production takes a bucket written with gs:// before it (measured
    // 2026-10-12), unlike a Cloud Storage subscription's.
    try ingestion(.{ .source = .{ .cloud_storage = .{
        .bucket = "gs://my-uploads",
        .format = .{ .text = .{ .delimiter = "\t" } },
        .minimum_object_create_time = .{ .nanoseconds = 0 },
        .match_glob = "logs/**.txt",
    } } }, &d);
    try ingestion(.{ .source = .{ .cloud_storage = .{ .bucket = "b", .format = .avro } } }, &d);
    try ingestion(.{ .source = .{ .cloud_storage = .{ .bucket = "b", .format = .pubsub_avro } } }, &d);

    // Every field of every source, left out and not UTF-8, by name.
    inline for (.{
        .{ kinesis, "aws_kinesis", .{
            .{ "stream_arn", "the Kinesis stream ARN" },
            .{ "consumer_arn", "the Kinesis consumer ARN" },
            .{ "aws_role_arn", "the AWS role ARN" },
        } },
        .{ hubs, "azure_event_hubs", .{
            .{ "resource_group", "the Event Hubs resource group" },
            .{ "namespace", "the Event Hubs namespace" },
            .{ "event_hub", "the event hub" },
            .{ "client_id", "the Event Hubs client id" },
            .{ "tenant_id", "the Event Hubs tenant id" },
            .{ "subscription_id", "the Event Hubs subscription id" },
        } },
        .{ msk, "aws_msk", .{
            .{ "cluster_arn", "the MSK cluster ARN" },
            .{ "topic", "the MSK topic" },
            .{ "aws_role_arn", "the AWS role ARN" },
        } },
        .{ confluent, "confluent_cloud", .{
            .{ "bootstrap_server", "the Confluent Cloud bootstrap server" },
            .{ "cluster_id", "the Confluent Cloud cluster id" },
            .{ "topic", "the Confluent Cloud topic" },
            .{ "identity_pool_id", "the Confluent Cloud identity pool id" },
        } },
    }) |case| {
        const good, const tag, const fields = case;
        inline for (fields) |field| {
            const name, const what = field;
            var missing = good;
            @field(missing, name) = "";
            try testing.expectError(error.InvalidArgument, ingestion(.{ .source = @unionInit(types.Ingestion.Source, tag, missing) }, &d));
            try testing.expectEqualStrings(what ++ " is empty", d.message());
            var garbled = good;
            @field(garbled, name) = "arn:\xff";
            try testing.expectError(error.InvalidArgument, ingestion(.{ .source = @unionInit(types.Ingestion.Source, tag, garbled) }, &d));
            try testing.expectEqualStrings(what ++ " is not valid UTF-8", d.message());
            // An ARN begins arn:, and nothing else is asked of it here.
            var plain = good;
            @field(plain, name) = "orders";
            const verdict = ingestion(.{ .source = @unionInit(types.Ingestion.Source, tag, plain) }, &d);
            if (comptime std.mem.endsWith(u8, name, "_arn")) {
                try testing.expectError(error.InvalidArgument, verdict);
                try testing.expectEqualStrings(what ++ " does not begin arn:", d.message());
            } else try verdict;
        }
        // Each source's service account has the shape of an address.
        var unaddressed = good;
        unaddressed.gcp_service_account = "importer";
        try testing.expectError(error.InvalidArgument, ingestion(.{ .source = @unionInit(types.Ingestion.Source, tag, unaddressed) }, &d));
        try testing.expectEqualStrings("the import topic's service account is not of the shape of an address", d.message());
    }
    var short = kinesis;
    short.stream_arn = "arn";
    try testing.expectError(error.InvalidArgument, ingestion(.{ .source = .{ .aws_kinesis = short } }, &d));
    short.stream_arn = "ARN:aws:kinesis";
    try testing.expectError(error.InvalidArgument, ingestion(.{ .source = .{ .aws_kinesis = short } }, &d));
    short.stream_arn = "arn:";
    try ingestion(.{ .source = .{ .aws_kinesis = short } }, &d);

    // A bucket: a name that is there, a delimiter of one byte, a time a
    // timestamp can hold, and a glob that is UTF-8.
    try testing.expectError(error.InvalidArgument, ingestion(.{ .source = .{ .cloud_storage = .{ .bucket = "" } } }, &d));
    try testing.expectEqualStrings("the import topic's bucket is empty", d.message());
    try testing.expectError(error.InvalidArgument, ingestion(.{ .source = .{ .cloud_storage = .{ .bucket = "b\xff" } } }, &d));
    try testing.expectEqualStrings("the import topic's bucket is not valid UTF-8", d.message());
    for ([_][]const u8{ "my-uploads/logs", "gs://my-uploads/logs", "gs://my-uploads/", "gs://", "/my-uploads", "gs:/my-uploads" }) |bucket| {
        try testing.expectError(error.InvalidArgument, ingestion(.{ .source = .{ .cloud_storage = .{ .bucket = bucket } } }, &d));
        try testing.expectEqualStrings("the import topic's bucket is not a bucket's name alone: it holds a slash, or nothing after gs://", d.message());
    }
    try ingestion(.{ .source = .{ .cloud_storage = .{ .bucket = "gs:my-uploads" } } }, &d);
    // Production's verdict on each of these, 2026-10-12, but for the two
    // of invalid UTF-8, which no request can carry.
    for ([_][]const u8{ "\n", "|", "\t", "\r", "\x00", "\x7f" }) |delimiter| {
        try ingestion(.{ .source = .{ .cloud_storage = .{ .bucket = "b", .format = .{ .text = .{ .delimiter = delimiter } } } } }, &d);
    }
    for ([_][]const u8{ "", "\r\n", "||", "\u{e9}", "\u{20ac}", "\x80", "\xc3" }) |delimiter| {
        try testing.expectError(error.InvalidArgument, ingestion(.{ .source = .{ .cloud_storage = .{ .bucket = "b", .format = .{ .text = .{ .delimiter = delimiter } } } } }, &d));
        try testing.expectEqualStrings("the text delimiter is not one character of one byte", d.message());
    }
    const last: std.Io.Timestamp = try timestamp.parse("9999-12-31T23:59:59.999999999Z");
    try ingestion(.{ .source = .{ .cloud_storage = .{ .bucket = "b", .minimum_object_create_time = last } } }, &d);
    try testing.expectError(error.InvalidArgument, ingestion(.{ .source = .{ .cloud_storage = .{ .bucket = "b", .minimum_object_create_time = .{ .nanoseconds = last.nanoseconds + 1 } } } }, &d));
    try testing.expectEqualStrings("the minimum object create time is outside 0001-01-01T00:00:00Z to 9999-12-31T23:59:59.999999999Z", d.message());
    try testing.expectError(error.InvalidArgument, ingestion(.{ .source = .{ .cloud_storage = .{ .bucket = "b", .match_glob = "\xff" } } }, &d));
    try testing.expectEqualStrings("the match glob is not valid UTF-8", d.message());

    // A severity that is only ever read, whatever the source.
    try testing.expectError(error.InvalidArgument, ingestion(.{ .source = .{ .aws_kinesis = kinesis }, .log_severity = .unknown }, &d));
    try testing.expectEqualStrings("the log severity is .unknown, which is only ever read", d.message());

    // Through a topic's settings and an update, where a clear is a change.
    try topicConfig(.{ .ingestion = .{ .source = .{ .aws_kinesis = kinesis } } }, &d);
    try topicUpdate(.{ .ingestion = .{ .set = .{ .source = .{ .aws_msk = msk } } } }, &d);
    try topicUpdate(.{ .ingestion = .clear }, &d);
    try testing.expectError(error.InvalidArgument, topicConfig(.{ .ingestion = .{ .source = .{ .cloud_storage = .{ .bucket = "" } } } }, &d));
    try testing.expectError(error.InvalidArgument, topicUpdate(.{ .ingestion = .{ .set = .{ .source = .{ .aws_kinesis = short }, .log_severity = .unknown } } }, &d));
    try testing.expectError(error.InvalidArgument, topicUpdate(.{}, &d));
    try testing.expectEqualStrings("the update changes nothing", d.message());
}

test "tags: fifty at most, no key twice, and keys and values of the forms production names" {
    var d: Diagnostics = .{};
    try tags(&.{}, &d);
    for ([_][]const u8{
        "my-project/env",
        "123456789012/cost-center",
        "tagKeys/281478409127147",
        "example.com:proj/env",
        "my-project/co\u{fb}t de revient",
    }) |key| {
        try testing.expect(isTagKey(key));
        const by_id = std.mem.startsWith(u8, key, "tagKeys/");
        try tags(&.{.{ .key = key, .value = if (by_id) "tagValues/281479442205542" else "prod" }}, &d);
    }
    // Production's refusal gives the format (2026-10-12): a namespace and
    // a key name, or tagKeys/ and an id. A key name holds no slash.
    for ([_][]const u8{ "", "env", "/env", "my-project/", "/", "my-project/env/eu", "my-project//env", "tagKeys/", "\xff/env" }) |key| {
        try testing.expect(!isTagKey(key));
        try testing.expectError(error.InvalidArgument, tags(&.{ .{ .key = "p/ok", .value = "v" }, .{ .key = key, .value = "prod" } }, &d));
        try testing.expectEqualStrings("tag 1 has a key that is neither {organization id or project}/{key name} nor tagKeys/{id}", d.message());
    }
    for ([_][]const u8{ "prod", "tagValues/281479442205542", "Production EU", "\u{e9}t\u{e9}", "tagValues" }) |value| {
        try testing.expect(isTagValue(value));
        const by_id = std.mem.startsWith(u8, value, "tagValues/");
        try tags(&.{.{ .key = if (by_id) "tagKeys/281478409127147" else "p/env", .value = value }}, &d);
    }
    // A key and its value go in the same form: both by name, or both by
    // id. Production refused one of each, either way round.
    for ([_]types.Tag{
        .{ .key = "p/env", .value = "tagValues/281479442205542" },
        .{ .key = "tagKeys/281478409127147", .value = "prod" },
    }) |mixed| {
        try testing.expectError(error.InvalidArgument, tags(&.{ .{ .key = "p/team", .value = "a" }, mixed }, &d));
        try testing.expectEqualStrings("tag 1 names its key and its value in different forms: both go by name, or tagKeys/{id} goes with tagValues/{id}", d.message());
    }
    for ([_][]const u8{ "", "tagValues/", "tagValues/1/2", "prod/eu", "tagKeys/1", "/prod", "TagValues/1", "prod\xff" }) |value| {
        try testing.expect(!isTagValue(value));
        try testing.expectError(error.InvalidArgument, tags(&.{.{ .key = "p/env", .value = value }}, &d));
        try testing.expectEqualStrings("tag 0 has a value that is neither a value's short name nor tagValues/{id}", d.message());
    }

    // Fifty, and not one more.
    var many: [max_tags + 1]types.Tag = undefined;
    var keys: [max_tags + 1][8]u8 = undefined;
    for (&many, &keys, 0..) |*tag, *key, i| {
        tag.* = .{ .key = try std.fmt.bufPrint(key, "p/k{d}", .{i}), .value = "v" };
    }
    try tags(many[0..max_tags], &d);
    try testing.expectError(error.InvalidArgument, tags(&many, &d));
    try testing.expectEqualStrings("51 tags; the limit is 50", d.message());

    // No key twice, whatever its values; one value under two keys is fine.
    try testing.expectError(error.InvalidArgument, tags(&.{ .{ .key = "p/env", .value = "prod" }, .{ .key = "p/team", .value = "a" }, .{ .key = "p/env", .value = "test" } }, &d));
    try testing.expectEqualStrings("tags 0 and 2 have the same key", d.message());
    try tags(&.{ .{ .key = "p/env", .value = "prod" }, .{ .key = "p/stage", .value = "prod" }, .{ .key = "p/Env", .value = "prod" } }, &d);

    // Through each of the three creates.
    const good = [_]types.Tag{.{ .key = "p/env", .value = "prod" }};
    const bad = [_]types.Tag{.{ .key = "env", .value = "prod" }};
    try topicConfig(.{ .tags = &good }, &d);
    try subscriptionConfig(.{ .topic_id = "t", .tags = &good }, false, &d);
    try snapshotConfig(.{ .subscription = "sub", .tags = &good }, &d);
    try testing.expectError(error.InvalidArgument, topicConfig(.{ .tags = &bad }, &d));
    try testing.expectError(error.InvalidArgument, subscriptionConfig(.{ .topic_id = "t", .tags = &bad }, true, &d));
    try testing.expectError(error.InvalidArgument, snapshotConfig(.{ .subscription = "sub", .tags = &bad }, &d));
}

fn tagFormProperty(_: void, input: []const u8) !void {
    var g: test_util.ByteGen = .init(input);
    const pieces = [_][]const u8{ "/", "tagKeys", "tagValues", "env", "p", "1", "\u{e9}", "\xff", " ", "tagValues/" };
    // Room for six of the longest piece.
    var buf: [6 * "tagValues/".len]u8 = undefined;
    var len: usize = 0;
    for (0..g.intRange(u8, 0, 6)) |_| {
        const piece = pieces[g.intRange(u8, 0, pieces.len - 1)];
        @memcpy(buf[len..][0..piece.len], piece);
        len += piece.len;
    }
    const text = buf[0..len];

    // The reference, from the format production's refusal gives: split at
    // every slash, and count the parts.
    var parts: usize = 0;
    var an_empty_part = false;
    var it = std.mem.splitScalar(u8, text, '/');
    while (it.next()) |part| {
        parts += 1;
        if (part.len == 0) an_empty_part = true;
    }
    const utf8 = std.unicode.utf8ValidateSlice(text);
    const key = utf8 and parts == 2 and !an_empty_part;
    const value = utf8 and text.len > 0 and (parts == 1 or (key and std.mem.startsWith(u8, text, "tagValues/")));
    try testing.expectEqual(key, isTagKey(text));
    try testing.expectEqual(value, isTagValue(text));
    // The list's check is the two, tag by tag, and that the two are of
    // one form: by name, or by id.
    const key_by_id = std.mem.startsWith(u8, text, "tagKeys/");
    const value_by_id = std.mem.startsWith(u8, text, "tagValues/");
    try testing.expectEqual(key and !key_by_id, if (tags(&.{.{ .key = text, .value = "v" }}, null)) |_| true else |_| false);
    try testing.expectEqual(key and key_by_id, if (tags(&.{.{ .key = text, .value = "tagValues/1" }}, null)) |_| true else |_| false);
    try testing.expectEqual(value and !value_by_id, if (tags(&.{.{ .key = "p/k", .value = text }}, null)) |_| true else |_| false);
    try testing.expectEqual(value and value_by_id, if (tags(&.{.{ .key = "tagKeys/1", .value = text }}, null)) |_| true else |_| false);
}

test "fuzz tags: the check of a key and of a value agrees with a reference that splits at every slash" {
    try test_util.fuzzBytes({}, tagFormProperty, .{ .corpus = &.{
        "",
        "\x03\x04\x00\x03",
        "\x03\x01\x00\x05",
        "\x02\x09\x05",
        "\x05\x04\x00\x03\x00\x03",
        "\x02\x07\x00",
        "\x01\x00",
        "\x06\x02\x00\x05\x00\x05\x06",
    } });
}
