//! Run a Cloud Run job, cancel an execution, or send all of a service's
//! traffic to one revision, as a console's confirmed write does: read
//! first and say whether production would take it, show the exact
//! request, send it only when confirmed, then follow it to its end.
//!
//!     GOOGLE_CLOUD_PROJECT=my-project zig build example-run_actions -- --run JOB
//!     GOOGLE_CLOUD_PROJECT=my-project zig build example-run_actions -- --cancel JOB EXECUTION --yes
//!     GOOGLE_CLOUD_PROJECT=my-project zig build example-run_actions -- --rollback SERVICE REVISION --yes
//!     zig build example-run_actions -- --fake --yes     # no network
//!
//! Without `--yes` it prints the request and stops: that is the
//! confirmation. Credentials come from `auth.findDefault`, with the
//! `run` scope (`.read_write`): production refuses every write to
//! `run.readonly`. IAM asks `run.jobs.run`, `run.executions.cancel` or
//! `run.services.update`. RUN_LOCATION picks the region (us-central1
//! when unset). `--fake` works on `run.testing.FakeRun` instead (a
//! rollback of `orders-api` unless another write is named), and stands
//! in for Cloud Run by moving its executions on.

const std = @import("std");
const auth = @import("auth");
const run = @import("run");

pub const std_options: std.Options = .{
    .log_scope_levels = &.{
        .{ .scope = .gcp_auth, .level = .warn },
        .{ .scope = .gcp_run, .level = .warn },
    },
};

const usage = "usage: run_actions (--run JOB | --cancel JOB EXECUTION | --rollback SERVICE REVISION | --fake) [--yes]\n";

const Write = union(enum) {
    run: []const u8,
    cancel: struct { job: []const u8, id: []const u8 },
    rollback: struct { service: []const u8, revision: []const u8 },
};

pub fn main(init: std.process.Init) !void {
    const arena = init.arena.allocator();
    var stdout_buffer: [4096]u8 = undefined;
    var stdout = std.Io.File.stdout().writerStreaming(init.io, &stdout_buffer);
    const out = &stdout.interface;
    var diag: run.Diagnostics = .{};

    var use_fake = false;
    var confirmed = false;
    var write: ?Write = null;
    const args = try init.minimal.args.toSlice(arena);
    var i: usize = @min(1, args.len);
    while (i < args.len) : (i += 1) {
        const arg = args[i];
        if (std.mem.eql(u8, arg, "--fake")) {
            use_fake = true;
        } else if (std.mem.eql(u8, arg, "--yes")) {
            confirmed = true;
        } else if (std.mem.eql(u8, arg, "--run") and write == null and i + 1 < args.len) {
            write = .{ .run = args[i + 1] };
            i += 1;
        } else if (std.mem.eql(u8, arg, "--cancel") and write == null and i + 2 < args.len) {
            write = .{ .cancel = .{ .job = args[i + 1], .id = args[i + 2] } };
            i += 2;
        } else if (std.mem.eql(u8, arg, "--rollback") and write == null and i + 2 < args.len) {
            write = .{ .rollback = .{ .service = args[i + 1], .revision = args[i + 2] } };
            i += 2;
        } else {
            std.debug.print(usage, .{});
            return error.Usage;
        }
    }
    if (use_fake and write == null) write = .{ .rollback = .{ .service = "orders-api", .revision = "orders-api-00001-abc" } };
    const which = write orelse {
        std.debug.print(usage, .{});
        return error.Usage;
    };

    var fake: run.testing.FakeRun = .init(init.gpa, init.io, .{ .project_id = "my-project" });
    defer fake.deinit();
    var static: run.StaticToken = .{ .token = "fake" };
    var creds: ?auth.Credentials = null;
    defer if (creds) |*c| c.deinit();
    const project = if (use_fake) "my-project" else init.environ_map.get("GOOGLE_CLOUD_PROJECT") orelse {
        std.debug.print("set GOOGLE_CLOUD_PROJECT to the project to act in\n", .{});
        return error.MissingProject;
    };
    const location = if (use_fake) "us-central1" else init.environ_map.get("RUN_LOCATION") orelse "us-central1";
    if (!use_fake) {
        var lookup = try auth.Lookup.fromEnv(init.environ_map, arena);
        lookup.diagnostics = &diag;
        creds = try auth.findDefault(init.gpa, init.io, lookup, .{});
    }
    var client = try run.Client.init(init.gpa, init.io, .{
        .project_id = project,
        .token_provider = if (creds) |*c| c.provider() else static.provider(),
        .scope = .read_write,
        .transport = if (use_fake) fake.transport() else null,
        .diagnostics = &diag,
    });
    defer client.deinit();
    if (use_fake) try seed(&fake);

    switch (which) {
        .run => |job_id| try runJob(out, &client, &diag, location, job_id, confirmed, if (use_fake) &fake else null),
        .cancel => |e| try cancel(out, &client, &diag, location, e.job, e.id, confirmed, if (use_fake) &fake else null),
        .rollback => |r| try rollback(out, &client, &diag, location, r.service, r.revision, confirmed),
    }
    try out.flush();
}

/// A job, an execution of it running, and a service with two ready
/// revisions, for `--fake`.
fn seed(fake: *run.testing.FakeRun) !void {
    try fake.putLocation("us-central1");
    _ = try fake.putJob(.{ .location = "us-central1", .id = "nightly-report", .containers = &.{.{ .image = "us-docker.pkg.dev/cloudrun/container/job" }} });
    _ = try fake.putExecution(.{ .location = "us-central1", .job = "nightly-report", .id = "nightly-report-x7k2p", .status = .running });
    _ = try fake.putService(.{
        .location = "us-central1",
        .id = "orders-api",
        .latest_ready_revision = "orders-api-00002-def",
        .traffic = &.{.{ .type = .latest, .percent = 100 }},
        .traffic_statuses = &.{.{ .type = .latest, .revision = "orders-api-00002-def", .percent = 100 }},
        .terminal_condition = .{ .type = "Ready", .state = .succeeded },
        .generation = 2,
    });
    for ([_][]const u8{ "orders-api-00001-abc", "orders-api-00002-def" }) |id| {
        _ = try fake.putRevision(.{ .location = "us-central1", .service = "orders-api", .id = id, .conditions = &.{.{ .type = "Ready", .state = .succeeded }} });
    }
}

/// The confirmation: the request, byte for byte what the write sends.
fn confirm(out: *std.Io.Writer, request: run.Owned(run.PreparedRequest), confirmed: bool) !bool {
    var r = request;
    defer r.deinit();
    try out.print("{t} {s}\n{s}\n", .{ r.value.method, r.value.url, r.value.body });
    if (!confirmed) try out.writeAll("not sent: run again with --yes to send it\n");
    try out.flush();
    return confirmed;
}

fn report(err: anyerror, diag: *const run.Diagnostics) anyerror {
    std.debug.print("{t}: {s}\n", .{ err, diag.message() });
    return err;
}

fn runJob(out: *std.Io.Writer, client: *run.Client, diag: *run.Diagnostics, location: []const u8, job_id: []const u8, confirmed: bool, fake: ?*run.testing.FakeRun) !void {
    var job = client.getJob(location, job_id) catch |err| return report(err, diag);
    defer job.deinit();
    try out.print("{s}: {d} executions", .{ job.value.id, job.value.execution_count });
    if (job.value.latest_created_execution) |latest| try out.print(", the latest {s} {t}", .{ latest.id, latest.status });
    try out.writeAll("\n");
    if (!try confirm(out, client.runJobRequest(location, job_id) catch |err| return report(err, diag), confirmed)) return;

    // Sent once: a run that may have landed is never sent again.
    var op = client.runJob(location, job_id) catch |err| {
        std.debug.print("list the job's executions to see whether it ran\n", .{});
        return report(err, diag);
    };
    defer op.deinit();
    const execution = op.value.subject.execution.name;
    try out.print("sent: execution {s}\n", .{op.value.subject.execution.id});
    try follow(out, client, execution, fake, &.{ .running, .succeeded });
}

fn cancel(out: *std.Io.Writer, client: *run.Client, diag: *run.Diagnostics, location: []const u8, job_id: []const u8, id: []const u8, confirmed: bool, fake: ?*run.testing.FakeRun) !void {
    var execution = client.getExecution(location, job_id, id) catch |err| return report(err, diag);
    defer execution.deinit();
    try out.print("{s} is {t}\n", .{ execution.value.id, execution.value.status() });
    if (!execution.value.cancellable()) try out.writeAll("production would refuse this cancel: it takes one of a pending or running execution only\n");
    if (!try confirm(out, client.cancelExecutionRequest(location, job_id, id) catch |err| return report(err, diag), confirmed)) return;
    var op = client.cancelExecution(location, job_id, id) catch |err| return report(err, diag);
    defer op.deinit();
    try out.writeAll("sent\n");
    try follow(out, client, execution.value.name, fake, &.{.cancelled});
}

/// Reads the execution every 10 s until it ends, printing each change: a
/// run took 100 s to end, a cancel 16 s (measured). Under `--fake` it
/// moves the execution through `steps` instead, standing in for Cloud Run.
fn follow(out: *std.Io.Writer, client: *run.Client, name: []const u8, fake: ?*run.testing.FakeRun, steps: []const run.ExecutionStatus) !void {
    var last: run.ExecutionStatus = .unspecified;
    var step: usize = 0;
    for (0..90) |_| {
        var now = try client.getExecutionNamed(name);
        defer now.deinit();
        const status = now.value.status();
        if (status != last) {
            last = status;
            try out.print("  {t}\n", .{status});
            try out.flush();
        }
        if (status.ended()) return;
        if (fake) |f| {
            if (step < steps.len) try f.setExecutionStatus(name, steps[step]);
            step += 1;
            continue;
        }
        try client.io.sleep(.fromSeconds(10), .awake);
    }
    try out.writeAll("it had not ended after fifteen minutes\n");
}

fn rollback(out: *std.Io.Writer, client: *run.Client, diag: *run.Diagnostics, location: []const u8, service_id: []const u8, revision_id: []const u8, confirmed: bool) !void {
    var service = client.getService(location, service_id) catch |err| return report(err, diag);
    defer service.deinit();
    var revision = client.getRevision(location, service_id, revision_id) catch |err| return report(err, diag);
    defer revision.deinit();
    // Production takes a change to a revision that is not ready, and the
    // service then fails: check first.
    if (!revision.value.ready()) {
        try out.print("{s} is not ready: sending traffic to it would leave {s} failed\n", .{ revision_id, service_id });
        return;
    }
    for (service.value.traffic) |t| try out.print("{s} now: {d}% to {s}\n", .{ service_id, t.percent, if (t.type == .latest) "the latest ready revision" else t.revision });
    const options: run.RouteOptions = .{ .etag = service.value.etag };
    // The service's own check: the etag is still current, and the target's
    // form is right (it does not check the revision exists).
    var check = client.routeAllTraffic(location, service_id, revision_id, .{ .etag = options.etag, .validate_only = true }) catch |err| return report(err, diag);
    check.deinit();
    if (!try confirm(out, client.routeAllTrafficRequest(location, service_id, revision_id, options) catch |err| return report(err, diag), confirmed)) return;

    var op = client.routeAllTraffic(location, service_id, revision_id, options) catch |err| {
        // error.Aborted: the service changed since it was read.
        return report(err, diag);
    };
    defer op.deinit();
    try out.writeAll("sent\n");
    // Done in 4 s when measured: read every 2 s for two minutes.
    for (0..60) |_| {
        var now = try client.getOperation(op.value.name);
        defer now.deinit();
        if (now.value.done) {
            if (now.value.failure) |why| {
                try out.print("failed ({d}): {s}\n", .{ why.code, why.message });
            } else {
                try out.print("done: all traffic to {s}\n", .{now.value.subject.service.traffic[0].revision});
            }
            return;
        }
        try client.io.sleep(.fromSeconds(2), .awake);
    }
    try out.writeAll("the change was not done after two minutes\n");
}
