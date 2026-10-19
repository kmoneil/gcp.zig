[Docs](../README.md) › [Run](README.md) › Testing

# Testing with the in-memory Cloud Run

`run.testing.FakeRun` is Cloud Run in memory, behind
`Client.Options.transport`, for tests of code that reads services and
revisions: a health view's tests, say, with no network and no project.
It answers the module's reads as production answered them when measured
(experimental, as the module is).

The API here is read only, so the fake's write side is the test's:
`putLocation`, `putService` and `putRevision` stand in for whoever
deployed, and `setUnreachable` for the regions a `-` listing names as
unreachable.

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

Not modelled, answered 501 with the reason: writes of any kind
(deploys, traffic, deletes, IAM), jobs, executions, operations, and
another project's paths.

A gated production suite (`tests/run_gcp_integration.zig`, `RUN_TEST=1`)
deploys a real `zigps-` hello service, breaks it with an image tag
nobody has, seeds the fake with everything production lists, and holds
the fake to production's answer for every read.
