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
  - a cumulative start moved earlier.

  A reset, the last point sent again, and a falling total are taken.
  Times are kept to the microsecond.
- **Requests refused whole**: no series or more than 200, another
  project's `project_id`, a descriptor production would not create.
- **Descriptors**: created (again with the same shape, or 409 with
  another), read, listed by prefix and in pages, deleted with their
  points. A first write creates one; a write with a new label adds it.
- **Reads**:
  - its own reading of the filter the client writes, labels it does not know refused as production refused them;
  - (start, end], newest first;
  - the gauge aligners and reducers min, max, mean, sum and count with group-by fields, periods ending at the read's end;
  - pages by points with series split across them, and HEADERS.
- **The resource types** the `Resource` union names.
- **Faults**: `refuseNext`, `refuseNextWithDelay`, `dropNext`, and
  `loseNext`, which serves a call and answers it with an error, as a 504
  that stored a write.

A production suite runs one script of 60 operations against production
and the fake, and holds the fake to every outcome.

## Where it differs

- Its messages give times in UTC, where production wrote US Pacific.
- A descriptor just created reads back at once, where production
  answered 404 for about 2 s.
- Only generic_task's resource type text is production's.

## What it does not model

It says so: 501, `error.Unimplemented`, with a message that begins
`fake:`. Among these:

- a cumulative start moved later but inside the series' last interval
  (production took one, and the earlier point vanished from reads);
- the rate, delta and percentile aligners, aligning a cumulative
  metric, a second aggregation;
- filters of another shape (OR, `one_of`), other projects, and the
  resource types `.other` names;
- distribution rules production was not asked about.
