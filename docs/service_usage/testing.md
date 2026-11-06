[Docs](../README.md) › [Service Usage](README.md) › Testing

# Testing with the in-memory Service Usage

`service_usage.testing.FakeServiceUsage` is Service Usage in memory,
behind `Client.Options.transport`, for tests of code that asks which
APIs a project has on: a console's list of them, or a panel that says
one is off, with no network and no project. It answers the client's
calls as production answered them when measured on 2026-11-06, byte
for byte, its refusals in production's words.

`putService` stands in for the project's settings: each service is put
in enabled or disabled, and `setState` turns one on or off as the
console or gcloud would.

<!-- snippet: tests/docs_examples.zig#su-fake -->
```zig
test "an API-off panel says whether the API is on, from the in-memory Service Usage" {
    var fake: service_usage.testing.FakeServiceUsage = .init(std.testing.allocator, std.testing.io, .{ .project_id = "my-project" });
    defer fake.deinit();
    // Standing in for the project's settings: one API on, one off.
    try fake.putService(.{ .name = "pubsub.googleapis.com", .title = "Cloud Pub/Sub API", .state = .enabled });
    try fake.putService(.{ .name = "dataflow.googleapis.com", .title = "Dataflow API" });

    var token: service_usage.StaticToken = .{ .token = "none" };
    var client = try service_usage.Client.init(std.testing.allocator, std.testing.io, .{
        .project_id = "my-project",
        .token_provider = token.provider(),
        .transport = fake.transport(),
    });
    defer client.deinit();

    // The project's list: the enabled ones only.
    var enabled = try client.enabledServices();
    defer enabled.deinit();
    try std.testing.expectEqual(1, enabled.value.len);
    try std.testing.expectEqualStrings("Cloud Pub/Sub API", enabled.value[0].title);

    // A Dataflow call failed: is the API on?
    var dataflow_api = try client.getService("dataflow.googleapis.com");
    defer dataflow_api.deinit();
    try std.testing.expectEqual(service_usage.State.disabled, dataflow_api.value.state);

    // Turned on elsewhere, it is listed.
    try fake.setState("dataflow.googleapis.com", .enabled);
    var now = try client.enabledServices();
    defer now.deinit();
    try std.testing.expectEqual(2, now.value.len);
}
```

## What it answers, and how

- Names carry the project by number, `Options.project_number`, as
  production's do; the client's project may be the id or the number.
- Lists are in name order, by the three filters: enabled, disabled, or
  every one. A page is 50 unless asked. The enabled list's page tokens
  are production's offset form; the other two lists' are the fake's
  own, and each takes the other's (production's disabled list took the
  unfiltered list's).
- Answers are what production wrote under the client's fields masks:
  `documentation` is `{}` when a service has no summary.
- A batch answers in the order asked, a name twice answered twice, and
  takes a name under any project as one under its own, as production
  did.
- Refused in production's words, with its ErrorInfo reason and
  metadata: a service nobody put (403, the first such in a batch); a
  project not the fake's (403, "not found or permission denied"); no
  credentials (403); a filter or page size production refuses, and a
  page token from another list (400); a batch of none, of more than 30,
  or of a name with no project (400). Production's PreconditionFailure
  details and its Help Token are left out.
- `refuseNext(n, status)` and `dropNext(n)` fail the next calls, for a
  test of what a caller does when a read is refused or its connection
  drops.

Not modelled, answered 501 with the reason: a call without the client's
fields mask, or with another (a service's whole configuration); a short
name such as `pubsub`, which production answered for some services and
not others, so put full names; an empty name, which production answered
as the unfiltered list; enabling and disabling; operations; quotas; and
folders and organizations.

The fake is held to production two ways. A unit test puts in the 49
services production answered on 2026-11-06 and reads them back the way
production was read, every success body equal byte for byte and every
refusal word for word. A production suite runs one script against
production and against a fake seeded from its answers, and compares
them line by line.
