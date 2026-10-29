//! Integration tests of the IAM reads against Google: milestone 2 of the
//! IAM reads spec (issue #308). They need a project and a token for the
//! `cloud-platform` scope that may read its IAM policy, deploy and delete
//! a Cloud Run service and job, and make and delete buckets (Editor with
//! Storage Admin does):
//!
//!     GCP_TEST_PROJECT=extractctl GCP_TEST_TOKEN=$(cat cp.tok) \
//!     IAM_READS_TEST=1 zig build test-integration-gcp -Dtest-filter="iam reads:"
//!
//! Without the variables the test skips. It reads the project's policy
//! and tests permissions on it; deploys a `zigps-<run>` hello service and
//! a `zigps-<run>-job` job raw (the clients deploy nothing) and reads
//! theirs, and those of a service and a job nobody has; makes two
//! `zigps-<run>` buckets, one with uniform access, through the Storage
//! client, writes an object in each and reads their policies and tests.
//! Then it replays every Resource Manager and Cloud Run call against
//! their fakes, seeded with what production answered, and counts each
//! answer that differs. Cloud Storage keeps its fakes inside the module,
//! so its answers are held here to the facts its fake's unit tests hold
//! the fake to. Everything made is deleted. About a minute, at no cost.

const std = @import("std");
const core = @import("core");
const resource_manager = @import("resource_manager");
const run_mod = @import("run");
const storage = @import("storage");
const testing = std.testing;
const Allocator = std.mem.Allocator;

const location = "us-central1";
const hello = "us-docker.pkg.dev/cloudrun/container/hello";
const job_image = "us-docker.pkg.dev/cloudrun/container/job";

const project_permissions = [_][]const u8{
    "resourcemanager.projects.get",          "resourcemanager.projects.getIamPolicy",
    "resourcemanager.projects.setIamPolicy", "run.services.create",
    "storage.buckets.create",                "pubsub.topics.create",
};
const service_permissions = [_][]const u8{ "run.services.get", "run.services.update", "run.services.delete", "run.services.getIamPolicy", "run.services.setIamPolicy", "run.routes.invoke" };
const job_permissions = [_][]const u8{ "run.jobs.get", "run.jobs.run", "run.jobs.runWithOverrides", "run.executions.cancel", "run.jobs.setIamPolicy" };

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

/// A refusal's message up to its troubleshooter link, whose request id
/// is production's own.
fn words(message: []const u8) []const u8 {
    const at = std.mem.indexOf(u8, message, " Remediate access") orelse return message;
    return message[0..at];
}

/// A policy as one line: its version, then each binding's role and
/// members, as answered.
fn policyLine(a: Allocator, result: anyerror!core.Owned(core.iam.Policy), diag: *const core.Diagnostics) ![]const u8 {
    var owned = result catch |err| return a.print("error.{t}: {s}", .{ err, words(diag.message()) });
    defer owned.deinit();
    var w: std.Io.Writer.Allocating = .init(a);
    try w.writer.print("v{d}", .{owned.value.version});
    for (owned.value.bindings) |b| {
        try w.writer.print(" {s}{s}=", .{ b.role, if (b.condition != null) "?" else "" });
        for (b.members, 0..) |m, i| try w.writer.print("{s}{s}", .{ if (i == 0) "" else ",", m });
    }
    return w.written();
}

fn heldLine(a: Allocator, result: anyerror!core.Owned([]const []const u8), diag: *const core.Diagnostics) ![]const u8 {
    var owned = result catch |err| return a.print("error.{t}: {s}", .{ err, words(diag.message()) });
    defer owned.deinit();
    var w: std.Io.Writer.Allocating = .init(a);
    try w.writer.print("{d}:", .{owned.value.len});
    for (owned.value) |p| try w.writer.print(" {s}", .{p});
    return w.written();
}

/// Polls a Cloud Run operation until done; true when it finished in time.
fn awaitOperation(transport: core.transport.Transport, token: []const u8, a: Allocator, body: []const u8) !bool {
    const parsed = std.json.parseFromSliceLeaky(struct { name: []const u8 }, a, body, .{ .ignore_unknown_fields = true }) catch return false;
    const url = try a.print("https://run.googleapis.com/v2/{s}", .{parsed.name});
    for (0..60) |_| {
        const res = try transport.send(.{ .method = .GET, .url = url, .bearer = token, .timeout_ms = 60_000 }, a);
        if (res.status == 200 and (std.mem.indexOf(u8, res.body, "\"done\": true") != null or std.mem.indexOf(u8, res.body, "\"done\":true") != null)) return true;
        try testing.io.sleep(.fromMilliseconds(3_000), .awake);
    }
    return false;
}

test "iam reads: a project's, a Cloud Run service's and job's, and an object's policy and permissions; the fakes answer as production did" {
    const gpa = testing.allocator;
    var env = try testing.environ.createMap(gpa);
    defer env.deinit();
    const project = env.get("GCP_TEST_PROJECT") orelse return error.SkipZigTest;
    const raw_token = env.get("GCP_TEST_TOKEN") orelse return error.SkipZigTest;
    if (env.get("IAM_READS_TEST") == null) return error.SkipZigTest;
    var token: core.StaticToken = .{ .token = std.mem.trim(u8, raw_token, &std.ascii.whitespace) };
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    const a = arena.allocator();
    var bytes: [3]u8 = undefined;
    testing.io.random(&bytes);
    const run = try a.print("{x}", .{bytes});
    const nobody = try a.print("zigps-nope-{s}", .{run});
    var differences: usize = 0;
    var diag: core.Diagnostics = .{};
    var fake_diag: core.Diagnostics = .{};

    // --- The project -----------------------------------------------------
    {
        var rm = try resource_manager.Client.init(gpa, testing.io, .{ .token_provider = token.provider(), .diagnostics = &diag, .user_agent = "gcp-zig-iam-gcp-integration/0.1" });
        defer rm.deinit();
        var info = try rm.getProject(project);
        defer info.deinit();
        var policy = try rm.getProjectIamPolicy(project);
        defer policy.deinit();
        var held = try rm.testProjectIamPermissions(project, &project_permissions);
        defer held.deinit();
        const production = [_][]const u8{
            try policyLine(a, rm.getProjectIamPolicy(project), &diag),
            try heldLine(a, rm.testProjectIamPermissions(project, &project_permissions), &diag),
            try policyLine(a, rm.getProjectIamPolicy(nobody), &diag),
            try heldLine(a, rm.testProjectIamPermissions(nobody, project_permissions[0..1]), &diag),
            try heldLine(a, rm.testProjectIamPermissions(project, &.{ "pubsub.topics.get", "bigquery.datasets.get" }), &diag),
        };
        fact("project {s}: {d} bindings, version {d}", .{ project, policy.value.bindings.len, policy.value.version });

        var clock: core.testing.FakeClock = .{};
        var fake: resource_manager.testing.FakeResourceManager = .init(gpa, clock.io(), .{});
        defer fake.deinit();
        try fake.addProject(.{ .number = info.value.number, .project_id = project });
        try fake.addPrincipal("suite-token", project);
        try fake.grant("suite-token", project);
        try fake.setProjectPolicy(project, policy.value.bindings);
        const all_held = try std.mem.concat(a, []const u8, &.{ held.value, &.{ "pubsub.topics.get", "bigquery.datasets.get" } });
        try fake.holdPermissions("suite-token", project, all_held);
        var fake_token: core.StaticToken = .{ .token = "suite-token" };
        var in_memory = try resource_manager.Client.init(gpa, clock.io(), .{ .token_provider = fake_token.provider(), .diagnostics = &fake_diag, .transport = fake.transport() });
        defer in_memory.deinit();
        const replayed = [_][]const u8{
            try policyLine(a, in_memory.getProjectIamPolicy(project), &fake_diag),
            try heldLine(a, in_memory.testProjectIamPermissions(project, &project_permissions), &fake_diag),
            try policyLine(a, in_memory.getProjectIamPolicy(nobody), &fake_diag),
            try heldLine(a, in_memory.testProjectIamPermissions(nobody, project_permissions[0..1]), &fake_diag),
            try heldLine(a, in_memory.testProjectIamPermissions(project, &.{ "pubsub.topics.get", "bigquery.datasets.get" }), &fake_diag),
        };
        for ([_][]const u8{ "project policy", "project test", "missing project's policy", "missing project's test", "another service's permissions" }, production, replayed) |label, p, r| {
            // The policy itself names real accounts: compared, not printed.
            if (std.mem.eql(u8, label, "project policy") and std.mem.eql(u8, p, r)) {
                fact("{s}: the same {d} bytes", .{ label, p.len });
                continue;
            }
            agree(&differences, label, p, r);
        }
    }

    // --- Cloud Run -------------------------------------------------------
    {
        var client = try run_mod.Client.init(gpa, testing.io, .{ .project_id = project, .token_provider = token.provider(), .scope = .cloud_platform, .diagnostics = &diag, .user_agent = "gcp-zig-iam-gcp-integration/0.1" });
        defer client.deinit();
        const svc = try a.print("zigps-{s}", .{run});
        const job = try a.print("zigps-{s}-job", .{run});
        const base = try a.print("https://run.googleapis.com/v2/projects/{s}/locations/{s}", .{ project, location });
        var deployed = false;
        var made_job = false;
        defer {
            if (deployed) if (client.transport.send(.{ .method = .DELETE, .url = std.fmt.allocPrint(a, "{s}/services/{s}", .{ base, svc }) catch "", .bearer = token.token }, a)) |res| {
                if (res.status == 200) _ = awaitOperation(client.transport, token.token, a, res.body) catch false;
                fact("delete {s}: HTTP {d}", .{ svc, res.status });
            } else |err| fact("delete {s}: {t}", .{ svc, err });
            if (made_job) if (client.transport.send(.{ .method = .DELETE, .url = std.fmt.allocPrint(a, "{s}/jobs/{s}", .{ base, job }) catch "", .bearer = token.token }, a)) |res| {
                if (res.status == 200) _ = awaitOperation(client.transport, token.token, a, res.body) catch false;
                fact("delete {s}: HTTP {d}", .{ job, res.status });
            } else |err| fact("delete {s}: {t}", .{ job, err });
        }
        const made_svc = try client.transport.send(.{ .method = .POST, .url = try a.print("{s}/services?serviceId={s}", .{ base, svc }), .bearer = token.token, .timeout_ms = 60_000, .body = try a.print(
            \\{{"template":{{"containers":[{{"image":"{s}"}}]}},"labels":{{"zigps":"suite"}}}}
        , .{hello}) }, a);
        try testing.expectEqual(200, made_svc.status);
        deployed = true;
        try testing.expect(try awaitOperation(client.transport, token.token, a, made_svc.body));
        const made_j = try client.transport.send(.{ .method = .POST, .url = try a.print("{s}/jobs?jobId={s}", .{ base, job }), .bearer = token.token, .timeout_ms = 60_000, .body = try a.print(
            \\{{"template":{{"taskCount":1,"template":{{"maxRetries":0,"containers":[{{"image":"{s}"}}]}}}},"labels":{{"zigps":"suite"}}}}
        , .{job_image}) }, a);
        try testing.expectEqual(200, made_j.status);
        made_job = true;
        try testing.expect(try awaitOperation(client.transport, token.token, a, made_j.body));
        fact("made {s} and {s}", .{ svc, job });

        const Call = struct { label: []const u8, kind: enum { service_policy, service_test, job_policy, job_test }, id: []const u8, permissions: []const []const u8 = &.{} };
        const calls = [_]Call{
            .{ .label = "service policy", .kind = .service_policy, .id = svc },
            .{ .label = "service test", .kind = .service_test, .id = svc, .permissions = &service_permissions },
            .{ .label = "job policy", .kind = .job_policy, .id = job },
            .{ .label = "job test", .kind = .job_test, .id = job, .permissions = &job_permissions },
            .{ .label = "missing service's policy", .kind = .service_policy, .id = nobody },
            .{ .label = "missing service's test", .kind = .service_test, .id = nobody, .permissions = service_permissions[0..1] },
            .{ .label = "missing job's policy", .kind = .job_policy, .id = nobody },
            .{ .label = "another service's permission", .kind = .service_test, .id = svc, .permissions = &.{ "run.services.get", "pubsub.topics.get" } },
        };
        var production: [calls.len][]const u8 = undefined;
        for (calls, &production) |c, *out| out.* = switch (c.kind) {
            .service_policy => try policyLine(a, client.getServiceIamPolicy(location, c.id), &diag),
            .job_policy => try policyLine(a, client.getJobIamPolicy(location, c.id), &diag),
            .service_test => try heldLine(a, client.testServiceIamPermissions(location, c.id, c.permissions), &diag),
            .job_test => try heldLine(a, client.testJobIamPermissions(location, c.id, c.permissions), &diag),
        };

        // The fake, seeded with what production answered.
        var clock: core.testing.FakeClock = .{};
        var fake: run_mod.testing.FakeRun = .init(gpa, clock.io(), .{ .project_id = project });
        defer fake.deinit();
        try fake.putLocation(location);
        const svc_name = try fake.putService(.{ .location = location, .id = svc });
        const job_name = try fake.putJob(.{ .location = location, .id = job });
        var svc_policy = try client.getServiceIamPolicy(location, svc);
        defer svc_policy.deinit();
        if (svc_policy.value.bindings.len > 0) try fake.setIamPolicy(svc_name, svc_policy.value.bindings);
        var job_policy = try client.getJobIamPolicy(location, job);
        defer job_policy.deinit();
        if (job_policy.value.bindings.len > 0) try fake.setIamPolicy(job_name, job_policy.value.bindings);
        var svc_held = try client.testServiceIamPermissions(location, svc, &service_permissions);
        defer svc_held.deinit();
        try fake.holdPermissions(svc_name, svc_held.value);
        var job_held = try client.testJobIamPermissions(location, job, &job_permissions);
        defer job_held.deinit();
        try fake.holdPermissions(job_name, job_held.value);
        var nobody_held = try client.testServiceIamPermissions(location, nobody, service_permissions[0..1]);
        defer nobody_held.deinit();
        try fake.holdPermissions(try a.print("projects/{s}/locations/{s}/services/{s}", .{ project, location, nobody }), nobody_held.value);
        var fake_token: core.StaticToken = .{ .token = "suite-token" };
        var in_memory = try run_mod.Client.init(gpa, clock.io(), .{ .project_id = project, .token_provider = fake_token.provider(), .diagnostics = &fake_diag, .transport = fake.transport() });
        defer in_memory.deinit();
        for (calls, production) |c, p| {
            const r = switch (c.kind) {
                .service_policy => try policyLine(a, in_memory.getServiceIamPolicy(location, c.id), &fake_diag),
                .job_policy => try policyLine(a, in_memory.getJobIamPolicy(location, c.id), &fake_diag),
                .service_test => try heldLine(a, in_memory.testServiceIamPermissions(location, c.id, c.permissions), &fake_diag),
                .job_test => try heldLine(a, in_memory.testJobIamPermissions(location, c.id, c.permissions), &fake_diag),
            };
            agree(&differences, c.label, p, r);
        }
    }

    // --- Cloud Storage ---------------------------------------------------
    {
        var gcs = try storage.Client.init(gpa, testing.io, .{ .project_id = project, .token_provider = token.provider(), .scope = .cloud_platform, .diagnostics = &diag, .user_agent = "gcp-zig-iam-gcp-integration/0.1" });
        defer gcs.deinit();
        const fine_name = try a.print("zigps-{s}-fine", .{run});
        const uniform_name = try a.print("zigps-{s}-uniform", .{run});
        const fine = gcs.bucket(fine_name);
        const uniform = gcs.bucket(uniform_name);
        var made: [2]bool = .{ false, false };
        defer for ([_]storage.Bucket{ fine, uniform }, made) |b, was| if (was) {
            for ([_][]const u8{ "a b.txt", "a.txt" }) |name| b.object(name).delete(.{}) catch {};
            b.delete() catch |err| fact("delete {s}: {t} {s}", .{ b.name, err, diag.message() });
            fact("deleted {s}", .{b.name});
        };
        var info = try fine.create(.{ .location = "US-CENTRAL1", .uniform_bucket_level_access = false, .soft_delete_retention_s = 0 });
        info.deinit();
        made[0] = true;
        info = try uniform.create(.{ .location = "US-CENTRAL1", .uniform_bucket_level_access = true, .soft_delete_retention_s = 0 });
        info.deinit();
        made[1] = true;
        var written = try fine.object("a b.txt").upload("one", .{ .content_type = "text/plain" });
        written.deinit();
        written = try uniform.object("a.txt").upload("one", .{ .content_type = "text/plain" });
        written.deinit();
        fact("made {s} and {s}, an object in each", .{ fine_name, uniform_name });

        // What the Storage fake's unit tests hold it to, from milestone 0.
        const team = struct {
            fn member(al: Allocator, kind: []const u8, p: []const u8) ![]const u8 {
                return al.print("{s}:{s}", .{ kind, p });
            }
        }.member;
        var policy = try fine.object("a b.txt").iamPolicy(.{});
        defer policy.deinit();
        const holds = [_]bool{
            policy.value.version == 1,
            std.mem.eql(u8, policy.value.etag orelse "", "CAE="),
            policy.value.bindings.len == 2,
            std.mem.eql(u8, policy.value.bindings[0].role, "roles/storage.legacyObjectReader"),
            policy.value.grants("roles/storage.legacyObjectReader", try team(a, "projectViewer", project)),
            policy.value.grants("roles/storage.legacyObjectOwner", try team(a, "projectOwner", project)),
            policy.value.grants("roles/storage.legacyObjectOwner", try team(a, "projectEditor", project)),
            policy.value.bindings[1].members.len == 3,
        };
        for (holds, 0..) |ok, i| if (!ok) {
            differences += 1;
            std.debug.print("object policy, fact {d} does not hold: {s}\n", .{ i, try policyLine(a, fine.object("a b.txt").iamPolicy(.{}), &diag) });
        };
        fact("object policy: {d} bindings, the fake's shape", .{policy.value.bindings.len});
        const Expect = struct { label: []const u8, got: []const u8, want: []const u8 };
        const expected = [_]Expect{
            .{ .label = "uniform bucket's object policy", .got = try policyLine(a, uniform.object("a.txt").iamPolicy(.{}), &diag), .want = try a.print("error.InvalidArgument: Object policies are disabled for bucket '{s}' when uniform bucket-level access is enabled. Read more at https://cloud.google.com/storage/docs/uniform-bucket-level-access.", .{uniform_name}) },
            .{ .label = "missing object's policy", .got = try policyLine(a, fine.object("nope.txt").iamPolicy(.{}), &diag), .want = try a.print("error.NotFound: No such object: {s}/nope.txt", .{fine_name}) },
            .{ .label = "object test", .got = try heldLine(a, fine.object("a b.txt").testIamPermissions(&.{ "storage.objects.get", "storage.objects.delete" }, .{}), &diag), .want = "2: storage.objects.delete storage.objects.get" },
            .{ .label = "missing object's test", .got = try heldLine(a, fine.object("nope.txt").testIamPermissions(&.{"storage.objects.get"}, .{}), &diag), .want = "1: storage.objects.get" },
            .{ .label = "uniform bucket's object test", .got = try heldLine(a, uniform.object("a.txt").testIamPermissions(&.{"storage.objects.get"}, .{}), &diag), .want = "1: storage.objects.get" },
            .{ .label = "a bucket's permission on an object", .got = try heldLine(a, fine.object("a b.txt").testIamPermissions(&.{"storage.buckets.get"}, .{}), &diag), .want = "error.InvalidArgument: Invalid argument." },
        };
        for (expected) |e| agree(&differences, e.label, e.got, e.want);
    }

    try testing.expectEqual(0, differences);
}
