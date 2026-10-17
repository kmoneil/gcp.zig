//! One search request, fixed when `Client.searchProjects` made it. AIP-158
//! says a page token works only with the arguments that produced it, so a
//! `Search` sends the same path for every page, the token after it.
//! Tokens "have a limited lifetime" (no number is given), so a refresh
//! starts a new search rather than keeping an old token.

const std = @import("std");
const Allocator = std.mem.Allocator;
const core = @import("core");

const Client = @import("Client.zig");
const codec = @import("codec.zig");
const errors = @import("errors.zig");
const rpc = @import("rpc.zig");
const types = @import("types.zig");
const Error = errors.Error;

/// A search of `T`s: `types.Project`.
pub fn Search(comptime T: type) type {
    return struct {
        client: *Client,
        /// Holds `path`.
        arena: std.heap.ArenaAllocator,
        /// The request's path and query, but for the token: the same bytes
        /// for every page.
        path: []const u8,

        const Self = @This();

        /// What a decoding failure calls the response.
        const what = if (T == types.Project) "project search" else @compileError("no search of " ++ @typeName(T));

        pub fn deinit(self: *Self) void {
            self.arena.deinit();
            self.* = undefined;
        }

        /// One page. `items` may be empty while `next_page_token` is set;
        /// only a null token ends the search. Pass null for the first page.
        pub fn page(self: *Self, page_token: ?[]const u8) Error!types.Owned(types.Page(T)) {
            rpc.begin(self.client);
            var result: types.Owned(types.Page(T)) = try .init(self.client.gpa);
            errdefer result.deinit();
            result.value = try self.pageInto(result.arena.allocator(), page_token);
            return result;
        }

        /// `page`, decoded into `out`, as a walk keeps what it finds. The
        /// response itself is gone when this returns.
        pub fn pageInto(self: *Self, out: Allocator, page_token: ?[]const u8) Error!types.Page(T) {
            const client = self.client;
            if (page_token) |t| if (!isToken(t)) {
                if (client.diagnostics) |d| d.print("invalid page token: expected the next_page_token of an earlier page", .{});
                return error.InvalidPageToken;
            };
            var response: std.heap.ArenaAllocator = .init(client.gpa);
            defer response.deinit();
            const path = if (page_token) |t| p: {
                var w: std.Io.Writer.Allocating = .init(response.allocator());
                w.writer.writeAll(self.path) catch return error.OutOfMemory;
                w.writer.writeAll("&pageToken=") catch return error.OutOfMemory;
                core.query.writeValue(&w.writer, t) catch return error.OutOfMemory;
                break :p w.written();
            } else self.path;
            const body = try rpc.get(client, &response, path, page_token != null);
            var scratch: std.heap.ArenaAllocator = .init(client.gpa);
            defer scratch.deinit();
            return codec.decodeProjectPage(out, scratch.allocator(), body) catch |err| rpc.decodeFailed(client, err, what);
        }
    };
}

/// A token as a page sends it: printable ASCII, as production's are.
fn isToken(token: []const u8) bool {
    if (token.len == 0) return false;
    for (token) |c| if (c <= ' ' or c >= 0x7f) return false;
    return true;
}

const testing = std.testing;
const test_util = @import("test_util.zig");
const bodies = @import("production_bodies.zig");

const two_projects =
    \\{"projects":[{"name":"projects/2","projectId":"b","state":"ACTIVE"},{"name":"projects/1","projectId":"a","state":"ACTIVE"}],"nextPageToken":"EAE+/="}
;

test "golden: a search's first page and the next send the same request" {
    var h: test_util.Harness = undefined;
    try h.init(&.{
        .{ .respond = .{ .body = two_projects } },
        // An empty page with a token, handed back as it came.
        .{ .respond = .{ .body = "{\"nextPageToken\":\"EAE5\"}" } },
        .{ .respond = .{ .body = "{}" } },
    }, .{});
    defer h.deinit();

    var s = try h.client.searchProjects(.{ .query = "state:ACTIVE parent:folders/1 name:\"a b\"*" });
    defer s.deinit();
    var first = try s.page(null);
    defer first.deinit();
    const path = "https://cloudresourcemanager.googleapis.com/v3/projects:search?query=state%3AACTIVE%20parent%3Afolders%2F1%20name%3A%22a%20b%22%2A&pageSize=500&prettyPrint=false";
    try h.expectRequest(0, .GET, path, null);
    try testing.expectEqual(2, first.value.items.len);
    // The server's order, kept.
    try testing.expectEqualStrings("b", first.value.items[0].project_id);

    var second = try s.page(first.value.next_page_token);
    defer second.deinit();
    try h.expectRequest(1, .GET, path ++ "&pageToken=EAE%2B%2F%3D", null);
    try testing.expectEqual(0, second.value.items.len);
    var third = try s.page(second.value.next_page_token);
    defer third.deinit();
    try h.expectRequest(2, .GET, path ++ "&pageToken=EAE5", null);
    try testing.expectEqual(null, third.value.next_page_token);

    // The read-only scope, and no quota project by default.
    try testing.expectEqualStrings("https://www.googleapis.com/auth/cloud-platform.read-only", h.token.firstScope());
    try testing.expectEqual(null, (try h.fake.request(0)).header("x-goog-user-project"));
}

test "golden: no query, and the server's page size, send neither" {
    var h: test_util.Harness = undefined;
    try h.init(&.{ .{ .respond = .{ .body = "{}" } }, .{ .respond = .{ .body = "{}" } } }, .{});
    defer h.deinit();
    var s = try h.client.searchProjects(.{ .page_size = 0 });
    defer s.deinit();
    var p = try s.page(null);
    p.deinit();
    try h.expectRequest(0, .GET, "https://cloudresourcemanager.googleapis.com/v3/projects:search?prettyPrint=false", null);
    var blank = try h.client.searchProjects(.{ .query = "", .page_size = std.math.maxInt(u31) });
    defer blank.deinit();
    var q = try blank.page(null);
    q.deinit();
    try h.expectRequest(1, .GET, "https://cloudresourcemanager.googleapis.com/v3/projects:search?pageSize=2147483647&prettyPrint=false", null);
}

test "page: an empty or unprintable token is refused before sending" {
    var h: test_util.Harness = undefined;
    try h.init(&.{}, .{});
    defer h.deinit();
    var s = try h.client.searchProjects(.{});
    defer s.deinit();
    for ([_][]const u8{ "", "a b", "a\nb", "\xff", "a\x7f" }) |t| {
        try testing.expectError(error.InvalidPageToken, s.page(t));
        try testing.expect(std.mem.indexOf(u8, h.diag.message(), "invalid page token") != null);
    }
    try h.expectRequestCount(0);
}

test "page: production's refusals of a query and a token have errors of their own" {
    var h: test_util.Harness = undefined;
    try h.init(&.{
        .{ .respond = .{ .status = bodies.query_syntax_status, .body = bodies.query_syntax } },
        .{ .respond = .{ .status = bodies.query_unknown_field_status, .body = bodies.query_unknown_field } },
        .{ .respond = .{ .status = bodies.query_global_restriction_status, .body = bodies.query_global_restriction } },
        .{ .respond = .{ .status = bodies.query_space_status, .body = bodies.query_space } },
        .{ .respond = .{ .status = bodies.query_parent_wildcard_status, .body = bodies.query_parent_wildcard } },
        .{ .respond = .{ .status = bodies.token_garbage_status, .body = bodies.token_garbage } },
        // The same words with no token sent are some other argument.
        .{ .respond = .{ .status = bodies.token_garbage_status, .body = bodies.token_garbage } },
        .{ .respond = .{ .status = bodies.query_parent_missing_status, .body = bodies.query_parent_missing } },
        .{ .respond = .{ .status = bodies.page_size_negative_status, .body = bodies.page_size_negative } },
    }, .{});
    defer h.deinit();
    var s = try h.client.searchProjects(.{ .query = "x" });
    defer s.deinit();
    try testing.expectError(error.InvalidQuery, s.page(null));
    try testing.expectEqualStrings("field [query] has issue [invalid syntax]", h.diag.message());
    try testing.expectError(error.InvalidQuery, s.page(null));
    try testing.expectError(error.InvalidQuery, s.page(null));
    try testing.expectError(error.InvalidQuery, s.page(null));
    try testing.expectError(error.InvalidQuery, s.page(null));
    try testing.expect(std.mem.indexOf(u8, h.diag.message(), "Parent id must be a number.") != null);
    try testing.expectError(error.InvalidPageToken, s.page("garbage"));
    try testing.expectError(error.InvalidArgument, s.page(null));
    try testing.expectError(error.PermissionDenied, s.page(null));
    try testing.expectEqualStrings("The caller does not have permission", h.diag.message());
    // A refusal of the page size, which this client cannot send, stays an
    // argument.
    try testing.expectError(error.InvalidArgument, s.page(null));
    try h.expectRequestCount(9);
}

test "page: 5xx and dropped connections are retried; a 429 never is" {
    var h: test_util.Harness = undefined;
    try h.init(&.{
        .{ .respond = .{ .status = 503, .body = "{\"error\":{\"code\":503,\"status\":\"UNAVAILABLE\"}}" } },
        .{ .fail = error.ConnectionResetByPeer },
        .{ .respond = .{ .status = 500, .body = "{\"error\":{\"code\":500,\"status\":\"INTERNAL\"}}" } },
        .{ .respond = .{ .status = 504, .body = "{\"error\":{\"code\":504,\"status\":\"DEADLINE_EXCEEDED\"}}" } },
        .{ .respond = .{ .body = two_projects } },
        .{ .respond = .{ .status = 429, .body =
        \\{"error":{"code":429,"message":"Quota exceeded for quota metric 'Read requests' and limit 'Read requests per minute' of service 'cloudresourcemanager.googleapis.com' for consumer 'project_number:764086051850'.","status":"RESOURCE_EXHAUSTED"}}
        } },
    }, .{});
    defer h.deinit();
    var s = try h.client.searchProjects(.{});
    defer s.deinit();
    var p = try s.page(null);
    defer p.deinit();
    try testing.expectEqual(2, p.value.items.len);
    try h.expectRequestCount(5);
    try testing.expectEqual(4, h.clock.sleep_count);
    try testing.expectError(error.ResourceExhausted, s.page(null));
    try h.expectRequestCount(6);
    try testing.expect(std.mem.indexOf(u8, h.diag.message(), "Read requests per minute") != null);
}

test "page: a response over the limit says what to change; a body that is no page is InvalidResponse" {
    var h: test_util.Harness = undefined;
    try h.init(&.{
        .{ .fail = error.ResponseTooLarge },
        .{ .respond = .{ .body = "{\"projects\":[{\"name\":\"projects/x\",\"projectId\":\"a\"}]}" } },
    }, .{});
    defer h.deinit();
    var s = try h.client.searchProjects(.{});
    defer s.deinit();
    try testing.expectError(error.ResponseTooLarge, s.page(null));
    try testing.expect(std.mem.indexOf(u8, h.diag.message(), "smaller page_size") != null);
    try testing.expectError(error.InvalidResponse, s.page(null));
    try testing.expect(std.mem.indexOf(u8, h.diag.message(), "project search") != null);
    try h.expectRequestCount(2);
}

test "page: every allocation failure is OutOfMemory without leaks" {
    const Run = struct {
        fn run(gpa: Allocator) !void {
            var fake: test_util.FakeTransport = .init(testing.allocator, &.{.{ .respond = .{ .body = two_projects } }});
            defer fake.deinit();
            var clock: test_util.FakeClock = .{};
            var token: test_util.FakeTokenProvider = .{};
            var client = try Client.init(gpa, clock.io(), .{ .token_provider = token.provider(), .transport = fake.transport() });
            defer client.deinit();
            var s = try client.searchProjects(.{ .query = "state:ACTIVE" });
            defer s.deinit();
            var p = try s.page("EAE");
            p.deinit();
        }
    };
    try testing.checkAllAllocationFailures(test_util.no_grow_allocator, Run.run, .{});
}
