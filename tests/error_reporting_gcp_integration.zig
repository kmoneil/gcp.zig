//! Integration tests against real Cloud Error Reporting, which has no
//! emulator: milestone 2 of the Error Reporting spec. They need a project
//! with the API on, and a token that may report errors and read and update
//! groups there (Editor does):
//!
//!     GCP_TEST_PROJECT=extractctl GCP_TEST_TOKEN=$(cat token.txt) \
//!     zig build test-integration-gcp -Dtest-filter=error_reporting
//!
//! Without both variables every test skips. Each run reports a few errors
//! of its own through `events.report`, which the module never calls, under
//! the service `zigps-er-<run>`: Error Reporting keeps them 30 days and
//! there is no way to delete one group's (`deleteEvents` deletes every
//! error in the project). Statuses are changed only on those groups. Calls
//! are free. The last test runs the same queries against production and
//! against `FakeErrorReporting` fed the same reports, and holds the fake to
//! what production said.

const std = @import("std");
const core = @import("core");
const er = @import("error_reporting");
const testing = std.testing;

const Kind = enum { python, java, node, go };

/// One seeded error: its kind, how many seconds before the seed it
/// happened, its user and its service version.
const Seed = struct { kind: Kind, back_s: i64, user: ?[]const u8, version: []const u8 };

/// Python 4 errors (three users, two by an address), Java 2, Node 2 (to be
/// muted), Go 1 two days back (to be resolved, then reopened).
const seeds = [_]Seed{
    .{ .kind = .python, .back_s = 300, .user = "u1", .version = "v1" },
    .{ .kind = .python, .back_s = 2 * 3600 + 120, .user = "u2", .version = "v1" },
    .{ .kind = .python, .back_s = 3 * 3600 + 30, .user = "u1", .version = "v1" },
    .{ .kind = .python, .back_s = 5 * 3600, .user = null, .version = "v1" },
    .{ .kind = .java, .back_s = 900, .user = null, .version = "v2" },
    .{ .kind = .java, .back_s = 4 * 3600 + 600, .user = "u3", .version = "v2" },
    .{ .kind = .node, .back_s = 1800, .user = null, .version = "v1" },
    .{ .kind = .node, .back_s = 1900, .user = null, .version = "v1" },
    .{ .kind = .go, .back_s = 2 * 24 * 3600, .user = "u2", .version = "v1" },
};

/// A stack trace of `kind` that no other run shares. Production groups
/// errors by exception type and frames, its file paths aside: measured on
/// 2026-10-18, the Node errors of two runs whose paths differed fell into
/// one group, so the run id is in the function names too.
fn trace(a: std.mem.Allocator, kind: Kind, run: []const u8) ![]const u8 {
    return switch (kind) {
        .python => a.print("Traceback (most recent call last):\n  File \"/srv/zigps_{s}/orders.py\", line 41, in handle_{s}\n    total = price_{s}(order)\n  File \"/srv/zigps_{s}/orders.py\", line 12, in price_{s}\n    raise ValueError(\"order has no lines\")\nValueError: order has no lines", .{ run, run, run, run, run }),
        .java => a.print("java.lang.NullPointerException: customer is null\n\tat com.example.zigps{s}.Billing.charge(Billing.java:88)\n\tat com.example.zigps{s}.Billing.run(Billing.java:31)\n\tat java.base/java.lang.Thread.run(Thread.java:1583)", .{ run, run }),
        .node => a.print("TypeError: Cannot read properties of undefined (reading 'id')\n    at render_{s} (/srv/zigps_{s}/view.js:17:23)\n    at main_{s} (/srv/zigps_{s}/index.js:5:3)", .{ run, run, run, run }),
        .go => a.print("panic: runtime error: index out of range [3] with length 3\n\ngoroutine 1 [running]:\nmain.pick_{s}(...)\n\t/srv/zigps_{s}/pick.go:9\nmain.main()\n\t/srv/zigps_{s}/main.go:14 +0x1d", .{ run, run, run }),
    };
}

/// The kind a stack trace's headline names.
fn kindOf(headline: []const u8) ?Kind {
    if (std.mem.startsWith(u8, headline, "ValueError")) return .python;
    if (std.mem.startsWith(u8, headline, "java.lang.NullPointerException")) return .java;
    if (std.mem.startsWith(u8, headline, "TypeError")) return .node;
    if (std.mem.startsWith(u8, headline, "panic:")) return .go;
    return null;
}

const Fixture = struct {
    env: std.process.Environ.Map,
    token: core.StaticToken,
    diag: er.Diagnostics,
    client: er.Client,
    project: []const u8,
    http: core.transport.HttpTransport,
    arena: std.heap.ArenaAllocator,
    run: []const u8,
    service: []const u8,
    /// When the seed was sent, whole seconds.
    seeded_s: i64 = 0,
    /// The production group id of each kind.
    ids: [4][]const u8 = .{ "", "", "", "" },

    fn init(f: *Fixture) !bool {
        const gpa = testing.allocator;
        f.env = try testing.environ.createMap(gpa);
        errdefer f.env.deinit();
        f.project = f.env.get("GCP_TEST_PROJECT") orelse return f.skip();
        const token = f.env.get("GCP_TEST_TOKEN") orelse return f.skip();
        f.token = .{ .token = std.mem.trim(u8, token, &std.ascii.whitespace) };
        f.diag = .{};
        f.arena = .init(gpa);
        errdefer f.arena.deinit();
        var bytes: [3]u8 = undefined;
        testing.io.random(&bytes);
        f.run = try f.arena.allocator().print("{x}", .{bytes});
        f.service = try f.arena.allocator().print("zigps-er-{s}", .{f.run});
        f.http = .init(gpa, testing.io, "zig-gcp-error_reporting-gcp-integration/0.1");
        errdefer f.http.deinit();
        f.client = try .init(gpa, testing.io, .{
            .project_id = f.project,
            .token_provider = f.token.provider(),
            .diagnostics = &f.diag,
            .user_agent = "zig-gcp-error_reporting-gcp-integration/0.1",
        });
        return true;
    }

    fn skip(f: *Fixture) bool {
        f.env.deinit();
        return false;
    }

    fn deinit(f: *Fixture) void {
        f.client.deinit();
        f.http.deinit();
        f.arena.deinit();
        f.env.deinit();
    }

    /// Reports one error to production, as the module never does.
    fn report(f: *Fixture, kind: Kind, back_s: i64, user: ?[]const u8, version: []const u8) !void {
        var scratch: std.heap.ArenaAllocator = .init(testing.allocator);
        defer scratch.deinit();
        const a = scratch.allocator();
        var tbuf: [core.timestamp.max_len]u8 = undefined;
        const when = core.timestamp.format(&tbuf, .{ .nanoseconds = @as(i96, f.seeded_s - back_s) * std.time.ns_per_s });
        var out: std.Io.Writer.Allocating = .init(a);
        var jw: std.json.Stringify = .{ .writer = &out.writer };
        try jw.write(.{
            .eventTime = when,
            .serviceContext = .{ .service = f.service, .version = version },
            .message = try trace(a, kind, f.run),
            .context = .{ .user = user orelse "", .httpRequest = .{ .method = "GET", .url = "/zigps", .responseStatusCode = 500, .remoteIp = if (user == null) "192.0.2.7" else "" } },
        });
        const url = try a.print("https://clouderrorreporting.googleapis.com/v1beta1/projects/{s}/events:report", .{f.project});
        const res = try f.http.transport().send(.{ .method = .POST, .url = url, .bearer = f.token.token, .body = out.written(), .content_type = .json, .timeout_ms = 60_000 }, a);
        if (res.status != 200) {
            std.debug.print("report answered {d}: {s}\n", .{ res.status, res.body });
            return error.ReportRefused;
        }
    }

    /// Reports every seed, then waits until production lists the four
    /// groups, and keeps their ids. Each kind's first seed goes alone and
    /// first: production's first seen is the time of a group's first error
    /// it processed, and reports sent together were not processed in the
    /// order sent.
    fn seed(f: *Fixture) !void {
        f.seeded_s = @intCast(@divFloor(std.Io.Clock.real.now(testing.io).nanoseconds, std.time.ns_per_s));
        var first: [4]bool = @splat(false);
        for (seeds) |s| if (!first[@backingInt(s.kind)]) {
            first[@backingInt(s.kind)] = true;
            try f.report(s.kind, s.back_s, s.user, s.version);
        };
        try f.awaitGroups();
        @memset(&first, false);
        for (seeds) |s| {
            if (!first[@backingInt(s.kind)]) {
                first[@backingInt(s.kind)] = true;
                continue;
            }
            try f.report(s.kind, s.back_s, s.user, s.version);
        }
        try f.awaitGroups();
        // The second wave listed with the first: wait for its counts.
        var waited_s: u32 = 0;
        while (waited_s < 240) : (waited_s += 5) {
            var page = try f.stats(.{ .period = .thirty_days });
            defer page.deinit();
            var total: u64 = 0;
            for (page.value.items) |s| total += s.count;
            if (total == seeds.len) return;
            try testing.io.sleep(.fromSeconds(5), .awake);
        }
        return error.SeededErrorsNotCounted;
    }

    fn awaitGroups(f: *Fixture) !void {
        var waited_s: u32 = 0;
        while (waited_s < 240) : (waited_s += 5) {
            var page = try f.stats(.{ .period = .thirty_days });
            defer page.deinit();
            var found: usize = 0;
            for (page.value.items) |s| {
                const kind = kindOf(if (s.representative) |r| r.headline() else "") orelse continue;
                f.ids[@backingInt(kind)] = try f.arena.allocator().dupe(u8, s.group.id);
                found += 1;
            }
            if (found == 4) {
                fact("the seeded groups were listed {d} s after the reports", .{waited_s});
                return;
            }
            try testing.io.sleep(.fromSeconds(5), .awake);
        }
        return error.SeededGroupsNotListed;
    }

    /// The first page of group stats of this run's service.
    fn stats(f: *Fixture, options: er.GroupStatsOptions) !er.Owned(er.GroupStatsPage) {
        var o = options;
        o.service.service = f.service;
        var q = try f.client.groupStats(o);
        defer q.deinit();
        return q.page(null);
    }

    fn id(f: *const Fixture, kind: Kind) []const u8 {
        return f.ids[@backingInt(kind)];
    }
};

fn fact(comptime format: []const u8, args: anytype) void {
    std.debug.print("  fact: " ++ format ++ "\n", args);
}

/// One query's answer, as text both sides can be compared by: each group
/// by its kind, its counts, its first and last seen as seconds before the
/// seed, and its buckets.
fn summary(a: std.mem.Allocator, page: er.GroupStatsPage, seeded_s: i64) ![]const u8 {
    var out: std.Io.Writer.Allocating = .init(a);
    const w = &out.writer;
    for (page.items) |s| {
        const kind = kindOf(if (s.representative) |r| r.headline() else "");
        try w.print("{s}:{t} count={d} users={d} services={d}", .{ if (kind) |k| @tagName(k) else "?", s.group.status, s.count, s.affected_users, s.affected_service_count });
        if (s.first_seen) |t| try w.print(" first=-{d}", .{seeded_s - @as(i64, @intCast(@divFloor(t.nanoseconds, std.time.ns_per_s)))});
        if (s.last_seen) |t| try w.print(" last=-{d}", .{seeded_s - @as(i64, @intCast(@divFloor(t.nanoseconds, std.time.ns_per_s)))});
        if (s.timed_counts.len > 0) {
            try w.writeAll(" buckets=");
            for (s.timed_counts) |t| try w.print("{d},", .{t.count});
        }
        try w.writeAll("; ");
    }
    return out.written();
}

test "error_reporting: seeded errors read back as reported, and the fake answers each query as production does" {
    var f: Fixture = undefined;
    if (!try f.init()) return error.SkipZigTest;
    defer f.deinit();
    try f.seed();
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    // The fake, fed the same reports, on a clock set to each production
    // answer's own now.
    var clock: core.testing.FakeClock = .{};
    var fake: er.testing.FakeErrorReporting = .init(testing.allocator, clock.io(), .{ .project_id = f.project });
    defer fake.deinit();
    for (seeds) |s| _ = try fake.report(.{
        .message = try trace(a, s.kind, f.run),
        .time = .{ .nanoseconds = @as(i96, f.seeded_s - s.back_s) * std.time.ns_per_s },
        .service = .{ .service = f.service, .version = s.version, .resource_type = "reported_errors" },
        .user = s.user,
        .http_request = .{ .method = "GET", .url = "/zigps", .response_status_code = 500, .remote_ip = if (s.user == null) "192.0.2.7" else null },
    });
    var fake_token: core.StaticToken = .{ .token = "t" };
    var fake_client = try er.Client.init(testing.allocator, clock.io(), .{ .project_id = f.project, .token_provider = fake_token.provider(), .transport = fake.transport(), .calls_per_minute = 0 });
    defer fake_client.deinit();

    const midnight: std.Io.Timestamp = .{ .nanoseconds = 0 };
    const queries = [_]struct { []const u8, er.GroupStatsOptions }{
        .{ "a day by count", .{ .period = .day } },
        .{ "30 days by count", .{ .period = .thirty_days } },
        .{ "a day by last seen", .{ .period = .day, .order = .last_seen } },
        .{ "a day by creation", .{ .period = .day, .order = .created } },
        .{ "a day by users", .{ .period = .day, .order = .affected_users } },
        .{ "6 hours in hours at the end", .{ .period = .six_hours, .timed_count_seconds = 3600 } },
        .{ "6 hours in hours on the hour", .{ .period = .six_hours, .timed_count_seconds = 3600, .alignment = .{ .rounded = midnight } } },
        .{ "a day in 864 s, the most buckets", .{ .period = .day, .timed_count_seconds = 864 } },
        .{ "an hour", .{ .period = .hour } },
        .{ "a week, version v2", .{ .period = .week, .service = .{ .version = "v2" } } },
    };
    var differences: usize = 0;
    for (queries) |q| {
        var theirs = try f.stats(q[1]);
        defer theirs.deinit();
        // The fake's now is production's: the period's end.
        const period = q[1].period orelse er.Period.default;
        clock.now_ns = theirs.value.time_range_begin.?.nanoseconds + @as(i96, period.seconds()) * std.time.ns_per_s;
        var o = q[1];
        o.service.service = f.service;
        var fq = try fake_client.groupStats(o);
        defer fq.deinit();
        var ours = try fq.page(null);
        defer ours.deinit();
        const production = try summary(a, theirs.value, f.seeded_s);
        const in_memory = try summary(a, ours.value, f.seeded_s);
        if (std.mem.eql(u8, production, in_memory)) {
            fact("{s}: {s}", .{ q[0], production });
        } else {
            differences += 1;
            std.debug.print("{s}:\n  production: {s}\n  fake:       {s}\n", .{ q[0], production, in_memory });
        }
    }
    try testing.expectEqual(0, differences);

    // Events, newest first, on both sides.
    var theirs = try f.client.events(f.id(.python), .{ .period = .day });
    defer theirs.deinit();
    var page = try theirs.page(null);
    defer page.deinit();
    try testing.expectEqual(4, page.value.items.len);
    for (page.value.items, [_]i64{ 300, 2 * 3600 + 120, 3 * 3600 + 30, 5 * 3600 }) |e, back| {
        try testing.expectEqual(@as(i96, f.seeded_s - back) * std.time.ns_per_s, @divFloor(e.time.?.nanoseconds, std.time.ns_per_s) * std.time.ns_per_s);
    }
    try testing.expectEqualStrings(f.service, page.value.items[0].service.service.?);
    try testing.expectEqualStrings("ValueError: order has no lines", page.value.items[0].headline());
}

test "error_reporting: statuses on the seeded groups, and what production refuses" {
    var f: Fixture = undefined;
    if (!try f.init()) return error.SkipZigTest;
    defer f.deinit();
    try f.seed();

    // Muted: gone from group stats, even by id; get still reads it. Opened
    // again whatever happens, though the group is this run's alone.
    var muted = try f.client.group(f.id(.node)).setStatus(.muted);
    muted.deinit();
    defer if (f.client.group(f.id(.node)).setStatus(.open)) |g| {
        var reopened = g;
        reopened.deinit();
    } else |_| {};
    {
        var page = try f.stats(.{ .period = .day, .group_ids = &.{ f.id(.node), f.id(.python) } });
        defer page.deinit();
        try testing.expectEqual(1, page.value.items.len);
        try testing.expectEqualStrings(f.id(.python), page.value.items[0].group.id);
    }
    var read = try f.client.group(f.id(.node)).get();
    defer read.deinit();
    try testing.expectEqual(.muted, read.value.status);

    // Resolved, then a new error: open again.
    var resolved = try f.client.group(f.id(.go)).setStatus(.resolved);
    resolved.deinit();
    try f.report(.go, 0, "u2", "v1");
    var reopened = false;
    for (0..24) |_| {
        var g = try f.client.group(f.id(.go)).get();
        defer g.deinit();
        if (g.value.status == .open) {
            reopened = true;
            break;
        }
        try testing.io.sleep(.fromSeconds(5), .awake);
    }
    try testing.expect(reopened);

    // setStatus keeps a tracking issue, which a bare PUT would clear.
    var scratch: std.heap.ArenaAllocator = .init(testing.allocator);
    defer scratch.deinit();
    const a = scratch.allocator();
    const url = try a.print("https://clouderrorreporting.googleapis.com/v1beta1/projects/{s}/groups/{s}", .{ f.project, f.id(.java) });
    const put = try f.http.transport().send(.{ .method = .PUT, .url = url, .bearer = f.token.token, .body = "{\"trackingIssues\":[{\"url\":\"https://example.com/issues/zigps\"}],\"resolutionStatus\":\"ACKNOWLEDGED\"}", .content_type = .json, .timeout_ms = 60_000 }, a);
    try testing.expectEqual(200, put.status);
    var kept = try f.client.group(f.id(.java)).setStatus(.open);
    defer kept.deinit();
    try testing.expectEqual(.open, kept.value.status);
    try testing.expectEqualStrings("https://example.com/issues/zigps", kept.value.tracking_issues[0].url);

    // Refusals.
    try testing.expectError(error.NotFound, f.client.group("CAAAAAAAAAAAAA").get());
    try testing.expectEqualStrings("Invalid group id: CAAAAAAAAAAAAA", f.diag.message());
    try testing.expectError(error.InvalidOptions, f.client.groupStats(.{ .period = .day, .timed_count_seconds = 863 }));
    var q = try f.client.groupStats(.{ .period = .day });
    defer q.deinit();
    try testing.expectError(error.InvalidPageToken, q.page("zigps-not-a-token"));

    // Every region and global name the same groups, without a location.
    for ([_][]const u8{ "global", "-" }) |location| {
        var c = try er.Client.init(testing.allocator, testing.io, .{ .project_id = f.project, .location = location, .token_provider = f.token.provider() });
        defer c.deinit();
        var lq = try c.groupStats(.{ .period = .day, .service = .{ .service = f.service } });
        defer lq.deinit();
        var page = try lq.page(null);
        defer page.deinit();
        try testing.expectEqual(3, page.value.items.len);
        try testing.expect(std.mem.indexOf(u8, page.value.items[0].group.name, "/locations/") == null);
    }
}
