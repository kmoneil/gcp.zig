//! An Error Reporting client: configuration, the HTTP connection pool, the
//! call budget, and the entry points for group stats, events and groups.
//!
//! Every call blocks the calling task until it completes, using the `std.Io`
//! and allocator passed to `init`. A client must not be used from two tasks
//! at once; give each task its own, and let them share a `Budget` through
//! `Options.budget`, as the quota is the user's.

const Client = @This();

const std = @import("std");
const Allocator = std.mem.Allocator;
const core = @import("core");

const budget_mod = @import("budget.zig");
const codec = @import("codec.zig");
const errors = @import("errors.zig");
const query = @import("query.zig");
const rpc = @import("rpc.zig");
const types = @import("types.zig");
const validate = @import("validate.zig");
const Budget = budget_mod.Budget;
const Diagnostics = core.Diagnostics;
const Error = errors.Error;
const HttpTransport = core.transport.HttpTransport;
const RetryPolicy = core.RetryPolicy;
const TokenProvider = core.TokenProvider;
const Transport = core.transport.Transport;

gpa: Allocator,
io: std.Io,
/// Owned. Scheme, host and port.
base_url: []const u8,
token_provider: TokenProvider,
/// Owned. "projects/P", or "projects/P/locations/L".
parent: []const u8,
/// Whether `parent` names every region, `-`, which only group stats take.
every_region: bool,
send_quota_project: bool,
retry: RetryPolicy,
request_timeout_ms: u32,
max_response_bytes: usize,
diagnostics: ?*Diagnostics,
transport: Transport,
/// The built-in transport, when `Options.transport` was null.
http: ?*HttpTransport,
/// Owned copy of `Options.user_agent`.
user_agent: []const u8,
/// `Options.budget`, or `own_budget`.
budget: *Budget,
/// The budget this client made, when it was given none.
own_budget: ?*Budget,
/// The delay the last refused attempt asked for, kept by the engine.
server_delay_ms: ?u32 = null,
/// The last call's consumer refusal, its text in `refusal_buf`.
refusal: ?StoredRefusal = null,
refusal_buf: [refusal_capacity]u8 = undefined,

pub const default_endpoint = "https://clouderrorreporting.googleapis.com";

/// Room for a refusal's consumer and link, with room to spare.
const refusal_capacity = 1024;

const StoredRefusal = struct {
    reason: types.ConsumerRefusal.Reason,
    consumer_len: usize,
    /// Null when the server sent none, or it did not fit.
    link_len: ?usize,
};

pub const Options = struct {
    /// Required: the project whose errors are read, an id or a number.
    project_id: []const u8,
    /// Required. Error Reporting has no emulator, so there is no
    /// unauthenticated mode.
    token_provider: TokenProvider,
    /// Null for the plain `projects/P` paths, which are `global`. A region
    /// reads the groups whose log entries are stored there, and `-` reads
    /// group stats from every region; events and groups need one place.
    location: ?[]const u8 = null,
    /// Overrides the host: a test server, say. Must be `https`, since it
    /// receives credentials.
    endpoint: ?[]const u8 = null,
    /// Sends the credentials' quota project as `x-goog-user-project`, as
    /// every module does: a person's login needs one for this API.
    send_quota_project: bool = true,
    /// 5xx and dropped connections are retried, a group's update too; a 429
    /// never.
    retry: RetryPolicy = .{},
    /// How long one request may take before it is `error.TimedOut`, which
    /// is retried. Google's clients wait up to 600 s for a whole call. 0
    /// removes the limit.
    request_timeout_ms: u32 = 60_000,
    /// A response whose decompressed body is larger fails with
    /// `error.ResponseTooLarge`. Used by the built-in transport; a transport
    /// passed in keeps its own limit.
    max_response_bytes: usize = core.transport.default_max_response_bytes,
    /// Calls a minute this client's own budget allows, at most 60, the
    /// per-user quota; 0 counts nothing. Ignored when `budget` is set.
    calls_per_minute: u32 = validate.max_calls_per_minute,
    /// A budget shared with other clients of the same user. Must outlive
    /// this client.
    budget: ?*Budget = null,
    /// Printable ASCII.
    user_agent: []const u8 = "zig-gcp-error_reporting/0.52",
    /// Filled with details of every failed call; cleared by each new call.
    diagnostics: ?*Diagnostics = null,
    /// Sends requests through this instead of `std.http.Client`. Useful for
    /// tests, including tests of code that uses this library.
    transport: ?Transport = null,
};

/// Copies what it keeps from `options`; nothing borrowed outlives the call
/// except `diagnostics`, `budget`, the token provider and the transport.
pub fn init(gpa: Allocator, io: std.Io, options: Options) Error!Client {
    const diag = options.diagnostics;
    if (diag) |d| d.clear();
    if (!validate.isProject(options.project_id)) {
        if (diag) |d| d.print("invalid project: expected a project id or number", .{});
        return error.InvalidName;
    }
    if (options.location) |l| if (!validate.isLocation(l)) {
        if (diag) |d| d.print("invalid location: expected a region such as us-central1, global, or -", .{});
        return error.InvalidName;
    };
    if (!options.retry.isValid()) {
        if (diag) |d| d.print("invalid retry policy: max_attempts must be at least 1, multiplier finite and at least 1", .{});
        return error.InvalidOptions;
    }
    if (!validate.isUserAgent(options.user_agent)) {
        if (diag) |d| d.print("invalid user agent: expected printable ASCII", .{});
        return error.InvalidOptions;
    }
    if (options.max_response_bytes == 0) {
        if (diag) |d| d.print("invalid max_response_bytes: 0 would refuse every answer", .{});
        return error.InvalidOptions;
    }
    if (options.budget == null and options.calls_per_minute > validate.max_calls_per_minute) {
        if (diag) |d| d.print("invalid calls_per_minute: at most {d}, Error Reporting's per-user quota", .{validate.max_calls_per_minute});
        return error.InvalidOptions;
    }

    const base_url = core.endpoint.baseUrl(gpa, options.endpoint orelse default_endpoint, .https) catch |err| {
        if (err == error.InvalidEndpoint) if (diag) |d| d.print("invalid endpoint: expected https://host[:port]", .{});
        return err;
    };
    errdefer gpa.free(base_url);
    // Every request carries a bearer token, which must not travel in cleartext.
    if (!std.mem.startsWith(u8, base_url, "https://")) {
        if (diag) |d| d.print("invalid endpoint: endpoints that receive credentials must use https", .{});
        return error.InvalidEndpoint;
    }
    const parent = if (options.location) |l|
        try gpa.print("projects/{s}/locations/{s}", .{ options.project_id, l })
    else
        try gpa.print("projects/{s}", .{options.project_id});
    errdefer gpa.free(parent);
    const user_agent = try gpa.dupe(u8, options.user_agent);
    errdefer gpa.free(user_agent);
    var own_budget: ?*Budget = null;
    const budget = options.budget orelse b: {
        const b = try gpa.create(Budget);
        b.* = .init(options.calls_per_minute);
        own_budget = b;
        break :b b;
    };
    errdefer if (own_budget) |b| gpa.destroy(b);

    var http: ?*HttpTransport = null;
    const transport = options.transport orelse t: {
        const h = try gpa.create(HttpTransport);
        h.* = .init(gpa, io, user_agent);
        h.max_response_bytes = options.max_response_bytes;
        http = h;
        break :t h.transport();
    };
    return .{
        .gpa = gpa,
        .io = io,
        .base_url = base_url,
        .token_provider = options.token_provider,
        .parent = parent,
        .every_region = if (options.location) |l| std.mem.eql(u8, l, "-") else false,
        .send_quota_project = options.send_quota_project,
        .retry = options.retry,
        .request_timeout_ms = options.request_timeout_ms,
        .max_response_bytes = options.max_response_bytes,
        .diagnostics = diag,
        .transport = transport,
        .http = http,
        .user_agent = user_agent,
        .budget = budget,
        .own_budget = own_budget,
    };
}

pub fn deinit(self: *Client) void {
    if (self.http) |h| {
        h.deinit();
        self.gpa.destroy(h);
    }
    if (self.own_budget) |b| self.gpa.destroy(b);
    self.gpa.free(self.user_agent);
    self.gpa.free(self.parent);
    self.gpa.free(self.base_url);
    self.* = undefined;
}

/// Group stats, page by page: what each group's errors in the period came
/// to, ordered as asked. The request is built and checked here and fixed:
/// every page sends it unchanged. Nothing is sent until the first page. The
/// query borrows the client and must not outlive it.
pub fn groupStats(self: *Client, options: types.GroupStatsOptions) Error!query.Query(types.GroupStats) {
    rpc.begin(self);
    var arena: std.heap.ArenaAllocator = .init(self.gpa);
    errdefer arena.deinit();
    const path = try query.groupStatsPath(arena.allocator(), self.diagnostics, self.parent, options);
    return .{ .client = self, .arena = arena, .path = path };
}

/// One group's events, newest first, page by page. Nothing is sent until
/// the first page. The query borrows the client and must not outlive it.
pub fn events(self: *Client, group_id: []const u8, options: types.EventsOptions) Error!query.Query(types.Event) {
    rpc.begin(self);
    try self.onePlace("events");
    var arena: std.heap.ArenaAllocator = .init(self.gpa);
    errdefer arena.deinit();
    const path = try query.eventsPath(arena.allocator(), self.diagnostics, self.parent, group_id, options);
    return .{ .client = self, .arena = arena, .path = path };
}

/// One group, to read or to set its status. Nothing is sent, nothing is
/// checked until a call.
pub fn group(self: *Client, group_id: []const u8) GroupRef {
    return .{ .client = self, .id = group_id };
}

/// A group, by id.
pub const GroupRef = struct {
    client: *Client,
    id: []const u8,

    /// The group as it is, muted or not: the only call that reads a muted
    /// group. An id that names no group is `error.NotFound`, though
    /// production answers it 400 "Invalid group id".
    pub fn get(self: GroupRef) Error!types.Owned(types.Group) {
        const c = self.client;
        rpc.begin(c);
        var result: types.Owned(types.Group) = try .init(c.gpa);
        errdefer result.deinit();
        result.value = try self.read(result.arena.allocator());
        return result;
    }

    /// Sets the group's status: reads it, then puts it back whole with the
    /// new status, as the API replaces what an update leaves out, tracking
    /// issues included. An edit of the issues made by someone else between
    /// the two calls is lost: the API has no etag. Two calls against the
    /// budget. Answers the group as written.
    pub fn setStatus(self: GroupRef, status: types.Status) Error!types.Owned(types.Group) {
        const c = self.client;
        rpc.begin(c);
        if (status == .unknown) {
            if (c.diagnostics) |d| d.print("invalid status: .unknown is what this version cannot name, never one to set", .{});
            return error.InvalidOptions;
        }
        var result: types.Owned(types.Group) = try .init(c.gpa);
        errdefer result.deinit();
        var scratch: std.heap.ArenaAllocator = .init(c.gpa);
        defer scratch.deinit();
        const current = try self.read(scratch.allocator());
        const body = try codec.encodeGroup(scratch.allocator(), current, status);
        const path = try self.route(scratch.allocator());
        var response: std.heap.ArenaAllocator = .init(c.gpa);
        defer response.deinit();
        const answer = try rpc.call(c, &response, .PUT, path, body, false);
        result.value = codec.decodeGroup(result.arena.allocator(), scratch.allocator(), answer) catch |err| return rpc.decodeFailed(c, err, "group");
        return result;
    }

    fn read(self: GroupRef, out: Allocator) Error!types.Group {
        const c = self.client;
        try c.onePlace("a group");
        var scratch: std.heap.ArenaAllocator = .init(c.gpa);
        defer scratch.deinit();
        const path = try self.route(scratch.allocator());
        var response: std.heap.ArenaAllocator = .init(c.gpa);
        defer response.deinit();
        const body = try rpc.call(c, &response, .GET, path, null, false);
        return codec.decodeGroup(out, scratch.allocator(), body) catch |err| rpc.decodeFailed(c, err, "group");
    }

    fn route(self: GroupRef, arena: Allocator) Error![]const u8 {
        const c = self.client;
        if (!validate.isGroupId(self.id)) {
            if (c.diagnostics) |d| d.print("invalid group id: expected one Error Reporting assigned, base64url characters", .{});
            return error.InvalidName;
        }
        return arena.print("/v1beta1/{s}/groups/{s}?prettyPrint=false", .{ c.parent, self.id });
    }
};

/// Events and groups live in one place: `-` is for group stats only.
fn onePlace(self: *Client, what: []const u8) Error!void {
    if (!self.every_region) return;
    if (self.diagnostics) |d| d.print("{s} need one location; - reads group stats only", .{what});
    return error.InvalidOptions;
}

/// Where the call budget stands: calls in the last minute and how long
/// until the next may go.
pub fn budgetStatus(self: *Client) types.BudgetStatus {
    return self.budget.status(self.io);
}

/// The last call's refusal that named the project charged, if it was one:
/// `error.ServiceDisabled` or `error.QuotaProjectDenied`. Borrowed from the
/// client until its next call.
pub fn lastConsumerRefusal(self: *const Client) ?types.ConsumerRefusal {
    const r = self.refusal orelse return null;
    return .{
        .reason = r.reason,
        .consumer = self.refusal_buf[0..r.consumer_len],
        .link = if (r.link_len) |n| self.refusal_buf[r.consumer_len..][0..n] else null,
    };
}

/// Keeps a refusal's consumer and link.
pub fn setRefusal(self: *Client, reason: types.ConsumerRefusal.Reason, consumer: []const u8, link: ?[]const u8) void {
    const consumer_len = @min(consumer.len, self.refusal_buf.len);
    @memcpy(self.refusal_buf[0..consumer_len], consumer[0..consumer_len]);
    var link_len: ?usize = null;
    if (link) |l| if (consumer_len + l.len <= self.refusal_buf.len) {
        @memcpy(self.refusal_buf[consumer_len..][0..l.len], l);
        link_len = l.len;
    };
    self.refusal = .{ .reason = reason, .consumer_len = consumer_len, .link_len = link_len };
}

const testing = std.testing;
const test_util = @import("test_util.zig");
const bodies = @import("production_bodies.zig");
const Reply = test_util.FakeTransport.Reply;

const base = "https://clouderrorreporting.googleapis.com/v1beta1/projects/my-project";

fn ok(comptime body: []const u8) Reply {
    return .{ .respond = .{ .body = body } };
}

fn refused(comptime status: u16, comptime body: []const u8) Reply {
    return .{ .respond = .{ .status = status, .body = body } };
}

test "golden: group stats, page by page, the same request with the token after it" {
    var h: test_util.Harness = undefined;
    try h.init(&.{ ok(bodies.group_stats_page_1), ok(bodies.group_stats_30_days) }, .{ .quota_project = "billing-p" });
    defer h.deinit();
    var q = try h.client.groupStats(.{ .period = .thirty_days, .page_size = 1 });
    defer q.deinit();
    var first = try q.page(null);
    defer first.deinit();
    try h.expectRequest(0, .GET, base ++ "/groupStats?prettyPrint=false&timeRange.period=PERIOD_30_DAYS&pageSize=1", null);
    const sent = try h.fake.request(0);
    try testing.expectEqualStrings("ya29.test-token", sent.bearer.?);
    try testing.expectEqualStrings("billing-p", sent.header("x-goog-user-project").?);
    try testing.expectEqual(1, first.value.items.len);
    var second = try q.page(first.value.next_page_token);
    defer second.deinit();
    try h.expectRequest(1, .GET, base ++ "/groupStats?prettyPrint=false&timeRange.period=PERIOD_30_DAYS&pageSize=1&pageToken=EicxMDEwODQxMzg5NjIwNDQ3NzQwNjE3OTIyOTA5Nzg3MzUzMjgwODQ%3D", null);
    try testing.expectEqual(2, second.value.items.len);
    try testing.expectEqual(null, second.value.next_page_token);
}

test "golden: a group's events, and a location in every path" {
    var h: test_util.Harness = undefined;
    try h.init(&.{ ok(bodies.events_page), ok(bodies.group_get), ok("{}") }, .{ .location = "global" });
    defer h.deinit();
    var q = try h.client.events("COiYvODSyMz2Bg", .{ .period = .thirty_days });
    defer q.deinit();
    var page = try q.page(null);
    defer page.deinit();
    try h.expectRequest(0, .GET, base ++ "/locations/global/events?prettyPrint=false&groupId=COiYvODSyMz2Bg&timeRange.period=PERIOD_30_DAYS", null);
    try testing.expectEqual(6, page.value.items.len);
    var g = try h.client.group("COiYvODSyMz2Bg").get();
    defer g.deinit();
    try h.expectRequest(1, .GET, base ++ "/locations/global/groups/COiYvODSyMz2Bg?prettyPrint=false", null);
    try testing.expectEqual(.open, g.value.status);
    var s = try h.client.groupStats(.{});
    defer s.deinit();
    var empty = try s.page(null);
    defer empty.deinit();
    try h.expectRequest(2, .GET, base ++ "/locations/global/groupStats?prettyPrint=false", null);
    try testing.expectEqual(0, empty.value.items.len);
}

test "every region reads group stats only: events and groups need one place" {
    var h: test_util.Harness = undefined;
    try h.init(&.{ok("{}")}, .{ .location = "-" });
    defer h.deinit();
    try testing.expectError(error.InvalidOptions, h.client.events("G", .{}));
    try testing.expectEqualStrings("events need one location; - reads group stats only", h.diag.message());
    try testing.expectError(error.InvalidOptions, h.client.group("G").get());
    try testing.expectError(error.InvalidOptions, h.client.group("G").setStatus(.resolved));
    var q = try h.client.groupStats(.{});
    defer q.deinit();
    var page = try q.page(null);
    defer page.deinit();
    try h.expectRequest(0, .GET, base ++ "/locations/-/groupStats?prettyPrint=false", null);
}

test "setStatus reads the group, then puts it back whole: its tracking issues kept" {
    var h: test_util.Harness = undefined;
    try h.init(&.{
        ok(bodies.group_with_issue),
        ok(
            \\{"name":"projects/extractctl/groups/CMfm1OTYhMPcdA","groupId":"CMfm1OTYhMPcdA","trackingIssues":[{"url":"https://example.com/issues/zigps-2"}],"resolutionStatus":"RESOLVED"}
        ),
    }, .{});
    defer h.deinit();
    var g = try h.client.group("CMfm1OTYhMPcdA").setStatus(.resolved);
    defer g.deinit();
    try h.expectRequest(0, .GET, base ++ "/groups/CMfm1OTYhMPcdA?prettyPrint=false", null);
    try h.expectRequest(1, .PUT, base ++ "/groups/CMfm1OTYhMPcdA?prettyPrint=false",
        \\{"name":"projects/extractctl/groups/CMfm1OTYhMPcdA","groupId":"CMfm1OTYhMPcdA","trackingIssues":[{"url":"https://example.com/issues/zigps-2"}],"resolutionStatus":"RESOLVED"}
    );
    try testing.expectEqual(.resolved, g.value.status);
    try testing.expectEqual(1, g.value.tracking_issues.len);
    try testing.expectError(error.InvalidOptions, h.client.group("G").setStatus(.unknown));
    try h.expectRequestCount(2);
}

test "production's refusals, each as an error of its own" {
    var h: test_util.Harness = undefined;
    try h.init(&.{
        refused(403, bodies.refused_disabled),
        refused(400, bodies.refused_group_id),
        refused(400, bodies.refused_well_formed_group_id),
        refused(400, bodies.refused_page_token),
        refused(400, bodies.refused_too_short),
        refused(400, bodies.refused_bad_period),
        refused(400, bodies.refused_missing_group_id),
        refused(400, bodies.refused_page_token),
    }, .{});
    defer h.deinit();
    var q = try h.client.groupStats(.{});
    defer q.deinit();
    try testing.expectError(error.ServiceDisabled, q.page(null));
    const r = h.client.lastConsumerRefusal().?;
    try testing.expectEqual(.service_disabled, r.reason);
    try testing.expectEqualStrings("projects/82150720798", r.consumer);
    try testing.expectEqualStrings("https://console.developers.google.com/apis/api/clouderrorreporting.googleapis.com/overview?project=82150720798", r.link.?);
    try testing.expect(std.mem.startsWith(u8, h.diag.message(), "Error Reporting API has not been used in project 82150720798"));

    try testing.expectError(error.NotFound, h.client.group("zigps-no-such-group").get());
    try testing.expectEqual(null, h.client.lastConsumerRefusal());
    try testing.expectEqualStrings("Invalid group id: zigps-no-such-group", h.diag.message());
    try testing.expectError(error.NotFound, h.client.group("CAAAAAAAAAAAAA").get());

    try testing.expectError(error.InvalidPageToken, q.page("zigps-not-a-token"));
    try testing.expectError(error.InvalidOptions, q.page(null));
    try testing.expectEqualStrings("'timed_count_duration' is too short for the requested period", h.diag.message());
    try testing.expectError(error.InvalidArgument, q.page(null));
    // Not a token: the same words from a request without one stay generic.
    try testing.expectError(error.InvalidArgument, q.page(null));
    try testing.expectEqualStrings("Missing group_id.", h.diag.message());
    // A token's refusal answering a request that sent none is no verdict on
    // a token.
    try testing.expectError(error.InvalidArgument, q.page(null));
    try h.expectRequestCount(8);
}

test "names and tokens this client will not send are refused unsent" {
    var h: test_util.Harness = undefined;
    try h.init(&.{}, .{});
    defer h.deinit();
    try testing.expectError(error.InvalidName, h.client.group("a/b").get());
    try testing.expectError(error.InvalidName, h.client.events("a b", .{}));
    try testing.expectError(error.InvalidName, h.client.groupStats(.{ .group_ids = &.{"%2F"} }));
    var q = try h.client.groupStats(.{});
    defer q.deinit();
    try testing.expectError(error.InvalidPageToken, q.page("a b"));
    try testing.expectError(error.InvalidPageToken, q.page(""));
    try h.expectRequestCount(0);
}

test "a 5xx is retried, a 429 is not and holds the budget back" {
    var h: test_util.Harness = undefined;
    try h.init(&.{
        refused(503, "{\"error\":{\"code\":503,\"status\":\"UNAVAILABLE\"}}"),
        ok(bodies.group_get),
        refused(429, "{\"error\":{\"code\":429,\"status\":\"RESOURCE_EXHAUSTED\"}}"),
        ok(bodies.group_get),
    }, .{});
    defer h.deinit();
    var g = try h.client.group("COiYvODSyMz2Bg").get();
    g.deinit();
    try h.expectRequestCount(2);
    try testing.expectEqual(1, h.clock.sleep_count);
    try testing.expectError(error.ResourceExhausted, h.client.group("COiYvODSyMz2Bg").get());
    try h.expectRequestCount(3);
    // Held back 5 s: the next call is refused here, unsent, and says when.
    try testing.expectError(error.ResourceExhausted, h.client.group("COiYvODSyMz2Bg").get());
    try h.expectRequestCount(3);
    try testing.expectEqualStrings("local budget: 60 calls a minute are spent; the next is free in 5000 ms", h.diag.message());
    try testing.expectEqual(5_000, h.client.budgetStatus().next_free_ms);
    h.clock.now_ns += 5 * std.time.ns_per_s;
    var again = try h.client.group("COiYvODSyMz2Bg").get();
    again.deinit();
    try h.expectRequestCount(4);
}

test "a 429 that asks for longer than 5 s holds the budget back that long" {
    var h: test_util.Harness = undefined;
    try h.init(&.{.{ .respond = .{ .status = 429, .headers = &.{.{ .name = "Retry-After", .value = "20" }}, .body = "{\"error\":{\"code\":429,\"status\":\"RESOURCE_EXHAUSTED\"}}" } }}, .{});
    defer h.deinit();
    try testing.expectError(error.ResourceExhausted, h.client.group("G").get());
    try testing.expectEqual(20_000, h.client.budgetStatus().next_free_ms);
    try testing.expectEqual(20_000, h.diag.retry_after_ms.?);
}

test "the budget counts every attempt, refuses past its limit unsent, and is shared" {
    var shared: Budget = .init(3);
    var a: test_util.Harness = undefined;
    try a.init(&.{ ok("{}"), ok("{}") }, .{ .budget = &shared });
    defer a.deinit();
    var b: test_util.Harness = undefined;
    try b.init(&.{ ok("{}"), ok("{}") }, .{ .budget = &shared });
    defer b.deinit();
    b.clock.now_ns = a.clock.now_ns;
    for ([_]*test_util.Harness{ &a, &a, &b }) |h| {
        var q = try h.client.groupStats(.{});
        defer q.deinit();
        var page = try q.page(null);
        page.deinit();
    }
    var q = try b.client.groupStats(.{});
    defer q.deinit();
    try testing.expectError(error.ResourceExhausted, q.page(null));
    try b.expectRequestCount(1);
    try testing.expectEqual(3, b.client.budgetStatus().used);

    // A limit of 0 counts nothing.
    var free: test_util.Harness = undefined;
    try free.init(&.{ ok("{}"), ok("{}"), ok("{}") }, .{ .calls_per_minute = 0 });
    defer free.deinit();
    for (0..3) |_| {
        var fq = try free.client.groupStats(.{});
        defer fq.deinit();
        var page = try fq.page(null);
        page.deinit();
    }
    try testing.expectEqual(0, free.client.budgetStatus().limit);
}

test "init refuses what it will not send, and says why" {
    var token: test_util.FakeTokenProvider = .{ .token = "t" };
    var diag: Diagnostics = .{};
    const cases = [_]struct { Options, Error, []const u8 }{
        .{ .{ .project_id = "Bad/Project", .token_provider = token.provider(), .diagnostics = &diag }, error.InvalidName, "invalid project: expected a project id or number" },
        .{ .{ .project_id = "p", .location = "US", .token_provider = token.provider(), .diagnostics = &diag }, error.InvalidName, "invalid location: expected a region such as us-central1, global, or -" },
        .{ .{ .project_id = "p", .retry = .{ .max_attempts = 0 }, .token_provider = token.provider(), .diagnostics = &diag }, error.InvalidOptions, "invalid retry policy: max_attempts must be at least 1, multiplier finite and at least 1" },
        .{ .{ .project_id = "p", .user_agent = "a\nb", .token_provider = token.provider(), .diagnostics = &diag }, error.InvalidOptions, "invalid user agent: expected printable ASCII" },
        .{ .{ .project_id = "p", .max_response_bytes = 0, .token_provider = token.provider(), .diagnostics = &diag }, error.InvalidOptions, "invalid max_response_bytes: 0 would refuse every answer" },
        .{ .{ .project_id = "p", .calls_per_minute = 61, .token_provider = token.provider(), .diagnostics = &diag }, error.InvalidOptions, "invalid calls_per_minute: at most 60, Error Reporting's per-user quota" },
        .{ .{ .project_id = "p", .endpoint = "http://example.com", .token_provider = token.provider(), .diagnostics = &diag }, error.InvalidEndpoint, "invalid endpoint: endpoints that receive credentials must use https" },
    };
    for (cases) |case| {
        try testing.expectError(case[1], Client.init(testing.allocator, testing.io, case[0]));
        try testing.expectEqualStrings(case[2], diag.message());
    }
    // A budget passed in may count more than the client's own could.
    var budget: Budget = .init(60);
    var client = try Client.init(testing.allocator, testing.io, .{ .project_id = "82150720798", .calls_per_minute = 61, .budget = &budget, .token_provider = token.provider() });
    client.deinit();
}

test "an answer that does not decode is InvalidResponse, and says what" {
    var h: test_util.Harness = undefined;
    try h.init(&.{ ok("[]"), ok("{\"errorEvents\":7}"), ok("{\"groupId\":\"G\"}") }, .{});
    defer h.deinit();
    var q = try h.client.groupStats(.{});
    defer q.deinit();
    try testing.expectError(error.InvalidResponse, q.page(null));
    try testing.expectEqualStrings("the group stats response could not be decoded", h.diag.message());
    var e = try h.client.events("G", .{});
    defer e.deinit();
    try testing.expectError(error.InvalidResponse, e.page(null));
    try testing.expectEqualStrings("the events response could not be decoded", h.diag.message());
    try testing.expectError(error.InvalidResponse, h.client.group("G").get());
    try testing.expectEqualStrings("the group response could not be decoded", h.diag.message());
}

test "every allocation failure is OutOfMemory without leaks" {
    const Run = struct {
        fn run(gpa: Allocator) !void {
            var fake: test_util.FakeTransport = .init(testing.allocator, &.{ ok(bodies.group_stats_timed_end), ok(bodies.events_page), ok(bodies.group_with_issue), ok(bodies.group_with_issue) });
            defer fake.deinit();
            var clock: test_util.FakeClock = .{};
            var token: test_util.FakeTokenProvider = .{ .token = "t" };
            var client = try Client.init(gpa, clock.io(), .{ .project_id = "p", .location = "global", .token_provider = token.provider(), .transport = fake.transport() });
            defer client.deinit();
            var q = try client.groupStats(.{ .period = .day, .timed_count_seconds = 3600, .group_ids = &.{"G"} });
            defer q.deinit();
            var page = try q.page(null);
            page.deinit();
            var e = try client.events("G", .{});
            defer e.deinit();
            var events_page = try e.page(null);
            events_page.deinit();
            var g = try client.group("G").setStatus(.muted);
            g.deinit();
        }
    };
    try testing.checkAllAllocationFailures(test_util.no_grow_allocator, Run.run, .{});
}
