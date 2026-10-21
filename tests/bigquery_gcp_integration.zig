//! Integration tests against real BigQuery, which has no emulator:
//! milestone 4 of the BigQuery spec. They need a project with the API on
//! and a token that may run queries there and make a dataset (BigQuery
//! Job User and Data Editor, or Editor), for the `bigquery` or
//! `cloud-platform` scope:
//!
//!     GCP_TEST_PROJECT=extractctl GCP_TEST_TOKEN=$(cat token.txt) \
//!     BIGQUERY_TEST=1 zig build test-integration-gcp -Dtest-filter="bigquery:"
//!
//! Without the variables the test skips. The suite reads the public
//! samples; makes a `zigps_<run>` dataset with a typed table, a
//! partitioned and clustered one, and a view, through DDL the client
//! runs as queries; dry-runs, runs, pages, polls, refuses (a syntax
//! error, a bytes limit, the wrong location) and cancels; holds every
//! preview byte for byte to what was sent; then replays the same script
//! on a fake seeded from production's reads and answers, every outcome
//! and every word held equal. The dataset is dropped at the end, and a
//! crashed run's is swept by the next. Every query sets a bytes limit of
//! 100 MB or less, so the suite stays inside the free tier: about 100 MiB
//! billed a run. About two minutes.

const std = @import("std");
const core = @import("core");
const bigquery = @import("bigquery");
const testing = std.testing;
const Allocator = std.mem.Allocator;
const FakeBigQuery = bigquery.testing.FakeBigQuery;

const hamlet = "SELECT word, word_count FROM `bigquery-public-data.samples.shakespeare` WHERE corpus = 'hamlet' ORDER BY word_count DESC LIMIT 5";
const words_25 = "SELECT word FROM `bigquery-public-data.samples.shakespeare` WHERE corpus = 'hamlet' ORDER BY word LIMIT 25";
const slow = "SELECT COUNT(*) AS n FROM UNNEST(GENERATE_ARRAY(1, 1000000)) AS a CROSS JOIN UNNEST(GENERATE_ARRAY(1, 3000)) AS b";
const slow_cancelled = slow ++ " -- to cancel";
const syntax_error = "SELECT 1\n  WHERE";
const limit = 100_000_000;
const shakespeare: bigquery.TableRef = .{ .project = "bigquery-public-data", .dataset = "samples", .table = "shakespeare" };

/// Every request sent, in order, through any transport.
const Recorder = struct {
    inner: core.transport.Transport,
    arena: std.heap.ArenaAllocator,
    sent: std.ArrayList(Sent) = .empty,

    const Sent = struct { method: core.transport.Method, url: []const u8, body: []const u8 };

    fn init(inner: core.transport.Transport) Recorder {
        return .{ .inner = inner, .arena = .init(testing.allocator) };
    }

    fn deinit(r: *Recorder) void {
        r.arena.deinit();
    }

    fn transport(r: *Recorder) core.transport.Transport {
        return .{ .ptr = r, .vtable = &.{ .send = send } };
    }

    fn send(ptr: *anyopaque, req: core.transport.Request, arena: Allocator) core.transport.Error!core.transport.Response {
        const r: *Recorder = @ptrCast(@alignCast(ptr));
        const a = r.arena.allocator();
        try r.sent.append(a, .{ .method = req.method, .url = try a.dupe(u8, req.url), .body = try a.dupe(u8, req.body orelse "") });
        return r.inner.send(req, arena);
    }

    fn last(r: *const Recorder) Sent {
        return r.sent.items[r.sent.items.len - 1];
    }
};

const Run = struct {
    client: *bigquery.Client,
    diag: *bigquery.Diagnostics,
    recorder: *Recorder,
    arena: Allocator,
    dataset: []const u8,
    /// Each step's outcome, ids and times left out: what a replay must
    /// match.
    outcomes: std.ArrayList([]const u8) = .empty,
    /// On the production run, the fake it seeds with what production
    /// answered, which the fake copies as it is given.
    seeds: ?*FakeBigQuery,
    /// Whether production's dry run of Hamlet was served from the cache,
    /// which the fake is to answer alike.
    hamlet_cached: bool = false,

    fn note(r: *Run, comptime fmt: []const u8, args: anytype) !void {
        const line = try std.fmt.allocPrint(r.arena, fmt, args);
        std.debug.print("bigquery: {s}\n", .{line});
        try r.outcomes.append(r.arena, line);
    }

    /// An error and BigQuery's words for it, any job id written `<job>`.
    fn noteError(r: *Run, step: []const u8, err: anyerror, job: ?[]const u8) !void {
        var words = r.diag.message();
        if (job) |id| words = try std.mem.replaceOwned(u8, r.arena, words, id, "<job>");
        try r.note("{s}: error.{t}: {s}", .{ step, err, words });
    }

    fn table(r: *Run, id: []const u8) bigquery.TableRef {
        return .{ .dataset = r.dataset, .table = id };
    }

    /// The query, its answer kept for the fake when this is production.
    fn query(r: *Run, step: []const u8, options: bigquery.QueryOptions, tables: []const bigquery.TableRef) !?bigquery.Owned(bigquery.QueryPage) {
        var page = r.client.query(options) catch |err| {
            try r.noteError(step, err, null);
            if (r.seeds) |fake| try fake.answer(options.query, .{ .refusal = .{
                .status = statusOf(err),
                .reason = reasonOf(err),
                .message = r.diag.message(),
            } });
            return null;
        };
        errdefer page.deinit();
        try r.notePage(step, page.value);
        if (r.seeds) |fake| if (page.value.complete) try fake.answer(options.query, answerOf(page.value, tables));
        return page;
    }

    /// An answer that bills what production billed: a table read when it
    /// billed anything or the cache served it, none when it billed
    /// nothing.
    fn answerOf(page: bigquery.QueryPage, tables: []const bigquery.TableRef) FakeBigQuery.Answer {
        const billed = (page.total_bytes_billed orelse 0) > 0;
        return .{
            .schema = page.schema,
            .rows = page.rows,
            .tables = if (billed or page.cache_hit == true) tables else &.{},
            .bytes_processed = page.total_bytes_processed orelse 0,
            .statement_type = page.statement_type,
            .num_dml_affected_rows = page.num_dml_affected_rows,
            .cached = page.cache_hit == true,
        };
    }

    fn notePage(r: *Run, step: []const u8, page: bigquery.QueryPage) !void {
        var w: std.Io.Writer.Allocating = .init(r.arena);
        try w.writer.print("{s}: complete={} rows={d}", .{ step, page.complete, page.rows.len });
        if (page.complete) {
            try w.writer.print(" total={?d} more={} billed={?d} statement={s} dml={?d} columns=", .{
                page.total_rows, page.page_token != null, page.total_bytes_billed, page.statement_type, page.num_dml_affected_rows,
            });
            for (page.schema) |f| try w.writer.print("{s}:{t}:{t},", .{ f.name, f.type, f.mode });
        }
        for (page.rows) |row| {
            try w.writer.writeAll(" |");
            for (row.cells) |cell| try w.writer.print(" {f}", .{cell.value});
        }
        try r.note("{s}", .{w.written()});
    }
};

fn statusOf(err: anyerror) u16 {
    return switch (err) {
        error.PermissionDenied => 403,
        error.NotFound => 404,
        else => 400,
    };
}

fn reasonOf(err: anyerror) []const u8 {
    return switch (err) {
        error.InvalidQuery => "invalidQuery",
        error.BytesBilledLimitExceeded => "bytesBilledLimitExceeded",
        error.PermissionDenied => "accessDenied",
        error.NotFound => "notFound",
        else => "invalid",
    };
}

/// The suite's script, run against production and then the fake.
fn script(r: *Run) !void {
    const c = r.client;
    const a = r.arena;

    // The public samples, read from this project.
    {
        var samples = try c.getDataset(.{ .project = "bigquery-public-data", .dataset = "samples" });
        defer samples.deinit();
        try r.note("samples: location={s} labels={d}", .{ samples.value.location, samples.value.labels.len });
        if (r.seeds) |fake| try fake.putDataset(samples.value);
        var tables = try c.listTables(.{ .project = "bigquery-public-data", .dataset = "samples" }, .{ .page_size = 3 });
        defer tables.deinit();
        for (tables.value.tables) |t| {
            try r.note("samples table: {s} {t}", .{ t.ref.table, t.type });
            if (!std.mem.eql(u8, t.ref.table, "shakespeare")) if (r.seeds) |fake| try fake.putTable(t);
        }
        var table = try c.getTable(shakespeare);
        defer table.deinit();
        try r.note("shakespeare: rows={?d} bytes={?d} columns={d}", .{ table.value.num_rows, table.value.num_bytes, table.value.schema.len });
        if (r.seeds) |fake| try fake.putTable(table.value);
    }

    // The suite's dataset and tables, made by DDL the client runs.
    const ddl = [_][]const u8{
        try std.fmt.allocPrint(a, "CREATE SCHEMA `{s}` OPTIONS (location = 'US', labels = [('zigps', 'suite')], default_table_expiration_days = 1)", .{r.dataset}),
        try std.fmt.allocPrint(a,
            \\CREATE TABLE `{s}.typed` AS SELECT 1 AS int64, 1.5 AS float64, NUMERIC '123.456' AS numeric, TRUE AS bool, 'héllo' AS string,
            \\ b'\x00\xffab' AS bytes, DATE '2026-10-21' AS date, TIME '13:14:15.123456' AS time, DATETIME '2026-10-21 13:14:15.123456' AS datetime,
            \\ TIMESTAMP '2026-10-21 13:14:15.123456+00' AS ts, ST_GEOGPOINT(-122.35, 47.62) AS geography, JSON '{{"a":[1,2]}}' AS json,
            \\ INTERVAL 3 DAY AS iv, RANGE(DATE '2024-01-01', NULL) AS span, [1, 2, 3] AS array_int, STRUCT(1 AS x, 'y' AS y) AS record
        , .{r.dataset}),
        try std.fmt.allocPrint(a, "CREATE TABLE `{s}.events` (ts TIMESTAMP, user STRING, n INT64) PARTITION BY DATE(ts) CLUSTER BY user OPTIONS (description = 'zigps events')", .{r.dataset}),
        try std.fmt.allocPrint(a, "INSERT `{s}.events` (ts, user, n) VALUES (TIMESTAMP '2026-10-21 01:00:00+00', 'a', 1), (TIMESTAMP '2026-10-20 02:00:00+00', 'b', 2)", .{r.dataset}),
        try std.fmt.allocPrint(a, "CREATE VIEW `{s}.recent` AS SELECT user, n FROM `{s}.events` WHERE n > 0", .{ r.dataset, r.dataset }),
    };
    for (ddl, 0..) |text, i| {
        var page = (try r.query(try std.fmt.allocPrint(a, "ddl {d}", .{i}), .{ .query = text, .maximum_bytes_billed = limit }, &.{})) orelse return error.TestUnexpectedResult;
        page.deinit();
    }
    {
        var ours = try c.getDataset(.{ .dataset = r.dataset });
        defer ours.deinit();
        try r.note("dataset: location={s} labels={s}={s} expiration={?d}", .{ ours.value.location, ours.value.labels[0].key, ours.value.labels[0].value, ours.value.default_table_expiration_ms });
        if (r.seeds) |fake| try fake.putDataset(ours.value);
        var tables = try c.listTables(.{ .dataset = r.dataset }, .{});
        defer tables.deinit();
        for (tables.value.tables) |t| try r.note("table: {s} {t} partitioned={} clustered={d}", .{ t.ref.table, t.type, t.time_partitioning != null, t.clustering.len });
        for ([_][]const u8{ "events", "recent", "typed" }) |id| {
            var t = try c.getTable(r.table(id));
            defer t.deinit();
            try r.note("table {s}: rows={?d} columns={d} view={} partition={s} description={s}", .{
                id,                                                t.value.num_rows,    t.value.schema.len, t.value.view_query != null,
                if (t.value.time_partitioning) |p| p.type else "", t.value.description,
            });
            if (r.seeds) |fake| try fake.putTable(t.value);
        }
    }

    // A dry run, then the run, from the cache and not.
    {
        var dry = try c.dryRun(.{ .query = hamlet });
        defer dry.deinit();
        try r.note("dry run: bytes={?d} cache={?} columns={d} statement={s}", .{ dry.value.total_bytes_processed, dry.value.cache_hit, dry.value.schema.len, dry.value.statement_type });
        var run = try c.query(.{ .query = hamlet, .use_query_cache = false, .maximum_bytes_billed = limit });
        defer run.deinit();
        try r.notePage("hamlet", run.value);
        if (r.seeds) |fake| {
            var answer = Run.answerOf(run.value, &.{shakespeare});
            // As the dry run found the cache, whatever this run, which
            // passed it by, says.
            answer.cached = dry.value.cache_hit == true;
            try fake.answer(hamlet, answer);
        }
        var typed = (try r.query("typed", .{ .query = try std.fmt.allocPrint(a, "SELECT * FROM `{s}.typed`", .{r.dataset}), .maximum_bytes_billed = limit }, &.{r.table("typed")})).?;
        typed.deinit();
        var view = (try r.query("view", .{ .query = try std.fmt.allocPrint(a, "SELECT * FROM `{s}.recent` ORDER BY n", .{r.dataset}), .maximum_bytes_billed = limit }, &.{r.table("events")})).?;
        view.deinit();
    }

    // The refusals.
    if (try r.query("syntax", .{ .query = syntax_error }, &.{})) |p| {
        var page = p;
        page.deinit();
    }
    if (c.dryRun(.{ .query = syntax_error })) |d| {
        var dry = d;
        dry.deinit();
        try r.note("dry syntax: answered", .{});
    } else |err| try r.noteError("dry syntax", err, null);
    if (c.query(.{ .query = hamlet, .use_query_cache = false, .maximum_bytes_billed = 1000 })) |p| {
        var page = p;
        page.deinit();
        try r.note("over limit: answered", .{});
    } else |err| try r.noteError("over limit", err, null);
    if (c.query(.{ .query = hamlet, .location = "EU", .maximum_bytes_billed = limit })) |p| {
        var page = p;
        page.deinit();
        try r.note("wrong location: answered", .{});
    } else |err| try r.noteError("wrong location", err, null);

    // Pages.
    {
        var first = try c.query(.{ .query = words_25, .page_size = 10, .maximum_bytes_billed = limit });
        defer first.deinit();
        try r.notePage("pages", first.value);
        const job = first.value.job.?;
        var token = first.value.page_token;
        var pages: [4]bigquery.Owned(bigquery.QueryPage) = undefined;
        var n: usize = 0;
        defer for (pages[0..n]) |*p| p.deinit();
        var all: std.ArrayList(bigquery.Row) = .empty;
        try all.appendSlice(a, first.value.rows);
        while (token) |t| : (n += 1) {
            if (n == pages.len) return error.TestUnexpectedResult;
            pages[n] = try c.getQueryResults(job, .{ .page_token = t, .page_size = 10 });
            try r.notePage("next page", pages[n].value);
            try all.appendSlice(a, pages[n].value.rows);
            token = pages[n].value.page_token;
        }
        // The fake is given every page's rows, as the job holds them.
        if (r.seeds) |fake| {
            var answer = Run.answerOf(first.value, &.{shakespeare});
            answer.rows = all.items;
            try fake.answer(words_25, answer);
        }
        var tail = try c.getQueryResults(job, .{ .start_index = 20 });
        defer tail.deinit();
        try r.notePage("from 20", tail.value);
    }

    // A query that outlives its timeout, polled to its end.
    {
        var started = try c.query(.{ .query = slow, .timeout_ms = 10, .use_query_cache = false, .maximum_bytes_billed = limit });
        defer started.deinit();
        var unfinished: u32 = if (started.value.complete) 0 else 1;
        const job = started.value.job.?;
        var page = try c.getQueryResults(job, .{ .timeout_ms = 2000 });
        defer page.deinit();
        while (!page.value.complete) {
            unfinished += 1;
            if (unfinished > 120) return error.TestUnexpectedResult;
            page.deinit();
            page = try c.getQueryResults(job, .{ .timeout_ms = 2000 });
        }
        try r.notePage("slow, polled", page.value);
        if (r.seeds) |fake| {
            var answer = Run.answerOf(page.value, &.{});
            answer.polls = unfinished;
            // A results page names no statement; the query's answer did.
            answer.statement_type = started.value.statement_type;
            try fake.answer(slow, answer);
        }
        std.debug.print("bigquery: (the slow query answered unfinished {d} times)\n", .{unfinished});
        var done = try c.getJob(job);
        defer done.deinit();
        try r.note("slow job: state={t} failed={}", .{ done.value.state, done.value.failed() });
    }

    // A cancel, and its preview.
    {
        var started = try c.query(.{ .query = slow_cancelled, .timeout_ms = 10, .use_query_cache = false, .maximum_bytes_billed = limit });
        defer started.deinit();
        try r.note("to cancel: complete={}", .{started.value.complete});
        // Cancelled long before it would end.
        if (r.seeds) |fake| try fake.answer(slow_cancelled, .{ .schema = &.{.{ .name = "n", .type = .int64 }}, .polls = 1000 });
        const job = started.value.job.?;
        var preview = try c.cancelJobRequest(job);
        defer preview.deinit();
        var cancelled = try c.cancelJob(job);
        defer cancelled.deinit();
        const sent = r.recorder.last();
        try testing.expectEqualStrings(preview.value.url, sent.url);
        try testing.expectEqualStrings(preview.value.body, sent.body);
        try r.note("cancel: state={t} failed={}", .{ cancelled.value.state, cancelled.value.failed() });
        var ended = try c.getJob(job);
        defer ended.deinit();
        var reads: usize = 0;
        while (ended.value.state != .done) : (reads += 1) {
            if (reads > 60) return error.TestUnexpectedResult;
            try testing.io.sleep(.fromMilliseconds(1000), .awake);
            ended.deinit();
            ended = try c.getJob(job);
        }
        try r.note("cancelled: failed={} reason={s} message={s}", .{ ended.value.failed(), ended.value.@"error".?.reason, ended.value.@"error".?.message });
        var again = try c.cancelJob(job);
        defer again.deinit();
        try r.note("cancel again: state={t} failed={}", .{ again.value.state, again.value.failed() });
        if (c.getJob(.{ .id = job.id, .location = "EU" })) |j| {
            var wrong = j;
            wrong.deinit();
            try r.note("wrong location: answered", .{});
        } else |err| try r.noteError("job elsewhere", err, job.id);
    }

    // A request id given twice answers the first job.
    {
        var id_buf: [36]u8 = undefined;
        const options: bigquery.QueryOptions = .{ .query = "SELECT 17 AS n", .use_query_cache = false, .request_id = c.newRequestId(&id_buf) };
        var preview = try c.queryRequest(options);
        defer preview.deinit();
        var first = (try r.query("request id", options, &.{})).?;
        defer first.deinit();
        try testing.expectEqualStrings(preview.value.url, r.recorder.last().url);
        try testing.expectEqualStrings(preview.value.body, r.recorder.last().body);
        var repeat = try c.query(options);
        defer repeat.deinit();
        try r.note("repeat: same job={} complete={}", .{ std.mem.eql(u8, first.value.job.?.id, repeat.value.job.?.id), repeat.value.complete });
        var dry_preview = try c.dryRunRequest(.{ .query = hamlet });
        defer dry_preview.deinit();
        var dry = try c.dryRun(.{ .query = hamlet });
        defer dry.deinit();
        try testing.expectEqualStrings(dry_preview.value.body, r.recorder.last().body);
    }

    // The history holds the suite's jobs, newest first.
    {
        var page = try c.listJobs(.{ .states = &.{.done}, .page_size = 100 });
        defer page.deinit();
        var found: usize = 0;
        for (page.value.jobs) |j| {
            if (std.mem.eql(u8, j.query, slow) or std.mem.eql(u8, j.query, slow_cancelled)) found += 1;
        }
        try r.note("history: both slow jobs listed={}", .{found >= 2});
    }
}

/// Drops `ours`, the run's own dataset, and any other `zigps_` dataset
/// labelled for the suite more than a day old, left by a crashed run;
/// another run's younger one may still be in use.
fn sweep(client: *bigquery.Client, arena: Allocator, ours: ?[]const u8) void {
    var page = client.listDatasets(.{ .label_filter = "labels.zigps:suite" }) catch |err| {
        std.debug.print("bigquery: sweep could not list: {t}\n", .{err});
        return;
    };
    defer page.deinit();
    for (page.value.datasets) |d| {
        if (!std.mem.startsWith(u8, d.ref.dataset, "zigps_")) continue;
        const own = if (ours) |o| std.mem.eql(u8, d.ref.dataset, o) else false;
        if (!own) {
            var full = client.getDataset(d.ref) catch continue;
            defer full.deinit();
            const created = full.value.creation_time orelse continue;
            const age = created.durationTo(std.Io.Clock.real.now(testing.io)).toSeconds();
            if (age < 24 * 3600) continue;
        }
        const text = std.fmt.allocPrint(arena, "DROP SCHEMA `{s}` CASCADE", .{d.ref.dataset}) catch return;
        if (client.query(.{ .query = text, .maximum_bytes_billed = limit })) |p| {
            var done = p;
            done.deinit();
            std.debug.print("bigquery: dropped {s}\n", .{d.ref.dataset});
        } else |err| std.debug.print("bigquery: could not drop {s}: {t}\n", .{ d.ref.dataset, err });
    }
}

test "bigquery: the public samples, a dataset of our own, queries run, paged, polled, refused and cancelled; replayed on the fake" {
    const gpa = testing.allocator;
    var env = try testing.environ.createMap(gpa);
    defer env.deinit();
    const project = env.get("GCP_TEST_PROJECT") orelse return error.SkipZigTest;
    const token_text = env.get("GCP_TEST_TOKEN") orelse return error.SkipZigTest;
    if (env.get("BIGQUERY_TEST") == null) return error.SkipZigTest;
    var token: core.StaticToken = .{ .token = std.mem.trim(u8, token_text, &std.ascii.whitespace) };
    var arena_state: std.heap.ArenaAllocator = .init(gpa);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    var bytes: [3]u8 = undefined;
    testing.io.random(&bytes);
    const dataset = try std.fmt.allocPrint(a, "zigps_{x}", .{bytes});

    // Production.
    var http: core.transport.HttpTransport = .init(gpa, testing.io, "zig-gcp-bigquery-gcp-integration/0.1");
    defer http.deinit();
    var recorder: Recorder = .init(http.transport());
    defer recorder.deinit();
    var diag: bigquery.Diagnostics = .{};
    var client = try bigquery.Client.init(gpa, testing.io, .{
        .project_id = project,
        .token_provider = token.provider(),
        .diagnostics = &diag,
        .transport = recorder.transport(),
        .request_timeout_ms = 60_000,
    });
    defer client.deinit();
    defer sweep(&client, a, dataset);
    sweep(&client, a, null);
    // Seeded with what production answers as the script runs, then given
    // the same script.
    var fake: FakeBigQuery = .init(gpa, testing.io, .{ .project_id = project });
    defer fake.deinit();
    var live: Run = .{ .client = &client, .diag = &diag, .recorder = &recorder, .arena = a, .dataset = dataset, .seeds = &fake };
    try script(&live);

    var fake_recorder: Recorder = .init(fake.transport());
    defer fake_recorder.deinit();
    var fake_diag: bigquery.Diagnostics = .{};
    var fake_client = try bigquery.Client.init(gpa, testing.io, .{
        .project_id = project,
        .token_provider = token.provider(),
        .diagnostics = &fake_diag,
        .transport = fake_recorder.transport(),
    });
    defer fake_client.deinit();
    var replay: Run = .{ .client = &fake_client, .diag = &fake_diag, .recorder = &fake_recorder, .arena = a, .dataset = dataset, .seeds = null };
    try script(&replay);

    var differences: usize = 0;
    for (live.outcomes.items, 0..) |want, i| {
        const got = if (i < replay.outcomes.items.len) replay.outcomes.items[i] else "(none)";
        if (!std.mem.eql(u8, want, got)) {
            differences += 1;
            std.debug.print("bigquery replay differs at step {d}:\n  production: {s}\n  fake:       {s}\n", .{ i, want, got });
        }
    }
    try testing.expectEqual(live.outcomes.items.len, replay.outcomes.items.len);
    try testing.expectEqual(0, differences);
    std.debug.print("bigquery: {d} outcomes, production and fake agree\n", .{live.outcomes.items.len});
}
