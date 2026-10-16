[Docs](../README.md) › [Cloud Logging](README.md) › Logs, buckets and views

# Logs, buckets and views

Before a query, a log explorer lets a person pick what to read: a
project's logs, or one bucket's view. These calls list them. None of
them counts against the read quota, which counts `entries.list`.

## Log names

`Client.listLogs(.{})` lists the client's project's logs; `.scope` names
another container or a view. Each page has `log_names` as sent (the log
id URL-encoded: `projects/P/logs/cloudaudit.googleapis.com%2Factivity`)
and `log_ids` decoded (`cloudaudit.googleapis.com/activity`).
Production lists only logs that have entries, in byte order, and showed
a new log within 100 seconds of its first entry.

## Buckets and views

Every project, folder, organization and billing account has two buckets
in `global`, as production listed them:

| Bucket | What it holds | Views |
| --- | --- | --- |
| `_Default` | Everything that is not required, 30 days by default | `_AllLogs`, and `_Default`, which leaves out data access audit logs |
| `_Required` | Audit and other required entries, 400 days, locked | `_AllLogs` |

`listBuckets` reads every location unless `.location` names one;
`bucket`, `listViews` and `view` read one at a time. There is no
wildcard for views: production refused location `-` in `views.list`
("Cloud Logging does not support location: -"), so views are listed a
bucket at a time. `_AllLogs` can be deleted, and a bucket being deleted
stays `.delete_requested` for 7 days while Logging still routes entries
to it.

## A picker

`Client.picker(parent)` does the whole round: one bucket list across
locations and one view list a bucket, every page followed. It orders
them for a person, since the server documents no order: `_Default`
first, then `_Required`, then the rest by location and id; within a
bucket, `_Default`, then `_AllLogs`, then the rest.

<!-- snippet: tests/docs_examples.zig#logging-picker -->
```zig
var picker = try client.picker(.{ .project = "my-project" });
defer picker.deinit();
if (picker.value.list_denied) {
    // A Logs View Accessor may read views but not list them.
    return error.AskForViewNames;
}
// The picker's memory goes with it: keep copies.
for (picker.value.buckets) |b| {
    for (b.views) |v| try choices.append(gpa, try arena.dupe(u8, v.name.view));
}
```

A caller who may not list buckets, as a Logs View Accessor
(`roles/logging.viewAccessor`) may not, gets `list_denied` and an empty
picker rather than an error; one who may not list one bucket's views
gets that bucket's `views_denied`. Any other failure fails the call.
It is a call a bucket: meant to be cached.
