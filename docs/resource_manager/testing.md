[Docs](../README.md) › [Resource Manager](README.md) › Testing

# Testing

Resource Manager has no emulator.
`resource_manager.testing.FakeResourceManager` is one in memory for your
own tests: it goes where a client's transport goes, and answers as
production answered when measured on 2026-10-17.

<!-- snippet: tests/docs_examples.zig#rm-fake -->
```zig
test "the switcher finds a project by a few letters, from a fake" {
    var clock: rm.testing.FakeClock = .{};
    var fake: rm.testing.FakeResourceManager = .init(std.testing.allocator, clock.io(), .{});
    defer fake.deinit();
    try fake.addProject(.{ .number = 1, .project_id = "payments-prod", .display_name = "Payments" });
    try fake.addProject(.{ .number = 2, .project_id = "web-front", .display_name = "Web" });
    try fake.addPrincipal("person", "payments-prod");
    try fake.grant("person", "payments-prod");
    try fake.grant("person", "web-front");

    var token: rm.StaticToken = .{ .token = "person" };
    var client = try rm.Client.init(std.testing.allocator, clock.io(), .{
        .token_provider = token.provider(),
        .transport = fake.transport(),
    });
    defer client.deinit();
    var list = try client.allProjects(.{});
    defer list.deinit();
    try std.testing.expectEqual(2, list.value.projects.len);
    try std.testing.expect(matches(list.value.projects[0], "pay"));
}
```

## What it models

- **Callers.** Each bearer token is a principal a test adds with
  `addPrincipal(token, home)`, `home` being the project it is charged to
  when it names none. An unknown token, and no token, are production's
  401.
- **Who sees what.** `grant(token, resource)` gives
  `resourcemanager.projects.get` on a project (by id or number), or on a
  folder or organization and everything under it. `addFolder` and
  `addOrganization` build the tree. A project added with `.public = true`
  is read by every caller's `getProject`, and listed by no search but its
  grantees', as production read `bigquery-public-data`.
- **The project charged.** The header when sent, else the caller's own;
  `allowQuotaUse` lets a caller name another; `setApiEnabled` turns the
  API off. That gives `SERVICE_DISABLED` and both `USER_PROJECT_DENIED`
  answers, in production's words.
- **The search quota**: 240 searches a minute per charged project, in
  fixed minutes. Production served ten in 205 ms, so 4 a second is not
  enforced.
- **Order and pages.** One order for every search, as production's
  was: by default a hash of each number, which no app can sort by, or
  `.order = .by_number`, as production listed two projects. A token is a
  position in that order: it goes on from there with another page size,
  and with another query, applied from there. `default_page_size` and
  `max_page_size` are options, since two visible projects could not show
  production's.
- **Eventual consistency.** `change` renames, moves, deletes or purges a
  project; `getProject` sees it at once, search after `search_lag_ns`.
- **The query language**, as the table in [Listing
  projects](projects.md#the-query-language-as-production-read-it) shows,
  refused in production's words where production refused.
- **Faults** on searches: `refuseNext`, `refuseNextWithDelay` for a
  refusal that asks the client to wait, in any of the three forms,
  `dropNext`, `emptyNext`, `shortenNext`.
- **Who has access, and what a caller may do** (measured on
  2026-10-23). `setProjectPolicy(project_id, bindings)` sets a project's
  IAM policy; `getProjectIamPolicy` answers it sorted by role with each
  binding's members sorted, as production's was, version 1 unless a
  binding has a condition, with an etag that moves with each set.
  `holdPermissions(token, project_id, permissions)` says exactly what a
  caller holds on a project: what `testProjectIamPermissions` answers,
  sorted, and whether it may read the policy
  (`resourcemanager.projects.getIamPolicy`). A caller nothing was said
  of holds every permission on a project it sees and none elsewhere. A
  policy the caller may not read, or of a project nobody added, is
  production's 403 "(or it may not exist)"; a test there holds nothing,
  as production's did. A permission list is held to production's rules:
  at least one, each `service.resource.verb`, at most 100.

```zig
try fake.setProjectPolicy("shop-prod", &.{
    .{ .role = "roles/owner", .members = &.{"user:alice@example.com"} },
    .{ .role = "roles/run.invoker", .members = &.{"allUsers"} },
});
// The caller may read the project and its policy, and do nothing else.
try fake.holdPermissions("person-token", "shop-prod", &.{ "resourcemanager.projects.get", "resourcemanager.projects.getIamPolicy" });
```

## What it does not model

Each is answered 501 with the reason, never guessed at:

- `!=`, which production takes and does not apply;
- a `*` anywhere but the end of a value;
- `parent`, `parent.type` and `parent.id`, which production answers from
  another index;
- a name match that depends on how production splits a display name or
  an id into words (measured only on one-word names);
- AND and OR mixed without parentheses;
- folder and organization queries other than the empty one;
- a token from another kind of search, or past `token_lifetime_ns`
  (production's still worked after 65 s).
- which permissions exist: every well-formed one is taken, where
  production refuses one it does not know ("Permission x.y.z is not
  valid for this resource.");
- a version 1 read of a policy with a condition, and a version past 3.

Its 403 for a project the caller cannot see leaves out production's
Troubleshooter link (its 403 for a policy carries one, its request id
the fake's own); its 429 uses the documented limit's names, since
production's for v3 search were not seen.

## Held to production

A production suite, `tests/resource_manager_gcp_integration.zig`, sets
the fake up as production answered and runs 37 scripts against both:
queries, refusals, gets, quota projects, and tokens sent with another
query or page size. On 2026-10-17 they agreed on all of them, after two
fixes to the fake: production refuses a malformed project id such as
`a..b` before it checks the caller's permission, and a production token
is a position in one order, where the fake had kept each search's own. The
refusals the probe recorded are kept verbatim in
`src/resource_manager/production_bodies.zig`, and the fake's are held to
them word for word. The IAM reads' suite, `tests/iam_gcp_integration.zig`, sets the
fake's policy and held permissions from production's answers and replays
five calls; on 2026-10-23 every one agreed, extractctl's 31-binding
policy byte for byte.
