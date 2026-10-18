[Docs](../README.md) › [Error Reporting](README.md) › Testing

# Testing

`error_reporting.testing.FakeErrorReporting` is Cloud Error Reporting in
memory, behind `Client.Options.transport`: errors a test reports, grouped,
counted and listed as production answered when measured, on a clock the
test sets. A dashboard's offline checks get deterministic data with no
network. **Experimental**, as the module is.

<!-- snippet: tests/docs_examples.zig#er-fake -->
```zig
/// A dashboard test with deterministic data: errors reported to the fake,
/// on a clock the test sets, read back through a real client.
fn dashboardTest(gpa: std.mem.Allocator) !void {
    var clock: er.testing.FakeClock = .{ .now_ns = 1_792_324_800 * std.time.ns_per_s };
    var fake: er.testing.FakeErrorReporting = .init(gpa, clock.io(), .{ .project_id = "my-project" });
    defer fake.deinit();
    const trace = "java.lang.NullPointerException: customer is null\n\tat Billing.charge(Billing.java:88)";
    for (0..3) |i| _ = try fake.report(.{
        .message = trace,
        .time = .{ .nanoseconds = (1_792_324_800 - @as(i96, @intCast(i)) * 3600) * std.time.ns_per_s },
        .service = .{ .service = "billing" },
    });
    var token: er.StaticToken = .{ .token = "test" };
    var client = try er.Client.init(gpa, clock.io(), .{
        .project_id = "my-project",
        .token_provider = token.provider(),
        .transport = fake.transport(),
    });
    defer client.deinit();

    var rows: std.ArrayList(Row) = .empty;
    defer {
        for (rows.items) |r| {
            gpa.free(r.group_id);
            gpa.free(r.headline);
        }
        rows.deinit(gpa);
    }
    try dashboard(&client, &rows, gpa);
    try std.testing.expectEqual(1, rows.items.len);
    try std.testing.expectEqual(3, rows.items[0].count);
    try std.testing.expectEqualStrings("java.lang.NullPointerException: customer is null", rows.items[0].headline);
}
```

## What it models

- **Groups**: errors with the same `Report.group` key share one, or with
  the same stack trace when there is no key. Production groups by
  exception and frames, which a test says with its own keys.
- **Group stats computed from the errors**, as production's came out: the
  period ending now in whole seconds, 7 days by default; counts; distinct
  users by `user`; every bucket in both alignments, at most 100 a period;
  first seen as the first error to arrive, last seen as the latest in
  whole seconds; the services with errors; every order; groups with no
  errors in the period left out unless asked for by id.
- **Statuses**: a muted group hidden, even by id, its new errors dropped;
  a resolved group reopened by a new error; an update that clears the
  tracking issues it leaves out.
- **Events** newest first, 30 days by default; **paging** with the
  server's default of 20.
- **Locations**: none, `global` and `-` read the same groups; any other
  region holds none.
- **Refusals in production's words**: an unknown group (400), events
  without a group id, buckets too narrow, a status or a period that is
  not one; the API off (`setApiEnabled`); the per-user quota as an option
  (`Options.calls_per_minute`); and `refuseNext`, `refuseNextWithDelay`
  and `dropNext`.

## What it does not

The representative is the group's first error to arrive in the period,
where production picks one of its own. Reporting and deleting errors,
another project, and events or groups at `-` are answered 501 with the
reason.

## Held to production

The production suite (`tests/error_reporting_gcp_integration.zig`) reports
the same errors to production and to the fake and asks both ten group-stats
queries: by count over a day and 30 days, by last seen, creation and
users, buckets at the end and on the hour and at the 100-bucket limit, an
hour, and a week filtered by version. Every answer matched, counts, users,
services, first and last seen and every bucket.
