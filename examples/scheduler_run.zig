//! Run a Cloud Scheduler job now, as a console's confirmed write does:
//! show the exact request, send it only when confirmed, then read the job
//! until its attempt shows.
//!
//!     GOOGLE_CLOUD_PROJECT=my-project zig build example-scheduler_run -- nightly-export
//!     GOOGLE_CLOUD_PROJECT=my-project zig build example-scheduler_run -- nightly-export --yes
//!     zig build example-scheduler_run -- --fake --yes     # no network
//!
//! Without `--yes` it prints the request and stops: that is the
//! confirmation. Credentials come from `auth.findDefault`, with the
//! cloud-platform scope; IAM asks `cloudscheduler.jobs.run` to run and
//! `cloudscheduler.jobs.get` to read the job back (Cloud Scheduler Job
//! Runner holds the first and not the second; Cloud Scheduler Admin
//! both). SCHEDULER_LOCATION picks the location (us-central1 when
//! unset). `--fake` runs `scheduler.testing.FakeScheduler`'s
//! nightly-export instead, whose attempt fails with code 5 two seconds
//! after the run, as production's HTTP 404s did.

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
    var confirmed = false;
    var job_id: ?[]const u8 = null;
    const args = try init.minimal.args.toSlice(arena);
    for (args[@min(1, args.len)..]) |arg| {
        if (std.mem.eql(u8, arg, "--fake")) {
            use_fake = true;
        } else if (std.mem.eql(u8, arg, "--yes")) {
            confirmed = true;
        } else if (job_id == null and !std.mem.startsWith(u8, arg, "-")) {
            job_id = arg;
        } else {
            std.debug.print("usage: scheduler_run (JOB_ID | --fake) [--yes]\n", .{});
            return error.Usage;
        }
    }
    if (use_fake) job_id = "nightly-export";
    const id = job_id orelse {
        std.debug.print("usage: scheduler_run (JOB_ID | --fake) [--yes]\n", .{});
        return error.Usage;
    };

    var fake: scheduler.testing.FakeScheduler = .init(init.gpa, init.io, .{ .project_id = "my-project" });
    defer fake.deinit();
    var static: scheduler.StaticToken = .{ .token = "fake" };
    var creds: ?auth.Credentials = null;
    defer if (creds) |*c| c.deinit();
    const project = if (use_fake) "my-project" else init.environ_map.get("GOOGLE_CLOUD_PROJECT") orelse {
        std.debug.print("set GOOGLE_CLOUD_PROJECT to the project whose job to run\n", .{});
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
        try fake.putLocation("us-central1");
        const name = try fake.putJob(.{
            .location = "us-central1",
            .id = "nightly-export",
            .schedule = "0 3 * * *",
            .target = .{ .http = .{ .uri = "https://example.com/export", .method = .post } },
        });
        try fake.setRunOutcome(name, .{ .code = 5, .after_ms = 2000 });
    }

    // The confirmation: the request, byte for byte what runJob sends.
    var request = client.runJobRequest(location, id) catch |err| {
        std.debug.print("{t}: {s}\n", .{ err, diag.message() });
        return err;
    };
    defer request.deinit();
    try out.print("{t} {s}\n{s}\n", .{ request.value.method, request.value.url, request.value.body });
    if (!confirmed) {
        try out.writeAll("not sent: run again with --yes to send it\n");
        try out.flush();
        return;
    }

    var before = client.runJob(location, id) catch |err| {
        // A paused job is refused: "Job.state must be ENABLED for RunJob."
        std.debug.print("{t}: {s}\n", .{ err, diag.message() });
        return err;
    };
    defer before.deinit();
    const since: ?i96 = if (before.value.last_attempt_time) |t| t.nanoseconds else null;
    try out.print("sent: {s} is {t}; its attempt shows in seconds\n", .{ before.value.id, before.value.state });
    try out.flush();

    // Measured: the attempt shows 3.4 to 14.9 s after the run, so read at
    // 5 s, then every 2 s for a minute.
    const sent = std.Io.Clock.real.now(init.io).nanoseconds;
    var wait_ms: u32 = if (use_fake) 1000 else 5000;
    while (std.Io.Clock.real.now(init.io).nanoseconds - sent < 60 * std.time.ns_per_s) {
        try init.io.sleep(.fromMilliseconds(wait_ms), .awake);
        wait_ms = 2000;
        var job = try client.getJob(location, id);
        defer job.deinit();
        const t = job.value.last_attempt_time orelse continue;
        if (since != null and t.nanoseconds == since.?) continue;
        const after_s = @divFloor(std.Io.Clock.real.now(init.io).nanoseconds - sent, std.time.ns_per_s);
        if (job.value.last_attempt) |attempt| {
            if (attempt.code == 0) {
                try out.print("attempt after {d} s: succeeded\n", .{after_s});
            } else {
                try out.print("attempt after {d} s: failed, code {d} ({s})\n", .{ after_s, attempt.code, codeName(attempt.code) });
            }
        } else {
            // A pause between the run and its start leaves no result.
            try out.print("attempt after {d} s: started, no result recorded\n", .{after_s});
        }
        try out.flush();
        return;
    }
    try out.writeAll("no attempt showed within a minute\n");
    try out.flush();
}

/// The gRPC code's name, as the console shows it.
fn codeName(code: i64) []const u8 {
    const names = [_][]const u8{
        "OK",                 "CANCELLED",           "UNKNOWN",        "INVALID_ARGUMENT",
        "DEADLINE_EXCEEDED",  "NOT_FOUND",           "ALREADY_EXISTS", "PERMISSION_DENIED",
        "RESOURCE_EXHAUSTED", "FAILED_PRECONDITION", "ABORTED",        "OUT_OF_RANGE",
        "UNIMPLEMENTED",      "INTERNAL",            "UNAVAILABLE",    "DATA_LOSS",
        "UNAUTHENTICATED",
    };
    return if (code >= 0 and code < names.len) names[@intCast(code)] else "?";
}
