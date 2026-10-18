//! A key version: the key material itself, numbered from 1, and its
//! state. A handle makes no call until asked.

const KeyVersion = @This();

const std = @import("std");
const core = @import("core");
const Client = @import("Client.zig");
const codec = @import("codec.zig");
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

/// The version: its state, algorithm and times.
pub fn get(self: KeyVersion) Error!types.Owned(types.VersionInfo) {
    const c = self.client;
    rpc.begin(c);
    try c.checkTarget(self.target);
    var scratch: std.heap.ArenaAllocator = .init(c.gpa);
    defer scratch.deinit();
    return self.request(scratch.allocator(), .{ .method = .GET, .path = try self.target.path(scratch.allocator(), "") });
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
    return operations.delete(c, try self.target.path(scratch.allocator(), ""), "a key version");
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
