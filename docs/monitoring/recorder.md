[Docs](../README.md) › [Monitoring](README.md) › The Recorder

# The Recorder

**On this page:** [Running one](#running-one) ·
[Instruments](#instruments) · [Observers](#observers) ·
[Each write](#each-write) · [Stopping](#stopping) ·
[Descriptors](#descriptors) · [Stats](#stats) · [Cost](#cost)

## Running one

A `Recorder` holds counters, gauges and histograms that any task
records into, and writes them every interval from a task of its own:

```zig
const task_id = monitoring.Resource.randomTaskId(io);
var recorder = try monitoring.Recorder.init(gpa, io, .{
    .client = .{ .project_id = "my-project", .token_provider = creds.provider() },
    .resource = .{ .generic_task = .{ .location = "us-central1", .namespace = "shop", .job = "api", .task_id = &task_id } },
});
defer recorder.deinit();
var running = try io.concurrent(monitoring.Recorder.run, .{&recorder});
defer {
    recorder.stop();
    running.await(io) catch {};
}
const shop = try ShopMetrics.declare(&recorder);
shop.taken("eu", 12.5); // from any task
```

`interval_ms` is 60 s by default and at least 5 s. Every series is
written each interval; at 60 s that keeps about 450 series inside the
free 150 MiB a month. `prefix`, `custom.googleapis.com/` by default, goes
before each instrument's name. A recorder must not be moved after
`init`.

## Instruments

<!-- snippet: tests/docs_examples.zig#mon-recorder -->
```zig
/// What a shop's API records: orders by region, the queue's depth, and
/// how long each request took.
const ShopMetrics = struct {
    orders: monitoring.Recorder.Counter,
    depth: monitoring.Recorder.Gauge,
    latency: monitoring.Recorder.Histogram,

    fn declare(recorder: *monitoring.Recorder) !ShopMetrics {
        return .{
            .orders = try recorder.counter(.{ .name = "shop/orders", .label_keys = &.{"region"}, .unit = "{order}", .description = "Orders taken" }),
            .depth = try recorder.gauge(.{ .name = "shop/queue_depth", .unit = "{message}" }, .int64),
            .latency = try recorder.histogram(.{ .name = "shop/latency", .unit = "ms" }, .{ .exponential = .{ .num_finite = 16, .growth_factor = 2, .scale = 1 } }),
        };
    }

    /// From any task, as each order is taken. Never fails or waits.
    fn taken(self: ShopMetrics, region: []const u8, ms: f64) void {
        self.orders.add(&.{region}, 1);
        self.latency.record(&.{}, ms);
    }
};
```

- **A counter** is cumulative: each write sends the total since the
  label set was first recorded, under that start time. A write that
  fails loses resolution, not counts: the next one carries the total.
- **A gauge** writes its last value at every write, so a chart has no
  gaps. One never set writes nothing.
- **A histogram** keeps its buckets, its count, and the exact mean and
  sum of squared deviations, where Google's exporters send 0 or an
  estimate. NaN and the infinities are dropped and counted.

An instrument and one set of label values is a series, made at its first
recording, up to `max_series` (10,000) across the recorder. Label values
are borrowed for the call, and copied once when a series is new.
Recording never fails and never waits on the network: what cannot be
kept, a series past the cap, the wrong number of label values, short
memory, is dropped, counted in `stats()`, and logged once per
instrument. The same instrument declared again is the one declared
already.

## Observers

An observer is read at every write, on `run`'s task and outside the
recorder's lock, for values another part of the program already keeps:

<!-- snippet: tests/docs_examples.zig#mon-observer -->
```zig
/// Counts another part of the program already keeps, read at each write.
const Totals = struct {
    sent: std.atomic.Value(u64) = .init(0),

    fn observer(self: *Totals) monitoring.Recorder.Observer {
        return .{ .context = self, .report = report };
    }

    fn report(context: *anyopaque, into: *monitoring.Recorder.Report) void {
        const self: *Totals = @ptrCast(@alignCast(context));
        into.int64(&.{}, @intCast(self.sent.load(.monotonic)));
    }
};
```

```zig
var totals: Totals = .{};
try recorder.observe(.{ .name = "shop/sent", .unit = "{message}" }, .cumulative, null, totals.observer());
```

A cumulative observer's series start at the start given, or when
`observe` was called; a total that falls is taken as a reset, and the
series starts again 1 ms after its last end. An observer reports int64s
or doubles, not both. `examples/pubsub_metrics.zig` turns a Pub/Sub
subscriber's `stats()` into metrics this way.

## Each write

A write takes every series that is due, under the lock, and sends
outside it, at most 200 series a request, one request after another. A
failed request does not stop the others. Nothing is retried beyond the
client's write rule, and nothing is queued: an outage leaves no backlog
of points the server would refuse as too old. A write that outlasts the
interval delays the next, and missed ticks are not made up.

A series is due when it was written 5 s or more before, by the
recorder's own times, or never. If the wall clock steps back, a series
waits until the clock passes its last end. A cumulative series first
written in the millisecond it was first recorded starts 1 ms earlier,
so its end is never in the future.

`flush` writes what is due now, for a program with no task to spare; it
must not be called while `run` runs.

## Stopping

`stop` ends `run` after one last write. A series written less than 5 s
before waits out the rest of the 5 s (`last_write = .wait`, at most 5 s,
which fits Cloud Run's 10 s after SIGTERM) or is left out (`.skip`).
After the clock stepped back, 5 s may not be enough, and such a series is
left out either way.

## Descriptors

With `descriptors = .create_if_missing` (the default) each instrument's
descriptor is read before its first write, and created when missing,
once, so its unit, description and labels reach the console:

- **Another kind or value type** than the instrument's: the server would
  refuse every point, so the instrument's series are not written,
  `descriptor_failures` counts it, and the log says both sides.
- **A create refused for good**, a 403 say: not asked again, and the
  first write creates the descriptor, with string labels and no unit.
- **A transient failure**: asked again at the next write; the
  instrument's series wait until then.

A unit or a description that differs is left alone: the recorder never
rewrites a descriptor. `.auto` never calls the descriptor API.

## Stats

`stats()` counts points written, points the server refused in a
summary (none, with one writer per series), points in requests that
failed as a whole, requests, recordings dropped, series, and descriptors
made or failed.

## Cost

Writing a program's own metrics is free within 150 MiB a month. A
series written every 60 s costs about 0.33 MiB a month, so about 450
scalar series fit. Series are never forgotten in this version: each is
written every interval until `deinit`.
