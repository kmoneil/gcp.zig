//! Cloud Scheduler in memory, for tests of code that reads jobs: behind
//! `Client.Options.transport`, it answers the module's three reads as
//! production answered them when measured on 2026-10-19 (issue #245).
//!
//! - Locations and jobs are put in by the test: the API here is read
//!   only, so `putLocation`, `putJob` and `setLastAttempt` are the
//!   test's levers, standing in for the console or Terraform that made
//!   the jobs and for Scheduler running them.
//! - A job always answers a `status`: code -1 before any attempt, as
//!   production bears a job with; the real code after `setLastAttempt`
//!   or a `PutJob.last_attempt`.
//! - Lists sort by name and page as production documents: the default
//!   page is the maximum, 500; a `pageSize` over 500 is production's
//!   400 in its words.
//! - Refused in production's words: a job nobody has (404 "Job not
//!   found."), a location nobody put (400 "Location '<l>' is not a
//!   valid location. Use ListLocations to list valid locations.").
//! - Faults a test asks for: refusals, dropped connections, and a lost
//!   answer.
//!
//! Not modelled, answered 501 with the reason: writes of any kind
//! (create, patch, delete, run, pause, resume), operations, CMEK, and
//! another project's paths.

const std = @import("std");
const Allocator = std.mem.Allocator;
const Stringify = std.json.Stringify;
const core = @import("core");
const tp = core.transport;
const types = @import("types.zig");
const validate = @import("validate.zig");

pub const FakeScheduler = struct {
    gpa: Allocator,
    io: std.Io,
    mutex: std.Io.Mutex = .init,
    options: Options,
    /// Strings, locations and jobs, freed with the fake.
    store: std.heap.ArenaAllocator,
    /// Location ids, in the order put in.
    locations: std.StringArrayHashMapUnmanaged(void) = .empty,
    /// By full name, sorted on read.
    jobs: std.StringArrayHashMapUnmanaged(*FakeJob) = .empty,
    faults: [3]Fault = .{ .{}, .{}, .{} },
    calls: usize = 0,
    job_counter: u64 = 0,

    const Fault = struct { n: usize = 0, status: u16 = 0 };
    const refuse = 0;
    const drop = 1;
    const lose = 2;

    pub const Options = struct {
        /// The project it answers for, by id.
        project_id: []const u8 = "my-project",
    };

    pub const Reply = struct { status: u16, headers: []const tp.Header = &.{}, body: []const u8 };

    const FakeJob = struct {
        name: []const u8,
        id: []const u8,
        location: []const u8,
        description: []const u8,
        schedule: []const u8,
        time_zone: []const u8,
        state: types.JobState,
        last_attempt: ?types.LastAttempt,
        last_attempt_time: ?std.Io.Timestamp,
        schedule_time: ?std.Io.Timestamp,
        user_update_time: ?std.Io.Timestamp,
        attempt_deadline_s: ?f64,
        retry: ?types.RetryConfig,
        target: types.Target,
    };

    pub fn init(gpa: Allocator, io: std.Io, options: Options) FakeScheduler {
        return .{ .gpa = gpa, .io = io, .options = options, .store = .init(gpa) };
    }

    pub fn deinit(f: *FakeScheduler) void {
        f.locations.deinit(f.gpa);
        f.jobs.deinit(f.gpa);
        f.store.deinit();
        f.* = undefined;
    }

    /// Goes into `Client.Options.transport`.
    pub fn transport(f: *FakeScheduler) tp.Transport {
        return .{ .ptr = f, .vtable = &.{ .send = send } };
    }

    // Faults, each for the next `n` calls.

    /// Answers them with `status`, and changes nothing.
    pub fn refuseNext(f: *FakeScheduler, n: usize, status: u16) void {
        f.setFault(refuse, .{ .n = n, .status = status });
    }

    /// Closes their connection before any answer.
    pub fn dropNext(f: *FakeScheduler, n: usize) void {
        f.setFault(drop, .{ .n = n });
    }

    /// Serves them and answers `status` instead of what was read.
    pub fn loseNext(f: *FakeScheduler, n: usize, status: u16) void {
        f.setFault(lose, .{ .n = n, .status = status });
    }

    fn setFault(f: *FakeScheduler, slot: usize, fault: Fault) void {
        f.mutex.lockUncancelable(f.io);
        defer f.mutex.unlock(f.io);
        f.faults[slot] = fault;
    }

    fn takeFault(f: *FakeScheduler, slot: usize) ?Fault {
        const fault = &f.faults[slot];
        if (fault.n == 0) return null;
        fault.n -= 1;
        return fault.*;
    }

    // What a test reads.

    /// Calls served, refusals included.
    pub fn callCount(f: *FakeScheduler) usize {
        f.mutex.lockUncancelable(f.io);
        defer f.mutex.unlock(f.io);
        return f.calls;
    }

    /// Jobs held, every location together.
    pub fn jobCount(f: *FakeScheduler) usize {
        f.mutex.lockUncancelable(f.io);
        defer f.mutex.unlock(f.io);
        return f.jobs.count();
    }

    // What a test puts in.

    pub const PutError = error{ OutOfMemory, InvalidEntry };

    /// A location jobs can live under, such as "us-central1". Production
    /// answered every public region; a test puts in the ones it wants.
    pub fn putLocation(f: *FakeScheduler, id: []const u8) PutError!void {
        f.mutex.lockUncancelable(f.io);
        defer f.mutex.unlock(f.io);
        if (!validate.isLocation(id)) return error.InvalidEntry;
        if (f.locations.contains(id)) return error.InvalidEntry;
        try f.locations.put(f.gpa, try f.store.allocator().dupe(u8, id), {});
    }

    /// A job as a test puts one in, standing in for whoever created it.
    pub const PutJob = struct {
        /// Must be put with `putLocation` first.
        location: []const u8,
        /// Assigned when null.
        id: ?[]const u8 = null,
        description: []const u8 = "",
        schedule: []const u8 = "* * * * *",
        time_zone: []const u8 = "UTC",
        state: types.JobState = .enabled,
        /// Set together with `last_attempt_time`, or neither: a job is
        /// born with neither, its wire status code -1.
        last_attempt: ?types.LastAttempt = null,
        last_attempt_time: ?std.Io.Timestamp = null,
        /// The next run. Production removes it from a paused job.
        schedule_time: ?std.Io.Timestamp = null,
        user_update_time: ?std.Io.Timestamp = null,
        attempt_deadline_s: ?f64 = null,
        /// Null leaves the keys out, as production answered a Pub/Sub
        /// job created without them.
        retry: ?types.RetryConfig = null,
        target: types.Target = .unknown,
    };

    /// Puts a job in and returns its full name, owned by the fake.
    ///
    /// `error.InvalidEntry`, with nothing kept, for: a location nobody
    /// put; an id taken or malformed; a state outside enabled, paused,
    /// disabled and update_failed; a last attempt without its time, or a
    /// time without its attempt; a target of `.unknown` (production
    /// always has one).
    pub fn putJob(f: *FakeScheduler, job: PutJob) PutError![]const u8 {
        f.mutex.lockUncancelable(f.io);
        defer f.mutex.unlock(f.io);
        if (!f.locations.contains(job.location)) return error.InvalidEntry;
        switch (job.state) {
            .enabled, .paused, .disabled, .update_failed => {},
            else => return error.InvalidEntry,
        }
        if ((job.last_attempt == null) != (job.last_attempt_time == null)) return error.InvalidEntry;
        if (job.target == .unknown) return error.InvalidEntry;
        const s = f.store.allocator();
        const id = if (job.id) |given| id: {
            if (!validate.isJobId(given)) return error.InvalidEntry;
            break :id try s.dupe(u8, given);
        } else try std.fmt.allocPrint(s, "job-{d}", .{f.job_counter});
        f.job_counter += 1;
        const name = try std.fmt.allocPrint(s, "projects/{s}/locations/{s}/jobs/{s}", .{ f.options.project_id, job.location, id });
        if (f.jobs.contains(name)) return error.InvalidEntry;
        const held = try s.create(FakeJob);
        held.* = .{
            .name = name,
            .id = id,
            .location = try s.dupe(u8, job.location),
            .description = try s.dupe(u8, job.description),
            .schedule = try s.dupe(u8, job.schedule),
            .time_zone = try s.dupe(u8, job.time_zone),
            .state = job.state,
            .last_attempt = if (job.last_attempt) |a| .{ .code = a.code, .message = try s.dupe(u8, a.message) } else null,
            .last_attempt_time = job.last_attempt_time,
            .schedule_time = job.schedule_time,
            .user_update_time = job.user_update_time,
            .attempt_deadline_s = job.attempt_deadline_s,
            .retry = job.retry,
            .target = try dupeTarget(s, job.target),
        };
        try f.jobs.put(f.gpa, held.name, held);
        return held.name;
    }

    /// Records an attempt, as Scheduler running the job would: the status
    /// a read answers, and `lastAttemptTime`. `error.InvalidEntry` for a
    /// name nobody has.
    pub fn setLastAttempt(f: *FakeScheduler, name: []const u8, code: i64, message: []const u8, at: std.Io.Timestamp) PutError!void {
        f.mutex.lockUncancelable(f.io);
        defer f.mutex.unlock(f.io);
        const job = f.jobs.get(name) orelse return error.InvalidEntry;
        job.last_attempt = .{ .code = code, .message = try f.store.allocator().dupe(u8, message) };
        job.last_attempt_time = at;
    }

    fn dupeTarget(s: Allocator, target: types.Target) Allocator.Error!types.Target {
        return switch (target) {
            .http => |t| .{ .http = .{
                .uri = try s.dupe(u8, t.uri),
                .method = t.method,
                .headers = try dupeLabels(s, t.headers),
                .body = try s.dupe(u8, t.body),
                .auth = switch (t.auth) {
                    .none => .none,
                    .oauth => |o| .{ .oauth = .{ .service_account_email = try s.dupe(u8, o.service_account_email), .scope = try s.dupe(u8, o.scope) } },
                    .oidc => |o| .{ .oidc = .{ .service_account_email = try s.dupe(u8, o.service_account_email), .audience = try s.dupe(u8, o.audience) } },
                },
            } },
            .pubsub => |t| .{ .pubsub = .{
                .topic_name = try s.dupe(u8, t.topic_name),
                .data = try s.dupe(u8, t.data),
                .attributes = try dupeLabels(s, t.attributes),
            } },
            .app_engine => |t| .{ .app_engine = .{
                .relative_uri = try s.dupe(u8, t.relative_uri),
                .method = t.method,
                .headers = try dupeLabels(s, t.headers),
                .body = try s.dupe(u8, t.body),
                .service = try s.dupe(u8, t.service),
                .version = try s.dupe(u8, t.version),
                .instance = try s.dupe(u8, t.instance),
                .host = try s.dupe(u8, t.host),
            } },
            .unknown => .unknown,
        };
    }

    fn dupeLabels(s: Allocator, labels: []const types.Label) Allocator.Error![]const types.Label {
        const out = try s.alloc(types.Label, labels.len);
        for (labels, out) |l, *o| o.* = .{ .key = try s.dupe(u8, l.key), .value = try s.dupe(u8, l.value) };
        return out;
    }

    // The transport.

    fn send(ptr: *anyopaque, req: tp.Request, arena: Allocator) tp.Error!tp.Response {
        const f: *FakeScheduler = @ptrCast(@alignCast(ptr));
        const reply = try f.serve(req, arena);
        return .{ .status = reply.status, .headers = reply.headers, .body = reply.body };
    }

    /// One request, as `send` serves it: for a test that wants to send
    /// what no client would.
    pub fn serve(f: *FakeScheduler, req: tp.Request, arena: Allocator) tp.Error!Reply {
        const path = pathOf(req.url);
        const q_at = std.mem.indexOfScalar(u8, path, '?');
        const route_text = path[0 .. q_at orelse path.len];
        const query = if (q_at) |q| path[q + 1 ..] else "";
        f.mutex.lockUncancelable(f.io);
        defer f.mutex.unlock(f.io);
        f.calls += 1;
        if (f.takeFault(drop) != null) return error.ConnectionResetByPeer;
        if (f.takeFault(refuse)) |fault| return refusal(arena, fault.status);
        const lost = f.takeFault(lose);
        const reply = try f.route(req, arena, route_text, query);
        if (lost) |fault| return refusal(arena, fault.status);
        return reply;
    }

    fn route(f: *FakeScheduler, req: tp.Request, arena: Allocator, route_text: []const u8, query: []const u8) Allocator.Error!Reply {
        if (req.bearer == null) return fail(arena, 401, "UNAUTHENTICATED", "Request is missing required authentication credential. Expected OAuth 2 access token, login cookie or other valid authentication credential. See https://developers.google.com/identity/sign-in/web/devconsole-project.");
        if (req.method != .GET) return notModelled(arena, "anything but a read");
        const target = parseRoute(route_text) orelse return notModelled(arena, "this path");
        if (!std.mem.eql(u8, target.project, f.options.project_id)) return notModelled(arena, "a project other than the fake's own");
        const params = try parseParams(arena, query) orelse return fail(arena, 400, "INVALID_ARGUMENT", "Invalid query string.");
        switch (target.kind) {
            .locations => return f.listLocations(arena, params),
            .jobs => |location| {
                if (!f.locations.contains(location)) {
                    return fail(arena, 400, "INVALID_ARGUMENT", try arena.print("Location '{s}' is not a valid location. Use ListLocations to list valid locations.", .{location}));
                }
                return f.listJobs(arena, location, params);
            },
            .job => |j| {
                if (!f.locations.contains(j.location)) {
                    return fail(arena, 400, "INVALID_ARGUMENT", try arena.print("Location '{s}' is not a valid location. Use ListLocations to list valid locations.", .{j.location}));
                }
                var name: std.Io.Writer.Allocating = .init(arena);
                name.writer.print("projects/{s}/locations/{s}/jobs/{s}", .{ f.options.project_id, j.location, j.id }) catch return error.OutOfMemory;
                const job = f.jobs.get(name.written()) orelse return fail(arena, 404, "NOT_FOUND", "Job not found.");
                var out: std.Io.Writer.Allocating = .init(arena);
                var jw: Stringify = .{ .writer = &out.writer };
                writeJob(&jw, job) catch return error.OutOfMemory;
                return .{ .status = 200, .body = out.written() };
            },
        }
    }

    fn listLocations(f: *FakeScheduler, arena: Allocator, params: []const Param) Allocator.Error!Reply {
        var sorted: std.ArrayList([]const u8) = .empty;
        try sorted.appendSlice(arena, f.locations.keys());
        std.mem.sort([]const u8, sorted.items, {}, lessThan);
        const window = pageOf(params, sorted.items.len, sorted.items.len) orelse return pageRefusal(arena);
        var out: std.Io.Writer.Allocating = .init(arena);
        var jw: Stringify = .{ .writer = &out.writer };
        write: {
            jw.beginObject() catch break :write;
            if (window.to > window.from) {
                jw.objectField("locations") catch break :write;
                jw.beginArray() catch break :write;
                for (sorted.items[window.from..window.to]) |id| {
                    jw.beginObject() catch break :write;
                    jw.objectField("name") catch break :write;
                    jw.print("\"projects/{s}/locations/{s}\"", .{ f.options.project_id, id }) catch break :write;
                    jw.objectField("locationId") catch break :write;
                    jw.write(id) catch break :write;
                    jw.objectField("labels") catch break :write;
                    jw.beginObject() catch break :write;
                    jw.objectField("cloud.googleapis.com/region") catch break :write;
                    jw.write(id) catch break :write;
                    jw.endObject() catch break :write;
                    jw.endObject() catch break :write;
                }
                jw.endArray() catch break :write;
            }
            if (window.next) |n| {
                jw.objectField("nextPageToken") catch break :write;
                jw.print("\"p{d}\"", .{n}) catch break :write;
            }
            jw.endObject() catch break :write;
            return .{ .status = 200, .body = out.written() };
        }
        return error.OutOfMemory;
    }

    fn listJobs(f: *FakeScheduler, arena: Allocator, location: []const u8, params: []const Param) Allocator.Error!Reply {
        if (paramOf(params, "pageSize")) |text| {
            const n = std.fmt.parseInt(usize, text, 10) catch return pageRefusal(arena);
            if (n > validate.max_page_size) {
                return fail(arena, 400, "INVALID_ARGUMENT", "ListJobsRequest.pageSize must be less than or equal to 500.");
            }
        }
        var matched: std.ArrayList(*FakeJob) = .empty;
        for (f.jobs.values()) |job| {
            if (std.mem.eql(u8, job.location, location)) try matched.append(arena, job);
        }
        std.mem.sort(*FakeJob, matched.items, {}, struct {
            fn inner(_: void, a: *FakeJob, b: *FakeJob) bool {
                return std.mem.lessThan(u8, a.name, b.name);
            }
        }.inner);
        const window = pageOf(params, matched.items.len, validate.max_page_size) orelse return pageRefusal(arena);
        var out: std.Io.Writer.Allocating = .init(arena);
        var jw: Stringify = .{ .writer = &out.writer };
        write: {
            jw.beginObject() catch break :write;
            if (window.to > window.from) {
                jw.objectField("jobs") catch break :write;
                jw.beginArray() catch break :write;
                for (matched.items[window.from..window.to]) |job| writeJob(&jw, job) catch break :write;
                jw.endArray() catch break :write;
            }
            if (window.next) |n| {
                jw.objectField("nextPageToken") catch break :write;
                jw.print("\"p{d}\"", .{n}) catch break :write;
            }
            jw.endObject() catch break :write;
            return .{ .status = 200, .body = out.written() };
        }
        return error.OutOfMemory;
    }

    /// Production's field order: name, description, the target,
    /// userUpdateTime, state, status (code -1 before any attempt, as a
    /// job is born), scheduleTime, lastAttemptTime, retryConfig,
    /// schedule, timeZone, attemptDeadline; what a job does not have is
    /// left out, as the paused job's scheduleTime was.
    fn writeJob(jw: *Stringify, job: *const FakeJob) Stringify.Error!void {
        var buf: [core.timestamp.max_len]u8 = undefined;
        try jw.beginObject();
        try jw.objectField("name");
        try jw.write(job.name);
        if (job.description.len > 0) {
            try jw.objectField("description");
            try jw.write(job.description);
        }
        switch (job.target) {
            .http => |t| {
                try jw.objectField("httpTarget");
                try jw.beginObject();
                try jw.objectField("uri");
                try jw.write(t.uri);
                if (t.method != .unspecified and t.method != .unknown) {
                    try jw.objectField("httpMethod");
                    try jw.write(methodWire(t.method));
                }
                if (t.headers.len > 0) {
                    try jw.objectField("headers");
                    try writeLabelObject(jw, t.headers);
                }
                try writeBytes(jw, "body", t.body);
                switch (t.auth) {
                    .none => {},
                    .oauth => |o| {
                        try jw.objectField("oauthToken");
                        try jw.beginObject();
                        try jw.objectField("serviceAccountEmail");
                        try jw.write(o.service_account_email);
                        if (o.scope.len > 0) {
                            try jw.objectField("scope");
                            try jw.write(o.scope);
                        }
                        try jw.endObject();
                    },
                    .oidc => |o| {
                        try jw.objectField("oidcToken");
                        try jw.beginObject();
                        try jw.objectField("serviceAccountEmail");
                        try jw.write(o.service_account_email);
                        if (o.audience.len > 0) {
                            try jw.objectField("audience");
                            try jw.write(o.audience);
                        }
                        try jw.endObject();
                    },
                }
                try jw.endObject();
            },
            .pubsub => |t| {
                try jw.objectField("pubsubTarget");
                try jw.beginObject();
                try jw.objectField("topicName");
                try jw.write(t.topic_name);
                try writeBytes(jw, "data", t.data);
                if (t.attributes.len > 0) {
                    try jw.objectField("attributes");
                    try writeLabelObject(jw, t.attributes);
                }
                try jw.endObject();
            },
            .app_engine => |t| {
                try jw.objectField("appEngineHttpTarget");
                try jw.beginObject();
                if (t.relative_uri.len > 0) {
                    try jw.objectField("relativeUri");
                    try jw.write(t.relative_uri);
                }
                if (t.method != .unspecified and t.method != .unknown) {
                    try jw.objectField("httpMethod");
                    try jw.write(methodWire(t.method));
                }
                if (t.headers.len > 0) {
                    try jw.objectField("headers");
                    try writeLabelObject(jw, t.headers);
                }
                try writeBytes(jw, "body", t.body);
                if (t.service.len > 0 or t.version.len > 0 or t.instance.len > 0 or t.host.len > 0) {
                    try jw.objectField("appEngineRouting");
                    try jw.beginObject();
                    inline for (.{ .{ "service", "service" }, .{ "version", "version" }, .{ "instance", "instance" }, .{ "host", "host" } }) |pair| {
                        const value = @field(t, pair[1]);
                        if (value.len > 0) {
                            try jw.objectField(pair[0]);
                            try jw.write(value);
                        }
                    }
                    try jw.endObject();
                }
                try jw.endObject();
            },
            .unknown => {},
        }
        if (job.user_update_time) |t| {
            try jw.objectField("userUpdateTime");
            try jw.write(core.timestamp.format(&buf, t));
        }
        try jw.objectField("state");
        try jw.write(switch (job.state) {
            .enabled => "ENABLED",
            .paused => "PAUSED",
            .disabled => "DISABLED",
            .update_failed => "UPDATE_FAILED",
            else => unreachable,
        });
        try jw.objectField("status");
        try jw.beginObject();
        try jw.objectField("code");
        try jw.print("{d}", .{if (job.last_attempt) |a| a.code else -1});
        if (job.last_attempt) |a| if (a.message.len > 0) {
            try jw.objectField("message");
            try jw.write(a.message);
        };
        try jw.endObject();
        if (job.schedule_time) |t| {
            try jw.objectField("scheduleTime");
            try jw.write(core.timestamp.format(&buf, t));
        }
        if (job.last_attempt_time) |t| {
            try jw.objectField("lastAttemptTime");
            try jw.write(core.timestamp.format(&buf, t));
        }
        if (job.retry) |retry| {
            try jw.objectField("retryConfig");
            try jw.beginObject();
            if (retry.retry_count) |n| {
                try jw.objectField("retryCount");
                try jw.print("{d}", .{n});
            }
            inline for (.{
                .{ "maxRetryDuration", "max_retry_duration_s" },
                .{ "minBackoffDuration", "min_backoff_duration_s" },
                .{ "maxBackoffDuration", "max_backoff_duration_s" },
            }) |pair| {
                if (@field(retry, pair[1])) |seconds| {
                    try jw.objectField(pair[0]);
                    try jw.print("\"{d}s\"", .{seconds});
                }
            }
            if (retry.max_doublings) |n| {
                try jw.objectField("maxDoublings");
                try jw.print("{d}", .{n});
            }
            try jw.endObject();
        }
        try jw.objectField("schedule");
        try jw.write(job.schedule);
        try jw.objectField("timeZone");
        try jw.write(job.time_zone);
        if (job.attempt_deadline_s) |seconds| {
            try jw.objectField("attemptDeadline");
            try jw.print("\"{d}s\"", .{seconds});
        }
        try jw.endObject();
    }

    fn methodWire(method: types.HttpMethod) []const u8 {
        return switch (method) {
            .post => "POST",
            .get => "GET",
            .head => "HEAD",
            .put => "PUT",
            .delete => "DELETE",
            .patch => "PATCH",
            .options => "OPTIONS",
            else => "HTTP_METHOD_UNSPECIFIED",
        };
    }

    fn writeBytes(jw: *Stringify, field_name: []const u8, raw: []const u8) Stringify.Error!void {
        if (raw.len == 0) return;
        var small: [512]u8 = undefined;
        if (std.base64.standard.Encoder.calcSize(raw.len) <= small.len) {
            try jw.objectField(field_name);
            try jw.write(std.base64.standard.Encoder.encode(&small, raw));
        }
    }

    fn writeLabelObject(jw: *Stringify, labels: []const types.Label) Stringify.Error!void {
        try jw.beginObject();
        for (labels) |l| {
            try jw.objectField(l.key);
            try jw.write(l.value);
        }
        try jw.endObject();
    }

    fn lessThan(_: void, a: []const u8, b: []const u8) bool {
        return std.mem.lessThan(u8, a, b);
    }

    // Routes and parameters.

    const Route = struct {
        project: []const u8,
        kind: union(enum) {
            locations,
            jobs: []const u8,
            job: struct { location: []const u8, id: []const u8 },
        },
    };

    fn pathOf(url: []const u8) []const u8 {
        const scheme = std.mem.indexOf(u8, url, "://") orelse return url;
        const rest = url[scheme + 3 ..];
        const slash = std.mem.indexOfScalar(u8, rest, '/') orelse return "/";
        return rest[slash..];
    }

    fn parseRoute(path: []const u8) ?Route {
        const prefix = "/v1/projects/";
        if (!std.mem.startsWith(u8, path, prefix)) return null;
        var parts = std.mem.splitScalar(u8, path[prefix.len..], '/');
        const project = parts.next() orelse return null;
        if (!std.mem.eql(u8, parts.next() orelse return null, "locations")) return null;
        const location = parts.next() orelse return .{ .project = project, .kind = .locations };
        if (!std.mem.eql(u8, parts.next() orelse return null, "jobs")) return null;
        const id = parts.next() orelse return .{ .project = project, .kind = .{ .jobs = location } };
        if (parts.next() != null) return null;
        return .{ .project = project, .kind = .{ .job = .{ .location = location, .id = id } } };
    }

    const Param = struct { name: []const u8, value: []const u8 };

    fn parseParams(arena: Allocator, query: []const u8) Allocator.Error!?[]const Param {
        var list: std.ArrayList(Param) = .empty;
        if (query.len == 0) return list.items;
        var it = std.mem.splitScalar(u8, query, '&');
        while (it.next()) |pair| {
            const eq = std.mem.indexOfScalar(u8, pair, '=') orelse return null;
            const name_copy = try arena.dupe(u8, pair[0..eq]);
            const value_copy = try arena.dupe(u8, pair[eq + 1 ..]);
            try list.append(arena, .{
                .name = std.Uri.percentDecodeInPlace(name_copy),
                .value = std.Uri.percentDecodeInPlace(value_copy),
            });
        }
        return list.items;
    }

    fn paramOf(params: []const Param, name: []const u8) ?[]const u8 {
        for (params) |p| if (std.mem.eql(u8, p.name, name)) return p.value;
        return null;
    }

    const Window = struct { from: usize, to: usize, next: ?usize };

    fn pageOf(params: []const Param, total: usize, max: usize) ?Window {
        var size = max;
        if (paramOf(params, "pageSize")) |text| {
            const n = std.fmt.parseInt(usize, text, 10) catch return null;
            if (n != 0) size = @min(n, max);
        }
        var from: usize = 0;
        if (paramOf(params, "pageToken")) |t| {
            if (!std.mem.startsWith(u8, t, "p")) return null;
            from = std.fmt.parseInt(usize, t[1..], 10) catch return null;
            if (from > total) return null;
        }
        const to = @min(total, from + size);
        return .{ .from = from, .to = to, .next = if (to < total) to else null };
    }

    fn pageRefusal(arena: Allocator) Allocator.Error!Reply {
        return fail(arena, 400, "INVALID_ARGUMENT", "Invalid page token or page size.");
    }

    fn fail(arena: Allocator, code: u16, status: []const u8, message: []const u8) Allocator.Error!Reply {
        return .{ .status = code, .body = try Stringify.valueAlloc(arena, .{ .@"error" = .{
            .code = code,
            .message = message,
            .status = status,
        } }, .{}) };
    }

    fn notModelled(arena: Allocator, what: []const u8) Allocator.Error!Reply {
        return fail(arena, 501, "UNIMPLEMENTED", try arena.print("fake: {s} is not modelled yet", .{what}));
    }

    fn refusal(arena: Allocator, status: u16) Allocator.Error!Reply {
        const name = switch (status) {
            400 => "INVALID_ARGUMENT",
            401 => "UNAUTHENTICATED",
            403 => "PERMISSION_DENIED",
            404 => "NOT_FOUND",
            429 => "RESOURCE_EXHAUSTED",
            500 => "INTERNAL",
            503 => "UNAVAILABLE",
            504 => "DEADLINE_EXCEEDED",
            else => "UNKNOWN",
        };
        return fail(arena, status, name, "fake: refused as the test asked");
    }
};

// Tests, held to what production answered in milestone 0.

const testing = std.testing;
const codec = @import("codec.zig");
const production = @import("production_bodies.zig");
const Client = @import("Client.zig");

const Bench = struct {
    clock: core.testing.FakeClock,
    fake: FakeScheduler,
    token: core.StaticToken,
    diag: core.Diagnostics,
    client: Client,

    fn init(b: *Bench, options: FakeScheduler.Options) !void {
        b.* = .{ .clock = .{}, .fake = undefined, .token = .{ .token = "t" }, .diag = .{}, .client = undefined };
        b.fake = .init(testing.allocator, b.clock.io(), options);
        errdefer b.fake.deinit();
        b.client = try .init(testing.allocator, b.clock.io(), .{
            .project_id = options.project_id,
            .token_provider = b.token.provider(),
            .transport = b.fake.transport(),
            .diagnostics = &b.diag,
            .retry = .{ .max_attempts = 2, .initial_backoff_ms = 1, .max_backoff_ms = 2 },
        });
    }

    fn deinit(b: *Bench) void {
        b.client.deinit();
        b.fake.deinit();
    }

    fn raw(b: *Bench, arena: Allocator, path: []const u8) !FakeScheduler.Reply {
        return b.fake.serve(.{ .method = .GET, .url = path, .bearer = "t" }, arena);
    }
};

/// The probe's failed HTTP job, as `putJob` takes it.
fn probeHttpJob() FakeScheduler.PutJob {
    return .{
        .location = "us-central1",
        .id = "zigps-399f5c-http",
        .schedule = "0 0 1 1 *",
        .time_zone = "UTC",
        .last_attempt = .{ .code = 2 },
        .last_attempt_time = ts("2026-10-19T18:16:55.258042Z"),
        .schedule_time = ts("2027-01-01T00:00:01.652510Z"),
        .user_update_time = ts("2026-10-19T18:16:52.688845Z"),
        .attempt_deadline_s = 180,
        .retry = .{ .retry_count = 1, .max_retry_duration_s = 0, .min_backoff_duration_s = 5, .max_backoff_duration_s = 3600, .max_doublings = 5 },
        .target = .{ .http = .{
            .uri = "https://zigps-399f5c-nowhere.invalid/hook",
            .method = .post,
            .headers = &.{.{ .key = "User-Agent", .value = "Google-Cloud-Scheduler" }},
        } },
    };
}

fn ts(text: []const u8) std.Io.Timestamp {
    return core.timestamp.parse(text) catch unreachable;
}

test "the probe's jobs put in, read back as production answered them" {
    var b: Bench = undefined;
    try b.init(.{ .project_id = "extractctl" });
    defer b.deinit();
    try b.fake.putLocation("us-central1");
    const name = try b.fake.putJob(probeHttpJob());
    try testing.expectEqualStrings("projects/extractctl/locations/us-central1/jobs/zigps-399f5c-http", name);

    // Field for field what production.job_failed_http decodes to.
    var out: std.heap.ArenaAllocator = .init(testing.allocator);
    defer out.deinit();
    var scratch: std.heap.ArenaAllocator = .init(testing.allocator);
    defer scratch.deinit();
    const wanted = try codec.decodeJob(out.allocator(), scratch.allocator(), production.job_failed_http);
    var got = try b.client.getJob("us-central1", "zigps-399f5c-http");
    defer got.deinit();
    try testing.expectEqualStrings(wanted.name, got.value.name);
    try testing.expectEqualStrings(wanted.id, got.value.id);
    try testing.expectEqualStrings(wanted.location, got.value.location);
    try testing.expectEqual(wanted.state, got.value.state);
    try testing.expectEqual(wanted.last_attempt.?.code, got.value.last_attempt.?.code);
    try testing.expectEqual(wanted.last_attempt_time.?.nanoseconds, got.value.last_attempt_time.?.nanoseconds);
    try testing.expectEqual(wanted.schedule_time.?.nanoseconds, got.value.schedule_time.?.nanoseconds);
    try testing.expectEqual(wanted.user_update_time.?.nanoseconds, got.value.user_update_time.?.nanoseconds);
    try testing.expectEqual(wanted.attempt_deadline_s, got.value.attempt_deadline_s);
    try testing.expectEqual(wanted.retry, got.value.retry);
    try testing.expectEqualStrings(wanted.target.http.uri, got.value.target.http.uri);
    try testing.expectEqual(wanted.target.http.method, got.value.target.http.method);
    try testing.expectEqualStrings(wanted.header("User-Agent").?, got.value.header("User-Agent").?);
    try testing.expectEqualStrings(wanted.schedule, got.value.schedule);
    try testing.expectEqualStrings(wanted.time_zone, got.value.time_zone);
    try testing.expect(got.value.failing());

    // By full name too.
    var by_name = try b.client.getJobNamed(name);
    defer by_name.deinit();
    try testing.expectEqualStrings("zigps-399f5c-http", by_name.value.id);
}

test "born, Pub/Sub and paused jobs answer as production did" {
    var b: Bench = undefined;
    try b.init(.{});
    defer b.deinit();
    try b.fake.putLocation("us-central1");

    // Born: no attempt yet, which the fake writes as production's
    // status code -1; the client reads it back as null.
    const born = try b.fake.putJob(.{
        .location = "us-central1",
        .id = "born",
        .schedule_time = ts("2027-01-01T00:00:00Z"),
        .target = .{ .http = .{ .uri = "https://x.invalid/" } },
    });
    var got = try b.client.getJobNamed(born);
    defer got.deinit();
    try testing.expectEqual(null, got.value.last_attempt);
    try testing.expectEqual(null, got.value.last_attempt_time);
    try testing.expect(!got.value.failing());
    // On the wire it is production's sentinel, not an absent field.
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const raw_born = try b.raw(arena.allocator(), "https://host/v1/projects/my-project/locations/us-central1/jobs/born");
    try testing.expectEqual(200, raw_born.status);
    try testing.expect(std.mem.indexOf(u8, raw_born.body, "\"status\":{\"code\":-1}") != null);

    // Scheduler ran it: the attempt arrives, as setLastAttempt stands in
    // for a run.
    try b.fake.setLastAttempt(born, 5, "", ts("2026-10-19T18:17:07.066120Z"));
    var ran = try b.client.getJobNamed(born);
    defer ran.deinit();
    try testing.expectEqual(5, ran.value.last_attempt.?.code);
    try testing.expect(ran.value.failing());

    // A Pub/Sub job without retry settings answers no retry keys, as
    // production did; its data travels as base64.
    _ = try b.fake.putJob(.{
        .location = "us-central1",
        .id = "ps",
        .target = .{ .pubsub = .{ .topic_name = "projects/my-project/topics/t", .data = "zigps", .attributes = &.{.{ .key = "k", .value = "v" }} } },
    });
    var ps = try b.client.getJob("us-central1", "ps");
    defer ps.deinit();
    try testing.expectEqual(types.RetryConfig{}, ps.value.retry);
    try testing.expectEqual(null, ps.value.attempt_deadline_s);
    try testing.expectEqualStrings("zigps", ps.value.target.pubsub.data);
    try testing.expectEqualStrings("v", ps.value.target.pubsub.attributes[0].value);

    // Paused: production removed scheduleTime; the test puts it that way.
    _ = try b.fake.putJob(.{
        .location = "us-central1",
        .id = "paused",
        .state = .paused,
        .target = .{ .http = .{ .uri = "https://x.invalid/", .body = "{\"probe\":true}" } },
    });
    var paused = try b.client.getJob("us-central1", "paused");
    defer paused.deinit();
    try testing.expectEqual(types.JobState.paused, paused.value.state);
    try testing.expectEqual(null, paused.value.schedule_time);
    try testing.expectEqualStrings("{\"probe\":true}", paused.value.target.http.body);

    // An App Engine job round-trips its routing.
    _ = try b.fake.putJob(.{
        .location = "us-central1",
        .id = "gae",
        .target = .{ .app_engine = .{ .relative_uri = "/tick", .method = .get, .service = "worker" } },
    });
    var gae = try b.client.getJob("us-central1", "gae");
    defer gae.deinit();
    try testing.expectEqualStrings("/tick", gae.value.target.app_engine.relative_uri);
    try testing.expectEqualStrings("worker", gae.value.target.app_engine.service);
}

test "locations and jobs list, page and refuse as production did" {
    var b: Bench = undefined;
    try b.init(.{});
    defer b.deinit();
    try b.fake.putLocation("us-east1");
    try b.fake.putLocation("us-central1");
    for ([_][]const u8{ "c", "a", "b" }) |id| {
        _ = try b.fake.putJob(.{ .location = "us-central1", .id = id, .target = .{ .http = .{ .uri = "https://x.invalid/" } } });
    }
    try testing.expectEqual(3, b.fake.jobCount());

    // Locations sort by id; jobs by name, and page with a token.
    var locations = try b.client.listLocations(.{});
    defer locations.deinit();
    try testing.expectEqual(2, locations.value.locations.len);
    try testing.expectEqualStrings("us-central1", locations.value.locations[0].id);
    var page = try b.client.listJobs("us-central1", .{ .page_size = 2 });
    defer page.deinit();
    try testing.expectEqual(2, page.value.jobs.len);
    try testing.expectEqualStrings("a", page.value.jobs[0].id);
    var rest = try b.client.listJobs("us-central1", .{ .page_size = 2, .page_token = page.value.next_page_token.? });
    defer rest.deinit();
    try testing.expectEqual(1, rest.value.jobs.len);
    try testing.expectEqualStrings("c", rest.value.jobs[0].id);
    try testing.expectEqual(null, rest.value.next_page_token);

    // An empty location is production's {}.
    var empty = try b.client.listJobs("us-east1", .{});
    defer empty.deinit();
    try testing.expectEqual(0, empty.value.jobs.len);
    try testing.expectEqual(null, empty.value.next_page_token);

    // Production's words for what it refused.
    try testing.expectError(error.InvalidArgument, b.client.listJobs("us-fake1", .{}));
    try testing.expect(std.mem.indexOf(u8, b.diag.message(), "is not a valid location") != null);
    try testing.expectError(error.NotFound, b.client.getJob("us-central1", "nobody"));
    try testing.expectEqualStrings("Job not found.", b.diag.message());
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const too_big = try b.raw(arena.allocator(), "https://host/v1/projects/my-project/locations/us-central1/jobs?pageSize=501");
    try testing.expectEqual(400, too_big.status);
    try testing.expect(std.mem.indexOf(u8, too_big.body, "must be less than or equal to 500") != null);
    const write = b.fake.serve(.{ .method = .POST, .url = "https://host/v1/projects/my-project/locations/us-central1/jobs", .bearer = "t", .body = "{}" }, arena.allocator());
    try testing.expectEqual(501, (try write).status);
    const bare = b.fake.serve(.{ .method = .GET, .url = "https://host/v1/projects/my-project/locations/us-central1/jobs" }, arena.allocator());
    try testing.expectEqual(401, (try bare).status);
}

test "what putJob, putLocation and setLastAttempt refuse, nothing kept" {
    var b: Bench = undefined;
    try b.init(.{});
    defer b.deinit();
    try b.fake.putLocation("us-central1");
    try testing.expectError(error.InvalidEntry, b.fake.putLocation("us-central1"));
    try testing.expectError(error.InvalidEntry, b.fake.putLocation("US"));
    const base: FakeScheduler.PutJob = .{ .location = "us-central1", .target = .{ .http = .{ .uri = "https://x.invalid/" } } };

    var bad = base;
    bad.location = "nowhere1";
    try testing.expectError(error.InvalidEntry, b.fake.putJob(bad));
    bad = base;
    bad.id = "a/b";
    try testing.expectError(error.InvalidEntry, b.fake.putJob(bad));
    bad = base;
    bad.state = .unspecified;
    try testing.expectError(error.InvalidEntry, b.fake.putJob(bad));
    bad = base;
    bad.last_attempt = .{ .code = 2 };
    try testing.expectError(error.InvalidEntry, b.fake.putJob(bad));
    bad = base;
    bad.last_attempt_time = ts("2026-10-19T18:16:55Z");
    try testing.expectError(error.InvalidEntry, b.fake.putJob(bad));
    bad = base;
    bad.target = .unknown;
    try testing.expectError(error.InvalidEntry, b.fake.putJob(bad));
    try testing.expectEqual(0, b.fake.jobCount());

    bad = base;
    bad.id = "taken";
    _ = try b.fake.putJob(bad);
    try testing.expectError(error.InvalidEntry, b.fake.putJob(bad));
    try testing.expectError(error.InvalidEntry, b.fake.setLastAttempt("projects/my-project/locations/us-central1/jobs/nobody", 2, "", ts("2026-10-19T18:16:55Z")));
    try testing.expectEqual(1, b.fake.jobCount());
}

test "faults on request: dropped, refused and lost answers" {
    var b: Bench = undefined;
    try b.init(.{});
    defer b.deinit();
    try b.fake.putLocation("us-central1");
    _ = try b.fake.putJob(.{ .location = "us-central1", .id = "j", .target = .{ .http = .{ .uri = "https://x.invalid/" } } });

    // A dropped connection is retried and the second try answers.
    b.fake.dropNext(1);
    var got = try b.client.getJob("us-central1", "j");
    got.deinit();
    // A refusal the policy does not retry arrives as its error.
    b.fake.refuseNext(1, 403);
    try testing.expectError(error.PermissionDenied, b.client.getJob("us-central1", "j"));
    // A lost answer: served, then a 500 instead; the retry answers.
    b.fake.loseNext(1, 500);
    var again = try b.client.getJob("us-central1", "j");
    again.deinit();
    try testing.expect(b.fake.callCount() >= 5);
}
