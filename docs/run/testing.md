[Docs](../README.md) › [Run](README.md) › Testing

# Testing with the in-memory Cloud Run

`run.testing.FakeRun` is Cloud Run in memory, behind
`Client.Options.transport`, for tests of code that reads services,
revisions, jobs and executions, and of code that runs a job, cancels an
execution or sends a service's traffic to one revision: a console's
tests, say, with no network and no project. It answers the module's
calls as production answered them when measured (experimental, as the
module is; its jobs, executions and writes carry their own marker).

What production holds is the test's to put in: `putLocation`,
`putService`, `putRevision`, `putJob` and `putExecution` stand in for
whoever deployed, `setUnreachable` for the regions a `-` listing names as
unreachable, and `setExecutionStatus` for a job's container, moving an
execution on: nothing moves on its own.

<!-- snippet: tests/docs_examples.zig#run-fake -->
```zig
test "the recent revisions, as a health view draws them" {
    var fake: run.testing.FakeRun = .init(std.testing.allocator, std.testing.io, .{ .project_id = "my-project" });
    defer fake.deinit();
    try fake.putLocation("us-central1");
    _ = try fake.putService(.{
        .location = "us-central1",
        .id = "checkout",
        .latest_ready_revision = "checkout-00007-abc",
        .latest_created_revision = "checkout-00008-def",
        .terminal_condition = .{ .type = "Ready", .state = .failed, .reason = "REVISION_FAILED", .message = "Image 'gcr.io/shop/checkout:v8' not found." },
    });
    // The deploy that broke, standing in for whoever deployed it.
    _ = try fake.putRevision(.{
        .location = "us-central1",
        .service = "checkout",
        .id = "checkout-00008-def",
        .create_time = .{ .nanoseconds = 1_792_436_660 * std.time.ns_per_s },
        .containers = &.{.{ .image = "gcr.io/shop/checkout:v8" }},
        .conditions = &.{.{ .type = "Ready", .state = .failed, .message = "Image 'gcr.io/shop/checkout:v8' not found." }},
    });

    var token: run.StaticToken = .{ .token = "none" };
    var client = try run.Client.init(std.testing.allocator, std.testing.io, .{
        .project_id = "my-project",
        .token_provider = token.provider(),
        .transport = fake.transport(),
    });
    defer client.deinit();
    // The widget's read: every service's revisions in the region.
    var revisions = try client.listRevisions("us-central1", "-", .{});
    defer revisions.deinit();
    try std.testing.expectEqual(1, revisions.value.revisions.len);
    const broken = revisions.value.revisions[0];
    try std.testing.expect(!broken.ready());
    try std.testing.expect(std.mem.indexOf(u8, broken.readyCondition().?.message, "not found") != null);
    // The deploy marker for the trend chart.
    try std.testing.expect(broken.create_time != null);
}
```

And the writes a console confirms, against the same fake:

<!-- snippet: tests/docs_examples.zig#run-fake-writes -->
```zig
test "a rollback and a run, as a console confirms and sends them" {
    var fake: run.testing.FakeRun = .init(std.testing.allocator, std.testing.io, .{ .project_id = "my-project" });
    defer fake.deinit();
    try fake.putLocation("us-central1");
    _ = try fake.putService(.{ .location = "us-central1", .id = "checkout", .traffic = &.{.{ .type = .latest, .percent = 100 }} });
    _ = try fake.putRevision(.{ .location = "us-central1", .service = "checkout", .id = "checkout-00007-abc", .conditions = &.{.{ .type = "Ready", .state = .succeeded }} });
    _ = try fake.putJob(.{ .location = "us-central1", .id = "nightly-report" });

    var token: run.StaticToken = .{ .token = "none" };
    var client = try run.Client.init(std.testing.allocator, std.testing.io, .{
        .project_id = "my-project",
        .token_provider = token.provider(),
        .scope = .read_write,
        .transport = fake.transport(),
    });
    defer client.deinit();

    // The rollback, guarded by the etag the read gave.
    var service = try client.getService("us-central1", "checkout");
    defer service.deinit();
    var request = try client.routeAllTrafficRequest("us-central1", "checkout", "checkout-00007-abc", .{ .etag = service.value.etag });
    defer request.deinit();
    try std.testing.expect(std.mem.endsWith(u8, request.value.url, "?updateMask=traffic,etag"));
    var change = try client.routeAllTraffic("us-central1", "checkout", "checkout-00007-abc", .{ .etag = service.value.etag });
    defer change.deinit();
    var done = try client.getOperation(change.value.name);
    defer done.deinit();
    try std.testing.expectEqualStrings("checkout-00007-abc", done.value.subject.service.traffic[0].revision);
    // The same read's etag is stale now.
    try std.testing.expectError(error.Aborted, client.routeAllTraffic("us-central1", "checkout", "checkout-00008-def", .{ .etag = service.value.etag }));

    // A run: pending at first, as production's were; the test stands in
    // for the job's container.
    var ran = try client.runJob("us-central1", "nightly-report");
    defer ran.deinit();
    const execution = ran.value.subject.execution.name;
    try fake.setExecutionStatus(execution, .running);
    try fake.setExecutionStatus(execution, .succeeded);
    var finished = try client.getOperation(ran.value.name);
    defer finished.deinit();
    try std.testing.expect(finished.value.done);
    try std.testing.expectEqual(run.ExecutionStatus.succeeded, finished.value.subject.execution.status());
}
```

## What it models

Each as production answered when measured on 2026-10-19:

- Lists sort by name; revisions newest first, as production answered
  them after a deploy. Pages walk with a token; an empty list is `{}`.
- The `-` location lists every region's services (production answers
  it, though its documentation says otherwise), with the `unreachable`
  regions the test set; `services/-` lists every service's revisions in
  the location.
- Refusals in production's words: a service nobody has is 404 "Resource
  '<id>' of kind 'SERVICE' in region '<l>' in project '<p>' does not
  exist." (a revision's the same with kind 'REVISION', production's
  shape though only the service's was measured); a location that is no
  region is 400 "The request has errors"; **revisions of a service
  nobody has are an empty page, not a 404**; a request without a token
  is a 401.
- Faults a test asks for: `refuseNext`, `dropNext` and `loseNext`, as
  the other fakes have them.

`putService` and `putRevision` refuse, with nothing kept, what
production could not hold: a location or service nobody put, an id
taken, malformed or `-`.

### Jobs, executions and the writes

Each as production answered when measured on 2026-10-21:

- Jobs are listed one region at a time: `-` is 400 "Request contains an
  invalid argument.", a region nobody put 403 "Permission denied on
  'locations/<l>' (or it may not exist)". `jobs/-` lists every job's
  executions; a job nobody has lists none. Both lists come newest first.
- **A run** makes an execution named `<job>-<suffix>`, the suffix a
  counter (`00001`, `00002`, ...) so a test can predict it, as
  `PutJob.run_outcome` says: `.pending` (the default, as production's
  were for their first 90 s) or `.running` until the test moves it, or
  `.succeeded` or `.failed` already ended. Its operation is done once the
  execution has ended, failing with code 10 and the task's words for a
  failed one. Two runs of one job may run at once.
- **A cancel** of a running execution makes it cancelling, and the test
  moves it on to cancelled; of a pending one, cancelled at once without a
  completion time, as production's was; of a cancelling one, nothing
  changes. An ended one is 400 FAILED_PRECONDITION "Execution '<id>'
  cannot be cancelled because it is not running." Moved to `.failed`
  after a cancel, an execution reads as one production cancelled as its
  task started: `Completed` failed with no reason, a task counted
  cancelled, and both its operations failing with code 2, "Unspecified
  error."
- **A traffic change** sets the one target asked, a new generation and a
  new etag (the fake's own form, `"v<version>"`). Under
  `updateMask=traffic,etag` a stale etag is 409 ABORTED "Conflict for
  resource '<s>': version '<a>' was specified but current version is
  '<b>'." (the fake's versions are counters where production's are
  times); under `updateMask=traffic` the etag is ignored; a change to the
  traffic the service already has changes nothing and checks no etag. A
  revision not prefixed with the service's id is 400 at once; one the
  service does not have, or one not ready, is taken, and its operation
  fails (code 9, or code 5 with the revision's own words) while the
  service keeps the asked traffic and fails. `validateOnly` checks the
  etag and the prefix, and changes nothing. Its operation is done from
  its first read on.
- Faults on the writes as on the reads: a lost answer to a run leaves the
  execution made, as a real one would.

`putJob` and `putExecution` refuse, with nothing kept, what production
could not hold: a location or job nobody put, an id taken, malformed or
`-`, a status of `.unspecified` or `.unknown`.

### What a deploy set

Each as production answered when measured on 2026-10-23:

- `putService(.{ .template = ... })`, `putRevision` and `putJob` take
  the settings `Service.template`, `Revision` and `Job` read, and the
  fake fills production's defaults where a test gives none: for each
  container of a service or revision 1000m of CPU and 512Mi of memory
  with `cpu_idle`, and port 8080 as `http1`; for a job's 1000m and
  512Mi without `cpu_idle` and no port; a service's or revision's 300 s
  timeout and concurrency of 80; a job's GEN2; a service's scaling with
  a maximum of 20 and ingress `.all`. A revision's unnamed container is
  named for its image and place (`hello-1`), as production named one.
- Every false and zero is left out of an answer, as production leaves
  them out, so it reads back as absent: a minimum of 0, `cpu_idle`
  false, `session_affinity` false.
- `default_uri_disabled` answers no `uri` and no `urls`, whatever was
  put.
- A service put with no template answers none, which no production
  service does: give one where a test reads it. Probes are not written.
- A put with an env var, volume or volume mount without a name, or a
  secret reference without a secret, is `error.InvalidEntry`.

### Who has access

Each as production answered when measured on 2026-10-23:

- `setIamPolicy(name, bindings)` sets the policy of a service or job a
  test put, by the full name `putService` or `putJob` returned;
  `getServiceIamPolicy` and `getJobIamPolicy` answer it sorted by role,
  each binding's members sorted. With none set the answer is
  production's empty policy, `{"etag":"ACAB"}`, and **so it is for a
  service or job nobody put**, as production answered one that did not
  exist.
- `holdPermissions(name, permissions)` says exactly what the caller holds
  on a service or job, put or not, since production tests permissions on
  one that does not exist as on one that does. Nothing said, every
  permission asked is held. The answer is sorted; a permission named
  twice is answered twice. Refused in production's words after "Failed
  to test IAM permissions: ": none, a malformed or wildcard permission,
  one that is not Cloud Run's, more than 100.
- A region nobody put, `-` included, is 403 "Permission denied on
  'locations/<l>' (or it may not exist)".

A policy with bindings is written version, etag, bindings, as KMS's was
measured: Cloud Run's was not, since the probe's account could not set
one. Which of Cloud Run's permissions belong to a service and which to a
job is not modelled: every `run.` one is taken on both.

Not modelled, answered 501 with the reason: other writes (deploys,
deletes, setting IAM), a version 1 read of a policy with a condition,
run overrides, traffic other than one revision at 100 %,
an update mask other than the two above, reading a `validateOnly`
request's operation, an etag the fake did not make under the etag mask,
`-` for a location in a jobs path other than the jobs list, and another
project's paths.

A gated production suite (`tests/run_gcp_integration.zig`, `RUN_TEST=1`)
deploys a real `zigps-` hello service, breaks it with an image tag
nobody has, seeds the fake with everything production lists, and holds
the fake to production's answer for every read. Its writes suite
(`RUN_WRITES_TEST=1`) runs, cancels and routes traffic on real `zigps-`
jobs and a service, then replays the same script on a fake seeded from
production's reads and holds every outcome and refusal equal. Its
settings test (`RUN_SETTINGS_TEST=1`) deploys a service with every
setting, a plain one and a job, and replays them on a fake seeded from
production's answers, the plain ones with an image alone so that the
fake's defaults answer for production's: on 2026-10-23 all seven
answers agreed. The IAM
reads' suite (`tests/iam_gcp_integration.zig`, `IAM_READS_TEST=1`) reads
a real service's and job's policies and permissions, and those of ones
nobody has, then replays the eight calls on a fake seeded from
production's answers: on 2026-10-23 all eight agreed.
