//! The health view's pipelines widget: every region's jobs in one call,
//! the failing ones called out with their first error, and any region
//! that did not answer named rather than silently missing.
//!
//!     GOOGLE_CLOUD_PROJECT=my-project zig build example-dataflow_jobs
//!     zig build example-dataflow_jobs -- --fake     # no network
//!
//! Credentials come from `auth.findDefault`; v1b3 has no read-only
//! scope, so reading takes `cloud-platform` with `dataflow.jobs.list`
//! and friends on the IAM side (Dataflow Viewer is enough). `--fake`
//! reads `dataflow.testing.FakeDataflow` instead, with a done pipeline
//! and a failed one a test put in.

const std = @import("std");
const auth = @import("auth");
const dataflow = @import("dataflow");

pub const std_options: std.Options = .{
    .log_scope_levels = &.{
        .{ .scope = .gcp_auth, .level = .warn },
        .{ .scope = .gcp_dataflow, .level = .warn },
    },
};

pub fn main(init: std.process.Init) !void {
    const arena = init.arena.allocator();
    var stdout_buffer: [4096]u8 = undefined;
    var stdout = std.Io.File.stdout().writerStreaming(init.io, &stdout_buffer);
    const out = &stdout.interface;
    var diag: dataflow.Diagnostics = .{};

    var use_fake = false;
    const args = try init.minimal.args.toSlice(arena);
    for (args[@min(1, args.len)..]) |arg| {
        if (std.mem.eql(u8, arg, "--fake")) {
            use_fake = true;
        } else {
            std.debug.print("usage: dataflow_jobs [--fake]\n", .{});
            return error.Usage;
        }
    }

    var fake: dataflow.testing.FakeDataflow = .init(init.gpa, init.io, .{ .project_id = "my-project" });
    defer fake.deinit();
    var static: dataflow.StaticToken = .{ .token = "fake" };
    var creds: ?auth.Credentials = null;
    defer if (creds) |*c| c.deinit();
    const project = if (use_fake) "my-project" else init.environ_map.get("GOOGLE_CLOUD_PROJECT") orelse {
        std.debug.print("set GOOGLE_CLOUD_PROJECT to the project whose jobs to read\n", .{});
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

    if (use_fake) {
        const now = std.Io.Clock.real.now(init.io);
        try fake.putLocation("us-central1");
        _ = try fake.putJob(.{
            .location = "us-central1",
            .id = "2026-10-20_02_00_00-1111111111111111111",
            .name = "orders-to-bigquery",
            .type = .streaming,
            .current_state = .running,
            .create_time = .{ .nanoseconds = now.nanoseconds - 26 * std.time.ns_per_hour },
        });
        _ = try fake.putJob(.{
            .location = "us-central1",
            .id = "2026-10-20_07_09_34-2222222222222222222",
            .name = "nightly-wordcount",
            .type = .batch,
            .current_state = .failed,
            .current_state_time = .{ .nanoseconds = now.nanoseconds - 20 * std.time.ns_per_min },
            .create_time = .{ .nanoseconds = now.nanoseconds - 22 * std.time.ns_per_min },
        });
        try fake.putMessage(.{
            .job = "2026-10-20_07_09_34-2222222222222222222",
            .time = .{ .nanoseconds = now.nanoseconds - 20 * std.time.ns_per_min },
            .text = "The Dataflow service agent cannot access the worker service account.",
            .importance = .@"error",
        });
        try fake.setFailedLocations(&.{"asia-east1"});
    }

    // Every region's jobs in one call: the widget.
    var jobs = try client.aggregatedJobs(.{ .filter = .all });
    defer jobs.deinit();
    var failing: usize = 0;
    for (jobs.value.jobs) |job| {
        const kind = switch (job.type) {
            .streaming => "streaming",
            .batch => "batch",
            else => "job",
        };
        if (job.failing()) {
            failing += 1;
            try out.print("[FAILED] {s} ({s}, {s})", .{ job.name, kind, job.location });
            // The first error is "why is it red".
            var story = try client.listMessages(job.location, job.id, .{ .minimum_importance = .@"error" });
            defer story.deinit();
            if (story.value.messages.len > 0) {
                try out.print(": {s}", .{story.value.messages[0].text});
            }
            try out.writeAll("\n");
        } else {
            try out.print("[{s}] {s} ({s}, {s})\n", .{ if (job.terminal()) "done" else "ok", job.name, kind, job.location });
        }
    }
    for (jobs.value.failed_locations) |region| {
        try out.print("note: {s} did not answer, its jobs are not shown\n", .{region});
    }
    try out.print("{d} of {d} jobs failing\n", .{ failing, jobs.value.jobs.len });
    try out.flush();
}
