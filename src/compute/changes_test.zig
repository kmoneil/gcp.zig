//! The changes' tests: requests as sent and previewed, refusals before
//! sending, production's refusals and failed operations, the update
//! helpers' read and resend, and FakeCompute's changes held to
//! production's words.

const std = @import("std");
const testing = std.testing;
const core = @import("core");

const types = @import("types.zig");
const test_util = @import("test_util.zig");
const production = @import("production_bodies.zig");
const codec = @import("codec.zig");
const Harness = test_util.Harness;
const Client = @import("Client.zig");
const FakeCompute = @import("fake_compute.zig").FakeCompute;

const base = "https://compute.googleapis.com/compute/v1/projects/my-project/";
const zone = "us-central1-a";
const id = "8068f1b8-03fc-4f7f-a5bd-d5e775aa7212";

fn reply(status: u16, body: []const u8) test_util.FakeTransport.Reply {
    return .{ .respond = .{ .status = status, .body = body } };
}

fn writer(h: *Harness, script: []const test_util.FakeTransport.Reply) !void {
    try h.initScope(script, .read_write);
    h.clock.random_byte = 0xab;
}

const ids: types.WriteOptions = .{ .request_id = id };
const labels = [_]types.Label{ .{ .key = "env", .value = "prod" }, .{ .key = "team", .value = "data" } };
const items = [_]types.MetadataItem{.{ .key = "startup-script", .value = "echo hi" }};
const tags = [_][]const u8{ "http-server", "ssh" };

test "every change's method, path and body, and its preview byte for byte" {
    var h: Harness = undefined;
    const op = reply(200, production.operation_set_labels);
    try writer(&h, &.{ op, op, op, op, op, op, op, op });
    defer h.deinit();
    const c = &h.client;
    const disk: types.AttachSpec = .{ .disk = "data-1", .device_name = "data", .force = true };
    const sched: types.SchedulingChange = .{ .spot = false, .on_host_maintenance = .migrate, .automatic_restart = true };
    const results = [_]anyerror!types.Owned(types.Operation){
        c.setLabels(zone, "web-1", &labels, "rNhSjTzLR00=", ids),
        c.setMetadata(zone, "web-1", &items, "inPgXPhJXaM=", ids),
        c.setTags(zone, "web-1", &tags, "42WmSpB8rSM=", ids),
        c.setMachineType(zone, "web-1", "e2-small", ids),
        c.setScheduling(zone, "web-1", sched, ids),
        c.setDeletionProtection(zone, "web-1", false, ids),
        c.attachDisk(zone, "web-1", disk, ids),
        c.detachDisk(zone, "web-1", "data", ids),
    };
    for (results) |r| {
        var owned = try r;
        owned.deinit();
    }
    var previews = [_]types.Owned(core.PreparedRequest){
        try c.setLabelsRequest(zone, "web-1", &labels, "rNhSjTzLR00=", ids),
        try c.setMetadataRequest(zone, "web-1", &items, "inPgXPhJXaM=", ids),
        try c.setTagsRequest(zone, "web-1", &tags, "42WmSpB8rSM=", ids),
        try c.setMachineTypeRequest(zone, "web-1", "e2-small", ids),
        try c.setSchedulingRequest(zone, "web-1", sched, ids),
        try c.setDeletionProtectionRequest(zone, "web-1", false, ids),
        try c.attachDiskRequest(zone, "web-1", disk, ids),
        try c.detachDiskRequest(zone, "web-1", "data", ids),
    };
    defer for (&previews) |*p| p.deinit();
    const vm = base ++ "zones/us-central1-a/instances/web-1/";
    const rid = "requestId=" ++ id;
    const want = [_]struct { []const u8, []const u8 }{
        .{ vm ++ "setLabels?" ++ rid, "{\"labels\":{\"env\":\"prod\",\"team\":\"data\"},\"labelFingerprint\":\"rNhSjTzLR00=\"}" },
        .{ vm ++ "setMetadata?" ++ rid, "{\"fingerprint\":\"inPgXPhJXaM=\",\"items\":[{\"key\":\"startup-script\",\"value\":\"echo hi\"}]}" },
        .{ vm ++ "setTags?" ++ rid, "{\"items\":[\"http-server\",\"ssh\"],\"fingerprint\":\"42WmSpB8rSM=\"}" },
        .{ vm ++ "setMachineType?" ++ rid, "{\"machineType\":\"zones/us-central1-a/machineTypes/e2-small\"}" },
        .{ vm ++ "setScheduling?" ++ rid, "{\"automaticRestart\":true,\"onHostMaintenance\":\"MIGRATE\",\"provisioningModel\":\"STANDARD\",\"preemptible\":false}" },
        .{ vm ++ "setDeletionProtection?deletionProtection=false&" ++ rid, "" },
        .{ vm ++ "attachDisk?forceAttach=true&" ++ rid, "{\"source\":\"zones/us-central1-a/disks/data-1\",\"deviceName\":\"data\",\"mode\":\"READ_WRITE\",\"autoDelete\":false}" },
        .{ vm ++ "detachDisk?deviceName=data&" ++ rid, "" },
    };
    for (want, h.fake.requests.items, previews) |w, sent, p| {
        try testing.expectEqual(core.transport.Method.POST, sent.method);
        try testing.expectEqualStrings(w[0], sent.url);
        try testing.expectEqualStrings(w[1], sent.body.?);
        try testing.expectEqualStrings(sent.url, p.value.url);
        try testing.expectEqualStrings(sent.body.?, p.value.body);
    }
}

test "changes refused before sending" {
    var h: Harness = undefined;
    try writer(&h, &.{});
    defer h.deinit();
    const c = &h.client;
    try testing.expectError(error.InvalidOptions, c.setLabels(zone, "web-1", &labels, "", .{}));
    try testing.expect(std.mem.indexOf(u8, h.diag.message(), "label_fingerprint") != null);
    try testing.expectError(error.InvalidOptions, c.setLabels(zone, "web-1", &.{.{ .key = "Env", .value = "x" }}, "f=", .{}));
    try testing.expectError(error.InvalidOptions, c.setMetadata(zone, "web-1", &.{.{ .key = "a b" }}, "f=", .{}));
    try testing.expectError(error.InvalidOptions, c.setMetadata(zone, "web-1", &items, "a b", .{}));
    try testing.expectError(error.InvalidName, c.setTags(zone, "web-1", &.{"Http"}, "f=", .{}));
    try testing.expectError(error.InvalidName, c.setMachineType(zone, "web-1", "e2 small", .{}));
    try testing.expectError(error.InvalidOptions, c.setScheduling(zone, "web-1", .{}, .{}));
    try testing.expect(std.mem.indexOf(u8, h.diag.message(), "changes nothing") != null);
    try testing.expectError(error.InvalidOptions, c.setScheduling(zone, "web-1", .{ .spot = true, .automatic_restart = true }, .{}));
    try testing.expectError(error.InvalidOptions, c.setScheduling(zone, "web-1", .{ .spot = true, .on_host_maintenance = .migrate }, .{}));
    try testing.expectError(error.InvalidOptions, c.setScheduling(zone, "web-1", .{ .max_run_duration_s = 0 }, .{}));
    try testing.expectError(error.InvalidOptions, c.setScheduling(zone, "web-1", .{ .termination_action = .unknown }, .{}));
    try testing.expectError(error.InvalidName, c.detachDisk(zone, "web-1", "a b", .{}));
    try testing.expectError(error.InvalidName, c.attachDisk(zone, "web-1", .{ .disk = "d", .device_name = "a/b" }, .{}));
    try testing.expectError(error.InvalidOptions, c.attachDisk(zone, "web-1", .{ .disk = "a b" }, .{}));
    try testing.expectError(error.InvalidName, c.setDeletionProtection(zone, "Web", true, .{}));
    try testing.expectError(error.InvalidOptions, c.updateLabels(zone, "web-1", .{ .set = &labels, .remove = &.{"env"} }));
    try testing.expectError(error.InvalidOptions, c.updateMetadata(zone, "web-1", .{ .remove = &.{"a.b"} }));
    try testing.expectEqual(0, h.fake.requests.items.len);

    var ro: Harness = undefined;
    try ro.init(&.{});
    defer ro.deinit();
    try testing.expectError(error.InvalidOptions, ro.client.setLabels(zone, "web-1", &labels, "f=", .{}));
    try testing.expectError(error.InvalidOptions, ro.client.attachDiskRequest(zone, "web-1", .{ .disk = "d" }, .{}));
    try testing.expectEqual(0, ro.fake.requests.items.len);
}

test "production's refusals of a change, and its failed operations" {
    var h: Harness = undefined;
    try writer(&h, &.{
        reply(412, production.stale_label_fingerprint),
        reply(412, production.stale_metadata_fingerprint),
        reply(412, production.stale_tags_fingerprint),
        reply(400, production.scheduling_running),
        reply(400, production.scheduling_standard_preemptible),
        reply(400, production.machine_type_unknown),
        reply(404, production.disk_not_found),
        reply(200, production.operation_disk_in_use),
        reply(200, production.operation_no_such_device),
        reply(200, production.operation_protection),
    });
    defer h.deinit();
    const c = &h.client;
    try testing.expectError(error.FailedPrecondition, c.setLabels(zone, "web-1", &labels, "f=", .{}));
    try testing.expect(std.mem.indexOf(u8, h.diag.message(), "Labels fingerprint either invalid") != null);
    try testing.expectError(error.FailedPrecondition, c.setMetadata(zone, "web-1", &items, "f=", .{}));
    try testing.expectError(error.FailedPrecondition, c.setTags(zone, "web-1", &tags, "f=", .{}));
    try testing.expect(std.mem.indexOf(u8, h.diag.message(), "Tags fingerprint") != null);
    try testing.expectError(error.InvalidArgument, c.setScheduling(zone, "web-1", .{ .automatic_restart = false }, .{}));
    try testing.expect(std.mem.indexOf(u8, h.diag.message(), "while the instance is running") != null);
    try testing.expectError(error.InvalidArgument, c.setScheduling(zone, "web-1", .{ .spot = false }, .{}));
    try testing.expectError(error.InvalidArgument, c.setMachineType(zone, "web-1", "e2-nonesuch", .{}));
    try testing.expect(std.mem.indexOf(u8, h.diag.message(), "does not exist in zone") != null);
    try testing.expectError(error.NotFound, c.attachDisk(zone, "web-1", .{ .disk = "zigps-m3-nonesuch" }, .{}));
    var in_use = try c.attachDisk(zone, "web-1", .{ .disk = "d" }, .{});
    defer in_use.deinit();
    try testing.expectEqualStrings("RESOURCE_IN_USE_BY_ANOTHER_RESOURCE", in_use.value.failure.?.code());
    try testing.expect(!in_use.value.failure.?.stockout());
    var no_device = try c.detachDisk(zone, "web-1", "zigps-data", .{});
    defer no_device.deinit();
    try testing.expectEqualStrings("INVALID_USAGE", no_device.value.failure.?.code());
    var protect = try c.setDeletionProtection(zone, "web-1", true, .{});
    defer protect.deinit();
    try testing.expect(protect.value.succeeded());
    // Not one retried.
    try testing.expectEqual(10, h.fake.requests.items.len);
}

test "decode: a VM with two disks, and one read right after setLabels" {
    var out: std.heap.ArenaAllocator = .init(testing.allocator);
    defer out.deinit();
    var scratch: std.heap.ArenaAllocator = .init(testing.allocator);
    defer scratch.deinit();
    const vm = try codec.decodeInstance(out.allocator(), scratch.allocator(), production.instance_two_disks);
    try testing.expectEqual(2, vm.disks.len);
    try testing.expect(vm.disks[0].boot);
    try testing.expectEqualStrings("zigps-data", vm.disks[1].device_name);
    try testing.expect(!vm.disks[1].auto_delete);
    try testing.expectEqual(1, vm.disks[1].index.?);
    try testing.expect(std.mem.endsWith(u8, vm.disks[1].source, "/disks/zigps-m3-11032241-d"));
    const relabelled = try codec.decodeInstance(out.allocator(), scratch.allocator(), production.instance_relabelled);
    try testing.expectEqualStrings("one", relabelled.label("probe").?);
    try testing.expectEqualStrings("GlFen7VtVrc=", relabelled.label_fingerprint);
}

test "updateLabels: read, merge, set under the fingerprint read; again after a 412" {
    var h: Harness = undefined;
    try writer(&h, &.{
        reply(200, production.instance_spot),
        reply(412, production.stale_label_fingerprint),
        reply(200, production.instance_relabelled),
        reply(200, production.operation_set_labels),
    });
    defer h.deinit();
    var op = try h.client.updateLabels(zone, "zigps-m3-11032241-a", .{ .set = &.{ .{ .key = "probe", .value = "two" }, .{ .key = "owner", .value = "kim" } }, .remove = &.{"tool"} });
    defer op.deinit();
    try testing.expectEqualStrings("compute.instance.setLabels", op.value.operation_type);
    const r = h.fake.requests.items;
    try testing.expectEqual(4, r.len);
    try testing.expectEqual(core.transport.Method.GET, r[2].method);
    // The second round's labels: read again, probe changed in place,
    // tool gone, owner last, under the fingerprint the second read gave.
    try testing.expectEqualStrings(
        \\{"labels":{"purpose":"gcp-zig-test","probe":"two","owner":"kim"},"labelFingerprint":"GlFen7VtVrc="}
    , r[3].body.?);
}

test "updateMetadata: an item set in place, one added, one removed" {
    var h: Harness = undefined;
    try writer(&h, &.{ reply(200, production.instance_spot), reply(200, production.operation_set_labels) });
    defer h.deinit();
    var vm_out: std.heap.ArenaAllocator = .init(testing.allocator);
    defer vm_out.deinit();
    var scratch: std.heap.ArenaAllocator = .init(testing.allocator);
    defer scratch.deinit();
    const vm = try codec.decodeInstance(vm_out.allocator(), scratch.allocator(), production.instance_spot);
    var op = try h.client.updateMetadata(zone, vm.name, .{ .set = &.{ .{ .key = "enable-guest-attributes", .value = "FALSE" }, .{ .key = "role", .value = "web" } }, .remove = &.{"startup-script"} });
    defer op.deinit();
    const sent = h.fake.requests.items[1].body.?;
    try testing.expect(std.mem.indexOf(u8, sent, "\"startup-script\"") == null);
    try testing.expect(std.mem.indexOf(u8, sent, "{\"key\":\"enable-guest-attributes\",\"value\":\"FALSE\"},{\"key\":\"role\",\"value\":\"web\"}") != null);
    try testing.expect(std.mem.startsWith(u8, sent, try std.fmt.allocPrint(scratch.allocator(), "{{\"fingerprint\":\"{s}\"", .{vm.metadata.fingerprint})));
}

test "updateLabels gives up after the retry policy's rounds" {
    var h: Harness = undefined;
    const vm = reply(200, production.instance_spot);
    const stale = reply(412, production.stale_label_fingerprint);
    try writer(&h, &.{ vm, stale, vm, stale, vm, stale, vm, stale, vm, stale });
    defer h.deinit();
    try testing.expectError(error.FailedPrecondition, h.client.updateLabels(zone, "a", .{ .set = &.{.{ .key = "k", .value = "v" }} }));
    try testing.expectEqual(2 * h.client.retry.max_attempts, h.fake.requests.items.len);
}

// Over FakeCompute.

const Fixture = struct {
    clock: test_util.FakeClock,
    fake: FakeCompute,
    token: test_util.FakeTokenProvider,
    diag: core.Diagnostics,
    client: Client,

    fn init(f: *Fixture, options: FakeCompute.Options) !void {
        return f.initWith(testing.allocator, options);
    }

    fn initWith(f: *Fixture, gpa: std.mem.Allocator, options: FakeCompute.Options) !void {
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

    fn read(f: *Fixture, name: []const u8) !types.Owned(types.Instance) {
        return f.client.getInstance(zone, name);
    }

    /// Waits for `op`; frees both; answers whether it succeeded, and its
    /// failure's code.
    fn settle(f: *Fixture, op: anyerror!types.Owned(types.Operation)) ![]const u8 {
        var started = try op;
        defer started.deinit();
        var done = try f.client.waitOperation(started.value.ref(), .{});
        defer done.deinit();
        try testing.expect(done.value.done());
        const failure = done.value.failure orelse return "";
        return if (std.mem.eql(u8, failure.code(), "RESOURCE_IN_USE_BY_ANOTHER_RESOURCE"))
            "in use"
        else if (std.mem.eql(u8, failure.code(), "INVALID_USAGE"))
            "no device"
        else if (std.mem.eql(u8, failure.code(), "UNSUPPORTED_OPERATION"))
            "unsupported"
        else
            "failed";
    }
};

test "FakeCompute: labels, metadata and tags under their fingerprints" {
    var f: Fixture = undefined;
    try f.init(.{});
    defer f.deinit();
    try f.fake.putInstance(.{ .zone = zone, .name = "web-1", .labels = &.{.{ .key = "env", .value = "test" }}, .tags = &.{"ssh"} });
    var before = try f.read("web-1");
    defer before.deinit();
    try testing.expectEqualStrings("", try f.settle(f.client.setLabels(zone, "web-1", &labels, before.value.label_fingerprint, .{})));
    var after = try f.read("web-1");
    defer after.deinit();
    try testing.expectEqualStrings("prod", after.value.label("env").?);
    try testing.expect(!std.mem.eql(u8, before.value.label_fingerprint, after.value.label_fingerprint));
    // The old one is stale now.
    try testing.expectError(error.FailedPrecondition, f.client.setLabels(zone, "web-1", &.{}, before.value.label_fingerprint, .{}));
    try testing.expectEqualStrings("", try f.settle(f.client.setMetadata(zone, "web-1", &items, after.value.metadata.fingerprint, .{})));
    try testing.expectError(error.FailedPrecondition, f.client.setMetadata(zone, "web-1", &.{}, after.value.metadata.fingerprint, .{}));
    try testing.expectEqualStrings("", try f.settle(f.client.setTags(zone, "web-1", &.{}, after.value.tags.fingerprint, .{})));
    try testing.expectError(error.FailedPrecondition, f.client.setTags(zone, "web-1", &tags, after.value.tags.fingerprint, .{}));
    var last = try f.read("web-1");
    defer last.deinit();
    try testing.expectEqualStrings("echo hi", last.value.metadataValue("startup-script").?);
    try testing.expectEqual(0, last.value.tags.items.len);
    // And the helpers, which read for themselves.
    try testing.expectEqualStrings("", try f.settle(f.client.updateLabels(zone, "web-1", .{ .set = &.{.{ .key = "owner", .value = "kim" }}, .remove = &.{"team"} })));
    try testing.expectEqualStrings("", try f.settle(f.client.updateMetadata(zone, "web-1", .{ .remove = &.{"startup-script"} })));
    var helped = try f.read("web-1");
    defer helped.deinit();
    try testing.expectEqual(2, helped.value.labels.len);
    try testing.expectEqualStrings("kim", helped.value.label("owner").?);
    try testing.expect(helped.value.label("team") == null);
    try testing.expectEqual(0, helped.value.metadata.items.len);
}

test "FakeCompute: a machine type, on a stopped VM only" {
    var f: Fixture = undefined;
    try f.init(.{});
    defer f.deinit();
    try f.fake.putInstance(.{ .zone = zone, .name = "web-1" });
    try testing.expectEqualStrings("unsupported", try f.settle(f.client.setMachineType(zone, "web-1", "e2-small", .{})));
    try testing.expectError(error.InvalidArgument, f.client.setMachineType(zone, "web-1", "e2-nonesuch", .{}));
    try f.fake.setStatus(zone, "web-1", .terminated);
    try testing.expectEqualStrings("", try f.settle(f.client.setMachineType(zone, "web-1", "e2-small", .{})));
    var vm = try f.read("web-1");
    defer vm.deinit();
    try testing.expectEqualStrings("e2-small", vm.value.machine_type);
}

test "FakeCompute: scheduling, field by field on a stopped VM" {
    var f: Fixture = undefined;
    try f.init(.{});
    defer f.deinit();
    try f.fake.putInstance(.{ .zone = zone, .name = "web-1", .spot = true, .max_run_duration_s = 3600, .termination_action = .delete });
    try testing.expectError(error.InvalidArgument, f.client.setScheduling(zone, "web-1", .{ .automatic_restart = false }, .{}));
    try testing.expect(std.mem.indexOf(u8, f.diag.message(), "Termination time cannot be changed while the instance is running.") != null);
    try testing.expectError(error.InvalidArgument, f.client.setScheduling(zone, "web-1", .{ .max_run_duration_s = 7200 }, .{}));
    try testing.expect(std.mem.indexOf(u8, f.diag.message(), "Max run duration cannot be changed") != null);
    try f.fake.setStatus(zone, "web-1", .terminated);
    try testing.expectEqualStrings("", try f.settle(f.client.setScheduling(zone, "web-1", .{ .max_run_duration_s = 7200 }, .{})));
    var limited = try f.read("web-1");
    defer limited.deinit();
    try testing.expectEqual(7200, limited.value.scheduling.max_run_duration_s.?);
    // The rest kept.
    try testing.expectEqual(types.ProvisioningModel.spot, limited.value.scheduling.provisioning_model);
    try testing.expectEqual(types.TerminationAction.delete, limited.value.scheduling.termination_action.?);
    try testing.expectEqualStrings("", try f.settle(f.client.setScheduling(zone, "web-1", .{ .spot = false, .on_host_maintenance = .migrate, .automatic_restart = true }, .{})));
    var standard = try f.read("web-1");
    defer standard.deinit();
    try testing.expectEqual(types.ProvisioningModel.standard, standard.value.scheduling.provisioning_model);
    try testing.expectEqualStrings("MIGRATE", standard.value.scheduling.on_host_maintenance);
    try testing.expectEqual(true, standard.value.scheduling.automatic_restart.?);
    // And back, preemptible with it, as the client sends it.
    try testing.expectEqualStrings("", try f.settle(f.client.setScheduling(zone, "web-1", .{ .spot = true, .automatic_restart = false, .on_host_maintenance = .terminate }, .{})));
    var spot = try f.read("web-1");
    defer spot.deinit();
    try testing.expectEqual(types.ProvisioningModel.spot, spot.value.scheduling.provisioning_model);
    // A running VM with no run limit: not measured.
    try f.fake.putInstance(.{ .zone = zone, .name = "web-2" });
    try testing.expectError(error.Unimplemented, f.client.setScheduling(zone, "web-2", .{ .automatic_restart = false }, .{}));
}

test "FakeCompute: deletion protection, DONE at once" {
    var f: Fixture = undefined;
    try f.init(.{});
    defer f.deinit();
    try f.fake.putInstance(.{ .zone = zone, .name = "web-1" });
    var on = try f.client.setDeletionProtection(zone, "web-1", true, .{});
    defer on.deinit();
    try testing.expect(on.value.succeeded());
    try testing.expectError(error.InvalidArgument, f.client.deleteInstance(zone, "web-1", .{}));
    var off = try f.client.setDeletionProtection(zone, "web-1", false, .{});
    defer off.deinit();
    try testing.expectEqualStrings("", try f.settle(f.client.deleteInstance(zone, "web-1", .{})));
}

test "FakeCompute: disks attached, refused in use, detached, freed with the VM" {
    var f: Fixture = undefined;
    try f.init(.{});
    defer f.deinit();
    try f.fake.putInstance(.{ .zone = zone, .name = "web-1" });
    try f.fake.putInstance(.{ .zone = zone, .name = "web-2" });
    try f.fake.putDisk(.{ .zone = zone, .name = "data-1", .size_gb = 20 });
    try f.fake.putDisk(.{ .zone = zone, .name = "scratch", .size_gb = 10 });
    try testing.expectError(error.AlreadyExists, f.fake.putDisk(.{ .zone = zone, .name = "data-1" }));
    try testing.expectEqualStrings("", try f.settle(f.client.attachDisk(zone, "web-1", .{ .disk = "data-1", .device_name = "data" }, .{})));
    try testing.expectEqualStrings("", try f.settle(f.client.attachDisk(zone, "web-1", .{ .disk = "scratch", .auto_delete = true, .read_only = true }, .{})));
    var two = try f.read("web-1");
    defer two.deinit();
    try testing.expectEqual(3, two.value.disks.len);
    try testing.expectEqualStrings("data", two.value.disks[1].device_name);
    try testing.expectEqual(20, two.value.disks[1].size_gb.?);
    try testing.expectEqualStrings("persistent-disk-2", two.value.disks[2].device_name);
    try testing.expectEqualStrings("READ_ONLY", two.value.disks[2].mode);
    // In use, by this VM or another; a VM's boot disk too.
    try testing.expectEqualStrings("in use", try f.settle(f.client.attachDisk(zone, "web-1", .{ .disk = "data-1" }, .{})));
    try testing.expectEqualStrings("in use", try f.settle(f.client.attachDisk(zone, "web-2", .{ .disk = "data-1" }, .{})));
    try testing.expectEqualStrings("in use", try f.settle(f.client.attachDisk(zone, "web-2", .{ .disk = "web-1" }, .{})));
    try testing.expectError(error.NotFound, f.client.attachDisk(zone, "web-2", .{ .disk = "nonesuch" }, .{}));
    try testing.expectEqualStrings("", try f.settle(f.client.detachDisk(zone, "web-1", "data", .{})));
    try testing.expectEqualStrings("no device", try f.settle(f.client.detachDisk(zone, "web-1", "data", .{})));
    try testing.expectEqualStrings("", try f.settle(f.client.attachDisk(zone, "web-2", .{ .disk = "data-1" }, .{})));
    // web-2 deleted frees data-1; web-1 deleted takes scratch with it.
    try testing.expectEqualStrings("", try f.settle(f.client.deleteInstance(zone, "web-2", .{})));
    try testing.expectEqualStrings("", try f.settle(f.client.deleteInstance(zone, "web-1", .{})));
    try f.fake.putInstance(.{ .zone = zone, .name = "web-3" });
    try testing.expectEqualStrings("", try f.settle(f.client.attachDisk(zone, "web-3", .{ .disk = "data-1" }, .{})));
    try testing.expectError(error.NotFound, f.client.attachDisk(zone, "web-3", .{ .disk = "scratch" }, .{}));
}

/// The error's status, reason and message from a refusal, or the code
/// and message of a failed operation's first error.
fn wordsOf(arena: std.mem.Allocator, body: []const u8) ![]const u8 {
    const parsed = try std.json.parseFromSliceLeaky(std.json.Value, arena, body, .{});
    const e = parsed.object.get("error").?.object;
    if (e.get("code")) |code| {
        const reason = e.get("errors").?.array.items[0].object.get("reason").?.string;
        return std.fmt.allocPrint(arena, "{d} {s} {s}", .{ code.integer, reason, e.get("message").?.string });
    }
    const first = e.get("errors").?.array.items[0].object;
    return std.fmt.allocPrint(arena, "DONE {s} {s}", .{ first.get("code").?.string, first.get("message").?.string });
}

test "FakeCompute: a change's refusals and failures in production's words" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    var clock: test_util.FakeClock = .{};
    var fake: FakeCompute = .init(testing.allocator, clock.io(), .{ .project_id = "extractctl", .write_waits = 0 });
    defer fake.deinit();
    const vm = "zigps-m3-11032241-a";
    try fake.putInstance(.{ .zone = zone, .name = vm, .spot = true, .max_run_duration_s = 3600, .termination_action = .delete });
    try fake.putInstance(.{ .zone = zone, .name = "zigps-d841c1-a", .status = .terminated });
    const standard_url = "https://compute.googleapis.com/compute/v1/projects/extractctl/zones/us-central1-a/instances/zigps-d841c1-a/";
    try fake.putDisk(.{ .zone = zone, .name = "zigps-m3-11032241-d" });
    const url = "https://compute.googleapis.com/compute/v1/projects/extractctl/zones/us-central1-a/instances/" ++ vm ++ "/";
    // Attach the disk first, so the second attach finds it in use.
    _ = try fake.serve(.{ .method = .POST, .url = url ++ "attachDisk", .bearer = "t", .body = "{\"source\":\"zones/us-central1-a/disks/zigps-m3-11032241-d\",\"deviceName\":\"zigps-data\"}" }, a);
    const Case = struct { []const u8, ?[]const u8, []const u8 };
    const cases = [_]Case{
        .{ url ++ "setTags", "{\"items\":[],\"fingerprint\":\"42WmSpB8rSM=\"}", production.stale_tags_fingerprint },
        .{ url ++ "setScheduling", "{\"automaticRestart\":false}", production.scheduling_running },
        .{ url ++ "setScheduling", "{\"maxRunDuration\":{\"seconds\":\"7200\"}}", production.scheduling_limit_running },
        .{ url ++ "setScheduling", "{\"provisioningModel\":\"STANDARD\"}", production.scheduling_standard_preemptible },
        .{ standard_url ++ "setScheduling", "{\"onHostMaintenance\":\"TERMINATE\",\"provisioningModel\":\"SPOT\"}", production.scheduling_spot_not_preemptible },
        .{ url ++ "setMachineType", "{\"machineType\":\"zones/us-central1-a/machineTypes/e2-nonesuch\"}", production.machine_type_unknown },
        .{ url ++ "attachDisk", "{\"source\":\"zones/us-central1-a/disks/zigps-m3-nonesuch\"}", production.disk_not_found },
        .{ url ++ "attachDisk", "{\"source\":\"zones/us-central1-a/disks/zigps-m3-11032241-d\"}", production.operation_disk_in_use },
        .{ url ++ "detachDisk?deviceName=nonesuch", null, production.operation_no_such_device },
    };
    for (cases, 0..) |case, n| {
        errdefer std.debug.print("case {d}\n", .{n});
        const got = try fake.serve(.{ .method = .POST, .url = case[0], .bearer = "t", .body = case[1] }, a);
        const want = try wordsOf(a, case[2]);
        // The device production was asked about was zigps-data.
        const have = try std.mem.replaceOwned(u8, a, try wordsOf(a, got.body), "'nonesuch'", "'zigps-data'");
        try testing.expectEqualStrings(want, have);
    }
}

/// What a read saw: how many label and tag changes had been taken then,
/// and the fingerprints it gave.
const Snapshot = struct {
    labels_gen: u32,
    tags_gen: u32,
    label_fp: [32]u8,
    label_fp_len: usize,
    tags_fp: [32]u8,
    tags_fp_len: usize,

    fn labelFp(s: *const Snapshot) []const u8 {
        return s.label_fp[0..s.label_fp_len];
    }

    fn tagsFp(s: *const Snapshot) []const u8 {
        return s.tags_fp[0..s.tags_fp_len];
    }
};

const label_keys = [_][]const u8{ "k0", "k1", "k2" };
const label_values = [_][]const u8{ "a", "b" };

/// The VM as a model holds it: a value or none for each key, the tags as
/// a count of one tag name, and how many changes of each were taken.
const ChangeModel = struct {
    labels: [3]?[]const u8 = .{ null, null, null },
    tag: bool = false,
    labels_gen: u32 = 0,
    tags_gen: u32 = 0,
};

/// Reads, label and tag changes under fresh and stale fingerprints, the
/// update helper, lost answers and dropped connections: a change is taken
/// exactly when its fingerprint is the VM's now, and what reads back is
/// the model's.
fn changesProperty(_: void, input: []const u8) !void {
    var g: test_util.ByteGen = .init(input);
    var f: Fixture = undefined;
    try f.initWith(test_util.propertyAllocator(), .{ .write_waits = g.intRange(u8, 0, 1) });
    defer f.deinit();
    try f.fake.putInstance(.{ .zone = zone, .name = "vm" });
    var model: ChangeModel = .{};
    var snaps: [4]Snapshot = undefined;
    var n_snaps: usize = 0;
    try snapshot(&f, &model, &snaps[0]);
    n_snaps = 1;
    const steps = g.intRange(u8, 1, 16);
    for (0..steps) |_| {
        switch (g.intRange(u8, 0, 5)) {
            0 => f.fake.loseNext(1, 503),
            1 => f.fake.dropNext(1),
            else => {},
        }
        const snap = &snaps[g.intRange(u8, 0, @intCast(n_snaps - 1))];
        switch (g.intRange(u8, 0, 3)) {
            0 => {
                const slot = if (n_snaps < snaps.len) n_snaps else g.intRange(u8, 0, snaps.len - 1);
                try snapshot(&f, &model, &snaps[slot]);
                n_snaps = @max(n_snaps, slot + 1);
            },
            1 => try changeLabels(&f, &model, snap, &g),
            2 => try changeTags(&f, &model, snap),
            else => try updateOne(&f, &model, &g),
        }
        try agrees(&f, &model);
    }
}

fn snapshot(f: *Fixture, model: *const ChangeModel, out: *Snapshot) !void {
    var vm = try f.read("vm");
    defer vm.deinit();
    out.* = .{ .labels_gen = model.labels_gen, .tags_gen = model.tags_gen, .label_fp = undefined, .label_fp_len = vm.value.label_fingerprint.len, .tags_fp = undefined, .tags_fp_len = vm.value.tags.fingerprint.len };
    @memcpy(out.label_fp[0..out.label_fp_len], vm.value.label_fingerprint);
    @memcpy(out.tags_fp[0..out.tags_fp_len], vm.value.tags.fingerprint);
}

fn changeLabels(f: *Fixture, model: *ChangeModel, snap: *const Snapshot, g: *test_util.ByteGen) !void {
    var want: [3]?[]const u8 = .{ null, null, null };
    var list: [3]types.Label = undefined;
    var n: usize = 0;
    for (label_keys, 0..) |k, i| if (g.boolean()) {
        const v = label_values[g.intRange(u8, 0, 1)];
        want[i] = v;
        list[n] = .{ .key = k, .value = v };
        n += 1;
    };
    const result = f.client.setLabels(zone, "vm", list[0..n], snap.labelFp(), .{});
    if (snap.labels_gen != model.labels_gen) return testing.expectError(error.FailedPrecondition, result);
    var op = try result;
    op.deinit();
    model.labels = want;
    model.labels_gen += 1;
}

fn changeTags(f: *Fixture, model: *ChangeModel, snap: *const Snapshot) !void {
    const want = !model.tag;
    const list: []const []const u8 = if (want) &.{"web"} else &.{};
    const result = f.client.setTags(zone, "vm", list, snap.tagsFp(), .{});
    if (snap.tags_gen != model.tags_gen) return testing.expectError(error.FailedPrecondition, result);
    var op = try result;
    op.deinit();
    model.tag = want;
    model.tags_gen += 1;
}

/// `updateLabels` reads for itself, so it is always taken.
fn updateOne(f: *Fixture, model: *ChangeModel, g: *test_util.ByteGen) !void {
    const i = g.intRange(u8, 0, 2);
    const remove = g.boolean();
    const v = label_values[g.intRange(u8, 0, 1)];
    const change: types.LabelChange = if (remove) .{ .remove = &.{label_keys[i]} } else .{ .set = &.{.{ .key = label_keys[i], .value = v }} };
    var op = try f.client.updateLabels(zone, "vm", change);
    op.deinit();
    model.labels[i] = if (remove) null else v;
    model.labels_gen += 1;
}

fn agrees(f: *Fixture, model: *const ChangeModel) !void {
    var vm = try f.read("vm");
    defer vm.deinit();
    var count: usize = 0;
    for (label_keys, model.labels) |k, want| {
        const got = vm.value.label(k);
        if (want) |w| {
            try testing.expectEqualStrings(w, got.?);
            count += 1;
        } else try testing.expect(got == null);
    }
    try testing.expectEqual(count, vm.value.labels.len);
    try testing.expectEqual(@as(usize, if (model.tag) 1 else 0), vm.value.tags.items.len);
}

test "slow property compute fake changes: a fingerprint takes once, a stale one never" {
    try test_util.fuzzBytes({}, changesProperty, .{ .random_runs = 60, .max_len = 96 });
}
