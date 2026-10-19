[Docs](../README.md) › [Monitoring](README.md) › Writing

# Writing

**On this page:** [A write and its result](#a-write-and-its-result) ·
[The rules for each series](#the-rules-for-each-series) ·
[Kinds and values](#kinds-and-values) · [Descriptors](#descriptors) ·
[Retries](#retries) · [Limits](#limits)

## A write and its result

`Client.write` sends one point to each of 1 to 200 series in one
request:

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

Every series is checked before anything is sent, and none is sent if one
fails: the error says which kind of check, `Diagnostics` which series
and why. The same series twice in one write is `error.DuplicateSeries`.

When the server judges the points, the `WriteResult` says how many it
stored (`written`) and why it refused the rest (`refused`, by status):

- `error.FailedPrecondition`: too soon after the series' last point.
- `error.InvalidArgument`: out of order, more than 5 minutes ahead or
  25h10s back, a kind or value type the descriptor does not take, a
  resource without its labels or in a location that is not one, and the
  rest.

Production answers any refused point with HTTP 400 and keeps the others,
so a 400 is a result, `ok()` is the check, and `message` names the first
series refused. A refusal of the whole request is an error: a DELTA or
STRING metric under `custom.googleapis.com/`, `workload.googleapis.com/`
or `external.googleapis.com/`, which production will not create; one of
Google's own metrics, which production refuses with 403; credentials; or
the network.

## The rules for each series

The server holds each series to one point at a time, and no client check
can see another writer's points:

- **One writer per series.** Two processes writing the same metric,
  labels and resource collide. Give each its own resource
  ([Who is writing](README.md#who-is-writing)).
- **A point at least 2.5 s after the series' last**, by end time.
  Google documents 5 s, which is safe; production refused 2.499 s and
  took 2.5 s when measured. The last point sent again as it was is taken
  and kept once; with another value it is too soon after itself.
- **End times only go forward**: an older one is out of order.
- **A cumulative series keeps its start time** until its total starts
  over. A start moved earlier is refused; a reset starts 1 ms or more
  after the series' last end. A total that falls under the same start
  was taken.
- **No more than 5 minutes ahead, or 25h10s back**, by the server's clock.
  The client does not check end times against this machine's clock: a
  skewed clock would refuse good points.

## Kinds and values

| Kind | `start` | Under `custom.googleapis.com/` |
| --- | --- | --- |
| `.gauge` | null, or the end | yes |
| `.cumulative` | the series' start, before the end | yes |
| `.delta` | the interval's start, before the end | no |

Values are `bool`, `int64`, `double` (NaN and the infinities included,
written as `"NaN"`, `"Infinity"` and `"-Infinity"`), `string` (not under
`custom.googleapis.com/`, at most 1,024 bytes) and `distribution`:
bucket counts in an explicit, linear or exponential layout, with their
count, mean and sum of squared deviations. Bucket 0 is underflow and the
last is overflow; trailing empty buckets may be left off, and the counts
must add up to the count.

## Descriptors

A metric's descriptor says its kind, value type, unit, description and
labels. The first write of a new metric type creates one, with string
labels and no description, and a later write with a new label adds it.
Create one first for a unit, a description, or a label of another type:

```zig
var made = try client.metric("custom.googleapis.com/shop/orders").create(.{
    .kind = .cumulative,
    .value_type = .int64,
    .unit = "{order}",
    .description = "Orders taken",
    .labels = &.{ .{ .key = "region" }, .{ .key = "paid", .value_type = .bool } },
});
defer made.deinit();
```

A create of an existing descriptor with the same kind and value type
answers it; with another, `error.AlreadyExists`. A descriptor just
created read back 404 for about 2 s when measured, once for more than
15 s, and once 404 again after a 200; a write straight after the create
was taken. Deleting a
descriptor makes its data unreadable, and a later write creates it
again.

## Retries

A write can be stored before it fails, so Google's own clients never
retry one. `Options.write_retries`:

- `.unsent_only` (the default): only a failure before the request left,
  a refused connection or a name lookup that failed.
- `.transient`: also 429, 500, 503 and 504, and a timed-out or dropped
  connection. Production kept a point sent twice once, so a retry of the
  same request is harmless to what was stored. In five runs of the
  production suite, production once answered a write with a bare 500
  where the other runs gave its summary.

A summary is never retried: the server judged each point.

## Limits

| Limit | Value | The client |
| --- | --- | --- |
| Series per write | 200 | `error.TooManySeries` |
| Points per series per write | 1 | the type holds one |
| Metric type | 512 characters, letters, digits and `._:-/` | `error.InvalidMetricType` |
| Label key | a letter, then letters, digits and `_`, 100 bytes | `error.InvalidLabel` |
| Label value | 1,024 bytes | `error.InvalidLabel` |
| Labels per metric | 30 | `error.InvalidLabel` |
| String point | 1,024 bytes | `error.InvalidPoint` |
| Distribution buckets | 200 | `error.InvalidPoint` |
| Descriptors per project | 10,000 under `custom.googleapis.com/` | the server's |
| Active series | 200,000 per monitored resource | the server's |
