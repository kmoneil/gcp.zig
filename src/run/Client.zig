//! A Cloud Run client: the locations services live in, the services with
//! their traffic and conditions, the revisions with their create times and
//! readiness, the jobs with their executions; and three writes a console
//! confirms before sending, each with a twin that builds its exact request
//! without sending it: run a job, cancel an execution, send all of a
//! service's traffic to one revision. Nothing here deploys, creates or
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
const logging = @import("logging.zig");
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

pub const default_endpoint = "https://run.googleapis.com";

pub const Options = struct {
    /// Required: the project whose services are read, an id or a number.
    project_id: []const u8,
    /// Required. Cloud Run has no emulator, so there is no
    /// unauthenticated mode.
    token_provider: TokenProvider,
    /// The OAuth scope asked of the token provider for every call. The
    /// default, `run.readonly`, takes every read. A provider made from a
    /// key file, workload identity or impersonation is fixed to the scope
    /// its first token was minted for (`auth.Credentials.bindsScopes`),
    /// so a client asks for one scope only.
    scope: rpc.Scope = .read_only,
    /// Overrides the host: a test server, say. Must be `https`, since it
    /// receives credentials.
    endpoint: ?[]const u8 = null,
    /// Sends the credentials' quota project as `x-goog-user-project`, as
    /// every module does.
    send_quota_project: bool = true,
    /// The reads, and the writes that set a state, retry 5xx, 429 and
    /// dropped connections; a run is sent again only when it cannot have
    /// reached the server. Each write's doc says how.
    retry: RetryPolicy = .{},
    /// How long one request may take before it is `error.TimedOut`, which
    /// is retried. 0 removes the limit.
    request_timeout_ms: u32 = 30_000,
    /// A response whose decompressed body is larger fails with
    /// `error.ResponseTooLarge`. Used by the built-in transport; a
    /// transport passed in keeps its own limit.
    max_response_bytes: usize = core.transport.default_max_response_bytes,
    /// Printable ASCII.
    user_agent: []const u8 = "zig-gcp-run/0.55",
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

/// One page of a region's jobs, newest first. Production refuses `-` for
/// jobs (measured 2026-10-21, though it takes it for services), so it is
/// refused here before sending: ask each region `listLocations` names.
pub fn listJobs(self: *Client, location: []const u8, options: types.ListOptions) Error!types.Owned(types.JobPage) {
    rpc.begin(self);
    try self.checkRegion(location);
    try self.checkToken(options.page_token);
    var scratch: std.heap.ArenaAllocator = .init(self.gpa);
    defer scratch.deinit();
    const a = scratch.allocator();
    var w: std.Io.Writer.Allocating = .init(a);
    w.writer.writeAll(try names.jobs(a, self.project, location)) catch return error.OutOfMemory;
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
    try self.checkRegion(location);
    try self.checkId(id, "job");
    var scratch: std.heap.ArenaAllocator = .init(self.gpa);
    defer scratch.deinit();
    const a = scratch.allocator();
    const path = try names.job(a, self.project, location, id);
    var result: types.Owned(types.Job) = try .init(self.gpa);
    errdefer result.deinit();
    const body = try rpc.execute(self, result.arena, .{ .method = .GET, .path = path });
    result.value = codec.decodeJob(result.arena.allocator(), a, body) catch |err|
        return rpc.decodeFailed(self, err, "job");
    return result;
}

/// One page of a job's executions, newest first. The job may be `-`,
/// every job in the region at once, which Cloud Run documents and
/// production answered; a job nobody has answers an empty page, not a
/// refusal (measured).
pub fn listExecutions(self: *Client, location: []const u8, job_id: []const u8, options: types.ListOptions) Error!types.Owned(types.ExecutionPage) {
    rpc.begin(self);
    try self.checkRegion(location);
    if (!std.mem.eql(u8, job_id, "-")) try self.checkId(job_id, "job");
    try self.checkToken(options.page_token);
    var scratch: std.heap.ArenaAllocator = .init(self.gpa);
    defer scratch.deinit();
    const a = scratch.allocator();
    var w: std.Io.Writer.Allocating = .init(a);
    w.writer.writeAll(try names.executions(a, self.project, location, job_id)) catch return error.OutOfMemory;
    var params: core.query.Params = .init(&w.writer);
    params.addNonZero("pageSize", options.page_size) catch return error.OutOfMemory;
    params.addOptional("pageToken", options.page_token) catch return error.OutOfMemory;

    var result: types.Owned(types.ExecutionPage) = try .init(self.gpa);
    errdefer result.deinit();
    const body = try rpc.execute(self, result.arena, .{ .method = .GET, .path = w.written() });
    result.value = codec.decodeExecutionPage(result.arena.allocator(), a, body) catch |err|
        return rpc.decodeFailed(self, err, "execution list");
    return result;
}

/// One execution, by its location, job and id.
pub fn getExecution(self: *Client, location: []const u8, job_id: []const u8, id: []const u8) Error!types.Owned(types.Execution) {
    rpc.begin(self);
    return self.getExecutionChecked(location, job_id, id);
}

/// One execution, by its full name, as a run's operation names it.
/// Another project's name is refused before sending.
pub fn getExecutionNamed(self: *Client, name: []const u8) Error!types.Owned(types.Execution) {
    rpc.begin(self);
    const parsed = names.executionName(name, self.project) orelse {
        if (self.diagnostics) |d| d.print("invalid execution name: expected projects/{s}/locations/<location>/jobs/<job>/executions/<id>", .{self.project});
        return error.InvalidName;
    };
    return self.getExecutionChecked(parsed.location, parsed.job, parsed.id);
}

fn getExecutionChecked(self: *Client, location: []const u8, job_id: []const u8, id: []const u8) Error!types.Owned(types.Execution) {
    try self.checkRegion(location);
    try self.checkId(job_id, "job");
    try self.checkId(id, "execution");
    var scratch: std.heap.ArenaAllocator = .init(self.gpa);
    defer scratch.deinit();
    const a = scratch.allocator();
    const path = try names.execution(a, self.project, location, job_id, id);
    var result: types.Owned(types.Execution) = try .init(self.gpa);
    errdefer result.deinit();
    const body = try rpc.execute(self, result.arena, .{ .method = .GET, .path = path });
    result.value = codec.decodeExecution(result.arena.allocator(), a, body) catch |err|
        return rpc.decodeFailed(self, err, "execution");
    return result;
}

/// An operation a write answered, read again by its full name
/// (`projects/P/locations/L/operations/U`): `done`, with a `failure` or
/// its final `subject`, once it has ended. A run's operation ends only
/// with its execution, about 100 s for a small job (measured), so a
/// reader follows the execution the first answer names rather than wait
/// on the operation. Another project's name is refused before sending.
pub fn getOperation(self: *Client, name: []const u8) Error!types.Owned(types.Operation) {
    rpc.begin(self);
    const parsed = names.operationName(name, self.project) orelse {
        if (self.diagnostics) |d| d.print("invalid operation name: expected projects/{s}/locations/<location>/operations/<id>", .{self.project});
        return error.InvalidName;
    };
    try self.checkRegion(parsed.location);
    try self.checkId(parsed.id, "operation");
    var scratch: std.heap.ArenaAllocator = .init(self.gpa);
    defer scratch.deinit();
    const a = scratch.allocator();
    const path = try names.operation(a, self.project, parsed.location, parsed.id);
    var result: types.Owned(types.Operation) = try .init(self.gpa);
    errdefer result.deinit();
    const body = try rpc.execute(self, result.arena, .{ .method = .GET, .path = path });
    result.value = codec.decodeOperation(result.arena.allocator(), a, body) catch |err|
        return rpc.decodeFailed(self, err, "operation");
    return result;
}

/// Starts a new execution of the job, as it is configured (no overrides).
/// Answers its operation at once, not done: the operation's subject is the
/// new execution, by its full name, to read with `getExecutionNamed`. The
/// operation is done only when the execution ends, which took 100 s for a
/// job that sleeps 2 s (a 90 s start, measured 2026-10-21), so follow the
/// execution rather than the operation. Two executions of one job may run
/// at once. Takes `run.jobs.run`, and a client whose scope is not
/// `.read_only`.
///
/// Every run that lands makes an execution, so a run that may have
/// reached the server is never sent again: only a refused connection or a
/// failed name lookup is retried. Any other failure is returned; list the
/// job's executions, newest first, to see whether it ran.
pub fn runJob(self: *Client, location: []const u8, id: []const u8) Error!types.Owned(types.Operation) {
    rpc.begin(self);
    var scratch: std.heap.ArenaAllocator = .init(self.gpa);
    defer scratch.deinit();
    const a = scratch.allocator();
    var call = try self.runJobCall(a, location, id);
    call.retryable = core.rpc.unsentOnly;
    return self.operationCall(a, call);
}

/// Asks the execution to stop. Answers its operation at once, not done.
/// The execution read running for about 10 s more, then counted a task
/// cancelled, and ended `.cancelled` 16 s after the cancel (measured); one
/// cancelled before it started ended at once. Takes
/// `run.executions.cancel`, which Cloud Run Invoker lacks, and a client
/// whose scope is not `.read_only`.
///
/// A cancel that lands twice is taken twice while the execution is still
/// stopping, so it is retried as the reads are. A resend that arrives
/// after the execution ended is refused, `error.FailedPrecondition`
/// ("cannot be cancelled because it is not running"); after an attempt
/// that may have reached the server, the execution is then read, and
/// cancelled or cancelling means an earlier attempt landed: the answer is
/// an operation with an empty name, done, the execution read as its
/// subject. A first attempt's refusal is returned as it is.
pub fn cancelExecution(self: *Client, location: []const u8, job_id: []const u8, id: []const u8) Error!types.Owned(types.Operation) {
    rpc.begin(self);
    var scratch: std.heap.ArenaAllocator = .init(self.gpa);
    defer scratch.deinit();
    const a = scratch.allocator();
    var call = try self.cancelCall(a, location, job_id, id);
    call.retry = false;
    var attempt: u32 = 0;
    var sent_before = false;
    while (true) {
        attempt += 1;
        if (self.operationCall(a, call)) |operation| {
            return operation;
        } else |err| {
            if (sent_before and err == error.FailedPrecondition) return self.cancelLanded(location, job_id, id, err);
            if (!core.isRetryable(err) or attempt >= self.retry.max_attempts) return err;
            const delay_ms = rpc.waitMs(self, attempt) orelse return err;
            logging.warn("cancelling an execution failed with {t}; trying again in {d} ms", .{ err, delay_ms });
            try self.io.sleep(.fromMilliseconds(delay_ms), .awake);
            if (!core.rpc.unsentOnly(err, 0)) sent_before = true;
        }
    }
}

/// After a resend refused because the execution was no longer running:
/// reads it, and answers for an earlier attempt that landed, or returns
/// `refused`.
fn cancelLanded(self: *Client, location: []const u8, job_id: []const u8, id: []const u8, refused: Error) Error!types.Owned(types.Operation) {
    var read = self.getExecutionChecked(location, job_id, id) catch |err| switch (err) {
        error.OutOfMemory, error.Canceled => return err,
        else => {
            if (self.diagnostics) |d| d.print("cancelling the execution was refused with {t} after an attempt that may have landed, and reading it to see failed with {t}", .{ refused, err });
            return refused;
        },
    };
    switch (read.value.status()) {
        .cancelled, .cancelling => {},
        else => {
            read.deinit();
            if (self.diagnostics) |d| d.print("cancelling the execution was refused with {t}: it is no longer running, and not cancelled", .{refused});
            return refused;
        },
    }
    // The read's success has cleared the refusal from `Diagnostics`.
    logging.debug("a cancel resent after a lost answer was refused, and the execution reads cancelled: an earlier attempt landed", .{});
    return .{
        .arena = read.arena,
        .value = .{ .name = "", .done = true, .subject = .{ .execution = read.value } },
    };
}

/// Sends all of the service's traffic to one revision, by its id as
/// `Revision.id` holds it: `traffic` becomes that one target at 100 %, and
/// nothing else of the service changes (no new revision, measured). The
/// change is sent with `options.etag` and an update mask naming it, so a
/// service changed since that read is refused with `error.Aborted`
/// ("Conflict for resource '<s>': version '<a>' was specified but current
/// version is '<b>'.") rather than overwritten: production enforces the
/// etag only when the mask names it (measured). Answers its operation,
/// done 4 s later when measured, its subject the service.
///
/// Production takes a change to a revision the service does not have, or
/// one whose `Ready` failed, and the operation then fails (code 9 or the
/// revision's own error) while the service keeps the asked traffic and
/// its terminal condition goes failed; `validate_only` does not catch
/// either. Offer only revisions whose `ready()` is true. Takes
/// `run.services.update`, and a client whose scope is not `.read_only`.
///
/// Retried as the reads are: a resend of a change that landed is no
/// refusal, production taking a change to the traffic the service already
/// has as one that changes nothing (measured).
pub fn routeAllTraffic(self: *Client, location: []const u8, service_id: []const u8, revision: []const u8, options: types.RouteOptions) Error!types.Owned(types.Operation) {
    rpc.begin(self);
    var scratch: std.heap.ArenaAllocator = .init(self.gpa);
    defer scratch.deinit();
    const a = scratch.allocator();
    return self.operationCall(a, try self.routeCall(a, location, service_id, revision, options));
}

/// The request `runJob` sends for the same arguments, built without
/// sending it, after the same checks with the same errors: to show before
/// the call, or to record after it. Credentials and other headers are not
/// part of it.
pub fn runJobRequest(self: *Client, location: []const u8, id: []const u8) Error!types.Owned(PreparedRequest) {
    rpc.begin(self);
    var result: types.Owned(PreparedRequest) = try .init(self.gpa);
    errdefer result.deinit();
    const a = result.arena.allocator();
    result.value = try .fromCall(a, self.base_url, try self.runJobCall(a, location, id));
    return result;
}

/// The request `cancelExecution` sends, as `runJobRequest` says. A cancel
/// whose answer is lost may be followed by a read of the execution, which
/// this does not show: it is the request a user confirms.
pub fn cancelExecutionRequest(self: *Client, location: []const u8, job_id: []const u8, id: []const u8) Error!types.Owned(PreparedRequest) {
    rpc.begin(self);
    var result: types.Owned(PreparedRequest) = try .init(self.gpa);
    errdefer result.deinit();
    const a = result.arena.allocator();
    result.value = try .fromCall(a, self.base_url, try self.cancelCall(a, location, job_id, id));
    return result;
}

/// The request `routeAllTraffic` sends, as `runJobRequest` says.
pub fn routeAllTrafficRequest(self: *Client, location: []const u8, service_id: []const u8, revision: []const u8, options: types.RouteOptions) Error!types.Owned(PreparedRequest) {
    rpc.begin(self);
    var result: types.Owned(PreparedRequest) = try .init(self.gpa);
    errdefer result.deinit();
    const a = result.arena.allocator();
    result.value = try .fromCall(a, self.base_url, try self.routeCall(a, location, service_id, revision, options));
    return result;
}

/// The call `runJob` sends: `POST .../jobs/J:run` with `{}`, no overrides.
fn runJobCall(self: *Client, arena: Allocator, location: []const u8, id: []const u8) Error!rpc.Call {
    try self.checkWrite();
    try self.checkRegion(location);
    try self.checkId(id, "job");
    const path = try std.mem.concat(arena, u8, &.{ try names.job(arena, self.project, location, id), ":run" });
    return .{ .method = .POST, .path = path, .body = "{}" };
}

/// The call `cancelExecution` sends: `POST .../executions/E:cancel` with
/// `{}`.
fn cancelCall(self: *Client, arena: Allocator, location: []const u8, job_id: []const u8, id: []const u8) Error!rpc.Call {
    try self.checkWrite();
    try self.checkRegion(location);
    try self.checkId(job_id, "job");
    try self.checkId(id, "execution");
    const path = try std.mem.concat(arena, u8, &.{ try names.execution(arena, self.project, location, job_id, id), ":cancel" });
    return .{ .method = .POST, .path = path, .body = "{}" };
}

/// The call `routeAllTraffic` sends: a `PATCH` of the service with
/// `updateMask=traffic,etag` (written as production was measured with it)
/// and a body of the one target and the etag, nothing else: a `PATCH`
/// without a mask replaces the whole service.
fn routeCall(self: *Client, arena: Allocator, location: []const u8, service_id: []const u8, revision: []const u8, options: types.RouteOptions) Error!rpc.Call {
    try self.checkWrite();
    try self.checkRegion(location);
    try self.checkId(service_id, "service");
    try self.checkId(revision, "revision");
    if (!validate.isEtag(options.etag)) {
        if (self.diagnostics) |d| d.print("invalid etag: expected Service.etag as read, printable ASCII; production takes a change without one unguarded", .{});
        return error.InvalidOptions;
    }
    const service_path = try names.service(arena, self.project, location, service_id);
    const query = if (options.validate_only) "?updateMask=traffic,etag&validateOnly=true" else "?updateMask=traffic,etag";
    const body = std.json.Stringify.valueAlloc(arena, .{
        .traffic = [_]struct { type: []const u8, revision: []const u8, percent: u8 }{.{
            .type = "TRAFFIC_TARGET_ALLOCATION_TYPE_REVISION",
            .revision = revision,
            .percent = 100,
        }},
        .etag = options.etag,
    }, .{}) catch return error.OutOfMemory;
    return .{ .method = .PATCH, .path = try std.mem.concat(arena, u8, &.{ service_path, query }), .body = body };
}

/// Sends `call` and decodes the operation it answers into memory of its
/// own.
fn operationCall(self: *Client, scratch: Allocator, call: rpc.Call) Error!types.Owned(types.Operation) {
    var result: types.Owned(types.Operation) = try .init(self.gpa);
    errdefer result.deinit();
    const body = try rpc.execute(self, result.arena, call);
    result.value = codec.decodeOperation(result.arena.allocator(), scratch, body) catch |err|
        return rpc.decodeFailed(self, err, "operation");
    return result;
}

/// A write needs a scope production takes writes with: every write to
/// `run.readonly` was refused, "Request had insufficient authentication
/// scopes." (measured).
fn checkWrite(self: *Client) Error!void {
    if (self.scope == .read_only) {
        if (self.diagnostics) |d| d.print("this client asks for run.readonly, which production refuses every write; give Options.scope .read_write", .{});
        return error.InvalidOptions;
    }
}

/// A single region: jobs, executions and operations live in one, and
/// production refuses `-` for a jobs list.
fn checkRegion(self: *Client, location: []const u8) Error!void {
    if (!validate.isLocation(location) or std.mem.eql(u8, location, "-")) {
        if (self.diagnostics) |d| d.print("invalid location: expected one region id such as us-central1 (jobs are not listed across regions)", .{});
        return error.InvalidName;
    }
}

/// An id as one path segment; `-` is refused, since it would read as
/// every one.
fn checkId(self: *Client, id: []const u8, what: []const u8) Error!void {
    if (!validate.isResourceId(id) or std.mem.eql(u8, id, "-")) {
        if (self.diagnostics) |d| d.print("invalid {s} id: visible ASCII without /, at most 500, not -", .{what});
        return error.InvalidName;
    }
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

test "golden: jobs, executions and operations listed and got, by parts and by name" {
    var h: Harness = undefined;
    try h.init(&.{
        .{ .respond = .{ .body = production.jobs_page } },
        .{ .respond = .{ .body = production.job_succeeded } },
        .{ .respond = .{ .body = production.job_fresh } },
        .{ .respond = .{ .body = production.executions_dash } },
        .{ .respond = .{ .body = production.executions_page_one } },
        .{ .respond = .{ .body = production.execution_running } },
        .{ .respond = .{ .body = production.execution_cancelled } },
        .{ .respond = .{ .body = production.operation_run_done } },
    });
    defer h.deinit();
    const c = &h.client;

    var jobs = try c.listJobs("us-central1", .{ .page_size = 1, .page_token = "t" });
    defer jobs.deinit();
    try h.expectRequest(0, .GET, "https://run.googleapis.com/v2/projects/my-project/locations/us-central1/jobs?pageSize=1&pageToken=t");
    try testing.expect(jobs.value.next_page_token != null);

    var job = try c.getJob("us-central1", "zigps-6b8297-quick");
    defer job.deinit();
    try h.expectRequest(1, .GET, "https://run.googleapis.com/v2/projects/my-project/locations/us-central1/jobs/zigps-6b8297-quick");
    try testing.expectEqual(types.ExecutionStatus.succeeded, job.value.latest_created_execution.?.status);

    var named = try c.getJobNamed("projects/my-project/locations/us-central1/jobs/zigps-6b8297-quick");
    defer named.deinit();
    try h.expectRequest(2, .GET, "https://run.googleapis.com/v2/projects/my-project/locations/us-central1/jobs/zigps-6b8297-quick");

    var every = try c.listExecutions("us-central1", "-", .{});
    defer every.deinit();
    try h.expectRequest(3, .GET, "https://run.googleapis.com/v2/projects/my-project/locations/us-central1/jobs/-/executions");
    try testing.expectEqual(5, every.value.executions.len);

    var one = try c.listExecutions("us-central1", "zigps-6b8297-slow", .{ .page_size = 1 });
    defer one.deinit();
    try h.expectRequest(4, .GET, "https://run.googleapis.com/v2/projects/my-project/locations/us-central1/jobs/zigps-6b8297-slow/executions?pageSize=1");

    var execution = try c.getExecution("us-central1", "zigps-6b8297-slow", "zigps-6b8297-slow-nlzdb");
    defer execution.deinit();
    try h.expectRequest(5, .GET, "https://run.googleapis.com/v2/projects/my-project/locations/us-central1/jobs/zigps-6b8297-slow/executions/zigps-6b8297-slow-nlzdb");
    try testing.expectEqual(types.ExecutionStatus.running, execution.value.status());

    // The name a run's operation gives reads back as it is.
    var by_name = try c.getExecutionNamed("projects/my-project/locations/us-central1/jobs/zigps-6b8297-slow/executions/zigps-6b8297-slow-nlzdb");
    defer by_name.deinit();
    try h.expectRequest(6, .GET, "https://run.googleapis.com/v2/projects/my-project/locations/us-central1/jobs/zigps-6b8297-slow/executions/zigps-6b8297-slow-nlzdb");

    var operation = try c.getOperation("projects/my-project/locations/us-central1/operations/6d1e1e32-b691-4524-b5e5-53a92d560cce");
    defer operation.deinit();
    try h.expectRequest(7, .GET, "https://run.googleapis.com/v2/projects/my-project/locations/us-central1/operations/6d1e1e32-b691-4524-b5e5-53a92d560cce");
    try testing.expect(operation.value.done);
    try testing.expectEqual(types.ExecutionStatus.succeeded, operation.value.subject.execution.status());
}

test "the job, execution and operation reads refuse what they will not send" {
    var h: Harness = undefined;
    try h.init(&.{});
    defer h.deinit();
    const c = &h.client;
    // Production refuses '-' for jobs, so nothing is sent.
    try testing.expectError(error.InvalidName, c.listJobs("-", .{}));
    try testing.expectEqualStrings("invalid location: expected one region id such as us-central1 (jobs are not listed across regions)", h.diag.message());
    try testing.expectError(error.InvalidName, c.listJobs("us-central1", .{ .page_token = "a b" }));
    try testing.expectError(error.InvalidName, c.getJob("-", "j"));
    try testing.expectError(error.InvalidName, c.getJob("us-central1", "-"));
    try testing.expectEqualStrings("invalid job id: visible ASCII without /, at most 500, not -", h.diag.message());
    try testing.expectError(error.InvalidName, c.getJob("us-central1", "a/b"));
    try testing.expectError(error.InvalidName, c.getJobNamed("projects/other/locations/l/jobs/j"));
    try testing.expectEqualStrings("invalid job name: expected projects/my-project/locations/<location>/jobs/<id>", h.diag.message());
    try testing.expectError(error.InvalidName, c.listExecutions("-", "-", .{}));
    try testing.expectError(error.InvalidName, c.listExecutions("us-central1", "j k", .{}));
    try testing.expectError(error.InvalidName, c.listExecutions("us-central1", "-", .{ .page_token = "a b" }));
    try testing.expectEqualStrings("invalid page token: expected printable ASCII", h.diag.message());
    try testing.expectError(error.InvalidName, c.getExecution("us-central1", "-", "e"));
    try testing.expectError(error.InvalidName, c.getExecution("us-central1", "j", "-"));
    try testing.expectEqualStrings("invalid execution id: visible ASCII without /, at most 500, not -", h.diag.message());
    try testing.expectError(error.InvalidName, c.getExecutionNamed("projects/my-project/locations/l/jobs/j"));
    try testing.expectError(error.InvalidName, c.getOperation("operations/o"));
    try testing.expectEqualStrings("invalid operation name: expected projects/my-project/locations/<location>/operations/<id>", h.diag.message());
    try testing.expectError(error.InvalidName, c.getOperation("projects/my-project/locations/-/operations/o"));
    try testing.expectError(error.InvalidName, c.getOperation("projects/other/locations/l/operations/o"));
    try h.expectRequestCount(0);
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

test "a job, execution or operation that cannot be decoded is InvalidResponse, named" {
    var h: Harness = undefined;
    try h.init(&.{
        .{ .respond = .{ .body = "{\"jobs\":[{}]}" } },
        .{ .respond = .{ .body = "{\"executionCount\":1}" } },
        .{ .respond = .{ .body = "{\"executions\":1}" } },
        .{ .respond = .{ .body = "{\"name\":\"e\",\"runningCount\":\"x\"}" } },
        .{ .respond = .{ .body = "{\"done\":true}" } },
    });
    defer h.deinit();
    const c = &h.client;
    try testing.expectError(error.InvalidResponse, c.listJobs("us-central1", .{}));
    try testing.expectEqualStrings("the job list response could not be decoded", h.diag.message());
    try testing.expectError(error.InvalidResponse, c.getJob("us-central1", "j"));
    try testing.expectEqualStrings("the job response could not be decoded", h.diag.message());
    try testing.expectError(error.InvalidResponse, c.listExecutions("us-central1", "j", .{}));
    try testing.expectEqualStrings("the execution list response could not be decoded", h.diag.message());
    try testing.expectError(error.InvalidResponse, c.getExecution("us-central1", "j", "e"));
    try testing.expectEqualStrings("the execution response could not be decoded", h.diag.message());
    try testing.expectError(error.InvalidResponse, c.getOperation("projects/my-project/locations/us-central1/operations/o"));
    try testing.expectEqualStrings("the operation response could not be decoded", h.diag.message());
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

test "the job, execution and operation refusals arrive as errors, production's words kept" {
    var h: Harness = undefined;
    try h.init(&.{
        .{ .respond = .{ .status = production.job_unknown_status, .body = production.job_unknown } },
        .{ .respond = .{ .status = production.jobs_made_up_region_status, .body = production.jobs_made_up_region } },
        .{ .respond = .{ .status = production.execution_unknown_status, .body = production.execution_unknown } },
        .{ .respond = .{ .status = production.operation_unknown_status, .body = production.operation_unknown } },
        .{ .respond = .{ .status = production.jobs_dash_status, .body = production.jobs_dash } },
        .{ .respond = .{ .body = "{}" } },
    });
    defer h.deinit();
    const c = &h.client;
    try testing.expectError(error.NotFound, c.getJob("us-central1", "zigps-nobody"));
    try testing.expectEqualStrings("Resource 'zigps-nobody' of kind 'JOB' in region 'us-central1' in project 'extractctl' does not exist.", h.diag.message());
    // A region that does not exist is a permission refusal for jobs.
    try testing.expectError(error.PermissionDenied, c.listJobs("us-fake1", .{}));
    try testing.expectEqualStrings("Permission denied on 'locations/us-fake1' (or it may not exist)", h.diag.message());
    try testing.expectError(error.NotFound, c.getExecution("us-central1", "zigps-nobody", "zigps-nobody-abcde"));
    try testing.expectError(error.NotFound, c.getOperation("projects/my-project/locations/us-central1/operations/00000000-0000-0000-0000-000000000000"));
    // What '-' would meet, were it sent: the client never sends it, but a
    // region production stops answering this way still maps.
    try testing.expectError(error.InvalidArgument, c.listJobs("us-central1", .{}));
    try testing.expectEqualStrings("Request contains an invalid argument.", h.diag.message());
    // A job nobody has lists no executions, as production answered.
    var none = try c.listExecutions("us-central1", "zigps-nobody", .{});
    defer none.deinit();
    try testing.expectEqual(0, none.value.executions.len);
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

test "a client asks its token provider for the one scope its options name" {
    const Case = struct { ?rpc.Scope, []const u8 };
    for ([_]Case{
        .{ null, "https://www.googleapis.com/auth/run.readonly" },
        .{ .read_only, "https://www.googleapis.com/auth/run.readonly" },
        .{ .read_write, "https://www.googleapis.com/auth/run" },
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
        var page = try client.listServices("us-central1", .{});
        page.deinit();
        try testing.expectEqual(1, tokens.scope_count);
        try testing.expectEqualStrings(case[1], tokens.firstScope());
    }
    try testing.expectEqualStrings("https://www.googleapis.com/auth/run.readonly", rpc.scope);
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
                .{ .respond = .{ .body = production.jobs_page } },
                .{ .respond = .{ .body = production.job_succeeded } },
                .{ .respond = .{ .body = production.executions_dash } },
                .{ .respond = .{ .body = production.execution_cancelled } },
                .{ .respond = .{ .body = production.operation_traffic_done } },
                .{ .respond = .{ .body = production.operation_run_failed } },
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
            var jobs = try client.listJobs("us-central1", .{ .page_token = "t" });
            jobs.deinit();
            var job = try client.getJobNamed("projects/my-project/locations/us-central1/jobs/zigps-6b8297-quick");
            job.deinit();
            var executions = try client.listExecutions("us-central1", "-", .{});
            executions.deinit();
            var execution = try client.getExecutionNamed("projects/my-project/locations/us-central1/jobs/j/executions/e");
            execution.deinit();
            var traffic = try client.getOperation("projects/my-project/locations/us-central1/operations/o");
            traffic.deinit();
            var failed = try client.getOperation("projects/my-project/locations/us-central1/operations/o");
            failed.deinit();
        }
    };
    try testing.checkAllAllocationFailures(test_util.no_grow_allocator, Run.calls, .{});
}

const job_url = "https://run.googleapis.com/v2/projects/my-project/locations/us-central1/jobs/zigps-6b8297-quick";
const execution_url = "https://run.googleapis.com/v2/projects/my-project/locations/us-central1/jobs/zigps-6b8297-slow/executions/zigps-6b8297-slow-nlzdb";
const service_url = "https://run.googleapis.com/v2/projects/my-project/locations/us-central1/services/zigps-6b8297";
const etag = "\"CM_g2dYGEKjFt8wB/cHJvamVjdHMv\"";
const route_body = "{\"traffic\":[{\"type\":\"TRAFFIC_TARGET_ALLOCATION_TYPE_REVISION\",\"revision\":\"zigps-6b8297-00001-527\",\"percent\":100}],\"etag\":\"\\\"CM_g2dYGEKjFt8wB/cHJvamVjdHMv\\\"\"}";

test "golden: the three writes, and their previews byte for byte what was sent" {
    var h: Harness = undefined;
    try h.initScope(&.{
        .{ .respond = .{ .body = production.operation_run } },
        .{ .respond = .{ .body = production.operation_cancel } },
        .{ .respond = .{ .body = production.operation_traffic } },
        .{ .respond = .{ .body = production.operation_traffic_validate } },
    }, .read_write);
    defer h.deinit();
    const c = &h.client;

    var run = try c.runJob("us-central1", "zigps-6b8297-quick");
    defer run.deinit();
    try h.expectSent(0, .POST, job_url ++ ":run", "{}");
    try testing.expect(!run.value.done);
    try testing.expectEqualStrings("projects/extractctl/locations/us-central1/jobs/zigps-6b8297-quick/executions/zigps-6b8297-quick-l4ffj", run.value.subject.execution.name);

    var cancel = try c.cancelExecution("us-central1", "zigps-6b8297-slow", "zigps-6b8297-slow-nlzdb");
    defer cancel.deinit();
    try h.expectSent(1, .POST, execution_url ++ ":cancel", "{}");
    try testing.expectEqualStrings("zigps-6b8297-slow-nlzdb", cancel.value.subject.execution.id);

    var route = try c.routeAllTraffic("us-central1", "zigps-6b8297", "zigps-6b8297-00001-527", .{ .etag = etag });
    defer route.deinit();
    try h.expectSent(2, .PATCH, service_url ++ "?updateMask=traffic,etag", route_body);
    try testing.expectEqualStrings("zigps-6b8297-00001-527", route.value.subject.service.traffic[0].revision);

    var check = try c.routeAllTraffic("us-central1", "zigps-6b8297", "zigps-6b8297-00001-527", .{ .etag = etag, .validate_only = true });
    defer check.deinit();
    try h.expectSent(3, .PATCH, service_url ++ "?updateMask=traffic,etag&validateOnly=true", route_body);
    try testing.expect(!check.value.done);

    // Each preview is the request its write sent, byte for byte.
    var previews: [4]types.Owned(PreparedRequest) = .{
        try c.runJobRequest("us-central1", "zigps-6b8297-quick"),
        try c.cancelExecutionRequest("us-central1", "zigps-6b8297-slow", "zigps-6b8297-slow-nlzdb"),
        try c.routeAllTrafficRequest("us-central1", "zigps-6b8297", "zigps-6b8297-00001-527", .{ .etag = etag }),
        try c.routeAllTrafficRequest("us-central1", "zigps-6b8297", "zigps-6b8297-00001-527", .{ .etag = etag, .validate_only = true }),
    };
    defer for (&previews) |*p| p.deinit();
    for (previews, 0..) |p, i| {
        const sent = try h.fake.request(i);
        try testing.expectEqual(sent.method, p.value.method);
        try testing.expectEqualStrings(sent.url, p.value.url);
        try testing.expectEqualStrings(sent.body.?, p.value.body);
    }
    try h.expectRequestCount(4);
}

test "a read-only client refuses every write and its preview, before sending" {
    var h: Harness = undefined;
    try h.init(&.{});
    defer h.deinit();
    const c = &h.client;
    try testing.expectError(error.InvalidOptions, c.runJob("us-central1", "j"));
    try testing.expectEqualStrings("this client asks for run.readonly, which production refuses every write; give Options.scope .read_write", h.diag.message());
    try testing.expectError(error.InvalidOptions, c.cancelExecution("us-central1", "j", "e"));
    try testing.expectError(error.InvalidOptions, c.routeAllTraffic("us-central1", "s", "r", .{ .etag = etag }));
    try testing.expectError(error.InvalidOptions, c.runJobRequest("us-central1", "j"));
    try testing.expectError(error.InvalidOptions, c.cancelExecutionRequest("us-central1", "j", "e"));
    try testing.expectError(error.InvalidOptions, c.routeAllTrafficRequest("us-central1", "s", "r", .{ .etag = etag }));
    try h.expectRequestCount(0);

    // cloud-platform takes the writes, as production did.
    var cp: Harness = undefined;
    try cp.initScope(&.{.{ .respond = .{ .body = production.operation_run } }}, .cloud_platform);
    defer cp.deinit();
    var run = try cp.client.runJob("us-central1", "zigps-6b8297-quick");
    run.deinit();
    try testing.expectEqualStrings("https://www.googleapis.com/auth/cloud-platform", cp.token.firstScope());
}

test "the writes refuse what they will not send, the previews alike" {
    var h: Harness = undefined;
    try h.initScope(&.{}, .read_write);
    defer h.deinit();
    const c = &h.client;
    try testing.expectError(error.InvalidName, c.runJob("-", "j"));
    try testing.expectError(error.InvalidName, c.runJob("us-central1", "-"));
    try testing.expectError(error.InvalidName, c.runJobRequest("us-central1", "a/b"));
    try testing.expectError(error.InvalidName, c.cancelExecution("us-central1", "-", "e"));
    try testing.expectError(error.InvalidName, c.cancelExecution("us-central1", "j", "-"));
    try testing.expectError(error.InvalidName, c.cancelExecutionRequest("US", "j", "e"));
    try testing.expectError(error.InvalidName, c.routeAllTraffic("-", "s", "r", .{ .etag = etag }));
    try testing.expectError(error.InvalidName, c.routeAllTraffic("us-central1", "-", "r", .{ .etag = etag }));
    try testing.expectError(error.InvalidName, c.routeAllTraffic("us-central1", "s", "-", .{ .etag = etag }));
    // A full name is refused here; production refuses it too, 400.
    try testing.expectError(error.InvalidName, c.routeAllTraffic("us-central1", "s", "projects/p/locations/l/services/s/revisions/r", .{ .etag = etag }));
    try testing.expectEqualStrings("invalid revision id: visible ASCII without /, at most 500, not -", h.diag.message());
    // The etag is the guard: none, or one no read could have given, is
    // refused, the preview alike.
    try testing.expectError(error.InvalidOptions, c.routeAllTraffic("us-central1", "s", "r", .{ .etag = "" }));
    try testing.expectEqualStrings("invalid etag: expected Service.etag as read, printable ASCII; production takes a change without one unguarded", h.diag.message());
    try testing.expectError(error.InvalidOptions, c.routeAllTrafficRequest("us-central1", "s", "r", .{ .etag = "a\nb" }));
    try testing.expectError(error.InvalidOptions, c.routeAllTraffic("us-central1", "s", "r", .{ .etag = core.testing.repeat("x", 1025) }));
    try h.expectRequestCount(0);
}

test "the writes' refusals arrive as errors, production's words kept" {
    var h: Harness = undefined;
    try h.initScope(&.{
        .{ .respond = .{ .status = production.write_scope_refused_status, .body = production.write_scope_refused } },
        .{ .respond = .{ .status = production.cancel_not_running_status, .body = production.cancel_not_running } },
        .{ .respond = .{ .status = production.traffic_stale_etag_status, .body = production.traffic_stale_etag } },
        .{ .respond = .{ .status = production.traffic_other_service_status, .body = production.traffic_other_service } },
    }, .read_write);
    defer h.deinit();
    const c = &h.client;
    // A token minted for run.readonly in spite of the client's scope.
    try testing.expectError(error.PermissionDenied, c.runJob("us-central1", "zigps-6b8297-quick"));
    try testing.expectEqualStrings("Request had insufficient authentication scopes.", h.diag.message());
    // A first attempt's refusal is returned as it is: nothing read.
    try testing.expectError(error.FailedPrecondition, c.cancelExecution("us-central1", "zigps-6b8297-slow", "zigps-6b8297-slow-nlzdb"));
    try testing.expectEqualStrings("Execution 'zigps-6b8297-slow-nlzdb' cannot be cancelled because it is not running.", h.diag.message());
    // A service changed since the read: refused, never retried.
    try testing.expectError(error.Aborted, c.routeAllTraffic("us-central1", "zigps-8e3f3f", "zigps-8e3f3f-00002-rgh", .{ .etag = etag }));
    try testing.expectEqualStrings("Conflict for resource 'zigps-8e3f3f': version '1792585476717971' was specified but current version is '1792585482447477'.", h.diag.message());
    try testing.expectError(error.InvalidArgument, c.routeAllTraffic("us-central1", "zigps-6b8297", "zigps-other-00001-abc", .{ .etag = etag }));
    try testing.expectEqualStrings("spec.traffic.revision_name[0]: Revision target 'zigps-other-00001-abc' invalid. Expected a revision prefixed with 'zigps-6b8297-'.", h.diag.message());
    try h.expectRequestCount(4);
}

test "a run is sent again only when it cannot have reached the server" {
    var h: Harness = undefined;
    try h.initScope(&.{
        .{ .respond = .{ .status = 503, .body = "{\"error\":{\"code\":503,\"message\":\"down\",\"status\":\"UNAVAILABLE\"}}" } },
        .{ .fail = error.ConnectionRefused },
        .{ .respond = .{ .body = production.operation_run } },
        .{ .fail = error.ConnectionResetByPeer },
    }, .read_write);
    defer h.deinit();
    const c = &h.client;
    // A 503 may follow a run that landed: returned after one send.
    try testing.expectError(error.Unavailable, c.runJob("us-central1", "zigps-6b8297-quick"));
    try h.expectRequestCount(1);
    // A refused connection never left: sent again.
    var run = try c.runJob("us-central1", "zigps-6b8297-quick");
    run.deinit();
    try h.expectRequestCount(3);
    try h.expectSent(2, .POST, job_url ++ ":run", "{}");
    // A dropped connection may follow one that landed.
    try testing.expectError(error.ConnectionResetByPeer, c.runJob("us-central1", "zigps-6b8297-quick"));
    try h.expectRequestCount(4);
}

test "a cancel is retried, and a resend refused as not running reads the execution" {
    const unavailable: test_util.FakeTransport.Reply = .{ .respond = .{ .status = 503, .body = "{\"error\":{\"code\":503,\"message\":\"down\",\"status\":\"UNAVAILABLE\"}}" } };
    const not_running: test_util.FakeTransport.Reply = .{ .respond = .{ .status = production.cancel_not_running_status, .body = production.cancel_not_running } };
    const cancel_url = execution_url ++ ":cancel";

    // A lost answer, then the resend taken.
    {
        var h: Harness = undefined;
        try h.initScope(&.{ unavailable, .{ .respond = .{ .body = production.operation_cancel } } }, .read_write);
        defer h.deinit();
        var op = try h.client.cancelExecution("us-central1", "zigps-6b8297-slow", "zigps-6b8297-slow-nlzdb");
        op.deinit();
        try h.expectRequestCount(2);
        try h.expectSent(1, .POST, cancel_url, "{}");
    }
    // A lost answer, the resend refused, the execution cancelled: the
    // first one landed, and the read is the answer.
    {
        var h: Harness = undefined;
        try h.initScope(&.{ unavailable, not_running, .{ .respond = .{ .body = production.execution_cancelled } } }, .read_write);
        defer h.deinit();
        var op = try h.client.cancelExecution("us-central1", "zigps-6b8297-slow", "zigps-6b8297-slow-nlzdb");
        defer op.deinit();
        try testing.expectEqualStrings("", op.value.name);
        try testing.expect(op.value.done);
        try testing.expectEqual(null, op.value.failure);
        try testing.expectEqual(types.ExecutionStatus.cancelled, op.value.subject.execution.status());
        try h.expectRequest(2, .GET, execution_url);
        try testing.expectEqualStrings("", h.diag.message());
    }
    // Refused while the read shows it still stopping: landed too.
    {
        var h: Harness = undefined;
        try h.initScope(&.{ unavailable, not_running, .{ .respond = .{ .body = cancelling_execution } } }, .read_write);
        defer h.deinit();
        var op = try h.client.cancelExecution("us-central1", "zigps-6b8297-slow", "zigps-6b8297-slow-nlzdb");
        defer op.deinit();
        try testing.expectEqualStrings("", op.value.name);
        try testing.expectEqual(types.ExecutionStatus.cancelling, op.value.subject.execution.status());
    }
    // The same, but the execution ended on its own: the refusal stands.
    {
        var h: Harness = undefined;
        try h.initScope(&.{ unavailable, not_running, .{ .respond = .{ .body = succeeded_execution } } }, .read_write);
        defer h.deinit();
        try testing.expectError(error.FailedPrecondition, h.client.cancelExecution("us-central1", "zigps-6b8297-slow", "zigps-6b8297-slow-nlzdb"));
        try testing.expectEqualStrings("cancelling the execution was refused with FailedPrecondition: it is no longer running, and not cancelled", h.diag.message());
        try h.expectRequestCount(3);
    }
    // The resend refused and the read failing: the refusal, both named.
    {
        var h: Harness = undefined;
        try h.initScope(&.{ unavailable, not_running, .{ .respond = .{ .status = production.execution_unknown_status, .body = production.execution_unknown } } }, .read_write);
        defer h.deinit();
        try testing.expectError(error.FailedPrecondition, h.client.cancelExecution("us-central1", "zigps-6b8297-slow", "zigps-6b8297-slow-nlzdb"));
        try testing.expectEqualStrings("cancelling the execution was refused with FailedPrecondition after an attempt that may have landed, and reading it to see failed with NotFound", h.diag.message());
    }
    // A refused connection never left: a refusal after it is the first.
    {
        var h: Harness = undefined;
        try h.initScope(&.{ .{ .fail = error.ConnectionRefused }, not_running }, .read_write);
        defer h.deinit();
        try testing.expectError(error.FailedPrecondition, h.client.cancelExecution("us-central1", "zigps-6b8297-slow", "zigps-6b8297-slow-nlzdb"));
        try h.expectRequestCount(2);
    }
    // The policy's attempts bound the resends.
    {
        var h: Harness = undefined;
        try h.initScope(&.{ unavailable, unavailable, unavailable, unavailable }, .read_write);
        defer h.deinit();
        h.client.retry.max_attempts = 3;
        try testing.expectError(error.Unavailable, h.client.cancelExecution("us-central1", "zigps-6b8297-slow", "zigps-6b8297-slow-nlzdb"));
        try h.expectRequestCount(3);
    }
}

/// An execution stopping: a task cancelled, `Completed` still reconciling,
/// as production showed one 11 s after a cancel.
const cancelling_execution =
    \\{"name":"projects/my-project/locations/us-central1/jobs/zigps-6b8297-slow/executions/zigps-6b8297-slow-nlzdb",
    \\ "job":"zigps-6b8297-slow","cancelledCount":1,
    \\ "conditions":[{"type":"Started","state":"CONDITION_SUCCEEDED"},{"type":"Completed","state":"CONDITION_RECONCILING"}]}
;

/// An execution that ended on its own, for the cancel that found it so.
const succeeded_execution =
    \\{"name":"projects/my-project/locations/us-central1/jobs/zigps-6b8297-slow/executions/zigps-6b8297-slow-nlzdb",
    \\ "job":"zigps-6b8297-slow","succeededCount":1,
    \\ "conditions":[{"type":"Started","state":"CONDITION_SUCCEEDED"},{"type":"Completed","state":"CONDITION_SUCCEEDED"}]}
;

test "a traffic change is retried as sent, and a stale etag never" {
    const unavailable: test_util.FakeTransport.Reply = .{ .respond = .{ .status = 503, .body = "{\"error\":{\"code\":503,\"message\":\"down\",\"status\":\"UNAVAILABLE\"}}" } };
    const stale: test_util.FakeTransport.Reply = .{ .respond = .{ .status = production.traffic_stale_etag_status, .body = production.traffic_stale_etag } };
    var h: Harness = undefined;
    try h.initScope(&.{ unavailable, .{ .respond = .{ .body = production.operation_traffic } }, unavailable, stale }, .read_write);
    defer h.deinit();
    const c = &h.client;
    var op = try c.routeAllTraffic("us-central1", "zigps-6b8297", "zigps-6b8297-00001-527", .{ .etag = etag });
    op.deinit();
    try h.expectSent(0, .PATCH, service_url ++ "?updateMask=traffic,etag", route_body);
    try h.expectSent(1, .PATCH, service_url ++ "?updateMask=traffic,etag", route_body);
    // A resend refused as stale: someone else changed the service between
    // the two, and the refusal is returned.
    try testing.expectError(error.Aborted, c.routeAllTraffic("us-central1", "zigps-6b8297", "zigps-6b8297-00001-527", .{ .etag = etag }));
    try h.expectRequestCount(4);
}

test "every allocation failure in a write is OutOfMemory without leaks" {
    const Run = struct {
        fn calls(gpa: Allocator) !void {
            var fake: test_util.FakeTransport = .init(testing.allocator, &.{
                .{ .respond = .{ .body = production.operation_run } },
                .{ .respond = .{ .status = 503, .body = "{\"error\":{\"code\":503,\"message\":\"down\",\"status\":\"UNAVAILABLE\"}}" } },
                .{ .respond = .{ .status = production.cancel_not_running_status, .body = production.cancel_not_running } },
                .{ .respond = .{ .body = production.execution_cancelled } },
                .{ .respond = .{ .body = production.operation_traffic } },
            });
            defer fake.deinit();
            var tokens: test_util.FakeTokenProvider = .{};
            var clock: test_util.FakeClock = .{};
            var client = try Client.init(gpa, clock.io(), .{ .project_id = "my-project", .token_provider = tokens.provider(), .scope = .read_write, .transport = fake.transport() });
            defer client.deinit();
            var run = try client.runJob("us-central1", "zigps-6b8297-quick");
            run.deinit();
            var cancel = try client.cancelExecution("us-central1", "zigps-6b8297-slow", "zigps-6b8297-slow-nlzdb");
            cancel.deinit();
            var route = try client.routeAllTraffic("us-central1", "zigps-6b8297", "zigps-6b8297-00001-527", .{ .etag = etag });
            route.deinit();
            var preview = try client.routeAllTrafficRequest("us-central1", "zigps-6b8297", "r", .{ .etag = etag, .validate_only = true });
            preview.deinit();
        }
    };
    try testing.checkAllAllocationFailures(test_util.no_grow_allocator, Run.calls, .{});
}
