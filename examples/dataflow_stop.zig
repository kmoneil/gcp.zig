//! Cancel a Dataflow job, or drain a streaming one, as a console's
//! confirmed write does: read the job and say whether production would
//! take the write, show the exact request, send it only when confirmed,
//! then read the job until it has ended.
//!
//!     GOOGLE_CLOUD_PROJECT=my-project zig build example-dataflow_stop -- --cancel JOB_ID
//!     GOOGLE_CLOUD_PROJECT=my-project zig build example-dataflow_stop -- --drain JOB_ID --yes
//!     zig build example-dataflow_stop -- --fake --yes     # no network
//!
//! Without `--yes` it prints the request and stops: that is the
//! confirmation. Credentials come from `auth.findDefault`, with the
//! cloud-platform scope; IAM asks `dataflow.jobs.cancel` for both writes
//! (Dataflow Developer holds it, Dataflow Viewer does not) and
//! `dataflow.jobs.get` to read the job. DATAFLOW_LOCATION picks the
//! job's region (us-central1 when unset): take it from the job as listed,
//! since a made-up region still reaches a us-central1 job. `--fake`
//! drains `dataflow.testing.FakeDataflow`'s streaming job instead, and
//! stands in for the service by ending it drained after the first read.

const std = @import("std");
const auth = @import("auth");
const dataflow = @import("dataflow");

pub const std_options: std.Options = .{
    .log_scope_levels = &.{
        .{ .scope = .gcp_auth, .level = .warn },
        .{ .scope = .gcp_dataflow, .level = .warn },
    },
};

const usage = "usage: dataflow_stop (--cancel JOB_ID | --drain JOB_ID | --fake) [--yes]\n";

pub fn main(init: std.process.Init) !void {
    const arena = init.arena.allocator();
    var stdout_buffer: [4096]u8 = undefined;
    var stdout = std.Io.File.stdout().writerStreaming(init.io, &stdout_buffer);
    const out = &stdout.interface;
    var diag: dataflow.Diagnostics = .{};

    const Write = enum { cancel, drain };
    var use_fake = false;
    var confirmed = false;
    var write: ?Write = null;
    var job_id: ?[]const u8 = null;
    const args = try init.minimal.args.toSlice(arena);
    var i: usize = @min(1, args.len);
    while (i < args.len) : (i += 1) {
        const arg = args[i];
        if (std.mem.eql(u8, arg, "--fake")) {
            use_fake = true;
        } else if (std.mem.eql(u8, arg, "--yes")) {
            confirmed = true;
        } else if ((std.mem.eql(u8, arg, "--cancel") or std.mem.eql(u8, arg, "--drain")) and write == null and i + 1 < args.len) {
            write = if (std.mem.eql(u8, arg, "--cancel")) .cancel else .drain;
            i += 1;
            job_id = args[i];
        } else {
            std.debug.print(usage, .{});
            return error.Usage;
        }
    }
    if (use_fake) {
        write = write orelse .drain;
        job_id = job_id orelse "2026-10-20_15_21_25-1828704797262605315";
    }
    const which = write orelse {
        std.debug.print(usage, .{});
        return error.Usage;
    };
    const id = job_id.?;

    var fake: dataflow.testing.FakeDataflow = .init(init.gpa, init.io, .{ .project_id = "my-project" });
    defer fake.deinit();
    var static: dataflow.StaticToken = .{ .token = "fake" };
    var creds: ?auth.Credentials = null;
    defer if (creds) |*c| c.deinit();
    const project = if (use_fake) "my-project" else init.environ_map.get("GOOGLE_CLOUD_PROJECT") orelse {
        std.debug.print("set GOOGLE_CLOUD_PROJECT to the project whose job to stop\n", .{});
        return error.MissingProject;
    };
    const location = if (use_fake) "us-central1" else init.environ_map.get("DATAFLOW_LOCATION") orelse "us-central1";
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
        try fake.putLocation("us-central1");
        _ = try fake.putJob(.{
            .location = "us-central1",
            .id = id,
            .name = "orders-stream",
            .type = .streaming,
            .current_state = .running,
        });
    }

    // What the job is now, and whether production would take the write.
    var job = client.getJob(location, id) catch |err| {
        std.debug.print("{t}: {s}\n", .{ err, diag.message() });
        return err;
    };
    defer job.deinit();
    const takes = switch (which) {
        .cancel => job.value.cancellable(),
        .drain => job.value.drainable(),
    };
    try out.print("{s} ({s}, {t}) is {t}\n", .{ job.value.id, job.value.name, job.value.type, job.value.current_state });
    if (!takes) try out.print("production would refuse this {t} as the job stands; sent anyway with --yes, its words come back\n", .{which});

    // The confirmation: the request, byte for byte what the write sends.
    var request = switch (which) {
        .cancel => client.cancelJobRequest(location, id),
        .drain => client.drainJobRequest(location, id),
    } catch |err| {
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

    const sent_result = switch (which) {
        .cancel => client.cancelJob(location, id),
        .drain => client.drainJob(location, id),
    };
    sent_result catch |err| {
        // A pending job's cancel: "Job is not yet ready for canceling."
        // A batch job's drain: "Only streaming workflows can be drained."
        std.debug.print("{t}: {s}\n", .{ err, diag.message() });
        return err;
    };
    try out.print("sent: production answers nothing more, so the job is read until it ends\n", .{});
    try out.flush();

    // Measured: a cancel took 240 s to end, a drain 126 s. Read every
    // 10 s for twenty minutes.
    const sent = std.Io.Clock.real.now(init.io).nanoseconds;
    var last: dataflow.JobState = .unspecified;
    while (std.Io.Clock.real.now(init.io).nanoseconds - sent < 20 * std.time.ns_per_min) {
        var now = try client.getJob(location, id);
        defer now.deinit();
        const after_s = @divFloor(std.Io.Clock.real.now(init.io).nanoseconds - sent, std.time.ns_per_s);
        if (now.value.current_state != last) {
            last = now.value.current_state;
            try out.print("after {d} s: {t}", .{ after_s, last });
            if (now.value.requested_state != .unspecified) try out.print(" (asked {t})", .{now.value.requested_state});
            try out.writeAll("\n");
            try out.flush();
        }
        if (now.value.terminal()) return;
        // The fake has no service to end the job: stand in for it.
        if (use_fake) {
            try fake.setJobState(id, if (which == .drain) .drained else .cancelled, null);
            continue;
        }
        try init.io.sleep(.fromSeconds(10), .awake);
    }
    try out.writeAll("the job had not ended after twenty minutes\n");
    try out.flush();
}
