//! The health view's recent-revisions widget: every revision in a region,
//! newest first, the failing ones called out, each a deploy marker for
//! the trend chart.
//!
//!     GOOGLE_CLOUD_PROJECT=my-project zig build example-run_revisions
//!     zig build example-run_revisions -- --fake     # no network
//!
//! Credentials come from `auth.findDefault`; reading takes run.readonly
//! (Cloud Run Viewer is enough on the IAM side). RUN_LOCATION picks the
//! region (us-central1 when unset). `--fake` reads `run.testing.FakeRun`
//! instead, with a healthy deploy and a broken one a test put in.

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
    const args = try init.minimal.args.toSlice(arena);
    for (args[@min(1, args.len)..]) |arg| {
        if (std.mem.eql(u8, arg, "--fake")) {
            use_fake = true;
        } else {
            std.debug.print("usage: run_revisions [--fake]\n", .{});
            return error.Usage;
        }
    }

    var fake: run.testing.FakeRun = .init(init.gpa, init.io, .{ .project_id = "my-project" });
    defer fake.deinit();
    var static: run.StaticToken = .{ .token = "fake" };
    var creds: ?auth.Credentials = null;
    defer if (creds) |*c| c.deinit();
    const project = if (use_fake) "my-project" else init.environ_map.get("GOOGLE_CLOUD_PROJECT") orelse {
        std.debug.print("set GOOGLE_CLOUD_PROJECT to the project whose revisions to read\n", .{});
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
        const now = std.Io.Clock.real.now(init.io);
        try fake.putLocation("us-central1");
        _ = try fake.putService(.{ .location = "us-central1", .id = "checkout", .terminal_condition = .{ .type = "Ready", .state = .failed, .reason = "REVISION_FAILED", .message = "Image 'gcr.io/shop/checkout:v8' not found." } });
        _ = try fake.putRevision(.{
            .location = "us-central1",
            .service = "checkout",
            .id = "checkout-00007-abc",
            .create_time = .{ .nanoseconds = now.nanoseconds - 26 * std.time.ns_per_hour },
            .containers = &.{.{ .image = "gcr.io/shop/checkout:v7" }},
            .conditions = &.{.{ .type = "Ready", .state = .succeeded, .message = "Deploying revision succeeded in 4.1s." }},
        });
        _ = try fake.putRevision(.{
            .location = "us-central1",
            .service = "checkout",
            .id = "checkout-00008-def",
            .create_time = .{ .nanoseconds = now.nanoseconds - 20 * std.time.ns_per_min },
            .containers = &.{.{ .image = "gcr.io/shop/checkout:v8" }},
            .conditions = &.{.{ .type = "Ready", .state = .failed, .message = "Image 'gcr.io/shop/checkout:v8' not found." }},
        });
    }

    // Every service's revisions in the region, newest first: the widget.
    var revisions = try client.listRevisions(location, "-", .{});
    defer revisions.deinit();
    const now = std.Io.Clock.real.now(init.io);
    var failing: usize = 0;
    for (revisions.value.revisions) |revision| {
        const age_min = if (revision.create_time) |t| @divFloor(now.nanoseconds - t.nanoseconds, std.time.ns_per_min) else -1;
        if (revision.ready()) {
            try out.print("[ok]     {s} (deployed {d} min ago)\n", .{ revision.id, age_min });
        } else {
            failing += 1;
            const why = if (revision.readyCondition()) |c| c.message else "no Ready condition";
            try out.print("[FAILED] {s} (deployed {d} min ago): {s}\n", .{ revision.id, age_min, why });
        }
    }
    try out.print("{d} of {d} revisions not ready in {s}\n", .{ failing, revisions.value.revisions.len, location });
    try out.flush();
}
