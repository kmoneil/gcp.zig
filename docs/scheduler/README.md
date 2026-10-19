[Docs](../README.md) › Scheduler

# ⏰ Scheduler

A client for Cloud Scheduler's v1 API, read only: the jobs a project
schedules, with their state, target and last attempt, for a health view
that shows the failing ones. Nothing here creates, changes, runs or
deletes a job. **Experimental**: new in 0.47.0.

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

In tests, `scheduler.testing.FakeScheduler` holds locations and jobs a
test puts in: [Testing](testing.md). `examples/scheduler_jobs.zig
--fake` draws the failing-jobs widget offline.
