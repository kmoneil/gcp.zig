//! Reading a search to its end: every page, a pause before each after the
//! first, and a stop at a page limit and at a token the server sends again,
//! which would page for ever. A project walk keeps each project number once,
//! leaves out projects pending deletion unless asked for, and sorts by
//! project id, since search returns projects "in an unspecified order". A
//! parent walk reads folders, then organizations, each once by name.

const std = @import("std");
const Allocator = std.mem.Allocator;

const Client = @import("Client.zig");
const errors = @import("errors.zig");
const search_mod = @import("search.zig");
const types = @import("types.zig");
const validate = @import("validate.zig");
const Error = errors.Error;

const Limits = struct { max_pages: u32, page_interval_ms: u32 };

/// `Client.allProjects`.
pub fn projects(client: *Client, options: types.WalkOptions) Error!types.Owned(types.ProjectList) {
    const limits: Limits = .{ .max_pages = options.max_pages, .page_interval_ms = options.page_interval_ms };
    if (optionsProblem(client, limits)) return error.InvalidOptions;
    var search = try client.searchProjects(.{ .query = options.query, .page_size = options.page_size });
    defer search.deinit();

    var result: types.Owned(types.ProjectList) = try .init(client.gpa);
    errdefer result.deinit();
    const out = result.arena.allocator();
    var scratch: std.heap.ArenaAllocator = .init(client.gpa);
    defer scratch.deinit();
    const s = scratch.allocator();

    var all: std.ArrayList(types.Project) = .empty;
    var pages: u32 = 0;
    const complete = try readAll(types.Project, client, &search, out, s, limits, &pages, &all);

    var list: types.ProjectList = .{ .projects = &.{}, .complete = complete, .pages = pages, .duplicates = 0, .pending_deletion = 0 };
    var seen: std.AutoHashMapUnmanaged(u64, void) = .empty;
    var kept: std.ArrayList(types.Project) = .empty;
    for (all.items) |p| {
        if ((try seen.getOrPut(s, p.number)).found_existing) {
            list.duplicates += 1;
            continue;
        }
        if (p.state == .delete_requested and !options.include_pending_deletion) {
            list.pending_deletion += 1;
            continue;
        }
        try kept.append(out, p);
    }
    std.mem.sort(types.Project, kept.items, {}, byProjectId);
    list.projects = kept.items;
    result.value = list;
    return result;
}

/// `Client.parentNames`.
pub fn parents(client: *Client, options: types.ParentOptions) Error!types.Owned(types.ParentNames) {
    const limits: Limits = .{ .max_pages = options.max_pages, .page_interval_ms = options.page_interval_ms };
    if (optionsProblem(client, limits)) return error.InvalidOptions;
    var result: types.Owned(types.ParentNames) = try .init(client.gpa);
    errdefer result.deinit();
    const out = result.arena.allocator();
    var scratch: std.heap.ArenaAllocator = .init(client.gpa);
    defer scratch.deinit();

    var pages: u32 = 0;
    var folders: std.ArrayList(types.Folder) = .empty;
    var folder_search = try client.searchFolders(.{ .page_size = options.page_size });
    defer folder_search.deinit();
    const folders_complete = try readAll(types.Folder, client, &folder_search, out, scratch.allocator(), limits, &pages, &folders);
    var organizations: std.ArrayList(types.Organization) = .empty;
    var org_search = try client.searchOrganizations(.{ .page_size = options.page_size });
    defer org_search.deinit();
    const orgs_complete = try readAll(types.Organization, client, &org_search, out, scratch.allocator(), limits, &pages, &organizations);

    result.value = .{
        .folders = onceByName(types.Folder, folders.items),
        .organizations = onceByName(types.Organization, organizations.items),
        .complete = folders_complete and orgs_complete,
        .pages = pages,
    };
    return result;
}

/// Reads every page of `search` into `items`, decoded into `out`, pausing
/// before each page but the very first `pages` counts. False when the page
/// limit stopped it with pages left.
fn readAll(comptime T: type, client: *Client, search: *search_mod.Search(T), out: Allocator, scratch: Allocator, limits: Limits, pages: *u32, items: *std.ArrayList(T)) Error!bool {
    var sent: std.StringHashMapUnmanaged(void) = .empty;
    var token: ?[]const u8 = null;
    var read: u32 = 0;
    while (true) {
        if (pages.* > 0 and limits.page_interval_ms > 0) {
            try client.io.sleep(.fromMilliseconds(limits.page_interval_ms), .awake);
        }
        const page = try search.pageInto(out, token);
        pages.* += 1;
        read += 1;
        try items.appendSlice(out, page.items);
        const next = page.next_page_token orelse return true;
        if ((try sent.getOrPut(scratch, next)).found_existing) {
            if (client.diagnostics) |d| d.print("the server sent a page token again after {d} pages; the walk would never end", .{read});
            return error.InvalidResponse;
        }
        if (read >= limits.max_pages) return false;
        token = next;
    }
}

/// `items` sorted by name, each name once: the first sent is kept.
fn onceByName(comptime T: type, items: []T) []const T {
    std.mem.sort(T, items, {}, struct {
        fn less(_: void, a: T, b: T) bool {
            return std.mem.order(u8, a.name, b.name) == .lt;
        }
    }.less);
    var n: usize = 0;
    for (items) |item| {
        if (n > 0 and std.mem.eql(u8, items[n - 1].name, item.name)) continue;
        items[n] = item;
        n += 1;
    }
    return items[0..n];
}

fn byProjectId(_: void, a: types.Project, b: types.Project) bool {
    return std.mem.order(u8, a.project_id, b.project_id) == .lt;
}

/// Says what is wrong in `Diagnostics`, and whether anything is.
fn optionsProblem(client: *Client, limits: Limits) bool {
    const diag = client.diagnostics;
    if (diag) |d| d.clear();
    if (limits.max_pages == 0 or limits.max_pages > validate.max_walk_pages) {
        if (diag) |d| d.print("invalid max_pages: 1 to {d}, not {d}", .{ validate.max_walk_pages, limits.max_pages });
        return true;
    }
    if (limits.page_interval_ms > validate.max_page_interval_ms) {
        if (diag) |d| d.print("invalid page_interval_ms: at most {d}, not {d}", .{ validate.max_page_interval_ms, limits.page_interval_ms });
        return true;
    }
    return false;
}

const testing = std.testing;
const test_util = @import("test_util.zig");
const bodies = @import("production_bodies.zig");

fn reply(body: []const u8) test_util.FakeTransport.Reply {
    return .{ .respond = .{ .body = body } };
}

test "walk: every page, empty ones too, each project once, pending deletion left out, sorted" {
    var h: test_util.Harness = undefined;
    try h.init(&.{
        reply(
            \\{"projects":[{"name":"projects/3","projectId":"c","state":"ACTIVE"},{"name":"projects/1","projectId":"a","state":"ACTIVE"}],"nextPageToken":"t1"}
        ),
        reply("{\"nextPageToken\":\"t2\"}"),
        reply(
            \\{"projects":[{"name":"projects/1","projectId":"a","state":"ACTIVE"},{"name":"projects/4","projectId":"d","state":"DELETE_REQUESTED"},{"name":"projects/2","projectId":"b"}],"nextPageToken":"t3"}
        ),
        reply(
            \\{"projects":[{"name":"projects/5","projectId":"e","state":"PURGING"}]}
        ),
    }, .{});
    defer h.deinit();
    var list = try h.client.allProjects(.{});
    defer list.deinit();
    const v = list.value;
    try testing.expect(v.complete);
    try testing.expectEqual(4, v.pages);
    try testing.expectEqual(1, v.duplicates);
    try testing.expectEqual(1, v.pending_deletion);
    try testing.expectEqual(4, v.projects.len);
    for ([_][]const u8{ "a", "b", "c", "e" }, v.projects) |id, p| try testing.expectEqualStrings(id, p.project_id);
    // An unknown state is kept, and no state at all.
    try testing.expectEqual(.unknown, v.projects[3].state);
    try testing.expectEqual(.unspecified, v.projects[1].state);

    const base = "https://cloudresourcemanager.googleapis.com/v3/projects:search?pageSize=500&prettyPrint=false";
    try h.expectRequest(0, .GET, base, null);
    try h.expectRequest(1, .GET, base ++ "&pageToken=t1", null);
    try h.expectRequest(2, .GET, base ++ "&pageToken=t2", null);
    try h.expectRequest(3, .GET, base ++ "&pageToken=t3", null);
    // A pause before each page after the first.
    try testing.expectEqual(3, h.clock.sleep_count);
    for (0..3) |i| try testing.expectEqual(250, h.clock.sleepMs(i));
}

test "walk: pending deletion kept when asked; the query and page size go with every page" {
    var h: test_util.Harness = undefined;
    try h.init(&.{
        reply("{\"projects\":[{\"name\":\"projects/4\",\"projectId\":\"d\",\"state\":\"DELETE_REQUESTED\"}],\"nextPageToken\":\"t\"}"),
        reply("{\"projects\":[{\"name\":\"projects/4\",\"projectId\":\"d\",\"state\":\"DELETE_REQUESTED\"}]}"),
    }, .{});
    defer h.deinit();
    var list = try h.client.allProjects(.{ .query = "labels.team:pay", .page_size = 1, .page_interval_ms = 0, .include_pending_deletion = true });
    defer list.deinit();
    try testing.expectEqual(1, list.value.projects.len);
    try testing.expectEqual(.delete_requested, list.value.projects[0].state);
    // The second copy counts as sent again, not as pending deletion.
    try testing.expectEqual(1, list.value.duplicates);
    try testing.expectEqual(0, list.value.pending_deletion);
    try h.expectRequest(1, .GET, "https://cloudresourcemanager.googleapis.com/v3/projects:search?query=labels.team%3Apay&pageSize=1&prettyPrint=false&pageToken=t", null);
    try testing.expectEqual(0, h.clock.sleep_count);
}

test "walk: the page limit stops it, incomplete; a token sent again fails it" {
    var h: test_util.Harness = undefined;
    try h.init(&.{
        reply("{\"projects\":[{\"name\":\"projects/1\",\"projectId\":\"a\"}],\"nextPageToken\":\"t1\"}"),
        reply("{\"projects\":[{\"name\":\"projects/2\",\"projectId\":\"b\"}],\"nextPageToken\":\"t2\"}"),
        reply("{\"nextPageToken\":\"a\"}"),
        reply("{\"nextPageToken\":\"b\"}"),
        reply("{\"nextPageToken\":\"a\"}"),
    }, .{});
    defer h.deinit();
    var list = try h.client.allProjects(.{ .max_pages = 2 });
    defer list.deinit();
    try testing.expect(!list.value.complete);
    try testing.expectEqual(2, list.value.pages);
    try testing.expectEqual(2, list.value.projects.len);
    try h.expectRequestCount(2);

    try testing.expectError(error.InvalidResponse, h.client.allProjects(.{}));
    try testing.expect(std.mem.indexOf(u8, h.diag.message(), "page token again after 3 pages") != null);
    try h.expectRequestCount(5);
}

test "walk: a failure on any page fails it, and leaks nothing" {
    var h: test_util.Harness = undefined;
    try h.init(&.{
        reply("{\"projects\":[{\"name\":\"projects/1\",\"projectId\":\"a\"}],\"nextPageToken\":\"t1\"}"),
        .{ .respond = .{ .status = bodies.query_syntax_status, .body = bodies.query_syntax } },
        reply("{\"projects\":[{\"name\":\"projects/1\",\"projectId\":\"a\"}],\"nextPageToken\":\"t1\"}"),
        reply("{\"projects\":[{\"name\":\"projects/x\",\"projectId\":\"a\"}]}"),
    }, .{ .retry = .{ .max_attempts = 1 } });
    defer h.deinit();
    try testing.expectError(error.InvalidQuery, h.client.allProjects(.{}));
    try testing.expectError(error.InvalidResponse, h.client.allProjects(.{}));
}

test "walk: options out of range are refused, unsent" {
    var h: test_util.Harness = undefined;
    try h.init(&.{reply("{}")}, .{});
    defer h.deinit();
    try testing.expectError(error.InvalidOptions, h.client.allProjects(.{ .max_pages = 0 }));
    try testing.expect(std.mem.indexOf(u8, h.diag.message(), "max_pages") != null);
    try testing.expectError(error.InvalidOptions, h.client.allProjects(.{ .max_pages = validate.max_walk_pages + 1 }));
    try testing.expectError(error.InvalidOptions, h.client.allProjects(.{ .page_interval_ms = validate.max_page_interval_ms + 1 }));
    try testing.expect(std.mem.indexOf(u8, h.diag.message(), "page_interval_ms") != null);
    try testing.expectError(error.InvalidQuery, h.client.allProjects(.{ .query = "\x00" }));
    try h.expectRequestCount(0);
    var fits = try h.client.allProjects(.{ .max_pages = validate.max_walk_pages, .page_interval_ms = validate.max_page_interval_ms });
    fits.deinit();
}

test "walk: every allocation failure is OutOfMemory without leaks" {
    const Run = struct {
        fn run(gpa: Allocator) !void {
            var fake: test_util.FakeTransport = .init(testing.allocator, &.{
                reply("{\"projects\":[{\"name\":\"projects/2\",\"projectId\":\"b\"},{\"name\":\"projects/1\",\"projectId\":\"a\"}],\"nextPageToken\":\"t\"}"),
                reply("{\"projects\":[{\"name\":\"projects/2\",\"projectId\":\"b\"},{\"name\":\"projects/3\",\"projectId\":\"c\",\"state\":\"DELETE_REQUESTED\"}]}"),
            });
            defer fake.deinit();
            var clock: test_util.FakeClock = .{};
            var token: test_util.FakeTokenProvider = .{};
            var client = try Client.init(gpa, clock.io(), .{ .token_provider = token.provider(), .transport = fake.transport() });
            defer client.deinit();
            var list = try client.allProjects(.{});
            list.deinit();
        }
    };
    try testing.checkAllAllocationFailures(test_util.no_grow_allocator, Run.run, .{});
}

test "parents: every page of folders, then organizations, each once by name, one pause between each page" {
    var h: test_util.Harness = undefined;
    try h.init(&.{
        reply(
            \\{"folders":[{"name":"folders/9","parent":"organizations/1","displayName":"Nine"},{"name":"folders/10","parent":"folders/9","displayName":"Ten"}],"nextPageToken":"f1"}
        ),
        reply(
            \\{"folders":[{"name":"folders/10","parent":"folders/9","displayName":"Ten again"},{"name":"folders/11","parent":"folders/10"}]}
        ),
        reply(
            \\{"organizations":[{"name":"organizations/1","displayName":"example.com","directoryCustomerId":"C0"}]}
        ),
    }, .{});
    defer h.deinit();
    var names = try h.client.parentNames(.{});
    defer names.deinit();
    const v = &names.value;
    try testing.expect(v.complete);
    try testing.expectEqual(3, v.pages);
    try testing.expectEqual(3, v.folders.len);
    // By name, in byte order; the first copy kept.
    try testing.expectEqualStrings("folders/10", v.folders[0].name);
    try testing.expectEqualStrings("Ten", v.folders[0].display_name.?);
    try testing.expectEqualStrings("folders/11", v.folders[1].name);
    try testing.expectEqualStrings("folders/9", v.folders[2].name);
    try testing.expectEqual(1, v.organizations.len);
    try h.expectRequest(0, .GET, "https://cloudresourcemanager.googleapis.com/v3/folders:search?pageSize=500&prettyPrint=false", null);
    try h.expectRequest(1, .GET, "https://cloudresourcemanager.googleapis.com/v3/folders:search?pageSize=500&prettyPrint=false&pageToken=f1", null);
    try h.expectRequest(2, .GET, "https://cloudresourcemanager.googleapis.com/v3/organizations:search?pageSize=500&prettyPrint=false", null);
    try testing.expectEqual(2, h.clock.sleep_count);

    const a = testing.allocator;
    try testing.expectEqualStrings("Ten", v.label(parentOf("folders/10")));
    // A folder with no display name, and one the caller cannot read, by name.
    try testing.expectEqualStrings("folders/11", v.label(parentOf("folders/11")));
    try testing.expectEqualStrings("folders/12", v.label(parentOf("folders/12")));
    try testing.expectEqualStrings("example.com", v.label(parentOf("organizations/1")));
    try testing.expectEqualStrings("organizations/2", v.label(parentOf("organizations/2")));
    try testing.expectEqualStrings("regions/x", v.label(parentOf("regions/x")));

    const path = try v.path(a, parentOf("folders/11"));
    defer a.free(path);
    try testing.expectEqual(4, path.len);
    for ([_][]const u8{ "folders/11", "Ten", "Nine", "example.com" }, path) |want, got| try testing.expectEqualStrings(want, got);
    const unreadable = try v.path(a, parentOf("folders/12"));
    defer a.free(unreadable);
    try testing.expectEqual(1, unreadable.len);
    try testing.expect(v.folder("folders/99") == null);
    try testing.expect(v.organization("organizations/1") != null);
}

/// A parent as the codec reads one; the names here are literals.
fn parentOf(name: []const u8) types.Parent {
    inline for (.{ .{ "folders/", types.Parent.Kind.folder }, .{ "organizations/", types.Parent.Kind.organization } }) |k| {
        if (std.mem.startsWith(u8, name, k[0])) return .{ .kind = k[1], .id = name[k[0].len..], .name = name };
    }
    return .{ .kind = .other, .id = name, .name = name };
}

test "parents: a path that loops ends at its limit" {
    var h: test_util.Harness = undefined;
    try h.init(&.{
        reply("{\"folders\":[{\"name\":\"folders/1\",\"parent\":\"folders/2\"},{\"name\":\"folders/2\",\"parent\":\"folders/1\"}]}"),
        reply("{}"),
    }, .{});
    defer h.deinit();
    var names = try h.client.parentNames(.{ .page_interval_ms = 0 });
    defer names.deinit();
    const path = try names.value.path(testing.allocator, parentOf("folders/1"));
    defer testing.allocator.free(path);
    try testing.expectEqual(types.ParentNames.max_path, path.len);
    try testing.expectEqual(0, h.clock.sleep_count);
}

test "parents: the page limit holds for each search, and either stopped is incomplete; a failure fails it" {
    var h: test_util.Harness = undefined;
    try h.init(&.{
        // The folders end within two pages; the organizations do not.
        reply("{\"folders\":[{\"name\":\"folders/1\",\"parent\":\"organizations/1\"}],\"nextPageToken\":\"f\"}"),
        reply("{\"folders\":[{\"name\":\"folders/2\",\"parent\":\"organizations/1\"}]}"),
        reply("{\"organizations\":[{\"name\":\"organizations/1\"}],\"nextPageToken\":\"o1\"}"),
        reply("{\"organizations\":[{\"name\":\"organizations/2\"}],\"nextPageToken\":\"o2\"}"),
        .{ .respond = .{ .status = bodies.folders_unknown_field_status, .body = bodies.folders_unknown_field } },
    }, .{});
    defer h.deinit();
    var names = try h.client.parentNames(.{ .max_pages = 2 });
    defer names.deinit();
    try testing.expect(!names.value.complete);
    try testing.expectEqual(4, names.value.pages);
    try testing.expectEqual(2, names.value.folders.len);
    try testing.expectEqual(2, names.value.organizations.len);
    try testing.expectError(error.InvalidQuery, h.client.parentNames(.{}));
    try testing.expectError(error.InvalidOptions, h.client.parentNames(.{ .max_pages = 0 }));
    try testing.expectError(error.InvalidOptions, h.client.parentNames(.{ .page_interval_ms = validate.max_page_interval_ms + 1 }));
    try h.expectRequestCount(5);
}

test "parents: every allocation failure is OutOfMemory without leaks" {
    const Run = struct {
        fn run(gpa: Allocator) !void {
            var fake: test_util.FakeTransport = .init(testing.allocator, &.{
                reply("{\"folders\":[{\"name\":\"folders/2\",\"parent\":\"folders/1\",\"displayName\":\"B\"},{\"name\":\"folders/1\",\"parent\":\"organizations/1\"}]}"),
                reply("{\"organizations\":[{\"name\":\"organizations/1\",\"displayName\":\"example.com\"}]}"),
            });
            defer fake.deinit();
            var clock: test_util.FakeClock = .{};
            var token: test_util.FakeTokenProvider = .{};
            var client = try Client.init(gpa, clock.io(), .{ .token_provider = token.provider(), .transport = fake.transport() });
            defer client.deinit();
            var names = try client.parentNames(.{});
            defer names.deinit();
            const path = try names.value.path(gpa, .{ .kind = .folder, .id = "2", .name = "folders/2" });
            gpa.free(path);
        }
    };
    try testing.checkAllAllocationFailures(test_util.no_grow_allocator, Run.run, .{});
}
