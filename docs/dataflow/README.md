[Docs](../README.md) › Dataflow

# 🌊 Dataflow

A client for Dataflow's v1b3 API, read only: the jobs a project runs,
across every region in one call or one region at a time, with their
states and their error messages, for a health view's pipelines widget.
Nothing here creates, updates, cancels or drains a job, and nothing
launches a template. **Experimental**: new in 0.50.0.

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

A `Job` carries its service-assigned `id`, `name`, `location`, `type`
(batch or streaming), `current_state` with its time, the informational
`requested_state` (a pending cancel shows there first), `create_time`,
`start_time`, `labels` and `stage_states`. **`Job.terminal()`** is the
five states the API labels terminal (done, failed, cancelled, updated,
drained) and **`Job.failing()`** is the widget's red.

## The scope

Every call asks its token provider for `cloud-platform`: v1b3 has no
read-only scope (the only other one is `compute`, no narrower). What a
token may read is IAM's to decide, through `dataflow.jobs.list`,
`dataflow.jobs.get` and `dataflow.messages.list`; Dataflow Viewer
carries all three.

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

In tests, `dataflow.testing.FakeDataflow` holds locations, jobs and
messages a test puts in: [Testing](testing.md). `examples/dataflow_jobs.zig
--fake` draws the pipelines widget offline.
