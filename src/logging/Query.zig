//! One `entries.list` request, fixed when `Client.query` made it. A page
//! token works only with the request that produced it: change anything, a
//! "now" recomputed per page included, and the server answers
//! "page_token doesn't match arguments from the request", the bug every
//! major Google client has had. A `Query` sends the same request for every
//! page, so a table can keep `(query, token)` for each block of rows and
//! fetch any block again within the token's 24 hours.

const Query = @This();

const std = @import("std");
const Allocator = std.mem.Allocator;
const core = @import("core");

const Client = @import("Client.zig");
const codec = @import("codec.zig");
const errors = @import("errors.zig");
const rpc = @import("rpc.zig");
const types = @import("types.zig");
const Error = errors.Error;

client: *Client,
/// Holds the request's parts.
arena: std.heap.ArenaAllocator,
request: codec.ListRequest,
/// `X-Server-Timeout`, when `QueryOptions.server_timeout_s` asks for one.
headers: []const core.transport.Header = &.{},

pub fn deinit(self: *Query) void {
    self.arena.deinit();
    self.* = undefined;
}

/// One page. `entries` may be empty while `next_page_token` is set: the
/// server ran out of time, not of entries, and the next page goes on. Only
/// a null token ends the listing. Pass null for the first page.
pub fn page(self: *Query, page_token: ?[]const u8) Error!types.Owned(types.EntryPage) {
    const client = self.client;
    rpc.begin(client);
    if (page_token) |token| if (token.len == 0 or !std.unicode.utf8ValidateSlice(token)) {
        if (client.diagnostics) |d| d.print("invalid page token: expected the next_page_token of an earlier page", .{});
        return error.InvalidPageToken;
    };
    var scratch: std.heap.ArenaAllocator = .init(client.gpa);
    defer scratch.deinit();
    const body = try codec.encodeListRequest(scratch.allocator(), self.request, page_token);

    var result: types.Owned(types.EntryPage) = try .init(client.gpa);
    errdefer result.deinit();
    const response = try rpc.listEntries(client, result.arena, body, self.headers);
    result.value = codec.decodeEntryPage(result.arena.allocator(), response) catch |err|
        return rpc.decodeFailed(client, err, "entry list");
    return result;
}

/// The filter as sent: the caller's own, in parentheses, and the clauses
/// joined to it. The line and column of a server's "Unparseable filter"
/// count in this text.
pub fn filter(self: *const Query) []const u8 {
    return self.request.filter;
}

const testing = std.testing;
const test_util = @import("test_util.zig");

const t0: std.Io.Timestamp = .{ .nanoseconds = 1_792_141_200 * std.time.ns_per_s };

const one_entry =
    \\{"entries":[{"logName":"projects/extractctl/logs/zigps","timestamp":"2026-10-16T09:00:00Z","insertId":"a","textPayload":"hello"}],"nextPageToken":"EAE4"}
;

test "golden: a query's first page and the next send the same request" {
    var h: test_util.Harness = undefined;
    try h.init(&.{
        .{ .respond = .{ .body = one_entry } },
        // An empty page with a token: the server ran out of time.
        .{ .respond = .{ .body = "{\"nextPageToken\":\"EAE5\"}" } },
        .{ .respond = .{ .body = "{}" } },
    }, .{});
    defer h.deinit();

    var q = try h.client.query(.{
        .filter = "resource.type = \"cloud_run_revision\"",
        .min_severity = .warning,
        .since = t0,
        .until = .{ .nanoseconds = t0.nanoseconds + 3600 * std.time.ns_per_s },
    });
    defer q.deinit();
    try testing.expectEqualStrings(
        \\(
        \\resource.type = "cloud_run_revision"
        \\)
        \\AND timestamp >= "2026-10-16T09:00:00Z"
        \\AND timestamp < "2026-10-16T10:00:00Z"
        \\AND severity >= WARNING
    , q.filter());

    var first = try q.page(null);
    defer first.deinit();
    const request =
        \\{"resourceNames":["projects/extractctl"],"filter":"(\nresource.type = \"cloud_run_revision\"\n)\nAND timestamp >= \"2026-10-16T09:00:00Z\"\nAND timestamp < \"2026-10-16T10:00:00Z\"\nAND severity >= WARNING","orderBy":"timestamp desc","pageSize":100
    ;
    try h.expectRequest(0, .POST, "https://logging.googleapis.com/v2/entries:list?prettyPrint=false", request ++ "}");
    try testing.expectEqual(1, first.value.entries.len);
    try testing.expectEqualStrings("hello", first.value.entries[0].payload.text);

    var second = try q.page(first.value.next_page_token);
    defer second.deinit();
    // The same bytes, and the token after them.
    try h.expectRequest(1, .POST, "https://logging.googleapis.com/v2/entries:list?prettyPrint=false", request ++ ",\"pageToken\":\"EAE4\"}");
    try testing.expectEqual(0, second.value.entries.len);
    try testing.expectEqualStrings("EAE5", second.value.next_page_token.?);

    var third = try q.page(second.value.next_page_token);
    defer third.deinit();
    try testing.expectEqual(null, third.value.next_page_token);
    // The read scope, and nothing wider.
    try testing.expectEqualStrings("https://www.googleapis.com/auth/logging.read", h.token.firstScope());
    const sent = try h.fake.request(0);
    try testing.expectEqualStrings("ya29.test-token", sent.bearer.?);
}

test "golden: scopes of every kind, and the oldest-first order" {
    var h: test_util.Harness = undefined;
    try h.init(&.{.{ .respond = .{ .body = "{}" } }}, .{});
    defer h.deinit();
    var q = try h.client.query(.{
        .scopes = &.{
            .{ .parent = .{ .project = "a" } },
            .{ .parent = .{ .folder = "12" } },
            .{ .parent = .{ .organization = "34" } },
            .{ .parent = .{ .billing_account = "012345-567890-ABCDEF" } },
            .{ .view = .{ .parent = .{ .project = "a" }, .location = "global", .bucket = "_Default", .view = "_AllLogs" } },
        },
        .order = .oldest_first,
        .page_size = 1000,
    });
    defer q.deinit();
    var p = try q.page(null);
    defer p.deinit();
    try h.expectRequest(0, .POST, "https://logging.googleapis.com/v2/entries:list?prettyPrint=false",
        \\{"resourceNames":["projects/a","folders/12","organizations/34","billingAccounts/012345-567890-ABCDEF","projects/a/locations/global/buckets/_Default/views/_AllLogs"],"orderBy":"timestamp asc","pageSize":1000}
    );
}

test "page: an empty or broken token is refused before sending" {
    var h: test_util.Harness = undefined;
    try h.init(&.{}, .{});
    defer h.deinit();
    var q = try h.client.query(.{});
    defer q.deinit();
    try testing.expectError(error.InvalidPageToken, q.page(""));
    try testing.expectError(error.InvalidPageToken, q.page("\xff"));
    try h.expectRequestCount(0);
}

test "page: the server's refusals of a filter and of a token have errors of their own" {
    var h: test_util.Harness = undefined;
    try h.init(&.{
        .{ .respond = .{ .status = 400, .body =
        \\{"error":{"code":400,"message":"Unparseable filter: syntax error at line 2, column 3, token '`'","status":"INVALID_ARGUMENT"}}
        } },
        .{ .respond = .{ .status = 400, .body =
        \\{"error":{"code":400,"message":"page_token doesn't match arguments from the request","status":"INVALID_ARGUMENT"}}
        } },
        .{ .respond = .{ .status = 400, .body =
        \\{"error":{"code":400,"message":"Invalid resource name","status":"INVALID_ARGUMENT"}}
        } },
    }, .{});
    defer h.deinit();
    var q = try h.client.query(.{ .filter = "a `b" });
    defer q.deinit();
    try testing.expectError(error.InvalidFilter, q.page(null));
    try testing.expect(std.mem.indexOf(u8, h.diag.message(), "line 2, column 3") != null);
    try testing.expectError(error.InvalidPageToken, q.page("EAE4"));
    try testing.expectError(error.InvalidArgument, q.page(null));
    // None of them was tried again.
    try h.expectRequestCount(3);
}

test "page: 5xx and dropped connections are retried, each try counted; a 429 never is" {
    var h: test_util.Harness = undefined;
    try h.init(&.{
        .{ .respond = .{ .status = 503, .body = "{\"error\":{\"code\":503,\"status\":\"UNAVAILABLE\"}}" } },
        .{ .fail = error.ConnectionResetByPeer },
        .{ .respond = .{ .status = 500, .body = "{\"error\":{\"code\":500,\"status\":\"INTERNAL\"}}" } },
        .{ .respond = .{ .status = 504, .body = "{\"error\":{\"code\":504,\"status\":\"DEADLINE_EXCEEDED\"}}" } },
        .{ .respond = .{ .body = one_entry } },
        .{ .respond = .{ .status = 429, .body =
        \\{"error":{"code":429,"message":"Quota exceeded for quota metric 'Read requests' and limit 'Read requests per minute'","status":"RESOURCE_EXHAUSTED"}}
        } },
    }, .{});
    defer h.deinit();
    var q = try h.client.query(.{});
    defer q.deinit();
    var p = try q.page(null);
    defer p.deinit();
    try testing.expectEqual(1, p.value.entries.len);
    try h.expectRequestCount(5);
    try testing.expectEqual(5, h.client.readBudget().used);
    // The backoffs between them.
    try testing.expectEqual(4, h.clock.sleep_count);

    try testing.expectError(error.ResourceExhausted, q.page(null));
    try h.expectRequestCount(6);
    try testing.expect(std.mem.indexOf(u8, h.diag.message(), "Read requests per minute") != null);
    // The 429 holds calls back: the next page is refused here, unsent.
    try testing.expectEqual(5_000, h.client.readBudget().next_free_ms);
    try testing.expectError(error.ResourceExhausted, q.page(null));
    try h.expectRequestCount(6);
    try testing.expect(std.mem.indexOf(u8, h.diag.message(), "local read budget") != null);
    try testing.expect(std.mem.indexOf(u8, h.diag.message(), "free in 5000 ms") != null);
}

test "page: a query's server timeout goes with every page" {
    var h: test_util.Harness = undefined;
    try h.init(&.{ .{ .respond = .{ .body = "{\"nextPageToken\":\"t\"}" } }, .{ .respond = .{ .body = "{}" } } }, .{});
    defer h.deinit();
    var q = try h.client.query(.{ .server_timeout_s = 30 });
    defer q.deinit();
    var first = try q.page(null);
    defer first.deinit();
    var second = try q.page(first.value.next_page_token);
    defer second.deinit();
    for (0..2) |i| try testing.expectEqualStrings("30", (try h.fake.request(i)).header("X-Server-Timeout").?);
    var plain = try h.client.query(.{});
    defer plain.deinit();
    try testing.expectEqual(0, plain.headers.len);
}

test "page: retries stop at the policy's attempts" {
    const unavailable: test_util.FakeTransport.Reply = .{ .respond = .{ .status = 503, .body = "{\"error\":{\"code\":503,\"status\":\"UNAVAILABLE\"}}" } };
    var h: test_util.Harness = undefined;
    try h.init(&.{ unavailable, unavailable, unavailable, .{ .respond = .{ .body = "{}" } } }, .{ .retry = .{ .max_attempts = 3 } });
    defer h.deinit();
    var q = try h.client.query(.{});
    defer q.deinit();
    try testing.expectError(error.Unavailable, q.page(null));
    try h.expectRequestCount(3);
    try testing.expectEqual(2, h.clock.sleep_count);
}

test "page: the read budget refuses the call past its count, unsent, and says when" {
    var h: test_util.Harness = undefined;
    try h.init(&.{
        .{ .respond = .{ .body = "{}" } },
        .{ .respond = .{ .body = "{}" } },
        .{ .respond = .{ .body = "{}" } },
    }, .{ .read_calls_per_minute = 2 });
    defer h.deinit();
    var q = try h.client.query(.{});
    defer q.deinit();
    for (0..2) |_| {
        var p = try q.page(null);
        p.deinit();
    }
    try testing.expectError(error.ResourceExhausted, q.page(null));
    try h.expectRequestCount(2);
    try testing.expect(std.mem.indexOf(u8, h.diag.message(), "2 entries.list calls a minute are spent; the next is free in 60000 ms") != null);
    h.clock.now_ns += 60 * std.time.ns_per_s;
    var p = try q.page(null);
    p.deinit();
    try h.expectRequestCount(3);
}

test "page: a budget runs out between retries" {
    var h: test_util.Harness = undefined;
    try h.init(&.{
        .{ .respond = .{ .status = 503, .body = "{}" } },
        .{ .respond = .{ .status = 503, .body = "{}" } },
    }, .{ .read_calls_per_minute = 2 });
    defer h.deinit();
    var q = try h.client.query(.{});
    defer q.deinit();
    try testing.expectError(error.ResourceExhausted, q.page(null));
    try h.expectRequestCount(2);
}

test "page: a response over the limit says what to change" {
    var h: test_util.Harness = undefined;
    try h.init(&.{.{ .fail = error.ResponseTooLarge }}, .{});
    defer h.deinit();
    var q = try h.client.query(.{});
    defer q.deinit();
    try testing.expectError(error.ResponseTooLarge, q.page(null));
    try testing.expect(std.mem.indexOf(u8, h.diag.message(), "smaller page_size") != null);
    try h.expectRequestCount(1);
}

test "page: a body that is no page is InvalidResponse, never retried" {
    var h: test_util.Harness = undefined;
    try h.init(&.{.{ .respond = .{ .body = "{\"entries\":[{}]}" } }}, .{});
    defer h.deinit();
    var q = try h.client.query(.{});
    defer q.deinit();
    try testing.expectError(error.InvalidResponse, q.page(null));
    try testing.expect(std.mem.indexOf(u8, h.diag.message(), "entry list") != null);
    try h.expectRequestCount(1);
}

test "query and page: every allocation failure is OutOfMemory without leaks" {
    const Run = struct {
        fn run(gpa: Allocator) !void {
            var fake: test_util.FakeTransport = .init(testing.allocator, &.{.{ .respond = .{ .body = one_entry } }});
            defer fake.deinit();
            var clock: test_util.FakeClock = .{};
            var token: test_util.FakeTokenProvider = .{};
            var client = try Client.init(gpa, clock.io(), .{
                .project_id = "extractctl",
                .token_provider = token.provider(),
                .transport = fake.transport(),
            });
            defer client.deinit();
            var q = try client.query(.{ .filter = "a", .since = t0, .log_id = "x/y" });
            defer q.deinit();
            var p = try q.page(null);
            p.deinit();
        }
    };
    try testing.checkAllAllocationFailures(test_util.no_grow_allocator, Run.run, .{});
}
