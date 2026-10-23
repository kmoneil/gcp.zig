//! A BigQuery Data Transfer client: the locations a project's transfer
//! configs live in, the configs (scheduled queries among them), their
//! runs, and a run's messages.
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
const PreparedRequest = core.PreparedRequest;
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

pub const default_endpoint = "https://bigquerydatatransfer.googleapis.com";

pub const Options = struct {
    /// Required: the project whose locations and configs are listed, an
    /// id or a number. A config's or a run's name names its own project.
    project_id: []const u8,
    /// Required. Data Transfer has no emulator, so there is no
    /// unauthenticated mode.
    token_provider: TokenProvider,
    /// The OAuth scope asked of the token provider for every call. A
    /// provider made from a key file, workload identity or impersonation is
    /// fixed to the scope its first token was minted for
    /// (`auth.Credentials.bindsScopes`), so a client asks for one only.
    scope: rpc.Scope = .bigquery,
    /// Overrides the host: a test server, say. Must be `https`, since it
    /// receives credentials.
    endpoint: ?[]const u8 = null,
    /// Sends the credentials' quota project as `x-goog-user-project`, as
    /// every module does.
    send_quota_project: bool = true,
    /// 5xx, 429 and dropped connections are retried, on the reads.
    retry: RetryPolicy = .{},
    /// How long one request may take before it is `error.TimedOut`, which
    /// is retried. 0 removes the limit.
    request_timeout_ms: u32 = 30_000,
    /// A response whose decompressed body is larger fails with
    /// `error.ResponseTooLarge`. Used by the built-in transport; a
    /// transport passed in keeps its own limit.
    max_response_bytes: usize = core.transport.default_max_response_bytes,
    /// Printable ASCII.
    user_agent: []const u8 = "zig-gcp-datatransfer/0.58",
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

/// The locations the project's configs can live in: `us`, `europe`, the
/// regions, and BigQuery Omni's `aws-` and `azure-` ones, 54 on one page
/// when measured. Configs are listed one location at a time, and
/// production has no value for every location at once, so a console walks
/// these.
pub fn listLocations(self: *Client, options: types.ListLocationsOptions) Error!types.Owned(types.LocationPage) {
    rpc.begin(self);
    try self.checkToken(options.page_token);
    var scratch: std.heap.ArenaAllocator = .init(self.gpa);
    defer scratch.deinit();
    const a = scratch.allocator();
    var w: std.Io.Writer.Allocating = .init(a);
    w.writer.writeAll(try names.locations(a, self.project)) catch return error.OutOfMemory;
    var params: core.query.Params = .init(&w.writer);
    params.addOptional("pageToken", options.page_token) catch return error.OutOfMemory;
    return self.call(types.LocationPage, a, w.written(), codec.decodeLocationPage, "location list");
}

/// One page of the configs in one location, the project's own, by data
/// source when asked (`scheduled_query` for scheduled queries alone). A
/// list carries no owner (measured): `getTransferConfig` does.
pub fn listTransferConfigs(self: *Client, location: []const u8, options: types.ListConfigsOptions) Error!types.Owned(types.TransferConfigPage) {
    rpc.begin(self);
    try self.checkLocation(location);
    try self.checkToken(options.page_token);
    for (options.data_sources) |id| if (!validate.isDataSourceId(id)) {
        if (self.diagnostics) |d| d.print("invalid data source id: expected lower case letters, digits, _ and -, such as scheduled_query", .{});
        return error.InvalidName;
    };
    var scratch: std.heap.ArenaAllocator = .init(self.gpa);
    defer scratch.deinit();
    const a = scratch.allocator();
    var w: std.Io.Writer.Allocating = .init(a);
    w.writer.writeAll(try names.configs(a, self.project, location)) catch return error.OutOfMemory;
    var params: core.query.Params = .init(&w.writer);
    for (options.data_sources) |id| params.add("dataSourceIds", id) catch return error.OutOfMemory;
    params.addNonZero("pageSize", options.page_size) catch return error.OutOfMemory;
    params.addOptional("pageToken", options.page_token) catch return error.OutOfMemory;
    return self.call(types.TransferConfigPage, a, w.written(), codec.decodeConfigPage, "config list");
}

/// One config, by its name as a list or get gave it.
pub fn getTransferConfig(self: *Client, name: []const u8) Error!types.Owned(types.TransferConfig) {
    rpc.begin(self);
    const config = try self.configOf(name);
    var scratch: std.heap.ArenaAllocator = .init(self.gpa);
    defer scratch.deinit();
    const a = scratch.allocator();
    return self.call(types.TransferConfig, a, try names.configPath(a, config, &.{}), codec.decodeConfig, "config");
}

/// One page of a config's runs, by state, every attempt or the latest of
/// each day.
pub fn listRuns(self: *Client, config_name: []const u8, options: types.ListRunsOptions) Error!types.Owned(types.TransferRunPage) {
    rpc.begin(self);
    const config = try self.configOf(config_name);
    try self.checkToken(options.page_token);
    var scratch: std.heap.ArenaAllocator = .init(self.gpa);
    defer scratch.deinit();
    const a = scratch.allocator();
    var w: std.Io.Writer.Allocating = .init(a);
    w.writer.writeAll(try names.configPath(a, config, &.{"runs"})) catch return error.OutOfMemory;
    var params: core.query.Params = .init(&w.writer);
    for (options.states) |state| {
        const wire = state.wireName() orelse {
            if (self.diagnostics) |d| d.print("invalid state filter: .unknown is no state a list can filter by", .{});
            return error.InvalidOptions;
        };
        params.add("states", wire) catch return error.OutOfMemory;
    }
    if (options.latest_only) params.add("runAttempt", "LATEST") catch return error.OutOfMemory;
    params.addNonZero("pageSize", options.page_size) catch return error.OutOfMemory;
    params.addOptional("pageToken", options.page_token) catch return error.OutOfMemory;
    return self.call(types.TransferRunPage, a, w.written(), codec.decodeRunPage, "run list");
}

/// One run, by its name.
pub fn getRun(self: *Client, name: []const u8) Error!types.Owned(types.TransferRun) {
    rpc.begin(self);
    const run = try self.runOf(name);
    var scratch: std.heap.ArenaAllocator = .init(self.gpa);
    defer scratch.deinit();
    const a = scratch.allocator();
    return self.call(types.TransferRun, a, try names.configPath(a, run.config, &.{ "runs", run.id }), codec.decodeRun, "run");
}

/// One page of a run's messages, by severity: every one when none is
/// asked.
pub fn listMessages(self: *Client, run_name: []const u8, options: types.ListMessagesOptions) Error!types.Owned(types.TransferMessagePage) {
    rpc.begin(self);
    const run = try self.runOf(run_name);
    try self.checkToken(options.page_token);
    var scratch: std.heap.ArenaAllocator = .init(self.gpa);
    defer scratch.deinit();
    const a = scratch.allocator();
    var w: std.Io.Writer.Allocating = .init(a);
    w.writer.writeAll(try names.configPath(a, run.config, &.{ "runs", run.id, "transferLogs" })) catch return error.OutOfMemory;
    var params: core.query.Params = .init(&w.writer);
    for (options.severities) |severity| {
        const wire = severity.wireName() orelse {
            if (self.diagnostics) |d| d.print("invalid severity filter: .unknown is no severity a list can filter by", .{});
            return error.InvalidOptions;
        };
        params.add("messageTypes", wire) catch return error.OutOfMemory;
    }
    params.addNonZero("pageSize", options.page_size) catch return error.OutOfMemory;
    params.addOptional("pageToken", options.page_token) catch return error.OutOfMemory;
    return self.call(types.TransferMessagePage, a, w.written(), codec.decodeMessagePage, "message list");
}

/// Runs the config now (`startManualRuns`): answers the run it started,
/// `PENDING`. When measured, a run read `RUNNING` within 3 s and a
/// scheduled query of literals `SUCCEEDED` 75 s after it started; follow
/// it with `getRun` until `ended()`. A disabled config is refused, 400
/// `error.InvalidArgument`: "Transfer is disabled. Please enable the
/// transfer config before starting transfer runs." Takes
/// `bigquery.transfers.update` (Editor, BigQuery Admin; not BigQuery
/// User), and a client whose scope is not `.cloud_platform_read_only`,
/// which production refuses a run now.
///
/// Sent once: a run now has no request id, and production made a second
/// run of the same time when asked twice (measured), as Google's clients,
/// which never retry it, expect. Only a refused connection or a failed
/// name lookup is tried again. After any other failure, list the config's
/// runs, newest run time first, to see whether it started.
pub fn startManualRun(self: *Client, config_name: []const u8, options: types.StartManualRunOptions) Error!types.Owned(types.StartedRuns) {
    rpc.begin(self);
    var scratch: std.heap.ArenaAllocator = .init(self.gpa);
    defer scratch.deinit();
    const a = scratch.allocator();
    var request = try self.startCall(a, config_name, options);
    request.retryable = core.rpc.unsentOnly;
    var result: types.Owned(types.StartedRuns) = try .init(self.gpa);
    errdefer result.deinit();
    const body = try rpc.execute(self, result.arena, request);
    result.value = codec.decodeStarted(result.arena.allocator(), a, body) catch |err|
        return rpc.decodeFailed(self, err, "run now");
    return result;
}

/// The request `startManualRun` sends for the same arguments, built
/// without sending it, after the same checks with the same errors: to
/// show before the call, or to record after it. Credentials and other
/// headers are not part of it. With `options.run_time` null each reads
/// the clock, so give both the same time to send exactly what was shown.
pub fn startManualRunRequest(self: *Client, config_name: []const u8, options: types.StartManualRunOptions) Error!types.Owned(PreparedRequest) {
    rpc.begin(self);
    var result: types.Owned(PreparedRequest) = try .init(self.gpa);
    errdefer result.deinit();
    const a = result.arena.allocator();
    result.value = try .fromCall(a, self.base_url, try self.startCall(a, config_name, options));
    return result;
}

/// The call `startManualRun` sends: `POST {name}:startManualRuns` with
/// `{"requestedRunTime": "<RFC 3339>"}`.
fn startCall(self: *Client, arena: Allocator, config_name: []const u8, options: types.StartManualRunOptions) Error!rpc.Call {
    if (self.scope == .cloud_platform_read_only) {
        if (self.diagnostics) |d| d.print("this client asks for cloud-platform.read-only, which production refuses a run now; give Options.scope .bigquery or .cloud_platform", .{});
        return error.InvalidOptions;
    }
    const config = try self.configOf(config_name);
    const when = options.run_time orelse std.Io.Clock.real.now(self.io);
    // To the microsecond, as production echoes a run time.
    const micros: std.Io.Timestamp = .{ .nanoseconds = when.nanoseconds - @mod(when.nanoseconds, std.time.ns_per_us) };
    if (!core.timestamp.inRange(micros)) {
        if (self.diagnostics) |d| d.print("invalid run time: outside the years 1 to 9999", .{});
        return error.InvalidOptions;
    }
    var buf: [core.timestamp.max_len]u8 = undefined;
    const text = core.timestamp.format(&buf, micros);
    const path = try std.mem.concat(arena, u8, &.{ try names.configPath(arena, config, &.{}), ":startManualRuns" });
    const body = try std.fmt.allocPrint(arena, "{{\"requestedRunTime\":\"{s}\"}}", .{text});
    return .{ .method = .POST, .path = path, .body = body };
}

/// A config's name in this client's project, for a caller that has its
/// location and id but not the name a list gave: the project as the
/// client was given it, which production takes as readily as its number
/// (measured).
pub fn configName(self: *Client, arena: Allocator, location: []const u8, id: []const u8) Error![]const u8 {
    try self.checkLocation(location);
    if (!validate.isResourceId(id)) {
        if (self.diagnostics) |d| d.print("invalid config id: expected letters, digits, - and _", .{});
        return error.InvalidName;
    }
    return names.configName(arena, .{ .project = self.project, .location = location, .id = id });
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

fn configOf(self: *Client, name: []const u8) Error!names.ConfigName {
    return names.parseConfig(name) catch {
        if (self.diagnostics) |d| d.print("invalid config name: expected projects/{{p}}/locations/{{l}}/transferConfigs/{{id}} as a list or get gave it", .{});
        return error.InvalidName;
    };
}

fn runOf(self: *Client, name: []const u8) Error!names.RunName {
    return names.parseRun(name) catch {
        if (self.diagnostics) |d| d.print("invalid run name: expected projects/{{p}}/locations/{{l}}/transferConfigs/{{id}}/runs/{{run}} as a list or get gave it", .{});
        return error.InvalidName;
    };
}

fn checkLocation(self: *Client, location: []const u8) Error!void {
    if (!validate.isLocation(location)) {
        if (self.diagnostics) |d| d.print("invalid location: expected one location such as us, europe or us-east1 (production has none for every location)", .{});
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
const base = "https://bigquerydatatransfer.googleapis.com/v1/";
const manual = "projects/82150720798/locations/us/transferConfigs/6ad99c4e-0000-2bb7-b042-14223bbd2862";
const run_ok = manual ++ "/runs/6ae65981-0000-2805-bdde-883d24fa83a4";

test "golden: locations, configs, runs and messages, as milestone 0 asked them" {
    var h: Harness = undefined;
    try h.init(&.{
        .{ .respond = .{ .body = production.locations_page } },
        .{ .respond = .{ .body = production.configs_page } },
        .{ .respond = .{ .body = production.config_manual } },
        .{ .respond = .{ .body = production.runs_page } },
        .{ .respond = .{ .body = production.run_succeeded } },
        .{ .respond = .{ .body = production.messages_succeeded } },
        .{ .respond = .{ .body = production.configs_page_token } },
        .{ .respond = .{ .body = production.runs_latest } },
        .{ .respond = .{ .body = production.messages_failed_error } },
        .{ .respond = .{ .body = production.locations_page } },
    });
    defer h.deinit();
    const c = &h.client;

    var locations = try c.listLocations(.{});
    defer locations.deinit();
    try h.expectRequest(0, .GET, base ++ "projects/my-project/locations");
    try testing.expectEqual(54, locations.value.locations.len);

    var configs = try c.listTransferConfigs("us", .{});
    defer configs.deinit();
    try h.expectRequest(1, .GET, base ++ "projects/my-project/locations/us/transferConfigs");
    try testing.expectEqual(3, configs.value.configs.len);

    var config = try c.getTransferConfig(configs.value.configs[0].name);
    defer config.deinit();
    try h.expectRequest(2, .GET, base ++ manual);
    try testing.expectEqualStrings("zig-gcp@extractctl.iam.gserviceaccount.com", config.value.owner_email);

    var runs = try c.listRuns(manual, .{});
    defer runs.deinit();
    try h.expectRequest(3, .GET, base ++ manual ++ "/runs");
    try testing.expectEqual(8, runs.value.runs.len);

    var run = try c.getRun(runs.value.runs[3].name);
    defer run.deinit();
    try h.expectRequest(4, .GET, base ++ run_ok);
    try testing.expect(run.value.succeeded());

    var messages = try c.listMessages(run_ok, .{});
    defer messages.deinit();
    try h.expectRequest(5, .GET, base ++ run_ok ++ "/transferLogs");
    try testing.expectEqual(5, messages.value.messages.len);

    // Every option.
    var filtered = try c.listTransferConfigs("us-east1", .{ .data_sources = &.{ "scheduled_query", "google_cloud_storage" }, .page_size = 1, .page_token = "CgwI" });
    defer filtered.deinit();
    try h.expectRequest(6, .GET, base ++ "projects/my-project/locations/us-east1/transferConfigs?dataSourceIds=scheduled_query&dataSourceIds=google_cloud_storage&pageSize=1&pageToken=CgwI");
    var latest = try c.listRuns(manual, .{ .states = &.{ .succeeded, .failed }, .latest_only = true, .page_size = 2, .page_token = "t" });
    defer latest.deinit();
    try h.expectRequest(7, .GET, base ++ manual ++ "/runs?states=SUCCEEDED&states=FAILED&runAttempt=LATEST&pageSize=2&pageToken=t");
    var errors_only = try c.listMessages(run_ok, .{ .severities = &.{ .@"error", .warning }, .page_size = 10, .page_token = "m" });
    defer errors_only.deinit();
    try h.expectRequest(8, .GET, base ++ run_ok ++ "/transferLogs?messageTypes=ERROR&messageTypes=WARNING&pageSize=10&pageToken=m");
    var next = try c.listLocations(.{ .page_token = "L2" });
    defer next.deinit();
    try h.expectRequest(9, .GET, base ++ "projects/my-project/locations?pageToken=L2");
}

test "configName: this project's config, by location and id" {
    var h: Harness = undefined;
    try h.init(&.{});
    defer h.deinit();
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    try testing.expectEqualStrings("projects/my-project/locations/us/transferConfigs/6ad99c4e-0000-2bb7-b042-14223bbd2862", try h.client.configName(arena.allocator(), "us", "6ad99c4e-0000-2bb7-b042-14223bbd2862"));
    try testing.expectError(error.InvalidName, h.client.configName(arena.allocator(), "-", "x"));
    try testing.expectError(error.InvalidName, h.client.configName(arena.allocator(), "us", "a/b"));
    try testing.expectEqualStrings("invalid config id: expected letters, digits, - and _", h.diag.message());
}

test "the reads refuse what they will not send" {
    var h: Harness = undefined;
    try h.init(&.{});
    defer h.deinit();
    const c = &h.client;
    try testing.expectError(error.InvalidName, c.listTransferConfigs("-", .{}));
    try testing.expectEqualStrings("invalid location: expected one location such as us, europe or us-east1 (production has none for every location)", h.diag.message());
    try testing.expectError(error.InvalidName, c.listTransferConfigs("us/east1", .{}));
    try testing.expectError(error.InvalidName, c.listTransferConfigs("us", .{ .data_sources = &.{"Scheduled Query"} }));
    try testing.expectEqualStrings("invalid data source id: expected lower case letters, digits, _ and -, such as scheduled_query", h.diag.message());
    try testing.expectError(error.InvalidName, c.listTransferConfigs("us", .{ .page_token = "a b" }));
    try testing.expectError(error.InvalidName, c.listLocations(.{ .page_token = "a\n" }));
    // A regionless name, which production answers only for the US.
    try testing.expectError(error.InvalidName, c.getTransferConfig("projects/p/transferConfigs/6ad99c4e"));
    try testing.expectEqualStrings("invalid config name: expected projects/{p}/locations/{l}/transferConfigs/{id} as a list or get gave it", h.diag.message());
    try testing.expectError(error.InvalidName, c.listRuns("projects/p/locations/us/transferConfigs/x/runs/r", .{}));
    try testing.expectError(error.InvalidName, c.getRun(manual));
    try testing.expectEqualStrings("invalid run name: expected projects/{p}/locations/{l}/transferConfigs/{id}/runs/{run} as a list or get gave it", h.diag.message());
    try testing.expectError(error.InvalidName, c.listMessages(manual ++ "/runs/a?b", .{}));
    try testing.expectError(error.InvalidOptions, c.listRuns(manual, .{ .states = &.{.unknown} }));
    try testing.expectEqualStrings("invalid state filter: .unknown is no state a list can filter by", h.diag.message());
    try testing.expectError(error.InvalidOptions, c.listMessages(run_ok, .{ .severities = &.{.unknown} }));
    try h.expectRequestCount(0);
}

test "the refusals arrive as errors, production's words kept" {
    const words = struct {
        fn of(arena: Allocator, body: []const u8) ![]const u8 {
            const v = try std.json.parseFromSliceLeaky(std.json.Value, arena, body, .{});
            return v.object.get("error").?.object.get("message").?.string;
        }
    };
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var h: Harness = undefined;
    try h.init(&.{
        .{ .respond = .{ .status = production.config_unknown_status, .body = production.config_unknown } },
        .{ .respond = .{ .status = production.config_wrong_location_status, .body = production.config_wrong_location } },
        .{ .respond = .{ .status = production.location_invalid_status, .body = production.location_invalid } },
        .{ .respond = .{ .status = production.run_unknown_status, .body = production.run_unknown } },
        .{ .respond = .{ .status = production.runs_states_invalid_status, .body = production.runs_states_invalid } },
        .{ .respond = .{ .status = production.locations_page_size_status, .body = production.locations_page_size } },
    });
    defer h.deinit();
    const c = &h.client;
    try testing.expectError(error.NotFound, c.getTransferConfig("projects/extractctl/locations/us/transferConfigs/zigps-nobody"));
    try testing.expectEqualStrings(try words.of(a, production.config_unknown), h.diag.message());
    try testing.expectError(error.NotFound, c.getTransferConfig("projects/extractctl/locations/europe/transferConfigs/6ad99c4e-0000-2bb7-b042-14223bbd2862"));
    try testing.expectEqualStrings(try words.of(a, production.config_wrong_location), h.diag.message());
    try testing.expectError(error.InvalidArgument, c.listTransferConfigs("zz-nowhere1", .{}));
    try testing.expectEqualStrings("Request uses an invalid location: zz-nowhere1", h.diag.message());
    try testing.expectError(error.NotFound, c.getRun(manual ++ "/runs/00000000-0000-0000-0000-000000000000"));
    try testing.expectEqualStrings(try words.of(a, production.run_unknown), h.diag.message());
    try testing.expectError(error.InvalidArgument, c.listRuns(manual, .{}));
    try testing.expectError(error.InvalidArgument, c.listLocations(.{}));
    try testing.expectEqualStrings("Request contains an invalid argument.", h.diag.message());
    // Each refusal is final.
    try h.expectRequestCount(6);
}

test "the reads are retried as core retries them" {
    const unavailable: test_util.FakeTransport.Reply = .{ .respond = .{ .status = 503, .body = "{\"error\":{\"code\":503,\"message\":\"The service is currently unavailable.\",\"status\":\"UNAVAILABLE\"}}" } };
    var h: Harness = undefined;
    try h.init(&.{
        unavailable,
        .{ .respond = .{ .body = production.config_manual } },
        .{ .fail = error.ConnectionResetByPeer },
        .{ .respond = .{ .body = production.runs_page } },
    });
    defer h.deinit();
    var config = try h.client.getTransferConfig(manual);
    config.deinit();
    var runs = try h.client.listRuns(manual, .{});
    runs.deinit();
    try h.expectRequestCount(4);
}

test "a response that cannot be decoded is InvalidResponse, named in Diagnostics" {
    var h: Harness = undefined;
    try h.init(&.{
        .{ .respond = .{ .body = "{\"locations\":1}" } },
        .{ .respond = .{ .body = "{\"transferConfigs\":[{}]}" } },
        .{ .respond = .{ .body = "{\"name\":\"projects/p/transferConfigs/x\"}" } },
        .{ .respond = .{ .body = "[]" } },
        .{ .respond = .{ .body = "{}" } },
        .{ .respond = .{ .body = "{\"transferMessages\":{}}" } },
    });
    defer h.deinit();
    const c = &h.client;
    try testing.expectError(error.InvalidResponse, c.listLocations(.{}));
    try testing.expectEqualStrings("the location list response could not be decoded", h.diag.message());
    try testing.expectError(error.InvalidResponse, c.listTransferConfigs("us", .{}));
    try testing.expectEqualStrings("the config list response could not be decoded", h.diag.message());
    try testing.expectError(error.InvalidResponse, c.getTransferConfig(manual));
    try testing.expectEqualStrings("the config response could not be decoded", h.diag.message());
    try testing.expectError(error.InvalidResponse, c.listRuns(manual, .{}));
    try testing.expectEqualStrings("the run list response could not be decoded", h.diag.message());
    try testing.expectError(error.InvalidResponse, c.getRun(run_ok));
    try testing.expectEqualStrings("the run response could not be decoded", h.diag.message());
    try testing.expectError(error.InvalidResponse, c.listMessages(run_ok, .{}));
    try testing.expectEqualStrings("the message list response could not be decoded", h.diag.message());
}

test "a response over max_response_bytes says how to ask for less" {
    var h: Harness = undefined;
    try h.init(&.{.{ .fail = error.ResponseTooLarge }});
    defer h.deinit();
    try testing.expectError(error.ResponseTooLarge, h.client.listRuns(manual, .{}));
    try testing.expectEqualStrings("the response was larger than max_response_bytes (33554432); ask for a smaller page_size", h.diag.message());
}

test "a client asks its token provider for the one scope its options name" {
    const Case = struct { ?rpc.Scope, []const u8 };
    for ([_]Case{
        .{ null, "https://www.googleapis.com/auth/bigquery" },
        .{ .bigquery, "https://www.googleapis.com/auth/bigquery" },
        .{ .cloud_platform, "https://www.googleapis.com/auth/cloud-platform" },
        .{ .cloud_platform_read_only, "https://www.googleapis.com/auth/cloud-platform.read-only" },
    }) |case| {
        var fake: test_util.FakeTransport = .init(testing.allocator, &.{.{ .respond = .{ .body = "{}" } }});
        defer fake.deinit();
        var tokens: test_util.FakeTokenProvider = .{};
        var clock: test_util.FakeClock = .{};
        var options: Options = .{ .project_id = "p", .token_provider = tokens.provider(), .transport = fake.transport() };
        if (case[0]) |s| options.scope = s;
        var client = try Client.init(testing.allocator, clock.io(), options);
        defer client.deinit();
        var page = try client.listLocations(.{});
        page.deinit();
        try testing.expectEqual(1, tokens.scope_count);
        try testing.expectEqualStrings(case[1], tokens.firstScope());
    }
}

test "init refuses what no call could use" {
    var tokens: test_util.FakeTokenProvider = .{};
    var clock: test_util.FakeClock = .{};
    var diag: core.Diagnostics = .{};
    try testing.expectError(error.InvalidName, Client.init(testing.allocator, clock.io(), .{ .project_id = "a/b", .token_provider = tokens.provider(), .diagnostics = &diag }));
    try testing.expectError(error.InvalidOptions, Client.init(testing.allocator, clock.io(), .{ .project_id = "p", .token_provider = tokens.provider(), .user_agent = "a\nb", .diagnostics = &diag }));
    try testing.expectError(error.InvalidOptions, Client.init(testing.allocator, clock.io(), .{ .project_id = "p", .token_provider = tokens.provider(), .retry = .{ .max_attempts = 0 }, .diagnostics = &diag }));
    try testing.expectError(error.InvalidOptions, Client.init(testing.allocator, clock.io(), .{ .project_id = "p", .token_provider = tokens.provider(), .max_response_bytes = 0, .diagnostics = &diag }));
    try testing.expectError(error.InvalidEndpoint, Client.init(testing.allocator, clock.io(), .{ .project_id = "p", .token_provider = tokens.provider(), .endpoint = "http://plain", .diagnostics = &diag }));
}

test "every allocation failure is OutOfMemory without leaks" {
    const Run = struct {
        fn calls(gpa: Allocator) !void {
            var fake: test_util.FakeTransport = .init(testing.allocator, &.{
                .{ .respond = .{ .body = production.locations_page } },
                .{ .respond = .{ .body = production.configs_page } },
                .{ .respond = .{ .body = production.config_scheduled } },
                .{ .respond = .{ .body = production.runs_page } },
                .{ .respond = .{ .body = production.run_failed } },
                .{ .respond = .{ .body = production.messages_succeeded } },
                .{ .respond = .{ .status = 404, .body = production.config_unknown } },
            });
            defer fake.deinit();
            var tokens: test_util.FakeTokenProvider = .{};
            var clock: test_util.FakeClock = .{};
            var client = try Client.init(gpa, clock.io(), .{ .project_id = "extractctl", .token_provider = tokens.provider(), .transport = fake.transport() });
            defer client.deinit();
            var locations = try client.listLocations(.{});
            locations.deinit();
            var configs = try client.listTransferConfigs("us", .{ .data_sources = &.{"scheduled_query"} });
            configs.deinit();
            var config = try client.getTransferConfig(manual);
            config.deinit();
            var runs = try client.listRuns(manual, .{ .states = &.{.failed} });
            runs.deinit();
            var run = try client.getRun(run_ok);
            run.deinit();
            var messages = try client.listMessages(run_ok, .{});
            messages.deinit();
            if (client.getTransferConfig(manual)) |unexpected| {
                var u = unexpected;
                u.deinit();
                return error.TestUnexpectedResult;
            } else |err| if (err != error.NotFound) return err;
        }
    };
    try testing.checkAllAllocationFailures(test_util.no_grow_allocator, Run.calls, .{});
}

test "golden: a run now, now or at a time given, and its answer" {
    var h: Harness = undefined;
    try h.init(&.{
        .{ .respond = .{ .body = production.started } },
        .{ .respond = .{ .body = production.started } },
    });
    defer h.deinit();
    h.clock.now_ns = 1_792_608_298_873_464_789;
    var started = try h.client.startManualRun(manual, .{});
    defer started.deinit();
    // The clock's reading, to the microsecond.
    try h.expectSent(0, .POST, base ++ manual ++ ":startManualRuns", "{\"requestedRunTime\":\"2026-10-21T18:44:58.873464Z\"}");
    try testing.expectEqual(1, started.value.runs.len);
    try testing.expectEqual(types.TransferState.pending, started.value.runs[0].state);
    var again = try h.client.startManualRun(manual, .{ .run_time = core.timestamp.parse("2026-10-20T00:00:00Z") catch unreachable });
    defer again.deinit();
    try h.expectSent(1, .POST, base ++ manual ++ ":startManualRuns", "{\"requestedRunTime\":\"2026-10-20T00:00:00Z\"}");
}

test "a run now is sent once: refused or lost, it is not sent again" {
    const unavailable: test_util.FakeTransport.Reply = .{ .respond = .{ .status = 503, .body = "{\"error\":{\"code\":503,\"message\":\"The service is currently unavailable.\",\"status\":\"UNAVAILABLE\"}}" } };
    var h: Harness = undefined;
    try h.init(&.{
        unavailable,
        .{ .fail = error.ConnectionResetByPeer },
        .{ .fail = error.TimedOut },
        .{ .fail = error.ConnectionRefused },
        .{ .respond = .{ .body = production.started } },
    });
    defer h.deinit();
    const c = &h.client;
    try testing.expectError(error.Unavailable, c.startManualRun(manual, .{}));
    try testing.expectError(error.ConnectionResetByPeer, c.startManualRun(manual, .{}));
    try testing.expectError(error.TimedOut, c.startManualRun(manual, .{}));
    try h.expectRequestCount(3);
    // A connection refused never reached the server: tried again.
    var started = try c.startManualRun(manual, .{});
    started.deinit();
    try h.expectRequestCount(5);
}

test "a run now's refusals, production's words kept, and what is refused before sending" {
    var h: Harness = undefined;
    try h.init(&.{
        .{ .respond = .{ .status = production.start_disabled_status, .body = production.start_disabled } },
        .{ .respond = .{ .status = production.start_read_only_status, .body = production.start_read_only } },
        .{ .respond = .{ .status = production.config_unknown_status, .body = production.config_unknown } },
    });
    defer h.deinit();
    const c = &h.client;
    try testing.expectError(error.InvalidArgument, c.startManualRun(manual, .{}));
    try testing.expectEqualStrings("Transfer is disabled. Please enable the transfer config before starting transfer runs.", h.diag.message());
    // A scope refusal that reached production all the same.
    try testing.expectError(error.PermissionDenied, c.startManualRun(manual, .{}));
    try testing.expectEqualStrings("Request had insufficient authentication scopes.", h.diag.message());
    try testing.expectError(error.NotFound, c.startManualRun("projects/extractctl/locations/us/transferConfigs/zigps-nobody", .{}));
    try h.expectRequestCount(3);
    try testing.expectError(error.InvalidName, c.startManualRun("projects/p/transferConfigs/x", .{}));
    try testing.expectError(error.InvalidName, c.startManualRunRequest(manual ++ "/runs/r", .{}));
    try testing.expectError(error.InvalidOptions, c.startManualRun(manual, .{ .run_time = .{ .nanoseconds = core.timestamp.max.nanoseconds + std.time.ns_per_s } }));
    try testing.expectEqualStrings("invalid run time: outside the years 1 to 9999", h.diag.message());
    try h.expectRequestCount(3);

    var reader: Harness = undefined;
    try reader.initScope(&.{}, .cloud_platform_read_only);
    defer reader.deinit();
    try testing.expectError(error.InvalidOptions, reader.client.startManualRun(manual, .{}));
    try testing.expectEqualStrings("this client asks for cloud-platform.read-only, which production refuses a run now; give Options.scope .bigquery or .cloud_platform", reader.diag.message());
    try testing.expectError(error.InvalidOptions, reader.client.startManualRunRequest(manual, .{}));
    try reader.expectRequestCount(0);
}

test "the preview is byte for byte what the run now sends" {
    var h: Harness = undefined;
    try h.init(&.{.{ .respond = .{ .body = production.started } }});
    defer h.deinit();
    const options: types.StartManualRunOptions = .{ .run_time = core.timestamp.parse("2026-10-21T18:44:58.873464Z") catch unreachable };
    var preview = try h.client.startManualRunRequest(manual, options);
    defer preview.deinit();
    try h.expectRequestCount(0);
    var started = try h.client.startManualRun(manual, options);
    started.deinit();
    const sent = try h.fake.request(0);
    try testing.expectEqual(preview.value.method, sent.method);
    try testing.expectEqualStrings(preview.value.url, sent.url);
    try testing.expectEqualStrings(preview.value.body, sent.body.?);
    try testing.expectEqualStrings("https://bigquerydatatransfer.googleapis.com/v1/" ++ manual ++ ":startManualRuns", preview.value.url);
}

test "a run now's answer that cannot be decoded, and its allocation failures" {
    var h: Harness = undefined;
    try h.init(&.{.{ .respond = .{ .body = "{\"runs\":7}" } }});
    defer h.deinit();
    try testing.expectError(error.InvalidResponse, h.client.startManualRun(manual, .{}));
    try testing.expectEqualStrings("the run now response could not be decoded", h.diag.message());

    const Run = struct {
        fn calls(gpa: Allocator) !void {
            var fake: test_util.FakeTransport = .init(testing.allocator, &.{.{ .respond = .{ .body = production.started } }});
            defer fake.deinit();
            var tokens: test_util.FakeTokenProvider = .{};
            var clock: test_util.FakeClock = .{};
            var client = try Client.init(gpa, clock.io(), .{ .project_id = "extractctl", .token_provider = tokens.provider(), .transport = fake.transport() });
            defer client.deinit();
            var preview = try client.startManualRunRequest(manual, .{});
            preview.deinit();
            var started = try client.startManualRun(manual, .{});
            started.deinit();
        }
    };
    try testing.checkAllAllocationFailures(test_util.no_grow_allocator, Run.calls, .{});
}
