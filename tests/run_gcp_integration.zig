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

    fn init(f: *Fixture) !bool {
        const gpa = testing.allocator;
        f.env = try testing.environ.createMap(gpa);
        errdefer f.env.deinit();
        f.project = f.env.get("GCP_TEST_PROJECT") orelse return f.skip();
        const token = f.env.get("GCP_TEST_TOKEN") orelse return f.skip();
        if (f.env.get("RUN_TEST") == null) return f.skip();
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
    if (!try f.init()) return error.SkipZigTest;
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
