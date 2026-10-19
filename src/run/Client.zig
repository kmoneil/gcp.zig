//! A Cloud Run client, read only: the locations services live in, the
//! services with their traffic and conditions, the revisions with their
//! create times and readiness. Nothing here deploys, routes traffic or
//! deletes anything.
//!
//! Every call blocks the calling task until it completes, using the
//! `std.Io` and allocator passed to `init`. A client must not be used from
//! two tasks at once; give each task its own.

const Client = @This();

const std = @import("std");
const Allocator = std.mem.Allocator;
const core = @import("core");

const codec = @import("codec.zig");
const errors = @import("errors.zig");
const names = @import("names.zig");
const rpc = @import("rpc.zig");
const types = @import("types.zig");
const validate = @import("validate.zig");
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
/// Owned copy of `Options.project_id`.
project: []const u8,
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
/// The delay the last refused attempt asked for, kept by the engine.
server_delay_ms: ?u32 = null,

pub const default_endpoint = "https://run.googleapis.com";

pub const Options = struct {
    /// Required: the project whose services are read, an id or a number.
    project_id: []const u8,
    /// Required. Cloud Run has no emulator, so there is no
    /// unauthenticated mode.
    token_provider: TokenProvider,
    /// Overrides the host: a test server, say. Must be `https`, since it
    /// receives credentials.
    endpoint: ?[]const u8 = null,
    /// Sends the credentials' quota project as `x-goog-user-project`, as
    /// every module does.
    send_quota_project: bool = true,
    /// Every call here is a GET: 5xx, 429 and dropped connections are
    /// retried.
    retry: RetryPolicy = .{},
    /// How long one request may take before it is `error.TimedOut`, which
    /// is retried. 0 removes the limit.
    request_timeout_ms: u32 = 30_000,
    /// A response whose decompressed body is larger fails with
    /// `error.ResponseTooLarge`. Used by the built-in transport; a
    /// transport passed in keeps its own limit.
    max_response_bytes: usize = core.transport.default_max_response_bytes,
    /// Printable ASCII.
    user_agent: []const u8 = "zig-gcp-run/0.48",
    /// Filled with details of every failed call; cleared by each new call.
    diagnostics: ?*Diagnostics = null,
    /// Sends requests through this instead of `std.http.Client`. Useful
    /// for tests, including tests of code that uses this library.
    transport: ?Transport = null,
};

/// Copies what it keeps from `options`; nothing borrowed outlives the call
/// except `diagnostics`, the token provider and the transport.
pub fn init(gpa: Allocator, io: std.Io, options: Options) Error!Client {
    const diag = options.diagnostics;
    if (diag) |d| d.clear();
    if (!core.names.isProjectId(options.project_id)) {
        if (diag) |d| d.print("invalid project: expected a project id or number", .{});
        return error.InvalidName;
    }
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

    const base_url = core.endpoint.baseUrl(gpa, options.endpoint orelse default_endpoint, .https) catch |err| {
        if (err == error.InvalidEndpoint) if (diag) |d| d.print("invalid endpoint: expected https://host[:port]", .{});
        return err;
    };
    errdefer gpa.free(base_url);
    // Every request carries a bearer token, which must not travel in
    // cleartext.
    if (!std.mem.startsWith(u8, base_url, "https://")) {
        if (diag) |d| d.print("invalid endpoint: endpoints that receive credentials must use https", .{});
        return error.InvalidEndpoint;
    }
    const project = try gpa.dupe(u8, options.project_id);
    errdefer gpa.free(project);
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
        .project = project,
        .send_quota_project = options.send_quota_project,
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
    self.gpa.free(self.project);
    self.gpa.free(self.user_agent);
    self.gpa.free(self.base_url);
    self.* = undefined;
}

/// One page of the locations services can live in, through v1's list:
/// v2 has none, and v1 answers on the same host (measured 2026-10-19,
/// 43 locations).
pub fn listLocations(self: *Client, options: types.ListOptions) Error!types.Owned(types.LocationPage) {
    rpc.begin(self);
    try self.checkToken(options.page_token);
    var scratch: std.heap.ArenaAllocator = .init(self.gpa);
    defer scratch.deinit();
    const a = scratch.allocator();
    var w: std.Io.Writer.Allocating = .init(a);
    w.writer.writeAll(names.locations(a, self.project) catch return error.OutOfMemory) catch return error.OutOfMemory;
    var params: core.query.Params = .init(&w.writer);
    params.addNonZero("pageSize", options.page_size) catch return error.OutOfMemory;
    params.addOptional("pageToken", options.page_token) catch return error.OutOfMemory;

    var result: types.Owned(types.LocationPage) = try .init(self.gpa);
    errdefer result.deinit();
    const body = try rpc.execute(self, result.arena, .{ .method = .GET, .path = w.written() });
    result.value = codec.decodeLocationPage(result.arena.allocator(), a, body) catch |err|
        return rpc.decodeFailed(self, err, "location list");
    return result;
}

/// One page of a location's services. The location may be `-`, every
/// region at once: production answers it (though its documentation says
/// otherwise), with `unreachable_regions` for the regions it could not
/// ask.
pub fn listServices(self: *Client, location: []const u8, options: types.ListOptions) Error!types.Owned(types.ServicePage) {
    rpc.begin(self);
    if (!validate.isLocation(location)) {
        if (self.diagnostics) |d| d.print("invalid location: expected a region id such as us-central1, or -", .{});
        return error.InvalidName;
    }
    try self.checkToken(options.page_token);
    var scratch: std.heap.ArenaAllocator = .init(self.gpa);
    defer scratch.deinit();
    const a = scratch.allocator();
    var w: std.Io.Writer.Allocating = .init(a);
    w.writer.writeAll(names.services(a, self.project, location) catch return error.OutOfMemory) catch return error.OutOfMemory;
    var params: core.query.Params = .init(&w.writer);
    params.addNonZero("pageSize", options.page_size) catch return error.OutOfMemory;
    params.addOptional("pageToken", options.page_token) catch return error.OutOfMemory;

    var result: types.Owned(types.ServicePage) = try .init(self.gpa);
    errdefer result.deinit();
    const body = try rpc.execute(self, result.arena, .{ .method = .GET, .path = w.written() });
    result.value = codec.decodeServicePage(result.arena.allocator(), a, body) catch |err|
        return rpc.decodeFailed(self, err, "service list");
    return result;
}

/// One service, by its location and id.
pub fn getService(self: *Client, location: []const u8, id: []const u8) Error!types.Owned(types.Service) {
    rpc.begin(self);
    return self.getServiceChecked(location, id);
}

/// One service, by its full `projects/P/locations/L/services/S` name.
/// Another project's name is refused before sending.
pub fn getServiceNamed(self: *Client, name: []const u8) Error!types.Owned(types.Service) {
    rpc.begin(self);
    const parsed = names.serviceName(name, self.project) orelse {
        if (self.diagnostics) |d| d.print("invalid service name: expected projects/{s}/locations/<location>/services/<id>", .{self.project});
        return error.InvalidName;
    };
    return self.getServiceChecked(parsed.location, parsed.id);
}

fn getServiceChecked(self: *Client, location: []const u8, id: []const u8) Error!types.Owned(types.Service) {
    try self.checkLocationAndId(location, id);
    var scratch: std.heap.ArenaAllocator = .init(self.gpa);
    defer scratch.deinit();
    const a = scratch.allocator();
    const path = try names.service(a, self.project, location, id);
    var result: types.Owned(types.Service) = try .init(self.gpa);
    errdefer result.deinit();
    const body = try rpc.execute(self, result.arena, .{ .method = .GET, .path = path });
    result.value = codec.decodeService(result.arena.allocator(), a, body) catch |err|
        return rpc.decodeFailed(self, err, "service");
    return result;
}

/// One page of a service's revisions, newest first as production answers
/// them. The service may be `-`, every service in the location at once,
/// which Cloud Run documents and production answered.
pub fn listRevisions(self: *Client, location: []const u8, service_id: []const u8, options: types.ListOptions) Error!types.Owned(types.RevisionPage) {
    rpc.begin(self);
    try self.checkLocationAndId(location, service_id);
    try self.checkToken(options.page_token);
    var scratch: std.heap.ArenaAllocator = .init(self.gpa);
    defer scratch.deinit();
    const a = scratch.allocator();
    var w: std.Io.Writer.Allocating = .init(a);
    w.writer.writeAll(names.revisions(a, self.project, location, service_id) catch return error.OutOfMemory) catch return error.OutOfMemory;
    var params: core.query.Params = .init(&w.writer);
    params.addNonZero("pageSize", options.page_size) catch return error.OutOfMemory;
    params.addOptional("pageToken", options.page_token) catch return error.OutOfMemory;

    var result: types.Owned(types.RevisionPage) = try .init(self.gpa);
    errdefer result.deinit();
    const body = try rpc.execute(self, result.arena, .{ .method = .GET, .path = w.written() });
    result.value = codec.decodeRevisionPage(result.arena.allocator(), a, body) catch |err|
        return rpc.decodeFailed(self, err, "revision list");
    return result;
}

/// One revision, by its location, service and id.
pub fn getRevision(self: *Client, location: []const u8, service_id: []const u8, id: []const u8) Error!types.Owned(types.Revision) {
    rpc.begin(self);
    return self.getRevisionChecked(location, service_id, id);
}

/// One revision, by its full name. Another project's name is refused
/// before sending.
pub fn getRevisionNamed(self: *Client, name: []const u8) Error!types.Owned(types.Revision) {
    rpc.begin(self);
    const parsed = names.revisionName(name, self.project) orelse {
        if (self.diagnostics) |d| d.print("invalid revision name: expected projects/{s}/locations/<location>/services/<service>/revisions/<id>", .{self.project});
        return error.InvalidName;
    };
    return self.getRevisionChecked(parsed.location, parsed.service, parsed.id);
}

fn getRevisionChecked(self: *Client, location: []const u8, service_id: []const u8, id: []const u8) Error!types.Owned(types.Revision) {
    try self.checkLocationAndId(location, service_id);
    if (!validate.isResourceId(id)) {
        if (self.diagnostics) |d| d.print("invalid revision id: visible ASCII without /, at most 500", .{});
        return error.InvalidName;
    }
    var scratch: std.heap.ArenaAllocator = .init(self.gpa);
    defer scratch.deinit();
    const a = scratch.allocator();
    const path = try names.revision(a, self.project, location, service_id, id);
    var result: types.Owned(types.Revision) = try .init(self.gpa);
    errdefer result.deinit();
    const body = try rpc.execute(self, result.arena, .{ .method = .GET, .path = path });
    result.value = codec.decodeRevision(result.arena.allocator(), a, body) catch |err|
        return rpc.decodeFailed(self, err, "revision");
    return result;
}

fn checkLocationAndId(self: *Client, location: []const u8, id: []const u8) Error!void {
    if (!validate.isLocation(location)) {
        if (self.diagnostics) |d| d.print("invalid location: expected a region id such as us-central1, or -", .{});
        return error.InvalidName;
    }
    if (!validate.isResourceId(id)) {
        if (self.diagnostics) |d| d.print("invalid service id: visible ASCII without /, at most 500", .{});
        return error.InvalidName;
    }
}

fn checkToken(self: *Client, token: ?[]const u8) Error!void {
    if (token) |t| if (!validate.isPageToken(t)) {
        if (self.diagnostics) |d| d.print("invalid page token: expected printable ASCII", .{});
        return error.InvalidName;
    };
}

const testing = std.testing;
const test_util = @import("test_util.zig");
const Harness = test_util.Harness;
const production = @import("production_bodies.zig");

test "golden: locations, services and revisions listed and got, by parts and by name" {
    var h: Harness = undefined;
    try h.init(&.{
        .{ .respond = .{ .body = production.locations_v1 } },
        .{ .respond = .{ .body = production.services_list } },
        .{ .respond = .{ .body = production.services_dash } },
        .{ .respond = .{ .body = production.service_ready } },
        .{ .respond = .{ .body = production.revisions_failed } },
        .{ .respond = .{ .body = production.revision_ready } },
    });
    defer h.deinit();

    var locations = try h.client.listLocations(.{ .page_size = 100 });
    defer locations.deinit();
    try h.expectRequest(0, .GET, "https://run.googleapis.com/v1/projects/my-project/locations?pageSize=100");
    try testing.expectEqual(3, locations.value.locations.len);

    var services = try h.client.listServices("us-central1", .{ .page_size = 2, .page_token = "t" });
    defer services.deinit();
    try h.expectRequest(1, .GET, "https://run.googleapis.com/v2/projects/my-project/locations/us-central1/services?pageSize=2&pageToken=t");
    try testing.expectEqual(1, services.value.services.len);

    var everywhere = try h.client.listServices("-", .{});
    defer everywhere.deinit();
    try h.expectRequest(2, .GET, "https://run.googleapis.com/v2/projects/my-project/locations/-/services");
    try testing.expectEqual(5, everywhere.value.unreachable_regions.len);

    var service = try h.client.getServiceNamed("projects/my-project/locations/us-central1/services/zigps-a12c61");
    defer service.deinit();
    try h.expectRequest(3, .GET, "https://run.googleapis.com/v2/projects/my-project/locations/us-central1/services/zigps-a12c61");
    try testing.expect(service.value.ready());

    var revisions = try h.client.listRevisions("us-central1", "-", .{});
    defer revisions.deinit();
    try h.expectRequest(4, .GET, "https://run.googleapis.com/v2/projects/my-project/locations/us-central1/services/-/revisions");
    try testing.expectEqual(2, revisions.value.revisions.len);

    var revision = try h.client.getRevision("us-central1", "zigps-a12c61", "zigps-a12c61-00001-ct8");
    defer revision.deinit();
    try h.expectRequest(5, .GET, "https://run.googleapis.com/v2/projects/my-project/locations/us-central1/services/zigps-a12c61/revisions/zigps-a12c61-00001-ct8");
    try testing.expect(revision.value.ready());
}

test "the calls refuse what they will not send" {
    var h: Harness = undefined;
    try h.init(&.{});
    defer h.deinit();
    const c = &h.client;
    try testing.expectError(error.InvalidName, c.listServices("US-central1", .{}));
    try testing.expectError(error.InvalidName, c.listServices("", .{}));
    try testing.expectError(error.InvalidName, c.listServices("us-central1", .{ .page_token = "a b" }));
    try testing.expectError(error.InvalidName, c.listLocations(.{ .page_token = "" }));
    try testing.expectError(error.InvalidName, c.getService("us-central1", "a/b"));
    try testing.expectError(error.InvalidName, c.getServiceNamed("projects/other/locations/l/services/s"));
    try testing.expectError(error.InvalidName, c.listRevisions("us central1", "-", .{}));
    try testing.expectError(error.InvalidName, c.getRevision("us-central1", "s", "a b"));
    try testing.expectError(error.InvalidName, c.getRevisionNamed("projects/my-project/locations/l/services/s"));
    try testing.expectEqualStrings("invalid revision name: expected projects/my-project/locations/<location>/services/<service>/revisions/<id>", h.diag.message());
    try h.expectRequestCount(0);
}

test "a response that cannot be decoded is InvalidResponse, named in Diagnostics" {
    var h: Harness = undefined;
    try h.init(&.{
        .{ .respond = .{ .body = "{\"services\":1}" } },
        .{ .respond = .{ .body = "{\"uri\":\"u\"}" } },
        .{ .respond = .{ .body = "{\"revisions\":[{}]}" } },
        .{ .respond = .{ .body = "[]" } },
        .{ .respond = .{ .body = "{\"locations\":[{}]}" } },
    });
    defer h.deinit();
    try testing.expectError(error.InvalidResponse, h.client.listServices("us-central1", .{}));
    try testing.expectEqualStrings("the service list response could not be decoded", h.diag.message());
    try testing.expectError(error.InvalidResponse, h.client.getService("us-central1", "s"));
    try testing.expectEqualStrings("the service response could not be decoded", h.diag.message());
    try testing.expectError(error.InvalidResponse, h.client.listRevisions("us-central1", "s", .{}));
    try testing.expectError(error.InvalidResponse, h.client.getRevision("us-central1", "s", "r"));
    try testing.expectEqualStrings("the revision response could not be decoded", h.diag.message());
    try testing.expectError(error.InvalidResponse, h.client.listLocations(.{}));
}

test "the server's refusals arrive as errors, production's words kept" {
    var h: Harness = undefined;
    try h.init(&.{
        .{ .respond = .{ .status = production.service_unknown_status, .body = production.service_unknown } },
        .{ .respond = .{ .status = production.location_bogus_status, .body = production.location_bogus } },
    });
    defer h.deinit();
    try testing.expectError(error.NotFound, h.client.getService("us-central1", "zigps-nobody"));
    try testing.expectError(error.InvalidArgument, h.client.listServices("us-fake1", .{}));
    try testing.expectEqualStrings("The request has errors", h.diag.message());
}

test "init refuses what no call could use" {
    var tokens: test_util.FakeTokenProvider = .{};
    var clock: test_util.FakeClock = .{};
    var diag: core.Diagnostics = .{};
    try testing.expectError(error.InvalidName, Client.init(testing.allocator, clock.io(), .{ .project_id = "", .token_provider = tokens.provider(), .diagnostics = &diag }));
    try testing.expectError(error.InvalidOptions, Client.init(testing.allocator, clock.io(), .{ .project_id = "p", .token_provider = tokens.provider(), .user_agent = "a\nb", .diagnostics = &diag }));
    try testing.expectError(error.InvalidOptions, Client.init(testing.allocator, clock.io(), .{ .project_id = "p", .token_provider = tokens.provider(), .retry = .{ .max_attempts = 0 }, .diagnostics = &diag }));
    try testing.expectError(error.InvalidOptions, Client.init(testing.allocator, clock.io(), .{ .project_id = "p", .token_provider = tokens.provider(), .max_response_bytes = 0, .diagnostics = &diag }));
    try testing.expectError(error.InvalidEndpoint, Client.init(testing.allocator, clock.io(), .{ .project_id = "p", .token_provider = tokens.provider(), .endpoint = "http://plain", .diagnostics = &diag }));
}

test "every allocation failure is OutOfMemory without leaks" {
    const Run = struct {
        fn calls(gpa: Allocator) !void {
            var fake: test_util.FakeTransport = .init(testing.allocator, &.{
                .{ .respond = .{ .body = production.locations_v1 } },
                .{ .respond = .{ .body = production.services_list } },
                .{ .respond = .{ .body = production.service_failed } },
                .{ .respond = .{ .body = production.revisions_failed } },
                .{ .respond = .{ .body = production.revision_ready } },
            });
            defer fake.deinit();
            var tokens: test_util.FakeTokenProvider = .{};
            var clock: test_util.FakeClock = .{};
            var client = try Client.init(gpa, clock.io(), .{ .project_id = "my-project", .token_provider = tokens.provider(), .transport = fake.transport() });
            defer client.deinit();
            var locations = try client.listLocations(.{});
            locations.deinit();
            var services = try client.listServices("us-central1", .{ .page_token = "t" });
            services.deinit();
            var service = try client.getService("us-central1", "zigps-a12c61");
            service.deinit();
            var revisions = try client.listRevisions("us-central1", "-", .{});
            revisions.deinit();
            var revision = try client.getRevisionNamed("projects/my-project/locations/us-central1/services/zigps-a12c61/revisions/zigps-a12c61-00001-ct8");
            revision.deinit();
        }
    };
    try testing.checkAllAllocationFailures(test_util.no_grow_allocator, Run.calls, .{});
}
