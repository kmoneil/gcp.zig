//! Dataflow in memory, for tests of code that reads jobs and stops them:
//! behind `Client.Options.transport`, it answers the module's reads, its
//! cancel and its drain as production answered them when measured on
//! 2026-10-20.
//!
//! - Locations, jobs, messages and autoscaling events are put in by the
//!   test: nothing here launches a job, so `putLocation`, `putJob`,
//!   `setJobState`, `putMessage` and `putAutoscalingEvent` stand in for
//!   whoever launched the pipeline, and for the service moving it along.
//! - A cancel taken makes a running or draining job `cancelling` with
//!   `requestedState` CANCELLED at once; a drain taken makes a running
//!   streaming job `draining` with DRAINED. Each adds production's line
//!   to the job's story ("Cancel request is committed for workflow job:
//!   <id>.", a repeat cancel another, a repeat drain none) and answers
//!   production's one field, `{"type":"JOB_TYPE_BATCH"}`, whatever the
//!   job. The end state is the test's to set with `setJobState`, as the
//!   service would (production took 240 s to end a cancel, 126 s a
//!   drain); a terminal state takes `requestedState` away.
//! - The writes' refusals, in production's words minus its request ids:
//!   a pending job's cancel ("not yet ready for canceling"), a batch
//!   job's drain in any state, an ended job's cancel naming its end
//!   state and its drain ("Job has terminated."), and a job nobody has
//!   ("Could not cancel workflow; ..."). A location nobody put reaches
//!   the default location's job, as a made-up region did in production.
//!   A write production's answer to was not measured is 501, naming it:
//!   a drain of a pending or cancelling streaming job, a cancel of an
//!   updated job, and either on a job in a state a template launch
//!   cannot reach (queued, pausing, paused, stopped, cleaning up).
//! - The aggregated list serves every location's jobs; the per-location
//!   list serves its own, and only it honors the `name` filter: the
//!   aggregated list accepts and ignores one, as production does. Lists
//!   answer summaries, without labels, stage states or `requestedState`,
//!   which only a get carries, as production answered them.
//! - A location nobody put is served by the default location's backend
//!   rather than refused: production answered a made-up region with
//!   us-central1's jobs, on a get and on a list.
//! - Filters order as production answered: terminated jobs newest
//!   termination first, active ones newest creation first, active before
//!   terminated under ALL or no filter; `ACTIVE` with nothing running is
//!   a bare `{}`.
//! - Messages sort by time, oldest first, filtered by the minimum
//!   importance; the autoscaling events come regardless of the filter,
//!   and `pageSize` is not honored here, exactly as production answered
//!   (every message came back past a pageSize of 5).
//! - Refused in production's words, minus the request id production
//!   prefixes: a job nobody has is 404 "Information about job <id>
//!   could not be found in our system. ..."; a filter outside the enum
//!   is 400 INVALID_ARGUMENT; a get at JOB_VIEW_ALL of a job put in
//!   with a `provisioning_error` is 400 FAILED_PRECONDITION carrying
//!   that text, as production answered the job that failed its launch.
//! - Faults a test asks for: refusals, dropped connections, and a lost
//!   answer.
//!
//! Not modelled, answered 501 with the reason: every other write
//! (creating, updating with a mask, pausing, launching templates),
//! metrics, snapshots, the legacy no-location paths, and another
//! project's paths.

const std = @import("std");
const Allocator = std.mem.Allocator;
const Stringify = std.json.Stringify;
const core = @import("core");
const tp = core.transport;
const types = @import("types.zig");
const validate = @import("validate.zig");

pub const FakeDataflow = struct {
    gpa: Allocator,
    io: std.Io,
    mutex: std.Io.Mutex = .init,
    options: Options,
    /// Strings and resources, freed with the fake.
    store: std.heap.ArenaAllocator,
    /// Location ids, in the order put in.
    locations: std.StringArrayHashMapUnmanaged(void) = .empty,
    /// By id, in the order put in.
    jobs: std.StringArrayHashMapUnmanaged(*FakeJob) = .empty,
    /// What list answers name as `failedLocation` on the aggregated
    /// list, standing in for a regional backend that did not answer.
    failed_locations: []const []const u8 = &.{},
    faults: [3]Fault = .{ .{}, .{}, .{} },
    calls: usize = 0,

    const Fault = struct { n: usize = 0, status: u16 = 0 };
    const refuse = 0;
    const drop = 1;
    const lose = 2;

    pub const Options = struct {
        /// The project it answers for, by id.
        project_id: []const u8 = "my-project",
        /// Where a location nobody put is served, as production routes
        /// a made-up region (measured 2026-10-20).
        default_location: []const u8 = "us-central1",
    };

    pub const Reply = struct { status: u16, headers: []const tp.Header = &.{}, body: []const u8 };

    const FakeJob = struct {
        id: []const u8,
        name: []const u8,
        location: []const u8,
        type: types.JobType,
        current_state: types.JobState,
        current_state_time: ?std.Io.Timestamp,
        requested_state: types.JobState,
        create_time: ?std.Io.Timestamp,
        start_time: ?std.Io.Timestamp,
        labels: []const types.Label,
        stage_states: []const types.StageState,
        provisioning_error: ?[]const u8,
        messages: std.ArrayList(FakeMessage) = .empty,
        events: std.ArrayList(FakeEvent) = .empty,
    };

    const FakeMessage = struct {
        id: []const u8,
        time: ?std.Io.Timestamp,
        text: []const u8,
        importance: types.MessageImportance,
    };

    const FakeEvent = struct {
        event_type: []const u8,
        time: ?std.Io.Timestamp,
        description: []const u8,
        current_num_workers: ?i64,
        target_num_workers: ?i64,
        worker_pool: []const u8,
    };

    pub fn init(gpa: Allocator, io: std.Io, options: Options) FakeDataflow {
        return .{ .gpa = gpa, .io = io, .options = options, .store = .init(gpa) };
    }

    pub fn deinit(f: *FakeDataflow) void {
        for (f.jobs.values()) |job| {
            job.messages.deinit(f.gpa);
            job.events.deinit(f.gpa);
        }
        f.locations.deinit(f.gpa);
        f.jobs.deinit(f.gpa);
        f.store.deinit();
        f.* = undefined;
    }

    /// Goes into `Client.Options.transport`.
    pub fn transport(f: *FakeDataflow) tp.Transport {
        return .{ .ptr = f, .vtable = &.{ .send = send } };
    }

    // Faults, each for the next `n` calls.

    /// Answers them with `status`, and changes nothing.
    pub fn refuseNext(f: *FakeDataflow, n: usize, status: u16) void {
        f.setFault(refuse, .{ .n = n, .status = status });
    }

    /// Closes their connection before any answer.
    pub fn dropNext(f: *FakeDataflow, n: usize) void {
        f.setFault(drop, .{ .n = n });
    }

    /// Serves them and answers `status` instead of what was read.
    pub fn loseNext(f: *FakeDataflow, n: usize, status: u16) void {
        f.setFault(lose, .{ .n = n, .status = status });
    }

    fn setFault(f: *FakeDataflow, slot: usize, fault: Fault) void {
        f.mutex.lockUncancelable(f.io);
        defer f.mutex.unlock(f.io);
        f.faults[slot] = fault;
    }

    fn takeFault(f: *FakeDataflow, slot: usize) ?Fault {
        const fault = &f.faults[slot];
        if (fault.n == 0) return null;
        fault.n -= 1;
        return fault.*;
    }

    // What a test reads.

    /// Calls served, refusals included.
    pub fn callCount(f: *FakeDataflow) usize {
        f.mutex.lockUncancelable(f.io);
        defer f.mutex.unlock(f.io);
        return f.calls;
    }

    /// Jobs held, every location together.
    pub fn jobCount(f: *FakeDataflow) usize {
        f.mutex.lockUncancelable(f.io);
        defer f.mutex.unlock(f.io);
        return f.jobs.count();
    }

    // What a test puts in.

    pub const PutError = error{ OutOfMemory, InvalidEntry };

    /// A location jobs can run in, such as "us-central1".
    pub fn putLocation(f: *FakeDataflow, id: []const u8) PutError!void {
        f.mutex.lockUncancelable(f.io);
        defer f.mutex.unlock(f.io);
        if (!validate.isLocation(id)) return error.InvalidEntry;
        if (f.locations.contains(id)) return error.InvalidEntry;
        try f.locations.put(f.gpa, try f.store.allocator().dupe(u8, id), {});
    }

    /// What the aggregated list names as the regions that did not
    /// answer, so a test can see its widget say so.
    pub fn setFailedLocations(f: *FakeDataflow, regions: []const []const u8) PutError!void {
        f.mutex.lockUncancelable(f.io);
        defer f.mutex.unlock(f.io);
        const s = f.store.allocator();
        const copy = try s.alloc([]const u8, regions.len);
        for (regions, copy) |region, *out| out.* = try s.dupe(u8, region);
        f.failed_locations = copy;
    }

    /// A job as a test puts one in, standing in for whoever launched
    /// it. Everything `types.Job` reads back can be set.
    pub const PutJob = struct {
        /// Must be put with `putLocation` first.
        location: []const u8,
        /// The service assigns these in production
        /// (`2026-10-20_07_11_01-168295...`); the test's choice here.
        id: []const u8,
        name: []const u8 = "",
        type: types.JobType = .batch,
        current_state: types.JobState = .pending,
        current_state_time: ?std.Io.Timestamp = null,
        requested_state: types.JobState = .unspecified,
        create_time: ?std.Io.Timestamp = null,
        start_time: ?std.Io.Timestamp = null,
        labels: []const types.Label = &.{},
        stage_states: []const types.StageState = &.{},
        /// Set, the job answers a get at JOB_VIEW_ALL with a 400
        /// FAILED_PRECONDITION carrying this text, as production
        /// answered the job that failed its launch.
        provisioning_error: ?[]const u8 = null,
    };

    /// Puts a job in and returns its id, owned by the fake.
    ///
    /// `error.InvalidEntry`, with nothing kept, for: a location nobody
    /// put; an id taken or malformed; a name production's regex would
    /// refuse on an active job of the same name (names are not checked
    /// here: production enforces them at creation, which the fake does
    /// not model).
    pub fn putJob(f: *FakeDataflow, job: PutJob) PutError![]const u8 {
        f.mutex.lockUncancelable(f.io);
        defer f.mutex.unlock(f.io);
        if (!f.locations.contains(job.location)) return error.InvalidEntry;
        if (!validate.isJobId(job.id)) return error.InvalidEntry;
        if (f.jobs.contains(job.id)) return error.InvalidEntry;
        const s = f.store.allocator();
        const held = try s.create(FakeJob);
        held.* = .{
            .id = try s.dupe(u8, job.id),
            .name = try s.dupe(u8, job.name),
            .location = try s.dupe(u8, job.location),
            .type = job.type,
            .current_state = job.current_state,
            .current_state_time = job.current_state_time,
            .requested_state = job.requested_state,
            .create_time = job.create_time,
            .start_time = job.start_time,
            .labels = try dupeLabels(s, job.labels),
            .stage_states = try dupeStages(s, job.stage_states),
            .provisioning_error = if (job.provisioning_error) |text| try s.dupe(u8, text) else null,
        };
        try f.jobs.put(f.gpa, held.id, held);
        return held.id;
    }

    /// Moves a job along, as the service does: PENDING to RUNNING to
    /// DONE, or a cancel's CANCELLING on to CANCELLED. A terminal state
    /// takes away `requestedState`, as production's ended jobs carried
    /// none.
    pub fn setJobState(f: *FakeDataflow, id: []const u8, state: types.JobState, at: ?std.Io.Timestamp) PutError!void {
        f.mutex.lockUncancelable(f.io);
        defer f.mutex.unlock(f.io);
        const job = f.jobs.get(id) orelse return error.InvalidEntry;
        job.current_state = state;
        if (state.terminal()) job.requested_state = .unspecified;
        if (at) |t| job.current_state_time = t;
    }

    pub const PutMessage = struct {
        /// The job must be put first.
        job: []const u8,
        id: []const u8 = "",
        time: ?std.Io.Timestamp = null,
        text: []const u8,
        importance: types.MessageImportance = .basic,
    };

    /// A line of a job's story, as whoever ran it would have left it.
    pub fn putMessage(f: *FakeDataflow, message: PutMessage) PutError!void {
        f.mutex.lockUncancelable(f.io);
        defer f.mutex.unlock(f.io);
        const job = f.jobs.get(message.job) orelse return error.InvalidEntry;
        const s = f.store.allocator();
        try job.messages.append(f.gpa, .{
            .id = try s.dupe(u8, message.id),
            .time = message.time,
            .text = try s.dupe(u8, message.text),
            .importance = message.importance,
        });
    }

    pub const PutEvent = struct {
        /// The job must be put first.
        job: []const u8,
        event_type: []const u8 = "TARGET_NUM_WORKERS_CHANGED",
        time: ?std.Io.Timestamp = null,
        description: []const u8 = "",
        current_num_workers: ?i64 = null,
        target_num_workers: ?i64 = null,
        worker_pool: []const u8 = "",
    };

    /// A worker-count change, answered regardless of the importance
    /// filter, as production answers them.
    pub fn putAutoscalingEvent(f: *FakeDataflow, event: PutEvent) PutError!void {
        f.mutex.lockUncancelable(f.io);
        defer f.mutex.unlock(f.io);
        const job = f.jobs.get(event.job) orelse return error.InvalidEntry;
        const s = f.store.allocator();
        try job.events.append(f.gpa, .{
            .event_type = try s.dupe(u8, event.event_type),
            .time = event.time,
            .description = try s.dupe(u8, event.description),
            .current_num_workers = event.current_num_workers,
            .target_num_workers = event.target_num_workers,
            .worker_pool = try s.dupe(u8, event.worker_pool),
        });
    }

    fn dupeLabels(s: Allocator, labels: []const types.Label) Allocator.Error![]const types.Label {
        const out = try s.alloc(types.Label, labels.len);
        for (labels, out) |l, *o| o.* = .{ .key = try s.dupe(u8, l.key), .value = try s.dupe(u8, l.value) };
        return out;
    }

    fn dupeStages(s: Allocator, stages: []const types.StageState) Allocator.Error![]const types.StageState {
        const out = try s.alloc(types.StageState, stages.len);
        for (stages, out) |stage, *o| o.* = .{
            .stage = try s.dupe(u8, stage.stage),
            .state = stage.state,
            .current_state_time = stage.current_state_time,
        };
        return out;
    }

    // The transport.

    fn send(ptr: *anyopaque, req: tp.Request, arena: Allocator) tp.Error!tp.Response {
        const f: *FakeDataflow = @ptrCast(@alignCast(ptr));
        const reply = try f.serve(req, arena);
        return .{ .status = reply.status, .headers = reply.headers, .body = reply.body };
    }

    /// One request, as `send` serves it: for a test that wants to send
    /// what no client would.
    pub fn serve(f: *FakeDataflow, req: tp.Request, arena: Allocator) tp.Error!Reply {
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

    fn route(f: *FakeDataflow, req: tp.Request, arena: Allocator, route_text: []const u8, query: []const u8) Allocator.Error!Reply {
        if (req.bearer == null) return fail(arena, 401, "UNAUTHENTICATED", "Request is missing required authentication credential. Expected OAuth 2 access token, login cookie or other valid authentication credential. See https://developers.google.com/identity/sign-in/web/devconsole-project.");
        if (req.method != .GET and req.method != .PUT) return notModelled(arena, "anything but a read, a cancel or a drain");
        const target = parseRoute(route_text) orelse return notModelled(arena, "this path");
        if (!std.mem.eql(u8, target.project, f.options.project_id)) return notModelled(arena, "a project other than the fake's own");
        const params = try parseParams(arena, query) orelse return fail(arena, 400, "INVALID_ARGUMENT", "Invalid query string.");
        if (req.method == .PUT) switch (target.kind) {
            .job => |job| return f.stop(arena, job.location, job.id, params, req.body orelse ""),
            else => return notModelled(arena, "a write other than a cancel or a drain"),
        };
        switch (target.kind) {
            .aggregated => return f.listJobs(arena, null, params, true),
            .jobs => |location| return f.listJobs(arena, f.resolve(location), params, false),
            .job => |job| {
                const held = f.find(f.resolve(job.location), job.id) orelse return unknownJob(arena, job.id);
                if (paramOf(params, "view")) |view| {
                    if (std.mem.eql(u8, view, "JOB_VIEW_ALL")) if (held.provisioning_error) |text| {
                        return fail(arena, 400, "FAILED_PRECONDITION", text);
                    };
                }
                var out: std.Io.Writer.Allocating = .init(arena);
                var jw: Stringify = .{ .writer = &out.writer };
                writeJob(f, &jw, held, true) catch return error.OutOfMemory;
                return .{ .status = 200, .body = out.written() };
            },
            .messages => |job| {
                const held = f.find(f.resolve(job.location), job.id) orelse return unknownJob(arena, job.id);
                return f.listMessages(arena, held, params);
            },
        }
    }

    const Stop = enum { cancel, drain };

    /// A cancel or a drain, as production answered them on 2026-10-20:
    /// the refusals first, in the order production checks (the job, then
    /// a drain's job type, then the state), then the change, a message
    /// in the job's story, and production's one-field answer, which says
    /// batch whatever the job is.
    fn stop(f: *FakeDataflow, arena: Allocator, location: []const u8, id: []const u8, params: []const Param, body: []const u8) Allocator.Error!Reply {
        if (params.len > 0) return notModelled(arena, "an update with an update mask or other parameters");
        const which = stopOf(arena, body) orelse return notModelled(arena, "an update other than a requested state of cancelled or drained alone");
        const held = f.find(f.resolve(location), id) orelse return fail(arena, 404, "NOT_FOUND", try arena.print("Could not cancel workflow; user does not have sufficient permissions on project: {s}, or the job does not exist in the project.", .{f.options.project_id}));
        if (which == .drain and held.type != .streaming) {
            return fail(arena, 400, "INVALID_ARGUMENT", try arena.print("Job {s} is not a streaming workflow. Only streaming workflows can be drained.", .{held.id}));
        }
        if (held.current_state.terminal()) return ended(arena, which, held);
        switch (held.current_state) {
            .running, .draining => {},
            .pending => {
                if (which == .drain) return unmeasured(arena, "a drain of a pending streaming job");
                return fail(arena, 400, "FAILED_PRECONDITION", try arena.print("Workflow modification failed. Causes: Operation cancel not allowed for job {s}. Job is not yet ready for canceling. Please retry in a few minutes.", .{held.id}));
            },
            .cancelling => if (which == .drain) return unmeasured(arena, "a drain of a cancelling streaming job"),
            else => return unmeasured(arena, "a write to a job in this state, which a template launch cannot put it in"),
        }
        const now = std.Io.Clock.real.now(f.io);
        switch (which) {
            // Taken while running or draining; a repeat while cancelling
            // changes nothing but adds its line to the story, as
            // production's did.
            .cancel => {
                if (held.current_state != .cancelling) {
                    held.current_state = .cancelling;
                    held.current_state_time = now;
                }
                held.requested_state = .cancelled;
                try f.committed(held, "Cancel", now);
            },
            // A repeat while draining changes nothing and adds no line.
            .drain => if (held.current_state == .running) {
                held.current_state = .draining;
                held.current_state_time = now;
                held.requested_state = .drained;
                try f.committed(held, "Drain", now);
            },
        }
        return .{ .status = 200, .body = "{\"type\":\"JOB_TYPE_BATCH\"}" };
    }

    /// The write a body asks for, when it is a requested state of
    /// cancelled or drained and nothing else.
    fn stopOf(arena: Allocator, body: []const u8) ?Stop {
        const value = std.json.parseFromSliceLeaky(std.json.Value, arena, body, .{}) catch return null;
        if (value != .object or value.object.count() != 1) return null;
        const state = value.object.get("requestedState") orelse return null;
        if (state != .string) return null;
        if (std.mem.eql(u8, state.string, "JOB_STATE_CANCELLED")) return .cancel;
        if (std.mem.eql(u8, state.string, "JOB_STATE_DRAINED")) return .drain;
        return null;
    }

    /// An ended job's refusal: a cancel names the state it ended in, a
    /// drain only that it has ended.
    fn ended(arena: Allocator, which: Stop, job: *const FakeJob) Allocator.Error!Reply {
        if (which == .drain) {
            return fail(arena, 400, "FAILED_PRECONDITION", try arena.print("Workflow modification failed. Causes: Cannot perform operation 'drain' on Job: {s}. Job has terminated.", .{job.id}));
        }
        const state: []const u8, const how: []const u8 = switch (job.current_state) {
            .done => .{ "SUCCESS", "succeeded" },
            .cancelled => .{ "CANCELLED", "cancelled" },
            .drained => .{ "DRAINED", "was drained" },
            .failed => if (job.provisioning_error != null) .{ "NOT_STARTED", "failed to start" } else .{ "FAILED", "failed" },
            else => return unmeasured(arena, "a cancel of an updated job"),
        };
        return fail(arena, 400, "FAILED_PRECONDITION", try arena.print("Workflow modification failed. Causes: Cannot perform operation 'cancel' on Job: {s}. Job has terminated in state {s}: Workflow job: {s} {s}.", .{ job.id, state, job.id, how }));
    }

    /// The line production adds to a job's story when it takes a write,
    /// at BASIC, its id the time in milliseconds as production's were.
    fn committed(f: *FakeDataflow, job: *FakeJob, verb: []const u8, now: std.Io.Timestamp) Allocator.Error!void {
        const s = f.store.allocator();
        try job.messages.append(f.gpa, .{
            .id = try std.fmt.allocPrint(s, "{d}", .{@divFloor(now.nanoseconds, std.time.ns_per_ms)}),
            .time = now,
            .text = try std.fmt.allocPrint(s, "{s} request is committed for workflow job: {s}.", .{ verb, job.id }),
            .importance = .basic,
        });
    }

    /// What production would answer cannot be said: no one measured it.
    fn unmeasured(arena: Allocator, what: []const u8) Allocator.Error!Reply {
        return fail(arena, 501, "UNIMPLEMENTED", try arena.print("fake: production's answer to {s} was not measured", .{what}));
    }

    /// A location nobody put is served by the default location, as
    /// production served us-fake1 with us-central1's jobs.
    fn resolve(f: *FakeDataflow, location: []const u8) []const u8 {
        if (f.locations.contains(location)) return location;
        return f.options.default_location;
    }

    fn find(f: *FakeDataflow, location: []const u8, id: []const u8) ?*FakeJob {
        const job = f.jobs.get(id) orelse return null;
        if (!std.mem.eql(u8, job.location, location)) return null;
        return job;
    }

    fn unknownJob(arena: Allocator, id: []const u8) Allocator.Error!Reply {
        return fail(arena, 404, "NOT_FOUND", try arena.print("Information about job {s} could not be found in our system. Please double check that the API being used is projects.locations.jobs.get (https://cloud.google.com/dataflow/docs/reference/rest/v1b3/projects.locations.jobs/get). If the API being used is projects.locations.jobs.get, please double check the id ({s}) is correct. If it is please contact customer support.", .{ id, id }));
    }

    const ListKind = enum { unknown, all, terminated, active };

    fn listJobs(f: *FakeDataflow, arena: Allocator, location: ?[]const u8, params: []const Param, aggregated: bool) Allocator.Error!Reply {
        var kind: ListKind = .unknown;
        if (paramOf(params, "filter")) |text| {
            if (std.mem.eql(u8, text, "ALL")) {
                kind = .all;
            } else if (std.mem.eql(u8, text, "TERMINATED")) {
                kind = .terminated;
            } else if (std.mem.eql(u8, text, "ACTIVE")) {
                kind = .active;
            } else if (!std.mem.eql(u8, text, "UNKNOWN")) {
                return fail(arena, 400, "INVALID_ARGUMENT", try arena.print("Invalid value at 'filter' (type.googleapis.com/google.dataflow.v1beta3.ListJobsRequest.Filter), \"{s}\"", .{text}));
            }
        }
        // Only the per-location list filters by name; the aggregated
        // one accepts and ignores it, as production does.
        const name = if (aggregated) null else paramOf(params, "name");
        var matched: std.ArrayList(*FakeJob) = .empty;
        for (f.jobs.values()) |job| {
            if (location) |l| if (!std.mem.eql(u8, job.location, l)) continue;
            if (name) |n| if (!std.mem.eql(u8, job.name, n)) continue;
            const terminal = job.current_state.terminal();
            switch (kind) {
                .terminated => if (!terminal) continue,
                .active => if (terminal) continue,
                .unknown, .all => {},
            }
            try matched.append(arena, job);
        }
        // Active jobs first by newest creation, then terminated ones by
        // newest termination, as production ordered the lists.
        std.mem.sort(*FakeJob, matched.items, {}, struct {
            fn inner(_: void, a: *FakeJob, b: *FakeJob) bool {
                const a_terminal = a.current_state.terminal();
                const b_terminal = b.current_state.terminal();
                if (a_terminal != b_terminal) return b_terminal;
                const a_at: i96 = if (a_terminal)
                    (if (a.current_state_time) |t| t.nanoseconds else 0)
                else
                    (if (a.create_time) |t| t.nanoseconds else 0);
                const b_at: i96 = if (b_terminal)
                    (if (b.current_state_time) |t| t.nanoseconds else 0)
                else
                    (if (b.create_time) |t| t.nanoseconds else 0);
                if (a_at != b_at) return a_at > b_at;
                return std.mem.lessThan(u8, a.id, b.id);
            }
        }.inner);
        const window = pageOf(params, matched.items.len, 1000) orelse return pageRefusal(arena);
        var out: std.Io.Writer.Allocating = .init(arena);
        var jw: Stringify = .{ .writer = &out.writer };
        write: {
            jw.beginObject() catch break :write;
            if (window.to > window.from) {
                jw.objectField("jobs") catch break :write;
                jw.beginArray() catch break :write;
                for (matched.items[window.from..window.to]) |job| writeJob(f, &jw, job, false) catch break :write;
                jw.endArray() catch break :write;
            }
            if (window.next) |n| {
                jw.objectField("nextPageToken") catch break :write;
                jw.print("\"p{d}\"", .{n}) catch break :write;
            }
            if (aggregated and f.failed_locations.len > 0) {
                jw.objectField("failedLocation") catch break :write;
                jw.beginArray() catch break :write;
                for (f.failed_locations) |region| {
                    jw.beginObject() catch break :write;
                    jw.objectField("name") catch break :write;
                    jw.write(region) catch break :write;
                    jw.endObject() catch break :write;
                }
                jw.endArray() catch break :write;
            }
            jw.endObject() catch break :write;
            return .{ .status = 200, .body = out.written() };
        }
        return error.OutOfMemory;
    }

    fn listMessages(f: *FakeDataflow, arena: Allocator, job: *FakeJob, params: []const Param) Allocator.Error!Reply {
        _ = f;
        var min: types.MessageImportance = .unspecified;
        if (paramOf(params, "minimumImportance")) |text| {
            min = types.MessageImportance.fromWire(text);
            if (min == .unknown) return fail(arena, 400, "INVALID_ARGUMENT", try arena.print("Invalid value at 'minimum_importance' (type.googleapis.com/google.dataflow.v1beta3.ListJobMessagesRequest.JobMessageImportance), \"{s}\"", .{text}));
        }
        var matched: std.ArrayList(*const FakeMessage) = .empty;
        for (job.messages.items) |*message| {
            if (!message.importance.atLeast(min)) continue;
            try matched.append(arena, message);
        }
        // Oldest first, as production answered the story; pageSize is
        // not honored, exactly as production answered every message
        // past a pageSize of 5.
        std.mem.sort(*const FakeMessage, matched.items, {}, struct {
            fn inner(_: void, a: *const FakeMessage, b: *const FakeMessage) bool {
                const a_at: i96 = if (a.time) |t| t.nanoseconds else 0;
                const b_at: i96 = if (b.time) |t| t.nanoseconds else 0;
                if (a_at != b_at) return a_at < b_at;
                return std.mem.lessThan(u8, a.id, b.id);
            }
        }.inner);
        var buf: [core.timestamp.max_len]u8 = undefined;
        var out: std.Io.Writer.Allocating = .init(arena);
        var jw: Stringify = .{ .writer = &out.writer };
        write: {
            jw.beginObject() catch break :write;
            if (matched.items.len > 0) {
                jw.objectField("jobMessages") catch break :write;
                jw.beginArray() catch break :write;
                for (matched.items) |message| {
                    jw.beginObject() catch break :write;
                    if (message.id.len > 0) {
                        jw.objectField("id") catch break :write;
                        jw.write(message.id) catch break :write;
                    }
                    if (message.time) |t| {
                        jw.objectField("time") catch break :write;
                        jw.write(core.timestamp.format(&buf, t)) catch break :write;
                    }
                    jw.objectField("messageText") catch break :write;
                    jw.write(message.text) catch break :write;
                    jw.objectField("messageImportance") catch break :write;
                    jw.write(message.importance.toWire()) catch break :write;
                    jw.endObject() catch break :write;
                }
                jw.endArray() catch break :write;
            }
            if (job.events.items.len > 0) {
                jw.objectField("autoscalingEvents") catch break :write;
                jw.beginArray() catch break :write;
                for (job.events.items) |event| {
                    jw.beginObject() catch break :write;
                    if (event.description.len > 0) {
                        jw.objectField("description") catch break :write;
                        jw.beginObject() catch break :write;
                        jw.objectField("messageText") catch break :write;
                        jw.write(event.description) catch break :write;
                        jw.endObject() catch break :write;
                    }
                    jw.objectField("eventType") catch break :write;
                    jw.write(event.event_type) catch break :write;
                    if (event.current_num_workers) |n| {
                        jw.objectField("currentNumWorkers") catch break :write;
                        jw.print("\"{d}\"", .{n}) catch break :write;
                    }
                    if (event.target_num_workers) |n| {
                        jw.objectField("targetNumWorkers") catch break :write;
                        jw.print("\"{d}\"", .{n}) catch break :write;
                    }
                    if (event.time) |t| {
                        jw.objectField("time") catch break :write;
                        jw.write(core.timestamp.format(&buf, t)) catch break :write;
                    }
                    if (event.worker_pool.len > 0) {
                        jw.objectField("workerPool") catch break :write;
                        jw.write(event.worker_pool) catch break :write;
                    }
                    jw.endObject() catch break :write;
                }
                jw.endArray() catch break :write;
            }
            jw.endObject() catch break :write;
            return .{ .status = 200, .body = out.written() };
        }
        return error.OutOfMemory;
    }

    /// `full` is a get's answer; a list's is the summary, without
    /// labels or stage states, as production answered them.
    fn writeJob(f: *FakeDataflow, jw: *Stringify, job: *const FakeJob, full: bool) Stringify.Error!void {
        var buf: [core.timestamp.max_len]u8 = undefined;
        try jw.beginObject();
        if (job.create_time) |t| {
            try jw.objectField("createTime");
            try jw.write(core.timestamp.format(&buf, t));
        }
        if (job.current_state != .unspecified) {
            try jw.objectField("currentState");
            try jw.write(stateWire(job.current_state));
        }
        if (job.current_state_time) |t| {
            try jw.objectField("currentStateTime");
            try jw.write(core.timestamp.format(&buf, t));
        }
        try jw.objectField("id");
        try jw.write(job.id);
        if (full and job.labels.len > 0) {
            try jw.objectField("labels");
            try jw.beginObject();
            for (job.labels) |l| {
                try jw.objectField(l.key);
                try jw.write(l.value);
            }
            try jw.endObject();
        }
        try jw.objectField("location");
        try jw.write(job.location);
        if (job.name.len > 0) {
            try jw.objectField("name");
            try jw.write(job.name);
        }
        try jw.objectField("projectId");
        try jw.write(f.options.project_id);
        // A get carries it; a list's summary never did (measured).
        if (full and job.requested_state != .unspecified) {
            try jw.objectField("requestedState");
            try jw.write(stateWire(job.requested_state));
        }
        if (full and job.stage_states.len > 0) {
            try jw.objectField("stageStates");
            try jw.beginArray();
            for (job.stage_states) |stage| {
                try jw.beginObject();
                if (stage.current_state_time) |t| {
                    try jw.objectField("currentStateTime");
                    try jw.write(core.timestamp.format(&buf, t));
                }
                if (stage.stage.len > 0) {
                    try jw.objectField("executionStageName");
                    try jw.write(stage.stage);
                }
                try jw.objectField("executionStageState");
                try jw.write(stateWire(stage.state));
                try jw.endObject();
            }
            try jw.endArray();
        }
        if (job.start_time) |t| {
            try jw.objectField("startTime");
            try jw.write(core.timestamp.format(&buf, t));
        }
        if (job.type != .unspecified) {
            try jw.objectField("type");
            try jw.write(switch (job.type) {
                .batch => "JOB_TYPE_BATCH",
                .streaming => "JOB_TYPE_STREAMING",
                else => "JOB_TYPE_UNKNOWN",
            });
        }
        try jw.endObject();
    }

    fn stateWire(state: types.JobState) []const u8 {
        return switch (state) {
            .stopped => "JOB_STATE_STOPPED",
            .running => "JOB_STATE_RUNNING",
            .done => "JOB_STATE_DONE",
            .failed => "JOB_STATE_FAILED",
            .cancelled => "JOB_STATE_CANCELLED",
            .updated => "JOB_STATE_UPDATED",
            .draining => "JOB_STATE_DRAINING",
            .drained => "JOB_STATE_DRAINED",
            .pending => "JOB_STATE_PENDING",
            .cancelling => "JOB_STATE_CANCELLING",
            .queued => "JOB_STATE_QUEUED",
            .resource_cleaning_up => "JOB_STATE_RESOURCE_CLEANING_UP",
            .pausing => "JOB_STATE_PAUSING",
            .paused => "JOB_STATE_PAUSED",
            .unspecified, .unknown => "JOB_STATE_UNKNOWN",
        };
    }

    // Routes and parameters.

    const Route = struct {
        project: []const u8,
        kind: union(enum) {
            aggregated,
            jobs: []const u8,
            job: struct { location: []const u8, id: []const u8 },
            messages: struct { location: []const u8, id: []const u8 },
        },
    };

    fn pathOf(url: []const u8) []const u8 {
        const scheme = std.mem.indexOf(u8, url, "://") orelse return url;
        const rest = url[scheme + 3 ..];
        const slash = std.mem.indexOfScalar(u8, rest, '/') orelse return "/";
        return rest[slash..];
    }

    fn parseRoute(path: []const u8) ?Route {
        if (!std.mem.startsWith(u8, path, "/v1b3/projects/")) return null;
        var parts = std.mem.splitScalar(u8, path["/v1b3/projects/".len..], '/');
        const project = parts.next() orelse return null;
        const next = parts.next() orelse return null;
        if (std.mem.eql(u8, next, "jobs:aggregated")) {
            if (parts.next() != null) return null;
            return .{ .project = project, .kind = .aggregated };
        }
        if (!std.mem.eql(u8, next, "locations")) return null;
        const location = parts.next() orelse return null;
        if (!std.mem.eql(u8, parts.next() orelse return null, "jobs")) return null;
        const id = parts.next() orelse return .{ .project = project, .kind = .{ .jobs = location } };
        const messages_word = parts.next() orelse return .{ .project = project, .kind = .{ .job = .{ .location = location, .id = id } } };
        if (!std.mem.eql(u8, messages_word, "messages")) return null;
        if (parts.next() != null) return null;
        return .{ .project = project, .kind = .{ .messages = .{ .location = location, .id = id } } };
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
    fake: FakeDataflow,
    token: core.StaticToken,
    diag: core.Diagnostics,
    client: Client,

    fn init(b: *Bench, options: FakeDataflow.Options) !void {
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

    fn raw(b: *Bench, arena: Allocator, method: tp.Method, path: []const u8) !FakeDataflow.Reply {
        return b.fake.serve(.{ .method = method, .url = path, .bearer = "t" }, arena);
    }
};

fn ts(text: []const u8) std.Io.Timestamp {
    return core.timestamp.parse(text) catch unreachable;
}

/// The probe's two jobs, as production answered them after the second
/// run: the DONE Word_Count and the one that failed its launch.
fn seedProbe(fake: *FakeDataflow) !void {
    try fake.putLocation("us-central1");
    _ = try fake.putJob(.{
        .location = "us-central1",
        .id = "2026-10-20_07_11_01-16829577348630633066",
        .name = "zigps-df-05461",
        .type = .batch,
        .current_state = .done,
        .current_state_time = ts("2026-10-20T14:15:21.374384Z"),
        .create_time = ts("2026-10-20T14:11:02.242566Z"),
        .start_time = ts("2026-10-20T14:11:02.242566Z"),
        .labels = &.{
            .{ .key = "goog-dataflow-provided-template-name", .value = "word_count" },
            .{ .key = "goog-dataflow-provided-template-type", .value = "legacy" },
        },
        .stage_states = &.{
            .{ .stage = "F10", .state = .done, .current_state_time = ts("2026-10-20T14:15:00Z") },
        },
    });
    _ = try fake.putJob(.{
        .location = "us-central1",
        .id = "2026-10-20_07_09_34-8524524531325271694",
        .name = "zigps-df-05373",
        .type = .batch,
        .current_state = .failed,
        .current_state_time = ts("2026-10-20T14:09:37.893665Z"),
        .create_time = ts("2026-10-20T14:09:35.414298Z"),
        .start_time = ts("2026-10-20T14:09:35.414298Z"),
        .provisioning_error = "The Dataflow service agent cannot access the worker service account. Ensure that the Dataflow API is enabled for your project.",
    });
    try fake.putMessage(.{
        .job = "2026-10-20_07_09_34-8524524531325271694",
        .id = "1792505377894",
        .time = ts("2026-10-20T14:09:37.893Z"),
        .text = "The Dataflow service agent cannot access the worker service account. Ensure that the Dataflow API is enabled for your project.",
        .importance = .@"error",
    });
    try fake.putAutoscalingEvent(.{
        .job = "2026-10-20_07_11_01-16829577348630633066",
        .time = ts("2026-10-20T14:11:24.731653Z"),
        .description = "Starting a pool of 1 workers.",
        .target_num_workers = 1,
        .worker_pool = "Regular",
    });
}

test "the probe's jobs put in, read back as production answered them" {
    var b: Bench = undefined;
    try b.init(.{ .project_id = "extractctl" });
    defer b.deinit();
    try seedProbe(&b.fake);
    try testing.expectEqual(2, b.fake.jobCount());

    // Field for field what production's DONE get decodes to, for
    // everything the fake's put covers.
    var out: std.heap.ArenaAllocator = .init(testing.allocator);
    defer out.deinit();
    var scratch: std.heap.ArenaAllocator = .init(testing.allocator);
    defer scratch.deinit();
    const wanted = try codec.decodeJob(out.allocator(), scratch.allocator(), production.job_done);
    var got = try b.client.getJob("us-central1", "2026-10-20_07_11_01-16829577348630633066");
    defer got.deinit();
    try testing.expectEqualStrings(wanted.id, got.value.id);
    try testing.expectEqualStrings(wanted.name, got.value.name);
    try testing.expectEqualStrings(wanted.location, got.value.location);
    try testing.expectEqual(wanted.type, got.value.type);
    try testing.expectEqual(wanted.current_state, got.value.current_state);
    try testing.expectEqual(wanted.terminal(), got.value.terminal());
    try testing.expectEqual(wanted.failing(), got.value.failing());
    try testing.expectEqualStrings(wanted.label("goog-dataflow-provided-template-name").?, got.value.label("goog-dataflow-provided-template-name").?);

    // Both lists: the DONE job terminated last, so it comes first, in
    // the region and across every region.
    var listed = try b.client.listJobs("us-central1", .{});
    defer listed.deinit();
    try testing.expectEqual(2, listed.value.jobs.len);
    try testing.expectEqualStrings("zigps-df-05461", listed.value.jobs[0].name);
    try testing.expectEqualStrings("zigps-df-05373", listed.value.jobs[1].name);
    // Summaries, as production lists them: the labels and stage states
    // come only with a get.
    try testing.expectEqual(0, listed.value.jobs[0].labels.len);
    try testing.expectEqual(0, listed.value.jobs[0].stage_states.len);
    try testing.expect(got.value.stage_states.len > 0);
    var everywhere = try b.client.aggregatedJobs(.{ .filter = .all });
    defer everywhere.deinit();
    try testing.expectEqual(2, everywhere.value.jobs.len);
    try testing.expectEqualStrings("us-central1", everywhere.value.jobs[0].location);

    // The name filter, and ACTIVE with nothing running: a bare {}.
    var named = try b.client.listJobs("us-central1", .{ .name = "zigps-df-05461" });
    defer named.deinit();
    try testing.expectEqual(1, named.value.jobs.len);
    var active = try b.client.listJobs("us-central1", .{ .filter = .active });
    defer active.deinit();
    try testing.expectEqual(0, active.value.jobs.len);
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const raw_active = try b.raw(arena.allocator(), .GET, "https://host/v1b3/projects/extractctl/locations/us-central1/jobs?filter=ACTIVE");
    try testing.expectEqualStrings("{}", raw_active.body);

    // The story: the failed job's error, and the DONE job's autoscaling
    // events coming regardless of the ERROR filter.
    try b.fake.putMessage(.{ .job = "2026-10-20_07_09_34-8524524531325271694", .id = "2", .time = ts("2026-10-20T14:09:39Z"), .text = "Worker pool stopped.", .importance = .basic });
    var red = try b.client.listMessages("us-central1", "2026-10-20_07_09_34-8524524531325271694", .{ .minimum_importance = .@"error" });
    defer red.deinit();
    try testing.expectEqual(1, red.value.messages.len);
    try testing.expect(std.mem.indexOf(u8, red.value.messages[0].text, "service agent") != null);
    // pageSize is not honored on messages, as production answered every
    // message past a pageSize of 5: both come back, oldest first.
    var story = try b.client.listMessages("us-central1", "2026-10-20_07_09_34-8524524531325271694", .{ .page_size = 1 });
    defer story.deinit();
    try testing.expectEqual(2, story.value.messages.len);
    try testing.expect(std.mem.indexOf(u8, story.value.messages[0].text, "service agent") != null);
    try testing.expectEqualStrings("Worker pool stopped.", story.value.messages[1].text);
    var quiet = try b.client.listMessages("us-central1", "2026-10-20_07_11_01-16829577348630633066", .{ .minimum_importance = .@"error" });
    defer quiet.deinit();
    try testing.expectEqual(0, quiet.value.messages.len);
    try testing.expectEqual(1, quiet.value.autoscaling_events.len);
    try testing.expectEqual(1, quiet.value.autoscaling_events[0].target_num_workers.?);

    // A get at JOB_VIEW_ALL of the job that failed its launch: 400
    // FAILED_PRECONDITION carrying the job's own error, as production
    // answered; the plain get still answers the job.
    try testing.expectError(error.FailedPrecondition, b.client.getJobView("us-central1", "2026-10-20_07_09_34-8524524531325271694", .all));
    try testing.expect(std.mem.indexOf(u8, b.diag.message(), "service agent") != null);
    var plain = try b.client.getJob("us-central1", "2026-10-20_07_09_34-8524524531325271694");
    defer plain.deinit();
    try testing.expect(plain.value.failing());
}

test "locations resolve as production routes them, pages walk, refusals in production's words" {
    var b: Bench = undefined;
    try b.init(.{});
    defer b.deinit();
    try b.fake.putLocation("us-central1");
    try b.fake.putLocation("europe-west1");
    try b.fake.setFailedLocations(&.{"asia-east1"});
    _ = try b.fake.putJob(.{ .location = "us-central1", .id = "j-a", .name = "a", .current_state = .running, .create_time = ts("2026-10-20T10:00:00Z") });
    _ = try b.fake.putJob(.{ .location = "us-central1", .id = "j-b", .name = "b", .current_state = .done, .current_state_time = ts("2026-10-20T11:00:00Z") });
    _ = try b.fake.putJob(.{ .location = "europe-west1", .id = "j-c", .name = "c", .current_state = .running, .create_time = ts("2026-10-20T12:00:00Z") });

    // Per location, and the aggregated list with its failed locations.
    var central = try b.client.listJobs("us-central1", .{});
    defer central.deinit();
    try testing.expectEqual(2, central.value.jobs.len);
    try testing.expectEqualStrings("j-a", central.value.jobs[0].id);
    var everywhere = try b.client.aggregatedJobs(.{});
    defer everywhere.deinit();
    try testing.expectEqual(3, everywhere.value.jobs.len);
    try testing.expectEqualStrings("j-c", everywhere.value.jobs[0].id);
    try testing.expectEqual(1, everywhere.value.failed_locations.len);
    try testing.expectEqualStrings("asia-east1", everywhere.value.failed_locations[0]);

    // Pages walk with a token; TERMINATED and ACTIVE split the jobs.
    var page = try b.client.aggregatedJobs(.{ .page_size = 2 });
    defer page.deinit();
    try testing.expectEqual(2, page.value.jobs.len);
    var rest = try b.client.aggregatedJobs(.{ .page_size = 2, .page_token = page.value.next_page_token.? });
    defer rest.deinit();
    try testing.expectEqual(1, rest.value.jobs.len);
    try testing.expectEqual(null, rest.value.next_page_token);
    var terminated = try b.client.listJobs("us-central1", .{ .filter = .terminated });
    defer terminated.deinit();
    try testing.expectEqual(1, terminated.value.jobs.len);
    try testing.expectEqualStrings("j-b", terminated.value.jobs[0].id);

    // The aggregated list accepts and ignores a name, as production
    // does: no client call sends one, so raw.
    var scratch: std.heap.ArenaAllocator = .init(testing.allocator);
    defer scratch.deinit();
    const raw_aggregated = try b.raw(scratch.allocator(), .GET, "https://host/v1b3/projects/my-project/jobs:aggregated?name=a");
    try testing.expectEqual(200, raw_aggregated.status);
    try testing.expectEqual(3, std.mem.count(u8, raw_aggregated.body, "\"id\":"));

    // A location nobody put is served by the default location, as
    // production answered us-fake1 with us-central1's jobs.
    var faked = try b.client.listJobs("us-fake1", .{});
    defer faked.deinit();
    try testing.expectEqual(2, faked.value.jobs.len);
    var got = try b.client.getJob("us-fake1", "j-a");
    defer got.deinit();
    try testing.expectEqualStrings("us-central1", got.value.location);
    // A known region holds its own jobs alone: j-a is not in europe.
    try testing.expectError(error.NotFound, b.client.getJob("europe-west1", "j-a"));
    try testing.expect(std.mem.indexOf(u8, b.diag.message(), "Information about job j-a could not be found") != null);

    // The state a test moves along shows on the next read.
    try b.fake.setJobState("j-a", .done, ts("2026-10-20T13:00:00Z"));
    var moved = try b.client.getJob("us-central1", "j-a");
    defer moved.deinit();
    try testing.expect(moved.value.terminal());
}

test "what the puts refuse, nothing kept; writes and other projects 501" {
    var b: Bench = undefined;
    try b.init(.{});
    defer b.deinit();
    try testing.expectError(error.InvalidEntry, b.fake.putLocation("US-central1"));
    try b.fake.putLocation("us-central1");
    try testing.expectError(error.InvalidEntry, b.fake.putLocation("us-central1"));
    try testing.expectError(error.InvalidEntry, b.fake.putJob(.{ .location = "nowhere1", .id = "j" }));
    try testing.expectError(error.InvalidEntry, b.fake.putJob(.{ .location = "us-central1", .id = "a/b" }));
    _ = try b.fake.putJob(.{ .location = "us-central1", .id = "taken" });
    try testing.expectError(error.InvalidEntry, b.fake.putJob(.{ .location = "us-central1", .id = "taken" }));
    try testing.expectError(error.InvalidEntry, b.fake.putMessage(.{ .job = "nobody", .text = "x" }));
    try testing.expectError(error.InvalidEntry, b.fake.putAutoscalingEvent(.{ .job = "nobody" }));
    try testing.expectError(error.InvalidEntry, b.fake.setJobState("nobody", .done, null));
    try testing.expectEqual(1, b.fake.jobCount());

    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const write = try b.raw(arena.allocator(), .POST, "https://host/v1b3/projects/my-project/locations/us-central1/jobs");
    try testing.expectEqual(501, write.status);
    const other = try b.raw(arena.allocator(), .GET, "https://host/v1b3/projects/other/locations/us-central1/jobs");
    try testing.expectEqual(501, other.status);
    const legacy = try b.raw(arena.allocator(), .GET, "https://host/v1b3/projects/my-project/jobs");
    try testing.expectEqual(501, legacy.status);
    const bare = b.fake.serve(.{ .method = .GET, .url = "https://host/v1b3/projects/my-project/locations/us-central1/jobs" }, arena.allocator());
    try testing.expectEqual(401, (try bare).status);

    // The filter refusal, in production's words.
    try testing.expectError(error.InvalidArgument, b.client.listJobs("us-central1", .{ .page_token = "p9999" }));
    const nonsense = try b.raw(arena.allocator(), .GET, "https://host/v1b3/projects/my-project/locations/us-central1/jobs?filter=NONSENSE");
    try testing.expectEqual(400, nonsense.status);
    try testing.expect(std.mem.indexOf(u8, nonsense.body, "Invalid value at 'filter'") != null);
}

test "faults on request: dropped, refused and lost answers" {
    var b: Bench = undefined;
    try b.init(.{});
    defer b.deinit();
    try b.fake.putLocation("us-central1");
    _ = try b.fake.putJob(.{ .location = "us-central1", .id = "j" });

    b.fake.dropNext(1);
    var got = try b.client.getJob("us-central1", "j");
    got.deinit();
    b.fake.refuseNext(1, 403);
    try testing.expectError(error.PermissionDenied, b.client.getJob("us-central1", "j"));
    b.fake.loseNext(1, 500);
    var again = try b.client.getJob("us-central1", "j");
    again.deinit();
    try testing.expect(b.fake.callCount() >= 5);
}

const test_util = @import("test_util.zig");

/// Production's words without the request ids it puts in parentheses
/// before each cause, which the fake leaves out.
fn withoutIds(arena: Allocator, text: []const u8) ![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    var i: usize = 0;
    while (i < text.len) {
        if (text[i] == '(') if (std.mem.indexOfPos(u8, text, i, "): ")) |close| {
            const inner = text[i + 1 .. close];
            const hex = inner.len > 0 and for (inner) |c| {
                if (!std.ascii.isHex(c)) break false;
            } else true;
            if (hex) {
                i = close + 3;
                continue;
            }
        };
        try out.append(arena, text[i]);
        i += 1;
    }
    return out.items;
}

fn errorMessage(arena: Allocator, body: []const u8) ![]const u8 {
    const value = try std.json.parseFromSliceLeaky(std.json.Value, arena, body, .{});
    return value.object.get("error").?.object.get("message").?.string;
}

test "the writes' refusals are production's words, minus its request ids" {
    const Case = struct {
        name: []const u8,
        job: FakeDataflow.PutJob,
        drain: bool = false,
        location: []const u8 = "us-central1",
        want: anyerror,
        production: []const u8,
    };
    const b1 = "2026-10-20_15_12_39-16726637407140010736";
    const b2 = "2026-10-20_15_12_40-17194894741260815925";
    const b3 = "2026-10-20_15_14_29-4138990520061636327";
    const s1 = "2026-10-20_15_12_41-6567995927817659660";
    const s3 = "2026-10-20_15_21_25-1828704797262605315";
    const launch_failed = "2026-10-20_07_09_34-8524524531325271694";
    const cases = [_]Case{
        .{ .name = "pending", .job = .{ .location = "us-central1", .id = b3, .current_state = .pending }, .want = error.FailedPrecondition, .production = production.cancel_not_ready },
        .{ .name = "made-up region", .job = .{ .location = "us-central1", .id = b1, .current_state = .pending }, .location = "us-fake1", .want = error.FailedPrecondition, .production = production.cancel_made_up_region },
        .{ .name = "batch drain", .job = .{ .location = "us-central1", .id = b2, .current_state = .running }, .drain = true, .want = error.InvalidArgument, .production = production.drain_batch },
        .{ .name = "done", .job = .{ .location = "us-central1", .id = b1, .current_state = .done }, .want = error.FailedPrecondition, .production = production.cancel_ended },
        .{ .name = "cancelled", .job = .{ .location = "us-central1", .id = b3, .current_state = .cancelled }, .want = error.FailedPrecondition, .production = production.cancel_cancelled },
        .{ .name = "failed", .job = .{ .location = "us-central1", .id = s1, .type = .streaming, .current_state = .failed }, .want = error.FailedPrecondition, .production = production.cancel_failed },
        .{ .name = "failed to start", .job = .{ .location = "us-central1", .id = launch_failed, .current_state = .failed, .provisioning_error = "Workflow failed." }, .want = error.FailedPrecondition, .production = production.cancel_not_started },
        .{ .name = "drained", .job = .{ .location = "us-central1", .id = s3, .type = .streaming, .current_state = .drained }, .want = error.FailedPrecondition, .production = production.cancel_drained },
        .{ .name = "ended drain", .job = .{ .location = "us-central1", .id = s1, .type = .streaming, .current_state = .failed }, .drain = true, .want = error.FailedPrecondition, .production = production.drain_ended },
        .{ .name = "nobody", .job = .{ .location = "us-central1", .id = "someone-else" }, .want = error.NotFound, .production = production.cancel_unknown },
    };
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    for (cases) |case| {
        errdefer std.debug.print("case: {s}\n", .{case.name});
        var b: Bench = undefined;
        try b.init(.{ .project_id = "extractctl" });
        defer b.deinit();
        try b.fake.putLocation("us-central1");
        _ = try b.fake.putJob(case.job);
        const id = if (case.want == error.NotFound) b1 else case.job.id;
        const got = if (case.drain) b.client.drainJob(case.location, id) else b.client.cancelJob(case.location, id);
        try testing.expectError(case.want, got);
        try testing.expectEqualStrings(try withoutIds(a, try errorMessage(a, case.production)), b.diag.message());
    }
}

test "a cancel, as production took one: cancelling at once, its line in the story, the end the test's" {
    var b: Bench = undefined;
    try b.init(.{});
    defer b.deinit();
    b.clock.now_ns = ts("2026-10-20T22:14:50.918Z").nanoseconds;
    try b.fake.putLocation("us-central1");
    const id = try b.fake.putJob(.{ .location = "us-central1", .id = "j", .current_state = .running });

    try b.client.cancelJob("us-central1", id);
    var got = try b.client.getJob("us-central1", id);
    defer got.deinit();
    try testing.expectEqual(types.JobState.cancelling, got.value.current_state);
    try testing.expectEqual(types.JobState.cancelled, got.value.requested_state);
    try testing.expectEqual(b.clock.now_ns, got.value.current_state_time.?.nanoseconds);
    try testing.expect(!got.value.cancellable());

    // The list's summary shows the state, never the request.
    var listed = try b.client.aggregatedJobs(.{});
    defer listed.deinit();
    try testing.expectEqual(types.JobState.cancelling, listed.value.jobs[0].current_state);
    try testing.expectEqual(types.JobState.unspecified, listed.value.jobs[0].requested_state);

    // A repeat is taken, changes nothing, and adds its line.
    b.clock.now_ns += std.time.ns_per_s;
    try b.client.cancelJob("us-central1", id);
    var story = try b.client.listMessages("us-central1", id, .{});
    defer story.deinit();
    try testing.expectEqual(2, story.value.messages.len);
    try testing.expectEqualStrings("Cancel request is committed for workflow job: j.", story.value.messages[0].text);
    try testing.expectEqualStrings("1792534490918", story.value.messages[0].id);
    try testing.expectEqual(types.MessageImportance.basic, story.value.messages[0].importance);
    var again = try b.client.getJob("us-central1", id);
    defer again.deinit();
    try testing.expectEqual(got.value.current_state_time.?.nanoseconds, again.value.current_state_time.?.nanoseconds);

    // The service ends it; the request goes with the end.
    try b.fake.setJobState(id, .cancelled, null);
    var done = try b.client.getJob("us-central1", id);
    defer done.deinit();
    try testing.expectEqual(types.JobState.unspecified, done.value.requested_state);
    try testing.expectError(error.FailedPrecondition, b.client.cancelJob("us-central1", id));
    try testing.expectError(error.InvalidArgument, b.client.drainJob("us-central1", id));
}

test "a drain, as production took one: draining at once, a repeat adding nothing, a cancel winning" {
    var b: Bench = undefined;
    try b.init(.{});
    defer b.deinit();
    try b.fake.putLocation("us-central1");
    const id = try b.fake.putJob(.{ .location = "us-central1", .id = "s", .type = .streaming, .current_state = .running });
    var before = try b.client.getJob("us-central1", id);
    defer before.deinit();
    try testing.expect(before.value.drainable());

    try b.client.drainJob("us-central1", id);
    try b.client.drainJob("us-central1", id);
    var got = try b.client.getJob("us-central1", id);
    defer got.deinit();
    try testing.expectEqual(types.JobState.draining, got.value.current_state);
    try testing.expectEqual(types.JobState.drained, got.value.requested_state);
    try testing.expect(!got.value.drainable());
    try testing.expect(got.value.cancellable());
    var story = try b.client.listMessages("us-central1", id, .{});
    defer story.deinit();
    try testing.expectEqual(1, story.value.messages.len);
    try testing.expectEqualStrings("Drain request is committed for workflow job: s.", story.value.messages[0].text);

    try b.client.cancelJob("us-central1", id);
    var cancelled = try b.client.getJob("us-central1", id);
    defer cancelled.deinit();
    try testing.expectEqual(types.JobState.cancelling, cancelled.value.current_state);
    try testing.expectEqual(types.JobState.cancelled, cancelled.value.requested_state);
    try b.fake.setJobState(id, .cancelled, null);
    try testing.expectError(error.FailedPrecondition, b.client.drainJob("us-central1", id));
    try testing.expect(std.mem.endsWith(u8, b.diag.message(), "Job has terminated."));
}

test "writes production's answer to was not measured are 501, naming what" {
    const Case = struct { job: FakeDataflow.PutJob, drain: bool };
    const cases = [_]Case{
        .{ .job = .{ .location = "us-central1", .id = "j", .type = .streaming, .current_state = .pending }, .drain = true },
        .{ .job = .{ .location = "us-central1", .id = "j", .type = .streaming, .current_state = .cancelling }, .drain = true },
        .{ .job = .{ .location = "us-central1", .id = "j", .current_state = .updated }, .drain = false },
        .{ .job = .{ .location = "us-central1", .id = "j", .current_state = .queued }, .drain = false },
        .{ .job = .{ .location = "us-central1", .id = "j", .type = .streaming, .current_state = .paused }, .drain = true },
        .{ .job = .{ .location = "us-central1", .id = "j", .current_state = .stopped }, .drain = false },
        .{ .job = .{ .location = "us-central1", .id = "j", .current_state = .resource_cleaning_up }, .drain = false },
        .{ .job = .{ .location = "us-central1", .id = "j", .current_state = .pausing }, .drain = false },
    };
    for (cases) |case| {
        var b: Bench = undefined;
        try b.init(.{});
        defer b.deinit();
        try b.fake.putLocation("us-central1");
        _ = try b.fake.putJob(case.job);
        const got = if (case.drain) b.client.drainJob("us-central1", "j") else b.client.cancelJob("us-central1", "j");
        try testing.expectError(error.Unimplemented, got);
        try testing.expect(std.mem.startsWith(u8, b.diag.message(), "fake: production's answer to "));
    }
    // A batch job's drain is refused before any state is looked at, as
    // production's was.
    var b: Bench = undefined;
    try b.init(.{});
    defer b.deinit();
    try b.fake.putLocation("us-central1");
    _ = try b.fake.putJob(.{ .location = "us-central1", .id = "q", .current_state = .queued });
    try testing.expectError(error.InvalidArgument, b.client.drainJob("us-central1", "q"));
}

test "the write route takes a requested state alone, on a job, nothing else" {
    var b: Bench = undefined;
    try b.init(.{});
    defer b.deinit();
    try b.fake.putLocation("us-central1");
    try b.fake.putLocation("us-east1");
    _ = try b.fake.putJob(.{ .location = "us-central1", .id = "j", .current_state = .running });
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const url = "https://host/v1b3/projects/my-project/locations/us-central1/jobs/j";
    const Put = struct { url: []const u8, body: []const u8 };
    for ([_]Put{
        .{ .url = url ++ "?updateMask=labels", .body = "{\"requestedState\":\"JOB_STATE_CANCELLED\"}" },
        .{ .url = url, .body = "{\"requestedState\":\"JOB_STATE_CANCELLED\",\"labels\":{\"force_cancel_job\":\"true\"}}" },
        .{ .url = url, .body = "{\"requestedState\":\"JOB_STATE_PAUSING\"}" },
        .{ .url = url, .body = "{\"requestedState\":7}" },
        .{ .url = url, .body = "[]" },
        .{ .url = url, .body = "" },
        .{ .url = "https://host/v1b3/projects/my-project/locations/us-central1/jobs", .body = "{\"requestedState\":\"JOB_STATE_CANCELLED\"}" },
    }) |put| {
        const reply = try b.fake.serve(.{ .method = .PUT, .url = put.url, .bearer = "t", .body = put.body }, a);
        try testing.expectEqual(501, reply.status);
    }
    var job = try b.client.getJob("us-central1", "j");
    defer job.deinit();
    try testing.expectEqual(types.JobState.running, job.value.current_state);

    // A region put in that the job is not in is the 404; the answer to
    // a taken write is production's one field.
    try testing.expectError(error.NotFound, b.client.cancelJob("us-east1", "j"));
    const taken = try b.fake.serve(.{ .method = .PUT, .url = url, .bearer = "t", .body = "{\"requestedState\":\"JOB_STATE_CANCELLED\"}" }, a);
    try testing.expectEqual(200, taken.status);
    try testing.expectEqualStrings("{\"type\":\"JOB_TYPE_BATCH\"}", taken.body);
}

test "faults on writes: a lost cancel's retry lands as a repeat, a dropped one as the first" {
    var b: Bench = undefined;
    try b.init(.{});
    defer b.deinit();
    try b.fake.putLocation("us-central1");
    _ = try b.fake.putJob(.{ .location = "us-central1", .id = "lost", .current_state = .running });
    _ = try b.fake.putJob(.{ .location = "us-central1", .id = "dropped", .type = .streaming, .current_state = .running });

    b.fake.loseNext(1, 503);
    try b.client.cancelJob("us-central1", "lost");
    var story = try b.client.listMessages("us-central1", "lost", .{});
    defer story.deinit();
    try testing.expectEqual(2, story.value.messages.len);

    b.fake.dropNext(1);
    try b.client.drainJob("us-central1", "dropped");
    var drained = try b.client.listMessages("us-central1", "dropped", .{});
    defer drained.deinit();
    try testing.expectEqual(1, drained.value.messages.len);

    b.fake.refuseNext(1, 403);
    try testing.expectError(error.PermissionDenied, b.client.cancelJob("us-central1", "dropped"));
    var still = try b.client.getJob("us-central1", "dropped");
    defer still.deinit();
    try testing.expectEqual(types.JobState.draining, still.value.current_state);
}

/// What the property expects of one job, from what production took and
/// refused on 2026-10-20.
const StopModel = struct {
    type: types.JobType,
    current: types.JobState,
    requested: types.JobState = .unspecified,
    launch_failed: bool,
    lines: usize = 0,

    const Outcome = enum { taken, failed_precondition, invalid_argument, unimplemented };

    fn cancel(m: *StopModel) Outcome {
        if (m.current.terminal()) {
            return if (m.current == .updated) .unimplemented else .failed_precondition;
        }
        switch (m.current) {
            .pending => return .failed_precondition,
            .running, .draining => {
                m.current = .cancelling;
                m.requested = .cancelled;
                m.lines += 1;
                return .taken;
            },
            .cancelling => {
                m.requested = .cancelled;
                m.lines += 1;
                return .taken;
            },
            else => return .unimplemented,
        }
    }

    fn drain(m: *StopModel) Outcome {
        if (m.type != .streaming) return .invalid_argument;
        if (m.current.terminal()) return .failed_precondition;
        switch (m.current) {
            .running => {
                m.current = .draining;
                m.requested = .drained;
                m.lines += 1;
                return .taken;
            },
            .draining => return .taken,
            else => return .unimplemented,
        }
    }

    fn set(m: *StopModel, state: types.JobState) void {
        m.current = state;
        if (state.terminal()) m.requested = .unspecified;
    }
};

fn expectOutcome(want: StopModel.Outcome, got: anyerror!void) !void {
    switch (want) {
        .taken => try got,
        .failed_precondition => try testing.expectError(error.FailedPrecondition, got),
        .invalid_argument => try testing.expectError(error.InvalidArgument, got),
        .unimplemented => try testing.expectError(error.Unimplemented, got),
    }
}

const all_states = [_]types.JobState{ .stopped, .running, .done, .failed, .cancelled, .updated, .draining, .drained, .pending, .cancelling, .queued, .resource_cleaning_up, .pausing, .paused };

fn stopsProperty(_: void, input: []const u8) !void {
    const gpa = test_util.propertyAllocator();
    var g: test_util.ByteGen = .init(input);
    var clock: core.testing.FakeClock = .{};
    var fake: FakeDataflow = .init(gpa, clock.io(), .{});
    defer fake.deinit();
    var token: core.StaticToken = .{ .token = "t" };
    var diag: core.Diagnostics = .{};
    var client = try Client.init(gpa, clock.io(), .{
        .project_id = "my-project",
        .token_provider = token.provider(),
        .transport = fake.transport(),
        .diagnostics = &diag,
        .retry = .{ .max_attempts = 2, .initial_backoff_ms = 1, .max_backoff_ms = 1 },
    });
    defer client.deinit();
    try fake.putLocation("us-central1");

    var m: StopModel = .{
        .type = if (g.boolean()) .streaming else .batch,
        .current = g.pick(types.JobState, &all_states),
        .launch_failed = g.boolean(),
    };
    _ = try fake.putJob(.{
        .location = "us-central1",
        .id = "j",
        .type = m.type,
        .current_state = m.current,
        .provisioning_error = if (m.launch_failed) "Workflow failed." else null,
    });

    const steps = g.intRange(usize, 0, 24);
    for (0..steps) |_| {
        switch (g.intRange(u8, 0, 6)) {
            0 => try expectOutcome(m.cancel(), client.cancelJob(g.pick([]const u8, &.{ "us-central1", "us-fake1" }), "j")),
            1 => try expectOutcome(m.drain(), client.drainJob("us-central1", "j")),
            2 => {
                const state = g.pick(types.JobState, &all_states);
                m.set(state);
                try fake.setJobState("j", state, null);
            },
            // A lost answer: the write lands, and the client's retry is
            // judged against what the first left.
            3 => {
                fake.loseNext(1, 503);
                if (g.boolean()) {
                    _ = m.cancel();
                    try expectOutcome(m.cancel(), client.cancelJob("us-central1", "j"));
                } else {
                    _ = m.drain();
                    try expectOutcome(m.drain(), client.drainJob("us-central1", "j"));
                }
            },
            4 => {
                var listed = try client.aggregatedJobs(.{});
                defer listed.deinit();
                try testing.expectEqual(1, listed.value.jobs.len);
                try testing.expectEqual(m.current, listed.value.jobs[0].current_state);
                try testing.expectEqual(types.JobState.unspecified, listed.value.jobs[0].requested_state);
            },
            5 => {
                var story = try client.listMessages("us-central1", "j", .{});
                defer story.deinit();
                try testing.expectEqual(m.lines, story.value.messages.len);
            },
            else => {},
        }
        var got = try client.getJob("us-central1", "j");
        defer got.deinit();
        try testing.expectEqual(m.current, got.value.current_state);
        try testing.expectEqual(m.requested, got.value.requested_state);
        // The helpers agree with what the fake then takes, where
        // production was measured. In the states a template launch
        // cannot reach, the fake answers 501 and `cancellable` follows
        // the documentation, which lets any job not ended be cancelled.
        const measured = switch (m.current) {
            .queued, .stopped, .paused, .pausing, .resource_cleaning_up => false,
            else => true,
        };
        var probe = m;
        if (measured) {
            try testing.expectEqual(probe.cancel() == .taken and m.current != .cancelling and m.requested != .cancelled, got.value.cancellable());
        } else {
            try testing.expectEqual(m.requested != .cancelled, got.value.cancellable());
        }
        probe = m;
        const asked = m.requested == .drained or m.requested == .cancelled;
        try testing.expectEqual(probe.drain() == .taken and m.current == .running and !asked, got.value.drainable());
    }
}

test "slow property stops: any sequence of cancels, drains, lost answers and state changes moves the job as production did" {
    try test_util.fuzzBytes({}, stopsProperty, .{
        .corpus = &.{
            // A running streaming job drained, cancelled while draining, ended.
            "\x01\x02\x00\x06\x01\x00\x00\x02\x04\x05",
            // A pending batch job: refused, then running, then cancelled twice.
            "\x00\x09\x00\x05\x00\x00\x02\x02\x00\x00\x03\x01",
            "",
        },
    });
}
