//! Moves: `objects.move`, which renames an object within its bucket in one
//! atomic step. As measured in production on 2026-10-24:
//!
//! - It works in flat buckets and hierarchical ones alike, and makes a
//!   hierarchical bucket's missing folders on the way.
//! - The destination is a new generation at metageneration 1, carrying the
//!   source's content type and the other content fields, its custom time,
//!   metadata, checksums, owner and access control list. The source
//!   leaves nothing behind, not even a noncurrent version in a versioned
//!   bucket; a destination it replaces becomes noncurrent there.
//! - A failed `Match` condition, on the source or the destination, is 412
//!   in one message for both; a `NotMatch` that hits is 304 with no body.
//! - A `Match` and a `NotMatch` on one field are 409, and a move onto its
//!   own name is 400: both are refused here before sending.
//! - A repeat under the same idempotency token answers the first result.
//!
//! Retries. A move pinned to its source's generation can never move a
//! second object, so it retries like any write made safe by a condition;
//! one that is not pinned retries only within the idempotency token's
//! window, or as `Options.retry_unconditional_writes` allows. The first
//! attempt goes alone, so a repeat that then meets 404 or 412 is known to
//! follow an attempt whose answer was lost: it may have met that attempt's
//! own move, after Cloud Storage forgot the token. For a pinned move, the
//! source's name says which. Still at the pinned generation, the move
//! never happened and the failure stands. Empty, it happened, and the
//! destination is read and answered. Holding another generation, nothing
//! tells: the failure stands, and its message says the move may have
//! happened. An unpinned move's repeat is never settled, and says so too.
//!
//! An emulator has no `objects.move`: fake-gcs-server takes the path for
//! an object's and answers 404. There both ends are read and the
//! conditions judged here, since fake-gcs-server enforces none on a copy;
//! then the source is copied at the generation read and deleted at it.
//! That is not atomic, and a warning says so, but code tested against the
//! emulator runs, and is answered as production would answer it.

const std = @import("std");
const core = @import("core");

const Client = @import("Client.zig");
const Object = @import("Object.zig");
const codec = @import("codec.zig");
const idempotency = @import("idempotency.zig");
const logging = @import("logging.zig");
const names = @import("names.zig");
const rpc = @import("rpc.zig");
const types = @import("types.zig");
const Error = @import("errors.zig").Error;

/// Refuses what Cloud Storage refuses for any object: one name for both
/// ends (400), and a `Match` beside a `NotMatch` on one field (409). Says
/// why in `diag`.
pub fn check(
    diag: ?*core.Diagnostics,
    source: []const u8,
    destination: []const u8,
    options: types.MoveOptions,
) error{InvalidArgument}!void {
    if (std.mem.eql(u8, source, destination)) {
        if (diag) |d| d.print("the source and the destination are one name, which Cloud Storage refuses", .{});
        return error.InvalidArgument;
    }
    const pairs = [_]struct { []const u8, ?u64, ?u64 }{
        .{ "if_source_generation", options.if_source_generation_match, options.if_source_generation_not_match },
        .{ "if_source_metageneration", options.if_source_metageneration_match, options.if_source_metageneration_not_match },
        .{ "preconditions.if_generation", options.preconditions.if_generation_match, options.preconditions.if_generation_not_match },
        .{ "preconditions.if_metageneration", options.preconditions.if_metageneration_match, options.preconditions.if_metageneration_not_match },
    };
    for (pairs) |pair| if (pair[1] != null and pair[2] != null) {
        if (diag) |d| d.print("{s}_match and {s}_not_match together, which Cloud Storage refuses as conflicting", .{ pair[0], pair[0] });
        return error.InvalidArgument;
    };
}

/// Moves `source` to `destination` in `bucket`. The caller has begun the
/// call and checked both names and `options`.
pub fn move(
    client: *Client,
    bucket: []const u8,
    source: []const u8,
    destination: []const u8,
    options: types.MoveOptions,
) Error!types.Owned(types.ObjectInfo) {
    if (client.unauthenticated and !client.multipart_test.on_emulator) {
        return emulated(client, bucket, source, destination, options);
    }
    var scratch: std.heap.ArenaAllocator = .init(client.gpa);
    defer scratch.deinit();
    const path = try names.movePath(scratch.allocator(), bucket, source, destination, options);
    var token: idempotency.Token = undefined;
    token.init(client);
    const pinned = options.if_source_generation_match;
    const retry = idempotency.writeRetry(client, pinned != null or client.retry_unconditional_writes);
    var result: types.Owned(types.ObjectInfo) = try .init(client.gpa);
    var repeated = false;
    const body = send(client, result.arena, path, token.slice(), retry, source, &repeated) catch |err| {
        result.deinit();
        if (repeated and (err == error.NotFound or err == error.FailedPrecondition)) {
            const generation = pinned orelse return mayHaveMoved(client, err);
            return settle(client, bucket, source, destination, generation, err);
        }
        return err;
    };
    errdefer result.deinit();
    result.value = codec.decodeObject(result.arena.allocator(), body) catch |err|
        return rpc.decodeFailed(client, err, "move");
    return result;
}

/// Sends the move: its first attempt alone, then, after a failure worth
/// another, the attempts left under the same token. `repeated` says
/// whether the failure returned came from a repeat.
fn send(
    client: *Client,
    response: *std.heap.ArenaAllocator,
    path: []const u8,
    headers: []const core.transport.Header,
    retry: idempotency.Retry,
    source: []const u8,
    repeated: *bool,
) Error![]const u8 {
    const call: rpc.Call = .{ .method = .POST, .path = path, .headers = headers, .retry = false };
    const started = std.Io.Clock.awake.now(client.io);
    return rpc.execute(client, response, call) catch |first| {
        if (!retry.retry or !core.isRetryable(first) or client.retry.max_attempts < 2) return first;
        const delay_ms = rpc.waitMs(client, 1, client.server_delay_ms) orelse return first;
        var again = call;
        again.retry = true;
        // The window runs from the first attempt, as the engine's would.
        if (retry.window_ms) |window| {
            const elapsed = started.durationTo(std.Io.Clock.awake.now(client.io)).toMilliseconds();
            const used = @as(i64, elapsed) + delay_ms;
            if (used > window) return first;
            again.retry_window_ms = @intCast(window - used);
        }
        // The attempts left, the first one spent.
        var rest = client.*;
        rest.retry.max_attempts -= 1;
        logging.debug("{s}: the move failed with {t}; repeating it in {d} ms", .{ source, first, delay_ms });
        try client.io.sleep(.fromMilliseconds(delay_ms), .awake);
        repeated.* = true;
        return rpc.execute(&rest, response, again);
    };
}

/// A pinned move repeated after a lost answer, that met 404 or 412: the
/// source's name tells whether the earlier attempt moved it. Its live
/// object is read, not the generation pinned: in a bucket without
/// versions, an object written over the source takes that generation away
/// too, and the move never happened.
fn settle(
    client: *Client,
    bucket: []const u8,
    source: []const u8,
    destination: []const u8,
    generation: u64,
    err: Error,
) Error!types.Owned(types.ObjectInfo) {
    const saved: ?core.Diagnostics = if (client.diagnostics) |d| d.* else null;
    const from: Object = .{ .client = client, .bucket = bucket, .name = source };
    const state: enum { there, gone, unknown } = state: {
        var live = from.get(.{}) catch |read_err| switch (read_err) {
            error.NotFound => break :state .gone,
            else => break :state .unknown,
        };
        defer live.deinit();
        break :state if (live.value.generation == generation) .there else .unknown;
    };
    if (state == .gone) {
        logging.debug("{s}: the source is gone; the move landed on an earlier attempt, whose answer was lost", .{source});
        const to: Object = .{ .client = client, .bucket = bucket, .name = destination };
        if (to.get(.{})) |info| return info else |read_err| if (read_err != error.NotFound) return read_err;
    }
    if (client.diagnostics) |d| d.* = saved.?;
    return if (state == .unknown) mayHaveMoved(client, err) else err;
}

/// A repeat's 404 or 412 that nothing settled: says the attempt whose
/// answer was lost may have moved the object, keeping the status.
fn mayHaveMoved(client: *Client, err: Error) Error {
    const d = client.diagnostics orelse return err;
    var status_buf: [core.Diagnostics.max_status_len]u8 = undefined;
    const status_text = d.status();
    @memcpy(status_buf[0..status_text.len], status_text);
    d.set(d.http_status, status_buf[0..status_text.len], "the move was repeated after an attempt whose answer was lost, and that attempt may have moved the object: read the destination to tell");
    return err;
}

/// An emulator's move: read both ends, judge the conditions as Cloud
/// Storage would, copy at the generation read, delete at it. The copy
/// carries the destination's conditions as well, for an emulator that
/// keeps them.
fn emulated(
    client: *Client,
    bucket: []const u8,
    source: []const u8,
    destination: []const u8,
    options: types.MoveOptions,
) Error!types.Owned(types.ObjectInfo) {
    logging.warn("{s}: an emulator has no objects.move, so it is copied to {s} and then deleted, which is not atomic", .{ source, destination });
    const from: Object = .{ .client = client, .bucket = bucket, .name = source };
    var read = try from.get(.{});
    defer read.deinit();
    const generation = read.value.generation;
    try judge(client, .{
        .if_generation_match = options.if_source_generation_match,
        .if_generation_not_match = options.if_source_generation_not_match,
        .if_metageneration_match = options.if_source_metageneration_match,
        .if_metageneration_not_match = options.if_source_metageneration_not_match,
    }, .{ generation, read.value.metageneration });
    const to: Object = .{ .client = client, .bucket = bucket, .name = destination };
    if (to.get(.{})) |found| {
        var there = found;
        defer there.deinit();
        try judge(client, options.preconditions, .{ there.value.generation, there.value.metageneration });
    } else |err| switch (err) {
        error.NotFound => try judge(client, options.preconditions, null),
        else => return err,
    }
    var copied = try from.copyTo(to, .{
        .source_generation = generation,
        .preconditions = options.preconditions,
    });
    errdefer copied.deinit();
    try from.delete(.{ .generation = generation });
    return copied;
}

/// Judges `conditions` against an object's generation and metageneration,
/// or against no object, as Cloud Storage does: a `Match` that fails is
/// 412, a `NotMatch` that hits is 304, and against no object only
/// "generation 0" holds. Says so in production's words.
fn judge(client: *Client, conditions: types.Preconditions, object: ?struct { u64, u64 }) Error!void {
    const outcome: enum { hold, failed, hit } = if (object) |o| outcome: {
        if (conditions.if_generation_match) |g| if (g != o[0]) break :outcome .failed;
        if (conditions.if_metageneration_match) |m| if (m != o[1]) break :outcome .failed;
        if (conditions.if_generation_not_match) |g| if (g == o[0]) break :outcome .hit;
        if (conditions.if_metageneration_not_match) |m| if (m == o[1]) break :outcome .hit;
        break :outcome .hold;
    } else if ((conditions.if_generation_match orelse 0) == 0 and conditions.if_generation_not_match == null and
        conditions.if_metageneration_match == null and conditions.if_metageneration_not_match == null) .hold else .failed;
    switch (outcome) {
        .hold => {},
        .failed => {
            if (client.diagnostics) |d| d.set(412, "conditionNotMet", "At least one of the pre-conditions you specified did not hold.");
            return error.FailedPrecondition;
        },
        .hit => {
            if (client.diagnostics) |d| d.set(304, "", "");
            return error.NotModified;
        },
    }
}

const testing = std.testing;
const test_util = @import("test_util.zig");
const bodies = @import("production_bodies.zig");

const base = "https://storage.googleapis.com/storage/v1/b/b/o/";

test "check: one name for both ends, and a Match beside a NotMatch, are refused" {
    var diag: core.Diagnostics = .{};
    try testing.expectError(error.InvalidArgument, check(&diag, "a", "a", .{}));
    try testing.expect(std.mem.indexOf(u8, diag.message(), "one name") != null);
    const conflicting = [_]types.MoveOptions{
        .{ .if_source_generation_match = 1, .if_source_generation_not_match = 2 },
        .{ .if_source_metageneration_match = 1, .if_source_metageneration_not_match = 2 },
        .{ .preconditions = .{ .if_generation_match = 0, .if_generation_not_match = 5 } },
        .{ .preconditions = .{ .if_metageneration_match = 1, .if_metageneration_not_match = 2 } },
    };
    for (conflicting) |options| {
        try testing.expectError(error.InvalidArgument, check(&diag, "a", "b", options));
        try testing.expect(std.mem.indexOf(u8, diag.message(), "conflicting") != null);
    }
    // Every other mix is the server's to judge.
    try check(null, "a", "b", .{
        .if_source_generation_match = 1,
        .if_source_metageneration_not_match = 2,
        .preconditions = .{ .if_generation_match = 0, .if_metageneration_not_match = 3 },
    });
    try check(null, "a/b", "a/b/", .{});
}

test "moveTo: the request, every condition, and the answer, as production gave it" {
    var h: test_util.Harness = undefined;
    try h.init(&.{.{ .respond = .{ .body = bodies.move_flat } }}, .{});
    defer h.deinit();
    var moved = try h.client.bucket("b").object("mv/src1").moveTo("mv/dst ü", .{
        .if_source_generation_match = 1792842035591224,
        .if_source_metageneration_not_match = 9,
        .preconditions = .does_not_exist,
    });
    defer moved.deinit();
    try h.expectRequest(
        0,
        .POST,
        base ++ "mv%2Fsrc1/moveTo/o/mv%2Fdst%20%C3%BC?ifSourceGenerationMatch=1792842035591224&ifSourceMetagenerationNotMatch=9&ifGenerationMatch=0",
        null,
    );
    try testing.expect((try h.fake.request(0)).header(idempotency.header_name) != null);
    try testing.expectEqualStrings("mv/dst1", moved.value.name);
    try testing.expectEqual(1792842035833399, moved.value.generation);
    try testing.expectEqual(1, moved.value.metageneration);
    try testing.expectEqualStrings("2026-10-01T00:00:00Z", moved.value.custom_time.?);
    try testing.expectEqualStrings("v", moved.value.metadataValue("k").?);
    try testing.expectEqualStrings("no-cache", moved.value.cache_control.?);
}

test "moveTo: refusals before sending, and production's answers as errors" {
    var h: test_util.Harness = undefined;
    try h.init(&.{
        .{ .respond = .{ .status = bodies.move_condition_failed_status, .body = bodies.move_condition_failed } },
        .{ .respond = .{ .status = bodies.move_not_match_hit_status, .body = bodies.move_not_match_hit } },
        .{ .respond = .{ .status = bodies.move_held_source_status, .body = bodies.move_held_source } },
        .{ .respond = .{ .status = bodies.move_missing_source_status, .body = bodies.move_missing_source } },
    }, .{});
    defer h.deinit();
    const obj = h.client.bucket("b").object("a");
    try testing.expectError(error.InvalidArgument, obj.moveTo("a", .{}));
    try testing.expectError(error.InvalidArgument, obj.moveTo("b", .{ .if_source_generation_match = 1, .if_source_generation_not_match = 1 }));
    try testing.expectError(error.InvalidObjectName, obj.moveTo("", .{}));
    try h.expectRequestCount(0);
    try testing.expectError(error.FailedPrecondition, obj.moveTo("b", .{ .preconditions = .does_not_exist }));
    try testing.expectError(error.NotModified, obj.moveTo("b", .{ .if_source_generation_not_match = 7 }));
    try testing.expectError(error.ObjectRetained, obj.moveTo("b", .{}));
    // A missing source on the first attempt is just that: nothing is read.
    try testing.expectError(error.NotFound, obj.moveTo("b", .{ .if_source_generation_match = 7 }));
    try h.expectRequestCount(4);
}

test "moveTo, pinned: a lost answer is repeated under the same token" {
    var h: test_util.Harness = undefined;
    try h.init(&.{
        .{ .fail = error.ConnectionResetByPeer },
        .{ .respond = .{ .body = bodies.move_flat } },
    }, .{});
    defer h.deinit();
    var moved = try h.client.bucket("b").object("mv/src1").moveTo("mv/dst1", .{ .if_source_generation_match = 1792842035591224 });
    defer moved.deinit();
    try h.expectRequestCount(2);
    const first = (try h.fake.request(0)).header(idempotency.header_name).?;
    try testing.expectEqualStrings(first, (try h.fake.request(1)).header(idempotency.header_name).?);
    try testing.expectEqual(1792842035833399, moved.value.generation);
}

test "moveTo, pinned: a repeat that finds the source gone answers the destination" {
    var h: test_util.Harness = undefined;
    try h.init(&.{
        .{ .respond = .{ .status = 503, .body = "{\"error\":{\"code\":503,\"message\":\"backend\"}}" } },
        .{ .respond = .{ .status = bodies.move_repeat_pinned_status, .body = bodies.move_repeat_pinned } },
        .{ .respond = .{ .status = 404, .body = "{\"error\":{\"code\":404,\"message\":\"No such object\",\"errors\":[{\"reason\":\"notFound\"}]}}" } },
        .{ .respond = .{ .body = bodies.move_flat } },
    }, .{});
    defer h.deinit();
    var moved = try h.client.bucket("b").object("mv/src1").moveTo("mv/dst1", .{ .if_source_generation_match = 1792842035591224 });
    defer moved.deinit();
    try h.expectRequestCount(4);
    try h.expectRequest(2, .GET, base ++ "mv%2Fsrc1", null);
    try h.expectRequest(3, .GET, base ++ "mv%2Fdst1", null);
    try testing.expectEqualStrings("mv/dst1", moved.value.name);
}

test "moveTo, pinned: a repeat that finds another object at the source stands, and says it may have moved" {
    var h: test_util.Harness = undefined;
    try h.init(&.{
        .{ .fail = error.ConnectionResetByPeer },
        .{ .respond = .{ .status = bodies.move_condition_failed_status, .body = bodies.move_condition_failed } },
        .{ .respond = .{ .body = bodies.object_custom_time_millis } },
    }, .{});
    defer h.deinit();
    // Pinned to a generation other than the one the source holds now.
    try testing.expectError(error.FailedPrecondition, h.client.bucket("b").object("ct/b").moveTo("d", .{
        .if_source_generation_match = 7,
    }));
    try h.expectRequestCount(3);
    try testing.expectEqual(412, h.diag.http_status);
    try testing.expect(std.mem.indexOf(u8, h.diag.message(), "may have moved") != null);
}

test "moveTo, pinned: a repeat whose source and destination are both gone keeps the move's 404" {
    var h: test_util.Harness = undefined;
    const missing = "{\"error\":{\"code\":404,\"message\":\"No such object\",\"errors\":[{\"reason\":\"notFound\"}]}}";
    try h.init(&.{
        .{ .fail = error.ConnectionResetByPeer },
        .{ .respond = .{ .status = bodies.move_repeat_pinned_status, .body = bodies.move_repeat_pinned } },
        .{ .respond = .{ .status = 404, .body = missing } },
        .{ .respond = .{ .status = 404, .body = missing } },
    }, .{});
    defer h.deinit();
    try testing.expectError(error.NotFound, h.client.bucket("b").object("mv/src1").moveTo("mv/dst1", .{ .if_source_generation_match = 1 }));
    try h.expectRequestCount(4);
    try testing.expect(std.mem.indexOf(u8, h.diag.message(), "zigps-7b3007-none/mv/src1") != null);
}

test "moveTo, pinned: a repeat refused while the source is still there stands" {
    var h: test_util.Harness = undefined;
    try h.init(&.{
        .{ .fail = error.ConnectionTimedOut },
        .{ .respond = .{ .status = bodies.move_condition_failed_status, .body = bodies.move_condition_failed } },
        .{ .respond = .{ .body = bodies.object_custom_time_millis } },
    }, .{});
    defer h.deinit();
    try testing.expectError(error.FailedPrecondition, h.client.bucket("b").object("a").moveTo("b", .{
        .if_source_generation_match = 1792842034478713,
        .preconditions = .does_not_exist,
    }));
    try h.expectRequestCount(3);
    // The move's own words, not the read's.
    try testing.expect(std.mem.indexOf(u8, h.diag.message(), "pre-conditions") != null);
}

test "moveTo, not pinned: repeated within the token's window only, and never settled" {
    var h: test_util.Harness = undefined;
    try h.init(&.{
        .{ .fail = error.ConnectionResetByPeer },
        .{ .respond = .{ .status = bodies.move_repeat_pinned_status, .body = bodies.move_repeat_pinned } },
    }, .{});
    defer h.deinit();
    try testing.expectError(error.NotFound, h.client.bucket("b").object("a").moveTo("b", .{}));
    try h.expectRequestCount(2);
    try testing.expectEqual(404, h.diag.http_status);
    try testing.expect(std.mem.indexOf(u8, h.diag.message(), "may have moved") != null);

    var without: test_util.Harness = undefined;
    try without.init(&.{.{ .fail = error.ConnectionResetByPeer }}, .{ .idempotency_tokens = false });
    defer without.deinit();
    try testing.expectError(error.ConnectionResetByPeer, without.client.bucket("b").object("a").moveTo("b", .{}));
    try without.expectRequestCount(1);
}

test "moveTo, pinned: repeated without idempotency tokens, and never past the attempts the policy allows" {
    var h: test_util.Harness = undefined;
    try h.init(&.{
        .{ .fail = error.ConnectionResetByPeer },
        .{ .respond = .{ .body = bodies.move_flat } },
    }, .{ .idempotency_tokens = false });
    defer h.deinit();
    var moved = try h.client.bucket("b").object("mv/src1").moveTo("mv/dst1", .{ .if_source_generation_match = 1792842035591224 });
    defer moved.deinit();
    try h.expectRequestCount(2);
    try testing.expectEqual(null, (try h.fake.request(0)).header(idempotency.header_name));

    const unavailable: test_util.FakeTransport.Reply = .{ .respond = .{ .status = 503, .body = "{\"error\":{\"code\":503,\"message\":\"backend\"}}" } };
    const script = [_]test_util.FakeTransport.Reply{ unavailable, unavailable, unavailable, unavailable, unavailable, unavailable };
    var busy: test_util.Harness = undefined;
    try busy.init(&script, .{ .retry = .{ .max_attempts = 4, .initial_backoff_ms = 1 } });
    defer busy.deinit();
    try testing.expectError(error.Unavailable, busy.client.bucket("b").object("a").moveTo("b", .{ .if_source_generation_match = 1 }));
    try busy.expectRequestCount(4);
}

test "moveTo, not pinned: a repeat the server's delay would push past the token's minute is never made" {
    var h: test_util.Harness = undefined;
    try h.init(&.{
        .{ .respond = .{
            .status = 503,
            .body = "{\"error\":{\"code\":503,\"message\":\"backend\"}}",
            .headers = &.{.{ .name = "Retry-After", .value = "61" }},
        } },
        .{ .respond = .{ .body = bodies.move_flat } },
    }, .{ .retry = .{ .initial_backoff_ms = 1, .max_backoff_ms = 120_000 } });
    defer h.deinit();
    try testing.expectError(error.Unavailable, h.client.bucket("b").object("a").moveTo("b", .{}));
    try h.expectRequestCount(1);
    // Pinned, the same delay is waited out.
    var pinned: test_util.Harness = undefined;
    try pinned.init(&.{
        .{ .respond = .{
            .status = 503,
            .body = "{\"error\":{\"code\":503,\"message\":\"backend\"}}",
            .headers = &.{.{ .name = "Retry-After", .value = "61" }},
        } },
        .{ .respond = .{ .body = bodies.move_flat } },
    }, .{ .retry = .{ .initial_backoff_ms = 1, .max_backoff_ms = 120_000 } });
    defer pinned.deinit();
    var moved = try pinned.client.bucket("b").object("mv/src1").moveTo("mv/dst1", .{ .if_source_generation_match = 1792842035591224 });
    defer moved.deinit();
    try pinned.expectRequestCount(2);
    try testing.expect(pinned.clock.now_ns >= 61 * std.time.ns_per_s);
}

test "moveTo against an emulator: both ends read and judged, then copy and delete at the generation read" {
    var fake: test_util.FakeTransport = .init(testing.allocator, &.{
        .{ .respond = .{ .body = "{\"name\":\"a\",\"bucket\":\"b\",\"generation\":\"5\",\"metageneration\":\"2\",\"size\":\"1\"}" } },
        .{ .respond = .{ .status = 404, .body = "{\"error\":{\"code\":404,\"message\":\"Not Found\"}}" } },
        .{ .respond = .{ .body = "{\"kind\":\"storage#rewriteResponse\",\"done\":true,\"totalBytesRewritten\":\"1\",\"objectSize\":\"1\",\"resource\":{\"name\":\"b\",\"bucket\":\"b\",\"generation\":\"6\",\"size\":\"1\"}}" } },
        .{ .respond = .{ .status = 204, .body = "" } },
    });
    defer fake.deinit();
    var client: Client = try .init(testing.allocator, testing.io, .{
        .endpoint = .{ .url = "http://127.0.0.1:4443", .emulator = true },
        .transport = fake.transport(),
    });
    defer client.deinit();
    var moved = try client.bucket("b").object("a").moveTo("b", .{
        .if_source_metageneration_match = 2,
        .preconditions = .does_not_exist,
    });
    defer moved.deinit();
    try testing.expectEqualStrings("b", moved.value.name);
    try testing.expectEqual(6, moved.value.generation);
    try testing.expectEqual(4, fake.requests.items.len);
    const read = try fake.request(0);
    try testing.expectEqual(.GET, read.method);
    try testing.expect(std.mem.endsWith(u8, read.url, "/o/a"));
    const looked = try fake.request(1);
    try testing.expectEqual(.GET, looked.method);
    try testing.expect(std.mem.endsWith(u8, looked.url, "/o/b"));
    const copy = try fake.request(2);
    try testing.expect(std.mem.indexOf(u8, copy.url, "/rewriteTo/b/b/o/b?sourceGeneration=5&ifGenerationMatch=0") != null);
    const gone = try fake.request(3);
    try testing.expectEqual(.DELETE, gone.method);
    try testing.expect(std.mem.indexOf(u8, gone.url, "/o/a?generation=5") != null);
}

test "moveTo against an emulator: conditions judged as Cloud Storage judges them, before anything is copied" {
    const source = "{\"name\":\"a\",\"bucket\":\"b\",\"generation\":\"5\",\"metageneration\":\"2\",\"size\":\"1\"}";
    const taken = "{\"name\":\"b\",\"bucket\":\"b\",\"generation\":\"9\",\"metageneration\":\"1\",\"size\":\"1\"}";
    const missing = "{\"error\":{\"code\":404,\"message\":\"Not Found\"}}";
    const cases = [_]struct { types.MoveOptions, bool, Error }{
        .{ .{ .if_source_generation_match = 4 }, false, error.FailedPrecondition },
        .{ .{ .if_source_metageneration_match = 3 }, false, error.FailedPrecondition },
        .{ .{ .if_source_generation_not_match = 5 }, false, error.NotModified },
        .{ .{ .if_source_metageneration_not_match = 2 }, false, error.NotModified },
        .{ .{ .preconditions = .does_not_exist }, true, error.FailedPrecondition },
        .{ .{ .preconditions = .{ .if_metageneration_match = 2 } }, true, error.FailedPrecondition },
        .{ .{ .preconditions = .{ .if_generation_not_match = 9 } }, true, error.NotModified },
        // Against no object, a NotMatch fails, as measured.
        .{ .{ .preconditions = .{ .if_generation_not_match = 0 } }, false, error.FailedPrecondition },
        .{ .{ .preconditions = .{ .if_generation_match = 9 } }, false, error.FailedPrecondition },
    };
    for (cases) |case| {
        const source_fails = case[0].preconditions.if_generation_match == null and case[0].preconditions.if_generation_not_match == null and
            case[0].preconditions.if_metageneration_match == null;
        var fake: test_util.FakeTransport = .init(testing.allocator, &.{
            .{ .respond = .{ .body = source } },
            .{ .respond = if (case[1]) .{ .body = taken } else .{ .status = 404, .body = missing } },
        });
        defer fake.deinit();
        var diag: core.Diagnostics = .{};
        var client: Client = try .init(testing.allocator, testing.io, .{
            .endpoint = .{ .url = "http://127.0.0.1:4443", .emulator = true },
            .transport = fake.transport(),
            .diagnostics = &diag,
        });
        defer client.deinit();
        try testing.expectError(case[2], client.bucket("b").object("a").moveTo("b", case[0]));
        // Nothing copied and nothing deleted; a source refused is all
        // that was read.
        try testing.expectEqual(@as(usize, if (source_fails) 1 else 2), fake.requests.items.len);
        if (case[2] == error.FailedPrecondition) try testing.expectEqualStrings("At least one of the pre-conditions you specified did not hold.", diag.message());
    }
}

/// A client on the fake, which answers moves and custom times as
/// production did on 2026-10-24.
const Fixture = struct {
    fake: test_util.FakeMultipart,
    token: core.StaticToken,
    diag: core.Diagnostics,
    client: Client,

    fn init(f: *Fixture) !void {
        f.fake = .init(testing.allocator, testing.io);
        errdefer f.fake.deinit();
        f.token = .{ .token = "ya29.move" };
        f.diag = .{};
        f.client = try .init(testing.allocator, testing.io, .{
            .project_id = "extractctl",
            .token_provider = f.token.provider(),
            .transport = f.fake.transport(),
            .diagnostics = &f.diag,
            .retry = .{ .max_attempts = 3, .initial_backoff_ms = 1, .max_backoff_ms = 2 },
        });
        errdefer f.client.deinit();
        var created = try f.client.bucket("b").create(.{});
        created.deinit();
    }

    fn deinit(f: *Fixture) void {
        f.client.deinit();
        f.fake.deinit();
    }

    fn object(f: *Fixture, name: []const u8) Object {
        return f.client.bucket("b").object(name);
    }
};

test "moveTo through the fake: production's refusals in its words, then the move and what it keeps" {
    var f: Fixture = undefined;
    try f.init();
    defer f.deinit();
    var src = try f.object("mv/src").upload("abc", .{ .content_type = "text/plain", .custom_time = "2026-10-01T00:00:00Z" });
    defer src.deinit();
    var other = try f.object("mv/other").upload("x", .{});
    defer other.deinit();
    const g = src.value.generation;

    try testing.expectError(error.NotFound, f.object("mv/nosuch").moveTo("mv/x", .{}));
    try testing.expectEqualStrings("No such object: b/mv/nosuch", f.diag.message());
    try testing.expectError(error.FailedPrecondition, f.object("mv/src").moveTo("mv/x", .{ .if_source_generation_match = g + 100 }));
    try testing.expectEqualStrings("At least one of the pre-conditions you specified did not hold.", f.diag.message());
    try testing.expectError(error.FailedPrecondition, f.object("mv/src").moveTo("mv/other", .{ .preconditions = .does_not_exist }));
    // A NotMatch against no destination fails too.
    try testing.expectError(error.FailedPrecondition, f.object("mv/src").moveTo("mv/x", .{ .preconditions = .{ .if_generation_not_match = 0 } }));
    // A NotMatch that hits, on either end, is 304.
    try testing.expectError(error.NotModified, f.object("mv/src").moveTo("mv/x", .{ .if_source_generation_not_match = g }));
    try testing.expectError(error.NotModified, f.object("mv/src").moveTo("mv/x", .{ .if_source_metageneration_not_match = 1 }));
    try testing.expectError(error.NotModified, f.object("mv/src").moveTo("mv/other", .{ .preconditions = .{ .if_generation_not_match = other.value.generation } }));
    try testing.expectEqual(7, f.fake.counts.moves);
    try testing.expect(f.fake.object("mv/src") != null);

    // A metadata update first, so the move is seen to reset the
    // metageneration.
    var patched = try f.object("mv/src").updateMetadata(.{ .custom_time = "2026-10-01T00:00:00Z" });
    defer patched.deinit();
    try testing.expectEqual(2, patched.value.metageneration);
    var moved = try f.object("mv/src").moveTo("mv/dst ü+%", .{ .if_source_generation_match = g, .preconditions = .does_not_exist });
    defer moved.deinit();
    try testing.expectEqualStrings("mv/dst ü+%", moved.value.name);
    try testing.expect(moved.value.generation > g);
    try testing.expectEqual(1, moved.value.metageneration);
    try testing.expectEqualStrings("text/plain", moved.value.content_type);
    try testing.expectEqualStrings("2026-10-01T00:00:00Z", moved.value.custom_time.?);
    var link_buf: [160]u8 = undefined;
    const link = try std.fmt.bufPrint(&link_buf, "https://storage.googleapis.com/download/storage/v1/b/b/o/mv%2Fdst%20%C3%BC%2B%25?generation={d}&alt=media", .{moved.value.generation});
    try testing.expectEqualStrings(link, moved.value.media_link.?);
    try testing.expectError(error.NotFound, f.object("mv/src").get(.{}));
    var read = try f.object("mv/dst ü+%").get(.{});
    defer read.deinit();
    try testing.expectEqual(moved.value.generation, read.value.generation);
}

test "moveTo through the fake: a held source or destination stays, in production's words" {
    var f: Fixture = undefined;
    try f.init();
    defer f.deinit();
    var held = try f.object("mv/held").upload("abc", .{ .temporary_hold = true });
    defer held.deinit();
    var free = try f.object("mv/free").upload("abc", .{});
    defer free.deinit();
    try testing.expectError(error.ObjectRetained, f.object("mv/held").moveTo("mv/x", .{}));
    try testing.expectEqualStrings("Object 'b/mv/held' is under active Temporary hold and cannot be deleted, overwritten or archived until hold is removed.", f.diag.message());
    try testing.expectError(error.ObjectRetained, f.object("mv/free").moveTo("mv/held", .{}));
    try testing.expect(f.fake.object("mv/free") != null);
    try testing.expectEqual(held.value.generation, f.fake.object("mv/held").?.generation);
}

test "the fake's custom time, as production keeps it: later or the same, null ignored, never earlier" {
    var f: Fixture = undefined;
    try f.init();
    defer f.deinit();
    var up = try f.object("ct").upload("abc", .{ .custom_time = "2026-10-01T12:34:56.789+02:00" });
    defer up.deinit();
    // Written back in UTC, the milliseconds kept.
    try testing.expectEqualStrings("2026-10-01T10:34:56.789Z", up.value.custom_time.?);
    // A resumable upload keeps it too.
    f.client.single_request_limit = 16;
    var resumed = try f.object("ct-resumed").upload("more than sixteen bytes, resumably", .{ .custom_time = "2026-10-01T00:00:00Z" });
    defer resumed.deinit();
    try testing.expectEqualStrings("2026-10-01T00:00:00Z", resumed.value.custom_time.?);
    try testing.expectEqual(1, f.fake.counts.session_starts);
    const steps = [_]struct { ?[]const u8, []const u8, u64 }{
        .{ "2026-10-01T10:34:56.789Z", "2026-10-01T10:34:56.789Z", 2 },
        .{ "2026-10-02T00:00:00Z", "2026-10-02T00:00:00Z", 3 },
    };
    for (steps) |step| {
        var next = try f.object("ct").updateMetadata(.{ .custom_time = step[0] });
        defer next.deinit();
        try testing.expectEqualStrings(step[1], next.value.custom_time.?);
        try testing.expectEqual(step[2], next.value.metageneration);
    }
    try testing.expectError(error.InvalidArgument, f.object("ct").updateMetadata(.{ .custom_time = "2025-01-01T00:00:00Z" }));
    try testing.expectEqualStrings("Custom time cannot be decreased. Previously: 2026-10-02T00:00:00+00:00. Attempting to set: 2025-01-01T00:00:00+00:00.", f.diag.message());
    var kept = try f.object("ct").get(.{});
    defer kept.deinit();
    try testing.expectEqualStrings("2026-10-02T00:00:00Z", kept.value.custom_time.?);
    try testing.expectEqual(3, kept.value.metageneration);
}
