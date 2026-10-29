//! Integration tests against real Cloud Resource Manager, which has no
//! emulator: milestone 3 of the Resource Manager spec. They need the id of
//! a project the token's principal can see, and a token:
//!
//!     GCP_TEST_PROJECT=extractctl GCP_TEST_TOKEN=$(cat token.txt) \
//!     zig build test-integration-gcp -Dtest-filter=resource_manager
//!
//! Without both variables every test skips. Everything here reads: nothing
//! is created, enabled or granted. The quota tests name
//! `bigquery-public-data`, a public project no test principal may charge,
//! which production refuses; nothing else changes. Calls are free. The
//! last test runs the same scripts against production and against
//! `FakeResourceManager` set up as production answered, and holds the fake
//! to what production said.

const std = @import("std");
const core = @import("core");
const rm = @import("resource_manager");
const testing = std.testing;

/// A public project, readable by any principal through get, which no test
/// principal may name as its quota project.
const public_project = "bigquery-public-data";
const missing_project = "zigps-no-such-project-x";

const Fixture = struct {
    env: std.process.Environ.Map,
    token: core.StaticToken,
    diag: rm.Diagnostics,
    client: rm.Client,
    project: []const u8,

    fn init(f: *Fixture) !bool {
        const gpa = testing.allocator;
        f.env = try testing.environ.createMap(gpa);
        errdefer f.env.deinit();
        f.project = f.env.get("GCP_TEST_PROJECT") orelse return f.skip();
        const token = f.env.get("GCP_TEST_TOKEN") orelse return f.skip();
        f.token = .{ .token = std.mem.trim(u8, token, &std.ascii.whitespace) };
        f.diag = .{};
        f.client = try f.clientFor(.none, &f.diag);
        return true;
    }

    fn clientFor(f: *Fixture, quota: rm.QuotaProject, diag: *rm.Diagnostics) !rm.Client {
        return .init(testing.allocator, testing.io, .{
            .token_provider = f.token.provider(),
            .diagnostics = diag,
            .quota_project = quota,
            .user_agent = "gcp-zig-resource_manager-gcp-integration/0.1",
        });
    }

    fn skip(f: *Fixture) bool {
        f.env.deinit();
        return false;
    }

    fn deinit(f: *Fixture) void {
        f.client.deinit();
        f.env.deinit();
    }
};

fn fact(comptime format: []const u8, args: anytype) void {
    std.debug.print("  fact: " ++ format ++ "\n", args);
}

test "resource_manager: search finds the test project; get by id and by number agrees" {
    var f: Fixture = undefined;
    if (!try f.init()) return error.SkipZigTest;
    defer f.deinit();
    var list = try f.client.allProjects(.{});
    defer list.deinit();
    try testing.expect(list.value.complete);
    fact("{d} projects visible in {d} pages, {d} pending deletion left out", .{ list.value.projects.len, list.value.pages, list.value.pending_deletion });
    const found = for (list.value.projects) |p| {
        if (std.mem.eql(u8, p.project_id, f.project)) break p;
    } else return error.TestProjectNotFound;
    try testing.expectEqual(.active, found.state);
    // Production's search leaves out updateTime, as measured.
    if (found.update_time != null) fact("search now sends updateTime", .{});

    var by_id = try f.client.getProject(f.project);
    defer by_id.deinit();
    var number_buf: [20]u8 = undefined;
    var by_number = try f.client.getProject(try std.fmt.bufPrint(&number_buf, "{d}", .{found.number}));
    defer by_number.deinit();
    try testing.expectEqual(found.number, by_id.value.number);
    try testing.expectEqualStrings(by_id.value.project_id, by_number.value.project_id);
    try testing.expectEqualStrings(found.name, by_id.value.name);
    try testing.expect(by_id.value.update_time != null);
    if (found.parent) |p| fact("the test project's parent is {s}", .{p.name}) else fact("the test project has no parent", .{});

    // A public project is read by get, and no search shows it.
    var public = try f.client.getProject(public_project);
    defer public.deinit();
    for (list.value.projects) |p| try testing.expect(!std.mem.eql(u8, p.project_id, public_project));
    try testing.expectError(error.PermissionDenied, f.client.getProject(missing_project));
    try testing.expect(std.mem.indexOf(u8, f.diag.message(), "(or it may not exist)") != null);
}

test "resource_manager: pages of one project each hold the same projects" {
    var f: Fixture = undefined;
    if (!try f.init()) return error.SkipZigTest;
    defer f.deinit();
    var whole = try f.client.allProjects(.{});
    defer whole.deinit();
    var paged = try f.client.allProjects(.{ .page_size = 1 });
    defer paged.deinit();
    try testing.expect(paged.value.complete);
    try testing.expectEqual(whole.value.projects.len, paged.value.projects.len);
    for (whole.value.projects, paged.value.projects) |a, b| try testing.expectEqual(a.number, b.number);
    fact("{d} pages of one", .{paged.value.pages});
}

test "resource_manager: the quota project: none, the test project, one it may not use, one that does not exist" {
    var f: Fixture = undefined;
    if (!try f.init()) return error.SkipZigTest;
    defer f.deinit();
    var diag: rm.Diagnostics = .{};
    var own = try f.clientFor(.{ .project = f.project }, &diag);
    defer own.deinit();
    var list = try own.allProjects(.{});
    list.deinit();

    var denied = try f.clientFor(.{ .project = public_project }, &diag);
    defer denied.deinit();
    try testing.expectError(error.QuotaProjectDenied, denied.allProjects(.{}));
    const refusal = denied.lastConsumerRefusal().?;
    try testing.expectEqual(.quota_project_denied, refusal.reason);
    try testing.expectEqualStrings("projects/" ++ public_project, refusal.consumer);
    try testing.expect(refusal.link != null);

    var missing = try f.clientFor(.{ .project = missing_project }, &diag);
    defer missing.deinit();
    try testing.expectError(error.QuotaProjectDenied, missing.allProjects(.{}));
    try testing.expectEqual(null, missing.lastConsumerRefusal().?.link);
    try testing.expectEqual(400, diag.http_status);
}

test "resource_manager: parent names, and the searches they read" {
    var f: Fixture = undefined;
    if (!try f.init()) return error.SkipZigTest;
    defer f.deinit();
    var names = try f.client.parentNames(.{});
    defer names.deinit();
    try testing.expect(names.value.complete);
    fact("{d} folders and {d} organizations readable", .{ names.value.folders.len, names.value.organizations.len });
}

/// One script of the replay: what is asked, of whom.
const Script = struct {
    name: []const u8,
    /// `after_first`: the first page of a search with no query, one
    /// project a page, then its token sent with `arg` as the query and
    /// `size` projects a page. It needs two visible projects.
    kind: enum { search, get, after_first } = .search,
    size: u31 = 1,
    /// The query, or the project a get names. `@id@`, `@ID@`, `@pre@` and
    /// `@number@` become the test project's id, its id in capitals, its
    /// first three letters and its number.
    arg: []const u8 = "",
    quota: enum { none, own, public, missing } = .none,
};

const scripts = [_]Script{
    .{ .name = "everything" },
    .{ .name = "an id", .arg = "id:@id@" },
    .{ .name = "projectId in capitals", .arg = "projectId:@ID@" },
    .{ .name = "an id's prefix", .arg = "id:@pre@*" },
    .{ .name = "an id's prefix with no star", .arg = "id:@pre@" },
    .{ .name = "= for :", .arg = "projectId=@id@" },
    .{ .name = "a quoted id", .arg = "projectId:\"@id@\"" },
    .{ .name = "active", .arg = "state:ACTIVE" },
    .{ .name = "pending deletion", .arg = "state:DELETE_REQUESTED" },
    .{ .name = "two terms are AND", .arg = "projectId:@id@ state:DELETE_REQUESTED" },
    .{ .name = "an explicit AND", .arg = "projectId:@id@ AND state:ACTIVE" },
    .{ .name = "OR", .arg = "projectId:@id@ OR state:DELETE_REQUESTED" },
    .{ .name = "NOT", .arg = "NOT state:DELETE_REQUESTED" },
    .{ .name = "a minus", .arg = "-projectId:@id@" },
    .{ .name = "parentheses", .arg = "(projectId:@id@ OR projectId:zzzz-none) state:ACTIVE" },
    .{ .name = "a project number", .arg = "projectNumber:@number@" },
    .{ .name = "an id that is a number", .arg = "id:@number@" },
    .{ .name = "a label nobody has", .arg = "labels.zigps:*" },
    .{ .name = "an unknown field", .arg = "foo:bar" },
    .{ .name = "a syntax error", .arg = "name:(" },
    .{ .name = "a bare word", .arg = "@id@" },
    .{ .name = "lowercase and", .arg = "projectId:@id@ and state:ACTIVE" },
    .{ .name = "one space", .arg = " " },
    .{ .name = "a value past ASCII", .arg = "name:\u{e9}t\u{e9}" },
    .{ .name = "a number star", .arg = "projectNumber:1*" },
    .{ .name = "a token, the same request", .kind = .after_first },
    .{ .name = "a token, another page size", .kind = .after_first, .size = 5 },
    .{ .name = "a token, a query for the first project", .kind = .after_first, .arg = "projectId:@first@" },
    .{ .name = "a token, another query", .kind = .after_first, .arg = "state:ACTIVE" },
    .{ .name = "get by id", .kind = .get, .arg = "@id@" },
    .{ .name = "get by number", .kind = .get, .arg = "@number@" },
    .{ .name = "get a public project", .kind = .get, .arg = public_project },
    .{ .name = "get a project that does not exist", .kind = .get, .arg = missing_project },
    .{ .name = "get a malformed id", .kind = .get, .arg = "a..b" },
    .{ .name = "charged to the test project", .quota = .own },
    .{ .name = "charged to a project it may not use", .quota = .public },
    .{ .name = "charged to a project that does not exist", .quota = .missing },
};

fn expand(a: std.mem.Allocator, text: []const u8, project: rm.Project, first: []const u8) ![]const u8 {
    var out = try std.mem.replaceOwned(u8, a, text, "@first@", first);
    const upper = try std.ascii.allocUpperString(a, project.project_id);
    const number = try std.fmt.allocPrint(a, "{d}", .{project.number});
    inline for (.{ .{ "@id@", project.project_id }, .{ "@ID@", upper }, .{ "@pre@", project.project_id[0..@min(3, project.project_id.len)] }, .{ "@number@", number } }) |r| {
        out = try std.mem.replaceOwned(u8, a, out, r[0], r[1]);
    }
    return out;
}

/// What a script got: project ids in order, or the error, its message cut
/// before any Troubleshooter link (which the fake does not make), and the
/// consumer of a refusal.
fn runScript(a: std.mem.Allocator, f: *Fixture, transport: ?core.transport.Transport, io: std.Io, token: rm.TokenProvider, project: rm.Project, first: []const u8, s: Script) ![]const u8 {
    var diag: rm.Diagnostics = .{};
    var client = try rm.Client.init(testing.allocator, io, .{
        .token_provider = token,
        .transport = transport,
        .diagnostics = &diag,
        .quota_project = switch (s.quota) {
            .none => .none,
            .own => .{ .project = f.project },
            .public => .{ .project = public_project },
            .missing => .{ .project = missing_project },
        },
        .user_agent = "gcp-zig-resource_manager-gcp-integration/0.1",
    });
    defer client.deinit();
    const arg = try expand(a, s.arg, project, first);
    var out: std.ArrayList(u8) = .empty;
    switch (s.kind) {
        .search => {
            var list = client.allProjects(.{ .query = arg, .page_interval_ms = 0 }) catch |err| return failed(a, err, &diag, &client);
            defer list.deinit();
            for (list.value.projects) |p| {
                if (out.items.len > 0) try out.append(a, ' ');
                try out.appendSlice(a, p.project_id);
            }
        },
        .get => {
            var got = client.getProject(arg) catch |err| return failed(a, err, &diag, &client);
            defer got.deinit();
            try out.appendSlice(a, got.value.project_id);
        },
        .after_first => {
            var plain = try client.searchProjects(.{ .page_size = 1 });
            defer plain.deinit();
            var one = plain.page(null) catch |err| return failed(a, err, &diag, &client);
            defer one.deinit();
            const next = one.value.next_page_token orelse return "one page only";
            var other = try client.searchProjects(.{ .query = if (arg.len == 0) null else arg, .page_size = s.size });
            defer other.deinit();
            var two = other.page(next) catch |err| return failed(a, err, &diag, &client);
            defer two.deinit();
            for (two.value.items) |p| {
                if (out.items.len > 0) try out.append(a, ' ');
                try out.appendSlice(a, p.project_id);
            }
            try out.appendSlice(a, if (two.value.next_page_token == null) " (end)" else " (more)");
        },
    }
    return out.items;
}

fn failed(a: std.mem.Allocator, err: anyerror, diag: *const rm.Diagnostics, client: *const rm.Client) ![]const u8 {
    const message = diag.message();
    const cut = std.mem.indexOf(u8, message, " Remediate access") orelse message.len;
    const consumer = if (client.lastConsumerRefusal()) |r| r.consumer else "";
    return std.fmt.allocPrint(a, "error.{t} ({d}): {s} {s}", .{ err, diag.http_status, message[0..cut], consumer });
}

test "resource_manager: the fake against production, script by script" {
    var f: Fixture = undefined;
    if (!try f.init()) return error.SkipZigTest;
    defer f.deinit();
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    // The fake as production answered: every project the principal sees,
    // granted to it, and the public one, as get read them, listed in
    // production's order.
    var mine = try f.client.getProject(f.project);
    defer mine.deinit();
    var clock: core.testing.FakeClock = .{ .now_ns = 1_792_141_200 * std.time.ns_per_s };
    var fake: rm.testing.FakeResourceManager = .init(testing.allocator, clock.io(), .{ .order = .by_number });
    defer fake.deinit();
    try fake.addPrincipal("principal", f.project);
    var visible = try f.client.allProjects(.{ .include_pending_deletion = true });
    defer visible.deinit();
    var refs: std.ArrayList([]const u8) = .empty;
    for (visible.value.projects) |p| try refs.append(a, p.project_id);
    try refs.append(a, public_project);
    for (refs.items, 0..) |ref, i| {
        var got = try f.client.getProject(ref);
        defer got.deinit();
        const p = got.value;
        const public = i == refs.items.len - 1;
        try fake.addProject(.{
            .number = p.number,
            .project_id = p.project_id,
            .display_name = p.display_name,
            .parent = if (p.parent) |x| x.name else null,
            .state = p.state,
            .labels = p.labels,
            .public = public,
        });
        if (!public) try fake.grant("principal", p.project_id);
    }
    // The first project of an unqueried search, in production's order.
    var plain = try f.client.searchProjects(.{ .page_size = 1 });
    defer plain.deinit();
    var head = try plain.page(null);
    defer head.deinit();
    const first = try a.dupe(u8, head.value.items[0].project_id);
    fact("{d} projects visible; production lists {s} first", .{ visible.value.projects.len, first });
    var fake_token: core.StaticToken = .{ .token = "principal" };

    var differences: usize = 0;
    for (scripts) |s| {
        const theirs = try runScript(a, &f, null, testing.io, f.token.provider(), mine.value, first, s);
        const ours = try runScript(a, &f, fake.transport(), clock.io(), fake_token.provider(), mine.value, first, s);
        if (std.mem.eql(u8, theirs, ours)) {
            fact("replay {s}: {s}", .{ s.name, theirs });
        } else {
            differences += 1;
            std.debug.print("replay {s}:\n  production: {s}\n  fake:       {s}\n", .{ s.name, theirs, ours });
        }
    }
    try testing.expectEqual(0, differences);
}
