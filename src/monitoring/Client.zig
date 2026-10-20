//! A Cloud Monitoring client: configuration, the HTTP connection pool, and
//! the entry points for writing points and for metric and resource
//! descriptors.
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
const Metric = @import("Metric.zig");
const names = @import("names.zig");
const rpc = @import("rpc.zig");
const types = @import("types.zig");
const validate = @import("validate.zig");
const Diagnostics = core.Diagnostics;
const Error = errors.Error;
const PreparedRequest = core.PreparedRequest;
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
write_retries: types.WriteRetries,
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

pub const default_endpoint = "https://monitoring.googleapis.com";

pub const Options = struct {
    /// Required: the project whose metrics are written and read, an id or a
    /// number.
    project_id: []const u8,
    /// Required. Cloud Monitoring has no emulator, so there is no
    /// unauthenticated mode.
    token_provider: TokenProvider,
    /// Overrides the host: a test server, say. Must be `https`, since it
    /// receives credentials.
    endpoint: ?[]const u8 = null,
    /// Sends the credentials' quota project as `x-goog-user-project`, as
    /// every module does.
    send_quota_project: bool = true,
    /// Reads and descriptor calls: 5xx, 429 and dropped connections are
    /// retried. Writes follow `write_retries`, under this policy's attempts
    /// and backoff.
    retry: RetryPolicy = .{},
    /// Which failed writes are tried again. See `WriteRetries`.
    write_retries: types.WriteRetries = .unsent_only,
    /// How long one request may take before it is `error.TimedOut`. Google's
    /// own clients stop a write at 12 s and see it time out on slow hosts,
    /// and the troubleshooting page asks for 15 s or more. Google gives
    /// `timeSeries.list` 90 s, so a large read takes a smaller page. 0
    /// removes the limit.
    request_timeout_ms: u32 = 30_000,
    /// A response whose decompressed body is larger fails with
    /// `error.ResponseTooLarge`. Used by the built-in transport; a transport
    /// passed in keeps its own limit.
    max_response_bytes: usize = core.transport.default_max_response_bytes,
    /// Printable ASCII.
    user_agent: []const u8 = "zig-gcp-monitoring/0.51",
    /// Filled with details of every failed call, and of a write's refused
    /// points; cleared by each new call.
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
    if (!validate.isProject(options.project_id)) {
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
    // Every request carries a bearer token, which must not travel in cleartext.
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
        .write_retries = options.write_retries,
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
    self.gpa.free(self.user_agent);
    self.gpa.free(self.project);
    self.gpa.free(self.base_url);
    self.* = undefined;
}

/// Writes one point to each of 1 to 200 series, in one request.
///
/// Each series is checked first, and none is sent if one fails: the error
/// says which kind of check, and `Diagnostics` which series and why. Two
/// series that are one (the same metric type, metric labels and resource)
/// are `error.DuplicateSeries`.
///
/// When the server answers about the points, the result says how many it
/// wrote and why it refused the rest, whatever the HTTP status: a point
/// too soon after its series' last, out of order, too far ahead or back,
/// or of a kind or value type its descriptor does not take. Production
/// answers a write that refused any point with HTTP 400 and keeps the
/// rest, so `ok()` is the check that matters; `Diagnostics` hold the
/// server's message too. A failure that says nothing about the points is
/// an error, retried as `Options.write_retries` allows: a refused request
/// (a metric production would not create, such as a DELTA one under
/// `custom.googleapis.com/`), credentials, the network.
///
/// The server, not this client, holds each series to one point at a time:
/// one writer per series, a point at least 2.5 s after the last (5 s, as
/// Google documents it, is safe), and a cumulative series' start kept until
/// its total starts over.
pub fn write(self: *Client, series: []const types.TimeSeries) Error!types.Owned(types.WriteResult) {
    rpc.begin(self);
    try checkWrite(self.diagnostics, series);
    var scratch: std.heap.ArenaAllocator = .init(self.gpa);
    defer scratch.deinit();
    const a = scratch.allocator();
    const path = try names.collection(a, self.project, .time_series);
    const body = try codec.encodeWrite(a, series);
    var result: types.Owned(types.WriteResult) = try .init(self.gpa);
    errdefer result.deinit();
    result.value = try rpc.write(self, result.arena, path, body, @intCast(series.len));
    return result;
}

fn checkWrite(diag: ?*Diagnostics, series: []const types.TimeSeries) Error!void {
    if (series.len == 0 or series.len > validate.max_series_per_write) {
        if (diag) |d| d.print("a write takes 1 to {d} series; this one has {d}", .{ validate.max_series_per_write, series.len });
        return error.TooManySeries;
    }
    for (series, 0..) |s, i| {
        if (validate.seriesProblem(s)) |p| {
            if (diag) |d| d.print("series {d}: {s}", .{ i, p.reason });
            return switch (p.err) {
                .metric_type => error.InvalidMetricType,
                .label => error.InvalidLabel,
                .point => error.InvalidPoint,
                .resource => error.InvalidResource,
            };
        }
        for (series[0..i], 0..) |earlier, j| if (validate.sameSeries(earlier, s)) {
            if (diag) |d| d.print("series {d} is series {d} again: a write takes one point per series", .{ i, j });
            return error.DuplicateSeries;
        };
    }
}

/// A handle on one metric type, such as "custom.googleapis.com/shop/orders".
/// Makes no call.
pub fn metric(self: *Client, metric_type: []const u8) Metric {
    return .{ .client = self, .type = metric_type };
}

/// One page of the project's metric descriptors: Google's own and its
/// users', or those whose type starts with `options.prefix`.
pub fn listMetrics(self: *Client, options: types.ListMetricsOptions) Error!types.Owned(types.MetricPage) {
    rpc.begin(self);
    if (options.prefix) |p| if (validate.prefixProblem(p)) |reason| {
        if (self.diagnostics) |d| d.print("invalid prefix: {s}", .{reason});
        return error.InvalidMetricType;
    };
    try self.checkToken(options.page_token);
    var scratch: std.heap.ArenaAllocator = .init(self.gpa);
    defer scratch.deinit();
    const a = scratch.allocator();
    var w: std.Io.Writer.Allocating = .init(a);
    names.writeCollection(&w.writer, self.project, .metric_descriptors) catch return error.OutOfMemory;
    var params: core.query.Params = .init(&w.writer);
    if (options.prefix) |p| {
        const filter = try std.fmt.allocPrint(a, "metric.type = starts_with(\"{s}\")", .{p});
        params.add("filter", filter) catch return error.OutOfMemory;
    }
    if (options.active_only) params.add("activeOnly", "true") catch return error.OutOfMemory;
    params.addNonZero("pageSize", options.page_size) catch return error.OutOfMemory;
    params.addOptional("pageToken", options.page_token) catch return error.OutOfMemory;

    var result: types.Owned(types.MetricPage) = try .init(self.gpa);
    errdefer result.deinit();
    const body = try rpc.execute(self, result.arena, .{ .method = .GET, .path = w.written() });
    result.value = codec.decodeMetricPage(result.arena.allocator(), a, body) catch |err|
        return rpc.decodeFailed(self, err, "metric descriptor list");
    return result;
}

/// A monitored resource type, such as "generic_task", with its labels.
pub fn resourceType(self: *Client, type_name: []const u8) Error!types.Owned(types.ResourceTypeInfo) {
    rpc.begin(self);
    if (!validate.isResourceType(type_name)) {
        if (self.diagnostics) |d| d.print("invalid resource type: letters, digits, _ and ., at most 256", .{});
        return error.InvalidResource;
    }
    var scratch: std.heap.ArenaAllocator = .init(self.gpa);
    defer scratch.deinit();
    const a = scratch.allocator();
    const path = try names.resourceType(a, self.project, type_name);
    var result: types.Owned(types.ResourceTypeInfo) = try .init(self.gpa);
    errdefer result.deinit();
    const body = try rpc.execute(self, result.arena, .{ .method = .GET, .path = path });
    result.value = codec.decodeResourceType(result.arena.allocator(), a, body) catch |err|
        return rpc.decodeFailed(self, err, "resource type");
    return result;
}

/// One page of the monitored resource types.
pub fn listResourceTypes(self: *Client, options: types.ListOptions) Error!types.Owned(types.ResourceTypePage) {
    rpc.begin(self);
    try self.checkToken(options.page_token);
    var scratch: std.heap.ArenaAllocator = .init(self.gpa);
    defer scratch.deinit();
    const a = scratch.allocator();
    var w: std.Io.Writer.Allocating = .init(a);
    names.writeCollection(&w.writer, self.project, .resource_descriptors) catch return error.OutOfMemory;
    var params: core.query.Params = .init(&w.writer);
    params.addNonZero("pageSize", options.page_size) catch return error.OutOfMemory;
    params.addOptional("pageToken", options.page_token) catch return error.OutOfMemory;

    var result: types.Owned(types.ResourceTypePage) = try .init(self.gpa);
    errdefer result.deinit();
    const body = try rpc.execute(self, result.arena, .{ .method = .GET, .path = w.written() });
    result.value = codec.decodeResourceTypePage(result.arena.allocator(), a, body) catch |err|
        return rpc.decodeFailed(self, err, "resource type list");
    return result;
}

/// One page of the project's alerts: the violations of its alert
/// policies, which only Cloud Monitoring itself opens and closes (#246).
/// Without `order_by`, production answers newest-opened first.
pub fn listAlerts(self: *Client, options: types.ListAlertsOptions) Error!types.Owned(types.AlertPage) {
    rpc.begin(self);
    if (options.filter) |f| if (!validate.isAlertFilter(f)) {
        if (self.diagnostics) |d| d.print("invalid filter: text without control characters, at most 4096 bytes", .{});
        return error.InvalidFilter;
    };
    if (options.open_only and options.filter != null) {
        if (self.diagnostics) |d| d.print("open_only writes its own filter; give one or the other", .{});
        return error.InvalidOptions;
    }
    try self.checkToken(options.page_token);
    var scratch: std.heap.ArenaAllocator = .init(self.gpa);
    defer scratch.deinit();
    const a = scratch.allocator();
    var w: std.Io.Writer.Allocating = .init(a);
    names.writeCollection(&w.writer, self.project, .alerts) catch return error.OutOfMemory;
    var params: core.query.Params = .init(&w.writer);
    const open_filter: ?[]const u8 = if (options.open_only) "state=\"OPEN\"" else null;
    params.addOptional("filter", options.filter orelse open_filter) catch return error.OutOfMemory;
    if (options.order_by) |o| params.add("orderBy", o.wire()) catch return error.OutOfMemory;
    params.addNonZero("pageSize", options.page_size) catch return error.OutOfMemory;
    params.addOptional("pageToken", options.page_token) catch return error.OutOfMemory;

    var result: types.Owned(types.AlertPage) = try .init(self.gpa);
    errdefer result.deinit();
    const body = try rpc.execute(self, result.arena, .{ .method = .GET, .path = w.written() });
    result.value = codec.decodeAlertPage(result.arena.allocator(), a, body) catch |err|
        return rpc.decodeFailed(self, err, "alert list");
    return result;
}

/// One alert, by its id or its full `projects/P/alerts/ID` name. Another
/// project's name is refused before sending.
pub fn getAlert(self: *Client, id_or_name: []const u8) Error!types.Owned(types.Alert) {
    rpc.begin(self);
    const id = names.alertId(id_or_name, self.project) orelse "";
    if (!validate.isAlertId(id)) {
        if (self.diagnostics) |d| d.print("invalid alert: expected its id, or projects/{s}/alerts/<id>", .{self.project});
        return error.InvalidName;
    }
    var scratch: std.heap.ArenaAllocator = .init(self.gpa);
    defer scratch.deinit();
    const a = scratch.allocator();
    const path = try names.alert(a, self.project, id);
    var result: types.Owned(types.Alert) = try .init(self.gpa);
    errdefer result.deinit();
    const body = try rpc.execute(self, result.arena, .{ .method = .GET, .path = path });
    result.value = codec.decodeAlert(result.arena.allocator(), a, body) catch |err|
        return rpc.decodeFailed(self, err, "alert");
    return result;
}

/// One page of the project's alert policies (#275): when Cloud Monitoring
/// opens alerts, and what it tells people when it does. Without
/// `order_by`, production orders them by name.
pub fn listAlertPolicies(self: *Client, options: types.ListAlertPoliciesOptions) Error!types.Owned(types.AlertPolicyPage) {
    rpc.begin(self);
    if (options.filter) |f| if (!validate.isAlertFilter(f)) {
        if (self.diagnostics) |d| d.print("invalid filter: text without control characters, at most 4096 bytes", .{});
        return error.InvalidFilter;
    };
    if (options.order_by) |o| if (!validate.isAlertFilter(o)) {
        if (self.diagnostics) |d| d.print("invalid order_by: text without control characters, at most 4096 bytes", .{});
        return error.InvalidOptions;
    };
    try self.checkToken(options.page_token);
    var scratch: std.heap.ArenaAllocator = .init(self.gpa);
    defer scratch.deinit();
    const a = scratch.allocator();
    var w: std.Io.Writer.Allocating = .init(a);
    names.writeCollection(&w.writer, self.project, .alert_policies) catch return error.OutOfMemory;
    var params: core.query.Params = .init(&w.writer);
    params.addOptional("filter", options.filter) catch return error.OutOfMemory;
    params.addOptional("orderBy", options.order_by) catch return error.OutOfMemory;
    params.addNonZero("pageSize", options.page_size) catch return error.OutOfMemory;
    params.addOptional("pageToken", options.page_token) catch return error.OutOfMemory;

    var result: types.Owned(types.AlertPolicyPage) = try .init(self.gpa);
    errdefer result.deinit();
    const body = try rpc.execute(self, result.arena, .{ .method = .GET, .path = w.written() });
    result.value = codec.decodeAlertPolicyPage(result.arena.allocator(), a, body) catch |err|
        return rpc.decodeFailed(self, err, "alert policy list");
    return result;
}

/// One alert policy, by its id or its full `projects/P/alertPolicies/ID`
/// name. Another project's name is refused before sending.
pub fn getAlertPolicy(self: *Client, id_or_name: []const u8) Error!types.Owned(types.AlertPolicy) {
    rpc.begin(self);
    var scratch: std.heap.ArenaAllocator = .init(self.gpa);
    defer scratch.deinit();
    const a = scratch.allocator();
    const path = try names.alertPolicy(a, self.project, try self.policyId(id_or_name));
    return self.policyCall(a, .{ .method = .GET, .path = path });
}

/// Enables or disables an alert policy, and answers it as it then
/// stands: a disabled policy opens no alerts. Sends `PATCH
/// ...?updateMask=enabled` with the field set, and nothing else can go
/// with it: a patch without a mask would replace the whole policy.
/// Production answers a repeat with 200, moving the mutation record again
/// (measured 2026-10-20), so a patch is retried as the reads are. A token
/// for `monitoring.read` alone is refused; this takes `monitoring` or
/// `cloud-platform`.
pub fn setAlertPolicyEnabled(self: *Client, id_or_name: []const u8, enabled: bool) Error!types.Owned(types.AlertPolicy) {
    rpc.begin(self);
    var scratch: std.heap.ArenaAllocator = .init(self.gpa);
    defer scratch.deinit();
    const a = scratch.allocator();
    return self.policyCall(a, try self.enabledCall(a, id_or_name, enabled));
}

/// The request `setAlertPolicyEnabled` sends for the same arguments,
/// built without sending it, after the same checks with the same errors:
/// to show before the call, or to record after it. Credentials and other
/// headers are not part of it.
pub fn setAlertPolicyEnabledRequest(self: *Client, id_or_name: []const u8, enabled: bool) Error!types.Owned(PreparedRequest) {
    rpc.begin(self);
    var result: types.Owned(PreparedRequest) = try .init(self.gpa);
    errdefer result.deinit();
    const a = result.arena.allocator();
    result.value = try .fromCall(a, self.base_url, try self.enabledCall(a, id_or_name, enabled));
    return result;
}

fn enabledCall(self: *Client, arena: Allocator, id_or_name: []const u8, enabled: bool) Error!rpc.Call {
    const id = try self.policyId(id_or_name);
    var w: std.Io.Writer.Allocating = .init(arena);
    w.writer.writeAll(try names.alertPolicy(arena, self.project, id)) catch return error.OutOfMemory;
    var params: core.query.Params = .init(&w.writer);
    params.add("updateMask", "enabled") catch return error.OutOfMemory;
    return .{ .method = .PATCH, .path = w.written(), .body = try codec.encodeEnabled(arena, enabled) };
}

fn policyId(self: *Client, id_or_name: []const u8) Error![]const u8 {
    const id = names.alertPolicyId(id_or_name, self.project) orelse "";
    if (!validate.isAlertId(id)) {
        if (self.diagnostics) |d| d.print("invalid alert policy: expected its id, or projects/{s}/alertPolicies/<id>", .{self.project});
        return error.InvalidName;
    }
    return id;
}

/// Sends `call` and decodes the policy it answers.
fn policyCall(self: *Client, scratch: Allocator, call: rpc.Call) Error!types.Owned(types.AlertPolicy) {
    var result: types.Owned(types.AlertPolicy) = try .init(self.gpa);
    errdefer result.deinit();
    const body = try rpc.execute(self, result.arena, call);
    result.value = codec.decodeAlertPolicy(result.arena.allocator(), scratch, body) catch |err|
        return rpc.decodeFailed(self, err, "alert policy");
    return result;
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
const FakeMonitoring = @import("fake_monitoring.zig").FakeMonitoring;

const t0: std.Io.Timestamp = .{ .nanoseconds = 1_792_144_800 * std.time.ns_per_s };
const t1: std.Io.Timestamp = .{ .nanoseconds = 1_792_145_100 * std.time.ns_per_s };
const task: types.Resource = .{ .generic_task = .{ .location = "us-central1", .namespace = "shop", .job = "api", .task_id = "7" } };
const gauge: types.TimeSeries = .{ .metric_type = "custom.googleapis.com/shop/depth", .resource = task, .kind = .gauge, .end = t1, .value = .{ .int64 = 3 } };

test "golden: a write sends one POST to timeSeries, and 200 wrote every point" {
    var h: Harness = undefined;
    try h.init(&.{.{ .respond = .{ .body = "{}\n" } }}, .{});
    defer h.deinit();
    var result = try h.client.write(&.{gauge});
    defer result.deinit();
    try testing.expect(result.value.ok());
    try testing.expectEqual(1, result.value.points);
    try testing.expectEqual(0, result.value.refused.len);
    try h.expectRequest(0, .POST, "https://monitoring.googleapis.com/v3/projects/my-project/timeSeries",
        \\{"timeSeries":[{"metric":{"type":"custom.googleapis.com/shop/depth"},"resource":{"type":"generic_task","labels":{"location":"us-central1","namespace":"shop","job":"api","task_id":"7"}},"metricKind":"GAUGE","valueType":"INT64","points":[{"interval":{"endTime":"2026-10-16T10:05:00Z"},"value":{"int64Value":"3"}}]}]}
    );
    const r = try h.fake.request(0);
    try testing.expectEqualStrings("ya29.test-token", r.bearer.?);
}

test "write: production's summary is the result, written and refused counted, never retried" {
    var h: Harness = undefined;
    try h.init(&.{
        .{ .respond = .{ .status = production.write_mixed_status, .body = production.write_mixed } },
        .{ .respond = .{ .status = production.write_too_frequent_status, .body = production.write_too_frequent } },
    }, .{ .write_retries = .transient });
    defer h.deinit();
    const second = blk: {
        var s = gauge;
        s.metric_labels = &.{.{ .key = "k", .value = "2" }};
        break :blk s;
    };
    const third = blk: {
        var s = gauge;
        s.metric_labels = &.{.{ .key = "k", .value = "3" }};
        break :blk s;
    };
    var mixed = try h.client.write(&.{ gauge, second, third });
    defer mixed.deinit();
    try testing.expect(!mixed.value.ok());
    try testing.expectEqual(3, mixed.value.points);
    try testing.expectEqual(2, mixed.value.written);
    try testing.expectEqual(1, mixed.value.refused.len);
    try testing.expectEqual(error.InvalidArgument, mixed.value.refused[0].reason);
    try testing.expectEqual(1, mixed.value.refused[0].points);
    try testing.expect(std.mem.indexOf(u8, mixed.value.message, "more than 5m into the future") != null);
    try testing.expectEqual(400, h.diag.http_status);

    var frequent = try h.client.write(&.{gauge});
    defer frequent.deinit();
    try testing.expectEqual(0, frequent.value.written);
    try testing.expectEqual(error.FailedPrecondition, frequent.value.refused[0].reason);
    try h.expectRequestCount(2);
}

test "write: a refusal of the request as a whole is an error, in production's words" {
    var h: Harness = undefined;
    try h.init(&.{
        .{ .respond = .{ .status = production.write_delta_custom_status, .body = production.write_delta_custom } },
        .{ .respond = .{ .status = production.write_foreign_project_status, .body = production.write_foreign_project } },
    }, .{});
    defer h.deinit();
    try testing.expectError(error.InvalidArgument, h.client.write(&.{gauge}));
    try testing.expect(std.mem.indexOf(u8, h.diag.message(), "the DELTA metric kind is not supported for custom metrics") != null);
    try testing.expectError(error.InvalidArgument, h.client.write(&.{gauge}));
    try h.expectRequestCount(2);
}

test "write: .unsent_only retries what never left, and nothing else" {
    const fast: RetryPolicy = .{ .max_attempts = 3, .initial_backoff_ms = 1, .max_backoff_ms = 1 };
    {
        var h: Harness = undefined;
        try h.init(&.{
            .{ .fail = error.ConnectionRefused },
            .{ .fail = error.NameServerFailure },
            .{ .respond = .{ .body = "{}" } },
        }, .{ .retry = fast });
        defer h.deinit();
        var result = try h.client.write(&.{gauge});
        result.deinit();
        try h.expectRequestCount(3);
    }
    for ([_]FakeReplyFor{
        .{ .reply = .{ .respond = .{ .status = 503, .body = "{\"error\":{\"code\":503,\"status\":\"UNAVAILABLE\"}}" } }, .err = error.Unavailable },
        .{ .reply = .{ .respond = .{ .status = 504, .body = "{\"error\":{\"code\":504,\"status\":\"DEADLINE_EXCEEDED\"}}" } }, .err = error.DeadlineExceeded },
        .{ .reply = .{ .respond = .{ .status = 429, .body = "{\"error\":{\"code\":429,\"status\":\"RESOURCE_EXHAUSTED\"}}" } }, .err = error.ResourceExhausted },
        .{ .reply = .{ .fail = error.ConnectionResetByPeer }, .err = error.ConnectionResetByPeer },
        .{ .reply = .{ .fail = error.TimedOut }, .err = error.TimedOut },
        .{ .reply = .{ .fail = error.TlsFailure }, .err = error.TlsFailure },
    }) |case| {
        var h: Harness = undefined;
        try h.init(&.{ case.reply, .{ .respond = .{ .body = "{}" } } }, .{ .retry = fast });
        defer h.deinit();
        try testing.expectError(case.err, h.client.write(&.{gauge}));
        try h.expectRequestCount(1);
    }
}

const FakeReplyFor = struct { reply: test_util.FakeTransport.Reply, err: anyerror };

test "write: .transient retries 429, 5xx and dropped connections, up to the policy's attempts" {
    const fast: RetryPolicy = .{ .max_attempts = 4, .initial_backoff_ms = 1, .max_backoff_ms = 1 };
    var h: Harness = undefined;
    try h.init(&.{
        .{ .respond = .{ .status = 503, .body = "{\"error\":{\"code\":503,\"status\":\"UNAVAILABLE\"}}" } },
        .{ .fail = error.ConnectionResetByPeer },
        .{ .respond = .{ .status = 500, .body = "{\"error\":{\"code\":500,\"status\":\"INTERNAL\"}}" } },
        .{ .respond = .{ .body = "{}" } },
    }, .{ .retry = fast, .write_retries = .transient });
    defer h.deinit();
    var result = try h.client.write(&.{gauge});
    result.deinit();
    try h.expectRequestCount(4);

    // Out of attempts: the last failure.
    var h2: Harness = undefined;
    try h2.init(&.{
        .{ .respond = .{ .status = 503, .body = "{\"error\":{\"code\":503,\"status\":\"UNAVAILABLE\"}}" } },
        .{ .respond = .{ .status = 504, .body = "{\"error\":{\"code\":504,\"status\":\"DEADLINE_EXCEEDED\"}}" } },
    }, .{ .retry = .{ .max_attempts = 2, .initial_backoff_ms = 1, .max_backoff_ms = 1 }, .write_retries = .transient });
    defer h2.deinit();
    try testing.expectError(error.DeadlineExceeded, h2.client.write(&.{gauge}));
    try h2.expectRequestCount(2);

    // A 500 that carries a summary is the result, not retried.
    var h3: Harness = undefined;
    try h3.init(&.{
        .{ .respond = .{ .status = 500, .body = "{\"error\":{\"code\":500,\"status\":\"INTERNAL\",\"message\":\"m\",\"details\":[{\"@type\":\"type.googleapis.com/google.monitoring.v3.CreateTimeSeriesSummary\",\"totalPointCount\":1,\"errors\":[{\"status\":{\"code\":13},\"pointCount\":1}]}]}}" } },
        .{ .respond = .{ .body = "{}" } },
    }, .{ .retry = fast, .write_retries = .transient });
    defer h3.deinit();
    var summarized = try h3.client.write(&.{gauge});
    defer summarized.deinit();
    try testing.expectEqual(error.Internal, summarized.value.refused[0].reason);
    try h3.expectRequestCount(1);
}

test "write: a summary that cannot be read is InvalidResponse" {
    var h: Harness = undefined;
    try h.init(&.{.{ .respond = .{ .status = 400, .body = "{\"error\":{\"code\":400,\"details\":[{\"@type\":\"type.googleapis.com/google.monitoring.v3.CreateTimeSeriesSummary\",\"totalPointCount\":\"x\"}]}}" } }}, .{});
    defer h.deinit();
    try testing.expectError(error.InvalidResponse, h.client.write(&.{gauge}));
    try testing.expectEqualStrings("the write's summary could not be decoded", h.diag.message());
}

test "write: every check refuses before sending, the series named in Diagnostics" {
    var h: Harness = undefined;
    try h.init(&.{}, .{});
    defer h.deinit();
    const c = &h.client;
    try testing.expectError(error.TooManySeries, c.write(&.{}));
    var many: [201]types.TimeSeries = @splat(gauge);
    try testing.expectError(error.TooManySeries, c.write(&many));
    try testing.expectEqualStrings("a write takes 1 to 200 series; this one has 201", h.diag.message());

    var bad = gauge;
    bad.metric_type = "custom.googleapis.com/a b";
    try testing.expectError(error.InvalidMetricType, c.write(&.{ gauge, bad }));
    try testing.expect(std.mem.startsWith(u8, h.diag.message(), "series 1: "));
    bad = gauge;
    bad.metric_labels = &.{.{ .key = "1k", .value = "v" }};
    try testing.expectError(error.InvalidLabel, c.write(&.{bad}));
    bad = gauge;
    bad.start = t0;
    try testing.expectError(error.InvalidPoint, c.write(&.{bad}));
    bad = gauge;
    bad.resource = .{ .other = .{ .type = "generic_task", .labels = &.{.{ .key = "project_id", .value = "x" }} } };
    try testing.expectError(error.InvalidResource, c.write(&.{bad}));
    // The same series twice, its labels in another order.
    var a = gauge;
    a.metric_labels = &.{ .{ .key = "x", .value = "1" }, .{ .key = "y", .value = "2" } };
    var b = a;
    b.metric_labels = &.{ .{ .key = "y", .value = "2" }, .{ .key = "x", .value = "1" } };
    try testing.expectError(error.DuplicateSeries, c.write(&.{ gauge, a, b }));
    try testing.expectEqualStrings("series 2 is series 1 again: a write takes one point per series", h.diag.message());
    try h.expectRequestCount(0);

    // 200 is the limit, not the refusal.
    var two_hundred: [200]types.TimeSeries = undefined;
    var ids: [200][3]u8 = undefined;
    for (&two_hundred, &ids, 0..) |*s, *id, i| {
        s.* = gauge;
        s.resource = .{ .generic_task = .{ .location = "us-central1", .namespace = "n", .job = "j", .task_id = std.fmt.bufPrint(id, "{d}", .{i}) catch unreachable } };
    }
    var h2: Harness = undefined;
    try h2.init(&.{.{ .respond = .{ .body = "{}" } }}, .{});
    defer h2.deinit();
    var result = try h2.client.write(&two_hundred);
    defer result.deinit();
    try testing.expectEqual(200, result.value.written);
}

test "golden: descriptors created, read, deleted and listed, the type's slashes literal" {
    var h: Harness = undefined;
    try h.init(&.{
        .{ .respond = .{ .body = production.descriptor_get } },
        .{ .respond = .{ .body = production.descriptor_get } },
        .{ .respond = .{ .body = "{}" } },
        .{ .respond = .{ .body = "{\"metricDescriptors\":[{\"type\":\"custom.googleapis.com/shop/a\"}],\"nextPageToken\":\"p1\"}" } },
        .{ .respond = .{ .body = "{}" } },
    }, .{});
    defer h.deinit();
    const orders = h.client.metric("custom.googleapis.com/zigps-m0-62b2c8/gauge");
    var made = try orders.create(.{ .kind = .gauge, .value_type = .int64, .unit = "1", .labels = &.{.{ .key = "k" }} });
    defer made.deinit();
    try h.expectRequest(0, .POST, "https://monitoring.googleapis.com/v3/projects/my-project/metricDescriptors",
        \\{"type":"custom.googleapis.com/zigps-m0-62b2c8/gauge","metricKind":"GAUGE","valueType":"INT64","unit":"1","labels":[{"key":"k"}]}
    );
    try testing.expectEqual(types.Kind.gauge, made.value.kind);
    var got = try orders.get();
    defer got.deinit();
    try h.expectRequest(1, .GET, "https://monitoring.googleapis.com/v3/projects/my-project/metricDescriptors/custom.googleapis.com/zigps-m0-62b2c8/gauge", null);
    try orders.delete();
    try h.expectRequest(2, .DELETE, "https://monitoring.googleapis.com/v3/projects/my-project/metricDescriptors/custom.googleapis.com/zigps-m0-62b2c8/gauge", null);

    var page = try h.client.listMetrics(.{ .prefix = "custom.googleapis.com/shop/", .active_only = true, .page_size = 2, .page_token = "a+b/=" });
    defer page.deinit();
    try h.expectRequest(3, .GET, "https://monitoring.googleapis.com/v3/projects/my-project/metricDescriptors?filter=metric.type%20%3D%20starts_with%28%22custom.googleapis.com%2Fshop%2F%22%29&activeOnly=true&pageSize=2&pageToken=a%2Bb%2F%3D", null);
    try testing.expectEqualStrings("custom.googleapis.com/shop/a", page.value.metrics[0].type);
    try testing.expectEqualStrings("p1", page.value.next_page_token.?);
    var all = try h.client.listMetrics(.{});
    defer all.deinit();
    try h.expectRequest(4, .GET, "https://monitoring.googleapis.com/v3/projects/my-project/metricDescriptors", null);
}

test "golden: resource types read and listed" {
    var h: Harness = undefined;
    try h.init(&.{
        .{ .respond = .{ .body = production.resource_generic_task } },
        .{ .respond = .{ .body = "{\"resourceDescriptors\":[{\"type\":\"global\"}]}" } },
    }, .{});
    defer h.deinit();
    var generic = try h.client.resourceType("generic_task");
    defer generic.deinit();
    try h.expectRequest(0, .GET, "https://monitoring.googleapis.com/v3/projects/my-project/monitoredResourceDescriptors/generic_task", null);
    try testing.expectEqualStrings("Generic Task", generic.value.display_name);
    var page = try h.client.listResourceTypes(.{ .page_size = 5, .page_token = "t" });
    defer page.deinit();
    try h.expectRequest(1, .GET, "https://monitoring.googleapis.com/v3/projects/my-project/monitoredResourceDescriptors?pageSize=5&pageToken=t", null);
    try testing.expectEqual(null, page.value.next_page_token);
}

test "golden: alerts listed with every option, and one got by id or by name" {
    var h: Harness = undefined;
    try h.init(&.{
        .{ .respond = .{ .body = "{\"alerts\":[{\"name\":\"projects/my-project/alerts/0.oe0ehmpm95z2\",\"state\":\"OPEN\",\"openTime\":\"2026-10-19T14:02:11.311Z\"}],\"totalSize\":7,\"nextPageToken\":\"n\"}" } },
        .{ .respond = .{ .body = "{}" } },
        .{ .respond = .{ .body = "{\"alerts\":[],\"totalSize\":0}" } },
        .{ .respond = .{ .body = "{\"name\":\"projects/my-project/alerts/0.oe0ehmpm95z2\",\"state\":\"CLOSED\",\"openTime\":\"2026-10-19T14:02:11.311Z\",\"closeTime\":\"2026-10-19T15:00:00Z\"}" } },
        .{ .respond = .{ .body = "{\"name\":\"projects/my-project/alerts/0.oe0ehmpm95z2\",\"state\":\"OPEN\",\"openTime\":\"2026-10-19T14:02:11.311Z\"}" } },
    }, .{});
    defer h.deinit();
    var page = try h.client.listAlerts(.{ .filter = "state=\"OPEN\"", .order_by = .open_time, .page_size = 2, .page_token = "t" });
    defer page.deinit();
    try h.expectRequest(0, .GET, "https://monitoring.googleapis.com/v3/projects/my-project/alerts?filter=state%3D%22OPEN%22&orderBy=open_time%20asc&pageSize=2&pageToken=t", null);
    try testing.expectEqual(1, page.value.alerts.len);
    try testing.expectEqualStrings("0.oe0ehmpm95z2", page.value.alerts[0].id);
    try testing.expectEqual(types.AlertState.open, page.value.alerts[0].state);
    try testing.expectEqual(7, page.value.total_size.?);
    try testing.expectEqualStrings("n", page.value.next_page_token.?);
    var empty = try h.client.listAlerts(.{});
    defer empty.deinit();
    try h.expectRequest(1, .GET, "https://monitoring.googleapis.com/v3/projects/my-project/alerts", null);
    try testing.expectEqual(0, empty.value.alerts.len);
    try testing.expectEqual(null, empty.value.total_size);
    var open = try h.client.listAlerts(.{ .open_only = true });
    defer open.deinit();
    try h.expectRequest(2, .GET, "https://monitoring.googleapis.com/v3/projects/my-project/alerts?filter=state%3D%22OPEN%22", null);
    var got = try h.client.getAlert("0.oe0ehmpm95z2");
    defer got.deinit();
    try h.expectRequest(3, .GET, "https://monitoring.googleapis.com/v3/projects/my-project/alerts/0.oe0ehmpm95z2", null);
    try testing.expectEqual(types.AlertState.closed, got.value.state);
    try testing.expect(got.value.close_time != null);
    var by_name = try h.client.getAlert("projects/my-project/alerts/0.oe0ehmpm95z2");
    defer by_name.deinit();
    try h.expectRequest(4, .GET, "https://monitoring.googleapis.com/v3/projects/my-project/alerts/0.oe0ehmpm95z2", null);
    try testing.expectEqualStrings("0.oe0ehmpm95z2", by_name.value.id);
}

const policy_url = "https://monitoring.googleapis.com/v3/projects/my-project/alertPolicies/9594883664150561401";

test "golden: alert policies listed, got by id and by name, disabled and enabled" {
    var h: Harness = undefined;
    try h.init(&.{
        .{ .respond = .{ .body = production.policy_page } },
        .{ .respond = .{ .body = "{}" } },
        .{ .respond = .{ .body = production.policy_threshold } },
        .{ .respond = .{ .body = production.policy_threshold } },
        .{ .respond = .{ .body = production.policy_disabled } },
        .{ .respond = .{ .body = production.policy_threshold } },
    }, .{});
    defer h.deinit();
    var page = try h.client.listAlertPolicies(.{ .filter = "enabled=false AND display_name=starts_with(\"zigps-\")", .order_by = "-display_name", .page_size = 1, .page_token = "t" });
    defer page.deinit();
    try h.expectRequest(0, .GET, "https://monitoring.googleapis.com/v3/projects/my-project/alertPolicies?filter=enabled%3Dfalse%20AND%20display_name%3Dstarts_with%28%22zigps-%22%29&orderBy=-display_name&pageSize=1&pageToken=t", null);
    try testing.expectEqual(1, page.value.policies.len);
    try testing.expectEqual(6, page.value.total_size.?);
    var empty = try h.client.listAlertPolicies(.{});
    defer empty.deinit();
    try h.expectRequest(1, .GET, "https://monitoring.googleapis.com/v3/projects/my-project/alertPolicies", null);
    try testing.expectEqual(0, empty.value.policies.len);
    var got = try h.client.getAlertPolicy("9594883664150561401");
    defer got.deinit();
    try h.expectRequest(2, .GET, policy_url, null);
    try testing.expectEqualStrings("zigps-d5b8f4-threshold", got.value.display_name);
    var by_name = try h.client.getAlertPolicy("projects/my-project/alertPolicies/9594883664150561401");
    by_name.deinit();
    try h.expectRequest(3, .GET, policy_url, null);
    var off = try h.client.setAlertPolicyEnabled("9594883664150561401", false);
    defer off.deinit();
    try h.expectRequest(4, .PATCH, policy_url ++ "?updateMask=enabled", "{\"enabled\":false}");
    try testing.expect(!off.value.enabled);
    try testing.expect(off.value.mutated.time.?.nanoseconds > off.value.created.time.?.nanoseconds);
    var on = try h.client.setAlertPolicyEnabled("projects/my-project/alertPolicies/9594883664150561401", true);
    defer on.deinit();
    try h.expectRequest(5, .PATCH, policy_url ++ "?updateMask=enabled", "{\"enabled\":true}");
    try testing.expect(on.value.enabled);
}

test "setAlertPolicyEnabledRequest: byte for byte what the patch sends, and sends nothing" {
    for ([_]bool{ false, true }) |enabled| {
        var h: Harness = undefined;
        try h.init(&.{.{ .respond = .{ .body = production.policy_threshold } }}, .{});
        defer h.deinit();
        var prepared = try h.client.setAlertPolicyEnabledRequest("9594883664150561401", enabled);
        defer prepared.deinit();
        try h.expectRequestCount(0);
        var answered = try h.client.setAlertPolicyEnabled("9594883664150561401", enabled);
        answered.deinit();
        const sent = try h.fake.request(0);
        try testing.expectEqual(sent.method, prepared.value.method);
        try testing.expectEqualStrings(sent.url, prepared.value.url);
        try testing.expectEqualStrings(sent.body.?, prepared.value.body);
    }
}

test "alert policy calls refuse what they will not send, the preview with the same words" {
    var h: Harness = undefined;
    try h.init(&.{}, .{});
    defer h.deinit();
    const c = &h.client;
    try testing.expectError(error.InvalidFilter, c.listAlertPolicies(.{ .filter = "a\nb" }));
    try testing.expectError(error.InvalidFilter, c.listAlertPolicies(.{ .filter = "" }));
    try testing.expectError(error.InvalidOptions, c.listAlertPolicies(.{ .order_by = "a\tb" }));
    try testing.expectEqualStrings("invalid order_by: text without control characters, at most 4096 bytes", h.diag.message());
    try testing.expectError(error.InvalidName, c.listAlertPolicies(.{ .page_token = "a b" }));
    for ([_][]const u8{ "", "a/b", "a b", "projects/other/alertPolicies/9", "projects/my-project/alerts/9" }) |bad| {
        try testing.expectError(error.InvalidName, c.getAlertPolicy(bad));
        try testing.expectError(error.InvalidName, c.setAlertPolicyEnabled(bad, false));
        try testing.expectEqualStrings("invalid alert policy: expected its id, or projects/my-project/alertPolicies/<id>", h.diag.message());
        try testing.expectError(error.InvalidName, c.setAlertPolicyEnabledRequest(bad, false));
        try testing.expectEqualStrings("invalid alert policy: expected its id, or projects/my-project/alertPolicies/<id>", h.diag.message());
    }
    try h.expectRequestCount(0);
}

test "alert policy refusals arrive as errors in production's words" {
    var h: Harness = undefined;
    try h.init(&.{
        .{ .respond = .{ .status = production.policy_unknown_status, .body = production.policy_unknown } },
        .{ .respond = .{ .status = production.policy_patch_unknown_status, .body = production.policy_patch_unknown } },
        .{ .respond = .{ .status = production.policy_filter_severity_status, .body = production.policy_filter_severity } },
        .{ .respond = .{ .status = production.policy_order_desc_word_status, .body = production.policy_order_desc_word } },
        .{ .respond = .{ .status = production.policy_patch_read_scope_status, .body = production.policy_patch_read_scope } },
        .{ .respond = .{ .body = "{\"alertPolicies\":1}" } },
    }, .{});
    defer h.deinit();
    const c = &h.client;
    try testing.expectError(error.NotFound, c.getAlertPolicy("1234567890"));
    try testing.expectEqualStrings("Failed to find alert policy 1234567890 in extractctl.", h.diag.message());
    try testing.expectError(error.NotFound, c.setAlertPolicyEnabled("1234567890", false));
    try testing.expectEqualStrings("Failed to find alert policy 1234567890 in 82150720798.", h.diag.message());
    try testing.expectError(error.InvalidArgument, c.listAlertPolicies(.{ .filter = "severity=\"WARNING\"" }));
    try testing.expect(std.mem.endsWith(u8, h.diag.message(), "No such field: severity."));
    try testing.expectError(error.InvalidArgument, c.listAlertPolicies(.{ .order_by = "display_name desc" }));
    try testing.expectError(error.PermissionDenied, c.setAlertPolicyEnabled("9", true));
    try testing.expectEqualStrings("Request had insufficient authentication scopes.", h.diag.message());
    try testing.expectError(error.InvalidResponse, c.listAlertPolicies(.{}));
    try testing.expectEqualStrings("the alert policy list response could not be decoded", h.diag.message());
    try h.expectRequestCount(6);
}

test "setAlertPolicyEnabled: retried as the reads are, since a repeat answers 200" {
    var h: Harness = undefined;
    try h.init(&.{
        .{ .fail = error.ConnectionResetByPeer },
        .{ .respond = .{ .status = 503, .body = "{\"error\":{\"code\":503,\"message\":\"The service is currently unavailable.\",\"status\":\"UNAVAILABLE\"}}" } },
        .{ .respond = .{ .body = production.policy_disabled } },
    }, .{});
    defer h.deinit();
    var off = try h.client.setAlertPolicyEnabled("9594883664150561401", false);
    defer off.deinit();
    try testing.expect(!off.value.enabled);
    try h.expectRequestCount(3);
    for (0..3) |i| try h.expectRequest(i, .PATCH, policy_url ++ "?updateMask=enabled", "{\"enabled\":false}");
}

test "alert calls refuse what they will not send" {
    var h: Harness = undefined;
    try h.init(&.{}, .{});
    defer h.deinit();
    try testing.expectError(error.InvalidFilter, h.client.listAlerts(.{ .filter = "a\nb" }));
    try testing.expectError(error.InvalidFilter, h.client.listAlerts(.{ .filter = "" }));
    try testing.expectError(error.InvalidOptions, h.client.listAlerts(.{ .open_only = true, .filter = "state=\"OPEN\"" }));
    try testing.expectEqualStrings("open_only writes its own filter; give one or the other", h.diag.message());
    try testing.expectError(error.InvalidName, h.client.listAlerts(.{ .page_token = "a b" }));
    try testing.expectError(error.InvalidName, h.client.getAlert(""));
    try testing.expectError(error.InvalidName, h.client.getAlert("a/b"));
    try testing.expectError(error.InvalidName, h.client.getAlert("a b"));
    try testing.expectError(error.InvalidName, h.client.getAlert("projects/other/alerts/9"));
    try testing.expectEqualStrings("invalid alert: expected its id, or projects/my-project/alerts/<id>", h.diag.message());
    try h.expectRequestCount(0);
}

test "an alert response that cannot be decoded is InvalidResponse, named in Diagnostics" {
    var h: Harness = undefined;
    try h.init(&.{
        .{ .respond = .{ .body = "{\"alerts\":1}" } },
        .{ .respond = .{ .body = "{\"state\":\"OPEN\"}" } },
    }, .{});
    defer h.deinit();
    try testing.expectError(error.InvalidResponse, h.client.listAlerts(.{}));
    try testing.expectEqualStrings("the alert list response could not be decoded", h.diag.message());
    try testing.expectError(error.InvalidResponse, h.client.getAlert("9"));
    try testing.expectEqualStrings("the alert response could not be decoded", h.diag.message());
}

test "descriptor and list calls refuse what they will not send" {
    var h: Harness = undefined;
    try h.init(&.{}, .{});
    defer h.deinit();
    const c = &h.client;
    try testing.expectError(error.InvalidMetricType, c.metric("shop/orders/").get());
    try testing.expectError(error.InvalidMetricType, c.metric("no-path").delete());
    try testing.expectError(error.InvalidMetricType, c.metric("a b/c").create(.{ .kind = .gauge, .value_type = .int64 }));
    try testing.expectError(error.InvalidLabel, c.metric("custom.googleapis.com/g").create(.{ .kind = .gauge, .value_type = .int64, .labels = &.{.{ .key = "a.b" }} }));
    try testing.expectError(error.InvalidOptions, c.metric("custom.googleapis.com/g").create(.{ .kind = .delta, .value_type = .int64 }));
    try testing.expectEqualStrings("invalid descriptor: custom.googleapis.com/ takes no DELTA metrics", h.diag.message());
    try testing.expectError(error.InvalidMetricType, c.listMetrics(.{ .prefix = "a\"b" }));
    try testing.expectError(error.InvalidName, c.listMetrics(.{ .page_token = "a b" }));
    try testing.expectError(error.InvalidName, c.listResourceTypes(.{ .page_token = "" }));
    try testing.expectError(error.InvalidResource, c.resourceType("a/b"));
    try h.expectRequestCount(0);
}

test "a response that cannot be decoded is InvalidResponse, named in Diagnostics" {
    var h: Harness = undefined;
    try h.init(&.{
        .{ .respond = .{ .body = "{\"metricKind\":\"GAUGE\"}" } },
        .{ .respond = .{ .body = "[]" } },
        .{ .respond = .{ .body = "{\"type\":1}" } },
        .{ .respond = .{ .body = "{\"resourceDescriptors\":1}" } },
    }, .{});
    defer h.deinit();
    try testing.expectError(error.InvalidResponse, h.client.metric("custom.googleapis.com/g").get());
    try testing.expectEqualStrings("the metric descriptor response could not be decoded", h.diag.message());
    try testing.expectError(error.InvalidResponse, h.client.listMetrics(.{}));
    try testing.expectError(error.InvalidResponse, h.client.resourceType("global"));
    try testing.expectError(error.InvalidResponse, h.client.listResourceTypes(.{}));
}

test "init refuses what no call could use" {
    var token: core.StaticToken = .{ .token = "t" };
    var diag: Diagnostics = .{};
    const cases = [_]struct { Options, anyerror, []const u8 }{
        .{ .{ .project_id = "Bad Project", .token_provider = token.provider(), .diagnostics = &diag }, error.InvalidName, "invalid project" },
        .{ .{ .project_id = "p", .token_provider = token.provider(), .retry = .{ .max_attempts = 0 }, .diagnostics = &diag }, error.InvalidOptions, "invalid retry policy" },
        .{ .{ .project_id = "p", .token_provider = token.provider(), .user_agent = "a\nb", .diagnostics = &diag }, error.InvalidOptions, "invalid user agent" },
        .{ .{ .project_id = "p", .token_provider = token.provider(), .max_response_bytes = 0, .diagnostics = &diag }, error.InvalidOptions, "max_response_bytes" },
        .{ .{ .project_id = "p", .token_provider = token.provider(), .endpoint = "http://localhost:1", .diagnostics = &diag }, error.InvalidEndpoint, "must use https" },
        .{ .{ .project_id = "p", .token_provider = token.provider(), .endpoint = "https://", .diagnostics = &diag }, error.InvalidEndpoint, "invalid endpoint" },
    };
    for (cases) |c| {
        try testing.expectError(c[1], Client.init(testing.allocator, testing.io, c[0]));
        try testing.expect(std.mem.indexOf(u8, diag.message(), c[2]) != null);
    }
    var client = try Client.init(testing.allocator, testing.io, .{ .project_id = "p", .token_provider = token.provider(), .endpoint = "https://localhost:8443" });
    defer client.deinit();
    try testing.expectEqualStrings("https://localhost:8443", client.base_url);
    try testing.expect(client.http != null);
}

test "every allocation failure is OutOfMemory without leaks" {
    const Run = struct {
        fn calls(gpa: Allocator) !void {
            var fake: test_util.FakeTransport = .init(testing.allocator, &.{
                .{ .respond = .{ .status = production.write_mixed_status, .body = production.write_mixed } },
                .{ .respond = .{ .body = production.descriptor_get } },
                .{ .respond = .{ .body = production.descriptor_get } },
                .{ .respond = .{ .body = "{}" } },
                .{ .respond = .{ .body = "{\"metricDescriptors\":[{\"type\":\"a/b\",\"labels\":[{\"key\":\"k\"}],\"monitoredResourceTypes\":[\"global\"]}],\"nextPageToken\":\"t\"}" } },
                .{ .respond = .{ .body = production.resource_generic_task } },
                .{ .respond = .{ .body = "{\"resourceDescriptors\":[{\"type\":\"global\",\"labels\":[{\"key\":\"project_id\"}]}]}" } },
                .{ .respond = .{ .body = production.policy_page } },
                .{ .respond = .{ .body = production.policy_two } },
                .{ .respond = .{ .body = production.policy_disabled } },
            });
            defer fake.deinit();
            var tokens: test_util.FakeTokenProvider = .{};
            var clock: test_util.FakeClock = .{};
            var client = try Client.init(gpa, clock.io(), .{ .project_id = "my-project", .token_provider = tokens.provider(), .transport = fake.transport() });
            defer client.deinit();
            const dist: types.TimeSeries = .{ .metric_type = "custom.googleapis.com/h", .metric_labels = &.{.{ .key = "k", .value = "v" }}, .resource = task, .kind = .cumulative, .start = t0, .end = t1, .value = .{ .distribution = .{ .count = 1, .mean = 1, .buckets = .{ .explicit = &.{ 1, 2 } }, .bucket_counts = &.{ 0, 1 } } } };
            var w = try client.write(&.{ gauge, dist, .{ .metric_type = "custom.googleapis.com/x", .resource = .global, .kind = .gauge, .end = t1, .value = .{ .double = 1.5 } } });
            w.deinit();
            const m = client.metric("custom.googleapis.com/zigps-m0-62b2c8/gauge");
            var made = try m.create(.{ .kind = .gauge, .value_type = .int64, .labels = &.{.{ .key = "k", .description = "d" }} });
            made.deinit();
            var got = try m.get();
            got.deinit();
            try m.delete();
            var page = try client.listMetrics(.{ .prefix = "a", .page_token = "t" });
            page.deinit();
            var r = try client.resourceType("generic_task");
            r.deinit();
            var rpage = try client.listResourceTypes(.{});
            rpage.deinit();
            var policies = try client.listAlertPolicies(.{ .filter = "enabled=true", .order_by = "name", .page_size = 1 });
            policies.deinit();
            var policy = try client.getAlertPolicy("7136103533907925714");
            policy.deinit();
            var off = try client.setAlertPolicyEnabled("9594883664150561401", false);
            off.deinit();
            var prepared = try client.setAlertPolicyEnabledRequest("9594883664150561401", true);
            prepared.deinit();
        }
    };
    try testing.checkAllAllocationFailures(test_util.no_grow_allocator, Run.calls, .{});
}

/// 2026-10-18T13:46:35.949Z.
const fuzz_now_ns: i96 = 1_792_331_195_949 * std.time.ns_per_ms;

fn randomSeries(g: *test_util.ByteGen, a: Allocator, i: usize) !types.TimeSeries {
    const metric_type = g.pick([]const u8, &.{ "custom.googleapis.com/a", "custom.googleapis.com/b/c", "external.googleapis.com/d", "custom.googleapis.com/a/b" });
    var labels: std.ArrayList(types.Label) = .empty;
    // A label of its own, so each series' points can be found again.
    try labels.append(a, .{ .key = "i", .value = try std.fmt.allocPrint(a, "{d}", .{i}) });
    for (0..g.intRange(usize, 0, 2)) |_| {
        const key = g.pick([]const u8, &.{ "region", "Zone", "1bad", "a_b" });
        for (labels.items) |l| {
            if (std.mem.eql(u8, l.key, key)) break;
        } else {
            var vbuf: [12]u8 = undefined;
            try labels.append(a, .{ .key = key, .value = try a.dupe(u8, g.utf8(&vbuf, 12)) });
        }
    }
    const resource: types.Resource = switch (g.intRange(u8, 0, 3)) {
        0 => .global,
        1 => .{ .generic_task = .{ .location = g.pick([]const u8, &.{ "us-central1", "europe-west1-b", "nowhere-1" }), .namespace = "n", .job = "j", .task_id = "t" } },
        2 => .{ .gce_instance = .{ .zone = "us-central1-a", .instance_id = "42" } },
        else => .{ .k8s_node = .{ .location = "global", .cluster_name = "c", .node_name = "n" } },
    };
    const kind = g.pick(types.Kind, &.{ .gauge, .gauge, .cumulative, .delta });
    const end_offset_ms = g.pick(i64, &.{ 0, -1_000, -3_600_000, -26 * 3_600_000, 4 * 60_000, 6 * 60_000 });
    const end: std.Io.Timestamp = .{ .nanoseconds = fuzz_now_ns + @as(i96, end_offset_ms) * std.time.ns_per_ms + g.intRange(u32, 0, 999_999) };
    const start: ?std.Io.Timestamp = switch (g.intRange(u8, 0, 3)) {
        0 => null,
        1 => end,
        2 => .{ .nanoseconds = end.nanoseconds - std.time.ns_per_ms },
        else => .{ .nanoseconds = end.nanoseconds - 60 * std.time.ns_per_s },
    };
    const value: types.Value = switch (g.intRange(u8, 0, 4)) {
        0 => .{ .bool = g.boolean() },
        1 => .{ .int64 = @bitCast(g.int(u64)) },
        2 => .{ .double = g.pick(f64, &.{ 0, -0.0, 1.5, -2.25e-300, 1e300, std.math.nan(f64), std.math.inf(f64), @as(f64, @floatFromInt(@as(i32, @bitCast(g.int(u32))))) / 7 }) },
        3 => blk: {
            var sbuf: [24]u8 = undefined;
            break :blk .{ .string = try a.dupe(u8, g.utf8(&sbuf, 24)) };
        },
        else => blk: {
            const counts = try a.alloc(u64, g.intRange(usize, 0, 4));
            var count: u64 = 0;
            for (counts) |*c| {
                c.* = g.intRange(u64, 0, 5);
                count += c.*;
            }
            break :blk .{ .distribution = .{
                .count = count,
                .mean = if (count == 0) 0 else 1.5,
                .sum_of_squared_deviation = if (count == 0) 0 else 0.25,
                .buckets = g.pick(types.Distribution.Buckets, &.{
                    .{ .explicit = &.{ 1, 2, 4 } },
                    .{ .linear = .{ .num_finite = 2, .width = 0.5, .offset = -1 } },
                    .{ .exponential = .{ .num_finite = 3, .growth_factor = 1.5, .scale = 2 } },
                }),
                .bucket_counts = counts,
            } };
        },
    };
    return .{ .metric_type = metric_type, .metric_labels = labels.items, .resource = resource, .kind = kind, .start = start, .end = end, .value = value };
}

fn sameValue(a: types.Value, b: types.Value) bool {
    if (std.meta.activeTag(a) != std.meta.activeTag(b)) return false;
    return switch (a) {
        .bool => |x| x == b.bool,
        .int64 => |x| x == b.int64,
        .double => |x| (std.math.isNan(x) and std.math.isNan(b.double)) or @as(u64, @bitCast(x)) == @as(u64, @bitCast(b.double)),
        .string => |x| std.mem.eql(u8, x, b.string),
        .distribution => |x| x.count == b.distribution.count and x.mean == b.distribution.mean and
            x.sum_of_squared_deviation == b.distribution.sum_of_squared_deviation and
            std.mem.eql(u64, x.bucket_counts, b.distribution.bucket_counts) and
            sameBuckets(x.buckets, b.distribution.buckets),
    };
}

fn sameBuckets(a: types.Distribution.Buckets, b: types.Distribution.Buckets) bool {
    if (std.meta.activeTag(a) != std.meta.activeTag(b)) return false;
    return switch (a) {
        .explicit => |x| std.mem.eql(f64, x, b.explicit),
        .linear => |x| x.num_finite == b.linear.num_finite and x.width == b.linear.width and x.offset == b.linear.offset,
        .exponential => |x| x.num_finite == b.exponential.num_finite and x.growth_factor == b.exponential.growth_factor and x.scale == b.exponential.scale,
    };
}

/// Any series: the client refuses it before sending, or the fake, which
/// parses requests with code of its own, keeps exactly what was sent, or
/// says in a summary why not, and the counts add up. What it kept, a read
/// gives back exactly.
fn writeRoundTripProperty(_: void, input: []const u8) !void {
    const gpa = test_util.propertyAllocator();
    var g: test_util.ByteGen = .init(input);
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    const a = arena.allocator();
    var clock: test_util.FakeClock = .{ .now_ns = fuzz_now_ns };
    var fake: FakeMonitoring = .init(gpa, clock.io(), .{});
    defer fake.deinit();
    var token: core.StaticToken = .{ .token = "t" };
    var client = try Client.init(gpa, clock.io(), .{ .project_id = "my-project", .token_provider = token.provider(), .transport = fake.transport() });
    defer client.deinit();

    const series = try a.alloc(types.TimeSeries, g.intRange(usize, 1, 4));
    for (series, 0..) |*s, i| s.* = try randomSeries(&g, a, i);
    if (series.len > 1 and g.intRange(u8, 0, 7) == 0) series[series.len - 1] = series[0];

    var result = client.write(series) catch |err| switch (err) {
        error.InvalidMetricType, error.InvalidLabel, error.InvalidPoint, error.InvalidResource, error.DuplicateSeries => {
            try testing.expectEqual(0, fake.callCount());
            return;
        },
        // A DELTA or STRING metric under external.googleapis.com/, which
        // production makes for no program, refuses the whole request.
        error.InvalidArgument => {
            for (series) |s| {
                if (std.mem.startsWith(u8, s.metric_type, "external.googleapis.com/") and (s.kind == .delta or s.value == .string)) break;
            } else return err;
            try testing.expectEqual(0, fake.pointCount());
            return;
        },
        else => return err,
    };
    defer result.deinit();
    const r = result.value;
    var refused: u32 = 0;
    for (r.refused) |x| refused += x.points;
    try testing.expectEqual(r.points, r.written + refused);
    try testing.expectEqual(r.written, fake.pointCount());
    try testing.expectEqual(r.ok(), r.message.len == 0);
    for (series) |s| {
        const kept = try fake.points(a, s.metric_type, s.metric_labels);
        if (kept.len == 0) continue;
        try testing.expectEqual(1, kept.len);
        const end_us = @divFloor(s.end.nanoseconds, std.time.ns_per_us) * std.time.ns_per_us;
        try testing.expectEqual(end_us, kept[0].end.nanoseconds);
        try testing.expect(sameValue(s.value, kept[0].value));

        var page = try client.metric(s.metric_type).read(.{
            .start = .{ .nanoseconds = end_us - std.time.ns_per_s },
            .end = .{ .nanoseconds = end_us },
            .filter = .{ .metric_labels = &.{.{ .key = "i", .value = s.metric_labels[0].value }} },
        });
        defer page.deinit();
        try testing.expectEqual(1, page.value.series.len);
        const got = page.value.series[0];
        try testing.expectEqual(s.kind, got.kind);
        try testing.expectEqual(s.value.valueType(), got.value_type);
        try testing.expectEqual(end_us, got.points[0].end.nanoseconds);
        try testing.expect(sameValue(s.value, got.points[0].value.?));
        for (s.metric_labels) |l| try testing.expectEqualStrings(l.value, got.label(l.key).?);
    }
}

test "fuzz write round trip: refused before sending, or kept exactly as sent, or refused in a summary" {
    try test_util.fuzzBytes({}, writeRoundTripProperty, .{ .corpus = &.{
        "",
        "\x00\x00\x00\x00\x00\x00\x00\x00\x01\x00",
        "\x02\x01\x02\x03\x04\x05\x06\x07\x08\x09\x0a\x0b\x0c\x0d\x0e\x0f\x10\x11\x12\x13\x14\x15\x16\x17\x18\x19\x1a\x1b\x1c\x1d\x1e\x1f",
    } });
}

test "init: every allocation failure with the built-in transport is OutOfMemory without leaks" {
    const Run = struct {
        fn build(gpa: Allocator) !void {
            var token: core.StaticToken = .{ .token = "t" };
            var client = try Client.init(gpa, testing.io, .{ .project_id = "p", .token_provider = token.provider() });
            client.deinit();
        }
    };
    try testing.checkAllAllocationFailures(testing.allocator, Run.build, .{});
}
