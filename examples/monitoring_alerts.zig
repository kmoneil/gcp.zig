//! The console's open-incidents widget: the alerts open in a project now,
//! each with the policy that opened it, its severity and its age.
//!
//!     GOOGLE_CLOUD_PROJECT=my-project zig build example-monitoring_alerts
//!     zig build example-monitoring_alerts -- --fake     # no network
//!
//! Credentials come from `auth.findDefault`; reading alerts needs
//! `monitoring.alerts.list` (Monitoring Viewer). `--fake` reads
//! `monitoring.testing.FakeMonitoring` instead, with two incidents a test
//! put in, and closes one to show the widget emptying.

const std = @import("std");
const auth = @import("auth");
const monitoring = @import("monitoring");

pub const std_options: std.Options = .{
    .log_scope_levels = &.{
        .{ .scope = .gcp_auth, .level = .warn },
        .{ .scope = .gcp_monitoring, .level = .warn },
    },
};

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
        } else {
            std.debug.print("usage: monitoring_alerts [--fake]\n", .{});
            return error.Usage;
        }
    }

    var fake: monitoring.testing.FakeMonitoring = .init(init.gpa, init.io, .{ .project_id = "my-project" });
    defer fake.deinit();
    var static: monitoring.StaticToken = .{ .token = "fake" };
    var creds: ?auth.Credentials = null;
    defer if (creds) |*c| c.deinit();
    const project = if (use_fake) "my-project" else init.environ_map.get("GOOGLE_CLOUD_PROJECT") orelse {
        std.debug.print("set GOOGLE_CLOUD_PROJECT to the project whose alerts to read\n", .{});
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

    // Incidents come from alert policies, which no program makes through
    // this API; a test puts them into the fake.
    var backlog_id: []const u8 = "";
    if (use_fake) {
        const now = std.Io.Clock.real.now(init.io);
        backlog_id = try arena.dupe(u8, try fake.putAlert(.{
            .open_time = .{ .nanoseconds = now.nanoseconds - 42 * std.time.ns_per_min },
            .policy = .{ .display_name = "Pub/Sub backlog too deep", .severity = .warning, .user_labels = &.{.{ .key = "team", .value = "ingest" }} },
            .metric_type = "pubsub.googleapis.com/subscription/num_undelivered_messages",
            .resource_type = "pubsub_subscription",
            .resource_labels = &.{ .{ .key = "project_id", .value = "my-project" }, .{ .key = "subscription_id", .value = "orders" } },
        }));
        _ = try fake.putAlert(.{
            .open_time = .{ .nanoseconds = now.nanoseconds - 3 * std.time.ns_per_min },
            .policy = .{ .display_name = "API error rate over 1%", .severity = .critical },
            .metric_type = "custom.googleapis.com/shop/errors",
            .resource_type = "global",
            .resource_labels = &.{.{ .key = "project_id", .value = "my-project" }},
        });
    }

    try drawWidget(out, &client, init.io);
    if (use_fake) {
        // The backlog drains: production would close the alert itself.
        try fake.closeAlert(backlog_id, std.Io.Clock.real.now(init.io));
        try out.writeAll("\nthe backlog alert closes...\n\n");
        try drawWidget(out, &client, init.io);
    }
    try out.flush();
}

/// The widget: open incidents, newest first, production's default order.
fn drawWidget(out: *std.Io.Writer, client: *monitoring.Client, io: std.Io) !void {
    var page = try client.listAlerts(.{ .open_only = true });
    defer page.deinit();
    if (page.value.alerts.len == 0) {
        try out.writeAll("no open incidents\n");
        try out.flush();
        return;
    }
    const now = std.Io.Clock.real.now(io);
    for (page.value.alerts) |alert| {
        const age_min = @divFloor(now.nanoseconds - alert.open_time.nanoseconds, std.time.ns_per_min);
        try out.print("[{s}] {s} (open {d} min, id {s})\n", .{
            switch (alert.policy.severity) {
                .critical => "CRITICAL",
                .@"error" => "ERROR",
                .warning => "WARNING",
                else => "-",
            },
            alert.policy.display_name,
            age_min,
            alert.id,
        });
    }
    try out.flush();
}
