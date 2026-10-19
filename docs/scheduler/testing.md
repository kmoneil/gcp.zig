[Docs](../README.md) › [Scheduler](README.md) › Testing

# Testing with the in-memory Cloud Scheduler

`scheduler.testing.FakeScheduler` is Cloud Scheduler in memory, behind
`Client.Options.transport`, for tests of code that reads jobs: a health
view's tests, say, with no network and no project. It answers the
module's three reads as production answered them when measured
(experimental, as the module is).

The API here is read only, so the fake's write side is the test's:
`putLocation` and `putJob` stand in for whoever made the jobs, and
`setLastAttempt` for Scheduler running one. A job put in without an
attempt answers production's birth state, `status` code -1, which the
client reads back as `last_attempt == null`.

<!-- snippet: tests/docs_examples.zig#sched-fake -->
```zig
test "the failing jobs, as a health view draws them" {
    var fake: scheduler.testing.FakeScheduler = .init(std.testing.allocator, std.testing.io, .{ .project_id = "my-project" });
    defer fake.deinit();
    try fake.putLocation("us-central1");
    // The nightly export, standing in for whoever created it; the fake
    // assigns the attempt as Scheduler running it would.
    const name = try fake.putJob(.{
        .location = "us-central1",
        .id = "nightly-export",
        .schedule = "0 3 * * *",
        .target = .{ .http = .{ .uri = "https://example.com/export", .method = .post } },
    });
    try fake.setLastAttempt(name, 14, "", .{ .nanoseconds = 1_792_436_660 * std.time.ns_per_s });

    var token: scheduler.StaticToken = .{ .token = "none" };
    var client = try scheduler.Client.init(std.testing.allocator, std.testing.io, .{
        .project_id = "my-project",
        .token_provider = token.provider(),
        .transport = fake.transport(),
    });
    defer client.deinit();
    var jobs = try client.listJobs("us-central1", .{});
    defer jobs.deinit();
    try std.testing.expectEqual(1, jobs.value.jobs.len);
    const job = jobs.value.jobs[0];
    // The widget's question, answered in one place.
    try std.testing.expect(job.failing());
    try std.testing.expectEqual(14, job.last_attempt.?.code);
}
```

## What it models

Each as production answered when measured on 2026-10-19:

- A job always answers a `status`: code -1 before any attempt, as a job
  is born; the real code after `setLastAttempt` or a `PutJob` with one.
- Lists sort by name and page as the document says: the default page is
  the maximum, 500, and `pageSize` over 500 is production's 400 in its
  words ("ListJobsRequest.pageSize must be less than or equal to 500").
  An empty location's list is `{}`.
- Refusals in production's words: a job nobody has is 404 "Job not
  found."; a location nobody put is 400 "Location '<l>' is not a valid
  location. Use ListLocations to list valid locations."; a request
  without a token is a 401.
- Faults a test asks for: `refuseNext`, `dropNext` and `loseNext`, as
  the other fakes have them.

`putJob` refuses, with nothing kept, what production could not hold: a
location nobody put, an id taken or malformed, a state outside the four
real ones, a last attempt without its time or a time without its
attempt, a target of `.unknown`.

Not modelled, answered 501 with the reason: writes of any kind (create,
patch, delete, run, pause, resume: production cleared a paused job's
next run and its last attempt, so a test puts a paused job in the shape
it wants), operations, CMEK, and another project's paths.

A gated production suite (`tests/scheduler_gcp_integration.zig`,
`SCHEDULER_TEST=1`) makes real `zigps-` jobs, runs them for real failed
attempts, seeds the fake with everything production lists, and holds
the fake to production's answer for every read; its first run agreed on
all of them.
