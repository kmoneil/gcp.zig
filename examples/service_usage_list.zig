//! The APIs a project has enabled, and whether the ones named are.
//!
//!     zig build example-service_usage_list -- my-project
//!     zig build example-service_usage_list -- my-project pubsub.googleapis.com dataflow.googleapis.com
//!     zig build example-service_usage_list -- --fake     # no network
//!
//! The first argument is the project, by id or number; the rest, when
//! given, are services to ask about, at most 30, as a panel that says an
//! API is off would ask after a call fails because it is. Credentials come
//! from `auth.findDefault`; the principal needs
//! `serviceusage.services.list` and `.get` on the project (Viewer has
//! them). `--fake` reads `service_usage.testing.FakeServiceUsage` instead,
//! holding three services with the titles and summaries production gave
//! them on 2026-11-06, Dataflow's turned off.

const std = @import("std");
const auth = @import("auth");
const su = @import("service_usage");

pub const std_options: std.Options = .{
    .log_scope_levels = &.{
        .{ .scope = .gcp_auth, .level = .warn },
        .{ .scope = .gcp_service_usage, .level = .warn },
    },
};

pub fn main(init: std.process.Init) !void {
    const arena = init.arena.allocator();
    var stdout_buffer: [4096]u8 = undefined;
    var stdout = std.Io.File.stdout().writerStreaming(init.io, &stdout_buffer);
    const out = &stdout.interface;
    var diag: su.Diagnostics = .{};

    const all = try init.minimal.args.toSlice(arena);
    const args = all[@min(1, all.len)..];
    const use_fake = args.len > 0 and std.mem.eql(u8, args[0], "--fake");
    if (args.len == 0 or (use_fake and args.len > 1)) {
        std.debug.print("usage: service_usage_list PROJECT [SERVICE...] | --fake\n", .{});
        return error.Usage;
    }
    const project = if (use_fake) "my-project" else args[0];
    const asked: []const []const u8 = if (use_fake) &.{ "pubsub.googleapis.com", "dataflow.googleapis.com" } else args[1..];

    var fake: su.testing.FakeServiceUsage = .init(init.gpa, init.io, .{});
    defer fake.deinit();
    var static: su.StaticToken = .{ .token = "fake" };
    var creds: ?auth.Credentials = null;
    defer if (creds) |*c| c.deinit();
    if (use_fake) {
        try putSome(&fake);
    } else {
        var lookup = try auth.Lookup.fromEnv(init.environ_map, arena);
        lookup.diagnostics = &diag;
        creds = try auth.findDefault(init.gpa, init.io, lookup, .{});
    }
    var client = try su.Client.init(init.gpa, init.io, .{
        .project_id = project,
        .token_provider = if (creds) |*c| c.provider() else static.provider(),
        .transport = if (use_fake) fake.transport() else null,
        .diagnostics = &diag,
    });
    defer client.deinit();

    var enabled = client.enabledServices() catch |err| {
        std.debug.print("listing the enabled APIs failed: {t}: {s}\n", .{ err, diag.message() });
        return err;
    };
    defer enabled.deinit();
    const number = if (enabled.value.len > 0) enabled.value[0].project_number else "?";
    try out.print("{d} APIs enabled in {s} (project number {s}):\n", .{ enabled.value.len, project, number });
    for (enabled.value) |s| try out.print("  {s:<40} {s}\n", .{ s.name, s.title });

    if (asked.len > 0) {
        var states = client.getServices(asked) catch |err| {
            std.debug.print("asking about {d} services failed: {t}: {s}\n", .{ asked.len, err, diag.message() });
            return err;
        };
        defer states.deinit();
        try out.writeAll("\nasked:\n");
        for (states.value) |s| try out.print("  {s:<40} {t}\n", .{ s.name, s.state });
    }
    try out.flush();
}

/// Two enabled services and one not, in production's words.
fn putSome(fake: *su.testing.FakeServiceUsage) !void {
    try fake.putService(.{ .name = "pubsub.googleapis.com", .title = "Cloud Pub/Sub API", .summary = "Provides reliable, many-to-many, asynchronous messaging between applications.\n", .state = .enabled });
    try fake.putService(.{ .name = "serviceusage.googleapis.com", .title = "Service Usage API", .summary = "Enables services that service consumers want to use on Google Cloud Platform, lists the available or enabled services, or disables services that service consumers no longer use.", .state = .enabled });
    try fake.putService(.{ .name = "dataflow.googleapis.com", .title = "Dataflow API", .summary = "Manages Google Cloud Dataflow projects on Google Cloud Platform.", .state = .disabled });
}
