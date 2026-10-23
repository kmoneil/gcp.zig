//! A permissions tab: who has access to a project, what it grants that
//! everything under it inherits, whether a Cloud Run service is public,
//! who may read one object, and what the caller may do on each.
//!
//!     GOOGLE_CLOUD_PROJECT=my-project zig build example-permissions -- \
//!         --service us-central1/checkout --object gs://my-bucket/report.pdf
//!     zig build example-permissions -- --fake     # no network
//!
//! Credentials come from `auth.findDefault`. The project's policy takes
//! Resource Manager's read-only scope and `resourcemanager.projects.
//! getIamPolicy` (Viewer has it); a service's takes `run.readonly`; an
//! object's needs the `cloud-platform` scope, the only one short of full
//! control that Cloud Storage takes for it, and an object in a bucket
//! without uniform access. `--fake` reads `resource_manager.testing.
//! FakeResourceManager` and `run.testing.FakeRun` instead, with a policy
//! and held permissions put in, and leaves out the object.

const std = @import("std");
const auth = @import("auth");
const resource_manager = @import("resource_manager");
const run = @import("run");
const storage = @import("storage");

pub const std_options: std.Options = .{
    .log_scope_levels = &.{
        .{ .scope = .gcp_auth, .level = .warn },
        .{ .scope = .gcp_resource_manager, .level = .warn },
        .{ .scope = .gcp_run, .level = .warn },
        .{ .scope = .gcp_storage, .level = .warn },
    },
};

const Policy = resource_manager.iam.Policy;

/// Each binding as a line: the role, then its members, `PUBLIC` beside a
/// role that `allUsers` or `allAuthenticatedUsers` holds.
fn printPolicy(out: *std.Io.Writer, what: []const u8, policy: Policy) !void {
    try out.print("{s}: {d} bindings\n", .{ what, policy.bindings.len });
    for (policy.bindings) |b| {
        var public = false;
        for (b.members) |m| public = public or std.mem.eql(u8, m, "allUsers") or std.mem.eql(u8, m, "allAuthenticatedUsers");
        try out.print("  {s}{s}{s}\n", .{ b.role, if (b.condition != null) " (conditional)" else "", if (public) "  PUBLIC" else "" });
        for (b.members) |m| try out.print("    {s}\n", .{m});
    }
}

fn printHeld(out: *std.Io.Writer, asked: []const []const u8, held: []const []const u8) !void {
    for (asked) |p| {
        const can = for (held) |h| {
            if (std.mem.eql(u8, h, p)) break true;
        } else false;
        try out.print("  {s} {s}\n", .{ if (can) "can   " else "cannot", p });
    }
}

pub fn main(init: std.process.Init) !void {
    const arena = init.arena.allocator();
    var stdout_buffer: [4096]u8 = undefined;
    var stdout = std.Io.File.stdout().writerStreaming(init.io, &stdout_buffer);
    const out = &stdout.interface;

    var use_fake = false;
    var service: ?[]const u8 = null;
    var object: ?[]const u8 = null;
    const args = try init.minimal.args.toSlice(arena);
    var i: usize = 1;
    while (i < args.len) : (i += 1) {
        if (std.mem.eql(u8, args[i], "--fake")) {
            use_fake = true;
        } else if (std.mem.eql(u8, args[i], "--service") and i + 1 < args.len) {
            i += 1;
            service = args[i];
        } else if (std.mem.eql(u8, args[i], "--object") and i + 1 < args.len) {
            i += 1;
            object = args[i];
        } else {
            std.debug.print("usage: permissions [--fake] [--service LOCATION/ID] [--object gs://BUCKET/NAME]\n", .{});
            return error.Usage;
        }
    }
    if (use_fake) service = "us-central1/checkout";
    const project = if (use_fake) "shop-prod" else init.environ_map.get("GOOGLE_CLOUD_PROJECT") orelse {
        std.debug.print("set GOOGLE_CLOUD_PROJECT to the project whose permissions to read\n", .{});
        return error.MissingProject;
    };

    var rm_fake: resource_manager.testing.FakeResourceManager = .init(init.gpa, init.io, .{});
    defer rm_fake.deinit();
    var run_fake: run.testing.FakeRun = .init(init.gpa, init.io, .{ .project_id = project });
    defer run_fake.deinit();
    if (use_fake) {
        try rm_fake.addProject(.{ .number = 123456789012, .project_id = project, .display_name = "Shop" });
        try rm_fake.addPrincipal("fake", project);
        try rm_fake.grant("fake", project);
        try rm_fake.setProjectPolicy(project, &.{
            .{ .role = "roles/owner", .members = &.{"user:alice@example.com"} },
            .{ .role = "roles/viewer", .members = &.{ "group:engineers@example.com", "serviceAccount:ci@shop-prod.iam.gserviceaccount.com" } },
            .{ .role = "roles/run.developer", .members = &.{"user:bob@example.com"}, .condition = "{\"title\":\"until launch\",\"expression\":\"request.time < timestamp('2027-01-01T00:00:00Z')\"}" },
        });
        try rm_fake.holdPermissions("fake", project, &.{ "resourcemanager.projects.get", "resourcemanager.projects.getIamPolicy", "run.services.create" });
        try run_fake.putLocation("us-central1");
        const name = try run_fake.putService(.{ .location = "us-central1", .id = "checkout" });
        try run_fake.setIamPolicy(name, &.{.{ .role = "roles/run.invoker", .members = &.{"allUsers"} }});
        try run_fake.holdPermissions(name, &.{ "run.services.get", "run.routes.invoke" });
    }

    // One set of credentials per client where they bind their scopes, as
    // a key or impersonation does; a login serves all three.
    var held_creds: [3]?auth.Credentials = @splat(null);
    defer for (&held_creds) |*c| if (c.*) |*x| x.deinit();
    var diag: resource_manager.Diagnostics = .{};
    var static: resource_manager.StaticToken = .{ .token = "fake" };
    var providers: [3]resource_manager.TokenProvider = @splat(static.provider());
    if (!use_fake) {
        var lookup = try auth.Lookup.fromEnv(init.environ_map, arena);
        lookup.diagnostics = &diag;
        held_creds[0] = try auth.findDefault(init.gpa, init.io, lookup, .{});
        for (&held_creds, &providers, 0..) |*c, *p, n| {
            if (n > 0) c.* = if (held_creds[0].?.bindsScopes()) try auth.findDefault(init.gpa, init.io, lookup, .{}) else null;
            p.* = if (c.*) |*x| x.provider() else held_creds[0].?.provider();
        }
    }

    var rm = try resource_manager.Client.init(init.gpa, init.io, .{
        .token_provider = providers[0],
        .transport = if (use_fake) rm_fake.transport() else null,
        .diagnostics = &diag,
    });
    defer rm.deinit();
    var policy = rm.getProjectIamPolicy(project) catch |err| {
        std.debug.print("{s}'s policy: {t}: {s}\n", .{ project, err, diag.message() });
        return err;
    };
    defer policy.deinit();
    try printPolicy(out, project, policy.value);
    const project_asked = [_][]const u8{ "resourcemanager.projects.getIamPolicy", "resourcemanager.projects.setIamPolicy", "run.services.create", "storage.buckets.create" };
    var project_held = try rm.testProjectIamPermissions(project, &project_asked);
    defer project_held.deinit();
    try out.print("on {s}, you:\n", .{project});
    try printHeld(out, &project_asked, project_held.value);

    if (service) |s| {
        const slash = std.mem.indexOfScalar(u8, s, '/') orelse return error.Usage;
        var client = try run.Client.init(init.gpa, init.io, .{
            .project_id = project,
            .token_provider = providers[1],
            .transport = if (use_fake) run_fake.transport() else null,
            .diagnostics = &diag,
        });
        defer client.deinit();
        var svc_policy = try client.getServiceIamPolicy(s[0..slash], s[slash + 1 ..]);
        defer svc_policy.deinit();
        try out.print("\n", .{});
        try printPolicy(out, s, svc_policy.value);
        try out.print("  (and everything {s} grants)\n", .{project});
        const asked = [_][]const u8{ "run.services.get", "run.services.update", "run.routes.invoke" };
        var held = try client.testServiceIamPermissions(s[0..slash], s[slash + 1 ..], &asked);
        defer held.deinit();
        try out.print("on {s}, you:\n", .{s});
        try printHeld(out, &asked, held.value);
    }

    if (object) |o| {
        if (!std.mem.startsWith(u8, o, "gs://")) return error.Usage;
        const rest = o["gs://".len..];
        const slash = std.mem.indexOfScalar(u8, rest, '/') orelse return error.Usage;
        var gcs = try storage.Client.init(init.gpa, init.io, .{
            .project_id = project,
            .token_provider = providers[2],
            .scope = .cloud_platform,
            .diagnostics = &diag,
        });
        defer gcs.deinit();
        const handle = gcs.bucket(rest[0..slash]).object(rest[slash + 1 ..]);
        try out.print("\n", .{});
        if (handle.iamPolicy(.{})) |owned| {
            var obj_policy = owned;
            defer obj_policy.deinit();
            try printPolicy(out, o, obj_policy.value);
        } else |err| switch (err) {
            // A bucket with uniform access: its policy is the object's.
            error.InvalidArgument => try out.print("{s}: {s}\n", .{ o, diag.message() }),
            else => return err,
        }
        const asked = [_][]const u8{ "storage.objects.get", "storage.objects.delete" };
        var held = try handle.testIamPermissions(&asked, .{});
        defer held.deinit();
        try out.print("on {s}, you:\n", .{o});
        try printHeld(out, &asked, held.value);
    }
    try out.flush();
}
