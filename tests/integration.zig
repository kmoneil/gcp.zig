//! Integration tests against a real Pub/Sub server.
//!
//! - Emulator: set PUBSUB_EMULATOR_HOST (and optionally PUBSUB_PROJECT_ID,
//!   default "test").
//! - Production: set PUBSUB_TEST_PROJECT and PUBSUB_TEST_TOKEN, for example
//!   `PUBSUB_TEST_TOKEN=$(gcloud auth print-access-token)`. With
//!   PUBSUB_TEST_PROJECT_NUMBER too, the dead-letter test grants Pub/Sub's
//!   service agent what it needs on that test's own topic and subscription;
//!   without it, that test skips in production.
//!
//! With neither set, every test skips. Each test creates uniquely named
//! resources (prefix `zigps-`) and deletes them, even when it fails.

const std = @import("std");
const pubsub = @import("pubsub");
const testing = std.testing;
const Allocator = std.mem.Allocator;

const Fixture = struct {
    env: std.process.Environ.Map,
    token: pubsub.StaticToken,
    diag: pubsub.Diagnostics,
    client: pubsub.Client,
    production: bool,
    /// "zigps-" plus 8 random hex digits, unique per test.
    prefix: [14]u8,
    arena: std.heap.ArenaAllocator,
    topics: std.ArrayList([]const u8),
    subscriptions: std.ArrayList([]const u8),
    snapshots: std.ArrayList([]const u8),
    schemas: std.ArrayList([]const u8),

    /// Returns false when no server is configured; the test should skip.
    fn init(f: *Fixture) !bool {
        const gpa = testing.allocator;
        f.env = try testing.environ.createMap(gpa);
        errdefer f.env.deinit();
        f.diag = .{};
        f.arena = .init(gpa);
        errdefer f.arena.deinit();
        f.topics = .empty;
        f.subscriptions = .empty;
        f.snapshots = .empty;
        f.schemas = .empty;

        var random: [4]u8 = undefined;
        testing.io.random(&random);
        _ = try std.fmt.bufPrint(&f.prefix, "zigps-{x}", .{random});

        const emulator = pubsub.Endpoint.fromEnv(&f.env);
        const project = if (emulator != null)
            f.env.get("PUBSUB_PROJECT_ID") orelse "test"
        else
            f.env.get("PUBSUB_TEST_PROJECT") orelse {
                f.arena.deinit();
                f.env.deinit();
                return false;
            };
        f.production = emulator == null;
        if (f.production) {
            const token = f.env.get("PUBSUB_TEST_TOKEN") orelse {
                f.arena.deinit();
                f.env.deinit();
                return false;
            };
            f.token = .{ .token = std.mem.trim(u8, token, &std.ascii.whitespace) };
        } else {
            f.token = .{ .token = "" };
        }
        f.client = try .init(gpa, testing.io, .{
            .project_id = project,
            .endpoint = emulator,
            .token_provider = if (f.production) f.token.provider() else null,
            .diagnostics = &f.diag,
            .user_agent = "zig-pubsub-integration/0.1",
        });
        return true;
    }

    /// Deletes everything the test created: snapshots, then subscriptions,
    /// then topics, then the schemas those topics may have named.
    fn deinit(f: *Fixture) void {
        for (f.snapshots.items) |snapshot_id| f.client.snapshot(snapshot_id).delete() catch {};
        for (f.subscriptions.items) |sub_id| f.client.subscription(sub_id).delete() catch {};
        for (f.topics.items) |topic_id| f.client.topic(topic_id).delete() catch {};
        for (f.schemas.items) |schema_id| f.client.schema(schema_id).delete() catch {};
        f.schemas.deinit(testing.allocator);
        f.snapshots.deinit(testing.allocator);
        f.subscriptions.deinit(testing.allocator);
        f.topics.deinit(testing.allocator);
        f.client.deinit();
        f.arena.deinit();
        f.env.deinit();
    }

    /// A unique id: the prefix plus `suffix`.
    fn id(f: *Fixture, suffix: []const u8) []const u8 {
        return f.arena.allocator().print("{s}-{s}", .{ &f.prefix, suffix }) catch @panic("OOM");
    }

    // Resources are registered for cleanup before the create call: a call
    // can fail after the server created the resource.
    fn createTopic(f: *Fixture, suffix: []const u8) !pubsub.Topic {
        const topic = f.client.topic(f.id(suffix));
        try f.topics.append(testing.allocator, topic.id);
        var info = topic.create(.{}) catch |err| return f.fail(err);
        info.deinit();
        return topic;
    }

    fn createSubscription(f: *Fixture, suffix: []const u8, config: pubsub.SubscriptionConfig) !pubsub.Subscription {
        const sub = f.client.subscription(f.id(suffix));
        try f.subscriptions.append(testing.allocator, sub.id);
        var info = sub.create(config) catch |err| return f.fail(err);
        info.deinit();
        return sub;
    }

    fn fail(f: *Fixture, err: anyerror) anyerror {
        std.debug.print("{t}: HTTP {d} {s}: {s}\n", .{ err, f.diag.http_status, f.diag.status(), f.diag.message() });
        return err;
    }

    /// Seconds to wait for server-side effects: a new subscription starts
    /// receiving, a redelivery happens. Production needs longer.
    fn patience(f: *const Fixture) i64 {
        return if (f.production) 90 else 30;
    }

    /// Grants Pub/Sub's service agent `role` on one of this test's own
    /// topics or subscriptions, through the library's `addIamBinding`. The
    /// grant goes when the test deletes the resource.
    fn grantServiceAgent(f: *Fixture, project_number: []const u8, kind: enum { topic, subscription }, id_: []const u8, role: []const u8) !void {
        const member = try f.arena.allocator().print("serviceAccount:service-{s}@gcp-sa-pubsub.iam.gserviceaccount.com", .{project_number});
        var policy = switch (kind) {
            .topic => f.client.topic(id_).addIamBinding(role, member),
            .subscription => f.client.subscription(id_).addIamBinding(role, member),
        } catch |err| return f.fail(err);
        policy.deinit();
    }
};

/// Messages copied out of pull results so they outlive them.
const Collector = struct {
    arena: std.heap.ArenaAllocator,
    messages: std.ArrayList(Received) = .empty,

    const Received = struct {
        ack_id: []const u8,
        message_id: []const u8,
        data: []const u8,
        attributes: []const pubsub.Attribute,
        ordering_key: []const u8,
        publish_time: []const u8,
    };

    fn init() Collector {
        return .{ .arena = .init(testing.allocator) };
    }

    fn deinit(c: *Collector) void {
        c.arena.deinit();
    }

    fn add(c: *Collector, m: pubsub.ReceivedMessage) !void {
        const a = c.arena.allocator();
        const attrs = try a.alloc(pubsub.Attribute, m.attributes.len);
        for (m.attributes, attrs) |src, *dst| dst.* = .{ .key = try a.dupe(u8, src.key), .value = try a.dupe(u8, src.value) };
        try c.messages.append(a, .{
            .ack_id = try a.dupe(u8, m.ack_id),
            .message_id = try a.dupe(u8, m.message_id),
            .data = try a.dupe(u8, m.data),
            .attributes = attrs,
            .ordering_key = try a.dupe(u8, m.ordering_key),
            .publish_time = try a.dupe(u8, m.publish_time),
        });
    }

    fn find(c: *const Collector, data: []const u8) ?Received {
        for (c.messages.items) |m| if (std.mem.eql(u8, m.data, data)) return m;
        return null;
    }
};

fn nowMs() i64 {
    return std.Io.Clock.awake.now(testing.io).toMilliseconds();
}

/// Pulls until at least `want` messages arrived, acking each batch when
/// `ack` is set. Fails after `timeout_s` seconds.
fn pullUntil(f: *Fixture, sub: pubsub.Subscription, want: usize, timeout_s: i64, into: *Collector, ack: bool) !void {
    const deadline = nowMs() + timeout_s * 1000;
    while (into.messages.items.len < want) {
        if (nowMs() > deadline) {
            std.debug.print("timed out with {d} of {d} messages\n", .{ into.messages.items.len, want });
            return error.TestTimedOut;
        }
        var batch = sub.pull(.{ .max_messages = 1000, .return_immediately = true }) catch |err| return f.fail(err);
        defer batch.deinit();
        for (batch.value.messages) |m| try into.add(m);
        if (ack and batch.value.messages.len > 0) {
            const ids = try testing.allocator.alloc([]const u8, batch.value.messages.len);
            defer testing.allocator.free(ids);
            for (batch.value.messages, ids) |m, *id| id.* = m.ack_id;
            sub.ack(ids) catch |err| return f.fail(err);
        }
        if (batch.value.messages.len == 0) try testing.io.sleep(.fromMilliseconds(250), .awake);
    }
}

/// Pulls briefly and fails if anything arrives.
fn expectNoMessages(f: *Fixture, sub: pubsub.Subscription) !void {
    for (0..3) |_| {
        var batch = sub.pull(.{ .return_immediately = true }) catch |err| return f.fail(err);
        defer batch.deinit();
        if (batch.value.messages.len != 0) {
            std.debug.print("unexpected message {s}\n", .{batch.value.messages[0].message_id});
            return error.TestUnexpectedMessage;
        }
        try testing.io.sleep(.fromMilliseconds(200), .awake);
    }
}

/// Retries `check` until it stops failing, for eventually consistent reads.
fn eventually(f: *Fixture, timeout_s: i64, context: anytype, comptime check: fn (@TypeOf(context)) anyerror!void) !void {
    const deadline = nowMs() + timeout_s * 1000;
    while (true) {
        check(context) catch |err| {
            if (nowMs() > deadline) return f.fail(err);
            try testing.io.sleep(.fromMilliseconds(500), .awake);
            continue;
        };
        return;
    }
}

fn publishOne(f: *Fixture, topic: pubsub.Topic, message: pubsub.Message, options: pubsub.PublishOptions) ![]const u8 {
    var sent = topic.publish(&.{message}, options) catch |err| return f.fail(err);
    defer sent.deinit();
    return f.arena.allocator().dupe(u8, sent.value.message_ids[0]);
}

// 1. Topic lifecycle.
test "topic: create, get, find in list, delete, then NotFound" {
    var f: Fixture = undefined;
    if (!try f.init()) return error.SkipZigTest;
    defer f.deinit();

    const topic = f.client.topic(f.id("life"));
    try f.topics.append(testing.allocator, topic.id);
    var created = topic.create(.{}) catch |err| return f.fail(err);
    defer created.deinit();
    try testing.expect(std.mem.endsWith(u8, created.value.name, topic.id));

    var got = topic.get() catch |err| return f.fail(err);
    defer got.deinit();
    try testing.expectEqualStrings(created.value.name, got.value.name);

    // Find it in the list, following pages.
    var found = false;
    var token: ?[]const u8 = null;
    var token_arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer token_arena.deinit();
    for (0..1000) |_| {
        var page = f.client.listTopics(.{ .page_size = 100, .page_token = token }) catch |err| return f.fail(err);
        defer page.deinit();
        for (page.value.topics) |t| found = found or std.mem.eql(u8, t.name, created.value.name);
        token = if (page.value.next_page_token) |t| try token_arena.allocator().dupe(u8, t) else null;
        if (found or token == null) break;
    }
    try testing.expect(found);

    topic.delete() catch |err| return f.fail(err);
    const Check = struct {
        fn gone(t: pubsub.Topic) anyerror!void {
            var info = t.get() catch |err| switch (err) {
                error.NotFound => return,
                else => return err,
            };
            info.deinit();
            return error.TestStillExists;
        }
    };
    try eventually(&f, 30, topic, Check.gone);
    try testing.expectEqual(404, f.diag.http_status);
    try testing.expectEqualStrings("NOT_FOUND", f.diag.status());
}

// 2.
test "topic: creating the same topic twice is AlreadyExists" {
    var f: Fixture = undefined;
    if (!try f.init()) return error.SkipZigTest;
    defer f.deinit();
    const topic = try f.createTopic("twice");
    try testing.expectError(error.AlreadyExists, topic.create(.{}));
    try testing.expectEqual(409, f.diag.http_status);
    try testing.expectEqualStrings("ALREADY_EXISTS", f.diag.status());
    try testing.expect(f.diag.message().len > 0);
}

// 3.
test "subscription: creating one on a missing topic is NotFound" {
    var f: Fixture = undefined;
    if (!try f.init()) return error.SkipZigTest;
    defer f.deinit();
    const sub = f.client.subscription(f.id("orphan"));
    try testing.expectError(error.NotFound, sub.create(.{ .topic_id = f.id("no-such-topic") }));
    try testing.expectEqualStrings("NOT_FOUND", f.diag.status());
}

// 4.
test "round trip: publish 3, pull, compare exactly, ack, then nothing left" {
    var f: Fixture = undefined;
    if (!try f.init()) return error.SkipZigTest;
    defer f.deinit();
    const topic = try f.createTopic("rt");
    const sub = try f.createSubscription("rt-sub", .{ .topic_id = topic.id });

    const messages = [_]pubsub.Message{
        .{ .data = "first message", .attributes = &.{.{ .key = "n", .value = "1" }} },
        .{ .data = "second, with ünïcödé and \"quotes\"", .attributes = &.{ .{ .key = "n", .value = "2" }, .{ .key = "kind", .value = "test" } } },
        .{ .data = "third\x00with\nbytes", .attributes = &.{.{ .key = "n", .value = "3" }} },
    };
    var sent = topic.publish(&messages, .{}) catch |err| return f.fail(err);
    defer sent.deinit();
    try testing.expectEqual(3, sent.value.message_ids.len);

    var got: Collector = .init();
    defer got.deinit();
    try pullUntil(&f, sub, 3, f.patience(), &got, true);
    try testing.expectEqual(3, got.messages.items.len);
    for (messages, sent.value.message_ids) |want, id| {
        const m = got.find(want.data) orelse return error.TestMessageMissing;
        try testing.expectEqualStrings(id, m.message_id);
        try testing.expectEqual(want.attributes.len, m.attributes.len);
        for (want.attributes) |attr| {
            var matched = false;
            for (m.attributes) |g| matched = matched or (std.mem.eql(u8, g.key, attr.key) and std.mem.eql(u8, g.value, attr.value));
            try testing.expect(matched);
        }
        _ = try pubsub.parseTimestamp(m.publish_time);
    }
    try expectNoMessages(&f, sub);
}

// 5.
test "binary safety: all 256 byte values survive the round trip" {
    var f: Fixture = undefined;
    if (!try f.init()) return error.SkipZigTest;
    defer f.deinit();
    const topic = try f.createTopic("bin");
    const sub = try f.createSubscription("bin-sub", .{ .topic_id = topic.id });
    var all: [256]u8 = undefined;
    for (&all, 0..) |*b, i| b.* = @intCast(i);
    _ = try publishOne(&f, topic, .{ .data = &all }, .{});
    var got: Collector = .init();
    defer got.deinit();
    try pullUntil(&f, sub, 1, f.patience(), &got, true);
    try testing.expectEqualSlices(u8, &all, got.messages.items[0].data);
}

test "compressed publish: every byte value and a long text arrive exactly as sent" {
    var f: Fixture = undefined;
    if (!try f.init()) return error.SkipZigTest;
    defer f.deinit();
    const topic = try f.createTopic("gzip");
    const sub = try f.createSubscription("gzip-sub", .{ .topic_id = topic.id });
    var all: [256]u8 = undefined;
    for (&all, 0..) |*b, i| b.* = @intCast(i);
    const text: []const u8 = comptime text: {
        const lines: [1000][36]u8 = @splat("a line of text that compresses well\n".*);
        break :text @ptrCast(&lines);
    };
    const messages = [_]pubsub.Message{
        .{ .data = &all, .attributes = &.{.{ .key = "kind", .value = "bytes" }} },
        .{ .data = text, .attributes = &.{.{ .key = "kind", .value = "text" }} },
    };
    var sent = topic.publish(&messages, .{ .compression = .{} }) catch |err| return f.fail(err);
    defer sent.deinit();
    try testing.expectEqual(2, sent.value.message_ids.len);

    var got: Collector = .init();
    defer got.deinit();
    try pullUntil(&f, sub, 2, f.patience(), &got, true);
    for (messages, sent.value.message_ids) |want, id| {
        const m = got.find(want.data) orelse return error.TestMessageMissing;
        try testing.expectEqualStrings(id, m.message_id);
    }
    try expectNoMessages(&f, sub);
}

// 6.
test "attribute-only message with empty data" {
    var f: Fixture = undefined;
    if (!try f.init()) return error.SkipZigTest;
    defer f.deinit();
    const topic = try f.createTopic("attr");
    const sub = try f.createSubscription("attr-sub", .{ .topic_id = topic.id });
    _ = try publishOne(&f, topic, .{ .attributes = &.{.{ .key = "only", .value = "attributes" }} }, .{});
    var got: Collector = .init();
    defer got.deinit();
    try pullUntil(&f, sub, 1, f.patience(), &got, true);
    const m = got.messages.items[0];
    try testing.expectEqual(0, m.data.len);
    try testing.expectEqual(1, m.attributes.len);
    try testing.expectEqualStrings("only", m.attributes[0].key);
    try testing.expectEqualStrings("attributes", m.attributes[0].value);
}

// 7.
test "nack: the same message comes back" {
    var f: Fixture = undefined;
    if (!try f.init()) return error.SkipZigTest;
    defer f.deinit();
    const topic = try f.createTopic("nack");
    const sub = try f.createSubscription("nack-sub", .{ .topic_id = topic.id, .ack_deadline_seconds = 60 });
    const id = try publishOne(&f, topic, .{ .data = "nack me" }, .{});

    var first: Collector = .init();
    defer first.deinit();
    try pullUntil(&f, sub, 1, f.patience(), &first, false);
    try testing.expectEqualStrings(id, first.messages.items[0].message_id);
    sub.nack(&.{first.messages.items[0].ack_id}) catch |err| return f.fail(err);

    var again: Collector = .init();
    defer again.deinit();
    try pullUntil(&f, sub, 1, f.patience(), &again, true);
    try testing.expectEqualStrings(id, again.messages.items[0].message_id);
}

// 8.
test "deadline: an unacked message is redelivered after its deadline" {
    var f: Fixture = undefined;
    if (!try f.init()) return error.SkipZigTest;
    defer f.deinit();
    const topic = try f.createTopic("dl");
    const sub = try f.createSubscription("dl-sub", .{ .topic_id = topic.id, .ack_deadline_seconds = 10 });
    const id = try publishOne(&f, topic, .{ .data = "let it expire" }, .{});

    var first: Collector = .init();
    defer first.deinit();
    try pullUntil(&f, sub, 1, f.patience(), &first, false);
    const pulled_at = nowMs();

    var again: Collector = .init();
    defer again.deinit();
    try pullUntil(&f, sub, 1, 10 + f.patience(), &again, true);
    try testing.expectEqualStrings(id, again.messages.items[0].message_id);
    // Not before the deadline (allowing a second of clock slack).
    try testing.expect(nowMs() - pulled_at >= 9_000);
}

// 9.
test "ordering key: messages arrive in publish order" {
    var f: Fixture = undefined;
    if (!try f.init()) return error.SkipZigTest;
    defer f.deinit();
    const topic = try f.createTopic("ord");
    const sub = try f.createSubscription("ord-sub", .{ .topic_id = topic.id, .enable_message_ordering = true });

    const bodies = [_][]const u8{ "0", "1", "2", "3", "4" };
    for (bodies) |b| _ = try publishOne(&f, topic, .{ .data = b }, .{ .ordering_key = "user-42" });

    var got: Collector = .init();
    defer got.deinit();
    try pullUntil(&f, sub, bodies.len, f.patience(), &got, true);
    try testing.expectEqual(bodies.len, got.messages.items.len);
    for (bodies, got.messages.items) |want, m| {
        try testing.expectEqualStrings(want, m.data);
        try testing.expectEqualStrings("user-42", m.ordering_key);
    }
}

// 10.
test "pagination: list topics two at a time until the token runs out" {
    var f: Fixture = undefined;
    if (!try f.init()) return error.SkipZigTest;
    defer f.deinit();
    var names: [5][]const u8 = undefined;
    for (&names, 0..) |*n, i| {
        var buf: [8]u8 = undefined;
        n.* = (try f.createTopic(try std.fmt.bufPrint(&buf, "page-{d}", .{i}))).id;
    }

    var seen: [5]bool = @splat(false);
    var pages: usize = 0;
    var token: ?[]const u8 = null;
    var token_arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer token_arena.deinit();
    while (true) : (pages += 1) {
        if (pages > 5000) return error.TestTooManyPages;
        var page = f.client.listTopics(.{ .page_size = 2, .page_token = token }) catch |err| return f.fail(err);
        defer page.deinit();
        try testing.expect(page.value.topics.len <= 2);
        for (page.value.topics) |t| {
            for (names, &seen) |n, *s| {
                if (std.mem.endsWith(u8, t.name, n)) s.* = true;
            }
        }
        token = if (page.value.next_page_token) |t| try token_arena.allocator().dupe(u8, t) else break;
    }
    for (seen) |s| try testing.expect(s);
    try testing.expect(pages >= 2);
}

test "pagination: list subscriptions two at a time" {
    var f: Fixture = undefined;
    if (!try f.init()) return error.SkipZigTest;
    defer f.deinit();
    const topic = try f.createTopic("subpage");
    var names: [3][]const u8 = undefined;
    for (&names, 0..) |*n, i| {
        var buf: [8]u8 = undefined;
        n.* = (try f.createSubscription(try std.fmt.bufPrint(&buf, "s-{d}", .{i}), .{ .topic_id = topic.id })).id;
    }
    var seen: [3]bool = @splat(false);
    var token: ?[]const u8 = null;
    var token_arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer token_arena.deinit();
    for (0..5000) |_| {
        var page = f.client.listSubscriptions(.{ .page_size = 2, .page_token = token }) catch |err| return f.fail(err);
        defer page.deinit();
        for (page.value.subscriptions) |s| {
            for (names, &seen) |n, *hit| {
                if (std.mem.endsWith(u8, s.name, n)) hit.* = true;
            }
        }
        token = if (page.value.next_page_token) |t| try token_arena.allocator().dupe(u8, t) else break;
    }
    for (seen) |s| try testing.expect(s);
}

test "ids with literal % and + reach the server intact" {
    var f: Fixture = undefined;
    if (!try f.init()) return error.SkipZigTest;
    defer f.deinit();
    // Unencoded, the server would decode %41 and create "...-aAb".
    const topic = try f.createTopic("a%41+b");
    var got = topic.get() catch |err| return f.fail(err);
    defer got.deinit();
    try testing.expect(std.mem.endsWith(u8, got.value.name, "-a%41+b"));
    // The emulator (0.8.35) decodes a literal "%25" twice, storing "%".
    // Production decodes once, like `%41` above.
    const sub_suffix = if (f.production) "s%25+x~y" else "s%7E+x~y";
    const sub = try f.createSubscription(sub_suffix, .{ .topic_id = topic.id });
    var info = sub.get() catch |err| return f.fail(err);
    defer info.deinit();
    try testing.expect(std.mem.endsWith(u8, info.value.name, sub_suffix));
    try testing.expect(std.mem.endsWith(u8, info.value.topic, "-a%41+b"));
}

test "subscription get reflects its configuration" {
    var f: Fixture = undefined;
    if (!try f.init()) return error.SkipZigTest;
    defer f.deinit();
    const topic = try f.createTopic("cfg");
    const sub = try f.createSubscription("cfg-sub", .{ .topic_id = topic.id, .ack_deadline_seconds = 42, .enable_message_ordering = true });
    var info = sub.get() catch |err| return f.fail(err);
    defer info.deinit();
    try testing.expectEqual(42, info.value.ack_deadline_seconds);
    try testing.expect(info.value.enable_message_ordering);
    try testing.expect(std.mem.endsWith(u8, info.value.topic, topic.id));
}

test "limits: the largest attributes and a 1 MiB payload round-trip" {
    var f: Fixture = undefined;
    if (!try f.init()) return error.SkipZigTest;
    defer f.deinit();
    const topic = try f.createTopic("big");
    const sub = try f.createSubscription("big-sub", .{ .topic_id = topic.id });

    const gpa = testing.allocator;
    const data = try gpa.alloc(u8, 1024 * 1024);
    defer gpa.free(data);
    var prng: std.Random.DefaultPrng = .init(42);
    prng.random().bytes(data);

    var attrs: [pubsub.limits.max_attributes]pubsub.Attribute = undefined;
    var keys: [pubsub.limits.max_attributes][pubsub.limits.max_attribute_key_bytes]u8 = undefined;
    const value: [pubsub.limits.max_attribute_value_bytes]u8 = @splat('v');
    for (&attrs, &keys, 0..) |*a, *k, i| {
        @memset(k, 'k');
        _ = std.fmt.bufPrint(k, "{d:0>3}", .{i}) catch unreachable;
        a.* = .{ .key = k, .value = &value };
    }
    _ = try publishOne(&f, topic, .{ .data = data, .attributes = &attrs }, .{});

    var got: Collector = .init();
    defer got.deinit();
    try pullUntil(&f, sub, 1, f.patience(), &got, true);
    const m = got.messages.items[0];
    try testing.expectEqualSlices(u8, data, m.data);
    try testing.expectEqual(attrs.len, m.attributes.len);
}

test "batch: 1000 messages in one publish, pulled and acked in bulk" {
    var f: Fixture = undefined;
    if (!try f.init()) return error.SkipZigTest;
    defer f.deinit();
    const topic = try f.createTopic("batch");
    const sub = try f.createSubscription("batch-sub", .{ .topic_id = topic.id, .ack_deadline_seconds = 120 });

    var bodies: [1000][8]u8 = undefined;
    var messages: [1000]pubsub.Message = undefined;
    for (&bodies, &messages, 0..) |*b, *m, i| {
        _ = std.fmt.bufPrint(b, "{d:0>8}", .{i}) catch unreachable;
        m.* = .{ .data = b };
    }
    var sent = topic.publish(&messages, .{}) catch |err| return f.fail(err);
    defer sent.deinit();
    try testing.expectEqual(1000, sent.value.message_ids.len);

    // Collect everything first, then ack all ids in a single call.
    var got: Collector = .init();
    defer got.deinit();
    try pullUntil(&f, sub, 1000, 2 * f.patience(), &got, false);
    const ids = try testing.allocator.alloc([]const u8, got.messages.items.len);
    defer testing.allocator.free(ids);
    for (got.messages.items, ids) |m, *id| id.* = m.ack_id;
    sub.ack(ids) catch |err| return f.fail(err);

    var distinct: std.StringHashMapUnmanaged(void) = .empty;
    defer distinct.deinit(testing.allocator);
    for (got.messages.items) |m| try distinct.put(testing.allocator, m.data, {});
    try testing.expectEqual(1000, distinct.count());
    try expectNoMessages(&f, sub);
}

test "modifyAckDeadline extends the lease" {
    var f: Fixture = undefined;
    if (!try f.init()) return error.SkipZigTest;
    defer f.deinit();
    const topic = try f.createTopic("lease");
    const sub = try f.createSubscription("lease-sub", .{ .topic_id = topic.id, .ack_deadline_seconds = 10 });
    _ = try publishOne(&f, topic, .{ .data = "hold" }, .{});

    var got: Collector = .init();
    defer got.deinit();
    try pullUntil(&f, sub, 1, f.patience(), &got, false);
    const ack_id = got.messages.items[0].ack_id;
    sub.modifyAckDeadline(&.{ack_id}, 120) catch |err| return f.fail(err);
    // Past the original 10 s deadline, the message is still leased to us.
    try testing.io.sleep(.fromSeconds(14), .awake);
    try expectNoMessages(&f, sub);
    sub.ack(&.{ack_id}) catch |err| return f.fail(err);
}

test "calls on deleted resources are NotFound" {
    var f: Fixture = undefined;
    if (!try f.init()) return error.SkipZigTest;
    defer f.deinit();
    const topic = f.client.topic(f.id("never-created"));
    try testing.expectError(error.NotFound, topic.publish(&.{.{ .data = "x" }}, .{}));
    try testing.expectError(error.NotFound, topic.delete());
    const sub = f.client.subscription(f.id("never-created-sub"));
    try testing.expectError(error.NotFound, sub.pull(.{ .return_immediately = true }));
    try testing.expectError(error.NotFound, sub.get());
}

test "empty pull with return_immediately returns promptly" {
    var f: Fixture = undefined;
    if (!try f.init()) return error.SkipZigTest;
    defer f.deinit();
    const topic = try f.createTopic("empty");
    const sub = try f.createSubscription("empty-sub", .{ .topic_id = topic.id });
    const started = nowMs();
    var batch = sub.pull(.{ .return_immediately = true }) catch |err| return f.fail(err);
    defer batch.deinit();
    try testing.expectEqual(0, batch.value.messages.len);
    try testing.expect(nowMs() - started < 10_000);
}

test "cancel: a held pull returns error.Canceled when its task is canceled" {
    var f: Fixture = undefined;
    if (!try f.init()) return error.SkipZigTest;
    defer f.deinit();
    const topic = try f.createTopic("cancel");
    const sub = try f.createSubscription("cancel-sub", .{ .topic_id = topic.id });

    const Pull = struct {
        fn run(s: pubsub.Subscription) pubsub.Error!usize {
            var batch = try s.pull(.{});
            defer batch.deinit();
            return batch.value.messages.len;
        }
    };
    // Without return_immediately the server holds an empty pull open.
    var pending = try testing.io.concurrent(Pull.run, .{sub});
    try testing.io.sleep(.fromMilliseconds(500), .awake);
    const started = nowMs();
    try testing.expectError(error.Canceled, pending.cancel(testing.io));
    try testing.expect(nowMs() - started < 2_000);

    // The client still works after a canceled call.
    var info = sub.get() catch |err| return f.fail(err);
    info.deinit();
}

test "timeout: race a held pull against a sleep with Io.Select" {
    var f: Fixture = undefined;
    if (!try f.init()) return error.SkipZigTest;
    defer f.deinit();
    const topic = try f.createTopic("race");
    const sub = try f.createSubscription("race-sub", .{ .topic_id = topic.id });

    // The pattern from docs/essentials.md: whichever finishes first wins, and the
    // other is canceled. An empty subscription holds the pull open, so the
    // timer wins here.
    const Race = union(enum) {
        pulled: pubsub.Error!pubsub.Owned(pubsub.PullResult),
        timed_out: std.Io.Cancelable!void,
    };
    var buffer: [2]Race = undefined;
    var select: std.Io.Select(Race) = .init(testing.io, &buffer);
    try select.concurrent(.pulled, pubsub.Subscription.pull, .{ sub, .{} });
    try select.concurrent(.timed_out, std.Io.sleep, .{ testing.io, .fromMilliseconds(500), .awake });
    const started = nowMs();
    const first = try select.await();
    // Cancel the loser. It may have finished first, so free what it returned.
    while (select.cancel()) |other| switch (other) {
        .pulled => |result| if (result) |owned| {
            var batch = owned;
            batch.deinit();
        } else |_| {},
        .timed_out => {},
    };
    try testing.expect(first == .timed_out);
    try testing.expect(nowMs() - started < 5_000);
}

/// A handler for the subscriber tests: counts distinct message bodies,
/// optionally failing each body's first delivery, and stops the
/// subscriber once `want` distinct bodies succeeded.
const Worker = struct {
    gpa: Allocator = undefined,
    subscriber: *pubsub.Subscriber = undefined,
    want: usize = 0,
    fail_first: bool = false,
    sleep_ms: i64 = 0,
    /// Sleep this long on a body's first delivery only.
    sleep_first_ms: i64 = 0,
    mutex: std.Io.Mutex = .init,
    /// Body -> deliveries seen (successes and failures).
    deliveries: std.StringHashMapUnmanaged(usize) = .empty,
    /// Body -> handler calls started, counted before any sleep, so that a
    /// redelivery arriving while the first delivery sleeps is the second.
    starts: std.StringHashMapUnmanaged(usize) = .empty,
    distinct_done: usize = 0,

    fn deinit(w: *Worker) void {
        var it = w.deliveries.keyIterator();
        while (it.next()) |key| w.gpa.free(key.*);
        w.deliveries.deinit(w.gpa);
        var started = w.starts.keyIterator();
        while (started.next()) |key| w.gpa.free(key.*);
        w.starts.deinit(w.gpa);
    }

    fn handler(w: *Worker) pubsub.Subscriber.Handler {
        return .{ .ptr = w, .vtable = &.{ .handle = handle } };
    }

    fn handle(ptr: *anyopaque, io: std.Io, message: pubsub.ReceivedMessage) anyerror!void {
        const w: *Worker = @ptrCast(@alignCast(ptr));
        const start = s: {
            w.mutex.lockUncancelable(io);
            defer w.mutex.unlock(io);
            const entry = try w.starts.getOrPut(w.gpa, message.data);
            if (!entry.found_existing) {
                entry.key_ptr.* = try w.gpa.dupe(u8, message.data);
                entry.value_ptr.* = 0;
            }
            entry.value_ptr.* += 1;
            break :s entry.value_ptr.*;
        };
        if (w.sleep_ms > 0) try io.sleep(.fromMilliseconds(w.sleep_ms), .awake);
        if (start == 1 and w.sleep_first_ms > 0) try io.sleep(.fromMilliseconds(w.sleep_first_ms), .awake);
        w.mutex.lockUncancelable(io);
        defer w.mutex.unlock(io);
        const entry = try w.deliveries.getOrPut(w.gpa, message.data);
        if (!entry.found_existing) {
            entry.key_ptr.* = try w.gpa.dupe(u8, message.data);
            entry.value_ptr.* = 0;
        }
        entry.value_ptr.* += 1;
        if (w.fail_first and entry.value_ptr.* == 1) return error.FirstDeliveryRefused;
        if (entry.value_ptr.* == @as(usize, if (w.fail_first) 2 else 1)) {
            w.distinct_done += 1;
            if (w.distinct_done >= w.want) w.subscriber.stop();
        }
    }

    fn done(w: *Worker) bool {
        w.mutex.lockUncancelable(testing.io);
        defer w.mutex.unlock(testing.io);
        return w.distinct_done >= w.want;
    }
};

const SubscriberKnobs = struct {
    extension_period_s: ?u32 = null,
    max_extension_s: u32 = 600,
};

/// Builds a subscriber against the fixture's server and runs it under
/// `worker`'s control, failing rather than hanging if it never finishes.
fn runSubscriber(f: *Fixture, sub: pubsub.Subscription, worker: *Worker, concurrency: u16, timeout_s: i64, knobs: SubscriberKnobs) !pubsub.Subscriber.Stats {
    const io = testing.io;
    var subscriber: pubsub.Subscriber = try .init(testing.allocator, io, .{
        .subscription_id = sub.id,
        .client = .{
            .project_id = f.client.project_id,
            .endpoint = .{ .url = f.client.base_url, .emulator = f.client.emulator },
            .token_provider = if (f.production) f.token.provider() else null,
        },
        .concurrency = concurrency,
        .extension_period_s = knobs.extension_period_s,
        .max_extension_s = knobs.max_extension_s,
    });
    defer subscriber.deinit();
    worker.subscriber = &subscriber;

    var running = try io.concurrent(pubsub.Subscriber.run, .{ &subscriber, worker.handler() });
    const deadline = nowMs() + timeout_s * 1000;
    while (!worker.done()) {
        if (nowMs() > deadline) {
            _ = running.cancel(io) catch {};
            std.debug.print("subscriber timed out with {d} of {d} done\n", .{ worker.distinct_done, worker.want });
            return error.TestTimedOut;
        }
        try io.sleep(.fromMilliseconds(100), .awake);
    }
    running.await(io) catch |err| return f.fail(err);
    return subscriber.stats();
}

test "subscriber: concurrent handlers process every message, then ack it away" {
    var f: Fixture = undefined;
    if (!try f.init()) return error.SkipZigTest;
    defer f.deinit();
    const topic = try f.createTopic("subw");
    const sub = try f.createSubscription("subw-sub", .{ .topic_id = topic.id });

    var bodies: [40][8]u8 = undefined;
    var messages: [40]pubsub.Message = undefined;
    for (&bodies, &messages, 0..) |*b, *m, i| {
        _ = std.fmt.bufPrint(b, "{d:0>8}", .{i}) catch unreachable;
        m.* = .{ .data = b };
    }
    var sent = topic.publish(&messages, .{}) catch |err| return f.fail(err);
    sent.deinit();

    var worker: Worker = .{ .gpa = testing.allocator, .want = 40 };
    defer worker.deinit();
    const counts = try runSubscriber(&f, sub, &worker, 4, f.patience(), .{});
    try testing.expectEqual(40, worker.deliveries.count());
    try testing.expect(counts.acked >= 40);
    try testing.expectEqual(counts.received, counts.acked + counts.ack_failed + counts.nacked + counts.receipt_refused);
    try expectNoMessages(&f, sub);
}

test "subscriber: a failing handler sees the message again, and nothing is lost" {
    var f: Fixture = undefined;
    if (!try f.init()) return error.SkipZigTest;
    defer f.deinit();
    const topic = try f.createTopic("subr");
    const sub = try f.createSubscription("subr-sub", .{ .topic_id = topic.id });
    for (0..10) |i| {
        var buf: [8]u8 = undefined;
        _ = try publishOne(&f, topic, .{ .data = try std.fmt.bufPrint(&buf, "retry-{d}", .{i}) }, .{});
    }

    var worker: Worker = .{ .gpa = testing.allocator, .want = 10, .fail_first = true };
    defer worker.deinit();
    const counts = try runSubscriber(&f, sub, &worker, 2, 2 * f.patience(), .{});
    try testing.expectEqual(10, worker.deliveries.count());
    try testing.expect(counts.handler_failures >= 10);
    try testing.expect(counts.acked >= 10);
    try expectNoMessages(&f, sub);
}

test "subscriber: lease extension carries a handler past the ack deadline" {
    var f: Fixture = undefined;
    if (!try f.init()) return error.SkipZigTest;
    defer f.deinit();
    const topic = try f.createTopic("sublease");
    const sub = try f.createSubscription("sublease-sub", .{ .topic_id = topic.id, .ack_deadline_seconds = 10 });
    _ = try publishOne(&f, topic, .{ .data = "hold me past the deadline" }, .{});

    // The handler outlives the 10 s deadline; the subscriber's extensions
    // must keep the message leased, so it is handled exactly once.
    var worker: Worker = .{ .gpa = testing.allocator, .want = 1, .sleep_ms = 15_000 };
    defer worker.deinit();
    const counts = try runSubscriber(&f, sub, &worker, 1, 30 + f.patience(), .{});
    try testing.expectEqual(1, worker.deliveries.count());
    try testing.expectEqual(1, worker.deliveries.get("hold me past the deadline").?);
    try testing.expect(counts.extended >= 1);
    try testing.expectEqual(1, counts.acked);
    try expectNoMessages(&f, sub);
}

test "subscriber: on an exactly-once subscription, an ack that comes too late is counted, and the loop runs on" {
    // Regression: the refused ack stopped the whole subscriber.
    var f: Fixture = undefined;
    if (!try f.init()) return error.SkipZigTest;
    defer f.deinit();
    const topic = try f.createTopic("eod");
    const sub = try f.createSubscription("eod-sub", .{
        .topic_id = topic.id,
        .ack_deadline_seconds = 10,
        .enable_exactly_once_delivery = true,
    });
    _ = try publishOne(&f, topic, .{ .data = "outlives its lease" }, .{});

    // The first delivery sleeps past its lease, which is never extended
    // (max_extension_s is 1 s, the first extension comes at 5 s), so the
    // message comes again and a second handler acks it. The first
    // handler's ack is then refused.
    var worker: Worker = .{ .gpa = testing.allocator, .want = 1, .sleep_first_ms = 15_000 };
    defer worker.deinit();
    const counts = try runSubscriber(&f, sub, &worker, 2, 30 + f.patience(), .{ .extension_period_s = 10, .max_extension_s = 1 });
    try testing.expectEqual(2, worker.starts.get("outlives its lease").?);
    try testing.expectEqual(1, counts.acked);
    try testing.expectEqual(1, counts.ack_failed);
    try testing.expectEqual(counts.received, counts.acked + counts.ack_failed + counts.nacked + counts.receipt_refused);
    try expectNoMessages(&f, sub);
}

test "ackWithResults: a lapsed id and a live one in the same request" {
    var f: Fixture = undefined;
    if (!try f.init()) return error.SkipZigTest;
    defer f.deinit();
    const topic = try f.createTopic("eodres");
    const sub = try f.createSubscription("eodres-sub", .{
        .topic_id = topic.id,
        .ack_deadline_seconds = 10,
        .enable_exactly_once_delivery = true,
    });
    _ = try publishOne(&f, topic, .{ .data = "lapses" }, .{});
    var first = Collector.init();
    defer first.deinit();
    try pullUntil(&f, sub, 1, f.patience(), &first, false);
    // Past the 10 s lease: the message comes again under a new ack id.
    try testing.io.sleep(.fromSeconds(12), .awake);
    var again = Collector.init();
    defer again.deinit();
    try pullUntil(&f, sub, 1, f.patience(), &again, false);

    var results: [2]pubsub.AckResult = undefined;
    sub.ackWithResults(&.{ first.messages.items[0].ack_id, again.messages.items[0].ack_id }, &results) catch |err| return f.fail(err);
    if (f.production) {
        // Production names the lapsed id and takes the live one.
        try testing.expectEqualSlices(pubsub.AckResult, &.{ .invalid_ack_id, .ok }, &results);
    } else {
        // The emulator refuses the request with no word per id, though it
        // too takes the live one.
        try testing.expectEqualSlices(pubsub.AckResult, &.{ .other, .other }, &results);
    }
    try expectNoMessages(&f, sub);
}

// Settings and updates.

fn attributeOf(attrs: []const pubsub.Attribute, key: []const u8) ?[]const u8 {
    for (attrs) |a| {
        if (std.mem.eql(u8, a.key, key)) return a.value;
    }
    return null;
}

test "subscription settings: every setting reads back as it was made" {
    var f: Fixture = undefined;
    if (!try f.init()) return error.SkipZigTest;
    defer f.deinit();
    const topic = try f.createTopic("set");
    const dead = try f.createTopic("set-dead");
    const sub = try f.createSubscription("set-sub", .{
        .topic_id = topic.id,
        .ack_deadline_seconds = 20,
        .enable_message_ordering = true,
        .enable_exactly_once_delivery = true,
        .filter = "attributes.kind = \"a\"",
        .dead_letter_policy = .{ .topic = dead.id, .max_delivery_attempts = 7 },
        .retry_policy = .{ .minimum = .fromMilliseconds(1500), .maximum = .fromSeconds(30) },
        .message_retention = .fromSeconds(1200),
        .retain_acked_messages = true,
        .expiration = .{ .after = .fromSeconds(2 * 24 * 60 * 60) },
        .labels = &.{ .{ .key = "team", .value = "zig" }, .{ .key = "suite", .value = "integration" } },
    });
    var got = sub.get() catch |err| return f.fail(err);
    defer got.deinit();
    const s = got.value;
    try testing.expectEqual(20, s.ack_deadline_seconds);
    try testing.expect(s.enable_message_ordering and s.enable_exactly_once_delivery and s.retain_acked_messages);
    try testing.expectEqualStrings("attributes.kind = \"a\"", s.filter);
    try testing.expect(std.mem.endsWith(u8, s.dead_letter_policy.?.topic, dead.id));
    try testing.expectEqual(7, s.dead_letter_policy.?.max_delivery_attempts);
    try testing.expectEqual(std.Io.Duration.fromMilliseconds(1500), s.retry_policy.?.minimum);
    try testing.expectEqual(std.Io.Duration.fromSeconds(30), s.retry_policy.?.maximum);
    try testing.expectEqual(std.Io.Duration.fromSeconds(1200), s.message_retention.?);
    try testing.expectEqual(std.Io.Duration.fromSeconds(2 * 24 * 60 * 60), s.expiration.after);
    try testing.expectEqualStrings("zig", s.label("team").?);
    try testing.expectEqualStrings("integration", s.label("suite").?);
    try testing.expectEqual(.active, s.state);
}

test "subscription update: settings change, and clear back to their defaults" {
    var f: Fixture = undefined;
    if (!try f.init()) return error.SkipZigTest;
    defer f.deinit();
    const topic = try f.createTopic("upd");
    const dead = try f.createTopic("upd-dead");
    const sub = try f.createSubscription("upd-sub", .{ .topic_id = topic.id });

    var changed = sub.update(.{
        .ack_deadline_seconds = 30,
        .enable_exactly_once_delivery = true,
        .dead_letter_policy = .{ .set = .{ .topic = dead.id } },
        .retry_policy = .{ .set = .{ .minimum = .fromSeconds(1), .maximum = .fromSeconds(5) } },
        .message_retention = .{ .set = .fromSeconds(3600) },
        .retain_acked_messages = true,
    }) catch |err| return f.fail(err);
    defer changed.deinit();
    try testing.expectEqual(30, changed.value.ack_deadline_seconds);
    try testing.expect(changed.value.enable_exactly_once_delivery and changed.value.retain_acked_messages);
    try testing.expect(std.mem.endsWith(u8, changed.value.dead_letter_policy.?.topic, dead.id));
    try testing.expectEqual(std.Io.Duration.fromSeconds(5), changed.value.retry_policy.?.maximum);
    try testing.expectEqual(std.Io.Duration.fromSeconds(3600), changed.value.message_retention.?);

    var cleared = sub.update(.{
        .enable_exactly_once_delivery = false,
        .dead_letter_policy = .clear,
        .retry_policy = .clear,
        .message_retention = .clear,
    }) catch |err| return f.fail(err);
    defer cleared.deinit();
    try testing.expect(!cleared.value.enable_exactly_once_delivery);
    try testing.expectEqual(null, cleared.value.dead_letter_policy);
    try testing.expectEqual(null, cleared.value.retry_policy);
    // Cleared retention is Pub/Sub's default, 7 days.
    try testing.expectEqual(std.Io.Duration.fromSeconds(7 * 24 * 60 * 60), cleared.value.message_retention.?);
    // Untouched by either update.
    try testing.expectEqual(30, cleared.value.ack_deadline_seconds);

    // The emulator cannot update labels or expiration; production can.
    if (!f.production) return;
    var labelled = sub.update(.{ .labels = &.{.{ .key = "team", .value = "zig" }}, .expiration = .never }) catch |err| return f.fail(err);
    defer labelled.deinit();
    try testing.expectEqualStrings("zig", labelled.value.label("team").?);
    try testing.expectEqual(.never, std.meta.activeTag(labelled.value.expiration));
    var unlabelled = sub.update(.{ .labels = &.{}, .expiration = .default }) catch |err| return f.fail(err);
    defer unlabelled.deinit();
    try testing.expectEqual(0, unlabelled.value.labels.len);
    try testing.expect(std.meta.activeTag(unlabelled.value.expiration) != .never);
}

test "dead-lettering: after the last attempt, a message moves on, marked with where it came from" {
    var f: Fixture = undefined;
    if (!try f.init()) return error.SkipZigTest;
    defer f.deinit();
    // Production forwards only once Pub/Sub's service agent may publish to
    // the dead-letter topic and acknowledge here, and the agent is named by
    // the project's number.
    const project_number: ?[]const u8 = if (f.production) f.env.get("PUBSUB_TEST_PROJECT_NUMBER") orelse
        return error.SkipZigTest else null;
    const topic = try f.createTopic("dlq");
    const dead = try f.createTopic("dlq-dead");
    const dead_sub = try f.createSubscription("dlq-dead-sub", .{ .topic_id = dead.id });
    const sub = try f.createSubscription("dlq-sub", .{
        .topic_id = topic.id,
        .dead_letter_policy = .{ .topic = dead.id, .max_delivery_attempts = 5 },
    });
    if (project_number) |number| {
        try f.grantServiceAgent(number, .topic, dead.id, "roles/pubsub.publisher");
        try f.grantServiceAgent(number, .subscription, sub.id, "roles/pubsub.subscriber");
    }
    _ = try publishOne(&f, topic, .{ .data = "doomed" }, .{});

    // Released after each of its five deliveries, it then goes.
    for (0..5) |_| {
        var batch = Collector.init();
        defer batch.deinit();
        try pullUntil(&f, sub, 1, f.patience(), &batch, false);
        sub.nack(&.{batch.messages.items[0].ack_id}) catch |err| return f.fail(err);
    }
    // The emulator forwards when the source is pulled next, production on
    // its own within seconds; either way nothing more is delivered there.
    try expectNoMessages(&f, sub);
    var forwarded = Collector.init();
    defer forwarded.deinit();
    try pullUntil(&f, dead_sub, 1, f.patience(), &forwarded, true);
    const m = forwarded.messages.items[0];
    try testing.expectEqualStrings("doomed", m.data);
    try testing.expectEqualStrings("5", attributeOf(m.attributes, "CloudPubSubDeadLetterSourceDeliveryCount").?);
    try testing.expectEqualStrings(sub.id, attributeOf(m.attributes, "CloudPubSubDeadLetterSourceSubscription").?);
}

test "IAM: the emulator answers every call Unimplemented; production grants once, revokes once, tests, and takes two grants at once" {
    var f: Fixture = undefined;
    if (!try f.init()) return error.SkipZigTest;
    defer f.deinit();
    const topic = try f.createTopic("iam");
    const sub = try f.createSubscription("iam-sub", .{ .topic_id = topic.id });
    if (!f.production) {
        try testing.expectError(error.Unimplemented, topic.iamPolicy());
        try testing.expectError(error.Unimplemented, sub.iamPolicy());
        try testing.expectError(error.Unimplemented, sub.addIamBinding("roles/pubsub.viewer", "user:a@example.com"));
        try testing.expectError(error.Unimplemented, topic.testIamPermissions(&.{"pubsub.topics.get"}));
        return;
    }
    // The member is Pub/Sub's service agent, named by the project's number.
    const number = f.env.get("PUBSUB_TEST_PROJECT_NUMBER") orelse return error.SkipZigTest;
    const a = f.arena.allocator();
    const agent = try a.print("serviceAccount:service-{s}@gcp-sa-pubsub.iam.gserviceaccount.com", .{number});
    const shouting = try a.print("serviceAccount:{s}", .{try std.ascii.allocUpperString(a, agent["serviceAccount:".len..])});
    const role = "roles/pubsub.viewer";

    var fresh = sub.iamPolicy() catch |err| return f.fail(err);
    defer fresh.deinit();
    try testing.expectEqualStrings("ACAB", fresh.value.etag.?);
    try testing.expectEqual(0, fresh.value.bindings.len);

    var granted = sub.addIamBinding(role, agent) catch |err| return f.fail(err);
    defer granted.deinit();
    try testing.expect(granted.value.grants(role, agent));
    // Held already, asked in capitals: nothing written, so the etag stands.
    var again = sub.addIamBinding(role, shouting) catch |err| return f.fail(err);
    defer again.deinit();
    try testing.expectEqualStrings(granted.value.etag.?, again.value.etag.?);

    var held = sub.testIamPermissions(&.{ "pubsub.subscriptions.get", "pubsub.subscriptions.consume" }) catch |err| return f.fail(err);
    defer held.deinit();
    try testing.expectEqual(2, held.value.len);

    var revoked = sub.removeIamBinding(role, shouting) catch |err| return f.fail(err);
    defer revoked.deinit();
    try testing.expect(!revoked.value.grants(role, agent));
    var gone = sub.removeIamBinding(role, agent) catch |err| return f.fail(err);
    defer gone.deinit();
    try testing.expectEqualStrings(revoked.value.etag.?, gone.value.etag.?);

    // Refused here, as production refuses it.
    try testing.expectError(error.InvalidArgument, sub.setIamPolicy(.{ .bindings = &.{.{ .role = role, .members = &.{agent}, .condition = "{\"title\":\"t\",\"expression\":\"true\"}" }} }));

    // A write under an etag another write has moved on is Aborted.
    var stale = topic.iamPolicy() catch |err| return f.fail(err);
    defer stale.deinit();
    var scratch: std.heap.ArenaAllocator = .init(testing.allocator);
    defer scratch.deinit();
    var first = topic.setIamPolicy(try pubsub.iam.withMember(scratch.allocator(), stale.value, role, agent)) catch |err| return f.fail(err);
    first.deinit();
    try testing.expectError(error.Aborted, topic.setIamPolicy(try pubsub.iam.withMember(scratch.allocator(), stale.value, "roles/pubsub.subscriber", agent)));

    // Two clients granting on one topic at once both land: each starts
    // over when the other came in between.
    var other = try pubsub.Client.init(testing.allocator, testing.io, .{
        .project_id = f.client.project_id,
        .token_provider = f.token.provider(),
        .user_agent = "zig-pubsub-integration/0.1",
    });
    defer other.deinit();
    const Grant = struct {
        fn run(t: pubsub.Topic, r: []const u8, member: []const u8) pubsub.Error!void {
            var p = try t.addIamBinding(r, member);
            p.deinit();
        }
    };
    var one = try testing.io.concurrent(Grant.run, .{ topic, "roles/pubsub.subscriber", agent });
    var two = try testing.io.concurrent(Grant.run, .{ other.topic(topic.id), "roles/pubsub.editor", agent });
    const one_result = one.await(testing.io);
    const two_result = two.await(testing.io);
    one_result catch |err| return f.fail(err);
    two_result catch |err| return f.fail(err);
    var final = topic.iamPolicy() catch |err| return f.fail(err);
    defer final.deinit();
    for ([_][]const u8{ role, "roles/pubsub.subscriber", "roles/pubsub.editor" }) |r| try testing.expect(final.value.grants(r, agent));
}

test "filter: only messages whose attributes match are delivered" {
    var f: Fixture = undefined;
    if (!try f.init()) return error.SkipZigTest;
    defer f.deinit();
    const topic = try f.createTopic("flt");
    const sub = try f.createSubscription("flt-sub", .{ .topic_id = topic.id, .filter = "attributes.kind = \"keep\"" });
    _ = try publishOne(&f, topic, .{ .data = "kept", .attributes = &.{.{ .key = "kind", .value = "keep" }} }, .{});
    _ = try publishOne(&f, topic, .{ .data = "dropped", .attributes = &.{.{ .key = "kind", .value = "drop" }} }, .{});
    var got = Collector.init();
    defer got.deinit();
    try pullUntil(&f, sub, 1, f.patience(), &got, true);
    try testing.expectEqualStrings("kept", got.messages.items[0].data);
    try expectNoMessages(&f, sub);
}

test "topic settings: labels and retention read back, and retention changes and clears" {
    var f: Fixture = undefined;
    if (!try f.init()) return error.SkipZigTest;
    defer f.deinit();
    const topic = f.client.topic(f.id("tset"));
    try f.topics.append(testing.allocator, topic.id);
    var created = topic.create(.{
        .labels = &.{.{ .key = "suite", .value = "integration" }},
        .message_retention = .fromSeconds(3600),
    }) catch |err| return f.fail(err);
    created.deinit();
    var got = topic.get() catch |err| return f.fail(err);
    defer got.deinit();
    try testing.expectEqualStrings("integration", got.value.label("suite").?);
    try testing.expectEqual(std.Io.Duration.fromSeconds(3600), got.value.message_retention.?);

    var longer = topic.update(.{ .message_retention = .{ .set = .fromSeconds(7200) } }) catch |err| return f.fail(err);
    defer longer.deinit();
    try testing.expectEqual(std.Io.Duration.fromSeconds(7200), longer.value.message_retention.?);
    var none = topic.update(.{ .message_retention = .clear }) catch |err| return f.fail(err);
    defer none.deinit();
    if (f.production) {
        try testing.expectEqual(null, none.value.message_retention);
    } else {
        // The emulator answers a cleared retention with its longest, 31 days.
        try testing.expectEqual(std.Io.Duration.fromSeconds(31 * 24 * 60 * 60), none.value.message_retention.?);
    }

    // The emulator cannot update a topic's labels; production can.
    if (!f.production) return;
    var relabelled = topic.update(.{ .labels = &.{.{ .key = "suite", .value = "updated" }} }) catch |err| return f.fail(err);
    defer relabelled.deinit();
    try testing.expectEqualStrings("updated", relabelled.value.label("suite").?);
}

// Snapshots, and what a topic has attached.

/// Every name in one of a topic's lists, read a page of `page_size` at a
/// time.
fn allNames(f: *Fixture, topic: pubsub.Topic, comptime list: enum { subscriptions, snapshots }, page_size: u32) ![]const []const u8 {
    const a = f.arena.allocator();
    var names: std.ArrayList([]const u8) = .empty;
    var token: ?[]const u8 = null;
    var pages: usize = 0;
    while (true) : (pages += 1) {
        if (pages > 50) return error.TestTooManyPages;
        const options: pubsub.PageOptions = .{ .page_size = page_size, .page_token = token };
        var page = (switch (list) {
            .subscriptions => topic.listSubscriptions(options),
            .snapshots => topic.listSnapshots(options),
        }) catch |err| return f.fail(err);
        defer page.deinit();
        try testing.expect(page.value.names.len <= page_size);
        for (page.value.names) |name| try names.append(a, try a.dupe(u8, name));
        token = try a.dupe(u8, page.value.next_page_token orelse break);
    }
    return names.items;
}

fn holds(names: []const []const u8, name: []const u8) bool {
    for (names) |n| if (std.mem.eql(u8, n, name)) return true;
    return false;
}

test "snapshots: one is made, read, found in its project's list and its topic's, relabelled, and outlives its subscription and its topic" {
    var f: Fixture = undefined;
    if (!try f.init()) return error.SkipZigTest;
    defer f.deinit();
    const a = f.arena.allocator();
    const project = f.client.project_id;
    const topic = try f.createTopic("snap");
    const sub = try f.createSubscription("snap-sub", .{ .topic_id = topic.id });
    const other = try f.createSubscription("snap-sub2", .{ .topic_id = topic.id });
    const topic_name = try a.print("projects/{s}/topics/{s}", .{ project, topic.id });

    const snapshot = f.client.snapshot(f.id("snap"));
    try f.snapshots.append(testing.allocator, snapshot.id);
    const name = try a.print("projects/{s}/snapshots/{s}", .{ project, snapshot.id });
    var created = snapshot.create(.{
        .subscription = sub.id,
        .labels = &.{.{ .key = "suite", .value = "integration" }},
    }) catch |err| return f.fail(err);
    defer created.deinit();
    try testing.expectEqualStrings(name, created.value.name);
    try testing.expectEqualStrings(topic_name, created.value.topic);
    // It lives 7 days, less the age of what its subscription held, and
    // nothing here is minutes old.
    const lifetime_s = created.value.expire_time.toSeconds() - std.Io.Clock.real.now(testing.io).toSeconds();
    try testing.expect(lifetime_s <= 7 * 86400 + 120);
    try testing.expect(lifetime_s >= 7 * 86400 - 600);
    if (f.production) {
        try testing.expectEqualStrings("integration", created.value.label("suite").?);
    } else {
        // The emulator keeps no labels, and says nothing of it.
        try testing.expectEqual(0, created.value.labels.len);
    }

    // Its name is taken, and a subscription that is not there has no
    // backlog to keep.
    try testing.expectError(error.AlreadyExists, snapshot.create(.{ .subscription = sub.id }));
    const absent = f.client.snapshot(f.id("snap-none"));
    try testing.expectError(error.NotFound, absent.create(.{ .subscription = f.id("no-such-sub") }));
    try testing.expectError(error.NotFound, absent.get());

    var got = snapshot.get() catch |err| return f.fail(err);
    defer got.deinit();
    try testing.expectEqual(created.value.expire_time, got.value.expire_time);

    // Whole among its project's snapshots, and by name among its topic's.
    var token: ?[]const u8 = null;
    const listed = search: while (true) {
        var page = f.client.listSnapshots(.{ .page_size = 1000, .page_token = token }) catch |err| return f.fail(err);
        defer page.deinit();
        for (page.value.snapshots) |s| {
            if (!std.mem.eql(u8, s.name, name)) continue;
            try testing.expectEqualStrings(topic_name, s.topic);
            try testing.expectEqual(created.value.expire_time, s.expire_time);
            break :search true;
        }
        token = try a.dupe(u8, page.value.next_page_token orelse break :search false);
    };
    try testing.expect(listed);
    const of_topic = try allNames(&f, topic, .snapshots, 100);
    try testing.expectEqual(1, of_topic.len);
    try testing.expectEqualStrings(name, of_topic[0]);

    // The topic's two subscriptions, one to a page, in the server's order.
    const attached = try allNames(&f, topic, .subscriptions, 1);
    try testing.expectEqual(2, attached.len);
    try testing.expect(holds(attached, try a.print("projects/{s}/subscriptions/{s}", .{ project, sub.id })));
    try testing.expect(holds(attached, try a.print("projects/{s}/subscriptions/{s}", .{ project, other.id })));

    if (f.production) {
        var relabelled = snapshot.update(.{ .labels = &.{.{ .key = "suite", .value = "updated" }} }) catch |err| return f.fail(err);
        defer relabelled.deinit();
        try testing.expectEqualStrings("updated", relabelled.value.label("suite").?);
        try testing.expectEqual(created.value.expire_time, relabelled.value.expire_time);
        var bare = snapshot.update(.{ .labels = &.{} }) catch |err| return f.fail(err);
        defer bare.deinit();
        try testing.expectEqual(0, bare.value.labels.len);
        // A fresh snapshot's policy is empty, and its maker may seek to it.
        var policy = snapshot.iamPolicy() catch |err| return f.fail(err);
        defer policy.deinit();
        try testing.expectEqual(0, policy.value.bindings.len);
        var held = snapshot.testIamPermissions(&.{"pubsub.snapshots.seek"}) catch |err| return f.fail(err);
        defer held.deinit();
        try testing.expectEqual(1, held.value.len);
    } else {
        // The emulator has no snapshot update, and serves a snapshot no
        // IAM call: it takes the method for part of the name.
        try testing.expectError(error.Unimplemented, snapshot.update(.{ .labels = &.{} }));
        try testing.expectError(error.InvalidArgument, snapshot.iamPolicy());
    }

    // It outlives the subscription it was made of, and then the topic.
    sub.delete() catch |err| return f.fail(err);
    var outlived = snapshot.get() catch |err| return f.fail(err);
    outlived.deinit();
    other.delete() catch |err| return f.fail(err);
    topic.delete() catch |err| return f.fail(err);
    var orphan = snapshot.get() catch |err| return f.fail(err);
    defer orphan.deinit();
    if (f.production) {
        try testing.expectEqualStrings("_deleted-topic_", orphan.value.topic);
        try testing.expectError(error.NotFound, topic.listSnapshots(.{}));
    } else {
        // The emulator goes on naming the topic, and listing for it.
        try testing.expectEqualStrings(topic_name, orphan.value.topic);
        try testing.expectEqual(1, (try allNames(&f, topic, .snapshots, 100)).len);
    }

    snapshot.delete() catch |err| return f.fail(err);
    try testing.expectError(error.NotFound, snapshot.delete());
    try testing.expectError(error.NotFound, snapshot.get());
}

// Seek and detach.

/// Pulls and acknowledges until every one of `wanted` came at least once.
/// More may come, and the same one twice: around a seek, production's
/// deliveries take up to a minute to settle.
fn pullEach(f: *Fixture, sub: pubsub.Subscription, wanted: []const []const u8, timeout_s: i64) !void {
    var seen: Collector = .init();
    defer seen.deinit();
    const deadline = nowMs() + timeout_s * 1000;
    while (true) {
        const missing = for (wanted) |data| {
            if (seen.find(data) == null) break data;
        } else return;
        if (nowMs() > deadline) {
            std.debug.print("timed out waiting for \"{s}\"\n", .{missing});
            return error.TestTimedOut;
        }
        var batch = sub.pull(.{ .max_messages = 1000, .return_immediately = true }) catch |err| return f.fail(err);
        defer batch.deinit();
        for (batch.value.messages) |m| try seen.add(m);
        if (batch.value.messages.len > 0) {
            const ids = try testing.allocator.alloc([]const u8, batch.value.messages.len);
            defer testing.allocator.free(ids);
            for (batch.value.messages, ids) |m, *id| id.* = m.ack_id;
            sub.ack(ids) catch |err| return f.fail(err);
        } else {
            try testing.io.sleep(.fromMilliseconds(250), .awake);
        }
    }
}

fn publishEach(f: *Fixture, topic: pubsub.Topic, data: []const []const u8) !void {
    for (data) |d| _ = try publishOne(f, topic, .{ .data = d }, .{});
}

test "seek: to a snapshot, back to a time, and ahead, on a subscription that retains what it acknowledged" {
    var f: Fixture = undefined;
    if (!try f.init()) return error.SkipZigTest;
    defer f.deinit();
    const topic = try f.createTopic("seek");
    const sub = try f.createSubscription("seek-sub", .{ .topic_id = topic.id, .retain_acked_messages = true });
    const other_topic = try f.createTopic("seek-other");
    const other_sub = try f.createSubscription("seek-other-sub", .{ .topic_id = other_topic.id });
    // A time before anything is published, by this machine's clock and,
    // with a second to spare, by the server's.
    const before = std.Io.Clock.real.now(testing.io);
    try testing.io.sleep(.fromMilliseconds(2000), .awake);

    try publishEach(&f, topic, &.{ "a", "b" });
    try pullEach(&f, sub, &.{ "a", "b" }, f.patience());
    // `c` and `d` are what the snapshot keeps: published, not acknowledged.
    try publishEach(&f, topic, &.{ "c", "d" });
    const snapshot = f.client.snapshot(f.id("seek-snap"));
    try f.snapshots.append(testing.allocator, snapshot.id);
    var kept = snapshot.create(.{ .subscription = sub.id }) catch |err| return f.fail(err);
    kept.deinit();
    try pullEach(&f, sub, &.{ "c", "d" }, f.patience());

    // To the snapshot: its two messages come again, and it stays.
    sub.seek(.{ .snapshot = snapshot.id }) catch |err| return f.fail(err);
    try pullEach(&f, sub, &.{ "c", "d" }, f.patience());
    var still = snapshot.get() catch |err| return f.fail(err);
    still.deinit();

    // Back to before everything: all four, the acknowledged ones retained.
    sub.seek(.{ .time = before }) catch |err| return f.fail(err);
    try pullEach(&f, sub, &.{ "a", "b", "c", "d" }, f.patience());

    // Ahead of everything: a purge. It is no standing filter: what is
    // published after it is delivered, an hour before the time it named.
    const ahead: std.Io.Timestamp = .{ .nanoseconds = std.Io.Clock.real.now(testing.io).nanoseconds + 3600 * std.time.ns_per_s };
    sub.seek(.{ .time = ahead }) catch |err| return f.fail(err);
    // Production can still deliver, for up to a minute, what the seek
    // acknowledged; the emulator's seek shows at once.
    if (!f.production) try expectNoMessages(&f, sub);
    try publishEach(&f, topic, &.{"e"});
    try pullEach(&f, sub, &.{"e"}, f.patience());

    // A snapshot serves its own topic's subscriptions and no other's.
    try testing.expectError(error.FailedPrecondition, other_sub.seek(.{ .snapshot = snapshot.id }));
    try testing.expect(std.mem.startsWith(u8, f.diag.message(), "The subscription's topic"));
    try testing.expectError(error.NotFound, sub.seek(.{ .snapshot = f.id("no-such-snap") }));
    try testing.expectError(error.NotFound, f.client.subscription(f.id("no-such-sub")).seek(.{ .time = before }));
}

test "detach: the emulator has none; production cuts the subscription off its topic for good" {
    var f: Fixture = undefined;
    if (!try f.init()) return error.SkipZigTest;
    defer f.deinit();
    const topic = try f.createTopic("detach");
    const sub = try f.createSubscription("detach-sub", .{ .topic_id = topic.id });
    if (!f.production) {
        try testing.expectError(error.Unimplemented, sub.detach());
        return;
    }
    const a = f.arena.allocator();
    const name = try a.print("projects/{s}/subscriptions/{s}", .{ f.client.project_id, sub.id });
    try testing.expect(holds(try allNames(&f, topic, .subscriptions, 100), name));

    sub.detach() catch |err| return f.fail(err);
    // It stays, reads back detached, and is gone from its topic's list.
    var got = sub.get() catch |err| return f.fail(err);
    defer got.deinit();
    try testing.expect(got.value.detached);
    try testing.expect(!holds(try allNames(&f, topic, .subscriptions, 100), name));

    // Within seconds, everything but a read, an update and a delete is
    // refused, a second detach among it.
    const Refused = struct {
        fn pull(s: pubsub.Subscription) anyerror!void {
            var batch = s.pull(.{ .return_immediately = true }) catch |err| {
                return if (err == error.FailedPrecondition) {} else err;
            };
            batch.deinit();
            return error.TestStillAttached;
        }
    };
    try eventually(&f, f.patience(), sub, Refused.pull);
    try testing.expectEqualStrings("This method is not supported on detached subscriptions.", f.diag.message());
    try testing.expectError(error.FailedPrecondition, sub.detach());
    try testing.expectError(error.FailedPrecondition, sub.seek(.{ .time = std.Io.Clock.real.now(testing.io) }));
    try testing.expectError(error.FailedPrecondition, f.client.snapshot(f.id("of-detached")).create(.{ .subscription = sub.id }));

    // An update still lands. Its own answer leaves `detached` out, as
    // measured on 2026-10-10, and a read after it says what is true.
    var updated = sub.update(.{ .labels = &.{.{ .key = "state", .value = "detached" }} }) catch |err| return f.fail(err);
    defer updated.deinit();
    try testing.expectEqualStrings("detached", updated.value.label("state").?);
    try testing.expect(!updated.value.detached);
    var again = sub.get() catch |err| return f.fail(err);
    defer again.deinit();
    try testing.expect(again.value.detached);
    try testing.expectEqualStrings("detached", again.value.label("state").?);
}

/// The fixture client's transport, with the answer to the first detach
/// lost: the request reaches the server, and the caller sees a dropped
/// connection.
const LoseDetachAnswer = struct {
    inner: pubsub.transport.Transport,
    detaches: usize = 0,
    lost: usize = 0,

    fn transport(l: *LoseDetachAnswer) pubsub.transport.Transport {
        return .{ .ptr = l, .vtable = &.{ .send = send } };
    }

    fn send(ptr: *anyopaque, req: pubsub.transport.Request, arena: Allocator) pubsub.transport.Error!pubsub.transport.Response {
        const l: *LoseDetachAnswer = @ptrCast(@alignCast(ptr));
        const response = try l.inner.send(req, arena);
        if (!std.mem.endsWith(u8, req.url, ":detach")) return response;
        l.detaches += 1;
        if (l.detaches > 1) return response;
        l.lost += 1;
        return error.ConnectionResetByPeer;
    }
};

test "detach: in production, one whose answer was lost is read back and succeeds" {
    var f: Fixture = undefined;
    if (!try f.init()) return error.SkipZigTest;
    defer f.deinit();
    // The emulator has no detach to lose the answer of.
    if (!f.production) return error.SkipZigTest;
    const topic = try f.createTopic("lost");
    const sub = try f.createSubscription("lost-sub", .{ .topic_id = topic.id });

    var lossy: LoseDetachAnswer = .{ .inner = f.client.transport };
    var diag: pubsub.Diagnostics = .{};
    var client: pubsub.Client = try .init(testing.allocator, testing.io, .{
        .project_id = f.client.project_id,
        .token_provider = f.token.provider(),
        .diagnostics = &diag,
        .transport = lossy.transport(),
    });
    defer client.deinit();

    // The first attempt lands and its answer is lost. The second finds
    // the subscription detached already, which the read after it confirms.
    client.subscription(sub.id).detach() catch |err| {
        std.debug.print("{t}: HTTP {d} {s}: {s}\n", .{ err, diag.http_status, diag.status(), diag.message() });
        return err;
    };
    try testing.expectEqual(1, lossy.lost);
    try testing.expectEqual(2, lossy.detaches);
    try testing.expectEqualStrings("", diag.message());
    var got = sub.get() catch |err| return f.fail(err);
    defer got.deinit();
    try testing.expect(got.value.detached);
}

// Publisher.

// Delivery: push, BigQuery and Cloud Storage subscriptions.

/// A tiny HTTP server on the loopback interface that records every request
/// and answers 204, which acknowledges a pushed message. What lands here is
/// what the emulator really sends: the loopback listener is the only way to
/// see that the body option asked for is the body an endpoint gets.
const PushListener = struct {
    gpa: Allocator,
    server: std.Io.net.Server,
    port: u16,
    mutex: std.Io.Mutex = .init,
    requests: std.ArrayList(Request) = .empty,

    const Request = struct { head: []u8, body: []u8 };

    /// Locally the emulator shares the loopback. In CI it lives in a
    /// container and reaches the runner only through a gateway address,
    /// so the listener binds every interface there.
    fn start(gpa: Allocator, bind_all: bool) !PushListener {
        const address: std.Io.net.IpAddress = .{ .ip4 = if (bind_all) .unspecified(0) else .loopback(0) };
        const server = try address.listen(testing.io, .{ .reuse_address = true });
        return .{ .gpa = gpa, .server = server, .port = server.socket.address.getPort() };
    }

    fn deinit(l: *PushListener) void {
        for (l.requests.items) |r| {
            l.gpa.free(r.head);
            l.gpa.free(r.body);
        }
        l.requests.deinit(l.gpa);
        l.server.deinit(testing.io);
    }

    /// Serves until canceled, each connection on a task of its own, since
    /// the pusher keeps connections open between pushes. This task stays
    /// in `accept`, where the cancel can land: a canceled read surfaces as
    /// `ReadFailed` and consumes the cancel, so a connection served here
    /// inline would leave the loop blocking in `accept` forever (the same
    /// trap `FaultProxy.run` documents).
    fn run(l: *PushListener, io: std.Io) std.Io.Cancelable!void {
        var group: std.Io.Group = .init;
        defer group.cancel(io);
        while (true) {
            const stream = l.server.accept(io) catch |err| switch (err) {
                error.Canceled => return error.Canceled,
                else => return,
            };
            group.concurrent(io, serveTask, .{ l, io, stream }) catch {
                // No task for it: serve on this one, as a lone pusher allows.
                serveTask(l, io, stream);
            };
        }
    }

    fn serveTask(l: *PushListener, io: std.Io, stream: std.Io.net.Stream) void {
        l.serve(io, stream) catch {};
    }

    fn serve(l: *PushListener, io: std.Io, stream: std.Io.net.Stream) !void {
        defer stream.close(io);
        var read_buf: [64 * 1024]u8 = undefined;
        var reader = stream.reader(io, &read_buf);
        var write_buf: [256]u8 = undefined;
        var writer = stream.writer(io, &write_buf);
        // The pusher may keep its connection and send several requests on it.
        while (true) {
            var head: std.Io.Writer.Allocating = .init(l.gpa);
            defer head.deinit();
            var content_length: u64 = 0;
            var first = true;
            while (true) {
                const line = reader.interface.takeDelimiterInclusive('\n') catch |err| {
                    if (first and err == error.EndOfStream) return;
                    return err;
                };
                first = false;
                try head.writer.writeAll(line);
                if (std.ascii.startsWithIgnoreCase(line, "content-length:")) {
                    const value = std.mem.trim(u8, line["content-length:".len..], " \r\n");
                    content_length = try std.fmt.parseInt(u64, value, 10);
                }
                if (std.mem.eql(u8, line, "\r\n") or std.mem.eql(u8, line, "\n")) break;
            }
            if (content_length > 1024 * 1024) return error.RequestTooLarge;
            var body: std.Io.Writer.Allocating = .init(l.gpa);
            defer body.deinit();
            try reader.interface.streamExact64(&body.writer, content_length);
            {
                l.mutex.lockUncancelable(io);
                defer l.mutex.unlock(io);
                try l.requests.ensureUnusedCapacity(l.gpa, 1);
                const kept_head = try l.gpa.dupe(u8, head.written());
                errdefer l.gpa.free(kept_head);
                const kept_body = try l.gpa.dupe(u8, body.written());
                l.requests.appendAssumeCapacity(.{ .head = kept_head, .body = kept_body });
            }
            try writer.interface.writeAll("HTTP/1.1 204 No Content\r\n\r\n");
            try writer.interface.flush();
        }
    }

    fn count(l: *PushListener) usize {
        l.mutex.lockUncancelable(testing.io);
        defer l.mutex.unlock(testing.io);
        return l.requests.items.len;
    }

    /// The recorded request whose first line names `path`, or null.
    fn find(l: *PushListener, path: []const u8) ?Request {
        l.mutex.lockUncancelable(testing.io);
        defer l.mutex.unlock(testing.io);
        for (l.requests.items) |r| {
            const line_end = std.mem.indexOfScalar(u8, r.head, '\n') orelse continue;
            if (std.mem.indexOf(u8, r.head[0..line_end], path) != null) return r;
        }
        return null;
    }
};

fn containsIgnoreCase(haystack: []const u8, needle: []const u8) bool {
    if (needle.len > haystack.len) return false;
    for (0..haystack.len - needle.len + 1) |i| {
        if (std.ascii.eqlIgnoreCase(haystack[i .. i + needle.len], needle)) return true;
    }
    return false;
}

test "push delivery: the emulator POSTs to a loopback listener, wrapped and unwrapped, and 204 acknowledges" {
    var f: Fixture = undefined;
    if (!try f.init()) return error.SkipZigTest;
    defer f.deinit();
    // Production requires https:// and cannot reach a loopback listener.
    if (f.production) return error.SkipZigTest;

    // The address the emulator reaches this test at: the shared loopback
    // locally, and in CI, where the emulator is a container,
    // PUBSUB_TEST_PUSH_HOST names the host gateway (ci.yml sets
    // host.docker.internal).
    const push_host = f.env.get("PUBSUB_TEST_PUSH_HOST");
    var listener = try PushListener.start(testing.allocator, push_host != null);
    defer listener.deinit();
    var serving = try testing.io.concurrent(PushListener.run, .{ &listener, testing.io });
    defer serving.cancel(testing.io) catch {};

    const topic = try f.createTopic("push");
    const a = f.arena.allocator();
    const host = push_host orelse "127.0.0.1";
    const wrapped = try f.createSubscription("push-wrapped", .{ .topic_id = topic.id, .delivery = .{ .push = .{
        .endpoint = try a.print("http://{s}:{d}/wrapped", .{ host, listener.port }),
    } } });
    _ = try f.createSubscription("push-unwrapped", .{ .topic_id = topic.id, .delivery = .{ .push = .{
        .endpoint = try a.print("http://{s}:{d}/unwrapped", .{ host, listener.port }),
        .body = .{ .unwrapped = .{ .write_metadata = true } },
    } } });

    const message_id = try publishOne(&f, topic, .{ .data = "pushed", .attributes = &.{.{ .key = "origin", .value = "zig" }} }, .{});

    // Both subscriptions deliver the one message to their endpoints.
    const deadline = nowMs() + f.patience() * 1000;
    while (listener.find("/wrapped") == null or listener.find("/unwrapped") == null) {
        if (nowMs() > deadline) {
            std.debug.print("timed out with {d} pushes\n", .{listener.count()});
            return error.TestTimedOut;
        }
        try testing.io.sleep(.fromMilliseconds(100), .awake);
    }

    // The wrapped body is the JSON envelope: the message with base64 data,
    // its attributes and id, and the full subscription name.
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const envelope_body = listener.find("/wrapped").?.body;
    const Envelope = struct {
        message: struct {
            data: []const u8,
            attributes: std.json.ArrayHashMap([]const u8) = .{},
            messageId: []const u8 = "",
        },
        subscription: []const u8,
    };
    const envelope = try std.json.parseFromSliceLeaky(Envelope, arena.allocator(), envelope_body, .{ .ignore_unknown_fields = true });
    const decoder = std.base64.standard.Decoder;
    const data = try arena.allocator().alloc(u8, try decoder.calcSizeForSlice(envelope.message.data));
    try decoder.decode(data, envelope.message.data);
    try testing.expectEqualStrings("pushed", data);
    try testing.expectEqualStrings("zig", envelope.message.attributes.map.get("origin").?);
    try testing.expectEqualStrings(message_id, envelope.message.messageId);
    const wrapped_name = try a.print("projects/{s}/subscriptions/{s}", .{ f.client.project_id, wrapped.id });
    try testing.expectEqualStrings(wrapped_name, envelope.subscription);

    // The unwrapped body is the message's data alone, with its metadata in
    // x-goog-pubsub-* headers when asked.
    const unwrapped_push = listener.find("/unwrapped").?;
    try testing.expectEqualStrings("pushed", unwrapped_push.body);
    try testing.expect(containsIgnoreCase(unwrapped_push.head, "x-goog-pubsub-message-id:"));

    // The 204s acknowledge: deliveries stop. Push is at least once, so a
    // duplicate may still land (CI saw one); quiet means no new push for a
    // whole redelivery window, the 10 s ack deadline with slack. A push
    // nothing acknowledges comes back every deadline, and never settles.
    var settled = listener.count();
    var rounds: usize = 0;
    while (true) {
        try testing.io.sleep(.fromMilliseconds(13_000), .awake);
        const count_now = listener.count();
        if (count_now == settled) break;
        settled = count_now;
        rounds += 1;
        try testing.expect(rounds < 5);
    }
}

test "delivery: each export kind is created and read back, which is all the emulator does with them" {
    var f: Fixture = undefined;
    if (!try f.init()) return error.SkipZigTest;
    defer f.deinit();
    // In production an export needs a real table or bucket and a grant;
    // those cases are gated on PUBSUB_TEST_BIGQUERY_TABLE and
    // PUBSUB_TEST_BUCKET (milestone 3 of the delivery spec).
    if (f.production) return error.SkipZigTest;

    const topic = try f.createTopic("export");

    // A push config with everything reads back as it was made.
    const push = try f.createSubscription("push-full", .{ .topic_id = topic.id, .delivery = .{ .push = .{
        .endpoint = "https://example.com/zigps-hook",
        .oidc_token = .{ .service_account_email = "zig-gcp@extractctl.iam.gserviceaccount.com", .audience = "zigps" },
        .body = .{ .unwrapped = .{ .write_metadata = true } },
    } } });
    var pushed = push.get() catch |err| return f.fail(err);
    defer pushed.deinit();
    const push_config = pushed.value.delivery.push;
    try testing.expectEqualStrings("https://example.com/zigps-hook", push_config.endpoint);
    try testing.expectEqualStrings("zig-gcp@extractctl.iam.gserviceaccount.com", push_config.oidc_token.?.service_account_email);
    try testing.expectEqualStrings("zigps", push_config.oidc_token.?.audience);
    try testing.expect(push_config.body.unwrapped.write_metadata);

    // BigQuery: the emulator stores the config unchecked and delivers
    // nothing; its page says so. The state stays the server's secret.
    const bq = try f.createSubscription("bq", .{ .topic_id = topic.id, .delivery = .{ .bigquery = .{
        .table = "test.zigps_dataset.rows",
        .schema = .topic,
        .write_metadata = true,
        .drop_unknown_fields = true,
    } } });
    var rows = bq.get() catch |err| return f.fail(err);
    defer rows.deinit();
    const bq_config = rows.value.delivery.bigquery.config;
    try testing.expectEqualStrings("test.zigps_dataset.rows", bq_config.table);
    try testing.expectEqual(.topic, bq_config.schema);
    try testing.expect(bq_config.write_metadata);
    try testing.expect(bq_config.drop_unknown_fields);
    try testing.expectEqual(.unknown, rows.value.delivery.bigquery.state);

    // Cloud Storage, with every option.
    const gcs = try f.createSubscription("gcs", .{ .topic_id = topic.id, .delivery = .{ .cloud_storage = .{
        .bucket = "zigps-no-such-bucket",
        .filename_prefix = "logs/",
        .filename_suffix = ".avro",
        .filename_datetime_format = "YYYY-MM-DD/hh_mm_ssZ",
        .format = .{ .avro = .{ .write_metadata = true } },
        .max_duration = .fromSeconds(120),
        .max_bytes = 2000,
        .max_messages = 1000,
    } } });
    var files = gcs.get() catch |err| return f.fail(err);
    defer files.deinit();
    const gcs_config = files.value.delivery.cloud_storage.config;
    try testing.expectEqualStrings("zigps-no-such-bucket", gcs_config.bucket);
    try testing.expectEqualStrings("logs/", gcs_config.filename_prefix);
    try testing.expectEqualStrings(".avro", gcs_config.filename_suffix);
    try testing.expectEqualStrings("YYYY-MM-DD/hh_mm_ssZ", gcs_config.filename_datetime_format);
    try testing.expect(gcs_config.format.avro.write_metadata);
    try testing.expect(!gcs_config.format.avro.use_topic_schema);
    try testing.expectEqual(std.Io.Duration.fromSeconds(120), gcs_config.max_duration.?);
    try testing.expectEqual(2000, gcs_config.max_bytes);
    try testing.expectEqual(1000, gcs_config.max_messages);
    try testing.expectEqual(.unknown, files.value.delivery.cloud_storage.state);

    // The export kinds list beside the pull ones without failing.
    var page = f.client.listSubscriptions(.{ .page_size = 100 }) catch |err| return f.fail(err);
    defer page.deinit();
}

test "delivery update: pull to push and back on the emulator, and an export change is refused before sending" {
    var f: Fixture = undefined;
    if (!try f.init()) return error.SkipZigTest;
    defer f.deinit();
    // Production's updates, replacing an export kind among them, are gated
    // behind PUBSUB_TEST_BIGQUERY_TABLE and PUBSUB_TEST_BUCKET.
    if (f.production) return error.SkipZigTest;

    const topic = try f.createTopic("upd");
    const sub = try f.createSubscription("upd-sub", .{ .topic_id = topic.id });

    var pushed = sub.update(.{ .delivery = .{ .push = .{ .endpoint = "https://example.com/zigps-hook" } } }) catch |err| return f.fail(err);
    defer pushed.deinit();
    try testing.expectEqualStrings("https://example.com/zigps-hook", pushed.value.delivery.push.endpoint);

    var pulled = sub.update(.{ .delivery = .pull }) catch |err| return f.fail(err);
    defer pulled.deinit();
    try testing.expectEqual(.pull, std.meta.activeTag(pulled.value.delivery));
    var read = sub.get() catch |err| return f.fail(err);
    defer read.deinit();
    try testing.expectEqual(.pull, std.meta.activeTag(read.value.delivery));

    // The emulator refuses the export kinds' mask paths, so a change to an
    // export kind, and away from one, is refused here before sending.
    try testing.expectError(error.InvalidArgument, sub.update(.{ .delivery = .{ .bigquery = .{ .table = "test.d.t" } } }));
    const bq = try f.createSubscription("upd-bq", .{ .topic_id = topic.id, .delivery = .{ .bigquery = .{ .table = "test.d.t" } } });
    try testing.expectError(error.InvalidArgument, bq.update(.{ .delivery = .pull }));
    try testing.expect(std.mem.indexOf(u8, f.diag.message(), "emulator") != null);

    // What is not the delivery still changes on an export subscription.
    var retried = bq.update(.{ .retry_policy = .{ .set = .{ .minimum = .fromSeconds(1), .maximum = .fromSeconds(5) } } }) catch |err| return f.fail(err);
    defer retried.deinit();
    try testing.expectEqual(std.Io.Duration.fromSeconds(5), retried.value.retry_policy.?.maximum);
    try testing.expectEqualStrings("test.d.t", retried.value.delivery.bigquery.config.table);
}

test "delivery in production: export kinds with their states, switches by update, and the measured refusals" {
    var f: Fixture = undefined;
    if (!try f.init()) return error.SkipZigTest;
    defer f.deinit();
    // Needs a real table and bucket, both granted to Pub/Sub's service
    // agent (`_plan/zig-pubsub-delivery-settings-spec.md`, question 8):
    //   PUBSUB_TEST_BIGQUERY_TABLE=project.dataset.table
    //   PUBSUB_TEST_BUCKET=bucket
    if (!f.production) return error.SkipZigTest;
    const table = f.env.get("PUBSUB_TEST_BIGQUERY_TABLE") orelse return error.SkipZigTest;
    const bucket = f.env.get("PUBSUB_TEST_BUCKET") orelse return error.SkipZigTest;

    const topic = try f.createTopic("deliver");
    const sub = try f.createSubscription("deliver-sub", .{
        .topic_id = topic.id,
        .ack_deadline_seconds = 600,
        .delivery = .{ .bigquery = .{ .table = table, .write_metadata = true } },
    });
    var rows = sub.get() catch |err| return f.fail(err);
    defer rows.deinit();
    try testing.expectEqualStrings(table, rows.value.delivery.bigquery.config.table);
    try testing.expect(rows.value.delivery.bigquery.config.write_metadata);
    try testing.expectEqual(.active, rows.value.delivery.bigquery.state);

    // One update switches the kind, the delivery replaced whole.
    var files = sub.update(.{ .delivery = .{ .cloud_storage = .{
        .bucket = bucket,
        .filename_prefix = "zigps/",
        .filename_datetime_format = "YYYY-MM-DD/hh_mm_ssZ",
        .max_duration = .fromSeconds(60),
    } } }) catch |err| return f.fail(err);
    defer files.deinit();
    try testing.expectEqualStrings(bucket, files.value.delivery.cloud_storage.config.bucket);
    try testing.expectEqualStrings("zigps/", files.value.delivery.cloud_storage.config.filename_prefix);
    try testing.expectEqual(.active, files.value.delivery.cloud_storage.state);

    var pushed = sub.update(.{ .delivery = .{ .push = .{ .endpoint = "https://example.com/zigps-hook" } } }) catch |err| return f.fail(err);
    defer pushed.deinit();
    try testing.expectEqualStrings("https://example.com/zigps-hook", pushed.value.delivery.push.endpoint);

    // A push subscription refuses a pull, which is also what stops a
    // Subscriber run on one.
    try testing.expectError(error.FailedPrecondition, sub.pull(.{ .return_immediately = true }));
    try testing.expectEqualStrings("This method is not supported for this subscription type.", f.diag.message());

    var pulled = sub.update(.{ .delivery = .pull }) catch |err| return f.fail(err);
    defer pulled.deinit();
    try testing.expectEqual(.pull, std.meta.activeTag(pulled.value.delivery));

    // The refusals measured on 2026-10-10, in production's words: a
    // missing table says only "permission", a missing bucket names the
    // service agent and what to grant.
    const a = f.arena.allocator();
    const missing_table = try a.print("{s}.zigps_no_such_dataset.t", .{f.client.project_id});
    try testing.expectError(error.PermissionDenied, f.client.subscription(f.id("no-table")).create(.{
        .topic_id = topic.id,
        .delivery = .{ .bigquery = .{ .table = missing_table } },
    }));
    const missing_bucket = try a.print("{s}-no-such-bucket", .{&f.prefix});
    try testing.expectError(error.FailedPrecondition, f.client.subscription(f.id("no-bucket")).create(.{
        .topic_id = topic.id,
        .delivery = .{ .cloud_storage = .{ .bucket = missing_bucket } },
    }));
    try testing.expect(std.mem.indexOf(u8, f.diag.message(), "service-") != null);
}

const Publisher = pubsub.Publisher;

const PublisherKnobs = struct {
    concurrency: u16 = 4,
    max_batch_messages: u16 = 100,
    max_batch_bytes: u32 = 1_000_000,
    max_batch_delay_ms: u32 = 10,
    enable_message_ordering: bool = false,
    max_outstanding_bytes: u64 = 10_000_000,
    compression: ?pubsub.Compression = null,
};

/// Options for a publisher on the fixture's server.
fn publisherOptions(f: *Fixture, topic_id: []const u8, knobs: PublisherKnobs) Publisher.Options {
    return .{
        .topic_id = topic_id,
        .client = .{
            .project_id = f.client.project_id,
            .endpoint = .{ .url = f.client.base_url, .emulator = f.client.emulator },
            .token_provider = if (f.production) f.token.provider() else null,
            .user_agent = "zig-pubsub-integration/0.1",
            // A publisher never holds a pull open: a stalled request should
            // be retried long before the default three minutes.
            .request_timeout_ms = 30_000,
        },
        .concurrency = knobs.concurrency,
        .max_batch_messages = knobs.max_batch_messages,
        .max_batch_bytes = knobs.max_batch_bytes,
        .max_batch_delay_ms = knobs.max_batch_delay_ms,
        .enable_message_ordering = knobs.enable_message_ordering,
        .max_outstanding_bytes = knobs.max_outstanding_bytes,
        .compression = knobs.compression,
    };
}

/// A publisher running on a task of its own until `finish`.
const LivePublisher = struct {
    publisher: Publisher,
    running: ?std.Io.Future(Publisher.Error!void) = null,

    fn start(l: *LivePublisher, options: Publisher.Options) !void {
        l.* = .{ .publisher = try .init(testing.allocator, testing.io, options) };
        errdefer l.publisher.deinit();
        l.running = try testing.io.concurrent(Publisher.run, .{&l.publisher});
    }

    /// Stops the publisher and returns what `run` returns.
    fn finish(l: *LivePublisher) Publisher.Error!void {
        l.publisher.stop();
        var running = l.running orelse return;
        l.running = null;
        return running.await(testing.io);
    }

    fn deinit(l: *LivePublisher) void {
        if (l.running != null) l.finish() catch {};
        l.publisher.deinit();
    }
};

/// `receipt.wait()`, failing rather than hanging after `timeout_s`.
fn waitReceipt(receipt: Publisher.Receipt, timeout_s: i64) ![]const u8 {
    const deadline = nowMs() + timeout_s * 1000;
    while (!receipt.batch.resolved.isSet()) {
        if (nowMs() > deadline) return error.TestTimedOut;
        try testing.io.sleep(.fromMilliseconds(10), .awake);
    }
    return receipt.wait();
}

test "publisher: several tasks publish 1,000 messages in far fewer requests, and every one arrives" {
    var f: Fixture = undefined;
    if (!try f.init()) return error.SkipZigTest;
    defer f.deinit();
    const topic = try f.createTopic("pubv");
    const sub = try f.createSubscription("pubv-sub", .{ .topic_id = topic.id });

    var live: LivePublisher = undefined;
    try live.start(publisherOptions(&f, topic.id, .{}));
    defer live.deinit();

    const per_task = 250;
    const Task = struct {
        fn publishMany(p: *Publisher, task: usize) anyerror!void {
            var receipts: [per_task]Publisher.Receipt = undefined;
            var made: usize = 0;
            defer for (receipts[0..made]) |r| r.release();
            for (&receipts, 0..) |*r, i| {
                var buf: [16]u8 = undefined;
                r.* = try p.publish(.{ .data = try std.fmt.bufPrint(&buf, "t{d}-{d:0>3}", .{ task, i }) }, .{});
                made += 1;
            }
            for (receipts) |r| _ = try waitReceipt(r, 60);
        }
    };
    var tasks: [4]std.Io.Future(anyerror!void) = undefined;
    var started: usize = 0;
    defer for (tasks[0..started]) |*task| task.cancel(testing.io) catch {};
    for (&tasks, 0..) |*task, i| {
        task.* = try testing.io.concurrent(Task.publishMany, .{ &live.publisher, i });
        started += 1;
    }
    for (tasks[0..started]) |*task| try task.await(testing.io);
    try live.finish();

    const counts = live.publisher.stats();
    try testing.expectEqual(4 * per_task, counts.succeeded);
    try testing.expect(counts.requests < 100);

    var got: Collector = .init();
    defer got.deinit();
    try pullUntil(&f, sub, 4 * per_task, f.patience(), &got, true);
    for (0..4) |t| for (0..per_task) |i| {
        var buf: [16]u8 = undefined;
        const data = try std.fmt.bufPrint(&buf, "t{d}-{d:0>3}", .{ t, i });
        if (got.find(data) == null) {
            std.debug.print("{s} never arrived\n", .{data});
            return error.TestMessageMissing;
        }
    };
}

test "publisher: each ordering key's messages arrive in publish order on an ordered subscription" {
    var f: Fixture = undefined;
    if (!try f.init()) return error.SkipZigTest;
    defer f.deinit();
    const topic = try f.createTopic("pubord");
    const sub = try f.createSubscription("pubord-sub", .{ .topic_id = topic.id, .enable_message_ordering = true });

    var live: LivePublisher = undefined;
    try live.start(publisherOptions(&f, topic.id, .{ .max_batch_messages = 5, .enable_message_ordering = true }));
    defer live.deinit();

    // Three tasks, a key each, publishing at once: the keys' batches
    // interleave across the four connections.
    const per_key = 20;
    const Task = struct {
        fn publishKey(p: *Publisher, k: usize) anyerror!void {
            var key_buf: [8]u8 = undefined;
            const key = try std.fmt.bufPrint(&key_buf, "key-{d}", .{k});
            var receipts: [per_key]Publisher.Receipt = undefined;
            var made: usize = 0;
            defer for (receipts[0..made]) |r| r.release();
            for (&receipts, 0..) |*r, i| {
                var buf: [16]u8 = undefined;
                r.* = try p.publish(.{ .data = try std.fmt.bufPrint(&buf, "k{d}-{d:0>2}", .{ k, i }) }, .{ .ordering_key = key });
                made += 1;
            }
            for (receipts) |r| _ = try waitReceipt(r, 60);
        }
    };
    var tasks: [3]std.Io.Future(anyerror!void) = undefined;
    var started: usize = 0;
    defer for (tasks[0..started]) |*task| task.cancel(testing.io) catch {};
    for (&tasks, 0..) |*task, k| {
        task.* = try testing.io.concurrent(Task.publishKey, .{ &live.publisher, k });
        started += 1;
    }
    for (tasks[0..started]) |*task| try task.await(testing.io);
    try live.finish();

    var got: Collector = .init();
    defer got.deinit();
    try pullUntil(&f, sub, 3 * per_key, f.patience(), &got, true);
    // Each key's messages in order, counting a redelivered one once.
    for (0..3) |k| {
        var next: usize = 0;
        var key_buf: [8]u8 = undefined;
        const key = try std.fmt.bufPrint(&key_buf, "key-{d}", .{k});
        for (got.messages.items) |m| {
            if (!std.mem.eql(u8, m.ordering_key, key)) continue;
            var buf: [16]u8 = undefined;
            if (next < per_key and std.mem.eql(u8, m.data, try std.fmt.bufPrint(&buf, "k{d}-{d:0>2}", .{ k, next }))) {
                next += 1;
            } else {
                // Anything else must be a repeat of one already seen.
                const i = try std.fmt.parseInt(usize, m.data[m.data.len - 2 ..], 10);
                try testing.expect(i < next);
            }
        }
        try testing.expectEqual(per_key, next);
    }
}

test "publisher: a lone message goes out once its delay runs out" {
    var f: Fixture = undefined;
    if (!try f.init()) return error.SkipZigTest;
    defer f.deinit();
    const topic = try f.createTopic("pubdelay");
    var live: LivePublisher = undefined;
    try live.start(publisherOptions(&f, topic.id, .{ .max_batch_delay_ms = 50 }));
    defer live.deinit();

    const started = nowMs();
    const receipt = try live.publisher.publish(.{ .data = "alone" }, .{});
    defer receipt.release();
    _ = try waitReceipt(receipt, 30);
    const elapsed = nowMs() - started;
    // Not before the delay, and not long after: no stop, only the timer.
    try testing.expect(elapsed >= 45);
    try testing.expect(elapsed < 10_000);
    try live.finish();
    try testing.expectEqual(1, live.publisher.stats().requests);
}

test "publisher: a batch at exactly the 10,485,760-byte limit is accepted, and a byte more splits it" {
    try exactLimit(null);
}

test "publisher: compressed, the limit counts the bytes before compression, as Google's clients count them" {
    // The batches compress to a few kilobytes, and still split where they
    // would uncompressed.
    try exactLimit(.{});
}

fn exactLimit(compression: ?pubsub.Compression) !void {
    var f: Fixture = undefined;
    if (!try f.init()) return error.SkipZigTest;
    defer f.deinit();
    const topic = try f.createTopic(if (compression == null) "publimit" else "publimit-gz");
    const gpa = testing.allocator;
    const limit = pubsub.limits.max_publish_request_bytes;

    // Two messages that fill a request to the byte: one of plain data, and
    // one whose attribute takes up the last few bytes.
    const first_data = try gpa.alloc(u8, 3_900_000);
    defer gpa.free(first_data);
    @memset(first_data, 'a');
    const second_data = try gpa.alloc(u8, 3_964_600);
    defer gpa.free(second_data);
    @memset(second_data, 'b');
    const pad: [8]u8 = @splat('p');
    const first: pubsub.Message = .{ .data = first_data };
    // Base64 moves in steps of four bytes; the attribute fills the gap.
    var fit: ?struct { usize, usize } = null;
    search: for (0..600) |trim| for (0..pad.len - 1) |pad_len| {
        const second: pubsub.Message = .{
            .data = second_data[0 .. second_data.len - trim],
            .attributes = &.{.{ .key = "pad", .value = pad[0..pad_len] }},
        };
        if (pubsub.limits.publishRequestBytes(&.{ first, second }, null) == limit) {
            fit = .{ trim, pad_len };
            break :search;
        }
    };
    const trim, const pad_len = fit orelse return error.TestNoExactFit;
    const exact: pubsub.Message = .{
        .data = second_data[0 .. second_data.len - trim],
        .attributes = &.{.{ .key = "pad", .value = pad[0..pad_len] }},
    };
    const over: pubsub.Message = .{
        .data = second_data[0 .. second_data.len - trim],
        .attributes = &.{.{ .key = "pad", .value = pad[0 .. pad_len + 1] }},
    };
    try testing.expectEqual(limit + 1, pubsub.limits.publishRequestBytes(&.{ first, over }, null));

    var live: LivePublisher = undefined;
    try live.start(publisherOptions(&f, topic.id, .{
        .concurrency = 1,
        .max_batch_messages = 1000,
        .max_batch_bytes = limit,
        // The default cap is smaller than a batch this big.
        .max_outstanding_bytes = 3 * limit,
        // Encoding a 4 MB message outlasts a short delay, which would send
        // the first message alone. Only size or flush may close a batch.
        .max_batch_delay_ms = 30_000,
        .compression = compression,
    }));
    defer live.deinit();
    for ([_]pubsub.Message{ exact, over }, [_]u64{ 1, 3 }) |second, requests| {
        const a = try live.publisher.publish(first, .{});
        defer a.release();
        const b = try live.publisher.publish(second, .{});
        defer b.release();
        try live.publisher.flush();
        _ = waitReceipt(a, 120) catch |err| return f.fail(err);
        _ = waitReceipt(b, 120) catch |err| return f.fail(err);
        // At the limit, one request; a byte over, two.
        try testing.expectEqual(requests, live.publisher.stats().requests);
    }
    try live.finish();
}

test "publisher: compressed batches arrive intact" {
    var f: Fixture = undefined;
    if (!try f.init()) return error.SkipZigTest;
    defer f.deinit();
    const topic = try f.createTopic("pubgz");
    const sub = try f.createSubscription("pubgz-sub", .{ .topic_id = topic.id });
    var live: LivePublisher = undefined;
    try live.start(publisherOptions(&f, topic.id, .{ .compression = .{ .level = 9 } }));
    defer live.deinit();

    const count = 300;
    var receipts: [count]Publisher.Receipt = undefined;
    var made: usize = 0;
    defer for (receipts[0..made]) |r| r.release();
    for (&receipts, 0..) |*r, i| {
        var buf: [64]u8 = undefined;
        r.* = try live.publisher.publish(.{ .data = try std.fmt.bufPrint(&buf, "compressed message {d:0>4}, in a batch", .{i}) }, .{});
        made += 1;
    }
    for (receipts) |r| _ = waitReceipt(r, 60) catch |err| return f.fail(err);
    try live.finish();
    try testing.expectEqual(count, live.publisher.stats().succeeded);

    var got: Collector = .init();
    defer got.deinit();
    try pullUntil(&f, sub, count, f.patience(), &got, true);
    for (0..count) |i| {
        var buf: [64]u8 = undefined;
        const data = try std.fmt.bufPrint(&buf, "compressed message {d:0>4}, in a batch", .{i});
        if (got.find(data) == null) {
            std.debug.print("{s} never arrived\n", .{data});
            return error.TestMessageMissing;
        }
    }
}

test "publisher: after its topic is deleted, receipts fail with NotFound and the publisher carries on" {
    var f: Fixture = undefined;
    if (!try f.init()) return error.SkipZigTest;
    defer f.deinit();
    const topic = try f.createTopic("pubgone");
    var live: LivePublisher = undefined;
    try live.start(publisherOptions(&f, topic.id, .{}));
    defer live.deinit();

    const before = try live.publisher.publish(.{ .data = "before" }, .{});
    defer before.release();
    _ = try waitReceipt(before, 30);
    topic.delete() catch |err| return f.fail(err);
    const deleted = nowMs();

    // The deletion can take a while to reach publishing. The emulator
    // refuses the next publish; production took 0.7 to 14 s in nine runs
    // on 2026-09-28, and once over 90 s.
    const patience_s: i64 = if (f.production) 300 else f.patience();
    const deadline = deleted + patience_s * 1000;
    var failures: usize = 0;
    var taken: usize = 0;
    while (failures < 2) {
        if (nowMs() > deadline) {
            std.debug.print("publishes still taken {d} ms after the topic was deleted ({d} taken)\n", .{ nowMs() - deleted, taken });
            return error.TestTimedOut;
        }
        const after = try live.publisher.publish(.{ .data = "after" }, .{});
        defer after.release();
        if (waitReceipt(after, 30)) |_| {
            taken += 1;
            try testing.io.sleep(.fromMilliseconds(500), .awake);
        } else |err| {
            try testing.expectEqual(error.NotFound, err);
            if (failures == 0) std.debug.print("publishing failed {d} ms after the topic was deleted, {d} taken before\n", .{ nowMs() - deleted, taken });
            failures += 1;
        }
    }
    // Still running: stop drains and returns.
    try live.finish();
    try testing.expect(live.publisher.stats().failed >= 2);
}

const avro_order =
    \\{"type":"record","name":"Order","fields":[{"name":"id","type":"string"},{"name":"quantity","type":"int"}]}
;
const proto_order = "syntax = \"proto3\";\nmessage Order {\n  string id = 1;\n  int32 quantity = 2;\n}\n";

test "schemas: one is made, read in both views and by its revision, found in its project's list, asked about messages both ways, and deleted" {
    var f: Fixture = undefined;
    if (!try f.init()) return error.SkipZigTest;
    defer f.deinit();
    const a = f.arena.allocator();
    const project = f.client.project_id;
    const definition: pubsub.SchemaDefinition = .{ .type = .avro, .definition = avro_order };

    // Pub/Sub says whether it would store a definition before it is asked to.
    f.client.validateSchema(definition) catch |err| return f.fail(err);
    try testing.expectError(error.InvalidArgument, f.client.validateSchema(.{ .type = .avro, .definition = "{\"type\":\"record\"" }));

    const schema = f.client.schema(f.id("order"));
    try f.schemas.append(testing.allocator, schema.id);
    const name = try a.print("projects/{s}/schemas/{s}", .{ project, schema.id });
    var created = schema.create(definition) catch |err| return f.fail(err);
    defer created.deinit();
    // The definition is kept byte for byte, by both.
    try testing.expectEqualStrings(name, created.value.name);
    try testing.expectEqual(pubsub.SchemaType.avro, created.value.type);
    try testing.expect(created.value.revision_id.len > 0);
    try testing.expectEqualStrings(avro_order, created.value.definition);
    const made_at = created.value.revision_create_time.?.toSeconds();
    if (f.production) {
        try testing.expect(@abs(made_at - std.Io.Clock.real.now(testing.io).toSeconds()) < 600);
    } else {
        // The emulator dates every revision in January 1970.
        try testing.expect(made_at < 366 * 86400);
    }
    const revision = created.value.revision_id;

    // Its id is taken, and what is not there is not found.
    try testing.expectError(error.AlreadyExists, schema.create(definition));
    const absent = f.client.schema(f.id("no-such-schema"));
    try testing.expectError(error.NotFound, absent.get(.{}));
    try testing.expectError(error.NotFound, absent.delete());
    try testing.expectError(error.NotFound, schema.get(.{ .revision_id = "deadbeef" }));

    var full = schema.get(.{}) catch |err| return f.fail(err);
    defer full.deinit();
    try testing.expectEqualStrings(created.value.definition, full.value.definition);
    try testing.expectEqualStrings(revision, full.value.revision_id);
    var basic = schema.get(.{ .view = .basic }) catch |err| return f.fail(err);
    defer basic.deinit();
    try testing.expectEqualStrings("", basic.value.definition);
    try testing.expectEqual(pubsub.SchemaType.avro, basic.value.type);
    var one = schema.get(.{ .revision_id = revision }) catch |err| return f.fail(err);
    defer one.deinit();
    try testing.expectEqualStrings(created.value.definition, one.value.definition);
    try testing.expectEqualStrings(revision, one.value.revision_id);

    // Among its project's schemas, with its definition when that is asked.
    var token: ?[]const u8 = null;
    const listed = search: while (true) {
        var page = f.client.listSchemas(.{ .view = .full, .page = .{ .page_token = token } }) catch |err| return f.fail(err);
        defer page.deinit();
        for (page.value.schemas) |s| {
            if (std.mem.startsWith(u8, s.name, name)) break :search try a.dupe(u8, s.definition);
        }
        token = try a.dupe(u8, page.value.next_page_token orelse break :search null);
    };
    try testing.expectEqualStrings(created.value.definition, listed.?);
    {
        // And without it in the basic view, a list's default, which the
        // client always says: asked for no view, the emulator sends it.
        var page = f.client.listSchemas(.{ .page = .{ .page_size = 1000 } }) catch |err| return f.fail(err);
        defer page.deinit();
        for (page.value.schemas) |s| {
            if (std.mem.startsWith(u8, s.name, name)) try testing.expectEqualStrings("", s.definition);
        }
    }

    // Read by its revision, production's answer names it `name@revision`:
    // the client gives the schema's own name either way.
    try testing.expectEqualStrings(name, one.value.name);

    // Would a message be taken? Asked of the stored schema, of one revision
    // of it and of the definition alone, in both encodings.
    const fits = "{\"id\":\"a\",\"quantity\":1}";
    const fits_binary = "\x02a\x02";
    schema.validateMessage(fits, .json, null) catch |err| return f.fail(err);
    schema.validateMessage(fits_binary, .binary, null) catch |err| return f.fail(err);
    schema.validateMessage(fits, .json, revision) catch |err| return f.fail(err);
    f.client.validateMessage(definition, fits_binary, .binary) catch |err| return f.fail(err);
    try testing.expectError(error.InvalidArgument, schema.validateMessage("{\"id\":\"a\",\"quantity\":\"one\"}", .json, null));
    try testing.expectError(error.InvalidArgument, schema.validateMessage("\xff\xff\xff", .binary, null));
    try testing.expectError(error.InvalidArgument, f.client.validateMessage(definition, "{}", .json));
    try testing.expectError(error.NotFound, absent.validateMessage(fits, .json, null));

    const proto = f.client.schema(f.id("order-proto"));
    if (f.production) {
        // What only production has: Protocol Buffer schemas and schema IAM.
        try f.schemas.append(testing.allocator, proto.id);
        var made = proto.create(.{ .type = .protocol_buffer, .definition = proto_order }) catch |err| return f.fail(err);
        made.deinit();
        proto.validateMessage("\x0a\x01a\x10\x01", .binary, null) catch |err| return f.fail(err);
        var policy = schema.iamPolicy() catch |err| return f.fail(err);
        policy.deinit();
    } else {
        try testing.expectError(error.Unimplemented, proto.create(.{ .type = .protocol_buffer, .definition = proto_order }));
        try testing.expectEqualStrings("Protocol buffer support not implemented in emulator", f.diag.message());
        try testing.expectError(error.Unimplemented, f.client.validateSchema(.{ .type = .protocol_buffer, .definition = proto_order }));
        try testing.expectError(error.InvalidArgument, schema.iamPolicy());
    }

    schema.delete() catch |err| return f.fail(err);
    try testing.expectError(error.NotFound, schema.get(.{}));
}

const avro_order_v2 =
    \\{"type":"record","name":"Order","fields":[{"name":"id","type":"string"},{"name":"quantity","type":"int"},{"name":"note","type":"string","default":""}]}
;

test "schema revisions: one is committed, read, listed, rolled back to and deleted, and a schema's only one cannot be" {
    var f: Fixture = undefined;
    if (!try f.init()) return error.SkipZigTest;
    defer f.deinit();
    const a = f.arena.allocator();
    const schema = f.client.schema(f.id("rev"));
    try f.schemas.append(testing.allocator, schema.id);
    var first = schema.create(.{ .type = .avro, .definition = avro_order }) catch |err| return f.fail(err);
    defer first.deinit();
    const v2: pubsub.SchemaDefinition = .{ .type = .avro, .definition = avro_order_v2 };

    // A schema that is not there has nothing to revise, and a revision
    // must parse as the first did.
    try testing.expectError(error.NotFound, f.client.schema(f.id("no-such-schema")).commit(v2));
    try testing.expectError(error.InvalidArgument, schema.commit(.{ .type = .avro, .definition = "{\"type\":\"record\"" }));

    var second = schema.commit(v2) catch |err| return f.fail(err);
    defer second.deinit();
    try testing.expect(second.value.revision_id.len > 0);
    try testing.expect(!std.mem.eql(u8, first.value.revision_id, second.value.revision_id));

    // A read with no revision gives the latest, and each is still read by
    // its id.
    var latest = schema.get(.{}) catch |err| return f.fail(err);
    defer latest.deinit();
    try testing.expectEqualStrings(second.value.revision_id, latest.value.revision_id);
    try testing.expectEqualStrings(second.value.definition, latest.value.definition);
    var old = schema.get(.{ .revision_id = first.value.revision_id }) catch |err| return f.fail(err);
    defer old.deinit();
    try testing.expectEqualStrings(first.value.definition, old.value.definition);
    schema.validateMessage("{\"id\":\"a\",\"quantity\":1}", .json, first.value.revision_id) catch |err| return f.fail(err);
    schema.validateMessage("{\"id\":\"a\",\"quantity\":1,\"note\":\"x\"}", .json, second.value.revision_id) catch |err| return f.fail(err);

    // Both are among its revisions, a page of one at a time, without their
    // definitions in a list's default view.
    var ids: std.ArrayList([]const u8) = .empty;
    var token: ?[]const u8 = null;
    for (0..10) |_| {
        var page = schema.listRevisions(.{ .page = .{ .page_size = 1, .page_token = token } }) catch |err| return f.fail(err);
        defer page.deinit();
        for (page.value.schemas) |s| {
            try testing.expectEqualStrings("", s.definition);
            try testing.expectEqualStrings(first.value.name, s.name);
            try ids.append(a, try a.dupe(u8, s.revision_id));
        }
        token = try a.dupe(u8, page.value.next_page_token orelse break);
    } else return error.TestUnexpectedResult;
    try testing.expectEqual(2, ids.items.len);
    // Production lists the newest first, and the emulator the oldest.
    const newest: usize = if (f.production) 0 else 1;
    try testing.expectEqualStrings(second.value.revision_id, ids.items[newest]);
    try testing.expectEqualStrings(first.value.revision_id, ids.items[1 - newest]);
    var whole = schema.listRevisions(.{ .view = .full }) catch |err| return f.fail(err);
    defer whole.deinit();
    try testing.expectEqual(2, whole.value.schemas.len);
    for (whole.value.schemas) |s| try testing.expect(s.definition.len > 0);

    // Back to the first: a new revision that holds what it held.
    var back = schema.rollback(first.value.revision_id) catch |err| return f.fail(err);
    defer back.deinit();
    try testing.expectEqualStrings(first.value.definition, back.value.definition);
    try testing.expect(!std.mem.eql(u8, first.value.revision_id, back.value.revision_id));
    try testing.expect(!std.mem.eql(u8, second.value.revision_id, back.value.revision_id));
    try testing.expectError(error.NotFound, schema.rollback("deadbeef"));

    // The second is deleted, once, and the others stay. Production went on
    // serving a deleted revision for a moment on 2026-10-12, so the read
    // is waited for.
    schema.deleteRevision(second.value.revision_id) catch |err| return f.fail(err);
    const Deleted = struct {
        schema: pubsub.Schema,
        revision_id: []const u8,

        fn gone(self: @This()) !void {
            var still = self.schema.get(.{ .revision_id = self.revision_id }) catch |err| return testing.expectEqual(error.NotFound, err);
            still.deinit();
            return error.TestExpectedError;
        }

        fn refused(self: @This()) !void {
            try testing.expectError(error.NotFound, self.schema.deleteRevision(self.revision_id));
        }
    };
    const deleted: Deleted = .{ .schema = schema, .revision_id = second.value.revision_id };
    try eventually(&f, f.patience(), deleted, Deleted.gone);
    try eventually(&f, f.patience(), deleted, Deleted.refused);
    var kept = schema.get(.{ .revision_id = first.value.revision_id }) catch |err| return f.fail(err);
    kept.deinit();
    var after = schema.get(.{}) catch |err| return f.fail(err);
    defer after.deinit();
    try testing.expectEqualStrings(back.value.revision_id, after.value.revision_id);

    // A schema's only revision cannot be deleted: the schema can.
    const single = f.client.schema(f.id("rev-one"));
    try f.schemas.append(testing.allocator, single.id);
    var only = single.create(.{ .type = .avro, .definition = avro_order }) catch |err| return f.fail(err);
    defer only.deinit();
    if (f.production) {
        try testing.expectError(error.FailedPrecondition, single.deleteRevision(only.value.revision_id));
        try testing.expect(std.mem.startsWith(u8, f.diag.message(), "This schema contains only one revision"));
    } else {
        try testing.expectError(error.InvalidArgument, single.deleteRevision(only.value.revision_id));
        try testing.expectEqualStrings("Cannot delete last revision. Please use DeleteSchema.", f.diag.message());
    }
    var still = single.get(.{ .view = .basic }) catch |err| return f.fail(err);
    still.deinit();

    if (f.production) {
        // What only production checks: a revision against the ones before
        // it, and a rollback to where the schema already is. The emulator
        // would take both, each as one more revision.
        const incompatible =
            \\{"type":"record","name":"Order","fields":[{"name":"id","type":"string"},{"name":"quantity","type":"string"}]}
        ;
        try testing.expectError(error.FailedPrecondition, single.commit(.{ .type = .avro, .definition = incompatible }));
        try testing.expect(std.mem.indexOf(u8, f.diag.message(), "incompatible with previous revision") != null);
        if (single.rollback(only.value.revision_id)) |r| {
            var made = r;
            made.deinit();
            return error.TestUnexpectedResult;
        } else |_| {
            try testing.expect(std.mem.startsWith(u8, f.diag.message(), "Cannot rollback to the latest revision"));
        }
    }
}

/// Pulls until one message arrives, acknowledges it, and returns what a
/// test of a schema topic wants of it: its data and what the topic wrote
/// on it.
const Fitted = struct { data: []const u8, schema: ?pubsub.MessageSchema };

fn pullOne(f: *Fixture, sub: pubsub.Subscription) !Fitted {
    const a = f.arena.allocator();
    const deadline = nowMs() + f.patience() * 1000;
    while (nowMs() < deadline) {
        var batch = sub.pull(.{ .max_messages = 1, .return_immediately = true }) catch |err| return f.fail(err);
        defer batch.deinit();
        if (batch.value.messages.len == 0) {
            try testing.io.sleep(.fromMilliseconds(250), .awake);
            continue;
        }
        const m = batch.value.messages[0];
        sub.ack(&.{m.ack_id}) catch |err| return f.fail(err);
        const s = m.schema();
        return .{
            .data = try a.dupe(u8, m.data),
            .schema = if (s) |x| .{ .name = try a.dupe(u8, x.name), .revision_id = try a.dupe(u8, x.revision_id), .encoding = x.encoding } else null,
        };
    }
    return error.TestTimedOut;
}

/// Publishes one message, again and again while a change to the topic's
/// schema settings is still taking hold: Google says that can take
/// minutes in production. The emulator's changes hold at once.
fn publishOnceItHolds(f: *Fixture, topic: pubsub.Topic, data: []const u8) !void {
    const deadline = nowMs() + (if (f.production) @as(i64, 300) else 0) * 1000;
    while (true) {
        if (topic.publish(&.{.{ .data = data }}, .{})) |sent| {
            var s = sent;
            s.deinit();
            return;
        } else |err| {
            if (nowMs() >= deadline) return f.fail(err);
            try testing.io.sleep(.fromMilliseconds(5000), .awake);
        }
    }
}

test "a topic with a schema: what fits is taken and says what it fit, what does not is refused, and the settings change, clear and outlive their schema" {
    var f: Fixture = undefined;
    if (!try f.init()) return error.SkipZigTest;
    defer f.deinit();
    const a = f.arena.allocator();
    const project = f.client.project_id;

    const schema = f.client.schema(f.id("topic-schema"));
    try f.schemas.append(testing.allocator, schema.id);
    var stored = schema.create(.{ .type = .avro, .definition = avro_order }) catch |err| return f.fail(err);
    defer stored.deinit();
    const schema_name = try a.print("projects/{s}/schemas/{s}", .{ project, schema.id });
    const revision = stored.value.revision_id;

    // A schema that is not there cannot be named, nor a revision of one
    // that is.
    const nowhere = f.client.topic(f.id("schema-nowhere"));
    try f.topics.append(testing.allocator, nowhere.id);
    try testing.expectError(error.NotFound, nowhere.create(.{ .schema = .{ .schema = f.id("no-such-schema"), .encoding = .json } }));
    try testing.expectError(error.NotFound, nowhere.create(.{ .schema = .{ .schema = schema.id, .encoding = .json, .first_revision_id = "deadbeef" } }));

    const topic = f.client.topic(f.id("schema-topic"));
    try f.topics.append(testing.allocator, topic.id);
    var created = topic.create(.{ .schema = .{ .schema = schema.id, .encoding = .json } }) catch |err| return f.fail(err);
    defer created.deinit();
    try testing.expectEqualStrings(schema_name, created.value.schema.?.schema);
    try testing.expectEqual(pubsub.SchemaEncoding.json, created.value.schema.?.encoding);
    try testing.expectEqual(null, created.value.schema.?.first_revision_id);
    var read = topic.get() catch |err| return f.fail(err);
    defer read.deinit();
    try testing.expectEqualStrings(schema_name, read.value.schema.?.schema);
    const sub = try f.createSubscription("schema-sub", .{ .topic_id = topic.id });

    // What fits is taken. What does not is refused, and takes the message
    // beside it in the same request with it.
    const fits = "{\"id\":\"a\",\"quantity\":1}";
    const misfit = "{\"id\":\"a\",\"quantity\":\"one\"}";
    try publishOnceItHolds(&f, topic, fits);
    try testing.expectError(error.InvalidArgument, topic.publish(&.{.{ .data = misfit }}, .{}));
    try testing.expectError(error.InvalidArgument, topic.publish(&.{ .{ .data = fits }, .{ .data = misfit } }, .{}));
    // Binary where JSON is the encoding does not fit either.
    try testing.expectError(error.InvalidArgument, topic.publish(&.{.{ .data = "\x02a\x02" }}, .{}));

    // The one message taken says what it fit, and how it is written.
    const got = try pullOne(&f, sub);
    try testing.expectEqualStrings(fits, got.data);
    try testing.expectEqual(pubsub.SchemaEncoding.json, got.schema.?.encoding);
    try testing.expectEqualStrings(schema_name, got.schema.?.name);
    try testing.expectEqualStrings(revision, got.schema.?.revision_id);
    try expectNoMessages(&f, sub);

    // The settings are replaced whole: the other encoding, and a range.
    var binary = topic.update(.{ .schema = .{ .set = .{ .schema = schema.id, .encoding = .binary, .first_revision_id = revision, .last_revision_id = revision } } }) catch |err| return f.fail(err);
    defer binary.deinit();
    try testing.expectEqual(pubsub.SchemaEncoding.binary, binary.value.schema.?.encoding);
    try testing.expectEqualStrings(revision, binary.value.schema.?.first_revision_id.?);
    try testing.expectEqualStrings(revision, binary.value.schema.?.last_revision_id.?);
    try publishOnceItHolds(&f, topic, "\x02a\x02");
    const packed_one = try pullOne(&f, sub);
    try testing.expectEqualStrings("\x02a\x02", packed_one.data);
    try testing.expectEqual(pubsub.SchemaEncoding.binary, packed_one.schema.?.encoding);
    // Without the range in the next update, the range is gone.
    var open = topic.update(.{ .schema = .{ .set = .{ .schema = schema.id, .encoding = .binary } } }) catch |err| return f.fail(err);
    defer open.deinit();
    try testing.expectEqual(null, open.value.schema.?.first_revision_id);
    try testing.expectEqual(null, open.value.schema.?.last_revision_id);

    // Cleared, the topic takes any bytes again, and writes nothing on them.
    var cleared = topic.update(.{ .schema = .clear }) catch |err| return f.fail(err);
    defer cleared.deinit();
    try testing.expectEqual(null, cleared.value.schema);
    try publishOnceItHolds(&f, topic, "not an order at all");
    const free = try pullOne(&f, sub);
    try testing.expectEqualStrings("not an order at all", free.data);
    try testing.expectEqual(null, free.schema);

    // Set again, then the schema deleted under it: the topic reads as
    // having lost it, and takes nothing more.
    var again = topic.update(.{ .schema = .{ .set = .{ .schema = schema_name, .encoding = .json } } }) catch |err| return f.fail(err);
    again.deinit();
    schema.delete() catch |err| return f.fail(err);
    // The emulator shows it at once. Production showed it at once in one
    // run and not yet in another (measured 2026-10-12).
    const lost_by = nowMs() + f.patience() * 1000;
    while (true) {
        var orphan = topic.get() catch |err| return f.fail(err);
        defer orphan.deinit();
        if (orphan.value.schema.?.isDeleted()) {
            try testing.expectEqual(pubsub.SchemaEncoding.json, orphan.value.schema.?.encoding);
            // What such a topic reads back cannot be sent as it is.
            try testing.expectError(error.InvalidArgument, topic.update(.{ .schema = .{ .set = orphan.value.schema.? } }));
            break;
        }
        if (nowMs() > lost_by) return error.TestTimedOut;
        try testing.io.sleep(.fromMilliseconds(2000), .awake);
    }
    // And it takes nothing more: at once on the emulator, and in
    // production after a minute in which publishes were still taken, off
    // and on.
    const refused_by = nowMs() + (if (f.production) @as(i64, 300) else 0) * 1000;
    while (true) {
        if (topic.publish(&.{.{ .data = fits }}, .{})) |sent| {
            var taken = sent;
            taken.deinit();
            if (nowMs() >= refused_by) return error.TestTimedOut;
            try testing.io.sleep(.fromMilliseconds(5000), .awake);
        } else |err| {
            try testing.expectEqual(error.NotFound, err);
            try testing.expectEqualStrings(
                if (f.production) "The schema associated with the topic has been deleted." else "Schema associated with topic deleted.",
                f.diag.message(),
            );
            break;
        }
    }
    if (!f.production) {
        // A schema made again under the id is not the one the topic had.
        var remade = schema.create(.{ .type = .avro, .definition = avro_order }) catch |err| return f.fail(err);
        remade.deinit();
        var still = topic.get() catch |err| return f.fail(err);
        defer still.deinit();
        try testing.expect(still.value.schema.?.isDeleted());
    }
}

// Message transforms. Production runs them; the emulator keeps them and
// runs none (emulator 0.8.36, 2026-10-12), so a message goes through one
// untouched there, none is dropped and none is refused.

const upper_transform: pubsub.MessageTransform = .{ .kind = .{ .javascript_udf = .{
    .function_name = "upper",
    .code = "function upper(message, metadata) { message.data = message.data.toUpperCase(); message.attributes['seen'] = 'yes'; return message; }",
} } };
const drop_transform: pubsub.MessageTransform = .{ .kind = .{ .javascript_udf = .{
    .function_name = "drop",
    .code = "function drop(message, metadata) { if (message.data === 'drop') return null; return message; }",
} } };
const boom_transform: pubsub.MessageTransform = .{ .kind = .{ .javascript_udf = .{
    .function_name = "boom",
    .code = "function boom(message, metadata) { throw new Error('no'); }",
} } };
const via_transform: pubsub.MessageTransform = .{ .kind = .{ .javascript_udf = .{
    .function_name = "via",
    .code = "function via(message, metadata) { message.attributes['via'] = 'subscription'; return message; }",
} } };

/// What a test of transforms wants of a message: its data, and the
/// attributes the test's functions write.
const Arrived = struct { data: []const u8, seen: ?[]const u8, via: ?[]const u8 };

/// Pulls and acknowledges until `count` messages have arrived, or for
/// `wait_s` seconds, and returns what came.
fn pullArrived(f: *Fixture, sub: pubsub.Subscription, count: usize, wait_s: i64) ![]const Arrived {
    const a = f.arena.allocator();
    var arrived: std.ArrayList(Arrived) = .empty;
    const deadline = nowMs() + wait_s * 1000;
    while (arrived.items.len < count and nowMs() < deadline) {
        var batch = sub.pull(.{ .max_messages = 10, .return_immediately = true }) catch |err| return f.fail(err);
        defer batch.deinit();
        if (batch.value.messages.len == 0) {
            try testing.io.sleep(.fromMilliseconds(250), .awake);
            continue;
        }
        for (batch.value.messages) |m| {
            sub.ack(&.{m.ack_id}) catch |err| return f.fail(err);
            try arrived.append(a, .{
                .data = try a.dupe(u8, m.data),
                .seen = if (m.attribute("seen")) |v| try a.dupe(u8, v) else null,
                .via = if (m.attribute("via")) |v| try a.dupe(u8, v) else null,
            });
        }
    }
    return arrived.items;
}

fn hasData(arrived: []const Arrived, data: []const u8) bool {
    for (arrived) |m| if (std.mem.eql(u8, m.data, data)) return true;
    return false;
}

fn expectTransform(want: pubsub.MessageTransform, have: pubsub.MessageTransform) !void {
    try testing.expectEqualStrings(want.kind.javascript_udf.function_name, have.kind.javascript_udf.function_name);
    try testing.expectEqualStrings(want.kind.javascript_udf.code, have.kind.javascript_udf.code);
    try testing.expectEqual(want.disabled, have.disabled);
}

test "message transforms: a topic's and a subscription's are kept, read back, replaced and cleared" {
    var f: Fixture = undefined;
    if (!try f.init()) return error.SkipZigTest;
    defer f.deinit();

    const topic = f.client.topic(f.id("smt"));
    try f.topics.append(testing.allocator, topic.id);
    var created = topic.create(.{ .message_transforms = &.{upper_transform} }) catch |err| return f.fail(err);
    defer created.deinit();
    try testing.expectEqual(1, created.value.message_transforms.len);
    try expectTransform(upper_transform, created.value.message_transforms[0]);
    var read = topic.get() catch |err| return f.fail(err);
    defer read.deinit();
    try testing.expectEqual(1, read.value.message_transforms.len);
    try expectTransform(upper_transform, read.value.message_transforms[0]);

    // A list replaces the list, in its order and with each one's switch;
    // an empty one clears it.
    var off = drop_transform;
    off.disabled = true;
    var replaced = topic.update(.{ .message_transforms = &.{ off, via_transform } }) catch |err| return f.fail(err);
    defer replaced.deinit();
    try testing.expectEqual(2, replaced.value.message_transforms.len);
    try expectTransform(off, replaced.value.message_transforms[0]);
    try expectTransform(via_transform, replaced.value.message_transforms[1]);
    var cleared = topic.update(.{ .message_transforms = &.{} }) catch |err| return f.fail(err);
    defer cleared.deinit();
    try testing.expectEqual(0, cleared.value.message_transforms.len);
    var plain = topic.get() catch |err| return f.fail(err);
    defer plain.deinit();
    try testing.expectEqual(0, plain.value.message_transforms.len);

    // The same on a subscription, which still pulls.
    const sub = f.client.subscription(f.id("smt-sub"));
    try f.subscriptions.append(testing.allocator, sub.id);
    var subscribed = sub.create(.{ .topic_id = topic.id, .message_transforms = &.{ via_transform, off } }) catch |err| return f.fail(err);
    defer subscribed.deinit();
    try testing.expectEqual(2, subscribed.value.message_transforms.len);
    try expectTransform(via_transform, subscribed.value.message_transforms[0]);
    try expectTransform(off, subscribed.value.message_transforms[1]);
    try testing.expectEqual(pubsub.DeliveryInfo.pull, subscribed.value.delivery);
    var sub_read = sub.get() catch |err| return f.fail(err);
    defer sub_read.deinit();
    try testing.expectEqual(2, sub_read.value.message_transforms.len);
    var sub_replaced = sub.update(.{ .message_transforms = &.{upper_transform} }) catch |err| return f.fail(err);
    defer sub_replaced.deinit();
    try testing.expectEqual(1, sub_replaced.value.message_transforms.len);
    try expectTransform(upper_transform, sub_replaced.value.message_transforms[0]);
    var sub_cleared = sub.update(.{ .message_transforms = &.{} }) catch |err| return f.fail(err);
    defer sub_cleared.deinit();
    try testing.expectEqual(0, sub_cleared.value.message_transforms.len);

    // A list in a page reads as it does alone.
    var back = topic.update(.{ .message_transforms = &.{upper_transform} }) catch |err| return f.fail(err);
    defer back.deinit();
    var token: ?[]const u8 = null;
    var found = false;
    var pages: usize = 0;
    while (!found) : (pages += 1) {
        if (pages > 200) return error.TestTooManyPages;
        var page = f.client.listTopics(.{ .page_size = 100, .page_token = token }) catch |err| return f.fail(err);
        defer page.deinit();
        for (page.value.topics) |t| {
            if (!std.mem.endsWith(u8, t.name, topic.id)) continue;
            found = true;
            try testing.expectEqual(1, t.message_transforms.len);
            try expectTransform(upper_transform, t.message_transforms[0]);
        }
        token = try f.arena.allocator().dupe(u8, page.value.next_page_token orelse break);
    }
    try testing.expect(found);
}

test "message transforms: production rewrites, drops and refuses with them, and the emulator delivers every message untouched" {
    var f: Fixture = undefined;
    if (!try f.init()) return error.SkipZigTest;
    defer f.deinit();

    // A topic whose function upper-cases, with a plain subscription and
    // one that has a function of its own.
    const topic = f.client.topic(f.id("smt-up"));
    try f.topics.append(testing.allocator, topic.id);
    var created = topic.create(.{ .message_transforms = &.{upper_transform} }) catch |err| return f.fail(err);
    created.deinit();
    const plain = try f.createSubscription("smt-up-plain", .{ .topic_id = topic.id });
    const tagged = try f.createSubscription("smt-up-via", .{ .topic_id = topic.id, .message_transforms = &.{via_transform} });
    var sent = topic.publish(&.{.{ .data = "hello" }}, .{}) catch |err| return f.fail(err);
    sent.deinit();
    const from_plain = try pullArrived(&f, plain, 1, f.patience());
    const from_tagged = try pullArrived(&f, tagged, 1, f.patience());
    try testing.expectEqual(1, from_plain.len);
    try testing.expectEqual(1, from_tagged.len);
    if (f.production) {
        try testing.expectEqualStrings("HELLO", from_plain[0].data);
        try testing.expectEqualStrings("yes", from_plain[0].seen.?);
        try testing.expectEqual(null, from_plain[0].via);
        try testing.expectEqualStrings("HELLO", from_tagged[0].data);
        try testing.expectEqualStrings("subscription", from_tagged[0].via.?);
    } else {
        try testing.expectEqualStrings("hello", from_plain[0].data);
        try testing.expectEqual(null, from_plain[0].seen);
        try testing.expectEqualStrings("hello", from_tagged[0].data);
        try testing.expectEqual(null, from_tagged[0].via);
    }

    // A function that returns null drops the message, and the publisher
    // is still given an id for it: a dropped message looks published.
    const dropping = f.client.topic(f.id("smt-drop"));
    try f.topics.append(testing.allocator, dropping.id);
    var dropping_made = dropping.create(.{ .message_transforms = &.{drop_transform} }) catch |err| return f.fail(err);
    dropping_made.deinit();
    const kept = try f.createSubscription("smt-drop-sub", .{ .topic_id = dropping.id });
    var both = dropping.publish(&.{ .{ .data = "drop" }, .{ .data = "keep" } }, .{}) catch |err| return f.fail(err);
    defer both.deinit();
    try testing.expectEqual(2, both.value.message_ids.len);
    try testing.expect(both.value.message_ids[0].len > 0 and both.value.message_ids[1].len > 0);
    if (f.production) {
        const first = try pullArrived(&f, kept, 1, f.patience());
        try testing.expectEqual(1, first.len);
        try testing.expectEqualStrings("keep", first[0].data);
        // Ten seconds more, and the dropped one has still not come.
        try testing.expectEqual(0, (try pullArrived(&f, kept, 1, 10)).len);
    } else {
        const all = try pullArrived(&f, kept, 2, f.patience());
        try testing.expectEqual(2, all.len);
        try testing.expect(hasData(all, "drop") and hasData(all, "keep"));
    }

    // A function that throws refuses the whole publish.
    const throwing = f.client.topic(f.id("smt-boom"));
    try f.topics.append(testing.allocator, throwing.id);
    var throwing_made = throwing.create(.{ .message_transforms = &.{boom_transform} }) catch |err| return f.fail(err);
    throwing_made.deinit();
    if (throwing.publish(&.{ .{ .data = "a" }, .{ .data = "b" } }, .{})) |refused| {
        var r = refused;
        r.deinit();
        try testing.expect(!f.production);
    } else |err| {
        if (!f.production) return f.fail(err);
        try testing.expectEqual(error.InvalidArgument, err);
        try testing.expect(std.mem.startsWith(u8, f.diag.message(), "Pub/Sub failed to apply a message transformation"));
    }

    // Code that does not parse: production's to refuse, when the topic is
    // made. The emulator keeps it.
    const broken = f.client.topic(f.id("smt-bad"));
    try f.topics.append(testing.allocator, broken.id);
    const unparsed: pubsub.MessageTransform = .{ .kind = .{ .javascript_udf = .{ .function_name = "f", .code = "function f(message, metadata) {" } } };
    if (broken.create(.{ .message_transforms = &.{unparsed} })) |made| {
        var m = made;
        m.deinit();
        try testing.expect(!f.production);
    } else |err| {
        if (!f.production) return f.fail(err);
        try testing.expectEqual(error.FailedPrecondition, err);
        try testing.expect(std.mem.startsWith(u8, f.diag.message(), "Provided message transform configuration is invalid"));
    }
}

// Import topics. Production connects to the source when the topic is made
// and refuses what it cannot reach; the emulator keeps whatever it is
// given, reports no state and imports nothing (emulator 0.8.36,
// 2026-10-12). No account on another cloud is used: in production the
// four sources there are tested to their refusals.

fn expectSameSource(want: pubsub.Ingestion.Source, have: pubsub.Ingestion.Source) !void {
    try testing.expectEqual(std.meta.activeTag(want), std.meta.activeTag(have));
    switch (want) {
        .cloud_storage => |w| {
            const h = have.cloud_storage;
            try testing.expectEqualStrings(w.bucket, h.bucket);
            try testing.expectEqual(std.meta.activeTag(w.format), std.meta.activeTag(h.format));
            if (w.format == .text) try testing.expectEqualStrings(w.format.text.delimiter, h.format.text.delimiter);
            try testing.expectEqual(w.minimum_object_create_time, h.minimum_object_create_time);
            try testing.expectEqualStrings(w.match_glob, h.match_glob);
        },
        inline else => |w, tag| {
            const h = @field(have, @tagName(tag));
            inline for (@typeInfo(@TypeOf(w)).@"struct".field_names) |name| {
                try testing.expectEqualStrings(@field(w, name), @field(h, name));
            }
        },
    }
}

test "import topics: each source is kept and read back by the emulator, and refused by production, which cannot reach a made-up one" {
    var f: Fixture = undefined;
    if (!try f.init()) return error.SkipZigTest;
    defer f.deinit();
    const a = f.arena.allocator();
    // The caller must be able to act as the account: in production, the
    // test's own.
    const account = try a.print("zig-gcp@{s}.iam.gserviceaccount.com", .{f.client.project_id});
    const cases = [_]struct { []const u8, pubsub.Ingestion.Source, anyerror, []const u8 }{
        .{ "imp-kinesis", .{ .aws_kinesis = .{
            .stream_arn = "arn:aws:kinesis:us-east-1:111111111111:stream/zigps",
            .consumer_arn = "arn:aws:kinesis:us-east-1:111111111111:stream/zigps/consumer/c:1",
            .aws_role_arn = "arn:aws:iam::111111111111:role/zigps",
            .gcp_service_account = account,
        } }, error.PermissionDenied, "Cloud Pub/Sub does not have the necessary permissions settings on the ingestion data source" },
        .{ "imp-gcs", .{ .cloud_storage = .{
            .bucket = f.id("no-such-bucket"),
            .format = .{ .text = .{ .delimiter = "|" } },
            .minimum_object_create_time = .{ .nanoseconds = 1_791_772_433_500_000_000 },
            .match_glob = "logs/**.txt",
        } }, error.NotFound, "Cloud Pub/Sub encountered a not-found error while trying to connect to the ingestion data source" },
        .{ "imp-hubs", .{ .azure_event_hubs = .{
            .resource_group = "rg",
            .namespace = "ns",
            .event_hub = "eh",
            .client_id = "11111111-1111-1111-1111-111111111111",
            .tenant_id = "22222222-2222-2222-2222-222222222222",
            .subscription_id = "33333333-3333-3333-3333-333333333333",
            .gcp_service_account = account,
        } }, error.NotFound, "Cloud Pub/Sub encountered a not-found error while trying to connect to the ingestion data source" },
        .{ "imp-msk", .{ .aws_msk = .{
            .cluster_arn = "arn:aws:kafka:us-east-1:111111111111:cluster/zigps/abc",
            .topic = "t",
            .aws_role_arn = "arn:aws:iam::111111111111:role/zigps",
            .gcp_service_account = account,
        } }, error.PermissionDenied, "Cloud Pub/Sub does not have the necessary permissions settings on the ingestion data source" },
        .{ "imp-confluent", .{ .confluent_cloud = .{
            .bootstrap_server = "pkc-xxxx.us-east-1.aws.confluent.cloud:9092",
            .cluster_id = "lkc-xxxx",
            .topic = "t",
            .identity_pool_id = "pool-xxxx",
            .gcp_service_account = account,
        } }, error.InvalidArgument, "Cloud Pub/Sub received invalid argument/s for the ingestion data source" },
    };
    for (cases) |case| {
        const suffix, const source, const production_error, const production_words = case;
        const topic = f.client.topic(f.id(suffix));
        try f.topics.append(testing.allocator, topic.id);
        if (topic.create(.{ .ingestion = .{ .source = source, .log_severity = .warning } })) |made| {
            var created = made;
            defer created.deinit();
            // Only the emulator takes a source nobody can reach.
            try testing.expect(!f.production);
            const kept = created.value.ingestion orelse return error.TestExpectedEqual;
            try expectSameSource(source, kept.source.?);
            try testing.expectEqual(pubsub.Ingestion.LogSeverity.warning, kept.log_severity);
            try testing.expectEqual(pubsub.IngestionState.unknown, kept.state);
            var read = topic.get() catch |err| return f.fail(err);
            defer read.deinit();
            try expectSameSource(source, read.value.ingestion.?.source.?);
            try testing.expectEqual(pubsub.Ingestion.LogSeverity.warning, read.value.ingestion.?.log_severity);
        } else |err| {
            if (!f.production) return f.fail(err);
            try testing.expectEqual(production_error, err);
            try testing.expect(std.mem.startsWith(u8, f.diag.message(), production_words));
        }
    }
}

test "import topics on the emulator: an update replaces the settings whole, and a clear makes a standard topic" {
    var f: Fixture = undefined;
    if (!try f.init()) return error.SkipZigTest;
    defer f.deinit();
    // Production refuses every source this test could name without a
    // bucket of its own; its turn is the gated test.
    if (f.production) return error.SkipZigTest;

    const topic = f.client.topic(f.id("imp-upd"));
    try f.topics.append(testing.allocator, topic.id);
    const from_bucket: pubsub.Ingestion.Source = .{ .cloud_storage = .{ .bucket = "my-uploads", .format = .pubsub_avro } };
    var created = topic.create(.{ .ingestion = .{ .source = from_bucket, .log_severity = .debug } }) catch |err| return f.fail(err);
    defer created.deinit();
    try expectSameSource(from_bucket, created.value.ingestion.?.source.?);
    try testing.expectEqual(pubsub.Ingestion.LogSeverity.debug, created.value.ingestion.?.log_severity);

    // Another source, and no word on logs: the old source and its logs
    // are both gone.
    const from_msk: pubsub.Ingestion.Source = .{ .aws_msk = .{
        .cluster_arn = "arn:aws:kafka:us-east-1:111111111111:cluster/zigps/abc",
        .topic = "t",
        .aws_role_arn = "arn:aws:iam::111111111111:role/zigps",
        .gcp_service_account = "zig-gcp@test.iam.gserviceaccount.com",
    } };
    var changed = topic.update(.{ .ingestion = .{ .set = .{ .source = from_msk } } }) catch |err| return f.fail(err);
    defer changed.deinit();
    try expectSameSource(from_msk, changed.value.ingestion.?.source.?);
    try testing.expectEqual(pubsub.Ingestion.LogSeverity.disabled, changed.value.ingestion.?.log_severity);
    var read = topic.get() catch |err| return f.fail(err);
    defer read.deinit();
    try expectSameSource(from_msk, read.value.ingestion.?.source.?);

    var standard = topic.update(.{ .ingestion = .clear }) catch |err| return f.fail(err);
    defer standard.deinit();
    try testing.expectEqual(null, standard.value.ingestion);
    // Clearing a topic that has none is taken too, and a standard topic
    // becomes an import topic by an update.
    var still = topic.update(.{ .ingestion = .clear }) catch |err| return f.fail(err);
    defer still.deinit();
    try testing.expectEqual(null, still.value.ingestion);
    var again = topic.update(.{ .ingestion = .{ .set = .{ .source = .{ .cloud_storage = .{ .bucket = "my-uploads", .format = .avro } }, .log_severity = .@"error" } } }) catch |err| return f.fail(err);
    defer again.deinit();
    try testing.expect(again.value.ingestion.?.source.?.cloud_storage.format == .avro);
    try testing.expectEqual(pubsub.Ingestion.LogSeverity.@"error", again.value.ingestion.?.log_severity);

    // The emulator's import topic takes a publish like any topic.
    var sent = topic.publish(&.{.{ .data = "by hand" }}, .{}) catch |err| return f.fail(err);
    defer sent.deinit();
    try testing.expectEqual(1, sent.value.message_ids.len);

    // A text delimiter is one byte, which is production's rule: the
    // emulator would take one wide character, so the client refuses it
    // before sending, as it refuses two.
    const tabbed = f.client.topic(f.id("imp-tab"));
    try f.topics.append(testing.allocator, tabbed.id);
    var by_tabs = tabbed.create(.{ .ingestion = .{ .source = .{ .cloud_storage = .{ .bucket = "my-uploads", .format = .{ .text = .{ .delimiter = "\t" } } } } } }) catch |err| return f.fail(err);
    defer by_tabs.deinit();
    try testing.expectEqualStrings("\t", by_tabs.value.ingestion.?.source.?.cloud_storage.format.text.delimiter);
    for ([_][]const u8{ "\u{20ac}", "\r\n" }) |delimiter| {
        try testing.expectError(error.InvalidArgument, tabbed.update(.{ .ingestion = .{ .set = .{ .source = .{ .cloud_storage = .{ .bucket = "my-uploads", .format = .{ .text = .{ .delimiter = delimiter } } } } } } }));
        try testing.expectEqualStrings("the text delimiter is not one character of one byte", f.diag.message());
    }
}

// Tags. Production binds a tag only when its key and value are there and
// the caller may use them, and returns none on a read; the emulator takes
// any key and any value (emulator 0.8.36, 2026-10-12).

test "tags: the emulator takes them on the three creates, and production refuses a key that is not there" {
    var f: Fixture = undefined;
    if (!try f.init()) return error.SkipZigTest;
    defer f.deinit();
    const a = f.arena.allocator();
    const tags = [_]pubsub.Tag{.{ .key = try a.print("{s}/zigps-no-such-key", .{f.client.project_id}), .value = "v" }};

    const topic = f.client.topic(f.id("tag"));
    try f.topics.append(testing.allocator, topic.id);
    if (topic.create(.{ .tags = &tags })) |made| {
        var created = made;
        created.deinit();
        try testing.expect(!f.production);
    } else |err| {
        if (!f.production) return f.fail(err);
        try testing.expectEqual(error.PermissionDenied, err);
        try testing.expect(std.mem.indexOf(u8, f.diag.message(), "(or it may not exist)") != null);
    }

    const plain = try f.createTopic("tag-plain");
    const sub = f.client.subscription(f.id("tag-sub"));
    try f.subscriptions.append(testing.allocator, sub.id);
    if (sub.create(.{ .topic_id = plain.id, .tags = &tags })) |made| {
        var created = made;
        created.deinit();
        try testing.expect(!f.production);
    } else |err| {
        if (!f.production) return f.fail(err);
        try testing.expectEqual(error.PermissionDenied, err);
    }
    if (f.production) return;

    // A snapshot with tags, of the subscription just made.
    const snapshot = f.client.snapshot(f.id("tag-snap"));
    try f.snapshots.append(testing.allocator, snapshot.id);
    var kept = snapshot.create(.{ .subscription = sub.id, .tags = &tags }) catch |err| return f.fail(err);
    defer kept.deinit();
    try testing.expect(std.mem.endsWith(u8, kept.value.name, snapshot.id));
    // Read back, each is what it was made as: the echoed tags are read past.
    var read = topic.get() catch |err| return f.fail(err);
    defer read.deinit();
    try testing.expect(std.mem.endsWith(u8, read.value.name, topic.id));
}
