//! The client's tests: requests as sent, refusals before sending, answers
//! and refusals as production gave them, the wait loop, and the client
//! over `FakeCompute`, held to production's words.

const std = @import("std");
const testing = std.testing;
const core = @import("core");

const Client = @import("Client.zig");
const types = @import("types.zig");
const test_util = @import("test_util.zig");
const production = @import("production_bodies.zig");
const FakeCompute = @import("fake_compute.zig").FakeCompute;
const Harness = test_util.Harness;

const base = "https://compute.googleapis.com/compute/v1/projects/my-project/";

fn reply(status: u16, body: []const u8) test_util.FakeTransport.Reply {
    return .{ .respond = .{ .status = status, .body = body } };
}

test "sibling: the same settings, a connection of its own, and diagnostics of its own" {
    var token: core.StaticToken = .{ .token = "ya29.t" };
    var diag: core.Diagnostics = .{};
    var client: Client = try .init(testing.allocator, testing.io, .{
        .project_id = "my-project",
        .token_provider = token.provider(),
        .scope = .read_write,
        .retry = .{ .max_attempts = 7 },
        .request_timeout_ms = 1234,
        .max_response_bytes = 4096,
        .send_quota_project = false,
        .user_agent = "gcp-zig-test/1",
        .diagnostics = &diag,
    });
    defer client.deinit();
    client.server_delay_ms = 5000;
    var sibling_diag: core.Diagnostics = .{};
    var s = try client.sibling(&sibling_diag);
    defer s.deinit();
    // A built-in transport is never shared: one per task, with the same
    // limit on an answer's size.
    try testing.expect(s.http != null and s.http != client.http);
    try testing.expect(s.transport.ptr != client.transport.ptr);
    try testing.expectEqual(4096, s.http.?.max_response_bytes);
    try testing.expectEqual(&sibling_diag, s.diagnostics.?);
    // Its own copies of the strings, equal to the original's.
    try testing.expect(s.base_url.ptr != client.base_url.ptr);
    try testing.expectEqualStrings(client.base_url, s.base_url);
    try testing.expect(s.project.ptr != client.project.ptr);
    try testing.expectEqualStrings("my-project", s.project);
    try testing.expect(s.user_agent.ptr != client.user_agent.ptr);
    try testing.expectEqualStrings("gcp-zig-test/1", s.user_agent);
    try testing.expectEqual(.read_write, s.scope);
    try testing.expectEqual(7, s.retry.max_attempts);
    try testing.expectEqual(1234, s.request_timeout_ms);
    try testing.expectEqual(4096, s.max_response_bytes);
    try testing.expect(!s.send_quota_project);
    try testing.expectEqual(client.token_provider.ptr, s.token_provider.ptr);
    // A delay the original's last refusal asked for is not the sibling's.
    try testing.expectEqual(null, s.server_delay_ms);
    try testing.expectEqual(5000, client.server_delay_ms);

    // A custom transport is shared, as documented.
    var h: Harness = undefined;
    try h.init(&.{});
    defer h.deinit();
    var shared = try h.client.sibling(null);
    defer shared.deinit();
    try testing.expectEqual(null, shared.http);
    try testing.expectEqual(h.client.transport.ptr, shared.transport.ptr);
    try testing.expectEqual(null, shared.diagnostics);
}

fn siblingOf(gpa: std.mem.Allocator) !void {
    var token: core.StaticToken = .{ .token = "ya29.t" };
    var client: Client = try .init(gpa, testing.io, .{
        .project_id = "my-project",
        .token_provider = token.provider(),
    });
    defer client.deinit();
    var s = try client.sibling(null);
    s.deinit();
}

test "sibling: every allocation failure is OutOfMemory without leaks" {
    try testing.checkAllAllocationFailures(testing.allocator, siblingOf, .{});
}

test "listInstances: the path and query as sent" {
    var h: Harness = undefined;
    try h.init(&.{reply(200, production.instance_list_empty)});
    defer h.deinit();
    var page = try h.client.listInstances("us-central1-a", .{ .filter = "labels.env = prod", .max_results = 50, .page_token = "Cg5h", .partial_success = true });
    defer page.deinit();
    try testing.expectEqual(0, page.value.instances.len);
    const sent = h.fake.requests.items[0];
    try testing.expectEqual(core.transport.Method.GET, sent.method);
    try testing.expectEqualStrings(base ++ "zones/us-central1-a/instances?filter=labels.env%20%3D%20prod&maxResults=50&pageToken=Cg5h&returnPartialSuccess=true", sent.url);
    try testing.expectEqualStrings("ya29.test-token", sent.bearer.?);
}

test "the reads' paths" {
    var h: Harness = undefined;
    try h.init(&.{
        reply(200, production.aggregated_two),
        reply(200, production.instance_spot),
        reply(200, production.serial_tail),
        reply(200, production.guest_attributes),
        reply(200, production.zone),
        reply(200, production.machine_type),
        reply(200, production.image),
        reply(200, production.image),
        reply(200, production.operation_done),
        reply(200, production.operation_list),
    });
    defer h.deinit();
    const c = &h.client;
    var all = try c.listAllInstances(.{ .partial_success = true });
    defer all.deinit();
    try testing.expectEqual(2, all.value.instances.len);
    var one = try c.getInstance("us-central1-a", "web-1");
    defer one.deinit();
    var serial = try c.serialOutput("us-central1-a", "web-1", .{ .start = 0 });
    defer serial.deinit();
    var ga = try c.guestAttributes("us-central1-a", "web-1", "zigps/");
    defer ga.deinit();
    var zone = try c.getZone("us-central1-a");
    defer zone.deinit();
    var mt = try c.getMachineType("us-central1-a", "e2-micro");
    defer mt.deinit();
    var img = try c.imageFromFamily("debian-cloud", "debian-12");
    defer img.deinit();
    var named = try c.getImage("debian-cloud", "debian-12-bookworm-v20261027");
    defer named.deinit();
    var op = try c.getOperation(.{ .name = "operation-1", .scope = .{ .zone = "us-central1-a" } });
    defer op.deinit();
    var ops = try c.listOperations(.{ .zone = "us-central1-a" }, .{ .filter = "targetLink eq .*/instances/web-1" });
    defer ops.deinit();

    const r = h.fake.requests.items;
    try testing.expectEqualStrings(base ++ "aggregated/instances?returnPartialSuccess=true", r[0].url);
    try testing.expectEqualStrings(base ++ "zones/us-central1-a/instances/web-1", r[1].url);
    try testing.expectEqualStrings(base ++ "zones/us-central1-a/instances/web-1/serialPort?port=1&start=0", r[2].url);
    try testing.expectEqualStrings(base ++ "zones/us-central1-a/instances/web-1/getGuestAttributes?queryPath=zigps%2F", r[3].url);
    try testing.expectEqualStrings(base ++ "zones/us-central1-a", r[4].url);
    try testing.expectEqualStrings(base ++ "zones/us-central1-a/machineTypes/e2-micro", r[5].url);
    try testing.expectEqualStrings("https://compute.googleapis.com/compute/v1/projects/debian-cloud/global/images/family/debian-12", r[6].url);
    try testing.expectEqualStrings("https://compute.googleapis.com/compute/v1/projects/debian-cloud/global/images/debian-12-bookworm-v20261027", r[7].url);
    try testing.expectEqualStrings(base ++ "zones/us-central1-a/operations/operation-1", r[8].url);
    try testing.expectEqualStrings(base ++ "zones/us-central1-a/operations?filter=targetLink%20eq%20.%2A%2Finstances%2Fweb-1", r[9].url);
    for (r) |req| try testing.expectEqual(core.transport.Method.GET, req.method);
}

test "refused before sending: names, zones, lists, ports, paths" {
    var h: Harness = undefined;
    try h.init(&.{});
    defer h.deinit();
    const c = &h.client;
    try testing.expectError(error.InvalidName, c.getInstance("US-central1", "web-1"));
    try testing.expectError(error.InvalidName, c.getInstance("us-central1-a", "Bad_Name"));
    try testing.expectError(error.InvalidName, c.getInstance("us-central1-a", "web-1/x"));
    try testing.expectError(error.InvalidOptions, c.listInstances("us-central1-a", .{ .filter = "status = RUNNING", .order_by = "name" }));
    try testing.expect(std.mem.indexOf(u8, h.diag.message(), "Specifying both a list filter and sort order") != null);
    try testing.expectError(error.InvalidOptions, c.listInstances("us-central1-a", .{ .max_results = 501 }));
    try testing.expectError(error.InvalidName, c.listInstances("us-central1-a", .{ .page_token = "a b" }));
    try testing.expectError(error.InvalidOptions, c.serialOutput("us-central1-a", "web-1", .{ .port = 5 }));
    try testing.expectError(error.InvalidOptions, c.serialOutput("us-central1-a", "web-1", .{ .port = 0 }));
    try testing.expectError(error.InvalidName, c.guestAttributes("us-central1-a", "web-1", "a b"));
    try testing.expectError(error.InvalidName, c.imageFromFamily("Debian Cloud", "debian-12"));
    try testing.expectError(error.InvalidName, c.getOperation(.{ .name = "op/1", .scope = .global }));
    try testing.expectError(error.InvalidName, c.listOperations(.{ .region = "US" }, .{}));
    try testing.expectEqual(0, h.fake.requests.items.len);
}

test "production's refusals, as errors with production's words" {
    var h: Harness = undefined;
    try h.init(&.{
        reply(404, production.not_found_instance),
        reply(400, production.unknown_zone),
        reply(409, production.already_exists),
        reply(412, production.stale_label_fingerprint),
    });
    defer h.deinit();
    const c = &h.client;
    try testing.expectError(error.NotFound, c.getInstance("us-central1-a", "zigps-m0-11031830-none"));
    try testing.expect(std.mem.indexOf(u8, h.diag.message(), "was not found") != null);
    try testing.expectError(error.InvalidArgument, c.listInstances("us-central1-q", .{}));
    try testing.expect(std.mem.indexOf(u8, h.diag.message(), "Unknown zone.") != null);
    try testing.expectError(error.AlreadyExists, c.getInstance("us-central1-a", "a"));
    try testing.expectError(error.FailedPrecondition, c.getInstance("us-central1-a", "a"));
}

test "waitOperation: POSTs the wait until DONE, a second apart when answered at once" {
    var h: Harness = undefined;
    try h.init(&.{
        reply(200, production.operation_running),
        reply(200, production.operation_suspending),
        reply(200, production.operation_done),
    });
    defer h.deinit();
    var op = try h.client.waitOperation(.{ .name = "operation-1793730664860-65f63771a0c50-6411bc86-75804f1f", .scope = .{ .zone = "us-central1-a" } }, .{});
    defer op.deinit();
    try testing.expect(op.value.succeeded());
    const r = h.fake.requests.items;
    try testing.expectEqual(3, r.len);
    for (r) |req| {
        try testing.expectEqual(core.transport.Method.POST, req.method);
        try testing.expect(std.mem.endsWith(u8, req.url, "/zones/us-central1-a/operations/operation-1793730664860-65f63771a0c50-6411bc86-75804f1f/wait"));
        try testing.expectEqualStrings("", req.body.?);
        // The server holds a wait for up to two minutes.
        try testing.expect(req.timeout_ms >= 150_000);
    }
    try testing.expectEqual(2, h.clock.sleep_count);
    try testing.expectEqual(1000, h.clock.sleepMs(0));
}

test "waitOperation: at the deadline, the operation as it stands" {
    var h: Harness = undefined;
    const running = reply(200, production.operation_running);
    try h.init(&.{ running, running, running, running, running, running });
    defer h.deinit();
    var op = try h.client.waitOperation(.{ .name = "operation-1", .scope = .{ .zone = "us-central1-a" } }, .{ .timeout_ms = 2500 });
    defer op.deinit();
    try testing.expectEqual(types.OperationStatus.running, op.value.status);
    // Three calls a second apart, then the last 500 ms, then the answer.
    try testing.expectEqual(4, h.fake.requests.items.len);
}

test "waitOperation: a failed operation is an answer, not an error" {
    var h: Harness = undefined;
    try h.init(&.{reply(200, production.operation_failed)});
    defer h.deinit();
    var op = try h.client.waitOperation(.{ .name = "operation-2", .scope = .{ .zone = "us-central1-a" } }, .{});
    defer op.deinit();
    try testing.expect(op.value.done() and !op.value.succeeded());
    try testing.expectEqualStrings("UNSUPPORTED_OPERATION", op.value.failure.?.code());
}

test "waitOperation: a dropped connection is retried" {
    var h: Harness = undefined;
    try h.init(&.{ .{ .fail = error.ConnectionResetByPeer }, reply(200, production.operation_done) });
    defer h.deinit();
    var op = try h.client.waitOperation(.{ .name = "operation-3", .scope = .global }, .{});
    defer op.deinit();
    try testing.expect(op.value.succeeded());
    try testing.expectEqualStrings(base ++ "global/operations/operation-3/wait", h.fake.requests.items[1].url);
}

// Over FakeCompute.

const Fixture = struct {
    clock: test_util.FakeClock,
    fake: FakeCompute,
    token: test_util.FakeTokenProvider,
    diag: core.Diagnostics,
    client: Client,

    fn init(f: *Fixture, gpa: std.mem.Allocator) !void {
        f.* = .{ .clock = .{}, .fake = undefined, .token = .{ .token = "ya29.t" }, .diag = .{}, .client = undefined };
        f.fake = .init(gpa, f.clock.io(), .{});
        errdefer f.fake.deinit();
        f.client = try .init(gpa, f.clock.io(), .{
            .project_id = "my-project",
            .token_provider = f.token.provider(),
            .diagnostics = &f.diag,
            .transport = f.fake.transport(),
        });
    }

    fn deinit(f: *Fixture) void {
        f.client.deinit();
        f.fake.deinit();
    }
};

test "FakeCompute: a VM put in reads back as production wrote one" {
    var f: Fixture = undefined;
    try f.init(testing.allocator);
    defer f.deinit();
    try f.fake.putInstance(.{
        .zone = "us-central1-a",
        .name = "web-1",
        .labels = &.{.{ .key = "env", .value = "prod" }},
        .metadata = &.{ .{ .key = "startup-script", .value = "echo hi" }, .{ .key = "enable-guest-attributes", .value = "TRUE" } },
        .spot = true,
        .max_run_duration_s = 3600,
        .termination_action = .delete,
    });
    var i = try f.client.getInstance("us-central1-a", "web-1");
    defer i.deinit();
    const v = i.value;
    try testing.expect(v.running());
    try testing.expectEqualStrings("us-central1-a", v.zone);
    try testing.expectEqualStrings("e2-micro", v.machine_type);
    try testing.expectEqualStrings("prod", v.label("env").?);
    try testing.expectEqualStrings("echo hi", v.metadataValue("startup-script").?);
    try testing.expect(v.label_fingerprint.len > 0 and v.metadata.fingerprint.len > 0 and v.tags.fingerprint.len > 0);
    // A spot VM's scheduling as production filled it in.
    try testing.expectEqual(types.ProvisioningModel.spot, v.scheduling.provisioning_model);
    try testing.expect(v.scheduling.preemptible);
    try testing.expectEqualStrings("TERMINATE", v.scheduling.on_host_maintenance);
    try testing.expectEqual(3600, v.scheduling.max_run_duration_s.?);
    try testing.expectEqual(types.TerminationAction.delete, v.scheduling.termination_action.?);
    try testing.expectEqual(1, v.disks.len);

    try f.fake.setStatus("us-central1-a", "web-1", .terminated);
    var after = try f.client.getInstance("us-central1-a", "web-1");
    defer after.deinit();
    try testing.expect(after.value.stopped());
}

test "FakeCompute: lists sort, filter and page; the aggregated list spans zones" {
    var f: Fixture = undefined;
    try f.init(testing.allocator);
    defer f.deinit();
    for ([_][]const u8{ "web-3", "web-1", "db-1", "web-2", "web-4" }) |n| {
        try f.fake.putInstance(.{ .zone = "us-central1-a", .name = n, .labels = &.{.{ .key = "role", .value = if (n[0] == 'w') "web" else "db" }} });
    }
    try f.fake.putInstance(.{ .zone = "us-central1-b", .name = "web-9" });
    var first = try f.client.listInstances("us-central1-a", .{ .filter = "labels.role = web", .max_results = 3 });
    defer first.deinit();
    try testing.expectEqual(3, first.value.instances.len);
    try testing.expectEqualStrings("web-1", first.value.instances[0].name);
    try testing.expectEqualStrings("web-3", first.value.instances[2].name);
    var second = try f.client.listInstances("us-central1-a", .{ .filter = "labels.role = web", .max_results = 3, .page_token = first.value.next_page_token.? });
    defer second.deinit();
    try testing.expectEqual(1, second.value.instances.len);
    try testing.expect(second.value.next_page_token == null);
    var prefix = try f.client.listInstances("us-central1-a", .{ .filter = "name = \"db-.*\"" });
    defer prefix.deinit();
    try testing.expectEqual(1, prefix.value.instances.len);
    var newest = try f.client.listInstances("us-central1-a", .{ .order_by = "creationTimestamp desc" });
    defer newest.deinit();
    try testing.expectEqualStrings("web-4", newest.value.instances[0].name);
    var all = try f.client.listAllInstances(.{});
    defer all.deinit();
    try testing.expectEqual(6, all.value.instances.len);
    // Empty zones answered NO_RESULTS_ON_PAGE, which the client leaves out.
    try testing.expectEqual(0, all.value.warnings.len);
    try testing.expectEqualStrings("us-central1-b", all.value.instances[5].zone);
}

test "FakeCompute: a serial console's window, offsets and nothing new" {
    var f: Fixture = undefined;
    try f.init(testing.allocator);
    defer f.deinit();
    try f.fake.putInstance(.{ .zone = "us-central1-a", .name = "web-1" });
    var chunk: [64 * 1024]u8 = undefined;
    @memset(&chunk, 'x');
    for (0..40) |_| try f.fake.appendSerial("us-central1-a", "web-1", &chunk); // 2.5 MiB
    const total: u64 = 40 * chunk.len;
    var newest = try f.client.serialOutput("us-central1-a", "web-1", .{});
    defer newest.deinit();
    try testing.expectEqual(1 << 20, newest.value.contents.len);
    try testing.expectEqual(total - (1 << 20), newest.value.start);
    try testing.expectEqual(total, newest.value.next);
    // From 0: moved up to the oldest byte kept.
    var old = try f.client.serialOutput("us-central1-a", "web-1", .{ .start = 0 });
    defer old.deinit();
    try testing.expectEqual(total - (1 << 20), old.value.start);
    var none = try f.client.serialOutput("us-central1-a", "web-1", .{ .start = newest.value.next });
    defer none.deinit();
    try testing.expectEqual(0, none.value.contents.len);
    try testing.expectEqual(newest.value.next, none.value.next);
}

test "FakeCompute: guest attributes, images by family" {
    var f: Fixture = undefined;
    try f.init(testing.allocator);
    defer f.deinit();
    try f.fake.putInstance(.{ .zone = "us-central1-a", .name = "web-1" });
    try f.fake.putGuestAttribute("us-central1-a", "web-1", .{ .namespace = "app", .key = "state", .value = "ready" });
    var ga = try f.client.guestAttributes("us-central1-a", "web-1", "app/");
    defer ga.deinit();
    try testing.expectEqualStrings("ready", ga.value.attributes[0].value);
    var one = try f.client.guestAttributes("us-central1-a", "web-1", "app/state");
    defer one.deinit();
    try testing.expectEqualStrings("ready", one.value.attributes[0].value);
    try testing.expectError(error.NotFound, f.client.guestAttributes("us-central1-a", "web-1", "nonesuch/"));

    try f.fake.putImage(.{ .project = "debian-cloud", .name = "debian-12-a", .family = "debian-12" });
    try f.fake.putImage(.{ .project = "debian-cloud", .name = "debian-12-b", .family = "debian-12" });
    try f.fake.putImage(.{ .project = "debian-cloud", .name = "debian-12-c", .family = "debian-12", .deprecated = "DEPRECATED" });
    var img = try f.client.imageFromFamily("debian-cloud", "debian-12");
    defer img.deinit();
    try testing.expectEqualStrings("debian-12-b", img.value.name);
    try testing.expectEqualStrings("debian-cloud", img.value.project);
    try testing.expectError(error.NotFound, f.client.imageFromFamily("debian-cloud", "nonesuch-99"));
}

test "FakeCompute: operations finish after their waits; a GET does not move one" {
    var f: Fixture = undefined;
    try f.init(testing.allocator);
    defer f.deinit();
    try f.fake.putInstance(.{ .zone = "us-central1-a", .name = "web-1" });
    const name = try f.fake.putOperation(.{ .scope = .{ .zone = "us-central1-a" }, .target_instance = "web-1", .waits_to_finish = 3 });
    const ref: types.OperationRef = .{ .name = name, .scope = .{ .zone = "us-central1-a" } };
    var got = try f.client.getOperation(ref);
    defer got.deinit();
    try testing.expect(!got.value.done());
    var done = try f.client.waitOperation(ref, .{});
    defer done.deinit();
    try testing.expect(done.value.succeeded());
    try testing.expect(done.value.targetsInstance("web-1"));

    _ = try f.fake.putOperation(.{
        .scope = .{ .zone = "us-central1-a" },
        .operation_type = "compute.instances.preempted",
        .target_instance = "web-1",
        .user = "system",
    });
    var ops = try f.client.listOperations(.{ .zone = "us-central1-a" }, .{ .filter = "targetLink eq .*/instances/web-1" });
    defer ops.deinit();
    try testing.expectEqual(2, ops.value.operations.len);
    try testing.expectEqualStrings("system", ops.value.operations[1].user);

    const failed = try f.fake.putOperation(.{ .scope = .global, .failure = .{ .code = "RESOURCE_IN_USE_BY_ANOTHER_RESOURCE", .message = "in use" } });
    var fop = try f.client.waitOperation(.{ .name = failed, .scope = .global }, .{});
    defer fop.deinit();
    try testing.expectEqualStrings("RESOURCE_IN_USE_BY_ANOTHER_RESOURCE", fop.value.failure.?.code());
}

/// The fake's answer to one GET, served directly.
fn fakeGet(fake: *FakeCompute, arena: std.mem.Allocator, path: []const u8) !FakeCompute.Reply {
    return fake.serve(.{ .method = .GET, .url = try std.fmt.allocPrint(arena, "https://compute.googleapis.com/compute/v1/projects/{s}", .{path}), .bearer = "t" }, arena);
}

/// The error's status, reason and message from a body in Compute's
/// older shape, with the probe's project in place of `project`.
fn refusalOf(arena: std.mem.Allocator, body: []const u8, project: []const u8) !struct { code: i64, reason: []const u8, message: []const u8 } {
    const parsed = try std.json.parseFromSliceLeaky(std.json.Value, arena, body, .{});
    const e = parsed.object.get("error").?.object;
    const message = e.get("message").?.string;
    return .{
        .code = e.get("code").?.integer,
        .reason = e.get("errors").?.array.items[0].object.get("reason").?.string,
        .message = try std.mem.replaceOwned(u8, arena, message, project, "extractctl"),
    };
}

test "FakeCompute: refusals in production's words" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    var clock: test_util.FakeClock = .{};
    var fake: FakeCompute = .init(testing.allocator, clock.io(), .{ .project_id = "extractctl" });
    defer fake.deinit();
    try fake.putInstance(.{ .zone = "us-central1-a", .name = "zigps-m0-11031830-a" });
    const cases = [_]struct { path: []const u8, body: []const u8 }{
        .{ .path = "extractctl/zones/us-central1-a/instances/zigps-m0-11031830-none", .body = production.not_found_instance },
        .{ .path = "extractctl/zones/us-central1-a/machineTypes/e2-nonesuch", .body = production.not_found_machine_type },
        .{ .path = "debian-cloud/global/images/family/nonesuch-99", .body = production.not_found_family },
        .{ .path = "extractctl/zones/us-central1-a/operations/operation-nonesuch", .body = production.not_found_operation },
        .{ .path = "extractctl/zones/us-central1-q/instances", .body = production.unknown_zone },
        .{ .path = "extractctl/zones/us-central1-a/instances?filter=labels.tool%3Dcompute-m0&orderBy=creationTimestamp%20desc", .body = production.filter_and_order },
        .{ .path = "extractctl/zones/us-central1-a/instances?orderBy=status", .body = production.order_unsupported },
        .{ .path = "extractctl/zones/us-central1-a/instances?filter=nonesuch%20%3D%3D%3D", .body = production.filter_invalid },
        .{ .path = "extractctl/zones/us-central1-a/instances/zigps-m0-11031830-a/serialPort?port=9", .body = production.serial_port_out_of_range },
        .{ .path = "extractctl/zones/us-central1-a/instances/zigps-m0-11031830-a/getGuestAttributes?queryPath=nonesuch%2F", .body = production.guest_attribute_missing },
    };
    for (cases) |case| {
        const got = try fakeGet(&fake, a, case.path);
        const want = try refusalOf(a, case.body, "extractctl");
        const have = try refusalOf(a, got.body, "extractctl");
        testing.expectEqual(want.code, have.code) catch |err| {
            std.debug.print("{s}\n", .{case.path});
            return err;
        };
        try testing.expectEqualStrings(want.reason, have.reason);
        try testing.expectEqualStrings(want.message, have.message);
    }
}

test "FakeCompute: what it does not model, it says so" {
    var f: Fixture = undefined;
    try f.init(testing.allocator);
    defer f.deinit();
    try f.fake.putInstance(.{ .zone = "us-central1-a", .name = "web-1" });
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    const boot = try f.fake.serve(.{ .method = .POST, .url = base ++ "zones/us-central1-a/instances/web-1/detachDisk?deviceName=persistent-disk-0", .bearer = "t" }, a);
    try testing.expectEqual(501, boot.status);
    try testing.expect(std.mem.indexOf(u8, boot.body, "detaching a boot disk") != null);
    const verb = try f.fake.serve(.{ .method = .POST, .url = base ++ "zones/us-central1-a/instances/web-1/setServiceAccount", .bearer = "t", .body = "{}" }, a);
    try testing.expectEqual(501, verb.status);
    const no_name = try f.fake.serve(.{ .method = .POST, .url = base ++ "zones/us-central1-a/instances", .bearer = "t", .body = "{}" }, a);
    try testing.expectEqual(501, no_name.status);
    const template = try f.fake.serve(.{ .method = .POST, .url = base ++ "global/instanceTemplates", .bearer = "t", .body = "{}" }, a);
    try testing.expectEqual(501, template.status);
}

/// Pages hold every VM once, in order: a zone's by name, the aggregated
/// list's by zone then name, whatever the page size.
fn pagesProperty(_: void, input: []const u8) !void {
    const gpa = test_util.propertyAllocator();
    var g: test_util.ByteGen = .init(input);
    var f: Fixture = undefined;
    try f.init(gpa);
    defer f.deinit();
    const zones = [_][]const u8{ "us-central1-a", "us-central1-b", "us-central1-c" };
    const count = g.intRange(u8, 0, 24);
    var per_zone = [_]usize{ 0, 0, 0 };
    for (0..count) |n| {
        const z = g.intRange(u8, 0, 2);
        var buf: [16]u8 = undefined;
        const name = std.fmt.bufPrint(&buf, "vm-{d}", .{n}) catch unreachable;
        try f.fake.putInstance(.{ .zone = zones[z], .name = name });
        per_zone[z] += 1;
    }
    const size = g.intRange(u8, 1, 7);
    for (zones, per_zone) |zone, want| {
        var seen: usize = 0;
        var last: [16]u8 = undefined;
        var last_len: usize = 0;
        var token_buf: [32]u8 = undefined;
        var token: ?[]const u8 = null;
        while (true) {
            var page = try f.client.listInstances(zone, .{ .max_results = size, .page_token = token });
            defer page.deinit();
            for (page.value.instances) |i| {
                if (last_len > 0) try testing.expect(std.mem.lessThan(u8, last[0..last_len], i.name));
                @memcpy(last[0..i.name.len], i.name);
                last_len = i.name.len;
                seen += 1;
            }
            token = if (page.value.next_page_token) |t| token_buf[0..t.len] else null;
            if (page.value.next_page_token) |t| @memcpy(token_buf[0..t.len], t) else break;
        }
        try testing.expectEqual(want, seen);
    }
    var total: usize = 0;
    var token_buf: [32]u8 = undefined;
    var token: ?[]const u8 = null;
    while (true) {
        var page = try f.client.listAllInstances(.{ .max_results = size, .page_token = token });
        defer page.deinit();
        total += page.value.instances.len;
        token = if (page.value.next_page_token) |t| token_buf[0..t.len] else null;
        if (page.value.next_page_token) |t| @memcpy(token_buf[0..t.len], t) else break;
    }
    try testing.expectEqual(@as(usize, count), total);
}

test "fuzz compute fake: pages hold every VM once, in order" {
    try test_util.fuzzBytes({}, pagesProperty, .{
        .corpus = &.{ "", "\x18\x00\x01\x02\x00\x01\x02\x00\x01\x02\x03", "\x05\x02\x02\x02\x02\x02\x01" },
        .random_runs = 50,
        .max_len = 40,
    });
}

/// Whatever an operation's waits and failure, and whatever transient
/// faults come first, `waitOperation` answers it DONE, with its failure.
fn waitProperty(_: void, input: []const u8) !void {
    const gpa = test_util.propertyAllocator();
    var g: test_util.ByteGen = .init(input);
    var f: Fixture = undefined;
    try f.init(gpa);
    defer f.deinit();
    const waits = g.intRange(u8, 0, 6);
    const failed = g.boolean();
    const name = try f.fake.putOperation(.{
        .scope = .{ .zone = "us-central1-b" },
        .waits_to_finish = waits,
        .failure = if (failed) .{ .code = "UNSUPPORTED_OPERATION", .message = "Instance is starting or running." } else null,
    });
    switch (g.intRange(u8, 0, 2)) {
        0 => {},
        1 => f.fake.dropNext(g.intRange(u8, 1, 2)),
        else => f.fake.refuseNext(g.intRange(u8, 1, 2), 503),
    }
    var op = try f.client.waitOperation(.{ .name = name, .scope = .{ .zone = "us-central1-b" } }, .{});
    defer op.deinit();
    try testing.expect(op.value.done());
    try testing.expectEqual(failed, op.value.failure != null);
}

test "fuzz compute waitOperation: done through waits and faults" {
    try test_util.fuzzBytes({}, waitProperty, .{
        .corpus = &.{ "", "\x06\x01\x01\x02", "\x03\x00\x02\x01" },
        .random_runs = 50,
        .max_len = 8,
    });
}
