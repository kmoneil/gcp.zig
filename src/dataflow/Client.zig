//! A Dataflow client: the jobs a project runs, across every region or one
//! at a time, with their states, and two writes, `cancelJob` and
//! `drainJob`, each with a preview of the exact request it sends. Nothing
//! here creates or launches a job, or changes one in any other way.
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

pub const default_endpoint = "https://dataflow.googleapis.com";

pub const Options = struct {
    /// Required: the project whose jobs are read, an id or a number.
    project_id: []const u8,
    /// Required. Dataflow has no emulator, so there is no
    /// unauthenticated mode.
    token_provider: TokenProvider,
    /// Overrides the host: a test server, say. Must be `https`, since it
    /// receives credentials.
    endpoint: ?[]const u8 = null,
    /// Sends the credentials' quota project as `x-goog-user-project`, as
    /// every module does.
    send_quota_project: bool = true,
    /// Every call here is safe to repeat, the two writes included (a
    /// repeat cancel or drain answered 200 and changed nothing, measured):
    /// 5xx, 429 and dropped connections are retried.
    retry: RetryPolicy = .{},
    /// How long one request may take before it is `error.TimedOut`, which
    /// is retried. 0 removes the limit.
    request_timeout_ms: u32 = 30_000,
    /// A response whose decompressed body is larger fails with
    /// `error.ResponseTooLarge`. Used by the built-in transport; a
    /// transport passed in keeps its own limit.
    max_response_bytes: usize = core.transport.default_max_response_bytes,
    /// Printable ASCII.
    user_agent: []const u8 = "gcp-zig-dataflow/0.59",
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

/// One page of every region's jobs: the pipelines widget's one call.
/// Each job carries the `location` a `getJob` of it needs. A page whose
/// `failed_locations` is not empty is silently missing those regions'
/// jobs. The aggregated list takes no name filter, production confirms:
/// the parameter is accepted and ignored (measured 2026-10-20).
pub fn aggregatedJobs(self: *Client, options: types.AggregatedOptions) Error!types.Owned(types.JobPage) {
    rpc.begin(self);
    try self.checkToken(options.page_token);
    var scratch: std.heap.ArenaAllocator = .init(self.gpa);
    defer scratch.deinit();
    const a = scratch.allocator();
    var w: std.Io.Writer.Allocating = .init(a);
    w.writer.writeAll(names.aggregated(a, self.project) catch return error.OutOfMemory) catch return error.OutOfMemory;
    var params: core.query.Params = .init(&w.writer);
    if (options.filter) |filter| params.addOptional("filter", filter.toWire()) catch return error.OutOfMemory;
    params.addNonZero("pageSize", options.page_size) catch return error.OutOfMemory;
    params.addOptional("pageToken", options.page_token) catch return error.OutOfMemory;

    var result: types.Owned(types.JobPage) = try .init(self.gpa);
    errdefer result.deinit();
    const body = try rpc.execute(self, result.arena, .{ .method = .GET, .path = w.written() });
    result.value = codec.decodeJobPage(result.arena.allocator(), a, body) catch |err|
        return rpc.decodeFailed(self, err, "job list");
    return result;
}

/// One page of a region's jobs. Only this list filters by `name`;
/// unset sends nothing and the server orders on descending JobUuid.
pub fn listJobs(self: *Client, location: []const u8, options: types.ListJobsOptions) Error!types.Owned(types.JobPage) {
    rpc.begin(self);
    try self.checkLocation(location);
    try self.checkToken(options.page_token);
    if (options.name) |name| if (!validate.isJobName(name)) {
        if (self.diagnostics) |d| d.print("invalid job name filter: visible ASCII, at most 1024", .{});
        return error.InvalidName;
    };
    var scratch: std.heap.ArenaAllocator = .init(self.gpa);
    defer scratch.deinit();
    const a = scratch.allocator();
    var w: std.Io.Writer.Allocating = .init(a);
    w.writer.writeAll(names.jobs(a, self.project, location) catch return error.OutOfMemory) catch return error.OutOfMemory;
    var params: core.query.Params = .init(&w.writer);
    if (options.filter) |filter| params.addOptional("filter", filter.toWire()) catch return error.OutOfMemory;
    params.addOptional("name", options.name) catch return error.OutOfMemory;
    params.addNonZero("pageSize", options.page_size) catch return error.OutOfMemory;
    params.addOptional("pageToken", options.page_token) catch return error.OutOfMemory;

    var result: types.Owned(types.JobPage) = try .init(self.gpa);
    errdefer result.deinit();
    const body = try rpc.execute(self, result.arena, .{ .method = .GET, .path = w.written() });
    result.value = codec.decodeJobPage(result.arena.allocator(), a, body) catch |err|
        return rpc.decodeFailed(self, err, "job list");
    return result;
}

/// One job, by its region and id, as the summary every list answers.
/// The legacy no-location get sees only us-central1 and is not here;
/// take the location from the aggregated list's jobs.
pub fn getJob(self: *Client, location: []const u8, id: []const u8) Error!types.Owned(types.Job) {
    rpc.begin(self);
    return self.getChecked(location, id, null);
}

/// One job at a chosen view. `.description` adds labels and the pipeline
/// description; `.all` adds the steps, and production answered a job
/// that failed provisioning with a 400 FAILED_PRECONDITION carrying the
/// job's own error text (measured 2026-10-20), so expect
/// `error.FailedPrecondition` there.
pub fn getJobView(self: *Client, location: []const u8, id: []const u8, view: types.JobView) Error!types.Owned(types.Job) {
    rpc.begin(self);
    return self.getChecked(location, id, view);
}

fn getChecked(self: *Client, location: []const u8, id: []const u8, view: ?types.JobView) Error!types.Owned(types.Job) {
    try self.checkJob(location, id);
    var scratch: std.heap.ArenaAllocator = .init(self.gpa);
    defer scratch.deinit();
    const a = scratch.allocator();
    var w: std.Io.Writer.Allocating = .init(a);
    w.writer.writeAll(names.job(a, self.project, location, id) catch return error.OutOfMemory) catch return error.OutOfMemory;
    var params: core.query.Params = .init(&w.writer);
    if (view) |v| params.addOptional("view", v.toWire()) catch return error.OutOfMemory;

    var result: types.Owned(types.Job) = try .init(self.gpa);
    errdefer result.deinit();
    const body = try rpc.execute(self, result.arena, .{ .method = .GET, .path = w.written() });
    result.value = codec.decodeJob(result.arena.allocator(), a, body) catch |err|
        return rpc.decodeFailed(self, err, "job");
    return result;
}

/// One page of a job's story: the messages at or above
/// `minimum_importance` (`.@"error"` is the widget's "why is it red"),
/// and the autoscaling events, which production answers regardless of
/// the filter.
pub fn listMessages(self: *Client, location: []const u8, id: []const u8, options: types.ListMessagesOptions) Error!types.Owned(types.MessagePage) {
    rpc.begin(self);
    try self.checkJob(location, id);
    try self.checkToken(options.page_token);
    var scratch: std.heap.ArenaAllocator = .init(self.gpa);
    defer scratch.deinit();
    const a = scratch.allocator();
    var w: std.Io.Writer.Allocating = .init(a);
    w.writer.writeAll(names.messages(a, self.project, location, id) catch return error.OutOfMemory) catch return error.OutOfMemory;
    var params: core.query.Params = .init(&w.writer);
    if (options.minimum_importance) |min| params.addOptional("minimumImportance", min.toWire()) catch return error.OutOfMemory;
    var start_buf: [core.timestamp.max_len]u8 = undefined;
    if (options.start_time) |t| params.addOptional("startTime", core.timestamp.format(&start_buf, t)) catch return error.OutOfMemory;
    var end_buf: [core.timestamp.max_len]u8 = undefined;
    if (options.end_time) |t| params.addOptional("endTime", core.timestamp.format(&end_buf, t)) catch return error.OutOfMemory;
    params.addNonZero("pageSize", options.page_size) catch return error.OutOfMemory;
    params.addOptional("pageToken", options.page_token) catch return error.OutOfMemory;

    var result: types.Owned(types.MessagePage) = try .init(self.gpa);
    errdefer result.deinit();
    const body = try rpc.execute(self, result.arena, .{ .method = .GET, .path = w.written() });
    result.value = codec.decodeMessagePage(result.arena.allocator(), a, body) catch |err|
        return rpc.decodeFailed(self, err, "message list");
    return result;
}

/// Asks the service to cancel the job, batch or streaming: its workers
/// stop without finishing what is in flight. Production answers nothing
/// but the job's type, so read the job to watch it stop: a get right
/// after shows `current_state` `.cancelling` and `requested_state`
/// `.cancelled`, then `.cancelled` (measured; the guide has the times).
///
/// A job still `.pending` is refused, `error.FailedPrecondition`, "Job is
/// not yet ready for canceling. Please retry in a few minutes.": it is
/// taken once the job runs. A job that has ended is refused too. Takes
/// `dataflow.jobs.cancel`, which Dataflow Developer holds and Dataflow
/// Viewer does not.
pub fn cancelJob(self: *Client, location: []const u8, id: []const u8) Error!void {
    return self.stop(.cancel, location, id);
}

/// Asks a streaming job to drain: it stops pulling from its sources,
/// finishes what is in flight, and ends `.drained`. As with `cancelJob`,
/// production answers nothing but the job's type; read the job to watch
/// it. A batch job is refused, `error.InvalidArgument`, "Only streaming
/// workflows can be drained.". Takes `dataflow.jobs.cancel` too: the API
/// has no drain permission.
pub fn drainJob(self: *Client, location: []const u8, id: []const u8) Error!void {
    return self.stop(.drain, location, id);
}

/// The request `cancelJob` sends for the same arguments, built without
/// sending it, after the same checks with the same errors: to show before
/// the call, or to record after it. Credentials and other headers are not
/// part of it.
pub fn cancelJobRequest(self: *Client, location: []const u8, id: []const u8) Error!types.Owned(PreparedRequest) {
    return self.prepare(.cancel, location, id);
}

/// The request `drainJob` sends, as `cancelJobRequest` says.
pub fn drainJobRequest(self: *Client, location: []const u8, id: []const u8) Error!types.Owned(PreparedRequest) {
    return self.prepare(.drain, location, id);
}

/// The two writes: one method, `UpdateJob`, a PUT of the job's requested
/// state alone.
const Stop = enum {
    cancel,
    drain,

    /// What gcloud sends too. With no update mask the server considers
    /// the requested state alone; a drain asks for the end state.
    fn body(self: Stop) []const u8 {
        return switch (self) {
            .cancel => "{\"requestedState\":\"JOB_STATE_CANCELLED\"}",
            .drain => "{\"requestedState\":\"JOB_STATE_DRAINED\"}",
        };
    }
};

fn prepare(self: *Client, which: Stop, location: []const u8, id: []const u8) Error!types.Owned(PreparedRequest) {
    rpc.begin(self);
    var result: types.Owned(PreparedRequest) = try .init(self.gpa);
    errdefer result.deinit();
    const a = result.arena.allocator();
    result.value = try .fromCall(a, self.base_url, try self.stopCall(a, which, location, id));
    return result;
}

/// The call `which` sends, after the checks every job call makes.
fn stopCall(self: *Client, arena: Allocator, which: Stop, location: []const u8, id: []const u8) Error!rpc.Call {
    try self.checkJob(location, id);
    return .{ .method = .PUT, .path = try names.job(arena, self.project, location, id), .body = which.body() };
}

/// Sends a cancel or a drain. Either one landing twice changes nothing
/// (a repeat while cancelling answered 200, measured), so both are
/// retried as the reads are.
fn stop(self: *Client, which: Stop, location: []const u8, id: []const u8) Error!void {
    rpc.begin(self);
    var scratch: std.heap.ArenaAllocator = .init(self.gpa);
    defer scratch.deinit();
    const a = scratch.allocator();
    const call = try self.stopCall(a, which, location, id);
    // Apart from the call's own memory: a retry resets it.
    var response: std.heap.ArenaAllocator = .init(self.gpa);
    defer response.deinit();
    const body = try rpc.execute(self, &response, call);
    codec.checkStopAnswer(a, body) catch |err|
        return rpc.decodeFailed(self, err, @tagName(which));
}

fn checkLocation(self: *Client, location: []const u8) Error!void {
    if (!validate.isLocation(location)) {
        if (self.diagnostics) |d| d.print("invalid location: expected a region id such as us-central1", .{});
        return error.InvalidName;
    }
}

fn checkJob(self: *Client, location: []const u8, id: []const u8) Error!void {
    try self.checkLocation(location);
    if (!validate.isJobId(id)) {
        if (self.diagnostics) |d| d.print("invalid job id: visible ASCII without /, at most 1024", .{});
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

test "golden: jobs listed everywhere and per region, got plain and at a view" {
    var h: Harness = undefined;
    try h.init(&.{
        .{ .respond = .{ .body = production.jobs_aggregated } },
        .{ .respond = .{ .body = production.jobs_list } },
        .{ .respond = .{ .body = production.jobs_list_paged } },
        .{ .respond = .{ .body = production.job_done } },
        .{ .respond = .{ .body = production.job_running } },
    });
    defer h.deinit();

    var everywhere = try h.client.aggregatedJobs(.{ .filter = .all });
    defer everywhere.deinit();
    try h.expectRequest(0, .GET, "https://dataflow.googleapis.com/v1b3/projects/my-project/jobs:aggregated?filter=ALL");
    try testing.expectEqual(2, everywhere.value.jobs.len);
    try testing.expectEqual(0, everywhere.value.failed_locations.len);
    try testing.expectEqualStrings("us-central1", everywhere.value.jobs[0].location);

    var listed = try h.client.listJobs("us-central1", .{ .name = "zigps-df-05461" });
    defer listed.deinit();
    try h.expectRequest(1, .GET, "https://dataflow.googleapis.com/v1b3/projects/my-project/locations/us-central1/jobs?name=zigps-df-05461");
    try testing.expectEqual(2, listed.value.jobs.len);

    var paged = try h.client.listJobs("us-central1", .{ .filter = .terminated, .page_size = 1, .page_token = "t" });
    defer paged.deinit();
    try h.expectRequest(2, .GET, "https://dataflow.googleapis.com/v1b3/projects/my-project/locations/us-central1/jobs?filter=TERMINATED&pageSize=1&pageToken=t");
    try testing.expect(paged.value.next_page_token != null);

    var done = try h.client.getJob("us-central1", "2026-10-20_07_11_01-16829577348630633066");
    defer done.deinit();
    try h.expectRequest(3, .GET, "https://dataflow.googleapis.com/v1b3/projects/my-project/locations/us-central1/jobs/2026-10-20_07_11_01-16829577348630633066");
    try testing.expect(done.value.terminal());
    try testing.expect(!done.value.failing());

    var described = try h.client.getJobView("us-central1", "2026-10-20_07_11_01-16829577348630633066", .description);
    defer described.deinit();
    try h.expectRequest(4, .GET, "https://dataflow.googleapis.com/v1b3/projects/my-project/locations/us-central1/jobs/2026-10-20_07_11_01-16829577348630633066?view=JOB_VIEW_DESCRIPTION");
    try testing.expectEqual(types.JobState.running, described.value.current_state);
}

test "golden: a job's story, errors first, the events coming regardless" {
    var h: Harness = undefined;
    try h.init(&.{
        .{ .respond = .{ .body = production.messages_error_failed } },
        .{ .respond = .{ .body = production.messages_error_done } },
    });
    defer h.deinit();
    var red = try h.client.listMessages("us-central1", "2026-10-20_07_09_34-8524524531325271694", .{ .minimum_importance = .@"error" });
    defer red.deinit();
    try h.expectRequest(0, .GET, "https://dataflow.googleapis.com/v1b3/projects/my-project/locations/us-central1/jobs/2026-10-20_07_09_34-8524524531325271694/messages?minimumImportance=JOB_MESSAGE_ERROR");
    try testing.expectEqual(1, red.value.messages.len);
    try testing.expect(std.mem.indexOf(u8, red.value.messages[0].text, "service agent") != null);
    var quiet = try h.client.listMessages("us-central1", "2026-10-20_07_11_01-16829577348630633066", .{ .page_size = 5, .page_token = "t" });
    defer quiet.deinit();
    try h.expectRequest(1, .GET, "https://dataflow.googleapis.com/v1b3/projects/my-project/locations/us-central1/jobs/2026-10-20_07_11_01-16829577348630633066/messages?pageSize=5&pageToken=t");
    try testing.expectEqual(0, quiet.value.messages.len);
    try testing.expectEqual(6, quiet.value.autoscaling_events.len);
}

test "the calls refuse what they will not send" {
    var h: Harness = undefined;
    try h.init(&.{});
    defer h.deinit();
    const c = &h.client;
    try testing.expectError(error.InvalidName, c.listJobs("US-central1", .{}));
    try testing.expectError(error.InvalidName, c.listJobs("", .{}));
    try testing.expectError(error.InvalidName, c.listJobs("us central1", .{}));
    try testing.expectError(error.InvalidName, c.listJobs("us-central1", .{ .name = "a b" }));
    try testing.expectError(error.InvalidName, c.listJobs("us-central1", .{ .page_token = "a b" }));
    try testing.expectError(error.InvalidName, c.aggregatedJobs(.{ .page_token = "" }));
    try testing.expectError(error.InvalidName, c.getJob("us-central1", "a/b"));
    try testing.expectError(error.InvalidName, c.getJob("us-central1", ""));
    try testing.expectError(error.InvalidName, c.getJobView("us central1", "j", .all));
    try testing.expectError(error.InvalidName, c.listMessages("us-central1", "a/b", .{}));
    try testing.expectError(error.InvalidName, c.listMessages("", "j", .{}));
    try testing.expectError(error.InvalidName, c.listMessages("us-central1", "j", .{ .page_token = "a b" }));
    try testing.expectEqualStrings("invalid page token: expected printable ASCII", h.diag.message());
    try h.expectRequestCount(0);
}

test "a response that cannot be decoded is InvalidResponse, named in Diagnostics" {
    var h: Harness = undefined;
    try h.init(&.{
        .{ .respond = .{ .body = "{\"jobs\":1}" } },
        .{ .respond = .{ .body = "{\"name\":\"no-id\"}" } },
        .{ .respond = .{ .body = "[]" } },
    });
    defer h.deinit();
    try testing.expectError(error.InvalidResponse, h.client.listJobs("us-central1", .{}));
    try testing.expectEqualStrings("the job list response could not be decoded", h.diag.message());
    try testing.expectError(error.InvalidResponse, h.client.getJob("us-central1", "j"));
    try testing.expectEqualStrings("the job response could not be decoded", h.diag.message());
    try testing.expectError(error.InvalidResponse, h.client.aggregatedJobs(.{}));
}

test "a message list that cannot be decoded is InvalidResponse too" {
    var h: Harness = undefined;
    try h.init(&.{
        .{ .respond = .{ .body = "{\"jobMessages\":1}" } },
    });
    defer h.deinit();
    try testing.expectError(error.InvalidResponse, h.client.listMessages("us-central1", "j", .{}));
    try testing.expectEqualStrings("the message list response could not be decoded", h.diag.message());
}

test "the server's refusals arrive as errors, production's words kept" {
    var h: Harness = undefined;
    try h.init(&.{
        .{ .respond = .{ .status = production.job_unknown_status, .body = production.job_unknown } },
        .{ .respond = .{ .status = production.filter_bad_status, .body = production.filter_bad } },
        .{ .respond = .{ .status = production.job_failed_view_all_status, .body = production.job_failed_view_all } },
    });
    defer h.deinit();
    try testing.expectError(error.NotFound, h.client.getJob("us-central1", "2026-10-20_00_00_00-1234567890123456789"));
    try testing.expect(std.mem.indexOf(u8, h.diag.message(), "could not be found") != null);
    try testing.expectError(error.InvalidArgument, h.client.listJobs("us-central1", .{ .filter = .all }));
    // A get at ALL of a job that failed provisioning: 400
    // FAILED_PRECONDITION carrying the job's own error text, as
    // production answered.
    try testing.expectError(error.FailedPrecondition, h.client.getJobView("us-central1", "2026-10-20_07_09_34-8524524531325271694", .all));
    try testing.expect(std.mem.indexOf(u8, h.diag.message(), "service agent") != null);
}

const job_url = "https://dataflow.googleapis.com/v1b3/projects/my-project/locations/us-central1/jobs/2026-10-20_07_11_01-16829577348630633066";
const cancel_body = "{\"requestedState\":\"JOB_STATE_CANCELLED\"}";
const drain_body = "{\"requestedState\":\"JOB_STATE_DRAINED\"}";
const cancelled_reply: test_util.FakeTransport.Reply = .{ .respond = .{ .body = production.cancel_taken } };
const drained_reply: test_util.FakeTransport.Reply = .{ .respond = .{ .body = production.drain_taken } };

test "golden: cancel and drain PUT the requested state alone" {
    var h: Harness = undefined;
    try h.init(&.{ cancelled_reply, drained_reply });
    defer h.deinit();
    try h.client.cancelJob("us-central1", "2026-10-20_07_11_01-16829577348630633066");
    try h.expectWrite(0, job_url, cancel_body);
    try h.client.drainJob("us-central1", "2026-10-20_07_11_01-16829577348630633066");
    try h.expectWrite(1, job_url, drain_body);
    try h.expectRequestCount(2);
    try testing.expectEqualStrings("", h.diag.message());
}

test "each preview is byte for byte what its write sends, and sends nothing" {
    const Write = *const fn (*Client, []const u8, []const u8) Error!void;
    const Preview = *const fn (*Client, []const u8, []const u8) Error!types.Owned(PreparedRequest);
    const pairs = [_]struct { Write, Preview, test_util.FakeTransport.Reply }{
        .{ cancelJob, cancelJobRequest, cancelled_reply },
        .{ drainJob, drainJobRequest, drained_reply },
    };
    // An id that needs percent-encoding.
    for (pairs) |pair| {
        var h: Harness = undefined;
        try h.init(&.{pair[2]});
        defer h.deinit();
        var prepared = try pair[1](&h.client, "europe-west1", "job#1");
        defer prepared.deinit();
        try h.expectRequestCount(0);
        try pair[0](&h.client, "europe-west1", "job#1");
        const sent = try h.fake.request(0);
        try testing.expectEqual(sent.method, prepared.value.method);
        try testing.expectEqualStrings(sent.url, prepared.value.url);
        try testing.expectEqualStrings(sent.body.?, prepared.value.body);
        try testing.expect(std.mem.endsWith(u8, prepared.value.url, "/locations/europe-west1/jobs/job%231"));
    }
}

test "the writes and their previews refuse what they will not send, with the same words" {
    var h: Harness = undefined;
    try h.init(&.{});
    defer h.deinit();
    const c = &h.client;
    const cases = [_]struct { []const u8, []const u8, []const u8 }{
        .{ "US-central1", "j", "invalid location: expected a region id such as us-central1" },
        .{ "", "j", "invalid location: expected a region id such as us-central1" },
        .{ "us-central1", "a/b", "invalid job id: visible ASCII without /, at most 1024" },
        .{ "us-central1", "", "invalid job id: visible ASCII without /, at most 1024" },
    };
    for (cases) |case| {
        try testing.expectError(error.InvalidName, c.cancelJob(case[0], case[1]));
        try testing.expectEqualStrings(case[2], h.diag.message());
        try testing.expectError(error.InvalidName, c.cancelJobRequest(case[0], case[1]));
        try testing.expectEqualStrings(case[2], h.diag.message());
        try testing.expectError(error.InvalidName, c.drainJob(case[0], case[1]));
        try testing.expectEqualStrings(case[2], h.diag.message());
        try testing.expectError(error.InvalidName, c.drainJobRequest(case[0], case[1]));
        try testing.expectEqualStrings(case[2], h.diag.message());
    }
    try h.expectRequestCount(0);
}

test "a cancel's and a drain's refusals arrive as errors, production's words kept, sent once" {
    var h: Harness = undefined;
    try h.init(&.{
        .{ .respond = .{ .status = production.cancel_not_ready_status, .body = production.cancel_not_ready } },
        .{ .respond = .{ .status = production.drain_batch_status, .body = production.drain_batch } },
        .{ .respond = .{ .status = production.cancel_ended_status, .body = production.cancel_ended } },
        .{ .respond = .{ .status = production.cancel_unknown_status, .body = production.cancel_unknown } },
    });
    defer h.deinit();
    const id = "2026-10-20_15_14_29-4138990520061636327";
    try testing.expectError(error.FailedPrecondition, h.client.cancelJob("us-central1", id));
    try testing.expect(std.mem.endsWith(u8, h.diag.message(), "Job is not yet ready for canceling. Please retry in a few minutes."));
    try testing.expectError(error.InvalidArgument, h.client.drainJob("us-central1", id));
    try testing.expect(std.mem.endsWith(u8, h.diag.message(), "Only streaming workflows can be drained."));
    try testing.expectError(error.FailedPrecondition, h.client.cancelJob("us-central1", id));
    try testing.expect(std.mem.indexOf(u8, h.diag.message(), "Job has terminated in state SUCCESS") != null);
    try testing.expectError(error.NotFound, h.client.cancelJob("us-east1", id));
    try testing.expect(std.mem.indexOf(u8, h.diag.message(), "or the job does not exist in the project.") != null);
    try h.expectRequestCount(4);
    try testing.expectEqual(0, h.clock.sleep_count);
}

test "each write and each preview starts with Diagnostics clear" {
    const refused: test_util.FakeTransport.Reply = .{ .respond = .{ .status = production.cancel_ended_status, .body = production.cancel_ended } };
    var h: Harness = undefined;
    try h.init(&.{ refused, refused, cancelled_reply, refused, drained_reply });
    defer h.deinit();
    const id = "2026-10-20_15_12_39-16726637407140010736";
    try testing.expectError(error.FailedPrecondition, h.client.cancelJob("us-central1", id));
    var cancel = try h.client.cancelJobRequest("us-central1", id);
    cancel.deinit();
    try testing.expectEqualStrings("", h.diag.message());
    try testing.expectError(error.FailedPrecondition, h.client.cancelJob("us-central1", id));
    var drain = try h.client.drainJobRequest("us-central1", id);
    drain.deinit();
    try testing.expectEqualStrings("", h.diag.message());
    try h.client.cancelJob("us-central1", id);
    try testing.expectEqualStrings("", h.diag.message());
    try testing.expectError(error.FailedPrecondition, h.client.drainJob("us-central1", id));
    try h.client.drainJob("us-central1", id);
    try testing.expectEqualStrings("", h.diag.message());
}

test "a write that fails before sending does not keep the last call's words" {
    const refused: test_util.FakeTransport.Reply = .{ .respond = .{ .status = production.cancel_ended_status, .body = production.cancel_ended } };
    var failing: std.testing.FailingAllocator = .init(testing.allocator, .{});
    var fake: test_util.FakeTransport = .init(testing.allocator, &.{ refused, refused });
    defer fake.deinit();
    var tokens: test_util.FakeTokenProvider = .{};
    var clock: test_util.FakeClock = .{};
    var diag: core.Diagnostics = .{};
    var client = try Client.init(failing.allocator(), clock.io(), .{
        .project_id = "my-project",
        .token_provider = tokens.provider(),
        .transport = fake.transport(),
        .diagnostics = &diag,
    });
    defer client.deinit();
    const Write = *const fn (*Client, []const u8, []const u8) Error!void;
    for ([_]Write{ cancelJob, drainJob }) |write| {
        failing.fail_index = std.math.maxInt(usize);
        try testing.expectError(error.FailedPrecondition, write(&client, "us-central1", "j"));
        try testing.expect(diag.message().len > 0);
        failing.fail_index = failing.alloc_index;
        try testing.expectError(error.OutOfMemory, write(&client, "us-central1", "j"));
        try testing.expectEqualStrings("", diag.message());
    }
}

test "cancel and drain: retried as the reads are, a repeat answering as the first" {
    var h: Harness = undefined;
    try h.init(&.{
        .{ .fail = error.ConnectionResetByPeer },
        .{ .respond = .{ .status = 503, .body = "{\"error\":{\"code\":503,\"message\":\"The service is currently unavailable.\",\"status\":\"UNAVAILABLE\"}}" } },
        cancelled_reply,
        .{ .fail = error.TimedOut },
        drained_reply,
    });
    defer h.deinit();
    try h.client.cancelJob("us-central1", "2026-10-20_07_11_01-16829577348630633066");
    for (0..3) |i| try h.expectWrite(i, job_url, cancel_body);
    try h.client.drainJob("us-central1", "2026-10-20_07_11_01-16829577348630633066");
    for (3..5) |i| try h.expectWrite(i, job_url, drain_body);
    try h.expectRequestCount(5);
    try testing.expectEqual(3, h.clock.sleep_count);
    try testing.expectEqualStrings("", h.diag.message());
}

test "a stop answered with something other than an object is InvalidResponse" {
    var h: Harness = undefined;
    try h.init(&.{
        .{ .respond = .{ .body = "[]" } },
        .{ .respond = .{ .body = "<html>ok</html>" } },
    });
    defer h.deinit();
    try testing.expectError(error.InvalidResponse, h.client.cancelJob("us-central1", "j"));
    try testing.expectEqualStrings("the cancel response could not be decoded", h.diag.message());
    try testing.expectError(error.InvalidResponse, h.client.drainJob("us-central1", "j"));
    try testing.expectEqualStrings("the drain response could not be decoded", h.diag.message());
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
                .{ .respond = .{ .body = production.jobs_aggregated } },
                .{ .respond = .{ .body = production.jobs_list } },
                .{ .respond = .{ .body = production.job_done } },
                .{ .respond = .{ .body = production.job_failed } },
                .{ .respond = .{ .body = production.messages_error_failed } },
                .{ .respond = .{ .body = production.cancel_taken } },
                .{ .respond = .{ .body = production.drain_taken } },
            });
            defer fake.deinit();
            var tokens: test_util.FakeTokenProvider = .{};
            var clock: test_util.FakeClock = .{};
            var client = try Client.init(gpa, clock.io(), .{ .project_id = "my-project", .token_provider = tokens.provider(), .transport = fake.transport() });
            defer client.deinit();
            var everywhere = try client.aggregatedJobs(.{ .filter = .active });
            everywhere.deinit();
            var listed = try client.listJobs("us-central1", .{ .name = "zigps-df-05461", .page_token = "t" });
            listed.deinit();
            var done = try client.getJob("us-central1", "2026-10-20_07_11_01-16829577348630633066");
            done.deinit();
            var failed = try client.getJobView("us-central1", "2026-10-20_07_09_34-8524524531325271694", .description);
            failed.deinit();
            var story = try client.listMessages("us-central1", "2026-10-20_07_09_34-8524524531325271694", .{ .minimum_importance = .@"error" });
            story.deinit();
            try client.cancelJob("us-central1", "2026-10-20_07_09_34-8524524531325271694");
            try client.drainJob("us-central1", "2026-10-20_07_09_34-8524524531325271694");
            var preview = try client.drainJobRequest("us-central1", "2026-10-20_07_09_34-8524524531325271694");
            preview.deinit();
        }
    };
    try testing.checkAllAllocationFailures(test_util.no_grow_allocator, Run.calls, .{});
}
