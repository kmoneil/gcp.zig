//! Integration tests against real Cloud Monitoring, which has no emulator:
//! milestone 4 of the Monitoring spec. They need a project with the API on,
//! and a token that may write and read metrics and create and delete
//! descriptors there (Editor does):
//!
//!     GCP_TEST_PROJECT=extractctl GCP_TEST_TOKEN=$(cat token.txt) \
//!     zig build test-integration-gcp -Dtest-filter=monitoring
//!
//! Without both variables every test skips. Each run writes only under
//! `custom.googleapis.com/zigps-<run>/` and deletes every descriptor there
//! as it ends, failed or not; the points of a deleted descriptor are no
//! longer readable. Writes are free, and the reads, a few hundred series,
//! are far inside the free million a month. The last test runs the same
//! script against production and against `FakeMonitoring`, and holds the
//! fake to what production did.
//!
//! One more test reads Pub/Sub's own metrics, and takes about ten minutes,
//! so it runs only with MONITORING_TEST_PUBSUB=1 as well. It makes a topic
//! and two subscriptions named `zigps-mon-<run>`, sends traffic for four
//! minutes, waits until Monitoring shows it and its reads end five minutes
//! in the past, and deletes them as it ends.
//! It puts production's raw points into `FakeMonitoring` and holds every
//! aligned answer of the fake to production's, and its refusals of
//! filters, aligners and writes, its descriptors and resource types
//! (issue #239). Production refuses the writes it tries: one of Google's
//! metrics, a create under Google's domain, and a user metric on
//! `pubsub_subscription`, whose descriptor it makes all the same, under
//! the run's prefix.
//!
//! A quota test (MONITORING_TEST_QUOTA=1, about seven minutes) does the
//! same for Cloud's quota metrics (issue #247): it sends Pub/Sub topic
//! lists to consume rate quota, waits until Monitoring shows their
//! minute, puts the project's own quota series for two services over 26
//! hours into the fake, and holds the fake to production's answers,
//! refusals, descriptors and the `consumer_quota` resource type. It
//! creates and deletes nothing but the run's own user descriptor.

const std = @import("std");
const core = @import("core");
const monitoring = @import("monitoring");
const pubsub = @import("pubsub");
const testing = std.testing;
const Allocator = std.mem.Allocator;

const Fixture = struct {
    env: std.process.Environ.Map,
    token: core.StaticToken,
    diag: monitoring.Diagnostics,
    client: monitoring.Client,
    project: []const u8,
    arena: std.heap.ArenaAllocator,
    run: []const u8,
    /// "custom.googleapis.com/zigps-<run>/".
    prefix: []const u8,

    fn init(f: *Fixture) !bool {
        const gpa = testing.allocator;
        f.env = try testing.environ.createMap(gpa);
        errdefer f.env.deinit();
        f.project = f.env.get("GCP_TEST_PROJECT") orelse return f.skip();
        const token = f.env.get("GCP_TEST_TOKEN") orelse return f.skip();
        f.token = .{ .token = std.mem.trim(u8, token, &std.ascii.whitespace) };
        f.diag = .{};
        f.arena = .init(gpa);
        errdefer f.arena.deinit();
        var bytes: [3]u8 = undefined;
        testing.io.random(&bytes);
        f.run = try f.arena.allocator().print("{x}", .{bytes});
        f.prefix = try f.arena.allocator().print("custom.googleapis.com/zigps-{s}/", .{f.run});
        f.client = try .init(gpa, testing.io, .{
            .project_id = f.project,
            .token_provider = f.token.provider(),
            .diagnostics = &f.diag,
            .user_agent = "zig-gcp-monitoring-gcp-integration/0.1",
        });
        return true;
    }

    fn skip(f: *Fixture) bool {
        f.env.deinit();
        return false;
    }

    /// Deletes every descriptor under the run's prefix, then the rest.
    fn deinit(f: *Fixture) void {
        f.cleanup() catch |err| std.debug.print("cleanup of {s} failed: {t}\n", .{ f.prefix, err });
        f.client.deinit();
        f.arena.deinit();
        f.env.deinit();
    }

    fn cleanup(f: *Fixture) !void {
        var token: ?[]const u8 = null;
        var scratch: std.heap.ArenaAllocator = .init(testing.allocator);
        defer scratch.deinit();
        while (true) {
            var page = try f.client.listMetrics(.{ .prefix = f.prefix, .page_token = token });
            defer page.deinit();
            for (page.value.metrics) |m| f.client.metric(m.type).delete() catch |err| switch (err) {
                error.NotFound => {},
                else => return err,
            };
            token = if (page.value.next_page_token) |t| try scratch.allocator().dupe(u8, t) else null;
            if (token == null) break;
        }
    }

    fn name(f: *Fixture, short: []const u8) ![]const u8 {
        return f.arena.allocator().print("{s}{s}", .{ f.prefix, short });
    }

    fn task(f: *Fixture, id: []const u8) monitoring.Resource {
        _ = f;
        return .{ .generic_task = .{ .location = "us-central1", .namespace = "zigps", .job = "it", .task_id = id } };
    }

    /// Reads a descriptor until it reads back: production answered 404 for
    /// about 2 s after a create, and once, on 2026-10-19, for more than
    /// 15 s.
    fn awaitDescriptor(f: *Fixture, metric_type: []const u8) !monitoring.Owned(monitoring.MetricInfo) {
        for (0..120) |_| {
            if (f.client.metric(metric_type).get()) |info| return info else |err| switch (err) {
                error.NotFound => try testing.io.sleep(.fromMilliseconds(500), .awake),
                else => return err,
            }
        }
        return error.TestDescriptorNeverReadable;
    }

    /// Reads until at least `points` points come back, as production shows
    /// a point within a second when measured.
    fn awaitRead(f: *Fixture, metric_type: []const u8, options: monitoring.ReadOptions, points: usize) !monitoring.Owned(monitoring.SeriesPage) {
        for (0..40) |_| {
            var page = try f.client.metric(metric_type).read(options);
            var n: usize = 0;
            for (page.value.series) |s| n += s.points.len;
            if (n >= points) return page;
            page.deinit();
            try testing.io.sleep(.fromMilliseconds(500), .awake);
        }
        return error.TestPointsNeverReadable;
    }
};

fn fact(comptime format: []const u8, args: anytype) void {
    std.debug.print("  " ++ format ++ "\n", args);
}

fn nowMs() i96 {
    const now = std.Io.Clock.real.now(testing.io).nanoseconds;
    return @divFloor(now, std.time.ns_per_ms) * std.time.ns_per_ms;
}

fn at(base: i96, ms: i64) std.Io.Timestamp {
    return .{ .nanoseconds = base + @as(i96, ms) * std.time.ns_per_ms };
}

test "monitoring: descriptors created, read back once readable, listed by prefix, deleted" {
    var f: Fixture = undefined;
    if (!try f.init()) return error.SkipZigTest;
    defer f.deinit();
    const m = f.client.metric(try f.name("descriptors/orders"));
    var made = try m.create(.{ .kind = .cumulative, .value_type = .int64, .unit = "{order}", .description = "zig-gcp integration", .display_name = "Orders", .labels = &.{ .{ .key = "region" }, .{ .key = "paid", .value_type = .bool } } });
    made.deinit();
    var read = try f.awaitDescriptor(m.type);
    defer read.deinit();
    try testing.expectEqual(.cumulative, read.value.kind);
    try testing.expectEqualStrings("{order}", read.value.unit);
    try testing.expectEqualStrings("Orders", read.value.display_name);
    try testing.expectEqual(.bool, read.value.label("paid").?.value_type);
    try testing.expect(read.value.resource_types.len > 7);
    // The same create again answers it; another kind is refused.
    var again = try m.create(.{ .kind = .cumulative, .value_type = .int64, .unit = "{order}", .labels = &.{.{ .key = "region" }} });
    again.deinit();
    try testing.expectError(error.AlreadyExists, m.create(.{ .kind = .gauge, .value_type = .int64 }));
    var listed = false;
    for (0..30) |_| {
        var page = try f.client.listMetrics(.{ .prefix = try f.name("descriptors/") });
        defer page.deinit();
        if (page.value.metrics.len == 1) {
            listed = true;
            break;
        }
        try testing.io.sleep(.fromMilliseconds(500), .awake);
    }
    try testing.expect(listed);
    try m.delete();
    try testing.expectError(error.NotFound, m.delete());
    var generic = try f.client.resourceType("generic_task");
    defer generic.deinit();
    try testing.expectEqualStrings("Generic Task", generic.value.display_name);
    try testing.expectError(error.NotFound, f.client.resourceType("no_such_type"));
}

test "monitoring: every value type written and read back exactly, and production's refusals as results" {
    var f: Fixture = undefined;
    if (!try f.init()) return error.SkipZigTest;
    defer f.deinit();
    const base = nowMs() - 10 * std.time.ns_per_min;
    const r = f.task(f.run);
    const dist: monitoring.Distribution = .{ .count = 4, .mean = 2.5, .sum_of_squared_deviation = 5, .buckets = .{ .explicit = &.{ 1, 2, 4 } }, .bucket_counts = &.{ 0, 1, 2, 1 } };
    const written = [_]monitoring.TimeSeries{
        .{ .metric_type = try f.name("values/int"), .resource = r, .kind = .gauge, .end = .{ .nanoseconds = base + 123_456_789 }, .value = .{ .int64 = -42 } },
        .{ .metric_type = try f.name("values/double"), .resource = r, .kind = .gauge, .end = at(base, 0), .value = .{ .double = 0.1 } },
        .{ .metric_type = try f.name("values/nan"), .resource = r, .kind = .gauge, .end = at(base, 0), .value = .{ .double = std.math.nan(f64) } },
        .{ .metric_type = try f.name("values/bool"), .resource = r, .kind = .gauge, .end = at(base, 0), .value = .{ .bool = true } },
        .{ .metric_type = try f.name("values/total"), .resource = r, .kind = .cumulative, .start = at(base, -60_000), .end = at(base, 0), .value = .{ .int64 = 4217 } },
        .{ .metric_type = try f.name("values/latency"), .resource = r, .kind = .cumulative, .unit = "ms", .start = at(base, -60_000), .end = at(base, 0), .value = .{ .distribution = dist } },
    };
    var result = try f.client.write(&written);
    defer result.deinit();
    try testing.expect(result.value.ok());
    for (written) |s| {
        var page = try f.awaitRead(s.metric_type, .{ .start = at(base, -1_000), .end = at(base, 1_000) }, 1);
        defer page.deinit();
        const got = page.value.series[0];
        try testing.expectEqual(s.kind, got.kind);
        const p = got.points[0];
        // Microseconds, as production keeps them.
        try testing.expectEqual(@divFloor(s.end.nanoseconds, std.time.ns_per_us) * std.time.ns_per_us, p.end.nanoseconds);
        switch (s.value) {
            .int64 => |n| try testing.expectEqual(n, p.value.?.int64),
            .double => |d| if (std.math.isNan(d)) try testing.expect(std.math.isNan(p.value.?.double)) else try testing.expectEqual(d, p.value.?.double),
            .bool => |b| try testing.expectEqual(b, p.value.?.bool),
            .distribution => |d| {
                const back = p.value.?.distribution;
                try testing.expectEqual(d.count, back.count);
                try testing.expectEqual(d.mean, back.mean);
                try testing.expectEqual(d.sum_of_squared_deviation, back.sum_of_squared_deviation);
                try testing.expectEqualSlices(f64, d.buckets.explicit, back.buckets.explicit);
                try testing.expectEqualSlices(u64, d.bucket_counts, back.bucket_counts);
            },
            else => unreachable,
        }
    }

    // Refusals come back in the result.
    const g = try f.name("refusals/g");
    var first = try f.client.write(&.{.{ .metric_type = g, .resource = r, .kind = .gauge, .end = at(base, 0), .value = .{ .int64 = 1 } }});
    first.deinit();
    var soon = try f.client.write(&.{.{ .metric_type = g, .resource = r, .kind = .gauge, .end = at(base, 1_000), .value = .{ .int64 = 2 } }});
    defer soon.deinit();
    try testing.expectEqual(0, soon.value.written);
    try testing.expectEqual(error.FailedPrecondition, soon.value.refused[0].reason);
    try testing.expectEqual(400, f.diag.http_status);
    var mixed = try f.client.write(&.{
        .{ .metric_type = g, .metric_labels = &.{.{ .key = "k", .value = "a" }}, .resource = r, .kind = .gauge, .end = at(base, 0), .value = .{ .int64 = 1 } },
        .{ .metric_type = g, .metric_labels = &.{.{ .key = "k", .value = "b" }}, .resource = r, .kind = .gauge, .end = .{ .nanoseconds = nowMs() + 6 * std.time.ns_per_min }, .value = .{ .int64 = 1 } },
    });
    defer mixed.deinit();
    try testing.expectEqual(1, mixed.value.written);
    try testing.expectEqual(error.InvalidArgument, mixed.value.refused[0].reason);
    try testing.expect(std.mem.indexOf(u8, mixed.value.message, "timeSeries[1]") != null);
    // Refused whole: a DELTA metric under custom.googleapis.com/ is the
    // client's to refuse, so the server never sees it.
    try testing.expectError(error.InvalidPoint, f.client.write(&.{.{ .metric_type = try f.name("refusals/delta"), .resource = r, .kind = .delta, .start = at(base, -1_000), .end = at(base, 0), .value = .{ .int64 = 1 } }}));
}

test "monitoring: a Recorder over three intervals, its totals read back" {
    var f: Fixture = undefined;
    if (!try f.init()) return error.SkipZigTest;
    defer f.deinit();
    var recorder = try monitoring.Recorder.init(testing.allocator, testing.io, .{
        .client = .{ .project_id = f.project, .token_provider = f.token.provider() },
        .resource = f.task(f.run),
        .prefix = f.prefix,
        .interval_ms = 5_000,
    });
    defer recorder.deinit();
    const orders = try recorder.counter(.{ .name = "recorder/orders", .label_keys = &.{"region"}, .unit = "{order}", .description = "Orders taken" });
    const depth = try recorder.gauge(.{ .name = "recorder/depth" }, .int64);
    const sizes = try recorder.histogram(.{ .name = "recorder/sizes", .unit = "By" }, .{ .exponential = .{ .num_finite = 8, .growth_factor = 2, .scale = 1 } });
    var running = try testing.io.concurrent(monitoring.Recorder.run, .{&recorder});
    var total: u64 = 0;
    for (0..3) |i| {
        for (0..10) |j| {
            orders.add(&.{"eu"}, j + 1);
            total += j + 1;
            sizes.record(&.{}, @floatFromInt(j * j));
        }
        depth.set(&.{}, .{ .int64 = @intCast(i * 10) });
        try testing.io.sleep(.fromMilliseconds(5_500), .awake);
    }
    recorder.stop();
    try running.await(testing.io);
    const s = recorder.stats();
    fact("recorder: {d} requests, {d} points written, {d} refused, {d} failed, {d} descriptors made", .{ s.requests, s.points_written, s.points_refused, s.points_failed, s.descriptors_created });
    try testing.expectEqual(0, s.points_refused);
    try testing.expectEqual(0, s.points_failed);
    try testing.expectEqual(3, s.descriptors_created);

    // The last write shows within a few seconds: read until it does.
    const now = nowMs();
    var settled = false;
    for (0..40) |_| {
        var page = try f.awaitRead(try f.name("recorder/orders"), .{ .start = at(now, -60_000), .end = at(now, 1_000) }, 3);
        defer page.deinit();
        const points = page.value.series[0].points;
        // One start for every point of the series.
        for (points) |p| try testing.expectEqual(points[0].start.?.nanoseconds, p.start.?.nanoseconds);
        if (points[0].value.?.int64 == @as(i64, @intCast(total))) {
            settled = true;
            break;
        }
        try testing.io.sleep(.fromMilliseconds(500), .awake);
    }
    try testing.expect(settled);
    var desc = try f.awaitDescriptor(try f.name("recorder/orders"));
    defer desc.deinit();
    try testing.expectEqualStrings("Orders taken", desc.value.description);
    settled = false;
    for (0..40) |_| {
        var latest = try f.awaitRead(try f.name("recorder/sizes"), .{ .start = at(now, -60_000), .end = at(now, 1_000) }, 1);
        defer latest.deinit();
        if (latest.value.series[0].points[0].value.?.distribution.count == 30) {
            settled = true;
            break;
        }
        try testing.io.sleep(.fromMilliseconds(500), .awake);
    }
    try testing.expect(settled);
}

// The fake against production: one script, run on both, every outcome
// compared.

const Op = union(enum) {
    create: struct { name: []const u8, kind: monitoring.Kind, value_type: monitoring.ValueType, labels: []const monitoring.LabelDescriptor = &.{} },
    get: []const u8,
    delete: []const u8,
    write: []const Point,
    read: Read,
};

/// One point of a write, its times from the script's base in ms, or from
/// now when `from_now`.
const Point = struct {
    name: []const u8,
    labels: []const monitoring.Label = &.{},
    resource: Res = .{ .task = "a" },
    kind: monitoring.Kind = .gauge,
    start_ms: ?i64 = null,
    end_ms: i64,
    from_now: bool = false,
    value: monitoring.Value = .{ .int64 = 1 },
};

const Res = union(enum) {
    task: []const u8,
    location: []const u8,
    no_namespace,
    global,
    gce,
    node,
};

const Read = struct {
    name: []const u8,
    start_ms: ?i64,
    end_ms: i64,
    filter: monitoring.Filter = .{},
    aggregation: ?monitoring.Aggregation = null,
    view: monitoring.View = .full,
    page_size: u32 = 0,
};

const script = [_]Op{
    // The floor, counted from the series' last point.
    .{ .create = .{ .name = "floor", .kind = .gauge, .value_type = .int64 } },
    .{ .write = &.{.{ .name = "floor", .end_ms = 0 }} },
    .{ .write = &.{.{ .name = "floor", .end_ms = 2_499 }} },
    .{ .write = &.{.{ .name = "floor", .end_ms = 2_500 }} },
    .{ .write = &.{.{ .name = "floor", .end_ms = 2_500 }} },
    .{ .write = &.{.{ .name = "floor", .end_ms = 1_000 }} },
    .{ .write = &.{.{ .name = "floor", .end_ms = 7_499 }} },
    .{ .read = .{ .name = "floor", .start_ms = -1, .end_ms = 10_000 } },
    // Ahead and back.
    .{ .create = .{ .name = "when", .kind = .gauge, .value_type = .int64 } },
    .{ .write = &.{.{ .name = "when", .end_ms = 6 * 60_000, .from_now = true }} },
    .{ .write = &.{.{ .name = "when", .end_ms = -26 * 3_600_000, .from_now = true }} },
    .{ .write = &.{.{ .name = "when", .end_ms = 4 * 60_000, .from_now = true }} },
    // A cumulative series: its start kept, moved earlier, a total that
    // fell, a reset.
    .{ .create = .{ .name = "total", .kind = .cumulative, .value_type = .int64 } },
    .{ .write = &.{.{ .name = "total", .kind = .cumulative, .start_ms = 0, .end_ms = 60_000, .value = .{ .int64 = 10 } }} },
    .{ .write = &.{.{ .name = "total", .kind = .cumulative, .start_ms = -30_000, .end_ms = 90_000, .value = .{ .int64 = 20 } }} },
    .{ .write = &.{.{ .name = "total", .kind = .cumulative, .start_ms = 0, .end_ms = 120_000, .value = .{ .int64 = 5 } }} },
    .{ .write = &.{.{ .name = "total", .kind = .cumulative, .start_ms = 0, .end_ms = 120_000, .value = .{ .int64 = 12 } }} },
    .{ .write = &.{.{ .name = "total", .kind = .cumulative, .start_ms = 120_001, .end_ms = 130_000, .value = .{ .int64 = 1 } }} },
    .{ .read = .{ .name = "total", .start_ms = -60_000, .end_ms = 200_000 } },
    // A kind and a value type the descriptor does not take.
    .{ .create = .{ .name = "kinds", .kind = .gauge, .value_type = .int64 } },
    .{ .write = &.{.{ .name = "kinds", .kind = .cumulative, .start_ms = -1_000, .end_ms = 0 }} },
    .{ .write = &.{.{ .name = "kinds", .end_ms = 0, .value = .{ .double = 1.5 } }} },
    // Resources.
    .{ .create = .{ .name = "where", .kind = .gauge, .value_type = .int64 } },
    .{ .write = &.{.{ .name = "where", .resource = .{ .location = "nowhere-1" }, .end_ms = 0 }} },
    .{ .write = &.{.{ .name = "where", .resource = .no_namespace, .end_ms = 0 }} },
    .{ .write = &.{ .{ .name = "where", .resource = .global, .end_ms = 0 }, .{ .name = "where", .resource = .gce, .end_ms = 0 }, .{ .name = "where", .resource = .node, .end_ms = 0 }, .{ .name = "where", .resource = .{ .location = "europe-west1-b" }, .end_ms = 0 } } },
    // A mixed request.
    .{ .create = .{ .name = "mixed", .kind = .gauge, .value_type = .int64 } },
    .{ .write = &.{ .{ .name = "mixed", .labels = &.{.{ .key = "k", .value = "a" }}, .end_ms = 0 }, .{ .name = "mixed", .labels = &.{.{ .key = "k", .value = "b" }}, .end_ms = 6 * 60_000, .from_now = true }, .{ .name = "mixed", .labels = &.{.{ .key = "k", .value = "c" }}, .end_ms = 0 } } },
    // A label the descriptor lacks: written, and the descriptor gains it.
    .{ .create = .{ .name = "labels", .kind = .gauge, .value_type = .int64, .labels = &.{.{ .key = "a" }} } },
    .{ .write = &.{.{ .name = "labels", .labels = &.{ .{ .key = "a", .value = "1" }, .{ .key = "b", .value = "2" } }, .end_ms = 0 }} },
    .{ .get = "labels" },
    // Descriptors: made again, refused with another kind, deleted twice,
    // made again at once with another kind.
    .{ .create = .{ .name = "again", .kind = .gauge, .value_type = .int64 } },
    .{ .create = .{ .name = "again", .kind = .gauge, .value_type = .int64 } },
    .{ .create = .{ .name = "again", .kind = .cumulative, .value_type = .int64 } },
    .{ .delete = "again" },
    .{ .delete = "again" },
    .{ .create = .{ .name = "again", .kind = .cumulative, .value_type = .int64 } },
    // Reads: filters, alignment, reduction, paging, edges.
    .{ .create = .{ .name = "reads", .kind = .gauge, .value_type = .int64, .labels = &.{ .{ .key = "region" }, .{ .key = "path" } } } },
    .{ .write = &.{
        .{ .name = "reads", .labels = &.{ .{ .key = "region", .value = "eu" }, .{ .key = "path", .value = "/api/orders" } }, .resource = .{ .task = "t0" }, .end_ms = 10_000, .value = .{ .int64 = 30 } },
        .{ .name = "reads", .labels = &.{ .{ .key = "region", .value = "eu" }, .{ .key = "path", .value = "/web/home" } }, .resource = .{ .task = "t1" }, .end_ms = 20_000, .value = .{ .int64 = 20 } },
        .{ .name = "reads", .labels = &.{ .{ .key = "region", .value = "us" }, .{ .key = "path", .value = "a\"b\\c" } }, .resource = .{ .task = "t2" }, .end_ms = 30_000, .value = .{ .int64 = 21 } },
    } },
    .{ .write = &.{.{ .name = "reads", .labels = &.{ .{ .key = "region", .value = "eu" }, .{ .key = "path", .value = "/api/orders" } }, .resource = .{ .task = "t0" }, .end_ms = 60_000, .value = .{ .int64 = 40 } }} },
    .{ .read = .{ .name = "reads", .start_ms = 0, .end_ms = 60_000 } },
    .{ .read = .{ .name = "reads", .start_ms = 10_000, .end_ms = 60_000 } },
    .{ .read = .{ .name = "reads", .start_ms = null, .end_ms = 30_000 } },
    .{ .read = .{ .name = "reads", .start_ms = 0, .end_ms = 60_000, .filter = .{ .metric_labels = &.{.{ .key = "path", .op = .starts_with, .value = "/api" }} } } },
    .{ .read = .{ .name = "reads", .start_ms = 0, .end_ms = 60_000, .filter = .{ .metric_labels = &.{.{ .key = "path", .op = .ends_with, .value = "home" }} } } },
    .{ .read = .{ .name = "reads", .start_ms = 0, .end_ms = 60_000, .filter = .{ .metric_labels = &.{.{ .key = "path", .op = .has_substring, .value = "/" }} } } },
    .{ .read = .{ .name = "reads", .start_ms = 0, .end_ms = 60_000, .filter = .{ .metric_labels = &.{.{ .key = "region", .op = .not_equals, .value = "eu" }} } } },
    .{ .read = .{ .name = "reads", .start_ms = 0, .end_ms = 60_000, .filter = .{ .metric_labels = &.{.{ .key = "path", .value = "a\"b\\c" }} } } },
    .{ .read = .{ .name = "reads", .start_ms = 0, .end_ms = 60_000, .filter = .{ .metric_labels = &.{.{ .key = "missing", .op = .not_equals, .value = "x" }} } } },
    .{ .read = .{ .name = "reads", .start_ms = 0, .end_ms = 60_000, .filter = .{ .resource_type = "generic_task", .resource_labels = &.{.{ .key = "task_id", .value = "t1" }} } } },
    .{ .read = .{ .name = "reads", .start_ms = 0, .end_ms = 60_000, .filter = .{ .resource_labels = &.{.{ .key = "missing", .value = "x" }} } } },
    .{ .read = .{ .name = "reads", .start_ms = 0, .end_ms = 60_000, .aggregation = .{ .alignment_period_s = 60, .aligner = .max, .reducer = .sum } } },
    .{ .read = .{ .name = "reads", .start_ms = 0, .end_ms = 60_000, .aggregation = .{ .alignment_period_s = 60, .aligner = .mean, .reducer = .max, .group_by = &.{"metric.labels.region"} } } },
    .{ .read = .{ .name = "reads", .start_ms = 0, .end_ms = 60_000, .aggregation = .{ .alignment_period_s = 60, .aligner = .min, .reducer = .count, .group_by = &.{"resource.labels.task_id"} } } },
    .{ .read = .{ .name = "reads", .start_ms = 0, .end_ms = 60_000, .aggregation = .{ .alignment_period_s = 60, .aligner = .sum } } },
    // A point on a period's start, and one inside: which period each is in.
    .{ .read = .{ .name = "reads", .start_ms = -60_000, .end_ms = 60_000, .aggregation = .{ .alignment_period_s = 30, .aligner = .count, .reducer = .sum } } },
    .{ .read = .{ .name = "reads", .start_ms = -60_000, .end_ms = 70_000, .aggregation = .{ .alignment_period_s = 10, .aligner = .count, .reducer = .sum } } },
    .{ .read = .{ .name = "reads", .start_ms = 0, .end_ms = 60_000, .view = .headers } },
    .{ .read = .{ .name = "reads", .start_ms = 0, .end_ms = 60_000, .page_size = 1 } },
    .{ .read = .{ .name = "reads", .start_ms = 0, .end_ms = 60_000, .page_size = 2 } },
};

/// What an operation came to, the same words for production and the fake.
fn outcome(a: Allocator, client: *monitoring.Client, prefix: []const u8, base: i96, now: i96, op: Op) ![]const u8 {
    switch (op) {
        .create => |c| {
            var info = client.metric(try full(a, prefix, c.name)).create(.{ .kind = c.kind, .value_type = c.value_type, .labels = c.labels }) catch |err| return a.print("{t}", .{err});
            defer info.deinit();
            return a.print("ok {t} {t}", .{ info.value.kind, info.value.value_type });
        },
        .get => |n| {
            var info = client.metric(try full(a, prefix, n)).get() catch |err| return a.print("{t}", .{err});
            defer info.deinit();
            var out: std.Io.Writer.Allocating = .init(a);
            try out.writer.print("{t} {t} labels", .{ info.value.kind, info.value.value_type });
            const keys = try a.alloc([]const u8, info.value.labels.len);
            for (info.value.labels, keys) |l, *k| k.* = try a.dupe(u8, l.key);
            std.mem.sort([]const u8, keys, {}, lessThan);
            for (keys) |k| try out.writer.print(" {s}", .{k});
            return out.written();
        },
        .delete => |n| {
            client.metric(try full(a, prefix, n)).delete() catch |err| return a.print("{t}", .{err});
            return "ok";
        },
        .write => |points| {
            const series = try a.alloc(monitoring.TimeSeries, points.len);
            for (points, series) |p, *s| s.* = .{
                .metric_type = try full(a, prefix, p.name),
                .metric_labels = p.labels,
                .resource = resourceOf(p.resource),
                .kind = p.kind,
                .start = if (p.start_ms) |ms| at(base, ms) else null,
                .end = at(if (p.from_now) now else base, p.end_ms),
                .value = p.value,
            };
            var result = client.write(series) catch |err| return a.print("{t}", .{err});
            defer result.deinit();
            var out: std.Io.Writer.Allocating = .init(a);
            try out.writer.print("wrote {d} of {d}", .{ result.value.written, result.value.points });
            for (result.value.refused) |r| try out.writer.print(", {d} {t}", .{ r.points, r.reason });
            if (!result.value.ok()) {
                const at_series = std.mem.indexOf(u8, result.value.message, "timeSeries[") orelse 0;
                const close = std.mem.indexOfScalarPos(u8, result.value.message, at_series, ']') orelse at_series;
                try out.writer.print(" ({s})", .{result.value.message[at_series .. close + 1]});
            }
            return out.written();
        },
        .read => |r| {
            var out: std.Io.Writer.Allocating = .init(a);
            var token: ?[]const u8 = null;
            var lines: std.ArrayList([]const u8) = .empty;
            var pages: usize = 0;
            while (true) {
                var page = client.metric(try full(a, prefix, r.name)).read(.{
                    .start = if (r.start_ms) |ms| at(base, ms) else null,
                    .end = at(base, r.end_ms),
                    .filter = r.filter,
                    .aggregation = r.aggregation,
                    .view = r.view,
                    .page_size = r.page_size,
                    .page_token = token,
                }) catch |err| return a.print("{t}", .{err});
                defer page.deinit();
                pages += 1;
                var on_page: usize = 0;
                for (page.value.series) |s| {
                    on_page += s.points.len;
                    try lines.append(a, try seriesLine(a, base, s));
                }
                if (r.page_size != 0) try out.writer.print("[{d}]", .{on_page});
                token = if (page.value.next_page_token) |t| try a.dupe(u8, t) else null;
                if (token == null) break;
            }
            std.mem.sort([]const u8, lines.items, {}, lessThan);
            try out.writer.print("{d} pages:", .{pages});
            for (lines.items) |l| try out.writer.print(" | {s}", .{l});
            return out.written();
        },
    }
}

/// A series as one line: kind, value type, labels, and each point's end,
/// its start where it differs, and its value, times in milliseconds from
/// `base`, so production's and the fake's compare as text.
fn seriesLine(a: Allocator, base: i96, s: monitoring.Series) ![]const u8 {
    var line: std.Io.Writer.Allocating = .init(a);
    try line.writer.print("{t} {t} {{", .{ s.kind, s.value_type });
    try writeLabels(a, &line.writer, s.metric_labels, false);
    try line.writer.writeAll("} {");
    try writeLabels(a, &line.writer, s.resource_labels, true);
    try line.writer.writeAll("}");
    for (s.points) |p| {
        const end_ms = @divFloor(p.end.nanoseconds - base, std.time.ns_per_ms);
        try line.writer.print(" {d}", .{end_ms});
        if (p.start) |st| if (st.nanoseconds != p.end.nanoseconds) try line.writer.print("@{d}", .{@divFloor(st.nanoseconds - base, std.time.ns_per_ms)});
        try line.writer.writeByte('=');
        if (p.value) |v| switch (v) {
            .int64 => |n| try line.writer.print("{d}", .{n}),
            .double => |d| try line.writer.print("{d}", .{d}),
            .bool => |b| try line.writer.print("{}", .{b}),
            else => try line.writer.writeAll("?"),
        } else try line.writer.writeAll("null");
    }
    return line.written();
}

fn isServerError(text: []const u8) bool {
    for ([_][]const u8{ "Internal", "Unavailable", "DeadlineExceeded" }) |name| {
        if (std.mem.eql(u8, text, name)) return true;
    }
    return false;
}

fn lessThan(_: void, a: []const u8, b: []const u8) bool {
    return std.mem.lessThan(u8, a, b);
}

fn writeLabels(a: Allocator, w: *std.Io.Writer, labels: []const monitoring.Label, skip_project: bool) !void {
    const sorted = try a.dupe(monitoring.Label, labels);
    std.mem.sort(monitoring.Label, sorted, {}, struct {
        fn lt(_: void, x: monitoring.Label, y: monitoring.Label) bool {
            return std.mem.lessThan(u8, x.key, y.key);
        }
    }.lt);
    for (sorted) |l| {
        if (skip_project and std.mem.eql(u8, l.key, "project_id")) continue;
        try w.print("{s}={s},", .{ l.key, l.value });
    }
}

fn full(a: Allocator, prefix: []const u8, short: []const u8) ![]const u8 {
    return a.print("{s}replay/{s}", .{ prefix, short });
}

fn resourceOf(r: Res) monitoring.Resource {
    return switch (r) {
        .task => |id| .{ .generic_task = .{ .location = "us-central1", .namespace = "zigps", .job = "replay", .task_id = id } },
        .location => |l| .{ .generic_task = .{ .location = l, .namespace = "zigps", .job = "replay", .task_id = "x" } },
        .no_namespace => .{ .other = .{ .type = "generic_task", .labels = &.{ .{ .key = "location", .value = "us-central1" }, .{ .key = "job", .value = "replay" }, .{ .key = "task_id", .value = "x" } } } },
        .global => .global,
        .gce => .{ .gce_instance = .{ .zone = "us-central1-a", .instance_id = "42" } },
        .node => .{ .generic_node = .{ .location = "us-central1", .namespace = "zigps", .node_id = "n" } },
    };
}

test "monitoring: the fake against production, every outcome of one script compared" {
    var f: Fixture = undefined;
    if (!try f.init()) return error.SkipZigTest;
    defer f.deinit();
    var fake: monitoring.testing.FakeMonitoring = .init(testing.allocator, testing.io, .{ .project_id = f.project });
    defer fake.deinit();
    var fake_client = try monitoring.Client.init(testing.allocator, testing.io, .{ .project_id = f.project, .token_provider = f.token.provider(), .transport = fake.transport() });
    defer fake_client.deinit();
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const base = nowMs() - 20 * std.time.ns_per_min;
    var differences: usize = 0;
    for (script, 0..) |op, i| {
        const now = nowMs();
        const in_memory = try outcome(a, &fake_client, f.prefix, base, now, op);
        var production = try outcome(a, &f.client, f.prefix, base, now, op);
        // A server error is production's, not the fake's to match: once a
        // write answered a bare 500 where every other run gave its
        // summary. Sent again; production keeps a point sent twice once.
        var errors: usize = 0;
        while (errors < 3 and isServerError(production)) : (errors += 1) {
            fact("{d}: production answered {s}; again", .{ i, production });
            try testing.io.sleep(.fromSeconds(1), .awake);
            production = try outcome(a, &f.client, f.prefix, base, now, op);
        }
        // A descriptor or a point production has yet to show: ask again.
        var tries: usize = 0;
        while (!std.mem.eql(u8, production, in_memory) and tries < 30 and (op == .read or op == .get)) : (tries += 1) {
            try testing.io.sleep(.fromMilliseconds(500), .awake);
            production = try outcome(a, &f.client, f.prefix, base, now, op);
        }
        if (op == .create) if (f.awaitDescriptor(try full(a, f.prefix, op.create.name))) |d| {
            var info = d;
            info.deinit();
        } else |_| {};
        if (std.mem.eql(u8, production, in_memory)) {
            fact("{d}: {s}", .{ i, production });
        } else {
            differences += 1;
            std.debug.print("{d}: {t}\n  production: {s}\n  fake:       {s}\n", .{ i, op, production, in_memory });
        }
    }
    try testing.expectEqual(0, differences);
}

// Pub/Sub's own metrics (issue #239).

const pubsub_prefix = "pubsub.googleapis.com/";

/// The nine metrics `FakeMonitoring` holds, after `pubsub_prefix`.
const pubsub_metrics = [_][]const u8{
    "subscription/num_undelivered_messages",
    "subscription/oldest_unacked_message_age",
    "subscription/sent_message_count",
    "subscription/ack_message_count",
    "subscription/expired_ack_deadlines_count",
    "subscription/dead_letter_message_count",
    "subscription/push_request_count",
    "topic/send_message_operation_count",
    "topic/byte_cost",
};

/// One read of the Pub/Sub and quota tests, made of production and of
/// the fake.
const PubsubRead = struct {
    label: []const u8,
    /// After `prefix`.
    metric: []const u8,
    prefix: []const u8 = pubsub_prefix,
    start: ?std.Io.Timestamp,
    end: std.Io.Timestamp,
    filter: monitoring.Filter,
    aggregation: ?monitoring.Aggregation = null,
};

/// A read's outcome as text: its error, or its unit and its series, sorted.
fn pubsubOutcome(a: Allocator, client: *monitoring.Client, diag: *monitoring.Diagnostics, base: i96, r: PubsubRead) ![]const u8 {
    var page = client.metric(try a.print("{s}{s}", .{ r.prefix, r.metric })).read(.{
        .start = r.start,
        .end = r.end,
        .filter = r.filter,
        .aggregation = r.aggregation,
    }) catch |err| return a.print("{t}: {s}", .{ err, diag.message() });
    defer page.deinit();
    const lines = try a.alloc([]const u8, page.value.series.len);
    for (page.value.series, lines) |s, *l| l.* = try seriesLine(a, base, s);
    std.mem.sort([]const u8, lines, {}, lessThan);
    var out: std.Io.Writer.Allocating = .init(a);
    try out.writer.print("unit {s}, {d} series", .{ page.value.unit, lines.len });
    for (lines) |l| try out.writer.print(" | {s}", .{l});
    if (page.value.next_page_token != null) try out.writer.writeAll(" | more pages");
    return out.written();
}

/// Pulls what a subscription has and acknowledges every `every`-th
/// message, so the rest expire and come again.
fn pullAndAck(ps: *pubsub.Client, id: []const u8, every: usize) !void {
    var pulled = try ps.subscription(id).pull(.{ .max_messages = 100, .return_immediately = true });
    defer pulled.deinit();
    var ids: std.ArrayList([]const u8) = .empty;
    defer ids.deinit(testing.allocator);
    for (pulled.value.messages, 0..) |m, i| if (i % every == 0) try ids.append(testing.allocator, m.ack_id);
    try ps.subscription(id).ack(ids.items);
}

/// Prints the outcome when production and the fake agree, both when not,
/// and counts the second.
fn agree(differences: *usize, label: []const u8, production: []const u8, in_memory: []const u8) void {
    if (std.mem.eql(u8, production, in_memory)) {
        fact("{s}: {s}", .{ label, production });
    } else {
        differences.* += 1;
        std.debug.print("{s}\n  production: {s}\n  fake:       {s}\n", .{ label, production, in_memory });
    }
}

fn floorMinute(ns: i96) i96 {
    return @divFloor(ns, std.time.ns_per_min) * std.time.ns_per_min;
}

test "monitoring: Pub/Sub's own metrics, and the fake given production's points answers as production did" {
    var f: Fixture = undefined;
    if (!try f.init()) return error.SkipZigTest;
    defer f.deinit();
    if (f.env.get("MONITORING_TEST_PUBSUB") == null) return error.SkipZigTest;
    const a = f.arena.allocator();
    var ps_diag: pubsub.Diagnostics = .{};
    var ps = try pubsub.Client.init(testing.allocator, testing.io, .{ .project_id = f.project, .token_provider = f.token.provider(), .diagnostics = &ps_diag });
    defer ps.deinit();

    // A topic and two subscriptions, made for the run: -a acknowledges
    // everything, -b every other message and keeps a backlog at the end.
    const topic_id = try a.print("zigps-mon-{s}", .{f.run});
    const subs = [_][]const u8{ try a.print("{s}-a", .{topic_id}), try a.print("{s}-b", .{topic_id}) };
    const topic = ps.topic(topic_id);
    var made = try topic.create(.{});
    made.deinit();
    defer topic.delete() catch |err| fact("deleting {s} failed: {t}", .{ topic_id, err });
    for (subs) |id| {
        var sub = try ps.subscription(id).create(.{ .topic_id = topic_id, .ack_deadline_seconds = 10 });
        sub.deinit();
    }
    defer for (subs) |id| ps.subscription(id).delete() catch |err| fact("deleting {s} failed: {t}", .{ id, err });
    const created = nowMs();
    fact("made {s} and its two subscriptions", .{topic_id});

    var messages: [10]pubsub.Message = @splat(.{ .data = "zigps" });
    for (0..8) |round| {
        const t0 = nowMs();
        var sent = try topic.publish(messages[0 .. 2 + round], .{});
        sent.deinit();
        try pullAndAck(&ps, subs[0], 1);
        try pullAndAck(&ps, subs[1], 2);
        const spent = nowMs() - t0;
        if (spent < 30 * std.time.ns_per_s) try testing.io.sleep(.fromNanoseconds(30 * std.time.ns_per_s - spent), .awake);
    }
    var tail = try topic.publish(messages[0..5], .{});
    tail.deinit();
    const traffic_end = nowMs();
    fact("traffic sent", .{});

    // Production showed a minute's counts about 130 s after it ended (a
    // topic's once later, Google says up to 240 s), and a new
    // subscription's first backlog point about 400 s after it was made.
    // The reads end five minutes in the past, past both subscriptions'
    // first backlog points, so nothing arrives while they run.
    const window_start: std.Io.Timestamp = .{ .nanoseconds = floorMinute(created) - 2 * std.time.ns_per_min };
    const prefix_match = [_]monitoring.Match{.{ .key = "subscription_id", .op = .starts_with, .value = try a.print("{s}-", .{topic_id}) }};
    const by_subs: monitoring.Filter = .{ .resource_labels = &prefix_match };
    const by_topic: monitoring.Filter = .{ .resource_labels = &.{.{ .key = "topic_id", .value = topic_id }} };
    var waited: usize = 0;
    while (true) : (waited += 1) {
        if (waited == 32) return error.TestPointsNeverReadable;
        try testing.io.sleep(.fromSeconds(30), .awake);
        const now: std.Io.Timestamp = .{ .nanoseconds = nowMs() };
        var sent = try f.client.metric(pubsub_prefix ++ "subscription/sent_message_count").read(.{ .start = window_start, .end = now, .filter = by_subs });
        defer sent.deinit();
        var backlog = try f.client.metric(pubsub_prefix ++ "subscription/num_undelivered_messages").read(.{ .start = window_start, .end = now, .filter = by_subs });
        defer backlog.deinit();
        var latest: i96 = 0;
        for (sent.value.series) |s| for (s.points) |p| {
            latest = @max(latest, p.end.nanoseconds);
        };
        if (latest >= floorMinute(traffic_end) and backlog.value.series.len > 0 and now.nanoseconds - floorMinute(traffic_end) >= 8 * std.time.ns_per_min) break;
    }
    fact("points readable {d} s after the subscriptions were made", .{@divFloor(nowMs() - created, std.time.ns_per_s)});

    // Production's raw points, put into the fake.
    const end: std.Io.Timestamp = .{ .nanoseconds = floorMinute(nowMs()) - 5 * std.time.ns_per_min };
    const mid: std.Io.Timestamp = .{ .nanoseconds = end.nanoseconds - 30 * std.time.ns_per_s };
    var fake: monitoring.testing.FakeMonitoring = .init(testing.allocator, testing.io, .{ .project_id = f.project });
    defer fake.deinit();
    var fake_diag: monitoring.Diagnostics = .{};
    var fake_client = try monitoring.Client.init(testing.allocator, testing.io, .{ .project_id = f.project, .token_provider = f.token.provider(), .transport = fake.transport(), .diagnostics = &fake_diag });
    defer fake_client.deinit();
    var put_series: usize = 0;
    for (pubsub_metrics) |m| {
        var raw = try f.client.metric(try a.print("{s}{s}", .{ pubsub_prefix, m })).read(.{ .start = window_start, .end = end, .filter = if (std.mem.startsWith(u8, m, "topic/")) by_topic else by_subs });
        defer raw.deinit();
        try testing.expectEqual(null, raw.value.next_page_token);
        for (raw.value.series) |s| {
            const pts = try a.alloc(monitoring.testing.FakeMonitoring.Point, s.points.len);
            // Newest first in a read; oldest first in a put.
            for (s.points, 0..) |p, i| pts[pts.len - 1 - i] = .{ .start = if (s.kind == .gauge) null else p.start, .end = p.end, .value = p.value.? };
            try fake.put(.{ .metric_type = s.metric_type, .metric_labels = s.metric_labels, .resource_type = s.resource_type, .resource_labels = s.resource_labels, .kind = s.kind, .value_type = s.value_type, .points = pts });
            put_series += 1;
        }
    }
    fact("{d} series put into the fake", .{put_series});

    // The reads a console makes, and the edges of their periods.
    const by_type: []const []const u8 = &.{"metric.labels.delivery_type"};
    const by_sub: []const []const u8 = &.{"resource.labels.subscription_id"};
    var reads: std.ArrayList(PubsubRead) = .empty;
    for (pubsub_metrics) |m| {
        const topic_metric = std.mem.startsWith(u8, m, "topic/");
        try reads.append(a, .{ .label = try a.print("raw {s}", .{m}), .metric = m, .start = window_start, .end = end, .filter = if (topic_metric) by_topic else by_subs });
        const counted = !std.mem.endsWith(u8, m, "messages") and !std.mem.endsWith(u8, m, "age");
        const aggregations: []const monitoring.Aggregation = if (counted) &.{
            .{ .alignment_period_s = 60, .aligner = .delta, .reducer = .sum },
            .{ .alignment_period_s = 60, .aligner = .rate, .reducer = .sum },
            .{ .alignment_period_s = 120, .aligner = .sum },
            .{ .alignment_period_s = 120, .aligner = .count, .reducer = .sum },
            .{ .alignment_period_s = 120, .aligner = .max, .reducer = .max },
            .{ .alignment_period_s = 120, .aligner = .mean },
            .{ .alignment_period_s = 60, .aligner = .min, .reducer = .count },
            .{ .alignment_period_s = 60, .aligner = .rate, .reducer = .mean },
            .{ .alignment_period_s = 60, .aligner = .next_older },
        } else &.{
            .{ .alignment_period_s = 60, .aligner = .max },
            .{ .alignment_period_s = 60, .aligner = .max, .reducer = .sum },
            .{ .alignment_period_s = 120, .aligner = .mean, .reducer = .max, .group_by = by_sub },
            .{ .alignment_period_s = 60, .aligner = .count },
            .{ .alignment_period_s = 60, .aligner = .max, .reducer = .count },
            .{ .alignment_period_s = 60, .aligner = .sum },
            .{ .alignment_period_s = 60, .aligner = .delta },
            .{ .alignment_period_s = 60, .aligner = .rate },
        };
        for (aggregations, 0..) |agg, i| try reads.append(a, .{ .label = try a.print("{s} #{d}", .{ m, i }), .metric = m, .start = window_start, .end = end, .filter = if (topic_metric) by_topic else by_subs, .aggregation = agg });
    }
    const sent_metric = "subscription/sent_message_count";
    for ([_]struct { []const u8, std.Io.Timestamp, monitoring.Aggregation }{
        .{ "delta 60", end, .{ .alignment_period_s = 60, .aligner = .delta } },
        .{ "delta 60 mid", mid, .{ .alignment_period_s = 60, .aligner = .delta } },
        .{ "delta 60 sum mid", mid, .{ .alignment_period_s = 60, .aligner = .delta, .reducer = .sum } },
        .{ "delta 60 sum by delivery type", end, .{ .alignment_period_s = 60, .aligner = .delta, .reducer = .sum, .group_by = by_type } },
        .{ "delta 60 sum by subscription", end, .{ .alignment_period_s = 60, .aligner = .delta, .reducer = .sum, .group_by = by_sub } },
        .{ "delta 60 max", end, .{ .alignment_period_s = 60, .aligner = .delta, .reducer = .max } },
        .{ "delta 60 mean", end, .{ .alignment_period_s = 60, .aligner = .delta, .reducer = .mean } },
        .{ "delta 60 count", end, .{ .alignment_period_s = 60, .aligner = .delta, .reducer = .count } },
        .{ "delta 120", end, .{ .alignment_period_s = 120, .aligner = .delta } },
        .{ "delta 300", end, .{ .alignment_period_s = 300, .aligner = .delta } },
        .{ "delta 90", end, .{ .alignment_period_s = 90, .aligner = .delta } },
        .{ "delta 30", end, .{ .alignment_period_s = 30, .aligner = .delta } },
        .{ "rate 60", end, .{ .alignment_period_s = 60, .aligner = .rate } },
        .{ "rate 60 mid", mid, .{ .alignment_period_s = 60, .aligner = .rate } },
        .{ "rate 60 sum by delivery type", end, .{ .alignment_period_s = 60, .aligner = .rate, .reducer = .sum, .group_by = by_type } },
        .{ "rate 120", end, .{ .alignment_period_s = 120, .aligner = .rate } },
        .{ "rate 30", end, .{ .alignment_period_s = 30, .aligner = .rate } },
        .{ "sum 90", end, .{ .alignment_period_s = 90, .aligner = .sum } },
        .{ "sum 60 mid", mid, .{ .alignment_period_s = 60, .aligner = .sum, .reducer = .sum } },
        .{ "min 120 by delivery type", end, .{ .alignment_period_s = 120, .aligner = .min, .reducer = .min, .group_by = by_type } },
        .{ "interpolate", end, .{ .alignment_period_s = 60, .aligner = .interpolate } },
        .{ "percentile 99", end, .{ .alignment_period_s = 60, .aligner = .percentile_99 } },
        .{ "count true", end, .{ .alignment_period_s = 60, .aligner = .count_true } },
    }) |c| try reads.append(a, .{ .label = c[0], .metric = sent_metric, .start = window_start, .end = c[1], .filter = by_subs, .aggregation = c[2] });
    try reads.append(a, .{ .label = "raw sent mid", .metric = sent_metric, .start = window_start, .end = mid, .filter = by_subs });
    try reads.append(a, .{ .label = "delta 60 sum instant", .metric = sent_metric, .start = null, .end = end, .filter = by_subs, .aggregation = .{ .alignment_period_s = 60, .aligner = .delta, .reducer = .sum } });
    try reads.append(a, .{ .label = "push by response class", .metric = "subscription/push_request_count", .start = window_start, .end = end, .filter = by_subs, .aggregation = .{ .alignment_period_s = 60, .aligner = .delta, .reducer = .sum, .group_by = &.{"metric.labels.response_class"} } });
    try reads.append(a, .{ .label = "publishes by response code", .metric = "topic/send_message_operation_count", .start = window_start, .end = end, .filter = by_topic, .aggregation = .{ .alignment_period_s = 60, .aligner = .delta, .reducer = .sum, .group_by = &.{"metric.labels.response_code"} } });
    // Around one point of -a's sent count: which reads hold it.
    {
        const only_a: monitoring.Filter = .{ .resource_labels = &.{.{ .key = "subscription_id", .value = subs[0] }} };
        var raw = try f.client.metric(pubsub_prefix ++ sent_metric).read(.{ .start = window_start, .end = end, .filter = only_a });
        defer raw.deinit();
        if (raw.value.series.len > 0 and raw.value.series[0].points.len >= 3) {
            const p = raw.value.series[0].points[1];
            const pe = p.end.nanoseconds;
            const point_start = p.start.?.nanoseconds;
            const s = std.time.ns_per_s;
            for ([_]struct { []const u8, ?i96, i96, ?monitoring.Aggregation }{
                .{ "edge: start at the point's end", pe, end.nanoseconds, null },
                .{ "edge: start inside the point", pe - 30 * s, end.nanoseconds, null },
                .{ "edge: start at the point's start", point_start, end.nanoseconds, null },
                .{ "edge: end inside the point", window_start.nanoseconds, pe - s, null },
                .{ "edge: end at the point's end", window_start.nanoseconds, pe, null },
                .{ "edge: instant at the point's end", null, pe, null },
                .{ "edge: instant inside the point", null, pe - 30 * s, null },
                .{ "edge: delta 60 ending at the point's end", window_start.nanoseconds, pe, .{ .alignment_period_s = 60, .aligner = .delta } },
                .{ "edge: delta 60 ending inside the point", window_start.nanoseconds, pe - 30 * s, .{ .alignment_period_s = 60, .aligner = .delta } },
                .{ "edge: delta 60 ending 1 s after it", window_start.nanoseconds, pe + s, .{ .alignment_period_s = 60, .aligner = .delta } },
                .{ "edge: rate 60 ending inside the point", window_start.nanoseconds, pe - 30 * s, .{ .alignment_period_s = 60, .aligner = .rate } },
            }) |c| try reads.append(a, .{ .label = c[0], .metric = sent_metric, .start = if (c[1]) |t| .{ .nanoseconds = t } else null, .end = .{ .nanoseconds = c[2] }, .filter = only_a, .aggregation = c[3] });
        } else fact("-a's sent count has fewer than 3 points: no edge reads", .{});
    }
    // Filters production refused, or did not.
    for ([_]struct { []const u8, []const u8, monitoring.Filter }{
        .{ "filter: a subscription metric on topic_id", sent_metric, .{ .resource_labels = &.{.{ .key = "topic_id", .value = "x" }} } },
        .{ "filter: a subscription metric on zone", sent_metric, .{ .resource_labels = &.{.{ .key = "zone", .value = "x" }} } },
        .{ "filter: a topic metric on subscription_id", "topic/send_message_operation_count", .{ .resource_labels = &.{.{ .key = "subscription_id", .value = "x" }} } },
        .{ "filter: a metric label the metric lacks", sent_metric, .{ .metric_labels = &.{.{ .key = "nope", .value = "x" }} } },
        .{ "filter: another resource type", sent_metric, .{ .resource_type = "pubsub_topic" } },
        .{ "filter: its own resource type", sent_metric, .{ .resource_type = "pubsub_subscription", .resource_labels = &prefix_match } },
        .{ "filter: resource type global", sent_metric, .{ .resource_type = "global" } },
        .{ "filter: resource type gce_instance", sent_metric, .{ .resource_type = "gce_instance" } },
        .{ "filter: a topic metric on its own type and topic_id", "topic/byte_cost", .{ .resource_type = "pubsub_topic", .resource_labels = &.{.{ .key = "topic_id", .value = topic_id }} } },
        .{ "filter: a backlog with a metric label", "subscription/num_undelivered_messages", .{ .metric_labels = &.{.{ .key = "delivery_type", .value = "pull" }} } },
    }) |c| try reads.append(a, .{ .label = c[0], .metric = c[1], .start = window_start, .end = end, .filter = c[2] });

    var differences: usize = 0;
    for (reads.items) |r| {
        const in_memory = try pubsubOutcome(a, &fake_client, &fake_diag, window_start.nanoseconds, r);
        const production = try pubsubOutcome(a, &f.client, &f.diag, window_start.nanoseconds, r);
        agree(&differences, r.label, production, in_memory);
    }

    // A user metric, empty, filtered on Pub/Sub's resources and others,
    // and aligned.
    {
        const g = try f.name("g");
        for ([_]*monitoring.Client{ &f.client, &fake_client }) |client| {
            var d = try client.metric(g).create(.{ .kind = .gauge, .value_type = .int64 });
            d.deinit();
        }
        var info = try f.awaitDescriptor(g);
        info.deinit();
        for ([_]struct { []const u8, monitoring.Filter, ?monitoring.Aggregation }{
            .{ "a user metric on subscription_id", .{ .resource_labels = &.{.{ .key = "subscription_id", .value = "x" }} }, null },
            .{ "a user metric on resource type pubsub_subscription", .{ .resource_type = "pubsub_subscription" }, null },
            .{ "a user metric on resource type global", .{ .resource_type = "global" }, null },
            .{ "a user metric on resource type global and zone", .{ .resource_type = "global", .resource_labels = &.{.{ .key = "zone", .value = "x" }} }, null },
            .{ "a user metric on resource type gce_instance and zone", .{ .resource_type = "gce_instance", .resource_labels = &.{.{ .key = "zone", .value = "x" }} }, null },
            .{ "a user metric, its points counted", .{}, .{ .alignment_period_s = 60, .aligner = .count } },
            .{ "a user metric, its rate", .{}, .{ .alignment_period_s = 60, .aligner = .rate } },
        }) |c| {
            var lines: [2][]const u8 = undefined;
            for ([_]*monitoring.Client{ &f.client, &fake_client }, [_]*monitoring.Diagnostics{ &f.diag, &fake_diag }, &lines) |client, diag, *line| {
                if (client.metric(g).read(.{ .start = window_start, .end = end, .filter = c[1], .aggregation = c[2] })) |page| {
                    var owned = page;
                    defer owned.deinit();
                    line.* = try a.print("unit {s}, {d} series", .{ owned.value.unit, owned.value.series.len });
                } else |err| line.* = try a.print("{t}: {s}", .{ err, diag.message() });
            }
            agree(&differences, c[0], lines[0], lines[1]);
        }
    }

    // Writes production refused: one of Google's metrics; a user metric on
    // Pub/Sub's resource type, its descriptor made all the same; a create
    // under Google's domain.
    {
        const on_sub = try f.name("on_sub");
        const sub_resource: monitoring.Resource = .{ .other = .{ .type = "pubsub_subscription", .labels = &.{.{ .key = "subscription_id", .value = subs[0] }} } };
        const google_type = try a.print("{s}subscription/zigps_mon_{s}", .{ pubsub_prefix, f.run });
        var lines: [2][]const u8 = undefined;
        for ([_]*monitoring.Client{ &f.client, &fake_client }, [_]*monitoring.Diagnostics{ &f.diag, &fake_diag }, &lines) |client, diag, *line| {
            var out: std.Io.Writer.Allocating = .init(a);
            const now: std.Io.Timestamp = .{ .nanoseconds = nowMs() };
            if (client.write(&.{.{ .metric_type = pubsub_prefix ++ "subscription/num_undelivered_messages", .resource = sub_resource, .kind = .gauge, .end = now, .value = .{ .int64 = 1 } }})) |r| {
                var owned = r;
                owned.deinit();
                try out.writer.writeAll("Google's: written");
            } else |err| try out.writer.print("Google's: {t}: {s}", .{ err, diag.message() });
            if (client.write(&.{.{ .metric_type = on_sub, .resource = sub_resource, .kind = .gauge, .end = now, .value = .{ .int64 = 1 } }})) |r| {
                var owned = r;
                defer owned.deinit();
                try out.writer.print(" | a user metric: {d} written, {s}", .{ owned.value.written, owned.value.message });
            } else |err| try out.writer.print(" | a user metric: {t}: {s}", .{ err, diag.message() });
            if (client.metric(google_type).create(.{ .kind = .gauge, .value_type = .int64 })) |d| {
                var owned = d;
                owned.deinit();
                try out.writer.writeAll(" | a create: made");
            } else |err| try out.writer.print(" | a create: {t}: {s}", .{ err, diag.message() });
            line.* = out.written();
        }
        agree(&differences, "writes production refused", lines[0], lines[1]);
        var on_sub_info = try f.awaitDescriptor(on_sub);
        on_sub_info.deinit();
        var fake_made = try fake_client.metric(on_sub).get();
        fake_made.deinit();
        fact("the user metric's descriptor was made by both", .{});
    }

    // Descriptors and resource types, as production gives them.
    for (pubsub_metrics) |m| {
        const t = try a.print("{s}{s}", .{ pubsub_prefix, m });
        var lines: [2][]const u8 = undefined;
        for ([_]*monitoring.Client{ &f.client, &fake_client }, &lines) |client, *line| {
            var info = try client.metric(t).get();
            defer info.deinit();
            var out: std.Io.Writer.Allocating = .init(a);
            try out.writer.print("{t} {t} unit {s}, \"{s}\", \"{s}\", labels", .{ info.value.kind, info.value.value_type, info.value.unit, info.value.display_name, info.value.description });
            for (info.value.labels) |l| try out.writer.print(" {s} \"{s}\"", .{ l.key, l.description });
            try out.writer.writeAll(", on");
            for (info.value.resource_types) |rt| try out.writer.print(" {s}", .{rt});
            line.* = out.written();
        }
        agree(&differences, m, lines[0], lines[1]);
    }
    for ([_][]const u8{ "pubsub_subscription", "pubsub_topic" }) |rt| {
        var lines: [2][]const u8 = undefined;
        for ([_]*monitoring.Client{ &f.client, &fake_client }, &lines) |client, *line| {
            var info = try client.resourceType(rt);
            defer info.deinit();
            var out: std.Io.Writer.Allocating = .init(a);
            try out.writer.print("\"{s}\", \"{s}\", labels", .{ info.value.display_name, info.value.description });
            for (info.value.labels) |l| try out.writer.print(" {s} \"{s}\"", .{ l.key, l.description });
            line.* = out.written();
        }
        agree(&differences, rt, lines[0], lines[1]);
    }
    try testing.expectEqual(0, differences);
}

const quota_prefix = "serviceruntime.googleapis.com/quota/";

/// The four quota metrics `FakeMonitoring` holds, after `quota_prefix`.
const quota_metrics = [_][]const u8{
    "allocation/usage",
    "exceeded",
    "limit",
    "rate/net_usage",
};

test "monitoring: Cloud's quota metrics, and the fake given production's points answers as production did" {
    var f: Fixture = undefined;
    if (!try f.init()) return error.SkipZigTest;
    defer f.deinit();
    if (f.env.get("MONITORING_TEST_QUOTA") == null) return error.SkipZigTest;
    const a = f.arena.allocator();

    // Rate quota is consumed by requests, so make some: topic lists are
    // Pub/Sub administrator operations.
    var ps_diag: pubsub.Diagnostics = .{};
    var ps = try pubsub.Client.init(testing.allocator, testing.io, .{ .project_id = f.project, .token_provider = f.token.provider(), .diagnostics = &ps_diag });
    defer ps.deinit();
    for (0..20) |_| {
        var topics = try ps.listTopics(.{});
        topics.deinit();
    }
    const called = nowMs();
    fact("20 topic lists sent", .{});

    // Wait until the calls' minute shows in the rate quota (sampled every
    // 60 s, Google says visible within 240 s), and is at least a minute
    // older than the window's end, so nothing arrives while the reads
    // below run.
    const by_pubsub: monitoring.Filter = .{ .resource_labels = &.{.{ .key = "service", .value = "pubsub.googleapis.com" }} };
    var waited: usize = 0;
    while (true) : (waited += 1) {
        if (waited == 32) return error.TestPointsNeverReadable;
        try testing.io.sleep(.fromSeconds(30), .awake);
        const now: std.Io.Timestamp = .{ .nanoseconds = nowMs() };
        var net = try f.client.metric(quota_prefix ++ "rate/net_usage").read(.{ .start = .{ .nanoseconds = floorMinute(called) - std.time.ns_per_min }, .end = now, .filter = by_pubsub });
        defer net.deinit();
        var latest: i96 = 0;
        for (net.value.series) |s| for (s.points) |p| {
            latest = @max(latest, p.end.nanoseconds);
        };
        if (latest > floorMinute(called) and now.nanoseconds - floorMinute(called) >= 6 * std.time.ns_per_min) break;
    }
    fact("rate points readable {d} s after the calls", .{@divFloor(nowMs() - called, std.time.ns_per_s)});

    // Production's raw points over 26 hours, put into the fake. The limit
    // is sampled daily and usage repeats at least daily, so the window
    // holds each series the project has; it ends five minutes back, past
    // the calls above.
    const end: std.Io.Timestamp = .{ .nanoseconds = floorMinute(nowMs()) - 5 * std.time.ns_per_min };
    const window_start: std.Io.Timestamp = .{ .nanoseconds = end.nanoseconds - 26 * std.time.ns_per_hour };
    var fake: monitoring.testing.FakeMonitoring = .init(testing.allocator, testing.io, .{ .project_id = f.project });
    defer fake.deinit();
    var fake_diag: monitoring.Diagnostics = .{};
    var fake_client = try monitoring.Client.init(testing.allocator, testing.io, .{ .project_id = f.project, .token_provider = f.token.provider(), .transport = fake.transport(), .diagnostics = &fake_diag });
    defer fake_client.deinit();
    const services = [_][]const u8{ "pubsub.googleapis.com", "monitoring.googleapis.com" };
    var put_series: usize = 0;
    var put_points: usize = 0;
    for (quota_metrics) |m| for (services) |svc| {
        var raw = try f.client.metric(try a.print("{s}{s}", .{ quota_prefix, m })).read(.{ .start = window_start, .end = end, .filter = .{ .resource_labels = &.{.{ .key = "service", .value = svc }} } });
        defer raw.deinit();
        try testing.expectEqual(null, raw.value.next_page_token);
        for (raw.value.series) |s| {
            const pts = try a.alloc(monitoring.testing.FakeMonitoring.Point, s.points.len);
            // Newest first in a read; oldest first in a put.
            for (s.points, 0..) |p, i| pts[pts.len - 1 - i] = .{ .start = if (s.kind == .gauge) null else p.start, .end = p.end, .value = p.value.? };
            try fake.put(.{ .metric_type = s.metric_type, .metric_labels = s.metric_labels, .resource_type = s.resource_type, .resource_labels = s.resource_labels, .kind = s.kind, .value_type = s.value_type, .points = pts });
            put_series += 1;
            put_points += pts.len;
        }
    };
    fact("{d} series put into the fake, {d} points", .{ put_series, put_points });

    // The reads a console makes: raw by service, and the aligners each
    // kind takes, with the refusals production answers on the rest.
    const by_monitoring: monitoring.Filter = .{ .resource_labels = &.{.{ .key = "service", .value = "monitoring.googleapis.com" }} };
    const by_quota_metric: []const []const u8 = &.{"metric.labels.quota_metric"};
    var reads: std.ArrayList(PubsubRead) = .empty;
    for (quota_metrics) |m| {
        try reads.append(a, .{ .label = try a.print("raw {s} pubsub", .{m}), .metric = m, .prefix = quota_prefix, .start = window_start, .end = end, .filter = by_pubsub });
        try reads.append(a, .{ .label = try a.print("raw {s} monitoring", .{m}), .metric = m, .prefix = quota_prefix, .start = window_start, .end = end, .filter = by_monitoring });
        const aggregations: []const monitoring.Aggregation = if (std.mem.eql(u8, m, "rate/net_usage")) &.{
            .{ .alignment_period_s = 60, .aligner = .delta, .reducer = .sum },
            .{ .alignment_period_s = 300, .aligner = .delta, .reducer = .sum, .group_by = &.{"metric.labels.method"} },
            .{ .alignment_period_s = 60, .aligner = .rate, .reducer = .sum },
            .{ .alignment_period_s = 3600, .aligner = .delta },
            .{ .alignment_period_s = 3600, .aligner = .sum, .reducer = .sum },
            .{ .alignment_period_s = 300, .aligner = .max, .reducer = .max },
            .{ .alignment_period_s = 300, .aligner = .count, .reducer = .sum },
        } else if (std.mem.eql(u8, m, "exceeded")) &.{
            .{ .alignment_period_s = 3600, .aligner = .count },
            .{ .alignment_period_s = 3600, .aligner = .count, .reducer = .sum },
        } else &.{
            .{ .alignment_period_s = 3600, .aligner = .max },
            .{ .alignment_period_s = 3600, .aligner = .max, .reducer = .sum, .group_by = by_quota_metric },
            .{ .alignment_period_s = 3600, .aligner = .mean, .reducer = .max },
            .{ .alignment_period_s = 86400, .aligner = .max },
            .{ .alignment_period_s = 3600, .aligner = .min },
            .{ .alignment_period_s = 3600, .aligner = .sum },
            .{ .alignment_period_s = 3600, .aligner = .count, .reducer = .count },
            .{ .alignment_period_s = 3600, .aligner = .delta },
            .{ .alignment_period_s = 3600, .aligner = .rate },
        };
        for (aggregations, 0..) |agg, i| try reads.append(a, .{ .label = try a.print("{s} #{d}", .{ m, i }), .metric = m, .prefix = quota_prefix, .start = window_start, .end = end, .filter = by_pubsub, .aggregation = agg });
    }
    // Around one quota metric of the limit: both metrics filtered on its
    // label.
    {
        var raw = try f.client.metric(quota_prefix ++ "limit").read(.{ .start = window_start, .end = end, .filter = by_pubsub });
        defer raw.deinit();
        if (raw.value.series.len > 0) {
            const labels = try a.alloc(monitoring.Match, 1);
            labels[0] = .{ .key = "quota_metric", .value = try a.dupe(u8, raw.value.series[0].label("quota_metric").?) };
            try reads.append(a, .{ .label = "limit by quota_metric", .metric = "limit", .prefix = quota_prefix, .start = window_start, .end = end, .filter = .{ .metric_labels = labels } });
            try reads.append(a, .{ .label = "usage by quota_metric", .metric = "allocation/usage", .prefix = quota_prefix, .start = window_start, .end = end, .filter = .{ .metric_labels = labels } });
        } else fact("no limit series for pubsub: no quota_metric reads", .{});
    }
    // Filters production refused, or did not.
    for ([_]struct { []const u8, []const u8, monitoring.Filter }{
        .{ "filter: a quota metric on subscription_id", "allocation/usage", .{ .resource_labels = &.{.{ .key = "subscription_id", .value = "x" }} } },
        .{ "filter: a quota metric on zone", "allocation/usage", .{ .resource_labels = &.{.{ .key = "zone", .value = "x" }} } },
        .{ "filter: a metric label the metric lacks", "allocation/usage", .{ .metric_labels = &.{.{ .key = "limit_name", .value = "x" }} } },
        .{ "filter: its own resource type and service", "allocation/usage", .{ .resource_type = "consumer_quota", .resource_labels = &.{.{ .key = "service", .value = "pubsub.googleapis.com" }} } },
        .{ "filter: resource type global", "allocation/usage", .{ .resource_type = "global" } },
        .{ "filter: resource type pubsub_topic", "allocation/usage", .{ .resource_type = "pubsub_topic" } },
        .{ "filter: a quota_metric prefix", "limit", .{ .metric_labels = &.{.{ .key = "quota_metric", .op = .starts_with, .value = "pubsub.googleapis.com/" }} } },
        .{ "filter: location global", "limit", .{ .resource_labels = &.{ .{ .key = "service", .value = "pubsub.googleapis.com" }, .{ .key = "location", .value = "global" } } } },
    }) |c| try reads.append(a, .{ .label = c[0], .metric = c[1], .prefix = quota_prefix, .start = window_start, .end = end, .filter = c[2] });

    var differences: usize = 0;
    for (reads.items) |r| {
        const in_memory = try pubsubOutcome(a, &fake_client, &fake_diag, window_start.nanoseconds, r);
        const production = try pubsubOutcome(a, &f.client, &f.diag, window_start.nanoseconds, r);
        agree(&differences, r.label, production, in_memory);
    }

    // producer_quota, which the fake does not hold: production's answer
    // on the record, the fake's 501 checked by its unit tests.
    if (f.client.metric(quota_prefix ++ "limit").read(.{ .start = window_start, .end = end, .filter = .{ .resource_type = "producer_quota" } })) |page| {
        var owned = page;
        defer owned.deinit();
        fact("producer_quota filter: production answered {d} series", .{owned.value.series.len});
    } else |err| fact("producer_quota filter: production refused {t}: {s}", .{ err, f.diag.message() });

    // Writes production refused: one of the quota metrics; a user metric
    // on consumer_quota, its descriptor made all the same; a create under
    // serviceruntime's domain.
    {
        const on_quota = try f.name("on_quota");
        const quota_resource: monitoring.Resource = .{ .other = .{ .type = "consumer_quota", .labels = &.{ .{ .key = "service", .value = "pubsub.googleapis.com" }, .{ .key = "location", .value = "global" } } } };
        const google_type = try a.print("{s}zigps_mon_{s}", .{ quota_prefix, f.run });
        var lines: [2][]const u8 = undefined;
        for ([_]*monitoring.Client{ &f.client, &fake_client }, [_]*monitoring.Diagnostics{ &f.diag, &fake_diag }, &lines) |client, diag, *line| {
            var out: std.Io.Writer.Allocating = .init(a);
            const now: std.Io.Timestamp = .{ .nanoseconds = nowMs() };
            if (client.write(&.{.{ .metric_type = quota_prefix ++ "allocation/usage", .resource = quota_resource, .kind = .gauge, .end = now, .value = .{ .int64 = 1 } }})) |r| {
                var owned = r;
                owned.deinit();
                try out.writer.writeAll("Google's: written");
            } else |err| try out.writer.print("Google's: {t}: {s}", .{ err, diag.message() });
            if (client.write(&.{.{ .metric_type = on_quota, .resource = quota_resource, .kind = .gauge, .end = now, .value = .{ .int64 = 1 } }})) |r| {
                var owned = r;
                defer owned.deinit();
                try out.writer.print(" | a user metric: {d} written, {s}", .{ owned.value.written, owned.value.message });
            } else |err| try out.writer.print(" | a user metric: {t}: {s}", .{ err, diag.message() });
            if (client.metric(google_type).create(.{ .kind = .gauge, .value_type = .int64 })) |d| {
                var owned = d;
                owned.deinit();
                try out.writer.writeAll(" | a create: made");
            } else |err| try out.writer.print(" | a create: {t}: {s}", .{ err, diag.message() });
            line.* = out.written();
        }
        agree(&differences, "writes production refused", lines[0], lines[1]);
        var on_quota_info = try f.awaitDescriptor(on_quota);
        on_quota_info.deinit();
        var fake_made = try fake_client.metric(on_quota).get();
        fake_made.deinit();
        fact("the user metric's descriptor was made by both", .{});
    }

    // Descriptors and the resource type, as production gives them.
    for (quota_metrics) |m| {
        const t = try a.print("{s}{s}", .{ quota_prefix, m });
        var lines: [2][]const u8 = undefined;
        for ([_]*monitoring.Client{ &f.client, &fake_client }, &lines) |client, *line| {
            var info = try client.metric(t).get();
            defer info.deinit();
            var out: std.Io.Writer.Allocating = .init(a);
            try out.writer.print("{t} {t} unit {s}, \"{s}\", \"{s}\", labels", .{ info.value.kind, info.value.value_type, info.value.unit, info.value.display_name, info.value.description });
            for (info.value.labels) |l| try out.writer.print(" {s} \"{s}\"", .{ l.key, l.description });
            try out.writer.writeAll(", on");
            for (info.value.resource_types) |rt| try out.writer.print(" {s}", .{rt});
            line.* = out.written();
        }
        agree(&differences, m, lines[0], lines[1]);
    }
    {
        var lines: [2][]const u8 = undefined;
        for ([_]*monitoring.Client{ &f.client, &fake_client }, &lines) |client, *line| {
            var info = try client.resourceType("consumer_quota");
            defer info.deinit();
            var out: std.Io.Writer.Allocating = .init(a);
            try out.writer.print("\"{s}\", \"{s}\", labels", .{ info.value.display_name, info.value.description });
            for (info.value.labels) |l| try out.writer.print(" {s} \"{s}\"", .{ l.key, l.description });
            line.* = out.written();
        }
        agree(&differences, "consumer_quota", lines[0], lines[1]);
    }
    try testing.expectEqual(0, differences);
}
