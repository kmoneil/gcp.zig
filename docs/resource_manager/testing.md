[Docs](../README.md) › [Resource Manager](README.md) › Testing

# Testing

Resource Manager has no emulator.
`resource_manager.testing.FakeResourceManager` is one in memory for your
own tests: it goes where a client's transport goes, and answers as
production answered when measured on 2026-10-17. **Experimental**: new in
0.40.0, and free to change between minor versions until it has been
used for a while.

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
- **Order and pages.** A seeded shuffle that differs between searches;
  `default_page_size` and `max_page_size` as options, since one visible
  project could not show production's; tokens that go on with their own
  search.
- **Eventual consistency.** `change` renames, moves, deletes or purges a
  project; `getProject` sees it at once, search after `search_lag_ns`.
- **The query language**, as the table in [Listing
  projects](projects.md#the-query-language-as-production-read-it) shows,
  refused in production's words where production refused.
- **Faults** on searches: `refuseNext`, `dropNext`, `emptyNext`,
  `shortenNext`.

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
- a token sent with another query, page size, caller or kind of search,
  or past `token_lifetime_ns`.

Its 403 for a project the caller cannot see leaves out production's
Troubleshooter link; its 429 uses the documented limit's names, since
production's for v3 search were not seen.

## Held to production

A production suite, `tests/resource_manager_gcp_integration.zig`, sets
the fake up as production answered and runs 33 scripts against both:
queries, refusals, gets and quota projects. On 2026-10-17 they agreed on
all 33, after one fix to the fake (production refuses a malformed project
id such as `a..b` before it checks the caller's permission). The
refusals the probe recorded are kept verbatim in
`src/resource_manager/production_bodies.zig`, and the fake's are held to
them word for word.
