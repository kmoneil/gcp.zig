//! A Service Usage client, read only: the services a project has enabled,
//! and whether one service, or up to 30 at once, is enabled.
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
scope: rpc.Scope,
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

pub const default_endpoint = "https://serviceusage.googleapis.com";

pub const Options = struct {
    /// Required: the project whose services are read, an id or a number.
    /// Production takes either and answers with the number (measured).
    project_id: []const u8,
    /// Required. Service Usage has no emulator, so there is no
    /// unauthenticated mode.
    token_provider: TokenProvider,
    /// `cloud-platform.read-only` by default; either reads everything.
    scope: rpc.Scope = .read_only,
    /// Overrides the host: a test server, say. Must be `https`, since it
    /// receives credentials.
    endpoint: ?[]const u8 = null,
    /// Sends the credentials' quota project as `x-goog-user-project`, as
    /// every module does.
    send_quota_project: bool = true,
    /// Every call is a read, retried on 5xx, 429 and dropped connections.
    /// Production's quotas are per project and per minute: 600 gets and
    /// enabled lists, and 60 of the other lists (measured).
    retry: RetryPolicy = .{},
    /// How long one request may take before it is `error.TimedOut`, which
    /// is retried. 0 removes the limit.
    request_timeout_ms: u32 = 30_000,
    /// A response whose decompressed body is larger fails with
    /// `error.ResponseTooLarge`. Every answer is small under the client's
    /// fields masks (45 enabled services were 14 KB, measured). Used by the
    /// built-in transport; a transport passed in keeps its own limit.
    max_response_bytes: usize = core.transport.default_max_response_bytes,
    /// Printable ASCII.
    user_agent: []const u8 = "gcp-zig-service_usage/0.69",
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
    try checkOptions(options);
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
        .scope = options.scope,
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

fn checkOptions(options: Options) Error!void {
    const diag = options.diagnostics;
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

/// One page of the project's services, in name order: the enabled ones
/// unless `options.state` says otherwise. For every enabled one at once,
/// `enabledServices`.
pub fn listServices(self: *Client, options: types.ListServicesOptions) Error!types.Owned(types.ServicePage) {
    rpc.begin(self);
    if (options.page_size > validate.max_page_size) {
        if (self.diagnostics) |d| d.print("invalid page_size: the server refuses more than {d}", .{validate.max_page_size});
        return error.InvalidOptions;
    }
    if (options.page_token) |t| if (!validate.isPageToken(t)) {
        if (self.diagnostics) |d| d.print("invalid page token: expected printable ASCII", .{});
        return error.InvalidName;
    };
    var scratch: std.heap.ArenaAllocator = .init(self.gpa);
    defer scratch.deinit();
    const a = scratch.allocator();
    var w: std.Io.Writer.Allocating = .init(a);
    self.writeProject(&w.writer, "/services") catch return error.OutOfMemory;
    var params: core.query.Params = .init(&w.writer);
    params.addOptional("filter", options.state.wire()) catch return error.OutOfMemory;
    params.addNonZero("pageSize", options.page_size) catch return error.OutOfMemory;
    params.addOptional("pageToken", options.page_token) catch return error.OutOfMemory;
    finish(&params, codec.list_fields) catch return error.OutOfMemory;
    return self.call(types.ServicePage, a, w.written(), codec.decodeServicePage, "service list");
}

/// Every service enabled in the project, in name order, read a page of
/// 200 at a time (45 were one page when measured).
pub fn enabledServices(self: *Client) Error!types.Owned([]const types.Service) {
    var result: types.Owned([]const types.Service) = try .init(self.gpa);
    errdefer result.deinit();
    const out = result.arena.allocator();
    var all: std.ArrayList(types.Service) = .empty;
    var token_buf: std.ArrayList(u8) = .empty;
    defer token_buf.deinit(self.gpa);
    var token: ?[]const u8 = null;
    while (true) {
        var page = try self.listServices(.{ .page_size = validate.max_page_size, .page_token = token });
        defer page.deinit();
        for (page.value.services) |s| try all.append(out, try copyService(out, s));
        const next = page.value.next_page_token orelse break;
        if (token) |t| if (std.mem.eql(u8, t, next)) {
            if (self.diagnostics) |d| d.print("the service list answered the same page token twice", .{});
            return error.InvalidResponse;
        };
        token_buf.clearRetainingCapacity();
        try token_buf.appendSlice(self.gpa, next);
        token = token_buf.items;
    }
    result.value = all.items;
    return result;
}

fn copyService(out: Allocator, s: types.Service) Allocator.Error!types.Service {
    return .{
        .name = try out.dupe(u8, s.name),
        .title = try out.dupe(u8, s.title),
        .summary = try out.dupe(u8, s.summary),
        .state = s.state,
        .project_number = try out.dupe(u8, s.project_number),
    };
}

/// One service and whether it is enabled in the project, by its name such
/// as `pubsub.googleapis.com`. A service production does not know, or
/// will not show, is `error.PermissionDenied` ("Not found or permission
/// denied for service(s): ...", measured). A disabled one is answered, as
/// `.disabled`: what a panel that says an API is off asks.
pub fn getService(self: *Client, name: []const u8) Error!types.Owned(types.Service) {
    rpc.begin(self);
    try self.checkName(name, null);
    var scratch: std.heap.ArenaAllocator = .init(self.gpa);
    defer scratch.deinit();
    const a = scratch.allocator();
    var w: std.Io.Writer.Allocating = .init(a);
    self.writeProject(&w.writer, "/services/") catch return error.OutOfMemory;
    w.writer.writeAll(name) catch return error.OutOfMemory;
    var params: core.query.Params = .init(&w.writer);
    finish(&params, codec.service_fields) catch return error.OutOfMemory;
    return self.call(types.Service, a, w.written(), codec.decodeService, "service");
}

/// 1 to 30 services at once, in the order asked, a name asked twice
/// answered twice (measured). One that production does not know fails
/// them all, `error.PermissionDenied`, its message naming the first such.
pub fn getServices(self: *Client, names: []const []const u8) Error!types.Owned([]const types.Service) {
    rpc.begin(self);
    if (names.len == 0 or names.len > validate.max_batch) {
        if (self.diagnostics) |d| d.print("invalid names: getServices takes 1 to {d}, and was given {d}", .{ validate.max_batch, names.len });
        return error.InvalidOptions;
    }
    for (names, 0..) |name, i| try self.checkName(name, i);
    var scratch: std.heap.ArenaAllocator = .init(self.gpa);
    defer scratch.deinit();
    const a = scratch.allocator();
    var w: std.Io.Writer.Allocating = .init(a);
    self.writeProject(&w.writer, "/services:batchGet") catch return error.OutOfMemory;
    var params: core.query.Params = .init(&w.writer);
    var full: std.Io.Writer.Allocating = .init(a);
    for (names) |name| {
        full.clearRetainingCapacity();
        full.writer.print("projects/{s}/services/{s}", .{ self.project, name }) catch return error.OutOfMemory;
        params.add("names", full.written()) catch return error.OutOfMemory;
    }
    finish(&params, codec.batch_fields) catch return error.OutOfMemory;
    return self.call([]const types.Service, a, w.written(), codec.decodeServices, "service batch");
}

/// `/v1/projects/{project}` and `rest`.
fn writeProject(self: *Client, w: *std.Io.Writer, rest: []const u8) std.Io.Writer.Error!void {
    try w.writeAll("/v1/projects/");
    try core.query.writeSegment(w, self.project);
    try w.writeAll(rest);
}

/// The fields mask, then `prettyPrint=false`, which every call ends with.
fn finish(params: *core.query.Params, fields: []const u8) std.Io.Writer.Error!void {
    try params.add("fields", fields);
    try params.add("prettyPrint", "false");
}

fn checkName(self: *Client, name: []const u8, index: ?usize) Error!void {
    const problem = validate.serviceNameProblem(name) orelse return;
    if (self.diagnostics) |d| {
        var buf: [256]u8 = undefined;
        var w: std.Io.Writer = .fixed(&buf);
        if (index) |i| {
            w.print("invalid service name names[{d}]: ", .{i}) catch {};
        } else {
            w.writeAll("invalid service name: ") catch {};
        }
        validate.describe(&w, problem) catch {};
        d.print("{s}", .{w.buffered()});
    }
    return error.InvalidName;
}

/// Sends a GET of `path` and decodes its answer with `decode`.
fn call(
    self: *Client,
    comptime T: type,
    scratch: Allocator,
    path: []const u8,
    comptime decode: fn (Allocator, Allocator, []const u8) codec.DecodeError!T,
    what: []const u8,
) Error!types.Owned(T) {
    var result: types.Owned(T) = try .init(self.gpa);
    errdefer result.deinit();
    const body = try rpc.execute(self, result.arena, .{ .method = .GET, .path = path });
    result.value = decode(result.arena.allocator(), scratch, body) catch |err|
        return rpc.decodeFailed(self, err, what);
    return result;
}

const testing = std.testing;
const test_util = @import("test_util.zig");
const Harness = test_util.Harness;
const production = @import("production_bodies.zig");
const base = "https://serviceusage.googleapis.com/v1/projects/my-project/services";
const list_mask = "fields=services%28name%2Cconfig%28name%2Ctitle%2Cdocumentation%2Fsummary%29%2Cstate%29%2CnextPageToken&prettyPrint=false";
const get_mask = "fields=name%2Cconfig%28name%2Ctitle%2Cdocumentation%2Fsummary%29%2Cstate&prettyPrint=false";
const batch_mask = "fields=services%28name%2Cconfig%28name%2Ctitle%2Cdocumentation%2Fsummary%29%2Cstate%29&prettyPrint=false";

test "golden: lists, gets and a batch, as the probe asked production" {
    var h: Harness = undefined;
    try h.init(&.{
        .{ .respond = .{ .body = production.list_enabled_page } },
        .{ .respond = .{ .body = production.list_enabled_next } },
        .{ .respond = .{ .body = production.list_disabled_page } },
        .{ .respond = .{ .body = production.list_any_page } },
        .{ .respond = .{ .body = production.get_enabled } },
        .{ .respond = .{ .body = production.get_disabled } },
        .{ .respond = .{ .body = production.batch_two } },
    });
    defer h.deinit();
    const c = &h.client;

    var first = try c.listServices(.{ .page_size = 3 });
    defer first.deinit();
    try h.expectRequest(0, .GET, base ++ "?filter=state%3AENABLED&pageSize=3&" ++ list_mask);
    try testing.expectEqual(3, first.value.services.len);
    var second = try c.listServices(.{ .page_size = 3, .page_token = first.value.next_page_token });
    defer second.deinit();
    try h.expectRequest(1, .GET, base ++ "?filter=state%3AENABLED&pageSize=3&pageToken=ZW5hYmxlZC1zZXJ2aWNlcy1vZmZzZXQ6Mw%3D%3D&" ++ list_mask);
    try testing.expectEqualStrings("bigquery.googleapis.com", second.value.services[0].name);
    var disabled = try c.listServices(.{ .state = .disabled, .page_size = 2 });
    defer disabled.deinit();
    try h.expectRequest(2, .GET, base ++ "?filter=state%3ADISABLED&pageSize=2&" ++ list_mask);
    var any = try c.listServices(.{ .state = .any, .page_size = 2 });
    defer any.deinit();
    try h.expectRequest(3, .GET, base ++ "?pageSize=2&" ++ list_mask);
    try testing.expectEqual(types.State.disabled, any.value.services[0].state);

    var pubsub = try c.getService("pubsub.googleapis.com");
    defer pubsub.deinit();
    try h.expectRequest(4, .GET, base ++ "/pubsub.googleapis.com?" ++ get_mask);
    try testing.expectEqual(types.State.enabled, pubsub.value.state);
    try testing.expectEqualStrings("Cloud Pub/Sub API", pubsub.value.title);
    var off = try c.getService("a10-thunder-adc-601b150-byol.endpoints.a10networks-public-396315.cloud.goog");
    defer off.deinit();
    try testing.expectEqual(types.State.disabled, off.value.state);

    var two = try c.getServices(&.{ "pubsub.googleapis.com", "a10-thunder-adc-601b150-byol.endpoints.a10networks-public-396315.cloud.goog" });
    defer two.deinit();
    try h.expectRequest(6, .GET, base ++ ":batchGet?names=projects%2Fmy-project%2Fservices%2Fpubsub.googleapis.com&names=projects%2Fmy-project%2Fservices%2Fa10-thunder-adc-601b150-byol.endpoints.a10networks-public-396315.cloud.goog&" ++ batch_mask);
    try testing.expectEqual(2, two.value.len);
    try testing.expectEqualStrings("pubsub.googleapis.com", two.value[0].name);
    try testing.expectEqual(types.State.disabled, two.value[1].state);
}

test "enabledServices: every page of the enabled list, 200 at a time, in one answer" {
    var h: Harness = undefined;
    try h.init(&.{
        .{ .respond = .{ .body = production.list_enabled_page } },
        .{ .respond = .{ .body = production.list_enabled_next } },
        .{ .respond = .{ .body = "{\"services\":[{\"name\":\"projects/82150720798/services/zz.googleapis.com\",\"state\":\"ENABLED\"}]}" } },
        .{ .respond = .{ .body = production.list_enabled_all } },
    });
    defer h.deinit();
    var three = try h.client.enabledServices();
    defer three.deinit();
    try h.expectRequest(0, .GET, base ++ "?filter=state%3AENABLED&pageSize=200&" ++ list_mask);
    try h.expectRequest(1, .GET, base ++ "?filter=state%3AENABLED&pageSize=200&pageToken=ZW5hYmxlZC1zZXJ2aWNlcy1vZmZzZXQ6Mw%3D%3D&" ++ list_mask);
    try h.expectRequest(2, .GET, base ++ "?filter=state%3AENABLED&pageSize=200&pageToken=ZW5hYmxlZC1zZXJ2aWNlcy1vZmZzZXQ6Ng%3D%3D&" ++ list_mask);
    try testing.expectEqual(7, three.value.len);
    try testing.expectEqualStrings("analyticshub.googleapis.com", three.value[0].name);
    try testing.expectEqualStrings("zz.googleapis.com", three.value[6].name);
    var all = try h.client.enabledServices();
    defer all.deinit();
    try testing.expectEqual(45, all.value.len);
    try testing.expectEqualStrings("telemetry.googleapis.com", all.value[44].name);
}

test "enabledServices: a server that hands back the token it was given is refused" {
    var h: Harness = undefined;
    try h.init(&.{
        .{ .respond = .{ .body = "{\"services\":[],\"nextPageToken\":\"MQ==\"}" } },
        .{ .respond = .{ .body = "{\"services\":[],\"nextPageToken\":\"MQ==\"}" } },
    });
    defer h.deinit();
    try testing.expectError(error.InvalidResponse, h.client.enabledServices());
    try testing.expectEqualStrings("the service list answered the same page token twice", h.diag.message());
}

test "the calls refuse what they will not send, saying where" {
    var h: Harness = undefined;
    try h.init(&.{});
    defer h.deinit();
    const c = &h.client;
    try testing.expectError(error.InvalidName, c.getService(""));
    try testing.expectEqualStrings("invalid service name: empty", h.diag.message());
    try testing.expectError(error.InvalidName, c.getService("PUBSUB.googleapis.com"));
    try testing.expectEqualStrings("invalid service name: 'P' at byte 0; expected a-z, 0-9, '.' and '-', such as pubsub.googleapis.com", h.diag.message());
    try testing.expectError(error.InvalidName, c.getService("pubsub.googleapis.com/x"));
    try testing.expectError(error.InvalidName, c.getService("pubsub.googleapis.com?x"));
    try testing.expectError(error.InvalidName, c.getServices(&.{ "pubsub.googleapis.com", "a b" }));
    try testing.expectEqualStrings("invalid service name names[1]: byte 0x20 at byte 1; expected a-z, 0-9, '.' and '-', such as pubsub.googleapis.com", h.diag.message());
    try testing.expectError(error.InvalidOptions, c.getServices(&.{}));
    try testing.expectEqualStrings("invalid names: getServices takes 1 to 30, and was given 0", h.diag.message());
    const many: [31][]const u8 = @splat("pubsub.googleapis.com");
    try testing.expectError(error.InvalidOptions, c.getServices(&many));
    try testing.expectEqualStrings("invalid names: getServices takes 1 to 30, and was given 31", h.diag.message());
    try testing.expectError(error.InvalidOptions, c.listServices(.{ .page_size = 201 }));
    try testing.expectEqualStrings("invalid page_size: the server refuses more than 200", h.diag.message());
    try testing.expectError(error.InvalidName, c.listServices(.{ .page_token = "a b" }));
    try testing.expectEqualStrings("invalid page token: expected printable ASCII", h.diag.message());
    try testing.expectError(error.InvalidName, c.listServices(.{ .page_token = "" }));
    try h.expectRequestCount(0);
    // Thirty is the most, and a name twice is sent twice.
    try testing.expectEqual(30, validate.max_batch);
}

test "the refusals arrive as errors, production's words kept" {
    var h: Harness = undefined;
    try h.init(&.{
        .{ .respond = .{ .status = production.get_unknown_status, .body = production.get_unknown } },
        .{ .respond = .{ .status = production.batch_unknown_two_status, .body = production.batch_unknown_two } },
        .{ .respond = .{ .status = production.no_such_project_status, .body = production.no_such_project } },
        .{ .respond = .{ .status = production.other_project_status, .body = production.other_project } },
        .{ .respond = .{ .status = production.scope_insufficient_status, .body = production.scope_insufficient } },
        .{ .respond = .{ .status = production.token_garbage_status, .body = production.token_garbage } },
        .{ .respond = .{ .status = production.token_disabled_under_enabled_status, .body = production.token_disabled_under_enabled } },
    });
    defer h.deinit();
    const c = &h.client;
    try testing.expectError(error.PermissionDenied, c.getService("zigps-nope-316.googleapis.com"));
    try testing.expect(std.mem.startsWith(u8, h.diag.message(), "Not found or permission denied for service(s): zigps-nope-316.googleapis.com.\nHelp Token: "));
    try testing.expectError(error.PermissionDenied, c.getServices(&.{ "zigps-nope-a.googleapis.com", "pubsub.googleapis.com", "zigps-nope-b.googleapis.com" }));
    try testing.expect(std.mem.startsWith(u8, h.diag.message(), "Not found or permission denied for service(s): zigps-nope-a.googleapis.com.\n"));
    try testing.expectError(error.PermissionDenied, c.listServices(.{}));
    try testing.expect(std.mem.startsWith(u8, h.diag.message(), "Project 'zigps-no-such-project-316' not found or permission denied."));
    try testing.expectError(error.PermissionDenied, c.listServices(.{}));
    try testing.expect(std.mem.startsWith(u8, h.diag.message(), "Permission denied to list services for consumer container [projects/1057666841514]"));
    try testing.expectError(error.PermissionDenied, c.listServices(.{}));
    try testing.expectEqualStrings("Request had insufficient authentication scopes.", h.diag.message());
    try testing.expectError(error.InvalidArgument, c.listServices(.{ .page_token = "abc" }));
    try testing.expect(std.mem.startsWith(u8, h.diag.message(), "Invalid page token 'abc'."));
    try testing.expectError(error.InvalidArgument, c.listServices(.{ .page_token = "Cs8B" }));
    // Each refusal is final.
    try h.expectRequestCount(7);
}

test "the reads are retried as core retries them" {
    const unavailable: test_util.FakeTransport.Reply = .{ .respond = .{ .status = 503, .body = "{\"error\":{\"code\":503,\"message\":\"The service is currently unavailable.\",\"status\":\"UNAVAILABLE\"}}" } };
    const exhausted: test_util.FakeTransport.Reply = .{ .respond = .{ .status = 429, .body = "{\"error\":{\"code\":429,\"message\":\"Quota exceeded for quota metric 'List available/disabled services requests'.\",\"status\":\"RESOURCE_EXHAUSTED\"}}" } };
    var h: Harness = undefined;
    try h.init(&.{
        unavailable,
        .{ .respond = .{ .body = production.get_enabled } },
        exhausted,
        .{ .respond = .{ .body = production.list_disabled_page } },
        .{ .fail = error.ConnectionResetByPeer },
        .{ .respond = .{ .body = production.batch_two } },
    });
    defer h.deinit();
    var one = try h.client.getService("pubsub.googleapis.com");
    one.deinit();
    var page = try h.client.listServices(.{ .state = .disabled });
    page.deinit();
    var two = try h.client.getServices(&.{ "pubsub.googleapis.com", "a10-thunder-adc-601b150-byol.endpoints.a10networks-public-396315.cloud.goog" });
    two.deinit();
    try h.expectRequestCount(6);
}

test "a response that cannot be decoded is InvalidResponse, named in Diagnostics" {
    var h: Harness = undefined;
    try h.init(&.{
        .{ .respond = .{ .body = "{\"services\":1}" } },
        .{ .respond = .{ .body = "{\"name\":\"pubsub.googleapis.com\"}" } },
        .{ .respond = .{ .body = "[]" } },
    });
    defer h.deinit();
    const c = &h.client;
    try testing.expectError(error.InvalidResponse, c.listServices(.{}));
    try testing.expectEqualStrings("the service list response could not be decoded", h.diag.message());
    try testing.expectError(error.InvalidResponse, c.getService("pubsub.googleapis.com"));
    try testing.expectEqualStrings("the service response could not be decoded", h.diag.message());
    try testing.expectError(error.InvalidResponse, c.getServices(&.{"pubsub.googleapis.com"}));
    try testing.expectEqualStrings("the service batch response could not be decoded", h.diag.message());
}

test "a response over max_response_bytes says how to ask for less" {
    var h: Harness = undefined;
    try h.init(&.{.{ .fail = error.ResponseTooLarge }});
    defer h.deinit();
    try testing.expectError(error.ResponseTooLarge, h.client.listServices(.{ .state = .any }));
    try testing.expectEqualStrings("the response was larger than max_response_bytes (33554432); ask for a smaller page_size", h.diag.message());
}

test "a client asks its token provider for the one scope its options name" {
    const Case = struct { ?rpc.Scope, []const u8 };
    for ([_]Case{
        .{ null, "https://www.googleapis.com/auth/cloud-platform.read-only" },
        .{ .read_only, "https://www.googleapis.com/auth/cloud-platform.read-only" },
        .{ .cloud_platform, "https://www.googleapis.com/auth/cloud-platform" },
    }) |case| {
        var fake: test_util.FakeTransport = .init(testing.allocator, &.{.{ .respond = .{ .body = "{}" } }});
        defer fake.deinit();
        var tokens: test_util.FakeTokenProvider = .{};
        var clock: test_util.FakeClock = .{};
        var options: Options = .{ .project_id = "p", .token_provider = tokens.provider(), .transport = fake.transport() };
        if (case[0]) |s| options.scope = s;
        var client = try Client.init(testing.allocator, clock.io(), options);
        defer client.deinit();
        var page = try client.listServices(.{});
        page.deinit();
        try testing.expectEqual(1, tokens.scope_count);
        try testing.expectEqualStrings(case[1], tokens.firstScope());
    }
}

test "a project by number, or domain-scoped, goes into the path as given" {
    var fake: test_util.FakeTransport = .init(testing.allocator, &.{
        .{ .respond = .{ .body = production.get_enabled } },
        .{ .respond = .{ .body = production.get_enabled } },
    });
    defer fake.deinit();
    var tokens: test_util.FakeTokenProvider = .{};
    var clock: test_util.FakeClock = .{};
    inline for (.{ "82150720798", "example.com:my-project" }, 0..) |project, i| {
        var client = try Client.init(testing.allocator, clock.io(), .{ .project_id = project, .token_provider = tokens.provider(), .transport = fake.transport() });
        defer client.deinit();
        var one = try client.getService("pubsub.googleapis.com");
        defer one.deinit();
        // Production names the project by number whichever it was asked by.
        try testing.expectEqualStrings("82150720798", one.value.project_number);
        const r = try fake.request(i);
        try testing.expectEqualStrings("https://serviceusage.googleapis.com/v1/projects/" ++ project ++ "/services/pubsub.googleapis.com?" ++ get_mask, r.url);
    }
}

test "init refuses what no call could use" {
    var tokens: test_util.FakeTokenProvider = .{};
    var clock: test_util.FakeClock = .{};
    var diag: core.Diagnostics = .{};
    try testing.expectError(error.InvalidName, Client.init(testing.allocator, clock.io(), .{ .project_id = "a/b", .token_provider = tokens.provider(), .diagnostics = &diag }));
    try testing.expectEqualStrings("invalid project: expected a project id or number", diag.message());
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
                .{ .respond = .{ .body = production.list_enabled_page } },
                .{ .respond = .{ .body = production.list_enabled_page } },
                .{ .respond = .{ .body = production.list_enabled_next } },
                .{ .respond = .{ .body = "{\"services\":[]}" } },
                .{ .respond = .{ .body = production.get_enabled } },
                .{ .respond = .{ .body = production.batch_two } },
                .{ .respond = .{ .status = production.get_unknown_status, .body = production.get_unknown } },
            });
            defer fake.deinit();
            var tokens: test_util.FakeTokenProvider = .{};
            var clock: test_util.FakeClock = .{};
            var client = try Client.init(gpa, clock.io(), .{ .project_id = "extractctl", .token_provider = tokens.provider(), .transport = fake.transport() });
            defer client.deinit();
            var page = try client.listServices(.{ .page_size = 3 });
            page.deinit();
            var all = try client.enabledServices();
            all.deinit();
            var one = try client.getService("pubsub.googleapis.com");
            one.deinit();
            var two = try client.getServices(&.{ "pubsub.googleapis.com", "a10-thunder-adc-601b150-byol.endpoints.a10networks-public-396315.cloud.goog" });
            two.deinit();
            if (client.getService("zigps-nope-316.googleapis.com")) |unexpected| {
                var u = unexpected;
                u.deinit();
                return error.TestUnexpectedResult;
            } else |err| if (err != error.PermissionDenied) return err;
        }
    };
    try testing.checkAllAllocationFailures(std.testing.allocator, Run.calls, .{});
}
