[Docs](../README.md) › [Scheduler](README.md) › Testing

# Testing with the in-memory Cloud Scheduler

`scheduler.testing.FakeScheduler` is Cloud Scheduler in memory, behind
`Client.Options.transport`, for tests of code that reads jobs and runs,
pauses and resumes them: a health view's tests, or a console's
confirmed writes, with no network and no project. It answers the
module's three reads and three writes as production answered them when
measured.

`putLocation` and `putJob` stand in for whoever made the jobs, and
`setLastAttempt` for Scheduler running one on schedule. A job put in
without an attempt answers production's birth state, `status` code -1,
which the client reads back as `last_attempt == null`.

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

## Runs, pauses and resumes

A run answers the job as it stood, as production's does; its attempt
starts then and shows once the fake's clock has passed the outcome's
`after_ms`. `setRunOutcome` says what the job's runs come to (a gRPC
code, 0 for success, and how long they take to show), standing in for
the target; `setNextRun` gives the next run a resume brings back, since
the fake has no cron engine:

<!-- snippet: tests/docs_examples.zig#sched-run-fake -->
```zig
test "a confirmed run, and the poll that finds its attempt" {
    var clock: scheduler.testing.FakeClock = .{ .now_ns = 1_792_436_660 * std.time.ns_per_s };
    var fake: scheduler.testing.FakeScheduler = .init(std.testing.allocator, clock.io(), .{ .project_id = "my-project" });
    defer fake.deinit();
    try fake.putLocation("us-central1");
    const name = try fake.putJob(.{
        .location = "us-central1",
        .id = "nightly-export",
        .schedule = "0 3 * * *",
        .target = .{ .http = .{ .uri = "https://example.com/export", .method = .post } },
    });
    // The target answers 404, which Scheduler records as code 5, six
    // seconds after the run.
    try fake.setRunOutcome(name, .{ .code = 5, .after_ms = 6_000 });

    var token: scheduler.StaticToken = .{ .token = "none" };
    var client = try scheduler.Client.init(std.testing.allocator, clock.io(), .{
        .project_id = "my-project",
        .token_provider = token.provider(),
        .transport = fake.transport(),
    });
    defer client.deinit();
    var ran = try client.runJob("us-central1", "nightly-export");
    defer ran.deinit();
    try std.testing.expectEqual(null, ran.value.last_attempt);

    // The console reads again after five seconds: not yet.
    clock.now_ns += 5 * std.time.ns_per_s;
    var early = try client.getJob("us-central1", "nightly-export");
    defer early.deinit();
    try std.testing.expectEqual(null, early.value.last_attempt);

    // Two seconds later it has shown.
    clock.now_ns += 2 * std.time.ns_per_s;
    var landed = try client.getJob("us-central1", "nightly-export");
    defer landed.deinit();
    try std.testing.expectEqual(5, landed.value.last_attempt.?.code);
    try std.testing.expect(landed.value.failing());
}
```

What the writes do, each as measured on 2026-10-20:

- A run of a paused job is production's 400, "spanner.RunInTransaction:
  generic::failed_precondition: Job.state must be ENABLED for RunJob.",
  and starts nothing. A run while an attempt is still to show adds no
  second one, as two quick runs showed one attempt.
- A success shows as `status: {}`, as production writes code 0.
- A pause makes the job paused, takes away its next run, clears its
  last attempt and stamps `userUpdateTime`. A resume brings the next
  run back and stamps it; the cleared attempt stays cleared. A repeated
  pause, or a resume of an enabled job, changes nothing.
- Production's race: an attempt still to show when its job is paused
  shows its start and a next run of the same moment, never its result,
  and a resume then answers `status: {}`, a success no one recorded.
- `pendingAttempts` counts attempts still to show, for a test that
  waits on them.
- Not modelled: the seconds of jitter production adds to the next run
  after a job's first attempt, and the retries of a failed attempt.
  A run, pause or resume of a `disabled` or `update_failed` job is
  answered 501 with the reason: no one can put a job in either state
  on purpose, so production's answer was never measured.

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

Not modelled, answered 501 with the reason: creates, patches and
deletes, operations, CMEK, and another project's paths.

A gated production suite (`tests/scheduler_gcp_integration.zig`,
`SCHEDULER_TEST=1`) makes real `zigps-` jobs, runs them for real failed
attempts, seeds the fake with everything production lists, and holds
the fake to production's answer for every read; its first run agreed on
all of them. Its writes test runs, pauses and resumes two more jobs
through the client, holds each request to its preview byte for byte,
and replays every step on a fake seeded from production, each attempt
given the code production's showed.
