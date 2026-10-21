[Docs](../README.md) › [Data Transfer](README.md) › Testing

# Testing with the in-memory Data Transfer

`datatransfer.testing.FakeDataTransfer` is BigQuery Data Transfer in
memory, behind `Client.Options.transport`, for tests of code that reads
scheduled queries and their runs and runs one now: a console's tests,
say, with no network and no project. It answers the module's calls as
production answered them when measured (experimental, as the module is).

What production holds is the test's to put in: `putLocation`,
`putConfig` (a scheduled query's params typed, or any data source's as
JSON), `putRun` and `putMessage`. How a run now ends is the config's
`PutConfig.manual_run`: `.pending` until the test moves it with
`setRunState`, or `.succeeded` or `.failed` at once, with production's
lines for a scheduled query. Nothing moves on its own.

<!-- snippet: tests/docs_examples.zig#datatransfer-fake -->
```zig
test "a scheduled query's run now, against the in-memory Data Transfer" {
    var fake: datatransfer.testing.FakeDataTransfer = .init(std.testing.allocator, std.testing.io, .{ .project_id = "my-project" });
    defer fake.deinit();
    try fake.putLocation("us");
    // What production holds is the test's to put in; how a run now ends
    // is the test's to say.
    const config = try fake.putConfig(.{
        .location = "us",
        .display_name = "Daily orders",
        .destination_dataset_id = "reporting",
        .schedule = .{ .time_based = .{ .schedule = "every 24 hours" } },
        .scheduled_query = .{ .query = "SELECT COUNT(*) AS orders FROM shop.orders", .destination_table_name_template = "orders_{run_date}", .write_disposition = "WRITE_TRUNCATE" },
        .manual_run = .{ .failed = .{ .code = 3, .message = "Unrecognized name: created at [1:44]" } },
    });
    var token: datatransfer.StaticToken = .{ .token = "none" };
    var client = try datatransfer.Client.init(std.testing.allocator, std.testing.io, .{
        .project_id = "my-project",
        .token_provider = token.provider(),
        .transport = fake.transport(),
    });
    defer client.deinit();

    var page = try client.listTransferConfigs("us", .{ .data_sources = &.{"scheduled_query"} });
    defer page.deinit();
    try std.testing.expectEqualStrings("every 24 hours", page.value.configs[0].schedule.time_based.schedule);
    var started = try client.startManualRun(config, .{});
    defer started.deinit();
    try std.testing.expectEqual(.pending, started.value.runs[0].state);
    // This config's runs fail at once, with production's lines.
    var ended = try client.getRun(started.value.runs[0].name);
    defer ended.deinit();
    try std.testing.expect(ended.value.failed());
    var errors_only = try client.listMessages(ended.value.name, .{ .severities = &.{.@"error"} });
    defer errors_only.deinit();
    try std.testing.expectEqual(1, errors_only.value.messages.len);
    try std.testing.expectEqual(1, fake.runsStarted());
}
```

`callCount()` and `runsStarted()` say what reached the fake:
`runsStarted` counts runs now, so a test can hold a lost answer to one
run.

## What it models

Each as production answered when measured on 2026-10-21:

- **Names carry the project by number** (`Options.project_number`), and
  a path may name it by id or number.
- **Configs list one location at a time**, by id: `-` is refused,
  "BigQuery Data Transfer Service does not yet support location:
  unknown", and a location nobody put, "Request uses an invalid
  location: <l>", as production refused a made-up one. A list carries no
  owner; a get does. Both schedule shapes are written, as production
  writes them, and a config's state is its latest run's.
- **A run now** makes one run, `PENDING` in the answer, its `runTime`
  the time asked (production took one ahead of its own clock) and its
  `scheduleTime` now. Sent twice, it makes two. A disabled config is
  refused, "Transfer is disabled. Please enable the transfer config
  before starting transfer runs."
- **Runs** list newest run time first, `LATEST` one a run date, by state;
  **messages** newest first, by severity. A run that succeeded carries
  `errorStatus: {}`, as production writes it.
- **Refused in production's words**: a config nobody has, a run nobody
  has, a state outside the enum, a page size on the locations list, a
  request without a token. Faults a test asks for: `refuseNext`,
  `dropNext` and `loseNext`, as the other fakes have them; a lost answer
  to a run now leaves its run started, as a real one would.

`putLocation`, `putConfig`, `putRun`, `putMessage` and `setRunState`
refuse, with nothing kept, what production could not hold: a location
or config nobody put, an id taken or malformed, params that are not
JSON, a state of `.unknown`, a run moved on after it ended.

Not modelled, answered 501 with the reason: writes to configs, backfills
over a time range, deleting runs, data sources, the regionless paths, and
another project's.

A gated production suite (`tests/datatransfer_gcp_integration.zig`,
`DATATRANSFER_TEST=1`) makes a `zigps_dt_` dataset and three scheduled
queries raw (the client writes no configs), lists and reads them through
the client, runs two now with the request shown first, follows them to
their end, reads their runs and messages, meets production's refusals,
and replays the same script on a fake seeded from production's answers.
Its 18 outcomes agree, every word included; its first run taught the
fake that configs list by id.
