[Docs](../README.md) › [Dataflow](README.md) › Testing

# Testing with the in-memory Dataflow

`dataflow.testing.FakeDataflow` is Dataflow in memory, behind
`Client.Options.transport`, for tests of code that reads jobs: a health
view's tests, say, with no network and no project. It answers the
module's reads as production answered them when measured
(experimental, as the module is).

The API here is read only, so the fake's write side is the test's:
`putLocation`, `putJob`, `putMessage` and `putAutoscalingEvent` stand
in for whoever launched the pipeline, `setJobState` moves a job along
as the service would, and `setFailedLocations` for the regions an
aggregated listing names as unanswered.

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

## What it models

Each as production answered when measured on 2026-10-20:

- The aggregated list serves every location's jobs; the per-location
  list its own, and only it honors the `name` filter (the aggregated
  one accepts and ignores it). Lists answer summaries, without labels
  or stage states, which only a get carries.
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

Not modelled, answered 501 with the reason: writes of any kind
(creating, updating, cancelling, draining, launching templates),
metrics, snapshots, the legacy no-location paths, and another
project's paths.

A gated production suite (`tests/dataflow_gcp_integration.zig`,
`DATAFLOW_TEST=1`, a cent or two per run) launches a real `zigps-`
Word_Count template job, seeds the fake with everything production
lists, and holds the fake to production's answer for every read.
