//! Writes a program's own metrics to Cloud Monitoring: a gauge, a queue's
//! depth now, and a counter, the orders taken since the program started,
//! then says what the server did with them, reads the gauge back, and lists
//! the metrics written.
//!
//!     GOOGLE_CLOUD_PROJECT=my-project zig build example-monitoring
//!     zig build example-monitoring -- --fake     # no network
//!
//! Credentials come from `auth.findDefault`. Writing needs
//! `monitoring.timeSeries.create`, reading `monitoring.timeSeries.list` and
//! listing `monitoring.metricDescriptors.list` (Monitoring Metric Writer
//! and Monitoring Viewer). `--fake` writes to
//! `monitoring.testing.FakeMonitoring` instead.
//!
//! Each run starts its own series: its task id is new every time, so the
//! counter's start time is this run's. A program keeps one task id for its
//! life, and writes each series at most every 5 seconds.

const std = @import("std");
const auth = @import("auth");
const monitoring = @import("monitoring");

pub const std_options: std.Options = .{
    .log_scope_levels = &.{
        .{ .scope = .gcp_auth, .level = .warn },
        .{ .scope = .gcp_monitoring, .level = .warn },
    },
};

const prefix = "custom.googleapis.com/zig-gcp-example/";

pub fn main(init: std.process.Init) !void {
    const arena = init.arena.allocator();
    var stdout_buffer: [4096]u8 = undefined;
    var stdout = std.Io.File.stdout().writerStreaming(init.io, &stdout_buffer);
    const out = &stdout.interface;
    var diag: monitoring.Diagnostics = .{};

    var use_fake = false;
    const args = try init.minimal.args.toSlice(arena);
    for (args[@min(1, args.len)..]) |arg| {
        if (std.mem.eql(u8, arg, "--fake")) {
            use_fake = true;
        } else return usage();
    }

    var fake: monitoring.testing.FakeMonitoring = .init(init.gpa, init.io, .{ .project_id = "my-project" });
    defer fake.deinit();
    var creds: ?auth.Credentials = null;
    defer if (creds) |*c| c.deinit();
    var static: monitoring.StaticToken = .{ .token = "fake" };
    const project = if (use_fake) "my-project" else init.environ_map.get("GOOGLE_CLOUD_PROJECT") orelse {
        std.debug.print("set GOOGLE_CLOUD_PROJECT to the project to write metrics to\n", .{});
        return error.MissingProject;
    };
    if (!use_fake) {
        var lookup = try auth.Lookup.fromEnv(init.environ_map, arena);
        lookup.diagnostics = &diag;
        creds = auth.findDefault(init.gpa, init.io, lookup, .{}) catch |err| return fail(err, &diag);
    }
    var client = monitoring.Client.init(init.gpa, init.io, .{
        .project_id = project,
        .token_provider = if (creds) |*c| c.provider() else static.provider(),
        .transport = if (use_fake) fake.transport() else null,
        .diagnostics = &diag,
    }) catch |err| return fail(err, &diag);
    defer client.deinit();

    // Who is writing: one task of one job, with an id of its own.
    const task_id = monitoring.Resource.randomTaskId(init.io);
    const resource: monitoring.Resource = .{ .generic_task = .{
        .location = "us-central1",
        .namespace = "zig-gcp",
        .job = "example",
        .task_id = &task_id,
    } };
    const started = std.Io.Clock.real.now(init.io);
    const now = std.Io.Clock.real.now(init.io);
    const later: std.Io.Timestamp = .{ .nanoseconds = @max(now.nanoseconds, started.nanoseconds + std.time.ns_per_ms) };

    var result = client.write(&.{
        .{
            .metric_type = prefix ++ "queue_depth",
            .metric_labels = &.{.{ .key = "queue", .value = "orders" }},
            .resource = resource,
            .kind = .gauge,
            .unit = "{message}",
            .end = later,
            .value = .{ .int64 = 17 },
        },
        .{
            .metric_type = prefix ++ "orders",
            .metric_labels = &.{.{ .key = "region", .value = "eu" }},
            .resource = resource,
            .kind = .cumulative,
            .unit = "{order}",
            .start = started,
            .end = later,
            .value = .{ .int64 = 4217 },
        },
    }) catch |err| return fail(err, &diag);
    defer result.deinit();
    try out.print("wrote {d} of {d} points as task {s}\n", .{ result.value.written, result.value.points, &task_id });
    for (result.value.refused) |r| try out.print("  {d} refused: {t}\n", .{ r.points, r.reason });
    if (!result.value.ok()) try out.print("  {s}\n", .{result.value.message});

    // This task's queue depth over the last minute. Production showed a
    // point 0.2 s after its write when measured; a few seconds is safe.
    var depth = client.metric(prefix ++ "queue_depth").read(.{
        .start = .{ .nanoseconds = later.nanoseconds - std.time.ns_per_min },
        .end = later,
        .filter = .{ .resource_labels = &.{.{ .key = "task_id", .value = &task_id }} },
    }) catch |err| return fail(err, &diag);
    defer depth.deinit();
    for (depth.value.series) |s| for (s.points) |p| {
        try out.print("read back queue_depth{{queue={s}}} = {d}\n", .{ s.label("queue") orelse "", p.value.?.int64 });
    };
    if (depth.value.series.len == 0) try out.writeAll("queue_depth not readable yet: try again in a few seconds\n");

    var page = client.listMetrics(.{ .prefix = prefix }) catch |err| return fail(err, &diag);
    defer page.deinit();
    try out.print("\nmetrics under {s}\n", .{prefix});
    for (page.value.metrics) |m| {
        try out.print("  {s}  {t} {t}", .{ m.type[prefix.len..], m.kind, m.value_type });
        if (m.unit.len > 0) try out.print("  unit {s}", .{m.unit});
        for (m.labels) |l| try out.print("  label {s}", .{l.key});
        try out.writeByte('\n');
    }
    if (page.value.metrics.len == 0) try out.writeAll("  (none yet: a new descriptor can take a few seconds to list)\n");
    try out.flush();
}

fn usage() error{Usage} {
    std.debug.print("usage: monitoring [--fake]\n", .{});
    return error.Usage;
}

fn fail(err: anyerror, diag: *const monitoring.Diagnostics) anyerror {
    std.debug.print("error.{t}", .{err});
    if (diag.http_status != 0) std.debug.print(" (HTTP {d} {s})", .{ diag.http_status, diag.status() });
    if (diag.message().len != 0) std.debug.print(": {s}", .{diag.message()});
    std.debug.print("\n", .{});
    return err;
}
