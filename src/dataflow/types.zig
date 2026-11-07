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

/// What a transform or an execution stage does, as the pipeline
/// description names it. A kind the wire adds later reads as `.unknown`.
pub const TransformKind = enum {
    unknown,
    par_do,
    group_by_key,
    flatten,
    read,
    write,
    constant,
    singleton,
    shuffle,

    pub fn fromWire(name: []const u8) TransformKind {
        inline for (.{
            .{ "PAR_DO_KIND", .par_do },
            .{ "GROUP_BY_KEY_KIND", .group_by_key },
            .{ "FLATTEN_KIND", .flatten },
            .{ "READ_KIND", .read },
            .{ "WRITE_KIND", .write },
            .{ "CONSTANT_KIND", .constant },
            .{ "SINGLETON_KIND", .singleton },
            .{ "SHUFFLE_KIND", .shuffle },
        }) |entry| {
            if (std.mem.eql(u8, name, entry[0])) return entry[1];
        }
        return .unknown;
    }
};

/// A display datum's value, in whichever of the wire's typed forms it
/// came. Production sent strings, and integers as strings
/// (`"int64Value": "1"`), which read as `.integer` (measured 2026-11-07).
pub const DisplayValue = union(enum) {
    none,
    string: []const u8,
    integer: i64,
    float: f64,
    boolean: bool,
    timestamp: std.Io.Timestamp,
    /// A proto3 duration as sent, such as "1.500s".
    duration: []const u8,
    java_class: []const u8,
};

/// One setting the SDK, the template service or the template recorded
/// about the pipeline. A template's own parameters carry no namespace;
/// Beam's options carry their interface's (`org.apache.beam.sdk.options.
/// PipelineOptions`), and the template service's settings
/// `google.dataflow.v1beta3.TemplatesService` (measured 2026-11-07).
pub const DisplayData = struct {
    key: []const u8 = "",
    namespace: []const u8 = "",
    label: []const u8 = "",
    url: []const u8 = "",
    value: DisplayValue = .none,
    /// `shortStrValue`: a short form shown beside a long string value,
    /// such as a class's name without its package.
    short: []const u8 = "",
};

/// A transform as the user's pipeline wrote it: one node of the graph a
/// console draws. Collections join it to the transforms around it.
pub const Transform = struct {
    id: []const u8 = "",
    /// The user's name, slashes for nesting: "CountWords/ExtractWords".
    name: []const u8 = "",
    kind: TransformKind = .unknown,
    input_collections: []const []const u8 = &.{},
    output_collections: []const []const u8 = &.{},
    display_data: []const DisplayData = &.{},
};

/// What flows into or out of an execution stage.
pub const StageSource = struct {
    name: []const u8 = "",
    user_name: []const u8 = "",
    /// `originalTransformOrCollection`: the transform or collection of the
    /// user's pipeline it stands for.
    original: []const u8 = "",
    /// An estimate: production sent round numbers (67108864).
    size_bytes: ?i64 = null,
};

/// A transform or a source an execution stage was made from.
pub const StageComponent = struct {
    name: []const u8 = "",
    user_name: []const u8 = "",
    /// `originalTransform`, or a source's `originalTransformOrCollection`.
    original: []const u8 = "",
};

/// A stage the service runs: several of the user's transforms fused into
/// one, the names `stage_states` report on (`F58`).
pub const Stage = struct {
    id: []const u8 = "",
    name: []const u8 = "",
    kind: TransformKind = .unknown,
    inputs: []const StageSource = &.{},
    outputs: []const StageSource = &.{},
    /// Stage ids that must finish before this one starts.
    prerequisites: []const []const u8 = &.{},
    transforms: []const StageComponent = &.{},
    sources: []const StageComponent = &.{},
};

/// `pipelineDescription`: the job's graph, as the user wrote it and as
/// the service runs it, and the settings it was launched with. The
/// transforms come in another order on every read, even of a job that
/// has ended (measured 2026-11-07): join them by `id` and by their
/// collections, not by position.
pub const Pipeline = struct {
    transforms: []const Transform = &.{},
    stages: []const Stage = &.{},
    display_data: []const DisplayData = &.{},
    /// Only `.all` carries it.
    step_names_hash: []const u8 = "",
};

/// One pool of workers. Production's pool also holds about 450 KB of
/// staged packages and metadata, which the decode skips.
pub const WorkerPool = struct {
    /// "harness" when measured.
    kind: []const u8 = "",
    machine_type: []const u8 = "",
    num_workers: ?i64 = null,
    /// `autoscalingSettings.maxNumWorkers`.
    max_workers: ?i64 = null,
    autoscaling_algorithm: []const u8 = "",
    disk_size_gb: ?i64 = null,
    disk_type: []const u8 = "",
    zone: []const u8 = "",
    network: []const u8 = "",
    subnetwork: []const u8 = "",
    ip_configuration: []const u8 = "",
    teardown_policy: []const u8 = "",
    on_host_maintenance: []const u8 = "",
    /// `workerHarnessContainerImage`.
    harness_image: []const u8 = "",
};

/// Where and as whom the job runs. The decode keeps these and skips the
/// raw pipeline options (`sdkPipelineOptions`, about 100 KB when
/// measured), whose values the pipeline's display data carries typed.
pub const Environment = struct {
    service_account: []const u8 = "",
    worker_region: []const u8 = "",
    worker_zone: []const u8 = "",
    /// Production listed about 50, nearly all Google's own.
    experiments: []const []const u8 = &.{},
    service_options: []const []const u8 = &.{},
    shuffle_mode: []const u8 = "",
    streaming_mode: []const u8 = "",
    flex_resource_scheduling_goal: []const u8 = "",
    temp_storage_prefix: []const u8 = "",
    dataset: []const u8 = "",
    service_kms_key_name: []const u8 = "",
    use_public_ips: ?bool = null,
    worker_pools: []const WorkerPool = &.{},
};

pub const SdkSupportStatus = enum {
    unknown,
    supported,
    stale,
    deprecated,
    unsupported,

    pub fn fromWire(name: []const u8) SdkSupportStatus {
        inline for (.{
            .{ "SUPPORTED", .supported },
            .{ "STALE", .stale },
            .{ "DEPRECATED", .deprecated },
            .{ "UNSUPPORTED", .unsupported },
        }) |entry| {
            if (std.mem.eql(u8, name, entry[0])) return entry[1];
        }
        return .unknown;
    }
};

/// `jobMetadata.sdkVersion`: "Apache Beam SDK for Java" 2.77.0,
/// supported, when measured.
pub const Sdk = struct {
    version: []const u8 = "",
    /// `versionDisplayName`.
    name: []const u8 = "",
    support: SdkSupportStatus = .unknown,
};

/// A step as the service compiled it, which only `.all` carries. Its
/// properties have no schema, so they are kept as JSON text.
pub const Step = struct {
    kind: []const u8 = "",
    name: []const u8 = "",
    /// The step's `properties` object as JSON, "" when it had none.
    /// Production orders its members differently from one read to the
    /// next (measured 2026-11-07), so parse it rather than compare text.
    properties: []const u8 = "",
};

/// A Google-provided template, as its labels name it.
pub const Template = struct {
    name: []const u8,
    version: []const u8 = "",
    /// "legacy" for a classic template, "flex" for a Flex one.
    type: []const u8 = "",
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
    /// The job's graph and the settings it was launched with: a get at
    /// `.description` or `.all` carries it, a list or a plain get not.
    pipeline: Pipeline = .{},
    /// Workers, region and service account, at `.description` or `.all`.
    environment: Environment = .{},
    /// The SDK the pipeline was built with. Lists and every get carry it,
    /// in the summary's `jobMetadata` (measured 2026-10-20).
    sdk: Sdk = .{},
    /// The compiled steps, which only `.all` carries.
    steps: []const Step = &.{},

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

    /// The Google-provided template the job was launched from, as its
    /// `goog-dataflow-provided-template-*` labels name it, or null for a
    /// job that names none. A plain get carries the labels already.
    pub fn template(self: Job) ?Template {
        const name = self.label("goog-dataflow-provided-template-name") orelse return null;
        return .{
            .name = name,
            .version = self.label("goog-dataflow-provided-template-version") orelse "",
            .type = self.label("goog-dataflow-provided-template-type") orelse "",
        };
    }

    /// A template parameter's value, as given at launch: the pipeline's
    /// display datum of that key with no namespace (production recorded
    /// Word_Count's `inputFile` and `output` so, beside Beam's own
    /// options under theirs). Null without one, and on a job read at a
    /// view that carries no pipeline.
    pub fn parameter(self: Job, key: []const u8) ?DisplayValue {
        for (self.pipeline.display_data) |d| {
            if (d.namespace.len == 0 and std.mem.eql(u8, d.key, key)) return d.value;
        }
        return null;
    }
};

/// A metric update's value. The wire's `scalar` is a Long, a Double or a
/// Boolean; production sent integers and floats only (measured
/// 2026-11-07). A value in one of the other forms is kept as JSON text.
pub const MetricValue = union(enum) {
    none,
    integer: i64,
    float: f64,
    boolean: bool,
    /// A value in another of the wire's fields (`meanSum` and
    /// `meanCount`, `distribution`, `set`, `gauge`, ...), or a scalar
    /// that is none of the three: the field's name and its JSON text.
    other: Other,

    pub const Other = struct {
        field: []const u8,
        json: []const u8,
    };
};

/// One metric of a job, as the service last computed it.
pub const MetricUpdate = struct {
    /// "dataflow/v1b3" for the service's own, "user" for the pipeline's
    /// counters.
    origin: []const u8 = "",
    name: []const u8 = "",
    /// What the metric is about, as pairs in the server's order:
    /// `original_name`, `step`, `execution_step`, `output_user_name` and
    /// `namespace` when measured, and `tentative`. That order changes
    /// from one read to the next (measured 2026-11-07): look an entry up
    /// with `contextValue`.
    context: []const Label = &.{},
    /// Production sent every metric twice, once with context
    /// `tentative: "true"` and once committed, with the same value when
    /// the job was done. A console shows the committed ones.
    tentative: bool = false,
    value: MetricValue = .none,
    update_time: ?std.Io.Timestamp = null,
    /// "Sum", "Max" and the like; production sent none.
    kind: []const u8 = "",
    /// Production sent none.
    cumulative: ?bool = null,

    /// A context entry's value, or null when the update has no such key.
    pub fn contextValue(self: MetricUpdate, key: []const u8) ?[]const u8 {
        for (self.context) |c| {
            if (std.mem.eql(u8, c.key, key)) return c.value;
        }
        return null;
    }
};

/// What `getJobMetrics` answers. A job 20 s in had 42 updates; done, 374
/// (152 KB), when measured.
pub const JobMetrics = struct {
    /// The time the server computed them at.
    metric_time: ?std.Io.Timestamp = null,
    updates: []const MetricUpdate = &.{},
};

pub const MetricsOptions = struct {
    /// Only updates made at or after this time. Production answered a
    /// time past every update with none.
    start_time: ?std.Io.Timestamp = null,
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
