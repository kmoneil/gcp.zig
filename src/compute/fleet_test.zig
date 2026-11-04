//! The fleets' tests: templates and groups as sent and previewed,
//! refusals before sending, production's answers decoded, the group wait,
//! and FakeCompute's templates and groups held to production's words.

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
const ids: types.WriteOptions = .{ .request_id = id };

fn reply(status: u16, body: []const u8) test_util.FakeTransport.Reply {
    return .{ .respond = .{ .status = status, .body = body } };
}

fn writer(h: *Harness, script: []const test_util.FakeTransport.Reply) !void {
    try h.initScope(script, .read_write);
    h.clock.random_byte = 0xab;
}

/// A group's template: spot VMs that stop, no run limit.
const web_spec: types.InstanceSpec = .{
    .name = "web-tpl",
    .machine_type = "e2-micro",
    .image = .{ .family = .{ .project = "debian-cloud", .name = "debian-12" } },
    .spot = true,
    .termination_action = .stop,
    .labels = &.{.{ .key = "role", .value = "web" }},
};

test "the fleet writes' paths and bodies, and each preview byte for byte" {
    var h: Harness = undefined;
    const op = reply(200, production.operation_group_insert);
    try writer(&h, &.{ op, op, op, op, op, op, op, op });
    defer h.deinit();
    const c = &h.client;
    const group: types.GroupSpec = .{ .name = "web", .template = .{ .global = "web-tpl" }, .target_size = 3 };
    const gd: types.GroupDeleteOptions = .{ .request_id = id, .no_graceful_shutdown = true };
    const results = [_]anyerror!types.Owned(types.Operation){
        c.insertTemplate(null, web_spec, ids),
        c.insertTemplate("us-east1", web_spec, ids),
        c.deleteTemplate(.{ .regional = .{ .region = "us-east1", .name = "web-tpl" } }, ids),
        c.insertGroup(zone, group, ids),
        c.resizeGroup(zone, "web", 5, ids),
        c.createGroupInstances(zone, "web", &.{"web-named"}, ids),
        c.deleteGroupInstances(zone, "web", &.{ "web-abcd", "web-named" }, gd),
        c.deleteGroup(zone, "web", gd),
    };
    for (results) |r| {
        var owned = try r;
        owned.deinit();
    }
    var previews = [_]types.Owned(core.PreparedRequest){
        try c.insertTemplateRequest(null, web_spec, ids),
        try c.insertTemplateRequest("us-east1", web_spec, ids),
        try c.deleteTemplateRequest(.{ .regional = .{ .region = "us-east1", .name = "web-tpl" } }, ids),
        try c.insertGroupRequest(zone, group, ids),
        try c.resizeGroupRequest(zone, "web", 5, ids),
        try c.createGroupInstancesRequest(zone, "web", &.{"web-named"}, ids),
        try c.deleteGroupInstancesRequest(zone, "web", &.{ "web-abcd", "web-named" }, gd),
        try c.deleteGroupRequest(zone, "web", gd),
    };
    defer for (&previews) |*p| p.deinit();
    const rid = "requestId=" ++ id;
    const igm = base ++ "zones/us-central1-a/instanceGroupManagers";
    const Want = struct { core.transport.Method, []const u8, ?[]const u8 };
    const want = [_]Want{
        .{ .POST, base ++ "global/instanceTemplates?" ++ rid, null },
        .{ .POST, base ++ "regions/us-east1/instanceTemplates?" ++ rid, null },
        .{ .DELETE, base ++ "regions/us-east1/instanceTemplates/web-tpl?" ++ rid, null },
        .{ .POST, igm ++ "?" ++ rid, "{\"name\":\"web\",\"baseInstanceName\":\"web\",\"instanceTemplate\":\"projects/my-project/global/instanceTemplates/web-tpl\",\"targetSize\":3}" },
        .{ .POST, igm ++ "/web/resize?size=5&" ++ rid, "" },
        .{ .POST, igm ++ "/web/createInstances?" ++ rid, "{\"instances\":[{\"name\":\"web-named\"}]}" },
        .{ .POST, igm ++ "/web/deleteInstances?noGracefulShutdown=true&" ++ rid, "{\"instances\":[\"zones/us-central1-a/instances/web-abcd\",\"zones/us-central1-a/instances/web-named\"]}" },
        .{ .DELETE, igm ++ "/web?noGracefulShutdown=true&" ++ rid, null },
    };
    for (want, h.fake.requests.items, previews, 0..) |w, sent, p, n| {
        errdefer std.debug.print("request {d}\n", .{n});
        try testing.expectEqual(w[0], sent.method);
        try testing.expectEqualStrings(w[1], sent.url);
        if (w[2]) |b| try testing.expectEqualStrings(b, sent.body.?);
        try testing.expectEqualStrings(sent.url, p.value.url);
        try testing.expectEqualStrings(sent.body orelse "", p.value.body);
    }
    // A template's properties: bare machine type, no zone in any path.
    const tpl = h.fake.requests.items[0].body.?;
    try testing.expect(std.mem.startsWith(u8, tpl, "{\"name\":\"web-tpl\",\"properties\":{\"machineType\":\"e2-micro\""));
}

test "the fleet reads' paths" {
    var h: Harness = undefined;
    try h.init(&.{
        reply(200, "{}"),
        reply(200, "{}"),
        reply(200, production.template),
        reply(200, "{}"),
        reply(200, production.group_stable),
        reply(200, production.group_instances_stable),
    });
    defer h.deinit();
    const c = &h.client;
    var a = try c.listTemplates(null, .{ .filter = "name eq web-.*" });
    defer a.deinit();
    var b = try c.listTemplates("us-east1", .{ .max_results = 10 });
    defer b.deinit();
    var t = try c.getTemplate(.{ .global = "zigps-m0d-11031901-tpl" });
    defer t.deinit();
    var gs = try c.listGroups(zone, .{});
    defer gs.deinit();
    var g = try c.getGroup(zone, "zigps-m0d-11031901-g");
    defer g.deinit();
    var vms = try c.listManagedInstances(zone, "zigps-m0d-11031901-g", .{ .max_results = 50 });
    defer vms.deinit();
    const r = h.fake.requests.items;
    try testing.expectEqualStrings(base ++ "global/instanceTemplates?filter=name%20eq%20web-.%2A", r[0].url);
    try testing.expectEqualStrings(base ++ "regions/us-east1/instanceTemplates?maxResults=10", r[1].url);
    try testing.expectEqualStrings(base ++ "global/instanceTemplates/zigps-m0d-11031901-tpl", r[2].url);
    try testing.expectEqualStrings(base ++ "zones/us-central1-a/instanceGroupManagers", r[3].url);
    try testing.expectEqualStrings(base ++ "zones/us-central1-a/instanceGroupManagers/zigps-m0d-11031901-g", r[4].url);
    try testing.expectEqual(core.transport.Method.POST, r[5].method);
    try testing.expectEqualStrings(base ++ "zones/us-central1-a/instanceGroupManagers/zigps-m0d-11031901-g/listManagedInstances?maxResults=50", r[5].url);
    try testing.expectEqual(0, a.value.templates.len);
    try testing.expectEqual(0, gs.value.groups.len);
}

test "decode: production's template, group and its VMs" {
    var out: std.heap.ArenaAllocator = .init(testing.allocator);
    defer out.deinit();
    var scratch: std.heap.ArenaAllocator = .init(testing.allocator);
    defer scratch.deinit();
    const o = out.allocator();
    const s = scratch.allocator();
    const t = try codec.decodeTemplate(o, s, production.template);
    try testing.expectEqualStrings("zigps-m0d-11031901-tpl", t.name);
    try testing.expect(t.region == null);
    try testing.expectEqualStrings("e2-micro", t.machine_type);
    try testing.expectEqual(types.ProvisioningModel.spot, t.scheduling.provisioning_model);
    try testing.expectEqual(types.TerminationAction.stop, t.scheduling.termination_action.?);
    try testing.expectEqualStrings("projects/debian-cloud/global/images/family/debian-12", t.source_image);
    try testing.expectEqualStrings("compute-m0", t.label("tool").?);
    try testing.expectEqualStrings("zigps-m0d-11031901-tpl", t.ref().global);
    const g = try codec.decodeGroup(o, s, production.group_stable);
    try testing.expect(g.is_stable);
    try testing.expectEqual(2, g.target_size);
    try testing.expectEqual(2, g.current_actions.none);
    try testing.expectEqual(0, g.current_actions.creating_without_retries);
    try testing.expectEqualStrings("us-central1-a", g.zone);
    try testing.expectEqualStrings("projects/extractctl/global/instanceTemplates/zigps-m0d-11031901-tpl", g.template);
    try testing.expectEqualStrings("zigps-m0d-11031901-g-i", g.base_instance_name);
    const creating = try codec.decodeManagedInstancePage(o, s, production.group_instances_creating);
    try testing.expectEqual(2, creating.instances.len);
    try testing.expectEqual(types.ManagedAction.creating, creating.instances[0].current_action);
    try testing.expect(creating.instances[0].status == null);
    const stable = try codec.decodeManagedInstancePage(o, s, production.group_instances_stable);
    try testing.expectEqual(types.Status.running, stable.instances[1].status.?);
    try testing.expectEqual(types.ManagedAction.none, stable.instances[1].current_action);
    try testing.expectEqualStrings("projects/extractctl/global/instanceTemplates/zigps-m0d-11031901-tpl", stable.instances[1].template);
    const named = try codec.decodeManagedInstancePage(o, s, production.group_instances_named);
    try testing.expectEqualStrings("zigps-m0d-11031901-g-named", named.instances[1].name);
    try testing.expectEqual(types.ManagedAction.parse("CREATING_WITHOUT_RETRIES"), .creating_without_retries);
    try testing.expectEqual(types.ManagedAction.parse("HIBERNATING"), .unknown);
}

test "production's fleet refusals and failed operations" {
    var h: Harness = undefined;
    try writer(&h, &.{
        reply(409, production.template_taken),
        reply(400, production.delete_instances_malformed),
        reply(200, production.operation_template_in_use),
        reply(200, production.operation_group_spot_delete),
    });
    defer h.deinit();
    const c = &h.client;
    try testing.expectError(error.AlreadyExists, c.insertTemplate(null, web_spec, .{}));
    try testing.expectError(error.InvalidArgument, c.deleteGroupInstances(zone, "web", &.{"web-abcd"}, .{}));
    try testing.expect(std.mem.indexOf(u8, h.diag.message(), "The URL is malformed.") != null);
    var in_use = try c.deleteTemplate(.{ .global = "web-tpl" }, .{});
    defer in_use.deinit();
    try testing.expectEqualStrings("RESOURCE_IN_USE_BY_ANOTHER_RESOURCE", in_use.value.failure.?.code());
    var refused = try c.insertGroup(zone, .{ .name = "web", .template = .{ .global = "web-tpl" }, .target_size = 1 }, .{});
    defer refused.deinit();
    try testing.expectEqualStrings("UNSUPPORTED_OPERATION", refused.value.failure.?.code());
    try testing.expect(std.mem.indexOf(u8, refused.value.failure.?.message(), "termination action set to DELETE") != null);
}

test "fleet calls refused before sending" {
    var h: Harness = undefined;
    try writer(&h, &.{});
    defer h.deinit();
    const c = &h.client;
    try testing.expectError(error.InvalidName, c.getTemplate(.{ .global = "Web" }));
    try testing.expectError(error.InvalidName, c.listTemplates("US", .{}));
    try testing.expectError(error.InvalidName, c.getGroup(zone, "web/1"));
    try testing.expectError(error.InvalidName, c.listManagedInstances("US", "web", .{}));
    var bad = web_spec;
    bad.subnetwork = "apps";
    try testing.expectError(error.InvalidOptions, c.insertTemplate(null, bad, .{}));
    try testing.expect(std.mem.indexOf(u8, h.diag.message(), "regions/R/subnetworks/S") != null);
    try testing.expectError(error.InvalidName, c.insertTemplate(null, .{ .name = "Web", .machine_type = "e2-micro", .image = web_spec.image }, .{}));
    try testing.expectError(error.InvalidName, c.insertGroup(zone, .{ .name = "web", .template = .{ .global = "t" }, .base_instance_name = "Web", .target_size = 1 }, .{}));
    try testing.expectError(error.InvalidName, c.insertGroup(zone, .{ .name = "web", .template = .{ .regional = .{ .region = "US", .name = "t" } }, .target_size = 1 }, .{}));
    try testing.expectError(error.InvalidOptions, c.createGroupInstances(zone, "web", &.{}, .{}));
    try testing.expectError(error.InvalidName, c.deleteGroupInstances(zone, "web", &.{""}, .{}));
    try testing.expectError(error.InvalidName, c.resizeGroup(zone, "Web", 1, .{}));
    try testing.expectError(error.InvalidName, c.deleteGroup(zone, "web/1", .{}));
    try testing.expectEqual(0, h.fake.requests.items.len);
    var ro: Harness = undefined;
    try ro.init(&.{});
    defer ro.deinit();
    try testing.expectError(error.InvalidOptions, ro.client.insertGroup(zone, .{ .name = "web", .template = .{ .global = "t" }, .target_size = 1 }, .{}));
    try testing.expectError(error.InvalidOptions, ro.client.resizeGroupRequest(zone, "web", 0, .{}));
}

test "waitGroupStable: reads until stable, a poll apart; at the deadline, as it stands" {
    var h: Harness = undefined;
    const creating = reply(200, "{\"name\":\"web\",\"targetSize\":2,\"status\":{\"isStable\":false}}");
    try writer(&h, &.{ creating, creating, reply(200, production.group_stable), creating, creating, creating, creating });
    defer h.deinit();
    var g = try h.client.waitGroupStable(zone, "zigps-m0d-11031901-g", .{});
    defer g.deinit();
    try testing.expect(g.value.is_stable);
    try testing.expectEqual(2, h.clock.sleep_count);
    try testing.expectEqual(5000, h.clock.sleepMs(0));
    var late = try h.client.waitGroupStable(zone, "web", .{ .timeout_ms = 7_000, .poll_ms = 5_000 });
    defer late.deinit();
    try testing.expect(!late.value.is_stable);
    // Reads at 0, 5 and 7 s; the last sleep is what was left.
    try testing.expectEqual(2000, h.clock.sleepMs(3));
}

// Over FakeCompute.

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

    /// Waits for `op`; frees both; answers its failure's code, or "".
    fn settle(f: *Fixture, op: anyerror!types.Owned(types.Operation)) ![]const u8 {
        var started = try op;
        defer started.deinit();
        var done = try f.client.waitOperation(started.value.ref(), .{});
        defer done.deinit();
        try testing.expect(done.value.done());
        const failure = done.value.failure orelse return "";
        return if (std.mem.eql(u8, failure.code(), "UNSUPPORTED_OPERATION")) "unsupported" else if (std.mem.eql(u8, failure.code(), "RESOURCE_IN_USE_BY_ANOTHER_RESOURCE")) "in use" else "failed";
    }

    fn stable(f: *Fixture, name: []const u8) !types.Owned(types.Group) {
        return f.client.waitGroupStable(zone, name, .{ .timeout_ms = 60_000, .poll_ms = 1_000 });
    }
};

test "FakeCompute: templates made, listed, read and deleted, global and regional" {
    var f: Fixture = undefined;
    try f.init(testing.allocator, .{});
    defer f.deinit();
    const c = &f.client;
    try testing.expectEqualStrings("", try f.settle(c.insertTemplate(null, web_spec, .{})));
    try testing.expectEqualStrings("", try f.settle(c.insertTemplate("us-central1", web_spec, .{})));
    var other = web_spec;
    other.name = "db-tpl";
    other.machine_type = "e2-medium";
    try testing.expectEqualStrings("", try f.settle(c.insertTemplate(null, other, .{})));
    try testing.expectError(error.AlreadyExists, c.insertTemplate(null, web_spec, .{}));
    var global = try c.listTemplates(null, .{});
    defer global.deinit();
    try testing.expectEqual(2, global.value.templates.len);
    try testing.expectEqualStrings("db-tpl", global.value.templates[0].name);
    var web_only = try c.listTemplates(null, .{ .filter = "name eq web-.*" });
    defer web_only.deinit();
    try testing.expectEqual(1, web_only.value.templates.len);
    var regional = try c.listTemplates("us-central1", .{});
    defer regional.deinit();
    try testing.expectEqual(1, regional.value.templates.len);
    try testing.expectEqualStrings("us-central1", regional.value.templates[0].region.?);
    var t = try c.getTemplate(.{ .global = "web-tpl" });
    defer t.deinit();
    try testing.expectEqualStrings("e2-micro", t.value.machine_type);
    try testing.expectEqualStrings("web", t.value.label("role").?);
    try testing.expectEqual(types.ProvisioningModel.spot, t.value.scheduling.provisioning_model);
    try testing.expectEqualStrings("projects/debian-cloud/global/images/family/debian-12", t.value.source_image);
    try testing.expectEqualStrings("", try f.settle(c.deleteTemplate(.{ .regional = .{ .region = "us-central1", .name = "web-tpl" } }, .{})));
    try testing.expectError(error.NotFound, c.getTemplate(.{ .regional = .{ .region = "us-central1", .name = "web-tpl" } }));
    // A VM from a template made through the API.
    try testing.expectEqualStrings("", try f.settle(c.insertFromTemplate(zone, "solo", .{ .global = "db-tpl" }, .{})));
    var solo = try c.getInstance(zone, "solo");
    defer solo.deinit();
    try testing.expectEqualStrings("e2-medium", solo.value.machine_type);
}

test "FakeCompute: a group made, waited on, resized, its VMs named and deleted, then gone" {
    var f: Fixture = undefined;
    try f.init(testing.allocator, .{});
    defer f.deinit();
    const c = &f.client;
    try testing.expectEqualStrings("", try f.settle(c.insertTemplate(null, web_spec, .{})));
    try testing.expectEqualStrings("", try f.settle(c.insertGroup(zone, .{ .name = "web", .template = .{ .global = "web-tpl" }, .target_size = 2 }, .{})));
    // The operation is DONE; its VMs are not.
    var vms = try c.listManagedInstances(zone, "web", .{});
    defer vms.deinit();
    try testing.expectEqual(2, vms.value.instances.len);
    try testing.expectEqual(types.ManagedAction.creating, vms.value.instances[0].current_action);
    var up = try f.stable("web");
    defer up.deinit();
    try testing.expect(up.value.is_stable);
    try testing.expectEqual(2, up.value.current_actions.none);
    var running = try c.listManagedInstances(zone, "web", .{});
    defer running.deinit();
    for (running.value.instances) |m| {
        try testing.expectEqual(types.Status.running, m.status.?);
        try testing.expect(std.mem.startsWith(u8, m.name, "web-"));
        try testing.expectEqual(8, m.name.len);
        try testing.expectEqualStrings("projects/my-project/global/instanceTemplates/web-tpl", m.template);
        // Each is a VM of the zone, from the template.
        var vm = try c.getInstance(zone, m.name);
        defer vm.deinit();
        try testing.expectEqualStrings("web", vm.value.label("role").?);
    }
    // A template a group uses cannot go.
    try testing.expectEqualStrings("in use", try f.settle(c.deleteTemplate(.{ .global = "web-tpl" }, .{})));
    try testing.expectEqualStrings("", try f.settle(c.resizeGroup(zone, "web", 1, .{})));
    var one = try f.stable("web");
    defer one.deinit();
    try testing.expectEqual(1, one.value.target_size);
    try testing.expectEqualStrings("", try f.settle(c.createGroupInstances(zone, "web", &.{"web-named"}, .{})));
    var two = try f.stable("web");
    defer two.deinit();
    try testing.expectEqual(2, two.value.target_size);
    var named = try c.getInstance(zone, "web-named");
    defer named.deinit();
    try testing.expectEqual(types.Status.running, named.value.status);
    try testing.expectEqualStrings("", try f.settle(c.deleteGroupInstances(zone, "web", &.{"web-named"}, .{})));
    var back = try f.stable("web");
    defer back.deinit();
    try testing.expectEqual(1, back.value.target_size);
    try testing.expectError(error.NotFound, c.getInstance(zone, "web-named"));
    var groups = try c.listGroups(zone, .{});
    defer groups.deinit();
    try testing.expectEqual(1, groups.value.groups.len);
    try testing.expectEqualStrings("", try f.settle(c.deleteGroup(zone, "web", .{})));
    try testing.expectError(error.NotFound, c.getGroup(zone, "web"));
    var left = try c.listInstances(zone, .{});
    defer left.deinit();
    try testing.expectEqual(0, left.value.instances.len);
    try testing.expectEqualStrings("", try f.settle(c.deleteTemplate(.{ .global = "web-tpl" }, .{})));
}

test "FakeCompute: a template of spot VMs that DELETE or have a run limit makes no group" {
    var f: Fixture = undefined;
    try f.init(testing.allocator, .{});
    defer f.deinit();
    const c = &f.client;
    var deleting = web_spec;
    deleting.name = "del-tpl";
    deleting.termination_action = .delete;
    var limited = web_spec;
    limited.name = "lim-tpl";
    limited.max_run_duration_s = 600;
    try testing.expectEqualStrings("", try f.settle(c.insertTemplate(null, deleting, .{})));
    try testing.expectEqualStrings("", try f.settle(c.insertTemplate(null, limited, .{})));
    try testing.expectEqualStrings("unsupported", try f.settle(c.insertGroup(zone, .{ .name = "web", .template = .{ .global = "del-tpl" }, .target_size = 1 }, .{})));
    try testing.expectError(error.NotFound, c.getGroup(zone, "web"));
    try testing.expectEqualStrings("unsupported", try f.settle(c.insertGroup(zone, .{ .name = "web", .template = .{ .global = "lim-tpl" }, .target_size = 1 }, .{})));
    try testing.expectError(error.NotFound, c.insertGroup(zone, .{ .name = "web", .template = .{ .global = "nonesuch" }, .target_size = 1 }, .{}));
    // A single VM from either is fine, as milestone 2's live suite made.
    try testing.expectEqualStrings("", try f.settle(c.insertFromTemplate(zone, "solo", .{ .global = "del-tpl" }, .{})));
}

/// The error's message from a refusal, or a failed operation's first
/// error's code and message.
fn wordsOf(arena: std.mem.Allocator, body: []const u8) ![]const u8 {
    const parsed = try std.json.parseFromSliceLeaky(std.json.Value, arena, body, .{});
    const e = parsed.object.get("error").?.object;
    if (e.get("code")) |code| return std.fmt.allocPrint(arena, "{d} {s}", .{ code.integer, e.get("message").?.string });
    const first = e.get("errors").?.array.items[0].object;
    return std.fmt.allocPrint(arena, "DONE {s} {s}", .{ first.get("code").?.string, first.get("message").?.string });
}

test "FakeCompute: the fleets' refusals and failures in production's words" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    var clock: test_util.FakeClock = .{};
    var fake: FakeCompute = .init(testing.allocator, clock.io(), .{ .project_id = "extractctl", .write_waits = 0, .group_steps = 0 });
    defer fake.deinit();
    const api = "https://compute.googleapis.com/compute/v1/projects/extractctl/";
    const tpl = "{\"name\":\"zigps-m0d-11031901-tpl\",\"properties\":{\"machineType\":\"e2-micro\",\"scheduling\":{\"provisioningModel\":\"SPOT\",\"instanceTerminationAction\":\"STOP\"}}}";
    _ = try fake.serve(.{ .method = .POST, .url = api ++ "global/instanceTemplates", .bearer = "t", .body = tpl }, a);
    const del = "{\"name\":\"zigps-m0-11031830-tpl\",\"properties\":{\"machineType\":\"e2-micro\",\"scheduling\":{\"provisioningModel\":\"SPOT\",\"instanceTerminationAction\":\"DELETE\",\"maxRunDuration\":{\"seconds\":\"3600\"}}}}";
    _ = try fake.serve(.{ .method = .POST, .url = api ++ "global/instanceTemplates", .bearer = "t", .body = del }, a);
    const lim = "{\"name\":\"zigps-m0d-11031901-tpl-limit\",\"properties\":{\"machineType\":\"e2-micro\",\"scheduling\":{\"provisioningModel\":\"SPOT\",\"instanceTerminationAction\":\"STOP\",\"maxRunDuration\":{\"seconds\":\"120\"}}}}";
    _ = try fake.serve(.{ .method = .POST, .url = api ++ "global/instanceTemplates", .bearer = "t", .body = lim }, a);
    const group = "{\"name\":\"zigps-m0d-11031901-g\",\"baseInstanceName\":\"zigps-m0d-11031901-g-i\",\"instanceTemplate\":\"https://www.googleapis.com/compute/v1/projects/extractctl/global/instanceTemplates/zigps-m0d-11031901-tpl\",\"targetSize\":2}";
    _ = try fake.serve(.{ .method = .POST, .url = api ++ "zones/us-central1-a/instanceGroupManagers", .bearer = "t", .body = group }, a);
    const Case = struct { core.transport.Method, []const u8, ?[]const u8, []const u8 };
    const cases = [_]Case{
        .{ .POST, api ++ "global/instanceTemplates", tpl, production.template_taken },
        .{ .POST, api ++ "zones/us-central1-a/instanceGroupManagers/zigps-m0d-11031901-g/deleteInstances", "{\"instances\":[\"\"]}", production.delete_instances_malformed },
        .{ .POST, api ++ "zones/us-central1-a/instanceGroupManagers", "{\"name\":\"zigps-m0-11031830-g\",\"instanceTemplate\":\"global/instanceTemplates/zigps-m0-11031830-tpl\",\"targetSize\":2}", production.operation_group_spot_delete },
        .{ .POST, api ++ "zones/us-central1-a/instanceGroupManagers", "{\"name\":\"zigps-m0d-11031901-g-limit\",\"instanceTemplate\":\"global/instanceTemplates/zigps-m0d-11031901-tpl-limit\",\"targetSize\":2}", production.operation_group_spot_limit },
    };
    for (cases, 0..) |case, n| {
        errdefer std.debug.print("case {d}\n", .{n});
        const got = try fake.serve(.{ .method = case[0], .url = case[1], .bearer = "t", .body = case[2] }, a);
        try testing.expectEqualStrings(try wordsOf(a, case[3]), try wordsOf(a, got.body));
    }
    // In use: the group's id, as production wrote it, differs.
    const in_use = try fake.serve(.{ .method = .DELETE, .url = api ++ "global/instanceTemplates/zigps-m0d-11031901-tpl", .bearer = "t" }, a);
    const want = try wordsOf(a, production.operation_template_in_use);
    const have = try wordsOf(a, in_use.body);
    try testing.expectEqualStrings(want[0 .. std.mem.indexOfScalar(u8, want, '@').? + 1], have[0 .. std.mem.indexOfScalar(u8, have, '@').? + 1]);
}

/// A group as a model holds it: its target, and which of the names
/// given to `createGroupInstances` it keeps.
const GroupModel = struct {
    target: u32 = 0,
    named: [3]bool = .{ false, false, false },
};

const named_vms = [_][]const u8{ "web-n0", "web-n1", "web-n2" };

/// Resizes, VMs made and deleted by name, reads and waits, with lost
/// answers: once stable, the group keeps as many VMs as its target, its
/// named ones among them, each a RUNNING VM of the zone, and every VM it
/// dropped gone.
fn groupProperty(_: void, input: []const u8) !void {
    var g: test_util.ByteGen = .init(input);
    var f: Fixture = undefined;
    try f.init(test_util.propertyAllocator(), .{ .write_waits = g.intRange(u8, 0, 1), .group_steps = g.intRange(u8, 0, 3) });
    defer f.deinit();
    const c = &f.client;
    try f.fake.putTemplate(.{ .name = "web-tpl", .spot = true, .termination_action = .stop });
    var model: GroupModel = .{ .target = g.intRange(u8, 0, 3) };
    _ = try f.settle(c.insertGroup(zone, .{ .name = "web", .template = .{ .global = "web-tpl" }, .target_size = model.target }, .{}));
    const steps = g.intRange(u8, 1, 12);
    for (0..steps) |_| {
        if (g.intRange(u8, 0, 5) == 0) f.fake.loseNext(1, 503);
        try groupStep(&f, &model, &g);
        if (g.boolean()) try groupAgrees(&f, &model);
    }
    try groupAgrees(&f, &model);
}

fn groupStep(f: *Fixture, model: *GroupModel, g: *test_util.ByteGen) !void {
    const c = &f.client;
    const n = g.intRange(u8, 0, 2);
    switch (g.intRange(u8, 0, 3)) {
        0 => {
            // A resize keeps the named VMs only while the target covers
            // them; the fake drops the newest first, as the model does.
            const size = g.intRange(u8, 0, 4);
            _ = try f.settle(c.resizeGroup(zone, "web", size, .{}));
            var vms = try c.listManagedInstances(zone, "web", .{});
            defer vms.deinit();
            model.target = size;
            for (&model.named, named_vms) |*kept, name| kept.* = kept.* and listedLive(vms.value.instances, name);
        },
        1 => if (!model.named[n]) {
            // A namesake dropped earlier must be gone first, as
            // production would have its name taken until then.
            var settled = try f.stable("web");
            settled.deinit();
            _ = try f.settle(c.createGroupInstances(zone, "web", &.{named_vms[n]}, .{}));
            model.named[n] = true;
            model.target += 1;
        },
        2 => if (model.named[n]) {
            _ = try f.settle(c.deleteGroupInstances(zone, "web", &.{named_vms[n]}, .{}));
            model.named[n] = false;
            model.target -= 1;
        },
        else => {
            var vms = try c.listManagedInstances(zone, "web", .{});
            vms.deinit();
        },
    }
}

/// Among `list`, not on its way out.
fn listedLive(list: []const types.ManagedInstance, name: []const u8) bool {
    for (list) |m| if (std.mem.eql(u8, m.name, name)) return m.current_action != .deleting;
    return false;
}

fn groupAgrees(f: *Fixture, model: *const GroupModel) !void {
    const c = &f.client;
    var group = try f.stable("web");
    defer group.deinit();
    try testing.expect(group.value.is_stable);
    try testing.expectEqual(model.target, group.value.target_size);
    var vms = try c.listManagedInstances(zone, "web", .{});
    defer vms.deinit();
    try testing.expectEqual(@as(usize, model.target), vms.value.instances.len);
    for (vms.value.instances) |m| {
        try testing.expectEqual(types.ManagedAction.none, m.current_action);
        var vm = try c.getInstance(zone, m.name);
        defer vm.deinit();
        try testing.expectEqual(types.Status.running, vm.value.status);
    }
    for (model.named, named_vms) |kept, name| {
        try testing.expectEqual(kept, listedLive(vms.value.instances, name));
        if (!kept) try testing.expectError(error.NotFound, c.getInstance(zone, name));
    }
    var all = try c.listInstances(zone, .{});
    defer all.deinit();
    try testing.expectEqual(@as(usize, model.target), all.value.instances.len);
}

test "slow property compute fake groups: stable at the target, named VMs kept, dropped ones gone" {
    try test_util.fuzzBytes({}, groupProperty, .{ .random_runs = 40, .max_len = 64 });
}
