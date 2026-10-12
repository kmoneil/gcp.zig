//! Pub/Sub with no server at all: a `Publisher` and a `Subscriber` over
//! `pubsub.testing.FakePubSub`, which keeps topics, subscriptions and
//! messages in this process and answers as production does. It is what a
//! test of your own code can stand on: see docs/pubsub/testing.md.
//!
//!     zig build example-in_memory -- 200
//!
//! Argument: how many messages to send (default 100). Two publishes are
//! refused and the answer to one acknowledgement is lost, to show the
//! library carrying on through both.

const std = @import("std");
const pubsub = @import("pubsub");

/// The library logs each retry as a warning under `.gcp_pubsub`; this
/// example asks for failures, so it shows errors alone.
pub const std_options: std.Options = .{
    .log_scope_levels = &.{.{ .scope = .gcp_pubsub, .level = .err }},
};

/// Counts the messages it is given. Called from several tasks at once.
const Counter = struct {
    handled: std.atomic.Value(usize) = .init(0),

    fn handler(self: *Counter) pubsub.Subscriber.Handler {
        return .{ .ptr = self, .vtable = &.{ .handle = handle } };
    }

    fn handle(ptr: *anyopaque, io: std.Io, message: pubsub.ReceivedMessage) anyerror!void {
        const self: *Counter = @ptrCast(@alignCast(ptr));
        _ = io;
        _ = message;
        _ = self.handled.fetchAdd(1, .monotonic);
    }
};

pub fn main(init: std.process.Init) !void {
    const gpa = init.gpa;
    const io = init.io;
    const args = try init.minimal.args.toSlice(init.arena.allocator());
    const count = if (args.len > 1) try std.fmt.parseInt(usize, args[1], 10) else 100;

    var stdout_buffer: [1024]u8 = undefined;
    var stdout = std.Io.File.stdout().writerStreaming(io, &stdout_buffer);
    const out = &stdout.interface;

    // A pull with nothing to give is held a moment, as production holds
    // one, so the subscriber's loop does not spin.
    var fake: pubsub.testing.FakePubSub = .init(gpa, io, .{ .empty_pull_hold = .fromMilliseconds(20) });
    defer fake.deinit();
    // A production client: the fake checks no credentials, and any token
    // will do.
    var token: pubsub.StaticToken = .{ .token = "none" };
    const options: pubsub.Client.Options = .{
        .project_id = "my-project",
        .token_provider = token.provider(),
        .transport = fake.transport(),
    };
    var client = try pubsub.Client.init(gpa, io, options);
    defer client.deinit();
    var topic = try client.topic("orders").create(.{});
    topic.deinit();
    var subscription = try client.subscription("orders-worker").create(.{ .topic_id = "orders" });
    subscription.deinit();

    // What a test would ask for, to see its code survive it.
    const refused = 2;
    fake.refuseNext(refused, 503, .publish);
    fake.loseAnswers(1, .acknowledge);

    var counter: Counter = .{};
    var subscriber = try pubsub.Subscriber.init(gpa, io, .{
        .subscription_id = "orders-worker",
        .client = options,
        .concurrency = 4,
    });
    defer subscriber.deinit();
    var subscribing = try io.concurrent(pubsub.Subscriber.run, .{ &subscriber, counter.handler() });

    var publisher = try pubsub.Publisher.init(gpa, io, .{ .topic_id = "orders", .client = options });
    defer publisher.deinit();
    var publishing = try io.concurrent(pubsub.Publisher.run, .{&publisher});
    var failed: usize = 0;
    var sent: usize = 0;
    while (sent < count) {
        var receipts: [64]pubsub.Publisher.Receipt = undefined;
        var made: usize = 0;
        defer for (receipts[0..made]) |r| r.release();
        while (made < receipts.len and sent < count) : (sent += 1) {
            var buf: [32]u8 = undefined;
            const data = std.fmt.bufPrint(&buf, "order {d}", .{sent}) catch unreachable;
            receipts[made] = publisher.publish(.{ .data = data }, .{}) catch {
                failed += 1;
                continue;
            };
            made += 1;
        }
        for (receipts[0..made]) |r| {
            if (r.wait()) |_| {} else |_| failed += 1;
        }
    }
    publisher.stop();
    try publishing.await(io);

    // Until the subscription has nothing left that is not acknowledged.
    while (fake.backlog("my-project", "orders-worker") > 0) try io.sleep(.fromMilliseconds(10), .awake);
    subscriber.stop();
    try subscribing.await(io);

    try out.print("published {d} messages in {d} requests, {d} of them refused and sent again\n", .{
        fake.publishedCount("my-project", "orders"), fake.requestCount(.publish), refused,
    });
    try out.print("handled {d}; {d} not acknowledged\n", .{ counter.handled.load(.monotonic), fake.backlog("my-project", "orders-worker") });
    try out.flush();
    if (failed > 0 or counter.handled.load(.monotonic) < count) return error.MessagesLost;
}
