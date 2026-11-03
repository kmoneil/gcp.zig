//! The writes' tests: requests as sent and as previewed, byte for byte;
//! request ids made, given, and kept across a retry; refusals before
//! sending; and production's refusals as errors in its words.

const std = @import("std");
const testing = std.testing;
const core = @import("core");

const types = @import("types.zig");
const test_util = @import("test_util.zig");
const production = @import("production_bodies.zig");
const Harness = test_util.Harness;
const Client = @import("Client.zig");

const base = "https://compute.googleapis.com/compute/v1/projects/my-project/";
const zone = "us-central1-a";
/// The id `newRequestId` makes when every random byte is 0xab.
const made_id = "abababab-abab-4bab-abab-abababababab";
const given_id = "8068f1b8-03fc-4f7f-a5bd-d5e775aa7212";

fn reply(status: u16, body: []const u8) test_util.FakeTransport.Reply {
    return .{ .respond = .{ .status = status, .body = body } };
}

fn writer(h: *Harness, script: []const test_util.FakeTransport.Reply) !void {
    try h.initScope(script, .read_write);
    h.clock.random_byte = 0xab;
}

const spot_spec: types.InstanceSpec = .{
    .name = "web-1",
    .machine_type = "e2-micro",
    .image = .{ .family = .{ .project = "debian-cloud", .name = "debian-12" } },
    .spot = true,
    .max_run_duration_s = 600,
    .termination_action = .delete,
    .labels = &.{.{ .key = "env", .value = "test" }},
    .metadata = &.{.{ .key = "startup-script", .value = "echo hi > /dev/ttyS0" }},
};

test "insertInstance: the path, the body and a request id made for it" {
    var h: Harness = undefined;
    try writer(&h, &.{reply(200, production.operation_running)});
    defer h.deinit();
    var op = try h.client.insertInstance(zone, spot_spec, .{});
    defer op.deinit();
    try testing.expectEqual(types.OperationStatus.running, op.value.status);
    try testing.expectEqualStrings("insert", op.value.operation_type);
    try testing.expectEqualStrings(zone, op.value.scope.zone);
    const sent = h.fake.requests.items[0];
    try testing.expectEqual(core.transport.Method.POST, sent.method);
    try testing.expectEqualStrings(base ++ "zones/us-central1-a/instances?requestId=" ++ made_id, sent.url);
    try testing.expectEqualStrings(
        \\{"name":"web-1","machineType":"zones/us-central1-a/machineTypes/e2-micro","labels":{"env":"test"},"disks":[{"boot":true,"autoDelete":true,"initializeParams":{"sourceImage":"projects/debian-cloud/global/images/family/debian-12"}}],"networkInterfaces":[{"network":"global/networks/default"}],"metadata":{"items":[{"key":"startup-script","value":"echo hi > /dev/ttyS0"}]},"scheduling":{"automaticRestart":false,"maxRunDuration":{"seconds":"600"},"instanceTerminationAction":"DELETE","provisioningModel":"SPOT"}}
    , sent.body.?);
}

test "every write's method, path and body" {
    var h: Harness = undefined;
    const op = reply(200, production.operation_running);
    try writer(&h, &.{ op, op, op, op, op, op, op, op, op });
    defer h.deinit();
    const c = &h.client;
    const ids: types.WriteOptions = .{ .request_id = given_id };
    const results = [_]anyerror!types.Owned(types.Operation){
        c.insertInstanceJson(zone, "{\"name\":\"web-2\",\"machineType\":\"zones/us-central1-a/machineTypes/a2-highgpu-1g\"}", ids),
        c.insertFromTemplate(zone, "web-3", .{ .global = "web-tpl" }, ids),
        c.startInstance(zone, "web-1", ids),
        c.stopInstance(zone, "web-1", .{ .request_id = given_id, .no_graceful_shutdown = true, .discard_local_ssd = false }),
        c.suspendInstance(zone, "web-1", .{ .request_id = given_id, .discard_local_ssd = true }),
        c.resumeInstance(zone, "web-1", ids),
        c.resetInstance(zone, "web-1", ids),
        c.deleteInstance(zone, "web-1", .{ .request_id = given_id, .no_graceful_shutdown = true }),
        c.insertFromTemplate(zone, "web-4", .{ .regional = .{ .region = "us-central1", .name = "web-tpl" } }, ids),
    };
    for (results) |r| {
        var owned = try r;
        owned.deinit();
    }
    const r = h.fake.requests.items;
    const id = "requestId=" ++ given_id;
    const Want = struct { core.transport.Method, []const u8, ?[]const u8 };
    const want = [_]Want{
        .{ .POST, "zones/us-central1-a/instances?" ++ id, "{\"name\":\"web-2\",\"machineType\":\"zones/us-central1-a/machineTypes/a2-highgpu-1g\"}" },
        .{ .POST, "zones/us-central1-a/instances?sourceInstanceTemplate=projects%2Fmy-project%2Fglobal%2FinstanceTemplates%2Fweb-tpl&" ++ id, "{\"name\":\"web-3\"}" },
        .{ .POST, "zones/us-central1-a/instances/web-1/start?" ++ id, "" },
        .{ .POST, "zones/us-central1-a/instances/web-1/stop?discardLocalSsd=false&noGracefulShutdown=true&" ++ id, "" },
        .{ .POST, "zones/us-central1-a/instances/web-1/suspend?discardLocalSsd=true&" ++ id, "" },
        .{ .POST, "zones/us-central1-a/instances/web-1/resume?" ++ id, "" },
        .{ .POST, "zones/us-central1-a/instances/web-1/reset?" ++ id, "" },
        .{ .DELETE, "zones/us-central1-a/instances/web-1?noGracefulShutdown=true&" ++ id, null },
        .{ .POST, "zones/us-central1-a/instances?sourceInstanceTemplate=projects%2Fmy-project%2Fregions%2Fus-central1%2FinstanceTemplates%2Fweb-tpl&" ++ id, "{\"name\":\"web-4\"}" },
    };
    try testing.expectEqual(want.len, r.len);
    for (want, r) |w, sent| {
        try testing.expectEqual(w[0], sent.method);
        const url = try std.mem.concat(testing.allocator, u8, &.{ base, w[1] });
        defer testing.allocator.free(url);
        try testing.expectEqualStrings(url, sent.url);
        if (w[2]) |b| try testing.expectEqualStrings(b, sent.body.?) else try testing.expect(sent.body == null);
    }
}

test "every preview is what its write sends, byte for byte" {
    var h: Harness = undefined;
    const op = reply(200, production.operation_running);
    try writer(&h, &.{ op, op, op, op, op, op, op, op, op });
    defer h.deinit();
    const c = &h.client;
    var buf: [36]u8 = undefined;
    const ids: types.WriteOptions = .{ .request_id = c.newRequestId(&buf) };
    const stop: types.StopOptions = .{ .request_id = ids.request_id, .no_graceful_shutdown = true };
    const sus: types.SuspendOptions = .{ .request_id = ids.request_id, .discard_local_ssd = false };
    const del: types.DeleteOptions = .{ .request_id = ids.request_id };
    const raw = "{\"name\":\"web-2\"}";
    const tpl: types.TemplateRef = .{ .global = "web-tpl" };
    var previews = [_]types.Owned(core.PreparedRequest){
        try c.insertInstanceRequest(zone, spot_spec, ids),
        try c.insertInstanceJsonRequest(zone, raw, ids),
        try c.insertFromTemplateRequest(zone, "web-3", tpl, ids),
        try c.startInstanceRequest(zone, "web-1", ids),
        try c.stopInstanceRequest(zone, "web-1", stop),
        try c.suspendInstanceRequest(zone, "web-1", sus),
        try c.resumeInstanceRequest(zone, "web-1", ids),
        try c.resetInstanceRequest(zone, "web-1", ids),
        try c.deleteInstanceRequest(zone, "web-1", del),
    };
    defer for (&previews) |*p| p.deinit();
    try testing.expectEqual(0, h.fake.requests.items.len);
    const results = [_]anyerror!types.Owned(types.Operation){
        c.insertInstance(zone, spot_spec, ids),
        c.insertInstanceJson(zone, raw, ids),
        c.insertFromTemplate(zone, "web-3", tpl, ids),
        c.startInstance(zone, "web-1", ids),
        c.stopInstance(zone, "web-1", stop),
        c.suspendInstance(zone, "web-1", sus),
        c.resumeInstance(zone, "web-1", ids),
        c.resetInstance(zone, "web-1", ids),
        c.deleteInstance(zone, "web-1", del),
    };
    for (results) |r| {
        var owned = try r;
        owned.deinit();
    }
    for (previews, h.fake.requests.items) |p, sent| {
        try testing.expectEqual(p.value.method, sent.method);
        try testing.expectEqualStrings(p.value.url, sent.url);
        try testing.expectEqualStrings(p.value.body, sent.body orelse "");
    }
}

test "a request id made for a write is kept by every retry, within its window" {
    var h: Harness = undefined;
    try writer(&h, &.{
        .{ .fail = error.ConnectionResetByPeer },
        reply(503, "{\"error\":{\"code\":503,\"message\":\"x\",\"errors\":[{\"reason\":\"backendError\"}]}}"),
        reply(200, production.operation_running),
    });
    defer h.deinit();
    h.clock.random_byte = null;
    var op = try h.client.insertInstance(zone, spot_spec, .{});
    defer op.deinit();
    const r = h.fake.requests.items;
    try testing.expectEqual(3, r.len);
    const at = std.mem.indexOf(u8, r[0].url, "requestId=").? + "requestId=".len;
    const id = r[0].url[at..];
    try testing.expect(@import("validate.zig").isRequestId(id));
    try testing.expect(!std.mem.eql(u8, made_id, id));
    for (r[1..]) |again| try testing.expectEqualStrings(r[0].url, again.url);
    // A second write makes a new one.
    var other: types.Owned(core.PreparedRequest) = try h.client.startInstanceRequest(zone, "web-1", .{});
    defer other.deinit();
    try testing.expect(std.mem.indexOf(u8, other.value.url, id) == null);
    try testing.expectEqual(10 * std.time.ms_per_min, Client.request_id_window_ms);
}

test "newRequestId: a version 4 UUID" {
    var h: Harness = undefined;
    try writer(&h, &.{});
    defer h.deinit();
    var buf: [36]u8 = undefined;
    try testing.expectEqualStrings(made_id, h.client.newRequestId(&buf));
    h.clock.random_byte = 0;
    // Zero bytes still make a valid id: the version and variant bits.
    try testing.expectEqualStrings("00000000-0000-4000-8000-000000000000", h.client.newRequestId(&buf));
    try testing.expect(@import("validate.zig").isRequestId(h.client.newRequestId(&buf)));
}

test "a read-only client refuses every write and its preview, sending nothing" {
    var h: Harness = undefined;
    try h.init(&.{});
    defer h.deinit();
    const c = &h.client;
    try testing.expectError(error.InvalidOptions, c.insertInstance(zone, spot_spec, .{}));
    try testing.expect(std.mem.indexOf(u8, h.diag.message(), "compute.readonly") != null);
    try testing.expectError(error.InvalidOptions, c.insertInstanceRequest(zone, spot_spec, .{}));
    try testing.expectError(error.InvalidOptions, c.insertInstanceJson(zone, "{\"name\":\"a\"}", .{}));
    try testing.expectError(error.InvalidOptions, c.insertFromTemplate(zone, "a", .{ .global = "t" }, .{}));
    try testing.expectError(error.InvalidOptions, c.startInstance(zone, "a", .{}));
    try testing.expectError(error.InvalidOptions, c.stopInstance(zone, "a", .{}));
    try testing.expectError(error.InvalidOptions, c.suspendInstance(zone, "a", .{}));
    try testing.expectError(error.InvalidOptions, c.resumeInstance(zone, "a", .{}));
    try testing.expectError(error.InvalidOptions, c.resetInstance(zone, "a", .{}));
    try testing.expectError(error.InvalidOptions, c.deleteInstance(zone, "a", .{}));
    try testing.expectError(error.InvalidOptions, c.deleteInstanceRequest(zone, "a", .{}));
    try testing.expectEqual(0, h.fake.requests.items.len);
}

fn specWith(comptime field: []const u8, value: @FieldType(types.InstanceSpec, field)) types.InstanceSpec {
    var s = spot_spec;
    @field(s, field) = value;
    return s;
}

test "refused before sending: the spec, names, zones, ids, bodies and templates" {
    var h: Harness = undefined;
    try writer(&h, &.{});
    defer h.deinit();
    const c = &h.client;
    const Case = struct { anyerror, types.InstanceSpec };
    const cases = [_]Case{
        .{ error.InvalidName, specWith("name", "Bad_Name") },
        .{ error.InvalidName, specWith("machine_type", "e2 micro") },
        .{ error.InvalidName, specWith("image", .{ .family = .{ .project = "Debian Cloud", .name = "debian-12" } }) },
        .{ error.InvalidName, specWith("image", .{ .image = .{ .project = "debian-cloud", .name = "Debian" } }) },
        .{ error.InvalidOptions, specWith("image", .{ .path = "global/images/a b" }) },
        .{ error.InvalidOptions, specWith("boot_disk", .{ .size_gb = 9 }) },
        .{ error.InvalidOptions, specWith("boot_disk", .{ .type = "pd ssd" }) },
        .{ error.InvalidOptions, specWith("automatic_restart", true) },
        .{ error.InvalidOptions, specWith("termination_action", .unknown) },
        .{ error.InvalidOptions, specWith("max_run_duration_s", 0) },
        .{ error.InvalidOptions, specWith("metadata", &.{.{ .key = "a.b", .value = "x" }}) },
        .{ error.InvalidOptions, specWith("metadata", &.{.{ .key = "bad-utf8", .value = "\xff" }}) },
        .{ error.InvalidOptions, specWith("labels", &.{.{ .key = "Env", .value = "x" }}) },
        .{ error.InvalidOptions, specWith("labels", &.{.{ .key = "env", .value = "a b" }}) },
        .{ error.InvalidName, specWith("tags", &.{"Http"}) },
        .{ error.InvalidOptions, specWith("service_account", .{ .email = "a b" }) },
        .{ error.InvalidOptions, specWith("service_account", .{ .email = "a@b", .scopes = &.{"x y"} }) },
        .{ error.InvalidOptions, specWith("network", "") },
        .{ error.InvalidOptions, specWith("subnetwork", "a b") },
        .{ error.InvalidOptions, specWith("description", "\xff") },
    };
    for (cases, 0..) |case, i| {
        errdefer std.debug.print("case {d}\n", .{i});
        try testing.expectError(case[0], c.insertInstance(zone, case[1], .{}));
        try testing.expect(h.diag.message().len > 0);
        try testing.expectError(case[0], c.insertInstanceRequest(zone, case[1], .{}));
    }
    var too_many: [65]types.Label = undefined;
    for (&too_many) |*l| l.* = .{ .key = "k", .value = "v" };
    try testing.expectError(error.InvalidOptions, c.insertInstance(zone, specWith("labels", &too_many), .{}));
    var big: [256 * 1024 + 1]u8 = undefined;
    @memset(&big, 'a');
    try testing.expectError(error.InvalidOptions, c.insertInstance(zone, specWith("metadata", &.{.{ .key = "big", .value = &big }}), .{}));
    try testing.expectError(error.InvalidName, c.insertInstance("US", spot_spec, .{}));
    try testing.expectError(error.InvalidOptions, c.insertInstance(zone, spot_spec, .{ .request_id = "00000000-0000-0000-0000-000000000000" }));
    try testing.expect(std.mem.indexOf(u8, h.diag.message(), "UUID") != null);
    try testing.expectError(error.InvalidOptions, c.startInstance(zone, "web-1", .{ .request_id = "not-a-uuid" }));
    try testing.expectError(error.InvalidName, c.stopInstance(zone, "web-1/x", .{}));
    try testing.expectError(error.InvalidName, c.deleteInstance("us-central1-a/x", "web-1", .{}));
    try testing.expectError(error.InvalidOptions, c.insertInstanceJson(zone, "[1]", .{}));
    try testing.expectError(error.InvalidOptions, c.insertInstanceJson(zone, "{\"name\":", .{}));
    try testing.expectError(error.InvalidName, c.insertInstanceJson(zone, "{\"machineType\":\"x\"}", .{}));
    try testing.expectError(error.InvalidName, c.insertInstanceJson(zone, "{\"name\":\"Bad_Name\"}", .{}));
    try testing.expectError(error.InvalidName, c.insertFromTemplate(zone, "web-1", .{ .global = "Tpl" }, .{}));
    try testing.expectError(error.InvalidName, c.insertFromTemplate(zone, "web-1", .{ .regional = .{ .region = "US", .name = "t" } }, .{}));
    try testing.expectError(error.InvalidName, c.insertFromTemplate(zone, "Web", .{ .global = "t" }, .{}));
    try testing.expectEqual(0, h.fake.requests.items.len);
}

test "production's refusals of a write, as errors in its words" {
    var h: Harness = undefined;
    try writer(&h, &.{
        reply(409, production.already_exists),
        reply(400, production.insert_bad_machine_type),
        reply(404, production.insert_bad_image),
        reply(400, production.insert_bad_name),
        reply(400, production.e2_terminate),
        reply(400, production.deletion_protected),
    });
    defer h.deinit();
    const c = &h.client;
    try testing.expectError(error.AlreadyExists, c.insertInstance(zone, spot_spec, .{}));
    try testing.expect(std.mem.indexOf(u8, h.diag.message(), "already exists") != null);
    try testing.expectError(error.InvalidArgument, c.insertInstance(zone, spot_spec, .{}));
    try testing.expect(std.mem.indexOf(u8, h.diag.message(), "Machine type with name 'e2-nonesuch' does not exist") != null);
    try testing.expectError(error.NotFound, c.insertInstance(zone, spot_spec, .{}));
    try testing.expect(std.mem.indexOf(u8, h.diag.message(), "family/nonesuch-99' was not found") != null);
    try testing.expectError(error.InvalidArgument, c.insertInstanceJson(zone, "{\"name\":\"web-2\"}", .{}));
    try testing.expect(std.mem.indexOf(u8, h.diag.message(), "Must be a match of regex") != null);
    try testing.expectError(error.InvalidArgument, c.insertInstanceJson(zone, "{\"name\":\"web-2\"}", .{}));
    try testing.expect(std.mem.indexOf(u8, h.diag.message(), "onHostMaintenance=TERMINATE") != null);
    try testing.expectError(error.InvalidArgument, c.deleteInstance(zone, "web-1", .{}));
    try testing.expect(std.mem.indexOf(u8, h.diag.message(), "protected against deletion") != null);
    // Refusals are not retried: each took one request.
    try testing.expectEqual(6, h.fake.requests.items.len);
}

test "the lifecycle's operations, as production answered them" {
    var h: Harness = undefined;
    try writer(&h, &.{
        reply(200, production.operation_stop),
        reply(200, production.operation_start),
        reply(200, production.operation_start_running),
        reply(200, production.operation_reset),
        reply(200, production.operation_suspend),
        reply(200, production.operation_resume),
        reply(200, production.operation_start_pending),
        reply(200, production.operation_delete),
    });
    defer h.deinit();
    const c = &h.client;
    const Want = struct { []const u8, types.OperationStatus, []const u8 };
    const m0 = "zigps-m0-11031830-a";
    const m2 = "zigps-9e4cc1-a";
    const want = [_]Want{
        .{ "stop", .running, m0 },
        .{ "start", .running, m0 },
        .{ "start", .done, m0 },
        .{ "reset", .running, m0 },
        .{ "suspend", .running, m0 },
        .{ "resume", .running, m0 },
        .{ "start", .pending, m2 },
        .{ "delete", .running, m2 },
    };
    var ops = [_]types.Owned(types.Operation){
        try c.stopInstance(zone, m0, .{}),
        try c.startInstance(zone, m0, .{}),
        try c.startInstance(zone, m0, .{}),
        try c.resetInstance(zone, m0, .{}),
        try c.suspendInstance(zone, m0, .{}),
        try c.resumeInstance(zone, m0, .{}),
        try c.startInstance(zone, m2, .{}),
        try c.deleteInstance(zone, m2, .{}),
    };
    defer for (&ops) |*o| o.deinit();
    for (want, ops) |w, o| {
        try testing.expectEqualStrings(w[0], o.value.operation_type);
        try testing.expectEqual(w[1], o.value.status);
        try testing.expect(o.value.targetsInstance(w[2]));
        try testing.expectEqualStrings(zone, o.value.ref().scope.zone);
    }
    // PENDING is not done either: a wait follows it as it does RUNNING.
    try testing.expect(!ops[6].value.done());
}

// Over FakeCompute.

const FakeCompute = @import("fake_compute.zig").FakeCompute;

const Fixture = struct {
    clock: test_util.FakeClock,
    fake: FakeCompute,
    token: test_util.FakeTokenProvider,
    diag: core.Diagnostics,
    client: Client,

    fn init(f: *Fixture, gpa: std.mem.Allocator, options: FakeCompute.Options) !void {
        f.* = .{ .clock = .{}, .fake = undefined, .token = .{ .token = "ya29.t" }, .diag = .{}, .client = undefined };
        f.fake = .init(gpa, f.clock.io(), options);
        errdefer f.fake.deinit();
        f.client = try .init(gpa, f.clock.io(), .{
            .project_id = options.project_id,
            .token_provider = f.token.provider(),
            .scope = .read_write,
            .diagnostics = &f.diag,
            .transport = f.fake.transport(),
        });
    }

    fn deinit(f: *Fixture) void {
        f.client.deinit();
        f.fake.deinit();
    }

    fn status(f: *Fixture, z: []const u8, name: []const u8) !types.Status {
        var i = try f.client.getInstance(z, name);
        defer i.deinit();
        return i.value.status;
    }

    /// Waits for `op` and answers it DONE; frees both.
    fn settle(f: *Fixture, op: anyerror!types.Owned(types.Operation)) !void {
        var started = try op;
        defer started.deinit();
        var done = try f.client.waitOperation(started.value.ref(), .{});
        defer done.deinit();
        try testing.expect(done.value.done());
        if (done.value.failure) |failure| {
            std.debug.print("{s}: {s}\n", .{ failure.code(), failure.message() });
            return error.TestUnexpectedFailure;
        }
    }
};

test "FakeCompute: an insert comes up as its operation finishes; a GET moves nothing" {
    var f: Fixture = undefined;
    try f.init(testing.allocator, .{});
    defer f.deinit();
    var op = try f.client.insertInstance(zone, spot_spec, .{});
    defer op.deinit();
    try testing.expectEqual(types.OperationStatus.running, op.value.status);
    try testing.expectEqualStrings("insert", op.value.operation_type);
    try testing.expect(op.value.targetsInstance("web-1"));
    try testing.expectEqual(types.Status.provisioning, try f.status(zone, "web-1"));
    var read = try f.client.getOperation(op.value.ref());
    defer read.deinit();
    try testing.expect(!read.value.done());
    var done = try f.client.waitOperation(op.value.ref(), .{});
    defer done.deinit();
    try testing.expect(done.value.succeeded());
    var vm = try f.client.getInstance(zone, "web-1");
    defer vm.deinit();
    try testing.expectEqual(types.Status.running, vm.value.status);
    try testing.expectEqual(types.ProvisioningModel.spot, vm.value.scheduling.provisioning_model);
    try testing.expectEqual(600, vm.value.scheduling.max_run_duration_s.?);
    try testing.expectEqual(types.TerminationAction.delete, vm.value.scheduling.termination_action.?);
    try testing.expectEqualStrings("test", vm.value.label("env").?);
    try testing.expectEqualStrings("echo hi > /dev/ttyS0", vm.value.metadataValue("startup-script").?);
    try testing.expectEqualStrings("e2-micro", vm.value.machine_type);
}

test "FakeCompute: the lifecycle, through each state production showed" {
    var f: Fixture = undefined;
    try f.init(testing.allocator, .{});
    defer f.deinit();
    const c = &f.client;
    try f.settle(c.insertInstance(zone, spot_spec, .{}));
    const Step = struct { []const u8, ?types.Status, types.Status };
    // Each write, the VM's status while it runs (null: unchanged), and
    // once it is DONE.
    const steps = [_]Step{
        .{ "stop", .stopping, .terminated },
        .{ "stop", null, .terminated },
        .{ "start", .staging, .running },
        .{ "suspend", .suspending, .suspended },
        .{ "resume", .staging, .running },
        .{ "reset", null, .running },
    };
    for (steps) |s| {
        const before = try f.status(zone, "web-1");
        var op = try if (std.mem.eql(u8, s[0], "stop"))
            c.stopInstance(zone, "web-1", .{})
        else if (std.mem.eql(u8, s[0], "start"))
            c.startInstance(zone, "web-1", .{})
        else if (std.mem.eql(u8, s[0], "suspend"))
            c.suspendInstance(zone, "web-1", .{})
        else if (std.mem.eql(u8, s[0], "resume"))
            c.resumeInstance(zone, "web-1", .{})
        else
            c.resetInstance(zone, "web-1", .{});
        defer op.deinit();
        try testing.expectEqualStrings(s[0], op.value.operation_type);
        try testing.expectEqual(s[1] orelse before, try f.status(zone, "web-1"));
        var done = try c.waitOperation(op.value.ref(), .{});
        defer done.deinit();
        try testing.expect(done.value.succeeded());
        try testing.expectEqual(s[2], try f.status(zone, "web-1"));
    }
    // Starting a running VM: DONE at once, as production answered.
    var again = try c.startInstance(zone, "web-1", .{});
    defer again.deinit();
    try testing.expect(again.value.succeeded());
    // A delete: STOPPING, then gone.
    var del = try c.deleteInstance(zone, "web-1", .{});
    defer del.deinit();
    try testing.expectEqual(types.Status.stopping, try f.status(zone, "web-1"));
    var gone = try c.waitOperation(del.value.ref(), .{});
    defer gone.deinit();
    try testing.expectError(error.NotFound, c.getInstance(zone, "web-1"));
    // The name is free again.
    try f.settle(c.insertInstance(zone, spot_spec, .{}));
    try testing.expectEqual(types.Status.running, try f.status(zone, "web-1"));
}

test "FakeCompute: a write from a state production was not seen in is 501, and says so" {
    var f: Fixture = undefined;
    try f.init(testing.allocator, .{});
    defer f.deinit();
    try f.fake.putInstance(.{ .zone = zone, .name = "web-1", .status = .terminated });
    try testing.expectError(error.Unimplemented, f.client.suspendInstance(zone, "web-1", .{}));
    try testing.expect(std.mem.indexOf(u8, f.diag.message(), "suspend on a VM that is TERMINATED") != null);
    try testing.expectError(error.Unimplemented, f.client.resumeInstance(zone, "web-1", .{}));
    try testing.expectError(error.Unimplemented, f.client.resetInstance(zone, "web-1", .{}));
    try testing.expectEqual(types.Status.terminated, try f.status(zone, "web-1"));
    try testing.expectError(error.NotFound, f.client.startInstance(zone, "web-9", .{}));
    try testing.expectError(error.NotFound, f.client.deleteInstance(zone, "web-9", .{}));
    try testing.expectError(error.InvalidArgument, f.client.startInstance("us-central1-q", "web-1", .{}));
}

test "FakeCompute: a requestId sent again answers its first operation and changes nothing" {
    var f: Fixture = undefined;
    try f.init(testing.allocator, .{});
    defer f.deinit();
    const c = &f.client;
    var first = try c.insertInstance(zone, spot_spec, .{ .request_id = given_id });
    defer first.deinit();
    var again = try c.insertInstance(zone, spot_spec, .{ .request_id = given_id });
    defer again.deinit();
    try testing.expectEqualStrings(first.value.name, again.value.name);
    try testing.expectEqualStrings(given_id, again.value.client_operation_id);
    // A new id is a new insert, of a name taken.
    try testing.expectError(error.AlreadyExists, c.insertInstance(zone, spot_spec, .{}));
    try testing.expect(std.mem.indexOf(u8, f.diag.message(), "zones/us-central1-a/instances/web-1' already exists") != null);
    var done = try c.waitOperation(first.value.ref(), .{});
    defer done.deinit();
    // After DONE too.
    var after = try c.insertInstance(zone, spot_spec, .{ .request_id = given_id });
    defer after.deinit();
    try testing.expectEqualStrings(first.value.name, after.value.name);
    try testing.expect(after.value.succeeded());
    var page = try c.listInstances(zone, .{});
    defer page.deinit();
    try testing.expectEqual(1, page.value.instances.len);
}

test "FakeCompute: a write whose answer was lost, retried, lands once" {
    var f: Fixture = undefined;
    try f.init(testing.allocator, .{});
    defer f.deinit();
    const c = &f.client;
    f.fake.loseNext(1, 503);
    var op = try c.insertInstance(zone, spot_spec, .{});
    defer op.deinit();
    try testing.expectEqual(2, f.fake.callCount());
    var page = try c.listInstances(zone, .{});
    defer page.deinit();
    try testing.expectEqual(1, page.value.instances.len);
    try f.settle(c.waitOperation(op.value.ref(), .{}));
    f.fake.loseNext(1, 503);
    try f.settle(c.stopInstance(zone, "web-1", .{}));
    try testing.expectEqual(types.Status.terminated, try f.status(zone, "web-1"));
    f.fake.dropNext(1);
    try f.settle(c.deleteInstance(zone, "web-1", .{}));
    try testing.expectError(error.NotFound, c.getInstance(zone, "web-1"));
}

test "FakeCompute: a stockout ends the operation failed; another zone has room" {
    var f: Fixture = undefined;
    try f.init(testing.allocator, .{});
    defer f.deinit();
    const c = &f.client;
    try f.settle(c.insertInstance(zone, specWith("name", "web-2"), .{}));
    try f.settle(c.stopInstance(zone, "web-2", .{}));
    try f.fake.setStockout(zone, true);
    var op = try c.insertInstance(zone, spot_spec, .{});
    defer op.deinit();
    var done = try c.waitOperation(op.value.ref(), .{});
    defer done.deinit();
    try testing.expect(done.value.done() and !done.value.succeeded());
    try testing.expect(done.value.failure.?.stockout());
    try testing.expectEqualStrings("ZONE_RESOURCE_POOL_EXHAUSTED", done.value.failure.?.code());
    try testing.expectError(error.NotFound, c.getInstance(zone, "web-1"));
    // A start there fails the same way, and the VM stays stopped.
    var start = try c.startInstance(zone, "web-2", .{});
    defer start.deinit();
    var started = try c.waitOperation(start.value.ref(), .{});
    defer started.deinit();
    try testing.expect(started.value.failure.?.stockout());
    try testing.expectEqual(types.Status.terminated, try f.status(zone, "web-2"));
    // The caller's next zone.
    try f.settle(c.insertInstance("us-central1-b", spot_spec, .{}));
    try testing.expectEqual(types.Status.running, try f.status("us-central1-b", "web-1"));
    try f.fake.setStockout(zone, false);
    try f.settle(c.startInstance(zone, "web-2", .{}));
    try testing.expectError(error.UnknownZone, f.fake.setStockout("us-central1-q", true));
}

test "FakeCompute: an insert from a template, global or regional" {
    var f: Fixture = undefined;
    try f.init(testing.allocator, .{});
    defer f.deinit();
    const c = &f.client;
    try f.fake.putTemplate(.{ .name = "web-tpl", .machine_type = "e2-small", .labels = &.{.{ .key = "role", .value = "web" }}, .spot = true });
    try f.fake.putTemplate(.{ .name = "web-tpl", .region = "us-central1", .machine_type = "e2-medium" });
    try testing.expectError(error.AlreadyExists, f.fake.putTemplate(.{ .name = "web-tpl" }));
    try f.settle(c.insertFromTemplate(zone, "web-1", .{ .global = "web-tpl" }, .{}));
    try f.settle(c.insertFromTemplate(zone, "web-2", .{ .regional = .{ .region = "us-central1", .name = "web-tpl" } }, .{}));
    var one = try c.getInstance(zone, "web-1");
    defer one.deinit();
    try testing.expectEqualStrings("e2-small", one.value.machine_type);
    try testing.expectEqualStrings("web", one.value.label("role").?);
    try testing.expectEqual(types.ProvisioningModel.spot, one.value.scheduling.provisioning_model);
    var two = try c.getInstance(zone, "web-2");
    defer two.deinit();
    try testing.expectEqualStrings("e2-medium", two.value.machine_type);
    try testing.expectError(error.NotFound, c.insertFromTemplate(zone, "web-3", .{ .global = "nonesuch" }, .{}));
    try testing.expect(std.mem.indexOf(u8, f.diag.message(), "global/instanceTemplates/nonesuch' was not found") != null);
}

test "FakeCompute: a standard VM reads as production's did, its automatic restart as asked" {
    var f: Fixture = undefined;
    try f.init(testing.allocator, .{});
    defer f.deinit();
    var standard = spot_spec;
    standard.spot = false;
    standard.automatic_restart = false;
    try f.settle(f.client.insertInstance(zone, standard, .{}));
    var vm = try f.client.getInstance(zone, "web-1");
    defer vm.deinit();
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    var scratch: std.heap.ArenaAllocator = .init(testing.allocator);
    defer scratch.deinit();
    const want = try @import("codec.zig").decodeInstance(arena_state.allocator(), scratch.allocator(), production.instance_standard_restartless);
    try testing.expectEqual(want.scheduling.provisioning_model, vm.value.scheduling.provisioning_model);
    try testing.expectEqual(want.scheduling.automatic_restart, vm.value.scheduling.automatic_restart);
    try testing.expectEqual(want.scheduling.preemptible, vm.value.scheduling.preemptible);
    try testing.expectEqualStrings(want.scheduling.on_host_maintenance, vm.value.scheduling.on_host_maintenance);
    try testing.expectEqual(want.scheduling.termination_action, vm.value.scheduling.termination_action);
}

test "FakeCompute: finishOperations finishes what is still running" {
    var f: Fixture = undefined;
    try f.init(testing.allocator, .{ .write_waits = 3 });
    defer f.deinit();
    var a = try f.client.insertInstance(zone, spot_spec, .{});
    defer a.deinit();
    var b = try f.client.insertInstance(zone, specWith("name", "web-2"), .{});
    defer b.deinit();
    try testing.expectEqual(types.Status.provisioning, try f.status(zone, "web-2"));
    f.fake.finishOperations();
    try testing.expectEqual(types.Status.running, try f.status(zone, "web-1"));
    try testing.expectEqual(types.Status.running, try f.status(zone, "web-2"));
    var read = try f.client.getOperation(a.value.ref());
    defer read.deinit();
    try testing.expect(read.value.succeeded());
}

/// The error's status, reason and message from a body in Compute's
/// older shape.
fn refusalOf(arena: std.mem.Allocator, body: []const u8) !struct { code: i64, reason: []const u8, message: []const u8 } {
    const parsed = try std.json.parseFromSliceLeaky(std.json.Value, arena, body, .{});
    const e = parsed.object.get("error").?.object;
    return .{
        .code = e.get("code").?.integer,
        .reason = e.get("errors").?.array.items[0].object.get("reason").?.string,
        .message = e.get("message").?.string,
    };
}

test "FakeCompute: a write's refusals in production's words" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    var clock: test_util.FakeClock = .{};
    var fake: FakeCompute = .init(testing.allocator, clock.io(), .{ .project_id = "extractctl" });
    defer fake.deinit();
    try fake.putInstance(.{ .zone = zone, .name = "zigps-m0-11031830-a" });
    try fake.putInstance(.{ .zone = zone, .name = "zigps-m0-11031830-s", .deletion_protection = true });
    const disks = "\"disks\":[{\"boot\":true,\"initializeParams\":{\"sourceImage\":\"projects/debian-cloud/global/images/family/debian-12\"}}]";
    const insert = "https://compute.googleapis.com/compute/v1/projects/extractctl/zones/us-central1-a/instances";
    const Case = struct { method: core.transport.Method = .POST, url: []const u8 = insert, body: ?[]const u8, want: []const u8 };
    const cases = [_]Case{
        .{ .body = "{\"name\":\"zigps-m0-11031830-a\",\"machineType\":\"zones/us-central1-a/machineTypes/e2-micro\"," ++ disks ++ "}", .want = production.already_exists },
        .{ .body = "{\"name\":\"zigps-m0-b\",\"machineType\":\"zones/us-central1-a/machineTypes/e2-nonesuch\"," ++ disks ++ "}", .want = production.insert_bad_machine_type },
        .{ .body = "{\"name\":\"zigps-m0-b\",\"machineType\":\"zones/us-central1-a/machineTypes/e2-micro\",\"disks\":[{\"boot\":true,\"initializeParams\":{\"sourceImage\":\"projects/debian-cloud/global/images/family/nonesuch-99\"}}]}", .want = production.insert_bad_image },
        .{ .body = "{\"name\":\"Bad_Name\",\"machineType\":\"zones/us-central1-a/machineTypes/e2-micro\"," ++ disks ++ "}", .want = production.insert_bad_name },
        .{ .body = "{\"name\":\"zigps-m0-11031830-term\",\"machineType\":\"zones/us-central1-a/machineTypes/e2-micro\"," ++ disks ++ ",\"scheduling\":{\"onHostMaintenance\":\"TERMINATE\",\"automaticRestart\":false}}", .want = production.e2_terminate },
        .{ .method = .DELETE, .url = insert ++ "/zigps-m0-11031830-s?requestId=" ++ given_id, .body = null, .want = production.deletion_protected },
        .{ .url = insert ++ "?sourceInstanceTemplate=projects%2Fextractctl%2Fglobal%2FinstanceTemplates%2Fzigps-nonesuch", .body = "{\"name\":\"zigps-9e4cc1-x\"}", .want = production.template_not_found },
    };
    for (cases, 0..) |case, n| {
        errdefer std.debug.print("case {d}\n", .{n});
        const got = try fake.serve(.{ .method = case.method, .url = case.url, .bearer = "t", .body = case.body }, a);
        const want = try refusalOf(a, case.want);
        const have = try refusalOf(a, got.body);
        try testing.expectEqual(want.code, have.code);
        try testing.expectEqual(@as(u16, @intCast(want.code)), got.status);
        try testing.expectEqualStrings(want.reason, have.reason);
        try testing.expectEqualStrings(want.message, have.message);
    }
}

/// One VM's life as a model holds it, beside the fake's.
const Model = struct {
    exists: bool = false,
    status: types.Status = .running,
    protected: bool = false,
};

const Verb = enum { insert, start, stop, suspend_, resume_, reset, delete, replay };

/// Random writes to three VMs in one zone, some answers lost or their
/// connections dropped, each waited on: every answer and every VM's status
/// agrees with a model of what production showed, and a write retried
/// after a lost answer, or sent again with its id, lands once.
fn writesProperty(_: void, input: []const u8) !void {
    const gpa = test_util.propertyAllocator();
    var g: test_util.ByteGen = .init(input);
    var f: Fixture = undefined;
    try f.init(gpa, .{ .write_waits = g.intRange(u8, 0, 2) });
    defer f.deinit();
    var run: WriteRun = .{ .f = &f };
    const steps = g.intRange(u8, 1, 24);
    for (0..steps) |_| {
        try run.step(&g);
        try run.check();
    }
}

const WriteRun = struct {
    f: *Fixture,
    model: [3]Model = .{ .{}, .{}, .{} },
    /// The last write that landed, to send again with its id.
    last: ?Last = null,

    const names = [_][]const u8{ "vm-0", "vm-1", "vm-2" };
    const Last = struct { verb: Verb, vm: usize, id: [36]u8 };

    fn step(r: *WriteRun, g: *test_util.ByteGen) !void {
        const vm = g.intRange(u8, 0, 2);
        const verb = g.pick(Verb, std.enums.values(Verb));
        const protect = g.boolean();
        switch (g.intRange(u8, 0, 5)) {
            0 => r.f.fake.loseNext(1, 503),
            1 => r.f.fake.dropNext(1),
            else => {},
        }
        if (verb == .replay) return r.replay();
        var id_buf: [36]u8 = undefined;
        const id = r.f.client.newRequestId(&id_buf);
        const want = expected(verb, &r.model[vm], protect);
        const result = send(&r.f.client, verb, names[vm], id, protect);
        if (want) |e| return testing.expectError(e, result);
        var op = try result;
        defer op.deinit();
        var done = try r.f.client.waitOperation(op.value.ref(), .{});
        defer done.deinit();
        try testing.expect(done.value.succeeded());
        r.last = .{ .verb = verb, .vm = vm, .id = id_buf };
    }

    /// The last write again with its id: its operation, nothing changed,
    /// so the model is left as it is.
    fn replay(r: *WriteRun) !void {
        const last = r.last orelse return;
        var op = send(&r.f.client, last.verb, names[last.vm], &last.id, false) catch |err| {
            std.debug.print("replay of {t} answered {t}\n", .{ last.verb, err });
            return err;
        };
        op.deinit();
    }

    fn check(r: *WriteRun) !void {
        for (names, r.model) |n, want| {
            const got = r.f.client.getInstance(zone, n);
            if (!want.exists) {
                try testing.expectError(error.NotFound, got);
                continue;
            }
            var vm = try got;
            defer vm.deinit();
            try testing.expectEqual(want.status, vm.value.status);
        }
    }
};

fn send(c: *Client, verb: Verb, name: []const u8, id: []const u8, protect: bool) anyerror!types.Owned(types.Operation) {
    return switch (verb) {
        .insert => c.insertInstance(zone, .{
            .name = name,
            .machine_type = "e2-micro",
            .image = .{ .family = .{ .project = "debian-cloud", .name = "debian-12" } },
            .deletion_protection = protect,
        }, .{ .request_id = id }),
        .start => c.startInstance(zone, name, .{ .request_id = id }),
        .stop => c.stopInstance(zone, name, .{ .request_id = id }),
        .suspend_ => c.suspendInstance(zone, name, .{ .request_id = id }),
        .resume_ => c.resumeInstance(zone, name, .{ .request_id = id }),
        .reset => c.resetInstance(zone, name, .{ .request_id = id }),
        .delete => c.deleteInstance(zone, name, .{ .request_id = id }),
        .replay => unreachable,
    };
}

/// What production showed of each verb, as a model holds it: the
/// statuses it was taken from, and the status once DONE.
const moves = [_]struct { Verb, []const types.Status, types.Status }{
    .{ .start, &.{ .terminated, .running }, .running },
    .{ .stop, &.{ .running, .terminated }, .terminated },
    .{ .suspend_, &.{.running}, .suspended },
    .{ .resume_, &.{.suspended}, .running },
    .{ .reset, &.{.running}, .running },
};

/// The error the fake should answer `verb` on a VM the model holds as
/// `m`, or null with the model moved; `protect` is the protection an
/// insert asks for.
fn expected(verb: Verb, m: *Model, protect: bool) ?anyerror {
    if (verb == .insert) {
        if (m.exists) return error.AlreadyExists;
        m.* = .{ .exists = true, .status = .running, .protected = protect };
        return null;
    }
    if (!m.exists) return error.NotFound;
    if (verb == .delete) {
        if (m.protected) return error.InvalidArgument;
        m.exists = false;
        return null;
    }
    for (moves) |move| {
        if (move[0] != verb or std.mem.indexOfScalar(types.Status, move[1], m.status) == null) continue;
        m.status = move[2];
        return null;
    }
    return error.Unimplemented;
}

test "slow property compute fake writes: the lifecycle against a model, through lost answers" {
    // About 30 ms a run here, each up to 24 writes waited on and read
    // back; the fuzzer gives it volume, in a job of its own.
    try test_util.fuzzBytes({}, writesProperty, .{
        .random_runs = 40,
        .max_len = 128,
    });
}
