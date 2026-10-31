[Docs](../README.md) › Run

# 🏃 Run

A client for Cloud Run's v2 API: the services a project runs and the
revisions behind them, with their conditions, for a health view's
"recent revisions" widget and a trend chart's deploy markers; the jobs
it runs, with their executions; and three writes a console confirms
before sending: run a job, cancel an execution, send all of a service's
traffic to one revision. Nothing here deploys, creates or deletes
anything.

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
| `Client.getServiceIamPolicy(location, id)`, `getJobIamPolicy(location, id)` | A service's or a job's own IAM policy: [Who has access](#who-has-access) |
| `Client.testServiceIamPermissions(location, id, permissions)`, `testJobIamPermissions(...)` | Which of the permissions asked the caller holds there |

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

## What a deploy set

A `Revision` carries the settings it runs with, and `Service.template`
the ones the next deploy will make a revision from, as a
`RevisionTemplate` with the same field names:

| Field | What it is |
| --- | --- |
| `containers` | Each container's `image`, `command`, `args`, `working_dir`, `env`, `resources`, `ports`, `volume_mounts`, `depends_on` |
| `volumes` | Each volume by name: `.secret`, `.empty_dir`, `.cloud_sql`, `.gcs`, `.nfs`, or `.other` with the key of a kind not read here |
| `min_instances`, `max_instances` | The revision's scaling |
| `concurrency`, `timeout_s` | Requests an instance takes at once, and how long one may take |
| `execution_environment` | `.gen1` or `.gen2` |
| `vpc_access` | A connector, or direct egress's network, subnetwork and tags, and which traffic goes through it |
| `service_account`, `session_affinity`, `encryption_key` | The identity it runs as, sticky sessions, a customer-managed key |

A `Service` adds `ingress`, `invoker_iam_disabled`,
`default_uri_disabled` and its own `scaling` (minimum, maximum, mode,
manual count). A `Job` adds its task template's `volumes`, `vpc_access`
and `execution_environment` beside the containers it already had.

```zig
var service = try client.getService("us-central1", "checkout");
defer service.deinit();
const template = service.value.template.?;
for (template.containers) |c| {
    const r = c.resources orelse continue;
    std.debug.print("{s}: {d} millicores, {?d} bytes\n", .{ c.image, r.cpuMillis() orelse 0, r.memoryBytes() });
    for (c.env) |e| switch (e.source) {
        .value => std.debug.print("  {s}\n", .{e.name}), // the value is often a credential
        .secret => |ref| std.debug.print("  {s} from secret {s} ({s})\n", .{ e.name, ref.secret, ref.version }),
    };
}
```

An environment variable's `.value` is kept as deployed, and is often a
credential: show names where a person may see them.

Measured on 2026-10-23, with services and a job deployed for it:

- **Production leaves out every false and zero it holds.** `cpuIdle:
  false` and a minimum of 0 come back absent, so here they read as
  `false` and `null` (a null minimum is 0). It fills defaults only where
  a deploy gave none: 512Mi of memory, 1000m of CPU with `cpuIdle`, port
  8080 as `http1`, a 300 s timeout, a concurrency of 80, and a service
  scaling with a maximum of 20.
- **CPU and memory are kept as deployed**: `"1"` and `"1000m"`, `"1G"`
  and `"1024Mi"` each come back as written. `Resources.cpuMillis` and
  `.memoryBytes` read every form production took.
- **A secret is kept as deployed**, a bare id or a full name, with its
  version (`latest` or a number). A secret the runtime account may not
  read still makes a revision, and the service fails with reason
  `SECRETS_ACCESS_CHECK_FAILED`.
- **A disabled default URL leaves no `uri` and no `urls`** on the
  service.
- A template's container has no name unless the deploy gave one; a
  revision's does (`hello-1`), with its image pinned to a digest.
- `invoker_iam_disabled` could not be measured set: production takes it
  only from a caller who may set the service's IAM policy.

## Jobs and executions

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
| `.failed` | `Completed` failed, for a reason other than a cancel (`NON_ZERO_EXIT_CODE` for a task that exited 1), or for none at all, as a cancel that met the task's start ended |
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

## Writes

| Call | Sends | Answers |
| --- | --- | --- |
| `Client.runJob(location, id)` | `POST .../jobs/J:run`, `{}`: the job as configured, no overrides | The operation; its subject the new execution, by its full name |
| `Client.cancelExecution(location, job, id)` | `POST .../jobs/J/executions/E:cancel`, `{}` | The operation; its subject the execution |
| `Client.routeAllTraffic(location, service, revision, .{ .etag, .validate_only })` | `PATCH .../services/S?updateMask=traffic,etag` with one target, 100 % to the revision, and the etag | The operation; its subject the service |

Each has a twin, `runJobRequest`, `cancelExecutionRequest` and
`routeAllTrafficRequest`, that builds the exact request without sending
it, after the same checks with the same errors, for a console to show
before it asks. `getOperation` reads an operation again by its name.
Every write needs a client whose scope is `.read_write` (see
[The scope](#the-scope)); a `.read_only` client refuses them, and their
previews, before sending.

### What a run, a cancel and a traffic change come to

Measured on 2026-10-21:

- **A run** answered in 0.25 s with its operation, not done. The new
  execution is the operation's subject: read it with
  `getExecutionNamed`. It was pending for about 90 s, then running, then
  ended, and the run's operation was done only then, so follow the
  execution. A job that sleeps 2 s ended 100 s after its run. A failed
  execution's operation fails with code 10 and the task's words ("Task
  <id>-task0 failed with exit code: 1 and message: The container exited
  with an error.").
- **A cancel** answered at once. The execution read running for about
  10 s more, then counted a task cancelled, and ended `.cancelled` 16 s
  after the cancel; one cancelled before it started ended at once,
  without a completion time. An ended execution refuses a cancel,
  `error.FailedPrecondition`: "Execution '<id>' cannot be cancelled
  because it is not running."
- **A cancel that meets the task's start ends failed.** Cancelled the
  moment it first read running, an execution ended `Completed` failed
  with no reason and no message, a task counted cancelled, and both its
  run's and its cancel's operations failed with code 2, "Unspecified
  error." Cancels 15 s and 45 s into a run ended cancelled. Seen in two
  of five cancels of a running execution; `status()` keeps production's
  word, `.failed`.
- **A traffic change**'s operation was done 4 s later. Only `traffic`
  moved: no new revision, the template and labels as they were.
- **The etag is the guard.** Production enforces it only when the update
  mask names it (with `updateMask=traffic` alone it took a stale etag,
  a made-up one and none at all), so the client sends
  `updateMask=traffic,etag`. A service changed since the read is then
  refused, `error.Aborted`: "Conflict for resource '<service>': version
  '<a>' was specified but current version is '<b>'.", for
  `validate_only` too. Read the service again, and ask the user again.
- **`validate_only` does not check the revision.** Production took a
  change to a revision the service did not have, and one to a revision
  whose `Ready` failed; the real change was then taken too, its
  operation failing (code 9, "Revision '<r>' does not exist or is
  deleted. Update all traffic to route to currently available
  revisions.", or the revision's own error) while the service kept the
  asked traffic and its terminal condition went failed. The old revision
  went on serving. **Offer only revisions whose `ready()` is true, and
  read the operation to its end.**
- Another service's revision is refused at once, 400: "Revision target
  '<r>' invalid. Expected a revision prefixed with '<service>-'." The
  client refuses a full resource name (a `/`) before sending.

How each is retried:

- **A run is never sent twice** once it may have reached the server:
  each landing makes an execution. Only a refused connection or a failed
  name lookup is retried; after any other failure, list the job's
  executions, newest first, to see whether it ran.
- **A cancel** is retried as the reads are: a second cancel while the
  execution is stopping is taken. A resend that arrives after it ended
  is refused; the client then reads it, and cancelled means an earlier
  attempt landed: the answer is an operation with an empty name, done,
  the execution as its subject.
- **A traffic change** is retried as the reads are: a resend of one that
  landed is taken and changes nothing (measured). A stale etag is never
  retried.

The permissions each takes, from Google's roles reference (2026-10-20):

| Write | Permission | Cloud Run roles that hold it |
| --- | --- | --- |
| Run a job | `run.jobs.run` | Admin, Developer, Source Developer, Invoker, Jobs Executor, Jobs Executor With Overrides |
| Cancel an execution | `run.executions.cancel` | Admin, Developer, Source Developer, Jobs Executor, Jobs Executor With Overrides (not Invoker) |
| Send all traffic to a revision | `run.services.update` | Admin, Developer, Source Developer |

The basic Owner and Editor roles hold all three; Viewer holds none.
Running a job needs no Service Account User, as Cloud Run's page on
executing jobs says. Its page on rollbacks asks for Developer and
Service Account User on the service identity "to manage Cloud Run
services and revisions", without saying whether a change to traffic
alone checks the second.

## Who has access

`Client.getServiceIamPolicy(location, id)` and `getJobIamPolicy` read a
service's or a job's own IAM policy, as `core.iam.Policy` (exported here
as `iam`). `roles/run.invoker` held by `allUsers` makes a service public.
The policy holds only what was granted on the service itself: what the
project grants, which applies to the service too, is
`resource_manager.Client.getProjectIamPolicy`'s.

```zig
var policy = try client.getServiceIamPolicy("us-central1", "checkout");
defer policy.deinit();
const public = policy.value.grants("roles/run.invoker", "allUsers");

var held = try client.testServiceIamPermissions("us-central1", "checkout", &.{ "run.services.update", "run.services.delete" });
defer held.deinit();
```

`testServiceIamPermissions` and `testJobIamPermissions` answer which of
the permissions asked the caller holds, sorted by name as production
sends them. One to 100, each once and none a wildcard, are checked
before sending; Cloud Run refuses any permission but its own, 400
"Failed to test IAM permissions: Permission pubsub.topics.get is not
valid for this resource.", `error.InvalidArgument`.

Measured on 2026-10-23:

- A new service's and a new job's policy has no bindings:
  `{"etag":"ACAB"}`.
- **A service or job that does not exist is answered as if it did**: the
  same empty policy, and its permissions tested as for any other. Read
  the service first where that matters.
- Location `-` is a 403 that reads like a missing permission
  ("Permission denied on 'locations/-' (or it may not exist)"), so the
  client refuses it before sending, `error.InvalidName`.
- Both calls take every scope a client asks (`run.readonly` included).
  `cloud-platform.read-only` is refused.

## The scope

A client asks its token provider for one scope, `Options.scope`:
`.read_only` (`run.readonly`, the default, the narrowest every read
takes), `.read_write` (`run`) or `.cloud_platform`. Production refuses
every write to `run.readonly`, "Request had insufficient authentication
scopes.", and takes them with `run` or `cloud-platform`. A provider made
from a key file, workload identity or impersonation is fixed to the
scope its first token was minted for (`auth.Credentials.bindsScopes`),
so a program that reads with one client and writes with another gives
each its own credentials.

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

In tests, `run.testing.FakeRun` holds locations, services, revisions,
jobs and executions a test puts in, and takes the three writes as
production did: [Testing](testing.md). `examples/run_revisions.zig
--fake` draws the recent-revisions widget offline, and
`examples/run_actions.zig` runs a job, cancels an execution or rolls a
service back, showing the exact request and sending it only with
`--yes` (`--fake` for no network). `examples/run_service.zig` draws one
service's page: its URL and ingress, its scaling, and each container's
image, CPU and memory, environment variable names and secrets, volumes
and VPC access (`--fake` for no network).
