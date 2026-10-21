//! A BigQuery client: the datasets a project holds, their tables with
//! their schemas, and the job history, from the client's own project or
//! any other a caller can read (`bigquery-public-data` among them).
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

pub const default_endpoint = "https://bigquery.googleapis.com";

pub const Options = struct {
    /// Required: the project queries run in and are billed to, an id or a
    /// number. Reads name any project through their refs.
    project_id: []const u8,
    /// Required. BigQuery has no emulator, so there is no unauthenticated
    /// mode.
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
    /// 5xx, 429, dropped connections, and the refusals BigQuery names as
    /// transient (`rateLimitExceeded` even as a 403, `backendError`,
    /// `internalError`) are retried.
    retry: RetryPolicy = .{},
    /// How long one request may take before it is `error.TimedOut`, which
    /// is retried. 0 removes the limit.
    request_timeout_ms: u32 = 30_000,
    /// A response whose decompressed body is larger fails with
    /// `error.ResponseTooLarge`. Used by the built-in transport; a
    /// transport passed in keeps its own limit.
    max_response_bytes: usize = core.transport.default_max_response_bytes,
    /// Printable ASCII.
    user_agent: []const u8 = "zig-gcp-bigquery/0.55",
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

/// One page of a project's datasets: the client's own, or `options.project`.
/// Only those the caller may get are listed; the list asks no permission
/// of its own.
pub fn listDatasets(self: *Client, options: types.ListDatasetsOptions) Error!types.Owned(types.DatasetPage) {
    rpc.begin(self);
    const project = try self.projectOf(options.project);
    try self.checkToken(options.page_token);
    if (options.label_filter) |f| if (!validate.isLabelFilter(f)) {
        if (self.diagnostics) |d| d.print("invalid label filter: expected printable ASCII, such as labels.team:data", .{});
        return error.InvalidName;
    };
    var scratch: std.heap.ArenaAllocator = .init(self.gpa);
    defer scratch.deinit();
    const a = scratch.allocator();
    var w: std.Io.Writer.Allocating = .init(a);
    w.writer.writeAll(try names.datasets(a, project)) catch return error.OutOfMemory;
    var params: core.query.Params = .init(&w.writer);
    if (options.all) params.add("all", "true") catch return error.OutOfMemory;
    params.addOptional("filter", options.label_filter) catch return error.OutOfMemory;
    params.addNonZero("maxResults", options.page_size) catch return error.OutOfMemory;
    params.addOptional("pageToken", options.page_token) catch return error.OutOfMemory;
    return self.call(types.DatasetPage, a, w.written(), codec.decodeDatasetPage, "dataset list");
}

/// One dataset.
pub fn getDataset(self: *Client, ref: types.DatasetRef) Error!types.Owned(types.Dataset) {
    rpc.begin(self);
    const project = try self.projectOf(ref.project);
    try self.checkDataset(ref.dataset);
    var scratch: std.heap.ArenaAllocator = .init(self.gpa);
    defer scratch.deinit();
    const a = scratch.allocator();
    return self.call(types.Dataset, a, try names.dataset(a, project, ref.dataset), codec.decodeDataset, "dataset");
}

/// One page of a dataset's tables, as a list carries them: no schema and
/// no row count (`getTable` has both).
pub fn listTables(self: *Client, ref: types.DatasetRef, options: types.ListOptions) Error!types.Owned(types.TablePage) {
    rpc.begin(self);
    const project = try self.projectOf(ref.project);
    try self.checkDataset(ref.dataset);
    try self.checkToken(options.page_token);
    var scratch: std.heap.ArenaAllocator = .init(self.gpa);
    defer scratch.deinit();
    const a = scratch.allocator();
    var w: std.Io.Writer.Allocating = .init(a);
    w.writer.writeAll(try names.tables(a, project, ref.dataset)) catch return error.OutOfMemory;
    var params: core.query.Params = .init(&w.writer);
    params.addNonZero("maxResults", options.page_size) catch return error.OutOfMemory;
    params.addOptional("pageToken", options.page_token) catch return error.OutOfMemory;
    return self.call(types.TablePage, a, w.written(), codec.decodeTablePage, "table list");
}

/// One table, with its schema, row count and bytes.
pub fn getTable(self: *Client, ref: types.TableRef) Error!types.Owned(types.Table) {
    rpc.begin(self);
    const project = try self.projectOf(ref.project);
    try self.checkDataset(ref.dataset);
    if (!validate.isTableId(ref.table)) {
        if (self.diagnostics) |d| d.print("invalid table id: expected UTF-8 of 1 to 1,024 bytes without / or control characters", .{});
        return error.InvalidName;
    }
    var scratch: std.heap.ArenaAllocator = .init(self.gpa);
    defer scratch.deinit();
    const a = scratch.allocator();
    return self.call(types.Table, a, try names.table(a, project, ref.dataset, ref.table), codec.decodeTable, "table");
}

/// One page of the job history, newest first, with each job's
/// configuration (so a query's text): this library always asks the full
/// projection, as Google's clients do. A caller lists its own jobs
/// without any permission; `all_users` needs `bigquery.jobs.list` (others'
/// redacted) or `bigquery.jobs.listAll`.
pub fn listJobs(self: *Client, options: types.ListJobsOptions) Error!types.Owned(types.JobPage) {
    rpc.begin(self);
    const project = try self.projectOf(options.project);
    try self.checkToken(options.page_token);
    var scratch: std.heap.ArenaAllocator = .init(self.gpa);
    defer scratch.deinit();
    const a = scratch.allocator();
    var w: std.Io.Writer.Allocating = .init(a);
    w.writer.writeAll(try names.jobs(a, project)) catch return error.OutOfMemory;
    var params: core.query.Params = .init(&w.writer);
    params.add("projection", "full") catch return error.OutOfMemory;
    if (options.all_users) params.add("allUsers", "true") catch return error.OutOfMemory;
    for (options.states) |state| {
        const name = state.filterName() orelse {
            if (self.diagnostics) |d| d.print("invalid state filter: .unknown is no state a list can filter by", .{});
            return error.InvalidOptions;
        };
        params.add("stateFilter", name) catch return error.OutOfMemory;
    }
    if (options.min_creation_time) |t| params.addInt("minCreationTime", try epochMillis(self, t)) catch return error.OutOfMemory;
    if (options.max_creation_time) |t| params.addInt("maxCreationTime", try epochMillis(self, t)) catch return error.OutOfMemory;
    params.addNonZero("maxResults", options.page_size) catch return error.OutOfMemory;
    params.addOptional("pageToken", options.page_token) catch return error.OutOfMemory;
    return self.call(types.JobPage, a, w.written(), codec.decodeJobPage, "job list");
}

/// One job. Its location must be given for a job outside the US and EU
/// multi-regions; production found a US job without one, and answered
/// the wrong one with "Not found: Job <project>:<location>.<id>"
/// (measured).
pub fn getJob(self: *Client, ref: types.JobRef) Error!types.Owned(types.Job) {
    rpc.begin(self);
    var scratch: std.heap.ArenaAllocator = .init(self.gpa);
    defer scratch.deinit();
    const a = scratch.allocator();
    return self.call(types.Job, a, try self.jobPath(a, ref, ""), codec.decodeJob, "job");
}

/// `.../jobs/J[suffix]?location=L`, after the checks every job call makes.
pub fn jobPath(self: *Client, arena: Allocator, ref: types.JobRef, suffix: []const u8) Error![]const u8 {
    const project = try self.projectOf(ref.project);
    if (!validate.isJobId(ref.id)) {
        if (self.diagnostics) |d| d.print("invalid job id: expected letters, digits, _ and -, at most 1,024", .{});
        return error.InvalidName;
    }
    try self.checkLocation(ref.location);
    var w: std.Io.Writer.Allocating = .init(arena);
    w.writer.writeAll(try names.job(arena, project, ref.id)) catch return error.OutOfMemory;
    w.writer.writeAll(suffix) catch return error.OutOfMemory;
    var params: core.query.Params = .init(&w.writer);
    if (ref.location.len > 0) params.add("location", ref.location) catch return error.OutOfMemory;
    return w.written();
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

/// `project`, or the client's own when it is empty, checked.
pub fn projectOf(self: *Client, project: []const u8) Error![]const u8 {
    if (project.len == 0) return self.project;
    if (!core.names.isProjectId(project)) {
        if (self.diagnostics) |d| d.print("invalid project: expected a project id or number", .{});
        return error.InvalidName;
    }
    return project;
}

fn checkDataset(self: *Client, id: []const u8) Error!void {
    if (!validate.isDatasetId(id)) {
        if (self.diagnostics) |d| d.print("invalid dataset id: expected letters, digits and _, at most 1,024", .{});
        return error.InvalidName;
    }
}

/// A location, or empty for none.
pub fn checkLocation(self: *Client, location: []const u8) Error!void {
    if (location.len > 0 and !validate.isLocation(location)) {
        if (self.diagnostics) |d| d.print("invalid location: expected US, EU or a region such as us-central1", .{});
        return error.InvalidName;
    }
}

fn checkToken(self: *Client, token: ?[]const u8) Error!void {
    if (token) |t| if (!validate.isPageToken(t)) {
        if (self.diagnostics) |d| d.print("invalid page token: expected printable ASCII", .{});
        return error.InvalidName;
    };
}

/// Milliseconds since the epoch, as `jobs.list` takes a creation time;
/// a time before the epoch is refused.
fn epochMillis(self: *Client, t: std.Io.Timestamp) Error!u64 {
    if (t.nanoseconds < 0) {
        if (self.diagnostics) |d| d.print("invalid creation time: before 1970", .{});
        return error.InvalidOptions;
    }
    return @intCast(@divFloor(t.nanoseconds, std.time.ns_per_ms));
}

const testing = std.testing;
const test_util = @import("test_util.zig");
const Harness = test_util.Harness;
const production = @import("production_bodies.zig");
const base = "https://bigquery.googleapis.com/bigquery/v2/projects/";

test "golden: datasets, tables and jobs, of this project and another" {
    var h: Harness = undefined;
    try h.init(&.{
        .{ .respond = .{ .body = production.datasets_page } },
        .{ .respond = .{ .body = production.dataset_public } },
        .{ .respond = .{ .body = production.tables_page_public } },
        .{ .respond = .{ .body = production.table_shakespeare } },
        .{ .respond = .{ .body = production.jobs_page } },
        .{ .respond = .{ .body = production.job_cancelled } },
        .{ .respond = .{ .body = production.datasets_page } },
    });
    defer h.deinit();
    const c = &h.client;

    var datasets = try c.listDatasets(.{ .all = true, .label_filter = "labels.zigps:probe", .page_size = 10, .page_token = "t" });
    defer datasets.deinit();
    try h.expectRequest(0, .GET, base ++ "my-project/datasets?all=true&filter=labels.zigps%3Aprobe&maxResults=10&pageToken=t");
    try testing.expectEqual(1, datasets.value.datasets.len);

    var samples = try c.getDataset(.{ .project = "bigquery-public-data", .dataset = "samples" });
    defer samples.deinit();
    try h.expectRequest(1, .GET, base ++ "bigquery-public-data/datasets/samples");
    try testing.expectEqualStrings("US", samples.value.location);

    var tables = try c.listTables(.{ .project = "bigquery-public-data", .dataset = "samples" }, .{ .page_size = 3, .page_token = "BFXQ" });
    defer tables.deinit();
    try h.expectRequest(2, .GET, base ++ "bigquery-public-data/datasets/samples/tables?maxResults=3&pageToken=BFXQ");

    var shakespeare = try c.getTable(.{ .project = "bigquery-public-data", .dataset = "samples", .table = "shakespeare" });
    defer shakespeare.deinit();
    try h.expectRequest(3, .GET, base ++ "bigquery-public-data/datasets/samples/tables/shakespeare");
    try testing.expectEqual(164_656, shakespeare.value.num_rows.?);

    var jobs = try c.listJobs(.{
        .all_users = true,
        .states = &.{ .done, .running },
        .min_creation_time = .{ .nanoseconds = 1_792_597_000_000 * std.time.ns_per_ms },
        .max_creation_time = .{ .nanoseconds = 1_792_598_000_000 * std.time.ns_per_ms + 999_999 },
        .page_size = 5,
    });
    defer jobs.deinit();
    try h.expectRequest(4, .GET, base ++ "my-project/jobs?projection=full&allUsers=true&stateFilter=done&stateFilter=running&minCreationTime=1792597000000&maxCreationTime=1792598000000&maxResults=5");
    try testing.expectEqual(5, jobs.value.jobs.len);

    var job = try c.getJob(.{ .id = "job_uJJN89pQ9cqYnDKc4Z_VpBpHsSqC", .location = "US" });
    defer job.deinit();
    try h.expectRequest(5, .GET, base ++ "my-project/jobs/job_uJJN89pQ9cqYnDKc4Z_VpBpHsSqC?location=US");
    try testing.expect(job.value.failed());

    var bare = try c.listDatasets(.{});
    defer bare.deinit();
    try h.expectRequest(6, .GET, base ++ "my-project/datasets");
}

test "the reads refuse what they will not send" {
    var h: Harness = undefined;
    try h.init(&.{});
    defer h.deinit();
    const c = &h.client;
    try testing.expectError(error.InvalidName, c.getDataset(.{ .dataset = "with-dash" }));
    try testing.expectEqualStrings("invalid dataset id: expected letters, digits and _, at most 1,024", h.diag.message());
    try testing.expectError(error.InvalidName, c.getDataset(.{ .project = "a/b", .dataset = "d" }));
    try testing.expectError(error.InvalidName, c.listDatasets(.{ .page_token = "a b" }));
    try testing.expectError(error.InvalidName, c.listDatasets(.{ .label_filter = "labels.a\n" }));
    try testing.expectError(error.InvalidName, c.listTables(.{ .dataset = "" }, .{}));
    try testing.expectError(error.InvalidName, c.getTable(.{ .dataset = "d", .table = "a/b" }));
    try testing.expectError(error.InvalidName, c.getJob(.{ .id = "US.job" }));
    try testing.expectError(error.InvalidName, c.getJob(.{ .id = "j", .location = "us central1" }));
    try testing.expectError(error.InvalidOptions, c.listJobs(.{ .states = &.{.unknown} }));
    try testing.expectError(error.InvalidOptions, c.listJobs(.{ .min_creation_time = .{ .nanoseconds = -1 } }));
    try h.expectRequestCount(0);
}

test "the refusals arrive as errors, production's words kept" {
    var h: Harness = undefined;
    try h.init(&.{
        .{ .respond = .{ .status = production.dataset_unknown_status, .body = production.dataset_unknown } },
        .{ .respond = .{ .status = production.table_unknown_status, .body = production.table_unknown } },
        .{ .respond = .{ .status = production.project_unknown_status, .body = production.project_unknown } },
        .{ .respond = .{ .status = production.job_wrong_location_status, .body = production.job_wrong_location } },
    });
    defer h.deinit();
    const c = &h.client;
    try testing.expectError(error.NotFound, c.getDataset(.{ .dataset = "zigps_nobody" }));
    try testing.expectEqualStrings("Not found: Dataset extractctl:zigps_nobody", h.diag.message());
    try testing.expectError(error.NotFound, c.getTable(.{ .project = "bigquery-public-data", .dataset = "samples", .table = "zigps_nobody" }));
    try testing.expectError(error.NotFound, c.listDatasets(.{ .project = "zigps-not-a-project-x" }));
    try testing.expectEqualStrings("Not found: Project zigps-not-a-project-x", h.diag.message());
    try testing.expectError(error.NotFound, c.getJob(.{ .id = "job_uJJN89pQ9cqYnDKc4Z_VpBpHsSqC", .location = "EU" }));
    try testing.expect(std.mem.startsWith(u8, h.diag.message(), "Not found: Job extractctl:EU."));
}

test "a rate limit sent as 403 is retried, and a query's refusals are their own errors" {
    const rate_limited: test_util.FakeTransport.Reply = .{ .respond = .{
        .status = 403,
        .body = "{\"error\":{\"code\":403,\"message\":\"Exceeded rate limits: too many api requests per user per method for this user_method.\",\"errors\":[{\"message\":\"Exceeded rate limits\",\"domain\":\"usageLimits\",\"reason\":\"rateLimitExceeded\"}],\"status\":\"PERMISSION_DENIED\"}}",
    } };
    var h: Harness = undefined;
    try h.init(&.{
        rate_limited,
        .{ .respond = .{ .body = production.dataset_ours } },
        .{ .respond = .{ .status = 400, .body = "{\"error\":{\"code\":400,\"message\":\"Syntax error: Unexpected keyword WHERE at [2:3]\",\"errors\":[{\"message\":\"Syntax error: Unexpected keyword WHERE at [2:3]\",\"domain\":\"global\",\"reason\":\"invalidQuery\",\"location\":\"q\",\"locationType\":\"parameter\"}],\"status\":\"INVALID_ARGUMENT\"}}" } },
        .{ .respond = .{ .status = 400, .body = "{\"error\":{\"code\":400,\"message\":\"Query exceeded limit for bytes billed: 1000. 10485760 or higher required.\",\"errors\":[{\"reason\":\"bytesBilledLimitExceeded\"}],\"status\":\"INVALID_ARGUMENT\"}}" } },
        .{ .respond = .{ .status = 403, .body = "{\"error\":{\"code\":403,\"message\":\"Quota exceeded\",\"errors\":[{\"reason\":\"quotaExceeded\"}],\"status\":\"PERMISSION_DENIED\"}}" } },
        .{ .respond = .{ .status = 403, .body = "{\"error\":{\"code\":403,\"message\":\"Response too large to return.\",\"errors\":[{\"reason\":\"responseTooLarge\"}],\"status\":\"PERMISSION_DENIED\"}}" } },
        .{ .respond = .{ .status = production.cancel_read_only_status, .body = production.cancel_read_only } },
    });
    defer h.deinit();
    const c = &h.client;
    var dataset = try c.getDataset(.{ .dataset = "zigps_9cb674" });
    dataset.deinit();
    try h.expectRequestCount(2);
    // The reads never meet these; m3's queries do, through the same path.
    try testing.expectError(error.InvalidQuery, c.getDataset(.{ .dataset = "d" }));
    try testing.expectEqualStrings("Syntax error: Unexpected keyword WHERE at [2:3]", h.diag.message());
    try testing.expectError(error.BytesBilledLimitExceeded, c.getDataset(.{ .dataset = "d" }));
    try testing.expectError(error.QuotaExceeded, c.getDataset(.{ .dataset = "d" }));
    try testing.expectError(error.ResultTooLarge, c.getDataset(.{ .dataset = "d" }));
    // A scope refusal stays a permission refusal, not retried.
    try testing.expectError(error.PermissionDenied, c.getDataset(.{ .dataset = "d" }));
    try testing.expectEqualStrings("Request had insufficient authentication scopes.", h.diag.message());
    try h.expectRequestCount(7);
}

test "a response over max_response_bytes says how to ask for less" {
    var h: Harness = undefined;
    try h.init(&.{.{ .fail = error.ResponseTooLarge }});
    defer h.deinit();
    try testing.expectError(error.ResponseTooLarge, h.client.listJobs(.{}));
    try testing.expectEqualStrings("the response was larger than max_response_bytes (33554432); ask for a smaller page_size", h.diag.message());
}

test "a response that cannot be decoded is InvalidResponse, named in Diagnostics" {
    var h: Harness = undefined;
    try h.init(&.{
        .{ .respond = .{ .body = "{\"datasets\":1}" } },
        .{ .respond = .{ .body = "{\"datasetReference\":{}}" } },
        .{ .respond = .{ .body = "{\"tables\":[{}]}" } },
        .{ .respond = .{ .body = "[]" } },
        .{ .respond = .{ .body = "{\"jobs\":[{}]}" } },
        .{ .respond = .{ .body = "{}" } },
    });
    defer h.deinit();
    const c = &h.client;
    try testing.expectError(error.InvalidResponse, c.listDatasets(.{}));
    try testing.expectEqualStrings("the dataset list response could not be decoded", h.diag.message());
    try testing.expectError(error.InvalidResponse, c.getDataset(.{ .dataset = "d" }));
    try testing.expectError(error.InvalidResponse, c.listTables(.{ .dataset = "d" }, .{}));
    try testing.expectError(error.InvalidResponse, c.getTable(.{ .dataset = "d", .table = "t" }));
    try testing.expectEqualStrings("the table response could not be decoded", h.diag.message());
    try testing.expectError(error.InvalidResponse, c.listJobs(.{}));
    try testing.expectError(error.InvalidResponse, c.getJob(.{ .id = "j" }));
    try testing.expectEqualStrings("the job response could not be decoded", h.diag.message());
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
        var page = try client.listDatasets(.{});
        page.deinit();
        try testing.expectEqual(1, tokens.scope_count);
        try testing.expectEqualStrings(case[1], tokens.firstScope());
    }
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
                .{ .respond = .{ .body = production.datasets_page } },
                .{ .respond = .{ .body = production.dataset_public } },
                .{ .respond = .{ .body = production.tables_page } },
                .{ .respond = .{ .body = production.table_typed } },
                .{ .respond = .{ .body = production.jobs_page } },
                .{ .respond = .{ .body = production.job_cancelled } },
                .{ .respond = .{ .status = 400, .body = "{\"error\":{\"code\":400,\"message\":\"m\",\"errors\":[{\"reason\":\"invalidQuery\"}]}}" } },
            });
            defer fake.deinit();
            var tokens: test_util.FakeTokenProvider = .{};
            var clock: test_util.FakeClock = .{};
            var client = try Client.init(gpa, clock.io(), .{ .project_id = "my-project", .token_provider = tokens.provider(), .transport = fake.transport() });
            defer client.deinit();
            var datasets = try client.listDatasets(.{ .page_token = "t" });
            datasets.deinit();
            var dataset = try client.getDataset(.{ .project = "bigquery-public-data", .dataset = "samples" });
            dataset.deinit();
            var tables = try client.listTables(.{ .dataset = "d" }, .{});
            tables.deinit();
            var table = try client.getTable(.{ .dataset = "d", .table = "typed" });
            table.deinit();
            var jobs = try client.listJobs(.{ .states = &.{.done} });
            jobs.deinit();
            var job = try client.getJob(.{ .id = "j", .location = "US" });
            job.deinit();
            if (client.getDataset(.{ .dataset = "d" })) |unexpected| {
                var u = unexpected;
                u.deinit();
                return error.TestUnexpectedResult;
            } else |err| if (err != error.InvalidQuery) return err;
        }
    };
    try testing.checkAllAllocationFailures(test_util.no_grow_allocator, Run.calls, .{});
}
