[Docs](../README.md) › [Monitoring](README.md) › Reading

# Reading

**On this page:** [A read](#a-read) · [Filters](#filters) ·
[Aligning and reducing](#aligning-and-reducing) · [Pages](#pages) ·
[Incomplete answers](#incomplete-answers) · [Cost](#cost)

## A read

`Metric.read` reads one metric's series, a page at a time: points in
(start, end], newest first. `end` defaults to now and `start` to `end`,
which reads the instant at the end.

<!-- snippet: tests/docs_examples.zig#mon-read -->
```zig
/// The busiest queue's highest depth in each minute of the last hour,
/// summed over every task: one point per minute, newest first.
fn depthByMinute(client: *monitoring.Client, now: std.Io.Timestamp) !monitoring.Owned(monitoring.SeriesPage) {
    return client.metric("custom.googleapis.com/shop/queue_depth").read(.{
        .start = .{ .nanoseconds = now.nanoseconds - std.time.ns_per_hour },
        .end = now,
        .filter = .{ .metric_labels = &.{.{ .key = "queue", .value = "orders" }} },
        .aggregation = .{ .alignment_period_s = 60, .aligner = .max, .reducer = .sum },
    });
}
```

Each `Series` has its metric and resource labels, `project_id` among the
resource's, its kind and value type, and its points. A point's value is
null when it is one this library does not read, such as Google's money
metrics. A type with no descriptor is `error.NotFound`. Points were
readable 0.2 s after their write when measured, where Google says 3 to
7 s.

## Filters

A `Filter` narrows the series: metric label matches, a resource type,
resource label matches, all of which must hold. A match is `.equals`,
`.not_equals`, `.starts_with`, `.ends_with` or `.has_substring`. Values
are quoted with their `"` and `\` escaped, as production matched them.
`raw` is appended with AND for what the parts do not say, such as
`metric.labels.code = one_of("500", "503")`; in Cloud Monitoring's
filters OR binds tighter than AND.

A filter on a metric label the descriptor does not have is
`error.NotFound`, and on a resource label no resource type has,
`error.InvalidArgument`. A label that exists but matches nothing reads
no series.

## Aligning and reducing

An `Aggregation` turns each series' points into one per alignment
period, then can reduce the series to fewer:

- `alignment_period_s`: at least 10 (production refused 9; Google
  documents 60). Periods end at the read's end and every period before
  it, each holding the points in (its end minus the period, its end]: a
  point on a period's start belongs to the period before, as production
  showed. Each aligned point is at its period's end.
- `aligner`: `.max`, `.mean`, `.rate` and the rest of `common.proto`'s.
  A cumulative metric needs `.delta` or `.rate` before it is reduced.
- `reducer`: combines the aligned series, keeping apart those that
  differ in the `group_by` fields, such as `"metric.labels.region"` or
  `"resource.labels.zone"`. A reduced series has only the grouped labels.

`secondary_aggregation` applies after the first. The client refuses only
what is always wrong: a reducer without an aligner, an aligner without a
period, a period under 10 s, a second aggregation without a first.
Which aligner suits which kind of metric is the server's to say.

## Pages

With `.full`, a page holds at most `page_size` points, 100,000 by
default, so **one series can come on several pages**, the same series on
each: production's did with a page of one point. With `.headers` a page
holds series without their points. Pass `next_page_token` back for the
next page, with the same options; a token lasts 24 hours.

## Incomplete answers

A read can come back with HTTP 200 and still be missing part of the
answer: `execution_errors` and `unreachable_regions` say so, and
`SeriesPage.incomplete()` is the check.

## Cost

Since 2025-10-02 reads are billed per series returned, at least one per
call, after a free million a month. Descriptor and resource type reads
are free, and so are writes, within 150 MiB of a program's own metrics a
month.
