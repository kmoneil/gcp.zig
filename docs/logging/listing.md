[Docs](../README.md) › [Cloud Logging](README.md) › Listing entries

# Listing entries

`entries.list` is the one read most programs need: a page of log entries
matching a filter. This module makes it one page per call, through a
query whose request is fixed once.

## Queries and pages

`Client.query(options)` checks the options and builds the request;
nothing is sent. `Query.page(token)` sends it, with `null` for the first
page and the last page's `next_page_token` after that:

<!-- snippet: tests/docs_examples.zig#logging-pages -->
```zig
/// Every entry of a query, page after page, stopping after `max_empty`
/// empty pages in a row.
fn readAll(query: *logging.Query, max_empty: usize, seen: *usize) !void {
    var token: ?[]const u8 = null;
    var empty_in_a_row: usize = 0;
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    while (true) {
        var page = try query.page(token);
        defer page.deinit();
        seen.* += page.value.entries.len;
        empty_in_a_row = if (page.value.entries.len == 0) empty_in_a_row + 1 else 0;
        const next = page.value.next_page_token orelse return;
        if (empty_in_a_row >= max_empty) return;
        token = try arena.allocator().dupe(u8, next);
    }
}
```

**An empty page with a token is an ordinary answer.** The server
searches for about 10 seconds a call, then answers with what it has
found, which can be nothing. Only a null token ends the listing. A
virtualized table decides how far to fetch ahead; this module never
follows tokens on its own.

**A token works only with the request that produced it.** Production
refused a token sent with another filter, one more space included, or
another order, with "page_token doesn't match arguments from the
request" (`error.InvalidPageToken`). It took one with another page size
or other resource names. A `Query` sends the same request for every
page, so its tokens always match; keep the query and a page's token
together, and any page can be fetched again within the token's 24 hours.
A token the server never issued is "Invalid page_token", the same error.

## The time range

Nothing is added to your filter but what you ask for. `since` and
`until` are written into it as literal bounds, `timestamp >= "..."` and
`timestamp < "..."`, computed once when the query is made, so every page
sends the same ones.

Without a bound the server searches all of retention: measured, an
ascending listing came back empty after 5 seconds, then found a
30-hour-old entry on its next page. Google's own libraries add "the last
24 hours" when the filter does not contain the word `timestamp`, a test
that misfires on a field such as `jsonPayload.timestamp_ms`; this one
does not.

## Order and page size

`.order = .newest_first` is the default (`timestamp desc`), which the
API reference recommends for recent entries; `.oldest_first` is the
API's own default. Entries with the same timestamp come in `insertId`
order either way.

`page_size` is 100 by default. The proto says at most 1000, but
production served 1001 and 2000 when measured, so the client checks only
that it fits an int32. An entry can be 256 KiB, and 512 KiB in an audit
log; a page whose answer is larger than `Client.Options.max_response_bytes`
(32 MiB) fails with `error.ResponseTooLarge`, and a smaller page is the
cure.

`server_timeout_s` sends `X-Server-Timeout`, which lets the server search
longer than its 10 seconds before it answers. Measured, a broad query
found 58 entries in 6 s without it and a full 1000 in 21 s with 30. It
must stay under `request_timeout_ms` (60 s by default), or the client
gives up first.

## The read quota

Logging allows a project **60 `entries.list` calls a minute**, and says
that cannot be raised. Every reader of the project shares them: a
table, a tail, and anything else.

The client counts its own calls in a `ReadBudget`: 60 in any 60 seconds
by default (`read_calls_per_minute`; 0 counts nothing). A call past the
count is not sent; it fails at once with `error.ResourceExhausted`, and
`Client.readBudget()` says when the next is free. Clients are not
task-safe, so a table's task and a tail's task each have one, and share
a budget:

<!-- snippet: tests/docs_examples.zig#logging-budget -->
```zig
var budget: logging.ReadBudget = .init(60);
var table = try logging.Client.init(gpa, io, .{
    .project_id = "my-project",
    .token_provider = token,
    .read_budget = &budget,
});
defer table.deinit();
var tail = try logging.Client.init(gpa, io, .{
    .project_id = "my-project",
    .token_provider = token,
    .read_budget = &budget,
});
defer tail.deinit();
```

A 429 from the server is the same error and is never retried. It
carries the quota window it counts (`window_start_time`); measured, the
window is a fixed minute, and calls were served again 5 seconds after
the 429, when it ended. The budget holds calls back until then: at least
a second and at most a minute, or 5 seconds when the 429 names none.

## What an entry carries

`Entry` has the common envelope typed: `log_name` as sent and `log_id`
decoded, the resource's type and labels, `timestamp` to the nanosecond,
`receive_timestamp`, `severity`, `insert_id`, labels, `http_request`,
`operation`, `trace`, `span_id`, `trace_sampled`, `source_location` and
`split`.

The payload is one of `.none`, `.text`, `.json` and `.proto`. JSON and
proto payloads are the bytes the server sent; `Payload.parse` makes a
`std.json.Value` of them with every number kept as text. The server
keeps JSON payloads as doubles and writes them its own way, so a large
integer comes back as `1.2345678901234567e+19`, and keys in an order of
its own. A proto payload's `@type` is read; nested ones stay in the
bytes. `Entry.raw` is the whole entry's JSON, for fields this module
does not type, such as `otel` or `apphub`.

## Scopes

A query reads one to 100 scopes: projects, folders, organizations,
billing accounts, or a view of one bucket. None means the client's
project. A view's name is `PARENT/locations/L/buckets/B/views/V`:

```zig
.scopes = &.{.{ .view = .{
    .parent = .{ .project = "my-project" },
    .location = "global",
    .bucket = "_Default",
    .view = "_AllLogs",
} }},
```

## Errors

| Error | When |
| --- | --- |
| `error.InvalidScope` | A name that breaks the naming rules, or more than 100 scopes |
| `error.InvalidFilter` | A clause the client cannot quote, a filter over 20,000 characters, or production's "Unparseable filter: ..." or "Field not found: ..." |
| `error.InvalidPageToken` | A token sent with another query, or one the server did not issue |
| `error.InvalidOptions` | A page size of 0, `since` not before `until`, a server timeout the client would not wait for |
| `error.ResourceExhausted` | The read budget is spent, or the server's quota |
| `error.NotFound` | A project or view that does not exist: production answered a missing project 404, not 403 |
| `error.PermissionDenied` | No read permission on a scope |
| `error.ResponseTooLarge` | A page beyond `max_response_bytes` |

`Diagnostics` keeps the server's message. 5xx answers and dropped
connections are retried by the client's `RetryPolicy`, each attempt
counted against the budget; a 429 and a 4xx never are. A refusal that
asks for a delay is kept in `Diagnostics.retry_after_ms`, waited by a
retry, and after a 429 holds the client's later reads back for the
longer of the quota window and that delay. Production's 429 asks for
none.
