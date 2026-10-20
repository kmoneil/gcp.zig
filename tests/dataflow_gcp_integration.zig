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

    fn init(f: *Fixture) !bool {
        const gpa = testing.allocator;
        f.env = try testing.environ.createMap(gpa);
        errdefer f.env.deinit();
        f.project = f.env.get("GCP_TEST_PROJECT") orelse return f.skip();
        const token = f.env.get("GCP_TEST_TOKEN") orelse return f.skip();
        if (f.env.get("DATAFLOW_TEST") == null) return f.skip();
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
            const listed = try f.raw(arena, .GET, list_url, null);
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
                _ = try f.raw(arena, .DELETE, w.written(), null);
            }
        }
        const url = try std.fmt.allocPrint(arena, "https://storage.googleapis.com/storage/v1/b/{s}", .{bucket});
        const res = try f.raw(arena, .DELETE, url, null);
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
    if (!try f.init()) return error.SkipZigTest;
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
