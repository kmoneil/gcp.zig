//! Lists every project the credentials can see, as a project switcher
//! caches them, and matches a few letters locally, as it would on each
//! keystroke.
//!
//!     zig build example-projects_list
//!     zig build example-projects_list -- --match=pay
//!     ... -- --no-parents      # skip the two searches for parent names
//!     ... -- --query='labels.team:payments' --include-deleted
//!     ... -- --quota-project=my-billing-project
//!     zig build example-projects_list -- --fake     # no network
//!
//! Credentials come from `auth.findDefault`: the file
//! `GOOGLE_APPLICATION_CREDENTIALS` names, then the one `gcloud auth
//! application-default login` writes, then the metadata server. A project
//! shows when the principal holds `resourcemanager.projects.get` on it,
//! there or above it (Viewer, Browser and the basic roles do). `--fake`
//! reads from `resource_manager.testing.FakeResourceManager` instead.
//!
//! No quota project is sent unless `--quota-project` names one, as gcloud
//! sends none for its project commands: the project charged is then the
//! credential's own, and a refusal says which project to turn the API on
//! in, with the link.

const std = @import("std");
const auth = @import("auth");
const rm = @import("resource_manager");

pub const std_options: std.Options = .{
    .log_scope_levels = &.{
        .{ .scope = .gcp_auth, .level = .warn },
        .{ .scope = .gcp_resource_manager, .level = .warn },
    },
};

pub fn main(init: std.process.Init) !void {
    const arena = init.arena.allocator();
    var stdout_buffer: [4096]u8 = undefined;
    var stdout = std.Io.File.stdout().writerStreaming(init.io, &stdout_buffer);
    const out = &stdout.interface;
    var diag: rm.Diagnostics = .{};

    var walk: rm.WalkOptions = .{};
    var quota_project: rm.QuotaProject = .none;
    var match: ?[]const u8 = null;
    var use_fake = false;
    var parents = true;
    const args = try init.minimal.args.toSlice(arena);
    for (args[@min(1, args.len)..]) |arg| {
        if (std.mem.eql(u8, arg, "--fake")) {
            use_fake = true;
        } else if (std.mem.eql(u8, arg, "--no-parents")) {
            parents = false;
        } else if (std.mem.eql(u8, arg, "--include-deleted")) {
            walk.include_pending_deletion = true;
        } else if (std.mem.eql(u8, arg, "--quota-from-credentials")) {
            quota_project = .from_credentials;
        } else if (std.mem.startsWith(u8, arg, "--quota-project=")) {
            quota_project = .{ .project = arg["--quota-project=".len..] };
        } else if (std.mem.startsWith(u8, arg, "--query=")) {
            walk.query = arg["--query=".len..];
        } else if (std.mem.startsWith(u8, arg, "--match=")) {
            match = arg["--match=".len..];
        } else {
            return usage(out, "unknown argument");
        }
    }

    var fake: rm.testing.FakeResourceManager = .init(init.gpa, init.io, .{});
    defer fake.deinit();
    var static: rm.StaticToken = .{ .token = "fake" };
    var creds: ?auth.Credentials = null;
    defer if (creds) |*c| c.deinit();

    var client_options: rm.Client.Options = .{ .token_provider = static.provider(), .diagnostics = &diag, .quota_project = quota_project };
    if (use_fake) {
        try fill(&fake);
        client_options.transport = fake.transport();
    } else {
        var lookup = try auth.Lookup.fromEnv(init.environ_map, arena);
        lookup.diagnostics = &diag;
        creds = auth.findDefault(init.gpa, init.io, lookup, .{}) catch |err| return fail(err, &diag, null);
        client_options.token_provider = creds.?.provider();
    }

    var client = rm.Client.init(init.gpa, init.io, client_options) catch |err| return fail(err, &diag, null);
    defer client.deinit();
    var list = client.allProjects(walk) catch |err| return fail(err, &diag, &client);
    defer list.deinit();
    // Display text for the folders and organizations the caller can read,
    // cached with the list in an app; the rest show by name.
    var names: ?rm.Owned(rm.ParentNames) = if (parents) client.parentNames(.{}) catch |err| return fail(err, &diag, &client) else null;
    defer if (names) |*n| n.deinit();

    var shown: usize = 0;
    for (list.value.projects) |p| {
        if (match) |m| if (!matches(p, m)) continue;
        shown += 1;
        const parent = if (p.parent) |x| try where(arena, x, if (names) |*n| &n.value else null) else "(no parent)";
        const state: []const u8 = if (p.state == .delete_requested) "  [pending deletion]" else "";
        try out.print("{s: <30} {d: >14}  {s: <30} {s}{s}\n", .{ p.project_id, p.number, p.label(), parent, state });
    }
    try out.print("({d} shown of {d} projects, {d} pages", .{ shown, list.value.projects.len, list.value.pages });
    if (list.value.pending_deletion > 0) try out.print(", {d} pending deletion left out", .{list.value.pending_deletion});
    if (!list.value.complete) try out.writeAll(", stopped at the page limit");
    try out.writeAll(")\n");
    try out.flush();
}

/// "Prod / Payments / example.com", as far as the caller can read.
fn where(arena: std.mem.Allocator, parent: rm.Parent, names: ?*const rm.ParentNames) ![]const u8 {
    const n = names orelse return parent.name;
    const path = try n.path(arena, parent);
    return std.mem.join(arena, " / ", path);
}

/// What a switcher matches as a person types: the letters anywhere in the
/// display name, the project id or the number, case aside.
fn matches(p: rm.Project, letters: []const u8) bool {
    if (std.ascii.findIgnoreCase(p.label(), letters) != null) return true;
    if (std.ascii.findIgnoreCase(p.project_id, letters) != null) return true;
    var buf: [20]u8 = undefined;
    return std.mem.indexOf(u8, std.fmt.bufPrint(&buf, "{d}", .{p.number}) catch unreachable, letters) != null;
}

/// A few projects, as a person with an organization might see them.
fn fill(fake: *rm.testing.FakeResourceManager) !void {
    try fake.addOrganization(.{ .name = "organizations/123", .domain = "example.com" });
    try fake.addFolder(.{ .name = "folders/876", .parent = "organizations/123", .display_name = "Payments" });
    try fake.addProject(.{ .number = 415104041262, .project_id = "payments-prod", .display_name = "Payments (prod)", .parent = "folders/876", .labels = &.{.{ .key = "team", .value = "payments" }} });
    try fake.addProject(.{ .number = 415104041263, .project_id = "payments-dev", .display_name = "Payments (dev)", .parent = "folders/876", .labels = &.{.{ .key = "team", .value = "payments" }} });
    try fake.addProject(.{ .number = 98765432101, .project_id = "web-frontend", .display_name = "Web", .parent = "organizations/123" });
    try fake.addProject(.{ .number = 12345678901, .project_id = "my-sandbox" });
    try fake.addProject(.{ .number = 55555555555, .project_id = "old-experiment", .display_name = "Old", .state = .delete_requested });
    try fake.addProject(.{ .number = 11111111111, .project_id = "someone-elses" });
    try fake.addPrincipal("fake", "my-sandbox");
    try fake.grant("fake", "organizations/123");
    try fake.grant("fake", "my-sandbox");
    try fake.grant("fake", "old-experiment");
}

fn usage(out: *std.Io.Writer, why: []const u8) !void {
    try out.print("{s}\nusage: projects_list [--match=LETTERS] [--query=QUERY] [--include-deleted] [--no-parents] [--quota-project=ID | --quota-from-credentials] [--fake]\n", .{why});
    try out.flush();
}

fn fail(err: anyerror, diag: *const rm.Diagnostics, client: ?*const rm.Client) anyerror {
    std.debug.print("error.{t}", .{err});
    if (diag.http_status != 0) std.debug.print(" (HTTP {d} {s})", .{ diag.http_status, diag.status() });
    if (diag.message().len != 0) std.debug.print(": {s}", .{diag.message()});
    std.debug.print("\n", .{});
    if (client) |c| if (c.lastConsumerRefusal()) |r| switch (r.reason) {
        .service_disabled => std.debug.print("Turn the Cloud Resource Manager API on in {s}, or name another project with --quota-project: {s}\n", .{ r.consumer, r.link orelse "(no link sent)" }),
        .quota_project_denied => std.debug.print("This principal may not charge {s}: it needs serviceusage.services.use there, or send no quota project.\n", .{r.consumer}),
    };
    return err;
}
