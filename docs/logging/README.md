[Docs](../README.md) › Cloud Logging

# 📜 Cloud Logging

A client for the read side of Cloud Logging's v2 REST API: log entries
listed a page at a time, as a log explorer's table fetches them; a tail
that polls; and the logs, buckets and views a picker shows. It writes
nothing.

```zig
const std = @import("std");
const auth = @import("auth");
const logging = @import("logging");

pub fn main(init: std.process.Init) !void {
    const arena = init.arena.allocator();
    const lookup = try auth.Lookup.fromEnv(init.environ_map, arena);
    var creds = try auth.findDefault(init.gpa, init.io, lookup, .{});
    defer creds.deinit();
    var client = try logging.Client.init(init.gpa, init.io, .{
        .project_id = "my-project",
        .token_provider = creds.provider(),
    });
    defer client.deinit();
    try newestErrors(&client, std.Io.Clock.real.now(init.io));
}
```

<!-- snippet: tests/docs_examples.zig#logging-first -->
```zig
/// The last hour's errors from Cloud Run, newest first, two pages of them.
fn newestErrors(client: *logging.Client, now: std.Io.Timestamp) !void {
    var query = try client.query(.{
        .filter = "resource.type = \"cloud_run_revision\"",
        .min_severity = .@"error",
        .since = .{ .nanoseconds = now.nanoseconds - std.time.ns_per_hour },
        .until = now,
    });
    defer query.deinit();

    var first = try query.page(null);
    defer first.deinit();
    for (first.value.entries) |entry| show(entry);
    // An empty page with a token is the server out of time, not out of
    // entries: only a null token ends the listing.
    if (first.value.next_page_token) |token| {
        var second = try query.page(token);
        defer second.deinit();
        for (second.value.entries) |entry| show(entry);
    }
}
```

The principal needs `logging.logEntries.list` (the Logs Viewer role,
`roles/logging.viewer`). The client asks for the
`https://www.googleapis.com/auth/logging.read` scope and nothing wider.

## The guides

| Guide | What's in it |
| --- | --- |
| [Listing entries](listing.md) | Queries and their pages, page tokens, the time range, order and page size, the read quota and `ReadBudget`, what an entry carries, and the errors |
| [Filters](filters.md) | The query language as the client joins your filter to its clauses, and how production read it when measured |
| [Tailing](tail.md) | A tail by polling: the window, late entries, falling behind, keeping the cursor, and why there is no live tail |
| [Logs, buckets and views](picker.md) | Log names, buckets and views, and `picker`, which orders them for a person |
| [Testing](testing.md) | An in-memory Cloud Logging for your own tests, with production's answers and a clock the test moves |

## The calls

| Call | What it does |
| --- | --- |
| `Client.query(options)` | Builds and checks one `entries.list` request and fixes it. Nothing is sent. |
| `Query.page(token)` | One page, the same request every time, as page tokens require |
| `Client.tail(options)`, `Tail.poll()` | A tail by polling, each entry once |
| `Client.listLogs`, `listBuckets`, `bucket`, `listViews`, `view` | Log names, buckets and views |
| `Client.picker(parent)` | Every bucket of a parent with its views, ordered for a picker |
| `Client.readBudget()` | How many `entries.list` calls this minute, and when the next is free |

## What was measured

Cloud Logging has no emulator, so what this module does was measured in
production on 2026-10-16 before it was built on. What that changed:

- **There is no live tail over REST.** The `entries:tail` call is a
  bidirectional stream; a complete request ends it at once with `[]`,
  and one left open draws a 502 from Google's front end after 10 s.
  [Tailing](tail.md) polls instead.
- **A page token is bound to its filter and order**, to the byte: one
  more space was refused. Another page size, or other resource names,
  kept it good. `Query` sends the same request for every page.
- **No time range is added to a filter without one.** The server
  searches all of retention, from the oldest entry for an ascending
  listing, and answers a broad one with an empty page after about 5 s.
- **The read quota is 60 `entries.list` calls a minute a project**, a
  fixed window the 429 names. The client counts its own calls and, after
  a 429, waits for that window to end.
- **JSON payloads come back as the server's doubles**:
  12345678901234567890 was returned as 1.2345678901234567e+19.

## Not here

Writing entries, sinks, exclusions, log-based metrics, bucket and view
management, and Log Analytics. A live tail would need gRPC, which this
library does not speak.
