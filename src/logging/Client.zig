//! A Cloud Logging client: configuration, the HTTP connection pool, the
//! read budget, and the entry point for queries.
//!
//! Every call blocks the calling task until it completes, using the `std.Io`
//! and allocator passed to `init`. A client must not be used from two tasks
//! at once; give each task its own, and let them share a `ReadBudget`
//! through `Options.read_budget` when they read the same project.

const Client = @This();

const std = @import("std");
const Allocator = std.mem.Allocator;
const core = @import("core");

const Query = @import("Query.zig");
const Tail = @import("Tail.zig");
const budget_mod = @import("budget.zig");
const config = @import("config.zig");
const codec = @import("codec.zig");
const errors = @import("errors.zig");
const filter = @import("filter.zig");
const names = @import("names.zig");
const rpc = @import("rpc.zig");
const types = @import("types.zig");
const validate = @import("validate.zig");
const Diagnostics = core.Diagnostics;
const Error = errors.Error;
const HttpTransport = core.transport.HttpTransport;
const ReadBudget = budget_mod.ReadBudget;
const RetryPolicy = core.RetryPolicy;
const TokenProvider = core.TokenProvider;
const Transport = core.transport.Transport;

gpa: Allocator,
io: std.Io,
/// Owned copy of `Options.project_id`.
project_id: []const u8,
/// Owned. Scheme, host and port, such as `https://logging.googleapis.com`.
base_url: []const u8,
token_provider: TokenProvider,
retry: RetryPolicy,
send_quota_project: bool,
request_timeout_ms: u32,
max_response_bytes: usize,
diagnostics: ?*Diagnostics,
/// The delay the last failed attempt's response asked for, or null, as
/// the engine leaves it: this module's own retry loops wait by it.
server_delay_ms: ?u32 = null,
transport: Transport,
/// The built-in transport, when `Options.transport` was null.
http: ?*HttpTransport,
/// Owned copy of `Options.user_agent`.
user_agent: []const u8,
/// `Options.read_budget`, or `own_budget`.
budget: *ReadBudget,
/// The budget this client made, when it was given none.
own_budget: ?*ReadBudget,

pub const default_endpoint = "https://logging.googleapis.com";

pub const Options = struct {
    /// Project id or number, such as `my-project`. A query that names no
    /// scope reads this project.
    project_id: []const u8,
    /// Required. Logging has no emulator, so there is no unauthenticated
    /// mode.
    token_provider: TokenProvider,
    /// Overrides the host: a regional endpoint such as
    /// "https://logging.eu.rep.googleapis.com", or a test server. Must be
    /// `https`, since it receives credentials.
    endpoint: ?[]const u8 = null,
    /// Every call here is a read; a 429 is never retried.
    retry: RetryPolicy = .{},
    /// How long one request may take before it is `error.TimedOut`, which
    /// is retried. `entries.list` stops searching after 10 s and answers
    /// with what it has; Google's clients wait 60 s for any read. 0 removes
    /// the limit.
    request_timeout_ms: u32 = 60_000,
    /// A response whose decompressed body is larger fails with
    /// `error.ResponseTooLarge`; a smaller page size is the cure. An entry
    /// can be 256 KiB, and 512 KiB in an audit log. Used by the built-in
    /// transport; a transport passed in keeps its own limit.
    max_response_bytes: usize = core.transport.default_max_response_bytes,
    /// `entries.list` calls this client allows itself in any 60 seconds:
    /// Logging allows a project 60, and says that cannot be raised. 0
    /// counts nothing. Ignored when `read_budget` is set.
    read_calls_per_minute: u32 = 60,
    /// A count shared with other clients, which must outlive this one.
    read_budget: ?*ReadBudget = null,
    /// Sends `x-goog-user-project` when the credentials name a project to
    /// charge for quota, as a user's own credentials do.
    send_quota_project: bool = true,
    /// Printable ASCII.
    user_agent: []const u8 = "gcp-zig-logging/0.61",
    /// Filled with details of every failed call; cleared by each new call.
    diagnostics: ?*Diagnostics = null,
    /// Sends requests through this instead of `std.http.Client`. Useful for
    /// tests, including tests of code that uses this library.
    transport: ?Transport = null,
};

/// Copies what it keeps from `options`; nothing borrowed outlives the call
/// except `diagnostics`, the token provider, the transport and a shared
/// read budget.
pub fn init(gpa: Allocator, io: std.Io, options: Options) Error!Client {
    const diag = options.diagnostics;
    if (diag) |d| d.clear();
    if (!validate.isProjectId(options.project_id)) {
        if (diag) |d| d.print("invalid project id: expected 1 to 100 letters, digits, '-', '.', ':' or '_'", .{});
        return error.InvalidScope;
    }
    if (!options.retry.isValid()) {
        if (diag) |d| d.print("invalid retry policy: max_attempts must be at least 1, multiplier finite and at least 1", .{});
        return error.InvalidOptions;
    }
    if (!validate.isUserAgent(options.user_agent)) {
        if (diag) |d| d.print("invalid user agent: expected printable ASCII", .{});
        return error.InvalidOptions;
    }
    if (options.read_budget == null and options.read_calls_per_minute > validate.max_read_calls_per_minute) {
        if (diag) |d| d.print("invalid read_calls_per_minute: at most {d}", .{validate.max_read_calls_per_minute});
        return error.InvalidOptions;
    }
    if (options.max_response_bytes == 0) {
        if (diag) |d| d.print("invalid max_response_bytes: 0 would refuse every answer", .{});
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
    const project_id = try gpa.dupe(u8, options.project_id);
    errdefer gpa.free(project_id);
    const user_agent = try gpa.dupe(u8, options.user_agent);
    errdefer gpa.free(user_agent);

    var own_budget: ?*ReadBudget = null;
    const budget = options.read_budget orelse b: {
        const b = try gpa.create(ReadBudget);
        b.* = .init(options.read_calls_per_minute);
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
        .project_id = project_id,
        .base_url = base_url,
        .token_provider = options.token_provider,
        .retry = options.retry,
        .send_quota_project = options.send_quota_project,
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
    self.gpa.free(self.project_id);
    self.gpa.free(self.base_url);
    self.* = undefined;
}

/// Builds and checks one `entries.list` request, and fixes it: every page
/// of the query sends it unchanged, as page tokens require. Nothing is
/// sent. The query borrows the client and must not outlive it.
pub fn query(self: *Client, options: types.QueryOptions) Error!Query {
    rpc.begin(self);
    const diag = self.diagnostics;
    if (options.scopes.len > validate.max_scopes) {
        if (diag) |d| d.print("invalid scopes: at most {d} in one query, not {d}", .{ validate.max_scopes, options.scopes.len });
        return error.InvalidScope;
    }
    for (options.scopes, 0..) |scope, i| if (!validate.isScope(scope)) {
        if (diag) |d| d.print("invalid scope {d}: {s}", .{ i, scopeProblem(scope) });
        return error.InvalidScope;
    };
    if (options.page_size == 0 or options.page_size > validate.max_page_size) {
        if (diag) |d| d.print("invalid page_size: 1 to {d}, not {d}", .{ validate.max_page_size, options.page_size });
        return error.InvalidOptions;
    }
    if (options.server_timeout_s > max_server_timeout_s or
        (options.server_timeout_s > 0 and self.request_timeout_ms > 0 and @as(u64, options.server_timeout_s) * 1000 >= self.request_timeout_ms))
    {
        if (diag) |d| d.print("invalid server_timeout_s: at most {d}, and under request_timeout_ms ({d} ms), or the client gives up first", .{ max_server_timeout_s, self.request_timeout_ms });
        return error.InvalidOptions;
    }
    if (options.since != null and options.until != null and options.since.?.nanoseconds >= options.until.?.nanoseconds) {
        if (diag) |d| d.print("invalid time range: since must be before until", .{});
        return error.InvalidOptions;
    }

    var arena: std.heap.ArenaAllocator = .init(self.gpa);
    errdefer arena.deinit();
    const a = arena.allocator();
    const joined = switch (try filter.join(a, .{
        .filter = options.filter,
        .since = options.since,
        .until = options.until,
        .min_severity = options.min_severity,
        .log_id = options.log_id,
        .resource_type = options.resource_type,
    })) {
        .ok => |text| text,
        .refused => |problem| {
            if (diag) |d| d.print("{s}", .{problem.text()});
            return if (problem == .severity_unnamed or problem == .since_out_of_range or problem == .until_out_of_range)
                error.InvalidOptions
            else
                error.InvalidFilter;
        },
    };
    const own_project: [1]types.Scope = .{.{ .parent = .{ .project = self.project_id } }};
    const scopes: []const types.Scope = if (options.scopes.len == 0) &own_project else options.scopes;
    const resource_names = try a.alloc([]const u8, scopes.len);
    for (scopes, resource_names) |scope, *name| name.* = try names.scopeName(a, scope);
    const headers: []const core.transport.Header = if (options.server_timeout_s == 0) &.{} else h: {
        const one = try a.alloc(core.transport.Header, 1);
        one[0] = .{ .name = "X-Server-Timeout", .value = try std.fmt.allocPrint(a, "{d}", .{options.server_timeout_s}) };
        break :h one;
    };
    return .{
        .client = self,
        .arena = arena,
        .request = .{
            .resource_names = resource_names,
            .filter = joined,
            .order = options.order,
            .page_size = options.page_size,
        },
        .headers = headers,
    };
}

/// The longest search a query may ask for: an hour, as the API's longest
/// backend deadline (a tail's) is.
pub const max_server_timeout_s = 3600;

fn scopeProblem(scope: types.Scope) []const u8 {
    const parent = switch (scope) {
        .parent => |p| p,
        .view => |v| v.parent,
    };
    if (!validate.isParent(parent)) return switch (parent) {
        .project => "a project id is 1 to 100 letters, digits, '-', '.', ':' or '_'",
        .folder => "a folder id is 1 to 32 digits",
        .organization => "an organization id is 1 to 32 digits",
        .billing_account => "a billing account id is three groups of six letters or digits joined by '-'",
    };
    const v = scope.view;
    if (!validate.isLocation(v.location)) return "a location is lowercase letters, digits and '-', such as \"global\"";
    if (!validate.isBucketId(v.bucket)) return "a bucket id is 1 to 100 letters, digits, '_', '-' or '.'";
    return "a view id is 1 to 100 letters, digits, '_' or '-'";
}

/// The read count: calls in the last 60 seconds and when the next is free.
pub fn readBudget(self: *Client) types.ReadStatus {
    return self.budget.status(self.io);
}

/// A tail by polling over `entries.list`. Nothing is sent until `Tail.poll`;
/// the options are checked here, as a query's are. It borrows the client.
pub fn tail(self: *Client, options: types.TailOptions) Error!Tail {
    return Tail.init(self, options);
}

/// One page of a container's or a view's log names: only logs that have
/// entries, in byte order.
pub fn listLogs(self: *Client, options: types.ListLogsOptions) Error!types.Owned(types.LogPage) {
    return config.listLogs(self, options);
}

/// One page of a parent's buckets, in one location or every one.
pub fn listBuckets(self: *Client, options: types.ListBucketsOptions) Error!types.Owned(types.BucketPage) {
    return config.listBuckets(self, options);
}

/// One bucket. A missing one is `error.NotFound`.
pub fn bucket(self: *Client, name: types.BucketName) Error!types.Owned(types.BucketInfo) {
    return config.bucket(self, name);
}

/// One page of a bucket's views. There is no wildcard: production refused
/// location `-` here ("Cloud Logging does not support location: -").
pub fn listViews(self: *Client, bucket_name: types.BucketName, options: types.PageOptions) Error!types.Owned(types.ViewPage) {
    return config.listViews(self, bucket_name, options);
}

/// One view. A missing one is `error.NotFound`.
pub fn view(self: *Client, name: types.ViewName) Error!types.Owned(types.ViewInfo) {
    return config.view(self, name);
}

/// Every bucket of `parent` with its views, ordered for a picker: one
/// bucket list across locations and one view list a bucket, every page
/// followed. Meant to be cached: it is a call a bucket.
pub fn picker(self: *Client, parent: types.Parent) Error!types.Owned(types.Picker) {
    return config.picker(self, parent);
}

const testing = std.testing;
const test_util = @import("test_util.zig");

fn testOptions(token: *test_util.FakeTokenProvider) Options {
    return .{ .project_id = "extractctl", .token_provider = token.provider() };
}

test "init rejects bad options before allocating" {
    const gpa = testing.failing_allocator;
    var token: test_util.FakeTokenProvider = .{};
    var diag: Diagnostics = .{};
    var options = testOptions(&token);
    options.diagnostics = &diag;

    options.project_id = "a/b";
    try testing.expectError(error.InvalidScope, Client.init(gpa, testing.io, options));
    try testing.expect(std.mem.indexOf(u8, diag.message(), "invalid project id") != null);
    options.project_id = "extractctl";

    options.retry = .{ .max_attempts = 0 };
    try testing.expectError(error.InvalidOptions, Client.init(gpa, testing.io, options));
    try testing.expect(std.mem.indexOf(u8, diag.message(), "invalid retry policy") != null);
    options.retry = .{};

    options.user_agent = "agent\r\nX: y";
    try testing.expectError(error.InvalidOptions, Client.init(gpa, testing.io, options));
    try testing.expect(std.mem.indexOf(u8, diag.message(), "invalid user agent") != null);
    options.user_agent = "a";

    options.read_calls_per_minute = validate.max_read_calls_per_minute + 1;
    try testing.expectError(error.InvalidOptions, Client.init(gpa, testing.io, options));
    try testing.expect(std.mem.indexOf(u8, diag.message(), "read_calls_per_minute") != null);
    options.read_calls_per_minute = 60;

    options.max_response_bytes = 0;
    try testing.expectError(error.InvalidOptions, Client.init(gpa, testing.io, options));
    try testing.expect(std.mem.indexOf(u8, diag.message(), "max_response_bytes") != null);
}

test "init: the endpoint is production's, a regional one, or the override; never plain http" {
    var token: test_util.FakeTokenProvider = .{};
    var client: Client = try .init(testing.allocator, testing.io, testOptions(&token));
    defer client.deinit();
    try testing.expectEqualStrings("https://logging.googleapis.com", client.base_url);
    try testing.expectEqual(core.transport.default_max_response_bytes, client.http.?.max_response_bytes);

    var options = testOptions(&token);
    options.endpoint = "https://logging.eu.rep.googleapis.com/";
    options.max_response_bytes = 1 << 20;
    var regional: Client = try .init(testing.allocator, testing.io, options);
    defer regional.deinit();
    try testing.expectEqualStrings("https://logging.eu.rep.googleapis.com", regional.base_url);
    try testing.expectEqual(1 << 20, regional.http.?.max_response_bytes);

    var diag: Diagnostics = .{};
    options.diagnostics = &diag;
    options.endpoint = "http://proxy.internal:8080";
    try testing.expectError(error.InvalidEndpoint, Client.init(testing.allocator, testing.io, options));
    try testing.expect(std.mem.indexOf(u8, diag.message(), "must use https") != null);
    options.endpoint = "ftp://host";
    try testing.expectError(error.InvalidEndpoint, Client.init(testing.allocator, testing.io, options));
}

test "init copies the strings it keeps, and makes its own budget unless given one" {
    var token: test_util.FakeTokenProvider = .{};
    var project = "project-1".*;
    var agent = "agent/1".*;
    var client: Client = try .init(testing.allocator, testing.io, .{
        .project_id = &project,
        .user_agent = &agent,
        .token_provider = token.provider(),
        .read_calls_per_minute = 7,
    });
    defer client.deinit();
    @memset(&project, 'x');
    @memset(&agent, 'x');
    try testing.expectEqualStrings("project-1", client.project_id);
    try testing.expectEqualStrings("agent/1", client.user_agent);
    try testing.expectEqual(7, client.readBudget().limit);

    var shared: ReadBudget = .init(3);
    var a: Client = try .init(testing.allocator, testing.io, .{ .project_id = "p", .token_provider = token.provider(), .read_budget = &shared, .read_calls_per_minute = 5000 });
    defer a.deinit();
    try testing.expectEqual(&shared, a.budget);
    try testing.expectEqual(null, a.own_budget);
}

test "init: every allocation failure is OutOfMemory without leaks" {
    const Run = struct {
        fn run(gpa: Allocator) !void {
            var token: test_util.FakeTokenProvider = .{};
            var client: Client = try .init(gpa, testing.io, .{ .project_id = "extractctl", .token_provider = token.provider() });
            client.deinit();
        }
    };
    try testing.checkAllAllocationFailures(test_util.no_grow_allocator, Run.run, .{});
}

test "query: each refusal, each with an input only it refuses" {
    var h: test_util.Harness = undefined;
    try h.init(&.{}, .{});
    defer h.deinit();
    const c = &h.client;
    const ok_scope: types.Scope = .{ .parent = .{ .project = "p" } };

    const too_many: [validate.max_scopes + 1]types.Scope = @splat(ok_scope);
    try testing.expectError(error.InvalidScope, c.query(.{ .scopes = &too_many }));
    try testing.expect(std.mem.indexOf(u8, h.diag.message(), "at most 100") != null);
    var fits = try c.query(.{ .scopes = too_many[0..validate.max_scopes] });
    fits.deinit();

    const bad_scopes = [_]struct { types.Scope, []const u8 }{
        .{ .{ .parent = .{ .project = "a b" } }, "a project id" },
        .{ .{ .parent = .{ .folder = "f1" } }, "a folder id" },
        .{ .{ .parent = .{ .organization = "" } }, "an organization id" },
        .{ .{ .parent = .{ .billing_account = "x" } }, "a billing account id" },
        .{ .{ .view = .{ .parent = .{ .project = "p" }, .location = "Global", .bucket = "b", .view = "v" } }, "a location" },
        .{ .{ .view = .{ .parent = .{ .project = "p" }, .location = "global", .bucket = "b/c", .view = "v" } }, "a bucket id" },
        .{ .{ .view = .{ .parent = .{ .project = "p" }, .location = "global", .bucket = "b", .view = "v.w" } }, "a view id" },
        .{ .{ .view = .{ .parent = .{ .folder = "x" }, .location = "global", .bucket = "b", .view = "v" } }, "a folder id" },
    };
    for (bad_scopes) |case| {
        try testing.expectError(error.InvalidScope, c.query(.{ .scopes = &.{ ok_scope, case[0] } }));
        try testing.expect(std.mem.startsWith(u8, h.diag.message(), "invalid scope 1: "));
        try testing.expect(std.mem.indexOf(u8, h.diag.message(), case[1]) != null);
    }

    try testing.expectError(error.InvalidOptions, c.query(.{ .page_size = 0 }));
    try testing.expectError(error.InvalidOptions, c.query(.{ .page_size = validate.max_page_size + 1 }));
    var largest = try c.query(.{ .page_size = validate.max_page_size });
    largest.deinit();

    // The default request timeout is 60 s: a search must end before it.
    try testing.expectError(error.InvalidOptions, c.query(.{ .server_timeout_s = 60 }));
    try testing.expect(std.mem.indexOf(u8, h.diag.message(), "server_timeout_s") != null);
    var longest = try c.query(.{ .server_timeout_s = 59 });
    longest.deinit();

    const t: std.Io.Timestamp = .{ .nanoseconds = 1_792_141_200 * std.time.ns_per_s };
    try testing.expectError(error.InvalidOptions, c.query(.{ .since = t, .until = t }));
    try testing.expect(std.mem.indexOf(u8, h.diag.message(), "since must be before until") != null);
    var one_ns = try c.query(.{ .since = t, .until = .{ .nanoseconds = t.nanoseconds + 1 } });
    one_ns.deinit();

    try testing.expectError(error.InvalidFilter, c.query(.{ .log_id = "a\x01b" }));
    try testing.expectError(error.InvalidFilter, c.query(.{ .filter = "\xff" }));
    try testing.expectError(error.InvalidFilter, c.query(.{ .filter = test_util.repeat("x", 20_000) }));
    try testing.expectError(error.InvalidOptions, c.query(.{ .min_severity = .unknown }));
    try testing.expectError(error.InvalidOptions, c.query(.{ .until = .{ .nanoseconds = core.timestamp.max.nanoseconds + 1 } }));
    // Nothing was sent for any of them.
    try h.expectRequestCount(0);
}
