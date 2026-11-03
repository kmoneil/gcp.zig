//! Create a spot VM with a startup script, wait for it, read what the
//! script wrote to its serial console, stop it, start it and delete it:
//! the life of a VM, each write shown before it is sent.
//!
//!     GOOGLE_CLOUD_PROJECT=my-project zig build example-compute -- --yes
//!     GOOGLE_CLOUD_PROJECT=my-project zig build example-compute -- --zone europe-west1-b --name batch-1 --yes
//!     zig build example-compute -- --fake --yes     # no network
//!
//! Without `--yes` it prints the insert it would send and stops: that is
//! the confirmation. The VM is an e2-micro spot VM from debian-12 with a
//! one-hour run limit that deletes it, so a VM left behind by a crash
//! goes on its own; it costs well under a cent. Credentials come from
//! `auth.findDefault`, with the `compute` scope (`.read_write`); IAM
//! asks `compute.instances.create`, `.start`, `.stop`, `.delete` and
//! `.getSerialPortOutput`. A zone out of spot VMs ends the insert's
//! operation failed: the example says so, and `--zone` names another.
//! `--fake` works on `compute.testing.FakeCompute` instead, and writes
//! the script's line to the console itself.

const std = @import("std");
const auth = @import("auth");
const compute = @import("compute");

pub const std_options: std.Options = .{
    .log_scope_levels = &.{
        .{ .scope = .gcp_auth, .level = .warn },
        .{ .scope = .gcp_compute, .level = .warn },
    },
};

const usage = "usage: compute [--zone ZONE] [--name NAME] [--fake] [--yes]\n";

pub fn main(init: std.process.Init) !void {
    const arena = init.arena.allocator();
    var stdout_buffer: [4096]u8 = undefined;
    var stdout = std.Io.File.stdout().writerStreaming(init.io, &stdout_buffer);
    const out = &stdout.interface;
    var diag: compute.Diagnostics = .{};

    var use_fake = false;
    var confirmed = false;
    var zone: []const u8 = "us-central1-a";
    var name: []const u8 = "example-vm";
    const args = try init.minimal.args.toSlice(arena);
    var i: usize = @min(1, args.len);
    while (i < args.len) : (i += 1) {
        const arg = args[i];
        if (std.mem.eql(u8, arg, "--fake")) {
            use_fake = true;
        } else if (std.mem.eql(u8, arg, "--yes")) {
            confirmed = true;
        } else if (std.mem.eql(u8, arg, "--zone") and i + 1 < args.len) {
            zone = args[i + 1];
            i += 1;
        } else if (std.mem.eql(u8, arg, "--name") and i + 1 < args.len) {
            name = args[i + 1];
            i += 1;
        } else {
            std.debug.print(usage, .{});
            return error.Usage;
        }
    }

    var fake: compute.testing.FakeCompute = .init(init.gpa, init.io, .{ .project_id = "my-project" });
    defer fake.deinit();
    var static: compute.StaticToken = .{ .token = "fake" };
    var creds: ?auth.Credentials = null;
    defer if (creds) |*c| c.deinit();
    const project = if (use_fake) "my-project" else init.environ_map.get("GOOGLE_CLOUD_PROJECT") orelse {
        std.debug.print("set GOOGLE_CLOUD_PROJECT to the project to create the VM in\n", .{});
        return error.MissingProject;
    };
    if (!use_fake) {
        var lookup = try auth.Lookup.fromEnv(init.environ_map, arena);
        lookup.diagnostics = &diag;
        creds = try auth.findDefault(init.gpa, init.io, lookup, .{});
    }
    var client = try compute.Client.init(init.gpa, init.io, .{
        .project_id = project,
        .token_provider = if (creds) |*c| c.provider() else static.provider(),
        .scope = .read_write,
        .transport = if (use_fake) fake.transport() else null,
        .diagnostics = &diag,
    });
    defer client.deinit();

    const marker = try std.fmt.allocPrint(arena, "hello from {s}", .{name});
    const spec: compute.InstanceSpec = .{
        .name = name,
        .machine_type = "e2-micro",
        .image = .{ .family = .{ .project = "debian-cloud", .name = "debian-12" } },
        .spot = true,
        .max_run_duration_s = 3600,
        .termination_action = .delete,
        .labels = &.{.{ .key = "made-by", .value = "gcp-zig-example" }},
        .metadata = &.{.{ .key = "startup-script", .value = try std.fmt.allocPrint(arena, "#!/bin/bash\necho '{s}' > /dev/ttyS0\n", .{marker}) }},
    };

    // The confirmation: the insert, byte for byte, with the request id the
    // insert will send, so a retry after a lost answer lands once.
    var id_buf: [36]u8 = undefined;
    const id = client.newRequestId(&id_buf);
    var preview = client.insertInstanceRequest(zone, spec, .{ .request_id = id }) catch |err| return report(err, &diag);
    defer preview.deinit();
    try out.print("{t} {s}\n{s}\n", .{ preview.value.method, preview.value.url, preview.value.body });
    if (!confirmed) {
        try out.writeAll("not sent: run again with --yes to create it\n");
        return out.flush();
    }

    var insert = client.insertInstance(zone, spec, .{ .request_id = id }) catch |err| return report(err, &diag);
    if (!try finished(out, &client, &diag, "insert", &insert)) {
        try out.print("{s} has no room for a spot e2-micro now: try another zone with --zone\n", .{zone});
        return out.flush();
    }
    try show(out, &client, zone, name);

    if (use_fake) try fake.appendSerial(zone, name, try std.fmt.allocPrint(arena, "[  4.2] startup-script: {s}\r\n", .{marker}));
    try serial(out, &client, zone, name, marker, use_fake);

    var stop = client.stopInstance(zone, name, .{}) catch |err| return report(err, &diag);
    _ = try finished(out, &client, &diag, "stop", &stop);
    try show(out, &client, zone, name);
    var start = client.startInstance(zone, name, .{}) catch |err| return report(err, &diag);
    _ = try finished(out, &client, &diag, "start", &start);
    try show(out, &client, zone, name);
    var delete = client.deleteInstance(zone, name, .{}) catch |err| return report(err, &diag);
    _ = try finished(out, &client, &diag, "delete", &delete);
    try out.print("{s} deleted\n", .{name});
    try out.flush();
}

fn report(err: anyerror, diag: *const compute.Diagnostics) anyerror {
    std.debug.print("{t}: {s}\n", .{ err, diag.message() });
    return err;
}

/// Waits for a write's operation and frees it: true when it succeeded,
/// false for a stockout, the zone out of room. Each wait call is held by
/// the server for up to two minutes; a stop took about a minute when
/// measured.
fn finished(out: *std.Io.Writer, client: *compute.Client, diag: *compute.Diagnostics, what: []const u8, op: *compute.Owned(compute.Operation)) !bool {
    defer op.deinit();
    try out.print("{s}: {s}\n", .{ what, op.value.name });
    try out.flush();
    var done = client.waitOperation(op.value.ref(), .{ .timeout_ms = 600_000 }) catch |err| return report(err, diag);
    defer done.deinit();
    if (!done.value.done()) {
        std.debug.print("{s} was not done after ten minutes: read it with getOperation\n", .{what});
        return error.TimedOut;
    }
    const failure = done.value.failure orelse return true;
    if (failure.stockout()) return false;
    std.debug.print("{s} failed: {s}: {s}\n", .{ what, failure.code(), failure.message() });
    return error.OperationFailed;
}

fn show(out: *std.Io.Writer, client: *compute.Client, zone: []const u8, name: []const u8) !void {
    var vm = try client.getInstance(zone, name);
    defer vm.deinit();
    try out.print("  {s} in {s}: {t}, {s}, {t}\n", .{ vm.value.name, vm.value.zone, vm.value.status, vm.value.machine_type, vm.value.scheduling.provisioning_model });
    try out.flush();
}

/// Follows the serial console from its oldest byte until the startup
/// script's line shows, for up to two minutes: a VM's console keeps its
/// last megabyte, and `next` is where to read on from.
fn serial(out: *std.Io.Writer, client: *compute.Client, zone: []const u8, name: []const u8, marker: []const u8, use_fake: bool) !void {
    var start: ?u64 = 0;
    for (0..24) |_| {
        var page = try client.serialOutput(zone, name, .{ .start = start });
        defer page.deinit();
        var lines = std.mem.splitScalar(u8, page.value.contents, '\n');
        while (lines.next()) |line| if (std.mem.indexOf(u8, line, marker) != null) {
            try out.print("  serial: {s}\n", .{std.mem.trimEnd(u8, line, "\r")});
            return out.flush();
        };
        start = page.value.next;
        if (!use_fake) try client.io.sleep(.fromSeconds(5), .awake);
    }
    try out.writeAll("  the startup script's line had not shown after two minutes\n");
}
