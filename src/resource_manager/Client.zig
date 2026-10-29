//! A Resource Manager client: configuration, the HTTP connection pool, the
//! quota project, and the entry points for searches, walks and gets.
//!
//! Every call blocks the calling task until it completes, using the `std.Io`
//! and allocator passed to `init`. A client must not be used from two tasks
//! at once; give each task its own.

const Client = @This();

const std = @import("std");
const Allocator = std.mem.Allocator;
const core = @import("core");

const codec = @import("codec.zig");
const errors = @import("errors.zig");
const rpc = @import("rpc.zig");
const search_mod = @import("search.zig");
const types = @import("types.zig");
const validate = @import("validate.zig");
const walk = @import("walk.zig");
const Diagnostics = core.Diagnostics;
const Error = errors.Error;
const HttpTransport = core.transport.HttpTransport;
const RetryPolicy = core.RetryPolicy;
const TokenProvider = core.TokenProvider;
const Transport = core.transport.Transport;

gpa: Allocator,
io: std.Io,
/// Owned. Scheme, host and port, such as
/// `https://cloudresourcemanager.googleapis.com`.
base_url: []const u8,
token_provider: TokenProvider,
/// `.project`'s id is owned.
quota_project: types.QuotaProject,
retry: RetryPolicy,
request_timeout_ms: u32,
max_response_bytes: usize,
diagnostics: ?*Diagnostics,
transport: Transport,
/// The built-in transport, when `Options.transport` was null.
http: ?*HttpTransport,
/// Owned copy of `Options.user_agent`.
user_agent: []const u8,
/// The last call's consumer refusal, its text in `refusal_buf`.
refusal: ?StoredRefusal = null,
refusal_buf: [refusal_capacity]u8 = undefined,

pub const default_endpoint = "https://cloudresourcemanager.googleapis.com";

/// Room for a refusal's consumer and link: "projects/" and a project id of
/// at most 100, and a console link, with room to spare.
const refusal_capacity = 1024;

const StoredRefusal = struct {
    reason: types.ConsumerRefusal.Reason,
    consumer_len: usize,
    /// Null when the server sent none, or it did not fit.
    link_len: ?usize,
};

pub const Options = struct {
    /// Required. Resource Manager has no emulator, so there is no
    /// unauthenticated mode.
    token_provider: TokenProvider,
    /// Overrides the host: a test server, say. Must be `https`, since it
    /// receives credentials.
    endpoint: ?[]const u8 = null,
    /// The project charged for quota and checked for the API. None by
    /// default, as gcloud does for every project command: a quota project
    /// with the API off breaks a search that would work without one.
    quota_project: types.QuotaProject = .none,
    /// Every call here is a GET with no side effect; a 429 is never
    /// retried.
    retry: RetryPolicy = .{},
    /// How long one request may take before it is `error.TimedOut`, which
    /// is retried. Google's clients wait 60 s; the backend's own deadline
    /// is 30 s. 0 removes the limit.
    request_timeout_ms: u32 = 60_000,
    /// A response whose decompressed body is larger fails with
    /// `error.ResponseTooLarge`; a page of 500 projects is about 200 KB.
    /// Used by the built-in transport; a transport passed in keeps its own
    /// limit.
    max_response_bytes: usize = core.transport.default_max_response_bytes,
    /// Printable ASCII.
    user_agent: []const u8 = "gcp-zig-resource_manager/0.59",
    /// Filled with details of every failed call; cleared by each new call.
    diagnostics: ?*Diagnostics = null,
    /// Sends requests through this instead of `std.http.Client`. Useful for
    /// tests, including tests of code that uses this library.
    transport: ?Transport = null,
};

/// Copies what it keeps from `options`; nothing borrowed outlives the call
/// except `diagnostics`, the token provider and the transport.
pub fn init(gpa: Allocator, io: std.Io, options: Options) Error!Client {
    const diag = options.diagnostics;
    if (diag) |d| d.clear();
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
    if (options.quota_project == .project and !validate.isQuotaProject(options.quota_project.project)) {
        if (diag) |d| d.print("invalid quota project: expected a project id or number", .{});
        return error.InvalidName;
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
    const quota_project: types.QuotaProject = switch (options.quota_project) {
        .project => |p| .{ .project = try gpa.dupe(u8, p) },
        else => |q| q,
    };
    errdefer if (quota_project == .project) gpa.free(quota_project.project);
    const user_agent = try gpa.dupe(u8, options.user_agent);
    errdefer gpa.free(user_agent);

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
        .quota_project = quota_project,
        .retry = options.retry,
        .request_timeout_ms = options.request_timeout_ms,
        .max_response_bytes = options.max_response_bytes,
        .diagnostics = diag,
        .transport = transport,
        .http = http,
        .user_agent = user_agent,
    };
}

pub fn deinit(self: *Client) void {
    if (self.http) |h| {
        h.deinit();
        self.gpa.destroy(h);
    }
    if (self.quota_project == .project) self.gpa.free(self.quota_project.project);
    self.gpa.free(self.user_agent);
    self.gpa.free(self.base_url);
    self.* = undefined;
}

/// A project search, page by page. The request is built and checked here
/// and fixed: every page sends it unchanged. Nothing is sent. The search
/// borrows the client and must not outlive it.
pub fn searchProjects(self: *Client, options: types.SearchOptions) Error!search_mod.Search(types.Project) {
    return self.search(types.Project, options);
}

/// A folder search, page by page: the folders the caller holds
/// `resourcemanager.folders.get` on. The query reads `displayName`,
/// `parent` and `state` (only its empty form was measured). Nothing is
/// sent until the first page.
pub fn searchFolders(self: *Client, options: types.SearchOptions) Error!search_mod.Search(types.Folder) {
    return self.search(types.Folder, options);
}

/// An organization search, page by page: the organizations the caller
/// holds `resourcemanager.organizations.get` on. The query reads
/// `directoryCustomerId` and `domain` (only its empty form was measured).
/// Nothing is sent until the first page.
pub fn searchOrganizations(self: *Client, options: types.SearchOptions) Error!search_mod.Search(types.Organization) {
    return self.search(types.Organization, options);
}

fn search(self: *Client, comptime T: type, options: types.SearchOptions) Error!search_mod.Search(T) {
    rpc.begin(self);
    if (options.query) |q| if (validate.queryProblem(q)) |problem| {
        if (self.diagnostics) |d| d.print("{s}", .{problem});
        return error.InvalidQuery;
    };
    var arena: std.heap.ArenaAllocator = .init(self.gpa);
    errdefer arena.deinit();
    var w: std.Io.Writer.Allocating = .init(arena.allocator());
    writeSearchPath(&w.writer, search_mod.Search(T).route, options) catch return error.OutOfMemory;
    return .{ .client = self, .arena = arena, .path = w.written() };
}

fn writeSearchPath(w: *std.Io.Writer, route: []const u8, options: types.SearchOptions) std.Io.Writer.Error!void {
    try w.writeAll(route);
    var params: core.query.Params = .init(w);
    try params.addOptional("query", options.query);
    try params.addNonZero("pageSize", options.page_size);
    try params.add("prettyPrint", "false");
}

/// Every project the credential can see, or those `options.query` finds:
/// each page of one search read, each project number kept once, projects
/// pending deletion left out, sorted by project id. Meant to be cached and
/// filtered locally: search is eventually consistent, and a call a
/// keystroke would spend the quota every user of the charged project
/// shares. A failure on any page fails the walk.
pub fn allProjects(self: *Client, options: types.WalkOptions) Error!types.Owned(types.ProjectList) {
    return walk.projects(self, options);
}

/// Display text for the parents a caller can read: one walk of
/// `folders.search` and one of `organizations.search`, both with no query,
/// every page of each. They share the project search's quota, and for most
/// people are a page each. A parent the caller cannot read is not in them,
/// and `ParentNames.label` gives its name instead. Meant to be cached with
/// the project list.
pub fn parentNames(self: *Client, options: types.ParentOptions) Error!types.Owned(types.ParentNames) {
    return walk.parents(self, options);
}

/// One project by id or number, from `projects.get`, which is strongly
/// consistent where search is not: for a project picked from a list that
/// may be stale, or typed in full before search shows it. Production
/// answers a project that does not exist, and one the caller cannot see,
/// with the same 403, `error.PermissionDenied`. A public project can be
/// read here though no search shows it.
pub fn getProject(self: *Client, id_or_number: []const u8) Error!types.Owned(types.Project) {
    rpc.begin(self);
    try self.checkProjectRef(id_or_number);
    var result: types.Owned(types.Project) = try .init(self.gpa);
    errdefer result.deinit();
    var response: std.heap.ArenaAllocator = .init(self.gpa);
    defer response.deinit();
    const path = try std.fmt.allocPrint(response.allocator(), "/v3/projects/{s}?prettyPrint=false", .{id_or_number});
    const body = try rpc.get(self, &response, path, false);
    var scratch: std.heap.ArenaAllocator = .init(self.gpa);
    defer scratch.deinit();
    result.value = codec.decodeProject(result.arena.allocator(), scratch.allocator(), body) catch |err|
        return rpc.decodeFailed(self, err, "project");
    return result;
}

/// The project's IAM policy, from `projects.getIamPolicy`, asked for as
/// version 3 so conditional bindings come back whole: what the project
/// grants, which every resource under it inherits. Takes the id or the
/// number. A policy with no condition is answered as version 1, whatever
/// was asked, as measured on 2026-10-23. Production answers a project that
/// does not exist, and one whose policy the caller may not read, with the
/// same 403, `error.PermissionDenied`, "(or it may not exist)" in
/// `Diagnostics`. Needs `resourcemanager.projects.getIamPolicy`; the
/// client's read-only scope serves it.
pub fn getProjectIamPolicy(self: *Client, id_or_number: []const u8) Error!types.Owned(core.iam.Policy) {
    rpc.begin(self);
    try self.checkProjectRef(id_or_number);
    var result: types.Owned(core.iam.Policy) = try .init(self.gpa);
    errdefer result.deinit();
    var response: std.heap.ArenaAllocator = .init(self.gpa);
    defer response.deinit();
    const path = try std.fmt.allocPrint(response.allocator(), "/v3/projects/{s}:getIamPolicy?prettyPrint=false", .{id_or_number});
    const body = try rpc.post(self, &response, path, "{\"options\":{\"requestedPolicyVersion\":3}}");
    result.value = core.iam.decode(result.arena.allocator(), body) catch |err|
        return rpc.decodeFailed(self, err, "IAM policy");
    return result;
}

/// Of `permissions`, those the caller holds on the project, from
/// `projects.testIamPermissions`, sorted by name as production answers
/// them. Any service's permissions can be asked of a project; 1 to 100 of
/// them, each once and none a wildcard, are checked before sending
/// (`error.InvalidArgument`). Production refuses a permission it does not
/// know with `error.InvalidArgument`, and answers a project that does not
/// exist with none held rather than an error: a diagnostic, not a check.
pub fn testProjectIamPermissions(self: *Client, id_or_number: []const u8, permissions: []const []const u8) Error!types.Owned([]const []const u8) {
    rpc.begin(self);
    try self.checkProjectRef(id_or_number);
    if (core.iam.permissionsProblem(permissions)) |problem| {
        if (self.diagnostics) |d| d.print("{s}", .{problem});
        return error.InvalidArgument;
    }
    var result: types.Owned([]const []const u8) = try .init(self.gpa);
    errdefer result.deinit();
    var response: std.heap.ArenaAllocator = .init(self.gpa);
    defer response.deinit();
    const a = response.allocator();
    const path = try std.fmt.allocPrint(a, "/v3/projects/{s}:testIamPermissions?prettyPrint=false", .{id_or_number});
    const body = try rpc.post(self, &response, path, try core.iam.encodePermissions(a, permissions));
    result.value = core.iam.decodePermissions(result.arena.allocator(), body) catch |err|
        return rpc.decodeFailed(self, err, "testIamPermissions answer");
    return result;
}

fn checkProjectRef(self: *Client, id_or_number: []const u8) Error!void {
    if (!validate.isProjectRef(id_or_number)) {
        if (self.diagnostics) |d| d.print("invalid project: expected a project number, or an id of lowercase letters, digits, '-', '.' and ':'", .{});
        return error.InvalidName;
    }
}

/// The last call's refusal for a disabled API or an unusable quota
/// project: the project charged and the link that fixes it, for a person
/// to read. Null after any other outcome. Valid until the next call.
pub fn lastConsumerRefusal(self: *const Client) ?types.ConsumerRefusal {
    const r = self.refusal orelse return null;
    const consumer = self.refusal_buf[0..r.consumer_len];
    return .{
        .reason = r.reason,
        .consumer = consumer,
        .link = if (r.link_len) |n| self.refusal_buf[r.consumer_len..][0..n] else null,
    };
}

/// Keeps a refusal's consumer, `prefix` then `consumer`, and its link.
pub fn setRefusal(self: *Client, reason: types.ConsumerRefusal.Reason, prefix: []const u8, consumer: []const u8, link: ?[]const u8) void {
    const consumer_len = @min(prefix.len + consumer.len, self.refusal_buf.len);
    var w: std.Io.Writer = .fixed(self.refusal_buf[0..consumer_len]);
    w.writeAll(prefix) catch {};
    w.writeAll(consumer) catch {};
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

fn testOptions(token: *test_util.FakeTokenProvider) Options {
    return .{ .token_provider = token.provider() };
}

test "init rejects bad options before allocating" {
    const gpa = testing.failing_allocator;
    var token: test_util.FakeTokenProvider = .{};
    var diag: Diagnostics = .{};
    var options = testOptions(&token);
    options.diagnostics = &diag;

    options.retry = .{ .max_attempts = 0 };
    try testing.expectError(error.InvalidOptions, Client.init(gpa, testing.io, options));
    try testing.expect(std.mem.indexOf(u8, diag.message(), "invalid retry policy") != null);
    options.retry = .{};

    options.user_agent = "agent\r\nX: y";
    try testing.expectError(error.InvalidOptions, Client.init(gpa, testing.io, options));
    try testing.expect(std.mem.indexOf(u8, diag.message(), "invalid user agent") != null);
    options.user_agent = "a";

    options.max_response_bytes = 0;
    try testing.expectError(error.InvalidOptions, Client.init(gpa, testing.io, options));
    try testing.expect(std.mem.indexOf(u8, diag.message(), "max_response_bytes") != null);
    options.max_response_bytes = 1;

    options.quota_project = .{ .project = "a b" };
    try testing.expectError(error.InvalidName, Client.init(gpa, testing.io, options));
    try testing.expect(std.mem.indexOf(u8, diag.message(), "invalid quota project") != null);
}

test "init: the endpoint is production's or the override; never plain http" {
    var token: test_util.FakeTokenProvider = .{};
    var client: Client = try .init(testing.allocator, testing.io, testOptions(&token));
    defer client.deinit();
    try testing.expectEqualStrings("https://cloudresourcemanager.googleapis.com", client.base_url);
    try testing.expectEqual(core.transport.default_max_response_bytes, client.http.?.max_response_bytes);
    try testing.expectEqual(.none, client.quota_project);

    var options = testOptions(&token);
    options.endpoint = "https://crm.test:8443/";
    options.max_response_bytes = 1 << 20;
    var other: Client = try .init(testing.allocator, testing.io, options);
    defer other.deinit();
    try testing.expectEqualStrings("https://crm.test:8443", other.base_url);
    try testing.expectEqual(1 << 20, other.http.?.max_response_bytes);

    var diag: Diagnostics = .{};
    options.diagnostics = &diag;
    options.endpoint = "http://proxy.internal:8080";
    try testing.expectError(error.InvalidEndpoint, Client.init(testing.allocator, testing.io, options));
    try testing.expect(std.mem.indexOf(u8, diag.message(), "must use https") != null);
    options.endpoint = "ftp://host";
    try testing.expectError(error.InvalidEndpoint, Client.init(testing.allocator, testing.io, options));
}

test "init copies the strings it keeps" {
    var token: test_util.FakeTokenProvider = .{};
    var agent = "agent/1".*;
    var quota = "billing-1".*;
    var client: Client = try .init(testing.allocator, testing.io, .{
        .user_agent = &agent,
        .token_provider = token.provider(),
        .quota_project = .{ .project = &quota },
    });
    defer client.deinit();
    @memset(&agent, 'x');
    @memset(&quota, 'x');
    try testing.expectEqualStrings("agent/1", client.user_agent);
    try testing.expectEqualStrings("billing-1", client.quota_project.project);
}

test "init: every allocation failure is OutOfMemory without leaks" {
    const Run = struct {
        fn run(gpa: Allocator) !void {
            var token: test_util.FakeTokenProvider = .{};
            var client: Client = try .init(gpa, testing.io, .{ .token_provider = token.provider(), .quota_project = .{ .project = "billing" } });
            client.deinit();
        }
    };
    try testing.checkAllAllocationFailures(test_util.no_grow_allocator, Run.run, .{});
}

test "searchProjects: a query it will not send is refused, unsent" {
    var h: test_util.Harness = undefined;
    try h.init(&.{}, .{});
    defer h.deinit();
    try testing.expectError(error.InvalidQuery, h.client.searchProjects(.{ .query = "a\nb" }));
    try testing.expect(std.mem.indexOf(u8, h.diag.message(), "control character") != null);
    try testing.expectError(error.InvalidQuery, h.client.searchProjects(.{ .query = test_util.repeat("a", validate.max_query_bytes + 1) }));
    var fits = try h.client.searchProjects(.{ .query = test_util.repeat("a", validate.max_query_bytes) });
    fits.deinit();
    try h.expectRequestCount(0);
}

test "quota project: none by default, the credentials' or a named one when asked" {
    const found: test_util.FakeTransport.Reply = .{ .respond = .{ .body = bodies.search_extractctl } };
    const got: test_util.FakeTransport.Reply = .{ .respond = .{ .body = bodies.get_extractctl } };
    var h: test_util.Harness = undefined;
    try h.init(&.{ found, got, got }, .{ .quota_project = "adc-project" });
    defer h.deinit();
    var s = try h.client.searchProjects(.{});
    defer s.deinit();
    var p = try s.page(null);
    p.deinit();
    // The credentials name one; none is sent.
    try testing.expectEqual(null, (try h.fake.request(0)).header("x-goog-user-project"));

    var creds: Client = try .init(testing.allocator, h.clock.io(), .{ .token_provider = h.token.provider(), .transport = h.fake.transport(), .quota_project = .from_credentials });
    defer creds.deinit();
    var one = try creds.getProject("extractctl");
    one.deinit();
    try testing.expectEqualStrings("adc-project", (try h.fake.request(1)).header("x-goog-user-project").?);

    var named: Client = try .init(testing.allocator, h.clock.io(), .{ .token_provider = h.token.provider(), .transport = h.fake.transport(), .quota_project = .{ .project = "82150720798" } });
    defer named.deinit();
    var two = try named.getProject("extractctl");
    two.deinit();
    try testing.expectEqualStrings("82150720798", (try h.fake.request(2)).header("x-goog-user-project").?);
}

test "consumer refusals: a quota project denied or missing, the API off, each with its project and link" {
    var h: test_util.Harness = undefined;
    try h.init(&.{
        .{ .respond = .{ .status = bodies.quota_project_denied_status, .body = bodies.quota_project_denied } },
        .{ .respond = .{ .status = bodies.quota_project_missing_status, .body = bodies.quota_project_missing } },
        // pgAdmin's report of 2025-04-16, as the REST body it renders.
        .{ .respond = .{ .status = 403, .body =
        \\{"error":{"code":403,"message":"Cloud Resource Manager API has not been used in project 706577269333 before or it is disabled. Enable it by visiting https://console.developers.google.com/apis/api/cloudresourcemanager.googleapis.com/overview?project=706577269333 then retry. If you enabled this API recently, wait a few minutes for the action to propagate to our systems and retry.","status":"PERMISSION_DENIED","details":[{"@type":"type.googleapis.com/google.rpc.ErrorInfo","reason":"SERVICE_DISABLED","domain":"googleapis.com","metadata":{"activationUrl":"https://console.developers.google.com/apis/api/cloudresourcemanager.googleapis.com/overview?project=706577269333","serviceTitle":"Cloud Resource Manager API","containerInfo":"706577269333","service":"cloudresourcemanager.googleapis.com","consumer":"projects/706577269333"}},{"@type":"type.googleapis.com/google.rpc.LocalizedMessage","locale":"en-US","message":"..."}]}}
        } },
        // The 2020 shape: a Help link, no ErrorInfo.
        .{ .respond = .{ .status = 403, .body =
        \\{"error":{"code":403,"message":"Cloud Resource Manager API has not been used in project 123456789012 before or it is disabled. Enable it by visiting https://console.developers.google.com/apis/api/cloudresourcemanager.googleapis.com/overview?project=123456789012 then retry. If you enabled this API recently, wait a few minutes for the action to propagate to our systems and retry.","status":"PERMISSION_DENIED","details":[{"@type":"type.googleapis.com/google.rpc.Help","links":[{"description":"Google developers console API activation","url":"https://console.developers.google.com/apis/api/cloudresourcemanager.googleapis.com/overview?project=123456789012"}]}]}}
        } },
        // Another domain's reason of the same name is not Google's own.
        .{ .respond = .{ .status = 403, .body =
        \\{"error":{"code":403,"message":"no","status":"PERMISSION_DENIED","details":[{"@type":"type.googleapis.com/google.rpc.ErrorInfo","reason":"SERVICE_DISABLED","domain":"example.com","metadata":{"consumer":"projects/1"}}]}}
        } },
        .{ .respond = .{ .status = bodies.get_missing_id_status, .body = bodies.get_missing_id } },
        .{ .respond = .{ .status = bodies.quota_project_denied_status, .body = bodies.quota_project_denied } },
        .{ .respond = .{ .body = bodies.search_extractctl } },
    }, .{});
    defer h.deinit();
    var s = try h.client.searchProjects(.{});
    defer s.deinit();

    try testing.expectError(error.QuotaProjectDenied, s.page(null));
    var r = h.client.lastConsumerRefusal().?;
    try testing.expectEqual(.quota_project_denied, r.reason);
    try testing.expectEqualStrings("projects/bigquery-public-data", r.consumer);
    try testing.expectEqualStrings("https://console.developers.google.com/iam-admin/iam?project=bigquery-public-data", r.link.?);
    try testing.expect(std.mem.startsWith(u8, h.diag.message(), "Caller does not have required permission to use project bigquery-public-data."));

    // Production answers a project that does not exist at 400.
    try testing.expectError(error.QuotaProjectDenied, s.page(null));
    r = h.client.lastConsumerRefusal().?;
    try testing.expectEqualStrings("projects/zigps-no-such-project-x", r.consumer);
    try testing.expectEqual(null, r.link);

    try testing.expectError(error.ServiceDisabled, s.page(null));
    r = h.client.lastConsumerRefusal().?;
    try testing.expectEqual(.service_disabled, r.reason);
    try testing.expectEqualStrings("projects/706577269333", r.consumer);
    try testing.expectEqualStrings("https://console.developers.google.com/apis/api/cloudresourcemanager.googleapis.com/overview?project=706577269333", r.link.?);

    try testing.expectError(error.ServiceDisabled, s.page(null));
    r = h.client.lastConsumerRefusal().?;
    try testing.expectEqualStrings("projects/123456789012", r.consumer);
    try testing.expectEqualStrings("https://console.developers.google.com/apis/api/cloudresourcemanager.googleapis.com/overview?project=123456789012", r.link.?);

    try testing.expectError(error.PermissionDenied, s.page(null));
    try testing.expectEqual(null, h.client.lastConsumerRefusal());
    try testing.expectError(error.PermissionDenied, h.client.getProject("zigps-no-such-project-x"));
    try testing.expectEqual(null, h.client.lastConsumerRefusal());

    // A refusal lasts until the next call, and a success clears it.
    try testing.expectError(error.QuotaProjectDenied, s.page(null));
    try testing.expect(h.client.lastConsumerRefusal() != null);
    var ok = try s.page(null);
    ok.deinit();
    try testing.expectEqual(null, h.client.lastConsumerRefusal());
}

test "consumer refusals: the old sentence with no project number after it is a plain refusal" {
    var h: test_util.Harness = undefined;
    try h.init(&.{.{ .respond = .{ .status = 403, .body =
        \\{"error":{"code":403,"message":"Cloud Resource Manager API has not been used in project my-project before or it is disabled.","status":"PERMISSION_DENIED"}}
    } }}, .{});
    defer h.deinit();
    try testing.expectError(error.PermissionDenied, h.client.getProject("extractctl"));
    try testing.expectEqual(null, h.client.lastConsumerRefusal());
}

test "setRefusal: a link that does not fit is left out, never cut" {
    var token: test_util.FakeTokenProvider = .{};
    var client: Client = try .init(testing.allocator, testing.io, testOptions(&token));
    defer client.deinit();
    client.setRefusal(.service_disabled, "projects/", "1", test_util.repeat("l", refusal_capacity));
    const r = client.lastConsumerRefusal().?;
    try testing.expectEqualStrings("projects/1", r.consumer);
    try testing.expectEqual(null, r.link);
    client.setRefusal(.service_disabled, "", test_util.repeat("c", refusal_capacity + 5), "x");
    try testing.expectEqual(refusal_capacity, client.lastConsumerRefusal().?.consumer.len);
    try testing.expectEqual(null, client.lastConsumerRefusal().?.link);
}

test "getProject: by id and by number, production's answers" {
    var h: test_util.Harness = undefined;
    try h.init(&.{
        .{ .respond = .{ .body = bodies.get_extractctl } },
        .{ .respond = .{ .body = bodies.get_extractctl } },
        .{ .respond = .{ .status = bodies.get_missing_number_status, .body = bodies.get_missing_number } },
        .{ .respond = .{ .status = bodies.get_malformed_status, .body = bodies.get_malformed } },
        .{ .respond = .{ .body = "{\"projectId\":\"a\"}" } },
    }, .{});
    defer h.deinit();
    var by_id = try h.client.getProject("extractctl");
    defer by_id.deinit();
    try h.expectRequest(0, .GET, "https://cloudresourcemanager.googleapis.com/v3/projects/extractctl?prettyPrint=false", null);
    try testing.expectEqual(82150720798, by_id.value.number);
    try testing.expect(by_id.value.update_time != null);
    var by_number = try h.client.getProject("82150720798");
    defer by_number.deinit();
    try h.expectRequest(1, .GET, "https://cloudresourcemanager.googleapis.com/v3/projects/82150720798?prettyPrint=false", null);
    try testing.expectEqualStrings("extractctl", by_number.value.project_id);

    try testing.expectError(error.PermissionDenied, h.client.getProject("1"));
    try testing.expect(std.mem.indexOf(u8, h.diag.message(), "(or it may not exist)") != null);
    // A name the server cannot read, sent only because it passed here.
    try testing.expectError(error.InvalidArgument, h.client.getProject("a..b"));
    try testing.expectError(error.InvalidResponse, h.client.getProject("a"));
    try testing.expect(std.mem.indexOf(u8, h.diag.message(), "project response") != null);
    try h.expectRequestCount(5);

    try testing.expectError(error.InvalidName, h.client.getProject("Bad_Id!"));
    try testing.expectError(error.InvalidName, h.client.getProject("a/b"));
    try testing.expect(std.mem.indexOf(u8, h.diag.message(), "invalid project") != null);
    try h.expectRequestCount(5);
}

test "getProject: every allocation failure is OutOfMemory without leaks" {
    const Run = struct {
        fn run(gpa: Allocator) !void {
            var fake: test_util.FakeTransport = .init(testing.allocator, &.{.{ .respond = .{ .body = bodies.get_public } }});
            defer fake.deinit();
            var clock: test_util.FakeClock = .{};
            var token: test_util.FakeTokenProvider = .{};
            var client = try Client.init(gpa, clock.io(), .{ .token_provider = token.provider(), .transport = fake.transport() });
            defer client.deinit();
            var p = try client.getProject("bigquery-public-data");
            p.deinit();
        }
    };
    try testing.checkAllAllocationFailures(test_util.no_grow_allocator, Run.run, .{});
}

test "getProjectIamPolicy: the version 3 request, production's policy, and its refusals" {
    var h: test_util.Harness = undefined;
    try h.init(&.{
        .{ .respond = .{ .body = bodies.iam_policy_extractctl } },
        .{ .respond = .{ .status = 503, .body = "{\"error\":{\"code\":503,\"status\":\"UNAVAILABLE\"}}" } },
        .{ .respond = .{ .body = bodies.iam_policy_extractctl } },
        .{ .respond = .{ .status = bodies.iam_policy_missing_status, .body = bodies.iam_policy_missing } },
        .{ .respond = .{ .status = bodies.iam_policy_scope_status, .body = bodies.iam_policy_scope } },
        .{ .respond = .{ .status = 400, .body = "{\"error\":{\"code\":400,\"message\":\"Fail to resolve resource 'projects/a..b'\",\"status\":\"INVALID_ARGUMENT\"}}" } },
        .{ .respond = .{ .body = "[]" } },
    }, .{ .retry = .{ .initial_backoff_ms = 1, .max_backoff_ms = 1 } });
    defer h.deinit();

    var policy = try h.client.getProjectIamPolicy("extractctl");
    defer policy.deinit();
    try h.expectRequest(0, .POST, "https://cloudresourcemanager.googleapis.com/v3/projects/extractctl:getIamPolicy?prettyPrint=false", "{\"options\":{\"requestedPolicyVersion\":3}}");
    try testing.expectEqualStrings("https://www.googleapis.com/auth/cloud-platform.read-only", h.token.firstScope());
    try testing.expectEqual(1, policy.value.version);
    try testing.expectEqualStrings("BwZeRiqaZf0=", policy.value.etag.?);
    try testing.expectEqual(31, policy.value.bindings.len);
    try testing.expect(policy.value.grants("roles/owner", "user:person2@example.com"));
    try testing.expect(policy.value.grants("roles/editor", "serviceAccount:ACCOUNT4@example-project.iam.gserviceaccount.com"));
    try testing.expect(!policy.value.grants("roles/owner", "serviceAccount:account4@example-project.iam.gserviceaccount.com"));
    try testing.expect(!policy.value.hasConditions());

    // By number, and a 503 is tried again: the POST changes nothing.
    var by_number = try h.client.getProjectIamPolicy("82150720798");
    defer by_number.deinit();
    try h.expectRequest(2, .POST, "https://cloudresourcemanager.googleapis.com/v3/projects/82150720798:getIamPolicy?prettyPrint=false", "{\"options\":{\"requestedPolicyVersion\":3}}");
    try testing.expectEqual(31, by_number.value.bindings.len);

    try testing.expectError(error.PermissionDenied, h.client.getProjectIamPolicy("zigps-nope-02667a"));
    try testing.expect(std.mem.indexOf(u8, h.diag.message(), "(or it may not exist)") != null);
    try testing.expectError(error.PermissionDenied, h.client.getProjectIamPolicy("extractctl"));
    try testing.expect(std.mem.indexOf(u8, h.diag.message(), "insufficient authentication scopes") != null);
    // A 400 is not tried again.
    try testing.expectError(error.InvalidArgument, h.client.getProjectIamPolicy("a..b"));
    try h.expectRequestCount(6);
    try testing.expectError(error.InvalidResponse, h.client.getProjectIamPolicy("extractctl"));
    try testing.expect(std.mem.indexOf(u8, h.diag.message(), "IAM policy response") != null);

    try testing.expectError(error.InvalidName, h.client.getProjectIamPolicy("Bad_Id!"));
    try testing.expectError(error.InvalidName, h.client.getProjectIamPolicy(""));
    try testing.expect(std.mem.indexOf(u8, h.diag.message(), "invalid project") != null);
    try h.expectRequestCount(7);
}

test "testProjectIamPermissions: the request, production's sorted answer, and the checks before sending" {
    var h: test_util.Harness = undefined;
    try h.init(&.{
        .{ .respond = .{ .body = bodies.iam_test_held } },
        .{ .respond = .{ .body = bodies.iam_test_other_service } },
        .{ .respond = .{ .body = bodies.iam_test_missing } },
        .{ .respond = .{ .status = bodies.iam_test_unknown_status, .body = bodies.iam_test_unknown } },
        .{ .respond = .{ .status = 503, .body = "{\"error\":{\"code\":503,\"status\":\"UNAVAILABLE\"}}" } },
        .{ .respond = .{ .body = bodies.iam_test_missing } },
        .{ .respond = .{ .body = "{\"permissions\":\"x\"}" } },
    }, .{ .retry = .{ .initial_backoff_ms = 1, .max_backoff_ms = 1 } });
    defer h.deinit();

    const asked = [_][]const u8{
        "resourcemanager.projects.get",          "resourcemanager.projects.getIamPolicy",
        "resourcemanager.projects.setIamPolicy", "resourcemanager.projects.delete",
        "run.services.create",                   "storage.buckets.create",
        "pubsub.topics.create",
    };
    var held = try h.client.testProjectIamPermissions("extractctl", &asked);
    defer held.deinit();
    try h.expectRequest(0, .POST, "https://cloudresourcemanager.googleapis.com/v3/projects/extractctl:testIamPermissions?prettyPrint=false", "{\"permissions\":[\"resourcemanager.projects.get\",\"resourcemanager.projects.getIamPolicy\",\"resourcemanager.projects.setIamPolicy\",\"resourcemanager.projects.delete\",\"run.services.create\",\"storage.buckets.create\",\"pubsub.topics.create\"]}");
    // Sorted by name, as production answers, not in the order asked.
    const want = [_][]const u8{ "pubsub.topics.create", "resourcemanager.projects.get", "resourcemanager.projects.getIamPolicy", "run.services.create", "storage.buckets.create" };
    try testing.expectEqual(want.len, held.value.len);
    for (want, held.value) |w, g| try testing.expectEqualStrings(w, g);

    var other = try h.client.testProjectIamPermissions("extractctl", &.{ "pubsub.topics.get", "bigquery.datasets.get" });
    defer other.deinit();
    try testing.expectEqualStrings("bigquery.datasets.get", other.value[0]);
    try testing.expectEqualStrings("pubsub.topics.get", other.value[1]);

    // A project that does not exist holds nothing, and is not an error.
    var missing = try h.client.testProjectIamPermissions("zigps-nope-02667a", &.{"resourcemanager.projects.get"});
    defer missing.deinit();
    try testing.expectEqual(0, missing.value.len);

    try testing.expectError(error.InvalidArgument, h.client.testProjectIamPermissions("extractctl", &.{"zigps.probe.get"}));
    try testing.expectEqualStrings("Permission zigps.probe.get is not valid for this resource.", h.diag.message());

    var retried = try h.client.testProjectIamPermissions("extractctl", &.{"resourcemanager.projects.get"});
    retried.deinit();
    try h.expectRequestCount(6);
    try testing.expectError(error.InvalidResponse, h.client.testProjectIamPermissions("extractctl", &.{"resourcemanager.projects.get"}));
    try testing.expect(std.mem.indexOf(u8, h.diag.message(), "testIamPermissions answer") != null);
    try h.expectRequestCount(7);

    // Refused before sending: production's limit of 100, none twice, no
    // wildcard, at least one, and a project name it could read.
    var many: [101][]const u8 = undefined;
    var names_buf: [101][24]u8 = undefined;
    for (&many, &names_buf, 0..) |*m, *buf, i| m.* = try std.fmt.bufPrint(buf, "storage.buckets.get{d}", .{i});
    try testing.expectError(error.InvalidArgument, h.client.testProjectIamPermissions("extractctl", &many));
    try testing.expectEqualStrings("at most 100 permissions in one test", h.diag.message());
    try testing.expectError(error.InvalidArgument, h.client.testProjectIamPermissions("extractctl", &.{}));
    try testing.expectError(error.InvalidArgument, h.client.testProjectIamPermissions("extractctl", &.{ "a.b.c", "a.b.c" }));
    try testing.expectError(error.InvalidArgument, h.client.testProjectIamPermissions("extractctl", &.{"resourcemanager.projects.*"}));
    try testing.expectError(error.InvalidName, h.client.testProjectIamPermissions("Bad_Id!", &.{"resourcemanager.projects.get"}));
    try h.expectRequestCount(7);
}

test "getProjectIamPolicy and testProjectIamPermissions: every allocation failure is OutOfMemory without leaks" {
    const Run = struct {
        fn run(gpa: Allocator) !void {
            var fake: test_util.FakeTransport = .init(testing.allocator, &.{
                .{ .respond = .{ .body = bodies.iam_policy_extractctl } },
                .{ .respond = .{ .body = bodies.iam_test_held } },
            });
            defer fake.deinit();
            var clock: test_util.FakeClock = .{};
            var token: test_util.FakeTokenProvider = .{};
            var client = try Client.init(gpa, clock.io(), .{ .token_provider = token.provider(), .transport = fake.transport() });
            defer client.deinit();
            var p = try client.getProjectIamPolicy("extractctl");
            p.deinit();
            var t = try client.testProjectIamPermissions("extractctl", &.{ "resourcemanager.projects.get", "run.services.create" });
            t.deinit();
        }
    };
    try testing.checkAllAllocationFailures(test_util.no_grow_allocator, Run.run, .{});
}
