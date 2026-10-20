[Docs](../README.md) › Dataflow

# 🌊 Dataflow

A client for Dataflow's v1b3 API: the jobs a project runs, across every
region in one call or one region at a time, with their states and their
error messages, for a health view's pipelines widget, and two writes a
console confirms first: [cancelling a job and draining a streaming
one](#cancel-and-drain). Nothing here creates or updates a job in any
other way, and nothing launches a template. **Experimental**: new in
0.50.0.

```zig
const std = @import("std");
const auth = @import("auth");
const dataflow = @import("dataflow");

pub fn main(init: std.process.Init) !void {
    const arena = init.arena.allocator();
    const lookup = try auth.Lookup.fromEnv(init.environ_map, arena);
    var creds = try auth.findDefault(init.gpa, init.io, lookup, .{});
    defer creds.deinit();
    var client = try dataflow.Client.init(init.gpa, init.io, .{
        .project_id = "my-project",
        .token_provider = creds.provider(),
    });
    defer client.deinit();
    var jobs = try client.aggregatedJobs(.{ .filter = .all });
    defer jobs.deinit();
    for (jobs.value.jobs) |job| {
        if (job.failing()) warn(job);
    }
}
```

## The calls

| Call | What it does |
| --- | --- |
| `Client.aggregatedJobs(options)` | One page of every region's jobs: the widget's one call. Each job carries the `location` a get needs, and `failed_locations` names any region that did not answer, without which a partial page looks complete |
| `Client.listJobs(location, options)` | One page of a region's jobs; the only list that filters by `name` (the aggregated list accepts and ignores one, as its documentation says) |
| `Client.getJob(location, id)` | One job, as the summary every list answers, plus the labels and stage states the lists leave out |
| `Client.getJobView(location, id, view)` | One job at a chosen view: `.description` adds the pipeline description, `.all` the steps |
| `Client.listMessages(location, id, options)` | One page of a job's story; `minimum_importance = .@"error"` is "why is it red", and the autoscaling events come regardless of the filter |
| `Client.cancelJob(location, id)` | Asks the service to cancel the job, batch or streaming; answers nothing, so read the job to watch it stop ([Cancel and drain](#cancel-and-drain)) |
| `Client.drainJob(location, id)` | Asks a streaming job to drain: stop pulling, finish what is in flight, end drained |
| `Client.cancelJobRequest(location, id)`, `drainJobRequest` | The exact request each would send, built without sending it, for a confirmation |

A `Job` carries its service-assigned `id`, `name`, `location`, `type`
(batch or streaming), `current_state` with its time, `requested_state`
(what a cancel or a drain asked for, on a get while it is under way),
`create_time`, `start_time`, `labels` and `stage_states`.
**`Job.terminal()`** is the five states the API labels terminal (done,
failed, cancelled, updated, drained) and **`Job.failing()`** is the
widget's red. **`Job.cancellable()`** and **`Job.drainable()`** say
whether production takes a cancel or a drain of the job as it stands.

## The scope

Every call asks its token provider for `cloud-platform`: v1b3 has no
read-only scope (the only other one is `compute`, no narrower). What a
token may read is IAM's to decide, through `dataflow.jobs.list`,
`dataflow.jobs.get` and `dataflow.messages.list`; Dataflow Viewer
carries all three. The two writes take `dataflow.jobs.cancel`, which
Viewer does not carry ([Permissions](#permissions)).

## What production showed

Measured on 2026-10-20 with two real Word_Count template runs (the
gated suite repeats one):

- A one-worker Word_Count went PENDING at launch, RUNNING at 30 s and
  **DONE at 244 s**; `stageStates` appear from RUNNING on.
- **Lists answer summaries**: no labels and no stage states, which only
  a get carries. The `view` parameter is deprecated on the lists, so
  the client never sends it there; the plain get carried the template's
  labels, though the documentation promises them only at `.description`
  or `.all`.
- A get at `.all` of a job that **failed provisioning is a 400
  FAILED_PRECONDITION carrying the job's own error text**; its plain
  get still answers the job, FAILED.
- **A made-up region is not refused**: production answered it with
  us-central1's jobs, on a get and on a list.
- A job nobody has is a 404 in a long sentence that names the method;
  a filter outside the enum is a 400 with a field violation; an ACTIVE
  list with nothing running is a bare `{}`.
- Messages at ERROR on a clean job answer no messages but still the
  autoscaling events; production answered every message past a
  `pageSize` of 5.

## Cancel and drain

New in 0.53.0, and **experimental** as the module is. When the reads
are promoted, these two keep the marker until they have had seven clean
nights of their own.

Both are one method, `UpdateJob`: a `PUT` to the job with its requested
state alone, `{"requestedState":"JOB_STATE_CANCELLED"}` or
`{"requestedState":"JOB_STATE_DRAINED"}`, no update mask and no query,
exactly what gcloud sends. A console that shows the user what it is
about to send asks the twin first:

<!-- snippet: tests/docs_examples.zig#dataflow-confirm -->
```zig
test "the exact request a cancel would send, for the user to confirm" {
    var fake: dataflow.testing.FakeDataflow = .init(std.testing.allocator, std.testing.io, .{ .project_id = "my-project" });
    defer fake.deinit();
    var token: dataflow.StaticToken = .{ .token = "none" };
    var client = try dataflow.Client.init(std.testing.allocator, std.testing.io, .{
        .project_id = "my-project",
        .token_provider = token.provider(),
        .transport = fake.transport(),
    });
    defer client.deinit();
    // Built, not sent: what the confirmation shows, the job's own
    // location taken from the list that found it.
    var request = try client.cancelJobRequest("us-central1", "2026-10-20_07_11_01-16829577348630633066");
    defer request.deinit();
    try std.testing.expectEqual(.PUT, request.value.method);
    try std.testing.expectEqualStrings(
        "https://dataflow.googleapis.com/v1b3/projects/my-project/locations/us-central1/jobs/2026-10-20_07_11_01-16829577348630633066",
        request.value.url,
    );
    try std.testing.expectEqualStrings("{\"requestedState\":\"JOB_STATE_CANCELLED\"}", request.value.body);
    try std.testing.expectEqual(0, fake.callCount());
}
```

The twin runs the same checks with the same errors, and builds the URL
and body the same way, so what the user confirmed is byte for byte what
`cancelJob` sends. Credentials and other headers are not part of it.

### What they answer

**Nothing worth keeping, so both return nothing.** Production answered
every cancel and drain it took with one field, `{"type":
"JOB_TYPE_BATCH"}`, which said batch of a streaming job too: no id and
no state. Read the job to watch it stop:

- A **get** right after shows `current_state` `.cancelling` (or
  `.draining`) and `requested_state` `.cancelled` (or `.drained`).
- A **list's** summary shows the current state at once but never
  carries `requested_state`.
- Once the job has ended, `requested_state` is gone from the get too.
- The job's messages gain "Cancel request is committed for workflow
  job: <id>." (or "Drain request ...") at the moment it was taken.

### What production refuses

Every message starts with a request id in parentheses, left out here.

| Write | The job | Error and production's words |
| --- | --- | --- |
| cancel | still `.pending` | `error.FailedPrecondition`: "Workflow modification failed. Causes: ... Operation cancel not allowed for job <id>. Job is not yet ready for canceling. Please retry in a few minutes." |
| cancel | ended | `error.FailedPrecondition`: "... Cannot perform operation 'cancel' on Job: <id>. Job has terminated in state SUCCESS: Workflow job: <id> succeeded." (`CANCELLED ... cancelled.`, `DRAINED ... was drained.`, `FAILED ... failed.`, and `NOT_STARTED ... failed to start.` for a job that failed its launch) |
| drain | batch, in any state | `error.InvalidArgument`: "Job <id> is not a streaming workflow. Only streaming workflows can be drained." |
| drain | streaming, ended | `error.FailedPrecondition`: "... Cannot perform operation 'drain' on Job: <id>. Job has terminated." |
| either | nobody has it, or a real region it is not in | `error.NotFound`: "Could not cancel workflow; user does not have sufficient permissions on project: <project>, or the job does not exist in the project." (a drain says cancel too) |

A pending job is refused for as long as it is pending, and taken once
it runs: a Word_Count job refused six cancels in its first 17.5 s and
took one at 20.9 s, when it read `.running`.

### What each repeats

**Both are retried as the reads are.** A cancel while cancelling and a
drain while draining answered 200 and changed nothing. A cancel while
draining is taken, and wins: that job ended `.cancelled`. Google's own
client libraries retry nothing on Dataflow, reads included.

### What a cancel and a drain come to

Measured on 2026-10-20, polling every 2 s:

- A Word_Count batch job cancelled while running: `.cancelling` at
  once, **`.cancelled` 240 s later**.
- One cancelled as it was finishing: `.cancelling`, then **`.done`** 36 s
  later. A cancel that comes too late does not change how the job ends.
- A streaming Pub/Sub-to-Pub/Sub job drained: `.draining` at once,
  **`.drained` 126 s later**.
- A streaming job drained, then cancelled while draining: `.cancelled`
  84 s later.
- **A streaming job reads `.running` before its worker is up.** One
  whose only worker never started (the zone was out of resources) took
  a drain, read `.draining`, and ended **`.failed`** 158 s later.

A console reading the job every 10 s or so until `Job.terminal()` sees
each step.

### The location

Take it from the job as listed, never from the user. A real region the
job is not in is the 404 above, but **a made-up region reaches the
job**: a cancel through `us-fake1` was answered by the job's own
backend, about the job, as the reads through a made-up region answer
us-central1's jobs. The client checks a location's characters only, so
a typo can still stop a job.

### `cancellable` and `drainable`

For a console's buttons, from what production took and refused. Both
read only `type`, `current_state` and `requested_state`, which a list's
summary carries (all but the last); the client itself never asks them
and leaves the refusing to the server.

- **`Job.cancellable()`**: not ended, not `.pending`, not `.cancelling`,
  not already asked to cancel. A draining job is cancellable.
- **`Job.drainable()`**: a streaming job that is `.running` and has not
  been asked to cancel or drain.

### Permissions

The scope is `cloud-platform`, as for the reads. IAM asks
`dataflow.jobs.cancel` for both: the API has no drain permission.
Dataflow Developer, Dataflow Admin, Editor and Owner hold it; **Dataflow
Viewer does not**, so a console signed in as a viewer can read a job it
cannot stop.

In tests, `dataflow.testing.FakeDataflow` holds locations, jobs and
messages a test puts in: [Testing](testing.md). `examples/dataflow_jobs.zig
--fake` draws the pipelines widget offline.
