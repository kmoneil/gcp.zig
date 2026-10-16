//! Tails a filter by polling, as a log explorer's live view does, and
//! prints each entry once, as it settles, with the tail's stats.
//!
//!     GOOGLE_CLOUD_PROJECT=my-project zig build example-logs_tail
//!     ... -- 'resource.type = "cloud_run_revision"' --severity=WARNING --every=5
//!     ... -- --polls=12 --overlap=60 --settle=5
//!     zig build example-logs_tail -- --fake       # no project, no network
//!
//! Credentials come from `auth.findDefault`; the principal needs
//! `logging.logEntries.list`. With `--fake`, entries are written into
//! `logging.testing.FakeLogging` as the tail runs, one of them late, to
//! show the overlap catching it.
//!
//! Every poll is one `entries.list` call or a few, of the 60 a minute a
//! project's readers share: every 5 seconds leaves most of them to others.
//! An entry that arrives later than the overlap is never shown.

const std = @import("std");
const auth = @import("auth");
const logging = @import("logging");

pub const std_options: std.Options = .{
    .log_scope_levels = &.{
        .{ .scope = .gcp_auth, .level = .warn },
        .{ .scope = .gcp_logging, .level = .warn },
    },
};

pub fn main(init: std.process.Init) !void {
    const arena = init.arena.allocator();
    var stdout_buffer: [4096]u8 = undefined;
    var stdout = std.Io.File.stdout().writerStreaming(init.io, &stdout_buffer);
    const out = &stdout.interface;
    var diag: logging.Diagnostics = .{};

    var options: logging.TailOptions = .{};
    var every_s: u32 = 5;
    var polls: ?usize = null;
    var use_fake = false;
    const args = try init.minimal.args.toSlice(arena);
    for (args[@min(1, args.len)..]) |arg| {
        if (std.mem.eql(u8, arg, "--fake")) {
            use_fake = true;
        } else if (std.mem.startsWith(u8, arg, "--severity=")) {
            const s = logging.Severity.fromName(arg["--severity=".len..]);
            if (s == .unknown) return usage(out, "unknown severity");
            options.min_severity = s;
        } else if (std.mem.startsWith(u8, arg, "--every=")) {
            every_s = std.fmt.parseInt(u32, arg["--every=".len..], 10) catch return usage(out, "--every takes seconds");
        } else if (std.mem.startsWith(u8, arg, "--polls=")) {
            polls = std.fmt.parseInt(usize, arg["--polls=".len..], 10) catch return usage(out, "--polls takes a number");
        } else if (std.mem.startsWith(u8, arg, "--overlap=")) {
            options.overlap_ms = 1000 * (std.fmt.parseInt(u32, arg["--overlap=".len..], 10) catch return usage(out, "--overlap takes seconds"));
        } else if (std.mem.startsWith(u8, arg, "--settle=")) {
            options.settle_ms = 1000 * (std.fmt.parseInt(u32, arg["--settle=".len..], 10) catch return usage(out, "--settle takes seconds"));
        } else if (std.mem.startsWith(u8, arg, "--log=")) {
            options.log_id = arg["--log=".len..];
        } else if (std.mem.startsWith(u8, arg, "--")) {
            return usage(out, "unknown flag");
        } else {
            options.filter = arg;
        }
    }

    var fake: logging.testing.FakeLogging = .init(init.gpa, init.io);
    defer fake.deinit();
    var static: logging.StaticToken = .{ .token = "fake" };
    var creds: ?auth.Credentials = null;
    defer if (creds) |*c| c.deinit();
    var client_options: logging.Client.Options = .{ .project_id = "fake-project", .token_provider = static.provider(), .diagnostics = &diag };
    if (use_fake) {
        client_options.transport = fake.transport();
        // A quick demonstration: one-second polls, a short settle.
        every_s = 1;
        options.settle_ms = 1000;
        options.overlap_ms = 10_000;
        polls = polls orelse 8;
    } else {
        var lookup = try auth.Lookup.fromEnv(init.environ_map, arena);
        lookup.diagnostics = &diag;
        creds = auth.findDefault(init.gpa, init.io, lookup, .{}) catch |err| return fail(err, &diag);
        const detected = creds.?.projectId(init.io, arena) catch |err| return fail(err, &diag);
        client_options.project_id = init.environ_map.get("GOOGLE_CLOUD_PROJECT") orelse
            detected orelse
            creds.?.quotaProjectId() orelse
            return usage(out, "set GOOGLE_CLOUD_PROJECT to name the project");
        client_options.token_provider = creds.?.provider();
    }

    var client = logging.Client.init(init.gpa, init.io, client_options) catch |err| return fail(err, &diag);
    defer client.deinit();
    var tail = client.tail(options) catch |err| return fail(err, &diag);
    defer tail.deinit();
    try out.print("tailing; every {d} s, settle {d} s, overlap {d} s\n", .{ every_s, options.settle_ms / 1000, options.overlap_ms / 1000 });
    try out.flush();

    var n: usize = 0;
    while (polls == null or n < polls.?) : (n += 1) {
        if (use_fake) try arrive(&fake, init.io, n);
        try init.io.sleep(.fromSeconds(every_s), .awake);
        var batch = tail.poll() catch |err| return fail(err, &diag);
        defer batch.deinit();
        for (batch.value.entries) |entry| try printEntry(out, entry);
        if (batch.value.behind) try out.writeAll("(behind: more was waiting than one poll reads)\n");
        if (batch.value.stopped) |err| try out.print("(poll stopped early: {t}; the next goes on)\n", .{err});
        try out.flush();
    }
    const s = tail.stats();
    try out.print("({d} polls, {d} calls, {d} entries, {d} seen again and dropped, {d} late, the latest {d} ms behind)\n", .{ s.polls, s.calls, s.entries, s.duplicates, s.late, s.latest_late_ms });
    try out.flush();
}

/// What the fake receives as the demonstration runs: an entry a poll, and
/// on the fourth one stamped four seconds back, arriving late.
fn arrive(fake: *logging.testing.FakeLogging, io: std.Io, n: usize) !void {
    const now = std.Io.Clock.real.now(io);
    const name = try fake.logName(.{ .project = "fake-project" }, "app");
    var text_buf: [64]u8 = undefined;
    const late = n == 3;
    const stamp: std.Io.Timestamp = if (late) .{ .nanoseconds = now.nanoseconds - 4 * std.time.ns_per_s } else now;
    try fake.write(.{
        .log_name = name,
        .timestamp = stamp,
        .severity = if (n % 3 == 2) .warning else .info,
        .payload = .{ .text = try std.fmt.bufPrint(&text_buf, "request {d}{s}", .{ n, if (late) " (arrived late)" else "" }) },
    });
}

fn printEntry(out: *std.Io.Writer, entry: logging.Entry) !void {
    const severity = entry.severity.name() orelse "?";
    const seconds: u64 = @intCast(@divFloor(entry.timestamp.nanoseconds, std.time.ns_per_s));
    const clock = (std.time.epoch.EpochSeconds{ .secs = seconds }).getDaySeconds();
    try out.print("{d:0>2}:{d:0>2}:{d:0>2} {s: <9} {s} ", .{ clock.getHoursIntoDay(), clock.getMinutesIntoHour(), clock.getSecondsIntoMinute(), severity, entry.log_id });
    switch (entry.payload) {
        .none => try out.writeAll("(no payload)"),
        .text => |t| try out.writeAll(t[0..@min(t.len, 160)]),
        .json => |j| try out.writeAll(j[0..@min(j.len, 160)]),
        .proto => |p| try out.print("[{s}]", .{p.type_url}),
    }
    try out.writeAll("\n");
}

fn usage(out: *std.Io.Writer, why: []const u8) !void {
    try out.print("{s}\nusage: logs_tail [filter] [--severity=NAME] [--log=ID] [--every=SECONDS] [--polls=N] [--settle=SECONDS] [--overlap=SECONDS] [--fake]\n", .{why});
    try out.flush();
}

fn fail(err: anyerror, diag: *const logging.Diagnostics) anyerror {
    std.debug.print("error.{t}", .{err});
    if (diag.http_status != 0) std.debug.print(" (HTTP {d} {s})", .{ diag.http_status, diag.status() });
    if (diag.message().len != 0) std.debug.print(": {s}", .{diag.message()});
    std.debug.print("\n", .{});
    return err;
}
