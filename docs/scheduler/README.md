[Docs](../README.md) › Scheduler

# ⏰ Scheduler

A client for Cloud Scheduler's v1 API: the jobs a project schedules,
with their state, target and last attempt, for a health view that shows
the failing ones; and three writes a console confirms before sending,
[run now, pause and resume](#run-now-pause-and-resume), each with a twin
that builds its exact request without sending it. Nothing here creates,
updates or deletes a job.

```zig
const std = @import("std");
const auth = @import("auth");
const scheduler = @import("scheduler");

pub fn main(init: std.process.Init) !void {
    const arena = init.arena.allocator();
    const lookup = try auth.Lookup.fromEnv(init.environ_map, arena);
    var creds = try auth.findDefault(init.gpa, init.io, lookup, .{});
    defer creds.deinit();
    var client = try scheduler.Client.init(init.gpa, init.io, .{
        .project_id = "my-project",
        .token_provider = creds.provider(),
    });
    defer client.deinit();
    var jobs = try client.listJobs("us-central1", .{});
    defer jobs.deinit();
    for (jobs.value.jobs) |job| {
        if (job.failing()) warn(job);
    }
}
```

## The calls

| Call | What it does |
| --- | --- |
| `Client.listLocations(options)` | One page of the locations jobs can live under; jobs are listed per location, so a reader starts here |
| `Client.listJobs(location, options)` | One page of a location's jobs; the server's page maximum and default are both 500, and more is refused |
| `Client.getJob(location, id)`, `Client.getJobNamed(name)` | One job, by its parts or its full `projects/P/locations/L/jobs/J` name; another project's name is refused before sending |
| `Client.runJob(location, id)` | Dispatches the job now and answers it as it stood; the attempt shows seconds later. Never sent twice once it may have left |
| `Client.pauseJob(location, id)`, `Client.resumeJob(location, id)` | Stops the job's schedule, or starts it again; each answers the job as it then stands |
| `Client.runJobRequest`, `pauseJobRequest`, `resumeJobRequest` | The exact request each write sends, built without sending it, for a confirmation |

A `Job` carries its cron `schedule` and `time_zone`, `state` (enabled,
paused, disabled, or `update_failed`, Scheduler's own trouble state),
the last attempt's `google.rpc.Status` and time, the next run
(`schedule_time`, which a paused job loses), the retry settings, and
its `target`: HTTP (uri, method, headers, body, and the OAuth or OIDC
token it authenticates with), Pub/Sub (topic, data, attributes) or App
Engine, bodies decoded from the wire's base64.

**`Job.failing()`** answers the health view's question in one place:
true when the job could not be updated, or its last attempt failed.

## The scope

Every call asks its token provider for `cloud-platform`: Cloud
Scheduler defines no narrower OAuth scope, unlike the other modules'
APIs, so there is no read-only scope to give it.

## Paging

The page token production answers is opaque and "valid for only 2
hours". Its documentation warns that fewer jobs than requested can come
back even when more exist, so walk `next_page_token` rather than
counting. A `page_size` over 500 is refused before sending, as the
server refuses it ("ListJobsRequest.pageSize must be less than or equal
to 500", not coerced).

## What production showed

Measured on 2026-10-19 with real jobs (the gated suite repeats it):

- **A job is born with `status: {"code": -1}`**, a sentinel no gRPC
  code names, before any attempt: the client decodes that as
  `last_attempt == null`, not a failure.
- A `:run` on an HTTP target whose host did not resolve showed its
  failed attempt **6 s** later, `code 2`; a Pub/Sub target on a topic
  nobody has, `code 5` after 16 s. Neither carried a message.
- Pausing a job removes its `scheduleTime`.
- An empty list is `{}`; a list in a location that does not exist is a
  400, not a 404 ("Location 'us-fake1' is not a valid location...").
- `locations.list` answered every public region (34): no App Engine
  tie.
- The server fills defaults in on create: a `User-Agent` header, a
  `Content-Type` when a body is set, retry backoffs and a 180 s attempt
  deadline for HTTP targets.

## Run now, pause and resume

Each write is a `POST` to the job's name with `:run`, `:pause` or
`:resume` and the empty message `{}`, and answers the job. A console
that shows the user what it is about to send asks the twin first:

<!-- snippet: tests/docs_examples.zig#sched-confirm -->
```zig
test "the exact request a run would send, for the user to confirm" {
    var fake: scheduler.testing.FakeScheduler = .init(std.testing.allocator, std.testing.io, .{ .project_id = "my-project" });
    defer fake.deinit();
    var token: scheduler.StaticToken = .{ .token = "none" };
    var client = try scheduler.Client.init(std.testing.allocator, std.testing.io, .{
        .project_id = "my-project",
        .token_provider = token.provider(),
        .transport = fake.transport(),
    });
    defer client.deinit();
    // Built, not sent: what the confirmation shows.
    var request = try client.runJobRequest("us-central1", "nightly-export");
    defer request.deinit();
    try std.testing.expectEqual(.POST, request.value.method);
    try std.testing.expectEqualStrings(
        "https://cloudscheduler.googleapis.com/v1/projects/my-project/locations/us-central1/jobs/nightly-export:run",
        request.value.url,
    );
    try std.testing.expectEqualStrings("{}", request.value.body);
    try std.testing.expectEqual(0, fake.callCount());
}
```

The twin runs the same checks with the same errors, and builds the URL
and body the same way, so what the user confirmed is byte for byte what
`runJob` sends. Credentials and other headers are not part of it.

### What each repeats

- **A run is never sent twice once it may have left.** Every run that
  lands dispatches the job again, so only a refused connection or a
  failed name lookup, which never left, is retried. Any other failure
  comes back as an error: whether the job ran is for a read of the job,
  or the target's own logs, to say. Google's own client libraries do
  not retry a run at all.
- **A pause and a resume are retried as the reads are.** Production
  answers a repeat with 200 and changes nothing: pausing a paused job
  and resuming an enabled one are no refusal, whatever Google's
  reference says.
- **A run of a paused job is refused**: `error.FailedPrecondition`,
  "Job.state must be ENABLED for RunJob."

### What a run comes to

Measured on 2026-10-20 over 18 runs and six kinds of target:

- The run answers in under a second with the job **as it stood**: the
  same `status`, `last_attempt_time` and `user_update_time`.
- The attempt **starts** about 1.3 s after the run was sent; that is
  `last_attempt_time` ("the time the last job attempt started").
- Its result **shows** in a read 3.4 to 14.9 s after the run was sent,
  6 s in the middle. Reading the job again about 5 s after the run,
  then every few seconds until `last_attempt_time` moves, finds it.
- A success reads `status: {}`, so `last_attempt.code` is 0. An HTTP
  404 was code 5 (NOT_FOUND); a host that does not resolve, or a port
  that refuses, code 2 (UNKNOWN); a Pub/Sub topic nobody has, code 5.
  **No attempt carried a message**, so the code is all there is.
- A second run sent while the first was still being attempted (at once,
  or 3 s later) showed no second attempt.
- With `retryCount` 1, the failed attempt's retry did not show within
  45 s.
- After a job's first run, its next `schedule_time` gains a few seconds
  of jitter.

### What a pause and a resume do

- A pause makes the job `paused`, takes away its next run and **clears
  its last attempt**: a read then answers it as never attempted.
- A resume makes it `enabled` and brings the next run back at the next
  cron tick; the attempt the pause cleared stays cleared.
- One race reads wrong: **a run sent just before a pause can still
  start after it**. The paused job then shows that attempt's
  `last_attempt_time` and a `schedule_time` of the same moment, with no
  result, and a resume afterwards answers `status: {}`, which decodes
  as a successful attempt though none was recorded.

### Permissions

The scope is `cloud-platform`, as for the reads; a token for another
scope is refused, 403 "Request had insufficient authentication
scopes." IAM asks `cloudscheduler.jobs.run` for a run,
`cloudscheduler.jobs.pause` for a pause and `cloudscheduler.jobs.enable`
for a resume. `roles/cloudscheduler.admin` holds all three.
`roles/cloudscheduler.jobRunner` holds the run alone, and not
`jobs.get` or `jobs.list`: a runner can run a job it cannot read back,
except through the run's own answer.

In tests, `scheduler.testing.FakeScheduler` holds locations and jobs a
test puts in, and takes the three writes as production does:
[Testing](testing.md). `examples/scheduler_jobs.zig --fake` draws the
failing-jobs widget offline, and `examples/scheduler_run.zig --fake`
shows a run's request, sends it with `--yes`, and reads the job until
its attempt shows.
