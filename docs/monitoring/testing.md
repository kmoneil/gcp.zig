[Docs](../README.md) › [Monitoring](README.md) › Testing

# Testing with the in-memory Cloud Monitoring

Cloud Monitoring has no emulator, so `monitoring.testing.FakeMonitoring`
is the test double: descriptors and points in memory, behind
`Client.Options.transport`, held to the rules production enforced when
measured.

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
written to Pub/Sub's resource types (or to `consumer_quota` or
`gcs_bucket`, below) is refused in the summary, as
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

### Cloud Storage's metrics

A bucket's size and traffic are Google's own metrics too, on the
resource type `gcs_bucket` (labels `bucket_name` and `location`). The
fake knows the five a bucket page charts, as production described them
on 5 November 2026 (issue #338):

| Metric, after `storage.googleapis.com/` | Kind | Value | Unit | Labels |
| --- | --- | --- | --- | --- |
| `storage/total_bytes` | GAUGE | DOUBLE | `By` | `storage_class` |
| `storage/object_count` | GAUGE | INT64 | `1` | `storage_class` |
| `api/request_count` | DELTA | INT64 | `1` | `response_code`, `method` |
| `network/received_bytes_count` | DELTA | INT64 | `By` | `response_code`, `method` |
| `network/sent_bytes_count` | DELTA | INT64 | `By` | `response_code`, `method` |

A test puts them in with `put`, as Pub/Sub's above, and they read, list
and refuse creates, writes and deletes the same way. To put in what
production would show, follow what it sent on that day:

- `location` is the bucket's location in lowercase: `us-central1` for a
  bucket in `US-CENTRAL1`, and `us` for the multi-region `US`.
- `storage_class` uses the older class names: a STANDARD bucket reported
  `REGIONAL` in a region and `MULTI_REGIONAL` in a multi-region.
- The two gauges have a point every 5 minutes, on the 5-minute mark. The
  value is measured once a day and repeated all day. An emptied bucket
  reported `0`.
- The counts have one point a minute, starting 1 ms after the minute
  before ended. A series has points only around activity, with one `0`
  minute after it; quiet minutes have none.
- `method` is the gRPC method's name even for JSON API calls
  (`WriteObject`, `ReadObject`, `GetObjectMetadata`, `ListObjects`,
  `DeleteObject`), and `response_code` the status code's name (`OK`,
  `NOT_FOUND`).

<!-- snippet: tests/docs_examples.zig#mon-storage -->
```zig
test "a bucket's size and requests, put in the in-memory Cloud Monitoring" {
    var clock: monitoring.testing.FakeClock = .{ .now_ns = 1_792_331_195 * std.time.ns_per_s };
    var fake: monitoring.testing.FakeMonitoring = .init(std.testing.allocator, clock.io(), .{ .project_id = "my-project" });
    defer fake.deinit();

    // A bucket's size and traffic are Google's own metrics on the
    // resource type gcs_bucket, so the test puts them in: the size a
    // point every 5 minutes, requests a minute at a time.
    const t = std.Io.Clock.real.now(clock.io()).nanoseconds;
    const s = std.time.ns_per_s;
    const bucket: []const monitoring.Label = &.{ .{ .key = "bucket_name", .value = "assets" }, .{ .key = "location", .value = "us-central1" } };
    try fake.put(.{
        .metric_type = "storage.googleapis.com/storage/total_bytes",
        .metric_labels = &.{.{ .key = "storage_class", .value = "REGIONAL" }},
        .resource_type = "gcs_bucket",
        .resource_labels = bucket,
        .kind = .gauge,
        .value_type = .double,
        .points = &.{
            .{ .start = null, .end = .{ .nanoseconds = t - 600 * s }, .value = .{ .double = 4_096 } },
            .{ .start = null, .end = .{ .nanoseconds = t - 300 * s }, .value = .{ .double = 8_192 } },
        },
    });
    try fake.put(.{
        .metric_type = "storage.googleapis.com/api/request_count",
        .metric_labels = &.{ .{ .key = "response_code", .value = "OK" }, .{ .key = "method", .value = "ReadObject" } },
        .resource_type = "gcs_bucket",
        .resource_labels = bucket,
        .kind = .delta,
        .value_type = .int64,
        .points = &.{.{ .start = .{ .nanoseconds = t - 60 * s + std.time.ns_per_ms }, .end = .{ .nanoseconds = t }, .value = .{ .int64 = 42 } }},
    });

    var token: monitoring.StaticToken = .{ .token = "none" };
    var client = try monitoring.Client.init(std.testing.allocator, clock.io(), .{
        .project_id = "my-project",
        .token_provider = token.provider(),
        .transport = fake.transport(),
    });
    defer client.deinit();
    const assets: monitoring.Filter = .{ .resource_type = "gcs_bucket", .resource_labels = &.{.{ .key = "bucket_name", .value = "assets" }} };
    // The bucket's size over the hour: its largest, summed over storage
    // classes.
    var size = try client.metric("storage.googleapis.com/storage/total_bytes").read(.{
        .start = .{ .nanoseconds = t - 3600 * s },
        .end = .{ .nanoseconds = t },
        .filter = assets,
        .aggregation = .{ .alignment_period_s = 3600, .aligner = .max, .reducer = .sum },
    });
    defer size.deinit();
    try std.testing.expectEqual(8_192, size.value.series[0].points[0].value.?.double);
    // Its requests in the last minute, every method and response summed.
    var requests = try client.metric("storage.googleapis.com/api/request_count").read(.{
        .start = .{ .nanoseconds = t - 60 * s },
        .end = .{ .nanoseconds = t },
        .filter = assets,
        .aggregation = .{ .alignment_period_s = 60, .aligner = .delta, .reducer = .sum },
    });
    defer requests.deinit();
    try std.testing.expectEqual(42, requests.value.series[0].points[0].value.?.int64);
}
```

### Alerts

Alerts come from alert policies, which no program makes through this
API, so `putAlert` is the test's lever: it holds what production
answered for a real incident (issue #246), and `closeAlert` closes one,
as production closed an alert 91 s after its policy's delete, its
metric and resource kept and the alert still listable. Reads answer as
production answered: the structured filters milestone 0 measured
(`state`, `severity`, `policy.display_name`; a filter form production
was not asked about is a 501), both orders, pages with `totalSize` on
every non-empty answer, and the 404 in production's words.

<!-- snippet: tests/docs_examples.zig#mon-alerts -->
```zig
test "the open incidents, as a console draws them" {
    var clock: monitoring.testing.FakeClock = .{ .now_ns = 1_792_331_195 * std.time.ns_per_s };
    var fake: monitoring.testing.FakeMonitoring = .init(std.testing.allocator, clock.io(), .{ .project_id = "my-project" });
    defer fake.deinit();
    // Alerts come from policies, which no program makes through this
    // API, so the test puts one in.
    const id = try fake.putAlert(.{
        .open_time = std.Io.Clock.real.now(clock.io()),
        .policy = .{ .display_name = "Pub/Sub backlog too deep", .severity = .warning, .user_labels = &.{.{ .key = "team", .value = "ingest" }} },
        .metric_type = "pubsub.googleapis.com/subscription/num_undelivered_messages",
        .resource_type = "pubsub_subscription",
        .resource_labels = &.{ .{ .key = "project_id", .value = "my-project" }, .{ .key = "subscription_id", .value = "orders" } },
    });

    var token: monitoring.StaticToken = .{ .token = "none" };
    var client = try monitoring.Client.init(std.testing.allocator, clock.io(), .{
        .project_id = "my-project",
        .token_provider = token.provider(),
        .transport = fake.transport(),
    });
    defer client.deinit();
    // The widget's read: the alerts still firing, newest first.
    var open = try client.listAlerts(.{ .open_only = true });
    defer open.deinit();
    try std.testing.expectEqual(1, open.value.alerts.len);
    try std.testing.expectEqualStrings("Pub/Sub backlog too deep", open.value.alerts[0].policy.display_name);
    try std.testing.expectEqual(monitoring.Severity.warning, open.value.alerts[0].policy.severity);

    // The incident resolves: production closes alerts itself; the fake
    // takes the test's word for it.
    try fake.closeAlert(id, std.Io.Clock.real.now(clock.io()));
    var after = try client.listAlerts(.{ .open_only = true });
    defer after.deinit();
    try std.testing.expectEqual(0, after.value.alerts.len);
}
```

### Alert policies

`putAlertPolicy` puts a policy in, standing in for the console or the
Terraform that made it (issue #275): its conditions of any kind, its
documentation, labels and channels, its creation record on the fake's
clock and `Options.caller`. The fake answers lists, gets and
`setAlertPolicyEnabled` as production answered on 2026-10-20: lists by
name without an order, `totalSize` on every page and `{}` for none;
the filter forms milestone 0 measured, with `AND`; `severity`, any
other field and a bare word refused in production's words; `OR`,
`NOT`, brackets and regular expressions a 501. A patch takes
`updateMask=enabled` alone, an absent `enabled` read as true, the
mutation record moved by every patch, a repeat included; a 404 names
the project id on a get and `Options.project_number` on a patch.

<!-- snippet: tests/docs_examples.zig#mon-policies -->
```zig
test "the policy behind an incident, disabled after a confirmation" {
    var clock: monitoring.testing.FakeClock = .{ .now_ns = 1_792_331_195 * std.time.ns_per_s };
    var fake: monitoring.testing.FakeMonitoring = .init(std.testing.allocator, clock.io(), .{ .project_id = "my-project" });
    defer fake.deinit();
    // Policies are made in the console or by Terraform; the test puts one in.
    const name = try fake.putAlertPolicy(.{
        .display_name = "Pub/Sub backlog too deep",
        .severity = .warning,
        .conditions = &.{.{
            .display_name = "backlog over 1000",
            .kind = .threshold,
            .filter = "metric.type=\"pubsub.googleapis.com/subscription/num_undelivered_messages\" AND resource.type=\"pubsub_subscription\"",
            .comparison = .gt,
            .threshold_value = 1000,
            .duration_s = 300,
        }},
    });

    var token: monitoring.StaticToken = .{ .token = "none" };
    var client = try monitoring.Client.init(std.testing.allocator, clock.io(), .{
        .project_id = "my-project",
        .token_provider = token.provider(),
        .transport = fake.transport(),
    });
    defer client.deinit();
    var policy = try client.getAlertPolicy(name);
    defer policy.deinit();
    try std.testing.expectEqual(monitoring.ConditionKind.threshold, policy.value.conditions[0].kind);
    try std.testing.expectEqual(1000, policy.value.conditions[0].threshold_value.?);

    // What the confirmation shows, then the write it names.
    var request = try client.setAlertPolicyEnabledRequest(name, false);
    defer request.deinit();
    try std.testing.expectEqualStrings("{\"enabled\":false}", request.value.body);
    try std.testing.expect(std.mem.endsWith(u8, request.value.url, "?updateMask=enabled"));
    var disabled = try client.setAlertPolicyEnabled(name, false);
    defer disabled.deinit();
    try std.testing.expect(!disabled.value.enabled);

    var off = try client.listAlertPolicies(.{ .filter = "enabled=false" });
    defer off.deinit();
    try std.testing.expectEqual(1, off.value.policies.len);
}
```

### Snoozes

Snoozes are made through the API, as production makes them (issue
#275), and the fake answers as production did on 2026-10-20: a create
checked in production's order and words (a start more than 15 s in
the past, more than 16 policies, a filter without exactly one policy,
no display name, under a minute), policies that need not exist, the
answer carrying the times as sent and reads after keeping whole
seconds; lists newest start first, filtered by `interval.start_time`
and `interval.end_time` with `>=` and `<=`, the refusals' reasons
production's; the three ways production ends one, and its refusal of
any change to an ended snooze. An active snooze closes the open alerts
of its policies at its start (and its filter's resource labels), on
the fake's clock, whenever the fake is next asked, and `putAlert`
refuses an open alert for a policy a snooze holds. Production wrote
its own parse tree into its filter refusals; the fake writes the
filter there, and the reason after it is production's. Where it
differs: the fake lists a new snooze at once, where production's lists
showed one anywhere from at once to 91 s after its create.

<!-- snippet: tests/docs_examples.zig#mon-snooze -->
```zig
test "a snooze from the incidents widget: the alert closes, and it ends early" {
    var clock: monitoring.testing.FakeClock = .{ .now_ns = 1_792_522_800 * std.time.ns_per_s };
    var fake: monitoring.testing.FakeMonitoring = .init(std.testing.allocator, clock.io(), .{ .project_id = "my-project" });
    defer fake.deinit();
    const policy = try fake.putAlertPolicy(.{ .display_name = "Pub/Sub backlog too deep", .severity = .warning });
    const alert = try fake.putAlert(.{
        .open_time = std.Io.Clock.real.now(clock.io()),
        .policy = .{ .name = policy, .display_name = "Pub/Sub backlog too deep", .severity = .warning },
    });

    var token: monitoring.StaticToken = .{ .token = "none" };
    var client = try monitoring.Client.init(std.testing.allocator, clock.io(), .{
        .project_id = "my-project",
        .token_provider = token.provider(),
        .transport = fake.transport(),
    });
    defer client.deinit();

    // An hour from now, confirmed first.
    const now = std.Io.Clock.real.now(clock.io());
    const spec: monitoring.NewSnooze = .{
        .display_name = "deploy window",
        .policies = &.{policy},
        .start = now,
        .end = .{ .nanoseconds = now.nanoseconds + std.time.ns_per_hour },
    };
    var request = try client.createSnoozeRequest(spec);
    defer request.deinit();
    try std.testing.expect(std.mem.endsWith(u8, request.value.url, "/snoozes"));
    var snooze = try client.createSnooze(spec);
    defer snooze.deinit();

    // From its start, the policy's open alert is closed.
    var closed = try client.getAlert(alert);
    defer closed.deinit();
    try std.testing.expectEqual(monitoring.AlertState.closed, closed.value.state);

    // Ended early, ten minutes in: its end set to now.
    clock.now_ns += 10 * std.time.ns_per_min;
    const later = std.Io.Clock.real.now(clock.io());
    var ended = try client.endSnooze(snooze.value, later);
    defer ended.deinit();
    try std.testing.expectEqual(monitoring.SnoozeState.ended, ended.value.stateAt(later));
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
  - a program's metric on a resource type only Google's metrics are on.

  A reset, the last point sent again, and a falling total are taken.
  Times are kept to the microsecond.
- **Requests refused whole**: no series or more than 200, another
  project's `project_id`, a descriptor production would not create
  (DELTA or STRING for any metric a program makes), one of Google's
  metrics (403).
- **Descriptors**: created (again with the same shape, or 409 with
  another), read, listed by prefix and in pages, deleted with their
  points. A first write creates one; a write with a new label adds it.
  Google's own are there from the start.
- **Reads**:
  - its own reading of the filter the client writes, labels it does not know refused as production refused them, by the resource types the metric can be on, and a resource type it cannot be on;
  - (start, end], newest first;
  - the gauge aligners and reducers min, max, mean, sum and count with group-by fields, periods ending at the read's end; a period that reaches back before the read's start holds the series' earlier points, as production held them;
  - on DELTA metrics, `ALIGN_DELTA` and `ALIGN_SUM` (each period's total over the period, DELTA), `ALIGN_RATE` (each period's total a second, GAUGE DOUBLE), and min, max, mean and count (a gauge at the period's end), with the same reducers; a point counts whole in the period its end falls in, as production counted it;
  - the aligners production refused on a kind, refused in its words: `ALIGN_DELTA` and `ALIGN_RATE` on a gauge; interpolate, next older, the true and false counts and the percentiles on a DELTA metric;
  - the unit production gave: `1` for a count, aligned or reduced, the metric's unit a second for a rate (`1/s`, `By/s`), and `{not_a_unit}` for a metric without one;
  - pages by points with series split across them, and HEADERS.
- **The resource types** the `Resource` union names, and Pub/Sub's two,
  `consumer_quota` and `gcs_bucket`, which carry only Google's metrics.
- **Faults**: `refuseNext`, `refuseNextWithDelay`, `dropNext`, and
  `loseNext`, which serves a call and answers it with an error, as a 504
  that stored a write.

A production suite runs one script of 60 operations against production
and the fake, and holds the fake to every outcome. Another sends Pub/Sub
traffic, puts production's points for it into the fake, and holds the
fake to production's answers to about 90 reads, its descriptors and its
resource types. A third reads the project's own quota series, puts them
into the fake, and holds it to production's answers the same way. A
fourth makes a bucket and sends it about seventy requests, puts that
bucket's counts and every bucket's size and object count into the fake,
and holds the fake to production's answers to 75 reads, its refusals,
its descriptors and `gcs_bucket`: on 5 November 2026 they agreed on
every one.

## Where it differs

- Its messages give times in UTC, where production wrote US Pacific.
- A descriptor just created reads back at once, where production
  answered 404 for about 2 s, and once for more than 15 s.
- Only the resource type text of generic_task, Pub/Sub's two,
  consumer_quota and gcs_bucket is production's.
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
