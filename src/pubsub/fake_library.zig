//! The library through the in-memory Pub/Sub: a `Publisher` and a
//! `Subscriber` over one `FakePubSub`, each with its own tasks, on a real
//! clock, while the fake fails calls of every kind as it is asked to.
//! What a caller's own test would do with the two, held here to what the
//! library promises: every message published is handled, and with
//! exactly-once delivery handled once.

const std = @import("std");
const core = @import("core");

const Client = @import("Client.zig");
const Publisher = @import("Publisher.zig");
const Subscriber = @import("Subscriber.zig");
const FakePubSub = @import("fake_pubsub.zig").FakePubSub;
const types = @import("types.zig");
const testing = std.testing;

const publishers = 4;
const each = 50;
const messages = publishers * each;

/// A handler that counts what it is given: each message by its number,
/// and each message id.
const Seen = struct {
    mutex: std.Io.Mutex = .init,
    by_number: [messages]u32 = @splat(0),
    ids: std.StringHashMapUnmanaged(u32) = .empty,
    handled: usize = 0,

    fn deinit(self: *Seen) void {
        var it = self.ids.keyIterator();
        while (it.next()) |id| testing.allocator.free(id.*);
        self.ids.deinit(testing.allocator);
    }

    fn handler(self: *Seen) Subscriber.Handler {
        return .{ .ptr = self, .vtable = &.{ .handle = handle } };
    }

    fn handle(ptr: *anyopaque, io: std.Io, message: types.ReceivedMessage) anyerror!void {
        const self: *Seen = @ptrCast(@alignCast(ptr));
        const number = try std.fmt.parseInt(usize, message.data, 10);
        self.mutex.lockUncancelable(io);
        defer self.mutex.unlock(io);
        self.by_number[number] += 1;
        self.handled += 1;
        const entry = try self.ids.getOrPut(testing.allocator, message.message_id);
        if (entry.found_existing) {
            entry.value_ptr.* += 1;
        } else {
            entry.key_ptr.* = try testing.allocator.dupe(u8, message.message_id);
            entry.value_ptr.* = 1;
        }
    }

    fn distinctIds(self: *Seen, io: std.Io) usize {
        self.mutex.lockUncancelable(io);
        defer self.mutex.unlock(io);
        return self.ids.count();
    }
};

/// Publishes one task's share, and waits for each message to be sent.
fn publishShare(publisher: *Publisher, task: usize, failures: *std.atomic.Value(usize)) std.Io.Cancelable!void {
    var receipts: [each]Publisher.Receipt = undefined;
    var made: usize = 0;
    defer for (receipts[0..made]) |r| r.release();
    for (0..each) |i| {
        var buf: [8]u8 = undefined;
        const data = std.fmt.bufPrint(&buf, "{d}", .{task * each + i}) catch unreachable;
        receipts[made] = publisher.publish(.{ .data = data }, .{}) catch |err| {
            if (err == error.Canceled) return error.Canceled;
            _ = failures.fetchAdd(1, .monotonic);
            continue;
        };
        made += 1;
    }
    for (receipts[0..made]) |r| {
        if (r.wait()) |_| {} else |err| {
            if (err == error.Canceled) return error.Canceled;
            _ = failures.fetchAdd(1, .monotonic);
        }
    }
}

const Faults = enum {
    /// A publish whose answer is lost has landed, and is sent again: the
    /// topic then holds the message twice, under two ids, as production's
    /// would.
    with_a_lost_publish,
    /// Every fault but that one, which no subscription can make up for.
    without,
};

fn through(exactly_once: bool, faults: Faults) !void {
    const gpa = testing.allocator;
    const io = testing.io;
    var fake: FakePubSub = .init(gpa, io, .{ .empty_pull_hold = .fromMilliseconds(20) });
    defer fake.deinit();
    var token: core.StaticToken = .{ .token = "fake" };
    const options: Client.Options = .{
        .project_id = "p",
        .token_provider = token.provider(),
        .transport = fake.transport(),
        // A test need not wait out a real backoff.
        .retry = .{ .max_attempts = 8, .initial_backoff_ms = 1, .max_backoff_ms = 5 },
    };
    var client = try Client.init(gpa, io, options);
    defer client.deinit();
    var topic = try client.topic("orders").create(.{});
    topic.deinit();
    var subscription = try client.subscription("worker").create(.{ .topic_id = "orders", .ack_deadline_seconds = 600, .enable_exactly_once_delivery = exactly_once });
    subscription.deinit();

    var seen: Seen = .{};
    defer seen.deinit();
    var subscriber = try Subscriber.init(gpa, io, .{ .subscription_id = "worker", .client = options, .concurrency = 3 });
    defer subscriber.deinit();
    var subscribing = try io.concurrent(Subscriber.run, .{ &subscriber, seen.handler() });
    // A failure below must not leave a task running on a fake that is
    // about to be freed.
    errdefer {
        subscriber.stop();
        subscribing.await(io) catch {};
    }
    var publisher = try Publisher.init(gpa, io, .{ .topic_id = "orders", .client = options, .max_batch_messages = 7 });
    defer publisher.deinit();
    var publishing = try io.concurrent(Publisher.run, .{&publisher});
    errdefer {
        publisher.stop();
        publishing.await(io) catch {};
    }

    // A fault of each kind, moved from one kind of call to the next while
    // the two run: a refusal changes nothing, a lost answer lands, and a
    // drop is a broken connection. No pull's answer is lost: its messages
    // would be out on their leases with nobody holding them, as
    // production's would, and come again only when those lapse.
    var failures: std.atomic.Value(usize) = .init(0);
    var group: std.Io.Group = .init;
    defer group.cancel(io);
    for (0..publishers) |task| try group.concurrent(io, publishShare, .{ &publisher, task, &failures });
    const kinds = [_]FakePubSub.Calls{ .pull, .acknowledge, .publish, .modify_ack_deadline };
    for (0..12) |round| {
        const kind = kinds[round % kinds.len];
        fake.refuseNext(1, 503, kind);
        fake.dropNext(1, kinds[(round + 1) % kinds.len]);
        if (kind != .pull and (kind != .publish or faults == .with_a_lost_publish)) fake.loseAnswers(1, kind);
        try io.sleep(.fromMilliseconds(5), .awake);
    }
    try group.await(io);
    try testing.expectEqual(0, failures.load(.monotonic));
    publisher.stop();
    try publishing.await(io);

    // Until everything the topic was sent has been handled and
    // acknowledged, or a test's patience runs out.
    const sent = fake.publishedCount("p", "orders");
    var waited_ms: usize = 0;
    while (seen.distinctIds(io) < sent or fake.backlog("p", "worker") > 0) : (waited_ms += 5) {
        if (waited_ms > 30_000) {
            std.debug.print("the topic was sent {d}, {d} were handled, {d} are not acknowledged and {d} of those are out: {any}\n", .{ sent, seen.distinctIds(io), fake.backlog("p", "worker"), fake.outstanding("p", "worker"), subscriber.stats() });
            return error.TheSubscriberDidNotFinish;
        }
        try io.sleep(.fromMilliseconds(5), .awake);
    }
    subscriber.stop();
    try subscribing.await(io);

    try testing.expect(sent >= messages);
    if (faults == .without) try testing.expectEqual(messages, sent);
    for (seen.by_number) |count| try testing.expect(count >= 1);
    try testing.expectEqual(sent, seen.ids.count());
    try testing.expectEqual(0, fake.backlog("p", "worker"));
    if (exactly_once) {
        // No lease lapsed in ten minutes: each message was given once,
        // and an ack sent again after its answer was lost was taken.
        var it = seen.ids.valueIterator();
        while (it.next()) |count| try testing.expectEqual(1, count.*);
        try testing.expectEqual(sent, seen.handled);
    }
}

test "fake, the library through it: what a Publisher sends, a Subscriber handles, with faults on every kind of call" {
    try through(false, .with_a_lost_publish);
    try through(false, .without);
}

test "fake, the library through it: with exactly-once delivery each message is handled once" {
    try through(true, .without);
    try through(true, .with_a_lost_publish);
}
