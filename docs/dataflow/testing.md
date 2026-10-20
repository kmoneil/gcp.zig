[Docs](../README.md) › [Dataflow](README.md) › Testing

# Testing with the in-memory Dataflow

`dataflow.testing.FakeDataflow` is Dataflow in memory, behind
`Client.Options.transport`, for tests of code that reads jobs and stops
them: a health view's tests, say, or a console's cancel button, with no
network and no project. It answers the module's reads, its cancel and
its drain as production answered them when measured (experimental, as
the module is).

Nothing here launches a job, so the rest is the test's: `putLocation`,
`putJob`, `putMessage` and `putAutoscalingEvent` stand in for whoever
launched the pipeline, `setJobState` moves a job along as the service
would, and `setFailedLocations` for the regions an aggregated listing
names as unanswered.

<!-- snippet: tests/docs_examples.zig#dataflow-fake -->
```zig
test "the pipelines widget, a failed job called out with its error" {
    var fake: dataflow.testing.FakeDataflow = .init(std.testing.allocator, std.testing.io, .{ .project_id = "my-project" });
    defer fake.deinit();
    try fake.putLocation("us-central1");
    // The nightly batch that broke, standing in for whoever launched it.
    _ = try fake.putJob(.{
        .location = "us-central1",
        .id = "2026-10-20_07_09_34-8524524531325271694",
        .name = "nightly-wordcount",
        .current_state = .failed,
        .current_state_time = .{ .nanoseconds = 1_792_505_378 * std.time.ns_per_s },
    });
    try fake.putMessage(.{
        .job = "2026-10-20_07_09_34-8524524531325271694",
        .text = "The Dataflow service agent cannot access the worker service account.",
        .importance = .@"error",
    });

    var token: dataflow.StaticToken = .{ .token = "none" };
    var client = try dataflow.Client.init(std.testing.allocator, std.testing.io, .{
        .project_id = "my-project",
        .token_provider = token.provider(),
        .transport = fake.transport(),
    });
    defer client.deinit();
    // The widget's one call: every region's jobs.
    var jobs = try client.aggregatedJobs(.{ .filter = .all });
    defer jobs.deinit();
    try std.testing.expectEqual(1, jobs.value.jobs.len);
    const job = jobs.value.jobs[0];
    try std.testing.expect(job.failing());
    // Why it is red: the first error of the job's story.
    var story = try client.listMessages(job.location, job.id, .{ .minimum_importance = .@"error" });
    defer story.deinit();
    try std.testing.expect(std.mem.indexOf(u8, story.value.messages[0].text, "service agent") != null);
}
```

## Cancels and drains

A write the fake takes changes the job at once, as production's get
showed it right after; the end state is the test's to set, standing in
for the service (production took 240 s to end a cancel and 126 s a
drain):

<!-- snippet: tests/docs_examples.zig#dataflow-stop-fake -->
```zig
test "a confirmed drain, and the reads that watch the job end" {
    var fake: dataflow.testing.FakeDataflow = .init(std.testing.allocator, std.testing.io, .{ .project_id = "my-project" });
    defer fake.deinit();
    try fake.putLocation("us-central1");
    const id = try fake.putJob(.{
        .location = "us-central1",
        .id = "2026-10-20_15_21_25-1828704797262605315",
        .name = "orders-stream",
        .type = .streaming,
        .current_state = .running,
    });
    var token: dataflow.StaticToken = .{ .token = "none" };
    var client = try dataflow.Client.init(std.testing.allocator, std.testing.io, .{
        .project_id = "my-project",
        .token_provider = token.provider(),
        .transport = fake.transport(),
    });
    defer client.deinit();

    // The button: a running streaming job takes a drain.
    var before = try client.getJob("us-central1", id);
    defer before.deinit();
    try std.testing.expect(before.value.drainable());
    // The write answers nothing; a read shows it under way at once.
    try client.drainJob("us-central1", id);
    var during = try client.getJob("us-central1", id);
    defer during.deinit();
    try std.testing.expectEqual(.draining, during.value.current_state);
    try std.testing.expectEqual(.drained, during.value.requested_state);
    // The service ends it, which a test stands in for.
    try fake.setJobState(id, .drained, null);
    var after = try client.getJob("us-central1", id);
    defer after.deinit();
    try std.testing.expect(after.value.terminal());
    // An ended job refuses both, in production's words.
    try std.testing.expectError(error.FailedPrecondition, client.cancelJob("us-central1", id));
}
```

- A cancel of a running or draining job makes it `cancelling`, with
  `requested_state` `cancelled`; a drain of a running streaming job
  makes it `draining`, with `drained`. Both answer production's one
  field, `{"type":"JOB_TYPE_BATCH"}`, whatever the job.
- A repeat cancel while cancelling is taken and changes nothing; a
  repeat drain while draining the same. A cancel while draining is
  taken and wins.
- Each write taken adds production's line to the job's story, at
  BASIC: "Cancel request is committed for workflow job: <id>." (a
  repeat cancel adds another; a repeat drain adds none).
- `setJobState` to a terminal state takes `requested_state` away, as
  production's ended jobs carried none, and a list's summary never
  carries it.
- Refusals, in production's words minus its request ids: a pending
  job's cancel ("Job is not yet ready for canceling. Please retry in a
  few minutes."), a batch job's drain in any state ("Only streaming
  workflows can be drained."), an ended job's cancel naming the state
  it ended in (SUCCESS, CANCELLED, DRAINED, FAILED, or NOT_STARTED for
  one put in with a `provisioning_error`), an ended job's drain ("Job
  has terminated."), and a job nobody has ("Could not cancel workflow;
  user does not have sufficient permissions on project: <project>, or
  the job does not exist in the project."). A location nobody put
  reaches the default location's job, as a made-up region did.
- **501, naming what, where production's answer was not measured**: a
  drain of a pending or cancelling streaming job, a cancel of an
  updated job, and either write on a job queued, pausing, paused,
  stopped or cleaning up, states a template launch cannot reach. A
  batch job's drain is refused first whatever its state, as
  production's was. `Job.cancellable()` follows the documentation for
  those states, which lets any job not ended be cancelled.

## What it models

Each as production answered when measured on 2026-10-20:

- The aggregated list serves every location's jobs; the per-location
  list its own, and only it honors the `name` filter (the aggregated
  one accepts and ignores it). Lists answer summaries, without labels,
  stage states or `requested_state`, which only a get carries.
- Filters order as production did: active jobs first by newest
  creation, then terminated ones by newest termination; `ACTIVE` with
  nothing running is a bare `{}`. Pages walk with a token.
- **A location nobody put is served by the default location** rather
  than refused, as production answered a made-up region with
  us-central1's jobs. The default is `Options.default_location`,
  us-central1 unless set.
- Messages sort oldest first, filtered by the minimum importance; the
  autoscaling events come regardless of the filter, and `pageSize` is
  not honored here, exactly as production answered every message past
  a pageSize of 5.
- Refusals in production's words, minus the request id production
  prefixes: a job nobody has is 404 "Information about job <id> could
  not be found in our system. ..."; a filter outside the enum is 400
  with the field named; a request without a token is a 401. A job put
  in with a `provisioning_error` answers a get at `.all` with a 400
  FAILED_PRECONDITION carrying that text, as production answered the
  job that failed its launch.
- Faults a test asks for: `refuseNext`, `dropNext` and `loseNext`, as
  the other fakes have them.

`putJob`, `putMessage` and `putAutoscalingEvent` refuse, with nothing
kept, what production could not hold: a location or job nobody put, a
job id taken or malformed.

Not modelled, answered 501 with the reason: every other write
(creating, updating with a mask, pausing, launching templates),
metrics, snapshots, the legacy no-location paths, and another
project's paths.

A gated production suite (`tests/dataflow_gcp_integration.zig`,
`DATAFLOW_TEST=1`, a cent or two per run) launches a real `zigps-`
Word_Count template job, seeds the fake with everything production
lists, and holds the fake to production's answer for every read. The
writes have their own gate, `DATAFLOW_WRITES_TEST=1` (about 3 cents a
run): a batch job cancelled and a streaming job drained through the
client, every refusal on the way, every preview held byte for byte to
what was sent, and every write replayed on a fake kept in step with
production's states. A slow property holds the fake's cancels and
drains to a model of what production took and refused, in the
`slow-dataflow` nightly job.
