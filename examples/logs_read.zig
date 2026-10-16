//! Lists log entries, newest first, a page at a time, as a log explorer's
//! table fetches them, and prints one line an entry.
//!
//!     GOOGLE_CLOUD_PROJECT=my-project zig build example-logs_read
//!     ... -- 'resource.type = "cloud_run_revision"' --severity=WARNING
//!     ... -- --since=15m --pages=3 --page-size=50 --log=run.googleapis.com/stderr
//!     zig build example-logs_read -- --fake        # no project, no network
//!
//! Credentials come from `auth.findDefault`: the file
//! `GOOGLE_APPLICATION_CREDENTIALS` names, then the one `gcloud auth
//! application-default login` writes, then the metadata server. The
//! principal needs `logging.logEntries.list` (Logs Viewer). `--fake` reads
//! from `logging.testing.FakeLogging` instead, with a few entries in it.
//!
//! A page can come back empty with a token: the server stopped searching
//! after its 10 seconds, not because nothing matched. The example goes on
//! to the next page then, as a table would, and says so.

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

    var options: logging.QueryOptions = .{};
    var pages: usize = 1;
    var use_fake = false;
    var since_s: ?i64 = null;
    const args = try init.minimal.args.toSlice(arena);
    for (args[@min(1, args.len)..]) |arg| {
        if (std.mem.eql(u8, arg, "--fake")) {
            use_fake = true;
        } else if (std.mem.eql(u8, arg, "--oldest-first")) {
            options.order = .oldest_first;
        } else if (std.mem.startsWith(u8, arg, "--severity=")) {
            const s = logging.Severity.fromName(arg["--severity=".len..]);
            if (s == .unknown) return usage(out, "unknown severity");
            options.min_severity = s;
        } else if (std.mem.startsWith(u8, arg, "--since=")) {
            since_s = parseAgo(arg["--since=".len..]) orelse return usage(out, "--since takes 30s, 15m, 2h or 1d");
        } else if (std.mem.startsWith(u8, arg, "--pages=")) {
            pages = std.fmt.parseInt(usize, arg["--pages=".len..], 10) catch return usage(out, "--pages takes a number");
        } else if (std.mem.startsWith(u8, arg, "--page-size=")) {
            options.page_size = std.fmt.parseInt(u32, arg["--page-size=".len..], 10) catch return usage(out, "--page-size takes a number");
        } else if (std.mem.startsWith(u8, arg, "--log=")) {
            options.log_id = arg["--log=".len..];
        } else if (std.mem.startsWith(u8, arg, "--")) {
            return usage(out, "unknown flag");
        } else {
            options.filter = arg;
        }
    }
    // The bounds are computed once, so every page sends the same request.
    const now = std.Io.Clock.real.now(init.io);
    if (since_s) |s| options.since = .{ .nanoseconds = now.nanoseconds - @as(i96, s) * std.time.ns_per_s };

    var fake: logging.testing.FakeLogging = .init(init.gpa, init.io);
    defer fake.deinit();
    var static: logging.StaticToken = .{ .token = "fake" };
    var creds: ?auth.Credentials = null;
    defer if (creds) |*c| c.deinit();

    var client_options: logging.Client.Options = .{ .project_id = "fake-project", .token_provider = static.provider(), .diagnostics = &diag };
    if (use_fake) {
        try fill(&fake, now);
        client_options.transport = fake.transport();
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
    var query = client.query(options) catch |err| return fail(err, &diag);
    defer query.deinit();

    var token: ?[]const u8 = null;
    var page_number: usize = 1;
    while (page_number <= pages) : (page_number += 1) {
        var page = query.page(token) catch |err| return fail(err, &diag);
        defer page.deinit();
        if (page.value.entries.len == 0 and page.value.next_page_token != null) {
            try out.print("(page {d}: nothing found yet; the server ran out of time and the search goes on)\n", .{page_number});
        }
        for (page.value.entries) |entry| try printEntry(out, entry);
        token = if (page.value.next_page_token) |t| try arena.dupe(u8, t) else {
            try out.print("(end of the listing)\n", .{});
            break;
        };
    }
    const budget = client.readBudget();
    try out.print("({d} of {d} entries.list calls this minute)\n", .{ budget.used, budget.limit });
    try out.flush();
}

fn printEntry(out: *std.Io.Writer, entry: logging.Entry) !void {
    var buf: [40]u8 = undefined;
    const severity = entry.severity.name() orelse std.fmt.bufPrint(&buf, "{d}", .{@backingInt(entry.severity)}) catch "?";
    var time_buf: [30]u8 = undefined;
    const time = formatTime(&time_buf, entry.timestamp);
    try out.print("{s} {s: <9} {s} ", .{ time, severity, entry.log_id });
    switch (entry.payload) {
        .none => try out.writeAll("(no payload)"),
        .text => |t| try writeLine(out, t),
        .json => |j| try writeLine(out, j),
        .proto => |p| try out.print("[{s}]", .{p.type_url}),
    }
    try out.writeAll("\n");
}

/// The text on one line, shortened.
fn writeLine(out: *std.Io.Writer, text: []const u8) !void {
    const shown = text[0..@min(text.len, 160)];
    for (shown) |c| try out.writeByte(if (c == '\n' or c == '\r' or c == '\t') ' ' else c);
    if (text.len > shown.len) try out.writeAll("...");
}

fn formatTime(buf: *[30]u8, ts: std.Io.Timestamp) []const u8 {
    const seconds: u64 = @intCast(@divFloor(ts.nanoseconds, std.time.ns_per_s));
    const millis: u64 = @intCast(@divFloor(@mod(ts.nanoseconds, std.time.ns_per_s), std.time.ns_per_ms));
    const epoch: std.time.epoch.EpochSeconds = .{ .secs = seconds };
    const day = epoch.getEpochDay().calculateYearDay();
    const md = day.calculateMonthDay();
    const clock = epoch.getDaySeconds();
    return std.fmt.bufPrint(buf, "{d:0>4}-{d:0>2}-{d:0>2} {d:0>2}:{d:0>2}:{d:0>2}.{d:0>3}", .{
        day.year, md.month.numeric(), md.day_index + 1, clock.getHoursIntoDay(), clock.getMinutesIntoHour(), clock.getSecondsIntoMinute(), millis,
    }) catch "?";
}

/// "30s", "15m", "2h" or "1d", in seconds.
fn parseAgo(text: []const u8) ?i64 {
    if (text.len < 2) return null;
    const n = std.fmt.parseInt(i64, text[0 .. text.len - 1], 10) catch return null;
    const unit: i64 = switch (text[text.len - 1]) {
        's' => 1,
        'm' => 60,
        'h' => 3600,
        'd' => 86400,
        else => return null,
    };
    return std.math.mul(i64, n, unit) catch null;
}

/// A few entries of the kinds a project holds.
fn fill(fake: *logging.testing.FakeLogging, now: std.Io.Timestamp) !void {
    const project: logging.Parent = .{ .project = "fake-project" };
    const minute: i96 = 60 * std.time.ns_per_s;
    const stderr = try fake.logName(project, "run.googleapis.com/stderr");
    try fake.write(.{ .log_name = stderr, .timestamp = .{ .nanoseconds = now.nanoseconds - 3 * minute }, .severity = .info, .resource_type = "cloud_run_revision", .payload = .{ .text = "listening on :8080" } });
    try fake.write(.{ .log_name = stderr, .timestamp = .{ .nanoseconds = now.nanoseconds - 2 * minute }, .severity = .warning, .resource_type = "cloud_run_revision", .payload = .{ .json = "{\"message\":\"slow request\",\"latency_ms\":1840}" } });
    try fake.write(.{ .log_name = stderr, .timestamp = .{ .nanoseconds = now.nanoseconds - minute }, .severity = .@"error", .resource_type = "cloud_run_revision", .payload = .{ .json = "{\"message\":\"payment failed\",\"order\":4217}" } });
    try fake.write(.{ .log_name = try fake.logName(project, "app"), .timestamp = .{ .nanoseconds = now.nanoseconds - 30 * std.time.ns_per_s }, .payload = .{ .text = "started" } });
}

fn usage(out: *std.Io.Writer, why: []const u8) !void {
    try out.print("{s}\nusage: logs_read [filter] [--severity=NAME] [--since=15m] [--log=ID] [--pages=N] [--page-size=N] [--oldest-first] [--fake]\n", .{why});
    try out.flush();
}

fn fail(err: anyerror, diag: *const logging.Diagnostics) anyerror {
    std.debug.print("error.{t}", .{err});
    if (diag.http_status != 0) std.debug.print(" (HTTP {d} {s})", .{ diag.http_status, diag.status() });
    if (diag.message().len != 0) std.debug.print(": {s}", .{diag.message()});
    std.debug.print("\n", .{});
    return err;
}
