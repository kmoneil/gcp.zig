//! An error dashboard: what is failing in a project now, how often over
//! the last day in hourly buckets, whether each group is new, and the
//! latest stack trace of the busiest.
//!
//!     GOOGLE_CLOUD_PROJECT=my-project zig build example-error_dashboard
//!     ... -- --period=week            # hour, six_hours, day, week, thirty_days
//!     ... -- --service=checkout       # one service's errors
//!     ... -- --resolve=GROUP_ID       # set a group's status, then list
//!     zig build example-error_dashboard -- --fake     # no network
//!
//! Credentials come from `auth.findDefault`. Reading needs
//! `errorreporting.groups.list` and `errorreporting.errorEvents.list`
//! (Viewer has both), resolving `errorreporting.groupMetadata.update`
//! (Error Reporting User, or Editor). `--fake` reads from
//! `error_reporting.testing.FakeErrorReporting` instead, filled with a few
//! errors of its own.

const std = @import("std");
const auth = @import("auth");
const er = @import("error_reporting");

pub const std_options: std.Options = .{
    .log_scope_levels = &.{
        .{ .scope = .gcp_auth, .level = .warn },
        .{ .scope = .gcp_error_reporting, .level = .warn },
    },
};

pub fn main(init: std.process.Init) !void {
    const arena = init.arena.allocator();
    var stdout_buffer: [4096]u8 = undefined;
    var stdout = std.Io.File.stdout().writerStreaming(init.io, &stdout_buffer);
    const out = &stdout.interface;
    var diag: er.Diagnostics = .{};

    var period: er.Period = .day;
    var service: ?[]const u8 = null;
    var resolve: ?[]const u8 = null;
    var use_fake = false;
    const args = try init.minimal.args.toSlice(arena);
    for (args[@min(1, args.len)..]) |arg| {
        if (std.mem.eql(u8, arg, "--fake")) {
            use_fake = true;
        } else if (std.mem.startsWith(u8, arg, "--period=")) {
            period = std.meta.stringToEnum(er.Period, arg["--period=".len..]) orelse return usage();
        } else if (std.mem.startsWith(u8, arg, "--service=")) {
            service = arg["--service=".len..];
        } else if (std.mem.startsWith(u8, arg, "--resolve=")) {
            resolve = arg["--resolve=".len..];
        } else return usage();
    }

    var fake: er.testing.FakeErrorReporting = .init(init.gpa, init.io, .{ .project_id = "my-project" });
    defer fake.deinit();
    var creds: ?auth.Credentials = null;
    defer if (creds) |*c| c.deinit();
    var static: er.StaticToken = .{ .token = "fake" };
    const project = if (use_fake) "my-project" else init.environ_map.get("GOOGLE_CLOUD_PROJECT") orelse {
        std.debug.print("set GOOGLE_CLOUD_PROJECT to the project whose errors to read\n", .{});
        return error.MissingProject;
    };
    if (use_fake) {
        try fill(&fake, init.io);
    } else {
        var lookup = try auth.Lookup.fromEnv(init.environ_map, arena);
        lookup.diagnostics = &diag;
        creds = auth.findDefault(init.gpa, init.io, lookup, .{}) catch |err| return fail(err, &diag, null);
    }
    var client = er.Client.init(init.gpa, init.io, .{
        .project_id = project,
        .token_provider = if (creds) |*c| c.provider() else static.provider(),
        .transport = if (use_fake) fake.transport() else null,
        .diagnostics = &diag,
    }) catch |err| return fail(err, &diag, null);
    defer client.deinit();

    if (resolve) |id| {
        var group = client.group(id).setStatus(.resolved) catch |err| return fail(err, &diag, &client);
        defer group.deinit();
        try out.print("resolved {s}\n\n", .{group.value.id});
    }

    // One page of the busiest groups over the period, each with its buckets:
    // what a dashboard's table and trend chart draw.
    var query = client.groupStats(.{
        .period = period,
        .timed_count_seconds = bucketSeconds(period),
        .service = .{ .service = service },
        .page_size = 10,
    }) catch |err| return fail(err, &diag, &client);
    defer query.deinit();
    var page = query.page(null) catch |err| return fail(err, &diag, &client);
    defer page.deinit();

    try out.print("{s}, over the last {t}:\n", .{ project, period });
    if (page.value.items.len == 0) try out.print("  no errors\n", .{});
    const begin = page.value.time_range_begin;
    for (page.value.items) |s| {
        const fresh = if (begin) |b| if (s.first_seen) |f| f.nanoseconds >= b.nanoseconds else false else false;
        try out.print("  {d:>6}  {s}{s}\n", .{ s.count, if (fresh) "NEW " else "", if (s.representative) |r| r.headline() else "(no sample)" });
        try out.print("          {s}  {t}  {d} users  ", .{ s.group.id, s.group.status, s.affected_users });
        try sparkline(out, s.timed_counts);
        try out.print("\n", .{});
    }
    if (page.value.next_page_token != null) try out.print("  ... and more\n", .{});

    // The busiest group's latest error, with its stack trace.
    if (page.value.items.len > 0) {
        const busiest = page.value.items[0].group.id;
        var events = client.events(busiest, .{ .period = period, .page_size = 1 }) catch |err| return fail(err, &diag, &client);
        defer events.deinit();
        var latest = events.page(null) catch |err| return fail(err, &diag, &client);
        defer latest.deinit();
        if (latest.value.items.len > 0) {
            const e = latest.value.items[0];
            try out.print("\nlatest of {s}, from {s}:\n{s}\n", .{ busiest, e.service.service orelse "an unnamed service", e.message });
        }
    }
    try out.flush();
}

/// Buckets a period's chart can show: at most 100, Error Reporting's limit.
fn bucketSeconds(period: er.Period) u32 {
    return switch (period) {
        .hour => 300,
        .six_hours => 1800,
        .day => 3600,
        .week => 6 * 3600,
        .thirty_days => 24 * 3600,
    };
}

/// The buckets as a row of eight levels, oldest first.
fn sparkline(out: *std.Io.Writer, buckets: []const er.TimedCount) !void {
    const levels = [_][]const u8{ " ", "▁", "▂", "▃", "▄", "▅", "▆", "▇", "█" };
    var top: u64 = 0;
    for (buckets) |b| top = @max(top, b.count);
    for (buckets) |b| {
        const level = if (top == 0) 0 else (b.count * (levels.len - 1) + top - 1) / top;
        try out.writeAll(levels[level]);
    }
}

/// A few errors for `--fake`: a Python one, frequent and new, a Java one
/// spread over the day, and a Go one from two days ago.
fn fill(fake: *er.testing.FakeErrorReporting, io: std.Io) !void {
    const now_s: i64 = @intCast(@divFloor(std.Io.Clock.real.now(io).nanoseconds, std.time.ns_per_s));
    const at = struct {
        fn at(now: i64, seconds_ago: i64) std.Io.Timestamp {
            return .{ .nanoseconds = @as(i96, now - seconds_ago) * std.time.ns_per_s };
        }
    }.at;
    const python = "Traceback (most recent call last):\n  File \"/srv/orders.py\", line 41, in handle\n    total = price(order)\n  File \"/srv/orders.py\", line 12, in price\n    raise ValueError(\"order has no lines\")\nValueError: order has no lines";
    for (0..12) |i| _ = try fake.report(.{ .message = python, .time = at(now_s, @intCast(60 + i * 300)), .service = .{ .service = "orders", .version = "v7" }, .user = if (i % 3 == 0) "ana" else "ben" });
    const java = "java.lang.NullPointerException: customer is null\n\tat com.example.Billing.charge(Billing.java:88)\n\tat com.example.Billing.run(Billing.java:31)";
    for (0..6) |i| _ = try fake.report(.{ .message = java, .time = at(now_s, @intCast(1800 + i * 4 * 3600)), .service = .{ .service = "billing", .version = "2026.10.1" } });
    _ = try fake.report(.{ .message = "panic: runtime error: index out of range [3] with length 3\n\ngoroutine 1 [running]:\nmain.pick(...)\n\t/srv/pick.go:9", .time = at(now_s, 2 * 24 * 3600), .service = .{ .service = "picker" } });
}

fn usage() error{Usage} {
    std.debug.print("usage: error_dashboard [--fake] [--period=hour|six_hours|day|week|thirty_days] [--service=NAME] [--resolve=GROUP_ID]\n", .{});
    return error.Usage;
}

fn fail(err: anyerror, diag: *const er.Diagnostics, client: ?*er.Client) anyerror {
    std.debug.print("error.{t}", .{err});
    if (diag.http_status != 0) std.debug.print(" (HTTP {d} {s})", .{ diag.http_status, diag.status() });
    if (diag.message().len != 0) std.debug.print(": {s}", .{diag.message()});
    std.debug.print("\n", .{});
    if (client) |c| if (c.lastConsumerRefusal()) |r| if (r.link) |link| {
        std.debug.print("turn the API on in {s}: {s}\n", .{ r.consumer, link });
    };
    return err;
}
