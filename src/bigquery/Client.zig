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
    user_agent: []const u8 = "zig-gcp-bigquery/0.56",
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

/// What a query would read and bill, the columns it would answer and its
/// statement type, without running it: free, and never in the job history
/// (measured). A query that would fail fails here the same way, a syntax
/// or semantic error as `error.InvalidQuery` with production's words
/// (`errorPosition` finds where), a table nobody has as `error.NotFound`.
/// Retried as the reads are.
pub fn dryRun(self: *Client, options: types.QueryOptions) Error!types.Owned(types.DryRun) {
    rpc.begin(self);
    var scratch: std.heap.ArenaAllocator = .init(self.gpa);
    defer scratch.deinit();
    const a = scratch.allocator();
    const request = try self.queryCall(a, options, .dry_run);
    var result: types.Owned(types.DryRun) = try .init(self.gpa);
    errdefer result.deinit();
    const body = try rpc.execute(self, result.arena, request);
    result.value = codec.decodeDryRun(result.arena.allocator(), a, body) catch |err|
        return rpc.decodeFailed(self, err, "dry run");
    return result;
}

/// Runs a query (`jobs.query`): answers its first page when the job ends
/// within `options.timeout_ms`, or `complete` false with the job, to read
/// with `getQueryResults`. A syntax error, a runtime error (`1 / 0`) and a
/// query over `maximum_bytes_billed` are refused at once, the call's error
/// (`error.InvalidQuery`, `error.BytesBilledLimitExceeded`) with
/// production's words, and bill nothing (measured).
///
/// Every query carries a request id, so a resend within 15 minutes answers
/// the first job rather than run it again: it is retried as the reads
/// are. Production answered such a repeat unfinished and without rows
/// although the job had ended (measured); read its results then.
pub fn query(self: *Client, options: types.QueryOptions) Error!types.Owned(types.QueryPage) {
    rpc.begin(self);
    var scratch: std.heap.ArenaAllocator = .init(self.gpa);
    defer scratch.deinit();
    const a = scratch.allocator();
    var request = try self.queryCall(a, options, .run);
    request.retry_window_ms = request_id_window_ms;
    var result: types.Owned(types.QueryPage) = try .init(self.gpa);
    errdefer result.deinit();
    const body = try rpc.executeHeld(self, result.arena, request, options.timeout_ms);
    result.value = codec.decodeQueryPage(result.arena.allocator(), a, body) catch |err|
        return rpc.decodeFailed(self, err, "query");
    return result;
}

/// How long after a query's first attempt a retry may still begin: well
/// inside the 15 minutes production remembers a request id for.
pub const request_id_window_ms = 10 * std.time.ms_per_min;

/// A page of a job's results, or, for a job still running, its state
/// once the call has been held `options.timeout_ms`: `complete` false
/// means ask again. Production held each call about as long as asked, and
/// one with `page_size` 0 and 60 s until the job ended, at 53 s
/// (measured). Rows come as `formatOptions.useInt64Timestamp` writes
/// them, timestamps exact to the microsecond.
pub fn getQueryResults(self: *Client, ref: types.JobRef, options: types.ResultsOptions) Error!types.Owned(types.QueryPage) {
    rpc.begin(self);
    var scratch: std.heap.ArenaAllocator = .init(self.gpa);
    defer scratch.deinit();
    const a = scratch.allocator();
    const project = try self.checkJob(ref);
    try self.checkToken(options.page_token);
    if (options.page_token != null and options.start_index != null) {
        if (self.diagnostics) |d| d.print("invalid results options: page_token and start_index are each a place to start; give one", .{});
        return error.InvalidOptions;
    }
    var w: std.Io.Writer.Allocating = .init(a);
    w.writer.writeAll(try names.queryResults(a, project, ref.id)) catch return error.OutOfMemory;
    var params: core.query.Params = .init(&w.writer);
    params.add("formatOptions.useInt64Timestamp", "true") catch return error.OutOfMemory;
    if (ref.location.len > 0) params.add("location", ref.location) catch return error.OutOfMemory;
    if (options.page_size) |n| params.addInt("maxResults", n) catch return error.OutOfMemory;
    params.addOptional("pageToken", options.page_token) catch return error.OutOfMemory;
    if (options.start_index) |i| params.addInt("startIndex", i) catch return error.OutOfMemory;
    params.addInt("timeoutMs", options.timeout_ms) catch return error.OutOfMemory;
    var result: types.Owned(types.QueryPage) = try .init(self.gpa);
    errdefer result.deinit();
    const body = try rpc.executeHeld(self, result.arena, .{ .method = .GET, .path = w.written() }, options.timeout_ms);
    result.value = codec.decodeQueryPage(result.arena.allocator(), a, body) catch |err|
        return rpc.decodeFailed(self, err, "query results");
    return result;
}

/// Asks the job to stop. Answers the job as it stands, running when
/// measured; it then ended `.done` with the error `stopped`, "Job execution
/// was cancelled: User requested cancellation". A cancel of a job already
/// done answers it done, no refusal (measured), so it is retried as the
/// reads are. Takes `bigquery.jobs.update` on another's job and
/// `bigquery.jobs.create` on the project for one's own, and a client
/// whose scope is not `.cloud_platform_read_only`, which production
/// refuses a cancel.
pub fn cancelJob(self: *Client, ref: types.JobRef) Error!types.Owned(types.Job) {
    rpc.begin(self);
    var scratch: std.heap.ArenaAllocator = .init(self.gpa);
    defer scratch.deinit();
    const a = scratch.allocator();
    const request = try self.cancelCall(a, ref);
    var result: types.Owned(types.Job) = try .init(self.gpa);
    errdefer result.deinit();
    const body = try rpc.execute(self, result.arena, request);
    result.value = codec.decodeCancel(result.arena.allocator(), a, body) catch |err|
        return rpc.decodeFailed(self, err, "cancel");
    return result;
}

/// The request `dryRun` sends for the same options, built without
/// sending it, after the same checks with the same errors: to show before
/// the call, or to record after it. Credentials and other headers are not
/// part of it.
pub fn dryRunRequest(self: *Client, options: types.QueryOptions) Error!types.Owned(PreparedRequest) {
    rpc.begin(self);
    var result: types.Owned(PreparedRequest) = try .init(self.gpa);
    errdefer result.deinit();
    const a = result.arena.allocator();
    result.value = try .fromCall(a, self.base_url, try self.queryCall(a, options, .dry_run));
    return result;
}

/// The request `query` sends, as `dryRunRequest` says. With
/// `options.request_id` null each call makes its own id, so the preview
/// and the query would differ in it alone: to send exactly what was shown,
/// make one with `newRequestId` and give it to both.
pub fn queryRequest(self: *Client, options: types.QueryOptions) Error!types.Owned(PreparedRequest) {
    rpc.begin(self);
    var result: types.Owned(PreparedRequest) = try .init(self.gpa);
    errdefer result.deinit();
    const a = result.arena.allocator();
    result.value = try .fromCall(a, self.base_url, try self.queryCall(a, options, .run));
    return result;
}

/// The request `cancelJob` sends, as `dryRunRequest` says.
pub fn cancelJobRequest(self: *Client, ref: types.JobRef) Error!types.Owned(PreparedRequest) {
    rpc.begin(self);
    var result: types.Owned(PreparedRequest) = try .init(self.gpa);
    errdefer result.deinit();
    const a = result.arena.allocator();
    result.value = try .fromCall(a, self.base_url, try self.cancelCall(a, ref));
    return result;
}

/// A request id as `query` makes one: a random UUID, which BigQuery
/// recommends, written into `buf`.
pub fn newRequestId(self: *Client, buf: *[36]u8) []const u8 {
    var bytes: [16]u8 = undefined;
    self.io.random(&bytes);
    // Version 4, variant 1.
    bytes[6] = (bytes[6] & 0x0f) | 0x40;
    bytes[8] = (bytes[8] & 0x3f) | 0x80;
    const hex = std.fmt.bytesToHex(bytes, .lower);
    return std.fmt.bufPrint(buf, "{s}-{s}-{s}-{s}-{s}", .{ hex[0..8], hex[8..12], hex[12..16], hex[16..20], hex[20..32] }) catch unreachable;
}

/// The call `dryRun` or `query` sends: `POST .../queries` with the
/// options as `jobs.query` takes them.
fn queryCall(self: *Client, arena: Allocator, options: types.QueryOptions, mode: enum { dry_run, run }) Error!rpc.Call {
    if (!validate.isQuery(options.query)) {
        if (self.diagnostics) |d| d.print("invalid query: expected UTF-8 text, not empty", .{});
        return error.InvalidOptions;
    }
    try self.checkLocation(options.location);
    var default_dataset: ?types.DatasetRef = null;
    if (options.default_dataset) |ref| {
        try self.checkDataset(ref.dataset);
        default_dataset = .{ .project = try self.projectOf(ref.project), .dataset = ref.dataset };
    }
    try self.checkLabels(options.labels);
    var id_buf: [36]u8 = undefined;
    const request_id: ?[]const u8 = switch (mode) {
        .dry_run => null,
        .run => if (options.request_id) |id| blk: {
            if (!validate.isRequestId(id)) {
                if (self.diagnostics) |d| d.print("invalid request id: expected 1 to 36 printable ASCII characters", .{});
                return error.InvalidOptions;
            }
            break :blk id;
        } else self.newRequestId(&id_buf),
    };

    var w: std.Io.Writer.Allocating = .init(arena);
    writeQueryBody(&w.writer, options, default_dataset, mode == .dry_run, request_id) catch return error.OutOfMemory;
    return .{ .method = .POST, .path = try names.queries(arena, self.project), .body = w.written() };
}

fn writeQueryBody(
    w: *std.Io.Writer,
    options: types.QueryOptions,
    default_dataset: ?types.DatasetRef,
    dry_run: bool,
    request_id: ?[]const u8,
) std.Io.Writer.Error!void {
    var json: std.json.Stringify = .{ .writer = w };
    try json.beginObject();
    try json.objectField("query");
    try json.write(options.query);
    try json.objectField("useLegacySql");
    try json.write(false);
    if (dry_run) {
        try json.objectField("dryRun");
        try json.write(true);
    }
    if (options.location.len > 0) {
        try json.objectField("location");
        try json.write(options.location);
    }
    if (default_dataset) |ref| {
        try json.objectField("defaultDataset");
        try json.beginObject();
        try json.objectField("projectId");
        try json.write(ref.project);
        try json.objectField("datasetId");
        try json.write(ref.dataset);
        try json.endObject();
    }
    if (!options.use_query_cache) {
        try json.objectField("useQueryCache");
        try json.write(false);
    }
    if (options.maximum_bytes_billed) |n| {
        // An int64, so a JSON string.
        try json.objectField("maximumBytesBilled");
        try json.print("\"{d}\"", .{n});
    }
    if (options.labels.len > 0) {
        try json.objectField("labels");
        try json.beginObject();
        for (options.labels) |label| {
            try json.objectField(label.key);
            try json.write(label.value);
        }
        try json.endObject();
    }
    if (!dry_run) {
        try json.objectField("timeoutMs");
        try json.write(options.timeout_ms);
        if (options.page_size) |n| {
            try json.objectField("maxResults");
            try json.write(n);
        }
        try json.objectField("requestId");
        try json.write(request_id.?);
        try json.objectField("formatOptions");
        try json.beginObject();
        try json.objectField("useInt64Timestamp");
        try json.write(true);
        try json.endObject();
    }
    try json.endObject();
}

/// The call `cancelJob` sends: `POST .../jobs/J/cancel?location=L`.
fn cancelCall(self: *Client, arena: Allocator, ref: types.JobRef) Error!rpc.Call {
    if (self.scope == .cloud_platform_read_only) {
        if (self.diagnostics) |d| d.print("this client asks for cloud-platform.read-only, which production refuses a cancel; give Options.scope .bigquery or .cloud_platform", .{});
        return error.InvalidOptions;
    }
    return .{ .method = .POST, .path = try self.jobPath(arena, ref, "/cancel") };
}

/// `.../jobs/J[suffix]?location=L`, after the checks every job call makes.
fn jobPath(self: *Client, arena: Allocator, ref: types.JobRef, suffix: []const u8) Error![]const u8 {
    const project = try self.checkJob(ref);
    var w: std.Io.Writer.Allocating = .init(arena);
    w.writer.writeAll(try names.job(arena, project, ref.id)) catch return error.OutOfMemory;
    w.writer.writeAll(suffix) catch return error.OutOfMemory;
    var params: core.query.Params = .init(&w.writer);
    if (ref.location.len > 0) params.add("location", ref.location) catch return error.OutOfMemory;
    return w.written();
}

/// The job's project, after the checks every job call makes.
fn checkJob(self: *Client, ref: types.JobRef) Error![]const u8 {
    const project = try self.projectOf(ref.project);
    if (!validate.isJobId(ref.id)) {
        if (self.diagnostics) |d| d.print("invalid job id: expected letters, digits, _ and -, at most 1,024", .{});
        return error.InvalidName;
    }
    try self.checkLocation(ref.location);
    return project;
}

fn checkLabels(self: *Client, labels: []const types.Label) Error!void {
    if (labels.len > validate.max_labels) {
        if (self.diagnostics) |d| d.print("invalid labels: more than 64", .{});
        return error.InvalidOptions;
    }
    for (labels, 0..) |label, i| {
        if (!validate.isLabelText(label.key, true) or !validate.isLabelText(label.value, false)) {
            if (self.diagnostics) |d| d.print("invalid label: keys and values are lowercase letters, digits, _ and -, at most 63 characters, a key starting with a letter", .{});
            return error.InvalidOptions;
        }
        for (labels[0..i]) |earlier| if (std.mem.eql(u8, earlier.key, label.key)) {
            if (self.diagnostics) |d| d.print("invalid labels: the key {s} appears twice", .{label.key});
            return error.InvalidOptions;
        };
    }
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
fn projectOf(self: *Client, project: []const u8) Error![]const u8 {
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
fn checkLocation(self: *Client, location: []const u8) Error!void {
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

const hamlet = "SELECT word, word_count FROM `bigquery-public-data.samples.shakespeare` WHERE corpus = 'hamlet' ORDER BY word_count DESC LIMIT 5";
/// The request id `newRequestId` makes when every random byte is 0xab.
const fixed_request_id = "abababab-abab-4bab-abab-abababababab";

test "golden: a query, a dry run, results and a cancel, as milestone 0 sent them" {
    var h: Harness = undefined;
    try h.init(&.{
        .{ .respond = .{ .body = production.query_run } },
        .{ .respond = .{ .body = production.query_dry_run } },
        .{ .respond = .{ .body = production.results_page } },
        .{ .respond = .{ .body = production.results_wait } },
        .{ .respond = .{ .body = production.cancel_running } },
        .{ .respond = .{ .body = production.query_run } },
    });
    defer h.deinit();
    h.clock.random_byte = 0xab;
    const c = &h.client;

    var run = try c.query(.{ .query = hamlet, .maximum_bytes_billed = 100_000_000 });
    defer run.deinit();
    try h.expectSent(0, .POST, base ++ "my-project/queries", "{\"query\":\"SELECT word, word_count FROM `bigquery-public-data.samples.shakespeare` WHERE corpus = 'hamlet' ORDER BY word_count DESC LIMIT 5\"," ++
        "\"useLegacySql\":false,\"maximumBytesBilled\":\"100000000\",\"timeoutMs\":10000," ++
        "\"requestId\":\"" ++ fixed_request_id ++ "\",\"formatOptions\":{\"useInt64Timestamp\":true}}");
    try testing.expect(run.value.complete);
    try testing.expectEqual(5, run.value.rows.len);
    try testing.expectEqual(5, run.value.total_rows.?);
    try testing.expectEqualStrings("word", run.value.schema[0].name);
    try testing.expectEqualStrings("the", run.value.rows[0].cells[0].value.string);
    try testing.expectEqualStrings("SELECT", run.value.statement_type);
    // Answered from the cache, an earlier run's: nothing billed.
    try testing.expect(run.value.cache_hit.?);
    try testing.expectEqual(0, run.value.total_bytes_billed.?);
    try testing.expectEqualStrings("US", run.value.job.?.location);

    var dry = try c.dryRun(.{ .query = hamlet });
    defer dry.deinit();
    try h.expectSent(1, .POST, base ++ "my-project/queries", "{\"query\":\"SELECT word, word_count FROM `bigquery-public-data.samples.shakespeare` WHERE corpus = 'hamlet' ORDER BY word_count DESC LIMIT 5\"," ++
        "\"useLegacySql\":false,\"dryRun\":true}");
    try testing.expectEqual(5_114_816, dry.value.total_bytes_processed.?);
    try testing.expectEqual(2, dry.value.schema.len);
    try testing.expectEqualStrings("SELECT", dry.value.statement_type);

    const job: types.JobRef = .{ .id = "job_zuWkgIS8xmg5cnX_F1jDBhKLWyA4", .location = "US" };
    var page = try c.getQueryResults(job, .{ .page_token = "BGYGO", .page_size = 10 });
    defer page.deinit();
    try h.expectRequest(2, .GET, base ++ "my-project/queries/job_zuWkgIS8xmg5cnX_F1jDBhKLWyA4?formatOptions.useInt64Timestamp=true&location=US&maxResults=10&pageToken=BGYGO&timeoutMs=10000");
    try testing.expectEqual(10, page.value.rows.len);
    try testing.expect(page.value.page_token != null);

    var wait = try c.getQueryResults(.{ .project = "other-project", .id = "job_5aP-2fB2ZnFmxumu9Gzyjx_d4D7k" }, .{ .page_size = 0, .timeout_ms = 60_000, .start_index = 45 });
    defer wait.deinit();
    try h.expectRequest(3, .GET, base ++ "other-project/queries/job_5aP-2fB2ZnFmxumu9Gzyjx_d4D7k?formatOptions.useInt64Timestamp=true&maxResults=0&startIndex=45&timeoutMs=60000");
    try testing.expect(wait.value.complete);
    try testing.expectEqual(0, wait.value.rows.len);
    try testing.expectEqual(1, wait.value.total_rows.?);

    var cancel = try c.cancelJob(.{ .id = "job_uJJN89pQ9cqYnDKc4Z_VpBpHsSqC", .location = "US" });
    defer cancel.deinit();
    try h.expectSent(4, .POST, base ++ "my-project/jobs/job_uJJN89pQ9cqYnDKc4Z_VpBpHsSqC/cancel?location=US", "");
    try testing.expectEqual(types.JobState.running, cancel.value.state);

    // Every option a query takes.
    var full = try c.query(.{
        .query = "SELECT n FROM t",
        .maximum_bytes_billed = 0,
        .location = "us-central1",
        .default_dataset = .{ .dataset = "zigps_d" },
        .use_query_cache = false,
        .timeout_ms = 0,
        .page_size = 100,
        .labels = &.{ .{ .key = "team", .value = "data" }, .{ .key = "é", .value = "" } },
        .request_id = "zigps-rid",
    });
    defer full.deinit();
    try h.expectSent(5, .POST, base ++ "my-project/queries", "{\"query\":\"SELECT n FROM t\",\"useLegacySql\":false,\"location\":\"us-central1\"," ++
        "\"defaultDataset\":{\"projectId\":\"my-project\",\"datasetId\":\"zigps_d\"},\"useQueryCache\":false," ++
        "\"maximumBytesBilled\":\"0\",\"labels\":{\"team\":\"data\",\"é\":\"\"},\"timeoutMs\":0,\"maxResults\":100," ++
        "\"requestId\":\"zigps-rid\",\"formatOptions\":{\"useInt64Timestamp\":true}}");
}

test "a query's answers: unfinished, a repeat, a statement without rows, no job" {
    var h: Harness = undefined;
    try h.init(&.{
        .{ .respond = .{ .body = production.query_slow } },
        .{ .respond = .{ .body = production.query_repeat } },
        .{ .respond = .{ .body = production.query_insert } },
        .{ .respond = .{ .body = production.query_optional_job } },
        .{ .respond = .{ .body = production.results_unfinished } },
        .{ .respond = .{ .body = production.results_last } },
        .{ .respond = .{ .body = production.cancel_done } },
    });
    defer h.deinit();
    const c = &h.client;

    var slow = try c.query(.{ .query = "SELECT 1", .timeout_ms = 10 });
    defer slow.deinit();
    try testing.expect(!slow.value.complete);
    try testing.expectEqualStrings("job_yqKr7l89vGwL2TIqWdhA7sDltZ8O", slow.value.job.?.id);
    try testing.expectEqual(0, slow.value.schema.len);

    var repeat = try c.query(.{ .query = "SELECT 1", .request_id = "zigps-828161-rid" });
    defer repeat.deinit();
    try testing.expect(!repeat.value.complete);
    try testing.expectEqualStrings("job_Sorr4TiYD0h32C31IK3GGXkQXsEn", repeat.value.job.?.id);

    var insert = try c.query(.{ .query = "INSERT t (n) VALUES (1), (2)" });
    defer insert.deinit();
    try testing.expectEqual(2, insert.value.num_dml_affected_rows.?);
    try testing.expectEqualStrings("INSERT", insert.value.statement_type);
    try testing.expectEqual(0, insert.value.rows.len);

    var optional = try c.query(.{ .query = "SELECT 1" });
    defer optional.deinit();
    try testing.expectEqual(null, optional.value.job);
    try testing.expect(optional.value.query_id.len > 0);
    try testing.expectEqual(1, optional.value.rows[0].cells[0].value.int64);

    var unfinished = try c.getQueryResults(.{ .id = "job_yqKr7l89vGwL2TIqWdhA7sDltZ8O" }, .{ .timeout_ms = 2000 });
    defer unfinished.deinit();
    try testing.expect(!unfinished.value.complete);

    var last = try c.getQueryResults(.{ .id = "job_zuWkgIS8xmg5cnX_F1jDBhKLWyA4" }, .{});
    defer last.deinit();
    try testing.expectEqual(null, last.value.page_token);
    try testing.expectEqual(10, last.value.rows.len);

    var done = try c.cancelJob(.{ .id = "job_uJJN89pQ9cqYnDKc4Z_VpBpHsSqC" });
    defer done.deinit();
    try testing.expect(done.value.failed());
    try testing.expectEqualStrings("stopped", done.value.@"error".?.reason);
}

test "a query's refusals, each its error with production's words" {
    var h: Harness = undefined;
    try h.init(&.{
        .{ .respond = .{ .status = production.query_syntax_status, .body = production.query_syntax } },
        .{ .respond = .{ .status = production.dry_run_syntax_status, .body = production.dry_run_syntax } },
        .{ .respond = .{ .status = production.query_over_limit_status, .body = production.query_over_limit } },
        .{ .respond = .{ .status = production.query_runtime_error_status, .body = production.query_runtime_error } },
        .{ .respond = .{ .status = production.query_location_eu_status, .body = production.query_location_eu } },
        .{ .respond = .{ .status = production.dry_run_missing_table_status, .body = production.dry_run_missing_table } },
    });
    defer h.deinit();
    const c = &h.client;
    const syntax = "SELECT 1\n  WHERE";

    if (c.query(.{ .query = syntax })) |unexpected| {
        var u = unexpected;
        u.deinit();
        return error.TestUnexpectedResult;
    } else |err| try testing.expectEqual(error.InvalidQuery, err);
    try testing.expectEqualStrings("Syntax error: Unexpected keyword WHERE at [2:3]", h.diag.message());
    try testing.expectEqual(@import("values.zig").Position{ .line = 2, .column = 3 }, @import("values.zig").errorPosition(h.diag.message()).?);
    try testing.expectError(error.InvalidQuery, c.dryRun(.{ .query = syntax }));
    try testing.expectError(error.BytesBilledLimitExceeded, c.query(.{ .query = hamlet, .maximum_bytes_billed = 1000 }));
    try testing.expectEqualStrings("Query exceeded limit for bytes billed: 1000. 10485760 or higher required.", h.diag.message());
    try testing.expectError(error.InvalidQuery, c.query(.{ .query = "SELECT 1 / 0" }));
    try testing.expectEqualStrings("division by zero: 1 / 0", h.diag.message());
    try testing.expectEqual(null, @import("values.zig").errorPosition(h.diag.message()));
    try testing.expectError(error.PermissionDenied, c.query(.{ .query = hamlet, .location = "EU" }));
    try testing.expect(std.mem.indexOf(u8, (try h.fake.request(4)).body.?, "\"location\":\"EU\"") != null);
    try testing.expect(std.mem.startsWith(u8, h.diag.message(), "Access Denied: Table bigquery-public-data:samples.shakespeare"));
    try testing.expectError(error.NotFound, c.dryRun(.{ .query = "SELECT * FROM zigps_nobody.t" }));
    // Each refusal is final: one request apiece.
    try h.expectRequestCount(6);
}

test "the queries refuse what they will not send" {
    var h: Harness = undefined;
    try h.initScope(&.{}, .cloud_platform_read_only);
    defer h.deinit();
    const c = &h.client;
    const Case = struct { types.QueryOptions, Error, []const u8 };
    var many: [65]types.Label = undefined;
    var keys: [65][2]u8 = undefined;
    for (&many, &keys, 0..) |*l, *k, i| {
        k.* = .{ 'a' + @as(u8, @intCast(i / 26)), 'a' + @as(u8, @intCast(i % 26)) };
        l.* = .{ .key = k, .value = "v" };
    }
    for ([_]Case{
        .{ .{ .query = "" }, error.InvalidOptions, "invalid query: expected UTF-8 text, not empty" },
        .{ .{ .query = "SELECT '\xff'" }, error.InvalidOptions, "invalid query: expected UTF-8 text, not empty" },
        .{ .{ .query = "SELECT 1", .location = "us central1" }, error.InvalidName, "invalid location: expected US, EU or a region such as us-central1" },
        .{ .{ .query = "SELECT 1", .default_dataset = .{ .dataset = "a-b" } }, error.InvalidName, "invalid dataset id: expected letters, digits and _, at most 1,024" },
        .{ .{ .query = "SELECT 1", .default_dataset = .{ .project = "a/b", .dataset = "d" } }, error.InvalidName, "invalid project: expected a project id or number" },
        .{ .{ .query = "SELECT 1", .labels = &many }, error.InvalidOptions, "invalid labels: more than 64" },
        .{ .{ .query = "SELECT 1", .labels = &.{.{ .key = "Team", .value = "x" }} }, error.InvalidOptions, "invalid label: keys and values are lowercase letters, digits, _ and -, at most 63 characters, a key starting with a letter" },
        .{ .{ .query = "SELECT 1", .labels = &.{.{ .key = "team", .value = "X" }} }, error.InvalidOptions, "invalid label: keys and values are lowercase letters, digits, _ and -, at most 63 characters, a key starting with a letter" },
        .{ .{ .query = "SELECT 1", .labels = &.{ .{ .key = "team", .value = "a" }, .{ .key = "team", .value = "b" } } }, error.InvalidOptions, "invalid labels: the key team appears twice" },
    }) |case| {
        try testing.expectError(case[1], c.dryRun(case[0]));
        try testing.expectEqualStrings(case[2], h.diag.message());
        if (c.queryRequest(case[0])) |unexpected| {
            var u = unexpected;
            u.deinit();
            return error.TestUnexpectedResult;
        } else |err| try testing.expectEqual(case[1], err);
    }
    // 64 labels are taken.
    var preview = try c.dryRunRequest(.{ .query = "SELECT 1", .labels = many[0..64] });
    preview.deinit();
    try testing.expectError(error.InvalidOptions, c.queryRequest(.{ .query = "SELECT 1", .request_id = core.testing.repeat("a", 37) }));
    try testing.expectEqualStrings("invalid request id: expected 1 to 36 printable ASCII characters", h.diag.message());
    // A dry run sends no request id, so it checks none.
    var dry = try c.dryRunRequest(.{ .query = "SELECT 1", .request_id = core.testing.repeat("a", 37) });
    dry.deinit();
    try testing.expectError(error.InvalidOptions, c.getQueryResults(.{ .id = "j" }, .{ .page_token = "t", .start_index = 0 }));
    try testing.expectEqualStrings("invalid results options: page_token and start_index are each a place to start; give one", h.diag.message());
    try testing.expectError(error.InvalidName, c.getQueryResults(.{ .id = "j" }, .{ .page_token = "a b" }));
    try testing.expectError(error.InvalidName, c.getQueryResults(.{ .id = "US.j" }, .{}));
    try testing.expectError(error.InvalidName, c.getQueryResults(.{ .id = "j", .location = "u s" }, .{}));
    // cloud-platform.read-only, which production refuses a cancel.
    try testing.expectError(error.InvalidOptions, c.cancelJob(.{ .id = "j" }));
    try testing.expectEqualStrings("this client asks for cloud-platform.read-only, which production refuses a cancel; give Options.scope .bigquery or .cloud_platform", h.diag.message());
    try testing.expectError(error.InvalidOptions, c.cancelJobRequest(.{ .id = "j" }));
    try h.expectRequestCount(0);
}

test "the previews are byte for byte what the calls send" {
    var h: Harness = undefined;
    try h.init(&.{
        .{ .respond = .{ .body = production.query_dry_run } },
        .{ .respond = .{ .body = production.query_run } },
        .{ .respond = .{ .body = production.cancel_running } },
    });
    defer h.deinit();
    const c = &h.client;
    var id_buf: [36]u8 = undefined;
    const options: types.QueryOptions = .{
        .query = hamlet,
        .maximum_bytes_billed = 20 * 1024 * 1024,
        .location = "US",
        .labels = &.{.{ .key = "console", .value = "inlay" }},
        .request_id = c.newRequestId(&id_buf),
    };
    const job: types.JobRef = .{ .project = "extractctl", .id = "job_uJJN89pQ9cqYnDKc4Z_VpBpHsSqC", .location = "US" };
    var previews = [_]types.Owned(PreparedRequest){
        try c.dryRunRequest(options),
        try c.queryRequest(options),
        try c.cancelJobRequest(job),
    };
    defer for (&previews) |*p| p.deinit();
    var dry = try c.dryRun(options);
    dry.deinit();
    var run = try c.query(options);
    run.deinit();
    var cancel = try c.cancelJob(job);
    cancel.deinit();
    for (previews, 0..) |p, i| {
        const sent = try h.fake.request(i);
        try testing.expectEqual(p.value.method, sent.method);
        try testing.expectEqualStrings(p.value.url, sent.url);
        try testing.expectEqualStrings(p.value.body, sent.body orelse "");
    }
    try testing.expect(std.mem.indexOf(u8, previews[1].value.body, id_buf[0..]) != null);
}

test "newRequestId: a version 4 UUID, fresh each time" {
    var h: Harness = undefined;
    try h.init(&.{});
    defer h.deinit();
    var a: [36]u8 = undefined;
    var b: [36]u8 = undefined;
    const first = h.client.newRequestId(&a);
    const second = h.client.newRequestId(&b);
    try testing.expect(!std.mem.eql(u8, first, second));
    for ([_][]const u8{ first, second }) |id| {
        try testing.expect(validate.isRequestId(id));
        try testing.expectEqual('-', id[8]);
        try testing.expectEqual('-', id[13]);
        try testing.expectEqual('4', id[14]);
        try testing.expectEqual('-', id[18]);
        try testing.expect(std.mem.indexOfScalar(u8, "89ab", id[19]) != null);
        try testing.expectEqual('-', id[23]);
    }
    h.clock.random_byte = 0xab;
    try testing.expectEqualStrings(fixed_request_id, h.client.newRequestId(&a));
    h.clock.random_byte = 0x00;
    try testing.expectEqualStrings("00000000-0000-4000-8000-000000000000", h.client.newRequestId(&a));
    h.clock.random_byte = 0xff;
    try testing.expectEqualStrings("ffffffff-ffff-4fff-bfff-ffffffffffff", h.client.newRequestId(&a));
}

test "a query's retry resends the same request id; a dry run's and a cancel's retry as the reads do" {
    const unavailable: test_util.FakeTransport.Reply = .{ .respond = .{ .status = 503, .body = "{\"error\":{\"code\":503,\"message\":\"Service unavailable\",\"status\":\"UNAVAILABLE\"}}" } };
    var h: Harness = undefined;
    try h.init(&.{
        unavailable,
        .{ .respond = .{ .body = production.query_run } },
        unavailable,
        .{ .respond = .{ .body = production.query_dry_run } },
        unavailable,
        .{ .respond = .{ .body = production.cancel_done } },
        .{ .respond = .{ .status = 403, .body = "{\"error\":{\"code\":403,\"message\":\"Exceeded rate limits\",\"errors\":[{\"reason\":\"rateLimitExceeded\"}]}}" } },
        .{ .respond = .{ .body = production.results_last } },
    });
    defer h.deinit();
    const c = &h.client;
    var run = try c.query(.{ .query = "SELECT 1" });
    run.deinit();
    const first = try h.fake.request(0);
    const second = try h.fake.request(1);
    try testing.expectEqualStrings(first.body.?, second.body.?);
    try testing.expect(std.mem.indexOf(u8, first.body.?, "\"requestId\":\"") != null);
    var dry = try c.dryRun(.{ .query = "SELECT 1" });
    dry.deinit();
    var cancel = try c.cancelJob(.{ .id = "j" });
    cancel.deinit();
    var page = try c.getQueryResults(.{ .id = "j" }, .{});
    page.deinit();
    try h.expectRequestCount(8);
    // Two queries make two ids.
    var again = try c.queryRequest(.{ .query = "SELECT 1" });
    defer again.deinit();
    try testing.expect(!std.mem.eql(u8, first.body.?, again.value.body));
}

test "a query is retried only within its request id's window" {
    // Asked to wait eleven minutes before the next attempt: past the
    // window.
    const unavailable: test_util.FakeTransport.Reply = .{ .respond = .{
        .status = 503,
        .body = "{\"error\":{\"code\":503,\"message\":\"Service unavailable\",\"status\":\"UNAVAILABLE\"}}",
        .headers = &.{.{ .name = "Retry-After", .value = "660" }},
    } };
    var fake: test_util.FakeTransport = .init(testing.allocator, &.{ unavailable, unavailable, .{ .respond = .{ .body = production.dataset_ours } } });
    defer fake.deinit();
    var tokens: test_util.FakeTokenProvider = .{};
    var clock: test_util.FakeClock = .{};
    var client = try Client.init(testing.allocator, clock.io(), .{
        .project_id = "p",
        .token_provider = tokens.provider(),
        .transport = fake.transport(),
        .retry = .{ .max_backoff_ms = 20 * std.time.ms_per_min },
    });
    defer client.deinit();
    try testing.expectError(error.Unavailable, client.query(.{ .query = "SELECT 1" }));
    try testing.expectEqual(1, fake.requests.items.len);
    // A read waits it out.
    var dataset = try client.getDataset(.{ .dataset = "d" });
    dataset.deinit();
    try testing.expectEqual(3, fake.requests.items.len);
}

test "a held call's request outlasts the hold it asks" {
    var h: Harness = undefined;
    try h.init(&.{
        .{ .respond = .{ .body = production.results_wait } },
        .{ .respond = .{ .body = production.results_last } },
        .{ .respond = .{ .body = production.query_slow } },
        .{ .respond = .{ .body = production.query_dry_run } },
    });
    defer h.deinit();
    const c = &h.client;
    var wait = try c.getQueryResults(.{ .id = "j" }, .{ .timeout_ms = 60_000, .page_size = 0 });
    wait.deinit();
    try testing.expectEqual(60_000 + rpc.hold_margin_ms, (try h.fake.request(0)).timeout_ms);
    // A short hold keeps the client's own timeout.
    var page = try c.getQueryResults(.{ .id = "j" }, .{ .timeout_ms = 0 });
    page.deinit();
    try testing.expectEqual(30_000, (try h.fake.request(1)).timeout_ms);
    var slow = try c.query(.{ .query = "SELECT 1", .timeout_ms = 200_000 });
    slow.deinit();
    try testing.expectEqual(200_000 + rpc.hold_margin_ms, (try h.fake.request(2)).timeout_ms);
    // A dry run is not held.
    var dry = try c.dryRun(.{ .query = "SELECT 1", .timeout_ms = 200_000 });
    dry.deinit();
    try testing.expectEqual(30_000, (try h.fake.request(3)).timeout_ms);

    // A client whose timeout is longer than the hold keeps it.
    {
        var long_fake: test_util.FakeTransport = .init(testing.allocator, &.{.{ .respond = .{ .body = production.results_wait } }});
        defer long_fake.deinit();
        var long_tokens: test_util.FakeTokenProvider = .{};
        var long_clock: test_util.FakeClock = .{};
        var long = try Client.init(testing.allocator, long_clock.io(), .{ .project_id = "p", .token_provider = long_tokens.provider(), .transport = long_fake.transport(), .request_timeout_ms = 120_000 });
        defer long.deinit();
        var held = try long.getQueryResults(.{ .id = "j" }, .{ .timeout_ms = 10_000 });
        held.deinit();
        try testing.expectEqual(120_000, (try long_fake.request(0)).timeout_ms);
    }
    // A client without a timeout stays without one.
    var fake: test_util.FakeTransport = .init(testing.allocator, &.{.{ .respond = .{ .body = production.results_wait } }});
    defer fake.deinit();
    var tokens: test_util.FakeTokenProvider = .{};
    var clock: test_util.FakeClock = .{};
    var client = try Client.init(testing.allocator, clock.io(), .{ .project_id = "p", .token_provider = tokens.provider(), .transport = fake.transport(), .request_timeout_ms = 0 });
    defer client.deinit();
    var held = try client.getQueryResults(.{ .id = "j" }, .{ .timeout_ms = 60_000 });
    held.deinit();
    try testing.expectEqual(0, (try fake.request(0)).timeout_ms);
}

test "a query answer that cannot be decoded is InvalidResponse, named in Diagnostics" {
    var h: Harness = undefined;
    try h.init(&.{
        .{ .respond = .{ .body = "{\"jobComplete\":false}" } },
        .{ .respond = .{ .body = "{\"schema\":7}" } },
        .{ .respond = .{ .body = "{\"jobComplete\":true,\"rows\":[{\"f\":[{\"v\":\"1\"}]}]}" } },
        .{ .respond = .{ .body = "{\"kind\":\"bigquery#jobCancelResponse\"}" } },
    });
    defer h.deinit();
    const c = &h.client;
    try testing.expectError(error.InvalidResponse, c.query(.{ .query = "SELECT 1" }));
    try testing.expectEqualStrings("the query response could not be decoded", h.diag.message());
    try testing.expectError(error.InvalidResponse, c.dryRun(.{ .query = "SELECT 1" }));
    try testing.expectEqualStrings("the dry run response could not be decoded", h.diag.message());
    // Rows without a schema to read them by.
    try testing.expectError(error.InvalidResponse, c.getQueryResults(.{ .id = "j" }, .{}));
    try testing.expectEqualStrings("the query results response could not be decoded", h.diag.message());
    try testing.expectError(error.InvalidResponse, c.cancelJob(.{ .id = "j" }));
    try testing.expectEqualStrings("the cancel response could not be decoded", h.diag.message());
}

test "every allocation failure in the queries is OutOfMemory without leaks" {
    const Run = struct {
        fn calls(gpa: Allocator) !void {
            var fake: test_util.FakeTransport = .init(testing.allocator, &.{
                .{ .respond = .{ .body = production.query_dry_run } },
                .{ .respond = .{ .body = production.query_run } },
                .{ .respond = .{ .body = production.results_page } },
                .{ .respond = .{ .body = production.cancel_running } },
                .{ .respond = .{ .status = 400, .body = production.query_syntax } },
            });
            defer fake.deinit();
            var tokens: test_util.FakeTokenProvider = .{};
            var clock: test_util.FakeClock = .{};
            var client = try Client.init(gpa, clock.io(), .{ .project_id = "my-project", .token_provider = tokens.provider(), .transport = fake.transport() });
            defer client.deinit();
            const options: types.QueryOptions = .{ .query = hamlet, .default_dataset = .{ .dataset = "d" }, .labels = &.{.{ .key = "a", .value = "b" }} };
            var dry = try client.dryRun(options);
            dry.deinit();
            var run = try client.query(options);
            run.deinit();
            var page = try client.getQueryResults(.{ .id = "j", .location = "US" }, .{ .page_token = "t" });
            page.deinit();
            var cancel = try client.cancelJob(.{ .id = "j" });
            cancel.deinit();
            var dry_preview = try client.dryRunRequest(options);
            dry_preview.deinit();
            var query_preview = try client.queryRequest(options);
            query_preview.deinit();
            var cancel_preview = try client.cancelJobRequest(.{ .id = "j" });
            cancel_preview.deinit();
            if (client.query(options)) |unexpected| {
                var u = unexpected;
                u.deinit();
                return error.TestUnexpectedResult;
            } else |err| if (err != error.InvalidQuery) return err;
        }
    };
    try testing.checkAllAllocationFailures(test_util.no_grow_allocator, Run.calls, .{});
}
