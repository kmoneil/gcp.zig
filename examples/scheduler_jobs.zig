//! The health view's failing-jobs widget: every Cloud Scheduler job in a
//! location whose last attempt failed, or that could not be updated.
//!
//!     GOOGLE_CLOUD_PROJECT=my-project zig build example-scheduler_jobs
//!     zig build example-scheduler_jobs -- --fake     # no network
//!
//! Credentials come from `auth.findDefault`; reading jobs takes the
//! cloud-platform scope, the only one Cloud Scheduler defines
//! (Cloud Scheduler Viewer is enough on the IAM side). SCHEDULER_LOCATION
//! picks the location (us-central1 when unset). `--fake` reads
//! `scheduler.testing.FakeScheduler` instead, with three jobs a test put
//! in: one healthy, one whose attempt failed, one Scheduler could not
//! update.

const std = @import("std");
const auth = @import("auth");
const scheduler = @import("scheduler");

pub const std_options: std.Options = .{
    .log_scope_levels = &.{
        .{ .scope = .gcp_auth, .level = .warn },
        .{ .scope = .gcp_scheduler, .level = .warn },
    },
};

pub fn main(init: std.process.Init) !void {
    const arena = init.arena.allocator();
    var stdout_buffer: [4096]u8 = undefined;
    var stdout = std.Io.File.stdout().writerStreaming(init.io, &stdout_buffer);
    const out = &stdout.interface;
    var diag: scheduler.Diagnostics = .{};

    var use_fake = false;
    const args = try init.minimal.args.toSlice(arena);
    for (args[@min(1, args.len)..]) |arg| {
        if (std.mem.eql(u8, arg, "--fake")) {
            use_fake = true;
        } else {
            std.debug.print("usage: scheduler_jobs [--fake]\n", .{});
            return error.Usage;
        }
    }

    var fake: scheduler.testing.FakeScheduler = .init(init.gpa, init.io, .{ .project_id = "my-project" });
    defer fake.deinit();
    var static: scheduler.StaticToken = .{ .token = "fake" };
    var creds: ?auth.Credentials = null;
    defer if (creds) |*c| c.deinit();
    const project = if (use_fake) "my-project" else init.environ_map.get("GOOGLE_CLOUD_PROJECT") orelse {
        std.debug.print("set GOOGLE_CLOUD_PROJECT to the project whose jobs to read\n", .{});
        return error.MissingProject;
    };
    const location = if (use_fake) "us-central1" else init.environ_map.get("SCHEDULER_LOCATION") orelse "us-central1";
    if (!use_fake) {
        var lookup = try auth.Lookup.fromEnv(init.environ_map, arena);
        lookup.diagnostics = &diag;
        creds = try auth.findDefault(init.gpa, init.io, lookup, .{});
    }
    var client = try scheduler.Client.init(init.gpa, init.io, .{
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
            .id = "hourly-report",
            .schedule = "0 * * * *",
            .last_attempt = .{ .code = 0 },
            .last_attempt_time = now,
            .schedule_time = .{ .nanoseconds = now.nanoseconds + std.time.ns_per_hour },
            .target = .{ .http = .{ .uri = "https://example.com/report", .method = .post } },
        });
        _ = try fake.putJob(.{
            .location = "us-central1",
            .id = "nightly-export",
            .schedule = "0 3 * * *",
            .last_attempt = .{ .code = 14 },
            .last_attempt_time = .{ .nanoseconds = now.nanoseconds - 7 * std.time.ns_per_hour },
            .schedule_time = .{ .nanoseconds = now.nanoseconds + 17 * std.time.ns_per_hour },
            .target = .{ .http = .{ .uri = "https://example.com/export", .method = .post } },
        });
        _ = try fake.putJob(.{
            .location = "us-central1",
            .id = "cleanup",
            .schedule = "*/10 * * * *",
            .state = .update_failed,
            .target = .{ .pubsub = .{ .topic_name = "projects/my-project/topics/cleanup" } },
        });
    }

    var jobs = try client.listJobs(location, .{});
    defer jobs.deinit();
    var failing: usize = 0;
    for (jobs.value.jobs) |job| {
        if (!job.failing()) continue;
        failing += 1;
        if (job.state == .update_failed) {
            try out.print("[UPDATE FAILED] {s} ({s})\n", .{ job.id, job.schedule });
        } else if (job.last_attempt) |attempt| {
            try out.print("[FAILED {d}] {s} ({s})", .{ attempt.code, job.id, job.schedule });
            if (job.last_attempt_time) |t| {
                const ago_min = @divFloor(std.Io.Clock.real.now(init.io).nanoseconds - t.nanoseconds, std.time.ns_per_min);
                try out.print(", last attempt {d} min ago", .{ago_min});
            }
            try out.writeAll("\n");
        }
    }
    try out.print("{d} of {d} jobs failing in {s}\n", .{ failing, jobs.value.jobs.len, location });
    try out.flush();
}
