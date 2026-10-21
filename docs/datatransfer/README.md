[Docs](../README.md) › Data Transfer

# 🔁 BigQuery Data Transfer

A client for BigQuery Data Transfer's v1 API, for a console's scheduled
queries and Data Transfers views: the locations a project's transfer
configs live in, the configs (BigQuery's scheduled queries among them)
with their schedules, their runs and each run's messages, and one write
a console confirms before sending: [run a config now](#run-now). Nothing
here creates, updates or deletes a config. **Experimental**: new in
0.56.0.

```zig
const std = @import("std");
const auth = @import("auth");
const datatransfer = @import("datatransfer");

pub fn main(init: std.process.Init) !void {
    const arena = init.arena.allocator();
    const lookup = try auth.Lookup.fromEnv(init.environ_map, arena);
    var creds = try auth.findDefault(init.gpa, init.io, lookup, .{});
    defer creds.deinit();
    var client = try datatransfer.Client.init(init.gpa, init.io, .{
        .project_id = "my-project",
        .token_provider = creds.provider(),
    });
    defer client.deinit();
    // Configs live in a location, listed one location at a time.
    var locations = try client.listLocations(.{});
    defer locations.deinit();
    for (locations.value.locations) |location| {
        var configs = try client.listTransferConfigs(location.id, .{ .data_sources = &.{"scheduled_query"} });
        defer configs.deinit();
        for (configs.value.configs) |config| {
            std.debug.print("{s} {s}: {t}\n", .{ location.id, config.display_name, config.state });
        }
    }
}
```

## The calls

| Call | What it does |
| --- | --- |
| `Client.listLocations(options)` | The locations configs can live in: `us`, `europe`, the regions and BigQuery Omni's, 54 on one page when measured |
| `Client.listTransferConfigs(location, options)` | One page of a location's configs, by data source (`scheduled_query` for scheduled queries alone) |
| `Client.getTransferConfig(name)` | One config, with its owner, which a list leaves out |
| `Client.listRuns(config_name, options)` | One page of a config's runs, newest run time first, by state, every attempt or `latest_only` (one a run date) |
| `Client.getRun(name)` | One run: its state, times and error |
| `Client.listMessages(run_name, options)` | One page of a run's messages, newest first, by severity |
| `Client.startManualRun(config_name, options)` | Runs the config now, or for a time given ([Run now](#run-now)) |
| `Client.startManualRunRequest(config_name, options)` | The exact request a run now would send, built without sending it |
| `Client.configName(arena, location, id)` | A config's name in this project, from its location and id |

Every call about a config or a run takes its **name as a list or get
gave it**, `projects/{p}/locations/{l}/transferConfigs/{id}[/runs/{run}]`.
Production names the project by number (`projects/82150720798/...`), and
takes the project id as readily. A regionless name
(`projects/{p}/transferConfigs/{id}`), which production answers only for
a config in the US, is refused before sending.

A `TransferConfig` carries its **`schedule`**, one union for both of the
API's shapes, which production answers together: `.time_based` (its cron
text, such as `every 24 hours`, and its start and end), `.manual` (run
only by hand), `.event_driven`, or `.default`. Then its `next_run_time`
(none for a manual or a disabled config), `state` (its latest run's,
`.unknown` before its first), `disabled`, destination dataset and
`dataset_region`, `owner_email` (from a get), `params` (each key with its
value's JSON text) and, for a scheduled query, **`scheduled_query`**: the
query text, destination table template, write disposition and
partitioning field. A `TransferRun` carries its `state`, `schedule_time`,
`run_time` (a scheduled query's `@run_time`), start, end and update
times, and its `error`; `ended()`, `succeeded()` and `failed()`.

## Locations

Configs live in a location, the destination dataset's, and **production
lists them one location at a time, with no value for every one**: `-`
is refused ("BigQuery Data Transfer Service does not yet support
location: unknown"), and the client refuses it before sending. A console
walks `listLocations`, as the example above does; 54 locations is 54
lists, each cheap. `listLocations` sends no page size: production refused
one ("Request contains an invalid argument.").

## Run now

`startManualRun` runs a config now: a scheduled query runs as if its
schedule had come, `@run_time` the time sent. It answers the run it
started, `PENDING`; follow it with `getRun` until `ended()`. A console
that shows the user what it is about to send asks the twin first:

<!-- snippet: tests/docs_examples.zig#datatransfer-confirm -->
```zig
test "the exact run now a console would send, for the user to confirm" {
    var fake: core.testing.FakeTransport = .init(std.testing.allocator, &.{});
    defer fake.deinit();
    var token: datatransfer.StaticToken = .{ .token = "none" };
    var client = try datatransfer.Client.init(std.testing.allocator, std.testing.io, .{
        .project_id = "my-project",
        .token_provider = token.provider(),
        .transport = fake.transport(),
    });
    defer client.deinit();
    // The config's name as the list gave it; one time for the preview and
    // the run, so the run sends byte for byte what the user confirmed.
    const config = "projects/82150720798/locations/us/transferConfigs/6ad99c4e-0000-2bb7-b042-14223bbd2862";
    const options: datatransfer.StartManualRunOptions = .{ .run_time = std.Io.Clock.real.now(std.testing.io) };
    var request = try client.startManualRunRequest(config, options);
    defer request.deinit();
    try std.testing.expectEqual(.POST, request.value.method);
    try std.testing.expectEqualStrings("https://bigquerydatatransfer.googleapis.com/v1/" ++ config ++ ":startManualRuns", request.value.url);
    try std.testing.expect(std.mem.startsWith(u8, request.value.body, "{\"requestedRunTime\":\""));
    // Built, not sent.
    try std.testing.expectEqual(0, fake.requests.items.len);
}
```

- **A time other than now** re-runs that moment: `.run_time` set to a
  day's midnight re-runs that day (`@run_date`). Production took a time
  60 s ahead of its own as readily as a past one, though the docs say it
  must be past, so a clock running ahead is no refusal.
- **Sent once.** A run now has no request id, and production started a
  second run when sent the same time twice, so the client never sends one
  again once it may have reached the server, as Google's clients never
  retry it. Only a refused connection or a failed name lookup is tried
  again. After any other failure, list the config's runs, newest first,
  to see whether it started.
- **A disabled config is refused**: 400 `error.InvalidArgument`,
  "Transfer is disabled. Please enable the transfer config before
  starting transfer runs."

`examples/datatransfer_runs.zig` lists every location's scheduled
queries with their latest runs, and with `--run NAME --yes` runs one now
and follows it to its end; `--fake` needs no network. For tests of code
like it, see [Testing](testing.md).

## The scope

A client asks its token provider for one scope, `Client.Options.scope`:

| `Scope` | Asks for | Serves |
| --- | --- | --- |
| `.bigquery`, the default | `bigquery` | Everything here; the same token serves `bigquery.Client` |
| `.cloud_platform` | `cloud-platform` | Everything here, for credentials already fixed to it |
| `.cloud_platform_read_only` | `cloud-platform.read-only` | Every read; not a run now, which the client refuses before sending (`error.InvalidOptions`), as production refuses one ("Request had insufficient authentication scopes.") |

Data Transfer has no permissions of its own; BigQuery's say what a token
may do:

| Call | Takes |
| --- | --- |
| `listLocations` | Nothing named |
| The other reads | `bigquery.transfers.get` (BigQuery User, Viewer, Editor, BigQuery Admin) |
| `startManualRun` | `bigquery.transfers.update` (Editor, BigQuery Admin; not BigQuery User) |

A scheduled query runs as its owner, `owner_email`, who needs
`bigquery.jobs.create` in the project and access to what the query reads.

## What production showed

Measured on 2026-10-21 in a test project, with scheduled queries made for
the measurement and deleted after:

- **A run now answered at once**, its run `PENDING`; it read `RUNNING`
  within 3 s, and a scheduled query of literals ended `SUCCEEDED` 75 s
  after it started. A failing one (`SELECT 1 / 0`) ended `FAILED` with
  its error, code 3: "division by zero: 1 / 0; JobID:
  <project number>:US.scheduled_query_<run id>". A success carries an
  empty error, which the client reads as none.
- **A run's messages come newest first**: for a success, five INFO lines
  ending "Summary: succeeded 1 jobs, failed 0 jobs."; for a failure, one
  ERROR: "BigQuery job scheduled_query_<run id> (table <table>) failed
  with error INVALID_ARGUMENT: division by zero: 1 / 0; JobID: <job>.
  Check BigQuery job details for more information."
- **Runs list newest run time first**; `latest_only` gave one run per run
  date, the latest of each. **Configs list by id.**
- A config's `state` is its latest run's (`SUCCEEDED`, `FAILED`), absent
  before its first; its `error` stayed empty after its run failed, so the
  runs say why.
- A config nobody has is 404: "The requested transfer config
  (projects/<p>/locations/<l>/transferConfigs/<id>) was not found."; a
  config read in a location it is not in, the same; a run nobody has,
  "The requested transfer run (<name>) was not found."; a location that
  is none, 400 "Request uses an invalid location: <l>". `US` in capitals
  is served as `us`.
