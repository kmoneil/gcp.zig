//! Cloud Scheduler in memory, for tests of code that reads jobs and runs,
//! pauses and resumes them: behind `Client.Options.transport`, it answers
//! the module's three reads as production answered them when measured on
//! 2026-10-19 (issue #245), and its three writes as measured on
//! 2026-10-20 (issue #273).
//!
//! - Locations and jobs are put in by the test: `putLocation`, `putJob`
//!   and `setLastAttempt` stand in for the console or Terraform that made
//!   the jobs and for Scheduler running them on schedule.
//! - A job always answers a `status`: code -1 before any attempt, as
//!   production bears a job with; `{}` for a success, as production
//!   writes code 0; the code otherwise.
//! - A run answers the job as it stood, and its attempt starts then and
//!   shows when the fake's clock has passed `RunOutcome.after_ms`
//!   (production: 3.4 to 14.9 s), with the outcome `setRunOutcome` gave
//!   (success by default). A run while an attempt is still to show adds
//!   none, as two quick runs showed one attempt. A paused job's run is
//!   production's 400.
//! - A pause clears the next run and the last attempt and stamps
//!   `userUpdateTime`; a resume brings back the next run, which the test
//!   gives with `PutJob.schedule_time` or `setNextRun` (the fake has no
//!   cron engine), and stamps it. A repeated pause or resume changes
//!   nothing, as measured.
//! - Production's race, measured: an attempt still to show when its job
//!   is paused shows its start and a next run of that moment, never its
//!   result, and a resume then answers `{}`, a success no one recorded.
//! - Not modelled: the seconds of jitter production adds to the next
//!   run after a job's first attempt; retries of a failed attempt.
//! - Lists sort by name and page as production documents: the default
//!   page is the maximum, 500; a `pageSize` over 500 is production's
//!   400 in its words.
//! - Refused in production's words: a job nobody has (404 "Job not
//!   found."), a location nobody put (400 "Location '<l>' is not a
//!   valid location. Use ListLocations to list valid locations.").
//! - Faults a test asks for: refusals, dropped connections, and a lost
//!   answer.
//!
//! Not modelled, answered 501 with the reason: creates, patches and
//! deletes; a run, pause or resume of a `disabled` or `update_failed`
//! job (no one can put a job in either state on purpose, so production's
//! answer was not measured); operations, CMEK, and another project's
//! paths.

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
        /// The next run production would plan, shown again by a resume.
        planned_run: ?std.Io.Timestamp,
        /// What the job's next run comes to.
        outcome: RunOutcome,
        /// A run's attempt that has started and not yet shown.
        pending: ?Pending,
    };

    const Pending = struct {
        started: std.Io.Timestamp,
        shows: std.Io.Timestamp,
        code: i64,
        message: []const u8,
    };

    /// What a run comes to, as the test says, standing in for the target.
    pub const RunOutcome = struct {
        /// The attempt's gRPC code: 0 for success. Production gave 5 for
        /// an HTTP 404 and a Pub/Sub topic nobody has, 2 for a host that
        /// does not resolve.
        code: i64 = 0,
        /// Production carried none on any attempt measured.
        message: []const u8 = "",
        /// How long after the run the attempt shows, on the fake's clock.
        after_ms: u32 = 0,
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
            .planned_run = job.schedule_time,
            .outcome = .{},
            .pending = null,
        };
        try f.jobs.put(f.gpa, held.name, held);
        return held.name;
    }

    /// What every later run of `name` comes to, until set again.
    /// `error.InvalidEntry` for a name nobody has, or a code outside
    /// gRPC's 0 to 16.
    pub fn setRunOutcome(f: *FakeScheduler, name: []const u8, outcome: RunOutcome) PutError!void {
        f.mutex.lockUncancelable(f.io);
        defer f.mutex.unlock(f.io);
        const job = f.jobs.get(name) orelse return error.InvalidEntry;
        if (outcome.code < 0 or outcome.code > 16) return error.InvalidEntry;
        job.outcome = .{ .code = outcome.code, .message = try f.store.allocator().dupe(u8, outcome.message), .after_ms = outcome.after_ms };
    }

    /// The next run production would plan for `name`, which the fake
    /// cannot compute: shown at once on an enabled job, and by the next
    /// resume on a paused one. `error.InvalidEntry` for a name nobody has.
    pub fn setNextRun(f: *FakeScheduler, name: []const u8, at: ?std.Io.Timestamp) PutError!void {
        f.mutex.lockUncancelable(f.io);
        defer f.mutex.unlock(f.io);
        const job = f.jobs.get(name) orelse return error.InvalidEntry;
        job.planned_run = at;
        if (job.state != .paused) job.schedule_time = at;
    }

    /// Runs' attempts that have started and not yet shown, every job
    /// together.
    pub fn pendingAttempts(f: *FakeScheduler) usize {
        f.mutex.lockUncancelable(f.io);
        defer f.mutex.unlock(f.io);
        var n: usize = 0;
        for (f.jobs.values()) |job| n += @intFromBool(job.pending != null);
        return n;
    }

    fn now(f: *FakeScheduler) std.Io.Timestamp {
        return std.Io.Clock.real.now(f.io);
    }

    /// Shows every attempt whose time has come. Called with the mutex held.
    fn settle(f: *FakeScheduler) void {
        const t = f.now();
        for (f.jobs.values()) |job| {
            const p = job.pending orelse continue;
            if (p.shows.nanoseconds > t.nanoseconds) continue;
            job.pending = null;
            job.last_attempt_time = p.started;
            if (job.state == .paused) {
                // Measured: an attempt that starts on a paused job shows
                // its start and a next run of the same moment, and never
                // its result.
                job.schedule_time = p.started;
            } else {
                job.last_attempt = .{ .code = p.code, .message = p.message };
            }
        }
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
        f.settle();
        if (f.takeFault(drop) != null) return error.ConnectionResetByPeer;
        if (f.takeFault(refuse)) |fault| return refusal(arena, fault.status);
        const lost = f.takeFault(lose);
        const reply = try f.route(req, arena, route_text, query);
        if (lost) |fault| return refusal(arena, fault.status);
        return reply;
    }

    fn route(f: *FakeScheduler, req: tp.Request, arena: Allocator, route_text: []const u8, query: []const u8) Allocator.Error!Reply {
        if (req.bearer == null) return fail(arena, 401, "UNAUTHENTICATED", "Request is missing required authentication credential. Expected OAuth 2 access token, login cookie or other valid authentication credential. See https://developers.google.com/identity/sign-in/web/devconsole-project.");
        const target = parseRoute(route_text) orelse return notModelled(arena, "this path");
        if (!std.mem.eql(u8, target.project, f.options.project_id)) return notModelled(arena, "a project other than the fake's own");
        if (target.kind == .action) {
            if (req.method != .POST) return notModelled(arena, "a run, pause or resume sent as anything but a POST");
            const a = target.kind.action;
            return f.act(arena, a.location, a.id, a.verb orelse return notModelled(arena, "this verb"));
        }
        if (req.method != .GET) return notModelled(arena, "a create, patch or delete");
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
                const job = try f.jobAt(arena, j.location, j.id) orelse return fail(arena, 404, "NOT_FOUND", "Job not found.");
                return jobReply(arena, job);
            },
            .action => unreachable,
        }
    }

    fn jobAt(f: *FakeScheduler, arena: Allocator, location: []const u8, id: []const u8) Allocator.Error!?*FakeJob {
        var name: std.Io.Writer.Allocating = .init(arena);
        name.writer.print("projects/{s}/locations/{s}/jobs/{s}", .{ f.options.project_id, location, id }) catch return error.OutOfMemory;
        return f.jobs.get(name.written());
    }

    fn jobReply(arena: Allocator, job: *const FakeJob) Allocator.Error!Reply {
        var out: std.Io.Writer.Allocating = .init(arena);
        var jw: Stringify = .{ .writer = &out.writer };
        writeJob(&jw, job) catch return error.OutOfMemory;
        return .{ .status = 200, .body = out.written() };
    }

    /// A run, a pause or a resume, as production answered each on
    /// 2026-10-20.
    fn act(f: *FakeScheduler, arena: Allocator, location: []const u8, id: []const u8, verb: Verb) Allocator.Error!Reply {
        if (!f.locations.contains(location)) {
            return fail(arena, 400, "INVALID_ARGUMENT", try arena.print("Location '{s}' is not a valid location. Use ListLocations to list valid locations.", .{location}));
        }
        const job = try f.jobAt(arena, location, id) orelse return fail(arena, 404, "NOT_FOUND", "Job not found.");
        switch (job.state) {
            .disabled, .update_failed => return notModelled(arena, "a run, pause or resume of a disabled or update_failed job (no one can put a job in either state on purpose, so production's answer was not measured)"),
            else => {},
        }
        const t = f.now();
        switch (verb) {
            .run => {
                if (job.state == .paused) {
                    return fail(arena, 400, "FAILED_PRECONDITION", "spanner.RunInTransaction: generic::failed_precondition: Job.state must be ENABLED for RunJob.");
                }
                // The job as it stood: the attempt shows later.
                const reply = try jobReply(arena, job);
                if (job.pending == null) job.pending = .{
                    .started = t,
                    .shows = .{ .nanoseconds = t.nanoseconds + @as(i96, job.outcome.after_ms) * std.time.ns_per_ms },
                    .code = job.outcome.code,
                    .message = job.outcome.message,
                };
                return reply;
            },
            .pause => if (job.state == .enabled) {
                job.state = .paused;
                job.last_attempt = null;
                job.last_attempt_time = null;
                job.schedule_time = null;
                job.user_update_time = t;
            },
            .@"resume" => if (job.state == .paused) {
                job.state = .enabled;
                job.schedule_time = job.planned_run;
                job.user_update_time = t;
                // Measured: a start with no result, as the race leaves,
                // answers `{}` after a resume.
                if (job.last_attempt == null and job.last_attempt_time != null) job.last_attempt = .{ .code = 0, .message = "" };
            },
        }
        return jobReply(arena, job);
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
        const code: i64 = if (job.last_attempt) |a| a.code else -1;
        // Production leaves a success's code out: `{}`.
        if (code != 0) {
            try jw.objectField("code");
            try jw.print("{d}", .{code});
        }
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
            /// `.../jobs/J:verb`; a verb the fake does not know is null.
            action: struct { location: []const u8, id: []const u8, verb: ?Verb },
        },
    };

    const Verb = enum { run, pause, @"resume" };

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
        const segment = parts.next() orelse return .{ .project = project, .kind = .{ .jobs = location } };
        if (parts.next() != null) return null;
        // A custom verb follows the last colon, as Google's paths bind it.
        if (std.mem.lastIndexOfScalar(u8, segment, ':')) |colon| {
            return .{ .project = project, .kind = .{ .action = .{
                .location = location,
                .id = segment[0..colon],
                .verb = std.meta.stringToEnum(Verb, segment[colon + 1 ..]),
            } } };
        }
        return .{ .project = project, .kind = .{ .job = .{ .location = location, .id = segment } } };
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
const test_util = @import("test_util.zig");

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

// The writes, held to what production answered in the writes spec's
// milestone 0 (2026-10-20).

/// An enabled job never attempted, its next run the cron's, as the
/// probe's were made.
fn writableJob(b: *Bench, id: []const u8) ![]const u8 {
    return b.fake.putJob(.{
        .location = "us-central1",
        .id = id,
        .schedule = "0 0 1 1 *",
        .schedule_time = ts("2027-01-01T00:00:00Z"),
        .user_update_time = ts("2026-10-20T17:06:43.737881Z"),
        .target = .{ .http = .{ .uri = "https://www.gstatic.com/generate_204", .method = .get } },
    });
}

fn decoded(arena: *std.heap.ArenaAllocator, body: []const u8) !types.Job {
    var scratch: std.heap.ArenaAllocator = .init(testing.allocator);
    defer scratch.deinit();
    return codec.decodeJob(arena.allocator(), scratch.allocator(), body);
}

/// The fields a write moves, which the fake must answer as production's
/// body does (times aside, which belong to the probe's run).
fn expectShape(wanted: types.Job, got: types.Job) !void {
    try testing.expectEqual(wanted.state, got.state);
    try testing.expectEqual(wanted.last_attempt == null, got.last_attempt == null);
    if (wanted.last_attempt) |a| try testing.expectEqual(a.code, got.last_attempt.?.code);
    try testing.expectEqual(wanted.last_attempt_time == null, got.last_attempt_time == null);
    try testing.expectEqual(wanted.schedule_time == null, got.schedule_time == null);
    try testing.expectEqual(wanted.user_update_time == null, got.user_update_time == null);
}

test "a run answers the job as it stood, and its attempt shows when the clock passes after_ms" {
    var b: Bench = undefined;
    try b.init(.{});
    defer b.deinit();
    try b.fake.putLocation("us-central1");
    const name = try writableJob(&b, "nf");
    const sent = ts("2026-10-20T17:07:20Z");
    b.clock.now_ns = sent.nanoseconds;
    try b.fake.setRunOutcome(name, .{ .code = 5, .after_ms = 6000 });

    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    var ran = try b.client.runJob("us-central1", "nf");
    defer ran.deinit();
    try expectShape(try decoded(&arena, production.job_run_answer), ran.value);
    try testing.expectEqual(ts("2026-10-20T17:06:43.737881Z").nanoseconds, ran.value.user_update_time.?.nanoseconds);
    try testing.expectEqual(1, b.fake.pendingAttempts());

    b.clock.now_ns += 5 * std.time.ns_per_s;
    var early = try b.client.getJob("us-central1", "nf");
    defer early.deinit();
    try testing.expectEqual(null, early.value.last_attempt);

    b.clock.now_ns += 1 * std.time.ns_per_s;
    var shown = try b.client.getJob("us-central1", "nf");
    defer shown.deinit();
    try testing.expectEqual(5, shown.value.last_attempt.?.code);
    try testing.expectEqual(sent.nanoseconds, shown.value.last_attempt_time.?.nanoseconds);
    try testing.expect(shown.value.failing());
    try testing.expectEqual(0, b.fake.pendingAttempts());
    // A run touches neither the update time nor the next run.
    try testing.expectEqual(ts("2026-10-20T17:06:43.737881Z").nanoseconds, shown.value.user_update_time.?.nanoseconds);
    try testing.expectEqual(ts("2027-01-01T00:00:00Z").nanoseconds, shown.value.schedule_time.?.nanoseconds);
}

test "a success shows as production writes it, an empty status" {
    var b: Bench = undefined;
    try b.init(.{});
    defer b.deinit();
    try b.fake.putLocation("us-central1");
    _ = try writableJob(&b, "ok");
    b.clock.now_ns = ts("2026-10-20T17:06:51Z").nanoseconds;
    var ran = try b.client.runJob("us-central1", "ok");
    ran.deinit();

    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const raw = try b.raw(arena.allocator(), "https://host/v1/projects/my-project/locations/us-central1/jobs/ok");
    try testing.expect(std.mem.indexOf(u8, raw.body, "\"status\":{}") != null);
    var got = try b.client.getJob("us-central1", "ok");
    defer got.deinit();
    try expectShape(try decoded(&arena, production.job_succeeded), got.value);
    try testing.expect(!got.value.failing());
}

test "a run while an attempt is still to show adds none, as two quick runs showed one" {
    var b: Bench = undefined;
    try b.init(.{});
    defer b.deinit();
    try b.fake.putLocation("us-central1");
    const name = try writableJob(&b, "twice");
    try b.fake.setRunOutcome(name, .{ .code = 2, .after_ms = 5000 });
    const first = ts("2026-10-20T17:13:10Z");
    b.clock.now_ns = first.nanoseconds;
    var one = try b.client.runJob("us-central1", "twice");
    one.deinit();
    b.clock.now_ns += 3 * std.time.ns_per_s;
    var two = try b.client.runJob("us-central1", "twice");
    two.deinit();
    try testing.expectEqual(1, b.fake.pendingAttempts());
    b.clock.now_ns += 30 * std.time.ns_per_s;
    var got = try b.client.getJob("us-central1", "twice");
    defer got.deinit();
    try testing.expectEqual(first.nanoseconds, got.value.last_attempt_time.?.nanoseconds);
    try testing.expectEqual(0, b.fake.pendingAttempts());
}

test "a paused job's run is refused in production's words, and nothing starts" {
    var b: Bench = undefined;
    try b.init(.{});
    defer b.deinit();
    try b.fake.putLocation("us-central1");
    _ = try b.fake.putJob(.{ .location = "us-central1", .id = "p", .state = .paused, .target = .{ .http = .{ .uri = "https://x.invalid/" } } });
    try testing.expectError(error.FailedPrecondition, b.client.runJob("us-central1", "p"));
    try testing.expectEqualStrings("spanner.RunInTransaction: generic::failed_precondition: Job.state must be ENABLED for RunJob.", b.diag.message());
    try testing.expectEqual(0, b.fake.pendingAttempts());
}

test "pause and resume answer as production did, and a repeat changes nothing" {
    var b: Bench = undefined;
    try b.init(.{});
    defer b.deinit();
    try b.fake.putLocation("us-central1");
    const name = try writableJob(&b, "nf2");
    try b.fake.setLastAttempt(name, 5, "", ts("2026-10-20T17:12:23.621983Z"));
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();

    // A resume of an enabled job: nothing moves, the failed code kept.
    b.clock.now_ns = ts("2026-10-20T17:12:20Z").nanoseconds;
    var noop = try b.client.resumeJob("us-central1", "nf2");
    defer noop.deinit();
    try testing.expectEqual(5, noop.value.last_attempt.?.code);
    try testing.expectEqual(ts("2026-10-20T17:06:43.737881Z").nanoseconds, noop.value.user_update_time.?.nanoseconds);

    const paused_at = ts("2026-10-20T17:12:44.388152Z");
    b.clock.now_ns = paused_at.nanoseconds;
    var p = try b.client.pauseJob("us-central1", "nf2");
    defer p.deinit();
    try expectShape(try decoded(&arena, production.job_pause_answer), p.value);
    try testing.expectEqual(paused_at.nanoseconds, p.value.user_update_time.?.nanoseconds);

    b.clock.now_ns += 11 * std.time.ns_per_s;
    var again = try b.client.pauseJob("us-central1", "nf2");
    defer again.deinit();
    try testing.expectEqual(paused_at.nanoseconds, again.value.user_update_time.?.nanoseconds);

    const resumed_at = ts("2026-10-20T17:12:55.812309Z");
    b.clock.now_ns = resumed_at.nanoseconds;
    var r = try b.client.resumeJob("us-central1", "nf2");
    defer r.deinit();
    try expectShape(try decoded(&arena, production.job_resume_answer), r.value);
    try testing.expectEqual(resumed_at.nanoseconds, r.value.user_update_time.?.nanoseconds);
    try testing.expectEqual(ts("2027-01-01T00:00:00Z").nanoseconds, r.value.schedule_time.?.nanoseconds);
}

test "production's race: an attempt still to show when its job is paused" {
    var b: Bench = undefined;
    try b.init(.{});
    defer b.deinit();
    try b.fake.putLocation("us-central1");
    const name = try writableJob(&b, "nf");
    try b.fake.setRunOutcome(name, .{ .code = 5, .after_ms = 2000 });
    const run_at = ts("2026-10-20T17:10:22.900000Z");
    b.clock.now_ns = run_at.nanoseconds;
    var ran = try b.client.runJob("us-central1", "nf");
    ran.deinit();
    b.clock.now_ns += 700 * std.time.ns_per_ms;
    var p = try b.client.pauseJob("us-central1", "nf");
    p.deinit();

    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    b.clock.now_ns += 2 * std.time.ns_per_s;
    var mid = try b.client.getJob("us-central1", "nf");
    defer mid.deinit();
    try expectShape(try decoded(&arena, production.job_paused_mid_run), mid.value);
    try testing.expectEqual(run_at.nanoseconds, mid.value.last_attempt_time.?.nanoseconds);
    try testing.expectEqual(run_at.nanoseconds, mid.value.schedule_time.?.nanoseconds);

    var r = try b.client.resumeJob("us-central1", "nf");
    defer r.deinit();
    try expectShape(try decoded(&arena, production.job_resumed_mid_run), r.value);
    // The success no one recorded.
    try testing.expectEqual(0, r.value.last_attempt.?.code);
    try testing.expect(!r.value.failing());
}

test "setNextRun: shown at once on an enabled job, by the resume on a paused one" {
    var b: Bench = undefined;
    try b.init(.{});
    defer b.deinit();
    try b.fake.putLocation("us-central1");
    const name = try writableJob(&b, "n");
    try b.fake.setNextRun(name, ts("2026-10-21T03:00:00Z"));
    var got = try b.client.getJob("us-central1", "n");
    got.deinit();
    var p = try b.client.pauseJob("us-central1", "n");
    p.deinit();
    try b.fake.setNextRun(name, ts("2026-10-22T03:00:00Z"));
    var still = try b.client.getJob("us-central1", "n");
    defer still.deinit();
    try testing.expectEqual(null, still.value.schedule_time);
    var r = try b.client.resumeJob("us-central1", "n");
    defer r.deinit();
    try testing.expectEqual(ts("2026-10-22T03:00:00Z").nanoseconds, r.value.schedule_time.?.nanoseconds);
    try b.fake.setNextRun(name, null);
    var none = try b.client.getJob("us-central1", "n");
    defer none.deinit();
    try testing.expectEqual(null, none.value.schedule_time);
}

test "writes refused: nobody's job and location in production's words, the unmeasured states 501" {
    var b: Bench = undefined;
    try b.init(.{});
    defer b.deinit();
    try b.fake.putLocation("us-central1");
    for ([_]types.JobState{ .disabled, .update_failed }) |state| {
        _ = try b.fake.putJob(.{ .location = "us-central1", .id = @tagName(state), .state = state, .target = .{ .http = .{ .uri = "https://x.invalid/" } } });
    }
    const Write = *const fn (*Client, []const u8, []const u8) @import("errors.zig").Error!types.Owned(types.Job);
    for ([_]Write{ &Client.runJob, &Client.pauseJob, &Client.resumeJob }) |write| {
        try testing.expectError(error.NotFound, write(&b.client, "us-central1", "nobody"));
        try testing.expectEqualStrings("Job not found.", b.diag.message());
        try testing.expectError(error.InvalidArgument, write(&b.client, "us-fake1", "nobody"));
        try testing.expectEqualStrings("Location 'us-fake1' is not a valid location. Use ListLocations to list valid locations.", b.diag.message());
        for ([_][]const u8{ "disabled", "update_failed" }) |id| {
            try testing.expectError(error.Unimplemented, write(&b.client, "us-central1", id));
            try testing.expect(std.mem.indexOf(u8, b.diag.message(), "production's answer was not measured") != null);
        }
    }
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const url = "https://host/v1/projects/my-project/locations/us-central1/jobs/disabled";
    try testing.expectEqual(501, (try b.fake.serve(.{ .method = .POST, .url = url ++ ":delete", .bearer = "t", .body = "{}" }, a)).status);
    // A run sent as a GET, on a job that could run: refused, nothing
    // started.
    _ = try writableJob(&b, "enabled");
    const get_run = try b.fake.serve(.{ .method = .GET, .url = "https://host/v1/projects/my-project/locations/us-central1/jobs/enabled:run", .bearer = "t" }, a);
    try testing.expectEqual(501, get_run.status);
    try testing.expect(std.mem.indexOf(u8, get_run.body, "anything but a POST") != null);
    try testing.expectEqual(0, b.fake.pendingAttempts());
    try testing.expectEqual(501, (try b.fake.serve(.{ .method = .PATCH, .url = url, .bearer = "t", .body = "{}" }, a)).status);
    try testing.expectEqual(401, (try b.fake.serve(.{ .method = .POST, .url = url ++ ":run", .body = "{}" }, a)).status);
}

test "what setRunOutcome and setNextRun refuse" {
    var b: Bench = undefined;
    try b.init(.{});
    defer b.deinit();
    try b.fake.putLocation("us-central1");
    const name = try writableJob(&b, "j");
    const nobody = "projects/my-project/locations/us-central1/jobs/nobody";
    try testing.expectError(error.InvalidEntry, b.fake.setRunOutcome(nobody, .{}));
    try testing.expectError(error.InvalidEntry, b.fake.setNextRun(nobody, null));
    try testing.expectError(error.InvalidEntry, b.fake.setRunOutcome(name, .{ .code = -1 }));
    try testing.expectError(error.InvalidEntry, b.fake.setRunOutcome(name, .{ .code = 17 }));
    try b.fake.setRunOutcome(name, .{ .code = 16, .message = "kept" });
    b.clock.now_ns = ts("2026-10-20T17:00:00Z").nanoseconds;
    var ran = try b.client.runJob("us-central1", "j");
    ran.deinit();
    var got = try b.client.getJob("us-central1", "j");
    defer got.deinit();
    try testing.expectEqual(16, got.value.last_attempt.?.code);
    try testing.expectEqualStrings("kept", got.value.last_attempt.?.message);
}

test "faults on writes: a dropped run is not resent, a lost pause answer is retried" {
    var b: Bench = undefined;
    try b.init(.{});
    defer b.deinit();
    try b.fake.putLocation("us-central1");
    _ = try writableJob(&b, "j");
    b.clock.now_ns = ts("2026-10-20T17:00:00Z").nanoseconds;
    b.fake.dropNext(1);
    try testing.expectError(error.ConnectionResetByPeer, b.client.runJob("us-central1", "j"));
    try testing.expectEqual(1, b.fake.callCount());
    try testing.expectEqual(0, b.fake.pendingAttempts());

    // Served, then lost: the retry answers the paused job, unchanged.
    b.fake.loseNext(1, 503);
    var p = try b.client.pauseJob("us-central1", "j");
    defer p.deinit();
    try testing.expectEqual(types.JobState.paused, p.value.state);
    try testing.expectEqual(ts("2026-10-20T17:00:00Z").nanoseconds, p.value.user_update_time.?.nanoseconds);
    try testing.expectEqual(3, b.fake.callCount());
}

/// What the property holds the fake to: one job's state as production
/// moves it, written apart from the fake.
const WriteModel = struct {
    state: types.JobState,
    code: ?i64,
    attempt_ns: ?i96,
    schedule_ns: ?i96,
    planned_ns: ?i96,
    update_ns: ?i96,
    outcome_code: i64 = 0,
    outcome_after_ms: u32 = 0,
    pending: ?struct { started: i96, shows: i96, code: i64 } = null,

    fn settle(m: *WriteModel, now_ns: i96) void {
        const p = m.pending orelse return;
        if (p.shows > now_ns) return;
        m.pending = null;
        m.attempt_ns = p.started;
        switch (m.state) {
            .paused => m.schedule_ns = p.started,
            else => m.code = p.code,
        }
    }

    fn expectJob(m: WriteModel, got: types.Job) !void {
        try testing.expectEqual(m.state, got.state);
        try testing.expectEqual(m.code, if (got.last_attempt) |a| a.code else null);
        try testing.expectEqual(m.attempt_ns, if (got.last_attempt_time) |t| t.nanoseconds else null);
        try testing.expectEqual(m.schedule_ns, if (got.schedule_time) |t| t.nanoseconds else null);
        try testing.expectEqual(m.update_ns, if (got.user_update_time) |t| t.nanoseconds else null);
    }
};

fn writesProperty(_: void, input: []const u8) !void {
    const gpa = test_util.propertyAllocator();
    var g: test_util.ByteGen = .init(input);
    var clock: core.testing.FakeClock = .{ .now_ns = ts("2026-10-20T17:00:00Z").nanoseconds };
    var fake: FakeScheduler = .init(gpa, clock.io(), .{});
    defer fake.deinit();
    var token: core.StaticToken = .{ .token = "t" };
    var diag: core.Diagnostics = .{};
    var client = try Client.init(gpa, clock.io(), .{ .project_id = "my-project", .token_provider = token.provider(), .transport = fake.transport(), .diagnostics = &diag });
    defer client.deinit();
    try fake.putLocation("us-central1");

    const next_run = ts("2027-01-01T00:00:00Z").nanoseconds;
    var m: WriteModel = .{
        .state = if (g.boolean()) .enabled else .paused,
        .code = null,
        .attempt_ns = null,
        .schedule_ns = null,
        .planned_ns = next_run,
        .update_ns = ts("2026-10-20T16:00:00Z").nanoseconds,
    };
    m.schedule_ns = if (m.state == .enabled) next_run else null;
    if (g.boolean()) {
        m.code = g.pick(i64, &.{ 0, 2, 5 });
        m.attempt_ns = ts("2026-10-20T16:30:00Z").nanoseconds;
    }
    const name = try fake.putJob(.{
        .location = "us-central1",
        .id = "j",
        .state = m.state,
        .last_attempt = if (m.code) |c| .{ .code = c } else null,
        .last_attempt_time = if (m.attempt_ns) |t| .{ .nanoseconds = t } else null,
        .schedule_time = if (m.schedule_ns) |t| .{ .nanoseconds = t } else null,
        .user_update_time = .{ .nanoseconds = m.update_ns.? },
        .target = .{ .http = .{ .uri = "https://x.invalid/" } },
    });
    // A paused job put in keeps its next run for the resume only if the
    // test sets it; the model starts both the same way.
    if (m.state == .paused) try fake.setNextRun(name, .{ .nanoseconds = next_run });

    const steps = g.intRange(usize, 0, 40);
    for (0..steps) |_| {
        switch (g.intRange(u8, 0, 6)) {
            0 => {
                m.settle(clock.now_ns);
                if (m.state == .paused) {
                    try testing.expectError(error.FailedPrecondition, client.runJob("us-central1", "j"));
                } else {
                    var ran = try client.runJob("us-central1", "j");
                    defer ran.deinit();
                    try m.expectJob(ran.value);
                    if (m.pending == null) m.pending = .{
                        .started = clock.now_ns,
                        .shows = clock.now_ns + @as(i96, m.outcome_after_ms) * std.time.ns_per_ms,
                        .code = m.outcome_code,
                    };
                }
            },
            1 => {
                m.settle(clock.now_ns);
                if (m.state == .enabled) {
                    m.state = .paused;
                    m.code = null;
                    m.attempt_ns = null;
                    m.schedule_ns = null;
                    m.update_ns = clock.now_ns;
                }
                var p = try client.pauseJob("us-central1", "j");
                defer p.deinit();
                try m.expectJob(p.value);
            },
            2 => {
                m.settle(clock.now_ns);
                if (m.state == .paused) {
                    m.state = .enabled;
                    m.schedule_ns = m.planned_ns;
                    m.update_ns = clock.now_ns;
                    if (m.code == null and m.attempt_ns != null) m.code = 0;
                }
                var r = try client.resumeJob("us-central1", "j");
                defer r.deinit();
                try m.expectJob(r.value);
            },
            3 => {
                m.settle(clock.now_ns);
                var got = try client.getJob("us-central1", "j");
                defer got.deinit();
                try m.expectJob(got.value);
            },
            4 => clock.now_ns += @as(i96, g.intRange(u32, 0, 20_000)) * std.time.ns_per_ms,
            5 => {
                m.outcome_code = g.pick(i64, &.{ 0, 2, 4, 5, 13 });
                m.outcome_after_ms = g.intRange(u32, 0, 15_000);
                try fake.setRunOutcome(name, .{ .code = m.outcome_code, .after_ms = m.outcome_after_ms });
            },
            else => {
                const at: ?i96 = if (g.boolean()) next_run + @as(i96, g.intRange(u32, 0, 86_400)) * std.time.ns_per_s else null;
                m.planned_ns = at;
                if (m.state != .paused) m.schedule_ns = at;
                try fake.setNextRun(name, if (at) |t| .{ .nanoseconds = t } else null);
            },
        }
        try testing.expectEqual(@intFromBool(m.pending != null), fake.pendingAttempts());
    }
}

test "slow property writes: any sequence of runs, pauses, resumes and clock steps moves the job as production does" {
    try test_util.fuzzBytes({}, writesProperty, .{
        .corpus = &.{
            // Run, pause before it shows, step past it, resume: the race.
            "\x00\x05\x00\x00\x00\x00\x00\x00\x01\x04\xff\x03\x02",
            // Run twice, step, read.
            "\x01\x00\x00\x00\x04\x80\x03",
            "",
        },
    });
}
