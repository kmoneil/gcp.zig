//! Integration tests against real Cloud Scheduler, which has no emulator:
//! milestone 2 of the Scheduler spec (issue #245). They need a project
//! with the API on and a token that may read, create, run, pause and
//! delete jobs there (Editor does):
//!
//!     GCP_TEST_PROJECT=extractctl GCP_TEST_TOKEN=$(cat token.txt) \
//!     SCHEDULER_TEST=1 zig build test-integration-gcp -Dtest-filter=scheduler
//!
//! Without the variables the test skips. The client reads only, so the
//! jobs the suite reads are made raw, beside it: two `zigps-<run>-` jobs
//! in us-central1 (an HTTP target whose host does not resolve, and a
//! Pub/Sub target on a topic nobody has), each `:run` once so its failed
//! attempt is real, one then paused. Every alert of the fake is seeded
//! from what production lists, and the fake is held to production's
//! answer for each read. The suite sweeps `zigps-` jobs of earlier runs
//! first, and deletes its own at the end; a delete while a run settles
//! answers 409 transiently (measured: one took minutes), so deletes
//! retry patiently. About five minutes in all.

const std = @import("std");
const core = @import("core");
const scheduler = @import("scheduler");
const testing = std.testing;
const Allocator = std.mem.Allocator;

const location = "us-central1";

const Fixture = struct {
    env: std.process.Environ.Map,
    token: core.StaticToken,
    diag: scheduler.Diagnostics,
    client: scheduler.Client,
    project: []const u8,
    arena: std.heap.ArenaAllocator,
    run: []const u8,

    fn init(f: *Fixture) !bool {
        const gpa = testing.allocator;
        f.env = try testing.environ.createMap(gpa);
        errdefer f.env.deinit();
        f.project = f.env.get("GCP_TEST_PROJECT") orelse return f.skip();
        const token = f.env.get("GCP_TEST_TOKEN") orelse return f.skip();
        if (f.env.get("SCHEDULER_TEST") == null) return f.skip();
        f.token = .{ .token = std.mem.trim(u8, token, &std.ascii.whitespace) };
        f.diag = .{};
        f.arena = .init(gpa);
        errdefer f.arena.deinit();
        var bytes: [3]u8 = undefined;
        testing.io.random(&bytes);
        f.run = try f.arena.allocator().print("{x}", .{bytes});
        f.client = try .init(gpa, testing.io, .{
            .project_id = f.project,
            .token_provider = f.token.provider(),
            .diagnostics = &f.diag,
            .user_agent = "zig-gcp-scheduler-gcp-integration/0.1",
        });
        return true;
    }

    fn skip(f: *Fixture) bool {
        f.env.deinit();
        return false;
    }

    fn deinit(f: *Fixture) void {
        f.client.deinit();
        f.arena.deinit();
        f.env.deinit();
    }

    /// One raw call beside the client, for what it deliberately has no
    /// verb for: the jobs the suite makes, runs, pauses and deletes.
    fn raw(f: *Fixture, arena: Allocator, method: core.transport.Method, path: []const u8, body: ?[]const u8) !core.transport.Response {
        const url = try std.fmt.allocPrint(arena, "{s}{s}", .{ f.client.base_url, path });
        return f.client.transport.send(.{ .method = method, .url = url, .bearer = f.token.token, .body = body, .timeout_ms = 30_000 }, arena);
    }

    /// Deletes a job, retrying through the transient 409 a settling run
    /// leaves (measured 2026-10-19: one kept answering 409 for minutes).
    fn deleteJob(f: *Fixture, arena: Allocator, name: []const u8) !u16 {
        const path = try std.fmt.allocPrint(arena, "/v1/{s}", .{name});
        for (0..40) |_| {
            const res = try f.raw(arena, .DELETE, path, null);
            if (res.status != 409) return res.status;
            try testing.io.sleep(.fromMilliseconds(5_000), .awake);
        }
        return 409;
    }
};

fn fact(comptime format: []const u8, args: anytype) void {
    std.debug.print("  " ++ format ++ "\n", args);
}

/// Prints the outcome when production and the fake agree, both when not,
/// and counts the second.
fn agree(differences: *usize, label: []const u8, production: []const u8, in_memory: []const u8) void {
    if (std.mem.eql(u8, production, in_memory)) {
        fact("{s}: {s}", .{ label, production });
    } else {
        differences.* += 1;
        std.debug.print("{s}\n  production: {s}\n  fake:       {s}\n", .{ label, production, in_memory });
    }
}

fn sweep(f: *Fixture, a: Allocator) !void {
    var page = f.client.listJobs(location, .{}) catch |err| {
        fact("sweep: listing jobs failed: {t}", .{err});
        return;
    };
    defer page.deinit();
    for (page.value.jobs) |job| {
        if (!std.mem.startsWith(u8, job.id, "zigps-")) continue;
        const status = try f.deleteJob(a, job.name);
        fact("sweep {s}: HTTP {d}", .{ job.id, status });
    }
}

fn writeJobLine(w: *std.Io.Writer, job: scheduler.Job) !void {
    try w.print("{s} {t} attempt=", .{ job.id, job.state });
    if (job.last_attempt) |attempt| {
        try w.print("{d}\"{s}\"", .{ attempt.code, attempt.message });
    } else {
        try w.writeAll("none");
    }
    try w.print(" at={?d} next={?d} failing={} sched=\"{s}\" tz={s} deadline={?d} retry={?d}/{?d}/{?d}/{?d}/{?d} ", .{
        if (job.last_attempt_time) |t| @divFloor(t.nanoseconds, std.time.ns_per_s) else null,
        if (job.schedule_time) |t| @divFloor(t.nanoseconds, std.time.ns_per_s) else null,
        job.failing(),
        job.schedule,
        job.time_zone,
        job.attempt_deadline_s,
        job.retry.retry_count,
        job.retry.max_retry_duration_s,
        job.retry.min_backoff_duration_s,
        job.retry.max_backoff_duration_s,
        job.retry.max_doublings,
    });
    switch (job.target) {
        .http => |t| try w.print("http {t} {s} headers={d} body={d}B", .{ t.method, t.uri, t.headers.len, t.body.len }),
        .pubsub => |t| try w.print("pubsub {s} data={d}B attributes={d}", .{ t.topic_name, t.data.len, t.attributes.len }),
        .app_engine => |t| try w.print("gae {s} service={s}", .{ t.relative_uri, t.service }),
        .unknown => try w.writeAll("unknown"),
    }
}

const Op = union(enum) {
    get: struct { location: []const u8, id: []const u8 },
    get_named: []const u8,
    list: struct { location: []const u8, options: scheduler.ListJobsOptions },
    locations: scheduler.ListLocationsOptions,
};

fn outcome(a: Allocator, client: *scheduler.Client, diag: *scheduler.Diagnostics, op: Op) ![]const u8 {
    var w: std.Io.Writer.Allocating = .init(a);
    switch (op) {
        .get => |g| {
            var got = client.getJob(g.location, g.id) catch |err| {
                try w.writer.print("error.{t}: {s}", .{ err, diag.message() });
                return w.written();
            };
            defer got.deinit();
            try writeJobLine(&w.writer, got.value);
        },
        .get_named => |name| {
            var got = client.getJobNamed(name) catch |err| {
                try w.writer.print("error.{t}: {s}", .{ err, diag.message() });
                return w.written();
            };
            defer got.deinit();
            try writeJobLine(&w.writer, got.value);
        },
        .list => |l| {
            var page = client.listJobs(l.location, l.options) catch |err| {
                try w.writer.print("error.{t}: {s}", .{ err, diag.message() });
                return w.written();
            };
            defer page.deinit();
            try w.writer.print("n={d} next={}", .{ page.value.jobs.len, page.value.next_page_token != null });
            for (page.value.jobs) |job| {
                try w.writer.writeAll(" | ");
                try writeJobLine(&w.writer, job);
            }
        },
        .locations => |options| {
            var page = client.listLocations(options) catch |err| {
                try w.writer.print("error.{t}: {s}", .{ err, diag.message() });
                return w.written();
            };
            defer page.deinit();
            try w.writer.print("n={d} next={}", .{ page.value.locations.len, page.value.next_page_token != null });
            for (page.value.locations) |loc| try w.writer.print(" {s}", .{loc.id});
        },
    }
    return w.written();
}

/// Everything production lists in the location, put into the fake as it
/// answered.
fn seed(fake: *scheduler.testing.FakeScheduler, page: *const scheduler.JobPage) !void {
    for (page.jobs) |job| {
        const retry_set = job.retry.retry_count != null or job.retry.max_retry_duration_s != null or
            job.retry.min_backoff_duration_s != null or job.retry.max_backoff_duration_s != null or
            job.retry.max_doublings != null;
        _ = try fake.putJob(.{
            .location = job.location,
            .id = job.id,
            .description = job.description,
            .schedule = job.schedule,
            .time_zone = job.time_zone,
            .state = job.state,
            .last_attempt = job.last_attempt,
            .last_attempt_time = job.last_attempt_time,
            .schedule_time = job.schedule_time,
            .user_update_time = job.user_update_time,
            .attempt_deadline_s = job.attempt_deadline_s,
            .retry = if (retry_set) job.retry else null,
            .target = job.target,
        });
    }
}

test "scheduler: real failing jobs, and the fake seeded with production's list answers as production did" {
    var f: Fixture = undefined;
    if (!try f.init()) return error.SkipZigTest;
    defer f.deinit();
    const a = f.arena.allocator();
    try sweep(&f, a);

    // The two jobs: a host that does not resolve, and a topic nobody has.
    // The cron (1 Jan, 00:00) never fires during the suite; the `:run`s
    // make the failed attempts, in seconds (measured: 6 and 16).
    const http_id = try a.print("zigps-{s}-http", .{f.run});
    const ps_id = try a.print("zigps-{s}-ps", .{f.run});
    const jobs_path = try a.print("/v1/projects/{s}/locations/{s}/jobs", .{ f.project, location });
    var made: std.ArrayList([]const u8) = .empty;
    defer {
        var cleanup: std.heap.ArenaAllocator = .init(testing.allocator);
        for (made.items) |name| {
            const status = f.deleteJob(cleanup.allocator(), name) catch 0;
            fact("cleanup {s}: HTTP {d}", .{ name, status });
        }
        cleanup.deinit();
        made.deinit(a);
    }
    {
        const body = try a.print(
            \\{{"name":"projects/{s}/locations/{s}/jobs/{s}","schedule":"0 0 1 1 *","timeZone":"UTC","httpTarget":{{"uri":"https://{s}-nowhere.invalid/hook","httpMethod":"POST","headers":{{"X-Zigps":"suite"}}}},"retryConfig":{{"retryCount":1}}}}
        , .{ f.project, location, http_id, http_id });
        const res = try f.raw(a, .POST, jobs_path, body);
        try testing.expectEqual(200, res.status);
        try made.append(a, try a.print("projects/{s}/locations/{s}/jobs/{s}", .{ f.project, location, http_id }));
    }
    {
        const body = try a.print(
            \\{{"name":"projects/{s}/locations/{s}/jobs/{s}","schedule":"0 0 1 1 *","timeZone":"UTC","pubsubTarget":{{"topicName":"projects/{s}/topics/zigps-{s}-missing","data":"emlncHM="}}}}
        , .{ f.project, location, ps_id, f.project, f.run });
        const res = try f.raw(a, .POST, jobs_path, body);
        try testing.expectEqual(200, res.status);
        try made.append(a, try a.print("projects/{s}/locations/{s}/jobs/{s}", .{ f.project, location, ps_id }));
    }
    fact("made {s} and {s}", .{ http_id, ps_id });

    // Run each once and wait for its attempt to land.
    for (made.items) |name| {
        const run_path = try a.print("/v1/{s}:run", .{name});
        const ran = try f.raw(a, .POST, run_path, "{}");
        try testing.expectEqual(200, ran.status);
        const ran_at = std.Io.Clock.real.now(testing.io).nanoseconds;
        var landed = false;
        for (0..60) |_| {
            var got = try f.client.getJobNamed(name);
            defer got.deinit();
            if (got.value.last_attempt_time != null) {
                try testing.expect(got.value.failing());
                landed = true;
                break;
            }
            try testing.io.sleep(.fromMilliseconds(5_000), .awake);
        }
        if (!landed) return error.AttemptNeverLanded;
        fact("{s}: attempt landed {d} s after run", .{ name, @divFloor(std.Io.Clock.real.now(testing.io).nanoseconds - ran_at, std.time.ns_per_s) });
    }

    // Pause the Pub/Sub job: production removes its next run.
    {
        const pause_path = try a.print("/v1/{s}:pause", .{made.items[1]});
        const paused = try f.raw(a, .POST, pause_path, "{}");
        try testing.expectEqual(200, paused.status);
    }

    // The fake, seeded with everything production lists.
    var fake: scheduler.testing.FakeScheduler = .init(testing.allocator, testing.io, .{ .project_id = f.project });
    defer fake.deinit();
    try fake.putLocation(location);
    try fake.putLocation("us-east1");
    var fake_diag: scheduler.Diagnostics = .{};
    var fake_token: core.StaticToken = .{ .token = "t" };
    var fake_client = try scheduler.Client.init(testing.allocator, testing.io, .{ .project_id = f.project, .token_provider = fake_token.provider(), .transport = fake.transport(), .diagnostics = &fake_diag });
    defer fake_client.deinit();
    var all = try f.client.listJobs(location, .{});
    defer all.deinit();
    try seed(&fake, &all.value);
    fact("{d} jobs seeded", .{all.value.jobs.len});

    // Every read, production and the fake compared as text.
    var differences: usize = 0;
    const ops = [_]struct { []const u8, Op }{
        .{ "get http", .{ .get = .{ .location = location, .id = http_id } } },
        .{ "get ps by name", .{ .get_named = made.items[1] } },
        .{ "get unknown", .{ .get = .{ .location = location, .id = "zigps-nobody" } } },
        .{ "list", .{ .list = .{ .location = location, .options = .{} } } },
        .{ "list empty location", .{ .list = .{ .location = "us-east1", .options = .{} } } },
        .{ "list unknown location", .{ .list = .{ .location = "us-fake1", .options = .{} } } },
    };
    for (ops) |op| {
        const in_production = try outcome(a, &f.client, &f.diag, op[1]);
        const in_memory = try outcome(a, &fake_client, &fake_diag, op[1]);
        agree(&differences, op[0], in_production, in_memory);
    }

    // The paging walk: page contents compared, tokens each side's own.
    {
        var prod_page = try f.client.listJobs(location, .{ .page_size = 1 });
        defer prod_page.deinit();
        var fake_page = try fake_client.listJobs(location, .{ .page_size = 1 });
        defer fake_page.deinit();
        var walked: usize = 1;
        while (true) : (walked += 1) {
            var pw: std.Io.Writer.Allocating = .init(a);
            try pw.writer.print("n={d} next={}", .{ prod_page.value.jobs.len, prod_page.value.next_page_token != null });
            for (prod_page.value.jobs) |job| {
                try pw.writer.writeAll(" | ");
                try writeJobLine(&pw.writer, job);
            }
            var fw: std.Io.Writer.Allocating = .init(a);
            try fw.writer.print("n={d} next={}", .{ fake_page.value.jobs.len, fake_page.value.next_page_token != null });
            for (fake_page.value.jobs) |job| {
                try fw.writer.writeAll(" | ");
                try writeJobLine(&fw.writer, job);
            }
            agree(&differences, try a.print("page {d}", .{walked}), pw.written(), fw.written());
            const prod_next = prod_page.value.next_page_token orelse break;
            const fake_next = fake_page.value.next_page_token orelse break;
            const prod_token = try a.dupe(u8, prod_next);
            const fake_token_text = try a.dupe(u8, fake_next);
            prod_page.deinit();
            fake_page.deinit();
            prod_page = try f.client.listJobs(location, .{ .page_size = 1, .page_token = prod_token });
            fake_page = try fake_client.listJobs(location, .{ .page_size = 1, .page_token = fake_token_text });
            if (walked > 10) return error.TestUnexpectedResult;
        }
    }

    // Locations: production's first hundred hold ours; the fake holds the
    // two the suite put, so only presence is compared, not the set.
    {
        var page = try f.client.listLocations(.{ .page_size = 100 });
        defer page.deinit();
        var ours = false;
        for (page.value.locations) |loc| {
            if (std.mem.eql(u8, loc.id, location)) ours = true;
        }
        try testing.expect(ours);
        fact("locations: production lists {d}, ours among them", .{page.value.locations.len});
    }

    try testing.expectEqual(0, differences);
}
