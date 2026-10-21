//! A project's scheduled queries in every location, each with its latest
//! run, and a run now as a console confirms one: show the exact request,
//! send it only when confirmed, follow the run to its end, print its
//! messages.
//!
//!     GOOGLE_CLOUD_PROJECT=my-project zig build example-datatransfer_runs
//!     GOOGLE_CLOUD_PROJECT=my-project zig build example-datatransfer_runs -- --run CONFIG_NAME --yes
//!     zig build example-datatransfer_runs -- --fake --run --yes     # no network
//!
//! Without `--yes` a run now prints its request and stops: that is the
//! confirmation. Credentials come from `auth.findDefault`, with the
//! `bigquery` scope; IAM asks `bigquery.transfers.get` to list, and
//! `bigquery.transfers.update` to run. CONFIG_NAME is a name the listing
//! prints. `--fake` works on `datatransfer.testing.FakeDataTransfer`
//! instead (`--run` alone runs its first scheduled query), and stands in
//! for the service by moving the run on.

const std = @import("std");
const auth = @import("auth");
const datatransfer = @import("datatransfer");

pub const std_options: std.Options = .{
    .log_scope_levels = &.{
        .{ .scope = .gcp_auth, .level = .warn },
        .{ .scope = .gcp_datatransfer, .level = .warn },
    },
};

const usage = "usage: datatransfer_runs [--fake] [--run [CONFIG_NAME]] [--yes]\n";

pub fn main(init: std.process.Init) !void {
    const arena = init.arena.allocator();
    var stdout_buffer: [4096]u8 = undefined;
    var stdout = std.Io.File.stdout().writerStreaming(init.io, &stdout_buffer);
    const out = &stdout.interface;
    var diag: datatransfer.Diagnostics = .{};

    var use_fake = false;
    var confirmed = false;
    var run_asked = false;
    var run_name: ?[]const u8 = null;
    const args = try init.minimal.args.toSlice(arena);
    var i: usize = @min(1, args.len);
    while (i < args.len) : (i += 1) {
        const arg = args[i];
        if (std.mem.eql(u8, arg, "--fake")) {
            use_fake = true;
        } else if (std.mem.eql(u8, arg, "--yes")) {
            confirmed = true;
        } else if (std.mem.eql(u8, arg, "--run")) {
            run_asked = true;
            if (i + 1 < args.len and !std.mem.startsWith(u8, args[i + 1], "--")) {
                run_name = args[i + 1];
                i += 1;
            }
        } else {
            std.debug.print(usage, .{});
            return error.Usage;
        }
    }

    var fake: datatransfer.testing.FakeDataTransfer = .init(init.gpa, init.io, .{ .project_id = "my-project" });
    defer fake.deinit();
    var static: datatransfer.StaticToken = .{ .token = "fake" };
    var creds: ?auth.Credentials = null;
    defer if (creds) |*c| c.deinit();
    const project = if (use_fake) "my-project" else init.environ_map.get("GOOGLE_CLOUD_PROJECT") orelse {
        std.debug.print("set GOOGLE_CLOUD_PROJECT to the project to read\n", .{});
        return error.MissingProject;
    };
    if (!use_fake) {
        var lookup = try auth.Lookup.fromEnv(init.environ_map, arena);
        lookup.diagnostics = &diag;
        creds = try auth.findDefault(init.gpa, init.io, lookup, .{});
    }
    var client = try datatransfer.Client.init(init.gpa, init.io, .{
        .project_id = project,
        .token_provider = if (creds) |*c| c.provider() else static.provider(),
        .transport = if (use_fake) fake.transport() else null,
        .diagnostics = &diag,
    });
    defer client.deinit();
    const first = if (use_fake) try seed(&fake) else "";

    if (run_asked) {
        const name = run_name orelse if (use_fake) first else {
            std.debug.print("--run needs a CONFIG_NAME, as the listing prints it\n", .{});
            return error.Usage;
        };
        runNow(out, &client, name, confirmed, if (use_fake) &fake else null) catch |err| {
            try out.print("refused: {t}: {s}\n", .{ err, diag.message() });
            try out.flush();
            return err;
        };
    } else {
        list(out, &client) catch |err| {
            try out.print("refused: {t}: {s}\n", .{ err, diag.message() });
            try out.flush();
            return err;
        };
    }
    try out.flush();
}

/// Every location's scheduled queries, each with its latest run: one list
/// a location, since production has none for every location at once.
fn list(out: *std.Io.Writer, client: *datatransfer.Client) !void {
    var locations = try client.listLocations(.{});
    defer locations.deinit();
    var found: usize = 0;
    for (locations.value.locations) |location| {
        var page = try client.listTransferConfigs(location.id, .{ .data_sources = &.{"scheduled_query"} });
        defer page.deinit();
        for (page.value.configs) |config| {
            found += 1;
            const schedule = switch (config.schedule) {
                .time_based => |t| t.schedule,
                .manual => "by hand",
                .event_driven => "on a message",
                .default => "default",
            };
            try out.print("{s}  {s}  ({s}{s})\n  {s}\n", .{ location.id, config.display_name, schedule, if (config.disabled) ", disabled" else "", config.name });
            var runs = try client.listRuns(config.name, .{ .page_size = 1 });
            defer runs.deinit();
            if (runs.value.runs.len == 0) {
                try out.writeAll("  no runs yet\n");
            } else {
                const run = runs.value.runs[0];
                try out.print("  latest run: {t}", .{run.state});
                if (run.@"error") |e| try out.print(": {s}", .{e.message});
                try out.writeAll("\n");
            }
        }
    }
    try out.print("{d} scheduled queries in {d} locations\n", .{ found, locations.value.locations.len });
}

/// A run now, shown first, then followed to its end, polling every 10 s
/// as Airflow does (the fake moves on at once).
fn runNow(out: *std.Io.Writer, client: *datatransfer.Client, name: []const u8, confirmed: bool, fake: ?*datatransfer.testing.FakeDataTransfer) !void {
    var config = try client.getTransferConfig(name);
    defer config.deinit();
    try out.print("{s}, run as {s}\n", .{ config.value.display_name, config.value.owner_email });
    if (config.value.scheduled_query) |q| try out.print("  {s}\n", .{q.query});
    if (config.value.disabled) try out.writeAll("  disabled: production will refuse a run now\n");

    // One time for the preview and the run: the run sends what was shown.
    const options: datatransfer.StartManualRunOptions = .{ .run_time = std.Io.Clock.real.now(client.io) };
    var request = try client.startManualRunRequest(name, options);
    defer request.deinit();
    try out.print("{t} {s}\n{s}\n", .{ request.value.method, request.value.url, request.value.body });
    if (!confirmed) {
        try out.writeAll("not sent: add --yes to run it\n");
        return;
    }
    var started = try client.startManualRun(name, options);
    defer started.deinit();
    const run_name = started.value.runs[0].name;
    try out.print("started {s}\n", .{run_name});
    try out.flush();
    if (fake) |f| {
        // The service's part: the run starts, then ends.
        try f.setRunState(run_name, .running, null);
        try f.setRunState(run_name, .succeeded, null);
        try f.putMessage(run_name, .{ .severity = .info, .text = "Summary: succeeded 1 jobs, failed 0 jobs." });
    }
    var run = try client.getRun(run_name);
    defer run.deinit();
    while (!run.value.ended()) {
        try out.print("  {t}...\n", .{run.value.state});
        try out.flush();
        try client.io.sleep(.fromSeconds(10), .awake);
        const next = try client.getRun(run_name);
        run.deinit();
        run = next;
    }
    try out.print("ended {t}", .{run.value.state});
    if (run.value.@"error") |e| try out.print(": {s}", .{e.message});
    try out.writeAll("\n");
    var messages = try client.listMessages(run_name, .{});
    defer messages.deinit();
    for (messages.value.messages) |m| try out.print("  [{t}] {s}\n", .{ m.severity, m.text });
}

/// Two scheduled queries in the US, one disabled, with a past run each,
/// for `--fake`; answers the first's name.
fn seed(fake: *datatransfer.testing.FakeDataTransfer) ![]const u8 {
    try fake.putLocation("us");
    try fake.putLocation("europe");
    const daily = try fake.putConfig(.{
        .location = "us",
        .display_name = "Daily orders",
        .destination_dataset_id = "reporting",
        .schedule = .{ .time_based = .{ .schedule = "every 24 hours" } },
        .owner_email = "reporting@my-project.iam.gserviceaccount.com",
        .scheduled_query = .{ .query = "SELECT DATE(@run_time) AS day, COUNT(*) AS orders FROM shop.orders WHERE DATE(created) = @run_date", .destination_table_name_template = "orders_{run_date}", .write_disposition = "WRITE_TRUNCATE" },
    });
    _ = try fake.putRun(.{ .config = daily, .state = .succeeded, .schedule = "every 24 hours" });
    const weekly = try fake.putConfig(.{
        .location = "us",
        .display_name = "Weekly churn",
        .destination_dataset_id = "reporting",
        .schedule = .{ .time_based = .{ .schedule = "every mon 06:00" } },
        .disabled = true,
        .scheduled_query = .{ .query = "SELECT 1", .destination_table_name_template = "churn_{run_date}", .write_disposition = "WRITE_TRUNCATE" },
    });
    _ = try fake.putRun(.{ .config = weekly, .state = .failed, .@"error" = .{ .code = 3, .message = "Unrecognized name: customer_id at [4:12]" } });
    return daily;
}
