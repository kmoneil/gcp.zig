//! Reading a search to its end: every page, a pause before each after the
//! first, each project number kept once, projects pending deletion left
//! out unless asked for, and the result sorted by project id, since search
//! returns projects "in an unspecified order". The walk stops at a page
//! limit, and at a token the server sends again, which would page for ever.

const std = @import("std");
const Allocator = std.mem.Allocator;

const Client = @import("Client.zig");
const errors = @import("errors.zig");
const types = @import("types.zig");
const validate = @import("validate.zig");
const Error = errors.Error;

/// `Client.allProjects`.
pub fn projects(client: *Client, options: types.WalkOptions) Error!types.Owned(types.ProjectList) {
    if (try optionsProblem(client, options)) return error.InvalidOptions;
    var search = try client.searchProjects(.{ .query = options.query, .page_size = options.page_size });
    defer search.deinit();

    var result: types.Owned(types.ProjectList) = try .init(client.gpa);
    errdefer result.deinit();
    const out = result.arena.allocator();
    // The walk's own bookkeeping: numbers seen, tokens sent.
    var scratch: std.heap.ArenaAllocator = .init(client.gpa);
    defer scratch.deinit();
    const s = scratch.allocator();
    var seen: std.AutoHashMapUnmanaged(u64, void) = .empty;
    var sent: std.StringHashMapUnmanaged(void) = .empty;
    var kept: std.ArrayList(types.Project) = .empty;

    var list: types.ProjectList = .{ .projects = &.{}, .complete = false, .pages = 0, .duplicates = 0, .pending_deletion = 0 };
    var token: ?[]const u8 = null;
    while (true) {
        if (list.pages > 0 and options.page_interval_ms > 0) {
            try client.io.sleep(.fromMilliseconds(options.page_interval_ms), .awake);
        }
        const page = try search.pageInto(out, token);
        list.pages += 1;
        for (page.items) |p| {
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
        const next = page.next_page_token orelse {
            list.complete = true;
            break;
        };
        if ((try sent.getOrPut(s, next)).found_existing) {
            if (client.diagnostics) |d| d.print("the server sent a page token again after {d} pages; the walk would never end", .{list.pages});
            return error.InvalidResponse;
        }
        if (list.pages >= options.max_pages) break;
        token = next;
    }
    std.mem.sort(types.Project, kept.items, {}, byProjectId);
    list.projects = kept.items;
    result.value = list;
    return result;
}

fn byProjectId(_: void, a: types.Project, b: types.Project) bool {
    return std.mem.order(u8, a.project_id, b.project_id) == .lt;
}

/// Says what is wrong in `Diagnostics`, and whether anything is.
fn optionsProblem(client: *Client, options: types.WalkOptions) Allocator.Error!bool {
    const diag = client.diagnostics;
    if (diag) |d| d.clear();
    if (options.max_pages == 0 or options.max_pages > validate.max_walk_pages) {
        if (diag) |d| d.print("invalid max_pages: 1 to {d}, not {d}", .{ validate.max_walk_pages, options.max_pages });
        return true;
    }
    if (options.page_interval_ms > validate.max_page_interval_ms) {
        if (diag) |d| d.print("invalid page_interval_ms: at most {d}, not {d}", .{ validate.max_page_interval_ms, options.page_interval_ms });
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
