//! Cloud Run's values as this library holds them: services, revisions,
//! their conditions and traffic, and the locations they live in. Wire
//! names live in the codec. The schemas are large; these types keep what
//! a health view and a deploy marker need, plus what identifies trouble,
//! and the decode skips the rest.

const std = @import("std");
const core = @import("core");

pub const Owned = core.Owned;

pub const Label = struct {
    key: []const u8,
    value: []const u8,
};

/// A condition's state, as the server holds it.
pub const ConditionState = enum {
    unspecified,
    pending,
    reconciling,
    failed,
    succeeded,
    /// A state this library does not know, read back from the server.
    unknown,

    pub fn fromWire(name: []const u8) ConditionState {
        inline for (.{
            .{ "CONDITION_SUCCEEDED", .succeeded },
            .{ "CONDITION_FAILED", .failed },
            .{ "CONDITION_PENDING", .pending },
            .{ "CONDITION_RECONCILING", .reconciling },
            .{ "STATE_UNSPECIFIED", .unspecified },
        }) |entry| {
            if (std.mem.eql(u8, name, entry[0])) return entry[1];
        }
        return .unknown;
    }
};

pub const ConditionSeverity = enum {
    unspecified,
    @"error",
    warning,
    info,
    /// A severity this library does not know, read back from the server.
    unknown,

    pub fn fromWire(name: []const u8) ConditionSeverity {
        inline for (.{
            .{ "ERROR", .@"error" },
            .{ "WARNING", .warning },
            .{ "INFO", .info },
            .{ "SEVERITY_UNSPECIFIED", .unspecified },
        }) |entry| {
            if (std.mem.eql(u8, name, entry[0])) return entry[1];
        }
        return .unknown;
    }
};

/// One condition of a service or revision, such as `Ready`.
pub const Condition = struct {
    type: []const u8 = "",
    state: ConditionState = .unknown,
    message: []const u8 = "",
    /// The wire's one-of reasons (`reason`, `revisionReason`,
    /// `executionReason`, `instanceReason`) collapsed to whichever came:
    /// production sent `reason: REVISION_FAILED` for a failed deploy.
    reason: []const u8 = "",
    severity: ConditionSeverity = .unspecified,
    last_transition_time: ?std.Io.Timestamp = null,

    pub fn succeeded(self: Condition) bool {
        return self.state == .succeeded;
    }
};

pub const TrafficType = enum {
    unspecified,
    latest,
    revision,
    /// A type this library does not know, read back from the server.
    unknown,

    pub fn fromWire(name: []const u8) TrafficType {
        inline for (.{
            .{ "TRAFFIC_TARGET_ALLOCATION_TYPE_LATEST", .latest },
            .{ "TRAFFIC_TARGET_ALLOCATION_TYPE_REVISION", .revision },
            .{ "TRAFFIC_TARGET_ALLOCATION_TYPE_UNSPECIFIED", .unspecified },
        }) |entry| {
            if (std.mem.eql(u8, name, entry[0])) return entry[1];
        }
        return .unknown;
    }
};

/// Where traffic is asked to go (`traffic`), or where the server says it
/// goes (`traffic_statuses`, which adds `uri`).
pub const TrafficTarget = struct {
    type: TrafficType = .unspecified,
    /// A revision id; empty for `.latest`.
    revision: []const u8 = "",
    percent: i64 = 0,
    tag: []const u8 = "",
    /// Only on `traffic_statuses`, and only for a tagged target.
    uri: []const u8 = "",
};

/// One container of a revision: what a deploy marker names.
pub const Container = struct {
    name: []const u8 = "",
    /// Production answers it pinned to its digest, not the tag deployed.
    image: []const u8 = "",
};

pub const Service = struct {
    /// `projects/P/locations/L/services/S`.
    name: []const u8,
    /// The trailing segment of `name`.
    id: []const u8,
    /// The `L` segment of `name`.
    location: []const u8,
    description: []const u8 = "",
    /// The main URI; `urls` holds every form.
    uri: []const u8 = "",
    urls: []const []const u8 = &.{},
    /// Revision ids (the trailing segment, as the console shows them).
    latest_ready_revision: []const u8 = "",
    latest_created_revision: []const u8 = "",
    traffic: []const TrafficTarget = &.{},
    traffic_statuses: []const TrafficTarget = &.{},
    /// The service's own summary condition, `Ready` when healthy.
    terminal_condition: ?Condition = null,
    conditions: []const Condition = &.{},
    create_time: ?std.Io.Timestamp = null,
    update_time: ?std.Io.Timestamp = null,
    creator: []const u8 = "",
    last_modifier: []const u8 = "",
    generation: ?i64 = null,
    observed_generation: ?i64 = null,
    /// The server is still working towards the asked state.
    reconciling: bool = false,
    labels: []const Label = &.{},
    /// This version of the service, as the server fingerprints it: a
    /// quoted string, quote characters and all, new on every change. A
    /// write that names it is refused once the service has changed.
    etag: []const u8 = "",

    /// Whether the service's terminal condition succeeded.
    pub fn ready(self: Service) bool {
        const terminal = self.terminal_condition orelse return false;
        return terminal.succeeded();
    }
};

pub const Revision = struct {
    /// `projects/P/locations/L/services/S/revisions/R`.
    name: []const u8,
    /// The trailing segment: `<service>-0000N-<suffix>`, as production
    /// names them.
    id: []const u8,
    /// The service's id, as the wire sends it.
    service: []const u8,
    /// The `L` segment of `name`.
    location: []const u8,
    /// The deploy marker.
    create_time: ?std.Io.Timestamp = null,
    update_time: ?std.Io.Timestamp = null,
    generation: ?i64 = null,
    containers: []const Container = &.{},
    conditions: []const Condition = &.{},
    /// A console link to the revision's logs.
    log_uri: []const u8 = "",
    service_account: []const u8 = "",
    labels: []const Label = &.{},

    /// The `Ready` condition, or null when the answer carried none.
    pub fn readyCondition(self: Revision) ?Condition {
        for (self.conditions) |condition| {
            if (std.mem.eql(u8, condition.type, "Ready")) return condition;
        }
        return null;
    }

    /// Whether the `Ready` condition succeeded.
    pub fn ready(self: Revision) bool {
        const condition = self.readyCondition() orelse return false;
        return condition.succeeded();
    }
};

/// Where an execution stands. A job's latest execution carries one from
/// the wire (`completionStatus`); `Execution.status` works one out from an
/// execution's own conditions.
pub const ExecutionStatus = enum {
    unspecified,
    /// Made, not started: production took about 90 s to start a small
    /// job's container (measured 2026-10-21).
    pending,
    running,
    succeeded,
    failed,
    /// Asked to stop and not yet stopped: only `Execution.status` says
    /// this, from a task already cancelled.
    cancelling,
    cancelled,
    /// A status this library does not know, read back from the server.
    unknown,

    pub fn fromWire(name: []const u8) ExecutionStatus {
        inline for (.{
            .{ "EXECUTION_SUCCEEDED", .succeeded },
            .{ "EXECUTION_FAILED", .failed },
            .{ "EXECUTION_RUNNING", .running },
            .{ "EXECUTION_PENDING", .pending },
            .{ "EXECUTION_CANCELLED", .cancelled },
            .{ "COMPLETION_STATUS_UNSPECIFIED", .unspecified },
        }) |entry| {
            if (std.mem.eql(u8, name, entry[0])) return entry[1];
        }
        return .unknown;
    }

    /// Succeeded, failed or cancelled: nothing more will happen to it.
    pub fn ended(self: ExecutionStatus) bool {
        return switch (self) {
            .succeeded, .failed, .cancelled => true,
            else => false,
        };
    }
};

/// A job's latest execution, as the job names it.
pub const ExecutionReference = struct {
    /// `projects/P/locations/L/jobs/J/executions/E`. The wire sends the id
    /// alone; the decode makes the full name from the job's.
    name: []const u8,
    /// The trailing segment: `<job>-<suffix>`.
    id: []const u8,
    create_time: ?std.Io.Timestamp = null,
    completion_time: ?std.Io.Timestamp = null,
    status: ExecutionStatus = .unspecified,
};

pub const Job = struct {
    /// `projects/P/locations/L/jobs/J`.
    name: []const u8,
    /// The trailing segment of `name`.
    id: []const u8,
    /// The `L` segment of `name`.
    location: []const u8,
    /// Null until the job's first run.
    latest_created_execution: ?ExecutionReference = null,
    /// The job's own summary condition, `Ready` when its configuration
    /// is: it stays succeeded after a run fails (measured).
    terminal_condition: ?Condition = null,
    conditions: []const Condition = &.{},
    /// How many executions the job has made; 0 before the first.
    execution_count: i32 = 0,
    /// What each execution runs, from the job's template: production
    /// answers it with its defaults filled in.
    task_count: i32 = 0,
    parallelism: i32 = 0,
    /// Each task attempt's limit.
    task_timeout_s: ?f64 = null,
    /// How often a failed task is tried again; the server's default is 3.
    max_retries: ?i32 = null,
    containers: []const Container = &.{},
    service_account: []const u8 = "",
    create_time: ?std.Io.Timestamp = null,
    update_time: ?std.Io.Timestamp = null,
    creator: []const u8 = "",
    last_modifier: []const u8 = "",
    generation: ?i64 = null,
    observed_generation: ?i64 = null,
    reconciling: bool = false,
    labels: []const Label = &.{},
    etag: []const u8 = "",

    /// Whether the job's terminal condition succeeded.
    pub fn ready(self: Job) bool {
        const terminal = self.terminal_condition orelse return false;
        return terminal.succeeded();
    }
};

/// One run of a job.
pub const Execution = struct {
    /// `projects/P/locations/L/jobs/J/executions/E`.
    name: []const u8,
    /// The trailing segment: `<job>-<suffix>`.
    id: []const u8,
    /// The job's id, as the wire sends it.
    job: []const u8,
    /// The `L` segment of `name`.
    location: []const u8,
    create_time: ?std.Io.Timestamp = null,
    /// When its first task started; null while pending.
    start_time: ?std.Io.Timestamp = null,
    /// When it ended. Production never set one on an execution cancelled
    /// before it started, so `status` reads the conditions instead.
    completion_time: ?std.Io.Timestamp = null,
    update_time: ?std.Io.Timestamp = null,
    task_count: i32 = 0,
    parallelism: i32 = 0,
    running_count: i32 = 0,
    succeeded_count: i32 = 0,
    failed_count: i32 = 0,
    cancelled_count: i32 = 0,
    retried_count: i32 = 0,
    /// `Completed` holds the outcome, `Started` the start; production
    /// also sends `Retry`, `ContainerReady` and `ResourcesAvailable`.
    conditions: []const Condition = &.{},
    /// A console link to the execution's logs.
    log_uri: []const u8 = "",
    reconciling: bool = false,
    generation: ?i64 = null,
    observed_generation: ?i64 = null,
    labels: []const Label = &.{},

    /// The condition of `kind` (`Completed`, `Started`), or null.
    pub fn condition(self: Execution, kind: []const u8) ?Condition {
        for (self.conditions) |c| {
            if (std.mem.eql(u8, c.type, kind)) return c;
        }
        return null;
    }

    /// Where it stands, from its conditions as production showed them
    /// (2026-10-21): `Completed` succeeded or failed (with reason
    /// `CANCELLED` for a cancel) once it has ended; before that, a task
    /// already cancelled while `Completed` is still reconciling; then
    /// `Started` succeeded once its container runs; anything earlier is
    /// pending.
    pub fn status(self: Execution) ExecutionStatus {
        const completed = self.condition("Completed");
        if (completed) |c| switch (c.state) {
            .succeeded => return .succeeded,
            .failed => return if (std.mem.eql(u8, c.reason, "CANCELLED")) .cancelled else .failed,
            else => {},
        };
        if (self.cancelled_count > 0) return .cancelling;
        if (completed) |c| if (std.mem.eql(u8, c.reason, "CANCELLING")) return .cancelling;
        if (self.condition("Started")) |c| if (c.succeeded()) return .running;
        if (self.running_count > 0) return .running;
        return .pending;
    }

    /// Whether production takes a cancel of it as it stands: pending or
    /// running. A cancel of an ended one is refused; one of a cancelling
    /// one is taken but changes nothing.
    pub fn cancellable(self: Execution) bool {
        return switch (self.status()) {
            .pending, .running => true,
            else => false,
        };
    }
};

/// A long-running operation: what each of Cloud Run's writes answers.
pub const Operation = struct {
    /// `projects/P/locations/L/operations/U`, for `Client.getOperation`.
    name: []const u8,
    done: bool = false,
    /// Set when the operation is done and failed: google.rpc.Status.
    failure: ?Failure = null,
    /// What it acts on: the response once done and succeeded, the
    /// metadata until then.
    subject: Subject = .none,

    pub const Failure = struct {
        /// A google.rpc.Code: 9 for a traffic target that does not
        /// exist, 10 for a failed execution, as production answered.
        code: i32,
        message: []const u8,
    };

    pub const Subject = union(enum) {
        none,
        /// A run's or a cancel's.
        execution: Execution,
        /// A traffic change's.
        service: Service,
        /// Another type, by its `@type` URL.
        other: []const u8,
    };
};

/// How `Client.routeAllTraffic` sends its change.
pub const RouteOptions = struct {
    /// Required: `Service.etag` from the read the change was decided on.
    /// Production refuses the change once the service has changed since,
    /// with `error.Aborted`, rather than overwrite it. Empty is refused
    /// before sending: production takes a change with no etag unguarded.
    etag: []const u8,
    /// Checks the change without making it. Production checks the etag
    /// and the target's form, but not that the revision exists or is
    /// ready (measured).
    validate_only: bool = false,
};

pub const ListOptions = struct {
    /// 0 for the server's default.
    page_size: u32 = 0,
    page_token: ?[]const u8 = null,
};

pub const ServicePage = struct {
    services: []const Service,
    /// Null on the last page.
    next_page_token: ?[]const u8 = null,
    /// On a `-` location, the regions the server could not ask.
    unreachable_regions: []const []const u8 = &.{},
};

pub const RevisionPage = struct {
    revisions: []const Revision,
    /// Null on the last page.
    next_page_token: ?[]const u8 = null,
};

pub const JobPage = struct {
    jobs: []const Job,
    /// Null on the last page.
    next_page_token: ?[]const u8 = null,
};

pub const ExecutionPage = struct {
    executions: []const Execution,
    /// Null on the last page.
    next_page_token: ?[]const u8 = null,
};

pub const Location = struct {
    /// `projects/P/locations/L`.
    name: []const u8,
    /// The trailing segment: `us-central1`.
    id: []const u8,
    display_name: []const u8 = "",
    labels: []const Label = &.{},
};

pub const LocationPage = struct {
    locations: []const Location,
    /// Null on the last page.
    next_page_token: ?[]const u8 = null,
};

const testing = std.testing;

test "enum wires both ways, unknown for the rest" {
    try testing.expectEqual(ConditionState.succeeded, ConditionState.fromWire("CONDITION_SUCCEEDED"));
    try testing.expectEqual(ConditionState.failed, ConditionState.fromWire("CONDITION_FAILED"));
    try testing.expectEqual(ConditionState.pending, ConditionState.fromWire("CONDITION_PENDING"));
    try testing.expectEqual(ConditionState.reconciling, ConditionState.fromWire("CONDITION_RECONCILING"));
    try testing.expectEqual(ConditionState.unspecified, ConditionState.fromWire("STATE_UNSPECIFIED"));
    try testing.expectEqual(ConditionState.unknown, ConditionState.fromWire("CONDITION_MOODY"));
    try testing.expectEqual(ConditionSeverity.@"error", ConditionSeverity.fromWire("ERROR"));
    try testing.expectEqual(ConditionSeverity.info, ConditionSeverity.fromWire("INFO"));
    try testing.expectEqual(ConditionSeverity.unknown, ConditionSeverity.fromWire("FATAL"));
    try testing.expectEqual(TrafficType.latest, TrafficType.fromWire("TRAFFIC_TARGET_ALLOCATION_TYPE_LATEST"));
    try testing.expectEqual(TrafficType.revision, TrafficType.fromWire("TRAFFIC_TARGET_ALLOCATION_TYPE_REVISION"));
    try testing.expectEqual(TrafficType.unknown, TrafficType.fromWire("SPLIT"));
}

test "Service.ready and Revision.ready answer the widget's question" {
    var service: Service = .{ .name = "projects/p/locations/l/services/s", .id = "s", .location = "l" };
    try testing.expect(!service.ready());
    service.terminal_condition = .{ .type = "Ready", .state = .succeeded };
    try testing.expect(service.ready());
    service.terminal_condition = .{ .type = "Ready", .state = .failed, .reason = "REVISION_FAILED" };
    try testing.expect(!service.ready());

    var revision: Revision = .{ .name = "projects/p/locations/l/services/s/revisions/r", .id = "r", .service = "s", .location = "l" };
    try testing.expect(!revision.ready());
    try testing.expectEqual(null, revision.readyCondition());
    revision.conditions = &.{
        .{ .type = "Active", .state = .succeeded, .severity = .info },
        .{ .type = "Ready", .state = .succeeded, .message = "Deploying revision succeeded in 3.77s." },
    };
    try testing.expect(revision.ready());
    try testing.expectEqualStrings("Deploying revision succeeded in 3.77s.", revision.readyCondition().?.message);
    revision.conditions = &.{.{ .type = "Ready", .state = .failed, .message = "Image not found." }};
    try testing.expect(!revision.ready());
}

test "ExecutionStatus: the wire's completion statuses, and which have ended" {
    try testing.expectEqual(ExecutionStatus.succeeded, ExecutionStatus.fromWire("EXECUTION_SUCCEEDED"));
    try testing.expectEqual(ExecutionStatus.failed, ExecutionStatus.fromWire("EXECUTION_FAILED"));
    try testing.expectEqual(ExecutionStatus.running, ExecutionStatus.fromWire("EXECUTION_RUNNING"));
    try testing.expectEqual(ExecutionStatus.pending, ExecutionStatus.fromWire("EXECUTION_PENDING"));
    try testing.expectEqual(ExecutionStatus.cancelled, ExecutionStatus.fromWire("EXECUTION_CANCELLED"));
    try testing.expectEqual(ExecutionStatus.unspecified, ExecutionStatus.fromWire("COMPLETION_STATUS_UNSPECIFIED"));
    try testing.expectEqual(ExecutionStatus.unknown, ExecutionStatus.fromWire("EXECUTION_CANCELLING"));
    for ([_]ExecutionStatus{ .succeeded, .failed, .cancelled }) |s| try testing.expect(s.ended());
    for ([_]ExecutionStatus{ .unspecified, .pending, .running, .cancelling, .unknown }) |s| try testing.expect(!s.ended());
}

test "Execution.status follows production's conditions through an execution's life" {
    const Case = struct { []const Condition, i32, i32, ExecutionStatus, bool };
    const completed_pending: Condition = .{ .type = "Completed", .state = .pending };
    const completed_reconciling: Condition = .{ .type = "Completed", .state = .reconciling };
    const started_reconciling: Condition = .{ .type = "Started", .state = .reconciling };
    const started: Condition = .{ .type = "Started", .state = .succeeded };
    // Measured 2026-10-21, in order; then what no run showed but the wire
    // allows.
    for ([_]Case{
        // 0.2 s after the run: only Completed, pending.
        .{ &.{completed_pending}, 0, 0, .pending, true },
        // Provisioning: Started and Completed reconciling, for ~90 s.
        .{ &.{ started_reconciling, .{ .type = "Retry", .state = .succeeded, .reason = "WAITING_FOR_OPERATION" }, completed_reconciling }, 0, 0, .pending, true },
        // Started, a task running.
        .{ &.{ started, completed_reconciling }, 1, 0, .running, true },
        // Between a failed attempt and its retry: started, none running.
        .{ &.{ started, completed_reconciling }, 0, 0, .running, true },
        // A cancel taken: the task cancelled, Completed still reconciling.
        .{ &.{ started, completed_reconciling }, 0, 1, .cancelling, false },
        // Ended.
        .{ &.{ started, .{ .type = "Completed", .state = .succeeded } }, 0, 0, .succeeded, false },
        .{ &.{ started, .{ .type = "Completed", .state = .failed, .reason = "NON_ZERO_EXIT_CODE" } }, 0, 0, .failed, false },
        .{ &.{ started, .{ .type = "Completed", .state = .failed, .reason = "CANCELLED", .message = "Cancelled by user." } }, 0, 1, .cancelled, false },
        // Cancelled before it started: Started still reconciling.
        .{ &.{ started_reconciling, .{ .type = "Completed", .state = .failed, .reason = "CANCELLED" } }, 0, 1, .cancelled, false },
        // The wire's CANCELLING reason, never seen, reads as cancelling.
        .{ &.{ started, .{ .type = "Completed", .state = .reconciling, .reason = "CANCELLING" } }, 1, 0, .cancelling, false },
        // A running count without a Started condition is still running.
        .{ &.{}, 1, 0, .running, true },
        // Nothing at all: not started.
        .{ &.{}, 0, 0, .pending, true },
        // A Completed state this library does not know is not an end.
        .{ &.{ started, .{ .type = "Completed", .state = .unknown } }, 1, 0, .running, true },
    }) |case| {
        const execution: Execution = .{
            .name = "projects/p/locations/l/jobs/j/executions/j-1",
            .id = "j-1",
            .job = "j",
            .location = "l",
            .conditions = case[0],
            .running_count = case[1],
            .cancelled_count = case[2],
        };
        try testing.expectEqual(case[3], execution.status());
        try testing.expectEqual(case[4], execution.cancellable());
    }
    const bare: Execution = .{ .name = "e", .id = "e", .job = "j", .location = "l", .conditions = &.{started} };
    try testing.expectEqual(null, bare.condition("Completed"));
    try testing.expectEqual(ConditionState.succeeded, bare.condition("Started").?.state);
}

test "Job.ready reads the job's own terminal condition" {
    var job: Job = .{ .name = "projects/p/locations/l/jobs/j", .id = "j", .location = "l" };
    try testing.expect(!job.ready());
    job.terminal_condition = .{ .type = "Ready", .state = .succeeded };
    try testing.expect(job.ready());
    job.terminal_condition = .{ .type = "Ready", .state = .failed };
    try testing.expect(!job.ready());
}
