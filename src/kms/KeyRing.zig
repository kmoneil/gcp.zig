//! A key ring: a name, in one location, for the keys made in it. Key rings
//! cost nothing and cannot move. A handle makes no call until asked.

const KeyRing = @This();

const std = @import("std");
const core = @import("core");
const Client = @import("Client.zig");
const codec = @import("codec.zig");
const Key = @import("Key.zig");
const names = @import("names.zig");
const operations = @import("operations.zig");
const rpc = @import("rpc.zig");
const types = @import("types.zig");
const Error = @import("errors.zig").Error;

client: *Client,
/// The project, location and key ring; the key and version unset.
target: names.Target,

/// The key ring's id.
pub fn id(self: KeyRing) []const u8 {
    return self.target.key_ring.?;
}

/// Creates the key ring. An id already taken in the location is
/// `error.AlreadyExists`, and one whose key ring was deleted in the last
/// 5 to 10 minutes may be too. A create whose answer was lost is read back
/// rather than sent again.
pub fn create(self: KeyRing) Error!types.Owned(types.KeyRingInfo) {
    const c = self.client;
    rpc.begin(c);
    try c.checkTarget(self.target);
    var scratch: std.heap.ArenaAllocator = .init(c.gpa);
    defer scratch.deinit();
    const a = scratch.allocator();
    var w: std.Io.Writer.Allocating = .init(a);
    self.target.parent().writePath(&w.writer, "/keyRings") catch return error.OutOfMemory;
    var params: core.query.Params = .init(&w.writer);
    params.add("keyRingId", self.id()) catch return error.OutOfMemory;
    const get_path = try self.target.path(a, "");

    var result: types.Owned(types.KeyRingInfo) = try .init(c.gpa);
    errdefer result.deinit();
    const body = try rpc.createOnce(c, result.arena, .{ .method = .POST, .path = w.written(), .body = "{}" }, get_path, "a key ring");
    result.value = codec.decodeKeyRing(result.arena.allocator(), a, body) catch |err|
        return rpc.decodeFailed(c, err, "key ring");
    return result;
}

/// The key ring: its name and creation time. `error.NotFound` when there
/// is none.
pub fn get(self: KeyRing) Error!types.Owned(types.KeyRingInfo) {
    const c = self.client;
    rpc.begin(c);
    try c.checkTarget(self.target);
    var scratch: std.heap.ArenaAllocator = .init(c.gpa);
    defer scratch.deinit();
    var result: types.Owned(types.KeyRingInfo) = try .init(c.gpa);
    errdefer result.deinit();
    const body = try rpc.execute(c, result.arena, .{ .method = .GET, .path = try self.target.path(scratch.allocator(), "") });
    result.value = codec.decodeKeyRing(result.arena.allocator(), scratch.allocator(), body) catch |err|
        return rpc.decodeFailed(c, err, "key ring");
    return result;
}

/// Deletes the key ring, and waits for the server to finish. Every key in
/// it must be deleted first, and every import job expired (they expire
/// three days after they are made). Its id is free again after 5 to 10
/// minutes.
pub fn delete(self: KeyRing) Error!void {
    const c = self.client;
    rpc.begin(c);
    try c.checkTarget(self.target);
    var scratch: std.heap.ArenaAllocator = .init(c.gpa);
    defer scratch.deinit();
    return operations.delete(c, try self.target.path(scratch.allocator(), ""), "a key ring");
}

/// A handle on the key `key_id` in this key ring. Makes no call; `key_id`
/// is borrowed for as long as the handle is used.
pub fn key(self: KeyRing, key_id: []const u8) Key {
    var target = self.target;
    target.key = key_id;
    return .{ .client = self.client, .target = target };
}

/// One page of the keys in this key ring.
pub fn listKeys(self: KeyRing, options: types.ListOptions) Error!types.Owned(types.KeyPage) {
    const c = self.client;
    rpc.begin(c);
    try c.checkTarget(self.target);
    var scratch: std.heap.ArenaAllocator = .init(c.gpa);
    defer scratch.deinit();
    const path = try c.listPath(scratch.allocator(), self.target, "/cryptoKeys", options);
    var result: types.Owned(types.KeyPage) = try .init(c.gpa);
    errdefer result.deinit();
    const body = try rpc.execute(c, result.arena, .{ .method = .GET, .path = path });
    result.value = codec.decodeKeyPage(result.arena.allocator(), scratch.allocator(), body) catch |err|
        return rpc.decodeFailed(c, err, "key list");
    return result;
}

const testing = std.testing;
const test_util = @import("test_util.zig");
const Harness = test_util.Harness;
const base = test_util.base;

const ring_body = "{\"name\":\"projects/my-project/locations/us-central1/keyRings/r\",\"createTime\":\"2026-10-18T09:46:40Z\"}";
const fast: core.RetryPolicy = .{ .max_attempts = 3, .initial_backoff_ms = 1, .max_backoff_ms = 2 };

test "golden: create posts {} with the id in the query, get and delete name the ring" {
    var h: Harness = undefined;
    try h.init(&.{
        .{ .respond = .{ .body = ring_body } },
        .{ .respond = .{ .body = ring_body } },
        .{ .respond = .{ .body = "{\"name\":\"projects/my-project/locations/us-central1/operations/o1\",\"done\":true}" } },
    }, .{});
    defer h.deinit();
    const ring = h.client.keyRing("r");
    var created = try ring.create();
    defer created.deinit();
    try testing.expectEqualStrings("projects/my-project/locations/us-central1/keyRings/r", created.value.name);
    try h.expectRequest(0, .POST, base ++ "/keyRings?keyRingId=r", "{}");
    var got = try ring.get();
    defer got.deinit();
    try h.expectRequest(1, .GET, base ++ "/keyRings/r", null);
    try ring.delete();
    try h.expectRequest(2, .DELETE, base ++ "/keyRings/r", null);
    try h.expectRequestCount(3);
}

test "create: an answer lost to a retryable failure is read back, not sent again" {
    var h: Harness = undefined;
    try h.init(&.{
        .{ .respond = .{ .status = 503, .body = "{\"error\":{\"code\":503,\"status\":\"UNAVAILABLE\"}}" } },
        .{ .respond = .{ .body = ring_body } },
    }, .{ .retry = fast });
    defer h.deinit();
    var created = try h.client.keyRing("r").create();
    defer created.deinit();
    try h.expectRequest(1, .GET, base ++ "/keyRings/r", null);
    try h.expectRequestCount(2);
    try testing.expectEqualStrings("", h.diag.message());
}

test "create: a read-back that finds nothing sends the create again" {
    var h: Harness = undefined;
    try h.init(&.{
        .{ .fail = error.ConnectionResetByPeer },
        .{ .respond = .{ .status = 404, .body = "{\"error\":{\"code\":404,\"status\":\"NOT_FOUND\"}}" } },
        .{ .respond = .{ .body = ring_body } },
    }, .{ .retry = fast });
    defer h.deinit();
    var created = try h.client.keyRing("r").create();
    defer created.deinit();
    try h.expectRequest(2, .POST, base ++ "/keyRings?keyRingId=r", "{}");
    try h.expectRequestCount(3);
}

test "create: ALREADY_EXISTS on the first attempt is the caller's, and a failed read-back says it may exist" {
    var h: Harness = undefined;
    try h.init(&.{
        .{ .respond = .{ .status = 409, .body = "{\"error\":{\"code\":409,\"message\":\"KeyRing projects/my-project/locations/us-central1/keyRings/r already exists.\",\"status\":\"ALREADY_EXISTS\"}}" } },
        .{ .respond = .{ .status = 503, .body = "{}" } },
        .{ .respond = .{ .status = 403, .body = "{\"error\":{\"code\":403,\"status\":\"PERMISSION_DENIED\"}}" } },
    }, .{ .retry = fast });
    defer h.deinit();
    try testing.expectError(error.AlreadyExists, h.client.keyRing("r").create());
    try testing.expectError(error.Unavailable, h.client.keyRing("r").create());
    try testing.expect(std.mem.indexOf(u8, h.diag.message(), "it may exist") != null);
    try h.expectRequestCount(3);
}

test "create: retries end with the policy's attempts" {
    var h: Harness = undefined;
    try h.init(&.{
        .{ .respond = .{ .status = 503, .body = "{}" } },
        .{ .respond = .{ .status = 404, .body = "{}" } },
        .{ .respond = .{ .status = 503, .body = "{}" } },
        .{ .respond = .{ .status = 404, .body = "{}" } },
    }, .{ .retry = .{ .max_attempts = 2, .initial_backoff_ms = 1, .max_backoff_ms = 2 } });
    defer h.deinit();
    try testing.expectError(error.Unavailable, h.client.keyRing("r").create());
    try h.expectRequestCount(4);
}

test "an id this client will not send is InvalidName, and nothing goes out" {
    var h: Harness = undefined;
    try h.init(&.{}, .{});
    defer h.deinit();
    for ([_][]const u8{ "", "a/b", "a b", test_util.repeat("a", 64) }) |bad| {
        const ring = h.client.keyRing(bad);
        try testing.expectError(error.InvalidName, ring.create());
        try testing.expectError(error.InvalidName, ring.get());
        try testing.expectError(error.InvalidName, ring.delete());
        try testing.expectError(error.InvalidName, ring.listKeys(.{}));
        try testing.expectError(error.InvalidName, ring.key("k").get());
    }
    try testing.expectError(error.InvalidName, h.client.keyRing("r").key("a.b").get());
    try h.expectRequestCount(0);
}

test "golden: listKeys sends its options as parameters" {
    var h: Harness = undefined;
    try h.init(&.{.{ .respond = .{ .body = "{\"cryptoKeys\":[{\"name\":\"projects/my-project/locations/us-central1/keyRings/r/cryptoKeys/k\",\"purpose\":\"MAC\"}],\"nextPageToken\":\"t2\"}" } }}, .{});
    defer h.deinit();
    var page = try h.client.keyRing("r").listKeys(.{ .page_size = 10, .page_token = "t1", .filter = "labels.team=alpha", .order_by = "name desc" });
    defer page.deinit();
    try h.expectRequest(0, .GET, base ++ "/keyRings/r/cryptoKeys?pageSize=10&pageToken=t1&filter=labels.team%3Dalpha&orderBy=name%20desc", null);
    try testing.expectEqual(types.Purpose.mac, page.value.keys[0].purpose);
    try testing.expectEqualStrings("t2", page.value.next_page_token.?);
}
