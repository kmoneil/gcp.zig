//! The console's policy view behind the open-incidents widget: every alert
//! policy with its conditions, and the two writes a user confirms, turning
//! one off and snoozing one for an hour.
//!
//!     GOOGLE_CLOUD_PROJECT=my-project zig build example-monitoring_policies
//!     zig build example-monitoring_policies -- --disable POLICY_ID [--yes]
//!     zig build example-monitoring_policies -- --snooze POLICY_ID [--yes]
//!     zig build example-monitoring_policies -- --fake --snooze 1000000000000000001 --yes
//!
//! Without `--yes` a write prints its exact request and stops: that is the
//! confirmation. Credentials come from `auth.findDefault`. Reading takes
//! `monitoring.alertPolicies.list` (Monitoring Viewer); disabling,
//! `monitoring.alertPolicies.update` (Monitoring AlertPolicy Editor);
//! snoozing, `monitoring.snoozes.create` (Monitoring Snooze Editor).
//! `--fake` runs `monitoring.testing.FakeMonitoring` instead, with two
//! policies and an open alert a test put in, so a snooze shows the alert
//! closing.

const std = @import("std");
const auth = @import("auth");
const monitoring = @import("monitoring");

pub const std_options: std.Options = .{
    .log_scope_levels = &.{
        .{ .scope = .gcp_auth, .level = .warn },
        .{ .scope = .gcp_monitoring, .level = .warn },
    },
};

const usage = "usage: monitoring_policies [--fake] [--disable POLICY_ID | --snooze POLICY_ID] [--yes]\n";

pub fn main(init: std.process.Init) !void {
    const arena = init.arena.allocator();
    var stdout_buffer: [4096]u8 = undefined;
    var stdout = std.Io.File.stdout().writerStreaming(init.io, &stdout_buffer);
    const out = &stdout.interface;
    var diag: monitoring.Diagnostics = .{};

    var use_fake = false;
    var confirmed = false;
    var disable: ?[]const u8 = null;
    var snooze: ?[]const u8 = null;
    const args = try init.minimal.args.toSlice(arena);
    var i: usize = @min(1, args.len);
    while (i < args.len) : (i += 1) {
        const arg = args[i];
        if (std.mem.eql(u8, arg, "--fake")) {
            use_fake = true;
        } else if (std.mem.eql(u8, arg, "--yes")) {
            confirmed = true;
        } else if (std.mem.eql(u8, arg, "--disable") and i + 1 < args.len) {
            i += 1;
            disable = args[i];
        } else if (std.mem.eql(u8, arg, "--snooze") and i + 1 < args.len) {
            i += 1;
            snooze = args[i];
        } else {
            std.debug.print(usage, .{});
            return error.Usage;
        }
    }

    var fake: monitoring.testing.FakeMonitoring = .init(init.gpa, init.io, .{ .project_id = "my-project" });
    defer fake.deinit();
    var static: monitoring.StaticToken = .{ .token = "fake" };
    var creds: ?auth.Credentials = null;
    defer if (creds) |*c| c.deinit();
    const project = if (use_fake) "my-project" else init.environ_map.get("GOOGLE_CLOUD_PROJECT") orelse {
        std.debug.print("set GOOGLE_CLOUD_PROJECT to the project whose policies to read\n", .{});
        return error.MissingProject;
    };
    if (!use_fake) {
        var lookup = try auth.Lookup.fromEnv(init.environ_map, arena);
        lookup.diagnostics = &diag;
        creds = try auth.findDefault(init.gpa, init.io, lookup, .{});
    }
    var client = try monitoring.Client.init(init.gpa, init.io, .{
        .project_id = project,
        .token_provider = if (creds) |*c| c.provider() else static.provider(),
        .transport = if (use_fake) fake.transport() else null,
        .diagnostics = &diag,
    });
    defer client.deinit();

    if (use_fake) {
        const backlog = try fake.putAlertPolicy(.{
            .display_name = "Pub/Sub backlog too deep",
            .severity = .warning,
            .documentation = .{ .content = "Scale the workers.", .subject = "orders backlog" },
            .conditions = &.{.{
                .display_name = "undelivered over 1000 for 5 min",
                .kind = .threshold,
                .filter = "metric.type=\"pubsub.googleapis.com/subscription/num_undelivered_messages\" AND resource.type=\"pubsub_subscription\"",
                .comparison = .gt,
                .threshold_value = 1000,
                .duration_s = 300,
            }},
        });
        _ = try fake.putAlertPolicy(.{
            .display_name = "Checkout errors",
            .severity = .critical,
            .conditions = &.{.{ .display_name = "5xx logged", .kind = .log_match, .filter = "resource.type=\"cloud_run_revision\" AND severity>=ERROR" }},
        });
        _ = try fake.putAlert(.{
            .open_time = std.Io.Clock.real.now(init.io),
            .policy = .{ .name = backlog, .display_name = "Pub/Sub backlog too deep", .severity = .warning },
        });
    }

    if (disable) |id| return disablePolicy(&client, &diag, out, id, confirmed);
    if (snooze) |id| return snoozePolicy(&client, &diag, out, id, confirmed);

    // The view: every policy, its conditions, and whether it is on.
    var page = client.listAlertPolicies(.{ .order_by = "display_name" }) catch |err| {
        std.debug.print("{t}: {s}\n", .{ err, diag.message() });
        return err;
    };
    defer page.deinit();
    for (page.value.policies) |p| {
        try out.print("{s} [{t}] {s} id={s}\n", .{ if (p.enabled) "on " else "off", p.severity, p.display_name, p.id });
        for (p.conditions) |c| {
            try out.print("    {t}: {s}", .{ c.kind, c.display_name });
            if (c.threshold_value) |v| try out.print(" ({t} {d})", .{ c.comparison, v });
            try out.writeAll("\n");
        }
    }
    try out.print("{d} policies\n", .{page.value.policies.len});
    try out.flush();
}

fn disablePolicy(client: *monitoring.Client, diag: *monitoring.Diagnostics, out: *std.Io.Writer, id: []const u8, confirmed: bool) !void {
    var request = client.setAlertPolicyEnabledRequest(id, false) catch |err| {
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
    var policy = client.setAlertPolicyEnabled(id, false) catch |err| {
        std.debug.print("{t}: {s}\n", .{ err, diag.message() });
        return err;
    };
    defer policy.deinit();
    try out.print("{s} is off; it opens no alerts until enabled\n", .{policy.value.display_name});
    try out.flush();
}

fn snoozePolicy(client: *monitoring.Client, diag: *monitoring.Diagnostics, out: *std.Io.Writer, id: []const u8, confirmed: bool) !void {
    const io = client.io;
    const now = std.Io.Clock.real.now(io);
    const spec: monitoring.NewSnooze = .{
        .display_name = "snoozed from the console",
        .policies = &.{id},
        .start = now,
        .end = .{ .nanoseconds = now.nanoseconds + std.time.ns_per_hour },
    };
    var request = client.createSnoozeRequest(spec) catch |err| {
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
    var made = client.createSnooze(spec) catch |err| {
        std.debug.print("{t}: {s}\n", .{ err, diag.message() });
        return err;
    };
    defer made.deinit();
    try out.print("snoozed until {d} s from now; its open alerts close at its start\n", .{@divFloor(made.value.end.nanoseconds - now.nanoseconds, std.time.ns_per_s)});
    // What the incidents widget shows next.
    var open = try client.listAlerts(.{ .open_only = true });
    defer open.deinit();
    try out.print("{d} alerts open now\n", .{open.value.alerts.len});
    try out.flush();
}
