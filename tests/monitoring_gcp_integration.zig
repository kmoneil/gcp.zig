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

const std = @import("std");
const core = @import("core");
const monitoring = @import("monitoring");
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
    /// about 2 s after a create.
    fn awaitDescriptor(f: *Fixture, metric_type: []const u8) !monitoring.Owned(monitoring.MetricInfo) {
        for (0..30) |_| {
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
                    var line: std.Io.Writer.Allocating = .init(a);
                    try line.writer.print("{t} {t} {{", .{ s.kind, s.value_type });
                    try writeLabels(a, &line.writer, s.metric_labels, false);
                    try line.writer.writeAll("} {");
                    try writeLabels(a, &line.writer, s.resource_labels, true);
                    try line.writer.writeAll("}");
                    for (s.points) |p| {
                        on_page += 1;
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
                    try lines.append(a, line.written());
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
