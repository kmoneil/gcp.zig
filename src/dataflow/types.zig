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
    /// Informational on a read: a pending cancel or drain shows here
    /// before `current_state` catches up.
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
