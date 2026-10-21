//! Run a BigQuery query as a console's query editor does: dry-run it and
//! say what it would read and bill, show the exact request, run it only
//! when confirmed, wait for it, and print its results as a table, a page
//! at a time.
//!
//!     GOOGLE_CLOUD_PROJECT=my-project zig build example-bigquery_query -- "SELECT 1 AS n"
//!     GOOGLE_CLOUD_PROJECT=my-project zig build example-bigquery_query -- "SELECT ..." --yes
//!     zig build example-bigquery_query -- --fake --yes     # no network
//!
//! Without `--yes` it prints the dry run and the request and stops: that
//! is the confirmation. Credentials come from `auth.findDefault`, with
//! the `bigquery` scope; IAM asks `bigquery.jobs.create` in the project
//! and read access to the tables the query reads. `--limit BYTES` caps
//! what the run may bill (100 MB when not given): over it the query fails
//! and bills nothing. `--fake` runs on `bigquery.testing.FakeBigQuery`
//! instead, with Hamlet's five most frequent words as the answer and a
//! job that takes two reads to finish.

const std = @import("std");
const auth = @import("auth");
const bigquery = @import("bigquery");

pub const std_options: std.Options = .{
    .log_scope_levels = &.{
        .{ .scope = .gcp_auth, .level = .warn },
        .{ .scope = .gcp_bigquery, .level = .warn },
    },
};

const usage = "usage: bigquery_query (QUERY | --fake) [--limit BYTES] [--yes]\n";

const hamlet = "SELECT word, word_count FROM `bigquery-public-data.samples.shakespeare` WHERE corpus = 'hamlet' ORDER BY word_count DESC LIMIT 5";

pub fn main(init: std.process.Init) !void {
    const arena = init.arena.allocator();
    var stdout_buffer: [4096]u8 = undefined;
    var stdout = std.Io.File.stdout().writerStreaming(init.io, &stdout_buffer);
    const out = &stdout.interface;
    var diag: bigquery.Diagnostics = .{};

    var use_fake = false;
    var confirmed = false;
    var limit: u64 = 100_000_000;
    var text: ?[]const u8 = null;
    const args = try init.minimal.args.toSlice(arena);
    var i: usize = @min(1, args.len);
    while (i < args.len) : (i += 1) {
        const arg = args[i];
        if (std.mem.eql(u8, arg, "--fake")) {
            use_fake = true;
        } else if (std.mem.eql(u8, arg, "--yes")) {
            confirmed = true;
        } else if (std.mem.eql(u8, arg, "--limit") and i + 1 < args.len) {
            limit = std.fmt.parseInt(u64, args[i + 1], 10) catch {
                std.debug.print(usage, .{});
                return error.Usage;
            };
            i += 1;
        } else if (!std.mem.startsWith(u8, arg, "--") and text == null) {
            text = arg;
        } else {
            std.debug.print(usage, .{});
            return error.Usage;
        }
    }
    if (use_fake and text == null) text = hamlet;
    const query = text orelse {
        std.debug.print(usage, .{});
        return error.Usage;
    };

    var fake: bigquery.testing.FakeBigQuery = .init(init.gpa, init.io, .{ .project_id = "my-project" });
    defer fake.deinit();
    var static: bigquery.StaticToken = .{ .token = "fake" };
    var creds: ?auth.Credentials = null;
    defer if (creds) |*c| c.deinit();
    const project = if (use_fake) "my-project" else init.environ_map.get("GOOGLE_CLOUD_PROJECT") orelse {
        std.debug.print("set GOOGLE_CLOUD_PROJECT to the project to run queries in\n", .{});
        return error.MissingProject;
    };
    if (!use_fake) {
        var lookup = try auth.Lookup.fromEnv(init.environ_map, arena);
        lookup.diagnostics = &diag;
        creds = try auth.findDefault(init.gpa, init.io, lookup, .{});
    }
    var client = try bigquery.Client.init(init.gpa, init.io, .{
        .project_id = project,
        .token_provider = if (creds) |*c| c.provider() else static.provider(),
        .transport = if (use_fake) fake.transport() else null,
        .diagnostics = &diag,
    });
    defer client.deinit();
    if (use_fake) try seed(&fake);

    run(out, &client, query, limit, confirmed) catch |err| {
        try out.print("refused: {t}: {s}\n", .{ err, diag.message() });
        if (bigquery.errorPosition(diag.message())) |at| try out.print("  at line {d}, column {d}\n", .{ at.line, at.column });
        try out.flush();
        return err;
    };
    try out.flush();
}

fn run(out: *std.Io.Writer, client: *bigquery.Client, query: []const u8, limit: u64, confirmed: bool) !void {
    // What it would read, for nothing: a syntax error shows up here.
    var dry = try client.dryRun(.{ .query = query });
    defer dry.deinit();
    const bytes = dry.value.total_bytes_processed orelse 0;
    try out.print("dry run: {s}, reads {d} bytes", .{ dry.value.statement_type, bytes });
    if (dry.value.cache_hit == true) try out.writeAll(" (answered from the cache: bills nothing)");
    try out.writeAll("\ncolumns:");
    for (dry.value.schema) |f| try out.print(" {s} ({t})", .{ f.name, f.type });
    try out.writeAll("\n");

    // The request, with its id fixed, so the run sends exactly this.
    var id: [36]u8 = undefined;
    const options: bigquery.QueryOptions = .{
        .query = query,
        .maximum_bytes_billed = limit,
        .page_size = 20,
        .request_id = client.newRequestId(&id),
    };
    var request = try client.queryRequest(options);
    defer request.deinit();
    try out.print("{t} {s}\n{s}\n", .{ request.value.method, request.value.url, request.value.body });
    if (!confirmed) {
        try out.writeAll("not sent: add --yes to run it\n");
        return;
    }

    var page = try client.query(options);
    defer page.deinit();
    // Waited out without reading rows, as Google's clients wait.
    while (!page.value.complete) {
        try out.writeAll("still running...\n");
        try out.flush();
        const next = try client.getQueryResults(page.value.job.?, .{ .page_size = 0, .timeout_ms = 10_000 });
        page.deinit();
        page = next;
    }
    // A results page leaves the statement and its bill to the job.
    var job = try client.getJob(page.value.job.?);
    defer job.deinit();
    try out.print("{s}: {?d} rows, billed {d} bytes", .{ job.value.statement_type, page.value.total_rows, job.value.total_bytes_billed orelse 0 });
    if (job.value.num_dml_affected_rows) |n| try out.print(", {d} rows changed", .{n});
    try out.writeAll("\n");
    if (page.value.schema.len == 0) return;

    for (page.value.schema) |f| try out.print("{s}\t", .{f.name});
    try out.writeAll("\n");
    // The first page may have stopped at the wait, with no rows.
    var rows = page.value.rows;
    var token = page.value.page_token;
    var next: ?bigquery.Owned(bigquery.QueryPage) = null;
    defer if (next) |*n| n.deinit();
    while (true) {
        for (rows) |row| {
            for (row.cells) |cell| try out.print("{f}\t", .{cell.value});
            try out.writeAll("\n");
        }
        const t = token orelse break;
        const read = try client.getQueryResults(page.value.job.?, .{ .page_token = t, .page_size = 20 });
        if (next) |*n| n.deinit();
        next = read;
        rows = read.value.rows;
        token = read.value.page_token;
    }
}

/// Hamlet's five most frequent words, the answer milestone 0 measured,
/// for `--fake`; the job takes two reads to finish.
fn seed(fake: *bigquery.testing.FakeBigQuery) !void {
    const words = [_]struct { []const u8, i64 }{ .{ "the", 995 }, .{ "and", 706 }, .{ "to", 635 }, .{ "of", 630 }, .{ "I", 546 } };
    var rows: [words.len]bigquery.Row = undefined;
    var cells: [words.len][2]bigquery.Cell = undefined;
    for (words, &rows, &cells) |w, *row, *pair| {
        pair.* = .{ .{ .value = .{ .string = w[0] } }, .{ .value = .{ .int64 = w[1] } } };
        row.* = .{ .cells = pair };
    }
    try fake.answer(hamlet, .{
        .schema = &.{ .{ .name = "word", .type = .string }, .{ .name = "word_count", .type = .int64 } },
        .rows = &rows,
        .tables = &.{.{ .project = "bigquery-public-data", .dataset = "samples", .table = "shakespeare" }},
        .bytes_processed = 5_114_816,
        .polls = 2,
    });
}
