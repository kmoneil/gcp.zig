//! Cloud Run in memory, for tests of code that reads services, revisions,
//! jobs and executions, and of code that runs a job, cancels an
//! execution or sends a service's traffic to one revision: behind
//! `Client.Options.transport`, it answers the module's calls as
//! production answered them when measured on 2026-10-19 (issue #244) and
//! 2026-10-21 (issue #272).
//!
//! - Locations, services, revisions, jobs and executions are put in by
//!   the test: `putLocation`, `putService`, `putRevision`, `putJob` and
//!   `putExecution` stand in for whoever deployed, and
//!   `setExecutionStatus` for the job's container, moving an execution
//!   on (no clock moves one).
//! - The `-` location lists every region's services, as production
//!   answers it (though its documentation says otherwise), with the
//!   `unreachable` regions a test asks for; `services/-` lists every
//!   service's revisions in the location.
//! - Lists sort by name and page; revisions sort newest first, as
//!   production answered them.
//! - Refused in production's words: a service nobody has is 404
//!   "Resource '<id>' of kind 'SERVICE' in region '<l>' in project '<p>'
//!   does not exist." (a revision's the same with kind 'REVISION',
//!   production's shape though only the service's was measured), a
//!   location that is no region is 400 "The request has errors";
//!   revisions of a service nobody has are an empty page, not a 404, as
//!   production answered.
//! - Jobs are listed one region at a time (`-` is 400 "Request contains
//!   an invalid argument.", a region nobody put 403 "Permission denied on
//!   'locations/<l>' (or it may not exist)"); `jobs/-` lists every job's
//!   executions; a job nobody has lists none. Both lists come newest
//!   first.
//! - A run makes an execution named `<job>-<suffix>`, the suffix a
//!   counter (`00001`, `00002`, ...), as `PutJob.run_outcome` says:
//!   pending or running until the test moves it, or already succeeded or
//!   failed. Its operation is done when the execution has ended, with
//!   production's error for a failed one.
//! - A cancel of a running execution makes it cancelling (the test moves
//!   it on to cancelled), of a pending one cancelled at once without a
//!   completion time, as production's was; of a cancelling one changes
//!   nothing; of an ended one is 400 FAILED_PRECONDITION "Execution
//!   '<id>' cannot be cancelled because it is not running." Moved to
//!   failed after a cancel, an execution reads as one production
//!   cancelled as its task started: failed with no reason, a task
//!   counted cancelled, both its operations failing with code 2,
//!   "Unspecified error."
//! - A traffic change sets the one target asked, a new generation and a
//!   new etag. Under `updateMask=traffic,etag` a stale etag is 409
//!   ABORTED "Conflict for resource '<s>': version '<a>' was specified but
//!   current version is '<b>'." (the fake's etags are `"v<version>"`, its
//!   versions counters where production's are times); under
//!   `updateMask=traffic` the etag is ignored, and a change to the
//!   traffic the service already has changes nothing and checks no etag,
//!   as production did. A revision not prefixed with the service's id is
//!   400; one the service does not have, or one that is not ready, is
//!   taken, and the operation fails (code 9, or code 5 with the
//!   revision's own message) while the service keeps the traffic asked
//!   and its terminal condition fails. `validateOnly` checks the etag and
//!   the prefix and changes nothing. Its operation is done from its first
//!   read on.
//! - Faults a test asks for: refusals, dropped connections, and a lost
//!   answer, writes included.
//!
//! Not modelled, answered 501 with the reason: other writes (deploys,
//! deletes, IAM), run overrides, traffic other than one revision at 100 %,
//! an update mask other than the two above, reading a `validateOnly`
//! request's operation (production's answer was not measured), an etag
//! the fake did not make under the etag mask, `-` for a location in a
//! jobs path other than the jobs list, and another project's paths.

const std = @import("std");
const Allocator = std.mem.Allocator;
const Stringify = std.json.Stringify;
const core = @import("core");
const tp = core.transport;
const types = @import("types.zig");
const validate = @import("validate.zig");

pub const FakeRun = struct {
    gpa: Allocator,
    io: std.Io,
    mutex: std.Io.Mutex = .init,
    options: Options,
    /// Strings and resources, freed with the fake.
    store: std.heap.ArenaAllocator,
    /// Location ids, in the order put in.
    locations: std.StringArrayHashMapUnmanaged(void) = .empty,
    /// By full name.
    services: std.StringArrayHashMapUnmanaged(*FakeService) = .empty,
    /// By full name.
    revisions: std.StringArrayHashMapUnmanaged(*FakeRevision) = .empty,
    /// What a `-` location's answer names as unreachable.
    unreachable_regions: []const []const u8 = &.{},
    /// By full name.
    jobs: std.StringArrayHashMapUnmanaged(*FakeJob) = .empty,
    /// By full name.
    executions: std.StringArrayHashMapUnmanaged(*FakeExecution) = .empty,
    /// By full name.
    operations: std.StringArrayHashMapUnmanaged(*FakeOperation) = .empty,
    /// Operations made so far, for their ids.
    made: u64 = 0,
    /// Executions runs made so far, for their suffixes.
    runs: u64 = 0,
    /// The last etag version handed out; each service change takes one.
    version: u64 = 0,
    faults: [3]Fault = .{ .{}, .{}, .{} },
    calls: usize = 0,

    const Fault = struct { n: usize = 0, status: u16 = 0 };
    const refuse = 0;
    const drop = 1;
    const lose = 2;

    pub const Options = struct {
        /// The project it answers for, by id.
        project_id: []const u8 = "my-project",
    };

    pub const Reply = struct { status: u16, headers: []const tp.Header = &.{}, body: []const u8 };

    const FakeService = struct {
        name: []const u8,
        id: []const u8,
        location: []const u8,
        description: []const u8,
        uri: []const u8,
        urls: []const []const u8,
        latest_ready_revision: []const u8,
        latest_created_revision: []const u8,
        traffic: []const types.TrafficTarget,
        traffic_statuses: []const types.TrafficTarget,
        terminal_condition: ?types.Condition,
        conditions: []const types.Condition,
        create_time: ?std.Io.Timestamp,
        update_time: ?std.Io.Timestamp,
        creator: []const u8,
        last_modifier: []const u8,
        generation: ?i64,
        observed_generation: ?i64,
        reconciling: bool,
        labels: []const types.Label,
        /// The etag's version: `"v<version>"`, new on every change.
        version: u64,
    };

    const FakeRevision = struct {
        name: []const u8,
        id: []const u8,
        service: []const u8,
        location: []const u8,
        create_time: ?std.Io.Timestamp,
        update_time: ?std.Io.Timestamp,
        generation: ?i64,
        containers: []const types.Container,
        conditions: []const types.Condition,
        log_uri: []const u8,
        service_account: []const u8,
        labels: []const types.Label,
    };

    const FakeJob = struct {
        name: []const u8,
        id: []const u8,
        location: []const u8,
        task_count: i32,
        parallelism: i32,
        task_timeout_s: ?f64,
        max_retries: ?i32,
        containers: []const types.Container,
        service_account: []const u8,
        labels: []const types.Label,
        create_time: ?std.Io.Timestamp,
        update_time: ?std.Io.Timestamp,
        terminal_condition: ?types.Condition,
        execution_count: i32,
        /// The full name of the newest execution, or null before the first.
        latest: ?[]const u8,
        run_outcome: RunOutcome,
        version: u64,
    };

    const FakeExecution = struct {
        name: []const u8,
        id: []const u8,
        /// The job's id, as the wire sends it.
        job: []const u8,
        location: []const u8,
        status: types.ExecutionStatus,
        /// Whether its container started: an execution cancelled before
        /// it started keeps `Started` reconciling and gets no completion
        /// time, as production's did.
        started: bool,
        task_count: i32,
        parallelism: i32,
        create_time: ?std.Io.Timestamp,
        start_time: ?std.Io.Timestamp,
        completion_time: ?std.Io.Timestamp,
        log_uri: []const u8,
        labels: []const types.Label,
        /// Whether a cancel was taken: one that then ends failed met the
        /// task's start, as production's did, with no reason given.
        cancel_asked: bool = false,
    };

    const FakeOperation = struct {
        name: []const u8,
        subject: union(enum) {
            /// A run's or a cancel's: done once the execution has ended.
            execution: []const u8,
            /// A traffic change's: done from its first read on.
            service: struct { name: []const u8, failure: ?types.Operation.Failure },
            /// A `validateOnly` request's: never read back here.
            validation,
        },
    };

    pub fn init(gpa: Allocator, io: std.Io, options: Options) FakeRun {
        return .{ .gpa = gpa, .io = io, .options = options, .store = .init(gpa) };
    }

    pub fn deinit(f: *FakeRun) void {
        f.locations.deinit(f.gpa);
        f.services.deinit(f.gpa);
        f.revisions.deinit(f.gpa);
        f.jobs.deinit(f.gpa);
        f.executions.deinit(f.gpa);
        f.operations.deinit(f.gpa);
        f.store.deinit();
        f.* = undefined;
    }

    /// Goes into `Client.Options.transport`.
    pub fn transport(f: *FakeRun) tp.Transport {
        return .{ .ptr = f, .vtable = &.{ .send = send } };
    }

    // Faults, each for the next `n` calls.

    /// Answers them with `status`, and changes nothing.
    pub fn refuseNext(f: *FakeRun, n: usize, status: u16) void {
        f.setFault(refuse, .{ .n = n, .status = status });
    }

    /// Closes their connection before any answer.
    pub fn dropNext(f: *FakeRun, n: usize) void {
        f.setFault(drop, .{ .n = n });
    }

    /// Serves them and answers `status` instead of what was read.
    pub fn loseNext(f: *FakeRun, n: usize, status: u16) void {
        f.setFault(lose, .{ .n = n, .status = status });
    }

    fn setFault(f: *FakeRun, slot: usize, fault: Fault) void {
        f.mutex.lockUncancelable(f.io);
        defer f.mutex.unlock(f.io);
        f.faults[slot] = fault;
    }

    fn takeFault(f: *FakeRun, slot: usize) ?Fault {
        const fault = &f.faults[slot];
        if (fault.n == 0) return null;
        fault.n -= 1;
        return fault.*;
    }

    // What a test reads.

    /// Calls served, refusals included.
    pub fn callCount(f: *FakeRun) usize {
        f.mutex.lockUncancelable(f.io);
        defer f.mutex.unlock(f.io);
        return f.calls;
    }

    /// Services held, every location together.
    pub fn serviceCount(f: *FakeRun) usize {
        f.mutex.lockUncancelable(f.io);
        defer f.mutex.unlock(f.io);
        return f.services.count();
    }

    /// Revisions held, every service together.
    pub fn revisionCount(f: *FakeRun) usize {
        f.mutex.lockUncancelable(f.io);
        defer f.mutex.unlock(f.io);
        return f.revisions.count();
    }

    /// Jobs held, every location together.
    pub fn jobCount(f: *FakeRun) usize {
        f.mutex.lockUncancelable(f.io);
        defer f.mutex.unlock(f.io);
        return f.jobs.count();
    }

    /// Executions held, every job together: put in and made by runs.
    pub fn executionCount(f: *FakeRun) usize {
        f.mutex.lockUncancelable(f.io);
        defer f.mutex.unlock(f.io);
        return f.executions.count();
    }

    /// Where the execution of that full name stands, or null for one
    /// nobody has.
    pub fn executionStatus(f: *FakeRun, name: []const u8) ?types.ExecutionStatus {
        f.mutex.lockUncancelable(f.io);
        defer f.mutex.unlock(f.io);
        const execution = f.executions.get(name) orelse return null;
        return execution.status;
    }

    // What a test puts in.

    pub const PutError = error{ OutOfMemory, InvalidEntry };

    /// A location services can live in, such as "us-central1".
    pub fn putLocation(f: *FakeRun, id: []const u8) PutError!void {
        f.mutex.lockUncancelable(f.io);
        defer f.mutex.unlock(f.io);
        if (!validate.isLocation(id) or std.mem.eql(u8, id, "-")) return error.InvalidEntry;
        if (f.locations.contains(id)) return error.InvalidEntry;
        try f.locations.put(f.gpa, try f.store.allocator().dupe(u8, id), {});
    }

    /// What a `-` location's list answers as its unreachable regions.
    pub fn setUnreachable(f: *FakeRun, regions: []const []const u8) PutError!void {
        f.mutex.lockUncancelable(f.io);
        defer f.mutex.unlock(f.io);
        const s = f.store.allocator();
        const copy = try s.alloc([]const u8, regions.len);
        for (regions, copy) |region, *out| out.* = try s.dupe(u8, region);
        f.unreachable_regions = copy;
    }

    /// A service as a test puts one in, standing in for whoever deployed
    /// it. Everything `types.Service` reads back can be set.
    pub const PutService = struct {
        /// Must be put with `putLocation` first.
        location: []const u8,
        id: []const u8,
        description: []const u8 = "",
        uri: []const u8 = "",
        urls: []const []const u8 = &.{},
        /// Revision ids, as production answers their trailing segments.
        latest_ready_revision: []const u8 = "",
        latest_created_revision: []const u8 = "",
        traffic: []const types.TrafficTarget = &.{},
        traffic_statuses: []const types.TrafficTarget = &.{},
        terminal_condition: ?types.Condition = null,
        conditions: []const types.Condition = &.{},
        create_time: ?std.Io.Timestamp = null,
        update_time: ?std.Io.Timestamp = null,
        creator: []const u8 = "",
        last_modifier: []const u8 = "",
        generation: ?i64 = null,
        observed_generation: ?i64 = null,
        reconciling: bool = false,
        labels: []const types.Label = &.{},
    };

    /// Puts a service in and returns its full name, owned by the fake.
    ///
    /// `error.InvalidEntry`, with nothing kept, for: a location nobody
    /// put; an id taken or malformed (or `-`, which Cloud Run reads as
    /// every service).
    pub fn putService(f: *FakeRun, service: PutService) PutError![]const u8 {
        f.mutex.lockUncancelable(f.io);
        defer f.mutex.unlock(f.io);
        if (!f.locations.contains(service.location)) return error.InvalidEntry;
        if (!validate.isResourceId(service.id) or std.mem.eql(u8, service.id, "-")) return error.InvalidEntry;
        const s = f.store.allocator();
        const name = try std.fmt.allocPrint(s, "projects/{s}/locations/{s}/services/{s}", .{ f.options.project_id, service.location, service.id });
        if (f.services.contains(name)) return error.InvalidEntry;
        const held = try s.create(FakeService);
        held.* = .{
            .name = name,
            .id = name[std.mem.lastIndexOfScalar(u8, name, '/').? + 1 ..],
            .location = try s.dupe(u8, service.location),
            .description = try s.dupe(u8, service.description),
            .uri = try s.dupe(u8, service.uri),
            .urls = try dupeStrings(s, service.urls),
            .latest_ready_revision = try s.dupe(u8, service.latest_ready_revision),
            .latest_created_revision = try s.dupe(u8, service.latest_created_revision),
            .traffic = try dupeTraffic(s, service.traffic),
            .traffic_statuses = try dupeTraffic(s, service.traffic_statuses),
            .terminal_condition = if (service.terminal_condition) |c| try dupeCondition(s, c) else null,
            .conditions = try dupeConditions(s, service.conditions),
            .create_time = service.create_time,
            .update_time = service.update_time,
            .creator = try s.dupe(u8, service.creator),
            .last_modifier = try s.dupe(u8, service.last_modifier),
            .generation = service.generation,
            .observed_generation = service.observed_generation,
            .reconciling = service.reconciling,
            .labels = try dupeLabels(s, service.labels),
            .version = f.version + 1,
        };
        try f.services.put(f.gpa, held.name, held);
        f.version += 1;
        return held.name;
    }

    /// A revision as a test puts one in. The service must be put first;
    /// the id follows production's `<service>-0000N-<suffix>` shape in
    /// spirit but is taken as given.
    pub const PutRevision = struct {
        location: []const u8,
        /// The service's id, as the wire's `service` field names it.
        service: []const u8,
        id: []const u8,
        create_time: ?std.Io.Timestamp = null,
        update_time: ?std.Io.Timestamp = null,
        generation: ?i64 = null,
        containers: []const types.Container = &.{},
        conditions: []const types.Condition = &.{},
        log_uri: []const u8 = "",
        service_account: []const u8 = "",
        labels: []const types.Label = &.{},
    };

    /// Puts a revision in and returns its full name, owned by the fake.
    ///
    /// `error.InvalidEntry`, with nothing kept, for: a service nobody
    /// put; an id taken, malformed or `-`.
    pub fn putRevision(f: *FakeRun, revision: PutRevision) PutError![]const u8 {
        f.mutex.lockUncancelable(f.io);
        defer f.mutex.unlock(f.io);
        const s = f.store.allocator();
        const service_name = try std.fmt.allocPrint(s, "projects/{s}/locations/{s}/services/{s}", .{ f.options.project_id, revision.location, revision.service });
        if (!f.services.contains(service_name)) return error.InvalidEntry;
        if (!validate.isResourceId(revision.id) or std.mem.eql(u8, revision.id, "-")) return error.InvalidEntry;
        const name = try std.fmt.allocPrint(s, "{s}/revisions/{s}", .{ service_name, revision.id });
        if (f.revisions.contains(name)) return error.InvalidEntry;
        const held = try s.create(FakeRevision);
        held.* = .{
            .name = name,
            .id = name[std.mem.lastIndexOfScalar(u8, name, '/').? + 1 ..],
            .service = try s.dupe(u8, revision.service),
            .location = try s.dupe(u8, revision.location),
            .create_time = revision.create_time,
            .update_time = revision.update_time,
            .generation = revision.generation,
            .containers = try dupeContainers(s, revision.containers),
            .conditions = try dupeConditions(s, revision.conditions),
            .log_uri = try s.dupe(u8, revision.log_uri),
            .service_account = try s.dupe(u8, revision.service_account),
            .labels = try dupeLabels(s, revision.labels),
        };
        try f.revisions.put(f.gpa, held.name, held);
        return held.name;
    }

    /// What each run of a job makes, standing in for its container.
    pub const RunOutcome = enum {
        /// An execution pending until `setExecutionStatus` moves it on, as
        /// production's were for their first 90 s.
        pending,
        /// One already running, its container started.
        running,
        /// One already ended, as production shows it a minute or two
        /// after the run (its container took ~90 s to start).
        succeeded,
        failed,
    };

    /// A job as a test puts one in, standing in for whoever created it.
    /// Its template's defaults are production's (one task, 600 s, three
    /// retries).
    pub const PutJob = struct {
        /// Must be put with `putLocation` first.
        location: []const u8,
        id: []const u8,
        task_count: i32 = 1,
        parallelism: i32 = 0,
        task_timeout_s: ?f64 = 600,
        max_retries: ?i32 = 3,
        containers: []const types.Container = &.{},
        service_account: []const u8 = "",
        labels: []const types.Label = &.{},
        create_time: ?std.Io.Timestamp = null,
        update_time: ?std.Io.Timestamp = null,
        /// The job's own condition: production's read Ready, succeeded,
        /// before any run and after a failed one.
        terminal_condition: ?types.Condition = .{ .type = "Ready", .state = .succeeded },
        run_outcome: RunOutcome = .pending,
    };

    /// Puts a job in and returns its full name, owned by the fake.
    ///
    /// `error.InvalidEntry`, with nothing kept, for: a location nobody
    /// put; an id taken or malformed (or `-`).
    pub fn putJob(f: *FakeRun, job: PutJob) PutError![]const u8 {
        f.mutex.lockUncancelable(f.io);
        defer f.mutex.unlock(f.io);
        if (!f.locations.contains(job.location)) return error.InvalidEntry;
        if (!validate.isResourceId(job.id) or std.mem.eql(u8, job.id, "-")) return error.InvalidEntry;
        const s = f.store.allocator();
        const name = try std.fmt.allocPrint(s, "projects/{s}/locations/{s}/jobs/{s}", .{ f.options.project_id, job.location, job.id });
        if (f.jobs.contains(name)) return error.InvalidEntry;
        const held = try s.create(FakeJob);
        held.* = .{
            .name = name,
            .id = name[std.mem.lastIndexOfScalar(u8, name, '/').? + 1 ..],
            .location = try s.dupe(u8, job.location),
            .task_count = job.task_count,
            .parallelism = job.parallelism,
            .task_timeout_s = job.task_timeout_s,
            .max_retries = job.max_retries,
            .containers = try dupeContainers(s, job.containers),
            .service_account = try s.dupe(u8, job.service_account),
            .labels = try dupeLabels(s, job.labels),
            .create_time = job.create_time,
            .update_time = job.update_time,
            .terminal_condition = if (job.terminal_condition) |c| try dupeCondition(s, c) else null,
            .execution_count = 0,
            .latest = null,
            .run_outcome = job.run_outcome,
            .version = f.version + 1,
        };
        try f.jobs.put(f.gpa, held.name, held);
        f.version += 1;
        return held.name;
    }

    /// An execution as a test puts one in, as though a run had made it.
    pub const PutExecution = struct {
        location: []const u8,
        /// The job's id; the job must be put first.
        job: []const u8,
        id: []const u8,
        /// Any but `.unspecified` and `.unknown`.
        status: types.ExecutionStatus = .running,
        task_count: i32 = 1,
        parallelism: i32 = 1,
        create_time: ?std.Io.Timestamp = null,
        /// A cancelled execution without one was cancelled before it
        /// started; a running or ended one is taken to have started.
        start_time: ?std.Io.Timestamp = null,
        completion_time: ?std.Io.Timestamp = null,
        log_uri: []const u8 = "",
        labels: []const types.Label = &.{},
    };

    /// Puts an execution in and returns its full name, owned by the fake.
    /// It counts on its job, and is the job's latest when no execution of
    /// the job was made later.
    ///
    /// `error.InvalidEntry`, with nothing kept, for: a job nobody put; an
    /// id taken or malformed (or `-`); a status of `.unspecified` or
    /// `.unknown`.
    pub fn putExecution(f: *FakeRun, execution: PutExecution) PutError![]const u8 {
        f.mutex.lockUncancelable(f.io);
        defer f.mutex.unlock(f.io);
        const s = f.store.allocator();
        const job_name = try std.fmt.allocPrint(s, "projects/{s}/locations/{s}/jobs/{s}", .{ f.options.project_id, execution.location, execution.job });
        const job = f.jobs.get(job_name) orelse return error.InvalidEntry;
        if (!validate.isResourceId(execution.id) or std.mem.eql(u8, execution.id, "-")) return error.InvalidEntry;
        switch (execution.status) {
            .unspecified, .unknown => return error.InvalidEntry,
            else => {},
        }
        const name = try std.fmt.allocPrint(s, "{s}/executions/{s}", .{ job_name, execution.id });
        if (f.executions.contains(name)) return error.InvalidEntry;
        const held = try s.create(FakeExecution);
        held.* = .{
            .name = name,
            .id = name[std.mem.lastIndexOfScalar(u8, name, '/').? + 1 ..],
            .job = job.id,
            .location = job.location,
            .status = execution.status,
            .started = execution.start_time != null or switch (execution.status) {
                .pending, .cancelled => false,
                else => true,
            },
            .task_count = execution.task_count,
            .parallelism = execution.parallelism,
            .create_time = execution.create_time,
            .start_time = execution.start_time,
            .completion_time = execution.completion_time,
            .log_uri = try s.dupe(u8, execution.log_uri),
            .labels = try dupeLabels(s, execution.labels),
        };
        try f.executions.put(f.gpa, held.name, held);
        f.counted(job, held);
        return held.name;
    }

    /// Moves the execution of that full name to `status`, standing in for
    /// its container: to `.running` it starts (a start time, now); to an
    /// end from running or cancelling it gets a completion time, now;
    /// cancelled while pending it gets neither, as production's did.
    ///
    /// `error.InvalidEntry`, with nothing changed, for an execution
    /// nobody has, or a status of `.unspecified` or `.unknown`.
    pub fn setExecutionStatus(f: *FakeRun, name: []const u8, status: types.ExecutionStatus) PutError!void {
        f.mutex.lockUncancelable(f.io);
        defer f.mutex.unlock(f.io);
        const execution = f.executions.get(name) orelse return error.InvalidEntry;
        switch (status) {
            .unspecified, .unknown => return error.InvalidEntry,
            else => {},
        }
        f.move(execution, status);
    }

    /// Moves `execution` to `status`, as `setExecutionStatus` says.
    fn move(f: *FakeRun, execution: *FakeExecution, status: types.ExecutionStatus) void {
        const at = f.now();
        switch (status) {
            .running, .cancelling, .succeeded, .failed => if (!execution.started) {
                execution.started = true;
                execution.start_time = execution.start_time orelse at;
            },
            else => {},
        }
        if (status.ended() and execution.started and execution.completion_time == null) execution.completion_time = at;
        execution.status = status;
    }

    /// Counts a new execution on its job, the job's latest when newest.
    fn counted(f: *FakeRun, job: *FakeJob, execution: *FakeExecution) void {
        job.execution_count += 1;
        const latest = if (job.latest) |n| f.executions.get(n) else null;
        if (latest) |l| {
            const at: i96 = if (l.create_time) |t| t.nanoseconds else 0;
            const new: i96 = if (execution.create_time) |t| t.nanoseconds else 0;
            if (new < at) return;
        }
        job.latest = execution.name;
    }

    fn now(f: *FakeRun) std.Io.Timestamp {
        return std.Io.Clock.real.now(f.io);
    }

    fn dupeStrings(s: Allocator, items: []const []const u8) Allocator.Error![]const []const u8 {
        const out = try s.alloc([]const u8, items.len);
        for (items, out) |item, *o| o.* = try s.dupe(u8, item);
        return out;
    }

    fn dupeLabels(s: Allocator, labels: []const types.Label) Allocator.Error![]const types.Label {
        const out = try s.alloc(types.Label, labels.len);
        for (labels, out) |l, *o| o.* = .{ .key = try s.dupe(u8, l.key), .value = try s.dupe(u8, l.value) };
        return out;
    }

    fn dupeTraffic(s: Allocator, targets: []const types.TrafficTarget) Allocator.Error![]const types.TrafficTarget {
        const out = try s.alloc(types.TrafficTarget, targets.len);
        for (targets, out) |t, *o| o.* = .{
            .type = t.type,
            .revision = try s.dupe(u8, t.revision),
            .percent = t.percent,
            .tag = try s.dupe(u8, t.tag),
            .uri = try s.dupe(u8, t.uri),
        };
        return out;
    }

    fn dupeCondition(s: Allocator, c: types.Condition) Allocator.Error!types.Condition {
        return .{
            .type = try s.dupe(u8, c.type),
            .state = c.state,
            .message = try s.dupe(u8, c.message),
            .reason = try s.dupe(u8, c.reason),
            .severity = c.severity,
            .last_transition_time = c.last_transition_time,
        };
    }

    fn dupeConditions(s: Allocator, conditions: []const types.Condition) Allocator.Error![]const types.Condition {
        const out = try s.alloc(types.Condition, conditions.len);
        for (conditions, out) |c, *o| o.* = try dupeCondition(s, c);
        return out;
    }

    fn dupeContainers(s: Allocator, containers: []const types.Container) Allocator.Error![]const types.Container {
        const out = try s.alloc(types.Container, containers.len);
        for (containers, out) |c, *o| o.* = .{ .name = try s.dupe(u8, c.name), .image = try s.dupe(u8, c.image) };
        return out;
    }

    // The transport.

    fn send(ptr: *anyopaque, req: tp.Request, arena: Allocator) tp.Error!tp.Response {
        const f: *FakeRun = @ptrCast(@alignCast(ptr));
        const reply = try f.serve(req, arena);
        return .{ .status = reply.status, .headers = reply.headers, .body = reply.body };
    }

    /// One request, as `send` serves it: for a test that wants to send
    /// what no client would.
    pub fn serve(f: *FakeRun, req: tp.Request, arena: Allocator) tp.Error!Reply {
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

    fn route(f: *FakeRun, req: tp.Request, arena: Allocator, route_text: []const u8, query: []const u8) Allocator.Error!Reply {
        if (req.bearer == null) return fail(arena, 401, "UNAUTHENTICATED", "Request is missing required authentication credential. Expected OAuth 2 access token, login cookie or other valid authentication credential. See https://developers.google.com/identity/sign-in/web/devconsole-project.");
        const target = parseRoute(route_text) orelse return notModelled(arena, "this path");
        if (!std.mem.eql(u8, target.project, f.options.project_id)) return notModelled(arena, "a project other than the fake's own");
        const allowed: tp.Method = switch (target.kind) {
            .run, .cancel => .POST,
            .service => if (req.method == .PATCH) .PATCH else .GET,
            else => .GET,
        };
        if (req.method != allowed) return notModelled(arena, "a write other than a run, a cancel or a traffic change");
        const params = try parseParams(arena, query) orelse return fail(arena, 400, "INVALID_ARGUMENT", "Invalid query string.");
        switch (target.kind) {
            .jobs => |location| {
                if (std.mem.eql(u8, location, "-")) return fail(arena, 400, "INVALID_ARGUMENT", "Request contains an invalid argument.");
                if (!f.locations.contains(location)) return noRegion(arena, location);
                return f.listJobs(arena, location, params);
            },
            .job, .run => |j| {
                if (!f.locations.contains(j.location)) return noRegion(arena, j.location);
                const name = try arena.print("projects/{s}/locations/{s}/jobs/{s}", .{ f.options.project_id, j.location, j.id });
                const job = f.jobs.get(name) orelse return fail(arena, 404, "NOT_FOUND", try arena.print("Resource '{s}' of kind 'JOB' in region '{s}' in project '{s}' does not exist.", .{ j.id, j.location, f.options.project_id }));
                if (target.kind == .run) return f.runJob(arena, job, req.body orelse "");
                var out: std.Io.Writer.Allocating = .init(arena);
                var jw: Stringify = .{ .writer = &out.writer };
                f.writeJob(&jw, job) catch return error.OutOfMemory;
                return .{ .status = 200, .body = out.written() };
            },
            .executions => |e| {
                if (std.mem.eql(u8, e.location, "-")) return notModelled(arena, "'-' for a location in a jobs path other than the jobs list");
                if (!f.locations.contains(e.location)) return noRegion(arena, e.location);
                return f.listExecutions(arena, e.location, e.job, params);
            },
            .execution, .cancel => |e| {
                if (!f.locations.contains(e.location)) return noRegion(arena, e.location);
                const name = try arena.print("projects/{s}/locations/{s}/jobs/{s}/executions/{s}", .{ f.options.project_id, e.location, e.job, e.id });
                const execution = f.executions.get(name) orelse return fail(arena, 404, "NOT_FOUND", try arena.print("Resource '{s}' of kind 'EXECUTION' in region '{s}' in project '{s}' does not exist.", .{ e.id, e.location, f.options.project_id }));
                if (target.kind == .cancel) return f.cancelExecution(arena, execution, req.body orelse "");
                var out: std.Io.Writer.Allocating = .init(arena);
                var jw: Stringify = .{ .writer = &out.writer };
                writeExecution(&jw, execution, false) catch return error.OutOfMemory;
                return .{ .status = 200, .body = out.written() };
            },
            .operation => |o| {
                if (!f.locations.contains(o.location)) return noRegion(arena, o.location);
                const name = try arena.print("projects/{s}/locations/{s}/operations/{s}", .{ f.options.project_id, o.location, o.id });
                const operation = f.operations.get(name) orelse return fail(arena, 404, "NOT_FOUND", o.id);
                if (operation.subject == .validation) return notModelled(arena, "reading a validateOnly request's operation (production's answer was not measured)");
                return f.operationReply(arena, operation, true, null);
            },
            .locations => return f.listLocations(arena, params),
            .services => |location| {
                if (!std.mem.eql(u8, location, "-") and !f.locations.contains(location)) return badRegion(arena);
                return f.listServices(arena, location, params);
            },
            .service => |svc| {
                if (!f.locations.contains(svc.location)) return badRegion(arena);
                const name = try serviceNameOf(arena, f.options.project_id, svc.location, svc.id);
                const service = f.services.get(name) orelse return fail(arena, 404, "NOT_FOUND", try arena.print("Resource '{s}' of kind 'SERVICE' in region '{s}' in project '{s}' does not exist.", .{ svc.id, svc.location, f.options.project_id }));
                if (req.method == .PATCH) return f.changeTraffic(arena, service, params, req.body orelse "");
                var out: std.Io.Writer.Allocating = .init(arena);
                var jw: Stringify = .{ .writer = &out.writer };
                writeService(&jw, service) catch return error.OutOfMemory;
                return .{ .status = 200, .body = out.written() };
            },
            .revisions => |rev| {
                if (!f.locations.contains(rev.location)) return badRegion(arena);
                return f.listRevisions(arena, rev.location, rev.service, params);
            },
            .revision => |rev| {
                if (!f.locations.contains(rev.location)) return badRegion(arena);
                var w: std.Io.Writer.Allocating = .init(arena);
                w.writer.print("projects/{s}/locations/{s}/services/{s}/revisions/{s}", .{ f.options.project_id, rev.location, rev.service, rev.id }) catch return error.OutOfMemory;
                const revision = f.revisions.get(w.written()) orelse return fail(arena, 404, "NOT_FOUND", try arena.print("Resource '{s}' of kind 'REVISION' in region '{s}' in project '{s}' does not exist.", .{ rev.id, rev.location, f.options.project_id }));
                var out: std.Io.Writer.Allocating = .init(arena);
                var jw: Stringify = .{ .writer = &out.writer };
                writeRevision(&jw, revision) catch return error.OutOfMemory;
                return .{ .status = 200, .body = out.written() };
            },
        }
    }

    fn badRegion(arena: Allocator) Allocator.Error!Reply {
        return fail(arena, 400, "INVALID_ARGUMENT", "The request has errors");
    }

    /// A jobs path in a region nobody put: production answered a made-up
    /// region so, for a jobs list and a cancel alike.
    fn noRegion(arena: Allocator, location: []const u8) Allocator.Error!Reply {
        return fail(arena, 403, "PERMISSION_DENIED", try arena.print("Permission denied on 'locations/{s}' (or it may not exist)", .{location}));
    }

    fn listJobs(f: *FakeRun, arena: Allocator, location: []const u8, params: []const Param) Allocator.Error!Reply {
        var matched: std.ArrayList(*FakeJob) = .empty;
        for (f.jobs.values()) |job| {
            if (std.mem.eql(u8, job.location, location)) try matched.append(arena, job);
        }
        // Newest first, as the API documents and production answered.
        std.mem.sort(*FakeJob, matched.items, {}, struct {
            fn inner(_: void, a: *FakeJob, b: *FakeJob) bool {
                return newer(a.create_time, b.create_time, a.name, b.name);
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
                for (matched.items[window.from..window.to]) |job| f.writeJob(&jw, job) catch break :write;
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

    fn listExecutions(f: *FakeRun, arena: Allocator, location: []const u8, job_id: []const u8, params: []const Param) Allocator.Error!Reply {
        const every_job = std.mem.eql(u8, job_id, "-");
        var matched: std.ArrayList(*FakeExecution) = .empty;
        for (f.executions.values()) |execution| {
            if (!std.mem.eql(u8, execution.location, location)) continue;
            if (every_job or std.mem.eql(u8, execution.job, job_id)) try matched.append(arena, execution);
        }
        std.mem.sort(*FakeExecution, matched.items, {}, struct {
            fn inner(_: void, a: *FakeExecution, b: *FakeExecution) bool {
                return newer(a.create_time, b.create_time, a.name, b.name);
            }
        }.inner);
        const window = pageOf(params, matched.items.len, 1000) orelse return pageRefusal(arena);
        var out: std.Io.Writer.Allocating = .init(arena);
        var jw: Stringify = .{ .writer = &out.writer };
        write: {
            jw.beginObject() catch break :write;
            if (window.to > window.from) {
                jw.objectField("executions") catch break :write;
                jw.beginArray() catch break :write;
                for (matched.items[window.from..window.to]) |execution| writeExecution(&jw, execution, false) catch break :write;
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

    /// Newest first; ties by name, for a stable page walk.
    fn newer(a: ?std.Io.Timestamp, b: ?std.Io.Timestamp, a_name: []const u8, b_name: []const u8) bool {
        const at: i96 = if (a) |t| t.nanoseconds else 0;
        const bt: i96 = if (b) |t| t.nanoseconds else 0;
        if (at != bt) return at > bt;
        return std.mem.lessThan(u8, a_name, b_name);
    }

    /// A write's JSON body, an object; null when it is not one.
    fn bodyObject(arena: Allocator, body: []const u8) Allocator.Error!?std.json.ObjectMap {
        const text = if (body.len == 0) "{}" else body;
        const value = std.json.parseFromSliceLeaky(std.json.Value, arena, text, .{}) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            else => return null,
        };
        return switch (value) {
            .object => |o| o,
            else => null,
        };
    }

    fn validateOnly(body: std.json.ObjectMap) bool {
        const v = body.get("validateOnly") orelse return false;
        return v == .bool and v.bool;
    }

    fn badBody(arena: Allocator) Allocator.Error!Reply {
        return fail(arena, 400, "INVALID_ARGUMENT", "Invalid JSON payload received.");
    }

    fn runJob(f: *FakeRun, arena: Allocator, job: *FakeJob, raw: []const u8) Allocator.Error!Reply {
        const body = try bodyObject(arena, raw) orelse return badBody(arena);
        if (body.contains("overrides")) return notModelled(arena, "run overrides");
        // A made-up etag was taken (measured), so the etag is ignored.
        f.runs += 1;
        const s = f.store.allocator();
        const name = try std.fmt.allocPrint(s, "{s}/executions/{s}-{d:0>5}", .{ job.name, job.id, f.runs });
        const at = f.now();
        const status: types.ExecutionStatus = switch (job.run_outcome) {
            .pending => .pending,
            .running => .running,
            .succeeded => .succeeded,
            .failed => .failed,
        };
        const started = status != .pending;
        var execution: FakeExecution = .{
            .name = name,
            .id = name[std.mem.lastIndexOfScalar(u8, name, '/').? + 1 ..],
            .job = job.id,
            .location = job.location,
            .status = status,
            .started = started,
            .task_count = job.task_count,
            .parallelism = if (job.parallelism > 0) job.parallelism else 1,
            .create_time = at,
            .start_time = if (started) at else null,
            .completion_time = if (status.ended()) at else null,
            .log_uri = "",
            .labels = &.{},
        };
        // A validateOnly run names an execution it never makes, as
        // production's did.
        if (validateOnly(body)) return f.validation(arena, job.location, .{ .execution = &execution });
        const held = try s.create(FakeExecution);
        held.* = execution;
        try f.executions.put(f.gpa, held.name, held);
        f.counted(job, held);
        // A run's is the latest created, whatever a test's clock says.
        job.latest = held.name;
        const operation = try f.newOperation(job.location, .{ .execution = held.name });
        return f.operationReply(arena, operation, false, null);
    }

    fn cancelExecution(f: *FakeRun, arena: Allocator, execution: *FakeExecution, raw: []const u8) Allocator.Error!Reply {
        const body = try bodyObject(arena, raw) orelse return badBody(arena);
        if (execution.status.ended()) return fail(arena, 400, "FAILED_PRECONDITION", try arena.print("Execution '{s}' cannot be cancelled because it is not running.", .{execution.id}));
        if (validateOnly(body)) return f.validation(arena, execution.location, .{ .execution = execution });
        execution.cancel_asked = true;
        switch (execution.status) {
            // Production's pending execution read cancelled 0.2 s later.
            .pending => f.move(execution, .cancelled),
            .running => f.move(execution, .cancelling),
            // A second cancel while stopping was taken, and changed
            // nothing.
            else => {},
        }
        const operation = try f.newOperation(execution.location, .{ .execution = execution.name });
        return f.operationReply(arena, operation, false, null);
    }

    fn changeTraffic(f: *FakeRun, arena: Allocator, service: *FakeService, params: []const Param, raw: []const u8) Allocator.Error!Reply {
        for (params) |p| {
            if (!std.mem.eql(u8, p.name, "updateMask") and !std.mem.eql(u8, p.name, "validateOnly")) return notModelled(arena, try arena.print("a traffic change with {s}", .{p.name}));
        }
        const mask_text = paramOf(params, "updateMask") orelse
            return fail(arena, 400, "INVALID_ARGUMENT", "Violation in UpdateServiceRequest.service.template: required field not present.");
        var has_traffic = false;
        var has_etag = false;
        var fields = std.mem.splitScalar(u8, mask_text, ',');
        while (fields.next()) |field| {
            if (std.mem.eql(u8, field, "traffic")) {
                has_traffic = true;
            } else if (std.mem.eql(u8, field, "etag")) {
                has_etag = true;
            } else return notModelled(arena, "an update mask other than traffic or traffic,etag");
        }
        if (!has_traffic) return notModelled(arena, "an update mask other than traffic or traffic,etag");
        const validate_only = if (paramOf(params, "validateOnly")) |v| std.mem.eql(u8, v, "true") else false;

        const body = try bodyObject(arena, raw) orelse return badBody(arena);
        var it = body.iterator();
        while (it.next()) |entry| {
            if (!std.mem.eql(u8, entry.key_ptr.*, "traffic") and !std.mem.eql(u8, entry.key_ptr.*, "etag")) return notModelled(arena, "a traffic change carrying other fields");
        }
        const revision = oneRevision(body) orelse return notModelled(arena, "traffic other than one revision at 100 %");
        const prefix = try arena.print("{s}-", .{service.id});
        if (!std.mem.startsWith(u8, revision, prefix))
            return fail(arena, 400, "INVALID_ARGUMENT", try arena.print("spec.traffic.revision_name[0]: Revision target '{s}' invalid. Expected a revision prefixed with '{s}'.", .{ revision, prefix }));

        // A change to the traffic the service already has changes nothing,
        // and production checked no etag for it.
        const unchanged = service.traffic.len == 1 and service.traffic[0].type == .revision and
            service.traffic[0].percent == 100 and std.mem.eql(u8, service.traffic[0].revision, revision);
        if (has_etag and !unchanged) if (body.get("etag")) |etag_value| {
            if (etag_value != .string) return badBody(arena);
            const given = versionOf(etag_value.string) orelse return notModelled(arena, "an etag the fake did not make");
            if (given != service.version) return fail(arena, 409, "ABORTED", try arena.print("Conflict for resource '{s}': version '{d}' was specified but current version is '{d}'.", .{ service.id, given, service.version }));
        };
        const target: types.TrafficTarget = .{ .type = .revision, .revision = revision, .percent = 100 };
        if (validate_only) {
            var asked = service.*;
            asked.traffic = &.{target};
            return f.validation(arena, service.location, .{ .service = &asked });
        }
        var failure: ?types.Operation.Failure = null;
        if (!unchanged) {
            const s = f.store.allocator();
            const held_target: types.TrafficTarget = .{ .type = .revision, .revision = try s.dupe(u8, revision), .percent = 100 };
            service.traffic = try s.dupe(types.TrafficTarget, &.{held_target});
            service.generation = (service.generation orelse 1) + 1;
            service.observed_generation = service.generation;
            f.version += 1;
            service.version = f.version;
            service.update_time = f.now();
            const revision_name = try arena.print("{s}/revisions/{s}", .{ service.name, revision });
            if (f.revisions.get(revision_name)) |held| {
                if (readyOf(held)) |ready| if (ready.state != .succeeded) {
                    failure = .{ .code = 5, .message = try s.dupe(u8, ready.message) };
                };
                if (readyOf(held) == null) failure = .{ .code = 5, .message = try std.fmt.allocPrint(s, "Revision '{s}' is not ready.", .{revision}) };
            } else {
                failure = .{ .code = 9, .message = try std.fmt.allocPrint(s, "Revision '{s}' does not exist or is deleted. Update all traffic to route to currently available revisions.", .{revision}) };
            }
            if (failure) |why| {
                // The asked traffic stays, the old revision serving, and the
                // service reads failed with the operation's words.
                service.terminal_condition = .{ .type = "Ready", .state = .failed, .message = why.message, .last_transition_time = service.update_time };
            } else {
                service.traffic_statuses = service.traffic;
                service.terminal_condition = .{ .type = "Ready", .state = .succeeded, .last_transition_time = service.update_time };
            }
        }
        const operation = try f.newOperation(service.location, .{ .service = .{ .name = service.name, .failure = failure } });
        return f.operationReply(arena, operation, false, null);
    }

    /// The one revision a traffic change names at 100 %, or null for any
    /// other traffic.
    fn oneRevision(body: std.json.ObjectMap) ?[]const u8 {
        const traffic = body.get("traffic") orelse return null;
        if (traffic != .array or traffic.array.items.len != 1) return null;
        const target = traffic.array.items[0];
        if (target != .object) return null;
        var revision: ?[]const u8 = null;
        var percent_ok = false;
        var type_ok = false;
        var it = target.object.iterator();
        while (it.next()) |entry| {
            const key = entry.key_ptr.*;
            const v = entry.value_ptr.*;
            if (std.mem.eql(u8, key, "type")) {
                type_ok = v == .string and std.mem.eql(u8, v.string, "TRAFFIC_TARGET_ALLOCATION_TYPE_REVISION");
            } else if (std.mem.eql(u8, key, "revision")) {
                if (v == .string) revision = v.string;
            } else if (std.mem.eql(u8, key, "percent")) {
                percent_ok = v == .integer and v.integer == 100;
            } else return null;
        }
        if (!type_ok or !percent_ok) return null;
        const r = revision orelse return null;
        return if (r.len > 0) r else null;
    }

    fn readyOf(revision: *const FakeRevision) ?types.Condition {
        for (revision.conditions) |c| {
            if (std.mem.eql(u8, c.type, "Ready")) return c;
        }
        return null;
    }

    /// The version in an etag the fake made, `"v<version>"`, its quote
    /// characters there or not (production took one without them).
    fn versionOf(etag: []const u8) ?u64 {
        var text = etag;
        if (text.len >= 2 and text[0] == '"' and text[text.len - 1] == '"') text = text[1 .. text.len - 1];
        if (text.len < 2 or text[0] != 'v') return null;
        return std.fmt.parseInt(u64, text[1..], 10) catch null;
    }

    fn newOperation(f: *FakeRun, location: []const u8, subject: @FieldType(FakeOperation, "subject")) Allocator.Error!*FakeOperation {
        f.made += 1;
        const s = f.store.allocator();
        const held = try s.create(FakeOperation);
        held.* = .{
            .name = try std.fmt.allocPrint(s, "projects/{s}/locations/{s}/operations/fake-{d}", .{ f.options.project_id, location, f.made }),
            .subject = subject,
        };
        try f.operations.put(f.gpa, held.name, held);
        return held;
    }

    /// What a `validateOnly` request answers: an operation, not done,
    /// whose metadata is what the change would make; nothing is kept but
    /// its name.
    fn validation(f: *FakeRun, arena: Allocator, location: []const u8, would: Would) Allocator.Error!Reply {
        const operation = try f.newOperation(location, .validation);
        return f.operationReply(arena, operation, false, would);
    }

    const Would = union(enum) { execution: *const FakeExecution, service: *const FakeService };

    /// An operation as production answers it: `reading` for a read after
    /// the write's own answer, when a traffic change's is done.
    fn operationReply(f: *FakeRun, arena: Allocator, operation: *const FakeOperation, reading: bool, would: ?Would) Allocator.Error!Reply {
        var out: std.Io.Writer.Allocating = .init(arena);
        var jw: Stringify = .{ .writer = &out.writer };
        f.writeOperation(&jw, operation, reading, would) catch return error.OutOfMemory;
        return .{ .status = 200, .body = out.written() };
    }

    fn writeOperation(f: *FakeRun, jw: *Stringify, operation: *const FakeOperation, reading: bool, would: ?Would) Stringify.Error!void {
        try jw.beginObject();
        try jw.objectField("name");
        try jw.write(operation.name);
        var done = false;
        var failure: ?types.Operation.Failure = null;
        const Subject = union(enum) { execution: *const FakeExecution, service: *const FakeService };
        const subject: Subject = switch (operation.subject) {
            .validation => switch (would.?) {
                .execution => |e| .{ .execution = e },
                .service => |s| .{ .service = s },
            },
            .execution => |name| e: {
                const execution = f.executions.get(name).?;
                done = execution.status.ended();
                // A cancel that met the task's start failed both
                // operations with code 2; a task that exited 1, the run's
                // with code 10 (measured).
                if (done and execution.status == .failed) failure = .{
                    .code = if (execution.cancel_asked) 2 else 10,
                    .message = if (execution.cancel_asked) "Unspecified error." else "",
                };
                break :e .{ .execution = execution };
            },
            .service => |change| s: {
                done = reading;
                if (done) failure = change.failure;
                break :s .{ .service = f.services.get(change.name).? };
            },
        };
        try jw.objectField("metadata");
        switch (subject) {
            .execution => |e| try writeExecution(jw, e, true),
            .service => |s| try writeServiceObject(jw, s, true),
        }
        if (done) {
            try jw.objectField("done");
            try jw.write(true);
        }
        if (failure) |why| {
            try jw.objectField("error");
            try jw.beginObject();
            try jw.objectField("code");
            try jw.write(why.code);
            try jw.objectField("message");
            switch (subject) {
                // Production's words for a task that exited 1.
                .execution => |e| if (why.code == 10)
                    try jw.print("\"Task {s}-task0 failed with exit code: 1 and message: The container exited with an error.\"", .{e.id})
                else
                    try jw.write(why.message),
                .service => try jw.write(why.message),
            }
            try jw.endObject();
        } else if (done) {
            try jw.objectField("response");
            switch (subject) {
                .execution => |e| try writeExecution(jw, e, true),
                .service => |s| try writeServiceObject(jw, s, true),
            }
        }
        try jw.endObject();
    }

    fn writeJob(f: *FakeRun, jw: *Stringify, job: *const FakeJob) Stringify.Error!void {
        var buf: [core.timestamp.max_len]u8 = undefined;
        try jw.beginObject();
        try jw.objectField("name");
        try jw.write(job.name);
        try jw.objectField("generation");
        try jw.write("1");
        if (job.labels.len > 0) {
            try jw.objectField("labels");
            try writeLabelObject(jw, job.labels);
        }
        if (job.create_time) |t| {
            try jw.objectField("createTime");
            try jw.write(core.timestamp.format(&buf, t));
        }
        if (job.update_time) |t| {
            try jw.objectField("updateTime");
            try jw.write(core.timestamp.format(&buf, t));
        }
        // `{}` before the first run, and the id alone after, as production
        // sent them.
        try jw.objectField("latestCreatedExecution");
        try jw.beginObject();
        if (job.latest) |name| if (f.executions.get(name)) |latest| {
            try jw.objectField("name");
            try jw.write(latest.id);
            if (latest.create_time) |t| {
                try jw.objectField("createTime");
                try jw.write(core.timestamp.format(&buf, t));
            }
            if (latest.completion_time) |t| {
                try jw.objectField("completionTime");
                try jw.write(core.timestamp.format(&buf, t));
            }
            try jw.objectField("completionStatus");
            try jw.write(switch (latest.status) {
                .pending => "EXECUTION_PENDING",
                .succeeded => "EXECUTION_SUCCEEDED",
                .failed => "EXECUTION_FAILED",
                .cancelled => "EXECUTION_CANCELLED",
                else => "EXECUTION_RUNNING",
            });
        };
        try jw.endObject();
        try jw.objectField("template");
        try jw.beginObject();
        try jw.objectField("taskCount");
        try jw.write(job.task_count);
        if (job.parallelism > 0) {
            try jw.objectField("parallelism");
            try jw.write(job.parallelism);
        }
        try jw.objectField("template");
        try jw.beginObject();
        try jw.objectField("containers");
        try jw.beginArray();
        for (job.containers) |container| {
            try jw.beginObject();
            if (container.name.len > 0) {
                try jw.objectField("name");
                try jw.write(container.name);
            }
            try jw.objectField("image");
            try jw.write(container.image);
            try jw.endObject();
        }
        try jw.endArray();
        if (job.max_retries) |n| {
            try jw.objectField("maxRetries");
            try jw.write(n);
        }
        if (job.task_timeout_s) |seconds| {
            try jw.objectField("timeout");
            try jw.print("\"{d}s\"", .{seconds});
        }
        if (job.service_account.len > 0) {
            try jw.objectField("serviceAccount");
            try jw.write(job.service_account);
        }
        try jw.endObject();
        try jw.endObject();
        if (job.terminal_condition) |condition| {
            try jw.objectField("terminalCondition");
            try writeCondition(jw, condition);
        }
        if (job.execution_count > 0) {
            try jw.objectField("executionCount");
            try jw.write(job.execution_count);
        }
        try jw.objectField("etag");
        try jw.print("\"\\\"v{d}\\\"\"", .{job.version});
        try jw.endObject();
    }

    /// An execution with the conditions and counts production showed for
    /// its status (2026-10-21).
    fn writeExecution(jw: *Stringify, execution: *const FakeExecution, with_type: bool) Stringify.Error!void {
        var buf: [core.timestamp.max_len]u8 = undefined;
        try jw.beginObject();
        if (with_type) {
            try jw.objectField("@type");
            try jw.write("type.googleapis.com/google.cloud.run.v2.Execution");
        }
        try jw.objectField("name");
        try jw.write(execution.name);
        try jw.objectField("generation");
        try jw.write("1");
        if (execution.labels.len > 0) {
            try jw.objectField("labels");
            try writeLabelObject(jw, execution.labels);
        }
        if (execution.create_time) |t| {
            try jw.objectField("createTime");
            try jw.write(core.timestamp.format(&buf, t));
        }
        if (execution.start_time) |t| {
            try jw.objectField("startTime");
            try jw.write(core.timestamp.format(&buf, t));
        }
        if (execution.completion_time) |t| {
            try jw.objectField("completionTime");
            try jw.write(core.timestamp.format(&buf, t));
        }
        try jw.objectField("job");
        try jw.write(execution.job);
        try jw.objectField("parallelism");
        try jw.write(execution.parallelism);
        try jw.objectField("taskCount");
        try jw.write(execution.task_count);
        try jw.objectField("conditions");
        try jw.beginArray();
        try writeExecutionCondition(jw, "Started", if (execution.started) "CONDITION_SUCCEEDED" else "CONDITION_RECONCILING", "", "");
        switch (execution.status) {
            .succeeded => try writeExecutionCondition(jw, "Completed", "CONDITION_SUCCEEDED", "", ""),
            // A cancel that met the task's start: failed, no reason.
            .failed => if (execution.cancel_asked) try writeExecutionCondition(jw, "Completed", "CONDITION_FAILED", "", "") else {
                try jw.beginObject();
                try jw.objectField("type");
                try jw.write("Completed");
                try jw.objectField("state");
                try jw.write("CONDITION_FAILED");
                try jw.objectField("message");
                try jw.print("\"Task {s}-task0 failed with exit code: 1 and message: The container exited with an error.\"", .{execution.id});
                try jw.objectField("executionReason");
                try jw.write("NON_ZERO_EXIT_CODE");
                try jw.endObject();
            },
            .cancelled => try writeExecutionCondition(jw, "Completed", "CONDITION_FAILED", "Cancelled by user.", "CANCELLED"),
            else => try writeExecutionCondition(jw, "Completed", "CONDITION_RECONCILING", "", ""),
        }
        try jw.endArray();
        if (execution.log_uri.len > 0) {
            try jw.objectField("logUri");
            try jw.write(execution.log_uri);
        }
        const count_field: ?[]const u8 = switch (execution.status) {
            .running => "runningCount",
            .cancelling, .cancelled => "cancelledCount",
            .succeeded => "succeededCount",
            .failed => if (execution.cancel_asked) "cancelledCount" else "failedCount",
            else => null,
        };
        if (count_field) |field| {
            try jw.objectField(field);
            try jw.write(execution.task_count);
        }
        if (!execution.status.ended()) {
            try jw.objectField("reconciling");
            try jw.write(true);
        }
        try jw.endObject();
    }

    fn writeExecutionCondition(jw: *Stringify, kind: []const u8, state: []const u8, message: []const u8, reason: []const u8) Stringify.Error!void {
        try jw.beginObject();
        try jw.objectField("type");
        try jw.write(kind);
        try jw.objectField("state");
        try jw.write(state);
        if (message.len > 0) {
            try jw.objectField("message");
            try jw.write(message);
        }
        if (reason.len > 0) {
            try jw.objectField("executionReason");
            try jw.write(reason);
        }
        try jw.endObject();
    }

    fn serviceNameOf(arena: Allocator, project: []const u8, location: []const u8, id: []const u8) Allocator.Error![]const u8 {
        var w: std.Io.Writer.Allocating = .init(arena);
        w.writer.print("projects/{s}/locations/{s}/services/{s}", .{ project, location, id }) catch return error.OutOfMemory;
        return w.written();
    }

    fn listLocations(f: *FakeRun, arena: Allocator, params: []const Param) Allocator.Error!Reply {
        var sorted: std.ArrayList([]const u8) = .empty;
        try sorted.appendSlice(arena, f.locations.keys());
        std.mem.sort([]const u8, sorted.items, {}, stringLess);
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

    fn listServices(f: *FakeRun, arena: Allocator, location: []const u8, params: []const Param) Allocator.Error!Reply {
        const everywhere = std.mem.eql(u8, location, "-");
        var matched: std.ArrayList(*FakeService) = .empty;
        for (f.services.values()) |service| {
            if (everywhere or std.mem.eql(u8, service.location, location)) try matched.append(arena, service);
        }
        std.mem.sort(*FakeService, matched.items, {}, struct {
            fn inner(_: void, a: *FakeService, b: *FakeService) bool {
                return std.mem.lessThan(u8, a.name, b.name);
            }
        }.inner);
        const window = pageOf(params, matched.items.len, 1000) orelse return pageRefusal(arena);
        var out: std.Io.Writer.Allocating = .init(arena);
        var jw: Stringify = .{ .writer = &out.writer };
        write: {
            jw.beginObject() catch break :write;
            if (window.to > window.from) {
                jw.objectField("services") catch break :write;
                jw.beginArray() catch break :write;
                for (matched.items[window.from..window.to]) |service| writeService(&jw, service) catch break :write;
                jw.endArray() catch break :write;
            }
            if (window.next) |n| {
                jw.objectField("nextPageToken") catch break :write;
                jw.print("\"p{d}\"", .{n}) catch break :write;
            }
            if (everywhere and f.unreachable_regions.len > 0) {
                jw.objectField("unreachable") catch break :write;
                jw.beginArray() catch break :write;
                for (f.unreachable_regions) |region| jw.write(region) catch break :write;
                jw.endArray() catch break :write;
            }
            jw.endObject() catch break :write;
            return .{ .status = 200, .body = out.written() };
        }
        return error.OutOfMemory;
    }

    fn listRevisions(f: *FakeRun, arena: Allocator, location: []const u8, service_id: []const u8, params: []const Param) Allocator.Error!Reply {
        const everywhere = std.mem.eql(u8, service_id, "-");
        var matched: std.ArrayList(*FakeRevision) = .empty;
        for (f.revisions.values()) |revision| {
            if (!std.mem.eql(u8, revision.location, location)) continue;
            if (everywhere or std.mem.eql(u8, revision.service, service_id)) try matched.append(arena, revision);
        }
        // Newest first, as production answered the revisions after the
        // bad deploy; ties by name for a stable page walk.
        std.mem.sort(*FakeRevision, matched.items, {}, struct {
            fn inner(_: void, a: *FakeRevision, b: *FakeRevision) bool {
                const at: i96 = if (a.create_time) |t| t.nanoseconds else 0;
                const bt: i96 = if (b.create_time) |t| t.nanoseconds else 0;
                if (at != bt) return at > bt;
                return std.mem.lessThan(u8, a.name, b.name);
            }
        }.inner);
        const window = pageOf(params, matched.items.len, 1000) orelse return pageRefusal(arena);
        var out: std.Io.Writer.Allocating = .init(arena);
        var jw: Stringify = .{ .writer = &out.writer };
        write: {
            jw.beginObject() catch break :write;
            if (window.to > window.from) {
                jw.objectField("revisions") catch break :write;
                jw.beginArray() catch break :write;
                for (matched.items[window.from..window.to]) |revision| writeRevision(&jw, revision) catch break :write;
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

    fn writeService(jw: *Stringify, service: *const FakeService) Stringify.Error!void {
        return writeServiceObject(jw, service, false);
    }

    /// A service, with its `@type` first inside an operation.
    fn writeServiceObject(jw: *Stringify, service: *const FakeService, with_type: bool) Stringify.Error!void {
        var buf: [core.timestamp.max_len]u8 = undefined;
        try jw.beginObject();
        if (with_type) {
            try jw.objectField("@type");
            try jw.write("type.googleapis.com/google.cloud.run.v2.Service");
        }
        try jw.objectField("name");
        try jw.write(service.name);
        if (service.description.len > 0) {
            try jw.objectField("description");
            try jw.write(service.description);
        }
        if (service.generation) |n| {
            try jw.objectField("generation");
            try jw.print("\"{d}\"", .{n});
        }
        if (service.labels.len > 0) {
            try jw.objectField("labels");
            try writeLabelObject(jw, service.labels);
        }
        if (service.create_time) |t| {
            try jw.objectField("createTime");
            try jw.write(core.timestamp.format(&buf, t));
        }
        if (service.update_time) |t| {
            try jw.objectField("updateTime");
            try jw.write(core.timestamp.format(&buf, t));
        }
        if (service.creator.len > 0) {
            try jw.objectField("creator");
            try jw.write(service.creator);
        }
        if (service.last_modifier.len > 0) {
            try jw.objectField("lastModifier");
            try jw.write(service.last_modifier);
        }
        if (service.traffic.len > 0) {
            try jw.objectField("traffic");
            try writeTraffic(jw, service.traffic, false);
        }
        if (service.urls.len > 0) {
            try jw.objectField("urls");
            try jw.beginArray();
            for (service.urls) |url| try jw.write(url);
            try jw.endArray();
        }
        if (service.observed_generation) |n| {
            try jw.objectField("observedGeneration");
            try jw.print("\"{d}\"", .{n});
        }
        if (service.terminal_condition) |condition| {
            try jw.objectField("terminalCondition");
            try writeCondition(jw, condition);
        }
        if (service.conditions.len > 0) {
            try jw.objectField("conditions");
            try jw.beginArray();
            for (service.conditions) |condition| try writeCondition(jw, condition);
            try jw.endArray();
        }
        if (service.latest_ready_revision.len > 0) {
            try jw.objectField("latestReadyRevision");
            try jw.print("\"{s}/revisions/{s}\"", .{ service.name, service.latest_ready_revision });
        }
        if (service.latest_created_revision.len > 0) {
            try jw.objectField("latestCreatedRevision");
            try jw.print("\"{s}/revisions/{s}\"", .{ service.name, service.latest_created_revision });
        }
        if (service.traffic_statuses.len > 0) {
            try jw.objectField("trafficStatuses");
            try writeTraffic(jw, service.traffic_statuses, true);
        }
        if (service.uri.len > 0) {
            try jw.objectField("uri");
            try jw.write(service.uri);
        }
        if (service.reconciling) {
            try jw.objectField("reconciling");
            try jw.write(true);
        }
        try jw.objectField("etag");
        try jw.print("\"\\\"v{d}\\\"\"", .{service.version});
        try jw.endObject();
    }

    fn writeRevision(jw: *Stringify, revision: *const FakeRevision) Stringify.Error!void {
        var buf: [core.timestamp.max_len]u8 = undefined;
        try jw.beginObject();
        try jw.objectField("name");
        try jw.write(revision.name);
        if (revision.generation) |n| {
            try jw.objectField("generation");
            try jw.print("\"{d}\"", .{n});
        }
        if (revision.labels.len > 0) {
            try jw.objectField("labels");
            try writeLabelObject(jw, revision.labels);
        }
        if (revision.create_time) |t| {
            try jw.objectField("createTime");
            try jw.write(core.timestamp.format(&buf, t));
        }
        if (revision.update_time) |t| {
            try jw.objectField("updateTime");
            try jw.write(core.timestamp.format(&buf, t));
        }
        try jw.objectField("service");
        try jw.write(revision.service);
        if (revision.service_account.len > 0) {
            try jw.objectField("serviceAccount");
            try jw.write(revision.service_account);
        }
        if (revision.containers.len > 0) {
            try jw.objectField("containers");
            try jw.beginArray();
            for (revision.containers) |container| {
                try jw.beginObject();
                if (container.name.len > 0) {
                    try jw.objectField("name");
                    try jw.write(container.name);
                }
                try jw.objectField("image");
                try jw.write(container.image);
                try jw.endObject();
            }
            try jw.endArray();
        }
        if (revision.conditions.len > 0) {
            try jw.objectField("conditions");
            try jw.beginArray();
            for (revision.conditions) |condition| try writeCondition(jw, condition);
            try jw.endArray();
        }
        if (revision.log_uri.len > 0) {
            try jw.objectField("logUri");
            try jw.write(revision.log_uri);
        }
        try jw.endObject();
    }

    fn writeTraffic(jw: *Stringify, targets: []const types.TrafficTarget, with_uri: bool) Stringify.Error!void {
        try jw.beginArray();
        for (targets) |target| {
            try jw.beginObject();
            try jw.objectField("type");
            try jw.write(switch (target.type) {
                .latest => "TRAFFIC_TARGET_ALLOCATION_TYPE_LATEST",
                .revision => "TRAFFIC_TARGET_ALLOCATION_TYPE_REVISION",
                else => "TRAFFIC_TARGET_ALLOCATION_TYPE_UNSPECIFIED",
            });
            if (target.revision.len > 0) {
                try jw.objectField("revision");
                try jw.write(target.revision);
            }
            if (target.percent != 0) {
                try jw.objectField("percent");
                try jw.print("{d}", .{target.percent});
            }
            if (target.tag.len > 0) {
                try jw.objectField("tag");
                try jw.write(target.tag);
            }
            if (with_uri and target.uri.len > 0) {
                try jw.objectField("uri");
                try jw.write(target.uri);
            }
            try jw.endObject();
        }
        try jw.endArray();
    }

    fn writeCondition(jw: *Stringify, condition: types.Condition) Stringify.Error!void {
        try jw.beginObject();
        if (condition.type.len > 0) {
            try jw.objectField("type");
            try jw.write(condition.type);
        }
        try jw.objectField("state");
        try jw.write(switch (condition.state) {
            .succeeded => "CONDITION_SUCCEEDED",
            .failed => "CONDITION_FAILED",
            .pending => "CONDITION_PENDING",
            .reconciling => "CONDITION_RECONCILING",
            else => "STATE_UNSPECIFIED",
        });
        if (condition.message.len > 0) {
            try jw.objectField("message");
            try jw.write(condition.message);
        }
        if (condition.last_transition_time) |t| {
            var buf: [core.timestamp.max_len]u8 = undefined;
            try jw.objectField("lastTransitionTime");
            try jw.write(core.timestamp.format(&buf, t));
        }
        if (condition.severity != .unspecified) {
            try jw.objectField("severity");
            try jw.write(switch (condition.severity) {
                .@"error" => "ERROR",
                .warning => "WARNING",
                .info => "INFO",
                else => "SEVERITY_UNSPECIFIED",
            });
        }
        if (condition.reason.len > 0) {
            try jw.objectField("reason");
            try jw.write(condition.reason);
        }
        try jw.endObject();
    }

    fn writeLabelObject(jw: *Stringify, labels: []const types.Label) Stringify.Error!void {
        try jw.beginObject();
        for (labels) |l| {
            try jw.objectField(l.key);
            try jw.write(l.value);
        }
        try jw.endObject();
    }

    fn stringLess(_: void, a: []const u8, b: []const u8) bool {
        return std.mem.lessThan(u8, a, b);
    }

    // Routes and parameters.

    const Route = struct {
        project: []const u8,
        kind: union(enum) {
            locations,
            services: []const u8,
            service: struct { location: []const u8, id: []const u8 },
            revisions: struct { location: []const u8, service: []const u8 },
            revision: struct { location: []const u8, service: []const u8, id: []const u8 },
            jobs: []const u8,
            job: JobRoute,
            /// `jobs/J:run`.
            run: JobRoute,
            executions: struct { location: []const u8, job: []const u8 },
            execution: ExecutionRoute,
            /// `executions/E:cancel`.
            cancel: ExecutionRoute,
            operation: struct { location: []const u8, id: []const u8 },
        },
    };

    const JobRoute = struct { location: []const u8, id: []const u8 };
    const ExecutionRoute = struct { location: []const u8, job: []const u8, id: []const u8 };

    fn pathOf(url: []const u8) []const u8 {
        const scheme = std.mem.indexOf(u8, url, "://") orelse return url;
        const rest = url[scheme + 3 ..];
        const slash = std.mem.indexOfScalar(u8, rest, '/') orelse return "/";
        return rest[slash..];
    }

    fn parseRoute(path: []const u8) ?Route {
        // v1's one path, the locations list.
        if (std.mem.startsWith(u8, path, "/v1/projects/")) {
            var parts = std.mem.splitScalar(u8, path["/v1/projects/".len..], '/');
            const project = parts.next() orelse return null;
            if (!std.mem.eql(u8, parts.next() orelse return null, "locations")) return null;
            if (parts.next() != null) return null;
            return .{ .project = project, .kind = .locations };
        }
        if (!std.mem.startsWith(u8, path, "/v2/projects/")) return null;
        var parts = std.mem.splitScalar(u8, path["/v2/projects/".len..], '/');
        const project = parts.next() orelse return null;
        if (!std.mem.eql(u8, parts.next() orelse return null, "locations")) return null;
        const location = parts.next() orelse return null;
        const collection = parts.next() orelse return null;
        if (std.mem.eql(u8, collection, "jobs")) {
            const job_part = parts.next() orelse return .{ .project = project, .kind = .{ .jobs = location } };
            const sub = parts.next() orelse {
                if (std.mem.endsWith(u8, job_part, ":run")) return .{ .project = project, .kind = .{ .run = .{ .location = location, .id = job_part[0 .. job_part.len - ":run".len] } } };
                return .{ .project = project, .kind = .{ .job = .{ .location = location, .id = job_part } } };
            };
            if (!std.mem.eql(u8, sub, "executions")) return null;
            const execution_part = parts.next() orelse return .{ .project = project, .kind = .{ .executions = .{ .location = location, .job = job_part } } };
            if (parts.next() != null) return null;
            if (std.mem.endsWith(u8, execution_part, ":cancel")) return .{ .project = project, .kind = .{ .cancel = .{ .location = location, .job = job_part, .id = execution_part[0 .. execution_part.len - ":cancel".len] } } };
            return .{ .project = project, .kind = .{ .execution = .{ .location = location, .job = job_part, .id = execution_part } } };
        }
        if (std.mem.eql(u8, collection, "operations")) {
            const id = parts.next() orelse return null;
            if (parts.next() != null) return null;
            return .{ .project = project, .kind = .{ .operation = .{ .location = location, .id = id } } };
        }
        if (!std.mem.eql(u8, collection, "services")) return null;
        const service_id = parts.next() orelse return .{ .project = project, .kind = .{ .services = location } };
        const revisions_word = parts.next() orelse return .{ .project = project, .kind = .{ .service = .{ .location = location, .id = service_id } } };
        if (!std.mem.eql(u8, revisions_word, "revisions")) return null;
        const revision_id = parts.next() orelse return .{ .project = project, .kind = .{ .revisions = .{ .location = location, .service = service_id } } };
        if (parts.next() != null) return null;
        return .{ .project = project, .kind = .{ .revision = .{ .location = location, .service = service_id, .id = revision_id } } };
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
const names = @import("names.zig");
const test_util = @import("test_util.zig");

const Bench = struct {
    clock: core.testing.FakeClock,
    fake: FakeRun,
    token: core.StaticToken,
    diag: core.Diagnostics,
    client: Client,

    fn init(b: *Bench, options: FakeRun.Options) !void {
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

    fn raw(b: *Bench, arena: Allocator, method: tp.Method, path: []const u8) !FakeRun.Reply {
        return b.fake.serve(.{ .method = method, .url = path, .bearer = "t" }, arena);
    }
};

fn ts(text: []const u8) std.Io.Timestamp {
    return core.timestamp.parse(text) catch unreachable;
}

/// The probe's service and both revisions, as production answered them
/// after the bad deploy, fed back through `putService` and `putRevision`.
fn seedProbe(fake: *FakeRun) !void {
    try fake.putLocation("us-central1");
    _ = try fake.putService(.{
        .location = "us-central1",
        .id = "zigps-a12c61",
        .uri = "https://zigps-a12c61-el44yx5gia-uc.a.run.app",
        .urls = &.{ "https://zigps-a12c61-82150720798.us-central1.run.app", "https://zigps-a12c61-el44yx5gia-uc.a.run.app" },
        .latest_ready_revision = "zigps-a12c61-00001-ct8",
        .latest_created_revision = "zigps-a12c61-00002-qmv",
        .traffic = &.{.{ .type = .latest, .percent = 100 }},
        .traffic_statuses = &.{.{ .type = .latest, .revision = "zigps-a12c61-00001-ct8", .percent = 100 }},
        .terminal_condition = .{ .type = "Ready", .state = .failed, .message = "Image 'us-docker.pkg.dev/cloudrun/container/hello:zigps-no-such-tag' not found.", .reason = "REVISION_FAILED", .last_transition_time = ts("2026-10-19T19:32:39.040916Z") },
        .conditions = &.{
            .{ .type = "RoutesReady", .state = .succeeded, .last_transition_time = ts("2026-10-19T19:32:36.714800Z") },
            .{ .type = "ConfigurationsReady", .state = .failed, .last_transition_time = ts("2026-10-19T19:32:38.903177Z") },
        },
        .create_time = ts("2026-10-19T19:32:31.428729Z"),
        .update_time = ts("2026-10-19T19:32:38.561685Z"),
        .creator = "zig-gcp@extractctl.iam.gserviceaccount.com",
        .generation = 2,
        .observed_generation = 2,
        .labels = &.{.{ .key = "zigps", .value = "probe" }},
    });
    _ = try fake.putRevision(.{
        .location = "us-central1",
        .service = "zigps-a12c61",
        .id = "zigps-a12c61-00001-ct8",
        .create_time = ts("2026-10-19T19:32:31.559921Z"),
        .generation = 1,
        .containers = &.{.{ .name = "hello-1", .image = "us-docker.pkg.dev/cloudrun/container/hello@sha256:efd04605322d5d1ce6b1fd3dfc63a9c1fb2b99c97194ec316c0df0fd8f5dcf01" }},
        .conditions = &.{.{ .type = "Ready", .state = .succeeded, .message = "Deploying revision succeeded in 3.77s.", .last_transition_time = ts("2026-10-19T19:32:35.332279Z") }},
        .log_uri = "https://console.cloud.google.com/logs/viewer?project=extractctl",
    });
    _ = try fake.putRevision(.{
        .location = "us-central1",
        .service = "zigps-a12c61",
        .id = "zigps-a12c61-00002-qmv",
        .create_time = ts("2026-10-19T19:32:38.561685Z"),
        .generation = 2,
        .containers = &.{.{ .name = "hello-1", .image = "us-docker.pkg.dev/cloudrun/container/hello:zigps-no-such-tag" }},
        .conditions = &.{.{ .type = "Ready", .state = .failed, .message = "Image 'us-docker.pkg.dev/cloudrun/container/hello:zigps-no-such-tag' not found.", .last_transition_time = ts("2026-10-19T19:32:38.903177Z") }},
    });
}

test "the probe's service put in, read back as production answered it" {
    var b: Bench = undefined;
    try b.init(.{ .project_id = "extractctl" });
    defer b.deinit();
    try seedProbe(&b.fake);
    try testing.expectEqual(1, b.fake.serviceCount());
    try testing.expectEqual(2, b.fake.revisionCount());

    // Field for field what production.service_failed decodes to, for
    // everything the fake's put covers.
    var out: std.heap.ArenaAllocator = .init(testing.allocator);
    defer out.deinit();
    var scratch: std.heap.ArenaAllocator = .init(testing.allocator);
    defer scratch.deinit();
    const wanted = try codec.decodeService(out.allocator(), scratch.allocator(), production.service_failed);
    var got = try b.client.getService("us-central1", "zigps-a12c61");
    defer got.deinit();
    try testing.expectEqualStrings(wanted.name, got.value.name);
    try testing.expectEqualStrings(wanted.id, got.value.id);
    try testing.expectEqual(wanted.ready(), got.value.ready());
    try testing.expectEqual(wanted.terminal_condition.?.state, got.value.terminal_condition.?.state);
    try testing.expectEqualStrings(wanted.terminal_condition.?.reason, got.value.terminal_condition.?.reason);
    try testing.expectEqualStrings(wanted.terminal_condition.?.message, got.value.terminal_condition.?.message);
    try testing.expectEqualStrings(wanted.latest_ready_revision, got.value.latest_ready_revision);
    try testing.expectEqualStrings(wanted.latest_created_revision, got.value.latest_created_revision);
    try testing.expectEqualStrings(wanted.uri, got.value.uri);

    // The revisions, newest first as production answered them, through
    // the service and through services/-.
    var revisions = try b.client.listRevisions("us-central1", "zigps-a12c61", .{});
    defer revisions.deinit();
    try testing.expectEqual(2, revisions.value.revisions.len);
    try testing.expectEqualStrings("zigps-a12c61-00002-qmv", revisions.value.revisions[0].id);
    try testing.expect(!revisions.value.revisions[0].ready());
    try testing.expect(std.mem.indexOf(u8, revisions.value.revisions[0].readyCondition().?.message, "zigps-no-such-tag") != null);
    try testing.expect(revisions.value.revisions[1].ready());
    var everywhere = try b.client.listRevisions("us-central1", "-", .{});
    defer everywhere.deinit();
    try testing.expectEqual(2, everywhere.value.revisions.len);
    var by_name = try b.client.getRevisionNamed("projects/extractctl/locations/us-central1/services/zigps-a12c61/revisions/zigps-a12c61-00001-ct8");
    defer by_name.deinit();
    try testing.expect(by_name.value.ready());
    // On the wire the latest revisions carry their full names, as
    // production sends them; the client trims to the id either way.
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const raw_service = try b.raw(arena.allocator(), .GET, "https://host/v2/projects/extractctl/locations/us-central1/services/zigps-a12c61");
    try testing.expectEqual(200, raw_service.status);
    try testing.expect(std.mem.indexOf(u8, raw_service.body, "\"latestReadyRevision\":\"projects/extractctl/locations/us-central1/services/zigps-a12c61/revisions/zigps-a12c61-00001-ct8\"") != null);
    try testing.expect(std.mem.startsWith(u8, by_name.value.containers[0].image, "us-docker.pkg.dev/cloudrun/container/hello@sha256:"));
}

test "locations, the - location, pages and refusals as production answered" {
    var b: Bench = undefined;
    try b.init(.{});
    defer b.deinit();
    try b.fake.putLocation("us-east1");
    try b.fake.putLocation("us-central1");
    try b.fake.setUnreachable(&.{ "europe-west15", "me-central2" });
    for ([_][]const u8{ "svc-c", "svc-a" }) |id| {
        _ = try b.fake.putService(.{ .location = "us-central1", .id = id, .terminal_condition = .{ .type = "Ready", .state = .succeeded } });
    }
    _ = try b.fake.putService(.{ .location = "us-east1", .id = "svc-b", .terminal_condition = .{ .type = "Ready", .state = .succeeded } });

    var locations = try b.client.listLocations(.{});
    defer locations.deinit();
    try testing.expectEqual(2, locations.value.locations.len);
    try testing.expectEqualStrings("us-central1", locations.value.locations[0].id);

    // One region: sorted by name, paged with a token.
    var page = try b.client.listServices("us-central1", .{ .page_size = 1 });
    defer page.deinit();
    try testing.expectEqual(1, page.value.services.len);
    try testing.expectEqualStrings("svc-a", page.value.services[0].id);
    // A regional listing names no unreachable regions: only '-' does.
    try testing.expectEqual(0, page.value.unreachable_regions.len);
    var rest = try b.client.listServices("us-central1", .{ .page_size = 1, .page_token = page.value.next_page_token.? });
    defer rest.deinit();
    try testing.expectEqualStrings("svc-c", rest.value.services[0].id);
    try testing.expectEqual(null, rest.value.next_page_token);

    // The - location: every region, with the unreachable regions named.
    var everywhere = try b.client.listServices("-", .{});
    defer everywhere.deinit();
    try testing.expectEqual(3, everywhere.value.services.len);
    try testing.expectEqual(2, everywhere.value.unreachable_regions.len);
    try testing.expectEqualStrings("europe-west15", everywhere.value.unreachable_regions[0]);

    // An empty region is {}, and so are an unknown service's revisions.
    var empty = try b.client.listRevisions("us-east1", "zigps-nobody", .{});
    defer empty.deinit();
    try testing.expectEqual(0, empty.value.revisions.len);

    // Production's words for what it refused.
    try testing.expectError(error.InvalidArgument, b.client.listServices("us-fake1", .{}));
    try testing.expectEqualStrings("The request has errors", b.diag.message());
    try testing.expectError(error.NotFound, b.client.getService("us-central1", "zigps-nobody"));
    try testing.expectEqualStrings("Resource 'zigps-nobody' of kind 'SERVICE' in region 'us-central1' in project 'my-project' does not exist.", b.diag.message());
    try testing.expectError(error.NotFound, b.client.getRevision("us-central1", "svc-a", "nobody"));
    try testing.expectEqualStrings("Resource 'nobody' of kind 'REVISION' in region 'us-central1' in project 'my-project' does not exist.", b.diag.message());
}

test "what the puts refuse, nothing kept; writes and other projects 501" {
    var b: Bench = undefined;
    try b.init(.{});
    defer b.deinit();
    try testing.expectError(error.InvalidEntry, b.fake.putLocation("-"));
    try b.fake.putLocation("us-central1");
    try testing.expectError(error.InvalidEntry, b.fake.putLocation("us-central1"));
    try testing.expectError(error.InvalidEntry, b.fake.putService(.{ .location = "nowhere1", .id = "s" }));
    try testing.expectError(error.InvalidEntry, b.fake.putService(.{ .location = "us-central1", .id = "-" }));
    try testing.expectError(error.InvalidEntry, b.fake.putService(.{ .location = "us-central1", .id = "a/b" }));
    _ = try b.fake.putService(.{ .location = "us-central1", .id = "taken" });
    try testing.expectError(error.InvalidEntry, b.fake.putService(.{ .location = "us-central1", .id = "taken" }));
    try testing.expectError(error.InvalidEntry, b.fake.putRevision(.{ .location = "us-central1", .service = "nobody", .id = "r" }));
    try testing.expectError(error.InvalidEntry, b.fake.putRevision(.{ .location = "us-central1", .service = "taken", .id = "-" }));
    _ = try b.fake.putRevision(.{ .location = "us-central1", .service = "taken", .id = "taken-00001-ab" });
    try testing.expectError(error.InvalidEntry, b.fake.putRevision(.{ .location = "us-central1", .service = "taken", .id = "taken-00001-ab" }));
    try testing.expectEqual(1, b.fake.serviceCount());
    try testing.expectEqual(1, b.fake.revisionCount());

    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const write = try b.raw(arena.allocator(), .POST, "https://host/v2/projects/my-project/locations/us-central1/services");
    try testing.expectEqual(501, write.status);
    const other = try b.raw(arena.allocator(), .GET, "https://host/v2/projects/other/locations/us-central1/services");
    try testing.expectEqual(501, other.status);
    const bare = b.fake.serve(.{ .method = .GET, .url = "https://host/v2/projects/my-project/locations/us-central1/services" }, arena.allocator());
    try testing.expectEqual(401, (try bare).status);
}

test "faults on request: dropped, refused and lost answers" {
    var b: Bench = undefined;
    try b.init(.{});
    defer b.deinit();
    try b.fake.putLocation("us-central1");
    _ = try b.fake.putService(.{ .location = "us-central1", .id = "s" });

    b.fake.dropNext(1);
    var got = try b.client.getService("us-central1", "s");
    got.deinit();
    b.fake.refuseNext(1, 403);
    try testing.expectError(error.PermissionDenied, b.client.getService("us-central1", "s"));
    b.fake.loseNext(1, 500);
    var again = try b.client.getService("us-central1", "s");
    again.deinit();
    try testing.expect(b.fake.callCount() >= 5);
}

/// The probe's quick job, as production answered it after its two runs:
/// put in, then its two executions, oldest first.
fn seedQuickJob(fake: *FakeRun) ![]const u8 {
    try fake.putLocation("us-central1");
    const job = try fake.putJob(.{
        .location = "us-central1",
        .id = "zigps-6b8297-quick",
        .task_count = 1,
        .task_timeout_s = 900,
        .max_retries = 0,
        .containers = &.{.{ .image = "us-docker.pkg.dev/cloudrun/container/job" }},
        .service_account = "82150720798-compute@developer.gserviceaccount.com",
        .labels = &.{.{ .key = "zigps", .value = "probe" }},
        .create_time = ts("2026-10-21T12:14:38.395057Z"),
        .update_time = ts("2026-10-21T12:14:38.395057Z"),
    });
    _ = try fake.putExecution(.{ .location = "us-central1", .job = "zigps-6b8297-quick", .id = "zigps-6b8297-quick-p64qb", .status = .succeeded, .create_time = ts("2026-10-21T12:15:20.000000Z"), .start_time = ts("2026-10-21T12:16:50.000000Z"), .completion_time = ts("2026-10-21T12:16:57.000000Z") });
    _ = try fake.putExecution(.{ .location = "us-central1", .job = "zigps-6b8297-quick", .id = "zigps-6b8297-quick-l4ffj", .status = .succeeded, .create_time = ts("2026-10-21T12:17:01.331509Z"), .start_time = ts("2026-10-21T12:18:33.000000Z"), .completion_time = ts("2026-10-21T12:18:38.818609Z") });
    return job;
}

test "the probe's job and executions put in, read back as production answered them" {
    var b: Bench = undefined;
    try b.init(.{ .project_id = "extractctl" });
    defer b.deinit();
    _ = try seedQuickJob(&b.fake);
    try testing.expectEqual(1, b.fake.jobCount());
    try testing.expectEqual(2, b.fake.executionCount());

    var out: std.heap.ArenaAllocator = .init(testing.allocator);
    defer out.deinit();
    var scratch: std.heap.ArenaAllocator = .init(testing.allocator);
    defer scratch.deinit();
    const wanted = try codec.decodeJob(out.allocator(), scratch.allocator(), production.job_succeeded);
    var got = try b.client.getJob("us-central1", "zigps-6b8297-quick");
    defer got.deinit();
    try testing.expectEqualStrings(wanted.name, got.value.name);
    try testing.expectEqual(wanted.execution_count, got.value.execution_count);
    try testing.expectEqualStrings(wanted.latest_created_execution.?.name, got.value.latest_created_execution.?.name);
    try testing.expectEqual(wanted.latest_created_execution.?.status, got.value.latest_created_execution.?.status);
    try testing.expectEqual(wanted.latest_created_execution.?.completion_time.?.nanoseconds, got.value.latest_created_execution.?.completion_time.?.nanoseconds);
    try testing.expectEqual(wanted.task_count, got.value.task_count);
    try testing.expectEqual(wanted.task_timeout_s, got.value.task_timeout_s);
    try testing.expectEqual(wanted.max_retries, got.value.max_retries);
    try testing.expectEqualStrings(wanted.containers[0].image, got.value.containers[0].image);
    try testing.expectEqualStrings(wanted.service_account, got.value.service_account);
    try testing.expectEqual(wanted.ready(), got.value.ready());
    try testing.expect(got.value.etag.len > 0);

    // A job never run: `{}` for its latest, as production sent.
    _ = try b.fake.putJob(.{ .location = "us-central1", .id = "zigps-fresh" });
    var fresh = try b.client.getJob("us-central1", "zigps-fresh");
    defer fresh.deinit();
    try testing.expectEqual(null, fresh.value.latest_created_execution);
    try testing.expectEqual(0, fresh.value.execution_count);
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const raw_fresh = try b.raw(arena.allocator(), .GET, "https://host/v2/projects/extractctl/locations/us-central1/jobs/zigps-fresh");
    try testing.expect(std.mem.indexOf(u8, raw_fresh.body, "\"latestCreatedExecution\":{}") != null);
    // After a run, the id alone, as production sent it.
    const raw_job = try b.raw(arena.allocator(), .GET, "https://host/v2/projects/extractctl/locations/us-central1/jobs/zigps-6b8297-quick");
    try testing.expect(std.mem.indexOf(u8, raw_job.body, "\"latestCreatedExecution\":{\"name\":\"zigps-6b8297-quick-l4ffj\"") != null);

    // Each status reads back as production's conditions say it.
    const statuses = [_]types.ExecutionStatus{ .pending, .running, .cancelling, .succeeded, .failed, .cancelled };
    for (statuses, 0..) |status, i| {
        const id = try std.fmt.allocPrint(arena.allocator(), "zigps-6b8297-quick-s{d}", .{i});
        _ = try b.fake.putExecution(.{ .location = "us-central1", .job = "zigps-6b8297-quick", .id = id, .status = status, .start_time = if (status == .cancelled) ts("2026-10-21T12:20:00Z") else null });
        var execution = try b.client.getExecution("us-central1", "zigps-6b8297-quick", id);
        defer execution.deinit();
        try testing.expectEqual(status, execution.value.status());
    }
    // Cancelled before it started: Started still reconciling, as
    // production's read.
    _ = try b.fake.putExecution(.{ .location = "us-central1", .job = "zigps-6b8297-quick", .id = "zigps-6b8297-quick-early", .status = .cancelled });
    var early = try b.client.getExecution("us-central1", "zigps-6b8297-quick", "zigps-6b8297-quick-early");
    defer early.deinit();
    const wanted_early = try codec.decodeExecution(out.allocator(), scratch.allocator(), production.execution_cancelled_pending);
    try testing.expectEqual(wanted_early.condition("Started").?.state, early.value.condition("Started").?.state);
    try testing.expectEqualStrings(wanted_early.condition("Completed").?.message, early.value.condition("Completed").?.message);
    try testing.expectEqualStrings(wanted_early.condition("Completed").?.reason, early.value.condition("Completed").?.reason);
    try testing.expectEqual(null, early.value.completion_time);
}

test "job and execution lists and refusals as production answered" {
    var b: Bench = undefined;
    try b.init(.{ .project_id = "extractctl" });
    defer b.deinit();
    _ = try seedQuickJob(&b.fake);
    _ = try b.fake.putJob(.{ .location = "us-central1", .id = "zigps-6b8297-slow", .create_time = ts("2026-10-21T12:14:40Z") });
    _ = try b.fake.putExecution(.{ .location = "us-central1", .job = "zigps-6b8297-slow", .id = "zigps-6b8297-slow-54x76", .status = .cancelled, .create_time = ts("2026-10-21T12:21:56.969041Z"), .start_time = ts("2026-10-21T12:22:00Z") });

    // Jobs newest first, paged.
    var page = try b.client.listJobs("us-central1", .{ .page_size = 1 });
    defer page.deinit();
    try testing.expectEqualStrings("zigps-6b8297-slow", page.value.jobs[0].id);
    var rest = try b.client.listJobs("us-central1", .{ .page_size = 1, .page_token = page.value.next_page_token.? });
    defer rest.deinit();
    try testing.expectEqualStrings("zigps-6b8297-quick", rest.value.jobs[0].id);
    try testing.expectEqual(null, rest.value.next_page_token);

    // jobs/-: every job's executions, newest first, as production's were.
    var every = try b.client.listExecutions("us-central1", "-", .{});
    defer every.deinit();
    try testing.expectEqual(3, every.value.executions.len);
    try testing.expectEqualStrings("zigps-6b8297-slow-54x76", every.value.executions[0].id);
    try testing.expectEqualStrings("zigps-6b8297-quick-p64qb", every.value.executions[2].id);
    var one = try b.client.listExecutions("us-central1", "zigps-6b8297-quick", .{ .page_size = 1 });
    defer one.deinit();
    try testing.expectEqualStrings("zigps-6b8297-quick-l4ffj", one.value.executions[0].id);
    try testing.expect(one.value.next_page_token != null);
    var none = try b.client.listExecutions("us-central1", "zigps-nobody", .{});
    defer none.deinit();
    try testing.expectEqual(0, none.value.executions.len);

    // Production's words, each held to its body.
    try testing.expectError(error.NotFound, b.client.getJob("us-central1", "zigps-nobody"));
    try testing.expectEqualStrings(try errorMessage(production.job_unknown), b.diag.message());
    try testing.expectError(error.PermissionDenied, b.client.listJobs("us-fake1", .{}));
    try testing.expectEqualStrings(try errorMessage(production.jobs_made_up_region), b.diag.message());
    try testing.expectError(error.NotFound, b.client.getExecution("us-central1", "zigps-nobody", "zigps-nobody-abcde"));
    try testing.expectEqualStrings(try errorMessage(production.execution_unknown), b.diag.message());
    try testing.expectError(error.NotFound, b.client.getOperation("projects/extractctl/locations/us-central1/operations/00000000-0000-0000-0000-000000000000"));
    try testing.expectEqualStrings(try errorMessage(production.operation_unknown), b.diag.message());
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const dash = try b.raw(arena.allocator(), .GET, "https://host/v2/projects/extractctl/locations/-/jobs");
    try testing.expectEqual(production.jobs_dash_status, dash.status);
    try testing.expectEqualStrings(try errorMessage(production.jobs_dash), try errorMessage(dash.body));
}

/// The `error.message` of an error body.
fn errorMessage(body: []const u8) ![]const u8 {
    const S = struct {
        var buf: [4096]u8 = undefined;
    };
    var fba: std.heap.FixedBufferAllocator = .init(&S.buf);
    const parsed = try std.json.parseFromSliceLeaky(struct { @"error": struct { message: []const u8 } }, fba.allocator(), body, .{ .ignore_unknown_fields = true });
    return parsed.@"error".message;
}

test "a run makes an execution as the job's outcome says, its operation done when it ends" {
    var b: Bench = undefined;
    try b.init(.{ .project_id = "extractctl" });
    defer b.deinit();
    b.client.scope = .read_write;
    _ = try seedQuickJob(&b.fake);
    b.clock.now_ns = ts("2026-10-21T12:30:00Z").nanoseconds;

    // Pending by default, as production's were for 90 s.
    var run = try b.client.runJob("us-central1", "zigps-6b8297-quick");
    defer run.deinit();
    try testing.expect(!run.value.done);
    const execution_name = run.value.subject.execution.name;
    try testing.expectEqualStrings("projects/extractctl/locations/us-central1/jobs/zigps-6b8297-quick/executions/zigps-6b8297-quick-00001", execution_name);
    try testing.expectEqual(types.ExecutionStatus.pending, run.value.subject.execution.status());
    var job_now = try b.client.getJob("us-central1", "zigps-6b8297-quick");
    defer job_now.deinit();
    try testing.expectEqual(3, job_now.value.execution_count);
    try testing.expectEqualStrings(execution_name, job_now.value.latest_created_execution.?.name);
    try testing.expectEqual(types.ExecutionStatus.pending, job_now.value.latest_created_execution.?.status);

    // Moved on by the test, the operation follows: done only at the end,
    // its response the execution.
    try b.fake.setExecutionStatus(execution_name, .running);
    var running = try b.client.getOperation(run.value.name);
    defer running.deinit();
    try testing.expect(!running.value.done);
    try testing.expectEqual(types.ExecutionStatus.running, running.value.subject.execution.status());
    try testing.expect(running.value.subject.execution.start_time != null);
    try b.fake.setExecutionStatus(execution_name, .succeeded);
    var done = try b.client.getOperation(run.value.name);
    defer done.deinit();
    try testing.expect(done.value.done);
    try testing.expectEqual(null, done.value.failure);
    try testing.expectEqual(types.ExecutionStatus.succeeded, done.value.subject.execution.status());
    try testing.expect(done.value.subject.execution.completion_time != null);

    // A failing job: the operation fails as production's did, code 10 in
    // the task's words, no response.
    _ = try b.fake.putJob(.{ .location = "us-central1", .id = "zigps-6b8297-fail", .run_outcome = .failed });
    var failed = try b.client.runJob("us-central1", "zigps-6b8297-fail");
    defer failed.deinit();
    var failed_op = try b.client.getOperation(failed.value.name);
    defer failed_op.deinit();
    try testing.expect(failed_op.value.done);
    try testing.expectEqual(10, failed_op.value.failure.?.code);
    const wanted = try errorOf(production.operation_run_failed);
    try testing.expectEqual(wanted.code, failed_op.value.failure.?.code);
    try testing.expectEqualStrings("Task zigps-6b8297-fail-00002-task0 failed with exit code: 1 and message: The container exited with an error.", failed_op.value.failure.?.message);
    try testing.expect(std.mem.endsWith(u8, wanted.message, "failed with exit code: 1 and message: The container exited with an error."));
    try testing.expectEqual(types.ExecutionStatus.failed, failed_op.value.subject.execution.status());

    // Two runs at once are taken, as production took them.
    _ = try b.fake.putJob(.{ .location = "us-central1", .id = "zigps-6b8297-slow", .run_outcome = .running });
    var first = try b.client.runJob("us-central1", "zigps-6b8297-slow");
    defer first.deinit();
    var second = try b.client.runJob("us-central1", "zigps-6b8297-slow");
    defer second.deinit();
    try testing.expectEqual(types.ExecutionStatus.running, second.value.subject.execution.status());
    try testing.expect(!std.mem.eql(u8, first.value.subject.execution.name, second.value.subject.execution.name));

    // A run's execution is its job's latest, though a test's clock reads
    // earlier than one the test put in.
    _ = try b.fake.putJob(.{ .location = "us-central1", .id = "zigps-later" });
    _ = try b.fake.putExecution(.{ .location = "us-central1", .job = "zigps-later", .id = "zigps-later-put", .status = .succeeded, .create_time = ts("2027-01-01T00:00:00Z") });
    var later = try b.client.runJob("us-central1", "zigps-later");
    defer later.deinit();
    var later_job = try b.client.getJob("us-central1", "zigps-later");
    defer later_job.deinit();
    try testing.expectEqualStrings(later.value.subject.execution.name, later_job.value.latest_created_execution.?.name);

    // A job nobody has.
    try testing.expectError(error.NotFound, b.client.runJob("us-central1", "zigps-nobody"));
    try testing.expectEqualStrings("Resource 'zigps-nobody' of kind 'JOB' in region 'us-central1' in project 'extractctl' does not exist.", b.diag.message());
}

/// The `error` of a done operation's body.
fn errorOf(body: []const u8) !types.Operation.Failure {
    const S = struct {
        var buf: [8192]u8 = undefined;
    };
    var fba: std.heap.FixedBufferAllocator = .init(&S.buf);
    const parsed = try std.json.parseFromSliceLeaky(struct { @"error": types.Operation.Failure }, fba.allocator(), body, .{ .ignore_unknown_fields = true });
    return parsed.@"error";
}

test "a cancel as production took it: running to cancelling, pending to cancelled, ended refused" {
    var b: Bench = undefined;
    try b.init(.{ .project_id = "extractctl" });
    defer b.deinit();
    b.client.scope = .read_write;
    try b.fake.putLocation("us-central1");
    _ = try b.fake.putJob(.{ .location = "us-central1", .id = "zigps-6b8297-slow" });
    const running = try b.fake.putExecution(.{ .location = "us-central1", .job = "zigps-6b8297-slow", .id = "zigps-6b8297-slow-nlzdb", .status = .running });
    const pending = try b.fake.putExecution(.{ .location = "us-central1", .job = "zigps-6b8297-slow", .id = "zigps-6b8297-slow-early", .status = .pending });

    var cancel = try b.client.cancelExecution("us-central1", "zigps-6b8297-slow", "zigps-6b8297-slow-nlzdb");
    defer cancel.deinit();
    try testing.expect(!cancel.value.done);
    try testing.expectEqual(types.ExecutionStatus.cancelling, b.fake.executionStatus(running).?);
    // A second cancel while stopping is taken and changes nothing.
    var again = try b.client.cancelExecution("us-central1", "zigps-6b8297-slow", "zigps-6b8297-slow-nlzdb");
    again.deinit();
    try testing.expectEqual(types.ExecutionStatus.cancelling, b.fake.executionStatus(running).?);
    try b.fake.setExecutionStatus(running, .cancelled);
    var ended = try b.client.getOperation(cancel.value.name);
    defer ended.deinit();
    try testing.expect(ended.value.done);
    try testing.expectEqual(null, ended.value.failure);
    try testing.expectEqual(types.ExecutionStatus.cancelled, ended.value.subject.execution.status());
    try testing.expect(ended.value.subject.execution.completion_time != null);

    // Ended: refused in production's words.
    try testing.expectError(error.FailedPrecondition, b.client.cancelExecution("us-central1", "zigps-6b8297-slow", "zigps-6b8297-slow-nlzdb"));
    try testing.expectEqualStrings(try errorMessage(production.cancel_not_running), b.diag.message());

    // A cancel that meets the task's start: the test moves it to failed,
    // and it reads as production's did, both operations failing code 2.
    const raced = try b.fake.putExecution(.{ .location = "us-central1", .job = "zigps-6b8297-slow", .id = "zigps-6b8297-slow-raced", .status = .running });
    var raced_cancel = try b.client.cancelExecution("us-central1", "zigps-6b8297-slow", "zigps-6b8297-slow-raced");
    defer raced_cancel.deinit();
    try b.fake.setExecutionStatus(raced, .failed);
    var raced_op = try b.client.getOperation(raced_cancel.value.name);
    defer raced_op.deinit();
    var out: std.heap.ArenaAllocator = .init(testing.allocator);
    defer out.deinit();
    const wanted_op = try codec.decodeOperation(out.allocator(), out.allocator(), production.operation_cancel_raced);
    try testing.expectEqual(wanted_op.failure.?.code, raced_op.value.failure.?.code);
    try testing.expectEqualStrings(wanted_op.failure.?.message, raced_op.value.failure.?.message);
    const wanted = try codec.decodeExecution(out.allocator(), out.allocator(), production.execution_cancel_raced);
    const got = raced_op.value.subject.execution;
    try testing.expectEqual(wanted.status(), got.status());
    try testing.expectEqualStrings(wanted.condition("Completed").?.reason, got.condition("Completed").?.reason);
    try testing.expectEqualStrings(wanted.condition("Completed").?.message, got.condition("Completed").?.message);
    try testing.expectEqual(wanted.cancelled_count, got.cancelled_count);
    try testing.expectEqual(wanted.failed_count, got.failed_count);

    // Pending: cancelled at once, never a completion time.
    var early = try b.client.cancelExecution("us-central1", "zigps-6b8297-slow", "zigps-6b8297-slow-early");
    defer early.deinit();
    try testing.expectEqual(types.ExecutionStatus.cancelled, b.fake.executionStatus(pending).?);
    var early_read = try b.client.getExecutionNamed(pending);
    defer early_read.deinit();
    try testing.expectEqual(null, early_read.value.completion_time);
    try testing.expectEqual(types.ExecutionStatus.cancelled, early_read.value.status());

    // validateOnly changes nothing; its operation is not read back here.
    const third = try b.fake.putExecution(.{ .location = "us-central1", .job = "zigps-6b8297-slow", .id = "zigps-6b8297-slow-third", .status = .running });
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const validate_reply = try b.fake.serve(.{ .method = .POST, .url = "https://host/v2/projects/extractctl/locations/us-central1/jobs/zigps-6b8297-slow/executions/zigps-6b8297-slow-third:cancel", .bearer = "t", .body = "{\"validateOnly\":true}" }, arena.allocator());
    try testing.expectEqual(200, validate_reply.status);
    try testing.expectEqual(types.ExecutionStatus.running, b.fake.executionStatus(third).?);
    const op = try codec.decodeOperation(arena.allocator(), arena.allocator(), validate_reply.body);
    try testing.expectError(error.Unimplemented, b.client.getOperation(op.name));

    // An execution nobody has, and a region nobody put.
    try testing.expectError(error.NotFound, b.client.cancelExecution("us-central1", "zigps-6b8297-slow", "zigps-6b8297-slow-zzzzz"));
    try testing.expectError(error.PermissionDenied, b.client.cancelExecution("us-fake1", "zigps-6b8297-slow", "zigps-6b8297-slow-third"));
    try testing.expectEqualStrings("Permission denied on 'locations/us-fake1' (or it may not exist)", b.diag.message());
}

/// The probe's service with two ready revisions and one that failed.
fn seedTrafficService(fake: *FakeRun) ![]const u8 {
    try fake.putLocation("us-central1");
    const name = try fake.putService(.{
        .location = "us-central1",
        .id = "zigps-6b8297",
        .latest_ready_revision = "zigps-6b8297-00002-v7z",
        .latest_created_revision = "zigps-6b8297-00003-bd6",
        .traffic = &.{.{ .type = .latest, .percent = 100 }},
        .traffic_statuses = &.{.{ .type = .latest, .revision = "zigps-6b8297-00002-v7z", .percent = 100 }},
        .terminal_condition = .{ .type = "Ready", .state = .succeeded },
        .generation = 2,
        .labels = &.{.{ .key = "zigps", .value = "probe" }},
    });
    for ([_][]const u8{ "zigps-6b8297-00001-527", "zigps-6b8297-00002-v7z" }) |id| {
        _ = try fake.putRevision(.{ .location = "us-central1", .service = "zigps-6b8297", .id = id, .conditions = &.{.{ .type = "Ready", .state = .succeeded }} });
    }
    _ = try fake.putRevision(.{ .location = "us-central1", .service = "zigps-6b8297", .id = "zigps-6b8297-00003-bd6", .conditions = &.{.{ .type = "Ready", .state = .failed, .message = "Image 'us-docker.pkg.dev/cloudrun/container/hello:zigps-no-such-tag' not found." }} });
    return name;
}

test "a traffic change as production took it: the etag enforced under its mask" {
    var b: Bench = undefined;
    try b.init(.{ .project_id = "extractctl" });
    defer b.deinit();
    b.client.scope = .read_write;
    _ = try seedTrafficService(&b.fake);
    var read = try b.client.getService("us-central1", "zigps-6b8297");
    defer read.deinit();
    const etag = try testing.allocator.dupe(u8, read.value.etag);
    defer testing.allocator.free(etag);

    // validate_only with the read's etag: an operation, nothing changed.
    var check = try b.client.routeAllTraffic("us-central1", "zigps-6b8297", "zigps-6b8297-00001-527", .{ .etag = etag, .validate_only = true });
    defer check.deinit();
    try testing.expectEqualStrings("zigps-6b8297-00001-527", check.value.subject.service.traffic[0].revision);
    var unchanged = try b.client.getService("us-central1", "zigps-6b8297");
    defer unchanged.deinit();
    try testing.expectEqualStrings(etag, unchanged.value.etag);
    try testing.expectEqual(types.TrafficType.latest, unchanged.value.traffic[0].type);

    // The change: one target, a new generation and etag, the labels kept.
    var change = try b.client.routeAllTraffic("us-central1", "zigps-6b8297", "zigps-6b8297-00001-527", .{ .etag = etag });
    defer change.deinit();
    try testing.expect(!change.value.done);
    var done = try b.client.getOperation(change.value.name);
    defer done.deinit();
    try testing.expect(done.value.done);
    try testing.expectEqual(null, done.value.failure);
    const after = done.value.subject.service;
    try testing.expectEqual(1, after.traffic.len);
    try testing.expectEqualStrings("zigps-6b8297-00001-527", after.traffic[0].revision);
    try testing.expectEqualStrings("zigps-6b8297-00001-527", after.traffic_statuses[0].revision);
    try testing.expectEqual(3, after.generation.?);
    try testing.expect(!std.mem.eql(u8, etag, after.etag));
    try testing.expectEqualStrings("probe", after.labels[0].value);
    try testing.expect(after.ready());

    // The stale etag now: refused in production's shape, validate_only
    // too, nothing changed.
    try testing.expectError(error.Aborted, b.client.routeAllTraffic("us-central1", "zigps-6b8297", "zigps-6b8297-00002-v7z", .{ .etag = etag }));
    try testing.expect(std.mem.startsWith(u8, b.diag.message(), "Conflict for resource 'zigps-6b8297': version '"));
    try testing.expect(std.mem.indexOf(u8, b.diag.message(), "' was specified but current version is '") != null);
    try testing.expectError(error.Aborted, b.client.routeAllTraffic("us-central1", "zigps-6b8297", "zigps-6b8297-00002-v7z", .{ .etag = etag, .validate_only = true }));
    // The same traffic again is no change, the stale etag unchecked, as a
    // resend of a change that landed was taken in production.
    var resend = try b.client.routeAllTraffic("us-central1", "zigps-6b8297", "zigps-6b8297-00001-527", .{ .etag = etag });
    defer resend.deinit();
    var same = try b.client.getService("us-central1", "zigps-6b8297");
    defer same.deinit();
    try testing.expectEqualStrings(after.etag, same.value.etag);
    try testing.expectEqual(3, same.value.generation.?);

    // Another service's revision, refused at once in production's words.
    try testing.expectError(error.InvalidArgument, b.client.routeAllTraffic("us-central1", "zigps-6b8297", "zigps-other-00001-abc", .{ .etag = same.value.etag }));
    try testing.expectEqualStrings(try errorMessage(production.traffic_other_service), b.diag.message());
}

test "a traffic change to a revision missing or failed is taken, and its operation fails" {
    var b: Bench = undefined;
    try b.init(.{ .project_id = "extractctl" });
    defer b.deinit();
    b.client.scope = .read_write;
    _ = try seedTrafficService(&b.fake);
    var read = try b.client.getService("us-central1", "zigps-6b8297");
    defer read.deinit();

    // validate_only does not check the revision, as production's did not.
    var check = try b.client.routeAllTraffic("us-central1", "zigps-6b8297", "zigps-6b8297-00009-zzz", .{ .etag = read.value.etag, .validate_only = true });
    check.deinit();
    var missing = try b.client.routeAllTraffic("us-central1", "zigps-6b8297", "zigps-6b8297-00009-zzz", .{ .etag = read.value.etag });
    defer missing.deinit();
    var missing_op = try b.client.getOperation(missing.value.name);
    defer missing_op.deinit();
    const wanted = try errorOf(production.operation_traffic_failed);
    try testing.expectEqual(wanted.code, missing_op.value.failure.?.code);
    try testing.expectEqualStrings("Revision 'zigps-6b8297-00009-zzz' does not exist or is deleted. Update all traffic to route to currently available revisions.", missing_op.value.failure.?.message);
    try testing.expect(std.mem.endsWith(u8, wanted.message, "does not exist or is deleted. Update all traffic to route to currently available revisions."));
    // The service keeps the asked traffic, fails, and goes on serving the
    // old revision.
    var after = try b.client.getService("us-central1", "zigps-6b8297");
    defer after.deinit();
    try testing.expectEqualStrings("zigps-6b8297-00009-zzz", after.value.traffic[0].revision);
    try testing.expect(!after.value.ready());
    try testing.expectEqualStrings(missing_op.value.failure.?.message, after.value.terminal_condition.?.message);
    try testing.expectEqualStrings("zigps-6b8297-00002-v7z", after.value.traffic_statuses[0].revision);

    // A revision whose Ready failed: code 5, the revision's own words.
    var failed = try b.client.routeAllTraffic("us-central1", "zigps-6b8297", "zigps-6b8297-00003-bd6", .{ .etag = after.value.etag });
    defer failed.deinit();
    var failed_op = try b.client.getOperation(failed.value.name);
    defer failed_op.deinit();
    try testing.expectEqual(5, failed_op.value.failure.?.code);
    try testing.expectEqualStrings("Image 'us-docker.pkg.dev/cloudrun/container/hello:zigps-no-such-tag' not found.", failed_op.value.failure.?.message);

    // Back to a ready one: served again, ready again.
    var back = try b.client.getService("us-central1", "zigps-6b8297");
    defer back.deinit();
    var fixed = try b.client.routeAllTraffic("us-central1", "zigps-6b8297", "zigps-6b8297-00002-v7z", .{ .etag = back.value.etag });
    defer fixed.deinit();
    var fixed_op = try b.client.getOperation(fixed.value.name);
    defer fixed_op.deinit();
    try testing.expectEqual(null, fixed_op.value.failure);
    try testing.expect(fixed_op.value.subject.service.ready());
}

test "a traffic change's masks, bodies and etags the fake does not model, as production answered" {
    var b: Bench = undefined;
    try b.init(.{ .project_id = "extractctl" });
    defer b.deinit();
    _ = try seedTrafficService(&b.fake);
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const url = "https://host/v2/projects/extractctl/locations/us-central1/services/zigps-6b8297";
    const one = "{\"traffic\":[{\"type\":\"TRAFFIC_TARGET_ALLOCATION_TYPE_REVISION\",\"revision\":\"zigps-6b8297-00001-527\",\"percent\":100}],\"etag\":\"\\\"v999\\\"\"}";
    const patch = struct {
        fn send(f: *FakeRun, arena_: Allocator, target: []const u8, body: []const u8) !FakeRun.Reply {
            return f.serve(.{ .method = .PATCH, .url = target, .bearer = "t", .body = body }, arena_);
        }
    }.send;
    // Without a mask: production's words for the whole service it wants.
    const bare = try patch(&b.fake, a, url, one);
    try testing.expectEqual(400, bare.status);
    try testing.expectEqualStrings("Violation in UpdateServiceRequest.service.template: required field not present.", try errorMessage(bare.body));
    // updateMask=traffic ignores the etag, stale or made up, as measured.
    const ignored = try patch(&b.fake, a, url ++ "?updateMask=traffic", one);
    try testing.expectEqual(200, ignored.status);
    // Under the etag mask, an etag the fake did not make is not modelled;
    // nor is a mask, a parameter, a body field or traffic beyond the one.
    try testing.expectEqual(501, (try patch(&b.fake, a, url ++ "?updateMask=traffic,etag", "{\"traffic\":[{\"type\":\"TRAFFIC_TARGET_ALLOCATION_TYPE_REVISION\",\"revision\":\"zigps-6b8297-00002-v7z\",\"percent\":100}],\"etag\":\"made-up\"}")).status);
    try testing.expectEqual(501, (try patch(&b.fake, a, url ++ "?updateMask=template", one)).status);
    try testing.expectEqual(501, (try patch(&b.fake, a, url ++ "?updateMask=traffic&allowMissing=true", one)).status);
    try testing.expectEqual(501, (try patch(&b.fake, a, url ++ "?updateMask=traffic", "{\"traffic\":[],\"labels\":{}}")).status);
    try testing.expectEqual(501, (try patch(&b.fake, a, url ++ "?updateMask=traffic", "{\"traffic\":[{\"type\":\"TRAFFIC_TARGET_ALLOCATION_TYPE_REVISION\",\"revision\":\"zigps-6b8297-00001-527\",\"percent\":50},{\"type\":\"TRAFFIC_TARGET_ALLOCATION_TYPE_LATEST\",\"percent\":50}]}")).status);
    try testing.expectEqual(501, (try patch(&b.fake, a, url ++ "?updateMask=traffic", "{\"traffic\":[{\"type\":\"TRAFFIC_TARGET_ALLOCATION_TYPE_REVISION\",\"revision\":\"zigps-6b8297-00001-527\",\"percent\":100,\"tag\":\"blue\"}]}")).status);
    try testing.expectEqual(400, (try patch(&b.fake, a, url ++ "?updateMask=traffic", "not json")).status);
    // Run overrides are not modelled; other writes are 501 too.
    _ = try b.fake.putJob(.{ .location = "us-central1", .id = "j" });
    try testing.expectEqual(501, (try b.fake.serve(.{ .method = .POST, .url = "https://host/v2/projects/extractctl/locations/us-central1/jobs/j:run", .bearer = "t", .body = "{\"overrides\":{\"taskCount\":2}}" }, a)).status);
    try testing.expectEqual(501, (try b.fake.serve(.{ .method = .DELETE, .url = "https://host/v2/projects/extractctl/locations/us-central1/jobs/j", .bearer = "t" }, a)).status);
    try testing.expectEqual(501, (try b.fake.serve(.{ .method = .GET, .url = "https://host/v2/projects/extractctl/locations/-/jobs/j/executions", .bearer = "t" }, a)).status);
    // A validateOnly run names an execution it never makes.
    const validate_run = try b.fake.serve(.{ .method = .POST, .url = "https://host/v2/projects/extractctl/locations/us-central1/jobs/j:run", .bearer = "t", .body = "{\"validateOnly\":true}" }, a);
    try testing.expectEqual(200, validate_run.status);
    try testing.expectEqual(0, b.fake.executionCount());
}

test "the job puts refuse what production could not hold, nothing kept" {
    var b: Bench = undefined;
    try b.init(.{});
    defer b.deinit();
    try b.fake.putLocation("us-central1");
    try testing.expectError(error.InvalidEntry, b.fake.putJob(.{ .location = "nowhere1", .id = "j" }));
    try testing.expectError(error.InvalidEntry, b.fake.putJob(.{ .location = "us-central1", .id = "-" }));
    try testing.expectError(error.InvalidEntry, b.fake.putJob(.{ .location = "us-central1", .id = "a/b" }));
    _ = try b.fake.putJob(.{ .location = "us-central1", .id = "j" });
    try testing.expectError(error.InvalidEntry, b.fake.putJob(.{ .location = "us-central1", .id = "j" }));
    try testing.expectError(error.InvalidEntry, b.fake.putExecution(.{ .location = "us-central1", .job = "nobody", .id = "e" }));
    try testing.expectError(error.InvalidEntry, b.fake.putExecution(.{ .location = "us-central1", .job = "j", .id = "-" }));
    try testing.expectError(error.InvalidEntry, b.fake.putExecution(.{ .location = "us-central1", .job = "j", .id = "e", .status = .unknown }));
    try testing.expectError(error.InvalidEntry, b.fake.putExecution(.{ .location = "us-central1", .job = "j", .id = "e", .status = .unspecified }));
    const e = try b.fake.putExecution(.{ .location = "us-central1", .job = "j", .id = "e" });
    try testing.expectError(error.InvalidEntry, b.fake.putExecution(.{ .location = "us-central1", .job = "j", .id = "e" }));
    try testing.expectError(error.InvalidEntry, b.fake.setExecutionStatus("projects/my-project/locations/us-central1/jobs/j/executions/nobody", .running));
    try testing.expectError(error.InvalidEntry, b.fake.setExecutionStatus(e, .unknown));
    try testing.expectEqual(1, b.fake.jobCount());
    try testing.expectEqual(1, b.fake.executionCount());
    try testing.expectEqual(null, b.fake.executionStatus("projects/my-project/locations/us-central1/jobs/j/executions/nobody"));
}

test "a lost answer to a run: the execution made all the same, and not made again" {
    var b: Bench = undefined;
    try b.init(.{});
    defer b.deinit();
    b.client.scope = .read_write;
    try b.fake.putLocation("us-central1");
    _ = try b.fake.putJob(.{ .location = "us-central1", .id = "j" });
    b.fake.loseNext(1, 503);
    try testing.expectError(error.Unavailable, b.client.runJob("us-central1", "j"));
    try testing.expectEqual(1, b.fake.executionCount());
    // The job says it ran: the guide's way to find out.
    var executions = try b.client.listExecutions("us-central1", "j", .{});
    defer executions.deinit();
    try testing.expectEqual(1, executions.value.executions.len);

    // A cancel's lost answer, then its resend after the execution ended:
    // the read-back says it landed.
    const e = executions.value.executions[0].name;
    try b.fake.setExecutionStatus(e, .running);
    b.fake.loseNext(1, 503);
    var cancelled = try b.client.cancelExecution("us-central1", "j", executions.value.executions[0].id);
    defer cancelled.deinit();
    try testing.expectEqual(types.ExecutionStatus.cancelling, b.fake.executionStatus(e).?);
    // A dropped connection on a traffic change: sent again, taken once.
    _ = try b.fake.putService(.{ .location = "us-central1", .id = "s" });
    _ = try b.fake.putRevision(.{ .location = "us-central1", .service = "s", .id = "s-00001-ab", .conditions = &.{.{ .type = "Ready", .state = .succeeded }} });
    var service = try b.client.getService("us-central1", "s");
    defer service.deinit();
    b.fake.loseNext(1, 503);
    var routed = try b.client.routeAllTraffic("us-central1", "s", "s-00001-ab", .{ .etag = service.value.etag });
    defer routed.deinit();
    var after = try b.client.getService("us-central1", "s");
    defer after.deinit();
    try testing.expectEqual(2, after.value.generation.?);
    try testing.expectEqualStrings("s-00001-ab", after.value.traffic[0].revision);
}

/// What the property expects of the fake, from the rules measured in
/// production: the executions' statuses, the operations made, and the
/// service's traffic, generation and etags.
const WritesModel = struct {
    const cap = 24;
    const Op = struct { name: []const u8, execution: ?usize, failure: ?i32 };

    execution_names: [cap][]const u8 = undefined,
    statuses: [cap]types.ExecutionStatus = undefined,
    executions: usize = 0,
    ops: [cap * 2]Op = undefined,
    op_count: usize = 0,
    /// The revision all traffic goes to, or null while it is the latest.
    traffic: ?[]const u8 = null,
    generation: i64 = 2,
    /// The etag the last read gave, and the one before it.
    fresh: ?[]const u8 = null,
    stale: ?[]const u8 = null,

    fn addOp(m: *WritesModel, op: Op) void {
        if (m.op_count < m.ops.len) {
            m.ops[m.op_count] = op;
            m.op_count += 1;
        }
    }
};

fn writesProperty(_: void, input: []const u8) !void {
    const gpa = test_util.propertyAllocator();
    var arena_state: std.heap.ArenaAllocator = .init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var g: test_util.ByteGen = .init(input);
    var clock: core.testing.FakeClock = .{ .now_ns = ts("2026-10-21T12:00:00Z").nanoseconds };
    var fake: FakeRun = .init(gpa, clock.io(), .{});
    defer fake.deinit();
    var token: core.StaticToken = .{ .token = "t" };
    var diag: core.Diagnostics = .{};
    var client = try Client.init(gpa, clock.io(), .{ .project_id = "my-project", .token_provider = token.provider(), .transport = fake.transport(), .scope = .read_write, .diagnostics = &diag });
    defer client.deinit();

    try fake.putLocation("us-central1");
    const jobs = [_]struct { []const u8, FakeRun.RunOutcome }{ .{ "a", .pending }, .{ "b", .running }, .{ "c", .failed } };
    for (jobs) |j| _ = try fake.putJob(.{ .location = "us-central1", .id = j[0], .run_outcome = j[1] });
    _ = try fake.putService(.{ .location = "us-central1", .id = "s", .traffic = &.{.{ .type = .latest, .percent = 100 }}, .generation = 2 });
    _ = try fake.putRevision(.{ .location = "us-central1", .service = "s", .id = "s-00001-aa", .conditions = &.{.{ .type = "Ready", .state = .succeeded }} });
    _ = try fake.putRevision(.{ .location = "us-central1", .service = "s", .id = "s-00002-bb", .conditions = &.{.{ .type = "Ready", .state = .succeeded }} });
    _ = try fake.putRevision(.{ .location = "us-central1", .service = "s", .id = "s-00003-cc", .conditions = &.{.{ .type = "Ready", .state = .failed, .message = "Image 'x' not found." }} });
    const revisions = [_][]const u8{ "s-00001-aa", "s-00002-bb", "s-00003-cc", "s-00009-zz" };

    var m: WritesModel = .{};
    const steps = g.intRange(usize, 0, 32);
    for (0..steps) |_| {
        switch (g.intRange(u8, 0, 7)) {
            // A run, of one of the three jobs.
            0 => if (m.executions < WritesModel.cap) {
                const j = jobs[g.intRange(usize, 0, jobs.len - 1)];
                var run = try client.runJob("us-central1", j[0]);
                defer run.deinit();
                const status: types.ExecutionStatus = switch (j[1]) {
                    .pending => .pending,
                    .running => .running,
                    .succeeded => .succeeded,
                    .failed => .failed,
                };
                const execution = run.value.subject.execution;
                try testing.expectEqual(status, execution.status());
                // Made already ended, its operation is done at once.
                try testing.expectEqual(status.ended(), run.value.done);
                m.execution_names[m.executions] = try arena.dupe(u8, execution.name);
                m.statuses[m.executions] = status;
                m.addOp(.{ .name = try arena.dupe(u8, run.value.name), .execution = m.executions, .failure = null });
                m.executions += 1;
            },
            // The test moves an execution on, as its container would.
            1 => if (m.executions > 0) {
                const i = g.intRange(usize, 0, m.executions - 1);
                const status = g.pick(types.ExecutionStatus, &.{ .running, .cancelling, .succeeded, .failed, .cancelled });
                try fake.setExecutionStatus(m.execution_names[i], status);
                m.statuses[i] = status;
            },
            // A cancel: refused once ended, else as production moved it.
            2 => if (m.executions > 0) {
                const i = g.intRange(usize, 0, m.executions - 1);
                const parts = names.executionName(m.execution_names[i], "my-project").?;
                if (m.statuses[i].ended()) {
                    try testing.expectError(error.FailedPrecondition, client.cancelExecution("us-central1", parts.job, parts.id));
                } else {
                    var cancel = try client.cancelExecution("us-central1", parts.job, parts.id);
                    defer cancel.deinit();
                    m.statuses[i] = switch (m.statuses[i]) {
                        .pending => .cancelled,
                        .running => .cancelling,
                        else => |s| s,
                    };
                    try testing.expectEqual(m.statuses[i], cancel.value.subject.execution.status());
                    m.addOp(.{ .name = try arena.dupe(u8, cancel.value.name), .execution = i, .failure = null });
                }
            },
            // A traffic change, with the fresh etag, a stale one, or
            // validate_only.
            3 => {
                if (m.fresh == null) {
                    var read = try client.getService("us-central1", "s");
                    defer read.deinit();
                    m.fresh = try arena.dupe(u8, read.value.etag);
                }
                const revision = revisions[g.intRange(usize, 0, revisions.len - 1)];
                const use_stale = g.boolean() and m.stale != null;
                const validate_only = g.boolean();
                const etag = if (use_stale) m.stale.? else m.fresh.?;
                const same = if (m.traffic) |t| std.mem.eql(u8, t, revision) else false;
                const stale = use_stale and !std.mem.eql(u8, m.stale.?, m.fresh.?);
                if (stale and !same) {
                    try testing.expectError(error.Aborted, client.routeAllTraffic("us-central1", "s", revision, .{ .etag = etag, .validate_only = validate_only }));
                } else {
                    var change = try client.routeAllTraffic("us-central1", "s", revision, .{ .etag = etag, .validate_only = validate_only });
                    defer change.deinit();
                    try testing.expectEqual(false, change.value.done);
                    try testing.expectEqualStrings(revision, change.value.subject.service.traffic[0].revision);
                    if (!validate_only) {
                        const failure: ?i32 = if (std.mem.eql(u8, revision, "s-00009-zz")) 9 else if (std.mem.eql(u8, revision, "s-00003-cc")) 5 else null;
                        if (!same) {
                            m.traffic = revision;
                            m.generation += 1;
                            m.stale = m.fresh;
                            m.fresh = null;
                        }
                        m.addOp(.{ .name = try arena.dupe(u8, change.value.name), .execution = null, .failure = if (same) null else failure });
                    }
                }
            },
            // The service read back: traffic and generation as the model
            // has them; its etag becomes the fresh one.
            4 => {
                var read = try client.getService("us-central1", "s");
                defer read.deinit();
                if (m.traffic) |t| {
                    try testing.expectEqualStrings(t, read.value.traffic[0].revision);
                } else {
                    try testing.expectEqual(types.TrafficType.latest, read.value.traffic[0].type);
                }
                try testing.expectEqual(m.generation, read.value.generation.?);
                if (m.fresh) |f| if (!std.mem.eql(u8, f, read.value.etag)) {
                    m.stale = f;
                };
                m.fresh = try arena.dupe(u8, read.value.etag);
            },
            5 => if (m.executions > 0) {
                const i = g.intRange(usize, 0, m.executions - 1);
                var read = try client.getExecutionNamed(m.execution_names[i]);
                defer read.deinit();
                try testing.expectEqual(m.statuses[i], read.value.status());
            },
            // An operation read back: a run's or a cancel's done once its
            // execution has ended, failed only for a failed one; a traffic
            // change's done, failed as its target said.
            6 => if (m.op_count > 0) {
                const op = m.ops[g.intRange(usize, 0, m.op_count - 1)];
                var read = try client.getOperation(op.name);
                defer read.deinit();
                if (op.execution) |i| {
                    try testing.expectEqual(m.statuses[i].ended(), read.value.done);
                    const failed = read.value.done and m.statuses[i] == .failed;
                    try testing.expectEqual(failed, read.value.failure != null);
                    try testing.expectEqual(m.statuses[i], read.value.subject.execution.status());
                } else {
                    try testing.expect(read.value.done);
                    try testing.expectEqual(op.failure, if (read.value.failure) |f| f.code else null);
                }
            },
            else => {
                var all = try client.listExecutions("us-central1", "-", .{});
                defer all.deinit();
                try testing.expectEqual(m.executions, all.value.executions.len);
            },
        }
    }
    try testing.expectEqual(m.executions, fake.executionCount());
}

test "slow property writes: any sequence of runs, cancels, status moves and traffic changes holds to production's rules" {
    try test_util.fuzzBytes({}, writesProperty, .{
        .corpus = &.{
            // Run, cancel, move, read the operation.
            "\x10\x00\x00\x02\x00\x01\x00\x04\x06\x00",
            // Read, change, change with the stale etag, read.
            "\x10\x04\x03\x00\x00\x00\x03\x01\x01\x00\x04",
            // Every kind once.
            "\x20\x00\x01\x01\x00\x01\x02\x00\x03\x02\x00\x01\x04\x05\x00\x06\x00\x07",
            "",
        },
    });
}
