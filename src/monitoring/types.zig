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

/// Which failed writes are tried again. A write can be stored in part
/// before it fails, and a stored point sent again is refused as out of
/// order or too frequent, so Google's own clients never retry one.
pub const WriteRetries = enum {
    /// Only a failure before the request left: a refused connection, or a
    /// name lookup that failed.
    unsent_only,
    /// Also 429, 500, 503 and 504, and a timed-out or dropped connection,
    /// as Cloud Monitoring's troubleshooting page suggests. A point already
    /// stored then comes back in the result as refused.
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

const testing = std.testing;

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
