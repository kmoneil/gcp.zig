//! JSON out: a key to create, an update, a version's state, a primary.
//! JSON in: key rings, keys, versions, locations, retired keys and their
//! pages, and operations. A body is parsed into a `std.json.Value` in a
//! scratch arena and read from there, every string copied into the
//! result's arena. `null` counts as absent (the proto3 JSON rule), unknown
//! fields are ignored, enums read as names with `.unknown` for a name this
//! library does not know, and int64s arrive as strings or numbers.

const std = @import("std");
const Allocator = std.mem.Allocator;
const Value = std.json.Value;
const Stringify = std.json.Stringify;
const core = @import("core");
const names = @import("names.zig");
const types = @import("types.zig");

pub const DecodeError = error{ InvalidResponse, OutOfMemory };

// Requests

/// A `cryptoKeys.create` body. The algorithm is always sent, the implied
/// `GOOGLE_SYMMETRIC_ENCRYPTION` too, so nothing is left to a default the
/// server might change.
pub fn encodeKey(arena: Allocator, config: types.KeyConfig) Allocator.Error![]u8 {
    return render(arena, KeyBody{ .config = config });
}

const KeyBody = struct {
    config: types.KeyConfig,

    fn write(self: KeyBody, jw: *Stringify) Stringify.Error!void {
        const c = self.config;
        try jw.beginObject();
        try jw.objectField("purpose");
        try jw.write(c.purpose.wire());
        try jw.objectField("versionTemplate");
        try jw.beginObject();
        try jw.objectField("protectionLevel");
        try jw.write(c.protection_level.wire());
        try jw.objectField("algorithm");
        try jw.write((c.algorithm orelse types.Algorithm.google_symmetric_encryption).wire());
        try jw.endObject();
        if (c.destroy_delay_s) |d| {
            try jw.objectField("destroyScheduledDuration");
            try writeSeconds(jw, d);
        }
        if (c.rotation) |r| try writeRotation(jw, r);
        if (c.labels.len > 0) {
            try jw.objectField("labels");
            try writeLabels(jw, c.labels);
        }
        try jw.endObject();
    }
};

/// A `cryptoKeys.patch`: the body, and the `updateMask` naming what it
/// changes, in the camelCase the REST API documents.
pub const KeyPatch = struct { body: []const u8, mask: []const u8 };

pub fn encodeKeyUpdate(arena: Allocator, update: types.KeyUpdate) Allocator.Error!KeyPatch {
    var mask: std.ArrayList(u8) = .empty;
    if (update.labels != .keep) try appendMask(arena, &mask, "labels");
    if (update.rotation != .keep) try appendMask(arena, &mask, "rotationPeriod,nextRotationTime");
    if (update.algorithm != null) try appendMask(arena, &mask, "versionTemplate.algorithm");
    return .{ .body = try render(arena, UpdateBody{ .update = update }), .mask = mask.items };
}

fn appendMask(arena: Allocator, mask: *std.ArrayList(u8), path: []const u8) Allocator.Error!void {
    if (mask.items.len > 0) try mask.append(arena, ',');
    try mask.appendSlice(arena, path);
}

const UpdateBody = struct {
    update: types.KeyUpdate,

    fn write(self: UpdateBody, jw: *Stringify) Stringify.Error!void {
        const u = self.update;
        try jw.beginObject();
        switch (u.labels) {
            .set => |labels| if (labels.len > 0) {
                try jw.objectField("labels");
                try writeLabels(jw, labels);
            },
            // Named in the mask and absent here: none left.
            .clear, .keep => {},
        }
        switch (u.rotation) {
            .set => |r| try writeRotation(jw, r),
            .clear, .keep => {},
        }
        if (u.algorithm) |a| {
            try jw.objectField("versionTemplate");
            try jw.beginObject();
            try jw.objectField("algorithm");
            try jw.write(a.wire());
            try jw.endObject();
        }
        try jw.endObject();
    }
};

/// `{"state": "ENABLED"}` or `DISABLED`, a version patch's body.
pub fn encodeState(arena: Allocator, state: types.State) Allocator.Error![]u8 {
    return Stringify.valueAlloc(arena, .{ .state = state.wire() }, .{});
}

/// `{"cryptoKeyVersionId": "2"}`, as `updatePrimaryVersion` takes it.
pub fn encodePrimary(arena: Allocator, version: u64) Allocator.Error![]u8 {
    return std.fmt.allocPrint(arena, "{{\"cryptoKeyVersionId\":\"{d}\"}}", .{version});
}

fn writeRotation(jw: *Stringify, r: types.Rotation) Stringify.Error!void {
    try jw.objectField("rotationPeriod");
    try writeSeconds(jw, r.period_s);
    try jw.objectField("nextRotationTime");
    try writeTimestamp(jw, r.next);
}

fn writeLabels(jw: *Stringify, labels: []const types.Label) Stringify.Error!void {
    try jw.beginObject();
    for (labels) |l| {
        try jw.objectField(l.key);
        try jw.write(l.value);
    }
    try jw.endObject();
}

/// Whole seconds as a Duration: `"86400s"`, never gcloud's `"1d"`.
fn writeSeconds(jw: *Stringify, whole: u64) Stringify.Error!void {
    var buf: [24]u8 = undefined;
    try jw.write(std.fmt.bufPrint(&buf, "{d}s", .{whole}) catch unreachable);
}

/// RFC 3339 in UTC. The timestamp has been checked to be in range.
fn writeTimestamp(jw: *Stringify, stamp: std.Io.Timestamp) Stringify.Error!void {
    var buf: [core.timestamp.max_len]u8 = undefined;
    try jw.write(core.timestamp.format(&buf, stamp));
}

fn render(arena: Allocator, body: anytype) Allocator.Error![]u8 {
    var out: std.Io.Writer.Allocating = .init(arena);
    var jw: Stringify = .{ .writer = &out.writer };
    body.write(&jw) catch return error.OutOfMemory;
    return out.toOwnedSlice();
}

// Responses

pub fn decodeKeyRing(out: Allocator, scratch: Allocator, body: []const u8) DecodeError!types.KeyRingInfo {
    return keyRingOf(out, try parse(scratch, body));
}

/// A page of `keyRings.list`: `{}` is an empty last page.
pub fn decodeKeyRingPage(out: Allocator, scratch: Allocator, body: []const u8) DecodeError!types.KeyRingPage {
    const obj = try object(try parse(scratch, body));
    return .{ .key_rings = try listOf(types.KeyRingInfo, out, obj, "keyRings", keyRingOf), .next_page_token = try token(out, obj) };
}

pub fn decodeKey(out: Allocator, scratch: Allocator, body: []const u8) DecodeError!types.KeyInfo {
    return keyOf(out, try parse(scratch, body));
}

pub fn decodeKeyPage(out: Allocator, scratch: Allocator, body: []const u8) DecodeError!types.KeyPage {
    const obj = try object(try parse(scratch, body));
    return .{ .keys = try listOf(types.KeyInfo, out, obj, "cryptoKeys", keyOf), .next_page_token = try token(out, obj) };
}

pub fn decodeVersion(out: Allocator, scratch: Allocator, body: []const u8) DecodeError!types.VersionInfo {
    return versionOf(out, try parse(scratch, body));
}

pub fn decodeVersionPage(out: Allocator, scratch: Allocator, body: []const u8) DecodeError!types.VersionPage {
    const obj = try object(try parse(scratch, body));
    return .{ .versions = try listOf(types.VersionInfo, out, obj, "cryptoKeyVersions", versionOf), .next_page_token = try token(out, obj) };
}

pub fn decodeLocationPage(out: Allocator, scratch: Allocator, body: []const u8) DecodeError!types.LocationPage {
    const obj = try object(try parse(scratch, body));
    return .{ .locations = try listOf(types.LocationInfo, out, obj, "locations", locationOf), .next_page_token = try token(out, obj) };
}

pub fn decodeRetiredKeyPage(out: Allocator, scratch: Allocator, body: []const u8) DecodeError!types.RetiredKeyPage {
    const obj = try object(try parse(scratch, body));
    return .{ .retired_keys = try listOf(types.RetiredKey, out, obj, "retiredResources", retiredOf), .next_page_token = try token(out, obj) };
}

/// A long-running operation, as a delete answers and as polling it does.
pub const Operation = struct {
    name: []const u8,
    done: bool,
    /// A `google.rpc.Status`, when it ended with one.
    failure: ?Failure = null,

    pub const Failure = struct { code: i64, message: []const u8 };
};

pub fn decodeOperation(out: Allocator, scratch: Allocator, body: []const u8) DecodeError!Operation {
    const obj = try object(try parse(scratch, body));
    var op: Operation = .{
        .name = try string(out, obj, "name") orelse return error.InvalidResponse,
        .done = try boolean(obj, "done"),
    };
    if (try field(obj, "error", .object)) |e| {
        op.failure = .{
            .code = try integer(i64, e, "code") orelse 2,
            .message = try string(out, e, "message") orelse "",
        };
    }
    return op;
}

fn keyRingOf(out: Allocator, v: Value) DecodeError!types.KeyRingInfo {
    const obj = try object(v);
    return .{
        .name = try string(out, obj, "name") orelse return error.InvalidResponse,
        .create_time = try time(obj, "createTime"),
    };
}

fn keyOf(out: Allocator, v: Value) DecodeError!types.KeyInfo {
    const obj = try object(v);
    var key: types.KeyInfo = .{
        .name = try string(out, obj, "name") orelse return error.InvalidResponse,
        .purpose = if (try field(obj, "purpose", .string)) |p| types.Purpose.fromWire(p) else .unknown,
        .create_time = try time(obj, "createTime"),
        .next_rotation = try time(obj, "nextRotationTime"),
        .rotation_period_s = try seconds(obj, "rotationPeriod"),
        .labels = try labelsOf(out, obj),
        .import_only = try boolean(obj, "importOnly"),
        .destroy_delay_s = try seconds(obj, "destroyScheduledDuration"),
        .backend = try string(out, obj, "cryptoKeyBackend") orelse "",
    };
    if (try field(obj, "primary", .object)) |_| key.primary = try versionOf(out, obj.get("primary").?);
    if (try field(obj, "versionTemplate", .object)) |t| {
        if (try field(t, "protectionLevel", .string)) |p| key.protection_level = types.ProtectionLevel.fromWire(p);
        if (try field(t, "algorithm", .string)) |a| key.algorithm = types.Algorithm.fromWire(a);
    }
    return key;
}

fn versionOf(out: Allocator, v: Value) DecodeError!types.VersionInfo {
    const obj = try object(v);
    const name = try string(out, obj, "name") orelse return error.InvalidResponse;
    return .{
        .name = name,
        .id = names.versionId(name) orelse return error.InvalidResponse,
        .state = if (try field(obj, "state", .string)) |s| types.State.fromWire(s) else .unknown,
        .protection_level = if (try field(obj, "protectionLevel", .string)) |p| types.ProtectionLevel.fromWire(p) else .unknown,
        .algorithm = if (try field(obj, "algorithm", .string)) |a| types.Algorithm.fromWire(a) else .unknown,
        .create_time = try time(obj, "createTime"),
        .generate_time = try time(obj, "generateTime"),
        .destroy_time = try time(obj, "destroyTime"),
        .destroy_event_time = try time(obj, "destroyEventTime"),
        .generation_failure_reason = try string(out, obj, "generationFailureReason") orelse "",
        .import_failure_reason = try string(out, obj, "importFailureReason") orelse "",
    };
}

fn locationOf(out: Allocator, v: Value) DecodeError!types.LocationInfo {
    const obj = try object(v);
    var loc: types.LocationInfo = .{
        .name = try string(out, obj, "name") orelse return error.InvalidResponse,
        .id = try string(out, obj, "locationId") orelse return error.InvalidResponse,
        .display_name = try string(out, obj, "displayName") orelse "",
    };
    if (try field(obj, "metadata", .object)) |m| {
        loc.hsm_available = try boolean(m, "hsmAvailable");
        loc.ekm_available = try boolean(m, "ekmAvailable");
    }
    return loc;
}

fn retiredOf(out: Allocator, v: Value) DecodeError!types.RetiredKey {
    const obj = try object(v);
    return .{
        .name = try string(out, obj, "name") orelse return error.InvalidResponse,
        .original_name = try string(out, obj, "originalResource") orelse return error.InvalidResponse,
        .resource_type = try string(out, obj, "resourceType") orelse "",
        .delete_time = try time(obj, "deleteTime"),
    };
}

fn listOf(comptime T: type, out: Allocator, obj: std.json.ObjectMap, list_name: []const u8, comptime each: fn (Allocator, Value) DecodeError!T) DecodeError![]const T {
    const list = try field(obj, list_name, .array) orelse return &.{};
    const items = try out.alloc(T, list.items.len);
    for (list.items, items) |v, *item| item.* = try each(out, v);
    return items;
}

fn labelsOf(out: Allocator, obj: std.json.ObjectMap) DecodeError![]const types.Label {
    const map = try field(obj, "labels", .object) orelse return &.{};
    const labels = try out.alloc(types.Label, map.count());
    for (map.keys(), map.values(), labels) |k, v, *l| {
        if (v != .string) return error.InvalidResponse;
        l.* = .{ .key = try out.dupe(u8, k), .value = try out.dupe(u8, v.string) };
    }
    return labels;
}

fn parse(scratch: Allocator, body: []const u8) DecodeError!Value {
    return std.json.parseFromSliceLeaky(Value, scratch, body, .{ .parse_numbers = false }) catch |err| switch (err) {
        error.OutOfMemory => error.OutOfMemory,
        else => error.InvalidResponse,
    };
}

fn object(v: Value) DecodeError!std.json.ObjectMap {
    return switch (v) {
        .object => |o| o,
        else => error.InvalidResponse,
    };
}

/// The field's value when it holds `tag`, null when absent or `null`, and
/// `InvalidResponse` when it holds anything else.
fn field(obj: std.json.ObjectMap, name: []const u8, comptime tag: std.meta.Tag(Value)) DecodeError!?@FieldType(Value, @tagName(tag)) {
    const v = obj.get(name) orelse return null;
    if (v == .null) return null;
    if (v != tag) return error.InvalidResponse;
    return @field(v, @tagName(tag));
}

fn string(out: Allocator, obj: std.json.ObjectMap, name: []const u8) DecodeError!?[]const u8 {
    const s = try field(obj, name, .string) orelse return null;
    return try out.dupe(u8, s);
}

/// A bool: absent means false, as proto3 JSON leaves false out.
fn boolean(obj: std.json.ObjectMap, name: []const u8) DecodeError!bool {
    return try field(obj, name, .bool) orelse false;
}

/// `nextPageToken`: absent or "" ends the list.
fn token(out: Allocator, obj: std.json.ObjectMap) DecodeError!?[]const u8 {
    const t = try field(obj, "nextPageToken", .string) orelse return null;
    if (t.len == 0) return null;
    return try out.dupe(u8, t);
}

/// An integer that may arrive as a string, as int64s do, or as a number,
/// which the parser keeps as its text.
fn integer(comptime T: type, obj: std.json.ObjectMap, name: []const u8) DecodeError!?T {
    const v = obj.get(name) orelse return null;
    const text = switch (v) {
        .null => return null,
        .number_string, .string => |s| s,
        else => return error.InvalidResponse,
    };
    return std.fmt.parseInt(T, text, 10) catch error.InvalidResponse;
}

fn time(obj: std.json.ObjectMap, name: []const u8) DecodeError!?std.Io.Timestamp {
    const text = try field(obj, name, .string) orelse return null;
    return core.timestamp.parse(text) catch error.InvalidResponse;
}

/// A Duration in whole seconds, its fraction dropped; a negative one is
/// refused.
fn seconds(obj: std.json.ObjectMap, name: []const u8) DecodeError!?u64 {
    const text = try field(obj, name, .string) orelse return null;
    const d = core.duration.parse(text) catch return error.InvalidResponse;
    if (d.nanoseconds < 0) return error.InvalidResponse;
    return @intCast(@divTrunc(d.nanoseconds, std.time.ns_per_s));
}

const testing = std.testing;
const test_util = @import("test_util.zig");

fn at(seconds_since_epoch: i64) std.Io.Timestamp {
    return .{ .nanoseconds = @as(i96, seconds_since_epoch) * std.time.ns_per_s };
}

test "golden: a symmetric key with every setting, and a signing key with none" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try testing.expectEqualStrings(
        \\{"purpose":"ENCRYPT_DECRYPT","versionTemplate":{"protectionLevel":"SOFTWARE","algorithm":"GOOGLE_SYMMETRIC_ENCRYPTION"},"destroyScheduledDuration":"86400s","rotationPeriod":"7776000s","nextRotationTime":"2026-10-19T00:00:00Z","labels":{"team":"alpha","env":""}}
    , try encodeKey(a, .{
        .purpose = .encrypt_decrypt,
        .destroy_delay_s = 86_400,
        .rotation = .{ .period_s = 90 * 86_400, .next = at(1_792_368_000) },
        .labels = &.{ .{ .key = "team", .value = "alpha" }, .{ .key = "env", .value = "" } },
    }));
    try testing.expectEqualStrings(
        \\{"purpose":"ASYMMETRIC_SIGN","versionTemplate":{"protectionLevel":"HSM","algorithm":"EC_SIGN_P256_SHA256"}}
    , try encodeKey(a, .{ .purpose = .asymmetric_sign, .algorithm = .ec_sign_p256_sha256, .protection_level = .hsm }));
}

test "golden: updates name in the mask exactly what they change" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const all = try encodeKeyUpdate(a, .{
        .labels = .{ .set = &.{.{ .key = "team", .value = "beta" }} },
        .rotation = .{ .set = .{ .period_s = 86_400, .next = at(1_792_368_000) } },
        .algorithm = .google_symmetric_encryption,
    });
    try testing.expectEqualStrings("labels,rotationPeriod,nextRotationTime,versionTemplate.algorithm", all.mask);
    try testing.expectEqualStrings(
        \\{"labels":{"team":"beta"},"rotationPeriod":"86400s","nextRotationTime":"2026-10-19T00:00:00Z","versionTemplate":{"algorithm":"GOOGLE_SYMMETRIC_ENCRYPTION"}}
    , all.body);
    const cleared = try encodeKeyUpdate(a, .{ .labels = .clear, .rotation = .clear });
    try testing.expectEqualStrings("labels,rotationPeriod,nextRotationTime", cleared.mask);
    try testing.expectEqualStrings("{}", cleared.body);
    // An empty list is the same as clearing.
    const empty = try encodeKeyUpdate(a, .{ .labels = .{ .set = &.{} } });
    try testing.expectEqualStrings("labels", empty.mask);
    try testing.expectEqualStrings("{}", empty.body);
    try testing.expectEqualStrings("{\"state\":\"DISABLED\"}", try encodeState(a, .disabled));
    try testing.expectEqualStrings("{\"cryptoKeyVersionId\":\"12\"}", try encodePrimary(a, 12));
}

test "decode: a key with its primary, template, rotation and labels" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const key = try decodeKey(a, a,
        \\{"name":"projects/p/locations/us-central1/keyRings/r/cryptoKeys/k",
        \\"primary":{"name":"projects/p/locations/us-central1/keyRings/r/cryptoKeys/k/cryptoKeyVersions/2","state":"ENABLED","createTime":"2026-10-18T10:00:00.123456789Z","protectionLevel":"SOFTWARE","algorithm":"GOOGLE_SYMMETRIC_ENCRYPTION","generateTime":"2026-10-18T10:00:00.123456789Z"},
        \\"purpose":"ENCRYPT_DECRYPT","createTime":"2026-10-18T09:00:00Z","nextRotationTime":"2026-10-19T00:00:00Z","rotationPeriod":"7776000s",
        \\"versionTemplate":{"protectionLevel":"SOFTWARE","algorithm":"GOOGLE_SYMMETRIC_ENCRYPTION"},"labels":{"team":"alpha"},
        \\"destroyScheduledDuration":"86400s","someNewField":{"x":[1]}}
    );
    try testing.expectEqualStrings("projects/p/locations/us-central1/keyRings/r/cryptoKeys/k", key.name);
    try testing.expectEqual(types.Purpose.encrypt_decrypt, key.purpose);
    try testing.expectEqual(2, key.primary.?.id);
    try testing.expectEqual(types.State.enabled, key.primary.?.state);
    try testing.expectEqual(at(1_792_368_000), key.next_rotation.?);
    try testing.expectEqual(7_776_000, key.rotation_period_s.?);
    try testing.expectEqual(types.ProtectionLevel.software, key.protection_level);
    try testing.expectEqual(types.Algorithm.google_symmetric_encryption, key.algorithm);
    try testing.expectEqualStrings("alpha", key.labels[0].value);
    try testing.expectEqual(86_400, key.destroy_delay_s.?);
    try testing.expect(!key.import_only);
    try testing.expectEqualStrings("", key.backend);
}

test "decode: a signing key has no primary, and names the server adds later read as unknown" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const key = try decodeKey(a, a,
        \\{"name":"projects/p/locations/global/keyRings/r/cryptoKeys/s","purpose":"ASYMMETRIC_SIGN",
        \\"versionTemplate":{"protectionLevel":"QUANTUM_VAULT","algorithm":"PQ_SIGN_SOMETHING_NEW"},"importOnly":true}
    );
    try testing.expectEqual(null, key.primary);
    try testing.expectEqual(types.ProtectionLevel.unknown, key.protection_level);
    try testing.expectEqual(types.Algorithm.unknown, key.algorithm);
    try testing.expect(key.import_only);
    try testing.expectEqual(null, key.destroy_delay_s);
}

test "decode: versions in each state, with the times only some states carry" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const page = try decodeVersionPage(a, a,
        \\{"cryptoKeyVersions":[
        \\{"name":"projects/p/locations/l/keyRings/r/cryptoKeys/k/cryptoKeyVersions/3","state":"DESTROY_SCHEDULED","destroyTime":"2026-10-19T00:00:00Z","algorithm":"EC_SIGN_P256_SHA256","protectionLevel":"SOFTWARE"},
        \\{"name":"projects/p/locations/l/keyRings/r/cryptoKeys/k/cryptoKeyVersions/2","state":"DESTROYED","destroyEventTime":"2026-10-19T00:00:00Z"},
        \\{"name":"projects/p/locations/l/keyRings/r/cryptoKeys/k/cryptoKeyVersions/1","state":"GENERATION_FAILED","generationFailureReason":"no"}],
        \\"nextPageToken":"CgE"}
    );
    try testing.expectEqual(3, page.versions.len);
    try testing.expectEqual(3, page.versions[0].id);
    try testing.expectEqual(types.State.destroy_scheduled, page.versions[0].state);
    try testing.expectEqual(at(1_792_368_000), page.versions[0].destroy_time.?);
    try testing.expectEqual(types.State.destroyed, page.versions[1].state);
    try testing.expectEqual(types.Algorithm.unknown, page.versions[1].algorithm);
    try testing.expectEqual(at(1_792_368_000), page.versions[1].destroy_event_time.?);
    try testing.expectEqualStrings("no", page.versions[2].generation_failure_reason);
    try testing.expectEqualStrings("CgE", page.next_page_token.?);
    // `{}` is an empty last page; "" ends the list as absence does.
    const empty = try decodeVersionPage(a, a, "{\"nextPageToken\":\"\"}");
    try testing.expectEqual(0, empty.versions.len);
    try testing.expectEqual(null, empty.next_page_token);
}

test "decode: key rings, locations, retired keys and operations" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const rings = try decodeKeyRingPage(a, a, "{\"keyRings\":[{\"name\":\"projects/p/locations/l/keyRings/r\",\"createTime\":\"2026-10-19T00:00:00Z\"}],\"totalSize\":1}");
    try testing.expectEqualStrings("projects/p/locations/l/keyRings/r", rings.key_rings[0].name);
    try testing.expectEqual(at(1_792_368_000), rings.key_rings[0].create_time.?);
    const locs = try decodeLocationPage(a, a,
        \\{"locations":[{"name":"projects/p/locations/us-central1","locationId":"us-central1","displayName":"Iowa",
        \\"metadata":{"@type":"type.googleapis.com/google.cloud.kms.v1.LocationMetadata","hsmAvailable":true,"ekmAvailable":true}},
        \\{"name":"projects/p/locations/global","locationId":"global","metadata":{"@type":"type.googleapis.com/google.cloud.kms.v1.LocationMetadata"}}]}
    );
    try testing.expectEqualStrings("Iowa", locs.locations[0].display_name);
    try testing.expect(locs.locations[0].hsm_available and locs.locations[0].ekm_available);
    try testing.expect(!locs.locations[1].hsm_available);
    const retired = try decodeRetiredKeyPage(a, a,
        \\{"retiredResources":[{"name":"projects/p/locations/l/retiredResources/abc","originalResource":"projects/p/locations/l/keyRings/r/cryptoKeys/k","resourceType":"cloudkms.googleapis.com/CryptoKey","deleteTime":"2026-10-19T00:00:00Z"}],"totalSize":"1"}
    );
    try testing.expectEqualStrings("projects/p/locations/l/keyRings/r/cryptoKeys/k", retired.retired_keys[0].original_name);
    const pending = try decodeOperation(a, a, "{\"name\":\"projects/p/locations/l/operations/o1\",\"metadata\":{\"@type\":\"x\"}}");
    try testing.expect(!pending.done);
    try testing.expectEqual(null, pending.failure);
    const failed = try decodeOperation(a, a, "{\"name\":\"projects/p/locations/l/operations/o1\",\"done\":true,\"error\":{\"code\":9,\"message\":\"not empty\"}}");
    try testing.expect(failed.done);
    try testing.expectEqual(9, failed.failure.?.code);
    try testing.expectEqualStrings("not empty", failed.failure.?.message);
}

test "decode: what is not the API's shape is InvalidResponse" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    for ([_][]const u8{
        "",
        "[]",
        "{\"name\":7}",
        "{}",
        "{\"name\":\"projects/p/locations/l/keyRings/r/cryptoKeys/k/cryptoKeyVersions/x\"}",
        "{\"name\":\"projects/p/locations/l/keyRings/r/cryptoKeys/k/cryptoKeyVersions/1\",\"state\":1}",
        "{\"name\":\"projects/p/locations/l/keyRings/r/cryptoKeys/k/cryptoKeyVersions/1\",\"createTime\":\"yesterday\"}",
    }) |body| try testing.expectError(error.InvalidResponse, decodeVersion(a, a, body));
    try testing.expectError(error.InvalidResponse, decodeKey(a, a, "{\"name\":\"k\",\"destroyScheduledDuration\":\"-1s\"}"));
    try testing.expectError(error.InvalidResponse, decodeKey(a, a, "{\"name\":\"k\",\"labels\":{\"a\":1}}"));
    try testing.expectError(error.InvalidResponse, decodeKey(a, a, "{\"name\":\"k\",\"primary\":{\"name\":\"no version\"}}"));
    try testing.expectError(error.InvalidResponse, decodeOperation(a, a, "{\"done\":true}"));
    try testing.expectError(error.InvalidResponse, decodeOperation(a, a, "{\"name\":\"o\",\"error\":{\"code\":\"x\"}}"));
}

fn decodersProperty(_: void, input: []const u8) !void {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    // Total: every decoder answers a value or InvalidResponse, never a crash.
    inline for (.{ decodeKeyRing, decodeKeyRingPage, decodeKey, decodeKeyPage, decodeVersion, decodeVersionPage, decodeLocationPage, decodeRetiredKeyPage, decodeOperation }) |decode| {
        if (decode(a, a, input)) |_| {} else |err| try testing.expectEqual(error.InvalidResponse, err);
    }
}

test "fuzz decoders: arbitrary bodies decode or are InvalidResponse" {
    try test_util.fuzzBytes({}, decodersProperty, .{ .corpus = &.{
        "{\"name\":\"projects/p/locations/l/keyRings/r/cryptoKeys/k/cryptoKeyVersions/1\",\"state\":\"ENABLED\"}",
        "{\"cryptoKeys\":[{\"name\":\"k\",\"primary\":{\"name\":\"k/cryptoKeyVersions/1\"},\"labels\":{\"a\":\"b\"},\"rotationPeriod\":\"1.5s\"}]}",
        "{\"name\":\"o\",\"done\":true,\"error\":{\"code\":\"9\"}}",
        "{\"locations\":[{\"name\":\"n\",\"locationId\":\"l\",\"metadata\":{\"hsmAvailable\":\"yes\"}}]}",
    } });
}

fn decodeAllocations(gpa: Allocator) !void {
    var out: std.heap.ArenaAllocator = .init(gpa);
    defer out.deinit();
    var scratch: std.heap.ArenaAllocator = .init(gpa);
    defer scratch.deinit();
    const key = try decodeKey(out.allocator(), scratch.allocator(),
        \\{"name":"projects/p/locations/l/keyRings/r/cryptoKeys/k","primary":{"name":"projects/p/locations/l/keyRings/r/cryptoKeys/k/cryptoKeyVersions/1","state":"ENABLED","generationFailureReason":"x"},
        \\"labels":{"a":"b","c":"d"},"cryptoKeyBackend":"b","purpose":"ENCRYPT_DECRYPT"}
    );
    try testing.expectEqual(2, key.labels.len);
}

test "decode: every allocation failure is OutOfMemory without leaks" {
    try testing.checkAllAllocationFailures(test_util.no_grow_allocator, decodeAllocations, .{});
}
