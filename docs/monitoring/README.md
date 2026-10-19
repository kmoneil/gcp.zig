[Docs](../README.md) › Monitoring

# 📈 Monitoring

A client for Cloud Monitoring's v3 API, for a program's own metrics:
write points, read series back filtered, aligned and reduced, manage the
descriptors that say what a metric is, and a `Recorder` that writes
counters, gauges and histograms every interval from a task of its own.
**Experimental**: new in 0.44.0.

```zig
const std = @import("std");
const auth = @import("auth");
const monitoring = @import("monitoring");

pub fn main(init: std.process.Init) !void {
    const arena = init.arena.allocator();
    const lookup = try auth.Lookup.fromEnv(init.environ_map, arena);
    var creds = try auth.findDefault(init.gpa, init.io, lookup, .{});
    defer creds.deinit();
    var client = try monitoring.Client.init(init.gpa, init.io, .{
        .project_id = "my-project",
        .token_provider = creds.provider(),
    });
    defer client.deinit();
    const task_id = monitoring.Resource.randomTaskId(init.io);
    try writeDepth(&client, &task_id, 17, std.Io.Clock.real.now(init.io));
}
```

<!-- snippet: tests/docs_examples.zig#mon-write -->
```zig
/// Writes a queue's depth now. A write whose points the server refused is
/// still a result, so its counts are the check that matters.
fn writeDepth(client: *monitoring.Client, task_id: []const u8, depth: i64, now: std.Io.Timestamp) !void {
    var result = try client.write(&.{.{
        .metric_type = "custom.googleapis.com/shop/queue_depth",
        .metric_labels = &.{.{ .key = "queue", .value = "orders" }},
        .resource = .{ .generic_task = .{ .location = "us-central1", .namespace = "shop", .job = "api", .task_id = task_id } },
        .kind = .gauge,
        .unit = "{message}",
        .end = now,
        .value = .{ .int64 = depth },
    }});
    defer result.deinit();
    if (!result.value.ok()) {
        std.log.warn("{d} of {d} points refused: {s}", .{ result.value.points - result.value.written, result.value.points, result.value.message });
    }
}
```

Writing needs `monitoring.timeSeries.create` (Monitoring Metric Writer),
reading `monitoring.timeSeries.list` (Monitoring Viewer), and descriptors
`monitoring.metricDescriptors.*` (Monitoring Editor; Editor has them
all). `examples/monitoring.zig` writes, reads back and lists, and runs
offline with `--fake`; `examples/pubsub_metrics.zig` turns a Pub/Sub
subscriber's counts into metrics through a `Recorder`.

## The guides

| Guide | What's in it |
| --- | --- |
| [Writing](writing.md) | A write and its result, the rules production holds each series to, resources, descriptors, retries, limits |
| [Reading](reading.md) | Filters, aligning and reducing, paging, incomplete answers, cost |
| [Alerts](alerts.md) | The incidents open in the project, read only: their policy snapshots, the filter production really parses, what a real incident showed |
| [The Recorder](recorder.md) | Counters, gauges, histograms and observers written every interval, stopping, descriptors, stats |
| [Testing](testing.md) | An in-memory Cloud Monitoring for your own tests, held to production's answers (experimental) |

## The calls

| Call | What it does |
| --- | --- |
| `Client.write(series)` | One point to each of up to 200 series: a `WriteResult` says how many the server stored, and why it refused the rest |
| `Client.metric(type).create(config)`, `.get()`, `.delete()` | A metric's descriptor: its kind, value type, unit, description and labels |
| `Client.metric(type).read(options)` | One page of the metric's series, filtered, aligned and reduced |
| `Client.listMetrics(options)` | The project's descriptors, or those under a prefix |
| `Client.resourceType(name)`, `Client.listResourceTypes(options)` | The monitored resource types and their labels |
| `Client.listAlerts(options)`, `Client.getAlert(id)` | The alerting incidents open (or lately closed) in the project, read only |
| `Recorder` | Counters, gauges, histograms and observers, written every interval |

## Who is writing

Every point belongs to a monitored resource, which with the metric's
labels makes the series. `Resource` names the types that take a
program's own metrics, each with its required labels as fields:
`generic_task`, `generic_node`, `gce_instance`, `k8s_container`,
`k8s_pod`, `k8s_node` and `global`; `.other` takes any type with its
labels as given. `project_id` is never one: the server fills it in from
the request, and refused another project's.

**One writer per series.** Two processes that write the same metric,
labels and resource collide: their points come too close together or
out of order, and production refuses them. This is the most common
production failure in every Google exporter's issue tracker. Give each
process a resource of its own: a `generic_task` with
`Resource.randomTaskId`, taken once when the process starts. `global` is
shared by every writer in the project.

## Errors

| Error | When |
| --- | --- |
| `InvalidMetricType` | A metric type past 512 characters, with a character outside letters, digits and `._:-/`, or without a domain and a path |
| `InvalidLabel` | A label key that is not a letter, then letters, digits and `_`, past 100 bytes; a value past 1,024 bytes; more than 30 labels |
| `InvalidPoint` | An interval its kind does not allow, a string past 1,024 bytes, a distribution that does not add up, DELTA or STRING under `custom.googleapis.com/` |
| `InvalidResource` | A resource type or label the client will not send, a `project_id` among them |
| `TooManySeries`, `DuplicateSeries` | No series, more than 200, or one series twice in a write |
| `InvalidFilter`, `InvalidOptions` | A read's filter or aggregation that is always wrong |
| `NotFound` | A metric with no descriptor, or a read filtered on a label it does not have |
| `AlreadyExists` | A create of a descriptor that exists with another kind or value type |
| `InvalidArgument` | A write refused as a whole: a descriptor production would not create |

A write whose points the server judged is a `WriteResult`, not an error,
however many it refused. Reads and descriptor calls retry 5xx, 429 and
dropped connections with the client's `RetryPolicy`; writes follow
`write_retries` ([Writing](writing.md#retries)).

## What was measured

Cloud Monitoring has no emulator, so this module was measured in
production on 2026-10-18 before it was built on, and a production suite
holds the fake to production's outcome for each of 60 operations. What
that changed from Google's documents:

- **The floor between a series' points is 2.5 s**, not 5: a point 2.499 s
  after the last was refused and one 2.5 s after taken. The `Recorder`
  keeps 5 s anyway.
- **A metric type may be 512 characters**, not 200.
- **The alignment period is at least 10 s**, not 60.
- **Every refused point comes back in a summary at HTTP 400**, the
  stored ones kept: partial writes are the normal way writes fail.
- **NaN and the infinities are taken** as doubles.
- **Times are kept to the microsecond.**
- **A descriptor just created reads back 404 for about 2 s**, once for
  more than 15 s, and once 404 again after a 200; a write straight after
  the create was taken.
- **A point was readable 0.2 s after its write**, where Google says 3 to
  7 s.
- **A point sent twice is kept once**, and a cumulative total that falls
  under the same start is taken.
- **A filter's value escapes `"` and `\` with a backslash**; single
  quotes are refused.
- **A read of a metric without a unit gives the unit `{not_a_unit}`**;
  counted, `1`.

## Not here

The configuration plane: alert policies, notification channels, uptime
checks, groups, SLOs, snoozes and dashboards. PromQL and MQL queries.
Reads across an organization or a folder. Finding the resource from the
metadata server. OTLP to `telemetry.googleapis.com`.
