//! Integration tests against real Cloud Run, which has no emulator:
//! milestone 2 of the Cloud Run spec (issue #244). They need a project
//! with the API on and a token that may read, deploy and delete services
//! there (Editor does, with actAs on the compute default account):
//!
//!     GCP_TEST_PROJECT=extractctl GCP_TEST_TOKEN=$(cat token.txt) \
//!     RUN_TEST=1 zig build test-integration-gcp -Dtest-filter="run:"
//!
//! Without the variables the test skips. The client reads only, so the
//! service the suite reads is deployed raw beside it: one `zigps-<run>`
//! hello service (the public image, scale to zero, request billed: its
//! minutes of life round to nothing), then a second revision with an
//! image tag nobody has, for a real failed deploy. Deploys and deletes
//! are LROs, polled raw. The fake is seeded with everything production
//! lists and held to production's answer for every read, including the
//! `-` location with its `unreachable` regions. The suite sweeps
//! `zigps-` services of earlier runs first and deletes its own at the
//! end. About two minutes.
//!
//! The writes (issue #272) have their own gate, so the read suite stays
//! two minutes long:
//!
//!     GCP_TEST_PROJECT=extractctl GCP_TEST_TOKEN=$(cat run.tok) \
//!     RUN_WRITES_TEST=1 zig build test-integration-gcp -Dtest-filter="run writes:"
//!
//! The token must carry the `run` or `cloud-platform` scope: production
//! refuses every write to `run.readonly`. It makes three `zigps-` jobs on
//! Google's sample job image (a quick one, a slow one to cancel, one that
//! fails) and a `zigps-` hello service with two revisions, raw; runs,
//! cancels and routes traffic through the client, every preview held
//! byte for byte to what was sent; then replays the same script on a fake
//! seeded from production's reads, every outcome and refusal held equal.
//! Cleanup cancels what still runs and deletes every job and the service.
//! About five minutes, inside Cloud Run's free tier.

const std = @import("std");
const core = @import("core");
const run_mod = @import("run");
const testing = std.testing;
const Allocator = std.mem.Allocator;

const location = "us-central1";
const hello = "us-docker.pkg.dev/cloudrun/container/hello";

const Fixture = struct {
    env: std.process.Environ.Map,
    token: core.StaticToken,
    diag: run_mod.Diagnostics,
    client: run_mod.Client,
    project: []const u8,
    arena: std.heap.ArenaAllocator,
    run: []const u8,

    fn init(f: *Fixture, gate: []const u8, scope: run_mod.Scope) !bool {
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
            .scope = scope,
            .diagnostics = &f.diag,
            .user_agent = "zig-gcp-run-gcp-integration/0.1",
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
    /// verb for: the deploys and deletes, which answer operations.
    fn raw(f: *Fixture, arena: Allocator, method: core.transport.Method, path: []const u8, body: ?[]const u8) !core.transport.Response {
        const url = try std.fmt.allocPrint(arena, "{s}{s}", .{ f.client.base_url, path });
        return f.client.transport.send(.{ .method = method, .url = url, .bearer = f.token.token, .body = body, .timeout_ms = 60_000 }, arena);
    }

    /// Polls an operation until done; true when it finished in time.
    fn awaitOperation(f: *Fixture, arena: Allocator, op_body: []const u8, budget_s: i64) !bool {
        const parsed = std.json.parseFromSliceLeaky(std.json.Value, arena, op_body, .{}) catch return false;
        if (parsed != .object) return false;
        const name = parsed.object.get("name") orelse return false;
        if (name != .string) return false;
        const path = try std.fmt.allocPrint(arena, "/v2/{s}", .{name.string});
        const started = std.Io.Clock.real.now(testing.io).nanoseconds;
        while (std.Io.Clock.real.now(testing.io).nanoseconds - started < @as(i96, budget_s) * std.time.ns_per_s) {
            const res = try f.raw(arena, .GET, path, null);
            if (res.status == 200 and std.mem.indexOf(u8, res.body, "\"done\": true") != null or
                std.mem.indexOf(u8, res.body, "\"done\":true") != null) return true;
            try testing.io.sleep(.fromMilliseconds(5_000), .awake);
        }
        return false;
    }

    fn deleteService(f: *Fixture, arena: Allocator, id: []const u8) !void {
        const path = try std.fmt.allocPrint(arena, "/v2/projects/{s}/locations/{s}/services/{s}", .{ f.project, location, id });
        const res = try f.raw(arena, .DELETE, path, null);
        if (res.status == 200) {
            _ = try f.awaitOperation(arena, res.body, 120);
        }
        fact("delete {s}: HTTP {d}", .{ id, res.status });
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

fn sweep(f: *Fixture, a: Allocator) !void {
    var page = f.client.listServices(location, .{}) catch |err| {
        fact("sweep: listing services failed: {t}", .{err});
        return;
    };
    defer page.deinit();
    for (page.value.services) |service| {
        if (!std.mem.startsWith(u8, service.id, "zigps-")) continue;
        try f.deleteService(a, service.id);
    }
}

fn writeCondition(w: *std.Io.Writer, condition: ?run_mod.Condition) !void {
    const c = condition orelse {
        try w.writeAll("none");
        return;
    };
    try w.print("{s}/{t}", .{ c.type, c.state });
    if (c.reason.len > 0) try w.print(" reason={s}", .{c.reason});
    if (c.message.len > 0) try w.print(" msg=\"{s}\"", .{c.message});
}

fn writeServiceLine(w: *std.Io.Writer, service: run_mod.Service) !void {
    try w.print("{s} ready={} terminal=", .{ service.id, service.ready() });
    try writeCondition(w, service.terminal_condition);
    try w.print(" latest_ready={s} latest_created={s} gen={?d}/{?d} traffic={d}/{d} urls={d} labels={d}", .{
        service.latest_ready_revision,
        service.latest_created_revision,
        service.generation,
        service.observed_generation,
        service.traffic.len,
        service.traffic_statuses.len,
        service.urls.len,
        service.labels.len,
    });
}

fn writeRevisionLine(w: *std.Io.Writer, revision: run_mod.Revision) !void {
    try w.print("{s} svc={s} ready={} gen={?d} created={?d} images=", .{
        revision.id,
        revision.service,
        revision.ready(),
        revision.generation,
        if (revision.create_time) |t| @divFloor(t.nanoseconds, std.time.ns_per_s) else null,
    });
    for (revision.containers) |container| try w.print("{s},", .{container.image});
    try w.writeAll(" ready_condition=");
    try writeCondition(w, revision.readyCondition());
}

const Op = union(enum) {
    get_service: []const u8,
    get_service_named: []const u8,
    get_revision_named: []const u8,
    list_services: struct { location: []const u8, options: run_mod.ListOptions = .{} },
    list_revisions: struct { service: []const u8, options: run_mod.ListOptions = .{} },
};

fn outcome(a: Allocator, client: *run_mod.Client, diag: *run_mod.Diagnostics, op: Op) ![]const u8 {
    var w: std.Io.Writer.Allocating = .init(a);
    switch (op) {
        .get_service => |id| {
            var got = client.getService(location, id) catch |err| {
                try w.writer.print("error.{t}: {s}", .{ err, diag.message() });
                return w.written();
            };
            defer got.deinit();
            try writeServiceLine(&w.writer, got.value);
        },
        .get_service_named => |name| {
            var got = client.getServiceNamed(name) catch |err| {
                try w.writer.print("error.{t}: {s}", .{ err, diag.message() });
                return w.written();
            };
            defer got.deinit();
            try writeServiceLine(&w.writer, got.value);
        },
        .get_revision_named => |name| {
            var got = client.getRevisionNamed(name) catch |err| {
                try w.writer.print("error.{t}: {s}", .{ err, diag.message() });
                return w.written();
            };
            defer got.deinit();
            try writeRevisionLine(&w.writer, got.value);
        },
        .list_services => |l| {
            var page = client.listServices(l.location, l.options) catch |err| {
                try w.writer.print("error.{t}: {s}", .{ err, diag.message() });
                return w.written();
            };
            defer page.deinit();
            try w.writer.print("n={d} next={} unreachable={d}", .{ page.value.services.len, page.value.next_page_token != null, page.value.unreachable_regions.len });
            for (page.value.services) |service| {
                try w.writer.writeAll(" | ");
                try writeServiceLine(&w.writer, service);
            }
        },
        .list_revisions => |l| {
            var page = client.listRevisions(location, l.service, l.options) catch |err| {
                try w.writer.print("error.{t}: {s}", .{ err, diag.message() });
                return w.written();
            };
            defer page.deinit();
            try w.writer.print("n={d} next={}", .{ page.value.revisions.len, page.value.next_page_token != null });
            for (page.value.revisions) |revision| {
                try w.writer.writeAll(" | ");
                try writeRevisionLine(&w.writer, revision);
            }
        },
    }
    return w.written();
}

/// Everything production lists, fed into the fake as it answered.
fn seed(fake: *run_mod.testing.FakeRun, services: *const run_mod.ServicePage, revisions: *const run_mod.RevisionPage) !void {
    for (services.services) |service| {
        _ = try fake.putService(.{
            .location = service.location,
            .id = service.id,
            .description = service.description,
            .uri = service.uri,
            .urls = service.urls,
            .latest_ready_revision = service.latest_ready_revision,
            .latest_created_revision = service.latest_created_revision,
            .traffic = service.traffic,
            .traffic_statuses = service.traffic_statuses,
            .terminal_condition = service.terminal_condition,
            .conditions = service.conditions,
            .create_time = service.create_time,
            .update_time = service.update_time,
            .creator = service.creator,
            .last_modifier = service.last_modifier,
            .generation = service.generation,
            .observed_generation = service.observed_generation,
            .reconciling = service.reconciling,
            .labels = service.labels,
        });
    }
    for (revisions.revisions) |revision| {
        _ = try fake.putRevision(.{
            .location = revision.location,
            .service = revision.service,
            .id = revision.id,
            .create_time = revision.create_time,
            .update_time = revision.update_time,
            .generation = revision.generation,
            .containers = revision.containers,
            .conditions = revision.conditions,
            .log_uri = revision.log_uri,
            .service_account = revision.service_account,
            .labels = revision.labels,
        });
    }
}

test "run: a real deploy and a real failed one, the fake seeded with production's lists answering alike" {
    var f: Fixture = undefined;
    if (!try f.init("RUN_TEST", .read_only)) return error.SkipZigTest;
    defer f.deinit();
    const a = f.arena.allocator();
    try sweep(&f, a);

    // Deploy the hello service: an LRO, done in seconds when measured.
    const svc = try a.print("zigps-{s}", .{f.run});
    const services_path = try a.print("/v2/projects/{s}/locations/{s}/services?serviceId={s}", .{ f.project, location, svc });
    var deployed = false;
    defer if (deployed) {
        var cleanup: std.heap.ArenaAllocator = .init(testing.allocator);
        f.deleteService(cleanup.allocator(), svc) catch |err| fact("cleanup failed: {t}", .{err});
        cleanup.deinit();
    };
    {
        const body = try a.print(
            \\{{"template":{{"containers":[{{"image":"{s}"}}]}},"labels":{{"zigps":"suite"}}}}
        , .{hello});
        const res = try f.raw(a, .POST, services_path, body);
        try testing.expectEqual(200, res.status);
        deployed = true;
        try testing.expect(try f.awaitOperation(a, res.body, 300));
        fact("deployed {s}", .{svc});
    }

    // A second revision with an image tag nobody has: the operation
    // completes with an error, and the trouble shapes are real.
    {
        const patch_path = try a.print("/v2/projects/{s}/locations/{s}/services/{s}", .{ f.project, location, svc });
        const body = try a.print(
            \\{{"template":{{"containers":[{{"image":"{s}:zigps-no-such-tag"}}]}}}}
        , .{hello});
        const res = try f.raw(a, .PATCH, patch_path, body);
        try testing.expectEqual(200, res.status);
        _ = try f.awaitOperation(a, res.body, 300);
        fact("broke {s} with a bad image", .{svc});
    }

    // Production's state, whole, for the seed and the ops.
    var prod_services = try f.client.listServices(location, .{});
    defer prod_services.deinit();
    var prod_revisions = try f.client.listRevisions(location, "-", .{});
    defer prod_revisions.deinit();
    var prod_dash = try f.client.listServices("-", .{});
    defer prod_dash.deinit();
    fact("production: {d} services, {d} revisions in {s}; '-' lists {d} services, {d} unreachable", .{
        prod_services.value.services.len,
        prod_revisions.value.revisions.len,
        location,
        prod_dash.value.services.len,
        prod_dash.value.unreachable_regions.len,
    });
    // Whether a deployed service appears in a '-' listing was milestone
    // 0's open question: answer it here.
    var ours_in_dash = false;
    for (prod_dash.value.services) |service| {
        if (std.mem.eql(u8, service.id, svc)) ours_in_dash = true;
    }
    fact("finding: the '-' location {s} the deployed service", .{if (ours_in_dash) "LISTS" else "does NOT list"});

    // The fake, seeded with everything production lists.
    var fake: run_mod.testing.FakeRun = .init(testing.allocator, testing.io, .{ .project_id = f.project });
    defer fake.deinit();
    try fake.putLocation(location);
    try fake.putLocation("us-east1");
    try fake.setUnreachable(prod_dash.value.unreachable_regions);
    var fake_diag: run_mod.Diagnostics = .{};
    var fake_token: core.StaticToken = .{ .token = "t" };
    var fake_client = try run_mod.Client.init(testing.allocator, testing.io, .{ .project_id = f.project, .token_provider = fake_token.provider(), .transport = fake.transport(), .diagnostics = &fake_diag });
    defer fake_client.deinit();
    try seed(&fake, &prod_services.value, &prod_revisions.value);
    fact("{d} services and {d} revisions seeded", .{ fake.serviceCount(), fake.revisionCount() });

    // Every read, production and the fake compared as text.
    const service_name = try a.print("projects/{s}/locations/{s}/services/{s}", .{ f.project, location, svc });
    const ready_revision = prod_revisions.value.revisions[prod_revisions.value.revisions.len - 1].id;
    const revision_name = try a.print("{s}/revisions/{s}", .{ service_name, ready_revision });
    var differences: usize = 0;
    const ops = [_]struct { []const u8, Op }{
        .{ "get service", .{ .get_service = svc } },
        .{ "get service by name", .{ .get_service_named = service_name } },
        .{ "get unknown service", .{ .get_service = "zigps-nobody" } },
        .{ "get revision by name", .{ .get_revision_named = revision_name } },
        .{ "list services", .{ .list_services = .{ .location = location } } },
        .{ "list services page of one", .{ .list_services = .{ .location = location, .options = .{ .page_size = 1 } } } },
        .{ "list revisions of the service", .{ .list_revisions = .{ .service = svc } } },
        .{ "list revisions of services/-", .{ .list_revisions = .{ .service = "-" } } },
        .{ "list revisions page of one", .{ .list_revisions = .{ .service = "-", .options = .{ .page_size = 1 } } } },
        .{ "revisions of an unknown service", .{ .list_revisions = .{ .service = "zigps-nobody" } } },
        .{ "list in a location that is no region", .{ .list_services = .{ .location = "us-fake1" } } },
    };
    for (ops) |op| {
        const in_production = try outcome(a, &f.client, &f.diag, op[1]);
        const in_memory = try outcome(a, &fake_client, &fake_diag, op[1]);
        agree(&differences, op[0], in_production, in_memory);
    }

    // The '-' location, comparable only when ours is the only service
    // anywhere (the fake holds just what the suite seeded).
    if (ours_in_dash and prod_dash.value.services.len == prod_services.value.services.len) {
        const in_production = try outcome(a, &f.client, &f.diag, .{ .list_services = .{ .location = "-" } });
        const in_memory = try outcome(a, &fake_client, &fake_diag, .{ .list_services = .{ .location = "-" } });
        agree(&differences, "list services everywhere", in_production, in_memory);
    }

    try testing.expectEqual(0, differences);
}

// The writes (issue #272).

const job_image = "us-docker.pkg.dev/cloudrun/container/job";

/// Records every request sent through it, then sends it on: what the
/// suite holds each write's preview to.
const Recorder = struct {
    inner: core.transport.Transport,
    sent: std.ArrayList(Sent) = .empty,
    arena: std.heap.ArenaAllocator,

    const Sent = struct { method: core.transport.Method, url: []const u8, body: []const u8 };

    fn transport(r: *Recorder) core.transport.Transport {
        return .{ .ptr = r, .vtable = &.{ .send = send } };
    }

    fn send(ptr: *anyopaque, req: core.transport.Request, arena: Allocator) core.transport.Error!core.transport.Response {
        const r: *Recorder = @ptrCast(@alignCast(ptr));
        const a = r.arena.allocator();
        r.sent.append(a, .{
            .method = req.method,
            .url = a.dupe(u8, req.url) catch return error.OutOfMemory,
            .body = a.dupe(u8, req.body orelse "") catch return error.OutOfMemory,
        }) catch return error.OutOfMemory;
        return r.inner.send(req, arena);
    }

    fn last(r: *const Recorder) Sent {
        return r.sent.items[r.sent.items.len - 1];
    }
};

/// Makes a job raw, labelled for the sweep: the client has no verb for it.
fn makeJob(f: *Fixture, a: Allocator, id: []const u8, env: []const u8) !void {
    const path = try a.print("/v2/projects/{s}/locations/{s}/jobs?jobId={s}", .{ f.project, location, id });
    const body = try a.print(
        \\{{"labels":{{"zigps":"suite"}},"template":{{"taskCount":1,"template":{{"maxRetries":0,"timeout":"900s","containers":[{{"image":"{s}","env":[{s}]}}]}}}}}}
    , .{ job_image, env });
    const res = try f.raw(a, .POST, path, body);
    if (res.status != 200) std.debug.print("making job {s}: HTTP {d} {s}\n", .{ id, res.status, res.body });
    try testing.expectEqual(200, res.status);
    try testing.expect(try f.awaitOperation(a, res.body, 120));
}

/// Deletes a job raw, trying a 503 again (probe 3 met one), after
/// cancelling whatever of it still runs.
fn deleteJob(f: *Fixture, a: Allocator, id: []const u8) !void {
    if (f.client.listExecutions(location, id, .{})) |page| {
        var p = page;
        defer p.deinit();
        for (p.value.executions) |execution| {
            if (!execution.cancellable()) continue;
            var cancel = f.client.cancelExecution(location, id, execution.id) catch continue;
            cancel.deinit();
        }
    } else |_| {}
    const path = try a.print("/v2/projects/{s}/locations/{s}/jobs/{s}", .{ f.project, location, id });
    for (0..5) |_| {
        const res = try f.raw(a, .DELETE, path, null);
        if (res.status == 200) {
            _ = try f.awaitOperation(a, res.body, 120);
            fact("delete job {s}: HTTP 200", .{id});
            return;
        }
        if (res.status == 404) return;
        fact("delete job {s}: HTTP {d}, trying again", .{ id, res.status });
        try testing.io.sleep(.fromMilliseconds(10_000), .awake);
    }
}

fn sweepJobs(f: *Fixture, a: Allocator) !void {
    var page = f.client.listJobs(location, .{}) catch |err| {
        fact("sweep: listing jobs failed: {t}", .{err});
        return;
    };
    defer page.deinit();
    for (page.value.jobs) |job| {
        if (std.mem.startsWith(u8, job.id, "zigps-")) try deleteJob(f, a, job.id);
    }
}

/// Reads the execution every 5 s until `until` says, within the budget;
/// its status at the end.
fn awaitExecution(client: *run_mod.Client, name: []const u8, budget_s: i64, until: *const fn (run_mod.ExecutionStatus) bool) !run_mod.ExecutionStatus {
    const started = std.Io.Clock.real.now(testing.io).nanoseconds;
    while (true) {
        var read = try client.getExecutionNamed(name);
        const status = read.value.status();
        read.deinit();
        if (until(status)) return status;
        if (std.Io.Clock.real.now(testing.io).nanoseconds - started > @as(i96, budget_s) * std.time.ns_per_s) return status;
        try testing.io.sleep(.fromMilliseconds(5_000), .awake);
    }
}

fn ended(status: run_mod.ExecutionStatus) bool {
    return status.ended();
}

fn runningOrEnded(status: run_mod.ExecutionStatus) bool {
    return status == .running or status.ended();
}

/// Reads the operation every 2 s until it is done, within the budget.
fn awaitDone(client: *run_mod.Client, name: []const u8, budget_s: i64) !run_mod.Owned(run_mod.Operation) {
    const started = std.Io.Clock.real.now(testing.io).nanoseconds;
    while (true) {
        var read = try client.getOperation(name);
        if (read.value.done or std.Io.Clock.real.now(testing.io).nanoseconds - started > @as(i96, budget_s) * std.time.ns_per_s) return read;
        read.deinit();
        try testing.io.sleep(.fromMilliseconds(2_000), .awake);
    }
}

/// A preview, held byte for byte to the request its write last sent.
fn holdPreview(recorder: *const Recorder, preview: run_mod.Owned(run_mod.PreparedRequest), label: []const u8) !void {
    var p = preview;
    defer p.deinit();
    const sent = recorder.last();
    try testing.expectEqual(sent.method, p.value.method);
    try testing.expectEqualStrings(sent.url, p.value.url);
    try testing.expectEqualStrings(sent.body, p.value.body);
    fact("preview of {s} is what was sent: {t} {s}", .{ label, p.value.method, p.value.url });
}

/// `text` with each id replaced by the role it plays, so production's and
/// the fake's compare. The newest first: the service's id begins every
/// job's and execution's.
fn withRoles(a: Allocator, text: []const u8, ids: []const [2][]const u8) ![]const u8 {
    var out = text;
    var i = ids.len;
    while (i > 0) {
        i -= 1;
        out = try std.mem.replaceOwned(u8, a, out, ids[i][0], ids[i][1]);
    }
    return out;
}

/// Text that names an error and its words, the ids in it replaced by the
/// role each plays.
fn refusal(a: Allocator, err: anyerror, diag: *const run_mod.Diagnostics, ids: []const [2][]const u8) ![]const u8 {
    var text = try withRoles(a, try a.print("error.{t}: {s}", .{ err, diag.message() }), ids);
    // The versions in a stale etag's refusal are production's times and
    // the fake's counters: only their places compare.
    if (std.mem.indexOf(u8, text, "version '")) |at| text = text[0 .. at + "version '".len];
    return text;
}

/// The script, run the same on production and on the fake. `settle`
/// brings an execution to a status production reaches on its own: by
/// waiting in production, where each status reached is kept, and by
/// moving the fake's execution to the one production reached at the same
/// step. A cancel that meets a task's start ends failed in production
/// (measured), so the fake replays what production did, not a guess.
const Script = struct {
    client: *run_mod.Client,
    diag: *run_mod.Diagnostics,
    /// The fake, or null in production.
    fake: ?*run_mod.testing.FakeRun,
    svc: []const u8,
    jobs: [3][]const u8,
    lines: std.ArrayList([]const u8) = .empty,
    ids: std.ArrayList([2][]const u8) = .empty,
    /// In production, each status `settle` reached, in order.
    outcomes: std.ArrayList(run_mod.ExecutionStatus) = .empty,
    /// In the fake, production's outcomes to replay, and the next one.
    replay: []const run_mod.ExecutionStatus = &.{},
    next: usize = 0,

    fn line(s: *Script, a: Allocator, comptime format: []const u8, args: anytype) !void {
        try s.lines.append(a, try withRoles(a, try a.print(format, args), s.ids.items));
    }

    /// Waits for, or moves the fake's execution to, a status production
    /// reaches on its own.
    fn settle(s: *Script, a: Allocator, name: []const u8, wanted: *const fn (run_mod.ExecutionStatus) bool, budget_s: i64) !run_mod.ExecutionStatus {
        if (s.fake) |fake| {
            const target = s.replay[s.next];
            s.next += 1;
            if (fake.executionStatus(name).? != target) try fake.setExecutionStatus(name, target);
            return fake.executionStatus(name).?;
        }
        const status = try awaitExecution(s.client, name, budget_s, wanted);
        try s.outcomes.append(a, status);
        return status;
    }

    fn run(s: *Script, a: Allocator, recorder: ?*Recorder) !void {
        const c = s.client;
        const quick, const slow, const failing = s.jobs;
        // Three runs at once, as production took two of one job at once.
        var runs: [4]run_mod.Owned(run_mod.Operation) = undefined;
        var made: usize = 0;
        defer for (runs[0..made]) |*r| r.deinit();
        const roles = [_]struct { []const u8, []const u8 }{ .{ quick, "<quick>" }, .{ failing, "<failing>" }, .{ slow, "<slow-a>" }, .{ slow, "<slow-b>" } };
        for (roles) |role| {
            runs[made] = try c.runJob(location, role[0]);
            made += 1;
            const execution = runs[made - 1].value.subject.execution;
            try s.ids.append(a, .{ try a.dupe(u8, execution.id), role[1] });
            if (recorder) |r| try holdPreview(r, try c.runJobRequest(location, role[0]), "a run");
            try s.line(a, "run {s}: done={} status={t}", .{ role[1], runs[made - 1].value.done, execution.status() });
        }
        const quick_name = runs[0].value.subject.execution.name;
        const failing_name = runs[1].value.subject.execution.name;
        const slow_a = runs[2].value.subject.execution;
        const slow_b_name = runs[3].value.subject.execution.name;

        // Cancelled while pending: ended at once, without a completion
        // time, as probe 4 measured.
        {
            var cancel = try c.cancelExecution(location, slow, slow_a.id);
            defer cancel.deinit();
            if (recorder) |r| try holdPreview(r, try c.cancelExecutionRequest(location, slow, slow_a.id), "a cancel");
            const status = try s.settle(a, slow_a.name, ended, 30);
            var read = try c.getExecutionNamed(slow_a.name);
            defer read.deinit();
            try s.line(a, "cancel <slow-a> while pending: then {t}, completion time {s}", .{ status, if (read.value.completion_time == null) "none" else "set" });
        }

        // The quick one succeeds and the failing one fails; their
        // operations say so.
        for ([_]struct { []const u8, usize, []const u8 }{ .{ quick_name, 0, "<quick>" }, .{ failing_name, 1, "<failing>" } }) |each| {
            const status = try s.settle(a, each[0], ended, 300);
            var op = try c.getOperation(runs[each[1]].value.name);
            defer op.deinit();
            try s.line(a, "{s} ends {t}: operation done={} failure={?d}", .{ each[2], status, op.value.done, if (op.value.failure) |x| x.code else null });
        }

        // The second slow one, cancelled once running: cancelling, then
        // cancelled; a cancel after it ended is refused.
        {
            const running = try s.settle(a, slow_b_name, runningOrEnded, 300);
            const id = slow_b_name[std.mem.lastIndexOfScalar(u8, slow_b_name, '/').? + 1 ..];
            var cancel = try c.cancelExecution(location, slow, id);
            defer cancel.deinit();
            const status = try s.settle(a, slow_b_name, ended, 120);
            var op = try awaitDone(c, cancel.value.name, 60);
            defer op.deinit();
            try s.line(a, "cancel <slow-b> while {t}: then {t}, operation done={} failure={?d}", .{ running, status, op.value.done, if (op.value.failure) |x| x.code else null });
            if (c.cancelExecution(location, slow, id)) |again| {
                var x = again;
                x.deinit();
                try s.line(a, "cancel <slow-b> again: TAKEN", .{});
            } else |err| try s.line(a, "cancel <slow-b> again: {s}", .{try refusal(a, err, s.diag, s.ids.items)});
            if (c.cancelExecution(location, slow, "zigps-x-nobody")) |nobody| {
                var x = nobody;
                x.deinit();
            } else |err| try s.line(a, "cancel nobody's: {s}", .{try refusal(a, err, s.diag, s.ids.items)});
        }

        var every = try c.listExecutions(location, "-", .{});
        defer every.deinit();
        try s.line(a, "executions of every job: {d}", .{every.value.executions.len});

        // Traffic: checked, sent, refused when stale, and the same again.
        var read = try c.getService(location, s.svc);
        defer read.deinit();
        const etag = try a.dupe(u8, read.value.etag);
        const rev1 = try a.print("{s}-00001", .{s.svc});
        var first: []const u8 = "";
        var revisions = try c.listRevisions(location, s.svc, .{});
        defer revisions.deinit();
        for (revisions.value.revisions) |r| if (std.mem.startsWith(u8, r.id, rev1)) {
            first = try a.dupe(u8, r.id);
        };
        try s.ids.append(a, .{ first, "<rev1>" });
        {
            var check = try c.routeAllTraffic(location, s.svc, first, .{ .etag = etag, .validate_only = true });
            defer check.deinit();
            if (recorder) |r| try holdPreview(r, try c.routeAllTrafficRequest(location, s.svc, first, .{ .etag = etag, .validate_only = true }), "a checked traffic change");
            var after = try c.getService(location, s.svc);
            defer after.deinit();
            try s.line(a, "validate <rev1>: done={} asked={s}; etag kept={} traffic={t}", .{ check.value.done, check.value.subject.service.traffic[0].revision, std.mem.eql(u8, after.value.etag, etag), after.value.traffic[0].type });
        }
        {
            var change = try c.routeAllTraffic(location, s.svc, first, .{ .etag = etag });
            defer change.deinit();
            if (recorder) |r| try holdPreview(r, try c.routeAllTrafficRequest(location, s.svc, first, .{ .etag = etag }), "a traffic change");
            var op = try awaitDone(c, change.value.name, 60);
            defer op.deinit();
            const service = op.value.subject.service;
            try s.line(a, "route <rev1>: first answer done={}; then done={} failure={?d} traffic={s} statuses={s} generation+{d} labels={d}", .{
                change.value.done,           op.value.done,                        if (op.value.failure) |x| x.code else null,
                service.traffic[0].revision, service.traffic_statuses[0].revision, (service.generation orelse 0) - (read.value.generation orelse 0),
                service.labels.len,
            });
        }
        if (c.routeAllTraffic(location, s.svc, try a.print("{s}-00002", .{s.svc}), .{ .etag = etag })) |stale| {
            var x = stale;
            x.deinit();
            try s.line(a, "route with the stale etag: TAKEN", .{});
        } else |err| try s.line(a, "route with the stale etag: {s}", .{try refusal(a, err, s.diag, s.ids.items)});
        if (c.routeAllTraffic(location, s.svc, first, .{ .etag = etag })) |same| {
            var x = same;
            x.deinit();
            var after = try c.getService(location, s.svc);
            defer after.deinit();
            var before = try c.getService(location, s.svc);
            defer before.deinit();
            try s.line(a, "route <rev1> again with the stale etag: taken, generation {s}", .{if (after.value.generation == before.value.generation) "kept" else "MOVED"});
        } else |err| try s.line(a, "route <rev1> again with the stale etag: {s}", .{try refusal(a, err, s.diag, s.ids.items)});
        if (c.routeAllTraffic(location, s.svc, "zigps-other-00001-abc", .{ .etag = etag })) |other| {
            var x = other;
            x.deinit();
            try s.line(a, "route to another service's revision: TAKEN", .{});
        } else |err| try s.line(a, "route to another service's revision: {s}", .{try refusal(a, err, s.diag, s.ids.items)});
        {
            var fresh = try c.getService(location, s.svc);
            defer fresh.deinit();
            const missing = try a.print("{s}-00009-zzz", .{s.svc});
            var change = try c.routeAllTraffic(location, s.svc, missing, .{ .etag = fresh.value.etag });
            defer change.deinit();
            var op = try awaitDone(c, change.value.name, 60);
            defer op.deinit();
            var after = try c.getService(location, s.svc);
            defer after.deinit();
            try s.line(a, "route to a revision it lacks: done={} failure={?d} \"{s}\"; service ready={} traffic={s}", .{
                op.value.done,       if (op.value.failure) |x| x.code else null, if (op.value.failure) |x| x.message else "",
                after.value.ready(), after.value.traffic[0].revision,
            });
        }
    }
};

test "run writes: real runs, cancels and a traffic change, the fake replaying them alike" {
    var f: Fixture = undefined;
    if (!try f.init("RUN_WRITES_TEST", .read_write)) return error.SkipZigTest;
    defer f.deinit();
    const a = f.arena.allocator();
    try sweepJobs(&f, a);
    try sweep(&f, a);

    // A read-only client refuses every write before sending.
    {
        var token: core.StaticToken = .{ .token = f.token.token };
        var diag: run_mod.Diagnostics = .{};
        var read_only = try run_mod.Client.init(testing.allocator, testing.io, .{ .project_id = f.project, .token_provider = token.provider(), .diagnostics = &diag });
        defer read_only.deinit();
        try testing.expectError(error.InvalidOptions, read_only.runJob(location, "zigps-nobody"));
        fact("a read-only client refuses a run before sending: {s}", .{diag.message()});
    }

    const jobs = [3][]const u8{ try a.print("zigps-{s}-quick", .{f.run}), try a.print("zigps-{s}-slow", .{f.run}), try a.print("zigps-{s}-fail", .{f.run}) };
    const svc = try a.print("zigps-{s}", .{f.run});
    var made_jobs: usize = 0;
    var deployed = false;
    defer {
        var cleanup: std.heap.ArenaAllocator = .init(testing.allocator);
        for (jobs[0..made_jobs]) |id| deleteJob(&f, cleanup.allocator(), id) catch |err| fact("cleanup of {s} failed: {t}", .{ id, err });
        if (deployed) f.deleteService(cleanup.allocator(), svc) catch |err| fact("cleanup failed: {t}", .{err});
        cleanup.deinit();
    }
    for (jobs, [_][]const u8{
        \\{"name":"SLEEP_MS","value":"1000"}
        ,
        \\{"name":"SLEEP_MS","value":"600000"}
        ,
        \\{"name":"FAIL_RATE","value":"1"}
    }) |id, env| {
        try makeJob(&f, a, id, env);
        made_jobs += 1;
    }
    {
        const path = try a.print("/v2/projects/{s}/locations/{s}/services?serviceId={s}", .{ f.project, location, svc });
        const res = try f.raw(a, .POST, path, try a.print(
            \\{{"template":{{"containers":[{{"image":"{s}","env":[{{"name":"ZIGPS","value":"1"}}]}}]}},"labels":{{"zigps":"suite"}}}}
        , .{hello}));
        try testing.expectEqual(200, res.status);
        deployed = true;
        try testing.expect(try f.awaitOperation(a, res.body, 300));
        const patch = try f.raw(a, .PATCH, try a.print("/v2/projects/{s}/locations/{s}/services/{s}", .{ f.project, location, svc }), try a.print(
            \\{{"template":{{"containers":[{{"image":"{s}","env":[{{"name":"ZIGPS","value":"2"}}]}}]}},"labels":{{"zigps":"suite"}}}}
        , .{hello}));
        try testing.expectEqual(200, patch.status);
        try testing.expect(try f.awaitOperation(a, patch.body, 300));
        fact("made {s}, {s} and {s}, and {s} with two revisions", .{ jobs[0], jobs[1], jobs[2], svc });
    }

    // Production's state before the script, for the fake's seed.
    var prod_jobs = try f.client.listJobs(location, .{});
    defer prod_jobs.deinit();
    var prod_service = try f.client.getService(location, svc);
    defer prod_service.deinit();
    var prod_revisions = try f.client.listRevisions(location, svc, .{});
    defer prod_revisions.deinit();

    // The script against production, through a client that records what
    // it sends, so every preview is held to it.
    var http: core.transport.HttpTransport = .init(testing.allocator, testing.io, "zig-gcp-run-gcp-integration/0.1");
    defer http.deinit();
    var recorder: Recorder = .{ .inner = http.transport(), .arena = .init(testing.allocator) };
    defer recorder.arena.deinit();
    var recorded_diag: run_mod.Diagnostics = .{};
    var recorded = try run_mod.Client.init(testing.allocator, testing.io, .{ .project_id = f.project, .token_provider = f.token.provider(), .scope = .read_write, .transport = recorder.transport(), .diagnostics = &recorded_diag });
    defer recorded.deinit();
    var in_production: Script = .{ .client = &recorded, .diag = &recorded_diag, .fake = null, .svc = svc, .jobs = jobs };
    try in_production.ids.append(a, .{ svc, "<svc>" });
    try in_production.run(a, &recorder);

    // The same script on a fake seeded from production's reads.
    var fake: run_mod.testing.FakeRun = .init(testing.allocator, testing.io, .{ .project_id = f.project });
    defer fake.deinit();
    try fake.putLocation(location);
    for (prod_jobs.value.jobs) |job| {
        if (!std.mem.startsWith(u8, job.id, "zigps-")) continue;
        _ = try fake.putJob(.{
            .location = job.location,
            .id = job.id,
            .task_count = job.task_count,
            .parallelism = job.parallelism,
            .task_timeout_s = job.task_timeout_s,
            .max_retries = job.max_retries,
            .containers = job.containers,
            .service_account = job.service_account,
            .labels = job.labels,
            .create_time = job.create_time,
            .update_time = job.update_time,
            .terminal_condition = job.terminal_condition,
        });
    }
    const service = prod_service.value;
    _ = try fake.putService(.{
        .location = service.location,
        .id = service.id,
        .uri = service.uri,
        .urls = service.urls,
        .latest_ready_revision = service.latest_ready_revision,
        .latest_created_revision = service.latest_created_revision,
        .traffic = service.traffic,
        .traffic_statuses = service.traffic_statuses,
        .terminal_condition = service.terminal_condition,
        .conditions = service.conditions,
        .create_time = service.create_time,
        .update_time = service.update_time,
        .generation = service.generation,
        .observed_generation = service.observed_generation,
        .labels = service.labels,
    });
    for (prod_revisions.value.revisions) |revision| {
        _ = try fake.putRevision(.{
            .location = revision.location,
            .service = revision.service,
            .id = revision.id,
            .create_time = revision.create_time,
            .generation = revision.generation,
            .containers = revision.containers,
            .conditions = revision.conditions,
        });
    }
    var fake_token: core.StaticToken = .{ .token = "t" };
    var fake_diag: run_mod.Diagnostics = .{};
    var fake_client = try run_mod.Client.init(testing.allocator, testing.io, .{ .project_id = f.project, .token_provider = fake_token.provider(), .scope = .read_write, .transport = fake.transport(), .diagnostics = &fake_diag });
    defer fake_client.deinit();
    var in_memory: Script = .{ .client = &fake_client, .diag = &fake_diag, .fake = &fake, .svc = svc, .jobs = jobs, .replay = in_production.outcomes.items };
    try in_memory.ids.append(a, .{ svc, "<svc>" });
    try in_memory.run(a, null);

    var differences: usize = 0;
    try testing.expectEqual(in_production.lines.items.len, in_memory.lines.items.len);
    for (in_production.lines.items, in_memory.lines.items, 0..) |p, m, i| {
        agree(&differences, try a.print("step {d}", .{i}), p, m);
    }
    try testing.expectEqual(0, differences);
}

/// A secret raw beside the client, for the settings to name; the
/// runtime account is never granted it, so the revisions that read it
/// fail to start and their settings are read all the same.
fn secretCall(f: *Fixture, a: Allocator, method: core.transport.Method, path: []const u8, body: ?[]const u8) !core.transport.Response {
    const url = try a.print("https://secretmanager.googleapis.com/v1/projects/{s}/secrets{s}", .{ f.project, path });
    return f.client.transport.send(.{ .method = method, .url = url, .bearer = f.token.token, .body = body, .timeout_ms = 60_000 }, a);
}

fn settingsLine(a: Allocator, settings: run_mod.RevisionTemplate) ![]const u8 {
    return std.json.Stringify.valueAlloc(a, settings, .{});
}

fn revisionSettings(r: run_mod.Revision) run_mod.RevisionTemplate {
    return .{
        .containers = r.containers,
        .volumes = r.volumes,
        .service_account = r.service_account,
        .min_instances = r.min_instances,
        .max_instances = r.max_instances,
        .concurrency = r.concurrency,
        .timeout_s = r.timeout_s,
        .execution_environment = r.execution_environment,
        .vpc_access = r.vpc_access,
        .session_affinity = r.session_affinity,
        .encryption_key = r.encryption_key,
    };
}

test "run settings: services, revisions and a job deployed with every setting, the fake answering alike" {
    var f: Fixture = undefined;
    if (!try f.init("RUN_SETTINGS_TEST", .cloud_platform)) return error.SkipZigTest;
    defer f.deinit();
    const a = f.arena.allocator();
    try sweepJobs(&f, a);
    try sweep(&f, a);

    const secret = try a.print("zigps-{s}", .{f.run});
    const full_id = try a.print("zigps-{s}-full", .{f.run});
    const plain_id = try a.print("zigps-{s}-plain", .{f.run});
    const job_id = try a.print("zigps-{s}-job", .{f.run});
    var made_secret = false;
    var made: [2]bool = .{ false, false };
    var made_job = false;
    defer {
        var cleanup: std.heap.ArenaAllocator = .init(testing.allocator);
        const ca = cleanup.allocator();
        for ([_][]const u8{ full_id, plain_id }, made) |id, was| if (was) f.deleteService(ca, id) catch |err| fact("cleanup of {s} failed: {t}", .{ id, err });
        if (made_job) deleteJob(&f, ca, job_id) catch |err| fact("cleanup of {s} failed: {t}", .{ job_id, err });
        if (made_secret) if (secretCall(&f, ca, .DELETE, std.fmt.allocPrint(ca, "/{s}", .{secret}) catch "", null)) |res| fact("delete secret {s}: HTTP {d}", .{ secret, res.status }) else |err| fact("delete secret: {t}", .{err});
        cleanup.deinit();
    }

    const made_s = try secretCall(&f, a, .POST, try a.print("?secretId={s}", .{secret}), "{\"replication\":{\"automatic\":{}}}");
    try testing.expectEqual(200, made_s.status);
    made_secret = true;
    const version = try secretCall(&f, a, .POST, try a.print("/{s}:addVersion", .{secret}), "{\"payload\":{\"data\":\"emlncHM=\"}}");
    try testing.expectEqual(200, version.status);

    const base = try a.print("/v2/projects/{s}/locations/{s}", .{ f.project, location });
    {
        const res = try f.raw(a, .POST, try a.print("{s}/services?serviceId={s}", .{ base, full_id }), try a.print(
            \\{{"labels":{{"zigps":"suite"}},"ingress":"INGRESS_TRAFFIC_INTERNAL_LOAD_BALANCER","defaultUriDisabled":true,
            \\"scaling":{{"maxInstanceCount":5,"scalingMode":"AUTOMATIC"}},"template":{{
            \\"containers":[{{"image":"{s}","env":[{{"name":"PLAIN","value":"hello"}},{{"name":"EMPTY","value":""}},
            \\{{"name":"FROM_SECRET","valueSource":{{"secretKeyRef":{{"secret":"{s}","version":"latest"}}}}}}],
            \\"resources":{{"limits":{{"cpu":"2","memory":"1Gi"}},"startupCpuBoost":true}},
            \\"ports":[{{"name":"http1","containerPort":8080}}],
            \\"volumeMounts":[{{"name":"sec","mountPath":"/secrets"}},{{"name":"scratch","mountPath":"/scratch"}}]}}],
            \\"volumes":[{{"name":"sec","secret":{{"secret":"{s}","items":[{{"version":"latest","path":"value"}}],"defaultMode":292}}}},
            \\{{"name":"scratch","emptyDir":{{"medium":"MEMORY","sizeLimit":"64Mi"}}}}],
            \\"scaling":{{"maxInstanceCount":3}},"maxInstanceRequestConcurrency":40,"timeout":"120s",
            \\"executionEnvironment":"EXECUTION_ENVIRONMENT_GEN2","sessionAffinity":true,
            \\"vpcAccess":{{"networkInterfaces":[{{"network":"default","subnetwork":"default","tags":["zigps"]}}],"egress":"PRIVATE_RANGES_ONLY"}}}}}}
        , .{ hello, secret, secret }));
        try testing.expectEqual(200, res.status);
        made[0] = true;
        _ = try f.awaitOperation(a, res.body, 300);
    }
    {
        const res = try f.raw(a, .POST, try a.print("{s}/services?serviceId={s}", .{ base, plain_id }), try a.print(
            \\{{"labels":{{"zigps":"suite"}},"template":{{"containers":[{{"image":"{s}"}}]}}}}
        , .{hello}));
        try testing.expectEqual(200, res.status);
        made[1] = true;
        try testing.expect(try f.awaitOperation(a, res.body, 300));
    }
    {
        const res = try f.raw(a, .POST, try a.print("{s}/jobs?jobId={s}", .{ base, job_id }), try a.print(
            \\{{"labels":{{"zigps":"suite"}},"template":{{"taskCount":1,"template":{{"maxRetries":0,
            \\"containers":[{{"image":"us-docker.pkg.dev/cloudrun/container/job","command":["/bin/sh","-c"],"args":["echo hi"],"workingDir":"/tmp",
            \\"env":[{{"name":"PLAIN","value":"x"}},{{"name":"FROM_SECRET","valueSource":{{"secretKeyRef":{{"secret":"{s}","version":"1"}}}}}}],
            \\"resources":{{"limits":{{"cpu":"1","memory":"512Mi"}}}},"volumeMounts":[{{"name":"scratch","mountPath":"/scratch"}}]}}],
            \\"volumes":[{{"name":"scratch","emptyDir":{{"medium":"MEMORY"}}}}],
            \\"vpcAccess":{{"networkInterfaces":[{{"network":"default","subnetwork":"default"}}],"egress":"ALL_TRAFFIC"}}}}}}}}
        , .{secret}));
        try testing.expectEqual(200, res.status);
        made_job = true;
        try testing.expect(try f.awaitOperation(a, res.body, 300));
    }
    fact("made {s}, {s} and {s}, beside secret {s}", .{ full_id, plain_id, job_id, secret });

    // Production, through the client.
    var full = try f.client.getService(location, full_id);
    defer full.deinit();
    var plain = try f.client.getService(location, plain_id);
    defer plain.deinit();
    var full_revs = try f.client.listRevisions(location, full_id, .{});
    defer full_revs.deinit();
    var plain_revs = try f.client.listRevisions(location, plain_id, .{});
    defer plain_revs.deinit();
    var job = try f.client.getJob(location, job_id);
    defer job.deinit();
    try testing.expect(full.value.template != null and plain.value.template != null);
    try testing.expect(full_revs.value.revisions.len == 1 and plain_revs.value.revisions.len == 1);
    fact("full: terminal {s} ({s}); plain: ready={}", .{ if (full.value.terminal_condition) |c| c.reason else "none", if (full.value.ready()) "ready" else "not ready", plain.value.ready() });

    // The fake: the full service and revision seeded with what production
    // answered; the plain ones with an image and an account alone, so its
    // defaults answer for production's.
    var clock: core.testing.FakeClock = .{};
    var fake: run_mod.testing.FakeRun = .init(testing.allocator, clock.io(), .{ .project_id = f.project });
    defer fake.deinit();
    try fake.putLocation(location);
    _ = try fake.putService(.{ .location = location, .id = full_id, .template = full.value.template, .ingress = full.value.ingress, .default_uri_disabled = full.value.default_uri_disabled, .scaling = full.value.scaling });
    const pt = plain.value.template.?;
    _ = try fake.putService(.{ .location = location, .id = plain_id, .template = .{ .containers = &.{.{ .image = pt.containers[0].image }}, .service_account = pt.service_account } });
    const fr = full_revs.value.revisions[0];
    const fs = revisionSettings(fr);
    _ = try fake.putRevision(.{ .location = location, .service = full_id, .id = fr.id, .containers = fs.containers, .volumes = fs.volumes, .service_account = fs.service_account, .min_instances = fs.min_instances, .max_instances = fs.max_instances, .concurrency = fs.concurrency, .timeout_s = fs.timeout_s, .execution_environment = fs.execution_environment, .vpc_access = fs.vpc_access, .session_affinity = fs.session_affinity, .encryption_key = fs.encryption_key });
    const pr = plain_revs.value.revisions[0];
    _ = try fake.putRevision(.{ .location = location, .service = plain_id, .id = pr.id, .containers = &.{.{ .image = pr.containers[0].image }}, .service_account = pr.service_account });
    _ = try fake.putJob(.{ .location = location, .id = job_id, .containers = job.value.containers, .service_account = job.value.service_account, .volumes = job.value.volumes, .vpc_access = job.value.vpc_access, .max_retries = job.value.max_retries, .task_timeout_s = job.value.task_timeout_s });
    var fake_token: core.StaticToken = .{ .token = "t" };
    var in_memory = try run_mod.Client.init(testing.allocator, clock.io(), .{ .project_id = f.project, .token_provider = fake_token.provider(), .transport = fake.transport() });
    defer in_memory.deinit();

    var differences: usize = 0;
    var fake_full = try in_memory.getService(location, full_id);
    defer fake_full.deinit();
    var fake_plain = try in_memory.getService(location, plain_id);
    defer fake_plain.deinit();
    var fake_fr = try in_memory.getRevision(location, full_id, fr.id);
    defer fake_fr.deinit();
    var fake_pr = try in_memory.getRevision(location, plain_id, pr.id);
    defer fake_pr.deinit();
    var fake_job = try in_memory.getJob(location, job_id);
    defer fake_job.deinit();
    const job_line = struct {
        fn line(al: Allocator, j: run_mod.Job) ![]const u8 {
            return std.json.Stringify.valueAlloc(al, .{ .containers = j.containers, .volumes = j.volumes, .vpc_access = j.vpc_access, .execution_environment = j.execution_environment, .timeout = j.task_timeout_s }, .{});
        }
    }.line;
    const service_line = struct {
        fn line(al: Allocator, s: run_mod.Service) ![]const u8 {
            return std.json.Stringify.valueAlloc(al, .{ .ingress = s.ingress, .scaling = s.scaling, .default_uri_disabled = s.default_uri_disabled, .uri = s.uri, .urls = s.urls.len }, .{});
        }
    }.line;
    agree(&differences, "full service's template", try settingsLine(a, full.value.template.?), try settingsLine(a, fake_full.value.template.?));
    agree(&differences, "full service", try service_line(a, full.value), try service_line(a, fake_full.value));
    agree(&differences, "plain service's template, the fake's defaults", try settingsLine(a, plain.value.template.?), try settingsLine(a, fake_plain.value.template.?));
    agree(&differences, "plain service's scaling and ingress", try std.json.Stringify.valueAlloc(a, .{ plain.value.scaling, plain.value.ingress }, .{}), try std.json.Stringify.valueAlloc(a, .{ fake_plain.value.scaling, fake_plain.value.ingress }, .{}));
    agree(&differences, "full revision", try settingsLine(a, fs), try settingsLine(a, revisionSettings(fake_fr.value)));
    agree(&differences, "plain revision, the fake's defaults and name", try settingsLine(a, revisionSettings(pr)), try settingsLine(a, revisionSettings(fake_pr.value)));
    agree(&differences, "job's task template", try job_line(a, job.value), try job_line(a, fake_job.value));
    try testing.expectEqual(0, differences);
}
