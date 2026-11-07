//! A console's job page: one Dataflow job in full, from one get at
//! JOB_VIEW_DESCRIPTION and its metrics. The template it was launched
//! from and the parameters it was given, the SDK, the workers, the stages
//! the service fused the pipeline into, and the committed metrics.
//!
//!     GOOGLE_CLOUD_PROJECT=my-project zig build example-dataflow_job -- us-central1 2026-11-07_12_14_27-5029885235339452204
//!     zig build example-dataflow_job -- --fake     # no network
//!
//! Credentials come from `auth.findDefault`, and Dataflow Viewer is
//! enough. `--fake` reads `dataflow.testing.FakeDataflow` instead, with
//! a done Word_Count job a test put in, shaped as production's was on
//! 2026-11-07.

const std = @import("std");
const auth = @import("auth");
const dataflow = @import("dataflow");

pub const std_options: std.Options = .{
    .log_scope_levels = &.{
        .{ .scope = .gcp_auth, .level = .warn },
        .{ .scope = .gcp_dataflow, .level = .warn },
    },
};

const fake_id = "2026-11-07_12_14_27-5029885235339452204";

pub fn main(init: std.process.Init) !void {
    const arena = init.arena.allocator();
    var stdout_buffer: [4096]u8 = undefined;
    var stdout = std.Io.File.stdout().writerStreaming(init.io, &stdout_buffer);
    const out = &stdout.interface;
    var diag: dataflow.Diagnostics = .{};

    const args = try init.minimal.args.toSlice(arena);
    const rest = args[@min(1, args.len)..];
    const use_fake = rest.len == 1 and std.mem.eql(u8, rest[0], "--fake");
    if (!use_fake and rest.len != 2) {
        std.debug.print("usage: dataflow_job LOCATION JOB_ID | dataflow_job --fake\n", .{});
        return error.Usage;
    }
    const location = if (use_fake) "us-central1" else rest[0];
    const id = if (use_fake) fake_id else rest[1];

    var fake: dataflow.testing.FakeDataflow = .init(init.gpa, init.io, .{ .project_id = "my-project" });
    defer fake.deinit();
    var static: dataflow.StaticToken = .{ .token = "fake" };
    var creds: ?auth.Credentials = null;
    defer if (creds) |*c| c.deinit();
    const project = if (use_fake) "my-project" else init.environ_map.get("GOOGLE_CLOUD_PROJECT") orelse {
        std.debug.print("set GOOGLE_CLOUD_PROJECT to the project the job runs in\n", .{});
        return error.MissingProject;
    };
    if (!use_fake) {
        var lookup = try auth.Lookup.fromEnv(init.environ_map, arena);
        lookup.diagnostics = &diag;
        creds = try auth.findDefault(init.gpa, init.io, lookup, .{});
    }
    var client = try dataflow.Client.init(init.gpa, init.io, .{
        .project_id = project,
        .token_provider = if (creds) |*c| c.provider() else static.provider(),
        .transport = if (use_fake) fake.transport() else null,
        .diagnostics = &diag,
    });
    defer client.deinit();
    if (use_fake) try seed(&fake);

    // DESCRIPTION carries all a page shows; ALL would add only the
    // compiled steps, about a tenth more bytes.
    var got = client.getJobView(location, id, .description) catch |err| {
        std.debug.print("{t}: {s}\n", .{ err, diag.message() });
        return err;
    };
    defer got.deinit();
    const job = got.value;

    try out.print("{s}  {t}\n", .{ job.name, job.current_state });
    if (job.template()) |t| try out.print("template   {s} ({s}, {s})\n", .{ t.name, t.type, t.version });
    // A template's parameters are the display data with no namespace.
    for (job.pipeline.display_data) |d| {
        if (d.namespace.len > 0) continue;
        switch (d.value) {
            .string => |s| try out.print("parameter  {s} = {s}\n", .{ d.key, s }),
            .integer => |n| try out.print("parameter  {s} = {d}\n", .{ d.key, n }),
            else => try out.print("parameter  {s}\n", .{d.key}),
        }
    }
    try out.print("sdk        {s} {s} ({t})\n", .{ job.sdk.name, job.sdk.version, job.sdk.support });
    for (job.environment.worker_pools) |pool| {
        try out.print("workers    {?d} x {s}, at most {?d}, {?d} GB disk\n", .{ pool.num_workers, pool.machine_type, pool.max_workers, pool.disk_size_gb });
    }
    if (job.environment.service_account.len > 0) try out.print("runs as    {s}\n", .{job.environment.service_account});

    // The graph as the service ran it: each stage, and what it was fused
    // from, in the user's names.
    for (job.pipeline.stages) |stage| {
        try out.print("stage      {s} ({t})", .{ stage.name, stage.kind });
        for (stage.transforms, 0..) |t, i| try out.print("{s}{s}", .{ if (i == 0) ": " else ", ", t.user_name });
        try out.writeAll("\n");
    }

    // The committed metrics: each comes twice, once tentative.
    var metrics = try client.getJobMetrics(location, id, .{});
    defer metrics.deinit();
    for (metrics.value.updates) |u| {
        if (u.tentative) continue;
        switch (u.value) {
            .integer => |n| try out.print("metric     {s} = {d}\n", .{ u.name, n }),
            .float => |f| try out.print("metric     {s} = {d:.6}\n", .{ u.name, f }),
            .boolean => |b| try out.print("metric     {s} = {}\n", .{ u.name, b }),
            .other => |o| try out.print("metric     {s} = {s}\n", .{ u.name, o.json }),
            .none => {},
        }
    }
    try out.flush();
}

/// A done Word_Count job, shaped as production's was on 2026-11-07.
fn seed(fake: *dataflow.testing.FakeDataflow) !void {
    try fake.putLocation("us-central1");
    _ = try fake.putJob(.{
        .location = "us-central1",
        .id = fake_id,
        .name = "nightly-wordcount",
        .type = .batch,
        .current_state = .done,
        .labels = &.{
            .{ .key = "goog-dataflow-provided-template-name", .value = "word_count" },
            .{ .key = "goog-dataflow-provided-template-type", .value = "legacy" },
            .{ .key = "goog-dataflow-provided-template-version", .value = "2026-10-27-00_rc00" },
        },
        .sdk = .{ .version = "2.77.0", .name = "Apache Beam SDK for Java", .support = .supported },
        .environment = .{
            .service_account = "123456789012-compute@developer.gserviceaccount.com",
            .worker_pools = &.{.{ .kind = "harness", .machine_type = "n1-standard-1", .num_workers = 2, .max_workers = 1, .disk_size_gb = 30 }},
        },
        .pipeline = .{
            .display_data = &.{
                .{ .key = "region", .namespace = "org.apache.beam.runners.dataflow.options.DataflowPipelineOptions", .value = .{ .string = "us-central1" } },
                .{ .key = "inputFile", .value = .{ .string = "gs://dataflow-samples/shakespeare/kinglear.txt" } },
                .{ .key = "output", .value = .{ .string = "gs://my-bucket/out/wc" } },
            },
            .stages = &.{
                .{ .id = "S01", .name = "F12", .kind = .par_do, .transforms = &.{ .{ .user_name = "ReadLines" }, .{ .user_name = "CountWords/ExtractWords" } } },
                .{ .id = "S02", .name = "F13", .kind = .shuffle, .transforms = &.{.{ .user_name = "CountWords/Count.PerElement" }} },
                .{ .id = "S03", .name = "F14", .kind = .par_do, .transforms = &.{ .{ .user_name = "FormatAsText" }, .{ .user_name = "WriteCounts" } } },
            },
        },
    });
    try fake.setMetrics(fake_id, .{ .updates = &.{
        .{ .origin = "dataflow/v1b3", .name = "TotalVcpuTime", .tentative = true, .context = &.{.{ .key = "tentative", .value = "true" }}, .value = .{ .integer = 103 } },
        .{ .origin = "dataflow/v1b3", .name = "TotalVcpuTime", .value = .{ .integer = 103 } },
        .{ .origin = "dataflow/v1b3", .name = "TotalShuffleDataProcessed", .value = .{ .float = 6.410107016563416e-05 } },
        .{ .origin = "user", .name = "emptyLines", .value = .{ .integer = 1663 } },
    } });
}
