[Docs](../README.md) › BigQuery

# 🔎 BigQuery

A client for BigQuery's v2 API, for a console's query editor and data
browser: the datasets a project holds, their tables with their
schemas, and the job history, from the client's own project or any
other a caller can read; queries dry-run for what they would bill,
run, read a page at a time with every type decoded exactly, and
cancelled. Nothing here creates, changes or deletes a dataset or a
table. **Experimental**: new in 0.55.0.

```zig
const std = @import("std");
const auth = @import("auth");
const bigquery = @import("bigquery");

pub fn main(init: std.process.Init) !void {
    const arena = init.arena.allocator();
    const lookup = try auth.Lookup.fromEnv(init.environ_map, arena);
    var creds = try auth.findDefault(init.gpa, init.io, lookup, .{});
    defer creds.deinit();
    var client = try bigquery.Client.init(init.gpa, init.io, .{
        .project_id = "my-project",
        .token_provider = creds.provider(),
    });
    defer client.deinit();

    const options: bigquery.QueryOptions = .{
        .query = "SELECT corpus, SUM(word_count) AS words FROM `bigquery-public-data.samples.shakespeare` GROUP BY corpus",
        .maximum_bytes_billed = 100 * 1024 * 1024,
    };
    // What it would read, for nothing.
    var cost = try client.dryRun(options);
    defer cost.deinit();
    std.debug.print("reads {d} bytes\n", .{cost.value.total_bytes_processed orelse 0});

    var page = try client.query(options);
    defer page.deinit();
    while (!page.value.complete) {
        const next = try client.getQueryResults(page.value.job.?, .{});
        page.deinit();
        page = next;
    }
    for (page.value.rows) |row| {
        std.debug.print("{f}: {f}\n", .{ row.cells[0].value, row.cells[1].value });
    }
}
```

## The calls

| Call | What it does |
| --- | --- |
| `Client.listDatasets(options)` | One page of a project's datasets, the client's own or `options.project`'s; `all` adds hidden ones, `label_filter` takes `labels.<key>[:<value>]` |
| `Client.getDataset(ref)` | One dataset: location, description, labels, times, default expirations |
| `Client.listTables(dataset_ref, options)` | One page of a dataset's tables, as a list carries them: type, partitioning, clustering and times, but no schema and no row count |
| `Client.getTable(ref)` | One table with its schema (nested records included), row count, bytes, partitioning, clustering, and a view's or materialized view's query |
| `Client.listJobs(options)` | One page of the job history, newest first, each with its query text; `all_users`, state and creation-time filters |
| `Client.getJob(ref)` | One job: its state, its final error, its statement type, the bytes it processed and billed |
| `Client.dryRun(options)` | What a query would read and bill, its columns and statement type, without running it: free, and never in the history |
| `Client.query(options)` | Runs a query: the first page when it ends within `timeout_ms`, or the job to read further |
| `Client.getQueryResults(job, options)` | A page of a job's results, or, for a job still running, its state once the call has been held `timeout_ms` |
| `Client.cancelJob(job)` | Asks a job to stop; answers the job as it stands |
| `Client.dryRunRequest(options)`, `queryRequest`, `cancelJobRequest` | The exact request each would send, built without sending it, for a confirmation |

`DatasetRef`, `TableRef` and `JobRef` name their project, an empty
one being the client's own, so `bigquery-public-data` reads as easily
as one's own. A job outside the US and EU multi-regions needs its
`location` in its `JobRef`; take it from the `QueryPage` or `Job` that
named the job.

## Running a query

Every query this library sends is GoogleSQL: BigQuery's default is
still legacy SQL, so it sends `useLegacySql` false. A console runs
one in three steps:

1. **Dry run it.** `dryRun` answers `total_bytes_processed`, what the
   query would read, and the columns it would answer, at once and for
   nothing. A query that would fail fails here the same way, so the
   editor can mark the error before anything runs.
2. **Run it under a limit.** `query` with `maximum_bytes_billed` set
   fails, billing nothing, when the query would bill more:
   `error.BytesBilledLimitExceeded`. A query that reads a table bills
   at least 10 MiB, so a limit below 10,485,760 refuses every such
   query.
3. **Read its results.** A query that ends within `timeout_ms` (10 s
   by default) answers its first page; one that does not answers
   `complete` false and its `job`. `getQueryResults` with the job
   reads it further: held up to its own `timeout_ms` while the job
   runs, then a page at a time by `page_token`, or from any row by
   `start_index`. `page_size` 0 waits for the job without reading
   rows, as Google's clients do.

The library has no waiting helper: the caller's task owns its waiting,
and calls `getQueryResults` until `complete`. Each held call's request
may take its `timeout_ms` and 30 s more before `error.TimedOut`, so
the client's own `request_timeout_ms` never cuts one short.

**Every query carries a request id**, so a query sent again within 15
minutes answers the first job rather than run it again, and `query` is
retried as the reads are. With `QueryOptions.request_id` null each call
makes its own; give one from `Client.newRequestId` to make a repeat of
your own safe too, and to send exactly what `queryRequest` showed:

<!-- snippet: tests/docs_examples.zig#bigquery-confirm -->
```zig
test "the exact query a console would run, for the user to confirm" {
    var fake: core.testing.FakeTransport = .init(std.testing.allocator, &.{});
    defer fake.deinit();
    var token: bigquery.StaticToken = .{ .token = "none" };
    var client = try bigquery.Client.init(std.testing.allocator, std.testing.io, .{
        .project_id = "my-project",
        .token_provider = token.provider(),
        .transport = fake.transport(),
    });
    defer client.deinit();
    // One request id for the preview and the run, so the run sends
    // byte for byte what the user confirmed.
    var id: [36]u8 = undefined;
    const options: bigquery.QueryOptions = .{
        .query = "SELECT word, word_count FROM `bigquery-public-data.samples.shakespeare` LIMIT 10",
        .maximum_bytes_billed = 100 * 1024 * 1024,
        .request_id = client.newRequestId(&id),
    };
    var request = try client.queryRequest(options);
    defer request.deinit();
    try std.testing.expectEqual(.POST, request.value.method);
    try std.testing.expectEqualStrings("https://bigquery.googleapis.com/bigquery/v2/projects/my-project/queries", request.value.url);
    try std.testing.expect(std.mem.indexOf(u8, request.value.body, "\"maximumBytesBilled\":\"104857600\"") != null);
    // Built, not sent.
    try std.testing.expectEqual(0, fake.requests.items.len);
}
```

A job that failed is answered as it is, never run again: Google's
clients run such a job again under a new id, but a new run can bill
again, and that is the caller's call.

`examples/bigquery_query.zig` is the whole loop: a dry run, the
request shown, the run only with `--yes`, the wait, and the results as
a table, a page at a time; `--fake` runs it with no network. For tests
of code like it, see [Testing](testing.md).

## Values

A `QueryPage` carries its `schema` and its `rows`, each `Row` a
`Cell` per column: the decoded `value` and, for a scalar, production's
wire `text` beside it.

| BigQuery type | `Value` | As decoded |
| --- | --- | --- |
| INT64 | `.int64` | `i64`, never a float |
| FLOAT64 | `.float64` | `f64`, NaN and the infinities included |
| NUMERIC, BIGNUMERIC | `.numeric`, `.bignumeric` | `Decimal`, the exact decimal text (BIGNUMERIC has 76 digits); `toF64()` for a chart |
| BOOL | `.boolean` | |
| STRING | `.string` | |
| BYTES | `.bytes` | Decoded from base64 |
| DATE, TIME, DATETIME | `.date`, `.time`, `.datetime` | `Date`, `Time` (to the microsecond), `DateTime` (no time zone) |
| TIMESTAMP | `.timestamp` | `std.Io.Timestamp`, exact to the microsecond |
| GEOGRAPHY | `.geography` | Well-known text, as answered |
| JSON | `.json` | The JSON text, as answered |
| INTERVAL | `.interval` | `Interval`: months, days and microseconds, each signed, as BigQuery holds them |
| RANGE | `.range` | `Range`: `start` and `end` of the element type, null when unbounded |
| REPEATED column | `.array` | A `Cell` per element |
| RECORD | `.record` | A `Cell` per field, in the schema's order |
| NULL | `.null` | |

A type this library does not know decodes as `.string`, its text
kept, so a new type does not break a results table. A value that does
not fit its column's type is `error.InvalidResponse`.

`Value.format` writes a value as BigQuery's console shows it (`{f}` in
`print`): a timestamp as `2026-10-21 13:14:15.123456 UTC`, NULL as
`NULL`, an array as `[1, 2]`, a record as `{1, y}`, bytes in base64,
every other scalar in its wire form.

## Errors

A refusal's `errors[].reason` decides its error, where BigQuery's
status says less:

| Reason | Error | |
| --- | --- | --- |
| `invalidQuery` | `error.InvalidQuery` | A syntax or semantic error, and a runtime one (`division by zero: 1 / 0`) |
| `bytesBilledLimitExceeded` | `error.BytesBilledLimitExceeded` | Over `maximum_bytes_billed`; nothing billed |
| `responseTooLarge` | `error.ResultTooLarge` | A result too large to return |
| `quotaExceeded` | `error.QuotaExceeded` | A quota, not a rate limit |
| `rateLimitExceeded`, `backendError`, `badGateway`, `internalError` | Retried, whatever their status | BigQuery sends a rate limit as a 403 at times |

`Diagnostics` keeps BigQuery's words, and
**`bigquery.errorPosition(message)`** reads the `at [line:column]` a
query error ends with, for the editor's cursor: "Syntax error:
Unexpected keyword WHERE at [2:3]" is line 2, column 3. A runtime
error names no position.

## The scope

A client asks its token provider for one scope,
`Client.Options.scope`:

| `Scope` | Asks for | Serves |
| --- | --- | --- |
| `.bigquery`, the default | `bigquery` | Everything here |
| `.cloud_platform` | `cloud-platform` | Everything here, for credentials already fixed to it |
| `.cloud_platform_read_only` | `cloud-platform.read-only` | Every read, a dry run, a query and its results; not a cancel, which the client refuses before sending (`error.InvalidOptions`) as production does |

BigQuery has no read-only scope of its own; `cloud-platform.read-only`
reads every Google Cloud API, so it is offered rather than the
default. What a token may do is IAM's to decide:

| Call | Takes |
| --- | --- |
| `listDatasets` | Nothing: lists the datasets the caller has `bigquery.datasets.get` on |
| `getDataset` | `bigquery.datasets.get` |
| `listTables` | `bigquery.tables.list` |
| `getTable` | `bigquery.tables.get` |
| `listJobs` | Nothing for one's own jobs; `all_users` needs `bigquery.jobs.list` (others' redacted) or `bigquery.jobs.listAll` |
| `getJob`, `getQueryResults` | `bigquery.jobs.get`, or `bigquery.jobs.create` on the project for one's own job |
| `dryRun`, `query` | `bigquery.jobs.create` on the client's project, and `bigquery.tables.getData` on the tables read |
| `cancelJob` | `bigquery.jobs.update`, or `bigquery.jobs.create` on the project for one's own job |

BigQuery Job User carries `bigquery.jobs.create`; BigQuery Data Viewer
the dataset and table reads and `getData`.

## What production showed

Measured on 2026-10-21, in the project the tests run in:

- **The public datasets read from any project.**
  `bigquery-public-data:samples` is in the US; `shakespeare` has
  164,656 rows and 6,432,064 bytes.
- **A dry run answers at once**, with the bytes, the schema and the
  statement type, and is never listed in the history.
- A query of literals alone billed 0 bytes; **one reading a table
  billed 10,485,760**, the 10 MiB minimum; one answered from the cache
  billed 0.
- **A syntax error is refused at once**, for a dry run and a run
  alike: "Syntax error: Unexpected keyword WHERE at [2:3]". So is a
  runtime error ("division by zero: 1 / 0") and a query over its
  limit: "Query exceeded limit for bytes billed: 1000. 10485760 or
  higher required."
- **A query that outlives `timeout_ms` answers its job and nothing
  else.** `getQueryResults` held each call about as long as asked (2 s
  each, twenty times over); one with `page_size` 0 and 60 s held until
  the job ended, at 53 s, and answered the schema, the row count and a
  page token, no rows. A quick query with `timeout_ms` 0 still came
  back complete.
- **A cancel answers at once with the job running**; the job then
  ended done, its error `stopped`: "Job execution was cancelled: User
  requested cancellation". A cancel of a job already done answered it
  done, no refusal.
- **A repeated request id answered the same job**, but unfinished and
  without rows, though the job had ended: read its results then. The
  same id with another query made a new job.
- `getJob` without a location found a US job; with the wrong one,
  "Not found: Job extractctl:EU.<id>". A US table queried with location
  EU is a permission refusal: "Access Denied: Table
  bigquery-public-data:samples.shakespeare: User does not have
  permission to query table ..., or perhaps it does not exist."
- Paging walked five pages of ten by token, and `start_index` 45 read
  the last five. The history lists newest first; without a page size
  production answered all 34 jobs on one page.
- **DDL and DML answer no row count**: CREATE SCHEMA, CREATE TABLE (AS
  SELECT), CREATE VIEW and INSERT came back complete, billing nothing,
  with their statement type and, for the INSERT, the rows it changed.
- A query of three billion generated rows (no table, so free) took
  about 50 s: polled with `timeout_ms` 2000, it answered unfinished 21
  to 25 times.
- **TIMESTAMP comes as float seconds by default**
  (`1.792588455123456E9`), which loses digits through a float; this
  library asks for microseconds, as Google's clients do, and decodes
  all three forms exactly. An INTERVAL's fraction came in three digits
  (`0-0 0 0:0:0.250`), NUMERIC without trailing zeros (`1.5` for
  `1.50`), JSON compact with its keys sorted, and schemas with the
  legacy type names (`INTEGER`, `FLOAT`, `BOOLEAN`, `RECORD`), which
  `FieldType` reads alongside the new ones.
