//! A key: what it is for, how new versions are made, and its versions.
//! A handle makes no call until asked.

const Key = @This();

const std = @import("std");
const core = @import("core");
const Client = @import("Client.zig");
const codec = @import("codec.zig");
const integrity = @import("integrity.zig");
const KeyVersion = @import("KeyVersion.zig");
const names = @import("names.zig");
const operations = @import("operations.zig");
const Plaintext = @import("Plaintext.zig");
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

/// Encrypts up to 64 KiB with the key's primary version, or with
/// `options.version`, binding `options.aad` to the ciphertext. The answer
/// names the version used, which after a primary change may for a while be
/// the old primary. Encrypting the same bytes twice gives two ciphertexts,
/// both good. The plaintext is wiped from every buffer this call fills.
/// For more than 64 KiB, encrypt a data key here and the data with it.
pub fn encrypt(self: Key, plaintext: []const u8, options: types.EncryptOptions) Error!types.Owned(types.Ciphertext) {
    const c = self.client;
    rpc.begin(c);
    try c.checkTarget(self.target);
    if (options.version) |v| try c.checkTarget(self.version(v).target);
    try checkPayload(c, "plaintext", plaintext.len);
    try checkPayload(c, "AAD", options.aad.len);

    var wiping: core.WipingAllocator = .init(c.gpa);
    var scratch: std.heap.ArenaAllocator = .init(wiping.allocator());
    defer scratch.deinit();
    const a = scratch.allocator();
    const target = if (options.version) |v| self.version(v).target else self.target;
    const path = try target.path(a, ":encrypt");
    const body = try codec.encodeEncrypt(a, plaintext, options.aad);
    const key_name = try self.target.name(a);

    var tries: integrity.Attempts = .{ .client = c, .what = "encrypt" };
    while (true) {
        tries.next();
        var result: types.Owned(types.Ciphertext) = try .init(c.gpa);
        const answer_body = rpc.execute(c, result.arena, .{ .method = .POST, .path = path, .body = body, .wipe = true }) catch |err| {
            result.deinit();
            if (err != error.IntegrityCheckFailed) return err;
            try tries.failed(integrity.request_refused);
            continue;
        };
        const answer = codec.decodeEncrypt(result.arena.allocator(), a, answer_body) catch |err| {
            result.deinit();
            return rpc.decodeFailed(c, err, "encrypt");
        };
        const version_id = versionOf(key_name, answer.name);
        const problem: ?[]const u8 = if (!answer.verified_plaintext)
            "the server did not get the plaintext's checksum"
        else if (!answer.verified_aad)
            "the server did not get the AAD's checksum"
        else if (!integrity.matches(answer.ciphertext, answer.ciphertext_crc32c))
            "the ciphertext does not match its checksum"
        else if (version_id == null or (options.version != null and version_id.? != options.version.?))
            "the answer names a version that was not asked for"
        else
            null;
        if (problem) |reason| {
            result.deinit();
            try tries.failed(reason);
            continue;
        }
        result.value = .{ .bytes = answer.ciphertext, .version = version_id.? };
        return result;
    }
}

/// Decrypts what `encrypt` made with this key, with the AAD it was given.
/// The ciphertext names its version, which must still be enabled: a
/// disabled one is `error.KeyVersionDisabled`, a destroyed or scheduled one
/// `error.KeyVersionDestroyed`, its name in `Diagnostics`. Another key's
/// ciphertext, or bytes that are not one, is `error.DecryptionFailed`. The
/// plaintext comes back in memory its `deinit` wipes, and every other
/// buffer that held it is wiped before the call returns.
///
/// The caller owns the result: `defer plaintext.deinit()`.
pub fn decrypt(self: Key, ciphertext: []const u8, options: types.DecryptOptions) Error!Plaintext {
    const c = self.client;
    rpc.begin(c);
    try c.checkTarget(self.target);
    try checkPayload(c, "AAD", options.aad.len);

    var wiping: core.WipingAllocator = .init(c.gpa);
    var scratch: std.heap.ArenaAllocator = .init(wiping.allocator());
    defer scratch.deinit();
    const a = scratch.allocator();
    const path = try self.target.path(a, ":decrypt");
    const body = try codec.encodeDecrypt(a, ciphertext, options.aad);

    var value: Plaintext = try .init(c.gpa);
    errdefer value.deinit();
    var tries: integrity.Attempts = .{ .client = c, .what = "decrypt" };
    while (true) {
        tries.next();
        const answer_body = rpc.execute(c, value.arena(), .{ .method = .POST, .path = path, .body = body, .wipe = true }) catch |err| {
            if (err != error.IntegrityCheckFailed) return err;
            value.clear();
            try tries.failed(integrity.request_refused);
            continue;
        };
        const answer = codec.decodeDecrypt(value.allocator(), value.allocator(), answer_body) catch |err|
            return rpc.decodeFailed(c, err, "decrypt");
        if (!integrity.matches(answer.plaintext, answer.plaintext_crc32c)) {
            value.clear();
            try tries.failed("the plaintext does not match its checksum");
            continue;
        }
        value.data = .init(answer.plaintext);
        value.used_primary = answer.used_primary;
        return value;
    }
}

/// The version number of `version_name` when it is a version of
/// `key_name`, or null.
fn versionOf(key_name: []const u8, version_name: []const u8) ?u64 {
    if (!std.mem.startsWith(u8, version_name, key_name)) return null;
    const rest = version_name[key_name.len..];
    if (!std.mem.startsWith(u8, rest, "/cryptoKeyVersions/")) return null;
    return names.versionId(version_name);
}

/// Refuses `len` bytes of `what` past 64 KiB.
pub fn checkPayload(c: *Client, what: []const u8, len: usize) Error!void {
    if (len <= validate.max_payload) return;
    if (c.diagnostics) |d| d.print("the {s} is {d} bytes; Cloud KMS takes at most 65,536", .{ what, len });
    return error.TooLarge;
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

const test_key = "projects/my-project/locations/us-central1/keyRings/r/cryptoKeys/k";
const key_body = "{\"name\":\"" ++ test_key ++ "\",\"purpose\":\"ENCRYPT_DECRYPT\",\"primary\":{\"name\":\"" ++ test_key ++ "/cryptoKeyVersions/1\",\"state\":\"ENABLED\"}}";
const version_body = "{\"name\":\"" ++ test_key ++ "/cryptoKeyVersions/2\",\"state\":\"PENDING_GENERATION\",\"algorithm\":\"EC_SIGN_P256_SHA256\"}";
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

const v1 = test_key ++ "/cryptoKeyVersions/1";
/// CRC-32C of "c1ph" 908558936, of "ctx" 2801377629, of "s3cr3t-plain"
/// 866759889, as integrity.zig's test of `matches` holds core.crc32c to.
/// An encrypt's answer: `ciphertext` "c1ph" whose checksum is right.
fn encryptAnswer(comptime name: []const u8, comptime flags: []const u8) []const u8 {
    return "{\"name\":\"" ++ name ++ "\",\"ciphertext\":\"YzFwaA==\",\"ciphertextCrc32c\":\"" ++ "908558936" ++ "\"" ++ flags ++ "}";
}
const both_verified = ",\"verifiedPlaintextCrc32c\":true,\"verifiedAdditionalAuthenticatedDataCrc32c\":true";

test "golden: encrypt sends the plaintext and AAD with their checksums, and answers the version used" {
    var h: Harness = undefined;
    try h.init(&.{
        .{ .respond = .{ .body = encryptAnswer(v1, both_verified) } },
        .{ .respond = .{ .body = encryptAnswer(test_key ++ "/cryptoKeyVersions/3", both_verified) } },
    }, .{});
    defer h.deinit();
    const key = h.client.keyRing("r").key("k");
    var c = try key.encrypt("hello", .{});
    defer c.deinit();
    try h.expectRequest(0, .POST, base ++ "/keyRings/r/cryptoKeys/k:encrypt", "{\"plaintext\":\"aGVsbG8=\",\"plaintextCrc32c\":\"2591144780\",\"additionalAuthenticatedDataCrc32c\":\"0\"}");
    try testing.expectEqualStrings("c1ph", c.value.bytes);
    try testing.expectEqual(1, c.value.version);
    var pinned = try key.encrypt("", .{ .aad = "ctx", .version = 3 });
    defer pinned.deinit();
    try h.expectRequest(1, .POST, base ++ "/keyRings/r/cryptoKeys/k/cryptoKeyVersions/3:encrypt", "{\"plaintextCrc32c\":\"0\",\"additionalAuthenticatedData\":\"Y3R4\",\"additionalAuthenticatedDataCrc32c\":\"" ++ "2801377629" ++ "\"}");
    try testing.expectEqual(3, pinned.value.version);
}

test "encrypt: each failed check is tried again, and past the attempts is IntegrityCheckFailed" {
    const cases = [_]struct { []const u8, []const u8 }{
        .{ encryptAnswer(v1, ",\"verifiedAdditionalAuthenticatedDataCrc32c\":true"), "did not get the plaintext's checksum" },
        .{ encryptAnswer(v1, ",\"verifiedPlaintextCrc32c\":true"), "did not get the AAD's checksum" },
        .{ "{\"name\":\"" ++ v1 ++ "\",\"ciphertext\":\"YzFwaA==\",\"ciphertextCrc32c\":\"1\"" ++ both_verified ++ "}", "ciphertext does not match its checksum" },
        .{ "{\"name\":\"" ++ v1 ++ "\",\"ciphertext\":\"YzFwaA==\"" ++ both_verified ++ "}", "ciphertext does not match its checksum" },
        .{ encryptAnswer("projects/my-project/locations/us-central1/keyRings/r/cryptoKeys/other/cryptoKeyVersions/1", both_verified), "names a version that was not asked for" },
        .{ encryptAnswer(test_key ++ "x/cryptoKeyVersions/1", both_verified), "names a version that was not asked for" },
        .{ encryptAnswer(test_key, both_verified), "names a version that was not asked for" },
    };
    for (cases) |case| {
        var h: Harness = undefined;
        try h.init(&.{
            .{ .respond = .{ .body = case[0] } },
            .{ .respond = .{ .body = encryptAnswer(v1, both_verified) } },
            .{ .respond = .{ .body = case[0] } },
            .{ .respond = .{ .body = case[0] } },
        }, .{ .retry = .{ .max_attempts = 2, .initial_backoff_ms = 1, .max_backoff_ms = 2 } });
        defer h.deinit();
        const key = h.client.keyRing("r").key("k");
        // Once: tried again, and the second answer is good.
        var c = try key.encrypt("x", .{});
        c.deinit();
        try h.expectRequestCount(2);
        // Every time: refused, with the check in Diagnostics.
        try testing.expectError(error.IntegrityCheckFailed, key.encrypt("x", .{}));
        try testing.expect(std.mem.indexOf(u8, h.diag.message(), case[1]) != null);
        try h.expectRequestCount(4);
    }
}

test "encrypt: a pinned version must be the one that answers, and a refused request checksum is tried again" {
    var h: Harness = undefined;
    const refused = "{\"error\":{\"code\":400,\"message\":\"The checksum in field plaintext_crc32c did not match the data in field plaintext.\",\"status\":\"INVALID_ARGUMENT\"}}";
    try h.init(&.{
        .{ .respond = .{ .body = encryptAnswer(v1, both_verified) } },
        .{ .respond = .{ .status = 400, .body = refused } },
        .{ .respond = .{ .body = encryptAnswer(v1, both_verified) } },
        .{ .respond = .{ .status = 400, .body = refused } },
        .{ .respond = .{ .status = 400, .body = refused } },
    }, .{ .retry = .{ .max_attempts = 2, .initial_backoff_ms = 1, .max_backoff_ms = 2 } });
    defer h.deinit();
    const key = h.client.keyRing("r").key("k");
    try testing.expectError(error.IntegrityCheckFailed, key.encrypt("x", .{ .version = 2 }));
    try testing.expect(std.mem.indexOf(u8, h.diag.message(), "request checksum") != null);
    var c = try key.encrypt("x", .{});
    c.deinit();
    try testing.expectError(error.IntegrityCheckFailed, key.encrypt("x", .{ .version = 1 }));
    try testing.expect(std.mem.indexOf(u8, h.diag.message(), "request checksum") != null);
}

test "encrypt and decrypt refuse what Cloud KMS would, before sending" {
    var h: Harness = undefined;
    try h.init(&.{}, .{});
    defer h.deinit();
    const key = h.client.keyRing("r").key("k");
    const big = try testing.allocator.alloc(u8, validate.max_payload + 1);
    defer testing.allocator.free(big);
    @memset(big, 'a');
    try testing.expectError(error.TooLarge, key.encrypt(big, .{}));
    try testing.expect(std.mem.indexOf(u8, h.diag.message(), "65537 bytes") != null);
    // 64 KiB exactly is sent; the empty script answers it with an error.
    try testing.expectError(error.HttpProtocolError, key.encrypt(big[0..validate.max_payload], .{}));
    try testing.expectError(error.HttpProtocolError, key.decrypt("x", .{ .aad = big[0..validate.max_payload] }));
    try testing.expectError(error.TooLarge, key.encrypt("x", .{ .aad = big }));
    try testing.expectError(error.TooLarge, key.decrypt("x", .{ .aad = big }));
    try testing.expectError(error.InvalidName, key.encrypt("x", .{ .version = 0 }));
    try testing.expectError(error.InvalidName, h.client.keyRing("r").key("a b").decrypt("x", .{}));
    try h.expectRequestCount(2);
}

fn decryptAnswer(comptime plaintext_b64: []const u8, comptime crc: u32, comptime extra: []const u8) []const u8 {
    return "{\"plaintext\":\"" ++ plaintext_b64 ++ "\",\"plaintextCrc32c\":\"" ++ std.fmt.comptimePrint("{d}", .{crc}) ++ "\"" ++ extra ++ "}";
}

test "golden: decrypt sends the ciphertext and AAD with their checksums, and checks the plaintext's" {
    var h: Harness = undefined;
    try h.init(&.{
        .{ .respond = .{ .body = decryptAnswer("aGVsbG8=", 2591144780, ",\"usedPrimary\":true") } },
        .{ .respond = .{ .body = decryptAnswer("aGVsbG8=", 1, "") } },
        .{ .respond = .{ .body = decryptAnswer("aGVsbG8=", 2591144780, "") } },
        // An empty plaintext is left out, and its checksum is 0.
        .{ .respond = .{ .body = "{\"plaintextCrc32c\":\"0\"}" } },
    }, .{ .retry = .{ .max_attempts = 2, .initial_backoff_ms = 1, .max_backoff_ms = 2 } });
    defer h.deinit();
    const key = h.client.keyRing("r").key("k");
    var p = try key.decrypt("c1ph", .{ .aad = "ctx" });
    defer p.deinit();
    try h.expectRequest(0, .POST, base ++ "/keyRings/r/cryptoKeys/k:decrypt", "{\"ciphertext\":\"YzFwaA==\",\"ciphertextCrc32c\":\"" ++ "908558936" ++ "\",\"additionalAuthenticatedData\":\"Y3R4\",\"additionalAuthenticatedDataCrc32c\":\"" ++ "2801377629" ++ "\"}");
    try testing.expectEqualStrings("hello", p.bytes());
    try testing.expect(p.used_primary);
    // A plaintext that fails its checksum is fetched again.
    var again = try key.decrypt("c1ph", .{});
    defer again.deinit();
    try testing.expectEqualStrings("hello", again.bytes());
    try testing.expect(!again.used_primary);
    var empty = try key.decrypt("c1ph", .{});
    defer empty.deinit();
    try testing.expectEqualStrings("", empty.bytes());
    try h.expectRequestCount(4);
}

test "decrypt: another key's ciphertext, and a version not enabled, are their own errors" {
    var h: Harness = undefined;
    try h.init(&.{
        .{ .respond = .{ .status = 400, .body = "{\"error\":{\"code\":400,\"message\":\"Decryption failed: verify that 'name' refers to the correct CryptoKey.\",\"status\":\"INVALID_ARGUMENT\"}}" } },
        .{ .respond = .{ .status = 400, .body = "{\"error\":{\"code\":400,\"message\":\"" ++ v1 ++ " is not enabled, current state is: DISABLED.\",\"status\":\"FAILED_PRECONDITION\",\"details\":[{\"@type\":\"type.googleapis.com/google.rpc.PreconditionFailure\",\"violations\":[{\"subject\":\"" ++ v1 ++ "\",\"type\":\"KEY_DISABLED\"}]}]}}" } },
        .{ .respond = .{ .status = 400, .body = "{\"error\":{\"code\":400,\"message\":\"Invalid value at 'ciphertext' (TYPE_BYTES)\",\"status\":\"INVALID_ARGUMENT\"}}" } },
    }, .{});
    defer h.deinit();
    const key = h.client.keyRing("r").key("k");
    try testing.expectError(error.DecryptionFailed, key.decrypt("c", .{}));
    try testing.expect(std.mem.indexOf(u8, h.diag.message(), "correct CryptoKey") != null);
    try testing.expectError(error.KeyVersionDisabled, key.decrypt("c", .{}));
    try testing.expect(std.mem.indexOf(u8, h.diag.message(), v1) != null);
    try testing.expectError(error.InvalidArgument, key.decrypt("c", .{}));
}

test "decrypt: the plaintext is wiped from every buffer the call filled, and from the result's at deinit" {
    var backing: [256 * 1024]u8 = @splat(0);
    var fba: std.heap.FixedBufferAllocator = .init(&backing);
    var fake: test_util.FakeTransport = .init(testing.allocator, &.{
        .{ .respond = .{ .body = decryptAnswer("czNjcjN0LXBsYWlu", 866759890, "") } },
        .{ .respond = .{ .body = decryptAnswer("czNjcjN0LXBsYWlu", 866759889, "") } },
        .{ .respond = .{ .body = encryptAnswer(v1, both_verified) } },
    });
    defer fake.deinit();
    var clock: test_util.FakeClock = .{};
    var token: test_util.FakeTokenProvider = .{ .token = "t" };
    var client: Client = try .init(fba.allocator(), clock.io(), .{ .project_id = "my-project", .location = "us-central1", .token_provider = token.provider(), .transport = fake.transport(), .retry = .{ .initial_backoff_ms = 1, .max_backoff_ms = 2 } });
    defer client.deinit();
    const key = client.keyRing("r").key("k");
    var p = try key.decrypt("c1ph", .{});
    try testing.expectEqualStrings("s3cr3t-plain", p.bytes());
    p.deinit();
    try testing.expectEqual(null, std.mem.indexOf(u8, &backing, "s3cr3t-plain"));
    try testing.expectEqual(null, std.mem.indexOf(u8, &backing, "czNjcjN0LXBsYWlu"));
    // Encrypt wipes the plaintext it sent, and its base64.
    var c = try key.encrypt("s3cr3t-plain", .{});
    c.deinit();
    try testing.expectEqual(null, std.mem.indexOf(u8, &backing, "s3cr3t-plain"));
    try testing.expectEqual(null, std.mem.indexOf(u8, &backing, "czNjcjN0LXBsYWlu"));
}
