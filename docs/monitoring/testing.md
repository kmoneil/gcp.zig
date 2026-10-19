[Docs](../README.md) › [Monitoring](README.md) › Testing

# Testing with the in-memory Cloud Monitoring

Cloud Monitoring has no emulator, so `monitoring.testing.FakeMonitoring`
is the test double: descriptors and points in memory, behind
`Client.Options.transport`, held to the rules production enforced when
measured. **Experimental**, as the module is.

<!-- snippet: tests/docs_examples.zig#mon-fake -->
```zig
test "a write, held by the in-memory Cloud Monitoring" {
    var clock: monitoring.testing.FakeClock = .{ .now_ns = 1_792_331_195 * std.time.ns_per_s };
    var fake: monitoring.testing.FakeMonitoring = .init(std.testing.allocator, clock.io(), .{ .project_id = "my-project" });
    defer fake.deinit();
    var token: monitoring.StaticToken = .{ .token = "none" };
    var client = try monitoring.Client.init(std.testing.allocator, clock.io(), .{
        .project_id = "my-project",
        .token_provider = token.provider(),
        .transport = fake.transport(),
    });
    defer client.deinit();

    const now = std.Io.Clock.real.now(clock.io());
    try writeDepth(&client, "7", 3, now);
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const kept = try fake.points(arena.allocator(), "custom.googleapis.com/shop/queue_depth", &.{.{ .key = "queue", .value = "orders" }});
    try std.testing.expectEqual(3, kept[0].value.int64);

    // Too soon after the last point: refused, as production refuses it.
    clock.now_ns += std.time.ns_per_s;
    var again = try client.write(&.{.{ .metric_type = "custom.googleapis.com/shop/queue_depth", .metric_labels = &.{.{ .key = "queue", .value = "orders" }}, .resource = .{ .generic_task = .{ .location = "us-central1", .namespace = "shop", .job = "api", .task_id = "7" } }, .kind = .gauge, .end = std.Io.Clock.real.now(clock.io()), .value = .{ .int64 = 4 } }});
    defer again.deinit();
    try std.testing.expectEqual(error.FailedPrecondition, again.value.refused[0].reason);
}
```

The fake's clock is the `Io` it is given: a `FakeClock` moves when a test
says, and the real clock suits a test of a `Recorder` that runs on its
own task.

## Google's own metrics

No program can write Google's own metrics, such as Pub/Sub's backlog and
delivery counts. A test of code that reads them puts them in with
`FakeMonitoring.put`, giving a metric type and labels, a resource type and
labels, the kind, the value type, and the points, oldest first:

<!-- snippet: tests/docs_examples.zig#mon-google -->
```zig
test "Pub/Sub's own counts, put in the in-memory Cloud Monitoring and read back" {
    var clock: monitoring.testing.FakeClock = .{ .now_ns = 1_792_331_195 * std.time.ns_per_s };
    var fake: monitoring.testing.FakeMonitoring = .init(std.testing.allocator, clock.io(), .{ .project_id = "my-project" });
    defer fake.deinit();

    // No program can write Google's own metrics, so the test puts them in:
    // a minute a point, as Pub/Sub reports them.
    const t = std.Io.Clock.real.now(clock.io()).nanoseconds;
    const minute: i96 = 60 * std.time.ns_per_s;
    const points = [_]monitoring.testing.FakeMonitoring.Point{
        .{ .start = .{ .nanoseconds = t - 2 * minute }, .end = .{ .nanoseconds = t - minute }, .value = .{ .int64 = 60 } },
        .{ .start = .{ .nanoseconds = t - minute }, .end = .{ .nanoseconds = t }, .value = .{ .int64 = 90 } },
    };
    try fake.put(.{
        .metric_type = "pubsub.googleapis.com/subscription/sent_message_count",
        .metric_labels = &.{.{ .key = "delivery_type", .value = "pull" }},
        .resource_type = "pubsub_subscription",
        .resource_labels = &.{.{ .key = "subscription_id", .value = "orders" }},
        .kind = .delta,
        .value_type = .int64,
        .points = &points,
    });

    var token: monitoring.StaticToken = .{ .token = "none" };
    var client = try monitoring.Client.init(std.testing.allocator, clock.io(), .{
        .project_id = "my-project",
        .token_provider = token.provider(),
        .transport = fake.transport(),
    });
    defer client.deinit();
    // Messages sent a second, minute by minute, newest first.
    var page = try client.metric("pubsub.googleapis.com/subscription/sent_message_count").read(.{
        .start = .{ .nanoseconds = t - 2 * minute },
        .end = .{ .nanoseconds = t },
        .filter = .{ .resource_labels = &.{.{ .key = "subscription_id", .value = "orders" }} },
        .aggregation = .{ .alignment_period_s = 60, .aligner = .rate, .reducer = .sum },
    });
    defer page.deinit();
    try std.testing.expectEqual(1.5, page.value.series[0].points[0].value.?.double);
    try std.testing.expectEqual(1.0, page.value.series[0].points[1].value.?.double);
}
```

`put` skips the write path's rules of time: the 2.5 s floor, 25 hours
back and 5 minutes ahead. So a test can lay out a day of history at once.
It keeps the other rules: the metric's kind, value type and labels, the
resource's labels, and points in order. Anything production could not
hold is `error.InvalidEntry`, and nothing is kept.

The fake knows the Pub/Sub metrics a console reads, as production
described them on 18 October 2026. Every value is INT64:

| Metric, after `pubsub.googleapis.com/` | Kind | Unit | Labels |
| --- | --- | --- | --- |
| `subscription/num_undelivered_messages` | GAUGE | `1` | none |
| `subscription/oldest_unacked_message_age` | GAUGE | `s` | none |
| `subscription/sent_message_count` | DELTA | `1` | `delivery_type` |
| `subscription/ack_message_count` | DELTA | `1` | `delivery_type` |
| `subscription/expired_ack_deadlines_count` | DELTA | `1` | `delivery_type` |
| `subscription/dead_letter_message_count` | DELTA | `1` | `response_code` |
| `subscription/push_request_count` | DELTA | `1` | `response_class`, `response_code`, `delivery_type` |
| `topic/send_message_operation_count` | DELTA | `1` | `response_code` |
| `topic/byte_cost` | DELTA | `By` | `operation_type`, `response_code` |

The subscription metrics are on the resource type `pubsub_subscription`
(label `subscription_id`), and the topic metrics on `pubsub_topic`
(label `topic_id`). Their descriptors read and list from the start, as
production's do, with production's descriptions. A read of one with
nothing put in answers no series: production answered that way for a
metric with nothing to count, rather than with zeros. None of them can
be created or written: each is production's 403,
`error.PermissionDenied`. A delete is a 501. A program's own metric
written to Pub/Sub's resource types is refused in the summary, as
production refused it, and its descriptor is made all the same, as
production made it.

Google marks `topic/send_message_operation_count` as deprecated, and
suggests counting `topic/message_sizes` instead. The fake does not hold
that metric yet.

### Cloud's quota metrics

Quota usage and limits are Google's own metrics too, on the resource
type `consumer_quota` (labels `service` and `location`: a region, a
zone, or `global`). The fake knows the four a console reads for quota
warnings, as production described them on 19 October 2026 (issue #247).
Every unit is `1`:

| Metric, after `serviceruntime.googleapis.com/` | Kind | Value | Labels |
| --- | --- | --- | --- |
| `quota/allocation/usage` | GAUGE | INT64 | `quota_metric` |
| `quota/exceeded` | GAUGE | BOOL | `limit_name`, `quota_metric` |
| `quota/limit` | GAUGE | INT64 | `limit_name`, `quota_metric` |
| `quota/rate/net_usage` | DELTA | INT64 | `method`, `quota_metric` |

A test puts them in with `put`, as Pub/Sub's above, and they read, list
and refuse creates, writes and deletes the same way. The descriptors of
all but `quota/exceeded` name `producer_quota` too, which the fake does
not hold: a `put` on it, or a filter naming it, is a 501. The BOOL
gauge reads raw and counts (`ALIGN_COUNT`); the other bool aligners are
not modelled.

<!-- snippet: tests/docs_examples.zig#mon-quota -->
```zig
test "quota usage against its limit, put in the in-memory Cloud Monitoring" {
    var clock: monitoring.testing.FakeClock = .{ .now_ns = 1_792_331_195 * std.time.ns_per_s };
    var fake: monitoring.testing.FakeMonitoring = .init(std.testing.allocator, clock.io(), .{ .project_id = "my-project" });
    defer fake.deinit();

    // Quota usage and limits are Google's own metrics on the resource
    // type consumer_quota, so the test puts them in.
    const t = std.Io.Clock.real.now(clock.io()).nanoseconds;
    const quota: []const monitoring.Label = &.{ .{ .key = "service", .value = "pubsub.googleapis.com" }, .{ .key = "location", .value = "global" } };
    try fake.put(.{
        .metric_type = "serviceruntime.googleapis.com/quota/allocation/usage",
        .metric_labels = &.{.{ .key = "quota_metric", .value = "pubsub.googleapis.com/topics" }},
        .resource_type = "consumer_quota",
        .resource_labels = quota,
        .kind = .gauge,
        .value_type = .int64,
        .points = &.{.{ .start = null, .end = .{ .nanoseconds = t }, .value = .{ .int64 = 9_950 } }},
    });
    try fake.put(.{
        .metric_type = "serviceruntime.googleapis.com/quota/limit",
        .metric_labels = &.{ .{ .key = "limit_name", .value = "Topics" }, .{ .key = "quota_metric", .value = "pubsub.googleapis.com/topics" } },
        .resource_type = "consumer_quota",
        .resource_labels = quota,
        .kind = .gauge,
        .value_type = .int64,
        .points = &.{.{ .start = null, .end = .{ .nanoseconds = t }, .value = .{ .int64 = 10_000 } }},
    });

    var token: monitoring.StaticToken = .{ .token = "none" };
    var client = try monitoring.Client.init(std.testing.allocator, clock.io(), .{
        .project_id = "my-project",
        .token_provider = token.provider(),
        .transport = fake.transport(),
    });
    defer client.deinit();
    // The widget's read: usage and limit for one quota metric, paired.
    const window: monitoring.ReadOptions = .{
        .start = .{ .nanoseconds = t - 60 * std.time.ns_per_s },
        .end = .{ .nanoseconds = t },
        .filter = .{ .metric_labels = &.{.{ .key = "quota_metric", .value = "pubsub.googleapis.com/topics" }} },
    };
    var usage = try client.metric("serviceruntime.googleapis.com/quota/allocation/usage").read(window);
    defer usage.deinit();
    var limit = try client.metric("serviceruntime.googleapis.com/quota/limit").read(window);
    defer limit.deinit();
    const used = usage.value.series[0].points[0].value.?.int64;
    const cap = limit.value.series[0].points[0].value.?.int64;
    // Near its limit: the widget warns.
    try std.testing.expect(used * 100 >= cap * 95);
}
```

## What it models

Each as production answered when measured, refusals in its words:

- **Writes**, judged point by point and answered as production answered:
  a summary at HTTP 400 for any refused point, the good ones kept. Refused:
  - under 2.5 s after the series' last point, or the same end with another value;
  - out of order, or more than 5 minutes ahead or 25h10s back;
  - a duplicate in the request;
  - a gauge whose start is not its end, or a non-gauge whose start is not before its end;
  - a kind or value type its descriptor does not take;
  - missing resource labels, or a location that is not a region or zone;
  - label and string limits, and a distribution that does not add up;
  - a cumulative start moved earlier;
  - a program's metric on one of Pub/Sub's resource types.

  A reset, the last point sent again, and a falling total are taken.
  Times are kept to the microsecond.
- **Requests refused whole**: no series or more than 200, another
  project's `project_id`, a descriptor production would not create
  (DELTA or STRING for any metric a program makes), one of Google's
  metrics (403).
- **Descriptors**: created (again with the same shape, or 409 with
  another), read, listed by prefix and in pages, deleted with their
  points. A first write creates one; a write with a new label adds it.
  Pub/Sub's own are there from the start.
- **Reads**:
  - its own reading of the filter the client writes, labels it does not know refused as production refused them, by the resource types the metric can be on, and a resource type it cannot be on;
  - (start, end], newest first;
  - the gauge aligners and reducers min, max, mean, sum and count with group-by fields, periods ending at the read's end; a period that reaches back before the read's start holds the series' earlier points, as production held them;
  - on DELTA metrics, `ALIGN_DELTA` and `ALIGN_SUM` (each period's total over the period, DELTA), `ALIGN_RATE` (each period's total a second, GAUGE DOUBLE), and min, max, mean and count (a gauge at the period's end), with the same reducers; a point counts whole in the period its end falls in, as production counted it;
  - the aligners production refused on a kind, refused in its words: `ALIGN_DELTA` and `ALIGN_RATE` on a gauge; interpolate, next older, the true and false counts and the percentiles on a DELTA metric;
  - the unit production gave: `1` for a count, aligned or reduced, the metric's unit a second for a rate (`1/s`, `By/s`), and `{not_a_unit}` for a metric without one;
  - pages by points with series split across them, and HEADERS.
- **The resource types** the `Resource` union names, Pub/Sub's two and
  `consumer_quota`, which carry only Google's metrics.
- **Faults**: `refuseNext`, `refuseNextWithDelay`, `dropNext`, and
  `loseNext`, which serves a call and answers it with an error, as a 504
  that stored a write.

A production suite runs one script of 60 operations against production
and the fake, and holds the fake to every outcome. Another sends Pub/Sub
traffic, puts production's points for it into the fake, and holds the
fake to production's answers to about 90 reads, its descriptors and its
resource types. A third reads the project's own quota series, puts them
into the fake, and holds it to production's answers the same way.

## Where it differs

- Its messages give times in UTC, where production wrote US Pacific.
- A descriptor just created reads back at once, where production
  answered 404 for about 2 s, and once for more than 15 s.
- Only generic_task's, Pub/Sub's and consumer_quota's resource type
  text is production's.
- A write summary prints the resource's labels in one order, where
  production's order varies call to call.
- A reduced double can differ from production's in its last bits, since
  the sums run in another order; the production suite compares 12
  significant digits.
- Nothing arrives late. Production's DELTA points each covered a minute
  and could be read about 130 s after their end, and a new
  subscription's first backlog point about 400 s after it was made. A
  test puts in what it wants, when it wants.

## What it does not model

It says so: 501, `error.Unimplemented`, with a message that begins
`fake:`. Among these:

- a cumulative start moved later but inside the series' last interval
  (production took one, and the earlier point vanished from reads);
- the aligners interpolate, next older, stddev, the true and false
  counts, percent change and the percentiles on a gauge; stddev and
  percent change on a DELTA metric; aligning a cumulative metric or a
  distribution; a second aggregation;
- filters of another shape (OR, `one_of`), other projects, and the
  resource types `.other` names, Pub/Sub's aside, in a write or a
  filter;
- Google's metrics other than Pub/Sub's nine and the quota four above,
  and deleting any; the quota metrics' producer side (`producer_quota`),
  in a put or a filter;
- distribution rules production was not asked about.
