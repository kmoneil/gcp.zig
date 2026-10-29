[Docs](../README.md) › Error Reporting

# 🚨 Error Reporting

A client for Cloud Error Reporting's read side, for an error dashboard:
what is failing in a project now, how often over time in buckets a trend
chart draws, whether each group is new, its errors with their stack
traces, and a group's status to resolve, acknowledge or mute it. It
reports no errors.

```zig
const std = @import("std");
const auth = @import("auth");
const er = @import("error_reporting");

pub fn main(init: std.process.Init) !void {
    const arena = init.arena.allocator();
    const lookup = try auth.Lookup.fromEnv(init.environ_map, arena);
    var creds = try auth.findDefault(init.gpa, init.io, lookup, .{});
    defer creds.deinit();
    var client = try er.Client.init(init.gpa, init.io, .{
        .project_id = "my-project",
        .token_provider = creds.provider(),
    });
    defer client.deinit();
    var rows: std.ArrayList(Row) = .empty;
    try dashboard(&client, &rows, init.gpa);
}
```

<!-- snippet: tests/docs_examples.zig#er-dashboard -->
```zig
/// The dashboard's table: the busiest groups over a day, each with its
/// hourly counts for a trend chart, and whether it is new in the period.
fn dashboard(client: *er.Client, rows: *std.ArrayList(Row), gpa: std.mem.Allocator) !void {
    var query = try client.groupStats(.{ .period = .day, .timed_count_seconds = 3600, .page_size = 20 });
    defer query.deinit();
    var page = try query.page(null);
    defer page.deinit();
    const begin = page.value.time_range_begin.?;
    for (page.value.items) |s| {
        const new = if (s.first_seen) |f| f.nanoseconds >= begin.nanoseconds else false;
        var trend: [24]u64 = @splat(0);
        for (s.timed_counts, 0..) |t, i| if (i < trend.len) {
            trend[i] = t.count;
        };
        try rows.append(gpa, .{
            .group_id = try gpa.dupe(u8, s.group.id),
            .headline = try gpa.dupe(u8, if (s.representative) |r| r.headline() else ""),
            .count = s.count,
            .new = new,
            .trend = trend,
        });
    }
}
```

Reading needs `errorreporting.groups.list` and
`errorreporting.errorEvents.list` (Viewer has both); a status needs
`errorreporting.groupMetadata.update` (Error Reporting User, or Editor).
The API must be on in the project, and in the quota project a person's
login is charged to. `examples/error_dashboard.zig` is a dashboard in a
terminal, and runs offline with `--fake`.

## The guides

| Guide | What's in it |
| --- | --- |
| [Testing](testing.md) | An in-memory Error Reporting for your own tests, held to production's answers |

## The calls

| Call | What it does |
| --- | --- |
| `Client.groupStats(options)`, `query.page(token)` | What each group's errors in a period came to, a page a call, the same request every time |
| `Client.events(group_id, options)`, `query.page(token)` | One group's errors, newest first, each with its stack trace and context |
| `Client.group(id).get()` | A group as it is: the only call that reads a muted one |
| `Client.group(id).setStatus(status)` | Open, acknowledged, resolved or muted, its tracking issues kept |
| `Client.budgetStatus()` | Calls in the last minute, and how long until the next may go |
| `Client.lastConsumerRefusal()` | The project a refusal named, and the link that turns the API on |
| `headlineOf(trace)`, `Event.headline()` | The line of a stack trace that names the exception and its message |

## Periods and buckets

A query looks back over a fixed period that ends now: an hour, six hours,
a day, a week or 30 days. With none, group stats cover 7 days and events
30. `timed_count_seconds` asks for every bucket of the period, those with
no errors too, for a chart:

- `.end` (the default): equal buckets ending exactly at now, the first cut
  short when the width does not divide the period.
- `.{ .rounded = t }`: buckets on a grid through `t`, which need not be
  in the period; midnight UTC gives calendar days. The first and the last
  are cut to the period.

A period holds **at most 100 buckets**: 864 s over a day is the narrowest,
36 s over an hour. The client refuses a narrower width before sending, as
production would. Counts are estimates: Error Reporting samples up to
1,000 errors an hour. It keeps 30 days.

## Statuses

New groups are open. A resolved group that has a new error is open again,
on its own. A **muted** group is left out of group stats, even when asked
for by id, and its new errors are not recorded: only
`Client.group(id).get()` reads it, so a dashboard that offers to unmute
keeps the ids it muted.

<!-- snippet: tests/docs_examples.zig#er-resolve -->
```zig
/// Marks a group resolved, keeping its tracking issues: a new error will
/// open it again on its own.
fn resolve(client: *er.Client, group_id: []const u8) !void {
    var group = try client.group(group_id).setStatus(.resolved);
    defer group.deinit();
}
```

An update replaces the whole group, and one that leaves out the tracking
issues clears them, so `setStatus` reads the group first and puts it back
with the new status. An edit of the issues by someone else between the
two calls is lost: the API has no etag.

## The quota

Error Reporting allows 60 calls a minute per user for event data, and 60
for group metadata. Each client counts its calls, 60 a minute by default,
and refuses one past the count at once, unsent, with
`error.ResourceExhausted` and the wait in `Diagnostics`; `budgetStatus`
says when the next may go, for a dashboard that shows it rather than
waits. Clients of the same user share a `Budget` through
`Options.budget`. A 429 from the server is never retried, and holds the
budget back 5 s, or as long as it asks.

## Locations

`Options.location` reads a region's groups: those whose log entries are
stored there. None, or `global`, reads the global ones; `-` reads group
stats from every region (events and groups need one place). Production
names groups `projects/P/groups/ID` whichever way they were read.

## Errors

| Error | When |
| --- | --- |
| `ServiceDisabled` | The API is off in the project charged; `lastConsumerRefusal` has the link that turns it on. Measured once as a passing refusal an hour after the API was turned on |
| `QuotaProjectDenied` | The quota project may not be used by the caller |
| `NotFound` | An id that names no group: production answers 400 "Invalid group id", never 404 |
| `InvalidPageToken` | A token the server did not issue |
| `InvalidOptions` | Buckets too narrow for the period, a page size or width of 0, `-` for events or a group, `.unknown` as a status |
| `InvalidName` | A project, location, group id or service filter the client will not send |
| `ResourceExhausted` | The budget is spent, or the server's quota |
| `PermissionDenied` | The caller may not read or update the project's errors |

5xx answers and dropped connections are retried with the client's
`RetryPolicy`, a status's update too.

## What was measured

Error Reporting has no emulator, so this module was measured in production
on 2026-10-18 before it was built on, and a production suite holds the
fake to production query by query. What that changed:

- **There is no exception type in the answer.** `headlineOf` takes the
  stack trace's line that names it.
- **A muted group stays hidden even when asked for by id.**
- **An update clears the tracking issues it leaves out.**
- **At most 100 buckets a period**; Google's "recommended minimum"
  widths are not the rule.
- **Distinct users count `user` alone**: an error that named only a
  remote address was not counted.
- **Groups are made by exception and frames, file paths aside**: errors of
  different services, and of different deployments, share a group.
- **First seen is the time of the group's first error processed**, and
  reports sent together are not processed in order. "Newest first by
  creation" orders by first seen.
- **An error showed within seconds** of being reported.

## Not here

Reporting errors (`events.report`) and deleting them (`deleteEvents`
deletes every error in the project); editing tracking issues; Error
Reporting's notifications, which Cloud Monitoring sends.
