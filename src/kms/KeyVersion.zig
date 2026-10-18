//! A key version: the key material itself, numbered from 1, and its
//! state. A handle makes no call until asked.

const KeyVersion = @This();

const std = @import("std");
const core = @import("core");
const Client = @import("Client.zig");
const codec = @import("codec.zig");
const integrity = @import("integrity.zig");
const Key = @import("Key.zig");
const logging = @import("logging.zig");
const names = @import("names.zig");
const operations = @import("operations.zig");
const rpc = @import("rpc.zig");
const types = @import("types.zig");
const Error = @import("errors.zig").Error;

client: *Client,
/// The project, location, key ring, key and version.
target: names.Target,

/// The version's number.
pub fn id(self: KeyVersion) u64 {
    return self.target.version.?;
}

/// Signs `message` with this version, whose algorithm is `algorithm`: the
/// caller says it, so no read precedes the signature. Algorithms that sign
/// a digest (ECDSA, RSA, SLH-DSA's pre-hash form) have it made here; those
/// that sign data (Ed25519, ML-DSA, SLH-DSA) send the message, at most
/// 64 KiB. An algorithm of another purpose, or raw PKCS#1 and ML-DSA's
/// external mu, whose input the caller prepares, is
/// `error.InvalidOptions`; one that is not the version's, the server's
/// refusal. A version still `pending_generation` is
/// `error.KeyVersionPending`. ECDSA signatures are DER, RSA ones the
/// modulus's length, Ed25519 64 bytes. `PublicKey.verify` checks one here.
pub fn sign(self: KeyVersion, algorithm: types.Algorithm, message: []const u8) Error!types.Owned([]const u8) {
    const c = self.client;
    rpc.begin(c);
    try c.checkTarget(self.target);
    const input = try signInput(c, algorithm);
    var buf: [64]u8 = undefined;
    switch (input) {
        .digest => |kind| return self.signWith(input, kind.digest(message, &buf)),
        .data => {
            try Key.checkPayload(c, "data to sign", message.len);
            return self.signWith(input, message);
        },
    }
}

/// Signs a digest made elsewhere, for an algorithm that signs a digest:
/// 32 bytes for SHA-256, 48 for SHA-384, 64 for SHA-512, or
/// `error.InvalidDigest`. An algorithm that signs data is
/// `error.InvalidOptions`.
pub fn signDigest(self: KeyVersion, algorithm: types.Algorithm, digest: []const u8) Error!types.Owned([]const u8) {
    const c = self.client;
    rpc.begin(c);
    try c.checkTarget(self.target);
    const input = try signInput(c, algorithm);
    switch (input) {
        .digest => |kind| if (digest.len != kind.length()) {
            if (c.diagnostics) |d| d.print("{s} signs a {s} digest of {d} bytes; this one has {d}", .{ algorithm.wire(), @tagName(kind), kind.length(), digest.len });
            return error.InvalidDigest;
        },
        .data => {
            if (c.diagnostics) |d| d.print("{s} signs the message itself, not a digest: use sign", .{algorithm.wire()});
            return error.InvalidOptions;
        },
    }
    return self.signWith(input, digest);
}

fn signInput(c: *Client, algorithm: types.Algorithm) Error!types.SignInput {
    return algorithm.signInput() orelse {
        if (c.diagnostics) |d| d.print("{s} is not an algorithm this library signs with", .{algorithm.wire()});
        return error.InvalidOptions;
    };
}

fn signWith(self: KeyVersion, input: types.SignInput, bytes: []const u8) Error!types.Owned([]const u8) {
    const c = self.client;
    var scratch: std.heap.ArenaAllocator = .init(c.gpa);
    defer scratch.deinit();
    const a = scratch.allocator();
    const path = try self.target.path(a, ":asymmetricSign");
    const body = try codec.encodeSign(a, input, bytes);
    const name = try self.target.name(a);
    var tries: integrity.Attempts = .{ .client = c, .what = "sign" };
    while (true) {
        tries.next();
        var result: types.Owned([]const u8) = try .init(c.gpa);
        const answer_body = rpc.execute(c, result.arena, .{ .method = .POST, .path = path, .body = body }) catch |err| {
            result.deinit();
            if (err != error.IntegrityCheckFailed) return err;
            try tries.failed(integrity.request_refused);
            continue;
        };
        const answer = codec.decodeSign(result.arena.allocator(), a, answer_body) catch |err| {
            result.deinit();
            return rpc.decodeFailed(c, err, "sign");
        };
        const verified = switch (input) {
            .digest => answer.verified_digest,
            .data => answer.verified_data,
        };
        const problem: ?[]const u8 = if (!verified)
            "the server did not get the checksum of what it signed"
        else if (!integrity.matches(answer.signature, answer.signature_crc32c))
            "the signature does not match its checksum"
        else if (!std.mem.eql(u8, answer.name, name))
            "the answer names another version"
        else
            null;
        if (problem) |reason| {
            result.deinit();
            try tries.failed(reason);
            continue;
        }
        result.value = answer.signature;
        return result;
    }
}

/// The version's public key, for an asymmetric key, checked against its
/// checksum: a PEM SubjectPublicKeyInfo, ML-DSA's too, or the NIST
/// encoding when the server says a key has only that, as Tink reports of
/// SLH-DSA. It never changes, so keep it while the version lives. A version
/// that is not enabled is that state's error.
pub fn publicKey(self: KeyVersion) Error!types.Owned(types.PublicKey) {
    const c = self.client;
    rpc.begin(c);
    try c.checkTarget(self.target);
    var scratch: std.heap.ArenaAllocator = .init(c.gpa);
    defer scratch.deinit();
    const a = scratch.allocator();
    const name = try self.target.name(a);
    // PEM unless the server says the key has only the NIST encoding:
    // asking which first would cost a read.
    var format: []const u8 = "PEM";
    var tries: integrity.Attempts = .{ .client = c, .what = "publicKey" };
    while (true) {
        tries.next();
        const path = try self.target.path(a, if (std.mem.eql(u8, format, "PEM")) "/publicKey?publicKeyFormat=PEM" else "/publicKey?publicKeyFormat=NIST_PQC");
        var result: types.Owned(types.PublicKey) = try .init(c.gpa);
        var error_body: ?[]const u8 = null;
        const answer_body = rpc.execute(c, result.arena, .{ .method = .GET, .path = path, .error_body_out = &error_body }) catch |err| {
            const only_nist = std.mem.eql(u8, format, "PEM") and (err == error.InvalidArgument or err == error.FailedPrecondition) and
                if (error_body) |b| std.mem.indexOf(u8, b, "NIST_PQC") != null else false;
            result.deinit();
            if (only_nist) {
                format = "NIST_PQC";
                tries.attempt -= 1;
                continue;
            }
            return err;
        };
        const answer = codec.decodePublicKey(result.arena.allocator(), a, answer_body) catch |err| {
            result.deinit();
            return rpc.decodeFailed(c, err, "public key");
        };
        // Asked for as PEM, production answered the PEM in `publicKey.data`
        // and no `pem`; asked with no format, in `pem` (2026-10-18).
        const pem_asked = std.mem.eql(u8, format, "PEM");
        const problem: ?[]const u8 = if (answer.pem.len == 0 and answer.data.len == 0)
            "the answer holds no key"
        else if (answer.pem.len > 0 and !integrity.matches(answer.pem, answer.pem_crc32c))
            "the PEM does not match its checksum"
        else if (answer.data.len > 0 and !integrity.matches(answer.data, answer.data_crc32c))
            "the key does not match its checksum"
        else if (answer.name != null and !std.mem.eql(u8, answer.name.?, name))
            "the answer names another version"
        else if (!pem_asked and answer.data.len == 0)
            "the key asked for in the NIST encoding came without it"
        else
            null;
        if (problem) |reason| {
            result.deinit();
            try tries.failed(reason);
            continue;
        }
        const owned_name = result.arena.allocator().dupe(u8, name) catch |err| {
            result.deinit();
            return err;
        };
        result.value = .{
            .name = owned_name,
            .algorithm = answer.algorithm,
            .protection_level = answer.protection_level,
            .pem = if (!pem_asked) "" else if (answer.pem.len > 0) answer.pem else answer.data,
            .raw = if (pem_asked) "" else answer.data,
        };
        return result;
    }
}

/// Signs `data`, at most 64 KiB, with this MAC version.
pub fn macSign(self: KeyVersion, data: []const u8) Error!types.Owned([]const u8) {
    const c = self.client;
    rpc.begin(c);
    try c.checkTarget(self.target);
    try Key.checkPayload(c, "data to sign", data.len);
    var scratch: std.heap.ArenaAllocator = .init(c.gpa);
    defer scratch.deinit();
    const a = scratch.allocator();
    const path = try self.target.path(a, ":macSign");
    const body = try codec.encodeMacSign(a, data);
    const name = try self.target.name(a);
    var tries: integrity.Attempts = .{ .client = c, .what = "macSign" };
    while (true) {
        tries.next();
        var result: types.Owned([]const u8) = try .init(c.gpa);
        const answer_body = rpc.execute(c, result.arena, .{ .method = .POST, .path = path, .body = body }) catch |err| {
            result.deinit();
            if (err != error.IntegrityCheckFailed) return err;
            try tries.failed(integrity.request_refused);
            continue;
        };
        const answer = codec.decodeMacSign(result.arena.allocator(), a, answer_body) catch |err| {
            result.deinit();
            return rpc.decodeFailed(c, err, "macSign");
        };
        const problem: ?[]const u8 = if (!answer.verified_data)
            "the server did not get the data's checksum"
        else if (!integrity.matches(answer.mac, answer.mac_crc32c))
            "the MAC does not match its checksum"
        else if (!std.mem.eql(u8, answer.name, name))
            "the answer names another version"
        else
            null;
        if (problem) |reason| {
            result.deinit();
            try tries.failed(reason);
            continue;
        }
        result.value = answer.mac;
        return result;
    }
}

/// Whether `mac` is this MAC version's over `data`. One that does not
/// match is `false`, not an error.
pub fn macVerify(self: KeyVersion, data: []const u8, mac: []const u8) Error!bool {
    const c = self.client;
    rpc.begin(c);
    try c.checkTarget(self.target);
    try Key.checkPayload(c, "data to verify", data.len);
    try Key.checkPayload(c, "MAC", mac.len);
    var scratch: std.heap.ArenaAllocator = .init(c.gpa);
    defer scratch.deinit();
    const a = scratch.allocator();
    const path = try self.target.path(a, ":macVerify");
    const body = try codec.encodeMacVerify(a, data, mac);
    const name = try self.target.name(a);
    var tries: integrity.Attempts = .{ .client = c, .what = "macVerify" };
    while (true) {
        tries.next();
        var response: std.heap.ArenaAllocator = .init(c.gpa);
        defer response.deinit();
        const answer_body = rpc.execute(c, &response, .{ .method = .POST, .path = path, .body = body }) catch |err| {
            if (err != error.IntegrityCheckFailed) return err;
            try tries.failed(integrity.request_refused);
            continue;
        };
        const answer = codec.decodeMacVerify(a, a, answer_body) catch |err|
            return rpc.decodeFailed(c, err, "macVerify");
        const problem: ?[]const u8 = if (!answer.verified_data)
            "the server did not get the data's checksum"
        else if (!answer.verified_mac)
            "the server did not get the MAC's checksum"
        else if (answer.verified_success_integrity != answer.success)
            "the answer's success and its integrity flag disagree"
        else if (!std.mem.eql(u8, answer.name, name))
            "the answer names another version"
        else
            null;
        if (problem) |reason| {
            try tries.failed(reason);
            continue;
        }
        return answer.success;
    }
}

/// The version: its state, algorithm and times.
pub fn get(self: KeyVersion) Error!types.Owned(types.VersionInfo) {
    const c = self.client;
    rpc.begin(c);
    try c.checkTarget(self.target);
    var scratch: std.heap.ArenaAllocator = .init(c.gpa);
    defer scratch.deinit();
    return self.request(scratch.allocator(), .{ .method = .GET, .path = try self.target.path(scratch.allocator(), "") });
}

/// Waits until the version is `enabled`, as a new asymmetric version is
/// after `pending_generation`, reading it under the client's backoff, and
/// answers it. A version that failed to generate or import is
/// `error.KeyVersionFailed`; one disabled, destroyed or scheduled for
/// destruction is that state's error at once; still pending after
/// `options.timeout_ms` is `error.DeadlineExceeded`. Symmetric and MAC
/// versions are enabled when made, and answer at the first read.
pub fn waitUntilEnabled(self: KeyVersion, options: types.WaitOptions) Error!types.Owned(types.VersionInfo) {
    const c = self.client;
    rpc.begin(c);
    try c.checkTarget(self.target);
    const started = std.Io.Clock.awake.now(c.io).nanoseconds;
    const budget_ns = @as(i96, options.timeout_ms) * std.time.ns_per_ms;
    var attempt: u32 = 0;
    while (true) {
        attempt += 1;
        var info = try self.get();
        const state = info.value.state;
        switch (state) {
            .enabled => return info,
            .pending_generation, .pending_import => {},
            .generation_failed, .import_failed => {
                if (c.diagnostics) |d| d.print("the version is {s}: {s}", .{ state.wire(), if (state == .generation_failed) info.value.generation_failure_reason else info.value.import_failure_reason });
                info.deinit();
                return error.KeyVersionFailed;
            },
            else => {
                if (c.diagnostics) |d| d.print("the version is {s}, and will not be enabled by waiting", .{state.wire()});
                info.deinit();
                return switch (state) {
                    .disabled => error.KeyVersionDisabled,
                    .destroy_scheduled, .destroyed => error.KeyVersionDestroyed,
                    else => error.FailedPrecondition,
                };
            },
        }
        info.deinit();
        const elapsed = std.Io.Clock.awake.now(c.io).nanoseconds - started;
        if (elapsed >= budget_ns) {
            if (c.diagnostics) |d| d.print("the version is still {s} after {d} ms", .{ state.wire(), @divTrunc(elapsed, std.time.ns_per_ms) });
            return error.DeadlineExceeded;
        }
        const wait_ms: u32 = rpc.waitMs(c, attempt) orelse c.retry.max_backoff_ms;
        const left_ms: u32 = @intCast(@min(std.math.maxInt(u32), @divTrunc(budget_ns - elapsed + std.time.ns_per_ms - 1, std.time.ns_per_ms)));
        try c.io.sleep(.fromMilliseconds(@max(1, @min(wait_ms, left_ms))), .awake);
    }
}

/// Makes a `disabled` version usable again.
pub fn enable(self: KeyVersion) Error!types.Owned(types.VersionInfo) {
    return self.setState(.enabled);
}

/// Stops the version being used, without destroying it; it is still
/// billed. Disabling is eventually consistent: the version typically stays
/// usable for up to a minute after, hours in exceptional cases.
pub fn disable(self: KeyVersion) Error!types.Owned(types.VersionInfo) {
    return self.setState(.disabled);
}

fn setState(self: KeyVersion, state: types.State) Error!types.Owned(types.VersionInfo) {
    const c = self.client;
    rpc.begin(c);
    try c.checkTarget(self.target);
    var scratch: std.heap.ArenaAllocator = .init(c.gpa);
    defer scratch.deinit();
    const a = scratch.allocator();
    return self.request(a, .{ .method = .PATCH, .path = try self.target.path(a, "?updateMask=state"), .body = try codec.encodeState(a, state) });
}

/// Schedules the version's material for destruction at the key's destroy
/// delay from now (1 to 120 days, 30 unless set at creation): it is
/// `destroy_scheduled`, unusable, still billed, and `restore` brings it
/// back until its `destroy_time`. Then it is `destroyed`, free, and can be
/// deleted. An enabled or disabled version can be destroyed.
pub fn destroy(self: KeyVersion) Error!types.Owned(types.VersionInfo) {
    return self.transition(":destroy", .destroy_scheduled);
}

/// Takes a `destroy_scheduled` version back before its destroy time: it
/// is `disabled`, and `enable` makes it usable.
pub fn restore(self: KeyVersion) Error!types.Owned(types.VersionInfo) {
    return self.transition(":restore", .disabled);
}

/// Sends `method`, which moves the version to `want`. A repeat of one that
/// landed is refused, the version no longer being in the state it left,
/// so a failure after an attempt that may have reached the server is
/// followed by a read: in `want`, the move landed and the read is its
/// answer; otherwise it goes out again, up to the retry policy's attempts.
fn transition(self: KeyVersion, method: []const u8, want: types.State) Error!types.Owned(types.VersionInfo) {
    const c = self.client;
    rpc.begin(c);
    try c.checkTarget(self.target);
    var scratch: std.heap.ArenaAllocator = .init(c.gpa);
    defer scratch.deinit();
    const a = scratch.allocator();
    const path = try self.target.path(a, method);
    const get_path = try self.target.path(a, "");
    var attempt: u32 = 0;
    var sent_before = false;
    while (true) {
        attempt += 1;
        if (self.request(a, .{ .method = .POST, .path = path, .body = "{}", .retry = false })) |moved| {
            return moved;
        } else |err| {
            const refused_as_moved = sent_before and switch (err) {
                error.FailedPrecondition, error.KeyVersionDisabled, error.KeyVersionDestroyed => true,
                else => false,
            };
            if (!core.isRetryable(err) and !refused_as_moved) return err;
            if (!refused_as_moved) {
                const delay_ms = rpc.waitMs(c, attempt) orelse return err;
                logging.warn("{s} on a key version failed with {t}; reading it in {d} ms", .{ method, err, delay_ms });
                try c.io.sleep(.fromMilliseconds(delay_ms), .awake);
            }
            sent_before = true;
            var read = self.request(a, .{ .method = .GET, .path = get_path }) catch |get_err| switch (get_err) {
                error.OutOfMemory, error.Canceled => return get_err,
                else => {
                    if (c.diagnostics) |d| d.print("{s} failed with {t}, and reading the version to see whether it landed failed with {t}", .{ method, err, get_err });
                    return err;
                },
            };
            if (read.value.state == want) {
                if (c.diagnostics) |d| d.clear();
                return read;
            }
            read.deinit();
            if (refused_as_moved or attempt >= c.retry.max_attempts) return err;
        }
    }
}

/// Deletes the version, and waits for the server to finish: one that is
/// `destroyed`, or failed to generate or import. Its number is not reused.
pub fn delete(self: KeyVersion) Error!void {
    const c = self.client;
    rpc.begin(c);
    try c.checkTarget(self.target);
    var scratch: std.heap.ArenaAllocator = .init(c.gpa);
    defer scratch.deinit();
    return operations.delete(c, try self.target.path(scratch.allocator(), ""), "a key version", .done);
}

fn request(self: KeyVersion, scratch: std.mem.Allocator, call: rpc.Call) Error!types.Owned(types.VersionInfo) {
    const c = self.client;
    var result: types.Owned(types.VersionInfo) = try .init(c.gpa);
    errdefer result.deinit();
    const body = try rpc.execute(c, result.arena, call);
    result.value = codec.decodeVersion(result.arena.allocator(), scratch, body) catch |err|
        return rpc.decodeFailed(c, err, "key version");
    return result;
}

const testing = std.testing;
const test_util = @import("test_util.zig");
const Harness = test_util.Harness;
const base = test_util.base;

const v1 = "projects/my-project/locations/us-central1/keyRings/r/cryptoKeys/k/cryptoKeyVersions/1";
fn versionIn(comptime state: []const u8) []const u8 {
    return "{\"name\":\"" ++ v1 ++ "\",\"state\":\"" ++ state ++ "\"}";
}
const fast: core.RetryPolicy = .{ .max_attempts = 3, .initial_backoff_ms = 1, .max_backoff_ms = 2 };

test "golden: enable and disable patch the state, destroy and restore post {}" {
    var h: Harness = undefined;
    try h.init(&.{
        .{ .respond = .{ .body = versionIn("ENABLED") } },
        .{ .respond = .{ .body = versionIn("DISABLED") } },
        .{ .respond = .{ .body = versionIn("DESTROY_SCHEDULED") } },
        .{ .respond = .{ .body = versionIn("DISABLED") } },
        .{ .respond = .{ .body = versionIn("DISABLED") } },
        .{ .respond = .{ .body = "{\"name\":\"projects/my-project/locations/us-central1/operations/o\",\"done\":true}" } },
    }, .{});
    defer h.deinit();
    const v = h.client.keyRing("r").key("k").version(1);
    inline for (.{ "enable", "disable", "destroy", "restore", "get" }) |name| {
        var r = try @field(KeyVersion, name)(v);
        r.deinit();
    }
    try v.delete();
    try h.expectRequest(0, .PATCH, base ++ "/keyRings/r/cryptoKeys/k/cryptoKeyVersions/1?updateMask=state", "{\"state\":\"ENABLED\"}");
    try h.expectRequest(1, .PATCH, base ++ "/keyRings/r/cryptoKeys/k/cryptoKeyVersions/1?updateMask=state", "{\"state\":\"DISABLED\"}");
    try h.expectRequest(2, .POST, base ++ "/keyRings/r/cryptoKeys/k/cryptoKeyVersions/1:destroy", "{}");
    try h.expectRequest(3, .POST, base ++ "/keyRings/r/cryptoKeys/k/cryptoKeyVersions/1:restore", "{}");
    try h.expectRequest(4, .GET, base ++ "/keyRings/r/cryptoKeys/k/cryptoKeyVersions/1", null);
    try h.expectRequest(5, .DELETE, base ++ "/keyRings/r/cryptoKeys/k/cryptoKeyVersions/1", null);
}

test "destroy: a lost answer is read back, and a repeat refused for the state it made is done" {
    var h: Harness = undefined;
    try h.init(&.{
        // Lost, and the read shows it landed.
        .{ .respond = .{ .status = 503, .body = "{}" } },
        .{ .respond = .{ .body = versionIn("DESTROY_SCHEDULED") } },
        // Lost, the read shows it did not, the repeat is refused because
        // it landed in between, and a second read shows so.
        .{ .fail = error.ConnectionResetByPeer },
        .{ .respond = .{ .body = versionIn("ENABLED") } },
        .{ .respond = .{ .status = 400, .body = "{\"error\":{\"code\":400,\"message\":\"The request cannot be fulfilled. Resource " ++ v1 ++ " has value DESTROY_SCHEDULED in field crypto_key_version.state.\",\"status\":\"FAILED_PRECONDITION\"}}" } },
        .{ .respond = .{ .body = versionIn("DESTROY_SCHEDULED") } },
    }, .{ .retry = fast });
    defer h.deinit();
    const v = h.client.keyRing("r").key("k").version(1);
    var first = try v.destroy();
    defer first.deinit();
    try testing.expectEqual(types.State.destroy_scheduled, first.value.state);
    var second = try v.destroy();
    defer second.deinit();
    try testing.expectEqual(types.State.destroy_scheduled, second.value.state);
    try h.expectRequest(4, .POST, base ++ "/keyRings/r/cryptoKeys/k/cryptoKeyVersions/1:destroy", "{}");
    try h.expectRequestCount(6);
    try testing.expectEqualStrings("", h.diag.message());
}

test "destroy: refused on the first attempt is the caller's, as is a repeat whose read says otherwise" {
    var h: Harness = undefined;
    const refused = "{\"error\":{\"code\":400,\"message\":\"The request cannot be fulfilled.\",\"status\":\"FAILED_PRECONDITION\"}}";
    try h.init(&.{
        .{ .respond = .{ .status = 400, .body = refused } },
        .{ .respond = .{ .status = 503, .body = "{}" } },
        .{ .respond = .{ .body = versionIn("ENABLED") } },
        .{ .respond = .{ .status = 400, .body = refused } },
        .{ .respond = .{ .body = versionIn("DESTROYED") } },
    }, .{ .retry = fast });
    defer h.deinit();
    const v = h.client.keyRing("r").key("k").version(1);
    try testing.expectError(error.FailedPrecondition, v.destroy());
    try testing.expectError(error.FailedPrecondition, v.destroy());
    try h.expectRequestCount(5);
}

test "destroy: a read-back that fails returns the destroy's error, and says what the read met" {
    var h: Harness = undefined;
    try h.init(&.{
        .{ .respond = .{ .status = 503, .body = "{}" } },
        .{ .respond = .{ .status = 403, .body = "{\"error\":{\"code\":403,\"status\":\"PERMISSION_DENIED\"}}" } },
    }, .{ .retry = fast });
    defer h.deinit();
    try testing.expectError(error.Unavailable, h.client.keyRing("r").key("k").version(1).destroy());
    try testing.expect(std.mem.indexOf(u8, h.diag.message(), "failed with PermissionDenied") != null);
}

test "a refusal naming the version's state is that state's error" {
    var h: Harness = undefined;
    const body = "{\"error\":{\"code\":400,\"message\":\"" ++ v1 ++ " is not enabled, current state is: DESTROYED.\",\"status\":\"FAILED_PRECONDITION\",\"details\":[{\"@type\":\"type.googleapis.com/google.rpc.PreconditionFailure\",\"violations\":[{\"subject\":\"" ++ v1 ++ "\",\"type\":\"KEY_DESTROYED\"}]}]}}";
    try h.init(&.{.{ .respond = .{ .status = 400, .body = body } }}, .{});
    defer h.deinit();
    try testing.expectError(error.KeyVersionDestroyed, h.client.keyRing("r").key("k").version(1).enable());
    try testing.expect(std.mem.indexOf(u8, h.diag.message(), v1) != null);
    try testing.expectEqualStrings("FAILED_PRECONDITION", h.diag.status());
}

test "waitUntilEnabled: a version that failed to generate says why" {
    var h: Harness = undefined;
    try h.init(&.{
        .{ .respond = .{ .body = "{\"name\":\"" ++ v1 ++ "\",\"state\":\"GENERATION_FAILED\",\"generationFailureReason\":\"the HSM said no\"}" } },
        .{ .respond = .{ .body = "{\"name\":\"" ++ v1 ++ "\",\"state\":\"IMPORT_FAILED\",\"importFailureReason\":\"bad wrapping\"}" } },
        .{ .respond = .{ .body = "{\"name\":\"" ++ v1 ++ "\",\"state\":\"EXTERNAL_DESTRUCTION_FAILED\"}" } },
    }, .{});
    defer h.deinit();
    const v = h.client.keyRing("r").key("k").version(1);
    try testing.expectError(error.KeyVersionFailed, v.waitUntilEnabled(.{}));
    try testing.expect(std.mem.indexOf(u8, h.diag.message(), "the HSM said no") != null);
    try testing.expectError(error.KeyVersionFailed, v.waitUntilEnabled(.{}));
    try testing.expect(std.mem.indexOf(u8, h.diag.message(), "bad wrapping") != null);
    try testing.expectError(error.FailedPrecondition, v.waitUntilEnabled(.{}));
    try testing.expectError(error.InvalidName, h.client.keyRing("r").key("k").version(0).waitUntilEnabled(.{}));
}

test "golden: IAM paths on a key ring and a key" {
    var h: Harness = undefined;
    try h.init(&.{
        .{ .respond = .{ .body = "{\"etag\":\"ACAB\"}" } },
        .{ .respond = .{ .body = "{\"version\":1,\"etag\":\"BwX1\"}" } },
        .{ .respond = .{ .body = "{\"permissions\":[\"cloudkms.cryptoKeys.get\"]}" } },
    }, .{});
    defer h.deinit();
    const key = h.client.keyRing("r").key("k");
    var p = try h.client.keyRing("r").iamPolicy();
    p.deinit();
    try h.expectRequest(0, .GET, base ++ "/keyRings/r:getIamPolicy?options.requestedPolicyVersion=3", null);
    var s = try key.setIamPolicy(.{ .etag = "ACAB", .bindings = &.{.{ .role = "roles/cloudkms.viewer", .members = &.{"user:a@example.com"} }} });
    s.deinit();
    try h.expectRequest(1, .POST, base ++ "/keyRings/r/cryptoKeys/k:setIamPolicy", "{\"policy\":{\"version\":1,\"etag\":\"ACAB\",\"bindings\":[{\"role\":\"roles/cloudkms.viewer\",\"members\":[\"user:a@example.com\"]}]}}");
    var t = try key.testIamPermissions(&.{"cloudkms.cryptoKeys.get"});
    t.deinit();
    try h.expectRequest(2, .POST, base ++ "/keyRings/r/cryptoKeys/k:testIamPermissions", "{\"permissions\":[\"cloudkms.cryptoKeys.get\"]}");
}

test "IAM: a policy written without an etag is sent once, and one with an etag retried" {
    var h: Harness = undefined;
    const unavailable = "{\"error\":{\"code\":503,\"status\":\"UNAVAILABLE\"}}";
    try h.init(&.{
        .{ .respond = .{ .status = 503, .body = unavailable } },
        .{ .respond = .{ .status = 503, .body = unavailable } },
        .{ .respond = .{ .body = "{\"version\":1,\"etag\":\"BwX2\"}" } },
    }, .{ .retry = .{ .max_attempts = 3, .initial_backoff_ms = 1, .max_backoff_ms = 2 } });
    defer h.deinit();
    const ring = h.client.keyRing("r");
    try testing.expectError(error.Unavailable, ring.setIamPolicy(.{ .bindings = &.{} }));
    try h.expectRequestCount(1);
    var p = try ring.setIamPolicy(.{ .etag = "BwX1", .bindings = &.{} });
    p.deinit();
    try h.expectRequestCount(3);
}

test "IAM: a grant whose write lost to another change reads and writes again" {
    var h: Harness = undefined;
    const aborted = "{\"error\":{\"code\":409,\"message\":\"There were concurrent policy changes. Please retry the whole read-modify-write with exponential backoff.\",\"status\":\"ABORTED\"}}";
    try h.init(&.{
        .{ .respond = .{ .body = "{\"etag\":\"ACAB\"}" } },
        .{ .respond = .{ .status = 409, .body = aborted } },
        .{ .respond = .{ .body = "{\"version\":1,\"etag\":\"BwX2\",\"bindings\":[{\"role\":\"roles/cloudkms.viewer\",\"members\":[\"user:b@example.com\"]}]}" } },
        .{ .respond = .{ .body = "{\"version\":1,\"etag\":\"BwX3\",\"bindings\":[{\"role\":\"roles/cloudkms.viewer\",\"members\":[\"user:b@example.com\",\"user:a@example.com\"]}]}" } },
    }, .{ .retry = .{ .max_attempts = 3, .initial_backoff_ms = 1, .max_backoff_ms = 2 } });
    defer h.deinit();
    var p = try h.client.keyRing("r").addIamBinding("roles/cloudkms.viewer", "user:a@example.com");
    defer p.deinit();
    try testing.expect(p.value.grants("roles/cloudkms.viewer", "user:a@example.com"));
    try testing.expect(p.value.grants("roles/cloudkms.viewer", "user:b@example.com"));
    try h.expectRequest(3, .POST, base ++ "/keyRings/r:setIamPolicy", "{\"policy\":{\"version\":1,\"etag\":\"BwX2\",\"bindings\":[{\"role\":\"roles/cloudkms.viewer\",\"members\":[\"user:b@example.com\",\"user:a@example.com\"]}]}}");
    try h.expectRequestCount(4);
}

test "production's keys and signatures: each family's public key read as production sent it, and its signature verified here" {
    const production = @import("production_bodies.zig");
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    for (production.signed) |entry| {
        const nist = std.mem.eql(u8, entry.algorithm, "PQ_SIGN_ML_DSA_65");
        // ML-DSA's key read as PEM; its NIST encoding is checked below.
        const answer = if (nist) production.mldsa_pem_answer else entry.public_key;
        var h: Harness = undefined;
        try h.init(&.{.{ .respond = .{ .body = answer } }}, .{});
        defer h.deinit();
        const name = (try std.json.parseFromSliceLeaky(struct { name: []const u8 }, a, answer, .{ .ignore_unknown_fields = true })).name;
        const parsed = core.names.KmsKeyName.parse(name).?;
        const v: KeyVersion = .{ .client = &h.client, .target = .{ .project = parsed.project, .location = parsed.location, .key_ring = parsed.key_ring, .key = parsed.key, .version = 1 } };
        var pk = try v.publicKey();
        defer pk.deinit();
        try testing.expectEqualStrings(entry.algorithm, pk.value.algorithm.wire());
        const signature = try core.base64.decode(a, entry.signature_b64);
        pk.value.verify("the message", signature) catch |err| {
            std.debug.print("{s}: {t}\n", .{ entry.algorithm, err });
            return err;
        };
        try testing.expectError(error.SignatureInvalid, pk.value.verify("the messagE", signature));
        if (nist) {
            const raw_answer = try codec.decodePublicKey(a, a, entry.public_key);
            const raw: types.PublicKey = .{ .name = name, .algorithm = .pq_sign_ml_dsa_65, .raw = raw_answer.data };
            try raw.verify("the message", signature);
        }
    }
    // With no format asked, production put the PEM in `pem`.
    const no_format = try codec.decodePublicKey(a, a, production.ec_no_format_answer);
    try testing.expect(std.mem.startsWith(u8, no_format.pem, "-----BEGIN PUBLIC KEY-----"));
    try testing.expect(integrity.matches(no_format.pem, no_format.pem_crc32c));
}

test "version 0 is InvalidName, and nothing goes out" {
    var h: Harness = undefined;
    try h.init(&.{}, .{});
    defer h.deinit();
    const v = h.client.keyRing("r").key("k").version(0);
    try testing.expectError(error.InvalidName, v.get());
    try testing.expectError(error.InvalidName, v.destroy());
    try testing.expectError(error.InvalidName, v.delete());
    try h.expectRequestCount(0);
}

// Checksums the tests below write out, held to core.crc32c by the first.
const crc_sig = "749997639"; // "sig!"
const crc_mac = "2164953591"; // "mac!"
const crc_pem = "705884274"; // "PEMTEXT"

test "the checksums these tests write out are core.crc32c's" {
    try testing.expect(integrity.matches("sig!", 749997639));
    try testing.expect(integrity.matches("mac!", 2164953591));
    try testing.expect(integrity.matches("PEMTEXT", 705884274));
    try testing.expect(integrity.matches("msg", 2067356545));
}

fn signAnswer(comptime flag: []const u8, comptime crc: []const u8, comptime name: []const u8) []const u8 {
    return "{\"name\":\"" ++ name ++ "\",\"signature\":\"c2lnIQ==\",\"signatureCrc32c\":\"" ++ crc ++ "\"" ++ flag ++ ",\"protectionLevel\":\"SOFTWARE\"}";
}

test "golden: sign hashes for a digest algorithm and sends data for the others" {
    var h: Harness = undefined;
    try h.init(&.{
        .{ .respond = .{ .body = signAnswer(",\"verifiedDigestCrc32c\":true", crc_sig, v1) } },
        .{ .respond = .{ .body = signAnswer(",\"verifiedDataCrc32c\":true", crc_sig, v1) } },
        .{ .respond = .{ .body = signAnswer(",\"verifiedDigestCrc32c\":true", crc_sig, v1) } },
    }, .{});
    defer h.deinit();
    const v = h.client.keyRing("r").key("k").version(1);
    var ec = try v.sign(.ec_sign_p256_sha256, "msg");
    defer ec.deinit();
    try testing.expectEqualStrings("sig!", ec.value);
    try h.expectRequest(0, .POST, base ++ "/keyRings/r/cryptoKeys/k/cryptoKeyVersions/1:asymmetricSign", "{\"digest\":{\"sha256\":\"5GsyAWXuyR5jRPoQNA1bMggwTWytKdDVrtGEZtHZ2A4=\"},\"digestCrc32c\":\"3911430446\"}");
    var ed = try v.sign(.ec_sign_ed25519, "msg");
    defer ed.deinit();
    try h.expectRequest(1, .POST, base ++ "/keyRings/r/cryptoKeys/k/cryptoKeyVersions/1:asymmetricSign", "{\"data\":\"bXNn\",\"dataCrc32c\":\"2067356545\"}");
    var digest: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash("msg", &digest, .{});
    var pre = try v.signDigest(.rsa_sign_pss_2048_sha256, &digest);
    defer pre.deinit();
    try h.expectRequest(2, .POST, base ++ "/keyRings/r/cryptoKeys/k/cryptoKeyVersions/1:asymmetricSign", "{\"digest\":{\"sha256\":\"5GsyAWXuyR5jRPoQNA1bMggwTWytKdDVrtGEZtHZ2A4=\"},\"digestCrc32c\":\"3911430446\"}");
}

test "sign: what this library will not send is refused before sending" {
    var h: Harness = undefined;
    try h.init(&.{}, .{});
    defer h.deinit();
    const v = h.client.keyRing("r").key("k").version(1);
    try testing.expectError(error.InvalidOptions, v.sign(.google_symmetric_encryption, "m"));
    try testing.expectError(error.InvalidOptions, v.sign(.rsa_sign_raw_pkcs1_2048, "m"));
    try testing.expectError(error.InvalidOptions, v.sign(.pq_sign_ml_dsa_65_external_mu, "m"));
    try testing.expectError(error.InvalidOptions, v.signDigest(.ec_sign_ed25519, "0123456789abcdef0123456789abcdef"));
    try testing.expect(std.mem.indexOf(u8, h.diag.message(), "use sign") != null);
    try testing.expectError(error.InvalidDigest, v.signDigest(.ec_sign_p384_sha384, "0123456789abcdef0123456789abcdef"));
    try testing.expect(std.mem.indexOf(u8, h.diag.message(), "sha384 digest of 48 bytes") != null);
    const big = try testing.allocator.alloc(u8, 64 * 1024 + 1);
    defer testing.allocator.free(big);
    @memset(big, 0);
    try testing.expectError(error.TooLarge, v.sign(.ec_sign_ed25519, big));
    // A message of any size signs by its digest.
    try testing.expectError(error.InvalidName, h.client.keyRing("r").key("k").version(0).sign(.ec_sign_p256_sha256, big));
    try h.expectRequestCount(0);
}

test "sign: each failed check is tried again, and past the attempts is IntegrityCheckFailed" {
    const cases = [_]struct { []const u8, []const u8 }{
        .{ signAnswer("", crc_sig, v1), "did not get the checksum" },
        .{ signAnswer(",\"verifiedDataCrc32c\":true", crc_sig, v1), "did not get the checksum" },
        .{ signAnswer(",\"verifiedDigestCrc32c\":true", "1", v1), "signature does not match" },
        .{ signAnswer(",\"verifiedDigestCrc32c\":true", crc_sig, v1 ++ "0"), "names another version" },
    };
    for (cases) |case| {
        var h: Harness = undefined;
        try h.init(&.{
            .{ .respond = .{ .body = case[0] } },
            .{ .respond = .{ .body = case[0] } },
        }, .{ .retry = .{ .max_attempts = 2, .initial_backoff_ms = 1, .max_backoff_ms = 2 } });
        defer h.deinit();
        try testing.expectError(error.IntegrityCheckFailed, h.client.keyRing("r").key("k").version(1).sign(.ec_sign_p256_sha256, "m"));
        try testing.expect(std.mem.indexOf(u8, h.diag.message(), case[1]) != null);
        try h.expectRequestCount(2);
    }
}

test "golden: publicKey asks for PEM, and for the NIST encoding when the server says that is all it has" {
    var h: Harness = undefined;
    const nist_only = "{\"error\":{\"code\":400,\"message\":\"Only NIST_PQC format is supported for this algorithm.\",\"status\":\"INVALID_ARGUMENT\"}}";
    try h.init(&.{
        .{ .respond = .{ .body = "{\"pem\":\"PEMTEXT\",\"pemCrc32c\":\"" ++ crc_pem ++ "\",\"algorithm\":\"EC_SIGN_P256_SHA256\",\"name\":\"" ++ v1 ++ "\",\"protectionLevel\":\"SOFTWARE\",\"publicKey\":{\"data\":\"UEVNVEVYVA==\",\"crc32cChecksum\":\"" ++ crc_pem ++ "\"}}" } },
        .{ .respond = .{ .status = 400, .body = nist_only } },
        .{ .respond = .{ .body = "{\"algorithm\":\"PQ_SIGN_ML_DSA_65\",\"name\":\"" ++ v1 ++ "\",\"publicKeyFormat\":\"NIST_PQC\",\"publicKey\":{\"data\":\"UEVNVEVYVA==\",\"crc32cChecksum\":\"" ++ crc_pem ++ "\"}}" } },
    }, .{});
    defer h.deinit();
    const v = h.client.keyRing("r").key("k").version(1);
    var ec = try v.publicKey();
    defer ec.deinit();
    try h.expectRequest(0, .GET, base ++ "/keyRings/r/cryptoKeys/k/cryptoKeyVersions/1/publicKey?publicKeyFormat=PEM", null);
    try testing.expectEqualStrings("PEMTEXT", ec.value.pem);
    try testing.expectEqualStrings("", ec.value.raw);
    try testing.expectEqual(types.Algorithm.ec_sign_p256_sha256, ec.value.algorithm);
    try testing.expectEqualStrings(v1, ec.value.name);
    var pq = try v.publicKey();
    defer pq.deinit();
    try h.expectRequest(2, .GET, base ++ "/keyRings/r/cryptoKeys/k/cryptoKeyVersions/1/publicKey?publicKeyFormat=NIST_PQC", null);
    try testing.expectEqualStrings("PEMTEXT", pq.value.raw);
    try testing.expectEqualStrings("", pq.value.pem);
}

test "publicKey: the NIST encoding is asked for by the server's words, with no Diagnostics to keep them" {
    var h: Harness = undefined;
    try h.init(&.{
        .{ .respond = .{ .status = 400, .body = "{\"error\":{\"code\":400,\"message\":\"Only NIST_PQC format is supported.\",\"status\":\"INVALID_ARGUMENT\"}}" } },
        // A PEM beside the NIST encoding is not the key's: it is left out.
        .{ .respond = .{ .body = "{\"pem\":\"PEMTEXT\",\"pemCrc32c\":\"" ++ crc_pem ++ "\",\"algorithm\":\"PQ_SIGN_ML_DSA_44\",\"publicKey\":{\"data\":\"UEVNVEVYVA==\",\"crc32cChecksum\":\"" ++ crc_pem ++ "\"}}" } },
    }, .{});
    defer h.deinit();
    h.client.diagnostics = null;
    var pq = try h.client.keyRing("r").key("k").version(1).publicKey();
    defer pq.deinit();
    try testing.expectEqualStrings("PEMTEXT", pq.value.raw);
    try testing.expectEqualStrings("", pq.value.pem);
}

test "publicKey: each failed check is tried again, and past the attempts is IntegrityCheckFailed" {
    const cases = [_]struct { []const u8, []const u8 }{
        .{ "{\"algorithm\":\"EC_SIGN_P256_SHA256\"}", "holds no key" },
        .{ "{\"pem\":\"PEMTEXT\",\"pemCrc32c\":\"1\",\"algorithm\":\"EC_SIGN_P256_SHA256\"}", "PEM does not match" },
        .{ "{\"pem\":\"PEMTEXT\",\"algorithm\":\"EC_SIGN_P256_SHA256\"}", "PEM does not match" },
        .{ "{\"pem\":\"PEMTEXT\",\"pemCrc32c\":\"" ++ crc_pem ++ "\",\"algorithm\":\"EC_SIGN_P256_SHA256\",\"publicKey\":{\"data\":\"UEVNVEVYVA==\",\"crc32cChecksum\":\"2\"}}", "key does not match" },
        .{ "{\"pem\":\"PEMTEXT\",\"pemCrc32c\":\"" ++ crc_pem ++ "\",\"algorithm\":\"EC_SIGN_P256_SHA256\",\"name\":\"" ++ v1 ++ "9\"}", "names another version" },
    };
    for (cases) |case| {
        var h: Harness = undefined;
        try h.init(&.{ .{ .respond = .{ .body = case[0] } }, .{ .respond = .{ .body = case[0] } } }, .{ .retry = .{ .max_attempts = 2, .initial_backoff_ms = 1, .max_backoff_ms = 2 } });
        defer h.deinit();
        try testing.expectError(error.IntegrityCheckFailed, h.client.keyRing("r").key("k").version(1).publicKey());
        try testing.expect(std.mem.indexOf(u8, h.diag.message(), case[1]) != null);
    }
    // A refusal that is not about the format is the caller's at once.
    var h: Harness = undefined;
    try h.init(&.{.{ .respond = .{ .status = 400, .body = "{\"error\":{\"code\":400,\"message\":\"no\",\"status\":\"INVALID_ARGUMENT\"}}" } }}, .{});
    defer h.deinit();
    try testing.expectError(error.InvalidArgument, h.client.keyRing("r").key("k").version(1).publicKey());
    try h.expectRequestCount(1);
}

test "golden: macSign and macVerify, a MAC that does not match being false" {
    var h: Harness = undefined;
    try h.init(&.{
        .{ .respond = .{ .body = "{\"name\":\"" ++ v1 ++ "\",\"mac\":\"bWFjIQ==\",\"macCrc32c\":\"" ++ crc_mac ++ "\",\"verifiedDataCrc32c\":true}" } },
        .{ .respond = .{ .body = "{\"name\":\"" ++ v1 ++ "\",\"success\":true,\"verifiedDataCrc32c\":true,\"verifiedMacCrc32c\":true,\"verifiedSuccessIntegrity\":true}" } },
        .{ .respond = .{ .body = "{\"name\":\"" ++ v1 ++ "\",\"verifiedDataCrc32c\":true,\"verifiedMacCrc32c\":true}" } },
    }, .{});
    defer h.deinit();
    const v = h.client.keyRing("r").key("k").version(1);
    var m = try v.macSign("data");
    defer m.deinit();
    try testing.expectEqualStrings("mac!", m.value);
    try h.expectRequest(0, .POST, base ++ "/keyRings/r/cryptoKeys/k/cryptoKeyVersions/1:macSign", "{\"data\":\"ZGF0YQ==\",\"dataCrc32c\":\"2933423569\"}");
    try testing.expect(try v.macVerify("data", "mac!"));
    try h.expectRequest(1, .POST, base ++ "/keyRings/r/cryptoKeys/k/cryptoKeyVersions/1:macVerify", "{\"data\":\"ZGF0YQ==\",\"dataCrc32c\":\"2933423569\",\"mac\":\"bWFjIQ==\",\"macCrc32c\":\"" ++ crc_mac ++ "\"}");
    try testing.expect(!try v.macVerify("data", "mac!"));
}

test "macSign and macVerify: each failed check is tried again, and past the attempts is IntegrityCheckFailed" {
    const sign_cases = [_]struct { []const u8, []const u8 }{
        .{ "{\"name\":\"" ++ v1 ++ "\",\"mac\":\"bWFjIQ==\",\"macCrc32c\":\"" ++ crc_mac ++ "\"}", "did not get the data's checksum" },
        .{ "{\"name\":\"" ++ v1 ++ "\",\"mac\":\"bWFjIQ==\",\"macCrc32c\":\"3\",\"verifiedDataCrc32c\":true}", "MAC does not match" },
        .{ "{\"name\":\"" ++ v1 ++ "1\",\"mac\":\"bWFjIQ==\",\"macCrc32c\":\"" ++ crc_mac ++ "\",\"verifiedDataCrc32c\":true}", "names another version" },
    };
    const verify_cases = [_]struct { []const u8, []const u8 }{
        .{ "{\"name\":\"" ++ v1 ++ "\",\"success\":true,\"verifiedMacCrc32c\":true,\"verifiedSuccessIntegrity\":true}", "did not get the data's checksum" },
        .{ "{\"name\":\"" ++ v1 ++ "\",\"success\":true,\"verifiedDataCrc32c\":true,\"verifiedSuccessIntegrity\":true}", "did not get the MAC's checksum" },
        .{ "{\"name\":\"" ++ v1 ++ "\",\"success\":true,\"verifiedDataCrc32c\":true,\"verifiedMacCrc32c\":true}", "success and its integrity flag disagree" },
        .{ "{\"name\":\"" ++ v1 ++ "\",\"verifiedDataCrc32c\":true,\"verifiedMacCrc32c\":true,\"verifiedSuccessIntegrity\":true}", "success and its integrity flag disagree" },
        .{ "{\"name\":\"other\",\"verifiedDataCrc32c\":true,\"verifiedMacCrc32c\":true}", "names another version" },
    };
    for (sign_cases) |case| {
        var h: Harness = undefined;
        try h.init(&.{ .{ .respond = .{ .body = case[0] } }, .{ .respond = .{ .body = case[0] } } }, .{ .retry = .{ .max_attempts = 2, .initial_backoff_ms = 1, .max_backoff_ms = 2 } });
        defer h.deinit();
        try testing.expectError(error.IntegrityCheckFailed, h.client.keyRing("r").key("k").version(1).macSign("data"));
        try testing.expect(std.mem.indexOf(u8, h.diag.message(), case[1]) != null);
    }
    for (verify_cases) |case| {
        var h: Harness = undefined;
        try h.init(&.{ .{ .respond = .{ .body = case[0] } }, .{ .respond = .{ .body = case[0] } } }, .{ .retry = .{ .max_attempts = 2, .initial_backoff_ms = 1, .max_backoff_ms = 2 } });
        defer h.deinit();
        try testing.expectError(error.IntegrityCheckFailed, h.client.keyRing("r").key("k").version(1).macVerify("data", "mac!"));
        try testing.expect(std.mem.indexOf(u8, h.diag.message(), case[1]) != null);
    }
}
