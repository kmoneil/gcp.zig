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

/// The writes, read back after each: the same calls on either side.
fn scenario(s: *Side, template: []const u8) !void {
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

    // Its life. Each write's id is made in `buf` as its argument is, so
    // the preview after it, built from `buf`, names the same request.
    try s.step("stop a", c.stopInstance(z, a, .{ .request_id = c.newRequestId(&buf) }), c.stopInstanceRequest(z, a, .{ .request_id = &buf }));
    try s.read(a, "a stopped");
    try s.waited("stop a again", try s.wrote("stop a again", c.stopInstance(z, a, .{})));
    try s.read(a, "a stopped again");
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

/// Deletes every VM labelled tool=compute-it (lifting deletion
/// protection first) and every `zigps-` template, `run` alone when
/// given.
fn sweep(f: *Fixture, client: *compute.Client, run: ?[]const u8) !void {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
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

    var prod: Side = .{ .a = a, .client = &client, .diag = &diag, .recorder = &recorder, .zone = f.zone, .run = f.run };
    try scenario(&prod, template);

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
    try scenario(&mem, template);

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
