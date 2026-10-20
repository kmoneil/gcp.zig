//! Dataflow's values as this library holds them: jobs, their states and
//! stage states. Wire names live in the codec. The Job schema has 28
//! properties; these types keep what a pipelines widget needs, and the
//! decode skips the rest.

const std = @import("std");
const core = @import("core");

pub const Owned = core.Owned;

pub const Label = struct {
    key: []const u8,
    value: []const u8,
};

/// A job's state, as the server holds it. `currentState` is the
/// service's own; callers cannot mutate it.
pub const JobState = enum {
    unspecified,
    /// Created and not yet started to run.
    stopped,
    running,
    done,
    failed,
    cancelled,
    /// Replaced by a newer job: an update's terminal state.
    updated,
    draining,
    drained,
    pending,
    cancelling,
    /// FlexRS, waiting to be scheduled.
    queued,
    /// An opt-in cleanup pass after a success. The API does not label
    /// it terminal, though it follows one more state change to done.
    resource_cleaning_up,
    pausing,
    paused,
    /// A state this library does not know, read back from the server.
    unknown,

    pub fn fromWire(name: []const u8) JobState {
        inline for (.{
            .{ "JOB_STATE_RUNNING", .running },
            .{ "JOB_STATE_DONE", .done },
            .{ "JOB_STATE_FAILED", .failed },
            .{ "JOB_STATE_PENDING", .pending },
            .{ "JOB_STATE_CANCELLED", .cancelled },
            .{ "JOB_STATE_CANCELLING", .cancelling },
            .{ "JOB_STATE_STOPPED", .stopped },
            .{ "JOB_STATE_UPDATED", .updated },
            .{ "JOB_STATE_DRAINING", .draining },
            .{ "JOB_STATE_DRAINED", .drained },
            .{ "JOB_STATE_QUEUED", .queued },
            .{ "JOB_STATE_RESOURCE_CLEANING_UP", .resource_cleaning_up },
            .{ "JOB_STATE_PAUSING", .pausing },
            .{ "JOB_STATE_PAUSED", .paused },
            .{ "JOB_STATE_UNKNOWN", .unspecified },
        }) |entry| {
            if (std.mem.eql(u8, name, entry[0])) return entry[1];
        }
        return .unknown;
    }

    /// The five states the API labels terminal: "no further state
    /// updates may be made" after them.
    pub fn terminal(self: JobState) bool {
        return switch (self) {
            .done, .failed, .cancelled, .updated, .drained => true,
            else => false,
        };
    }
};

pub const JobType = enum {
    unspecified,
    batch,
    streaming,
    /// A type this library does not know, read back from the server.
    unknown,

    pub fn fromWire(name: []const u8) JobType {
        inline for (.{
            .{ "JOB_TYPE_BATCH", .batch },
            .{ "JOB_TYPE_STREAMING", .streaming },
            .{ "JOB_TYPE_UNKNOWN", .unspecified },
        }) |entry| {
            if (std.mem.eql(u8, name, entry[0])) return entry[1];
        }
        return .unknown;
    }
};

/// One execution stage's state, for a finer widget.
pub const StageState = struct {
    /// `executionStageName`.
    stage: []const u8 = "",
    state: JobState = .unknown,
    current_state_time: ?std.Io.Timestamp = null,
};

pub const Job = struct {
    /// Assigned by the service, immutable:
    /// `2026-10-20_07_09_34-8524524531325271694` when measured.
    id: []const u8,
    /// The caller's name, unique per active job per region.
    name: []const u8 = "",
    /// `projectId`.
    project: []const u8 = "",
    /// The region whose backend holds the job; what `getJob` needs.
    location: []const u8 = "",
    type: JobType = .unspecified,
    current_state: JobState = .unspecified,
    current_state_time: ?std.Io.Timestamp = null,
    /// What a cancel or a drain asked for, while it is under way: a get
    /// right after one carries `.cancelled` or `.drained` here, with
    /// `current_state` already `.cancelling` or `.draining`. A list's
    /// summary never carries it, and it is gone once the job has ended
    /// (measured 2026-10-20).
    requested_state: JobState = .unspecified,
    create_time: ?std.Io.Timestamp = null,
    /// Equals `create_time` except FlexRS delayed starts.
    start_time: ?std.Io.Timestamp = null,
    labels: []const Label = &.{},
    stage_states: []const StageState = &.{},

    /// Whether the job has reached one of the five terminal states.
    pub fn terminal(self: Job) bool {
        return self.current_state.terminal();
    }

    /// The widget's red: the one terminal state that is trouble.
    pub fn failing(self: Job) bool {
        return self.current_state == .failed;
    }

    /// Whether production takes a cancel of the job as it stands: one
    /// that has not ended, is not already being cancelled, and is past
    /// `.pending` (production refuses a pending job as "not yet ready for
    /// canceling", measured, and takes it once it runs). For a console's
    /// button; `Client.cancelJob` does not ask it, and leaves the
    /// refusing to the server.
    pub fn cancellable(self: Job) bool {
        if (self.current_state.terminal()) return false;
        if (self.current_state == .pending or self.current_state == .cancelling) return false;
        return self.requested_state != .cancelled;
    }

    /// Whether production takes a drain: a streaming job that is running
    /// and has not been asked to stop already. Reads only what a list's
    /// summary carries, as `cancellable` does.
    pub fn drainable(self: Job) bool {
        if (self.type != .streaming or self.current_state != .running) return false;
        return self.requested_state != .drained and self.requested_state != .cancelled;
    }

    /// A label's value, or null when the job does not carry the key.
    pub fn label(self: Job, key: []const u8) ?[]const u8 {
        for (self.labels) |l| {
            if (std.mem.eql(u8, l.key, key)) return l.value;
        }
        return null;
    }
};

/// The list filters, which also pick the order. Unset sends nothing:
/// the server then orders on descending JobUuid.
pub const Filter = enum {
    /// Running jobs first by creation time, then terminated jobs by
    /// termination time.
    all,
    terminated,
    active,

    pub fn toWire(self: Filter) []const u8 {
        return switch (self) {
            .all => "ALL",
            .terminated => "TERMINATED",
            .active => "ACTIVE",
        };
    }
};

/// What a get carries. Lists always answer summaries: the `view`
/// parameter is deprecated there, so only `getJobView` sends one.
pub const JobView = enum {
    summary,
    all,
    description,

    pub fn toWire(self: JobView) []const u8 {
        return switch (self) {
            .summary => "JOB_VIEW_SUMMARY",
            .all => "JOB_VIEW_ALL",
            .description => "JOB_VIEW_DESCRIPTION",
        };
    }
};

pub const ListJobsOptions = struct {
    filter: ?Filter = null,
    /// Only the per-location list filters by name; the aggregated
    /// list's documentation says it does not take one.
    name: ?[]const u8 = null,
    /// 0 for the server's default (at most 50; 1000 is the maximum,
    /// larger values coerced to it).
    page_size: u32 = 0,
    /// Good for 72 hours, production says.
    page_token: ?[]const u8 = null,
};

pub const AggregatedOptions = struct {
    filter: ?Filter = null,
    page_size: u32 = 0,
    page_token: ?[]const u8 = null,
};

pub const JobPage = struct {
    jobs: []const Job,
    /// Null on the last page.
    next_page_token: ?[]const u8 = null,
    /// The regions that did not answer: a page carrying any is
    /// complete for every other region and silent about these, so a
    /// widget should say so rather than quietly show fewer jobs.
    failed_locations: []const []const u8 = &.{},
};

/// A message's importance. The list's filter is a minimum, so the
/// order here is the wire's, lowest first; `unknown` outranks them
/// all, so a future importance is never silently dropped.
pub const MessageImportance = enum {
    unspecified,
    debug,
    detailed,
    basic,
    warning,
    @"error",
    /// An importance this library does not know, read back from the
    /// server.
    unknown,

    pub fn fromWire(name: []const u8) MessageImportance {
        inline for (.{
            .{ "JOB_MESSAGE_ERROR", .@"error" },
            .{ "JOB_MESSAGE_WARNING", .warning },
            .{ "JOB_MESSAGE_BASIC", .basic },
            .{ "JOB_MESSAGE_DETAILED", .detailed },
            .{ "JOB_MESSAGE_DEBUG", .debug },
            .{ "JOB_MESSAGE_IMPORTANCE_UNKNOWN", .unspecified },
        }) |entry| {
            if (std.mem.eql(u8, name, entry[0])) return entry[1];
        }
        return .unknown;
    }

    pub fn toWire(self: MessageImportance) []const u8 {
        return switch (self) {
            .debug => "JOB_MESSAGE_DEBUG",
            .detailed => "JOB_MESSAGE_DETAILED",
            .basic => "JOB_MESSAGE_BASIC",
            .warning => "JOB_MESSAGE_WARNING",
            .@"error" => "JOB_MESSAGE_ERROR",
            .unspecified, .unknown => "JOB_MESSAGE_IMPORTANCE_UNKNOWN",
        };
    }

    /// Whether a message at this importance passes a filter of `min`.
    pub fn atLeast(self: MessageImportance, min: MessageImportance) bool {
        return @backingInt(self) >= @backingInt(min);
    }
};

/// One line of a job's story, as the messages list answers them.
pub const JobMessage = struct {
    id: []const u8 = "",
    time: ?std.Io.Timestamp = null,
    /// `messageText`.
    text: []const u8 = "",
    importance: MessageImportance = .unspecified,
};

/// A worker-count change. Production answers these regardless of the
/// importance filter (measured 2026-10-20: ERROR still carried six).
pub const AutoscalingEvent = struct {
    /// The wire's name, such as `TARGET_NUM_WORKERS_CHANGED`, kept raw.
    event_type: []const u8 = "",
    time: ?std.Io.Timestamp = null,
    /// The structured description's `messageText`.
    description: []const u8 = "",
    current_num_workers: ?i64 = null,
    target_num_workers: ?i64 = null,
    worker_pool: []const u8 = "",
};

pub const ListMessagesOptions = struct {
    /// Unset sends nothing and production answers every importance;
    /// `.@"error"` is the widget's "why is it red".
    minimum_importance: ?MessageImportance = null,
    /// Defaults to the job's creation when unset.
    start_time: ?std.Io.Timestamp = null,
    /// Defaults to now when unset.
    end_time: ?std.Io.Timestamp = null,
    /// 0 for the server's default, which is generous: production
    /// answered every message past a pageSize of 5 when measured.
    page_size: u32 = 0,
    page_token: ?[]const u8 = null,
};

pub const MessagePage = struct {
    messages: []const JobMessage,
    autoscaling_events: []const AutoscalingEvent = &.{},
    /// Null on the last page.
    next_page_token: ?[]const u8 = null,
};

const testing = std.testing;

test "states wire both ways, the terminal five, unknown for the rest" {
    try testing.expectEqual(JobState.running, JobState.fromWire("JOB_STATE_RUNNING"));
    try testing.expectEqual(JobState.done, JobState.fromWire("JOB_STATE_DONE"));
    try testing.expectEqual(JobState.pending, JobState.fromWire("JOB_STATE_PENDING"));
    try testing.expectEqual(JobState.resource_cleaning_up, JobState.fromWire("JOB_STATE_RESOURCE_CLEANING_UP"));
    try testing.expectEqual(JobState.unspecified, JobState.fromWire("JOB_STATE_UNKNOWN"));
    try testing.expectEqual(JobState.unknown, JobState.fromWire("JOB_STATE_MOODY"));
    try testing.expectEqual(JobType.batch, JobType.fromWire("JOB_TYPE_BATCH"));
    try testing.expectEqual(JobType.streaming, JobType.fromWire("JOB_TYPE_STREAMING"));
    try testing.expectEqual(JobType.unknown, JobType.fromWire("JOB_TYPE_SQL"));

    for ([_]JobState{ .done, .failed, .cancelled, .updated, .drained }) |state| {
        try testing.expect(state.terminal());
    }
    for ([_]JobState{ .unspecified, .stopped, .running, .draining, .pending, .cancelling, .queued, .resource_cleaning_up, .pausing, .paused, .unknown }) |state| {
        try testing.expect(!state.terminal());
    }
}

test "Job.terminal, failing and label answer the widget's questions" {
    var job: Job = .{ .id = "2026-10-20_07_09_34-85", .name = "wordcount" };
    try testing.expect(!job.terminal());
    try testing.expect(!job.failing());
    job.current_state = .failed;
    try testing.expect(job.terminal());
    try testing.expect(job.failing());
    job.current_state = .done;
    try testing.expect(job.terminal());
    try testing.expect(!job.failing());
    try testing.expectEqual(null, job.label("team"));
    job.labels = &.{.{ .key = "team", .value = "data" }};
    try testing.expectEqualStrings("data", job.label("team").?);

    try testing.expectEqualStrings("ALL", Filter.all.toWire());
    try testing.expectEqualStrings("TERMINATED", Filter.terminated.toWire());
    try testing.expectEqualStrings("ACTIVE", Filter.active.toWire());
    try testing.expectEqualStrings("JOB_VIEW_SUMMARY", JobView.summary.toWire());
    try testing.expectEqualStrings("JOB_VIEW_ALL", JobView.all.toWire());
    try testing.expectEqualStrings("JOB_VIEW_DESCRIPTION", JobView.description.toWire());
}

test "Job.cancellable and drainable over every type, state and request" {
    const all_states = std.enums.values(JobState);
    const all_types = std.enums.values(JobType);
    for (all_types) |job_type| for (all_states) |current| for (all_states) |requested| {
        const job: Job = .{ .id = "j", .type = job_type, .current_state = current, .requested_state = requested };
        const stopping = requested == .cancelled or requested == .drained;
        try testing.expectEqual(!current.terminal() and current != .pending and current != .cancelling and requested != .cancelled, job.cancellable());
        try testing.expectEqual(job_type == .streaming and current == .running and !stopping, job.drainable());
    };
    // The cases a console's buttons meet.
    try testing.expect((Job{ .id = "j", .type = .batch, .current_state = .running }).cancellable());
    try testing.expect(!(Job{ .id = "j", .type = .batch, .current_state = .pending }).cancellable());
    try testing.expect(!(Job{ .id = "j", .type = .batch, .current_state = .running }).drainable());
    try testing.expect((Job{ .id = "j", .type = .streaming, .current_state = .running }).drainable());
    try testing.expect((Job{ .id = "j", .type = .streaming, .current_state = .draining, .requested_state = .drained }).cancellable());
    try testing.expect(!(Job{ .id = "j", .type = .streaming, .current_state = .done }).cancellable());
}

test "message importances wire both ways and order as a minimum filter" {
    try testing.expectEqual(MessageImportance.@"error", MessageImportance.fromWire("JOB_MESSAGE_ERROR"));
    try testing.expectEqual(MessageImportance.basic, MessageImportance.fromWire("JOB_MESSAGE_BASIC"));
    try testing.expectEqual(MessageImportance.unspecified, MessageImportance.fromWire("JOB_MESSAGE_IMPORTANCE_UNKNOWN"));
    try testing.expectEqual(MessageImportance.unknown, MessageImportance.fromWire("JOB_MESSAGE_SHOUTED"));
    try testing.expectEqualStrings("JOB_MESSAGE_ERROR", MessageImportance.@"error".toWire());
    try testing.expectEqualStrings("JOB_MESSAGE_IMPORTANCE_UNKNOWN", MessageImportance.unknown.toWire());
    try testing.expect(MessageImportance.@"error".atLeast(.basic));
    try testing.expect(MessageImportance.basic.atLeast(.basic));
    try testing.expect(!MessageImportance.detailed.atLeast(.basic));
    try testing.expect(MessageImportance.unknown.atLeast(.@"error"));
}
