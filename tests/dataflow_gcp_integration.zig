//! Integration tests against real Dataflow, which has no emulator:
//! milestone 2 of the Dataflow spec. They need a project with the API on
//! and a token that may read and launch jobs there (Editor does, with
//! actAs on the compute default account), and the spend is real, though
//! small: one Word_Count template job on one worker, a cent or two,
//! done in about four minutes when measured:
//!
//!     GCP_TEST_PROJECT=extractctl GCP_TEST_TOKEN=$(cat token.txt) \
//!     DATAFLOW_TEST=1 zig build test-integration-gcp -Dtest-filter="dataflow:"
//!
//! Without the variables the test skips. The client reads only, so the
//! job the suite reads is launched raw beside it, with a raw `zigps-`
//! temp bucket the suite deletes at the end; the job itself cannot be
//! deleted (Dataflow keeps terminal jobs listed) and bills nothing once
//! done. The fake is seeded with everything production lists and held
//! to production's answer for every read, including the made-up region
//! production serves with us-central1's jobs. About five minutes.
//!
//! The writes have their own gate, since they launch a streaming job
//! too (about 3 cents a run, measured on 2026-10-20):
//!
//!     GCP_TEST_PROJECT=extractctl GCP_TEST_TOKEN=$(cat token.txt) \
//!     DATAFLOW_WRITES_TEST=1 zig build test-integration-gcp -Dtest-filter="dataflow writes:"
//!
//! It launches one Word_Count batch job and one Pub/Sub-to-Pub/Sub
//! streaming job on `e2-standard-2` (its `zigps-` topics, subscription
//! and temp bucket made raw beside them), cancels the one and drains the
//! other through the client with every refusal production gives on the
//! way, holds each preview byte for byte to what was sent, and replays
//! every write on a fake kept in step with production's states. Every
//! job still running at the end is cancelled, and everything made is
//! deleted. About ten minutes.

const std = @import("std");
const core = @import("core");
const dataflow = @import("dataflow");
const testing = std.testing;
const Allocator = std.mem.Allocator;

const location = "us-central1";
const template = "gs://dataflow-templates/latest/Word_Count";
const input = "gs://dataflow-samples/shakespeare/kinglear.txt";

const Fixture = struct {
    env: std.process.Environ.Map,
    token: core.StaticToken,
    diag: dataflow.Diagnostics,
    client: dataflow.Client,
    project: []const u8,
    arena: std.heap.ArenaAllocator,
    run: []const u8,

    fn init(f: *Fixture, gate: []const u8) !bool {
        const gpa = testing.allocator;
        f.env = try testing.environ.createMap(gpa);
        errdefer f.env.deinit();
        f.project = f.env.get("GCP_TEST_PROJECT") orelse return f.skip();
        const token = f.env.get("GCP_TEST_TOKEN") orelse return f.skip();
        if (f.env.get(gate) == null) return f.skip();
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
            .user_agent = "zig-gcp-dataflow-gcp-integration/0.1",
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
    /// verb for: the launch, and the temp bucket on storage's host.
    fn raw(f: *Fixture, arena: Allocator, method: core.transport.Method, url: []const u8, body: ?[]const u8) !core.transport.Response {
        return f.client.transport.send(.{ .method = method, .url = url, .bearer = f.token.token, .body = body, .timeout_ms = 60_000 }, arena);
    }

    /// `raw`, tried again after a connection error, for the cleanups: a
    /// kept connection was reset under them after the long waits (both
    /// deletes of a writes run, 2026-10-20), leaving what they meant to
    /// delete behind.
    fn rawRetried(f: *Fixture, arena: Allocator, method: core.transport.Method, url: []const u8, body: ?[]const u8) !core.transport.Response {
        var attempt: usize = 1;
        while (true) : (attempt += 1) {
            return f.raw(arena, method, url, body) catch |err| {
                if (attempt >= 4) return err;
                fact("{t} {s}: {t}, trying again", .{ method, url, err });
                try testing.io.sleep(.fromMilliseconds(1_000), .awake);
                continue;
            };
        }
    }

    fn makeBucket(f: *Fixture, arena: Allocator, bucket: []const u8) !void {
        const url = try std.fmt.allocPrint(arena, "https://storage.googleapis.com/storage/v1/b?project={s}", .{f.project});
        const body = try std.fmt.allocPrint(arena,
            \\{{"name":"{s}","location":"US-CENTRAL1","iamConfiguration":{{"uniformBucketLevelAccess":{{"enabled":true}}}},"softDeletePolicy":{{"retentionDurationSeconds":"0"}}}}
        , .{bucket});
        const res = try f.raw(arena, .POST, url, body);
        try testing.expectEqual(200, res.status);
        fact("made bucket {s}", .{bucket});
    }

    /// Deletes every object, then the bucket.
    fn deleteBucket(f: *Fixture, arena: Allocator, bucket: []const u8) !void {
        while (true) {
            const list_url = try std.fmt.allocPrint(arena, "https://storage.googleapis.com/storage/v1/b/{s}/o?fields=items(name)", .{bucket});
            const listed = try f.rawRetried(arena, .GET, list_url, null);
            if (listed.status != 200) break;
            const parsed = std.json.parseFromSliceLeaky(std.json.Value, arena, listed.body, .{}) catch break;
            const items = if (parsed == .object) parsed.object.get("items") else null;
            if (items == null or items.? != .array or items.?.array.items.len == 0) break;
            for (items.?.array.items) |item| {
                if (item != .object) continue;
                const name = item.object.get("name") orelse continue;
                if (name != .string) continue;
                var w: std.Io.Writer.Allocating = .init(arena);
                w.writer.print("https://storage.googleapis.com/storage/v1/b/{s}/o/", .{bucket}) catch break;
                core.query.writeSegment(&w.writer, name.string) catch break;
                _ = try f.rawRetried(arena, .DELETE, w.written(), null);
            }
        }
        const url = try std.fmt.allocPrint(arena, "https://storage.googleapis.com/storage/v1/b/{s}", .{bucket});
        const res = try f.rawRetried(arena, .DELETE, url, null);
        fact("delete bucket {s}: HTTP {d}", .{ bucket, res.status });
    }
};

fn fact(comptime format: []const u8, args: anytype) void {
    std.debug.print("  " ++ format ++ "\n", args);
}

fn agree(differences: *usize, label: []const u8, production: []const u8, in_memory: []const u8) void {
    if (std.mem.eql(u8, production, in_memory)) {
        fact("{s}: {s}", .{ label, production });
    } else {
        differences.* += 1;
        std.debug.print("{s}\n  production: {s}\n  fake:       {s}\n", .{ label, production, in_memory });
    }
}

/// Production prefixes refusal messages with a request id, "(hex): ",
/// which the fake does not model: strip it before comparing.
fn unprefixed(message: []const u8) []const u8 {
    if (message.len > 2 and message[0] == '(') {
        if (std.mem.indexOf(u8, message[0..@min(message.len, 40)], "): ")) |at| {
            return message[at + 3 ..];
        }
    }
    return message;
}

fn writeJobLine(w: *std.Io.Writer, job: dataflow.Job) !void {
    try w.print("{s} name={s} loc={s} type={t} state={t} terminal={} failing={} requested={t} created={?d} labels={d} stages={d}", .{
        job.id,
        job.name,
        job.location,
        job.type,
        job.current_state,
        job.terminal(),
        job.failing(),
        job.requested_state,
        if (job.create_time) |t| @divFloor(t.nanoseconds, std.time.ns_per_s) else null,
        job.labels.len,
        job.stage_states.len,
    });
}

const Op = union(enum) {
    aggregated: dataflow.AggregatedOptions,
    list: struct { location: []const u8, options: dataflow.ListJobsOptions = .{} },
    get: struct { location: []const u8, id: []const u8 },
    get_description: struct { location: []const u8, id: []const u8 },
    messages: struct { id: []const u8, min: ?dataflow.MessageImportance },
};

fn outcome(a: Allocator, client: *dataflow.Client, diag: *dataflow.Diagnostics, op: Op) ![]const u8 {
    var w: std.Io.Writer.Allocating = .init(a);
    switch (op) {
        .aggregated => |options| {
            var page = client.aggregatedJobs(options) catch |err| {
                try w.writer.print("error.{t}: {s}", .{ err, unprefixed(diag.message()) });
                return w.written();
            };
            defer page.deinit();
            try w.writer.print("n={d} next={} failed={d}", .{ page.value.jobs.len, page.value.next_page_token != null, page.value.failed_locations.len });
            for (page.value.jobs) |job| {
                try w.writer.writeAll(" | ");
                try writeJobLine(&w.writer, job);
            }
        },
        .list => |l| {
            var page = client.listJobs(l.location, l.options) catch |err| {
                try w.writer.print("error.{t}: {s}", .{ err, unprefixed(diag.message()) });
                return w.written();
            };
            defer page.deinit();
            try w.writer.print("n={d} next={}", .{ page.value.jobs.len, page.value.next_page_token != null });
            for (page.value.jobs) |job| {
                try w.writer.writeAll(" | ");
                try writeJobLine(&w.writer, job);
            }
        },
        .get => |g| {
            var got = client.getJob(g.location, g.id) catch |err| {
                try w.writer.print("error.{t}: {s}", .{ err, unprefixed(diag.message()) });
                return w.written();
            };
            defer got.deinit();
            try writeJobLine(&w.writer, got.value);
        },
        .get_description => |g| {
            var got = client.getJobView(g.location, g.id, .description) catch |err| {
                try w.writer.print("error.{t}: {s}", .{ err, unprefixed(diag.message()) });
                return w.written();
            };
            defer got.deinit();
            try writeJobLine(&w.writer, got.value);
        },
        .messages => |m| {
            var page = client.listMessages(location, m.id, .{ .minimum_importance = m.min }) catch |err| {
                try w.writer.print("error.{t}: {s}", .{ err, unprefixed(diag.message()) });
                return w.written();
            };
            defer page.deinit();
            try w.writer.print("n={d} events={d}", .{ page.value.messages.len, page.value.autoscaling_events.len });
            for (page.value.messages) |message| {
                try w.writer.print(" | {t} {s}", .{ message.importance, message.text });
            }
        },
    }
    return w.written();
}

/// Everything production lists, fed into the fake as it answered: the
/// summaries from the aggregated list, each job's get for the labels
/// and stage states the summaries do not carry, and our job's story.
fn seed(fake: *dataflow.testing.FakeDataflow, client: *dataflow.Client, page: *const dataflow.JobPage, ours: []const u8) !void {
    for (page.jobs) |job| {
        fake.putLocation(job.location) catch |err| if (err != error.InvalidEntry) return err;
        var whole = try client.getJob(job.location, job.id);
        defer whole.deinit();
        _ = try fake.putJob(.{
            .location = whole.value.location,
            .id = whole.value.id,
            .name = whole.value.name,
            .type = whole.value.type,
            .current_state = whole.value.current_state,
            .current_state_time = whole.value.current_state_time,
            .requested_state = whole.value.requested_state,
            .create_time = whole.value.create_time,
            .start_time = whole.value.start_time,
            .labels = whole.value.labels,
            .stage_states = whole.value.stage_states,
        });
        if (std.mem.eql(u8, job.id, ours)) {
            var story = try client.listMessages(job.location, job.id, .{ .minimum_importance = .@"error" });
            defer story.deinit();
            for (story.value.messages) |message| {
                try fake.putMessage(.{
                    .job = job.id,
                    .id = message.id,
                    .time = message.time,
                    .text = message.text,
                    .importance = message.importance,
                });
            }
            for (story.value.autoscaling_events) |event| {
                try fake.putAutoscalingEvent(.{
                    .job = job.id,
                    .event_type = event.event_type,
                    .time = event.time,
                    .description = event.description,
                    .current_num_workers = event.current_num_workers,
                    .target_num_workers = event.target_num_workers,
                    .worker_pool = event.worker_pool,
                });
            }
        }
    }
}

test "dataflow: a real Word_Count run, the fake seeded with production's lists answering alike" {
    var f: Fixture = undefined;
    if (!try f.init("DATAFLOW_TEST")) return error.SkipZigTest;
    defer f.deinit();
    const a = f.arena.allocator();

    // The temp bucket, deleted at the end whatever happens past here.
    const bucket = try a.print("zigps-df-{s}", .{f.run});
    try f.makeBucket(a, bucket);
    defer {
        var cleanup: std.heap.ArenaAllocator = .init(testing.allocator);
        f.deleteBucket(cleanup.allocator(), bucket) catch |err| fact("bucket cleanup failed: {t}", .{err});
        cleanup.deinit();
    }

    // Launch Word_Count raw: the client reads only.
    const job_name = try a.print("zigps-df-{s}", .{f.run});
    var job_id: []const u8 = "";
    {
        const url = try a.print("{s}/v1b3/projects/{s}/locations/{s}/templates:launch?gcsPath={s}", .{ f.client.base_url, f.project, location, template });
        const body = try a.print(
            \\{{"jobName":"{s}","parameters":{{"inputFile":"{s}","output":"gs://{s}/out/wc"}},"environment":{{"tempLocation":"gs://{s}/tmp","maxWorkers":1}}}}
        , .{ job_name, input, bucket, bucket });
        const res = try f.raw(a, .POST, url, body);
        try testing.expectEqual(200, res.status);
        const parsed = try std.json.parseFromSliceLeaky(std.json.Value, a, res.body, .{});
        job_id = try a.dupe(u8, parsed.object.get("job").?.object.get("id").?.string);
        fact("launched {s} as {s}", .{ job_name, job_id });
    }

    // Poll to a terminal state: DONE at 244 s when measured; the
    // budget is generous because a worker pool can be slow to start.
    const started = std.Io.Clock.real.now(testing.io).nanoseconds;
    var state: dataflow.JobState = .unspecified;
    while (std.Io.Clock.real.now(testing.io).nanoseconds - started < 20 * std.time.ns_per_min) {
        var got = try f.client.getJob(location, job_id);
        defer got.deinit();
        if (got.value.current_state != state) {
            state = got.value.current_state;
            fact("{d}s: {t}", .{ @divFloor(std.Io.Clock.real.now(testing.io).nanoseconds - started, std.time.ns_per_s), state });
        }
        if (state.terminal()) break;
        try testing.io.sleep(.fromMilliseconds(15_000), .awake);
    }
    try testing.expectEqual(dataflow.JobState.done, state);

    // Production's state, whole, for the seed and the ops.
    var everywhere = try f.client.aggregatedJobs(.{ .filter = .all });
    defer everywhere.deinit();
    fact("production: {d} jobs across every region, {d} failed locations", .{ everywhere.value.jobs.len, everywhere.value.failed_locations.len });

    var fake: dataflow.testing.FakeDataflow = .init(testing.allocator, testing.io, .{ .project_id = f.project });
    defer fake.deinit();
    var fake_diag: dataflow.Diagnostics = .{};
    var fake_token: core.StaticToken = .{ .token = "t" };
    var fake_client = try dataflow.Client.init(testing.allocator, testing.io, .{ .project_id = f.project, .token_provider = fake_token.provider(), .transport = fake.transport(), .diagnostics = &fake_diag });
    defer fake_client.deinit();
    try seed(&fake, &f.client, &everywhere.value, job_id);
    fact("{d} jobs seeded", .{fake.jobCount()});

    // Every read, production and the fake compared as text.
    var differences: usize = 0;
    const ops = [_]struct { []const u8, Op }{
        .{ "aggregated", .{ .aggregated = .{ .filter = .all } } },
        .{ "aggregated page of one", .{ .aggregated = .{ .filter = .all, .page_size = 1 } } },
        .{ "list the location", .{ .list = .{ .location = location, .options = .{ .filter = .all } } } },
        .{ "list terminated", .{ .list = .{ .location = location, .options = .{ .filter = .terminated } } } },
        .{ "list active", .{ .list = .{ .location = location, .options = .{ .filter = .active } } } },
        .{ "list by name", .{ .list = .{ .location = location, .options = .{ .filter = .all, .name = job_name } } } },
        .{ "get the job", .{ .get = .{ .location = location, .id = job_id } } },
        .{ "get at DESCRIPTION", .{ .get_description = .{ .location = location, .id = job_id } } },
        .{ "get an unknown job", .{ .get = .{ .location = location, .id = "2026-10-20_00_00_00-1234567890123456789" } } },
        .{ "get in a made-up region", .{ .get = .{ .location = "us-fake1", .id = job_id } } },
        .{ "list in a made-up region", .{ .list = .{ .location = "us-fake1", .options = .{ .filter = .all } } } },
        .{ "messages at ERROR", .{ .messages = .{ .id = job_id, .min = .@"error" } } },
    };
    for (ops) |op| {
        const in_production = try outcome(a, &f.client, &f.diag, op[1]);
        const in_memory = try outcome(a, &fake_client, &fake_diag, op[1]);
        agree(&differences, op[0], in_production, in_memory);
    }
    try testing.expectEqual(0, differences);
}

/// A transport that keeps the last request it passed on, for holding a
/// preview to what was sent.
const Recorder = struct {
    inner: core.transport.Transport,
    arena: std.heap.ArenaAllocator,
    method: core.transport.Method = .GET,
    url: []const u8 = "",
    body: []const u8 = "",

    fn transport(r: *Recorder) core.transport.Transport {
        return .{ .ptr = r, .vtable = &.{ .send = send } };
    }

    fn send(ptr: *anyopaque, req: core.transport.Request, arena: Allocator) core.transport.Error!core.transport.Response {
        const r: *Recorder = @ptrCast(@alignCast(ptr));
        r.method = req.method;
        r.url = r.arena.allocator().dupe(u8, req.url) catch return error.OutOfMemory;
        r.body = r.arena.allocator().dupe(u8, req.body orelse "") catch return error.OutOfMemory;
        return r.inner.send(req, arena);
    }
};

/// Production's words without the request ids it puts in parentheses
/// before each cause, which the fake leaves out.
fn withoutIds(a: Allocator, text: []const u8) ![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    var i: usize = 0;
    while (i < text.len) {
        if (text[i] == '(') if (std.mem.indexOfPos(u8, text, i, "): ")) |close| {
            const inner = text[i + 1 .. close];
            const hex = inner.len > 0 and for (inner) |c| {
                if (!std.ascii.isHex(c)) break false;
            } else true;
            if (hex) {
                i = close + 3;
                continue;
            }
        };
        try out.append(a, text[i]);
        i += 1;
    }
    return out.items;
}

const Stop = enum { cancel, drain };

fn stopOutcome(a: Allocator, client: *dataflow.Client, diag: *dataflow.Diagnostics, which: Stop, where: []const u8, id: []const u8) ![]const u8 {
    const got = switch (which) {
        .cancel => client.cancelJob(where, id),
        .drain => client.drainJob(where, id),
    };
    got catch |err| return a.print("error.{t}: {s}", .{ err, try withoutIds(a, diag.message()) });
    return "taken";
}

fn stateOf(a: Allocator, client: *dataflow.Client, id: []const u8) ![]const u8 {
    var job = try client.getJob(location, id);
    defer job.deinit();
    return a.print("current={t} requested={t} cancellable={} drainable={}", .{ job.value.current_state, job.value.requested_state, job.value.cancellable(), job.value.drainable() });
}

/// Polls production every 5 s until `until` holds or `limit_s` passes,
/// moving the fake's job along with each state production shows, as the
/// service moves its own. Answers the last state read.
fn follow(f: *Fixture, fake: *dataflow.testing.FakeDataflow, id: []const u8, until: *const fn (dataflow.JobState) bool, limit_s: u32) !dataflow.JobState {
    const started = std.Io.Clock.real.now(testing.io).nanoseconds;
    var state: dataflow.JobState = .unspecified;
    while (true) {
        var got = try f.client.getJob(location, id);
        defer got.deinit();
        if (got.value.current_state != state) {
            state = got.value.current_state;
            fact("{s} {d}s: {t}", .{ id, @divFloor(std.Io.Clock.real.now(testing.io).nanoseconds - started, std.time.ns_per_s), state });
            try fake.setJobState(id, state, null);
        }
        if (until(state)) return state;
        if (std.Io.Clock.real.now(testing.io).nanoseconds - started > @as(i96, limit_s) * std.time.ns_per_s) return state;
        try testing.io.sleep(.fromMilliseconds(5_000), .awake);
    }
}

fn isRunning(state: dataflow.JobState) bool {
    return state == .running or state.terminal();
}

fn isEnded(state: dataflow.JobState) bool {
    return state.terminal();
}

/// Whether the job's worker pool has a worker: production's streaming
/// jobs read RUNNING before one is up, and a drain of one with none
/// ended FAILED when measured.
fn workerUp(f: *Fixture, id: []const u8) !bool {
    var story = try f.client.listMessages(location, id, .{});
    defer story.deinit();
    for (story.value.autoscaling_events) |event| {
        if (event.current_num_workers) |n| if (n >= 1) return true;
    }
    return false;
}

/// The lines production adds to a job's story when it takes a write.
fn committedLines(a: Allocator, client: *dataflow.Client, id: []const u8) ![]const u8 {
    var story = try client.listMessages(location, id, .{});
    defer story.deinit();
    var w: std.Io.Writer.Allocating = .init(a);
    for (story.value.messages) |message| {
        if (std.mem.indexOf(u8, message.text, "request is committed") == null) continue;
        try w.writer.print("{s} {t} | ", .{ message.text, message.importance });
    }
    return w.written();
}

test "dataflow writes: a batch job cancelled, a streaming one drained, the fake answering alike" {
    var f: Fixture = undefined;
    if (!try f.init("DATAFLOW_WRITES_TEST")) return error.SkipZigTest;
    defer f.deinit();
    const a = f.arena.allocator();
    const prefix = try a.print("zigps-df-w{s}", .{f.run});
    const pubsub = "https://pubsub.googleapis.com/v1";
    const topic_in = try a.print("{s}-in", .{prefix});
    const topic_out = try a.print("{s}-out", .{prefix});
    const sub = try a.print("{s}-in-sub", .{prefix});

    // What is made is deleted at the end, whatever happens past here:
    // the bucket last, then the Pub/Sub resources, and first every job
    // still running, cancelled until production takes it.
    try f.makeBucket(a, prefix);
    defer {
        var cleanup: std.heap.ArenaAllocator = .init(testing.allocator);
        f.deleteBucket(cleanup.allocator(), prefix) catch |err| fact("bucket cleanup failed: {t}", .{err});
        cleanup.deinit();
    }
    for ([_][]const u8{ topic_in, topic_out }) |topic| {
        const res = try f.raw(a, .PUT, try a.print("{s}/projects/{s}/topics/{s}", .{ pubsub, f.project, topic }), "{}");
        try testing.expectEqual(200, res.status);
    }
    {
        const body = try a.print("{{\"topic\":\"projects/{s}/topics/{s}\"}}", .{ f.project, topic_in });
        const res = try f.raw(a, .PUT, try a.print("{s}/projects/{s}/subscriptions/{s}", .{ pubsub, f.project, sub }), body);
        try testing.expectEqual(200, res.status);
    }
    defer {
        var cleanup: std.heap.ArenaAllocator = .init(testing.allocator);
        const c = cleanup.allocator();
        if (std.fmt.allocPrint(c, "{s}/projects/{s}/subscriptions/{s}", .{ pubsub, f.project, sub })) |url| {
            if (f.rawRetried(c, .DELETE, url, null)) |res| fact("delete subscription: HTTP {d}", .{res.status}) else |err| fact("subscription cleanup failed: {t}", .{err});
        } else |_| {}
        for ([_][]const u8{ topic_in, topic_out }) |topic| {
            const url = std.fmt.allocPrint(c, "{s}/projects/{s}/topics/{s}", .{ pubsub, f.project, topic }) catch continue;
            if (f.rawRetried(c, .DELETE, url, null)) |res| fact("delete topic {s}: HTTP {d}", .{ topic, res.status }) else |err| fact("topic cleanup failed: {t}", .{err});
        }
        cleanup.deinit();
    }

    // Both jobs launched raw: the client launches nothing.
    var launched: std.ArrayList([]const u8) = .empty;
    defer {
        for (launched.items) |id| {
            var tries: usize = 0;
            while (tries < 60) : (tries += 1) {
                var job = f.client.getJob(location, id) catch break;
                defer job.deinit();
                if (job.value.terminal()) break;
                if (job.value.requested_state != .cancelled) f.client.cancelJob(location, id) catch {};
                testing.io.sleep(.fromMilliseconds(10_000), .awake) catch break;
            }
            fact("cleanup: {s} ended or given up after {d} tries", .{ id, tries });
        }
    }
    const launch_url = try a.print("{s}/v1b3/projects/{s}/locations/{s}/templates:launch?gcsPath=", .{ f.client.base_url, f.project, location });
    const batch_id = b: {
        const body = try a.print(
            \\{{"jobName":"{s}-b","parameters":{{"inputFile":"{s}","output":"gs://{s}/out/wc"}},"environment":{{"tempLocation":"gs://{s}/tmp","maxWorkers":1}}}}
        , .{ prefix, input, prefix, prefix });
        const res = try f.raw(a, .POST, try a.print("{s}{s}", .{ launch_url, template }), body);
        try testing.expectEqual(200, res.status);
        const parsed = try std.json.parseFromSliceLeaky(std.json.Value, a, res.body, .{});
        const id = try a.dupe(u8, parsed.object.get("job").?.object.get("id").?.string);
        try launched.append(a, id);
        break :b id;
    };
    const streaming_id = s: {
        const body = try a.print(
            \\{{"jobName":"{s}-s","parameters":{{"inputSubscription":"projects/{s}/subscriptions/{s}","outputTopic":"projects/{s}/topics/{s}"}},"environment":{{"tempLocation":"gs://{s}/tmp","machineType":"e2-standard-2","numWorkers":1,"maxWorkers":1}}}}
        , .{ prefix, f.project, sub, f.project, topic_out, prefix });
        const res = try f.raw(a, .POST, try a.print("{s}gs://dataflow-templates-us-central1/latest/Cloud_PubSub_to_Cloud_PubSub", .{launch_url}), body);
        try testing.expectEqual(200, res.status);
        const parsed = try std.json.parseFromSliceLeaky(std.json.Value, a, res.body, .{});
        const id = try a.dupe(u8, parsed.object.get("job").?.object.get("id").?.string);
        try launched.append(a, id);
        break :s id;
    };
    fact("launched {s} (batch) and {s} (streaming)", .{ batch_id, streaming_id });

    // The writes go through a client whose transport keeps what it sent.
    var recorder: Recorder = .{ .inner = f.client.transport, .arena = .init(testing.allocator) };
    defer recorder.arena.deinit();
    var wdiag: dataflow.Diagnostics = .{};
    var wc = try dataflow.Client.init(testing.allocator, testing.io, .{
        .project_id = f.project,
        .token_provider = f.token.provider(),
        .diagnostics = &wdiag,
        .transport = recorder.transport(),
        .user_agent = "zig-gcp-dataflow-gcp-integration/0.1",
    });
    defer wc.deinit();

    // The fake holds the two jobs, kept in step with production's states.
    var fake: dataflow.testing.FakeDataflow = .init(testing.allocator, testing.io, .{ .project_id = f.project });
    defer fake.deinit();
    try fake.putLocation(location);
    try fake.putLocation("us-east1");
    _ = try fake.putJob(.{ .location = location, .id = batch_id, .type = .batch, .current_state = .pending });
    _ = try fake.putJob(.{ .location = location, .id = streaming_id, .type = .streaming, .current_state = .pending });
    var fake_diag: dataflow.Diagnostics = .{};
    var fake_token: core.StaticToken = .{ .token = "t" };
    var fake_client = try dataflow.Client.init(testing.allocator, testing.io, .{ .project_id = f.project, .token_provider = fake_token.provider(), .transport = fake.transport(), .diagnostics = &fake_diag });
    defer fake_client.deinit();

    var differences: usize = 0;
    var previews: usize = 0;
    const Step = struct { label: []const u8, which: Stop, id: []const u8, where: []const u8 = location };
    const Run = struct {
        fn step(r: anytype, s: Step) !void {
            // The state production holds just before, into the fake.
            var before = try r.f.client.getJob(location, s.id);
            defer before.deinit();
            try r.fake.setJobState(s.id, before.value.current_state, null);
            // The preview, then the write it names: byte for byte the same.
            var preview = try switch (s.which) {
                .cancel => r.wc.cancelJobRequest(s.where, s.id),
                .drain => r.wc.drainJobRequest(s.where, s.id),
            };
            defer preview.deinit();
            const in_production = try stopOutcome(r.a, r.wc, r.wdiag, s.which, s.where, s.id);
            try testing.expectEqual(preview.value.method, r.recorder.method);
            try testing.expectEqualStrings(preview.value.url, r.recorder.url);
            try testing.expectEqualStrings(preview.value.body, r.recorder.body);
            r.previews.* += 1;
            const in_memory = try stopOutcome(r.a, r.fake_client, r.fake_diag, s.which, s.where, s.id);
            agree(r.differences, try r.a.print("{s} ({t} before)", .{ s.label, before.value.current_state }), in_production, in_memory);
            agree(r.differences, try r.a.print("{s}, read after", .{s.label}), try stateOf(r.a, &r.f.client, s.id), try stateOf(r.a, r.fake_client, s.id));
        }
    };
    const r = .{ .f = &f, .fake = &fake, .wc = &wc, .wdiag = &wdiag, .fake_client = &fake_client, .fake_diag = &fake_diag, .recorder = &recorder, .a = a, .previews = &previews, .differences = &differences };

    // The batch job, pending: a cancel is not yet taken, a drain never.
    try Run.step(r, .{ .label = "cancel the batch job just launched", .which = .cancel, .id = batch_id });
    try Run.step(r, .{ .label = "drain the batch job", .which = .drain, .id = batch_id });
    // A real region the job is not in, and one nobody has, which
    // production routes to the job's own.
    try Run.step(r, .{ .label = "cancel through us-east1", .which = .cancel, .id = batch_id, .where = "us-east1" });
    try Run.step(r, .{ .label = "cancel through us-fake1", .which = .cancel, .id = batch_id, .where = "us-fake1" });

    // Running: taken, a repeat taken, a drain still refused.
    const batch_state = try follow(&f, &fake, batch_id, isRunning, 300);
    if (batch_state == .running) {
        try Run.step(r, .{ .label = "cancel the running batch job", .which = .cancel, .id = batch_id });
        try Run.step(r, .{ .label = "cancel it again", .which = .cancel, .id = batch_id });
        try Run.step(r, .{ .label = "drain it while cancelling", .which = .drain, .id = batch_id });
    } else fact("the batch job was {t} before it could be cancelled running", .{batch_state});

    // The streaming job, once a worker is up.
    var up = false;
    {
        const started = std.Io.Clock.real.now(testing.io).nanoseconds;
        var last: dataflow.JobState = .unspecified;
        while (std.Io.Clock.real.now(testing.io).nanoseconds - started < 10 * std.time.ns_per_min) {
            var got = try f.client.getJob(location, streaming_id);
            defer got.deinit();
            const state = got.value.current_state;
            if (state != last) {
                last = state;
                fact("{s} {d}s: {t}", .{ streaming_id, @divFloor(std.Io.Clock.real.now(testing.io).nanoseconds - started, std.time.ns_per_s), state });
                try fake.setJobState(streaming_id, state, null);
            }
            if (state.terminal()) break;
            if (state == .running and try workerUp(&f, streaming_id)) {
                up = true;
                break;
            }
            try testing.io.sleep(.fromMilliseconds(10_000), .awake);
        }
    }
    if (up) {
        try Run.step(r, .{ .label = "drain the streaming job", .which = .drain, .id = streaming_id });
        try Run.step(r, .{ .label = "drain it again", .which = .drain, .id = streaming_id });
        const drained = try follow(&f, &fake, streaming_id, isEnded, 900);
        fact("the streaming job ended {t}", .{drained});
        if (drained.terminal()) {
            try Run.step(r, .{ .label = "drain the ended streaming job", .which = .drain, .id = streaming_id });
            try Run.step(r, .{ .label = "cancel the ended streaming job", .which = .cancel, .id = streaming_id });
        }
    } else fact("no worker came up for the streaming job (a stockout?): its drain is not measured this run", .{});

    // The batch job, ended.
    const ended = try follow(&f, &fake, batch_id, isEnded, 900);
    fact("the batch job ended {t}", .{ended});
    if (ended.terminal()) try Run.step(r, .{ .label = "cancel the ended batch job", .which = .cancel, .id = batch_id });

    // A job nobody has: the fake knows no such id either.
    for ([_]Stop{ .cancel, .drain }) |which| {
        const nobody = "2026-10-20_00_00_00-1234567890123456789";
        const in_production = try stopOutcome(a, &wc, &wdiag, which, location, nobody);
        const in_memory = try stopOutcome(a, &fake_client, &fake_diag, which, location, nobody);
        agree(&differences, try a.print("{t} a job nobody has", .{which}), in_production, in_memory);
    }

    // The lines each write added to the jobs' stories.
    for ([_][]const u8{ batch_id, streaming_id }) |id| {
        agree(&differences, try a.print("{s}'s committed lines", .{id}), try committedLines(a, &f.client, id), try committedLines(a, &fake_client, id));
    }

    fact("{d} previews held byte for byte to what was sent", .{previews});
    try testing.expectEqual(0, differences);
}
