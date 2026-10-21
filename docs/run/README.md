[Docs](../README.md) › Run

# 🏃 Run

A client for Cloud Run's v2 API, read only: the services a project runs
and the revisions behind them, with their conditions, for a health
view's "recent revisions" widget and a trend chart's deploy markers;
and the jobs it runs, with their executions. Nothing here deploys,
routes traffic or deletes anything. **Experimental**: new in 0.48.0;
jobs, executions and operations are new in 0.54.0 and carry their own
marker.

```zig
const std = @import("std");
const auth = @import("auth");
const run = @import("run");

pub fn main(init: std.process.Init) !void {
    const arena = init.arena.allocator();
    const lookup = try auth.Lookup.fromEnv(init.environ_map, arena);
    var creds = try auth.findDefault(init.gpa, init.io, lookup, .{});
    defer creds.deinit();
    var client = try run.Client.init(init.gpa, init.io, .{
        .project_id = "my-project",
        .token_provider = creds.provider(),
    });
    defer client.deinit();
    var revisions = try client.listRevisions("us-central1", "-", .{});
    defer revisions.deinit();
    for (revisions.value.revisions) |revision| {
        if (!revision.ready()) warn(revision);
    }
}
```

## The calls

| Call | What it does |
| --- | --- |
| `Client.listLocations(options)` | One page of the locations services can live in, through v1's list on the same host: v2 has none (43 locations when measured) |
| `Client.listServices(location, options)` | One page of a location's services; the location may be `-`, every region at once, which production answers (though its documentation says otherwise) with `unreachable_regions` for the regions it could not ask |
| `Client.getService(location, id)`, `getServiceNamed(name)` | One service, by its parts or its full name; another project's name is refused before sending |
| `Client.listRevisions(location, service, options)` | One page of a service's revisions, newest first; the service may be `-`, every service in the location |
| `Client.getRevision(location, service, id)`, `getRevisionNamed(name)` | One revision |
| `Client.listJobs(location, options)` | One page of a region's jobs, newest first; production refuses `-` here, so the client does too, before sending |
| `Client.getJob(location, id)`, `getJobNamed(name)` | One job |
| `Client.listExecutions(location, job, options)` | One page of a job's executions, newest first; the job may be `-`, every job in the region |
| `Client.getExecution(location, job, id)`, `getExecutionNamed(name)` | One execution |
| `Client.getOperation(name)` | A long-running operation, by the full name a write's answer gives |

A `Service` carries its `uri` and `urls`, the latest ready and created
revision ids, `traffic` (what was asked) and `traffic_statuses` (what
the server serves, with a tag's own uri), its `conditions` and
`terminal_condition`, times, generations and `reconciling`. A
`Revision` carries its `create_time` (the deploy marker), generation,
`containers` with images pinned to their digests as production answers
them, `conditions` and the console's `log_uri`.

**`Service.ready()`** and **`Revision.ready()`** answer the health
view's question; `Revision.readyCondition()` carries the reason and
message. When a deploy fails, production writes the story in plain
words: the broken revision's `Ready` condition said "Image
'&lt;image&gt;' not found." with the service's terminal condition
`CONDITION_FAILED`, reason `REVISION_FAILED`, while
`latest_ready_revision` stayed on the last good revision.

## Jobs and executions

**Experimental** on their own, new in 0.54.0.

A `Job` carries its `latest_created_execution` (name, times and a
`status`), its `terminal_condition`, `execution_count`, and what each
execution runs: `task_count`, `parallelism`, `task_timeout_s`,
`max_retries`, `containers` and `service_account`, which production
answers with its defaults filled in. `Job.ready()` is the job's own
configuration, not its last run: a job stayed ready after a run failed.

An `Execution` carries its create, start and completion times, its task
counts (`running_count`, `succeeded_count`, `failed_count`,
`cancelled_count`, `retried_count`), its `conditions` and the console's
`log_uri`. The API has no status field for an execution, so
**`Execution.status()`** reads one from its conditions as production
showed them:

| Status | When |
| --- | --- |
| `.pending` | Made, its container not started: `Started` still reconciling |
| `.running` | `Started` succeeded, `Completed` not yet ended |
| `.cancelling` | A task already cancelled, `Completed` not yet ended |
| `.succeeded` | `Completed` succeeded |
| `.failed` | `Completed` failed, for a reason other than a cancel (`NON_ZERO_EXIT_CODE` for a task that exited 1) |
| `.cancelled` | `Completed` failed with reason `CANCELLED`, "Cancelled by user." |

`Execution.cancellable()` says whether production takes a cancel of it
as it stands: pending or running. `ExecutionStatus.ended()` says
whether nothing more will happen to it.

What production showed, on 2026-10-21 with Google's sample job image:

- **An execution took about 90 s to start** ("Started deployed
  execution in 1m27.38s."): a job that sleeps 2 s ended 100 s after
  its run. Two executions of one job may run at once.
- **An execution cancelled before it started never got a completion
  time** (watched for five minutes), so read `status()`, not
  `completion_time`, to know it has ended.
- A job nobody has lists no executions (`{}`), not a 404; a get is a
  404 in plain words ("Resource '<id>' of kind 'JOB' in region '<l>' in
  project '<p>' does not exist."). A region that does not exist is a
  permission refusal for jobs: "Permission denied on 'locations/<l>' (or
  it may not exist)".
- The job names its latest execution by its id alone; the client makes
  the full name.

## The scope

A client asks its token provider for one scope, `Options.scope`:
`.read_only` (`run.readonly`, the default, the narrowest every read
takes), `.read_write` (`run`) or `.cloud_platform`. A provider made from
a key file, workload identity or impersonation is fixed to the scope its
first token was minted for (`auth.Credentials.bindsScopes`), so a
program that reads with one client and writes with another gives each
its own credentials.

## What production showed

Measured on 2026-10-19 with a real service (the gated suite repeats
it):

- Deploys, updates and deletes answer **long-running operations**; the
  hello service's deploy was done in 6 s, and a failed deploy's
  operation completes with an `error` rather than hanging.
- **Revisions of a service nobody has are an empty page, not a 404**; a
  service nobody has is a 404 in plain words ("Resource '<id>' of kind
  'SERVICE' in region '<l>' in project '<p>' does not exist.").
- A location that is no region is a 400, "The request has errors".
- An empty list is `{}`. Revisions are named `<service>-0000N-<suffix>`.

In tests, `run.testing.FakeRun` holds locations, services and revisions
a test puts in: [Testing](testing.md). `examples/run_revisions.zig
--fake` draws the recent-revisions widget offline.
