//! Cloud Monitoring's values as this library holds them: metric
//! descriptors, monitored resources, time series to write and what a write
//! came to. Wire names live in the codec.

const std = @import("std");
const core = @import("core");

pub const Owned = core.Owned;

/// How a metric's points relate in time.
pub const Kind = enum {
    /// A value at an instant: each point's start is its end.
    gauge,
    /// The change over each point's interval. Not for user metrics under
    /// `custom.googleapis.com/`: production refuses to create one.
    delta,
    /// A running total since a fixed start time, which moves only when the
    /// total starts over.
    cumulative,
    /// A kind this library does not know, read back from the server.
    unknown,

    pub fn wire(k: Kind) []const u8 {
        return switch (k) {
            .gauge => "GAUGE",
            .delta => "DELTA",
            .cumulative => "CUMULATIVE",
            .unknown => "METRIC_KIND_UNSPECIFIED",
        };
    }

    pub fn fromWire(name: []const u8) Kind {
        inline for (.{ .gauge, .delta, .cumulative }) |k| {
            if (std.mem.eql(u8, name, comptime wire(k))) return k;
        }
        return .unknown;
    }
};

/// What each point of a metric holds.
pub const ValueType = enum {
    bool,
    int64,
    double,
    /// Not for user metrics under `custom.googleapis.com/`: production
    /// refuses to create one.
    string,
    distribution,
    /// Read only: Google's own metrics, never one written here.
    money,
    /// A value type this library does not know, read back from the server.
    unknown,

    pub fn wire(t: ValueType) []const u8 {
        return switch (t) {
            .bool => "BOOL",
            .int64 => "INT64",
            .double => "DOUBLE",
            .string => "STRING",
            .distribution => "DISTRIBUTION",
            .money => "MONEY",
            .unknown => "VALUE_TYPE_UNSPECIFIED",
        };
    }

    pub fn fromWire(name: []const u8) ValueType {
        inline for (.{ .bool, .int64, .double, .string, .distribution, .money }) |t| {
            if (std.mem.eql(u8, name, comptime wire(t))) return t;
        }
        return .unknown;
    }
};

pub const Label = struct {
    key: []const u8,
    value: []const u8,
};

/// What a label's values are. A label a write adds to a descriptor is a
/// string.
pub const LabelType = enum {
    string,
    bool,
    int64,
    /// A type this library does not know, read back from the server.
    unknown,

    pub fn wire(t: LabelType) []const u8 {
        return switch (t) {
            .string => "STRING",
            .bool => "BOOL",
            .int64 => "INT64",
            .unknown => "STRING",
        };
    }

    pub fn fromWire(name: []const u8) LabelType {
        if (std.mem.eql(u8, name, "STRING")) return .string;
        if (std.mem.eql(u8, name, "BOOL")) return .bool;
        if (std.mem.eql(u8, name, "INT64")) return .int64;
        return .unknown;
    }
};

pub const LabelDescriptor = struct {
    key: []const u8,
    value_type: LabelType = .string,
    description: []const u8 = "",
};

/// A metric descriptor to create.
pub const MetricConfig = struct {
    kind: Kind,
    value_type: ValueType,
    /// A unit in UCUM's terms, as Cloud Monitoring reads them: "By", "s",
    /// "ms", "{request}", "1". Printable ASCII without spaces; the server
    /// checks the grammar.
    unit: []const u8 = "",
    description: []const u8 = "",
    display_name: []const u8 = "",
    /// At most 30.
    labels: []const LabelDescriptor = &.{},
};

/// What wrote a series: the monitored resource each written point belongs
/// to. The resource types that take user metrics have their required labels
/// as fields, so none can be left out. `project_id` is never one: the
/// server fills it in from the request, and refuses another project.
pub const Resource = union(enum) {
    /// The whole project. Every writer in the project shares it, so two
    /// processes writing the same metric and labels here collide.
    global,
    generic_task: GenericTask,
    generic_node: GenericNode,
    gce_instance: GceInstance,
    k8s_container: K8sContainer,
    k8s_pod: K8sPod,
    k8s_node: K8sNode,
    /// Any other resource type, with its labels as given: `aws_ec2_instance`,
    /// `gae_instance`, and so on. The server says which labels it requires.
    other: Other,

    pub const GenericTask = struct {
        /// A region or zone, such as "us-central1". Production refused a
        /// location that is not one.
        location: []const u8,
        namespace: []const u8,
        job: []const u8,
        task_id: []const u8,
    };
    pub const GenericNode = struct { location: []const u8, namespace: []const u8, node_id: []const u8 };
    pub const GceInstance = struct { zone: []const u8, instance_id: []const u8 };
    pub const K8sContainer = struct { location: []const u8, cluster_name: []const u8, namespace_name: []const u8, pod_name: []const u8, container_name: []const u8 };
    pub const K8sPod = struct { location: []const u8, cluster_name: []const u8, namespace_name: []const u8, pod_name: []const u8 };
    pub const K8sNode = struct { location: []const u8, cluster_name: []const u8, node_name: []const u8 };
    pub const Other = struct { type: []const u8, labels: []const Label = &.{} };

    /// The most labels a named resource type has.
    pub const max_named_labels = 5;

    /// The resource type's name, as the API names it.
    pub fn typeName(r: Resource) []const u8 {
        return switch (r) {
            .other => |o| o.type,
            else => @tagName(r),
        };
    }

    /// The resource's labels, in the order of its fields. A named type's are
    /// written into `buf`; `.other`'s are its own.
    pub fn labels(r: *const Resource, buf: *[max_named_labels]Label) []const Label {
        switch (r.*) {
            .global => return buf[0..0],
            .other => |o| return o.labels,
            inline else => |fields| {
                const names = @typeInfo(@TypeOf(fields)).@"struct".field_names;
                inline for (names, 0..) |name, i| buf[i] = .{ .key = name, .value = @field(fields, name) };
                return buf[0..names.len];
            },
        }
    }

    /// 16 random hex digits, for a `task_id` that only has to be unique to
    /// this process. Each new id starts new series, so take one when the
    /// process starts and keep it. A process forked after taking one shares
    /// it, and must take its own.
    pub fn randomTaskId(io: std.Io) [16]u8 {
        var bytes: [8]u8 = undefined;
        io.random(&bytes);
        return std.fmt.bytesToHex(bytes, .lower);
    }
};

/// One point's value. Its tag is the series' value type.
pub const Value = union(enum) {
    bool: bool,
    int64: i64,
    /// NaN and the infinities are written as Cloud Monitoring spells them,
    /// "NaN", "Infinity" and "-Infinity", which production took.
    double: f64,
    /// At most 1,024 bytes. Not under `custom.googleapis.com/`.
    string: []const u8,
    distribution: Distribution,

    pub fn valueType(v: Value) ValueType {
        return switch (v) {
            .bool => .bool,
            .int64 => .int64,
            .double => .double,
            .string => .string,
            .distribution => .distribution,
        };
    }
};

/// A histogram: how many values fell in each bucket, with their count, mean
/// and sum of squared deviations from the mean.
pub const Distribution = struct {
    count: u64 = 0,
    mean: f64 = 0,
    sum_of_squared_deviation: f64 = 0,
    buckets: Buckets,
    /// Underflow first, then each finite bucket, then overflow. Trailing
    /// zeros may be left off, and their sum must be `count`.
    bucket_counts: []const u64 = &.{},

    /// How values map to buckets. Bucket 0 is underflow, below the first
    /// bound; bucket `num_finite + 1` is overflow.
    pub const Buckets = union(enum) {
        /// Bounds `offset + width * i` for i in 0..num_finite.
        linear: struct { num_finite: u32, width: f64, offset: f64 },
        /// Bounds `scale * growth_factor^i` for i in 0..num_finite.
        exponential: struct { num_finite: u32, growth_factor: f64, scale: f64 },
        /// Strictly increasing bounds; one fewer finite bucket than bounds.
        explicit: []const f64,

        /// Every bucket, underflow and overflow included.
        pub fn total(b: Buckets) usize {
            return switch (b) {
                .linear => |l| @as(usize, l.num_finite) + 2,
                .exponential => |e| @as(usize, e.num_finite) + 2,
                .explicit => |bounds| bounds.len + 1,
            };
        }
    };
};

/// One point of one series, to write. A series is a metric type with its
/// labels and a resource with its labels; the series' first write makes
/// it.
pub const TimeSeries = struct {
    /// A whole type, such as "custom.googleapis.com/shop/orders".
    metric_type: []const u8,
    metric_labels: []const Label = &.{},
    resource: Resource,
    kind: Kind,
    /// Sent when not empty, for the descriptor a first write creates.
    unit: []const u8 = "",
    /// A gauge's is its end: leave it null. A cumulative's is the series'
    /// start, before `end`, and the same at every write until the total
    /// starts over; a delta's is its interval's start.
    start: ?std.Io.Timestamp = null,
    end: std.Io.Timestamp,
    value: Value,
};

/// What a write came to. The server answers about each point it was sent,
/// so a write that stored some points and refused others, or refused them
/// all, is a result rather than an error.
pub const WriteResult = struct {
    /// Points sent: one per series.
    points: u32,
    /// Points the server stored.
    written: u32,
    /// Points refused, grouped by the status the server gave them.
    refused: []const Refusal = &.{},
    /// The server's message, for people: it names the first series refused
    /// and why. Empty when every point was written.
    message: []const u8 = "",

    pub const Refusal = struct {
        /// `error.InvalidArgument` for a point that broke a rule, out of
        /// order, too far ahead or back, a duplicate in the request, a value
        /// the descriptor does not take; `error.FailedPrecondition` for a
        /// point too soon after the series' last.
        reason: core.ApiError,
        points: u32,
    };

    /// Whether every point was written.
    pub fn ok(self: WriteResult) bool {
        return self.written == self.points;
    }
};

/// Which failed writes are tried again. A write can be stored, in whole or
/// in part, before it fails, so Google's own clients never retry one. When
/// measured, production kept a point sent twice once and answered 200, so
/// a retry of the same request is harmless to what was stored; a point
/// that changed meanwhile would be refused as too frequent.
pub const WriteRetries = enum {
    /// Only a failure before the request left: a refused connection, or a
    /// name lookup that failed.
    unsent_only,
    /// Also 429, 500, 503 and 504, and a timed-out or dropped connection,
    /// as Cloud Monitoring's troubleshooting page suggests. In five runs
    /// of the production suite, production once answered a write with a
    /// bare 500 where the other runs gave its summary.
    transient,
};

/// A metric descriptor, as the server holds it.
pub const MetricInfo = struct {
    type: []const u8,
    kind: Kind,
    value_type: ValueType,
    unit: []const u8 = "",
    description: []const u8 = "",
    display_name: []const u8 = "",
    labels: []const LabelDescriptor = &.{},
    /// Read only: the resource types the metric may be written to. For a
    /// user metric production listed every type that takes them, written to
    /// or not.
    resource_types: []const []const u8 = &.{},

    /// The label named `key`, or null.
    pub fn label(self: MetricInfo, key: []const u8) ?LabelDescriptor {
        for (self.labels) |l| if (std.mem.eql(u8, l.key, key)) return l;
        return null;
    }
};

pub const ListMetricsOptions = struct {
    /// Lists only the types that start with this, such as
    /// "custom.googleapis.com/shop/".
    prefix: ?[]const u8 = null,
    /// Only metrics with data written recently.
    active_only: bool = false,
    /// 0 for the server's default and most, 10,000.
    page_size: u32 = 0,
    page_token: ?[]const u8 = null,
};

pub const MetricPage = struct {
    metrics: []const MetricInfo,
    /// Null on the last page.
    next_page_token: ?[]const u8 = null,
};

/// A monitored resource type: which labels a resource of it has.
pub const ResourceTypeInfo = struct {
    type: []const u8,
    display_name: []const u8 = "",
    description: []const u8 = "",
    labels: []const LabelDescriptor = &.{},
};

pub const ListOptions = struct {
    /// 0 for the server's default.
    page_size: u32 = 0,
    page_token: ?[]const u8 = null,
};

pub const ResourceTypePage = struct {
    types: []const ResourceTypeInfo,
    /// Null on the last page.
    next_page_token: ?[]const u8 = null,
};

/// How each series' points are grouped into one per alignment period
/// before anything else, as `common.proto` names them.
pub const Aligner = enum {
    none,
    delta,
    rate,
    interpolate,
    next_older,
    min,
    max,
    mean,
    count,
    sum,
    stddev,
    count_true,
    count_false,
    fraction_true,
    percentile_99,
    percentile_95,
    percentile_50,
    percentile_05,
    percent_change,

    /// "ALIGN_" and the name in capitals.
    pub fn wire(a: Aligner) []const u8 {
        return switch (a) {
            inline else => |tag| "ALIGN_" ++ comptime upper(@tagName(tag)),
        };
    }

    /// The aligner a wire name names, or null for one this library does
    /// not know.
    pub fn fromWire(name: []const u8) ?Aligner {
        for (std.enums.values(Aligner)) |a| if (std.mem.eql(u8, name, a.wire())) return a;
        return null;
    }
};

/// How aligned series are combined into fewer, as `common.proto` names them.
pub const Reducer = enum {
    none,
    mean,
    min,
    max,
    sum,
    stddev,
    count,
    count_true,
    count_false,
    fraction_true,
    percentile_99,
    percentile_95,
    percentile_50,
    percentile_05,

    /// "REDUCE_" and the name in capitals.
    pub fn wire(r: Reducer) []const u8 {
        return switch (r) {
            inline else => |tag| "REDUCE_" ++ comptime upper(@tagName(tag)),
        };
    }

    /// The reducer a wire name names, or null for one this library does
    /// not know.
    pub fn fromWire(name: []const u8) ?Reducer {
        for (std.enums.values(Reducer)) |r| if (std.mem.eql(u8, name, r.wire())) return r;
        return null;
    }
};

fn upper(comptime name: []const u8) []const u8 {
    comptime {
        var out: [name.len]u8 = undefined;
        for (name, &out) |c, *o| o.* = std.ascii.toUpper(c);
        const final = out;
        return &final;
    }
}

/// One label's condition in a read's filter.
pub const Match = struct {
    key: []const u8,
    op: Op = .equals,
    value: []const u8,

    pub const Op = enum { equals, not_equals, starts_with, ends_with, has_substring };
};

/// Which series of the metric a read returns. Every part must hold.
pub const Filter = struct {
    metric_labels: []const Match = &.{},
    resource_type: ?[]const u8 = null,
    resource_labels: []const Match = &.{},
    /// Appended with AND as it is, for what the parts above do not say,
    /// such as `metric.labels.code = one_of("500", "503")`. In Cloud
    /// Monitoring's filters OR binds tighter than AND.
    raw: ?[]const u8 = null,
};

pub const Aggregation = struct {
    /// Seconds per aligned point; at least 10, which production held to.
    /// Required with any aligner but `none`.
    alignment_period_s: u32 = 0,
    aligner: Aligner = .none,
    /// Needs an aligner other than `none`.
    reducer: Reducer = .none,
    /// What the reducer keeps apart, such as "metric.labels.region" or
    /// "resource.labels.zone"; `resource.type` always is.
    group_by: []const []const u8 = &.{},
};

/// Whether a read returns points, or only which series there are.
pub const View = enum { full, headers };

pub const ReadOptions = struct {
    /// A read covers (start, end]. `end` defaults to now, `start` to `end`.
    start: ?std.Io.Timestamp = null,
    end: ?std.Io.Timestamp = null,
    filter: Filter = .{},
    aggregation: ?Aggregation = null,
    /// Applied after `aggregation`, which it needs.
    secondary_aggregation: ?Aggregation = null,
    view: View = .full,
    /// Points a page holds with `.full`, series with `.headers`; 0 for the
    /// server's most, 100,000. With `.full` one series can span pages.
    page_size: u32 = 0,
    page_token: ?[]const u8 = null,
};

/// One point as a read returns it.
pub const ReadPoint = struct {
    /// A gauge's is its end.
    start: ?std.Io.Timestamp = null,
    end: std.Io.Timestamp,
    /// Null for a value this library does not read, such as Google's money.
    value: ?Value,
};

/// One series as a read returns it. The resource comes back as its type and
/// labels, `project_id` among them, since a read can see any resource type.
pub const Series = struct {
    metric_type: []const u8,
    metric_labels: []const Label = &.{},
    resource_type: []const u8,
    resource_labels: []const Label = &.{},
    /// After alignment or reduction these can differ from the descriptor's.
    kind: Kind,
    value_type: ValueType,
    unit: []const u8 = "",
    /// Newest first, as the server sends them. Empty with `.headers`.
    points: []const ReadPoint = &.{},

    /// The metric label named `key`, or null.
    pub fn label(self: Series, key: []const u8) ?[]const u8 {
        for (self.metric_labels) |l| if (std.mem.eql(u8, l.key, key)) return l.value;
        return null;
    }

    /// The resource label named `key`, or null.
    pub fn resourceLabel(self: Series, key: []const u8) ?[]const u8 {
        for (self.resource_labels) |l| if (std.mem.eql(u8, l.key, key)) return l.value;
        return null;
    }
};

/// Why part of a read may be missing.
pub const ExecutionError = struct {
    reason: core.ApiError,
    message: []const u8 = "",
};

pub const SeriesPage = struct {
    series: []const Series,
    /// Null on the last page.
    next_page_token: ?[]const u8 = null,
    /// The answer may be incomplete when this or `unreachable_regions` is
    /// not empty, though it came with HTTP 200.
    execution_errors: []const ExecutionError = &.{},
    unreachable_regions: []const []const u8 = &.{},
    /// The series' unit, or "{not_a_unit}" when they differ.
    unit: []const u8 = "",

    /// Whether the server said part of the answer may be missing.
    pub fn incomplete(self: SeriesPage) bool {
        return self.execution_errors.len > 0 or self.unreachable_regions.len > 0;
    }
};

// Alerts (issue #246): the violations of alert policies, read only. The
// API itself cannot make, change or close one.

/// Whether an alert is still firing.
pub const AlertState = enum {
    /// The proto's default, never seen in an answer when measured.
    unspecified,
    open,
    closed,
    /// A state this library does not know, read back from the server.
    unknown,

    pub fn fromWire(name: []const u8) AlertState {
        if (std.mem.eql(u8, name, "OPEN")) return .open;
        if (std.mem.eql(u8, name, "CLOSED")) return .closed;
        if (std.mem.eql(u8, name, "STATE_UNSPECIFIED")) return .unspecified;
        return .unknown;
    }
};

/// An alert policy's severity, as its snapshot carries it.
pub const Severity = enum {
    /// The default: the policy set none.
    unspecified,
    critical,
    @"error",
    warning,
    /// A severity this library does not know, read back from the server.
    unknown,

    pub fn fromWire(name: []const u8) Severity {
        if (std.mem.eql(u8, name, "CRITICAL")) return .critical;
        if (std.mem.eql(u8, name, "ERROR")) return .@"error";
        if (std.mem.eql(u8, name, "WARNING")) return .warning;
        if (std.mem.eql(u8, name, "SEVERITY_UNSPECIFIED")) return .unspecified;
        return .unknown;
    }
};

/// The state of the alert's policy at the time the alert was generated.
pub const PolicySnapshot = struct {
    /// `projects/P/alertPolicies/ID`.
    name: []const u8 = "",
    display_name: []const u8 = "",
    severity: Severity = .unspecified,
    user_labels: []const Label = &.{},

    /// The user label named `key`, or null.
    pub fn userLabel(self: PolicySnapshot, key: []const u8) ?[]const u8 {
        for (self.user_labels) |l| if (std.mem.eql(u8, l.key, key)) return l.value;
        return null;
    }
};

/// A violation of an alert policy, as the server holds it: only Cloud
/// Monitoring itself opens and closes one.
pub const Alert = struct {
    /// `projects/P/alerts/ID`, the id system-assigned.
    name: []const u8,
    /// The trailing segment of `name`, for display.
    id: []const u8,
    state: AlertState = .unknown,
    open_time: std.Io.Timestamp,
    /// Null while the alert is open.
    close_time: ?std.Io.Timestamp = null,
    policy: PolicySnapshot = .{},
    /// The metric and resource preserved from the condition that fired;
    /// empty when the answer named none.
    metric_type: []const u8 = "",
    metric_labels: []const Label = &.{},
    resource_type: []const u8 = "",
    resource_labels: []const Label = &.{},
    /// The monitored resource metadata's user labels.
    metadata_user_labels: []const Label = &.{},
    /// The metadata's system labels as they came: Google defines the
    /// values as strings, booleans or lists of strings, so they stay
    /// JSON. `.null` when the answer had none.
    system_labels: std.json.Value = .null,
    /// The labels a log-based alert extracted; empty otherwise.
    log_labels: []const Label = &.{},

    /// The metric label named `key`, or null.
    pub fn metricLabel(self: Alert, key: []const u8) ?[]const u8 {
        for (self.metric_labels) |l| if (std.mem.eql(u8, l.key, key)) return l.value;
        return null;
    }

    /// The resource label named `key`, or null.
    pub fn resourceLabel(self: Alert, key: []const u8) ?[]const u8 {
        for (self.resource_labels) |l| if (std.mem.eql(u8, l.key, key)) return l.value;
        return null;
    }
};

/// How a list of alerts orders its pages. The direction always goes on
/// the wire: production sorts a bare field name descending, despite its
/// documentation's "the default sort direction is ascending", and takes
/// an `asc` keyword the documentation does not mention (measured
/// 2026-10-19).
pub const AlertOrder = enum {
    open_time,
    open_time_desc,
    close_time,
    close_time_desc,

    pub fn wire(o: AlertOrder) []const u8 {
        return switch (o) {
            .open_time => "open_time asc",
            .open_time_desc => "open_time desc",
            .close_time => "close_time asc",
            .close_time_desc => "close_time desc",
        };
    }
};

pub const ListAlertsOptions = struct {
    /// Only the alerts still firing: sends `state="OPEN"`, the filter
    /// production honors (measured 2026-10-19). Not beside `filter`,
    /// which says what it wants itself.
    open_only: bool = false,
    /// Sent as `filter`, as written. Production parses it as the
    /// structured filter language, despite the discovery document's
    /// "match on any fields" wording: `state="OPEN"`,
    /// `severity="WARNING"` and `policy.display_name="x"` each matched,
    /// and a bare word was 400 "Restriction must have a left-hand side
    /// and a right-hand side". Null lists them all.
    filter: ?[]const u8 = null,
    /// Null sends nothing: production sorts by open_time, newest first.
    order_by: ?AlertOrder = null,
    /// 0 for the server's default of 50; production caps a page at 1,000.
    page_size: u32 = 0,
    page_token: ?[]const u8 = null,
};

pub const AlertPage = struct {
    alerts: []const Alert,
    /// Null on the last page.
    next_page_token: ?[]const u8 = null,
    /// The server's estimate of every match, when it sends one.
    total_size: ?i64 = null,
};

/// What a condition tests, by the one kind field it carries.
pub const ConditionKind = enum {
    /// `conditionThreshold`: series compared against a value.
    threshold,
    /// `conditionAbsent`: series that stopped reporting.
    absence,
    /// `conditionMatchedLog`: a log entry that matched a filter.
    log_match,
    /// `conditionMonitoringQueryLanguage`.
    mql,
    /// `conditionPrometheusQueryLanguage`.
    promql,
    /// `conditionSql`: GoogleSQL over logs.
    sql,
    /// A kind this library does not know; `Condition.raw` has it.
    unknown,
};

pub const Comparison = enum {
    unspecified,
    gt,
    ge,
    lt,
    le,
    eq,
    ne,
    unknown,

    pub fn fromWire(name: []const u8) Comparison {
        const map = std.StaticStringMap(Comparison).initComptime(.{
            .{ "COMPARISON_UNSPECIFIED", .unspecified },
            .{ "COMPARISON_GT", .gt },
            .{ "COMPARISON_GE", .ge },
            .{ "COMPARISON_LT", .lt },
            .{ "COMPARISON_LE", .le },
            .{ "COMPARISON_EQ", .eq },
            .{ "COMPARISON_NE", .ne },
        });
        return map.get(name) orelse .unknown;
    }
};

/// How many series must fail a condition's test for it to fire; Google
/// treats none as a count of 1.
pub const Trigger = struct {
    count: ?i64 = null,
    percent: ?f64 = null,
};

/// One test of an alert policy. The fields a console shows are decoded;
/// `raw` holds the whole condition as production sent it, for the rest
/// (denominators, forecasts, PromQL labels and rule names, SQL schedules
/// and tests) and for kinds Google adds later.
pub const Condition = struct {
    /// `projects/P/alertPolicies/A/conditions/C`.
    name: []const u8 = "",
    display_name: []const u8 = "",
    kind: ConditionKind = .unknown,
    /// The metric filter (threshold, absence) or the log filter (log
    /// match); empty for the query kinds.
    filter: []const u8 = "",
    /// The query (MQL, PromQL, SQL); empty for the filter kinds.
    query: []const u8 = "",
    /// Threshold conditions only.
    comparison: Comparison = .unspecified,
    threshold_value: ?f64 = null,
    /// How long the test must hold before the condition fires, in
    /// seconds; null when production sent none.
    duration_s: ?f64 = null,
    /// Threshold and absence conditions. Empty when the condition names an
    /// aligner or reducer this library does not know: `raw` has it.
    aggregations: []const Aggregation = &.{},
    trigger: ?Trigger = null,
    /// The condition object as production sent it, as JSON text.
    raw: []const u8 = "",
};

/// How an alert policy combines its conditions.
pub const Combiner = enum {
    unspecified,
    @"and",
    @"or",
    /// Every condition, on the same resource.
    and_with_matching_resource,
    unknown,

    pub fn fromWire(name: []const u8) Combiner {
        const map = std.StaticStringMap(Combiner).initComptime(.{
            .{ "COMBINE_UNSPECIFIED", .unspecified },
            .{ "AND", .@"and" },
            .{ "OR", .@"or" },
            .{ "AND_WITH_MATCHING_RESOURCE", .and_with_matching_resource },
        });
        return map.get(name) orelse .unknown;
    }
};

/// What a policy's notifications and incidents carry.
pub const Documentation = struct {
    content: []const u8 = "",
    /// `text/markdown` or `text/plain`.
    mime_type: []const u8 = "",
    /// The notification's subject line.
    subject: []const u8 = "",
};

/// Who changed a policy, and when.
pub const MutationRecord = struct {
    time: ?std.Io.Timestamp = null,
    /// An email, or a service account's.
    by: []const u8 = "",
};

/// An alert policy: when Cloud Monitoring opens alerts, and what it tells
/// people when it does.
pub const AlertPolicy = struct {
    /// `projects/P/alertPolicies/ID`, the id system-assigned.
    name: []const u8,
    /// The trailing segment of `name`.
    id: []const u8,
    display_name: []const u8 = "",
    /// A disabled policy opens no alerts.
    enabled: bool = true,
    severity: Severity = .unspecified,
    combiner: Combiner = .unspecified,
    documentation: Documentation = .{},
    user_labels: []const Label = &.{},
    /// Full names, `projects/P/notificationChannels/ID`.
    notification_channels: []const []const u8 = &.{},
    conditions: []const Condition = &.{},
    created: MutationRecord = .{},
    /// The latest change. Production moves it on every patch, a disable
    /// of a disabled policy included (measured 2026-10-20).
    mutated: MutationRecord = .{},
    /// Set only when production holds the policy invalid: it opens nothing
    /// until fixed.
    invalid: ?Invalid = null,

    pub const Invalid = struct { code: i64, message: []const u8 };

    /// The user label named `key`, or null.
    pub fn userLabel(self: AlertPolicy, key: []const u8) ?[]const u8 {
        for (self.user_labels) |l| if (std.mem.eql(u8, l.key, key)) return l.value;
        return null;
    }
};

pub const ListAlertPoliciesOptions = struct {
    /// Sent as `filter`, as written, in the sorting-and-filtering
    /// language over `name`, `display_name`, `documentation.content`,
    /// `documentation.mime_type`, `user_labels`, `conditions.size`,
    /// `combiner`, `enabled` and `notification_channels`; production
    /// refuses any other field, `severity` included, and a bare word
    /// (measured 2026-10-20). Null lists them all.
    filter: ?[]const u8 = null,
    /// Sent as `orderBy`, as written: field paths from the same list,
    /// comma-separated, `-` before one for descending (production refuses
    /// a trailing `desc`). Null: production orders by name.
    order_by: ?[]const u8 = null,
    /// 0 for the server's default, which answered every policy measured.
    page_size: u32 = 0,
    page_token: ?[]const u8 = null,
};

pub const AlertPolicyPage = struct {
    policies: []const AlertPolicy,
    /// Null on the last page.
    next_page_token: ?[]const u8 = null,
    /// The count of every match, which production sends on every page.
    total_size: ?i64 = null,
};

/// Where a snooze stands at a given time.
pub const SnoozeState = enum {
    /// Its start is still to come.
    upcoming,
    /// Its policies open no alerts, and the ones open were closed.
    active,
    /// Its end has passed, or it was cancelled (an end equal to its
    /// start). Production refuses any change to it.
    ended,
};

/// A snooze: alerts of the policies it names are closed when it starts
/// and none open while it holds (measured 2026-10-20: the open alert
/// closed within a second of the start). It cannot be deleted, and its
/// policies and filter cannot change.
pub const Snooze = struct {
    /// `projects/P/snoozes/ID`, the id system-assigned.
    name: []const u8,
    /// The trailing segment of `name`.
    id: []const u8,
    display_name: []const u8 = "",
    /// Full names, `projects/P/alertPolicies/ID`. Production does not
    /// check that they exist.
    policies: []const []const u8 = &.{},
    /// Resource labels joined by AND, narrowing it to some of one
    /// policy's alerts; empty for all of them.
    filter: []const u8 = "",
    /// Production keeps whole seconds.
    start: std.Io.Timestamp,
    end: std.Io.Timestamp,

    /// Upcoming before its start, active from its start until its end,
    /// ended from its end on. A cancelled snooze, start equal to end, is
    /// ended.
    pub fn stateAt(self: Snooze, now: std.Io.Timestamp) SnoozeState {
        if (self.cancelled() or self.end.nanoseconds <= now.nanoseconds) return .ended;
        if (now.nanoseconds < self.start.nanoseconds) return .upcoming;
        return .active;
    }

    /// Whether it was cancelled: an interval of no length, which is what
    /// cancelling one leaves.
    pub fn cancelled(self: Snooze) bool {
        return self.start.nanoseconds == self.end.nanoseconds;
    }
};

/// A snooze to make, checked as production checks one.
pub const NewSnooze = struct {
    /// Required, at most 512 characters.
    display_name: []const u8,
    /// 1 to 16, each an id or this project's full
    /// `projects/P/alertPolicies/ID` name.
    policies: []const []const u8,
    /// Resource labels joined by AND, such as
    /// `resource.labels.zone="us-central1-a"`; only with exactly one
    /// policy.
    filter: ?[]const u8 = null,
    /// Not in the past (production allows 15 s of skew). Sent in whole
    /// seconds, production's resolution.
    start: std.Io.Timestamp,
    /// At least a minute after `start`.
    end: std.Io.Timestamp,
};

pub const ListSnoozesOptions = struct {
    /// The snoozes holding at this time: sends `interval.start_time <=
    /// "T" AND interval.end_time >= "T"`, the filter production answers
    /// that question with. Not beside `filter`.
    active_at: ?std.Io.Timestamp = null,
    /// Sent as written. Production takes only `interval.start_time` and
    /// `interval.end_time`, compared with `=`, `>=` or `<=` to a quoted
    /// RFC 3339 time, joined by AND (measured 2026-10-20: `>`, `<`, `OR`
    /// and any other field refused).
    filter: ?[]const u8 = null,
    /// 0 for the server's default.
    page_size: u32 = 0,
    page_token: ?[]const u8 = null,
};

pub const SnoozePage = struct {
    /// Newest start first, as production orders them.
    snoozes: []const Snooze,
    /// Null on the last page.
    next_page_token: ?[]const u8 = null,
};

const testing = std.testing;

test "Alert: states, severities and orders on the wire, and the label helpers" {
    try testing.expectEqual(AlertState.open, AlertState.fromWire("OPEN"));
    try testing.expectEqual(AlertState.closed, AlertState.fromWire("CLOSED"));
    try testing.expectEqual(AlertState.unspecified, AlertState.fromWire("STATE_UNSPECIFIED"));
    try testing.expectEqual(AlertState.unknown, AlertState.fromWire("SNOOZED"));
    try testing.expectEqual(Severity.critical, Severity.fromWire("CRITICAL"));
    try testing.expectEqual(Severity.@"error", Severity.fromWire("ERROR"));
    try testing.expectEqual(Severity.warning, Severity.fromWire("WARNING"));
    try testing.expectEqual(Severity.unspecified, Severity.fromWire("SEVERITY_UNSPECIFIED"));
    try testing.expectEqual(Severity.unknown, Severity.fromWire("FATAL"));
    try testing.expectEqualStrings("open_time asc", AlertOrder.open_time.wire());
    try testing.expectEqualStrings("close_time asc", AlertOrder.close_time.wire());
    try testing.expectEqualStrings("close_time desc", AlertOrder.close_time_desc.wire());
    const alert: Alert = .{
        .name = "projects/p/alerts/9",
        .id = "9",
        .open_time = .{ .nanoseconds = 0 },
        .metric_labels = &.{.{ .key = "k", .value = "v" }},
        .resource_labels = &.{.{ .key = "r", .value = "w" }},
        .policy = .{ .user_labels = &.{.{ .key = "team", .value = "ingest" }} },
    };
    try testing.expectEqualStrings("v", alert.metricLabel("k").?);
    try testing.expectEqual(null, alert.metricLabel("r"));
    try testing.expectEqualStrings("w", alert.resourceLabel("r").?);
    try testing.expectEqual(null, alert.resourceLabel("k"));
    try testing.expectEqualStrings("ingest", alert.policy.userLabel("team").?);
    try testing.expectEqual(null, alert.policy.userLabel("x"));
}

test "Snooze.stateAt and cancelled: production's interval, its end the turn to ended" {
    const s: Snooze = .{ .name = "projects/p/snoozes/1", .id = "1", .start = .{ .nanoseconds = 100 * std.time.ns_per_s }, .end = .{ .nanoseconds = 200 * std.time.ns_per_s } };
    try testing.expectEqual(SnoozeState.upcoming, s.stateAt(.{ .nanoseconds = 99 * std.time.ns_per_s }));
    try testing.expectEqual(SnoozeState.active, s.stateAt(.{ .nanoseconds = 100 * std.time.ns_per_s }));
    try testing.expectEqual(SnoozeState.active, s.stateAt(.{ .nanoseconds = 199 * std.time.ns_per_s }));
    try testing.expectEqual(SnoozeState.ended, s.stateAt(.{ .nanoseconds = 200 * std.time.ns_per_s }));
    try testing.expect(!s.cancelled());
    const c: Snooze = .{ .name = "projects/p/snoozes/2", .id = "2", .start = s.start, .end = s.start };
    try testing.expect(c.cancelled());
    try testing.expectEqual(SnoozeState.ended, c.stateAt(.{ .nanoseconds = 50 * std.time.ns_per_s }));
}

test "Aligner, Reducer, Comparison and Combiner: wire names both ways, the unknown kept apart" {
    for (std.enums.values(Aligner)) |a| try testing.expectEqual(a, Aligner.fromWire(a.wire()).?);
    for (std.enums.values(Reducer)) |r| try testing.expectEqual(r, Reducer.fromWire(r.wire()).?);
    try testing.expectEqual(null, Aligner.fromWire("ALIGN_SOMETHING_NEW"));
    try testing.expectEqual(null, Reducer.fromWire("max"));
    try testing.expectEqual(Comparison.gt, Comparison.fromWire("COMPARISON_GT"));
    try testing.expectEqual(Comparison.unknown, Comparison.fromWire("COMPARISON_BETWEEN"));
    try testing.expectEqual(Combiner.and_with_matching_resource, Combiner.fromWire("AND_WITH_MATCHING_RESOURCE"));
    try testing.expectEqual(Combiner.unknown, Combiner.fromWire("XOR"));
}

test "Aligner and Reducer: the proto's names" {
    try testing.expectEqualStrings("ALIGN_NONE", Aligner.none.wire());
    try testing.expectEqualStrings("ALIGN_NEXT_OLDER", Aligner.next_older.wire());
    try testing.expectEqualStrings("ALIGN_PERCENTILE_05", Aligner.percentile_05.wire());
    try testing.expectEqualStrings("ALIGN_PERCENT_CHANGE", Aligner.percent_change.wire());
    try testing.expectEqualStrings("REDUCE_FRACTION_TRUE", Reducer.fraction_true.wire());
    try testing.expectEqualStrings("REDUCE_SUM", Reducer.sum.wire());
}

test "Series.label, resourceLabel and SeriesPage.incomplete" {
    const s: Series = .{ .metric_type = "t", .metric_labels = &.{.{ .key = "a", .value = "1" }}, .resource_type = "global", .resource_labels = &.{.{ .key = "project_id", .value = "p" }}, .kind = .gauge, .value_type = .int64 };
    try testing.expectEqualStrings("1", s.label("a").?);
    try testing.expectEqual(null, s.label("b"));
    try testing.expectEqualStrings("p", s.resourceLabel("project_id").?);
    try testing.expectEqual(null, s.resourceLabel("zone"));
    try testing.expect(!(SeriesPage{ .series = &.{} }).incomplete());
    try testing.expect((SeriesPage{ .series = &.{}, .unreachable_regions = &.{"asia"} }).incomplete());
    try testing.expect((SeriesPage{ .series = &.{}, .execution_errors = &.{.{ .reason = error.Unavailable }} }).incomplete());
}

test "Kind and ValueType: wire names both ways, unknown for the rest" {
    inline for (.{ .gauge, .delta, .cumulative }) |k| try testing.expectEqual(k, Kind.fromWire(Kind.wire(k)));
    try testing.expectEqual(Kind.unknown, Kind.fromWire("METRIC_KIND_UNSPECIFIED"));
    try testing.expectEqual(Kind.unknown, Kind.fromWire("gauge"));
    inline for (.{ .bool, .int64, .double, .string, .distribution, .money }) |t| try testing.expectEqual(t, ValueType.fromWire(ValueType.wire(t)));
    try testing.expectEqual(ValueType.unknown, ValueType.fromWire("INT32"));
    inline for (.{ .string, .bool, .int64 }) |t| try testing.expectEqual(t, LabelType.fromWire(LabelType.wire(t)));
    try testing.expectEqual(LabelType.unknown, LabelType.fromWire("DOUBLE"));
}

test "Resource: type names and labels in field order" {
    var buf: [Resource.max_named_labels]Label = undefined;
    const task: Resource = .{ .generic_task = .{ .location = "us-central1", .namespace = "shop", .job = "api", .task_id = "7" } };
    try testing.expectEqualStrings("generic_task", task.typeName());
    const got = task.labels(&buf);
    try testing.expectEqual(4, got.len);
    try testing.expectEqualStrings("location", got[0].key);
    try testing.expectEqualStrings("us-central1", got[0].value);
    try testing.expectEqualStrings("task_id", got[3].key);
    const global: Resource = .global;
    try testing.expectEqualStrings("global", global.typeName());
    try testing.expectEqual(0, global.labels(&buf).len);
    const container: Resource = .{ .k8s_container = .{ .location = "l", .cluster_name = "c", .namespace_name = "n", .pod_name = "p", .container_name = "x" } };
    try testing.expectEqual(5, container.labels(&buf).len);
    const other: Resource = .{ .other = .{ .type = "aws_ec2_instance", .labels = &.{.{ .key = "region", .value = "aws:us-east-1" }} } };
    try testing.expectEqualStrings("aws_ec2_instance", other.typeName());
    try testing.expectEqualStrings("aws:us-east-1", other.labels(&buf)[0].value);
}

test "Resource.randomTaskId: 16 lowercase hex digits, a new one each time" {
    const a = Resource.randomTaskId(std.testing.io);
    const b = Resource.randomTaskId(std.testing.io);
    for (a) |c| try testing.expect(std.ascii.isDigit(c) or (c >= 'a' and c <= 'f'));
    try testing.expect(!std.mem.eql(u8, &a, &b));
}

test "Distribution.Buckets.total counts underflow and overflow" {
    try testing.expectEqual(5, (Distribution.Buckets{ .linear = .{ .num_finite = 3, .width = 1, .offset = 0 } }).total());
    try testing.expectEqual(2, (Distribution.Buckets{ .exponential = .{ .num_finite = 0, .growth_factor = 2, .scale = 1 } }).total());
    try testing.expectEqual(4, (Distribution.Buckets{ .explicit = &.{ 1, 2, 3 } }).total());
}

test "WriteResult.ok and MetricInfo.label" {
    try testing.expect((WriteResult{ .points = 2, .written = 2 }).ok());
    try testing.expect(!(WriteResult{ .points = 2, .written = 1 }).ok());
    const info: MetricInfo = .{ .type = "t", .kind = .gauge, .value_type = .int64, .labels = &.{.{ .key = "region" }} };
    try testing.expectEqual(LabelType.string, info.label("region").?.value_type);
    try testing.expectEqual(null, info.label("zone"));
}
