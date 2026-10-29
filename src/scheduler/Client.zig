//! A Cloud Scheduler client: the locations a project's jobs live under,
//! the jobs with their schedules, targets and last attempts, and three
//! writes a console confirms: run a job now, pause it, resume it. Each
//! write has a twin that builds its exact request without sending it.
//! Nothing here creates, updates or deletes a job.
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

pub const default_endpoint = "https://cloudscheduler.googleapis.com";

pub const Options = struct {
    /// Required: the project whose jobs are read, an id or a number.
    project_id: []const u8,
    /// Required. Cloud Scheduler has no emulator, so there is no
    /// unauthenticated mode.
    token_provider: TokenProvider,
    /// Overrides the host: a test server, say. Must be `https`, since it
    /// receives credentials.
    endpoint: ?[]const u8 = null,
    /// Sends the credentials' quota project as `x-goog-user-project`, as
    /// every module does.
    send_quota_project: bool = true,
    /// The reads, a pause and a resume are retried on 5xx, 429 and
    /// dropped connections; a run is resent only when it never left (see
    /// `runJob`).
    retry: RetryPolicy = .{},
    /// How long one request may take before it is `error.TimedOut`, which
    /// is retried. 0 removes the limit.
    request_timeout_ms: u32 = 30_000,
    /// A response whose decompressed body is larger fails with
    /// `error.ResponseTooLarge`. Used by the built-in transport; a
    /// transport passed in keeps its own limit.
    max_response_bytes: usize = core.transport.default_max_response_bytes,
    /// Printable ASCII.
    user_agent: []const u8 = "gcp-zig-scheduler/0.61",
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

/// One page of the locations the project's jobs can live under. Jobs are
/// listed per location, so a reader starts here.
pub fn listLocations(self: *Client, options: types.ListLocationsOptions) Error!types.Owned(types.LocationPage) {
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

/// One page of a location's jobs. The server's default page is its
/// maximum, 500; more than 500 is refused before sending, as the server
/// refuses it ("ListJobsRequest.pageSize must be less than or equal to
/// 500"). Fewer jobs than requested can come back even when more exist:
/// walk `next_page_token`, which production says is valid for 2 hours.
pub fn listJobs(self: *Client, location: []const u8, options: types.ListJobsOptions) Error!types.Owned(types.JobPage) {
    rpc.begin(self);
    if (!validate.isLocation(location)) {
        if (self.diagnostics) |d| d.print("invalid location: expected a region id such as us-central1", .{});
        return error.InvalidName;
    }
    if (options.page_size > validate.max_page_size) {
        if (self.diagnostics) |d| d.print("invalid page_size: the server refuses more than {d}", .{validate.max_page_size});
        return error.InvalidOptions;
    }
    try self.checkToken(options.page_token);
    var scratch: std.heap.ArenaAllocator = .init(self.gpa);
    defer scratch.deinit();
    const a = scratch.allocator();
    var w: std.Io.Writer.Allocating = .init(a);
    w.writer.writeAll(names.jobs(a, self.project, location) catch return error.OutOfMemory) catch return error.OutOfMemory;
    var params: core.query.Params = .init(&w.writer);
    params.addNonZero("pageSize", options.page_size) catch return error.OutOfMemory;
    params.addOptional("pageToken", options.page_token) catch return error.OutOfMemory;

    var result: types.Owned(types.JobPage) = try .init(self.gpa);
    errdefer result.deinit();
    const body = try rpc.execute(self, result.arena, .{ .method = .GET, .path = w.written() });
    result.value = codec.decodeJobPage(result.arena.allocator(), a, body) catch |err|
        return rpc.decodeFailed(self, err, "job list");
    return result;
}

/// One job, by its location and id.
pub fn getJob(self: *Client, location: []const u8, id: []const u8) Error!types.Owned(types.Job) {
    rpc.begin(self);
    return self.getJobChecked(location, id);
}

/// One job, by its full `projects/P/locations/L/jobs/J` name. Another
/// project's name is refused before sending.
pub fn getJobNamed(self: *Client, name: []const u8) Error!types.Owned(types.Job) {
    rpc.begin(self);
    const parsed = names.jobName(name, self.project) orelse {
        if (self.diagnostics) |d| d.print("invalid job name: expected projects/{s}/locations/<location>/jobs/<id>", .{self.project});
        return error.InvalidName;
    };
    return self.getJobChecked(parsed.location, parsed.id);
}

fn getJobChecked(self: *Client, location: []const u8, id: []const u8) Error!types.Owned(types.Job) {
    try self.checkJob(location, id);
    var scratch: std.heap.ArenaAllocator = .init(self.gpa);
    defer scratch.deinit();
    const a = scratch.allocator();
    return self.jobCall(a, .{ .method = .GET, .path = try names.job(a, self.project, location, id) });
}

/// Dispatches the job now, even if it is already running (production's
/// words), and answers the job as it stood: the run's attempt shows in
/// `last_attempt` and `last_attempt_time` seconds later, when Scheduler
/// has dispatched it (the guide's "What a run comes to" has the measured
/// times). A paused job keeps its state.
///
/// Every run that lands dispatches the job once more, so a run that may
/// have reached the server is never sent again: only a refused connection
/// or a failed name lookup is retried. Any other failure is returned, and
/// whether the job ran is for a read of the job, or the target's own
/// logs, to say. Google's own clients retry a run not at all.
pub fn runJob(self: *Client, location: []const u8, id: []const u8) Error!types.Owned(types.Job) {
    rpc.begin(self);
    var scratch: std.heap.ArenaAllocator = .init(self.gpa);
    defer scratch.deinit();
    const a = scratch.allocator();
    var call = try self.actionCall(a, .run, location, id);
    call.retryable = core.rpc.unsentOnly;
    return self.jobCall(a, call);
}

/// Stops the job's schedule until `resumeJob`. Production also takes away
/// its next run (`schedule_time`) and its last attempt, which a list or a
/// get then answers as never attempted. Pausing a paused job changes
/// nothing and is no refusal (measured, though Google's reference says a
/// job must be enabled), so a pause is retried as the reads are.
///
/// A run sent just before a pause can still start after it: the paused
/// job then shows that attempt's `last_attempt_time` and a
/// `schedule_time` of the same moment, with no result.
pub fn pauseJob(self: *Client, location: []const u8, id: []const u8) Error!types.Owned(types.Job) {
    return self.stateCall(.pause, location, id);
}

/// Re-enables a paused job: its schedule runs again, and its next run
/// comes back at the next cron tick. The attempt a pause cleared stays
/// cleared. Resuming an enabled job changes nothing and is no refusal
/// (measured), so a resume is retried as the reads are.
///
/// One case reads wrong: a job paused while a run was starting (see
/// `pauseJob`) answers an empty status after the resume, which decodes
/// as a successful attempt though no result was recorded.
pub fn resumeJob(self: *Client, location: []const u8, id: []const u8) Error!types.Owned(types.Job) {
    return self.stateCall(.@"resume", location, id);
}

/// The request `runJob` sends for the same arguments, built without
/// sending it, after the same checks with the same errors: to show before
/// the call, or to record after it. Credentials and other headers are not
/// part of it.
pub fn runJobRequest(self: *Client, location: []const u8, id: []const u8) Error!types.Owned(PreparedRequest) {
    return self.prepare(.run, location, id);
}

/// The request `pauseJob` sends, as `runJobRequest` says. A pause whose
/// answer is lost is followed by a read of the job, which this does not
/// show: it is the request a user confirms.
pub fn pauseJobRequest(self: *Client, location: []const u8, id: []const u8) Error!types.Owned(PreparedRequest) {
    return self.prepare(.pause, location, id);
}

/// The request `resumeJob` sends, as `pauseJobRequest` says.
pub fn resumeJobRequest(self: *Client, location: []const u8, id: []const u8) Error!types.Owned(PreparedRequest) {
    return self.prepare(.@"resume", location, id);
}

/// The three writes, each named as its path names it (`:run`).
const Action = enum { run, pause, @"resume" };

fn prepare(self: *Client, action: Action, location: []const u8, id: []const u8) Error!types.Owned(PreparedRequest) {
    rpc.begin(self);
    var result: types.Owned(PreparedRequest) = try .init(self.gpa);
    errdefer result.deinit();
    const a = result.arena.allocator();
    result.value = try .fromCall(a, self.base_url, try self.actionCall(a, action, location, id));
    return result;
}

/// The call `action` sends, after the checks every job call makes. Its
/// body is `{}`: the request messages have no fields.
fn actionCall(self: *Client, arena: Allocator, action: Action, location: []const u8, id: []const u8) Error!rpc.Call {
    try self.checkJob(location, id);
    const path = try std.mem.concat(arena, u8, &.{ try names.job(arena, self.project, location, id), ":", @tagName(action) });
    return .{ .method = .POST, .path = path, .body = "{}" };
}

/// Sends a pause or a resume. Either one landing twice answers the job as
/// the first left it, so both are retried as the reads are.
fn stateCall(self: *Client, action: Action, location: []const u8, id: []const u8) Error!types.Owned(types.Job) {
    rpc.begin(self);
    var scratch: std.heap.ArenaAllocator = .init(self.gpa);
    defer scratch.deinit();
    const a = scratch.allocator();
    return self.jobCall(a, try self.actionCall(a, action, location, id));
}

/// Sends `call` and decodes the job it answers.
fn jobCall(self: *Client, scratch: Allocator, call: rpc.Call) Error!types.Owned(types.Job) {
    var result: types.Owned(types.Job) = try .init(self.gpa);
    errdefer result.deinit();
    const body = try rpc.execute(self, result.arena, call);
    result.value = codec.decodeJob(result.arena.allocator(), scratch, body) catch |err|
        return rpc.decodeFailed(self, err, "job");
    return result;
}

fn checkJob(self: *Client, location: []const u8, id: []const u8) Error!void {
    if (!validate.isLocation(location)) {
        if (self.diagnostics) |d| d.print("invalid location: expected a region id such as us-central1", .{});
        return error.InvalidName;
    }
    if (!validate.isJobId(id)) {
        if (self.diagnostics) |d| d.print("invalid job id: visible ASCII without /, at most 500", .{});
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

test "golden: locations and jobs listed, a job got by parts and by name" {
    var h: Harness = undefined;
    try h.init(&.{
        .{ .respond = .{ .body = production.locations_page } },
        .{ .respond = .{ .body = production.jobs_page } },
        .{ .respond = .{ .body = "{}" } },
        .{ .respond = .{ .body = production.job_failed_http } },
        .{ .respond = .{ .body = production.job_failed_pubsub } },
    });
    defer h.deinit();

    var locations = try h.client.listLocations(.{ .page_size = 2, .page_token = "t" });
    defer locations.deinit();
    try h.expectRequest(0, .GET, "https://cloudscheduler.googleapis.com/v1/projects/my-project/locations?pageSize=2&pageToken=t");
    try testing.expectEqual(2, locations.value.locations.len);
    try testing.expectEqualStrings("us-central1", locations.value.locations[0].id);
    try testing.expectEqualStrings("p2", locations.value.next_page_token.?);

    var jobs = try h.client.listJobs("us-central1", .{ .page_size = 500 });
    defer jobs.deinit();
    try h.expectRequest(1, .GET, "https://cloudscheduler.googleapis.com/v1/projects/my-project/locations/us-central1/jobs?pageSize=500");
    try testing.expectEqual(1, jobs.value.jobs.len);
    try testing.expectEqualStrings("zigps-d8a22f-ps", jobs.value.jobs[0].id);
    try testing.expect(jobs.value.next_page_token != null);

    var empty = try h.client.listJobs("us-east1", .{});
    defer empty.deinit();
    try h.expectRequest(2, .GET, "https://cloudscheduler.googleapis.com/v1/projects/my-project/locations/us-east1/jobs");
    try testing.expectEqual(0, empty.value.jobs.len);
    try testing.expectEqual(null, empty.value.next_page_token);

    var got = try h.client.getJob("us-central1", "zigps-399f5c-http");
    defer got.deinit();
    try h.expectRequest(3, .GET, "https://cloudscheduler.googleapis.com/v1/projects/my-project/locations/us-central1/jobs/zigps-399f5c-http");
    try testing.expect(got.value.failing());
    try testing.expectEqual(2, got.value.last_attempt.?.code);

    var by_name = try h.client.getJobNamed("projects/my-project/locations/us-central1/jobs/zigps-399f5c-ps");
    defer by_name.deinit();
    try h.expectRequest(4, .GET, "https://cloudscheduler.googleapis.com/v1/projects/my-project/locations/us-central1/jobs/zigps-399f5c-ps");
    try testing.expectEqualStrings("zigps", by_name.value.target.pubsub.data);
}

test "the calls refuse what they will not send" {
    var h: Harness = undefined;
    try h.init(&.{});
    defer h.deinit();
    const c = &h.client;
    try testing.expectError(error.InvalidName, c.listJobs("US-central1", .{}));
    try testing.expectError(error.InvalidName, c.listJobs("", .{}));
    try testing.expectError(error.InvalidOptions, c.listJobs("us-central1", .{ .page_size = 501 }));
    try testing.expectEqualStrings("invalid page_size: the server refuses more than 500", h.diag.message());
    try testing.expectError(error.InvalidName, c.listJobs("us-central1", .{ .page_token = "a b" }));
    try testing.expectError(error.InvalidName, c.listLocations(.{ .page_token = "" }));
    try testing.expectError(error.InvalidName, c.getJob("us-central1", "a/b"));
    try testing.expectError(error.InvalidName, c.getJob("us central1", "j"));
    try testing.expectError(error.InvalidName, c.getJobNamed("projects/other/locations/l/jobs/j"));
    try testing.expectError(error.InvalidName, c.getJobNamed("zigps-399f5c-http"));
    try testing.expectEqualStrings("invalid job name: expected projects/my-project/locations/<location>/jobs/<id>", h.diag.message());
    try h.expectRequestCount(0);
}

test "a response that cannot be decoded is InvalidResponse, named in Diagnostics" {
    var h: Harness = undefined;
    try h.init(&.{
        .{ .respond = .{ .body = "{\"jobs\":1}" } },
        .{ .respond = .{ .body = "{\"state\":\"ENABLED\"}" } },
        .{ .respond = .{ .body = "{\"locations\":[{\"locationId\":1}]}" } },
    });
    defer h.deinit();
    try testing.expectError(error.InvalidResponse, h.client.listJobs("us-central1", .{}));
    try testing.expectEqualStrings("the job list response could not be decoded", h.diag.message());
    try testing.expectError(error.InvalidResponse, h.client.getJob("us-central1", "j"));
    try testing.expectEqualStrings("the job response could not be decoded", h.diag.message());
    try testing.expectError(error.InvalidResponse, h.client.listLocations(.{}));
    try testing.expectEqualStrings("the location list response could not be decoded", h.diag.message());
}

test "the server's refusals arrive as errors, production's words kept" {
    var h: Harness = undefined;
    try h.init(&.{
        .{ .respond = .{ .status = production.job_unknown_status, .body = production.job_unknown } },
        .{ .respond = .{ .status = production.location_unknown_status, .body = production.location_unknown } },
    });
    defer h.deinit();
    try testing.expectError(error.NotFound, h.client.getJob("us-central1", "zigps-nobody"));
    try testing.expectEqualStrings("Job not found.", h.diag.message());
    try testing.expectError(error.InvalidArgument, h.client.listJobs("us-fake1", .{}));
    try testing.expect(std.mem.indexOf(u8, h.diag.message(), "not a valid location") != null);
}

const job_url = "https://cloudscheduler.googleapis.com/v1/projects/my-project/locations/us-central1/jobs/zigps-399f5c-http";

const unavailable: FakeTransport.Reply = .{ .respond = .{
    .status = 503,
    .body = "{\"error\":{\"code\":503,\"message\":\"The service is currently unavailable.\",\"status\":\"UNAVAILABLE\"}}",
} };
const FakeTransport = test_util.FakeTransport;
const ran: FakeTransport.Reply = .{ .respond = .{ .body = production.job_run_answer } };
const paused: FakeTransport.Reply = .{ .respond = .{ .body = production.job_pause_answer } };
const enabled: FakeTransport.Reply = .{ .respond = .{ .body = production.job_resume_answer } };

test "golden: run, pause and resume POST {} to the job's verb and answer the job" {
    var h: Harness = undefined;
    try h.init(&.{ ran, paused, enabled });
    defer h.deinit();
    var r = try h.client.runJob("us-central1", "zigps-399f5c-http");
    defer r.deinit();
    try h.expectWrite(0, job_url ++ ":run");
    try testing.expectEqual(.enabled, r.value.state);
    try testing.expectEqual(null, r.value.last_attempt);
    var p = try h.client.pauseJob("us-central1", "zigps-399f5c-http");
    defer p.deinit();
    try h.expectWrite(1, job_url ++ ":pause");
    try testing.expectEqual(.paused, p.value.state);
    try testing.expectEqual(null, p.value.schedule_time);
    var e = try h.client.resumeJob("us-central1", "zigps-399f5c-http");
    defer e.deinit();
    try h.expectWrite(2, job_url ++ ":resume");
    try testing.expectEqual(.enabled, e.value.state);
    try h.expectRequestCount(3);
    try testing.expectEqual(null, e.value.last_attempt);
    try testing.expect(e.value.schedule_time != null);
}

test "each preview is byte for byte what its write sends, and sends nothing" {
    const Write = *const fn (*Client, []const u8, []const u8) Error!types.Owned(types.Job);
    const Preview = *const fn (*Client, []const u8, []const u8) Error!types.Owned(PreparedRequest);
    const pairs = [_]struct { Write, Preview, FakeTransport.Reply }{
        .{ runJob, runJobRequest, ran },
        .{ pauseJob, pauseJobRequest, paused },
        .{ resumeJob, resumeJobRequest, enabled },
    };
    // An id that needs percent-encoding.
    for (pairs) |pair| {
        var h: Harness = undefined;
        try h.init(&.{pair[2]});
        defer h.deinit();
        var prepared = try pair[1](&h.client, "europe-west1", "report#1");
        defer prepared.deinit();
        try h.expectRequestCount(0);
        var answered = try pair[0](&h.client, "europe-west1", "report#1");
        defer answered.deinit();
        const sent = try h.fake.request(0);
        try testing.expectEqual(sent.method, prepared.value.method);
        try testing.expectEqualStrings(sent.url, prepared.value.url);
        try testing.expectEqualStrings(sent.body.?, prepared.value.body);
        try testing.expect(std.mem.indexOf(u8, prepared.value.url, "/locations/europe-west1/jobs/report%231:") != null);
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
        .{ "us-central1", "a/b", "invalid job id: visible ASCII without /, at most 500" },
        .{ "us-central1", "", "invalid job id: visible ASCII without /, at most 500" },
    };
    for (cases) |case| {
        try testing.expectError(error.InvalidName, c.runJob(case[0], case[1]));
        try testing.expectEqualStrings(case[2], h.diag.message());
        try testing.expectError(error.InvalidName, c.runJobRequest(case[0], case[1]));
        try testing.expectEqualStrings(case[2], h.diag.message());
        try testing.expectError(error.InvalidName, c.pauseJob(case[0], case[1]));
        try testing.expectError(error.InvalidName, c.pauseJobRequest(case[0], case[1]));
        try testing.expectError(error.InvalidName, c.resumeJob(case[0], case[1]));
        try testing.expectError(error.InvalidName, c.resumeJobRequest(case[0], case[1]));
    }
    try h.expectRequestCount(0);
}

test "run: never sent again once it may have left" {
    const after_send = [_]FakeTransport.Reply{
        .{ .fail = error.ConnectionResetByPeer },
        .{ .fail = error.TimedOut },
        .{ .fail = error.TlsFailure },
        .{ .fail = error.NetworkUnreachable },
        unavailable,
        .{ .respond = .{ .status = 429, .body = "{\"error\":{\"code\":429,\"message\":\"Quota exceeded.\",\"status\":\"RESOURCE_EXHAUSTED\"}}" } },
        .{ .respond = .{ .status = 500, .body = "{\"error\":{\"code\":500,\"message\":\"Internal error.\",\"status\":\"INTERNAL\"}}" } },
    };
    for (after_send) |reply| {
        var h: Harness = undefined;
        try h.init(&.{ reply, ran });
        defer h.deinit();
        if (h.client.runJob("us-central1", "zigps-399f5c-http")) |r| {
            var job = r;
            job.deinit();
            return error.TestUnexpectedResult;
        } else |_| {}
        try h.expectRequestCount(1);
        try testing.expectEqual(0, h.clock.sleep_count);
    }
}

test "run: resent after a refused connection or a failed lookup, which never left" {
    var h: Harness = undefined;
    try h.init(&.{ .{ .fail = error.ConnectionRefused }, .{ .fail = error.NameServerFailure }, ran });
    defer h.deinit();
    var r = try h.client.runJob("us-central1", "zigps-399f5c-http");
    defer r.deinit();
    try h.expectRequestCount(3);
    for (0..3) |i| try h.expectWrite(i, job_url ++ ":run");
}

test "run: a paused job is refused, production's words kept" {
    var h: Harness = undefined;
    try h.init(&.{.{ .respond = .{ .status = production.run_paused_status, .body = production.run_paused } }});
    defer h.deinit();
    try testing.expectError(error.FailedPrecondition, h.client.runJob("us-central1", "zigps-399f5c-http"));
    try testing.expectEqualStrings("spanner.RunInTransaction: generic::failed_precondition: Job.state must be ENABLED for RunJob.", h.diag.message());
    try h.expectRequestCount(1);
}

test "pause and resume: retried as the reads are, a repeat answering the job" {
    var h: Harness = undefined;
    try h.init(&.{ .{ .fail = error.ConnectionResetByPeer }, unavailable, paused, .{ .fail = error.TimedOut }, enabled });
    defer h.deinit();
    var p = try h.client.pauseJob("us-central1", "zigps-399f5c-http");
    defer p.deinit();
    try testing.expectEqual(.paused, p.value.state);
    for (0..3) |i| try h.expectWrite(i, job_url ++ ":pause");
    var e = try h.client.resumeJob("us-central1", "zigps-399f5c-http");
    defer e.deinit();
    try testing.expectEqual(.enabled, e.value.state);
    for (3..5) |i| try h.expectWrite(i, job_url ++ ":resume");
    try h.expectRequestCount(5);
    try testing.expectEqual(3, h.clock.sleep_count);
    try testing.expectEqualStrings("", h.diag.message());
}

test "pause and resume: a refusal is returned as it came, not retried" {
    var h: Harness = undefined;
    try h.init(&.{
        .{ .respond = .{ .status = production.job_unknown_status, .body = production.job_unknown } },
        .{ .respond = .{ .status = production.narrow_scope_status, .body = production.narrow_scope } },
        .{ .respond = .{ .status = production.location_unknown_status, .body = production.location_unknown } },
    });
    defer h.deinit();
    try testing.expectError(error.NotFound, h.client.pauseJob("us-central1", "zigps-nobody"));
    try testing.expectEqualStrings("Job not found.", h.diag.message());
    try testing.expectError(error.PermissionDenied, h.client.resumeJob("us-central1", "zigps-399f5c-http"));
    try testing.expectEqualStrings("Request had insufficient authentication scopes.", h.diag.message());
    try testing.expectError(error.InvalidArgument, h.client.runJob("us-fake1", "zigps-399f5c-http"));
    try h.expectRequestCount(3);
}

test "pause and resume: what production answers mid-run, decoded as it reads" {
    var h: Harness = undefined;
    try h.init(&.{
        .{ .respond = .{ .body = production.job_paused_mid_run } },
        .{ .respond = .{ .body = production.job_resumed_mid_run } },
    });
    defer h.deinit();
    // Paused while a run was starting: the attempt's start, no result.
    var p = try h.client.getJob("us-central1", "zigps-e03a4d-nf");
    defer p.deinit();
    try testing.expectEqual(.paused, p.value.state);
    try testing.expectEqual(null, p.value.last_attempt);
    try testing.expect(p.value.last_attempt_time != null);
    try testing.expect(p.value.schedule_time != null);
    // Resumed: an empty status, which reads as success.
    var e = try h.client.resumeJob("us-central1", "zigps-e03a4d-nf");
    defer e.deinit();
    try testing.expectEqual(0, e.value.last_attempt.?.code);
    try testing.expect(!e.value.failing());
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
                .{ .respond = .{ .body = production.locations_page } },
                .{ .respond = .{ .body = production.jobs_page } },
                .{ .respond = .{ .body = production.job_failed_http } },
                .{ .respond = .{ .body = production.job_failed_pubsub } },
                .{ .respond = .{ .body = production.job_run_answer } },
                .{ .respond = .{ .body = production.job_pause_answer } },
                .{ .respond = .{ .body = production.job_resume_answer } },
            });
            defer fake.deinit();
            var tokens: test_util.FakeTokenProvider = .{};
            var clock: test_util.FakeClock = .{};
            var client = try Client.init(gpa, clock.io(), .{ .project_id = "my-project", .token_provider = tokens.provider(), .transport = fake.transport() });
            defer client.deinit();
            var locations = try client.listLocations(.{ .page_size = 2 });
            locations.deinit();
            var jobs = try client.listJobs("us-central1", .{ .page_token = "t" });
            jobs.deinit();
            var got = try client.getJob("us-central1", "zigps-399f5c-http");
            got.deinit();
            var by_name = try client.getJobNamed("projects/my-project/locations/us-central1/jobs/zigps-399f5c-ps");
            by_name.deinit();
            var r = try client.runJob("us-central1", "zigps-399f5c-http");
            r.deinit();
            var p = try client.pauseJob("us-central1", "zigps-399f5c-http");
            p.deinit();
            var e = try client.resumeJob("us-central1", "zigps-399f5c-http");
            e.deinit();
            for ([_]Action{ .run, .pause, .@"resume" }) |action| {
                var prepared = try client.prepare(action, "us-central1", "zigps-399f5c-http");
                prepared.deinit();
            }
        }
    };
    try testing.checkAllAllocationFailures(test_util.no_grow_allocator, Run.calls, .{});
}
