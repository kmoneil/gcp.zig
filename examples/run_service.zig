//! One Cloud Run service's page: its URL and ingress, its scaling, and
//! what its next revision will run with: each container's image, CPU and
//! memory, the names of its environment variables and the secrets behind
//! them (never a value), its volumes, and its VPC access.
//!
//!     GOOGLE_CLOUD_PROJECT=my-project zig build example-run_service -- checkout
//!     zig build example-run_service -- --fake     # no network
//!
//! Credentials come from `auth.findDefault`; reading takes run.readonly
//! (Cloud Run Viewer is enough on the IAM side). RUN_LOCATION picks the
//! region (us-central1 when unset). `--fake` reads `run.testing.FakeRun`
//! instead, with a service a test put in.

const std = @import("std");
const auth = @import("auth");
const run = @import("run");

pub const std_options: std.Options = .{
    .log_scope_levels = &.{
        .{ .scope = .gcp_auth, .level = .warn },
        .{ .scope = .gcp_run, .level = .warn },
    },
};

pub fn main(init: std.process.Init) !void {
    const arena = init.arena.allocator();
    var stdout_buffer: [4096]u8 = undefined;
    var stdout = std.Io.File.stdout().writerStreaming(init.io, &stdout_buffer);
    const out = &stdout.interface;
    var diag: run.Diagnostics = .{};

    var use_fake = false;
    var service_id: ?[]const u8 = null;
    const args = try init.minimal.args.toSlice(arena);
    for (args[@min(1, args.len)..]) |arg| {
        if (std.mem.eql(u8, arg, "--fake")) {
            use_fake = true;
        } else if (service_id == null and !std.mem.startsWith(u8, arg, "-")) {
            service_id = arg;
        } else {
            std.debug.print("usage: run_service [--fake] SERVICE\n", .{});
            return error.Usage;
        }
    }
    if (use_fake) service_id = "checkout";
    const id = service_id orelse {
        std.debug.print("usage: run_service [--fake] SERVICE\n", .{});
        return error.Usage;
    };

    var fake: run.testing.FakeRun = .init(init.gpa, init.io, .{ .project_id = "my-project" });
    defer fake.deinit();
    var static: run.StaticToken = .{ .token = "fake" };
    var creds: ?auth.Credentials = null;
    defer if (creds) |*c| c.deinit();
    const project = if (use_fake) "my-project" else init.environ_map.get("GOOGLE_CLOUD_PROJECT") orelse {
        std.debug.print("set GOOGLE_CLOUD_PROJECT to the project whose service to read\n", .{});
        return error.MissingProject;
    };
    const location = if (use_fake) "us-central1" else init.environ_map.get("RUN_LOCATION") orelse "us-central1";
    if (!use_fake) {
        var lookup = try auth.Lookup.fromEnv(init.environ_map, arena);
        lookup.diagnostics = &diag;
        creds = try auth.findDefault(init.gpa, init.io, lookup, .{});
    }
    var client = try run.Client.init(init.gpa, init.io, .{
        .project_id = project,
        .token_provider = if (creds) |*c| c.provider() else static.provider(),
        .transport = if (use_fake) fake.transport() else null,
        .diagnostics = &diag,
    });
    defer client.deinit();

    if (use_fake) {
        try fake.putLocation("us-central1");
        _ = try fake.putService(.{
            .location = "us-central1",
            .id = "checkout",
            .uri = "https://checkout-abc123-uc.a.run.app",
            .ingress = .internal_load_balancer,
            .scaling = .{ .max_instances = 10, .mode = .automatic },
            .latest_ready_revision = "checkout-00008-def",
            .terminal_condition = .{ .type = "Ready", .state = .succeeded },
            .template = .{
                .containers = &.{.{
                    .image = "us-docker.pkg.dev/shop/app/checkout:v8",
                    .env = &.{
                        .{ .name = "STORE_REGION", .source = .{ .value = "eu" } },
                        .{ .name = "DB_PASSWORD", .source = .{ .secret = .{ .secret = "checkout-db", .version = "latest" } } },
                    },
                    .resources = .{ .cpu = "2", .memory = "1Gi", .startup_cpu_boost = true },
                    .volume_mounts = &.{.{ .name = "config", .mount_path = "/etc/checkout" }},
                }},
                .volumes = &.{.{ .name = "config", .source = .{ .secret = .{ .secret = "checkout-config", .items = &.{.{ .path = "app.yaml", .version = "3" }} } } }},
                .max_instances = 5,
                .concurrency = 40,
                .timeout_s = 120,
                .execution_environment = .gen2,
                .vpc_access = .{ .egress = .private_ranges_only, .network_interfaces = &.{.{ .network = "shop", .subnetwork = "shop-eu" }} },
            },
        });
    }

    var service = client.getService(location, id) catch |err| {
        std.debug.print("{s}: {t}: {s}\n", .{ id, err, diag.message() });
        return err;
    };
    defer service.deinit();
    const s = service.value;
    try out.print("{s} in {s}: {s}\n", .{ s.id, s.location, if (s.ready()) "ready" else "NOT READY" });
    if (s.default_uri_disabled) {
        try out.print("  URL: disabled\n", .{});
    } else try out.print("  URL: {s}\n", .{s.uri});
    try out.print("  ingress: {t}\n", .{s.ingress});
    if (s.scaling) |sc| try out.print("  service scaling: {t}, at most {?d} instances\n", .{ sc.mode, sc.max_instances });
    try out.print("  serving: {s}\n", .{if (s.latest_ready_revision.len > 0) s.latest_ready_revision else "nothing ready"});

    const t = s.template orelse {
        try out.flush();
        return;
    };
    try out.print("next revision:\n", .{});
    try out.print("  {d} to {?d} instances, {?d} requests each, {?d}s a request, {t}\n", .{ t.min_instances orelse 0, t.max_instances, t.concurrency, t.timeout_s, t.execution_environment });
    if (t.vpc_access) |vpc| {
        try out.print("  VPC: {t}", .{vpc.egress});
        if (vpc.connector.len > 0) try out.print(" through {s}", .{vpc.connector});
        for (vpc.network_interfaces) |ni| try out.print(" via {s}/{s}", .{ ni.network, ni.subnetwork });
        try out.print("\n", .{});
    }
    for (t.containers) |c| {
        try out.print("  container {s}\n", .{c.image});
        if (c.resources) |r| try out.print("    {d} millicores, {d} MiB{s}\n", .{ r.cpuMillis() orelse 0, (r.memoryBytes() orelse 0) >> 20, if (r.cpu_idle) ", CPU only during requests" else "" });
        // Names only: a value is often a credential.
        for (c.env) |e| switch (e.source) {
            .value => try out.print("    env {s}\n", .{e.name}),
            .secret => |ref| try out.print("    env {s} from secret {s} ({s})\n", .{ e.name, ref.secret, ref.version }),
        };
        for (c.volume_mounts) |m| try out.print("    mounts {s} at {s}\n", .{ m.name, m.mount_path });
    }
    for (t.volumes) |v| switch (v.source) {
        .secret => |sv| try out.print("  volume {s}: secret {s}\n", .{ v.name, sv.secret }),
        .empty_dir => |ed| try out.print("  volume {s}: empty dir {s}\n", .{ v.name, ed.medium }),
        .cloud_sql => |sql| try out.print("  volume {s}: Cloud SQL {d} instances\n", .{ v.name, sql.instances.len }),
        .gcs => |g| try out.print("  volume {s}: gs://{s}\n", .{ v.name, g.bucket }),
        .nfs => |n| try out.print("  volume {s}: nfs {s}:{s}\n", .{ v.name, n.server, n.path }),
        .other => |key| try out.print("  volume {s}: {s}\n", .{ v.name, key }),
    };
    try out.flush();
}
