//! A periodic writer: counters, gauges and histograms that any task records
//! into, and observers read at each write, written to Cloud Monitoring
//! every interval from a task of its own.
//!
//! It keeps the rules production enforces on writers, which is where every
//! Google exporter has had its trouble: a series is written at most every
//! 5 seconds (production refused under 2.5 s, Google documents 5), a
//! cumulative series keeps its start time until its total starts over, a
//! request holds no series twice and at most 200, and the last write at
//! shutdown does not land too soon after the one before.
//!
//! ```zig
//! var recorder = try monitoring.Recorder.init(gpa, io, .{
//!     .client = .{ .project_id = "my-project", .token_provider = creds.provider() },
//!     .resource = .{ .generic_task = .{ .location = "us-central1", .namespace = "shop", .job = "api", .task_id = &task_id } },
//! });
//! defer recorder.deinit();
//! var running = try io.concurrent(monitoring.Recorder.run, .{&recorder});
//! defer {
//!     recorder.stop();
//!     running.await(io) catch {};
//! }
//! const orders = try recorder.counter(.{ .name = "shop/orders", .label_keys = &.{"region"}, .unit = "{order}" });
//! orders.add(&.{"eu"}, 1); // from any task
//! ```
//!
//! Recording never fails and never waits on the network: a recording that
//! cannot be kept (the series cap reached, memory short, the wrong number
//! of label values) is dropped, counted in `Stats.recordings_dropped`, and
//! logged once per instrument. A recorder must not be moved after `init`.

const Recorder = @This();

const std = @import("std");
const Allocator = std.mem.Allocator;
const core = @import("core");

const Client = @import("Client.zig");
const errors = @import("errors.zig");
const logging = @import("logging.zig");
const types = @import("types.zig");
const validate = @import("validate.zig");
const Error = errors.Error;
const Diagnostics = core.Diagnostics;

gpa: Allocator,
io: std.Io,
client: Client,
resource: types.Resource,
/// Owned copies of the resource's labels and `.other` type, and of the
/// prefix.
owned: std.heap.ArenaAllocator,
prefix: []const u8,
interval_ns: i96,
descriptors: Descriptors,
max_series: u32,
last_write: LastWrite,
diagnostics: ?*Diagnostics,

mutex: std.Io.Mutex = .init,
/// Set by `stop`; wakes `run`.
wake: std.Io.Event = .unset,
stopping: bool = false,
ran: bool = false,
instruments: std.ArrayList(*Instrument) = .empty,
series: std.HashMapUnmanaged(SeriesKey, *Series, KeyContext, std.hash_map.default_max_load_percentage) = .empty,
/// Series data, which lives as long as the recorder.
store: std.heap.ArenaAllocator,
counts: Stats = .{},

/// The fewest nanoseconds between two points of one series this recorder
/// writes: the 5 s Google documents. Production refused under 2.5 s.
pub const floor_ns: i96 = 5 * std.time.ns_per_s;

pub const Options = struct {
    /// The client every write goes through. Its `write_retries` holds.
    client: Client.Options,
    /// Who is writing: every series of this recorder carries it. Give each
    /// process its own, such as a `generic_task` with a `task_id` of its
    /// own (`Resource.randomTaskId`): two writers of one series collide.
    resource: types.Resource,
    /// Put before every instrument's name. `custom.googleapis.com/` takes
    /// typed labels and is what Google teaches for a program's own metrics.
    prefix: []const u8 = validate.custom_domain,
    /// How often everything is written: at least 5 s, the floor Google
    /// documents per series. 60 s, OpenTelemetry's default, keeps about 450
    /// series inside the free 150 MiB a month.
    interval_ms: u32 = 60_000,
    descriptors: Descriptors = .create_if_missing,
    /// Series across every instrument; recordings past it are dropped and
    /// counted.
    max_series: u32 = 10_000,
    /// At `stop`, what becomes of a series written less than 5 s before.
    last_write: LastWrite = .wait,
};

/// How a recorder makes sure its instruments' descriptors say what they
/// are.
pub const Descriptors = enum {
    /// Reads each instrument's descriptor before its first write, and
    /// creates it when missing, once per instrument, so its unit,
    /// description and labels reach the console. A descriptor of another
    /// kind or value type stops the instrument's series, since the server
    /// would refuse every point; a refused create is not asked again, and
    /// the first write creates the descriptor instead.
    create_if_missing,
    /// Never calls the descriptor API: the first write creates each
    /// descriptor, with string labels and no unit or description.
    auto,
};

pub const LastWrite = enum {
    /// Waits out the rest of 5 s, at most, so a series written just before
    /// keeps its last totals. It fits Cloud Run's 10 s after SIGTERM.
    wait,
    /// Leaves such a series out of the last write.
    skip,
};

/// What an instrument is called and how its points read.
pub const InstrumentSpec = struct {
    /// Short name, such as "shop/orders"; the prefix is put before it.
    name: []const u8,
    /// At most 30. Recordings name their values in this order.
    label_keys: []const []const u8 = &.{},
    unit: []const u8 = "",
    description: []const u8 = "",
};

pub const GaugeType = enum { int64, double, bool };
pub const GaugeValue = union(GaugeType) { int64: i64, double: f64, bool: bool };

/// A running total: cumulative int64, from the first recording of each
/// label set.
pub const Counter = struct {
    recorder: *Recorder,
    index: u32,

    /// Adds `n` to the total of the series `label_values` name, in the
    /// order of the instrument's `label_keys`. Never fails or waits.
    pub fn add(self: Counter, label_values: []const []const u8, n: u64) void {
        self.recorder.record(self.index, label_values, .{ .add = n });
    }
};

/// A value now: the last one set is written at every write.
pub const Gauge = struct {
    recorder: *Recorder,
    index: u32,

    pub fn set(self: Gauge, label_values: []const []const u8, value: GaugeValue) void {
        self.recorder.record(self.index, label_values, .{ .set = value });
    }
};

/// A distribution of values: cumulative, in the instrument's buckets, with
/// the exact count, mean and sum of squared deviations.
pub const Histogram = struct {
    recorder: *Recorder,
    index: u32,

    /// Records `value`. NaN and the infinities are dropped and counted.
    pub fn record(self: Histogram, label_values: []const []const u8, value: f64) void {
        self.recorder.record(self.index, label_values, .{ .sample = value });
    }
};

/// A callback read at each write, for values another part of the program
/// already keeps, such as a `pubsub.Subscriber`'s `stats()`. It is called
/// on `run`'s task, outside the recorder's lock, and reports through
/// `Report`.
pub const Observer = struct {
    context: *anyopaque,
    report: *const fn (context: *anyopaque, into: *Report) void,
};

/// What an observer reports through: one call per label set. An observer
/// reports int64s or doubles, not both.
pub const Report = struct {
    arena: Allocator,
    items: std.ArrayList(Item) = .empty,
    failed: bool = false,

    const Item = struct { values: []const []const u8, value: GaugeValue };

    pub fn int64(self: *Report, label_values: []const []const u8, value: i64) void {
        self.add(label_values, .{ .int64 = value });
    }

    pub fn double(self: *Report, label_values: []const []const u8, value: f64) void {
        self.add(label_values, .{ .double = value });
    }

    fn add(self: *Report, label_values: []const []const u8, value: GaugeValue) void {
        const copy = self.arena.alloc([]const u8, label_values.len) catch return self.fail();
        for (label_values, copy) |v, *c| c.* = self.arena.dupe(u8, v) catch return self.fail();
        self.items.append(self.arena, .{ .values = copy, .value = value }) catch return self.fail();
    }

    fn fail(self: *Report) void {
        self.failed = true;
    }
};

/// Counters since `init`, for a consistent picture at one moment.
pub const Stats = struct {
    /// Points the server said it stored.
    points_written: u64 = 0,
    /// Points the server refused, saying why in its summary: with one
    /// writer per series, none should be.
    points_refused: u64 = 0,
    /// Points in requests that failed as a whole; the next write carries
    /// their totals.
    points_failed: u64 = 0,
    requests: u64 = 0,
    /// Requests that failed as a whole: the network, credentials, a
    /// refusal of the request.
    requests_failed: u64 = 0,
    /// Recordings that could not be kept: past `max_series`, the wrong
    /// number of label values, a value that is not a number, short memory.
    recordings_dropped: u64 = 0,
    series: u32 = 0,
    descriptors_created: u32 = 0,
    /// Instruments whose descriptor could not be made to fit: another kind
    /// or value type, or a create refused.
    descriptor_failures: u32 = 0,
};

const Kind = enum { counter, gauge, histogram, observer };

const DescriptorState = enum { unknown, ready, gave_up, mismatch };

const Instrument = struct {
    kind: Kind,
    /// The whole metric type.
    type: []const u8,
    label_keys: []const []const u8,
    unit: []const u8,
    description: []const u8,
    metric_kind: types.Kind,
    value_type: ?types.ValueType,
    buckets: ?types.Distribution.Buckets = null,
    observer: ?Observer = null,
    /// An observer's start for its cumulative series; null for when
    /// `observe` was called.
    observer_start_ns: i96 = 0,
    descriptor: DescriptorState = .unknown,
    /// Whether a dropped recording was logged already.
    logged_drop: bool = false,
};

const Series = struct {
    instrument: u32,
    /// Owned.
    values: []const []const u8,
    /// Cumulative series: the first recording's time, in ms.
    start_ns: i96,
    /// The end time of its last point written, or null.
    last_end_ns: ?i96 = null,
    state: State,

    const State = union(enum) {
        total: u64,
        double_total: f64,
        gauge: ?GaugeValue,
        histogram: Hist,
    };
};

const Hist = struct {
    count: u64 = 0,
    mean: f64 = 0,
    m2: f64 = 0,
    /// Underflow, each finite bucket, overflow.
    counts: []u64,
};

const SeriesKey = struct { instrument: u32, values: []const []const u8 };

const KeyContext = struct {
    pub fn hash(_: KeyContext, k: SeriesKey) u64 {
        return hashKey(k);
    }
    pub fn eql(_: KeyContext, a: SeriesKey, b: SeriesKey) bool {
        return keysEqual(a, b);
    }
};

fn hashKey(k: SeriesKey) u64 {
    var h: std.hash.Wyhash = .init(0);
    h.update(std.mem.asBytes(&k.instrument));
    for (k.values) |v| {
        h.update(std.mem.asBytes(&v.len));
        h.update(v);
    }
    return h.final();
}

fn keysEqual(a: SeriesKey, b: SeriesKey) bool {
    if (a.instrument != b.instrument or a.values.len != b.values.len) return false;
    for (a.values, b.values) |x, y| if (!std.mem.eql(u8, x, y)) return false;
    return true;
}

pub fn init(gpa: Allocator, io: std.Io, options: Options) Error!Recorder {
    const diag = options.client.diagnostics;
    if (options.interval_ms < floor_ns / std.time.ns_per_ms) {
        if (diag) |d| d.print("invalid interval: at least 5000 ms, the floor Google documents per series", .{});
        return error.InvalidOptions;
    }
    if (validate.prefixProblem(options.prefix)) |reason| {
        if (diag) |d| d.print("invalid prefix: {s}", .{reason});
        return error.InvalidMetricType;
    }
    if (validate.resourceProblem(options.resource)) |reason| {
        if (diag) |d| d.print("invalid resource: {s}", .{reason});
        return error.InvalidResource;
    }
    if (options.max_series == 0) {
        if (diag) |d| d.print("invalid max_series: 0 would drop every recording", .{});
        return error.InvalidOptions;
    }
    var owned: std.heap.ArenaAllocator = .init(gpa);
    errdefer owned.deinit();
    const a = owned.allocator();
    const prefix = try a.dupe(u8, options.prefix);
    const resource = try copyResource(a, options.resource);
    var client = try Client.init(gpa, io, options.client);
    errdefer client.deinit();
    return .{
        .gpa = gpa,
        .io = io,
        .client = client,
        .resource = resource,
        .owned = owned,
        .prefix = prefix,
        .interval_ns = @as(i96, options.interval_ms) * std.time.ns_per_ms,
        .descriptors = options.descriptors,
        .max_series = options.max_series,
        .last_write = options.last_write,
        .diagnostics = diag,
        .store = .init(gpa),
    };
}

pub fn deinit(self: *Recorder) void {
    self.series.deinit(self.gpa);
    self.instruments.deinit(self.gpa);
    self.store.deinit();
    self.client.deinit();
    self.owned.deinit();
    self.* = undefined;
}

fn copyResource(a: Allocator, r: types.Resource) Allocator.Error!types.Resource {
    switch (r) {
        .global => return .global,
        .other => |o| {
            const labels = try a.alloc(types.Label, o.labels.len);
            for (o.labels, labels) |l, *c| c.* = .{ .key = try a.dupe(u8, l.key), .value = try a.dupe(u8, l.value) };
            return .{ .other = .{ .type = try a.dupe(u8, o.type), .labels = labels } };
        },
        inline else => |fields, tag| {
            var copy = fields;
            inline for (@typeInfo(@TypeOf(fields)).@"struct".field_names) |name| @field(copy, name) = try a.dupe(u8, @field(fields, name));
            return @unionInit(types.Resource, @tagName(tag), copy);
        },
    }
}

// Declaring instruments.

pub fn counter(self: *Recorder, spec: InstrumentSpec) Error!Counter {
    return .{ .recorder = self, .index = try self.declare(spec, .counter, .cumulative, .int64, null, null) };
}

pub fn gauge(self: *Recorder, spec: InstrumentSpec, value_type: GaugeType) Error!Gauge {
    const vt: types.ValueType = switch (value_type) {
        .int64 => .int64,
        .double => .double,
        .bool => .bool,
    };
    return .{ .recorder = self, .index = try self.declare(spec, .gauge, .gauge, vt, null, null) };
}

/// A histogram in `buckets`: explicit bounds, or a linear or exponential
/// layout, at most 200 buckets with underflow and overflow.
pub fn histogram(self: *Recorder, spec: InstrumentSpec, buckets: types.Distribution.Buckets) Error!Histogram {
    if (validate.distributionProblem(.{ .buckets = buckets })) |reason| {
        if (self.diagnostics) |d| d.print("invalid buckets: {s}", .{reason});
        return error.InvalidOptions;
    }
    return .{ .recorder = self, .index = try self.declare(spec, .histogram, .cumulative, .distribution, buckets, null) };
}

/// Reads `observer` at every write. `kind` is `.gauge` or `.cumulative`;
/// a cumulative observer's series start at `start`, or now when null, and
/// a total that falls is taken as a reset: the series starts again 1 ms
/// after its last end, as the server requires.
pub fn observe(self: *Recorder, spec: InstrumentSpec, kind: types.Kind, start: ?std.Io.Timestamp, observer: Observer) Error!void {
    if (kind != .gauge and kind != .cumulative) {
        if (self.diagnostics) |d| d.print("invalid observer: a gauge or a cumulative", .{});
        return error.InvalidOptions;
    }
    const index = try self.declare(spec, .observer, kind, null, null, observer);
    self.mutex.lockUncancelable(self.io);
    defer self.mutex.unlock(self.io);
    self.instruments.items[index].observer_start_ns = millis((start orelse std.Io.Clock.real.now(self.io)).nanoseconds);
}

fn declare(self: *Recorder, spec: InstrumentSpec, kind: Kind, metric_kind: types.Kind, value_type: ?types.ValueType, buckets: ?types.Distribution.Buckets, observer: ?Observer) Error!u32 {
    var name_buf: [validate.max_metric_type_len + 1]u8 = undefined;
    const metric_type = std.fmt.bufPrint(&name_buf, "{s}{s}", .{ self.prefix, spec.name }) catch {
        if (self.diagnostics) |d| d.print("invalid instrument name: a metric type is at most 512 characters", .{});
        return error.InvalidMetricType;
    };
    if (validate.metricTypeProblem(metric_type)) |reason| {
        if (self.diagnostics) |d| d.print("invalid instrument name: {s}", .{reason});
        return error.InvalidMetricType;
    }
    if (spec.label_keys.len > validate.max_metric_labels) {
        if (self.diagnostics) |d| d.print("invalid instrument: more than 30 labels", .{});
        return error.InvalidLabel;
    }
    for (spec.label_keys, 0..) |k, i| {
        if (!validate.isLabelKey(k)) {
            if (self.diagnostics) |d| d.print("invalid instrument: a label key is a letter, then letters, digits and _, at most 100 bytes", .{});
            return error.InvalidLabel;
        }
        for (spec.label_keys[0..i]) |earlier| if (std.mem.eql(u8, earlier, k)) {
            if (self.diagnostics) |d| d.print("invalid instrument: a label key appears twice", .{});
            return error.InvalidLabel;
        };
    }
    if (!validate.isUnit(spec.unit)) {
        if (self.diagnostics) |d| d.print("invalid instrument: a unit is printable ASCII without spaces", .{});
        return error.InvalidOptions;
    }

    self.mutex.lockUncancelable(self.io);
    defer self.mutex.unlock(self.io);
    for (self.instruments.items, 0..) |existing, i| {
        if (!std.mem.eql(u8, existing.type, metric_type)) continue;
        // The same instrument again is the one already declared.
        if (existing.kind == kind and existing.metric_kind == metric_kind and existing.value_type == value_type and sameKeys(existing.label_keys, spec.label_keys) and observer == null) {
            return @intCast(i);
        }
        if (self.diagnostics) |d| d.print("invalid instrument: {s} is declared already with another shape", .{metric_type});
        return error.InvalidOptions;
    }
    const a = self.store.allocator();
    const keys = try a.alloc([]const u8, spec.label_keys.len);
    for (spec.label_keys, keys) |k, *c| c.* = try a.dupe(u8, k);
    const inst = try a.create(Instrument);
    inst.* = .{
        .kind = kind,
        .type = try a.dupe(u8, metric_type),
        .label_keys = keys,
        .unit = try a.dupe(u8, spec.unit),
        .description = try a.dupe(u8, spec.description),
        .metric_kind = metric_kind,
        .value_type = value_type,
        .buckets = if (buckets) |b| try copyBuckets(a, b) else null,
        .observer = observer,
        .descriptor = if (self.descriptors == .auto) .ready else .unknown,
    };
    try self.instruments.append(self.gpa, inst);
    return @intCast(self.instruments.items.len - 1);
}

fn sameKeys(a: []const []const u8, b: []const []const u8) bool {
    if (a.len != b.len) return false;
    for (a, b) |x, y| if (!std.mem.eql(u8, x, y)) return false;
    return true;
}

fn copyBuckets(a: Allocator, b: types.Distribution.Buckets) Allocator.Error!types.Distribution.Buckets {
    return switch (b) {
        .explicit => |bounds| .{ .explicit = try a.dupe(f64, bounds) },
        else => b,
    };
}

// Recording.

const Recording = union(enum) {
    add: u64,
    set: GaugeValue,
    sample: f64,
};

fn record(self: *Recorder, index: u32, label_values: []const []const u8, what: Recording) void {
    self.mutex.lockUncancelable(self.io);
    defer self.mutex.unlock(self.io);
    const inst = self.instruments.items[index];
    if (label_values.len != inst.label_keys.len) return self.dropped(inst, "the wrong number of label values");
    if (what == .sample and !std.math.isFinite(what.sample)) return self.dropped(inst, "a value that is not a finite number");
    if (what == .set and @as(GaugeType, what.set) != gaugeTypeOf(inst.value_type.?)) return self.dropped(inst, "a value of another type than the gauge's");
    const series = self.seriesFor(index, label_values) orelse return self.dropped(inst, "the series cap, or short memory");
    switch (what) {
        .add => |n| series.state.total +|= n,
        .set => |v| series.state.gauge = v,
        .sample => |x| {
            const h = &series.state.histogram;
            h.counts[bucketIndex(inst.buckets.?, x)] += 1;
            h.count += 1;
            const delta = x - h.mean;
            h.mean += delta / @as(f64, @floatFromInt(h.count));
            h.m2 += delta * (x - h.mean);
        },
    }
}

fn gaugeTypeOf(vt: types.ValueType) GaugeType {
    return switch (vt) {
        .int64 => .int64,
        .double => .double,
        else => .bool,
    };
}

/// Counts a recording that could not be kept, and logs the first one of
/// each instrument. Under the lock.
fn dropped(self: *Recorder, inst: *Instrument, why: []const u8) void {
    self.counts.recordings_dropped += 1;
    if (inst.logged_drop) return;
    inst.logged_drop = true;
    logging.warn("a recording of {s} was dropped: {s}; later ones are counted in stats() only", .{ inst.type, why });
}

/// The series of `index` with `label_values`, made when new and room
/// remains; null past `max_series` or when memory is short. Under the lock.
fn seriesFor(self: *Recorder, index: u32, label_values: []const []const u8) ?*Series {
    const key: SeriesKey = .{ .instrument = index, .values = label_values };
    if (self.series.getAdapted(key, KeyContext{})) |s| return s;
    if (self.series.count() >= self.max_series) return null;
    return self.newSeries(index, label_values) catch null;
}

fn newSeries(self: *Recorder, index: u32, label_values: []const []const u8) Allocator.Error!*Series {
    const inst = self.instruments.items[index];
    const a = self.store.allocator();
    const values = try a.alloc([]const u8, label_values.len);
    for (label_values, values) |v, *c| c.* = try a.dupe(u8, v);
    const s = try a.create(Series);
    const start = if (inst.kind == .observer) inst.observer_start_ns else millis(std.Io.Clock.real.now(self.io).nanoseconds);
    s.* = .{
        .instrument = index,
        .values = values,
        .start_ns = start,
        .state = switch (inst.kind) {
            .counter => .{ .total = 0 },
            .gauge => .{ .gauge = null },
            .histogram => .{ .histogram = .{ .counts = blk: {
                const counts = try a.alloc(u64, inst.buckets.?.total());
                @memset(counts, 0);
                break :blk counts;
            } } },
            .observer => if (inst.value_type == .double) .{ .double_total = 0 } else .{ .total = 0 },
        },
    };
    try self.series.putNoClobber(self.gpa, .{ .instrument = index, .values = values }, s);
    self.counts.series += 1;
    return s;
}

/// The bucket `x` falls in: 0 for underflow, then each finite bucket,
/// then overflow, as Cloud Monitoring's layouts define them.
fn bucketIndex(b: types.Distribution.Buckets, x: f64) usize {
    switch (b) {
        .explicit => |bounds| {
            var i: usize = 0;
            while (i < bounds.len and x >= bounds[i]) i += 1;
            return i;
        },
        .linear => |l| {
            if (x < l.offset) return 0;
            const i = @floor((x - l.offset) / l.width) + 1;
            return if (i > @as(f64, @floatFromInt(l.num_finite))) l.num_finite + 1 else @intFromFloat(i);
        },
        .exponential => |e| {
            if (x < e.scale) return 0;
            var bound = e.scale;
            var i: usize = 1;
            while (i <= e.num_finite) : (i += 1) {
                bound *= e.growth_factor;
                if (x < bound) return i;
            }
            return e.num_finite + 1;
        },
    }
}

fn millis(ns: i96) i96 {
    return @divFloor(ns, std.time.ns_per_ms) * std.time.ns_per_ms;
}

// Writing.

/// Writes every series that is due now: one written 5 s or more ago, or
/// never. Observers are read first. Several requests go when there are
/// more than 200 series, one after another, and a failed one does not
/// stop the rest. Nothing is retried beyond the client's write rule and
/// nothing is queued: the next write carries the totals. `run` calls this
/// every interval; a program without a task to spare can call it itself,
/// but not while `run` runs: the client serves one task at a time.
pub fn flush(self: *Recorder) std.Io.Cancelable!void {
    try self.writeDue();
}

fn writeDue(self: *Recorder) std.Io.Cancelable!void {
    var scratch: std.heap.ArenaAllocator = .init(self.gpa);
    defer scratch.deinit();
    const a = scratch.allocator();
    self.readObservers(a);
    self.ensureDescriptors(a);

    var pending: std.ArrayList(Pending) = .empty;
    {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        const now = millis(std.Io.Clock.real.now(self.io).nanoseconds);
        self.snapshot(a, now, &pending) catch {
            // Short memory: the next write carries the totals.
            logging.warn("a write was skipped: memory is short", .{});
            return;
        };
    }
    var at: usize = 0;
    while (at < pending.items.len) {
        const chunk = pending.items[at..@min(pending.items.len, at + validate.max_series_per_write)];
        at += chunk.len;
        try self.send(a, chunk);
    }
}

const Pending = struct { series: *Series, ts: types.TimeSeries };

/// Every due series as a point to write, its end `now`. Under the lock.
fn snapshot(self: *Recorder, a: Allocator, now: i96, out: *std.ArrayList(Pending)) Allocator.Error!void {
    var it = self.series.iterator();
    while (it.next()) |entry| {
        const s = entry.value_ptr.*;
        const inst = self.instruments.items[s.instrument];
        if (inst.descriptor == .mismatch or inst.descriptor == .unknown) continue;
        // The last write keeps the floor too: after a clock stepped back,
        // waiting 5 s may not be enough, and such a series is left out.
        if (s.last_end_ns) |prev| if (now - prev < floor_ns) continue;
        const value: types.Value = switch (s.state) {
            .total => |n| .{ .int64 = @intCast(@min(n, std.math.maxInt(i64))) },
            .double_total => |d| .{ .double = d },
            .gauge => |g| switch (g orelse continue) {
                .int64 => |n| .{ .int64 = n },
                .double => |d| .{ .double = d },
                .bool => |b| .{ .bool = b },
            },
            .histogram => |h| .{ .distribution = .{
                .count = h.count,
                .mean = if (h.count == 0) 0 else h.mean,
                .sum_of_squared_deviation = if (h.count == 0) 0 else h.m2,
                .buckets = inst.buckets.?,
                .bucket_counts = try a.dupe(u64, trimmed(h.counts)),
            } },
        };
        const end = now;
        const cumulative = inst.metric_kind == .cumulative;
        if (s.last_end_ns) |prev| {
            if (end <= prev) continue;
        } else if (cumulative and s.start_ns >= end) {
            // A start that is not before the first end, as when a series is
            // recorded and written in one millisecond, or the clock stepped
            // back: nothing is written yet, so the start moves back, where
            // Go's and Java's exporters move the end ahead, into the future.
            s.start_ns = end - std.time.ns_per_ms;
        }
        const labels = try a.alloc(types.Label, inst.label_keys.len);
        for (inst.label_keys, s.values, labels) |k, v, *l| l.* = .{ .key = k, .value = v };
        try out.append(a, .{ .series = s, .ts = .{
            .metric_type = inst.type,
            .metric_labels = labels,
            .resource = self.resource,
            .kind = inst.metric_kind,
            .unit = inst.unit,
            .start = if (cumulative) .{ .nanoseconds = s.start_ns } else null,
            .end = .{ .nanoseconds = end },
            .value = value,
        } });
    }
}

/// Bucket counts without their trailing zeros, which production took.
fn trimmed(counts: []const u64) []const u64 {
    var n = counts.len;
    while (n > 0 and counts[n - 1] == 0) n -= 1;
    return counts[0..n];
}

/// Sends one request, and counts what came of it. Every series in it is
/// taken as written at its end time, whatever the answer: a request that
/// failed may have been stored, and the next point must keep the floor
/// from it either way.
fn send(self: *Recorder, a: Allocator, chunk: []const Pending) std.Io.Cancelable!void {
    const series = a.alloc(types.TimeSeries, chunk.len) catch {
        logging.warn("a write of {d} points was skipped: memory is short", .{chunk.len});
        return;
    };
    for (chunk, series) |p, *s| s.* = p.ts;
    {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        for (chunk) |p| p.series.last_end_ns = p.ts.end.nanoseconds;
        self.counts.requests += 1;
    }
    var result = self.client.write(series) catch |err| {
        if (err == error.Canceled) return error.Canceled;
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        self.counts.requests_failed += 1;
        self.counts.points_failed += chunk.len;
        logging.warn("a write of {d} points failed with {t}", .{ chunk.len, err });
        return;
    };
    defer result.deinit();
    self.mutex.lockUncancelable(self.io);
    defer self.mutex.unlock(self.io);
    self.counts.points_written += result.value.written;
    self.counts.points_refused += result.value.points - result.value.written;
    if (!result.value.ok()) logging.warn("a write stored {d} of {d} points: {s}", .{ result.value.written, result.value.points, result.value.message });
}

/// Calls every observer, outside the lock, and keeps what each reported.
fn readObservers(self: *Recorder, a: Allocator) void {
    var observers: std.ArrayList(struct { index: u32, observer: Observer }) = .empty;
    {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        for (self.instruments.items, 0..) |inst, i| if (inst.observer) |o| {
            observers.append(a, .{ .index = @intCast(i), .observer = o }) catch return;
        };
    }
    for (observers.items) |o| {
        var report: Report = .{ .arena = a };
        o.observer.report(o.observer.context, &report);
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        const inst = self.instruments.items[o.index];
        if (report.failed) self.dropped(inst, "short memory");
        for (report.items.items) |item| self.observed(o.index, inst, item);
    }
}

/// One observed value. An observer's value type is fixed by its first
/// report. Under the lock.
fn observed(self: *Recorder, index: u32, inst: *Instrument, item: Report.Item) void {
    const vt: types.ValueType = if (item.value == .int64) .int64 else .double;
    if (inst.value_type == null) inst.value_type = vt;
    if (inst.value_type.? != vt) return self.dropped(inst, "an int64 and a double from one observer");
    if (item.values.len != inst.label_keys.len) return self.dropped(inst, "the wrong number of label values");
    const s = self.seriesFor(index, item.values) orelse return self.dropped(inst, "the series cap, or short memory");
    if (inst.metric_kind == .gauge) {
        s.state = .{ .gauge = item.value };
        return;
    }
    // A cumulative total that falls has started over.
    const fell = switch (item.value) {
        .int64 => |n| n < 0 or @as(u64, @intCast(n)) < s.state.total,
        .double => |d| d < s.state.double_total,
        .bool => false,
    };
    if (fell) if (s.last_end_ns) |prev| {
        s.start_ns = prev + std.time.ns_per_ms;
    };
    switch (item.value) {
        .int64 => |n| s.state = .{ .total = @intCast(@max(n, 0)) },
        .double => |d| s.state = .{ .double_total = d },
        .bool => {},
    }
}

/// Reads or creates the descriptor of every instrument that has none yet,
/// with `.create_if_missing`, outside the lock.
fn ensureDescriptors(self: *Recorder, a: Allocator) void {
    var todo: std.ArrayList(u32) = .empty;
    {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        for (self.instruments.items, 0..) |inst, i| {
            if (inst.descriptor == .unknown and inst.value_type != null) todo.append(a, @intCast(i)) catch return;
        }
    }
    for (todo.items) |index| {
        const inst = self.instruments.items[index];
        const state = self.descriptorFor(inst);
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        inst.descriptor = state;
        switch (state) {
            .mismatch, .gave_up => self.counts.descriptor_failures += 1,
            else => {},
        }
    }
}

/// Reads the descriptor, and creates it when missing. `.unknown` again
/// when the server could not be asked, so the next write asks.
fn descriptorFor(self: *Recorder, inst: *const Instrument) DescriptorState {
    const m = self.client.metric(inst.type);
    if (m.get()) |info| {
        var owned = info;
        defer owned.deinit();
        return self.compare(inst, owned.value);
    } else |err| switch (err) {
        error.NotFound => {},
        else => return if (isTransient(err)) .unknown else self.gaveUp(inst, err),
    }
    var labels_buf: [validate.max_metric_labels]types.LabelDescriptor = undefined;
    for (inst.label_keys, labels_buf[0..inst.label_keys.len]) |k, *l| l.* = .{ .key = k };
    if (m.create(.{
        .kind = inst.metric_kind,
        .value_type = inst.value_type.?,
        .unit = inst.unit,
        .description = inst.description,
        .labels = labels_buf[0..inst.label_keys.len],
    })) |made| {
        var owned = made;
        owned.deinit();
        self.mutex.lockUncancelable(self.io);
        self.counts.descriptors_created += 1;
        self.mutex.unlock(self.io);
        return .ready;
    } else |err| switch (err) {
        // Made meanwhile with another shape: production's 409.
        error.AlreadyExists => {
            var again = m.get() catch return .unknown;
            defer again.deinit();
            return self.compare(inst, again.value);
        },
        else => return if (isTransient(err)) .unknown else self.gaveUp(inst, err),
    }
}

fn isTransient(err: Error) bool {
    return core.isRetryable(err) or err == error.Canceled;
}

/// A descriptor this recorder may write to: the same kind and value type.
/// Missing labels a write adds, and a unit or description that differs is
/// left alone: the recorder never rewrites a descriptor.
fn compare(self: *Recorder, inst: *const Instrument, info: types.MetricInfo) DescriptorState {
    _ = self;
    if (info.kind == inst.metric_kind and info.value_type == inst.value_type.?) return .ready;
    logging.warn("{s} exists as {t} {t}, and this recorder writes {t} {t}: its series are not written", .{ inst.type, info.kind, info.value_type, inst.metric_kind, inst.value_type.? });
    return .mismatch;
}

fn gaveUp(self: *Recorder, inst: *const Instrument, err: Error) DescriptorState {
    _ = self;
    logging.warn("the descriptor of {s} could not be read or made ({t}); the first write makes it", .{ inst.type, err });
    return .gave_up;
}

// Running.

/// Writes every interval until `stop`, then once more, blocking the
/// calling task. A recorder runs once. A write that outlasts the interval
/// delays the next; missed ticks are not made up, so a slow network gives
/// fewer points, not a burst.
pub fn run(self: *Recorder) Error!void {
    const io = self.io;
    {
        self.mutex.lockUncancelable(io);
        defer self.mutex.unlock(io);
        if (self.ran) {
            if (self.diagnostics) |d| d.print("a Recorder runs once; init another to run again", .{});
            return error.InvalidOptions;
        }
        self.ran = true;
    }
    var next = std.Io.Clock.awake.now(io).nanoseconds + self.interval_ns;
    while (!self.isStopping()) {
        self.wake.waitTimeout(io, .{ .deadline = .{ .raw = .{ .nanoseconds = next }, .clock = .awake } }) catch |err| switch (err) {
            error.Timeout => {},
            error.Canceled => return error.Canceled,
        };
        if (self.isStopping()) break;
        try self.flush();
        next = @max(next + self.interval_ns, std.Io.Clock.awake.now(io).nanoseconds);
    }
    try self.finish();
}

/// The last write. With `.wait`, a series written less than 5 s before
/// waits out the rest of the 5 s, at most 5 s in all.
fn finish(self: *Recorder) std.Io.Cancelable!void {
    if (self.last_write == .wait) {
        var wait_ns: i96 = 0;
        {
            self.mutex.lockUncancelable(self.io);
            defer self.mutex.unlock(self.io);
            const now = millis(std.Io.Clock.real.now(self.io).nanoseconds);
            var it = self.series.valueIterator();
            while (it.next()) |s| if (s.*.last_end_ns) |prev| {
                wait_ns = @max(wait_ns, prev + floor_ns - now);
            };
        }
        if (wait_ns > 0) try self.io.sleep(.fromNanoseconds(@min(wait_ns, floor_ns)), .awake);
    }
    try self.writeDue();
}

/// Ends `run` after one last write. Safe from any task, before or during
/// `run`.
pub fn stop(self: *Recorder) void {
    self.mutex.lockUncancelable(self.io);
    self.stopping = true;
    self.mutex.unlock(self.io);
    self.wake.set(self.io);
}

fn isStopping(self: *Recorder) bool {
    self.mutex.lockUncancelable(self.io);
    defer self.mutex.unlock(self.io);
    return self.stopping;
}

/// A consistent snapshot of the counters.
pub fn stats(self: *Recorder) Stats {
    self.mutex.lockUncancelable(self.io);
    defer self.mutex.unlock(self.io);
    return self.counts;
}

const testing = std.testing;
const test_util = @import("test_util.zig");
const FakeMonitoring = @import("fake_monitoring.zig").FakeMonitoring;

/// 2026-10-18T13:46:35.949Z.
const t0_ns: i96 = 1_792_331_195_949 * std.time.ns_per_ms;
const task: types.Resource = .{ .generic_task = .{ .location = "us-central1", .namespace = "shop", .job = "api", .task_id = "7" } };

/// A recorder writing to a fake, on a fake clock. Initialize in place.
const Bench = struct {
    clock: test_util.FakeClock,
    fake: FakeMonitoring,
    token: core.StaticToken,
    recorder: Recorder,

    fn init(b: *Bench, options: struct { descriptors: Descriptors = .auto, max_series: u32 = 10_000, last_write: LastWrite = .wait, interval_ms: u32 = 60_000 }) !void {
        b.* = .{ .clock = .{ .now_ns = t0_ns }, .fake = undefined, .token = .{ .token = "t" }, .recorder = undefined };
        b.fake = .init(testing.allocator, b.clock.io(), .{});
        errdefer b.fake.deinit();
        b.recorder = try .init(testing.allocator, b.clock.io(), .{
            .client = .{ .project_id = "my-project", .token_provider = b.token.provider(), .transport = b.fake.transport() },
            .resource = task,
            .descriptors = options.descriptors,
            .max_series = options.max_series,
            .last_write = options.last_write,
            .interval_ms = options.interval_ms,
        });
    }

    fn deinit(b: *Bench) void {
        b.recorder.deinit();
        b.fake.deinit();
    }

    fn advance(b: *Bench, ms: i64) void {
        b.clock.now_ns += @as(i96, ms) * std.time.ns_per_ms;
    }

    /// The points of `name` with `labels`, oldest first.
    fn points(b: *Bench, a: Allocator, name: []const u8, labels: []const types.Label) ![]const FakeMonitoring.Point {
        const full = try std.fmt.allocPrint(a, "custom.googleapis.com/{s}", .{name});
        return b.fake.points(a, full, labels);
    }
};

test "a counter: one series per label set, its start kept, its total written each time" {
    var b: Bench = undefined;
    try b.init(.{});
    defer b.deinit();
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const orders = try b.recorder.counter(.{ .name = "shop/orders", .label_keys = &.{"region"}, .unit = "{order}" });
    orders.add(&.{"eu"}, 2);
    b.advance(10);
    orders.add(&.{"eu"}, 3);
    orders.add(&.{"us"}, 1);
    b.advance(1_000);
    try b.recorder.flush();
    var eu = try b.points(a, "shop/orders", &.{.{ .key = "region", .value = "eu" }});
    try testing.expectEqual(1, eu.len);
    try testing.expectEqual(5, eu[0].value.int64);
    try testing.expectEqual(t0_ns, eu[0].start.?.nanoseconds);
    try testing.expectEqual(t0_ns + 1_010 * std.time.ns_per_ms, eu[0].end.nanoseconds);

    orders.add(&.{"eu"}, 4);
    b.advance(5_000);
    try b.recorder.flush();
    eu = try b.points(a, "shop/orders", &.{.{ .key = "region", .value = "eu" }});
    try testing.expectEqual(2, eu.len);
    try testing.expectEqual(9, eu[1].value.int64);
    try testing.expectEqual(t0_ns, eu[1].start.?.nanoseconds);
    const s = b.recorder.stats();
    try testing.expectEqual(2, s.series);
    try testing.expectEqual(4, s.points_written);
    try testing.expectEqual(2, s.requests);
    const d = (try b.fake.descriptor(a, "custom.googleapis.com/shop/orders")).?;
    try testing.expectEqual(types.Kind.cumulative, d.kind);
    try testing.expectEqualStrings("{order}", d.unit);
}

test "a cumulative series written in the millisecond it was first recorded starts 1 ms earlier" {
    var b: Bench = undefined;
    try b.init(.{});
    defer b.deinit();
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const c = try b.recorder.counter(.{ .name = "now" });
    c.add(&.{}, 1);
    try b.recorder.flush();
    const p = try b.points(arena.allocator(), "now", &.{});
    try testing.expectEqual(t0_ns, p[0].end.nanoseconds);
    try testing.expectEqual(t0_ns - std.time.ns_per_ms, p[0].start.?.nanoseconds);
    // The start stays put from then on.
    c.add(&.{}, 1);
    b.advance(5_000);
    try b.recorder.flush();
    const q = try b.points(arena.allocator(), "now", &.{});
    try testing.expectEqual(t0_ns - std.time.ns_per_ms, q[1].start.?.nanoseconds);
    try testing.expectEqual(2, q[1].value.int64);
}

test "a gauge: its last value at every write, none before one is set" {
    var b: Bench = undefined;
    try b.init(.{});
    defer b.deinit();
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const depth = try b.recorder.gauge(.{ .name = "depth" }, .int64);
    const load = try b.recorder.gauge(.{ .name = "load", .label_keys = &.{"cpu"} }, .double);
    const up = try b.recorder.gauge(.{ .name = "up" }, .bool);
    _ = try b.recorder.gauge(.{ .name = "never" }, .int64);
    depth.set(&.{}, .{ .int64 = 7 });
    load.set(&.{"0"}, .{ .double = std.math.nan(f64) });
    up.set(&.{}, .{ .bool = true });
    try b.recorder.flush();
    b.advance(5_000);
    depth.set(&.{}, .{ .int64 = 8 });
    try b.recorder.flush();
    b.advance(5_000);
    try b.recorder.flush();
    const d = try b.points(a, "depth", &.{});
    try testing.expectEqual(3, d.len);
    try testing.expectEqual(7, d[0].value.int64);
    try testing.expectEqual(8, d[2].value.int64);
    try testing.expectEqual(null, d[0].start);
    try testing.expect(std.math.isNan((try b.points(a, "load", &.{.{ .key = "cpu", .value = "0" }}))[0].value.double));
    try testing.expect((try b.points(a, "up", &.{}))[2].value.bool);
    try testing.expectEqual(0, (try b.points(a, "never", &.{})).len);
    try testing.expectEqual(3, b.recorder.stats().series);
    // A value of another type is dropped.
    depth.set(&.{}, .{ .double = 1.5 });
    try testing.expectEqual(1, b.recorder.stats().recordings_dropped);
}

test "a histogram: buckets by layout, the exact count, mean and squared deviation" {
    var b: Bench = undefined;
    try b.init(.{});
    defer b.deinit();
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const values = [_]f64{ 0.5, 1, 1.5, 2, 3.25, 9, 100, -4 };
    const layouts = [_]struct { []const u8, types.Distribution.Buckets, []const u64 }{
        .{ "explicit", .{ .explicit = &.{ 1, 2, 4 } }, &.{ 2, 2, 2, 2 } },
        .{ "linear", .{ .linear = .{ .num_finite = 4, .width = 1, .offset = 0 } }, &.{ 1, 1, 2, 1, 1, 2 } },
        .{ "exponential", .{ .exponential = .{ .num_finite = 3, .growth_factor = 2, .scale = 1 } }, &.{ 2, 2, 2, 0, 2 } },
    };
    for (layouts) |l| {
        const h = try b.recorder.histogram(.{ .name = l[0] }, l[1]);
        for (values) |v| h.record(&.{}, v);
        h.record(&.{}, std.math.inf(f64));
    }
    try b.recorder.flush();
    // A two-pass reference.
    var sum: f64 = 0;
    for (values) |v| sum += v;
    const mean = sum / values.len;
    var ssd: f64 = 0;
    for (values) |v| ssd += (v - mean) * (v - mean);
    for (layouts) |l| {
        const d = (try b.points(a, l[0], &.{}))[0].value.distribution;
        try testing.expectEqual(values.len, d.count);
        try testing.expectApproxEqRel(mean, d.mean, 1e-12);
        try testing.expectApproxEqRel(ssd, d.sum_of_squared_deviation, 1e-12);
        try testing.expectEqualSlices(u64, l[2], d.bucket_counts);
    }
    try testing.expectEqual(3, b.recorder.stats().recordings_dropped);

    // Empty buckets at the end are left off, as production took them.
    const small = try b.recorder.histogram(.{ .name = "small" }, .{ .explicit = &.{ 10, 20, 30 } });
    small.record(&.{}, 1);
    small.record(&.{}, 12);
    try b.recorder.flush();
    try testing.expectEqualSlices(u64, &.{ 1, 1 }, (try b.points(a, "small", &.{}))[0].value.distribution.bucket_counts);
}

test "bucketIndex: each layout's edges" {
    const explicit: types.Distribution.Buckets = .{ .explicit = &.{ 1, 2 } };
    try testing.expectEqual(0, bucketIndex(explicit, 0.999));
    try testing.expectEqual(1, bucketIndex(explicit, 1));
    try testing.expectEqual(2, bucketIndex(explicit, 2));
    const linear: types.Distribution.Buckets = .{ .linear = .{ .num_finite = 2, .width = 10, .offset = 5 } };
    try testing.expectEqual(0, bucketIndex(linear, 4.9));
    try testing.expectEqual(1, bucketIndex(linear, 5));
    try testing.expectEqual(2, bucketIndex(linear, 24.9));
    try testing.expectEqual(3, bucketIndex(linear, 25));
    try testing.expectEqual(3, bucketIndex(linear, 1e300));
    const exponential: types.Distribution.Buckets = .{ .exponential = .{ .num_finite = 2, .growth_factor = 10, .scale = 1 } };
    try testing.expectEqual(0, bucketIndex(exponential, 0.5));
    try testing.expectEqual(1, bucketIndex(exponential, 9.99));
    try testing.expectEqual(2, bucketIndex(exponential, 10));
    try testing.expectEqual(3, bucketIndex(exponential, 100));
}

test "the 5 s floor per series, by the recorder's own times; a clock stepped back waits" {
    var b: Bench = undefined;
    try b.init(.{});
    defer b.deinit();
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const g = try b.recorder.gauge(.{ .name = "g" }, .int64);
    const late = try b.recorder.gauge(.{ .name = "late" }, .int64);
    g.set(&.{}, .{ .int64 = 1 });
    try b.recorder.flush();
    b.advance(3_000);
    late.set(&.{}, .{ .int64 = 1 });
    // g is not due; late, never written, is.
    try b.recorder.flush();
    try testing.expectEqual(1, (try b.points(a, "g", &.{})).len);
    try testing.expectEqual(1, (try b.points(a, "late", &.{})).len);
    b.advance(2_000);
    try b.recorder.flush();
    try testing.expectEqual(2, (try b.points(a, "g", &.{})).len);
    try testing.expectEqual(1, (try b.points(a, "late", &.{})).len);
    // The clock steps back a minute: nothing until it passes the last end.
    b.advance(-60_000);
    try b.recorder.flush();
    b.advance(64_999);
    try b.recorder.flush();
    try testing.expectEqual(2, (try b.points(a, "g", &.{})).len);
    b.advance(1);
    try b.recorder.flush();
    try testing.expectEqual(3, (try b.points(a, "g", &.{})).len);
    try testing.expectEqual(0, b.recorder.stats().points_refused);
}

test "more than 200 series go in several requests, and a failed one does not stop the rest" {
    var b: Bench = undefined;
    try b.init(.{});
    defer b.deinit();
    const c = try b.recorder.counter(.{ .name = "many", .label_keys = &.{"i"} });
    var buf: [8]u8 = undefined;
    for (0..450) |i| c.add(&.{try std.fmt.bufPrint(&buf, "{d}", .{i})}, 1);
    b.fake.refuseNext(1, 503);
    try b.recorder.flush();
    const s = b.recorder.stats();
    try testing.expectEqual(3, s.requests);
    try testing.expectEqual(1, s.requests_failed);
    try testing.expectEqual(250, s.points_written);
    try testing.expectEqual(200, s.points_failed);
    try testing.expectEqual(0, s.points_refused);
    try testing.expectEqual(250, b.fake.pointCount());
    // The series the failed request held are written at the next write.
    b.advance(5_000);
    try b.recorder.flush();
    try testing.expectEqual(700, b.fake.pointCount());
}

test "a refused point counts as refused, and its series is written again later" {
    var b: Bench = undefined;
    try b.init(.{});
    defer b.deinit();
    // Another writer took the series: production refuses this recorder's
    // point as too soon after it.
    var other = try b.recorder.client.write(&.{.{ .metric_type = "custom.googleapis.com/shared", .resource = task, .kind = .gauge, .end = .{ .nanoseconds = t0_ns }, .value = .{ .int64 = 1 } }});
    other.deinit();
    const g = try b.recorder.gauge(.{ .name = "shared" }, .int64);
    g.set(&.{}, .{ .int64 = 2 });
    b.advance(1_000);
    try b.recorder.flush();
    try testing.expectEqual(1, b.recorder.stats().points_refused);
    try testing.expectEqual(0, b.recorder.stats().requests_failed);
    b.advance(5_000);
    try b.recorder.flush();
    try testing.expectEqual(1, b.recorder.stats().points_written);
}

test "the series cap and recordings that do not fit are dropped, counted, and logged once" {
    var b: Bench = undefined;
    try b.init(.{ .max_series = 2 });
    defer b.deinit();
    const c = try b.recorder.counter(.{ .name = "capped", .label_keys = &.{"k"} });
    logging.capture.reset();
    c.add(&.{"a"}, 1);
    c.add(&.{"b"}, 1);
    c.add(&.{"c"}, 1);
    c.add(&.{"d"}, 1);
    c.add(&.{"a"}, 1);
    c.add(&.{ "a", "extra" }, 1);
    c.add(&.{}, 1);
    const s = b.recorder.stats();
    try testing.expectEqual(2, s.series);
    try testing.expectEqual(4, s.recordings_dropped);
    try testing.expectEqual(1, std.mem.count(u8, logging.capture.text(), "custom.googleapis.com/capped was dropped"));
}

test "descriptors: read, created once with unit, description and labels; a refusal not asked again" {
    var b: Bench = undefined;
    try b.init(.{ .descriptors = .create_if_missing });
    defer b.deinit();
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const c = try b.recorder.counter(.{ .name = "made", .label_keys = &.{"region"}, .unit = "By", .description = "Bytes sent" });
    c.add(&.{"eu"}, 1);
    try b.recorder.flush();
    const d = (try b.fake.descriptor(a, "custom.googleapis.com/made")).?;
    try testing.expectEqualStrings("Bytes sent", d.description);
    try testing.expectEqualStrings("region", d.labels[0].key);
    try testing.expectEqual(1, b.recorder.stats().descriptors_created);
    // get, create, write; then only writes.
    try testing.expectEqual(3, b.fake.callCount());
    b.advance(5_000);
    try b.recorder.flush();
    try testing.expectEqual(4, b.fake.callCount());

    // A 403 on the read: given up, written anyway, not asked again.
    const g = try b.recorder.gauge(.{ .name = "denied" }, .int64);
    g.set(&.{}, .{ .int64 = 1 });
    b.fake.refuseNext(1, 403);
    b.advance(5_000);
    try b.recorder.flush();
    try testing.expectEqual(1, b.recorder.stats().descriptor_failures);
    try testing.expectEqual(1, (try b.points(a, "denied", &.{})).len);
    const calls = b.fake.callCount();
    b.advance(5_000);
    try b.recorder.flush();
    // One write for both instruments.
    try testing.expectEqual(calls + 1, b.fake.callCount());

    // A 503 on the read is asked again at the next write, and nothing of
    // the instrument is written meanwhile.
    const h = try b.recorder.gauge(.{ .name = "flaky" }, .int64);
    h.set(&.{}, .{ .int64 = 1 });
    // Every attempt the client's retry policy makes.
    b.fake.refuseNext(5, 503);
    b.advance(5_000);
    try b.recorder.flush();
    try testing.expectEqual(0, (try b.points(a, "flaky", &.{})).len);
    b.advance(5_000);
    try b.recorder.flush();
    try testing.expectEqual(1, (try b.points(a, "flaky", &.{})).len);
}

test "descriptors: one that exists with another kind stops the instrument's series" {
    var b: Bench = undefined;
    try b.init(.{ .descriptors = .create_if_missing });
    defer b.deinit();
    var made = try b.recorder.client.metric("custom.googleapis.com/clash").create(.{ .kind = .gauge, .value_type = .int64 });
    made.deinit();
    const c = try b.recorder.counter(.{ .name = "clash" });
    c.add(&.{}, 1);
    logging.capture.reset();
    try b.recorder.flush();
    try testing.expectEqual(1, b.recorder.stats().descriptor_failures);
    try testing.expectEqual(0, b.fake.pointCount());
    try testing.expect(std.mem.indexOf(u8, logging.capture.text(), "exists as gauge int64") != null);
    // The same kind and another value type is a clash too.
    var doubles = try b.recorder.client.metric("custom.googleapis.com/clash2").create(.{ .kind = .cumulative, .value_type = .double });
    doubles.deinit();
    const c2 = try b.recorder.counter(.{ .name = "clash2" });
    c2.add(&.{}, 1);
    try b.recorder.flush();
    try testing.expectEqual(2, b.recorder.stats().descriptor_failures);
    try testing.expectEqual(0, b.fake.pointCount());
    // One that exists with the same shape is written to, and a create
    // that meets another writer's of another shape reads it again.
    var same = try b.recorder.client.metric("custom.googleapis.com/fits").create(.{ .kind = .cumulative, .value_type = .int64, .unit = "1" });
    same.deinit();
    const fits = try b.recorder.counter(.{ .name = "fits" });
    fits.add(&.{}, 1);
    b.advance(5_000);
    try b.recorder.flush();
    try testing.expectEqual(1, b.fake.pointCount());
}

test "stop: the last write waits out a series' floor, or skips it" {
    {
        var b: Bench = undefined;
        try b.init(.{});
        defer b.deinit();
        var arena: std.heap.ArenaAllocator = .init(testing.allocator);
        defer arena.deinit();
        const c = try b.recorder.counter(.{ .name = "orders" });
        c.add(&.{}, 1);
        try b.recorder.flush();
        b.advance(2_000);
        c.add(&.{}, 1);
        b.recorder.stop();
        try b.recorder.run();
        // 5 s from the first end, less the 2 s gone.
        try testing.expectEqual(1, b.clock.sleep_count);
        try testing.expectEqual(3_000, b.clock.sleepMs(0));
        const p = try b.points(arena.allocator(), "orders", &.{});
        try testing.expectEqual(2, p.len);
        try testing.expectEqual(2, p[1].value.int64);
        // A recorder runs once.
        try testing.expectError(error.InvalidOptions, b.recorder.run());
    }
    {
        var b: Bench = undefined;
        try b.init(.{ .last_write = .skip });
        defer b.deinit();
        var arena: std.heap.ArenaAllocator = .init(testing.allocator);
        defer arena.deinit();
        const c = try b.recorder.counter(.{ .name = "orders" });
        const fresh = try b.recorder.counter(.{ .name = "fresh" });
        c.add(&.{}, 1);
        try b.recorder.flush();
        b.advance(2_000);
        c.add(&.{}, 1);
        fresh.add(&.{}, 5);
        b.recorder.stop();
        try b.recorder.run();
        try testing.expectEqual(0, b.clock.sleep_count);
        try testing.expectEqual(1, (try b.points(arena.allocator(), "orders", &.{})).len);
        try testing.expectEqual(5, (try b.points(arena.allocator(), "fresh", &.{}))[0].value.int64);
    }
}

const Polled = struct {
    recorder: *Recorder,
    reports: []const i64,
    at: usize = 0,
    saw_stats: bool = false,

    fn observer(self: *Polled) Observer {
        return .{ .context = self, .report = report };
    }

    fn report(context: *anyopaque, into: *Report) void {
        const self: *Polled = @ptrCast(@alignCast(context));
        // Called outside the recorder's lock, so this would deadlock inside.
        _ = self.recorder.stats();
        self.saw_stats = true;
        into.int64(&.{"orders"}, self.reports[self.at]);
        self.at += 1;
    }
};

test "observers: read outside the lock at each write; a falling total starts the series over" {
    var b: Bench = undefined;
    try b.init(.{});
    defer b.deinit();
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    var polled: Polled = .{ .recorder = &b.recorder, .reports = &.{ 10, 12, 3 } };
    const started: std.Io.Timestamp = .{ .nanoseconds = t0_ns - 60 * std.time.ns_per_s };
    try b.recorder.observe(.{ .name = "pulled", .label_keys = &.{"queue"} }, .cumulative, started, polled.observer());
    try b.recorder.flush();
    b.advance(5_000);
    try b.recorder.flush();
    b.advance(5_000);
    try b.recorder.flush();
    try testing.expect(polled.saw_stats);
    const p = try b.points(arena.allocator(), "pulled", &.{.{ .key = "queue", .value = "orders" }});
    try testing.expectEqual(3, p.len);
    try testing.expectEqual(started.nanoseconds, p[0].start.?.nanoseconds);
    try testing.expectEqual(12, p[1].value.int64);
    // 3 after 12: a reset, started 1 ms after the last end.
    try testing.expectEqual(p[1].end.nanoseconds + std.time.ns_per_ms, p[2].start.?.nanoseconds);
    try testing.expectEqual(3, p[2].value.int64);
    try testing.expectEqual(0, b.recorder.stats().points_refused);
}

const Mixed = struct {
    fn report(_: *anyopaque, into: *Report) void {
        into.double(&.{}, 1.5);
        into.int64(&.{}, 2);
        into.double(&.{ "too", "many" }, 1);
    }
};

test "observers: a gauge observer, one type at a time, and observe's checks" {
    var b: Bench = undefined;
    try b.init(.{});
    defer b.deinit();
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    var unused: u8 = 0;
    try b.recorder.observe(.{ .name = "mixed" }, .gauge, null, .{ .context = &unused, .report = Mixed.report });
    try b.recorder.flush();
    try testing.expectEqual(1.5, (try b.points(arena.allocator(), "mixed", &.{}))[0].value.double);
    try testing.expectEqual(2, b.recorder.stats().recordings_dropped);
    try testing.expectError(error.InvalidOptions, b.recorder.observe(.{ .name = "d" }, .delta, null, .{ .context = &unused, .report = Mixed.report }));
}

test "declaring: names, labels and units checked; the same instrument again is the one declared" {
    var b: Bench = undefined;
    try b.init(.{});
    defer b.deinit();
    const r = &b.recorder;
    const first = try r.counter(.{ .name = "a", .label_keys = &.{"k"} });
    const again = try r.counter(.{ .name = "a", .label_keys = &.{"k"} });
    try testing.expectEqual(first.index, again.index);
    try testing.expectError(error.InvalidOptions, r.gauge(.{ .name = "a", .label_keys = &.{"k"} }, .int64));
    try testing.expectError(error.InvalidOptions, r.counter(.{ .name = "a", .label_keys = &.{"j"} }));
    try testing.expectError(error.InvalidMetricType, r.counter(.{ .name = "a b" }));
    try testing.expectError(error.InvalidMetricType, r.counter(.{ .name = test_util.repeat("x", 512) }));
    try testing.expectError(error.InvalidLabel, r.counter(.{ .name = "b", .label_keys = &.{"1k"} }));
    try testing.expectError(error.InvalidLabel, r.counter(.{ .name = "b", .label_keys = &.{ "k", "k" } }));
    var keys: [31][]const u8 = @splat("k");
    try testing.expectError(error.InvalidLabel, r.counter(.{ .name = "b", .label_keys = &keys }));
    try testing.expectError(error.InvalidOptions, r.counter(.{ .name = "b", .unit = "a b" }));
    try testing.expectError(error.InvalidOptions, r.histogram(.{ .name = "h" }, .{ .explicit = &.{} }));
}

test "init refuses what no write could use" {
    var token: core.StaticToken = .{ .token = "t" };
    var diag: Diagnostics = .{};
    const client: Client.Options = .{ .project_id = "p", .token_provider = token.provider(), .diagnostics = &diag };
    try testing.expectError(error.InvalidOptions, Recorder.init(testing.allocator, testing.io, .{ .client = client, .resource = task, .interval_ms = 4_999 }));
    try testing.expectEqualStrings("invalid interval: at least 5000 ms, the floor Google documents per series", diag.message());
    try testing.expectError(error.InvalidMetricType, Recorder.init(testing.allocator, testing.io, .{ .client = client, .resource = task, .prefix = "a b" }));
    try testing.expectError(error.InvalidResource, Recorder.init(testing.allocator, testing.io, .{ .client = client, .resource = .{ .other = .{ .type = "a/b" } } }));
    try testing.expectError(error.InvalidOptions, Recorder.init(testing.allocator, testing.io, .{ .client = client, .resource = task, .max_series = 0 }));
    try testing.expectError(error.InvalidName, Recorder.init(testing.allocator, testing.io, .{ .client = .{ .project_id = "Bad", .token_provider = token.provider() }, .resource = task }));
    // Every resource type copies.
    for ([_]types.Resource{ .global, .{ .other = .{ .type = "aws_ec2_instance", .labels = &.{.{ .key = "region", .value = "aws:us-east-1" }} } }, task }) |r| {
        var rec = try Recorder.init(testing.allocator, testing.io, .{ .client = .{ .project_id = "p", .token_provider = token.provider() }, .resource = r });
        rec.deinit();
    }
}

test "run: writes each interval until stop, on its own task" {
    // Real time, made short: the interval is set below what init allows.
    const io = testing.io;
    var fake: FakeMonitoring = .init(testing.allocator, io, .{});
    defer fake.deinit();
    var token: core.StaticToken = .{ .token = "t" };
    var recorder = try Recorder.init(testing.allocator, io, .{
        .client = .{ .project_id = "my-project", .token_provider = token.provider(), .transport = fake.transport() },
        .resource = task,
        .descriptors = .auto,
        .last_write = .skip,
    });
    defer recorder.deinit();
    recorder.interval_ns = 20 * std.time.ns_per_ms;
    const c = try recorder.counter(.{ .name = "ticks", .label_keys = &.{"n"} });
    var running = try io.concurrent(run, .{&recorder});
    var buf: [8]u8 = undefined;
    for (0..5) |i| {
        // A new series each time, so each write has one due.
        c.add(&.{try std.fmt.bufPrint(&buf, "{d}", .{i})}, 1);
        try io.sleep(.fromMilliseconds(30), .awake);
    }
    recorder.stop();
    try running.await(io);
    const s = recorder.stats();
    try testing.expect(s.requests >= 2);
    try testing.expectEqual(0, s.points_refused);
    try testing.expectEqual(5, fake.pointCount());
}

fn allocationCycle(gpa: Allocator) !Stats {
    var clock: test_util.FakeClock = .{ .now_ns = t0_ns };
    var fake: FakeMonitoring = .init(testing.allocator, clock.io(), .{});
    defer fake.deinit();
    var token: core.StaticToken = .{ .token = "t" };
    var recorder = try Recorder.init(gpa, clock.io(), .{
        .client = .{ .project_id = "my-project", .token_provider = token.provider(), .transport = fake.transport() },
        .resource = task,
    });
    defer recorder.deinit();
    const c = try recorder.counter(.{ .name = "c", .label_keys = &.{"k"} });
    const h = try recorder.histogram(.{ .name = "h" }, .{ .explicit = &.{ 1, 2 } });
    var watched: Watched = .{ .total = 4 };
    try recorder.observe(.{ .name = "o" }, .cumulative, null, watched.observer());
    c.add(&.{"v"}, 1);
    h.record(&.{}, 1.5);
    try recorder.flush();
    return recorder.stats();
}

test "every allocation failure: init and declaring fail with OutOfMemory, recording and writing go without, no leaks" {
    // Recording and writing swallow short memory by design, so std's
    // checker, which wants it returned, does not fit: each allocation fails
    // in turn instead, and the leak checker underneath watches.
    var counting: std.testing.FailingAllocator = .init(testing.allocator, .{});
    const whole = try allocationCycle(counting.allocator());
    try testing.expectEqual(3, whole.points_written);
    for (0..counting.alloc_index) |i| {
        var failing: std.testing.FailingAllocator = .init(testing.allocator, .{ .fail_index = i });
        if (allocationCycle(failing.allocator())) |s| {
            try testing.expect(s.points_written <= 3);
        } else |err| try testing.expectEqual(error.OutOfMemory, err);
    }
}

/// The total a counter's series holds now, for tests.
fn totalOf(self: *Recorder, index: u32, label_values: []const []const u8) ?u64 {
    self.mutex.lockUncancelable(self.io);
    defer self.mutex.unlock(self.io);
    const s = self.series.getAdapted(SeriesKey{ .instrument = index, .values = label_values }, KeyContext{}) orelse return null;
    return s.state.total;
}

test "recording from several tasks while run writes: no count lost" {
    const io = testing.io;
    var fake: FakeMonitoring = .init(testing.allocator, io, .{});
    defer fake.deinit();
    var token: core.StaticToken = .{ .token = "t" };
    var recorder = try Recorder.init(testing.allocator, io, .{
        .client = .{ .project_id = "my-project", .token_provider = token.provider(), .transport = fake.transport() },
        .resource = task,
        .descriptors = .auto,
        .last_write = .skip,
    });
    defer recorder.deinit();
    recorder.interval_ns = 5 * std.time.ns_per_ms;
    const c = try recorder.counter(.{ .name = "hits", .label_keys = &.{"k"} });
    const h = try recorder.histogram(.{ .name = "sizes", .label_keys = &.{"k"} }, .{ .explicit = &.{ 1, 10 } });
    var running = try io.concurrent(run, .{&recorder});
    const Worker = struct {
        fn work(counter_: Counter, hist: Histogram, which: []const u8) void {
            for (0..2_000) |i| {
                counter_.add(&.{which}, 1);
                hist.record(&.{which}, @floatFromInt(i % 20));
            }
        }
    };
    var group: std.Io.Group = .init;
    for ([_][]const u8{ "a", "b", "a", "b" }) |which| try group.concurrent(io, Worker.work, .{ c, h, which });
    try group.await(io);
    recorder.stop();
    try running.await(io);
    try testing.expectEqual(4_000, recorder.totalOf(c.index, &.{"a"}).?);
    try testing.expectEqual(4_000, recorder.totalOf(c.index, &.{"b"}).?);
    recorder.mutex.lockUncancelable(io);
    defer recorder.mutex.unlock(io);
    const hs = recorder.series.getAdapted(SeriesKey{ .instrument = h.index, .values = &.{"a"} }, KeyContext{}).?;
    try testing.expectEqual(4_000, hs.state.histogram.count);
    var sum: u64 = 0;
    for (hs.state.histogram.counts) |n| sum += n;
    try testing.expectEqual(4_000, sum);
}

/// A cumulative observer whose total the property sets.
const Watched = struct {
    total: i64 = 0,

    fn observer(self: *Watched) Observer {
        return .{ .context = self, .report = report };
    }

    fn report(context: *anyopaque, into: *Report) void {
        const self: *Watched = @ptrCast(@alignCast(context));
        into.int64(&.{}, self.total);
    }
};

/// Random recordings, clock moves (some backwards), writes and failed
/// requests, then a stop: the fake, which holds each series to production's
/// rules, refuses no point, and what it holds last is what was recorded.
fn recorderProperty(_: void, input: []const u8) !void {
    const gpa = test_util.propertyAllocator();
    var g: test_util.ByteGen = .init(input);
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    const a = arena.allocator();
    var clock: test_util.FakeClock = .{ .now_ns = t0_ns };
    var fake: FakeMonitoring = .init(gpa, clock.io(), .{});
    defer fake.deinit();
    var token: core.StaticToken = .{ .token = "t" };
    var recorder = try Recorder.init(gpa, clock.io(), .{
        .client = .{ .project_id = "my-project", .token_provider = token.provider(), .transport = fake.transport(), .retry = .{ .max_attempts = 2, .initial_backoff_ms = 1, .max_backoff_ms = 1 } },
        .resource = task,
        .descriptors = if (g.boolean()) .auto else .create_if_missing,
        .max_series = g.intRange(u32, 1, 12),
    });
    defer recorder.deinit();
    const c = try recorder.counter(.{ .name = "c", .label_keys = &.{"k"} });
    const gg = try recorder.gauge(.{ .name = "g", .label_keys = &.{"k"} }, .int64);
    const h = try recorder.histogram(.{ .name = "h" }, .{ .linear = .{ .num_finite = 3, .width = 2, .offset = 0 } });
    var watched: Watched = .{};
    try recorder.observe(.{ .name = "o" }, .cumulative, null, watched.observer());

    var counter_model: [3]u64 = @splat(0);
    var gauge_model: [3]?i64 = @splat(null);
    var hist_count: u64 = 0;
    const keys = [_][]const u8{ "x", "y", "z" };
    // The furthest the clock got, by a step or by a retry's backoff in a
    // flush: a series written then is due at the stop only if the clock is
    // back there.
    var furthest = clock.now_ns;
    const steps = g.intRange(usize, 1, 40);
    for (0..steps) |_| switch (g.intRange(u8, 0, 9)) {
        0, 1 => {
            const k = g.intRange(usize, 0, 2);
            const n = g.intRange(u64, 0, 1_000);
            c.add(&.{keys[k]}, n);
            counter_model[k] += n;
        },
        2 => {
            const k = g.intRange(usize, 0, 2);
            const v: i64 = @bitCast(g.int(u64));
            gg.set(&.{keys[k]}, .{ .int64 = v });
            gauge_model[k] = v;
        },
        3 => {
            h.record(&.{}, @floatFromInt(g.intRange(u8, 0, 12)));
            hist_count += 1;
        },
        4 => watched.total = if (g.intRange(u8, 0, 4) == 0) 0 else watched.total + @as(i64, g.intRange(u8, 0, 50)),
        5, 6 => {
            clock.now_ns += @as(i96, g.intRange(u16, 0, 12_000)) * std.time.ns_per_ms;
            furthest = @max(furthest, clock.now_ns);
        },
        7 => clock.now_ns -= @as(i96, g.intRange(u16, 0, 3_000)) * std.time.ns_per_ms,
        8 => {
            try recorder.flush();
            furthest = @max(furthest, clock.now_ns);
        },
        else => switch (g.intRange(u8, 0, 2)) {
            0 => fake.refuseNext(g.intRange(usize, 1, 3), 503),
            1 => fake.dropNext(g.intRange(usize, 1, 3)),
            else => fake.loseNext(g.intRange(usize, 1, 3), 504),
        },
    };
    // A last write that nothing fails.
    fake.refuseNext(0, 503);
    fake.dropNext(0);
    fake.loseNext(0, 504);
    const caught_up = clock.now_ns >= furthest;
    recorder.stop();
    try recorder.run();
    const s = recorder.stats();
    try testing.expectEqual(0, s.points_refused);
    // After the clock stepped back, waiting 5 s at the stop may leave a
    // series under the floor, and it is left out: only the counts hold.
    for (keys, counter_model) |k, total| if (recorder.totalOf(c.index, &.{k})) |held| try testing.expectEqual(total, held);
    if (!caught_up) return;

    // Every series the recorder holds was written last with what it holds.
    for (keys, counter_model, gauge_model) |k, total, last| {
        const labels: []const types.Label = &.{.{ .key = "k", .value = k }};
        if (recorder.totalOf(c.index, &.{k})) |held| {
            try testing.expectEqual(total, held);
            const p = try fake.points(a, "custom.googleapis.com/c", labels);
            try testing.expect(p.len > 0);
            try testing.expectEqual(@as(i64, @intCast(total)), p[p.len - 1].value.int64);
        }
        if (last) |v| {
            const p = try fake.points(a, "custom.googleapis.com/g", labels);
            if (p.len > 0) try testing.expectEqual(v, p[p.len - 1].value.int64);
        }
    }
    const hp = try fake.points(a, "custom.googleapis.com/h", &.{});
    if (hp.len > 0 and s.recordings_dropped == 0) try testing.expectEqual(hist_count, hp[hp.len - 1].value.distribution.count);
    const op = try fake.points(a, "custom.googleapis.com/o", &.{});
    if (op.len > 0) try testing.expectEqual(watched.total, op[op.len - 1].value.int64);
    // The series the fake holds are the recorder's.
    try testing.expect(fake.seriesCount() <= s.series);
}

test "slow property Recorder: the fake refuses no point, and holds last what was recorded" {
    try test_util.fuzzBytes({}, recorderProperty, .{ .corpus = &.{
        "",
        "\x00\x05\x00\x03\x08\x05\x0a\x08\x00\x01\x02\x07\x08",
        "\x01\x09\x09\x08\x05\x05\x08\x02\x00\x02\x03\x04\x08\x06\x08",
        backoff_past_furthest_histogram,
        backoff_past_furthest_gauges,
    } });
}

/// Fuzz-found, two nights running: a retry's 1 ms backoff in a flush took
/// the clock past the furthest the steps had, the clock stepped back to
/// that, and the stop's wait of at most 5 s fell 1 ms short, so the
/// histogram here, and the gauges in the next, were rightly left out.
const backoff_past_furthest_histogram = "\x0e\x2e\x00\xb4\xf3\x05\xa9\xa1\x0a\xfb\xc4\x68\x23\x67\x51\x5e\x1b\x20\x53\xc1\x92\x19\x5d\xca\x86\x0f\xf1\x43\x6e\xc0\x82\xef\x19\xdc\x47\x9d\x9c\x82\x82\x53\x5d\x2b\x63\x3f\x56\x5d\xef\x2a\xa3\x8f\x30\x5e\xb2\xd5\x8a\x43\x75\x3b\xbf\x84\x71\xad\x33\x95\xb4\xd2\x61\x12\xa4\x65\x5e\x13\xae\xb3\xf6\x70\x5e\x55\x77\x89\x96\x2d\xb7\xa4\x91\xfd\x08\x3c\x57\x36\x98\x2e";
const backoff_past_furthest_gauges = "\xe2\x6b\x0d\x5b\x8b\xe9\xd1\xc7\x54\x48\x39\xe7\x9b\x53\xd1\x48\x88\x37\x2d\xf3\x8a\x68\x20\x69\xb6\x24\x7e\x37\x1e\x2a\x8f\x4e\x11\x01\x35\xc9\x5a\x0d\xff\x14\xf4\x79\xe9\xe2\x18\xe1\x2c\xfa\x50\xe3\x00\xc8\x36\x00\xb7\x50\xde\xd7\x21\xc6\xf5\x50\x4f\x97\x1a\xe5\xee\x7e\xa9\x1d\x6c\xc3\xe9\x2f\xf2\x79\x22\x04\xcc\xc7\x93\xb3\x69\x01\x34\xca\x91\x65\xb3\x20\x5b\x8d\x60\x0c\xbb\xf9\x24\xfe\x9e\x3d\xaa\x7e\xf8\x30\x02\x4c\xea\x0e\xe2\x7a\x8b\x8a\x70\xfa\xd3\x54\xc6\xf3\xb0\x38\x1e\x50\x39\x4a\x2c\x75\x4a\x72\x00\x80\xe7\x66\x55\xb4\x8c\xcf\x13\x5f\xe7\x5e\xe8\x2c\xe0\x8c\x46\x22\x7a\xd4\x2d\x42\xaf\x27\x48\x96\x05\x3b\x6f\x82\x55\x3e\x37\xfd\x94\x61\xdb\x75\x59\xe6\xd1\xc4\x22\x61\x98\x8c\xc3\x34\x00\x30\x39\x0f\x35\x8f\x69\x16\xf2\x21\xc8\x78\x74\x2b\x54\x7b\x3a\xdd\xe4\x30\xd9\x1a\x38\x0f\x37\x88\xc9\x84\x30\xf0\xab\xc6\xe3\x3c\x33\x90\xbf\xf5\x50\xb9\x2b\xf9\xe4\x8f\x1f\xac\xa0\x84\xcf\xc1\x8a\x79\xa3\x5a\x19\x06\x24\xed\xfb\xd9\xed\x59\x7c\xf1\xd1\x75\x87\xf8\xd6\xf7\x9a\x18\xbe\x4f\x1d\xa5\x54\xb8\x5d\xfa\x80\xc1\x5f\x66\xce\x6a\xe0\x0a\xdc\x88\x39\x0c\xc6\xa3\x7b\xf2\x52\xc8\xb3\x8d\x16\x4f\x7d\x0a\x89\x87\x8d\x16\xab\x90\xde\xb0\x6d\x7c\xdb\x1b\xc8\x05\x0f\x21\xee\x2c\x0b\x8d\x40\x13\xe8\x7f\x2e\xe5";

const Seconds = struct {
    reports: []const f64,
    at: usize = 0,

    fn report(context: *anyopaque, into: *Report) void {
        const self: *Seconds = @ptrCast(@alignCast(context));
        into.double(&.{}, self.reports[self.at]);
        self.at += 1;
    }
};

test "observers: a cumulative double, and its reset" {
    var b: Bench = undefined;
    try b.init(.{});
    defer b.deinit();
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    var seconds: Seconds = .{ .reports = &.{ 1.5, 0.25 } };
    try b.recorder.observe(.{ .name = "busy", .unit = "s" }, .cumulative, .{ .nanoseconds = t0_ns - std.time.ns_per_s }, .{ .context = &seconds, .report = Seconds.report });
    try b.recorder.flush();
    b.advance(5_000);
    try b.recorder.flush();
    const p = try b.points(arena.allocator(), "busy", &.{});
    try testing.expectEqual(2, p.len);
    try testing.expectEqual(1.5, p[0].value.double);
    try testing.expectEqual(0.25, p[1].value.double);
    try testing.expectEqual(p[0].end.nanoseconds + std.time.ns_per_ms, p[1].start.?.nanoseconds);
}

test "descriptors: a create that meets another writer's descriptor reads it again" {
    const Case = struct { []const u8, bool };
    for ([_]Case{
        .{ "{\"type\":\"custom.googleapis.com/met\",\"metricKind\":\"CUMULATIVE\",\"valueType\":\"INT64\"}", true },
        .{ "{\"type\":\"custom.googleapis.com/met\",\"metricKind\":\"GAUGE\",\"valueType\":\"INT64\"}", false },
    }) |c| {
        var clock: test_util.FakeClock = .{ .now_ns = t0_ns };
        var fake: test_util.FakeTransport = .init(testing.allocator, &.{
            .{ .respond = .{ .status = 404, .body = "{\"error\":{\"code\":404,\"status\":\"NOT_FOUND\"}}" } },
            .{ .respond = .{ .status = 409, .body = "{\"error\":{\"code\":409,\"status\":\"ALREADY_EXISTS\"}}" } },
            .{ .respond = .{ .body = c[0] } },
            .{ .respond = .{ .body = "{}" } },
        });
        defer fake.deinit();
        var token: core.StaticToken = .{ .token = "t" };
        var recorder = try Recorder.init(testing.allocator, clock.io(), .{
            .client = .{ .project_id = "my-project", .token_provider = token.provider(), .transport = fake.transport() },
            .resource = task,
        });
        defer recorder.deinit();
        const counter_ = try recorder.counter(.{ .name = "met" });
        counter_.add(&.{}, 1);
        try recorder.flush();
        const s = recorder.stats();
        try testing.expectEqual(@as(u64, if (c[1]) 1 else 0), s.points_written);
        try testing.expectEqual(@as(u32, if (c[1]) 0 else 1), s.descriptor_failures);
        try testing.expectEqual(@as(usize, if (c[1]) 4 else 3), fake.requests.items.len);
    }
}

test "run: canceled, it returns Canceled" {
    const io = testing.io;
    var fake: FakeMonitoring = .init(testing.allocator, io, .{});
    defer fake.deinit();
    var token: core.StaticToken = .{ .token = "t" };
    var recorder = try Recorder.init(testing.allocator, io, .{
        .client = .{ .project_id = "my-project", .token_provider = token.provider(), .transport = fake.transport() },
        .resource = task,
    });
    defer recorder.deinit();
    var running = try io.concurrent(run, .{&recorder});
    try testing.expectError(error.Canceled, running.cancel(io));
}
