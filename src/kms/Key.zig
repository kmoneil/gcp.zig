//! A key: what it is for, how new versions are made, and its versions.
//! A handle makes no call until asked.

const Key = @This();

const std = @import("std");
const core = @import("core");
const Client = @import("Client.zig");
const codec = @import("codec.zig");
const KeyVersion = @import("KeyVersion.zig");
const names = @import("names.zig");
const operations = @import("operations.zig");
const rpc = @import("rpc.zig");
const types = @import("types.zig");
const validate = @import("validate.zig");
const Error = @import("errors.zig").Error;

client: *Client,
/// The project, location, key ring and key; the version unset.
target: names.Target,

/// The key's id.
pub fn id(self: Key) []const u8 {
    return self.target.key.?;
}

/// A handle on version `version_id` of this key. Makes no call.
pub fn version(self: Key, version_id: u64) KeyVersion {
    var target = self.target;
    target.version = version_id;
    return .{ .client = self.client, .target = target };
}

/// Creates the key as `config` says, with version 1 unless
/// `config.first_version` is false. A symmetric key's version is enabled
/// at once; an asymmetric one starts `pending_generation`, which
/// `KeyVersion.waitUntilEnabled` waits out. An id in use, or one a deleted
/// key held, which is retired for good, is `error.AlreadyExists`. A create
/// whose answer was lost is read back rather than sent again.
pub fn create(self: Key, config: types.KeyConfig) Error!types.Owned(types.KeyInfo) {
    const c = self.client;
    rpc.begin(c);
    try c.checkTarget(self.target);
    if (validate.keyConfigProblem(config)) |p| {
        if (c.diagnostics) |d| d.print("invalid key: {s}", .{p});
        return error.InvalidOptions;
    }
    var scratch: std.heap.ArenaAllocator = .init(c.gpa);
    defer scratch.deinit();
    const a = scratch.allocator();
    var w: std.Io.Writer.Allocating = .init(a);
    self.target.parent().writePath(&w.writer, "/cryptoKeys") catch return error.OutOfMemory;
    var params: core.query.Params = .init(&w.writer);
    params.add("cryptoKeyId", self.id()) catch return error.OutOfMemory;
    if (!config.first_version) params.add("skipInitialVersionCreation", "true") catch return error.OutOfMemory;
    const get_path = try self.target.path(a, "");

    var result: types.Owned(types.KeyInfo) = try .init(c.gpa);
    errdefer result.deinit();
    const body = try rpc.createOnce(c, result.arena, .{ .method = .POST, .path = w.written(), .body = try codec.encodeKey(a, config) }, get_path, "a key");
    result.value = codec.decodeKey(result.arena.allocator(), a, body) catch |err|
        return rpc.decodeFailed(c, err, "key");
    return result;
}

/// The key, with its primary version for an `encrypt_decrypt` key.
pub fn get(self: Key) Error!types.Owned(types.KeyInfo) {
    return self.keyCall(.GET, "", null);
}

/// Changes the key's labels, its automatic rotation or the algorithm of
/// its future versions, and answers the key as it then is. Purpose,
/// protection level and destroy delay are fixed at creation.
pub fn update(self: Key, changes: types.KeyUpdate) Error!types.Owned(types.KeyInfo) {
    const c = self.client;
    rpc.begin(c);
    try c.checkTarget(self.target);
    if (validate.keyUpdateProblem(changes)) |p| {
        if (c.diagnostics) |d| d.print("invalid update: {s}", .{p});
        return error.InvalidOptions;
    }
    var scratch: std.heap.ArenaAllocator = .init(c.gpa);
    defer scratch.deinit();
    const a = scratch.allocator();
    const patch = try codec.encodeKeyUpdate(a, changes);
    var w: std.Io.Writer.Allocating = .init(a);
    self.target.writePath(&w.writer, "") catch return error.OutOfMemory;
    var params: core.query.Params = .init(&w.writer);
    params.add("updateMask", patch.mask) catch return error.OutOfMemory;
    return self.keyRequest(a, .PATCH, w.written(), patch.body);
}

/// Makes `version_id` the version `encrypt` uses, for an `encrypt_decrypt`
/// key, and answers the key. Encrypt may go on using the old primary for
/// up to a minute, hours in exceptional cases: `Ciphertext.version` says
/// which version each encrypt used.
pub fn setPrimary(self: Key, version_id: u64) Error!types.Owned(types.KeyInfo) {
    const c = self.client;
    rpc.begin(c);
    try c.checkTarget(self.version(version_id).target);
    var scratch: std.heap.ArenaAllocator = .init(c.gpa);
    defer scratch.deinit();
    return self.keyCall(.POST, ":updatePrimaryVersion", try codec.encodePrimary(scratch.allocator(), version_id));
}

/// Makes the key's next version from its template, enabled (or
/// `pending_generation`, for an asymmetric key), not primary. Each create
/// makes a version billed until destroyed, so a request that may have
/// reached the server is never sent again: a failure after sending is
/// returned, and `listVersions` says whether it landed.
pub fn createVersion(self: Key) Error!types.Owned(types.VersionInfo) {
    const c = self.client;
    rpc.begin(c);
    try c.checkTarget(self.target);
    var scratch: std.heap.ArenaAllocator = .init(c.gpa);
    defer scratch.deinit();
    var result: types.Owned(types.VersionInfo) = try .init(c.gpa);
    errdefer result.deinit();
    const body = try rpc.execute(c, result.arena, .{
        .method = .POST,
        .path = try self.target.path(scratch.allocator(), "/cryptoKeyVersions"),
        .body = "{}",
        .retryable = rpc.unsentOnly,
    });
    result.value = codec.decodeVersion(result.arena.allocator(), scratch.allocator(), body) catch |err|
        return rpc.decodeFailed(c, err, "key version");
    return result;
}

/// One page of the key's versions, by number.
pub fn listVersions(self: Key, options: types.ListOptions) Error!types.Owned(types.VersionPage) {
    const c = self.client;
    rpc.begin(c);
    try c.checkTarget(self.target);
    var scratch: std.heap.ArenaAllocator = .init(c.gpa);
    defer scratch.deinit();
    const path = try c.listPath(scratch.allocator(), self.target, "/cryptoKeyVersions", options);
    var result: types.Owned(types.VersionPage) = try .init(c.gpa);
    errdefer result.deinit();
    const body = try rpc.execute(c, result.arena, .{ .method = .GET, .path = path });
    result.value = codec.decodeVersionPage(result.arena.allocator(), scratch.allocator(), body) catch |err|
        return rpc.decodeFailed(c, err, "key version list");
    return result;
}

/// Deletes the key, and waits for the server to finish. Every version
/// must be deleted first, so destroyed and its destroy delay passed, and
/// no rotation scheduled; a key made by Autokey cannot be deleted. Its id
/// is then retired in the project for good: `Client.listRetiredKeys`.
pub fn delete(self: Key) Error!void {
    const c = self.client;
    rpc.begin(c);
    try c.checkTarget(self.target);
    var scratch: std.heap.ArenaAllocator = .init(c.gpa);
    defer scratch.deinit();
    return operations.delete(c, try self.target.path(scratch.allocator(), ""), "a key");
}

fn keyCall(self: Key, method: core.transport.Method, tail: []const u8, body: ?[]const u8) Error!types.Owned(types.KeyInfo) {
    const c = self.client;
    rpc.begin(c);
    try c.checkTarget(self.target);
    var scratch: std.heap.ArenaAllocator = .init(c.gpa);
    defer scratch.deinit();
    const a = scratch.allocator();
    return self.keyRequest(a, method, try self.target.path(a, tail), body);
}

fn keyRequest(self: Key, scratch: std.mem.Allocator, method: core.transport.Method, path: []const u8, body: ?[]const u8) Error!types.Owned(types.KeyInfo) {
    const c = self.client;
    var result: types.Owned(types.KeyInfo) = try .init(c.gpa);
    errdefer result.deinit();
    const answer = try rpc.execute(c, result.arena, .{ .method = method, .path = path, .body = body });
    result.value = codec.decodeKey(result.arena.allocator(), scratch, answer) catch |err|
        return rpc.decodeFailed(c, err, "key");
    return result;
}

const testing = std.testing;
const test_util = @import("test_util.zig");
const Harness = test_util.Harness;
const base = test_util.base;

const key_name = "projects/my-project/locations/us-central1/keyRings/r/cryptoKeys/k";
const key_body = "{\"name\":\"" ++ key_name ++ "\",\"purpose\":\"ENCRYPT_DECRYPT\",\"primary\":{\"name\":\"" ++ key_name ++ "/cryptoKeyVersions/1\",\"state\":\"ENABLED\"}}";
const version_body = "{\"name\":\"" ++ key_name ++ "/cryptoKeyVersions/2\",\"state\":\"PENDING_GENERATION\",\"algorithm\":\"EC_SIGN_P256_SHA256\"}";
const fast: core.RetryPolicy = .{ .max_attempts = 3, .initial_backoff_ms = 1, .max_backoff_ms = 2 };

test "golden: create sends the key, its id and whether to skip version 1" {
    var h: Harness = undefined;
    try h.init(&.{ .{ .respond = .{ .body = key_body } }, .{ .respond = .{ .body = key_body } } }, .{});
    defer h.deinit();
    const key = h.client.keyRing("r").key("k");
    var created = try key.create(.{ .purpose = .encrypt_decrypt, .destroy_delay_s = 86_400 });
    defer created.deinit();
    try h.expectRequest(0, .POST, base ++ "/keyRings/r/cryptoKeys?cryptoKeyId=k",
        \\{"purpose":"ENCRYPT_DECRYPT","versionTemplate":{"protectionLevel":"SOFTWARE","algorithm":"GOOGLE_SYMMETRIC_ENCRYPTION"},"destroyScheduledDuration":"86400s"}
    );
    try testing.expectEqual(1, created.value.primary.?.id);
    var bare = try key.create(.{ .purpose = .asymmetric_sign, .algorithm = .ec_sign_p256_sha256, .first_version = false });
    defer bare.deinit();
    try h.expectRequest(1, .POST, base ++ "/keyRings/r/cryptoKeys?cryptoKeyId=k&skipInitialVersionCreation=true",
        \\{"purpose":"ASYMMETRIC_SIGN","versionTemplate":{"protectionLevel":"SOFTWARE","algorithm":"EC_SIGN_P256_SHA256"}}
    );
}

test "create: a config the server would refuse is InvalidOptions, and nothing goes out" {
    var h: Harness = undefined;
    try h.init(&.{}, .{});
    defer h.deinit();
    const key = h.client.keyRing("r").key("k");
    try testing.expectError(error.InvalidOptions, key.create(.{ .purpose = .mac }));
    try testing.expect(std.mem.indexOf(u8, h.diag.message(), "names its algorithm") != null);
    try testing.expectError(error.InvalidOptions, key.create(.{ .purpose = .encrypt_decrypt, .destroy_delay_s = 3600 }));
    try testing.expectError(error.InvalidOptions, key.update(.{}));
    try h.expectRequestCount(0);
}

test "golden: get, update with its mask, setPrimary and delete" {
    var h: Harness = undefined;
    try h.init(&.{
        .{ .respond = .{ .body = key_body } },
        .{ .respond = .{ .body = key_body } },
        .{ .respond = .{ .body = key_body } },
        .{ .respond = .{ .body = "{\"name\":\"projects/my-project/locations/us-central1/operations/o\",\"done\":true}" } },
    }, .{});
    defer h.deinit();
    const key = h.client.keyRing("r").key("k");
    var got = try key.get();
    defer got.deinit();
    try h.expectRequest(0, .GET, base ++ "/keyRings/r/cryptoKeys/k", null);
    var updated = try key.update(.{ .labels = .{ .set = &.{.{ .key = "team", .value = "a" }} }, .rotation = .clear });
    defer updated.deinit();
    try h.expectRequest(1, .PATCH, base ++ "/keyRings/r/cryptoKeys/k?updateMask=labels%2CrotationPeriod%2CnextRotationTime", "{\"labels\":{\"team\":\"a\"}}");
    var primary = try key.setPrimary(2);
    defer primary.deinit();
    try h.expectRequest(2, .POST, base ++ "/keyRings/r/cryptoKeys/k:updatePrimaryVersion", "{\"cryptoKeyVersionId\":\"2\"}");
    try key.delete();
    try h.expectRequest(3, .DELETE, base ++ "/keyRings/r/cryptoKeys/k", null);
    try testing.expectError(error.InvalidName, key.setPrimary(0));
    try h.expectRequestCount(4);
}

test "createVersion: sent again only when it cannot have left" {
    var h: Harness = undefined;
    try h.init(&.{
        .{ .fail = error.ConnectionRefused },
        .{ .respond = .{ .body = version_body } },
        .{ .respond = .{ .status = 503, .body = "{}" } },
        .{ .fail = error.ConnectionResetByPeer },
    }, .{ .retry = fast });
    defer h.deinit();
    const key = h.client.keyRing("r").key("k");
    var made = try key.createVersion();
    defer made.deinit();
    try h.expectRequest(1, .POST, base ++ "/keyRings/r/cryptoKeys/k/cryptoKeyVersions", "{}");
    try testing.expectEqual(2, made.value.id);
    try testing.expectEqual(types.State.pending_generation, made.value.state);
    // A 503 or a reset may follow a version made: neither is sent again.
    try testing.expectError(error.Unavailable, key.createVersion());
    try testing.expectError(error.ConnectionResetByPeer, key.createVersion());
    try h.expectRequestCount(4);
}

test "golden: listVersions, and reads retried as usual" {
    var h: Harness = undefined;
    try h.init(&.{
        .{ .respond = .{ .status = 500, .body = "{}" } },
        .{ .respond = .{ .body = "{\"cryptoKeyVersions\":[" ++ version_body ++ "]}" } },
    }, .{ .retry = fast });
    defer h.deinit();
    var page = try h.client.keyRing("r").key("k").listVersions(.{ .filter = "state != DESTROYED" });
    defer page.deinit();
    try h.expectRequest(1, .GET, base ++ "/keyRings/r/cryptoKeys/k/cryptoKeyVersions?filter=state%20%21%3D%20DESTROYED", null);
    try testing.expectEqual(1, page.value.versions.len);
}

test "a key named in full goes to its own project and location" {
    var h: Harness = undefined;
    try h.init(&.{.{ .respond = .{ .body = "{\"name\":\"projects/other/locations/global/keyRings/r2/cryptoKeys/k2\",\"purpose\":\"MAC\"}" } }}, .{});
    defer h.deinit();
    const key = try h.client.keyNamed("projects/other/locations/global/keyRings/r2/cryptoKeys/k2");
    var got = try key.get();
    defer got.deinit();
    try h.expectRequest(0, .GET, "https://cloudkms.googleapis.com/v1/projects/other/locations/global/keyRings/r2/cryptoKeys/k2", null);
    for ([_][]const u8{
        "projects/other/locations/global/keyRings/r2/cryptoKeys/k2/cryptoKeyVersions/1",
        "projects/other/locations/global/keyRings/r2",
        "projects/o t/locations/global/keyRings/r2/cryptoKeys/k2",
        "projects/other/locations/Global/keyRings/r2/cryptoKeys/k2",
        "projects/other/locations/global/keyRings/r.2/cryptoKeys/k2",
        "projects/other/locations/global/keyRings/r2/cryptoKeys/k%41",
    }) |bad| try testing.expectError(error.InvalidName, h.client.keyNamed(bad));
}
