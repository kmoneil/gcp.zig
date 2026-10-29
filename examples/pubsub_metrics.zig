//! A Pub/Sub subscriber whose counts become Cloud Monitoring metrics: a
//! `monitoring.Recorder` reads `Subscriber.stats()` at every write through
//! an observer, and writes them as one cumulative metric with an `outcome`
//! label, `received`, `acked`, `nacked` and so on, every 5 seconds.
//!
//!     GOOGLE_CLOUD_PROJECT=my-project zig build example-pubsub_metrics -- --subscription=orders-worker
//!     ... -- --subscription=orders-worker --seconds=300
//!     zig build example-pubsub_metrics -- --fake     # no network
//!
//! Credentials come from `auth.findDefault`; the subscription must exist.
//! Its messages are acknowledged as they come. `--fake` runs against
//! `pubsub.testing.FakePubSub` and `monitoring.testing.FakeMonitoring`,
//! publishes 500 messages, and prints what the in-memory Cloud Monitoring
//! holds at the end.
//!
//! The modules never import one another: this program wires them.

const std = @import("std");
const auth = @import("auth");
const pubsub = @import("pubsub");
const monitoring = @import("monitoring");

pub const std_options: std.Options = .{
    .log_scope_levels = &.{
        .{ .scope = .gcp_auth, .level = .warn },
        .{ .scope = .gcp_pubsub, .level = .err },
        .{ .scope = .gcp_monitoring, .level = .warn },
    },
};

const metric = "pubsub/subscriber/messages";

/// Reports a subscriber's counts, one series per outcome.
const SubscriberCounts = struct {
    subscriber: *pubsub.Subscriber,

    fn observer(self: *SubscriberCounts) monitoring.Recorder.Observer {
        return .{ .context = self, .report = report };
    }

    fn report(context: *anyopaque, into: *monitoring.Recorder.Report) void {
        const self: *SubscriberCounts = @ptrCast(@alignCast(context));
        const s = self.subscriber.stats();
        inline for (.{ "received", "acked", "ack_failed", "nacked", "handler_failures", "extended" }) |outcome| {
            into.int64(&.{outcome}, @intCast(@field(s, outcome)));
        }
    }
};

/// Acknowledges every message.
const Handler = struct {
    fn handler(self: *Handler) pubsub.Subscriber.Handler {
        return .{ .ptr = self, .vtable = &.{ .handle = handle } };
    }

    fn handle(_: *anyopaque, _: std.Io, _: pubsub.ReceivedMessage) anyerror!void {}
};

pub fn main(init: std.process.Init) !void {
    const gpa = init.gpa;
    const io = init.io;
    const arena = init.arena.allocator();
    var stdout_buffer: [4096]u8 = undefined;
    var stdout = std.Io.File.stdout().writerStreaming(io, &stdout_buffer);
    const out = &stdout.interface;

    var use_fake = false;
    var subscription_id: ?[]const u8 = null;
    var seconds: u32 = 60;
    const args = try init.minimal.args.toSlice(arena);
    for (args[@min(1, args.len)..]) |arg| {
        if (std.mem.eql(u8, arg, "--fake")) {
            use_fake = true;
        } else if (std.mem.startsWith(u8, arg, "--subscription=")) {
            subscription_id = arg["--subscription=".len..];
        } else if (std.mem.startsWith(u8, arg, "--seconds=")) {
            seconds = std.fmt.parseInt(u32, arg["--seconds=".len..], 10) catch return usage();
        } else return usage();
    }
    if (!use_fake and subscription_id == null) return usage();

    var fake_pubsub: pubsub.testing.FakePubSub = .init(gpa, io, .{ .empty_pull_hold = .fromMilliseconds(20) });
    defer fake_pubsub.deinit();
    var fake_monitoring: monitoring.testing.FakeMonitoring = .init(gpa, io, .{ .project_id = "my-project" });
    defer fake_monitoring.deinit();
    var creds: ?auth.Credentials = null;
    defer if (creds) |*c| c.deinit();
    var static: pubsub.StaticToken = .{ .token = "fake" };
    const project = if (use_fake) "my-project" else init.environ_map.get("GOOGLE_CLOUD_PROJECT") orelse {
        std.debug.print("set GOOGLE_CLOUD_PROJECT to the project of the subscription\n", .{});
        return error.MissingProject;
    };
    if (!use_fake) {
        const lookup = try auth.Lookup.fromEnv(init.environ_map, arena);
        creds = try auth.findDefault(gpa, io, lookup, .{});
    }
    const tokens = if (creds) |*c| c.provider() else static.provider();

    const pubsub_options: pubsub.Client.Options = .{
        .project_id = project,
        .token_provider = tokens,
        .transport = if (use_fake) fake_pubsub.transport() else null,
    };
    const sub_id = subscription_id orelse "orders-worker";
    if (use_fake) try seed(gpa, io, pubsub_options, sub_id);

    var subscriber = try pubsub.Subscriber.init(gpa, io, .{ .subscription_id = sub_id, .client = pubsub_options, .concurrency = 4 });
    defer subscriber.deinit();

    // Who is writing: this process, with an id of its own.
    const task_id = monitoring.Resource.randomTaskId(io);
    var recorder = try monitoring.Recorder.init(gpa, io, .{
        .client = .{ .project_id = project, .token_provider = tokens, .transport = if (use_fake) fake_monitoring.transport() else null },
        .resource = .{ .generic_task = .{ .location = "us-central1", .namespace = "zig-gcp", .job = "pubsub_metrics", .task_id = &task_id } },
        .interval_ms = 5_000,
    });
    defer recorder.deinit();
    var counts: SubscriberCounts = .{ .subscriber = &subscriber };
    try recorder.observe(.{
        .name = metric,
        .label_keys = &.{"outcome"},
        .unit = "{message}",
        .description = "Messages a gcp.zig subscriber handled, by outcome",
    }, .cumulative, std.Io.Clock.real.now(io), counts.observer());

    var handler: Handler = .{};
    var subscribing = try io.concurrent(pubsub.Subscriber.run, .{ &subscriber, handler.handler() });
    var recording = try io.concurrent(monitoring.Recorder.run, .{&recorder});

    if (use_fake) {
        // Until every message is acknowledged, and one write has gone.
        while (fake_pubsub.backlog("my-project", sub_id) > 0) try io.sleep(.fromMilliseconds(20), .awake);
        try io.sleep(.fromSeconds(6), .awake);
    } else {
        try out.print("subscribed to {s} for {d} s, writing custom.googleapis.com/{s} as task {s}\n", .{ sub_id, seconds, metric, &task_id });
        try out.flush();
        try io.sleep(.fromSeconds(seconds), .awake);
    }
    subscriber.stop();
    try subscribing.await(io);
    // The last write, with the subscriber's final counts.
    recorder.stop();
    try recording.await(io);

    const s = recorder.stats();
    try out.print("{d} writes, {d} points written, {d} refused, {d} failed\n", .{ s.requests, s.points_written, s.points_refused, s.points_failed });
    if (use_fake) {
        try out.print("\ncustom.googleapis.com/{s}, as the in-memory Cloud Monitoring holds it:\n", .{metric});
        inline for (.{ "received", "acked", "nacked" }) |outcome| {
            const points = try fake_monitoring.points(arena, "custom.googleapis.com/" ++ metric, &.{.{ .key = "outcome", .value = outcome }});
            if (points.len > 0) try out.print("  {s}: {d}, in {d} points\n", .{ outcome, points[points.len - 1].value.int64, points.len });
        }
    }
    try out.flush();
}

/// A topic, the subscription, and 500 messages, in the in-memory Pub/Sub.
fn seed(gpa: std.mem.Allocator, io: std.Io, options: pubsub.Client.Options, sub_id: []const u8) !void {
    var client = try pubsub.Client.init(gpa, io, options);
    defer client.deinit();
    var topic = try client.topic("orders").create(.{});
    topic.deinit();
    var sub = try client.subscription(sub_id).create(.{ .topic_id = "orders" });
    sub.deinit();
    var batch: [100]pubsub.Message = undefined;
    var bufs: [100][16]u8 = undefined;
    for (0..5) |b| {
        for (&batch, &bufs, 0..) |*m, *buf, i| m.* = .{ .data = std.fmt.bufPrint(buf, "order {d}", .{b * 100 + i}) catch unreachable };
        var sent = try client.topic("orders").publish(&batch, .{});
        sent.deinit();
    }
}

fn usage() error{Usage} {
    std.debug.print("usage: pubsub_metrics --subscription=ID [--seconds=N] | --fake\n", .{});
    return error.Usage;
}
