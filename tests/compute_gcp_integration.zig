//! Integration tests against real Compute Engine, which has no emulator:
//! milestone 2 of the Compute spec (issue #346). They need a project with
//! the Compute API on and a token that may create, start, stop, suspend
//! and delete VMs and instance templates there (Editor does):
//!
//!     GCP_TEST_PROJECT=extractctl GCP_TEST_TOKEN=$(cat token.txt) \
//!     COMPUTE_TEST=1 zig build test-integration-gcp -Dtest-filter=compute
//!
//! Without the variables the test skips. `COMPUTE_TEST_ZONE` moves it off
//! us-central1-a; `COMPUTE_TEST_SAVE=<file>` writes every answer
//! production gave, one JSON line each, for the module's recorded bodies.
//!
//! One scenario runs through the client against production, then against
//! `FakeCompute`, and the fake is held to production's answer at every
//! step; every write's preview is held byte for byte to what was sent,
//! on both. Four VMs, `zigps-<run>-a` to `-d`, e2-micro or e2-small, spot
//! but one, each with a 30-minute run limit that deletes it should the
//! suite die, labelled purpose=gcp-zig-test and tool=compute-it; one
//! instance template made raw beside the client, which has no verb for
//! one yet. The suite sweeps earlier runs' VMs and templates first, and
//! its own at the end. About eight minutes, and a cent or two.

const std = @import("std");
const core = @import("core");
const compute = @import("compute");
const testing = std.testing;
const Allocator = std.mem.Allocator;

const Fixture = struct {
    env: std.process.Environ.Map,
    token: core.StaticToken,
    project: []const u8,
    zone: []const u8,
    arena: std.heap.ArenaAllocator,
    run: []const u8,

    fn init(f: *Fixture) !bool {
        const gpa = testing.allocator;
        f.env = try testing.environ.createMap(gpa);
        errdefer f.env.deinit();
        f.project = f.env.get("GCP_TEST_PROJECT") orelse return f.skip();
        const token = f.env.get("GCP_TEST_TOKEN") orelse return f.skip();
        if (f.env.get("COMPUTE_TEST") == null) return f.skip();
        f.zone = f.env.get("COMPUTE_TEST_ZONE") orelse "us-central1-a";
        f.token = .{ .token = std.mem.trim(u8, token, &std.ascii.whitespace) };
        f.arena = .init(gpa);
        var bytes: [3]u8 = undefined;
        testing.io.random(&bytes);
        f.run = try f.arena.allocator().print("{x}", .{bytes});
        return true;
    }

    fn skip(f: *Fixture) bool {
        f.env.deinit();
        return false;
    }

    fn deinit(f: *Fixture) void {
        f.arena.deinit();
        f.env.deinit();
    }
};

fn fact(comptime format: []const u8, args: anytype) void {
    std.debug.print("  " ++ format ++ "\n", args);
}

/// A transport that keeps the last request it passed on, for holding a
/// preview to what was sent, and every answer, for `COMPUTE_TEST_SAVE`.
const Recorder = struct {
    inner: core.transport.Transport,
    arena: std.heap.ArenaAllocator,
    method: core.transport.Method = .GET,
    url: []const u8 = "",
    body: []const u8 = "",
    answers: std.ArrayList([]const u8) = .empty,

    fn transport(r: *Recorder) core.transport.Transport {
        return .{ .ptr = r, .vtable = &.{ .send = send } };
    }

    fn send(ptr: *anyopaque, req: core.transport.Request, arena: Allocator) core.transport.Error!core.transport.Response {
        const r: *Recorder = @ptrCast(@alignCast(ptr));
        const a = r.arena.allocator();
        r.method = req.method;
        r.url = a.dupe(u8, req.url) catch return error.OutOfMemory;
        r.body = a.dupe(u8, req.body orelse "") catch return error.OutOfMemory;
        const res = try r.inner.send(req, arena);
        const line = std.json.Stringify.valueAlloc(a, .{ .method = @tagName(req.method), .url = req.url, .request = req.body, .status = res.status, .body = res.body }, .{}) catch return error.OutOfMemory;
        r.answers.append(a, line) catch return error.OutOfMemory;
        return res;
    }
};

/// One side of the comparison: a client, what it answered as lines of
/// text, and the names it made.
const Side = struct {
    a: Allocator,
    client: *compute.Client,
    diag: *compute.Diagnostics,
    recorder: *Recorder,
    zone: []const u8,
    run: []const u8,
    lines: std.ArrayList([]const u8) = .empty,
    previews: usize = 0,

    fn say(s: *Side, comptime format: []const u8, args: anytype) !void {
        try s.lines.append(s.a, try s.a.print(format, args));
    }

    fn vm(s: *Side, comptime letter: []const u8) []const u8 {
        return s.a.print("zigps-{s}-" ++ letter, .{s.run}) catch @panic("OOM");
    }

    /// Holds the preview to the request the write after it sent.
    fn held(s: *Side, preview: compute.Error!compute.Owned(compute.PreparedRequest)) !void {
        var p = try preview;
        defer p.deinit();
        try testing.expectEqual(p.value.method, s.recorder.method);
        try testing.expectEqualStrings(p.value.url, s.recorder.url);
        try testing.expectEqualStrings(p.value.body, s.recorder.body);
        s.previews += 1;
    }

    /// A write's answer, as a line: its operation done or not, and its
    /// type, or its error. The operation, when there is one. Not done is
    /// RUNNING or PENDING as production has it: it answered a start
    /// PENDING here and RUNNING in milestone 0.
    fn wrote(s: *Side, label: []const u8, result: compute.Error!compute.Owned(compute.Operation)) !?compute.Owned(compute.Operation) {
        const op = result catch |err| {
            try s.say("{s}: error.{t}", .{ label, err });
            return null;
        };
        try s.say("{s}: {s} {s}", .{ label, if (op.value.done()) "done" else "not done", op.value.operation_type });
        return op;
    }

    /// A write, its preview held to what it sent (built after it, from
    /// the same arguments), then the wait on it.
    fn step(s: *Side, label: []const u8, result: compute.Error!compute.Owned(compute.Operation), preview: compute.Error!compute.Owned(compute.PreparedRequest)) !void {
        const op = try s.wrote(label, result);
        try s.held(preview);
        try s.waited(label, op);
    }

    /// Waits on a write's operation, as a line; frees it.
    fn waited(s: *Side, label: []const u8, op: ?compute.Owned(compute.Operation)) !void {
        var started = op orelse return;
        defer started.deinit();
        var done = s.client.waitOperation(started.value.ref(), .{ .timeout_ms = 900_000 }) catch |err| {
            try s.say("{s} waited: error.{t}", .{ label, err });
            return;
        };
        defer done.deinit();
        if (done.value.failure) |failure| {
            try s.say("{s} waited: {t} failed {s}", .{ label, done.value.status, failure.code() });
        } else try s.say("{s} waited: {t}", .{ label, done.value.status });
    }

    /// A template, as a line.
    fn readTemplate(s: *Side, ref: compute.TemplateRef, label: []const u8) !void {
        var got = s.client.getTemplate(ref) catch |err| {
            try s.say("{s}: error.{t}", .{ label, err });
            return;
        };
        defer got.deinit();
        const t = got.value;
        try s.say("{s}: {s} {t} {?t} region={s} image={s}", .{ label, t.machine_type, t.scheduling.provisioning_model, t.scheduling.termination_action, t.region orelse "-", t.source_image });
    }

    /// A group, as a line: its target and what its VMs are doing, or its
    /// error.
    fn readGroup(s: *Side, name: []const u8, label: []const u8) !void {
        var got = s.client.getGroup(s.zone, name) catch |err| {
            try s.say("{s}: error.{t}", .{ label, err });
            return;
        };
        defer got.deinit();
        try s.say("{s}: target {d}", .{ label, got.value.target_size });
    }

    /// Waits until the group is stable, then its target, actions and VMs,
    /// as lines: their statuses and actions, not their names, which end
    /// in letters production picks.
    fn waitStable(s: *Side, name: []const u8, label: []const u8) !void {
        var g = try s.client.waitGroupStable(s.zone, name, .{ .timeout_ms = 600_000 });
        defer g.deinit();
        const v = g.value;
        try s.say("{s}: stable={} target {d}, none {d}, creating {d}, deleting {d}", .{ label, v.is_stable, v.target_size, v.current_actions.none, v.current_actions.creating, v.current_actions.deleting });
        var vms = try s.client.listManagedInstances(s.zone, name, .{});
        defer vms.deinit();
        var parts: std.ArrayList([]const u8) = .empty;
        for (vms.value.instances) |m| try parts.append(s.a, try s.a.print("{?t}/{t}", .{ m.status, m.current_action }));
        std.mem.sort([]const u8, parts.items, {}, less);
        try s.say("{s}, its VMs: {s}", .{ label, try std.mem.join(s.a, " ", parts.items) });
    }

    /// A VM's labels, tags and metadata keys, as a line, each sorted.
    fn readChanges(s: *Side, name: []const u8, label: []const u8) !void {
        var got = try s.client.getInstance(s.zone, name);
        defer got.deinit();
        const i = got.value;
        var pairs: std.ArrayList([]const u8) = .empty;
        for (i.labels) |l| if (!std.mem.eql(u8, l.key, "run")) try pairs.append(s.a, try s.a.print("{s}={s}", .{ l.key, l.value }));
        var keys: std.ArrayList([]const u8) = .empty;
        for (i.metadata.items) |m| try keys.append(s.a, m.key);
        std.mem.sort([]const u8, pairs.items, {}, less);
        std.mem.sort([]const u8, keys.items, {}, less);
        const tag_list = try s.a.dupe([]const u8, i.tags.items);
        std.mem.sort([]const u8, tag_list, {}, less);
        try s.say("{s}: labels {s}; tags {s}; metadata {s}", .{ label, try std.mem.join(s.a, ",", pairs.items), try std.mem.join(s.a, ",", tag_list), try std.mem.join(s.a, ",", keys.items) });
    }

    /// A VM's disks, as a line: each device, boot or not, mode, auto
    /// delete.
    fn readDisks(s: *Side, name: []const u8, label: []const u8) !void {
        var got = try s.client.getInstance(s.zone, name);
        defer got.deinit();
        var parts: std.ArrayList([]const u8) = .empty;
        for (got.value.disks) |d| try parts.append(s.a, try s.a.print("{s} boot={} {s} auto_delete={} {?d} GB", .{ if (d.boot) "boot" else d.device_name, d.boot, d.mode, d.auto_delete, d.size_gb }));
        try s.say("{s}: {s}", .{ label, try std.mem.join(s.a, "; ", parts.items) });
    }

    fn less(_: void, x: []const u8, y: []const u8) bool {
        return std.mem.lessThan(u8, x, y);
    }

    /// A VM as it reads, as a line, its automatic restart too.
    fn read(s: *Side, name: []const u8, label: []const u8) !void {
        var got = s.client.getInstance(s.zone, name) catch |err| {
            try s.say("{s}: error.{t}", .{ label, err });
            return;
        };
        defer got.deinit();
        const i = got.value;
        try s.say("{s}: {t} {s} {t} restart={?} protected={} run={s}", .{ label, i.status, i.machine_type, i.scheduling.provisioning_model, i.scheduling.automatic_restart, i.deletion_protection, i.label("run") orelse "" });
    }

    fn labels(s: *Side) []const compute.Label {
        return s.a.dupe(compute.Label, &.{
            .{ .key = "purpose", .value = "gcp-zig-test" },
            .{ .key = "tool", .value = "compute-it" },
            .{ .key = "run", .value = s.run },
        }) catch @panic("OOM");
    }

    fn spec(s: *Side, name: []const u8, spot: bool, protect: bool) compute.InstanceSpec {
        return .{
            .name = name,
            .machine_type = "e2-micro",
            .image = .{ .family = .{ .project = "debian-cloud", .name = "debian-12" } },
            .boot_disk = .{ .size_gb = 10, .type = "pd-standard" },
            .spot = spot,
            .automatic_restart = if (spot) null else false,
            .max_run_duration_s = 1800,
            .termination_action = .delete,
            .labels = s.labels(),
            .metadata = &.{.{ .key = "startup-script", .value = "#!/bin/bash\necho zigps-compute-it up > /dev/ttyS0\n" }},
            .deletion_protection = protect,
        };
    }
};

/// The changes to a running VM, milestone 3's: labels, metadata and tags
/// under fresh and stale fingerprints, the update helpers, the changes a
/// running VM refuses, a disk attached and detached, deletion protection.
fn runningChanges(s: *Side, a: []const u8, disk: []const u8) !void {
    const c = s.client;
    const z = s.zone;
    var buf: [36]u8 = undefined;
    var vm = try c.getInstance(z, a);
    defer vm.deinit();
    const fp = vm.value.label_fingerprint;
    const labels = try std.mem.concat(s.a, compute.Label, &.{ s.labels(), &.{.{ .key = "stage", .value = "running" }} });
    try s.step("set a's labels", c.setLabels(z, a, labels, fp, .{ .request_id = c.newRequestId(&buf) }), c.setLabelsRequest(z, a, labels, fp, .{ .request_id = &buf }));
    try s.waited("set a's labels, the fingerprint used", try s.wrote("set a's labels, the fingerprint used", c.setLabels(z, a, labels, fp, .{})));
    try s.waited("update a's labels", try s.wrote("update a's labels", c.updateLabels(z, a, .{ .set = &.{.{ .key = "stage", .value = "updated" }} })));
    try s.waited("update a's metadata", try s.wrote("update a's metadata", c.updateMetadata(z, a, .{ .set = &.{.{ .key = "zigps-note", .value = "m3" }} })));
    const tfp = vm.value.tags.fingerprint;
    try s.step("set a's tags", c.setTags(z, a, &.{"zigps-it"}, tfp, .{ .request_id = c.newRequestId(&buf) }), c.setTagsRequest(z, a, &.{"zigps-it"}, tfp, .{ .request_id = &buf }));
    try s.waited("set a's tags, the fingerprint used", try s.wrote("set a's tags, the fingerprint used", c.setTags(z, a, &.{}, tfp, .{})));
    try s.readChanges(a, "a changed");
    try s.waited("set a's scheduling while it runs", try s.wrote("set a's scheduling while it runs", c.setScheduling(z, a, .{ .automatic_restart = false }, .{})));
    try s.waited("set a's machine type while it runs", try s.wrote("set a's machine type while it runs", c.setMachineType(z, a, "e2-small", .{})));
    try s.waited("set a's machine type to one nobody has", try s.wrote("set a's machine type to one nobody has", c.setMachineType(z, a, "e2-nonesuch", .{})));
    const attach: compute.AttachSpec = .{ .disk = disk, .device_name = "zigps-data" };
    try s.step("attach the disk", c.attachDisk(z, a, attach, .{ .request_id = c.newRequestId(&buf) }), c.attachDiskRequest(z, a, attach, .{ .request_id = &buf }));
    try s.readDisks(a, "a's disks");
    try s.waited("attach it again", try s.wrote("attach it again", c.attachDisk(z, a, attach, .{})));
    try s.waited("attach a disk nobody has", try s.wrote("attach a disk nobody has", c.attachDisk(z, a, .{ .disk = s.vm("nodisk") }, .{})));
    try s.step("detach the disk", c.detachDisk(z, a, "zigps-data", .{ .request_id = c.newRequestId(&buf) }), c.detachDiskRequest(z, a, "zigps-data", .{ .request_id = &buf }));
    try s.readDisks(a, "a's disks after");
    try s.waited("detach it again", try s.wrote("detach it again", c.detachDisk(z, a, "zigps-data", .{})));
    try s.step("protect a", c.setDeletionProtection(z, a, true, .{ .request_id = c.newRequestId(&buf) }), c.setDeletionProtectionRequest(z, a, true, .{ .request_id = &buf }));
    try s.waited("delete a, protected", try s.wrote("delete a, protected", c.deleteInstance(z, a, .{})));
    try s.step("unprotect a", c.setDeletionProtection(z, a, false, .{ .request_id = c.newRequestId(&buf) }), c.setDeletionProtectionRequest(z, a, false, .{ .request_id = &buf }));
}

/// The changes a stopped VM takes: its machine type, and its scheduling
/// to standard and back to spot.
fn stoppedChanges(s: *Side, a: []const u8) !void {
    const c = s.client;
    const z = s.zone;
    var buf: [36]u8 = undefined;
    try s.step("set a's machine type, stopped", c.setMachineType(z, a, "e2-small", .{ .request_id = c.newRequestId(&buf) }), c.setMachineTypeRequest(z, a, "e2-small", .{ .request_id = &buf }));
    const standard: compute.SchedulingChange = .{ .spot = false, .on_host_maintenance = .migrate };
    try s.step("make a standard", c.setScheduling(z, a, standard, .{ .request_id = c.newRequestId(&buf) }), c.setSchedulingRequest(z, a, standard, .{ .request_id = &buf }));
    try s.read(a, "a standard");
    try s.waited("make a spot again", try s.wrote("make a spot again", c.setScheduling(z, a, .{ .spot = true, .on_host_maintenance = .terminate }, .{})));
    try s.read(a, "a spot again");
}

/// Templates and a group, milestone 4's: the group made, waited on until
/// stable, resized, a VM made and deleted by name, the template it uses
/// refused deletion, a group from a template of spot VMs that DELETE
/// refused, and all of it deleted. `delete_template` is milestone 2's,
/// whose spot VMs DELETE at a run limit.
fn fleets(s: *Side, delete_template: []const u8) !void {
    const c = s.client;
    const z = s.zone;
    var buf: [36]u8 = undefined;
    const region = z[0..std.mem.lastIndexOfScalar(u8, z, '-').?];
    const global_name = s.vm("gtpl");
    const regional_name = s.vm("rtpl");
    var spec: compute.InstanceSpec = .{
        .name = global_name,
        .machine_type = "e2-micro",
        .image = .{ .family = .{ .project = "debian-cloud", .name = "debian-12" } },
        .spot = true,
        .termination_action = .stop,
        .labels = s.labels(),
    };
    try s.step("insert the group's template", c.insertTemplate(null, spec, .{ .request_id = c.newRequestId(&buf) }), c.insertTemplateRequest(null, spec, .{ .request_id = &buf }));
    try s.waited("insert it again", try s.wrote("insert it again", c.insertTemplate(null, spec, .{})));
    spec.name = regional_name;
    try s.step("insert a regional template", c.insertTemplate(region, spec, .{ .request_id = c.newRequestId(&buf) }), c.insertTemplateRequest(region, spec, .{ .request_id = &buf }));
    try s.readTemplate(.{ .global = global_name }, "the group's template");
    try s.readTemplate(.{ .regional = .{ .region = region, .name = regional_name } }, "the regional template");

    const g = s.vm("g");
    const group: compute.GroupSpec = .{ .name = g, .template = .{ .global = global_name }, .target_size = 2 };
    try s.step("insert the group", c.insertGroup(z, group, .{ .request_id = c.newRequestId(&buf) }), c.insertGroupRequest(z, group, .{ .request_id = &buf }));
    try s.waitStable(g, "the group");
    try s.step("resize it to 1", c.resizeGroup(z, g, 1, .{ .request_id = c.newRequestId(&buf) }), c.resizeGroupRequest(z, g, 1, .{ .request_id = &buf }));
    try s.waitStable(g, "resized");
    const named = s.vm("g-named");
    try s.step("make a VM by name", c.createGroupInstances(z, g, &.{named}, .{ .request_id = c.newRequestId(&buf) }), c.createGroupInstancesRequest(z, g, &.{named}, .{ .request_id = &buf }));
    try s.waitStable(g, "with the named VM");
    try s.step("delete it by name", c.deleteGroupInstances(z, g, &.{named}, .{ .request_id = c.newRequestId(&buf) }), c.deleteGroupInstancesRequest(z, g, &.{named}, .{ .request_id = &buf }));
    try s.waitStable(g, "without it");
    try s.read(named, "the named VM");
    try s.waited("delete the template it uses", try s.wrote("delete the template it uses", c.deleteTemplate(.{ .global = global_name }, .{})));
    const refused = s.vm("gdel");
    try s.waited("a group whose spot VMs DELETE", try s.wrote("a group whose spot VMs DELETE", c.insertGroup(z, .{ .name = refused, .template = .{ .global = delete_template }, .target_size = 1 }, .{})));
    try s.readGroup(refused, "that group");
    try s.step("delete the group", c.deleteGroup(z, g, .{ .request_id = c.newRequestId(&buf) }), c.deleteGroupRequest(z, g, .{ .request_id = &buf }));
    try s.readGroup(g, "the group deleted");
    try s.step("delete its template", c.deleteTemplate(.{ .global = global_name }, .{ .request_id = c.newRequestId(&buf) }), c.deleteTemplateRequest(.{ .global = global_name }, .{ .request_id = &buf }));
    try s.waited("delete the regional template", try s.wrote("delete the regional template", c.deleteTemplate(.{ .regional = .{ .region = region, .name = regional_name } }, .{})));
}

/// The writes, read back after each: the same calls on either side.
fn scenario(s: *Side, template: []const u8, disk: []const u8) !void {
    const c = s.client;
    const z = s.zone;
    const a = s.vm("a");
    const b = s.vm("b");
    var buf: [36]u8 = undefined;
    const id = c.newRequestId(&buf);

    // A: spot, created, sent again with its id, then with a new one.
    const spec_a = s.spec(a, true, false);
    const first = try s.wrote("insert a", c.insertInstance(z, spec_a, .{ .request_id = id }));
    try s.held(c.insertInstanceRequest(z, spec_a, .{ .request_id = id }));
    if (first) |op| try s.say("insert a's clientOperationId is its requestId: {}", .{std.mem.eql(u8, op.value.client_operation_id, id)});
    if (try s.wrote("insert a again, same requestId", c.insertInstance(z, spec_a, .{ .request_id = id }))) |again_op| {
        var again = again_op;
        defer again.deinit();
        if (first) |op| try s.say("the same operation: {}", .{std.mem.eql(u8, op.value.name, again.value.name)});
    }
    if (try s.wrote("insert a again, new requestId", c.insertInstance(z, spec_a, .{}))) |op_| {
        var op = op_;
        op.deinit();
    }
    try s.waited("insert a", first);
    try s.read(a, "a");
    try runningChanges(s, a, disk);

    // Its life. Each write's id is made in `buf` as its argument is, so
    // the preview after it, built from `buf`, names the same request.
    try s.step("stop a", c.stopInstance(z, a, .{ .request_id = c.newRequestId(&buf) }), c.stopInstanceRequest(z, a, .{ .request_id = &buf }));
    try s.read(a, "a stopped");
    try s.waited("stop a again", try s.wrote("stop a again", c.stopInstance(z, a, .{})));
    try s.read(a, "a stopped again");
    try stoppedChanges(s, a);
    try s.step("start a", c.startInstance(z, a, .{ .request_id = c.newRequestId(&buf) }), c.startInstanceRequest(z, a, .{ .request_id = &buf }));
    try s.read(a, "a started");
    try s.waited("start a again", try s.wrote("start a again", c.startInstance(z, a, .{})));
    try s.step("reset a", c.resetInstance(z, a, .{ .request_id = c.newRequestId(&buf) }), c.resetInstanceRequest(z, a, .{ .request_id = &buf }));
    try s.read(a, "a reset");

    // B: standard, under deletion protection, suspended and resumed.
    try s.waited("insert b", try s.wrote("insert b", c.insertInstance(z, s.spec(b, false, true), .{})));
    try s.read(b, "b");
    try s.step("suspend b", c.suspendInstance(z, b, .{ .request_id = c.newRequestId(&buf) }), c.suspendInstanceRequest(z, b, .{ .request_id = &buf }));
    try s.read(b, "b suspended");
    try s.step("resume b", c.resumeInstance(z, b, .{ .request_id = c.newRequestId(&buf) }), c.resumeInstanceRequest(z, b, .{ .request_id = &buf }));
    try s.read(b, "b resumed");
    try s.waited("delete b", try s.wrote("delete b, protected", c.deleteInstance(z, b, .{})));

    // C from the template; D from a raw body InstanceSpec cannot write.
    const c_name = s.vm("c");
    const tpl: compute.TemplateRef = .{ .global = template };
    try s.step("insert c from the template", c.insertFromTemplate(z, c_name, tpl, .{ .request_id = c.newRequestId(&buf) }), c.insertFromTemplateRequest(z, c_name, tpl, .{ .request_id = &buf }));
    try s.read(c_name, "c");
    try s.waited("insert from a template nobody has", try s.wrote("insert from a template nobody has", c.insertFromTemplate(z, s.vm("x"), .{ .global = "zigps-nonesuch" }, .{})));
    const d = s.vm("d");
    const raw_body = try s.a.print(
        \\{{"name":"{s}","machineType":"zones/{s}/machineTypes/e2-micro","labels":{{"purpose":"gcp-zig-test","tool":"compute-it","run":"{s}"}},"disks":[{{"boot":true,"autoDelete":true,"initializeParams":{{"sourceImage":"projects/debian-cloud/global/images/family/debian-12"}}}}],"networkInterfaces":[{{"network":"global/networks/default"}}],"shieldedInstanceConfig":{{"enableSecureBoot":true}},"scheduling":{{"provisioningModel":"SPOT","automaticRestart":false,"maxRunDuration":{{"seconds":"1800"}},"instanceTerminationAction":"DELETE"}}}}
    , .{ d, z, s.run });
    try s.step("insert d from a raw body", c.insertInstanceJson(z, raw_body, .{ .request_id = c.newRequestId(&buf) }), c.insertInstanceJsonRequest(z, raw_body, .{ .request_id = &buf }));
    try s.read(d, "d");

    // Deleted.
    for ([_][]const u8{ a, c_name, d }, [_][]const u8{ "delete a", "delete c", "delete d" }) |name, label| {
        try s.step(label, c.deleteInstance(z, name, .{ .request_id = c.newRequestId(&buf), .no_graceful_shutdown = true }), c.deleteInstanceRequest(z, name, .{ .request_id = &buf, .no_graceful_shutdown = true }));
        try s.read(name, label);
    }
    try s.waited("start a, gone", try s.wrote("start a, gone", c.startInstance(z, a, .{})));
    try fleets(s, template);
}

/// One raw call beside the client, for what it has no verb for yet: the
/// template, and lifting deletion protection.
fn raw(f: *Fixture, client: *compute.Client, arena: Allocator, method: core.transport.Method, path: []const u8, body: ?[]const u8) !core.transport.Response {
    const url = try std.fmt.allocPrint(arena, "{s}/compute/v1/projects/{s}/{s}", .{ client.base_url, f.project, path });
    return client.transport.send(.{ .method = method, .url = url, .bearer = f.token.token, .body = body, .timeout_ms = 60_000 }, arena);
}

/// Waits on an operation a raw call answered.
fn waitRaw(client: *compute.Client, body: []const u8, scope: compute.OperationScope) !void {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const parsed = try std.json.parseFromSliceLeaky(std.json.Value, arena.allocator(), body, .{});
    const name = parsed.object.get("name").?.string;
    var op = try client.waitOperation(.{ .name = name, .scope = scope }, .{ .timeout_ms = 600_000 });
    defer op.deinit();
}

/// Deletes every VM and disk labelled tool=compute-it (lifting deletion
/// protection first) and every `zigps-` template, `run`'s alone when
/// given.
fn sweep(f: *Fixture, client: *compute.Client, run: ?[]const u8) !void {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try sweepGroups(f, client, a, run);
    try sweepVms(f, client, a, run);
    try sweepDisks(f, client, a, run);
    try sweepTemplates(f, client, a, run);
}

/// Groups first: a group's VMs deleted alone would be made again.
fn sweepGroups(f: *Fixture, client: *compute.Client, a: Allocator, run: ?[]const u8) !void {
    _ = a;
    var page = client.listGroups(f.zone, .{ .filter = "name eq zigps-.*" }) catch |err| {
        fact("sweep: listing groups failed: {t}", .{err});
        return;
    };
    defer page.deinit();
    for (page.value.groups) |g| {
        if (run) |r| if (std.mem.indexOf(u8, g.name, r) == null) continue;
        var op = client.deleteGroup(f.zone, g.name, .{ .no_graceful_shutdown = true }) catch |err| {
            fact("sweep: deleting group {s} failed: {t}", .{ g.name, err });
            continue;
        };
        defer op.deinit();
        var done = client.waitOperation(op.value.ref(), .{}) catch continue;
        done.deinit();
        fact("sweep: deleted group {s}", .{g.name});
    }
}

fn sweepVms(f: *Fixture, client: *compute.Client, a: Allocator, run: ?[]const u8) !void {
    var page = client.listAllInstances(.{ .filter = "labels.tool = compute-it", .partial_success = true }) catch |err| {
        fact("sweep: listing VMs failed: {t}", .{err});
        return;
    };
    defer page.deinit();
    for (page.value.instances) |i| {
        if (run) |r| if (!std.mem.eql(u8, i.label("run") orelse "", r)) continue;
        if (i.deletion_protection) {
            const res = try raw(f, client, a, .POST, try a.print("zones/{s}/instances/{s}/setDeletionProtection?deletionProtection=false", .{ i.zone, i.name }), "");
            if (res.status == 200) try waitRaw(client, res.body, .{ .zone = i.zone });
        }
        var op = client.deleteInstance(i.zone, i.name, .{ .no_graceful_shutdown = true }) catch |err| {
            fact("sweep: deleting {s} failed: {t}", .{ i.name, err });
            continue;
        };
        defer op.deinit();
        var done = client.waitOperation(op.value.ref(), .{}) catch continue;
        done.deinit();
        fact("sweep: deleted {s}", .{i.name});
    }
}

fn sweepDisks(f: *Fixture, client: *compute.Client, a: Allocator, run: ?[]const u8) !void {
    const res = try raw(f, client, a, .GET, "aggregated/disks?filter=labels.tool%20%3D%20compute-it&returnPartialSuccess=true", null);
    if (res.status != 200) return;
    const listed = try std.json.parseFromSliceLeaky(std.json.Value, a, res.body, .{});
    const scopes = listed.object.get("items") orelse return;
    for (scopes.object.values()) |scope| {
        const in_scope = scope.object.get("disks") orelse continue;
        for (in_scope.array.items) |d| try sweepDisk(f, client, a, d.object, run);
    }
}

fn sweepDisk(f: *Fixture, client: *compute.Client, a: Allocator, disk: std.json.ObjectMap, run: ?[]const u8) !void {
    const name = disk.get("name").?.string;
    if (run) |r| if (std.mem.indexOf(u8, name, r) == null) return;
    const zone_url = disk.get("zone").?.string;
    const zone = zone_url[std.mem.lastIndexOfScalar(u8, zone_url, '/').? + 1 ..];
    const res = try raw(f, client, a, .DELETE, try a.print("zones/{s}/disks/{s}", .{ zone, name }), null);
    if (res.status == 200) try waitRaw(client, res.body, .{ .zone = zone });
    fact("sweep: deleted disk {s} ({d})", .{ name, res.status });
}

fn sweepTemplates(f: *Fixture, client: *compute.Client, a: Allocator, run: ?[]const u8) !void {
    const list = try raw(f, client, a, .GET, "global/instanceTemplates?filter=name%20eq%20zigps-.*", null);
    if (list.status != 200) return;
    const parsed = try std.json.parseFromSliceLeaky(std.json.Value, a, list.body, .{});
    const items = parsed.object.get("items") orelse return;
    for (items.array.items) |t| {
        const name = t.object.get("name").?.string;
        if (run) |r| if (std.mem.indexOf(u8, name, r) == null) continue;
        const res = try raw(f, client, a, .DELETE, try a.print("global/instanceTemplates/{s}", .{name}), null);
        if (res.status == 200) try waitRaw(client, res.body, .global);
        fact("sweep: deleted template {s} ({d})", .{ name, res.status });
    }
}

test "compute against production: the lifecycle, previews and request ids, the fake held to it" {
    var f: Fixture = undefined;
    if (!try f.init()) return error.SkipZigTest;
    defer f.deinit();
    const gpa = testing.allocator;
    const a = f.arena.allocator();

    // Production.
    var http: core.transport.HttpTransport = .init(gpa, testing.io, "gcp-zig-compute-gcp-integration/0.1");
    defer http.deinit();
    var recorder: Recorder = .{ .inner = http.transport(), .arena = .init(gpa) };
    defer recorder.arena.deinit();
    var diag: compute.Diagnostics = .{};
    var client = try compute.Client.init(gpa, testing.io, .{
        .project_id = f.project,
        .token_provider = f.token.provider(),
        .scope = .read_write,
        .diagnostics = &diag,
        .transport = recorder.transport(),
        .user_agent = "gcp-zig-compute-gcp-integration/0.1",
    });
    defer client.deinit();
    try sweep(&f, &client, null);
    defer sweep(&f, &client, f.run) catch |err| fact("final sweep failed: {t}", .{err});

    const template = try a.print("zigps-{s}-tpl", .{f.run});
    const tpl_body = try a.print(
        \\{{"name":"{s}","properties":{{"machineType":"e2-small","labels":{{"purpose":"gcp-zig-test","tool":"compute-it","run":"{s}"}},"disks":[{{"boot":true,"autoDelete":true,"initializeParams":{{"sourceImage":"projects/debian-cloud/global/images/family/debian-12"}}}}],"networkInterfaces":[{{"network":"global/networks/default"}}],"scheduling":{{"provisioningModel":"SPOT","automaticRestart":false,"maxRunDuration":{{"seconds":"1800"}},"instanceTerminationAction":"DELETE"}}}}}}
    , .{ template, f.run });
    const made = try raw(&f, &client, a, .POST, "global/instanceTemplates", tpl_body);
    try testing.expectEqual(200, made.status);
    try waitRaw(&client, made.body, .global);
    fact("made template {s}", .{template});
    const disk = try a.print("zigps-{s}-disk", .{f.run});
    const disk_body = try a.print(
        \\{{"name":"{s}","sizeGb":"10","type":"zones/{s}/diskTypes/pd-standard","labels":{{"purpose":"gcp-zig-test","tool":"compute-it","run":"{s}"}}}}
    , .{ disk, f.zone, f.run });
    const made_disk = try raw(&f, &client, a, .POST, try a.print("zones/{s}/disks", .{f.zone}), disk_body);
    try testing.expectEqual(200, made_disk.status);
    try waitRaw(&client, made_disk.body, .{ .zone = f.zone });
    fact("made disk {s}", .{disk});

    var prod: Side = .{ .a = a, .client = &client, .diag = &diag, .recorder = &recorder, .zone = f.zone, .run = f.run };
    try scenario(&prod, template, disk);

    // B is under deletion protection, which the client cannot lift yet.
    {
        const b = prod.vm("b");
        const res = try raw(&f, &client, a, .POST, try a.print("zones/{s}/instances/{s}/setDeletionProtection?deletionProtection=false", .{ f.zone, b }), "");
        if (res.status == 200) try waitRaw(&client, res.body, .{ .zone = f.zone });
        var op = try client.deleteInstance(f.zone, b, .{ .no_graceful_shutdown = true });
        defer op.deinit();
        var done = try client.waitOperation(op.value.ref(), .{});
        done.deinit();
    }

    if (f.env.get("COMPUTE_TEST_SAVE")) |path| {
        var out: std.Io.Writer.Allocating = .init(a);
        for (recorder.answers.items) |line| try out.writer.print("{s}\n", .{line});
        try std.Io.Dir.cwd().writeFile(testing.io, .{ .sub_path = path, .data = out.written() });
        fact("saved {d} answers to {s}", .{ recorder.answers.items.len, path });
    }

    // The fake, the same scenario.
    const zones = [_][]const u8{f.zone};
    var fake: compute.testing.FakeCompute = .init(gpa, testing.io, .{ .project_id = f.project, .zones = &zones });
    defer fake.deinit();
    try fake.putTemplate(.{
        .name = template,
        .machine_type = "e2-small",
        .labels = prod.labels(),
        .spot = true,
        .max_run_duration_s = 1800,
        .termination_action = .delete,
    });
    try fake.putDisk(.{ .zone = f.zone, .name = disk });
    var fake_recorder: Recorder = .{ .inner = fake.transport(), .arena = .init(gpa) };
    defer fake_recorder.arena.deinit();
    var fake_diag: compute.Diagnostics = .{};
    var fake_client = try compute.Client.init(gpa, testing.io, .{
        .project_id = f.project,
        .token_provider = f.token.provider(),
        .scope = .read_write,
        .diagnostics = &fake_diag,
        .transport = fake_recorder.transport(),
    });
    defer fake_client.deinit();
    var mem: Side = .{ .a = a, .client = &fake_client, .diag = &fake_diag, .recorder = &fake_recorder, .zone = f.zone, .run = f.run };
    try scenario(&mem, template, disk);

    var differences: usize = 0;
    for (prod.lines.items, 0..) |line, n| {
        const other = if (n < mem.lines.items.len) mem.lines.items[n] else "(nothing)";
        if (std.mem.eql(u8, line, other)) {
            fact("{s}", .{line});
        } else {
            differences += 1;
            std.debug.print("production: {s}\nfake:       {s}\n", .{ line, other });
        }
    }
    fact("{d} previews held byte for byte to what was sent, {d} on the fake", .{ prod.previews, mem.previews });
    try testing.expectEqual(prod.lines.items.len, mem.lines.items.len);
    try testing.expectEqual(0, differences);
}
