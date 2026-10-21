[Docs](../README.md) › [BigQuery](README.md) › Testing

# Testing with the in-memory BigQuery

`bigquery.testing.FakeBigQuery` is BigQuery in memory, behind
`Client.Options.transport`, for tests of code that browses datasets and
tables, reads the job history, and runs queries: a console's query
editor's tests, say, with no network and no project. It answers the
module's calls as production answered them when measured
(experimental, as the module is).

**There is no SQL engine.** A test gives each query text its `Answer`:
the schema and rows of its results (as `Value`s, written as production
writes them), the tables it reads, the bytes it processes, how many
reads of it answer it unfinished, whether the cache serves it, or the
refusal it meets in BigQuery's words. A query nobody answered is 501,
"fake: no answer was given for this query text". What production holds
besides is the test's to put in as a get answers it: `putDataset`,
`putTable` (schema and all) and `putJob`, any project's, so
`bigquery-public-data` can sit beside the test's own.

<!-- snippet: tests/docs_examples.zig#bigquery-fake -->
```zig
test "a query editor's run, against the in-memory BigQuery" {
    var fake: bigquery.testing.FakeBigQuery = .init(std.testing.allocator, std.testing.io, .{ .project_id = "my-project" });
    defer fake.deinit();
    // No SQL engine: the test says what each query text answers.
    const text = "SELECT word, word_count FROM `bigquery-public-data.samples.shakespeare` WHERE corpus = 'hamlet' ORDER BY word_count DESC LIMIT 2";
    try fake.answer(text, .{
        .schema = &.{ .{ .name = "word", .type = .string }, .{ .name = "word_count", .type = .int64 } },
        .rows = &.{
            .{ .cells = &.{ .{ .value = .{ .string = "the" } }, .{ .value = .{ .int64 = 995 } } } },
            .{ .cells = &.{ .{ .value = .{ .string = "and" } }, .{ .value = .{ .int64 = 706 } } } },
        },
        .tables = &.{.{ .project = "bigquery-public-data", .dataset = "samples", .table = "shakespeare" }},
        .bytes_processed = 5_114_816,
        // Unfinished for the first read, as a slow job answers.
        .polls = 1,
    });
    var token: bigquery.StaticToken = .{ .token = "none" };
    var client = try bigquery.Client.init(std.testing.allocator, std.testing.io, .{
        .project_id = "my-project",
        .token_provider = token.provider(),
        .transport = fake.transport(),
    });
    defer client.deinit();

    var dry = try client.dryRun(.{ .query = text });
    defer dry.deinit();
    try std.testing.expectEqual(5_114_816, dry.value.total_bytes_processed.?);
    // Under its bill: a table read bills at least 10 MiB.
    try std.testing.expectError(error.BytesBilledLimitExceeded, client.query(.{ .query = text, .maximum_bytes_billed = 1_000_000 }));

    var page = try client.query(.{ .query = text, .maximum_bytes_billed = 100_000_000 });
    defer page.deinit();
    try std.testing.expect(!page.value.complete);
    var done = try client.getQueryResults(page.value.job.?, .{});
    defer done.deinit();
    try std.testing.expect(done.value.complete);
    try std.testing.expectEqualStrings("the", done.value.rows[0].cells[0].value.string);
    try std.testing.expectEqual(995, done.value.rows[0].cells[1].value.int64);
    try std.testing.expectEqual(1, fake.queryCount());
}
```

`callCount()`, `jobCount()` and `queryCount()` say what reached the
fake: `queryCount` counts the queries run, not a repeat answered from
its request id, so a test can hold a retried query to one run.

## What it models

Each as production answered when measured on 2026-10-21:

- **A dry run** answers the bytes, the schema, the statement type and
  whether the cache would serve the query, and makes no job.
- **A run** makes a job in the history, owned by `Options.user_email`
  (so listed without `all_users`): done at once, or running for as many
  reads as the answer's `polls`, each answering it unfinished with its
  job and nothing else, as production answers a query that outlives
  `timeoutMs`.
- **Billing**: nothing for a query that reads no table or one the cache
  answers; otherwise the bytes rounded up to a MiB, at least 10 MiB a
  table read (production's minimum, measured for one table). A
  `maximumBytesBilled` below that refuses the run, "Query exceeded
  limit for bytes billed: <limit>. <bill> or higher required.", billing
  nothing; a dry run is not held to it.
- **A request id** sent again within 15 minutes with the same text
  answers the first job, unfinished and without rows, as production
  answered one that had ended; with another text it makes a new job.
  A query whose first answer was lost is retried with its id, so it runs
  once.
- **Results** page by token, by `maxResults` and by `startIndex`;
  `maxResults` 0 answers the schema, the count and a token, no rows. A
  statement other than a SELECT (DDL, DML) answers no row count, as
  production's CREATE, INSERT and the like answered none.
- **A cancel** answers the job as it stands, running when it was; the
  job is then done with the error `stopped`, "Job execution was
  cancelled: User requested cancellation". A cancel of a done job
  answers it, no refusal.
- **Where a job is**: found without a location when it is in the US or
  the EU, and not found with another location's, "Not found: Job
  <project>:<location>.<id>". A query asked to run somewhere other than
  its tables is refused as production refused a US table queried in the
  EU: "Access Denied: Table <project>:<dataset>.<table>: User does not
  have permission to query table ..., or perhaps it does not exist."
- **Lists**: hidden datasets (an id starting with `_`) only with `all`,
  label filters as BigQuery takes them, a list's fields only (no schema,
  no row count); the history newest first, by state and creation time,
  the configuration left out of a minimal projection.
- **Refused in production's words**: "Not found: Dataset <p>:<d>",
  "Not found: Table <p>:<d>.<t>", "Not found: Project <p>", and a job
  nobody has. Faults a test asks for: `refuseNext`, `dropNext` and
  `loseNext`, as the other fakes have them.

`answer` refuses a row that does not fit its schema or holds a value no
wire could carry (a 13th month, say), and `putDataset`, `putTable` and
`putJob` an id taken or malformed, or a table whose dataset nobody put,
each with nothing kept.

Not modelled, answered 501 with the reason: legacy SQL, `jobs.insert`
and every write to datasets and tables, `tabledata.list`, the results
of a job put in rather than run here or of one cancelled, rows without
`formatOptions.useInt64Timestamp`, and a query billed to another
project.

A gated production suite (`tests/bigquery_gcp_integration.zig`,
`BIGQUERY_TEST=1`) reads the public samples, makes a `zigps_` dataset
with a typed table, a partitioned and clustered one and a view through
the client's own DDL, dry-runs, runs, pages, polls, refuses and
cancels, holds every preview byte for byte to what was sent, then
replays the same script on a fake seeded from production's answers.
Its 39 outcomes agree, every word included; the first runs taught the
fake that DDL and DML answer no row count.
