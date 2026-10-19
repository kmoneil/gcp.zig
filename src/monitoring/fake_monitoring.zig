//! Cloud Monitoring for tests, behind the `Transport` seam: metric
//! descriptors, monitored resource types and written points, held to the
//! rules production enforced when measured on 2026-10-18 (milestone 0 of
//! the Monitoring spec, `_tmp/monitoring-m0/`; the answers are kept
//! verbatim in `production_bodies.zig`, and tests hold this fake's
//! refusals to them). It parses requests with code of its own, so a
//! request this library builds wrong is refused here as production would
//! refuse it.
//!
//! What it models:
//!
//! - Descriptors: created, read, listed by prefix, deleted. A create of an
//!   existing type with the same kind and value type answers it, with
//!   another is 409. A first write creates one, GAUGE and its value's type
//!   unless the write says otherwise, its labels strings; a write with a
//!   label the descriptor lacks adds it. DELTA and STRING are refused for
//!   any metric a program makes, as production refused them under
//!   `custom.googleapis.com/`, `workload.googleapis.com/` and
//!   `external.googleapis.com/`.
//! - Writes judged point by point, the refused ones in a
//!   `CreateTimeSeriesSummary` at HTTP 400 with the first one's reason, as
//!   production answered: out of order; under 2.5 s after the series' last
//!   point (`FAILED_PRECONDITION`); a duplicate in the request; a gauge
//!   whose start is not its end; a non-gauge whose start is not before its
//!   end; more than 5 minutes ahead or 25h10s back; a kind or value type
//!   the descriptor does not take; a resource without its labels, or in a
//!   location that is not a region or zone; label keys, label values and
//!   strings past their limits, more than 30 labels; a distribution whose
//!   counts do not add up, or of linear width 0; a cumulative start moved
//!   earlier; a user metric on one of Pub/Sub's resource types, though
//!   its descriptor is made. A reset, a start 1 ms or more after the
//!   series' last end, is taken, and so is a total that falls under the
//!   same start, and the series' last point sent again as it was, kept
//!   once; with another value it is too soon after itself.
//! - Requests refused whole, as production refused them: none or more than
//!   200 series, a resource `project_id` naming another project, a
//!   descriptor production would not create, one of Google's metrics
//!   (403, as is a create of one).
//! - Times kept to the microsecond, as production keeps them.
//! - Reads: its own reading of the filter the client writes, (start, end],
//!   a resource type or label the metric cannot be on refused; the gauge
//!   aligners, and on DELTA metrics ALIGN_DELTA and ALIGN_SUM (a period's
//!   total over the period), ALIGN_RATE (a second) and min, max, mean and
//!   count, the aligners production refused on each kind refused in its
//!   words; the reducers min, max, mean, sum and count and group-by fields;
//!   the unit as production gave it, `1` for a count and a second for a
//!   rate.
//! - Google's own metrics: the nine of Pub/Sub's a console reads (issue
//!   #239), their descriptors as production gave them, there from the
//!   start, on the resource types `pubsub_subscription` and `pubsub_topic`.
//!   No program writes or creates one, as production answered; `put` puts
//!   their points in, as it does any series a program could not write.
//! - Faults a test asks for, and a write served and then answered with an
//!   error, as a 504 that stored the points is.
//!
//! Where it differs: times in its messages are UTC, where production wrote
//! US Pacific; a descriptor just made reads back at once, where production
//! answered 404 for about 2 s, once for more than 15 s; its resource
//! types are the seven `Resource` names and Pub/Sub's two, only
//! generic_task's and Pub/Sub's text production's; nothing put in
//! arrives late, where production showed a minute's counts about 130 s
//! after it. Not modelled, each
//! answered 501 with the reason: another project, a cumulative start
//! moved later but inside the series' last interval (production took one,
//! and the earlier point vanished), distribution rules production was not
//! asked about, more than one point in a series, deleting one of Google's
//! metrics, and filters other than a type prefix.

const std = @import("std");
const Allocator = std.mem.Allocator;
const Stringify = std.json.Stringify;
const JsonValue = std.json.Value;
const core = @import("core");
const tp = core.transport;
const types = @import("types.zig");
const validate = @import("validate.zig");

pub const FakeMonitoring = struct {
    gpa: Allocator,
    io: std.Io,
    mutex: std.Io.Mutex = .init,
    options: Options,
    /// Strings, descriptors, series and points, freed with the fake.
    store: std.heap.ArenaAllocator,
    descriptors: std.StringArrayHashMapUnmanaged(*Descriptor) = .empty,
    /// By identity: metric type and labels, resource type and labels.
    series: std.StringArrayHashMapUnmanaged(*Series) = .empty,
    faults: [3]Fault = .{ .{}, .{}, .{} },
    calls: usize = 0,
    /// Whether Google's own descriptors are in `descriptors`: they go in
    /// at the first call, since `init` cannot fail.
    google_loaded: bool = false,

    const Fault = struct { n: usize = 0, status: u16 = 0, delay: ?core.retry_after.Asked = null };
    const refuse = 0;
    const drop = 1;
    const lose = 2;

    /// Production refused a point less than 2.5 s after its series' last,
    /// and took one 2.5 s after it, where Google documents 5 s.
    pub const min_gap_ns: i96 = 2500 * std.time.ns_per_ms;
    /// Production refused a point more than 5 minutes ahead.
    pub const max_ahead_ns: i96 = 5 * std.time.ns_per_min;
    /// "no more than 25h10s in the past".
    pub const max_back_ns: i96 = (25 * std.time.s_per_hour + 10) * std.time.ns_per_s;

    pub const Options = struct {
        /// The project it answers for, by id.
        project_id: []const u8 = "my-project",
    };

    pub const Reply = struct { status: u16, headers: []const tp.Header = &.{}, body: []const u8 };

    /// A point as the fake keeps it.
    pub const Point = struct {
        /// Null for a gauge.
        start: ?std.Io.Timestamp,
        end: std.Io.Timestamp,
        value: types.Value,
    };

    const Descriptor = struct {
        type: []const u8,
        kind: types.Kind,
        value_type: types.ValueType,
        unit: []const u8 = "",
        description: []const u8 = "",
        display_name: []const u8 = "",
        labels: std.ArrayList(types.LabelDescriptor) = .empty,
        /// Null for a user metric; for one of Google's own, which no
        /// program writes, creates or deletes, its entry.
        google: ?*const GoogleMetric = null,
    };

    const Series = struct {
        metric_type: []const u8,
        /// Sorted by key.
        metric_labels: []const types.Label,
        resource_type: []const u8,
        /// Sorted by key, `project_id` left out.
        resource_labels: []const types.Label,
        kind: types.Kind,
        value_type: types.ValueType,
        /// Oldest first.
        points: std.ArrayList(Point) = .empty,
    };

    pub fn init(gpa: Allocator, io: std.Io, options: Options) FakeMonitoring {
        return .{ .gpa = gpa, .io = io, .options = options, .store = .init(gpa) };
    }

    pub fn deinit(f: *FakeMonitoring) void {
        f.descriptors.deinit(f.gpa);
        f.series.deinit(f.gpa);
        f.store.deinit();
        f.* = undefined;
    }

    /// Goes into `Client.Options.transport`.
    pub fn transport(f: *FakeMonitoring) tp.Transport {
        return .{ .ptr = f, .vtable = &.{ .send = send } };
    }

    fn nowNs(f: *const FakeMonitoring) i96 {
        return std.Io.Clock.real.now(f.io).nanoseconds;
    }

    // Faults, each for the next `n` calls.

    /// Answers them with `status`, and changes nothing.
    pub fn refuseNext(f: *FakeMonitoring, n: usize, status: u16) void {
        f.setFault(refuse, .{ .n = n, .status = status });
    }

    /// Answers them as `refuseNext` does, and asks the client to wait
    /// `delay.ms` before trying again, in `delay.form`.
    pub fn refuseNextWithDelay(f: *FakeMonitoring, n: usize, status: u16, delay: core.retry_after.Asked) void {
        f.setFault(refuse, .{ .n = n, .status = status, .delay = delay });
    }

    /// Closes their connection before any answer.
    pub fn dropNext(f: *FakeMonitoring, n: usize) void {
        f.setFault(drop, .{ .n = n });
    }

    /// Serves them, so what they write is kept, and answers `status`
    /// instead of what was done, as a 504 can after storing a write.
    pub fn loseNext(f: *FakeMonitoring, n: usize, status: u16) void {
        f.setFault(lose, .{ .n = n, .status = status });
    }

    fn setFault(f: *FakeMonitoring, slot: usize, fault: Fault) void {
        f.mutex.lockUncancelable(f.io);
        defer f.mutex.unlock(f.io);
        f.faults[slot] = fault;
    }

    fn takeFault(f: *FakeMonitoring, slot: usize) ?Fault {
        const fault = &f.faults[slot];
        if (fault.n == 0) return null;
        fault.n -= 1;
        return fault.*;
    }

    // What a test reads.

    /// Calls served, refusals included.
    pub fn callCount(f: *FakeMonitoring) usize {
        f.mutex.lockUncancelable(f.io);
        defer f.mutex.unlock(f.io);
        return f.calls;
    }

    /// Series with at least one point.
    pub fn seriesCount(f: *FakeMonitoring) usize {
        f.mutex.lockUncancelable(f.io);
        defer f.mutex.unlock(f.io);
        return f.series.count();
    }

    /// Points kept, across every series.
    pub fn pointCount(f: *FakeMonitoring) usize {
        f.mutex.lockUncancelable(f.io);
        defer f.mutex.unlock(f.io);
        var n: usize = 0;
        for (f.series.values()) |s| n += s.points.items.len;
        return n;
    }

    /// The points of the series of `metric_type` with exactly
    /// `metric_labels`, in any order, on any resource, oldest first,
    /// copied into `arena`; empty when there is none. Where several
    /// resources have one, the first written.
    pub fn points(f: *FakeMonitoring, arena: Allocator, metric_type: []const u8, metric_labels: []const types.Label) Allocator.Error![]const Point {
        f.mutex.lockUncancelable(f.io);
        defer f.mutex.unlock(f.io);
        const sorted = try sortedLabels(arena, metric_labels);
        for (f.series.values()) |s| {
            if (!std.mem.eql(u8, s.metric_type, metric_type) or !labelsEqual(s.metric_labels, sorted)) continue;
            const out = try arena.alloc(Point, s.points.items.len);
            for (s.points.items, out) |p, *o| o.* = .{ .start = p.start, .end = p.end, .value = try copyValue(arena, p.value) };
            return out;
        }
        return &.{};
    }

    /// The descriptor of `metric_type`, copied into `arena`, or null.
    pub fn descriptor(f: *FakeMonitoring, arena: Allocator, metric_type: []const u8) Allocator.Error!?types.MetricInfo {
        f.mutex.lockUncancelable(f.io);
        defer f.mutex.unlock(f.io);
        try f.loadGoogle();
        const d = f.descriptors.get(metric_type) orelse return null;
        const labels = try arena.alloc(types.LabelDescriptor, d.labels.items.len);
        for (d.labels.items, labels) |l, *o| o.* = .{ .key = try arena.dupe(u8, l.key), .value_type = l.value_type, .description = try arena.dupe(u8, l.description) };
        return .{
            .type = try arena.dupe(u8, d.type),
            .kind = d.kind,
            .value_type = d.value_type,
            .unit = try arena.dupe(u8, d.unit),
            .description = try arena.dupe(u8, d.description),
            .display_name = try arena.dupe(u8, d.display_name),
            .labels = labels,
        };
    }

    // What a test puts in.

    /// A series as production holds one, put in by a test: Google's own
    /// metrics, such as Pub/Sub's backlog, which no program can write.
    pub const PutSeries = struct {
        metric_type: []const u8,
        metric_labels: []const types.Label = &.{},
        resource_type: []const u8,
        /// Every label the resource type has. `project_id` may be left
        /// out; given, it must be the fake's project.
        resource_labels: []const types.Label = &.{},
        kind: types.Kind,
        value_type: types.ValueType,
        /// For a metric with no descriptor, which the put makes.
        unit: []const u8 = "",
        /// Oldest first.
        points: []const Point,
    };

    pub const PutError = error{ OutOfMemory, InvalidEntry };

    /// Puts points in that a program could not write: Google's own
    /// metrics, such as Pub/Sub's, or points closer together or older
    /// than a write may send. Reads see them as they see written ones. It
    /// skips the write path's rules of time (the sampling floor, 25 hours
    /// back, 5 minutes ahead) and keeps the rest. A series that exists
    /// gets the points after its own.
    ///
    /// `error.InvalidEntry`, with nothing kept, for:
    ///
    /// - a resource type the fake does not know, a label it lacks or one
    ///   missing, or another project's `project_id`;
    /// - one of Google's metrics with another kind, value type or
    ///   resource type, or a label it lacks; a user metric on a resource
    ///   type only Google's metrics are on;
    /// - another kind or value type than the metric's descriptor, or one
    ///   production would not create: DELTA or STRING for a metric not
    ///   Google's;
    /// - a metric type or label the write path refuses, a label twice;
    /// - an unknown kind; no points, a value of another type than
    ///   `value_type` (so never `.money` or `.unknown`), a gauge
    ///   whose start is not its end, a non-gauge without a start before
    ///   its end, a distribution the write path refuses;
    /// - a point that does not end after the one before it, or after the
    ///   series' last; a DELTA point that starts before the one before it
    ///   ends; a cumulative start moved earlier.
    pub fn put(f: *FakeMonitoring, series: PutSeries) PutError!void {
        f.mutex.lockUncancelable(f.io);
        defer f.mutex.unlock(f.io);
        try f.loadGoogle();
        var scratch: std.heap.ArenaAllocator = .init(f.gpa);
        defer scratch.deinit();
        if (!try f.puttable(scratch.allocator(), series)) return error.InvalidEntry;

        const st = f.store.allocator();
        const pts = try st.alloc(Point, series.points.len);
        for (series.points, pts) |p, *o| o.* = .{
            .start = if (series.kind == .gauge) null else .{ .nanoseconds = truncated(p.start.?.nanoseconds) },
            .end = .{ .nanoseconds = truncated(p.end.nanoseconds) },
            .value = try copyValue(st, p.value),
        };
        const d = f.descriptors.get(series.metric_type) orelse try f.addDescriptor(series.metric_type, series.kind, series.value_type, series.unit);
        try f.addLabels(d, series.metric_labels);
        const s = try f.seriesOf(d, series.metric_labels, series.resource_type, series.resource_labels);
        try s.points.appendSlice(st, pts);
    }

    /// Whether `put` takes `s`: each rule its doc comment lists.
    fn puttable(f: *FakeMonitoring, a: Allocator, s: PutSeries) Allocator.Error!bool {
        if (validate.metricTypeProblem(s.metric_type) != null) return false;
        const r = catalogType(s.resource_type) orelse return false;
        for (s.resource_labels, 0..) |l, i| {
            for (s.resource_labels[0..i]) |m| if (std.mem.eql(u8, l.key, m.key)) return false;
            if (std.mem.eql(u8, l.key, "project_id")) {
                if (!std.mem.eql(u8, l.value, f.options.project_id)) return false;
            } else if (!r.hasLabel(l.key)) return false;
        }
        for (r.labels) |l| {
            if (!std.mem.eql(u8, l[0], "project_id") and labelValue(s.resource_labels, l[0]) == null) return false;
        }
        if (s.metric_labels.len > validate.max_metric_labels) return false;
        for (s.metric_labels, 0..) |l, i| {
            if (!validate.isLabelKey(l.key) or l.value.len > validate.max_label_value_len) return false;
            for (s.metric_labels[0..i]) |m| if (std.mem.eql(u8, l.key, m.key)) return false;
        }
        if (s.kind == .unknown) return false;
        if (f.descriptors.get(s.metric_type)) |d| {
            if (d.kind != s.kind or d.value_type != s.value_type) return false;
            if (d.google) |g| {
                if (!std.mem.eql(u8, g.resource_type, s.resource_type)) return false;
                for (s.metric_labels) |l| if (!g.hasLabel(l.key)) return false;
            } else if (!r.writable) return false;
        } else {
            if (!r.writable or googleDomain(s.metric_type)) return false;
            if (try creationRefusal(a, s.metric_type, s.kind, s.value_type, &.{}) != null) return false;
        }
        if (s.points.len == 0) return false;

        var last_end: ?i96 = null;
        var last_start: ?i96 = null;
        if (f.series.get(try identityOf(a, s.metric_type, s.metric_labels, s.resource_type, s.resource_labels))) |existing| {
            const last = existing.points.items[existing.points.items.len - 1];
            last_end = last.end.nanoseconds;
            if (last.start) |t| last_start = t.nanoseconds;
        }
        for (s.points) |p| {
            if (p.value.valueType() != s.value_type) return false;
            // None is a string: production makes no STRING metric for a
            // program, and Google's here are numbers.
            switch (p.value) {
                .distribution => |dist| if (validate.distributionProblem(dist) != null) return false,
                else => {},
            }
            const end = truncated(p.end.nanoseconds);
            if (s.kind == .gauge) {
                if (p.start) |t| if (truncated(t.nanoseconds) != end) return false;
            } else {
                const start = truncated((p.start orelse return false).nanoseconds);
                if (start >= end) return false;
                switch (s.kind) {
                    .delta => if (last_end) |e| if (start < e) return false,
                    else => if (last_start) |e| if (start < e) return false,
                }
                last_start = start;
            }
            if (last_end) |e| if (end <= e) return false;
            last_end = end;
        }
        return true;
    }

    /// Puts Google's own descriptors in `descriptors`, once.
    fn loadGoogle(f: *FakeMonitoring) Allocator.Error!void {
        if (f.google_loaded) return;
        const s = f.store.allocator();
        for (&google_metrics) |*g| {
            if (f.descriptors.contains(g.type)) continue;
            const d = try s.create(Descriptor);
            d.* = .{ .type = g.type, .kind = g.kind, .value_type = g.value_type, .unit = g.unit, .description = g.description, .display_name = g.display_name, .google = g };
            try d.labels.ensureTotalCapacity(s, g.labels.len);
            for (g.labels) |l| d.labels.appendAssumeCapacity(.{ .key = l[0], .description = l[1] });
            try f.descriptors.put(f.gpa, d.type, d);
        }
        f.google_loaded = true;
    }

    // The transport.

    fn send(ptr: *anyopaque, req: tp.Request, arena: Allocator) tp.Error!tp.Response {
        const f: *FakeMonitoring = @ptrCast(@alignCast(ptr));
        const reply = try f.serve(req, arena);
        return .{ .status = reply.status, .headers = reply.headers, .body = reply.body };
    }

    /// One request, as `send` serves it: for a test that wants to send
    /// what no client would.
    pub fn serve(f: *FakeMonitoring, req: tp.Request, arena: Allocator) tp.Error!Reply {
        const path = pathOf(req.url);
        const q_at = std.mem.indexOfScalar(u8, path, '?');
        const route_text = path[0 .. q_at orelse path.len];
        const query = if (q_at) |q| path[q + 1 ..] else "";
        f.mutex.lockUncancelable(f.io);
        defer f.mutex.unlock(f.io);
        f.calls += 1;
        if (f.takeFault(drop) != null) return error.ConnectionResetByPeer;
        if (f.takeFault(refuse)) |fault| return asking(arena, try refusal(arena, fault.status), fault.delay);
        const lost = f.takeFault(lose);
        const reply = try f.route(req, arena, route_text, query);
        if (lost) |fault| return refusal(arena, fault.status);
        return reply;
    }

    fn route(f: *FakeMonitoring, req: tp.Request, arena: Allocator, route_text: []const u8, query: []const u8) Allocator.Error!Reply {
        if (req.bearer == null) return fail(arena, 401, "UNAUTHENTICATED", "Request is missing required authentication credential. Expected OAuth 2 access token, login cookie or other valid authentication credential. See https://developers.google.com/identity/sign-in/web/devconsole-project.");
        try f.loadGoogle();
        const target = parseRoute(route_text) orelse return notModelled(arena, "this path");
        if (!std.mem.eql(u8, target.project, f.options.project_id)) return notModelled(arena, "a project other than the fake's own");
        const params = try parseParams(arena, query) orelse return fail(arena, 400, "INVALID_ARGUMENT", "Invalid query string.");
        switch (target.collection) {
            .metric_descriptors => {
                if (target.rest.len == 0) return switch (req.method) {
                    .POST => f.createDescriptor(arena, req.body orelse ""),
                    .GET => f.listDescriptors(arena, params),
                    else => notModelled(arena, "this method on metricDescriptors"),
                };
                // Production refused a type whose slashes came encoded.
                if (std.mem.indexOf(u8, target.rest, "%2F") != null or std.mem.indexOf(u8, target.rest, "%2f") != null) return fail(arena, 400, "INVALID_ARGUMENT", try arena.print("Invalid metric name: {s}", .{target.rest}));
                const metric_type = try decoded(arena, target.rest);
                return switch (req.method) {
                    .GET => if (f.descriptors.get(metric_type)) |d| .{ .status = 200, .body = try f.renderDescriptor(arena, d) } else descriptorNotFound(arena, metric_type),
                    .DELETE => f.deleteDescriptor(arena, metric_type),
                    else => notModelled(arena, "this method on a metric descriptor"),
                };
            },
            .resource_descriptors => {
                if (req.method != .GET) return notModelled(arena, "this method on monitoredResourceDescriptors");
                if (target.rest.len == 0) return f.listResourceTypes(arena, params);
                const name = try decoded(arena, target.rest);
                const r = catalogType(name) orelse return fail(arena, 404, "NOT_FOUND", try arena.print("Could not find descriptor for resource type '{s}'.", .{name}));
                return .{ .status = 200, .body = try f.renderResourceType(arena, r) };
            },
            .time_series => {
                if (target.rest.len != 0) return notModelled(arena, "this path under timeSeries");
                return switch (req.method) {
                    .POST => f.write(arena, req.body orelse ""),
                    .GET => f.read(arena, params),
                    else => notModelled(arena, "this method on timeSeries"),
                };
            },
        }
    }

    // Descriptors.

    fn createDescriptor(f: *FakeMonitoring, arena: Allocator, body: []const u8) Allocator.Error!Reply {
        const root = parseJson(arena, body) orelse return invalidJson(arena);
        if (root != .object) return invalidJson(arena);
        const o = root.object;
        const metric_type = stringField(o, "type") orelse return notModelled(arena, "a descriptor without a type");
        if (metric_type.len > validate.max_metric_type_len) return fail(arena, 400, "INVALID_ARGUMENT", try arena.print("Field metricDescriptor.type had an invalid value of \"{s}\": the metric type is more than 512 characters long.", .{metric_type}));
        if (validate.metricTypeProblem(metric_type) != null) return notModelled(arena, "a metric type with characters production was not asked about");
        if (googleDomain(metric_type)) return noPermission(arena, metric_type);
        const kind = types.Kind.fromWire(stringField(o, "metricKind") orelse "");
        const value_type = types.ValueType.fromWire(stringField(o, "valueType") orelse "");
        if (kind == .unknown or value_type == .unknown or value_type == .money) return notModelled(arena, "a descriptor without a kind and a value type");
        var labels: std.ArrayList(types.LabelDescriptor) = .empty;
        if (o.get("labels")) |lv| {
            if (lv != .array) return invalidJson(arena);
            for (lv.array.items) |item| {
                if (item != .object) return invalidJson(arena);
                const key = stringField(item.object, "key") orelse return invalidJson(arena);
                const lt = if (stringField(item.object, "valueType")) |t| types.LabelType.fromWire(t) else .string;
                if (lt == .unknown) return notModelled(arena, "a label of another type");
                try labels.append(arena, .{ .key = key, .value_type = lt, .description = stringField(item.object, "description") orelse "" });
            }
        }
        if (try creationRefusal(arena, metric_type, kind, value_type, labels.items)) |r| return r;
        const unit = stringField(o, "unit") orelse "";
        if (f.descriptors.get(metric_type)) |existing| {
            if (existing.kind != kind or existing.value_type != value_type) return fail(arena, 409, "ALREADY_EXISTS", try arena.print("Errors during metric descriptor creation: {{(metric: {s}, error: The metric already exists.)}}.", .{metric_type}));
            const s = f.store.allocator();
            existing.unit = try s.dupe(u8, unit);
            existing.description = try s.dupe(u8, stringField(o, "description") orelse "");
            existing.display_name = try s.dupe(u8, stringField(o, "displayName") orelse "");
            existing.labels.clearRetainingCapacity();
            for (labels.items) |l| try existing.labels.append(s, try dupeLabelDescriptor(s, l));
            return .{ .status = 200, .body = try f.renderDescriptor(arena, existing) };
        }
        const d = try f.addDescriptor(metric_type, kind, value_type, unit);
        const s = f.store.allocator();
        d.description = try s.dupe(u8, stringField(o, "description") orelse "");
        d.display_name = try s.dupe(u8, stringField(o, "displayName") orelse "");
        for (labels.items) |l| try d.labels.append(s, try dupeLabelDescriptor(s, l));
        return .{ .status = 200, .body = try f.renderDescriptor(arena, d) };
    }

    fn addDescriptor(f: *FakeMonitoring, metric_type: []const u8, kind: types.Kind, value_type: types.ValueType, unit: []const u8) Allocator.Error!*Descriptor {
        const s = f.store.allocator();
        const d = try s.create(Descriptor);
        d.* = .{ .type = try s.dupe(u8, metric_type), .kind = kind, .value_type = value_type, .unit = try s.dupe(u8, unit) };
        try f.descriptors.put(f.gpa, d.type, d);
        return d;
    }

    fn deleteDescriptor(f: *FakeMonitoring, arena: Allocator, metric_type: []const u8) Allocator.Error!Reply {
        if (f.descriptors.get(metric_type)) |d| if (d.google != null) return notModelled(arena, "deleting one of Google's own metrics");
        if (!f.descriptors.orderedRemove(metric_type)) return fail(arena, 404, "NOT_FOUND", try arena.print("The metric '{s}' does not exist.", .{metric_type}));
        // Its data is no longer readable.
        var i: usize = 0;
        while (i < f.series.count()) {
            if (std.mem.eql(u8, f.series.values()[i].metric_type, metric_type)) {
                f.series.orderedRemoveAt(i);
            } else i += 1;
        }
        return .{ .status = 200, .body = "{}" };
    }

    fn listDescriptors(f: *FakeMonitoring, arena: Allocator, params: []const Param) Allocator.Error!Reply {
        var prefix: []const u8 = "";
        if (paramOf(params, "filter")) |filter| {
            prefix = typePrefix(filter) orelse return notModelled(arena, "a filter other than metric.type = starts_with(\"...\")");
        }
        const active_only = if (paramOf(params, "activeOnly")) |v| std.mem.eql(u8, v, "true") else false;
        var matched: std.ArrayList(*Descriptor) = .empty;
        for (f.descriptors.values()) |d| {
            if (!std.mem.startsWith(u8, d.type, prefix)) continue;
            if (active_only and !f.hasPoints(d.type)) continue;
            try matched.append(arena, d);
        }
        std.mem.sort(*Descriptor, matched.items, {}, struct {
            fn lessThan(_: void, a: *Descriptor, b: *Descriptor) bool {
                return std.mem.lessThan(u8, a.type, b.type);
            }
        }.lessThan);
        const window = pageOf(params, matched.items.len, 10_000) orelse return pageTokenRefusal(arena);
        var out: std.Io.Writer.Allocating = .init(arena);
        var jw: Stringify = .{ .writer = &out.writer };
        writePage(f, &jw, "metricDescriptors", matched.items[window.from..window.to], window.next, writeDescriptor) catch return error.OutOfMemory;
        return .{ .status = 200, .body = out.written() };
    }

    fn hasPoints(f: *const FakeMonitoring, metric_type: []const u8) bool {
        for (f.series.values()) |s| if (std.mem.eql(u8, s.metric_type, metric_type)) return true;
        return false;
    }

    fn renderDescriptor(f: *const FakeMonitoring, arena: Allocator, d: *const Descriptor) Allocator.Error![]const u8 {
        var out: std.Io.Writer.Allocating = .init(arena);
        var jw: Stringify = .{ .writer = &out.writer };
        writeDescriptor(f, &jw, d) catch return error.OutOfMemory;
        return out.written();
    }

    /// As production wrote one: name, labels, kind, value type, unit,
    /// description, display name, type, and every resource type the
    /// metric may be on: Google's one, or each a user metric may be
    /// written to.
    fn writeDescriptor(f: *const FakeMonitoring, jw: *Stringify, d: *const Descriptor) Stringify.Error!void {
        try jw.beginObject();
        try jw.objectField("name");
        try jw.print("\"projects/{s}/metricDescriptors/{s}\"", .{ f.options.project_id, d.type });
        if (d.labels.items.len > 0) {
            try jw.objectField("labels");
            try jw.beginArray();
            for (d.labels.items) |l| try writeLabelDescriptor(jw, l);
            try jw.endArray();
        }
        try jw.objectField("metricKind");
        try jw.write(d.kind.wire());
        try jw.objectField("valueType");
        try jw.write(d.value_type.wire());
        if (d.unit.len > 0) {
            try jw.objectField("unit");
            try jw.write(d.unit);
        }
        if (d.description.len > 0) {
            try jw.objectField("description");
            try jw.write(d.description);
        }
        if (d.display_name.len > 0) {
            try jw.objectField("displayName");
            try jw.write(d.display_name);
        }
        try jw.objectField("type");
        try jw.write(d.type);
        try jw.objectField("monitoredResourceTypes");
        try jw.beginArray();
        if (d.google) |g| {
            try jw.write(g.resource_type);
        } else for (catalog) |r| if (r.writable) try jw.write(r.type);
        try jw.endArray();
        try jw.endObject();
    }

    // Resource types.

    fn listResourceTypes(f: *FakeMonitoring, arena: Allocator, params: []const Param) Allocator.Error!Reply {
        const window = pageOf(params, catalog.len, 100) orelse return pageTokenRefusal(arena);
        var refs: [catalog.len]*const CatalogType = undefined;
        for (&refs, &catalog) |*r, *c| r.* = c;
        var out: std.Io.Writer.Allocating = .init(arena);
        var jw: Stringify = .{ .writer = &out.writer };
        writePage(f, &jw, "resourceDescriptors", refs[window.from..window.to], window.next, writeResourceType) catch return error.OutOfMemory;
        return .{ .status = 200, .body = out.written() };
    }

    fn renderResourceType(f: *const FakeMonitoring, arena: Allocator, r: *const CatalogType) Allocator.Error![]const u8 {
        var out: std.Io.Writer.Allocating = .init(arena);
        var jw: Stringify = .{ .writer = &out.writer };
        writeResourceType(f, &jw, r) catch return error.OutOfMemory;
        return out.written();
    }

    fn writeResourceType(f: *const FakeMonitoring, jw: *Stringify, r: *const CatalogType) Stringify.Error!void {
        try jw.beginObject();
        try jw.objectField("type");
        try jw.write(r.type);
        try jw.objectField("displayName");
        try jw.write(r.display_name);
        if (r.description.len > 0) {
            try jw.objectField("description");
            try jw.write(r.description);
        }
        try jw.objectField("labels");
        try jw.beginArray();
        for (r.labels) |l| try writeLabelDescriptor(jw, .{ .key = l[0], .description = l[1] });
        try jw.endArray();
        try jw.objectField("name");
        try jw.print("\"projects/{s}/monitoredResourceDescriptors/{s}\"", .{ f.options.project_id, r.type });
        try jw.objectField("launchStage");
        try jw.write("GA");
        try jw.endObject();
    }

    // Writes.

    /// One series of a write, as the request said it.
    const Sent = struct {
        metric_type: []const u8,
        metric_labels: []const types.Label,
        resource_type: []const u8,
        resource_labels: []const types.Label,
        kind: ?types.Kind,
        value_type: ?types.ValueType,
        unit: []const u8,
        start: ?i96,
        end: i96,
        /// As written, before the microseconds production keeps.
        start_text: ?[]const u8,
        end_text: []const u8,
        value: types.Value,
    };

    /// `same`: the series' last point again, end, start and value, which
    /// production took and kept once. `described`: the descriptor made or
    /// widened all the same, as production made one for a user metric it
    /// would not write to Pub/Sub's resource types.
    const Verdict = union(enum) { ok, same, refused: struct { code: u8, reason: []const u8, described: bool = false } };

    fn write(f: *FakeMonitoring, arena: Allocator, body: []const u8) Allocator.Error!Reply {
        const root = parseJson(arena, body) orelse return invalidJson(arena);
        if (root != .object) return invalidJson(arena);
        const list_v = root.object.get("timeSeries") orelse return missingSeries(arena);
        if (list_v != .array) return invalidJson(arena);
        const list = list_v.array.items;
        if (list.len == 0) return missingSeries(arena);
        if (list.len > validate.max_series_per_write) return fail(arena, 400, "INVALID_ARGUMENT", "Field timeSeries had an invalid value: A maximum of 200 TimeSeries can be written in a single request.");

        const sent = try arena.alloc(Sent, list.len);
        for (list, sent) |item, *s| {
            s.* = switch (try parseSeries(arena, item)) {
                .ok => |p| p,
                .reply => |r| return r,
            };
        }
        // What production refused before judging any point.
        for (sent) |s| {
            for (s.resource_labels) |l| if (std.mem.eql(u8, l.key, "project_id") and !std.mem.eql(u8, l.value, f.options.project_id)) {
                return fail(arena, 400, "INVALID_ARGUMENT", try arena.print("Field resource.labels.project_id had an invalid value of \"{s}\": if present, must be the project number or ID in the request name (projects/{s}).", .{ l.value, f.options.project_id }));
            };
            if (googleDomain(s.metric_type)) return noPermission(arena, s.metric_type);
            if (catalogType(s.resource_type) == null) return notModelled(arena, "a resource type the fake does not know");
            if (f.descriptors.get(s.metric_type) == null) {
                for (s.metric_labels, 0..) |l, i| if (l.key.len > validate.max_label_key_len) {
                    return fail(arena, 400, "INVALID_ARGUMENT", try arena.print("Field labels[{d}].key had an invalid value of \"{s}\": When creating metric {s}:  the label key is more than 100 characters long.", .{ i, l.key, s.metric_type }));
                };
                // Production judged a point it could see was wrong before
                // creating its descriptor: a 1,025-byte string to a new
                // STRING type was refused in the summary, not as a STRING
                // metric under custom.googleapis.com/.
                if (intrinsicProblem(s) == null) {
                    if (try creationRefusal(arena, s.metric_type, s.kind orelse .gauge, s.value_type orelse s.value.valueType(), &.{})) |r| return r;
                }
            } else for (s.metric_labels) |l| if (l.key.len > validate.max_label_key_len) {
                return notModelled(arena, "a label key past 100 bytes for a metric that exists");
            };
            if (s.value == .distribution) if (unmodelledDistribution(s.value.distribution)) |what| return notModelled(arena, what);
            if (try f.movedStart(arena, s)) return notModelled(arena, "a cumulative start moved later but inside the series' last interval");
        }

        const verdicts = try arena.alloc(Verdict, sent.len);
        const now = f.nowNs();
        for (sent, verdicts, 0..) |s, *v, i| {
            v.* = try f.judge(arena, s, sent[0..i], now);
            switch (v.*) {
                .ok => try f.keep(s),
                .same => {},
                .refused => |r| if (r.described) {
                    _ = try f.describe(s);
                },
            }
        }

        var written: u32 = 0;
        var first: ?usize = null;
        for (verdicts, 0..) |v, i| switch (v) {
            .ok, .same => written += 1,
            .refused => if (first == null) {
                first = i;
            },
        };
        const at = first orelse return .{ .status = 200, .body = "{}" };
        return f.partial(arena, sent, verdicts, at, written);
    }

    const Parsed = union(enum) { ok: Sent, reply: Reply };

    fn parseSeries(arena: Allocator, v: JsonValue) Allocator.Error!Parsed {
        if (v != .object) return .{ .reply = try invalidJson(arena) };
        const o = v.object;
        const metric = objectField(o, "metric") orelse return .{ .reply = try invalidJson(arena) };
        const resource = objectField(o, "resource") orelse return .{ .reply = try invalidJson(arena) };
        const metric_type = stringField(metric, "type") orelse return .{ .reply = try invalidJson(arena) };
        const resource_type = stringField(resource, "type") orelse return .{ .reply = try invalidJson(arena) };
        const metric_labels = try labelsOf(arena, metric) orelse return .{ .reply = try invalidJson(arena) };
        const resource_labels = try labelsOf(arena, resource) orelse return .{ .reply = try invalidJson(arena) };
        var kind: ?types.Kind = null;
        if (stringField(o, "metricKind")) |k| {
            kind = types.Kind.fromWire(k);
            if (kind.? == .unknown) return .{ .reply = try notModelled(arena, "a metric kind it does not know") };
        }
        var value_type: ?types.ValueType = null;
        if (stringField(o, "valueType")) |t| {
            value_type = types.ValueType.fromWire(t);
            if (value_type.? == .unknown or value_type.? == .money) return .{ .reply = try notModelled(arena, "a value type it does not know") };
        }
        const pts = o.get("points") orelse return .{ .reply = try invalidJson(arena) };
        if (pts != .array) return .{ .reply = try invalidJson(arena) };
        if (pts.array.items.len != 1) return .{ .reply = try notModelled(arena, "a series with other than one point") };
        const point = pts.array.items[0];
        if (point != .object) return .{ .reply = try invalidJson(arena) };
        const interval = objectField(point.object, "interval") orelse return .{ .reply = try invalidJson(arena) };
        const end_text = stringField(interval, "endTime") orelse return .{ .reply = try invalidJson(arena) };
        const end = core.timestamp.parse(end_text) catch return .{ .reply = try invalidJson(arena) };
        var start: ?i96 = null;
        const start_text = stringField(interval, "startTime");
        if (start_text) |t| start = (core.timestamp.parse(t) catch return .{ .reply = try invalidJson(arena) }).nanoseconds;
        const value_o = objectField(point.object, "value") orelse return .{ .reply = try invalidJson(arena) };
        const value = try parseValue(arena, value_o) orelse return .{ .reply = try invalidJson(arena) };
        return .{ .ok = .{
            .metric_type = metric_type,
            .metric_labels = metric_labels,
            .resource_type = resource_type,
            .resource_labels = resource_labels,
            .kind = kind,
            .value_type = value_type,
            .unit = stringField(o, "unit") orelse "",
            .start = start,
            .end = end.nanoseconds,
            .start_text = start_text,
            .end_text = end_text,
            .value = value,
        } };
    }

    const Intrinsic = enum { labels, label_key, label_value, string, count, width };

    /// What is wrong with a point whatever the project holds: its labels,
    /// a string's length, a distribution's counts and width.
    fn intrinsicProblem(s: Sent) ?struct { Intrinsic, usize } {
        if (s.metric_labels.len > validate.max_metric_labels) return .{ .labels, 0 };
        for (s.metric_labels, 0..) |l, i| {
            if (!validate.isLabelKey(l.key)) return .{ .label_key, i };
            if (l.value.len > validate.max_label_value_len) return .{ .label_value, i };
        }
        switch (s.value) {
            .string => |text| if (text.len > validate.max_string_value_len) return .{ .string, 0 },
            .distribution => |d| {
                var sum: u64 = 0;
                for (d.bucket_counts) |c| sum +|= c;
                if (d.bucket_counts.len > 0 and sum != d.count) return .{ .count, 0 };
                if (d.buckets == .linear and !(d.buckets.linear.width > 0)) return .{ .width, 0 };
            },
            else => {},
        }
        return null;
    }

    /// Production's judgement of one point, in the order it was measured
    /// to give them where it was, and in the order of the series where not.
    fn judge(f: *FakeMonitoring, arena: Allocator, s: Sent, earlier: []const Sent, now: i96) Allocator.Error!Verdict {
        if (intrinsicProblem(s)) |p| return refused(3, switch (p[0]) {
            .labels => try arena.print("Field metric.labels had an invalid value: The metric {s} has more than 30 labels.", .{s.metric_type}),
            .label_key => try arena.print("Field metric.labels had an invalid value of \"{s}\": Label key contains invalid characters.", .{s.metric_labels[p[1]].key}),
            .label_value => try arena.print("Field metric.labels had an invalid value of \"{s}\": Label value exceeds the maximum string size of 1024 characters.", .{s.metric_labels[p[1]].key}),
            .string => "Field points[0].value had an invalid value: The metric value exceeds the maximum string size of 1024 characters.",
            .count => blk: {
                const d = s.value.distribution;
                var sum: u64 = 0;
                for (d.bucket_counts) |c| sum +|= c;
                break :blk try arena.print("Field points[0].distributionValue had an invalid value: Distribution value has |bucket_counts| fields that sum to {d} which does not equal the |count| field value of {d}.", .{ sum, d.count });
            },
            .width => try arena.print("Field points[0].distributionValue had an invalid value: Distribution |bucket_options.linear_buckets| has a |width| of {d} which is not greater than 0.0.", .{s.value.distribution.buckets.linear.width}),
        });
        const r = catalogType(s.resource_type).?;
        if (!r.writable) return .{ .refused = .{ .code = 3, .reason = try arena.print("metrics cannot be written to {s}, see https://cloud.google.com/monitoring/custom-metrics/creating-metrics#which-resource for a list of writable resource types", .{r.type}), .described = true } };
        var missing: std.ArrayList(u8) = .empty;
        for (r.labels) |l| {
            if (std.mem.eql(u8, l[0], "project_id")) continue;
            if (labelValue(s.resource_labels, l[0]) == null) {
                if (missing.items.len > 0) try missing.appendSlice(arena, ", ");
                try missing.appendSlice(arena, l[0]);
            }
        }
        if (missing.items.len > 0) return refused(3, try arena.print("the set of resource labels is incomplete, missing ({s})", .{missing.items}));
        for (r.location_labels) |key| if (!isLocation(labelValue(s.resource_labels, key).?)) {
            return refused(3, "write for resource failed: Unrecognized region or location.");
        };

        const kind = s.kind orelse if (f.descriptors.get(s.metric_type)) |d| d.kind else .gauge;
        const value_type = s.value_type orelse if (f.descriptors.get(s.metric_type)) |d| d.value_type else s.value.valueType();
        if (f.descriptors.get(s.metric_type)) |d| {
            if (d.kind != kind) return refused(3, try arena.print("metric kind for metric must be {s}, but is {s}", .{ d.kind.wire(), kind.wire() }));
            if (d.value_type != value_type) return refused(3, try arena.print("value type for metric must be {s}, but is {s}", .{ d.value_type.wire(), value_type.wire() }));
        }
        if (value_type != s.value.valueType()) return refused(3, try arena.print("value type for metric must be {s}, but is {s}", .{ value_type.wire(), s.value.valueType().wire() }));

        if (kind == .gauge) {
            if (s.start) |start| if (start != s.end) {
                return refused(3, try arena.print("Field points[0].interval.start_time had an invalid value of \"{s}\": The start time must be equal to the end time ({s}) for the gauge metric '{s}'.", .{ s.start_text.?, s.end_text, s.metric_type }));
            };
        } else {
            const start = s.start orelse s.end;
            if (start >= s.end) return refused(3, try arena.print("Field points[0].interval.start_time had an invalid value of \"{s}\": The start time must be before the end time ({s}) for the non-gauge metric '{s}'.", .{ s.start_text orelse s.end_text, s.end_text, s.metric_type }));
        }
        if (s.end - now > max_ahead_ns) return refused(3, try arena.print("Field points[0].interval.end_time had an invalid value of \"{s}\": Data points cannot be written more than 5m into the future. Your data point is {f} after the present time, which is too far in the future.", .{ s.end_text, Duration{ .ns = s.end - now } }));
        if (now - s.end > max_back_ns) return refused(3, try arena.print("Field points[0].interval.end_time had an invalid value of \"{s}\": Data points cannot be written more than approximately 24 hours in the past, specifically no more than 25h10s in the past. Your data point is {f} before the present time, which is too far in the past.", .{ s.end_text, Duration{ .ns = now - s.end } }));

        for (earlier) |e| if (sameSent(e, s)) return refused(3, "Duplicate TimeSeries encountered. Only one point can be written per TimeSeries per request.");

        const key = try identity(arena, s);
        const series = f.series.get(key) orelse return .ok;
        const last = series.points.items[series.points.items.len - 1];
        const end = truncated(s.end);
        if (end < last.end.nanoseconds) return refused(3, "write for resource failed: Points must be written in order. One or more of the points specified had an older end time than the most recent point.");
        // The last point again, as it was: taken, and kept once. With
        // another value, it is too soon after itself.
        if (end == last.end.nanoseconds and samePoint(last, s)) return .same;
        if (end - last.end.nanoseconds < min_gap_ns) return refused(9, try arena.print("write for resource failed: One or more points were written more frequently than the maximum sampling period configured for the metric. {{Metric: {s}, Timestamps: {{Youngest Existing: '{f}', New: '{f}'}}}}", .{ s.metric_type, Stamp{ .ns = last.end.nanoseconds }, Stamp{ .ns = end } }));
        if (kind != .gauge) {
            const start = truncated(s.start.?);
            const series_start = last.start.?.nanoseconds;
            // A total that falls under the same start is taken, as
            // production took one on 2026-10-18.
            if (start < series_start) return refused(3, older_start);
        }
        return .ok;
    }

    /// Whether `s` moves its cumulative series' start later, but not past
    /// the series' last end: production took one, and the earlier point
    /// vanished from reads.
    fn movedStart(f: *FakeMonitoring, arena: Allocator, s: Sent) Allocator.Error!bool {
        const start_ns = s.start orelse return false;
        const series = f.series.get(try identity(arena, s)) orelse return false;
        const last = series.points.items[series.points.items.len - 1];
        const series_start = (last.start orelse return false).nanoseconds;
        const start = truncated(start_ns);
        return start > series_start and start < last.end.nanoseconds + std.time.ns_per_ms;
    }

    const older_start = "write for resource failed: Points must be written in order. One or more of the points specified had an older start time than the most recent point.";

    // Reads.

    /// One series as a read gives it back.
    const OutSeries = struct {
        metric_type: []const u8,
        metric_labels: []const types.Label,
        resource_type: []const u8,
        /// With `project_id`, as production gave them back.
        resource_labels: []const types.Label,
        kind: types.Kind,
        value_type: types.ValueType,
        /// Newest first.
        points: []const Point,
    };

    fn read(f: *FakeMonitoring, arena: Allocator, params: []const Param) Allocator.Error!Reply {
        const filter_text = paramOf(params, "filter") orelse return fail(arena, 400, "INVALID_ARGUMENT", read_no_type);
        const parsed = try parseFilter(arena, filter_text) orelse return notModelled(arena, "a filter of another shape");
        const metric_type = parsed.metric_type orelse return fail(arena, 400, "INVALID_ARGUMENT", read_no_type);
        const end_text = paramOf(params, "interval.endTime") orelse return notModelled(arena, "a read without an end time");
        const end = (core.timestamp.parse(end_text) catch return notModelled(arena, "an end time it cannot read")).nanoseconds;
        const start = if (paramOf(params, "interval.startTime")) |t| (core.timestamp.parse(t) catch return notModelled(arena, "a start time it cannot read")).nanoseconds else end;
        if (start > end) return fail(arena, 400, "INVALID_ARGUMENT", "Field interval.endTime had an invalid value: The start time must be less than or equal to the end time.");

        for (params) |p| if (std.mem.startsWith(u8, p.name, "secondaryAggregation.")) return notModelled(arena, "a secondary aggregation");
        const aligner_name = paramOf(params, "aggregation.perSeriesAligner") orelse "ALIGN_NONE";
        const reducer_name = paramOf(params, "aggregation.crossSeriesReducer") orelse "REDUCE_NONE";
        if (!std.mem.eql(u8, reducer_name, "REDUCE_NONE") and std.mem.eql(u8, aligner_name, "ALIGN_NONE")) return fail(arena, 400, "INVALID_ARGUMENT", "Request was missing field aggregation.perSeriesAligner.");
        var period_ns: i96 = 0;
        if (!std.mem.eql(u8, aligner_name, "ALIGN_NONE")) {
            const period_text = paramOf(params, "aggregation.alignmentPeriod") orelse "0";
            const seconds = periodSeconds(period_text) orelse return notModelled(arena, "an alignment period it cannot read");
            if (seconds < validate.min_alignment_period_s) return fail(arena, 400, "INVALID_ARGUMENT", try arena.print("Field aggregation.alignmentPeriod had an invalid value of \"{s}\": The alignment period must be greater than or equal to 10s.", .{period_text}));
            period_ns = @as(i96, seconds) * std.time.ns_per_s;
        }
        const aligner = alignerOf(aligner_name) orelse return notModelled(arena, try arena.print("the aligner {s}", .{aligner_name}));
        const reducer = reducerOf(reducer_name) orelse return notModelled(arena, try arena.print("the reducer {s}", .{reducer_name}));
        const headers = if (paramOf(params, "view")) |v| std.mem.eql(u8, v, "HEADERS") else false;

        const d = f.descriptors.get(metric_type) orelse return fail(arena, 404, "NOT_FOUND", try arena.print("Cannot find metric(s) that match type = \"{s}\". If a metric was created recently, it could take up to 10 minutes to become available. Please try again soon.", .{metric_type}));
        // A label the metric has no descriptor for, as production answered
        // on 2026-10-18; a resource type the metric cannot be on, or a
        // resource label none it can be on has, on 2026-10-19. A type
        // named narrows the labels to its own.
        var named: ?*const CatalogType = null;
        for (parsed.conditions) |c| if (c.field == .resource_type) {
            if (c.op != .equals) return notModelled(arena, "a resource type matched other than by equals");
            const r = catalogType(c.value) orelse return notModelled(arena, "a resource type the fake does not know");
            if (!canBeOn(d, r)) return fail(arena, 400, "INVALID_ARGUMENT", invalid_combination);
            named = r;
        };
        for (parsed.conditions) |c| switch (c.field) {
            .metric_label => {
                for (d.labels.items) |l| {
                    if (std.mem.eql(u8, l.key, c.key)) break;
                } else return fail(arena, 404, "NOT_FOUND", try arena.print("Cannot find metric(s) that match type = \"{s}\" label = \"{s}\". If a metric was created recently, it could take up to 10 minutes to become available. Please try again soon.", .{ metric_type, c.key }));
            },
            .resource_label => {
                if (!resourceLabelKnown(d, named, c.key)) return fail(arena, 400, "INVALID_ARGUMENT", invalid_combination);
            },
            .resource_type => {},
        };
        // The aligners production took on each kind, and those it refused
        // in its words, on 2026-10-19.
        if (aligner != .none) switch (d.kind) {
            .gauge => switch (d.value_type) {
                .int64, .double => switch (aligner) {
                    .min, .max, .mean, .sum, .count => {},
                    .delta, .rate => return misaligned(arena, aligner, d),
                    else => return notModelled(arena, try arena.print("the aligner {s} on a gauge", .{aligner.wire()})),
                },
                .bool => if (aligner != .count) return notModelled(arena, "this aligner on a bool metric"),
                else => return notModelled(arena, "aligning this value type"),
            },
            // Only Google's, every one INT64.
            .delta => switch (aligner) {
                .delta, .rate, .sum, .min, .max, .mean, .count => {},
                .interpolate, .next_older, .count_true, .count_false, .fraction_true, .percentile_99, .percentile_95, .percentile_50, .percentile_05 => return misaligned(arena, aligner, d),
                else => return notModelled(arena, try arena.print("the aligner {s} on a DELTA metric", .{aligner.wire()})),
            },
            else => return notModelled(arena, "aligning a cumulative metric"),
        };

        // The series the filter selects, with their points in the interval.
        var raw: std.ArrayList(OutSeries) = .empty;
        for (f.series.values()) |s| {
            if (!std.mem.eql(u8, s.metric_type, metric_type)) continue;
            if (!f.selects(parsed.conditions, s)) continue;
            var pts: std.ArrayList(Point) = .empty;
            var i = s.points.items.len;
            while (i > 0) {
                i -= 1;
                const p = s.points.items[i];
                const in = if (start == end) p.end.nanoseconds == end else p.end.nanoseconds > start and p.end.nanoseconds <= end;
                if (in) try pts.append(arena, .{ .start = if (s.kind == .gauge) p.end else p.start, .end = p.end, .value = p.value });
            }
            if (pts.items.len == 0) continue;
            try raw.append(arena, .{
                .metric_type = s.metric_type,
                .metric_labels = s.metric_labels,
                .resource_type = s.resource_type,
                .resource_labels = try f.withProject(arena, s.resource_labels),
                .kind = s.kind,
                .value_type = s.value_type,
                .points = pts.items,
            });
        }

        var out = raw.items;
        if (aligner != .none) {
            for (out) |*s| s.* = try alignSeries(arena, s.*, aligner, start, end, period_ns);
            if (reducer != .none) out = try f.reduce(arena, out, reducer, paramsOf(arena, params, "aggregation.groupByFields") catch return error.OutOfMemory);
        }
        // The unit production gave: `1` for a count, the metric's a second
        // for a rate, `{not_a_unit}` for a metric without one.
        const unit: []const u8 = if (aligner == .count or reducer == .count) "1" else if (aligner == .rate) try arena.print("{s}/s", .{d.unit}) else if (d.unit.len == 0) "{not_a_unit}" else d.unit;
        return f.renderRead(arena, out, params, headers, unit);
    }

    /// The resource's labels with `project_id` first, as a read shows them.
    fn withProject(f: *const FakeMonitoring, arena: Allocator, labels: []const types.Label) Allocator.Error![]const types.Label {
        const out = try arena.alloc(types.Label, labels.len + 1);
        out[0] = .{ .key = "project_id", .value = f.options.project_id };
        @memcpy(out[1..], labels);
        return out;
    }

    fn selects(f: *const FakeMonitoring, conditions: []const Condition, s: *const Series) bool {
        for (conditions) |c| {
            const have: ?[]const u8 = switch (c.field) {
                .resource_type => s.resource_type,
                .metric_label => labelValue(s.metric_labels, c.key),
                .resource_label => if (std.mem.eql(u8, c.key, "project_id")) f.options.project_id else labelValue(s.resource_labels, c.key),
            };
            const value = have orelse return false;
            const ok = switch (c.op) {
                .equals => std.mem.eql(u8, value, c.value),
                .not_equals => !std.mem.eql(u8, value, c.value),
                .starts_with => std.mem.startsWith(u8, value, c.value),
                .ends_with => std.mem.endsWith(u8, value, c.value),
                .has_substring => std.mem.indexOf(u8, value, c.value) != null,
            };
            if (!ok) return false;
        }
        return true;
    }

    /// Series grouped by their resource type and the `group_by` fields,
    /// each group's aligned values combined at each period's end, of the
    /// kind and interval alignment gave them.
    fn reduce(f: *const FakeMonitoring, arena: Allocator, series: []const OutSeries, reducer: types.Reducer, group_by: []const []const u8) Allocator.Error![]OutSeries {
        var groups: std.StringArrayHashMapUnmanaged(std.ArrayList(OutSeries)) = .empty;
        for (series) |s| {
            var key: std.Io.Writer.Allocating = .init(arena);
            key.writer.writeAll(s.resource_type) catch return error.OutOfMemory;
            for (group_by) |g| key.writer.print("\x00{s}", .{fieldValue(s, g) orelse ""}) catch return error.OutOfMemory;
            const gop = try groups.getOrPut(arena, key.written());
            if (!gop.found_existing) gop.value_ptr.* = .empty;
            try gop.value_ptr.append(arena, s);
        }
        const out = try arena.alloc(OutSeries, groups.count());
        for (groups.values(), out) |members, *o| {
            const first = members.items[0];
            var metric_labels: std.ArrayList(types.Label) = .empty;
            var resource_labels: std.ArrayList(types.Label) = .empty;
            try resource_labels.append(arena, .{ .key = "project_id", .value = f.options.project_id });
            for (group_by) |g| {
                const value = fieldValue(first, g) orelse continue;
                if (std.mem.startsWith(u8, g, "metric.labels.")) try metric_labels.append(arena, .{ .key = g["metric.labels.".len..], .value = value });
                if (std.mem.startsWith(u8, g, "resource.labels.")) try resource_labels.append(arena, .{ .key = g["resource.labels.".len..], .value = value });
            }
            // Every period end any member has, newest first.
            var ends: std.ArrayList(i96) = .empty;
            for (members.items) |m| for (m.points) |p| {
                for (ends.items) |e| {
                    if (e == p.end.nanoseconds) break;
                } else try ends.append(arena, p.end.nanoseconds);
            };
            std.mem.sort(i96, ends.items, {}, std.sort.desc(i96));
            var value_type = first.value_type;
            const pts = try arena.alloc(Point, ends.items.len);
            for (ends.items, pts) |e, *p| {
                var values: std.ArrayList(types.Value) = .empty;
                // Every member's period ending at `e` starts at one time.
                var start: i96 = e;
                for (members.items) |m| for (m.points) |mp| {
                    if (mp.end.nanoseconds != e) continue;
                    try values.append(arena, mp.value);
                    if (mp.start) |t| start = t.nanoseconds;
                };
                const reduced = combine(reducer, values.items);
                value_type = reduced.valueType();
                p.* = .{ .start = .{ .nanoseconds = start }, .end = .{ .nanoseconds = e }, .value = reduced };
            }
            o.* = .{
                .metric_type = first.metric_type,
                .metric_labels = metric_labels.items,
                .resource_type = first.resource_type,
                .resource_labels = resource_labels.items,
                .kind = first.kind,
                .value_type = value_type,
                .points = pts,
            };
        }
        return out;
    }

    fn renderRead(f: *const FakeMonitoring, arena: Allocator, series: []const OutSeries, params: []const Param, headers: bool, unit: []const u8) Allocator.Error!Reply {
        _ = f;
        std.mem.sort(OutSeries, @constCast(series), {}, struct {
            fn lessThan(_: void, a: OutSeries, b: OutSeries) bool {
                return std.mem.lessThan(u8, a.resource_type, b.resource_type) or
                    (std.mem.eql(u8, a.resource_type, b.resource_type) and labelsLess(a.metric_labels, b.metric_labels, a.resource_labels, b.resource_labels));
            }
        }.lessThan);
        var out: std.Io.Writer.Allocating = .init(arena);
        var jw: Stringify = .{ .writer = &out.writer };
        writeRead(&jw, series, params, headers, unit) catch |err| switch (err) {
            error.WriteFailed => return error.OutOfMemory,
            error.InvalidToken => return pageTokenRefusal(arena),
        };
        return .{ .status = 200, .body = out.written() };
    }

    fn refused(code: u8, reason: []const u8) Verdict {
        return .{ .refused = .{ .code = code, .reason = reason } };
    }

    /// Keeps an accepted point: the descriptor made or widened, the series
    /// made, the point added.
    fn keep(f: *FakeMonitoring, s: Sent) Allocator.Error!void {
        const st = f.store.allocator();
        const d = try f.describe(s);
        const series = try f.seriesOf(d, s.metric_labels, s.resource_type, s.resource_labels);
        try series.points.append(st, .{
            .start = if (d.kind == .gauge) null else .{ .nanoseconds = truncated(s.start.?) },
            .end = .{ .nanoseconds = truncated(s.end) },
            .value = try copyValue(st, s.value),
        });
    }

    /// The descriptor of a written series, made or widened as a write
    /// makes or widens it.
    fn describe(f: *FakeMonitoring, s: Sent) Allocator.Error!*Descriptor {
        const d = f.descriptors.get(s.metric_type) orelse try f.addDescriptor(s.metric_type, s.kind orelse .gauge, s.value_type orelse s.value.valueType(), s.unit);
        try f.addLabels(d, s.metric_labels);
        return d;
    }

    /// Adds to a user metric's descriptor the labels it lacks, as strings,
    /// as a write does.
    fn addLabels(f: *FakeMonitoring, d: *Descriptor, labels: []const types.Label) Allocator.Error!void {
        const st = f.store.allocator();
        for (labels) |l| {
            for (d.labels.items) |have| {
                if (std.mem.eql(u8, have.key, l.key)) break;
            } else try d.labels.append(st, .{ .key = try st.dupe(u8, l.key) });
        }
    }

    /// The series of `d` with these labels on this resource, made if new.
    fn seriesOf(f: *FakeMonitoring, d: *Descriptor, metric_labels: []const types.Label, resource_type: []const u8, resource_labels: []const types.Label) Allocator.Error!*Series {
        const st = f.store.allocator();
        const key = try identityOf(st, d.type, metric_labels, resource_type, resource_labels);
        if (f.series.get(key)) |existing| return existing;
        const series = try st.create(Series);
        series.* = .{
            .metric_type = d.type,
            .metric_labels = try dupeLabels(st, try sortedLabels(st, metric_labels)),
            .resource_type = try st.dupe(u8, resource_type),
            .resource_labels = try dupeLabels(st, try withoutProject(st, try sortedLabels(st, resource_labels))),
            .kind = d.kind,
            .value_type = d.value_type,
        };
        try f.series.put(f.gpa, key, series);
        return series;
    }

    /// The 400 production answered when a write refused any point: the
    /// summary, and the first refusal's reason and status.
    fn partial(f: *FakeMonitoring, arena: Allocator, sent: []const Sent, verdicts: []const Verdict, at: usize, written: u32) Allocator.Error!Reply {
        _ = f;
        const first = verdicts[at].refused;
        const s = sent[at];
        var message: std.Io.Writer.Allocating = .init(arena);
        const w = &message.writer;
        w.print("One or more TimeSeries could not be written: timeSeries[{d}] (metric.type=\"{s}\", metric.labels=", .{ at, s.metric_type }) catch return error.OutOfMemory;
        writeLabelMap(w, s.metric_labels) catch return error.OutOfMemory;
        w.print(", resource.type=\"{s}\", resource.labels=", .{s.resource_type}) catch return error.OutOfMemory;
        writeLabelMap(w, try withoutProject(arena, s.resource_labels)) catch return error.OutOfMemory;
        w.print("): {s}", .{first.reason}) catch return error.OutOfMemory;

        // Counts by code, in the order each code first appears.
        var codes: [2]struct { code: u8, n: u32 } = undefined;
        var code_count: usize = 0;
        for (verdicts) |v| if (v == .refused) {
            for (codes[0..code_count]) |*c| {
                if (c.code == v.refused.code) {
                    c.n += 1;
                    break;
                }
            } else {
                codes[code_count] = .{ .code = v.refused.code, .n = 1 };
                code_count += 1;
            }
        };
        var out: std.Io.Writer.Allocating = .init(arena);
        var jw: Stringify = .{ .writer = &out.writer };
        const status = if (first.code == 9) "FAILED_PRECONDITION" else "INVALID_ARGUMENT";
        (struct {
            fn run(j: *Stringify, msg: []const u8, st: []const u8, total: usize, ok: u32, counts: anytype) Stringify.Error!void {
                try j.beginObject();
                try j.objectField("error");
                try j.beginObject();
                try j.objectField("code");
                try j.write(400);
                try j.objectField("message");
                try j.write(msg);
                try j.objectField("status");
                try j.write(st);
                try j.objectField("details");
                try j.beginArray();
                try j.beginObject();
                try j.objectField("@type");
                try j.write("type.googleapis.com/google.monitoring.v3.CreateTimeSeriesSummary");
                try j.objectField("totalPointCount");
                try j.write(total);
                if (ok > 0) {
                    try j.objectField("successPointCount");
                    try j.write(ok);
                }
                try j.objectField("errors");
                try j.beginArray();
                for (counts) |c| {
                    try j.beginObject();
                    try j.objectField("status");
                    try j.beginObject();
                    try j.objectField("code");
                    try j.write(c.code);
                    try j.endObject();
                    try j.objectField("pointCount");
                    try j.write(c.n);
                    try j.endObject();
                }
                try j.endArray();
                try j.endObject();
                try j.endArray();
                try j.endObject();
                try j.endObject();
            }
        }).run(&jw, message.written(), status, sent.len, written, codes[0..code_count]) catch return error.OutOfMemory;
        return .{ .status = 400, .body = out.written() };
    }
};

const read_no_type = "The provided filter matches more than one metric. TimeSeries data are limited to a single metric per request.";
const invalid_combination = "The supplied filter does not specify a valid combination of metric and monitored resource descriptors. The query will not return any time series.";

const Condition = struct {
    field: enum { resource_type, metric_label, resource_label },
    key: []const u8 = "",
    op: types.Match.Op,
    value: []const u8,
};

const ParsedFilter = struct {
    metric_type: ?[]const u8 = null,
    conditions: []const Condition,
};

/// The fake's own reading of a filter, as the client writes them: `field
/// op value` terms joined by AND, a value a quoted string with `\"` and
/// `\\` escapes, or `starts_with`, `ends_with` or `has_substring` of one.
/// Null for anything else.
fn parseFilter(arena: Allocator, text: []const u8) Allocator.Error!?ParsedFilter {
    var p: Scanner = .{ .text = text };
    var conditions: std.ArrayList(Condition) = .empty;
    var metric_type: ?[]const u8 = null;
    while (true) {
        p.skipSpaces();
        const name = p.identifier() orelse return null;
        p.skipSpaces();
        const negated = if (p.take("!=")) true else if (p.take("=")) false else return null;
        p.skipSpaces();
        var op: types.Match.Op = if (negated) .not_equals else .equals;
        var value: []const u8 = undefined;
        if (p.peek() == '"') {
            value = try p.quoted(arena) orelse return null;
        } else {
            if (negated) return null;
            const function = p.identifier() orelse return null;
            op = std.meta.stringToEnum(types.Match.Op, function) orelse return null;
            if (op == .equals or op == .not_equals or !p.take("(")) return null;
            value = try p.quoted(arena) orelse return null;
            if (!p.take(")")) return null;
        }
        if (std.mem.eql(u8, name, "metric.type")) {
            if (op != .equals or metric_type != null) return null;
            metric_type = value;
        } else if (std.mem.eql(u8, name, "resource.type")) {
            try conditions.append(arena, .{ .field = .resource_type, .op = op, .value = value });
        } else if (std.mem.startsWith(u8, name, "metric.labels.")) {
            try conditions.append(arena, .{ .field = .metric_label, .key = name["metric.labels.".len..], .op = op, .value = value });
        } else if (std.mem.startsWith(u8, name, "resource.labels.")) {
            try conditions.append(arena, .{ .field = .resource_label, .key = name["resource.labels.".len..], .op = op, .value = value });
        } else return null;
        p.skipSpaces();
        if (p.done()) break;
        if (!p.take("AND")) return null;
    }
    return .{ .metric_type = metric_type, .conditions = conditions.items };
}

const Scanner = struct {
    text: []const u8,
    at: usize = 0,

    fn done(s: *const Scanner) bool {
        return s.at >= s.text.len;
    }

    fn peek(s: *const Scanner) u8 {
        return if (s.done()) 0 else s.text[s.at];
    }

    fn skipSpaces(s: *Scanner) void {
        while (!s.done() and s.text[s.at] == ' ') s.at += 1;
    }

    fn take(s: *Scanner, word: []const u8) bool {
        if (!std.mem.startsWith(u8, s.text[s.at..], word)) return false;
        s.at += word.len;
        return true;
    }

    fn identifier(s: *Scanner) ?[]const u8 {
        const from = s.at;
        while (!s.done()) : (s.at += 1) switch (s.text[s.at]) {
            'a'...'z', 'A'...'Z', '0'...'9', '_', '.' => {},
            else => break,
        };
        return if (s.at == from) null else s.text[from..s.at];
    }

    fn quoted(s: *Scanner, arena: Allocator) Allocator.Error!?[]const u8 {
        if (!s.take("\"")) return null;
        var out: std.ArrayList(u8) = .empty;
        while (!s.done()) {
            const c = s.text[s.at];
            s.at += 1;
            switch (c) {
                '"' => return out.items,
                '\\' => {
                    if (s.done()) return null;
                    const next = s.text[s.at];
                    if (next != '"' and next != '\\') return null;
                    try out.append(arena, next);
                    s.at += 1;
                },
                else => try out.append(arena, c),
            }
        }
        return null;
    }
};

/// "60s": whole seconds. Null for anything else.
fn periodSeconds(text: []const u8) ?u64 {
    if (text.len < 2 or text[text.len - 1] != 's') return std.fmt.parseInt(u64, text, 10) catch null;
    return std.fmt.parseInt(u64, text[0 .. text.len - 1], 10) catch null;
}

/// An aligner by the name a request gives it.
fn alignerOf(name: []const u8) ?types.Aligner {
    inline for (comptime std.meta.tags(types.Aligner)) |a| {
        if (std.mem.eql(u8, name, comptime types.Aligner.wire(a))) return a;
    }
    return null;
}

fn reducerOf(name: []const u8) ?types.Reducer {
    inline for (.{ .none, .min, .max, .mean, .sum, .count }) |r| {
        if (std.mem.eql(u8, name, comptime types.Reducer.wire(r))) return r;
    }
    return null;
}

/// A series' points, one per period: periods end at the read's end and
/// every `period_ns` before it, each holding the points that end in (its
/// end minus the period, its end]; a period with none has no point.
/// Newest first.
fn alignSeries(arena: Allocator, s: FakeMonitoring.OutSeries, aligner: types.Aligner, start: i96, end: i96, period_ns: i96) Allocator.Error!FakeMonitoring.OutSeries {
    // ALIGN_DELTA's points span their period, and so do ALIGN_SUM's on a
    // DELTA metric; the others' are at the period's end.
    const spans = aligner == .delta or (aligner == .sum and s.kind == .delta);
    var pts: std.ArrayList(FakeMonitoring.Point) = .empty;
    var window_end = end;
    while (window_end > start or (start == end and window_end == end)) : (window_end -= period_ns) {
        var values: std.ArrayList(types.Value) = .empty;
        for (s.points) |p| {
            if (p.end.nanoseconds > window_end - period_ns and p.end.nanoseconds <= window_end) try values.append(arena, p.value);
        }
        if (values.items.len > 0) try pts.append(arena, alignedPoint(aligner, spans, values.items, window_end, period_ns));
        if (start == end) break;
    }
    var out = s;
    out.points = pts.items;
    out.kind = if (spans) .delta else .gauge;
    // Every series read has a point in (start, end], so in a period.
    out.value_type = pts.items[0].value.valueType();
    return out;
}

/// One period's values as an aligner makes them a point: a total for
/// ALIGN_DELTA and ALIGN_SUM, a total a second for ALIGN_RATE, the others'
/// value; over the period if it `spans` it, else at the period's end.
fn alignedPoint(aligner: types.Aligner, spans: bool, values: []const types.Value, window_end: i96, period_ns: i96) FakeMonitoring.Point {
    const at: std.Io.Timestamp = .{ .nanoseconds = window_end };
    return .{
        .start = if (spans) .{ .nanoseconds = window_end - period_ns } else at,
        .end = at,
        .value = switch (aligner) {
            .delta, .sum => combine(.sum, values),
            .rate => .{ .double = asDouble(combine(.sum, values)) / @as(f64, @floatFromInt(@divExact(period_ns, std.time.ns_per_s))) },
            .min => combine(.min, values),
            .max => combine(.max, values),
            .mean => combine(.mean, values),
            .count => combine(.count, values),
            else => unreachable,
        },
    };
}

/// Values combined as an aligner or a reducer of the same name does: min,
/// max and sum keep their type (a sum of int64s and doubles is a double),
/// mean is a double, count an int64.
fn combine(how: types.Reducer, values: []const types.Value) types.Value {
    if (how == .count) return .{ .int64 = @intCast(values.len) };
    var all_int = true;
    for (values) |v| if (v != .int64) {
        all_int = false;
    };
    if (how != .mean and all_int) {
        var acc: i64 = values[0].int64;
        for (values[1..]) |v| acc = switch (how) {
            .min => @min(acc, v.int64),
            .max => @max(acc, v.int64),
            else => acc +% v.int64,
        };
        return .{ .int64 = acc };
    }
    var acc: f64 = asDouble(values[0]);
    for (values[1..]) |v| acc = switch (how) {
        .min => @min(acc, asDouble(v)),
        .max => @max(acc, asDouble(v)),
        else => acc + asDouble(v),
    };
    if (how == .mean) acc /= @floatFromInt(values.len);
    return .{ .double = acc };
}

/// What min, max, sum and mean see: only numbers reach them.
fn asDouble(v: types.Value) f64 {
    return switch (v) {
        .int64 => |n| @floatFromInt(n),
        .double => |d| d,
        else => unreachable,
    };
}

/// A group-by field's value in a series: `metric.labels.K`,
/// `resource.labels.K`, or `resource.type`.
fn fieldValue(s: FakeMonitoring.OutSeries, field: []const u8) ?[]const u8 {
    if (std.mem.eql(u8, field, "resource.type")) return s.resource_type;
    if (std.mem.startsWith(u8, field, "metric.labels.")) return labelValue(s.metric_labels, field["metric.labels.".len..]);
    if (std.mem.startsWith(u8, field, "resource.labels.")) return labelValue(s.resource_labels, field["resource.labels.".len..]);
    return null;
}

fn labelsLess(a_metric: []const types.Label, b_metric: []const types.Label, a_resource: []const types.Label, b_resource: []const types.Label) bool {
    const order = labelsOrder(a_metric, b_metric);
    if (order != .eq) return order == .lt;
    return labelsOrder(a_resource, b_resource) == .lt;
}

fn labelsOrder(a: []const types.Label, b: []const types.Label) std.math.Order {
    for (a[0..@min(a.len, b.len)], b[0..@min(a.len, b.len)]) |x, y| {
        const k = std.mem.order(u8, x.key, y.key);
        if (k != .eq) return k;
        const v = std.mem.order(u8, x.value, y.value);
        if (v != .eq) return v;
    }
    return std.math.order(a.len, b.len);
}

/// A read's page. With FULL, `pageSize` counts points, so a series whose
/// points do not fit comes again on the next page, as production's did;
/// with HEADERS it counts series.
fn writeRead(jw: *Stringify, series: []const FakeMonitoring.OutSeries, params: []const Param, headers: bool, unit: []const u8) (Stringify.Error || error{InvalidToken})!void {
    var size: usize = 100_000;
    if (paramOf(params, "pageSize")) |text| {
        const n = std.fmt.parseInt(usize, text, 10) catch return error.InvalidToken;
        if (n != 0) size = @min(n, 100_000);
    }
    var from: usize = 0;
    if (paramOf(params, "pageToken")) |t| {
        if (!std.mem.startsWith(u8, t, "p")) return error.InvalidToken;
        from = std.fmt.parseInt(usize, t[1..], 10) catch return error.InvalidToken;
    }
    var total: usize = 0;
    for (series) |s| total += if (headers) 1 else s.points.len;
    if (from > total) return error.InvalidToken;
    const to = @min(total, from + size);

    try jw.beginObject();
    var position: usize = 0;
    var opened = false;
    for (series) |s| {
        const count = if (headers) 1 else s.points.len;
        defer position += count;
        if (position + count <= from or position >= to) continue;
        if (!opened) {
            try jw.objectField("timeSeries");
            try jw.beginArray();
            opened = true;
        }
        try jw.beginObject();
        try jw.objectField("metric");
        try jw.beginObject();
        if (s.metric_labels.len > 0) {
            try jw.objectField("labels");
            try writeLabelObject(jw, s.metric_labels);
        }
        try jw.objectField("type");
        try jw.write(s.metric_type);
        try jw.endObject();
        try jw.objectField("resource");
        try jw.beginObject();
        try jw.objectField("type");
        try jw.write(s.resource_type);
        try jw.objectField("labels");
        try writeLabelObject(jw, s.resource_labels);
        try jw.endObject();
        try jw.objectField("metricKind");
        try jw.write(s.kind.wire());
        try jw.objectField("valueType");
        try jw.write(s.value_type.wire());
        if (!headers) {
            const lo = @max(from, position) - position;
            const hi = @min(to, position + count) - position;
            try jw.objectField("points");
            try jw.beginArray();
            for (s.points[lo..hi]) |p| {
                try jw.beginObject();
                try jw.objectField("interval");
                try jw.beginObject();
                var buf: [core.timestamp.max_len]u8 = undefined;
                if (p.start) |st| {
                    try jw.objectField("startTime");
                    try jw.write(core.timestamp.format(&buf, st));
                }
                try jw.objectField("endTime");
                try jw.write(core.timestamp.format(&buf, p.end));
                try jw.endObject();
                try jw.objectField("value");
                try writePointValue(jw, p.value);
                try jw.endObject();
            }
            try jw.endArray();
        }
        try jw.endObject();
    }
    if (opened) try jw.endArray();
    if (to < total) {
        try jw.objectField("nextPageToken");
        try jw.print("\"p{d}\"", .{to});
    }
    try jw.objectField("unit");
    try jw.write(unit);
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

/// A value as production writes one: int64s as strings, doubles as numbers
/// or "NaN", "Infinity" and "-Infinity".
fn writePointValue(jw: *Stringify, v: types.Value) Stringify.Error!void {
    try jw.beginObject();
    switch (v) {
        .bool => |b| {
            try jw.objectField("boolValue");
            try jw.write(b);
        },
        .int64 => |n| {
            try jw.objectField("int64Value");
            try jw.print("\"{d}\"", .{n});
        },
        .double => |d| {
            try jw.objectField("doubleValue");
            try fakeDouble(jw, d);
        },
        .string => |s| {
            try jw.objectField("stringValue");
            try jw.write(s);
        },
        .distribution => |d| {
            try jw.objectField("distributionValue");
            try jw.beginObject();
            if (d.count != 0) {
                try jw.objectField("count");
                try jw.print("\"{d}\"", .{d.count});
            }
            if (d.mean != 0) {
                try jw.objectField("mean");
                try fakeDouble(jw, d.mean);
            }
            if (d.sum_of_squared_deviation != 0) {
                try jw.objectField("sumOfSquaredDeviation");
                try fakeDouble(jw, d.sum_of_squared_deviation);
            }
            try jw.objectField("bucketOptions");
            try jw.beginObject();
            switch (d.buckets) {
                .linear => |l| {
                    try jw.objectField("linearBuckets");
                    try jw.beginObject();
                    try jw.objectField("numFiniteBuckets");
                    try jw.write(l.num_finite);
                    try jw.objectField("width");
                    try fakeDouble(jw, l.width);
                    try jw.objectField("offset");
                    try fakeDouble(jw, l.offset);
                    try jw.endObject();
                },
                .exponential => |e| {
                    try jw.objectField("exponentialBuckets");
                    try jw.beginObject();
                    try jw.objectField("numFiniteBuckets");
                    try jw.write(e.num_finite);
                    try jw.objectField("growthFactor");
                    try fakeDouble(jw, e.growth_factor);
                    try jw.objectField("scale");
                    try fakeDouble(jw, e.scale);
                    try jw.endObject();
                },
                .explicit => |bounds| {
                    try jw.objectField("explicitBuckets");
                    try jw.beginObject();
                    try jw.objectField("bounds");
                    try jw.beginArray();
                    for (bounds) |b| try fakeDouble(jw, b);
                    try jw.endArray();
                    try jw.endObject();
                },
            }
            try jw.endObject();
            if (d.bucket_counts.len > 0) {
                try jw.objectField("bucketCounts");
                try jw.beginArray();
                for (d.bucket_counts) |c| try jw.print("\"{d}\"", .{c});
                try jw.endArray();
            }
            try jw.endObject();
        },
    }
    try jw.endObject();
}

fn fakeDouble(jw: *Stringify, d: f64) Stringify.Error!void {
    if (std.math.isNan(d)) return jw.write("NaN");
    if (std.math.isInf(d)) return jw.write(if (d > 0) "Infinity" else "-Infinity");
    try jw.print("{e}", .{d});
}

// Routes and parameters.

const Route = struct {
    project: []const u8,
    collection: enum { metric_descriptors, resource_descriptors, time_series },
    /// After the collection and its `/`, as sent; "" for the collection.
    rest: []const u8,
};

fn pathOf(url: []const u8) []const u8 {
    const scheme = std.mem.indexOf(u8, url, "://") orelse return url;
    const rest = url[scheme + 3 ..];
    const slash = std.mem.indexOfScalar(u8, rest, '/') orelse return "/";
    return rest[slash..];
}

fn parseRoute(path: []const u8) ?Route {
    const prefix = "/v3/projects/";
    if (!std.mem.startsWith(u8, path, prefix)) return null;
    const after = path[prefix.len..];
    const slash = std.mem.indexOfScalar(u8, after, '/') orelse return null;
    const project = after[0..slash];
    const tail = after[slash + 1 ..];
    const names = [_]struct { []const u8, @FieldType(Route, "collection") }{
        .{ "metricDescriptors", .metric_descriptors },
        .{ "monitoredResourceDescriptors", .resource_descriptors },
        .{ "timeSeries", .time_series },
    };
    for (names) |n| {
        if (std.mem.eql(u8, tail, n[0])) return .{ .project = project, .collection = n[1], .rest = "" };
        if (tail.len > n[0].len + 1 and std.mem.startsWith(u8, tail, n[0]) and tail[n[0].len] == '/') {
            return .{ .project = project, .collection = n[1], .rest = tail[n[0].len + 1 ..] };
        }
    }
    return null;
}

fn decoded(arena: Allocator, text: []const u8) Allocator.Error![]const u8 {
    const copy = try arena.dupe(u8, text);
    return std.Uri.percentDecodeInPlace(copy);
}

const Param = struct { name: []const u8, value: []const u8 };

fn parseParams(arena: Allocator, query: []const u8) Allocator.Error!?[]const Param {
    var list: std.ArrayList(Param) = .empty;
    if (query.len == 0) return list.items;
    var it = std.mem.splitScalar(u8, query, '&');
    while (it.next()) |pair| {
        const eq = std.mem.indexOfScalar(u8, pair, '=') orelse return null;
        try list.append(arena, .{ .name = try decoded(arena, pair[0..eq]), .value = try decoded(arena, pair[eq + 1 ..]) });
    }
    return list.items;
}

fn paramOf(params: []const Param, name: []const u8) ?[]const u8 {
    for (params) |p| if (std.mem.eql(u8, p.name, name)) return p.value;
    return null;
}

/// Every value of a repeated parameter, in order.
fn paramsOf(arena: Allocator, params: []const Param, name: []const u8) Allocator.Error![]const []const u8 {
    var out: std.ArrayList([]const u8) = .empty;
    for (params) |p| if (std.mem.eql(u8, p.name, name)) try out.append(arena, p.value);
    return out.items;
}

/// The prefix of `metric.type = starts_with("X")`, the one filter the fake
/// reads, its `\"` and `\\` unescaped.
fn typePrefix(filter: []const u8) ?[]const u8 {
    const head = "metric.type = starts_with(\"";
    const tail = "\")";
    if (!std.mem.startsWith(u8, filter, head) or !std.mem.endsWith(u8, filter, tail)) return null;
    const inner = filter[head.len .. filter.len - tail.len];
    if (std.mem.indexOfAny(u8, inner, "\"\\") != null) return null;
    return inner;
}

const Window = struct { from: usize, to: usize, next: ?usize };

/// The page a request asks for: `pageSize` (0 for `max`) from the position
/// its token names.
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

fn writePage(f: *const FakeMonitoring, jw: *Stringify, list_name: []const u8, items: anytype, next: ?usize, comptime each: anytype) Stringify.Error!void {
    try jw.beginObject();
    if (items.len > 0) {
        try jw.objectField(list_name);
        try jw.beginArray();
        for (items) |item| try each(f, jw, item);
        try jw.endArray();
    }
    if (next) |n| {
        try jw.objectField("nextPageToken");
        try jw.print("\"p{d}\"", .{n});
    }
    try jw.endObject();
}

// The resource types it knows: the ones `Resource` names, and Pub/Sub's.

const CatalogType = struct {
    type: []const u8,
    display_name: []const u8,
    description: []const u8 = "",
    /// Key and description, `project_id` first, as production lists them.
    labels: []const [2][]const u8,
    /// The labels that must name a region or a zone.
    location_labels: []const []const u8,
    /// Whether a user metric may be written to it; Pub/Sub's carry only
    /// Google's own metrics.
    writable: bool = true,

    fn hasLabel(r: *const CatalogType, key: []const u8) bool {
        for (r.labels) |l| if (std.mem.eql(u8, l[0], key)) return true;
        return false;
    }
};

const project_label = .{ "project_id", "The identifier of the GCP project associated with this resource, such as \"my-project\"." };

/// generic_task's and Pub/Sub's text is production's, measured 2026-10-18
/// and 2026-10-19; the others' labels are the ones `Resource` names, with
/// no descriptions.
const catalog = [_]CatalogType{
    .{ .type = "gce_instance", .display_name = "VM Instance", .labels = &.{ project_label, .{ "instance_id", "" }, .{ "zone", "" } }, .location_labels = &.{"zone"} },
    .{ .type = "generic_node", .display_name = "Generic Node", .labels = &.{ project_label, .{ "location", "" }, .{ "namespace", "" }, .{ "node_id", "" } }, .location_labels = &.{"location"} },
    .{
        .type = "generic_task",
        .display_name = "Generic Task",
        .description = "A generic task identifies an application process for which no more specific resource is applicable, such as a process scheduled by a custom orchestration system. The label values must uniquely identify the task.",
        .labels = &.{
            project_label,
            .{ "location", "The Google Cloud region or zone that determines where data about the resource is stored. For example, \"us-east1-a\"." },
            .{ "namespace", "A namespace identifier, such as a cluster name." },
            .{ "job", "An identifier for a grouping of related tasks, such as the name of a microservice or distributed batch job." },
            .{ "task_id", "A unique identifier for the task within the namespace and job, such as a replica index identifying the task within the job." },
        },
        .location_labels = &.{"location"},
    },
    .{ .type = "global", .display_name = "Global", .labels = &.{project_label}, .location_labels = &.{} },
    .{ .type = "k8s_container", .display_name = "Kubernetes Container", .labels = &.{ project_label, .{ "location", "" }, .{ "cluster_name", "" }, .{ "namespace_name", "" }, .{ "pod_name", "" }, .{ "container_name", "" } }, .location_labels = &.{"location"} },
    .{ .type = "k8s_node", .display_name = "Kubernetes Node", .labels = &.{ project_label, .{ "location", "" }, .{ "cluster_name", "" }, .{ "node_name", "" } }, .location_labels = &.{"location"} },
    .{ .type = "k8s_pod", .display_name = "Kubernetes Pod", .labels = &.{ project_label, .{ "location", "" }, .{ "cluster_name", "" }, .{ "namespace_name", "" }, .{ "pod_name", "" } }, .location_labels = &.{"location"} },
    .{
        .type = "pubsub_subscription",
        .display_name = "Cloud Pub/Sub Subscription",
        .description = "A subscription in Google Cloud Pub/Sub.",
        .labels = &.{ project_label, .{ "subscription_id", "The identifier of the subscription, such as \"my-subscription\"." } },
        .location_labels = &.{},
        .writable = false,
    },
    .{
        .type = "pubsub_topic",
        .display_name = "Cloud Pub/Sub Topic",
        .description = "A topic in Google Cloud Pub/Sub.",
        .labels = &.{ project_label, .{ "topic_id", "The identifier of the topic, such as \"my-topic\"." } },
        .location_labels = &.{},
        .writable = false,
    },
};

/// Whether the metric can be on `r`: Google's metric on its one type, a
/// user metric on any it may be written to.
fn canBeOn(d: *const FakeMonitoring.Descriptor, r: *const CatalogType) bool {
    if (d.google) |g| return std.mem.eql(u8, r.type, g.resource_type);
    return r.writable;
}

/// Whether a resource the metric can be on has a label `key`: the type
/// the filter names, or any.
fn resourceLabelKnown(d: *const FakeMonitoring.Descriptor, named: ?*const CatalogType, key: []const u8) bool {
    if (named) |r| return r.hasLabel(key);
    for (&catalog) |*r| if (canBeOn(d, r) and r.hasLabel(key)) return true;
    return false;
}

// Google's own metrics it knows: Pub/Sub's.

/// One of Google's own metrics, on one resource type.
const GoogleMetric = struct {
    type: []const u8,
    kind: types.Kind,
    value_type: types.ValueType,
    unit: []const u8,
    display_name: []const u8 = "",
    description: []const u8 = "",
    /// Key and description.
    labels: []const [2][]const u8 = &.{},
    resource_type: []const u8,

    fn hasLabel(g: *const GoogleMetric, key: []const u8) bool {
        for (g.labels) |l| if (std.mem.eql(u8, l[0], key)) return true;
        return false;
    }
};

const delivery_type = .{ "delivery_type", "Delivery mechanism: push, pull or streaming pull." };
const response_code = .{ "response_code", "Operation response code string, derived as a string representation of a status code (e.g., 'success', 'not_found', 'unavailable')." };

/// Pub/Sub's metrics a console reads, as production described them on
/// 2026-10-19 (issue #239).
const google_metrics = [_]GoogleMetric{
    .{
        .type = "pubsub.googleapis.com/subscription/num_undelivered_messages",
        .kind = .gauge,
        .value_type = .int64,
        .unit = "1",
        .display_name = "Unacked messages",
        .description = "Number of unacknowledged messages (a.k.a. backlog messages) in a subscription.",
        .resource_type = "pubsub_subscription",
    },
    .{
        .type = "pubsub.googleapis.com/subscription/oldest_unacked_message_age",
        .kind = .gauge,
        .value_type = .int64,
        .unit = "s",
        .display_name = "Oldest unacked message age",
        .description = "Age (in seconds) of the oldest unacknowledged message (a.k.a. backlog message) in a subscription.",
        .resource_type = "pubsub_subscription",
    },
    .{
        .type = "pubsub.googleapis.com/subscription/sent_message_count",
        .kind = .delta,
        .value_type = .int64,
        .unit = "1",
        .display_name = "Sent message count",
        .description = "Cumulative count of messages sent by Cloud Pub/Sub to subscriber clients, grouped by delivery type.",
        .labels = &.{delivery_type},
        .resource_type = "pubsub_subscription",
    },
    .{
        .type = "pubsub.googleapis.com/subscription/ack_message_count",
        .kind = .delta,
        .value_type = .int64,
        .unit = "1",
        .display_name = "Ack message count",
        .description = "Cumulative count of messages acknowledged by Acknowledge requests, grouped by delivery type. Dead-lettered messages may show up as pull acks.",
        .labels = &.{.{ "delivery_type", "Delivery mechanism: push, pull, streaming pull, or filter." }},
        .resource_type = "pubsub_subscription",
    },
    .{
        .type = "pubsub.googleapis.com/subscription/expired_ack_deadlines_count",
        .kind = .delta,
        .value_type = .int64,
        .unit = "1",
        .display_name = "Expired ack deadlines count",
        .description = "Cumulative count of messages whose ack deadline expired while the message was outstanding to a subscriber client.",
        .labels = &.{delivery_type},
        .resource_type = "pubsub_subscription",
    },
    .{
        .type = "pubsub.googleapis.com/subscription/dead_letter_message_count",
        .kind = .delta,
        .value_type = .int64,
        .unit = "1",
        .display_name = "Dead letter message count",
        .description = "Cumulative count of messages published to dead letter topic, grouped by result.",
        .labels = &.{response_code},
        .resource_type = "pubsub_subscription",
    },
    .{
        .type = "pubsub.googleapis.com/subscription/push_request_count",
        .kind = .delta,
        .value_type = .int64,
        .unit = "1",
        .display_name = "Push requests",
        .description = "Cumulative count of push attempts, grouped by result. Unlike pulls, the push server implementation does not batch user messages. So each request only contains one user message. The push server retries on errors, so a given user message can appear multiple times.",
        .labels = &.{
            .{ "response_class", "A classification group for the response code. It can be one of ['ack', 'deadline_exceeded', 'internal', 'invalid', 'remote_server_4xx', 'remote_server_5xx', 'unreachable']." },
            response_code,
            .{ "delivery_type", "Push delivery mechanism." },
        },
        .resource_type = "pubsub_subscription",
    },
    .{
        .type = "pubsub.googleapis.com/topic/send_message_operation_count",
        .kind = .delta,
        .value_type = .int64,
        .unit = "1",
        .display_name = "Publish message operations",
        .description = "Cumulative count of publish message operations, grouped by result. This metric is deprecated. Apply a count aggregator on topic/message_sizes instead.",
        .labels = &.{response_code},
        .resource_type = "pubsub_topic",
    },
    .{
        .type = "pubsub.googleapis.com/topic/byte_cost",
        .kind = .delta,
        .value_type = .int64,
        .unit = "By",
        .display_name = "Topic byte cost",
        .description = "Cost of operations, measured in bytes. This is used to measure utilization for quotas.",
        .labels = &.{ .{ "operation_type", "Type of operation performed." }, response_code },
        .resource_type = "pubsub_topic",
    },
};

comptime {
    // A read aligns a DELTA metric's values as numbers, and its 400s name
    // the value type.
    for (google_metrics) |g| if (g.kind == .delta and g.value_type != .int64) @compileError(g.type ++ ": the fake aligns only INT64 DELTA metrics");
}

/// Whether `metric_type` is under a domain of Google's the fake holds
/// metrics of, which no program writes or creates.
fn googleDomain(metric_type: []const u8) bool {
    return std.mem.startsWith(u8, metric_type, "pubsub.googleapis.com/");
}

fn catalogType(name: []const u8) ?*const CatalogType {
    for (&catalog) |*c| if (std.mem.eql(u8, c.type, name)) return c;
    return null;
}

/// A region or a zone as Google names them: `us-central1`,
/// `europe-west1-b`, `northamerica-northeast2`, or `global`. Production
/// refused `nowhere-1`; this is the fake's own reading of the rest.
fn isLocation(text: []const u8) bool {
    if (std.mem.eql(u8, text, "global")) return true;
    var parts = std.mem.splitScalar(u8, text, '-');
    const area = parts.next().?;
    const place = parts.next() orelse return false;
    const zone = parts.next();
    if (parts.next() != null) return false;
    if (area.len == 0 or !allLower(area)) return false;
    // Letters, then at least one digit.
    var i: usize = 0;
    while (i < place.len and std.ascii.isLower(place[i])) i += 1;
    if (i == 0 or i == place.len) return false;
    for (place[i..]) |c| if (!std.ascii.isDigit(c)) return false;
    if (zone) |z| if (z.len != 1 or !std.ascii.isLower(z[0])) return false;
    return true;
}

fn allLower(text: []const u8) bool {
    for (text) |c| if (!std.ascii.isLower(c)) return false;
    return true;
}

// Request parsing.

fn parseJson(arena: Allocator, body: []const u8) ?JsonValue {
    return std.json.parseFromSliceLeaky(JsonValue, arena, body, .{ .parse_numbers = false }) catch null;
}

fn stringField(o: std.json.ObjectMap, name: []const u8) ?[]const u8 {
    const v = o.get(name) orelse return null;
    return if (v == .string) v.string else null;
}

fn objectField(o: std.json.ObjectMap, name: []const u8) ?std.json.ObjectMap {
    const v = o.get(name) orelse return null;
    return if (v == .object) v.object else null;
}

/// The `labels` object as pairs, in the order sent; null when it is not
/// an object of strings.
fn labelsOf(arena: Allocator, o: std.json.ObjectMap) Allocator.Error!?[]const types.Label {
    const v = o.get("labels") orelse return &.{};
    if (v != .object) return null;
    const out = try arena.alloc(types.Label, v.object.count());
    for (v.object.keys(), v.object.values(), out) |k, val, *l| {
        if (val != .string) return null;
        l.* = .{ .key = k, .value = val.string };
    }
    return out;
}

fn parseValue(arena: Allocator, o: std.json.ObjectMap) Allocator.Error!?types.Value {
    if (o.count() != 1) return null;
    const name = o.keys()[0];
    const v = o.values()[0];
    if (std.mem.eql(u8, name, "boolValue")) return if (v == .bool) .{ .bool = v.bool } else null;
    if (std.mem.eql(u8, name, "int64Value")) return .{ .int64 = intOf(i64, v) orelse return null };
    if (std.mem.eql(u8, name, "doubleValue")) return .{ .double = doubleOf(v) orelse return null };
    if (std.mem.eql(u8, name, "stringValue")) return if (v == .string) .{ .string = v.string } else null;
    if (std.mem.eql(u8, name, "distributionValue")) {
        if (v != .object) return null;
        return .{ .distribution = try distributionOf(arena, v.object) orelse return null };
    }
    return null;
}

fn intOf(comptime T: type, v: JsonValue) ?T {
    const text = switch (v) {
        .number_string, .string => |s| s,
        else => return null,
    };
    return std.fmt.parseInt(T, text, 10) catch null;
}

fn doubleOf(v: JsonValue) ?f64 {
    switch (v) {
        .string => |s| {
            if (std.mem.eql(u8, s, "NaN")) return std.math.nan(f64);
            if (std.mem.eql(u8, s, "Infinity")) return std.math.inf(f64);
            if (std.mem.eql(u8, s, "-Infinity")) return -std.math.inf(f64);
            return null;
        },
        // A JSON number's own text, so never "inf" or hex.
        .number_string => |s| return std.fmt.parseFloat(f64, s) catch null,
        else => return null,
    }
}

fn distributionOf(arena: Allocator, o: std.json.ObjectMap) Allocator.Error!?types.Distribution {
    var d: types.Distribution = .{ .buckets = undefined };
    if (o.get("count")) |c| d.count = intOf(u64, c) orelse return null;
    if (o.get("mean")) |m| d.mean = doubleOf(m) orelse return null;
    if (o.get("sumOfSquaredDeviation")) |m| d.sum_of_squared_deviation = doubleOf(m) orelse return null;
    const options = objectField(o, "bucketOptions") orelse return null;
    if (options.count() != 1) return null;
    const layout = options.values()[0];
    if (layout != .object) return null;
    const name = options.keys()[0];
    if (std.mem.eql(u8, name, "linearBuckets")) {
        d.buckets = .{ .linear = .{
            .num_finite = intOf(u32, layout.object.get("numFiniteBuckets") orelse return null) orelse return null,
            .width = if (layout.object.get("width")) |w| doubleOf(w) orelse return null else 0,
            .offset = if (layout.object.get("offset")) |w| doubleOf(w) orelse return null else 0,
        } };
    } else if (std.mem.eql(u8, name, "exponentialBuckets")) {
        d.buckets = .{ .exponential = .{
            .num_finite = intOf(u32, layout.object.get("numFiniteBuckets") orelse return null) orelse return null,
            .growth_factor = if (layout.object.get("growthFactor")) |w| doubleOf(w) orelse return null else 0,
            .scale = if (layout.object.get("scale")) |w| doubleOf(w) orelse return null else 0,
        } };
    } else if (std.mem.eql(u8, name, "explicitBuckets")) {
        const bounds_v = layout.object.get("bounds") orelse return null;
        if (bounds_v != .array) return null;
        const bounds = try arena.alloc(f64, bounds_v.array.items.len);
        for (bounds_v.array.items, bounds) |b, *out| out.* = doubleOf(b) orelse return null;
        d.buckets = .{ .explicit = bounds };
    } else return null;
    if (o.get("bucketCounts")) |counts_v| {
        if (counts_v != .array) return null;
        const counts = try arena.alloc(u64, counts_v.array.items.len);
        for (counts_v.array.items, counts) |c, *out| out.* = intOf(u64, c) orelse return null;
        d.bucket_counts = counts;
    }
    return d;
}

/// What production refused about a distribution that the fake was not
/// measured against: the client's own checks, not the server's.
fn unmodelledDistribution(d: types.Distribution) ?[]const u8 {
    var copy = d;
    // The two rules production was measured on are judged per point.
    copy.bucket_counts = &.{};
    if (copy.buckets == .linear and !(copy.buckets.linear.width > 0)) copy.buckets.linear.width = 1;
    if (validate.distributionProblem(copy)) |_| return "a distribution rule production was not asked about";
    if (d.bucket_counts.len > d.buckets.total()) return "a distribution rule production was not asked about";
    return null;
}

// Answers.

/// What makes production refuse to create a descriptor, in its words.
/// Never called for one of Google's.
fn creationRefusal(arena: Allocator, metric_type: []const u8, kind: types.Kind, value_type: types.ValueType, labels: []const types.LabelDescriptor) Allocator.Error!?FakeMonitoring.Reply {
    // DELTA and STRING, refused as custom metrics under
    // custom.googleapis.com/ and workload.googleapis.com/, and as external
    // ones under external.googleapis.com/, on 2026-10-19.
    const what = if (std.mem.startsWith(u8, metric_type, "external.googleapis.com/")) "external" else "custom";
    if (kind == .delta) return try fail(arena, 400, "INVALID_ARGUMENT", try arena.print("Field metricDescriptor.metricKind had an invalid value of \"DELTA\": When creating metric {s}: the DELTA metric kind is not supported for {s} metrics.", .{ metric_type, what }));
    if (value_type == .string) return try fail(arena, 400, "INVALID_ARGUMENT", try arena.print("Field metricDescriptor.valueType had an invalid value of \"STRING\": When creating metric {s}: the value type is not supported for {s} metrics.", .{ metric_type, what }));
    for (labels, 0..) |l, i| {
        if (l.key.len > validate.max_label_key_len) return try fail(arena, 400, "INVALID_ARGUMENT", try arena.print("Field labels[{d}].key had an invalid value of \"{s}\": When creating metric {s}:  the label key is more than 100 characters long.", .{ i, l.key, metric_type }));
        if (!validate.isLabelKey(l.key)) return try notModelled(arena, "a label key production was not asked about in a create");
    }
    return null;
}

fn fail(arena: Allocator, code: u16, status: []const u8, message: []const u8) Allocator.Error!FakeMonitoring.Reply {
    return .{ .status = code, .body = try Stringify.valueAlloc(arena, .{ .@"error" = .{
        .code = code,
        .message = message,
        .status = status,
    } }, .{}) };
}

/// Production's answer to a write or a create of one of Google's metrics.
fn noPermission(arena: Allocator, metric_type: []const u8) Allocator.Error!FakeMonitoring.Reply {
    return fail(arena, 403, "PERMISSION_DENIED", try arena.print("User does not have permission to write to metric {s}.", .{metric_type}));
}

/// Production's answer to an aligner the metric's kind and value type do
/// not take.
fn misaligned(arena: Allocator, aligner: types.Aligner, d: *const FakeMonitoring.Descriptor) Allocator.Error!FakeMonitoring.Reply {
    return fail(arena, 400, "INVALID_ARGUMENT", try arena.print("Field aggregation.perSeriesAligner had an invalid value of \"{s}\": The aligner cannot be applied to metrics with kind {s} and value type {s}.", .{ aligner.wire(), d.kind.wire(), d.value_type.wire() }));
}

fn descriptorNotFound(arena: Allocator, metric_type: []const u8) Allocator.Error!FakeMonitoring.Reply {
    return fail(arena, 404, "NOT_FOUND", try arena.print("Could not find descriptor for metric '{s}'.", .{metric_type}));
}

fn missingSeries(arena: Allocator) Allocator.Error!FakeMonitoring.Reply {
    return fail(arena, 400, "INVALID_ARGUMENT", "Request was missing field timeSeries.");
}

/// The fake's own words: production was not asked about a body that is
/// not JSON or not of the API's shape.
fn invalidJson(arena: Allocator) Allocator.Error!FakeMonitoring.Reply {
    return fail(arena, 400, "INVALID_ARGUMENT", "Invalid JSON payload received.");
}

fn pageTokenRefusal(arena: Allocator) Allocator.Error!FakeMonitoring.Reply {
    return fail(arena, 400, "INVALID_ARGUMENT", "The page token is not valid.");
}

fn notModelled(arena: Allocator, what: []const u8) Allocator.Error!FakeMonitoring.Reply {
    return fail(arena, 501, "UNIMPLEMENTED", try arena.print("fake: {s} is not modelled yet", .{what}));
}

fn refusal(arena: Allocator, status: u16) Allocator.Error!FakeMonitoring.Reply {
    const name = switch (status) {
        400 => "INVALID_ARGUMENT",
        401 => "UNAUTHENTICATED",
        403 => "PERMISSION_DENIED",
        404 => "NOT_FOUND",
        409 => "ABORTED",
        429 => "RESOURCE_EXHAUSTED",
        500 => "INTERNAL",
        503 => "UNAVAILABLE",
        504 => "DEADLINE_EXCEEDED",
        else => "UNKNOWN",
    };
    return fail(arena, status, name, "fake: refused as the test asked");
}

fn asking(arena: Allocator, reply: FakeMonitoring.Reply, delay: ?core.retry_after.Asked) Allocator.Error!FakeMonitoring.Reply {
    const d = delay orelse return reply;
    return .{ .status = reply.status, .headers = try d.headers(arena), .body = try d.intoBody(arena, reply.body) };
}

// Small helpers.

fn writeLabelDescriptor(jw: *Stringify, l: types.LabelDescriptor) Stringify.Error!void {
    try jw.beginObject();
    try jw.objectField("key");
    try jw.write(l.key);
    if (l.value_type != .string) {
        try jw.objectField("valueType");
        try jw.write(l.value_type.wire());
    }
    if (l.description.len > 0) {
        try jw.objectField("description");
        try jw.write(l.description);
    }
    try jw.endObject();
}

/// `{"k": "v", ...}`, as production names labels in a message.
fn writeLabelMap(w: *std.Io.Writer, labels: []const types.Label) std.Io.Writer.Error!void {
    try w.writeByte('{');
    for (labels, 0..) |l, i| {
        if (i > 0) try w.writeAll(", ");
        try w.print("\"{s}\": \"{s}\"", .{ l.key, l.value });
    }
    try w.writeByte('}');
}

fn labelValue(labels: []const types.Label, key: []const u8) ?[]const u8 {
    for (labels) |l| if (std.mem.eql(u8, l.key, key)) return l.value;
    return null;
}

fn sortedLabels(arena: Allocator, labels: []const types.Label) Allocator.Error![]types.Label {
    const out = try arena.dupe(types.Label, labels);
    std.mem.sort(types.Label, out, {}, struct {
        fn lessThan(_: void, a: types.Label, b: types.Label) bool {
            return std.mem.lessThan(u8, a.key, b.key);
        }
    }.lessThan);
    return out;
}

fn withoutProject(arena: Allocator, labels: []const types.Label) Allocator.Error![]const types.Label {
    var out: std.ArrayList(types.Label) = .empty;
    for (labels) |l| if (!std.mem.eql(u8, l.key, "project_id")) try out.append(arena, l);
    return out.items;
}

fn labelsEqual(a: []const types.Label, b: []const types.Label) bool {
    if (a.len != b.len) return false;
    for (a, b) |x, y| if (!std.mem.eql(u8, x.key, y.key) or !std.mem.eql(u8, x.value, y.value)) return false;
    return true;
}

fn dupeLabels(arena: Allocator, labels: []const types.Label) Allocator.Error![]const types.Label {
    const out = try arena.alloc(types.Label, labels.len);
    for (labels, out) |l, *o| o.* = .{ .key = try arena.dupe(u8, l.key), .value = try arena.dupe(u8, l.value) };
    return out;
}

fn dupeLabelDescriptor(arena: Allocator, l: types.LabelDescriptor) Allocator.Error!types.LabelDescriptor {
    return .{ .key = try arena.dupe(u8, l.key), .value_type = l.value_type, .description = try arena.dupe(u8, l.description) };
}

/// A series' identity as one string: its metric type and sorted labels,
/// its resource type and sorted labels but `project_id`.
fn identity(arena: Allocator, s: FakeMonitoring.Sent) Allocator.Error![]const u8 {
    return identityOf(arena, s.metric_type, s.metric_labels, s.resource_type, s.resource_labels);
}

fn identityOf(arena: Allocator, metric_type: []const u8, metric_labels: []const types.Label, resource_type: []const u8, resource_labels: []const types.Label) Allocator.Error![]const u8 {
    var out: std.Io.Writer.Allocating = .init(arena);
    const w = &out.writer;
    w.writeAll(metric_type) catch return error.OutOfMemory;
    for (try sortedLabels(arena, metric_labels)) |l| w.print("\x00{s}\x01{s}", .{ l.key, l.value }) catch return error.OutOfMemory;
    w.print("\x02{s}", .{resource_type}) catch return error.OutOfMemory;
    for (try withoutProject(arena, try sortedLabels(arena, resource_labels))) |l| w.print("\x00{s}\x01{s}", .{ l.key, l.value }) catch return error.OutOfMemory;
    return out.written();
}

fn sameSent(a: FakeMonitoring.Sent, b: FakeMonitoring.Sent) bool {
    if (!std.mem.eql(u8, a.metric_type, b.metric_type) or !std.mem.eql(u8, a.resource_type, b.resource_type)) return false;
    return sameSet(a.metric_labels, b.metric_labels) and sameSet(a.resource_labels, b.resource_labels);
}

/// The same labels in any order, `project_id` aside.
fn sameSet(a: []const types.Label, b: []const types.Label) bool {
    var counted: usize = 0;
    for (a) |x| {
        if (std.mem.eql(u8, x.key, "project_id")) continue;
        const y = labelValue(b, x.key) orelse return false;
        if (!std.mem.eql(u8, x.value, y)) return false;
        counted += 1;
    }
    var others: usize = 0;
    for (b) |y| {
        if (!std.mem.eql(u8, y.key, "project_id")) others += 1;
    }
    return counted == others;
}

/// To the microsecond, as production keeps times.
fn truncated(ns: i96) i96 {
    return @divFloor(ns, std.time.ns_per_us) * std.time.ns_per_us;
}

/// Whether `s` is `last` again: its start, if it has one, and its value.
fn samePoint(last: FakeMonitoring.Point, s: FakeMonitoring.Sent) bool {
    if (last.start) |st| if (s.start == null or truncated(s.start.?) != st.nanoseconds) return false;
    return sameValue(last.value, s.value);
}

fn sameValue(a: types.Value, b: types.Value) bool {
    if (std.meta.activeTag(a) != std.meta.activeTag(b)) return false;
    return switch (a) {
        .bool => |x| x == b.bool,
        .int64 => |x| x == b.int64,
        .double => |x| @as(u64, @bitCast(x)) == @as(u64, @bitCast(b.double)),
        .string => |x| std.mem.eql(u8, x, b.string),
        .distribution => |x| x.count == b.distribution.count and x.mean == b.distribution.mean and
            x.sum_of_squared_deviation == b.distribution.sum_of_squared_deviation and
            std.mem.eql(u64, x.bucket_counts, b.distribution.bucket_counts),
    };
}

fn copyValue(arena: Allocator, v: types.Value) Allocator.Error!types.Value {
    return switch (v) {
        .string => |s| .{ .string = try arena.dupe(u8, s) },
        .distribution => |d| .{ .distribution = .{
            .count = d.count,
            .mean = d.mean,
            .sum_of_squared_deviation = d.sum_of_squared_deviation,
            .buckets = switch (d.buckets) {
                .explicit => |b| .{ .explicit = try arena.dupe(f64, b) },
                else => d.buckets,
            },
            .bucket_counts = try arena.dupe(u64, d.bucket_counts),
        } },
        else => v,
    };
}

/// A duration as production wrote one in a message: hours, minutes and
/// seconds, each left out when 0, the seconds' fraction to the millisecond
/// without trailing zeros: "5m59.949s", "26h0.051s", "25h10s".
const Duration = struct {
    ns: i96,

    pub fn format(d: Duration, w: *std.Io.Writer) std.Io.Writer.Error!void {
        const ms: u64 = @intCast(@divFloor(@max(d.ns, 0), std.time.ns_per_ms));
        const hours = ms / std.time.ms_per_hour;
        const minutes = (ms / std.time.ms_per_min) % 60;
        const seconds = (ms / std.time.ms_per_s) % 60;
        const millis = ms % std.time.ms_per_s;
        if (ms == 0) return w.writeAll("0");
        if (hours > 0) try w.print("{d}h", .{hours});
        if (minutes > 0) try w.print("{d}m", .{minutes});
        if (seconds > 0 or millis > 0) {
            try w.print("{d}", .{seconds});
            if (millis > 0) {
                var frac: [3]u8 = undefined;
                _ = std.fmt.bufPrint(&frac, "{d:0>3}", .{millis}) catch unreachable;
                var n: usize = 3;
                while (frac[n - 1] == '0') n -= 1;
                try w.print(".{s}", .{frac[0..n]});
            }
            try w.writeByte('s');
        }
    }
};

/// A time as production wrote one in a too-frequent message,
/// "2026/10/18-06:46:35.949", here in UTC.
const Stamp = struct {
    ns: i96,

    pub fn format(s: Stamp, w: *std.Io.Writer) std.Io.Writer.Error!void {
        var buf: [core.timestamp.max_len]u8 = undefined;
        const text = core.timestamp.format(&buf, .{ .nanoseconds = s.ns });
        // "YYYY-MM-DDTHH:MM:SS[.fff...]Z"
        const ms: u64 = @intCast(@divFloor(@mod(s.ns, std.time.ns_per_s), std.time.ns_per_ms));
        try w.print("{s}/{s}/{s}-{s}.{d:0>3}", .{ text[0..4], text[5..7], text[8..10], text[11..19], ms });
    }
};

const testing = std.testing;
const test_util = @import("test_util.zig");
const production = @import("production_bodies.zig");
const Client = @import("Client.zig");

/// 2026-10-18T13:46:35.949Z, about when milestone 0 ran.
const now_ns: i96 = 1_792_331_195_949 * std.time.ns_per_ms;

/// A client wired to a fake, on a fake clock. Initialize in place.
const Bench = struct {
    clock: test_util.FakeClock,
    fake: FakeMonitoring,
    token: core.StaticToken,
    diag: core.Diagnostics,
    client: Client,

    fn init(b: *Bench, options: FakeMonitoring.Options) !void {
        b.* = .{ .clock = .{ .now_ns = now_ns }, .fake = undefined, .token = .{ .token = "t" }, .diag = .{}, .client = undefined };
        b.fake = .init(testing.allocator, b.clock.io(), options);
        errdefer b.fake.deinit();
        b.client = try .init(testing.allocator, b.clock.io(), .{
            .project_id = options.project_id,
            .token_provider = b.token.provider(),
            .transport = b.fake.transport(),
            .diagnostics = &b.diag,
            .retry = .{ .max_attempts = 3, .initial_backoff_ms = 1, .max_backoff_ms = 1_000 },
        });
    }

    fn deinit(b: *Bench) void {
        b.client.deinit();
        b.fake.deinit();
    }

    /// `ms` milliseconds from the bench's start.
    fn at(b: *const Bench, ms: i64) std.Io.Timestamp {
        _ = b;
        return .{ .nanoseconds = now_ns + @as(i96, ms) * std.time.ns_per_ms };
    }

    fn raw(b: *Bench, arena: Allocator, method: tp.Method, path: []const u8, body: ?[]const u8) !FakeMonitoring.Reply {
        const url = try std.fmt.allocPrint(arena, "https://monitoring.googleapis.com/v3/projects/{s}/{s}", .{ b.fake.options.project_id, path });
        return b.fake.serve(.{ .method = method, .url = url, .bearer = "t", .body = body }, arena);
    }
};

const probe_task: types.Resource = .{ .generic_task = .{ .location = "us-central1", .namespace = "zigps", .job = "m0", .task_id = "62b2c8-a" } };

fn gaugeAt(metric_type: []const u8, labels: []const types.Label, end: std.Io.Timestamp, value: i64) types.TimeSeries {
    return .{ .metric_type = metric_type, .metric_labels = labels, .resource = probe_task, .kind = .gauge, .end = end, .value = .{ .int64 = value } };
}

/// The reason after the series a production refusal names.
fn reasonOf(message: []const u8) []const u8 {
    const at = std.mem.indexOf(u8, message, "}): ") orelse return message;
    return message[at + 4 ..];
}

/// The message in an error body.
fn messageOf(arena: Allocator, body: []const u8) ![]const u8 {
    const v = try std.json.parseFromSliceLeaky(JsonValue, arena, body, .{});
    return v.object.get("error").?.object.get("message").?.string;
}

/// Writes `series` and returns the reason of its only refusal.
fn refusedReason(b: *Bench, series: []const types.TimeSeries) ![]const u8 {
    var result = try b.client.write(series);
    defer result.deinit();
    try testing.expect(!result.value.ok());
    const copy = try testing.allocator.dupe(u8, reasonOf(result.value.message));
    return copy;
}

test "a write is kept, and makes its descriptor as production made one" {
    var b: Bench = undefined;
    try b.init(.{});
    defer b.deinit();
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const end: std.Io.Timestamp = .{ .nanoseconds = now_ns + 123_456_789 };
    var result = try b.client.write(&.{.{ .metric_type = "custom.googleapis.com/shop/depth", .metric_labels = &.{.{ .key = "region", .value = "eu" }}, .resource = probe_task, .kind = .gauge, .unit = "{item}", .end = end, .value = .{ .int64 = 7 } }});
    defer result.deinit();
    try testing.expect(result.value.ok());
    const kept = try b.fake.points(a, "custom.googleapis.com/shop/depth", &.{.{ .key = "region", .value = "eu" }});
    try testing.expectEqual(1, kept.len);
    // Microseconds, as production keeps them.
    try testing.expectEqual(now_ns + 123_456_000, kept[0].end.nanoseconds);
    try testing.expectEqual(null, kept[0].start);
    try testing.expectEqual(7, kept[0].value.int64);
    try testing.expectEqual(0, (try b.fake.points(a, "custom.googleapis.com/shop/depth", &.{})).len);

    var info = try b.client.metric("custom.googleapis.com/shop/depth").get();
    defer info.deinit();
    try testing.expectEqual(types.Kind.gauge, info.value.kind);
    try testing.expectEqual(types.ValueType.int64, info.value.value_type);
    try testing.expectEqualStrings("{item}", info.value.unit);
    try testing.expectEqual(types.LabelType.string, info.value.label("region").?.value_type);
    try testing.expectEqual(7, info.value.resource_types.len);

    // A label it lacks is added by a write.
    var more = try b.client.write(&.{.{ .metric_type = "custom.googleapis.com/shop/depth", .metric_labels = &.{ .{ .key = "region", .value = "eu" }, .{ .key = "zone", .value = "b" } }, .resource = probe_task, .kind = .gauge, .end = end, .value = .{ .int64 = 8 } }});
    more.deinit();
    const d = (try b.fake.descriptor(a, "custom.googleapis.com/shop/depth")).?;
    try testing.expectEqual(2, d.labels.len);
    try testing.expectEqualStrings("zone", d.labels[1].key);
    try testing.expectEqual(2, b.fake.seriesCount());
    try testing.expectEqual(2, b.fake.pointCount());

    // A write without kind or value type: GAUGE and the value's type.
    const untyped = try b.raw(a, .POST, "timeSeries",
        \\{"timeSeries":[{"metric":{"type":"custom.googleapis.com/untyped"},"resource":{"type":"global"},"points":[{"interval":{"endTime":"2026-10-18T13:46:35.949Z"},"value":{"doubleValue":"NaN"}}]}]}
    );
    try testing.expectEqual(200, untyped.status);
    const auto = (try b.fake.descriptor(a, "custom.googleapis.com/untyped")).?;
    try testing.expectEqual(types.Kind.gauge, auto.kind);
    try testing.expectEqual(types.ValueType.double, auto.value_type);
    try testing.expect(std.math.isNan((try b.fake.points(a, "custom.googleapis.com/untyped", &.{}))[0].value.double));
}

test "refusals of a point, in production's words" {
    var b: Bench = undefined;
    try b.init(.{ .project_id = "extractctl" });
    defer b.deinit();
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const g = "custom.googleapis.com/zigps-m0-62b2c8/gauge";

    // Out of order: a point 10 s before the series' last.
    var first = try b.client.write(&.{gaugeAt(g, &.{.{ .key = "k", .value = "order" }}, b.at(20_000), 1)});
    first.deinit();
    const order = try refusedReason(&b, &.{gaugeAt(g, &.{.{ .key = "k", .value = "order" }}, b.at(10_000), 2)});
    defer testing.allocator.free(order);
    try testing.expectEqualStrings(reasonOf(try messageOf(a, production.write_out_of_order)), order);

    // Another value type and another kind than the descriptor's.
    var dbl = gaugeAt(g, &.{.{ .key = "k", .value = "vt" }}, b.at(0), 0);
    dbl.value = .{ .double = 1.5 };
    const vt = try refusedReason(&b, &.{dbl});
    defer testing.allocator.free(vt);
    try testing.expectEqualStrings(reasonOf(try messageOf(a, production.write_wrong_value_type)), vt);
    var cum = gaugeAt(g, &.{.{ .key = "k", .value = "kind" }}, b.at(0), 1);
    cum.kind = .cumulative;
    cum.start = b.at(-30_000);
    const kind = try refusedReason(&b, &.{cum});
    defer testing.allocator.free(kind);
    try testing.expectEqualStrings(reasonOf(try messageOf(a, production.write_wrong_kind)), kind);

    // A location that is not one.
    var loc = gaugeAt(g, &.{.{ .key = "k", .value = "loc" }}, b.at(0), 1);
    loc.resource = .{ .generic_task = .{ .location = "nowhere-1", .namespace = "zigps", .job = "m0", .task_id = "62b2c8" } };
    const location = try refusedReason(&b, &.{loc});
    defer testing.allocator.free(location);
    try testing.expectEqualStrings(reasonOf(try messageOf(a, production.write_unknown_location)), location);

    // Six minutes ahead and 26 hours back: production's sentences, this
    // fake's clock.
    const ahead = try refusedReason(&b, &.{gaugeAt(g, &.{.{ .key = "k", .value = "ahead" }}, b.at(6 * 60_000), 1)});
    defer testing.allocator.free(ahead);
    try testing.expectEqualStrings("Field points[0].interval.end_time had an invalid value of \"2026-10-18T13:52:35.949Z\": Data points cannot be written more than 5m into the future. Your data point is 6m after the present time, which is too far in the future.", ahead);
    try testing.expect(std.mem.indexOf(u8, reasonOf(try messageOf(a, production.write_ahead)), "Data points cannot be written more than 5m into the future. Your data point is ") != null);
    const back = try refusedReason(&b, &.{gaugeAt(g, &.{.{ .key = "k", .value = "back" }}, b.at(-26 * 3_600_000 - 51), 1)});
    defer testing.allocator.free(back);
    try testing.expectEqualStrings("Field points[0].interval.end_time had an invalid value of \"2026-10-17T11:46:35.898Z\": Data points cannot be written more than approximately 24 hours in the past, specifically no more than 25h10s in the past. Your data point is 26h0.051s before the present time, which is too far in the past.", back);
    try testing.expect(std.mem.endsWith(u8, reasonOf(try messageOf(a, production.write_back)), "Your data point is 26h0.051s before the present time, which is too far in the past."));

    // Too soon after the series' last: production's sentence, UTC times.
    var freq = try b.client.write(&.{gaugeAt(g, &.{.{ .key = "k", .value = "freq" }}, b.at(0), 1)});
    freq.deinit();
    var again = try b.client.write(&.{gaugeAt(g, &.{.{ .key = "k", .value = "freq" }}, b.at(1_000), 2)});
    defer again.deinit();
    try testing.expectEqual(error.FailedPrecondition, again.value.refused[0].reason);
    try testing.expectEqualStrings("write for resource failed: One or more points were written more frequently than the maximum sampling period configured for the metric. {Metric: custom.googleapis.com/zigps-m0-62b2c8/gauge, Timestamps: {Youngest Existing: '2026/10/18-13:46:35.949', New: '2026/10/18-13:46:36.949'}}", reasonOf(again.value.message));
    try testing.expect(std.mem.startsWith(u8, reasonOf(try messageOf(a, production.write_too_frequent)), "write for resource failed: One or more points were written more frequently than the maximum sampling period configured for the metric. {Metric: custom.googleapis.com/zigps-m0-62b2c8/gauge, Timestamps: {Youngest Existing: '2026/10/18-"));
}

test "refusals of a point the client would not send, in production's words" {
    var b: Bench = undefined;
    try b.init(.{ .project_id = "extractctl" });
    defer b.deinit();
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const resource = "\"resource\":{\"type\":\"generic_task\",\"labels\":{\"location\":\"us-central1\",\"namespace\":\"zigps\",\"job\":\"m0\",\"task_id\":\"b66e4f-a\"}}";
    const Case = struct { body: []const u8, production: []const u8 };
    const cases = [_]Case{
        .{ .body = "{\"metric\":{\"type\":\"custom.googleapis.com/zigps-m0b-b66e4f/gauge2\",\"labels\":{\"k\":\"" ++ test_util.repeat("v", 1025) ++ "\"}}," ++ resource ++ ",\"metricKind\":\"GAUGE\",\"valueType\":\"INT64\",\"points\":[{\"interval\":{\"endTime\":\"2026-10-18T13:46:35Z\"},\"value\":{\"int64Value\":\"1\"}}]}", .production = production.write_label_value_long },
        .{ .body = "{\"metric\":{\"type\":\"custom.googleapis.com/zigps-m0b-b66e4f/keys\",\"labels\":{\"1k\":\"v\"}}," ++ resource ++ ",\"metricKind\":\"GAUGE\",\"valueType\":\"INT64\",\"points\":[{\"interval\":{\"endTime\":\"2026-10-18T13:46:35Z\"},\"value\":{\"int64Value\":\"1\"}}]}", .production = production.write_label_key_digit },
        .{ .body = "{\"metric\":{\"type\":\"custom.googleapis.com/zigps-m0b-b66e4f/str2\"}," ++ resource ++ ",\"metricKind\":\"GAUGE\",\"valueType\":\"STRING\",\"points\":[{\"interval\":{\"endTime\":\"2026-10-18T13:46:35Z\"},\"value\":{\"stringValue\":\"" ++ test_util.repeat("s", 1025) ++ "\"}}]}", .production = production.write_string_long },
        .{ .body = "{\"metric\":{\"type\":\"custom.googleapis.com/zigps-m0b-b66e4f/dist\"}," ++ resource ++ ",\"metricKind\":\"GAUGE\",\"valueType\":\"DISTRIBUTION\",\"points\":[{\"interval\":{\"endTime\":\"2026-10-18T13:46:35Z\"},\"value\":{\"distributionValue\":{\"count\":\"4\",\"mean\":2.0,\"sumOfSquaredDeviation\":2.0,\"bucketOptions\":{\"explicitBuckets\":{\"bounds\":[1,2,3]}},\"bucketCounts\":[\"0\",\"1\",\"1\",\"1\"]}}}]}", .production = production.write_distribution_count },
        .{ .body = "{\"metric\":{\"type\":\"custom.googleapis.com/zigps-m0b-b66e4f/dist\"}," ++ resource ++ ",\"metricKind\":\"GAUGE\",\"valueType\":\"DISTRIBUTION\",\"points\":[{\"interval\":{\"endTime\":\"2026-10-18T13:46:35Z\"},\"value\":{\"distributionValue\":{\"count\":\"1\",\"mean\":5.0,\"bucketOptions\":{\"linearBuckets\":{\"numFiniteBuckets\":2,\"width\":0,\"offset\":0}},\"bucketCounts\":[\"0\",\"1\"]}}}]}", .production = production.write_linear_width },
        .{ .body = "{\"metric\":{\"type\":\"custom.googleapis.com/zigps-m0-62b2c8/gauge\",\"labels\":{\"k\":\"res\"}},\"resource\":{\"type\":\"generic_task\",\"labels\":{\"location\":\"us-central1\",\"job\":\"m0\",\"task_id\":\"62b2c8\"}},\"metricKind\":\"GAUGE\",\"valueType\":\"INT64\",\"points\":[{\"interval\":{\"endTime\":\"2026-10-18T13:46:35Z\"},\"value\":{\"int64Value\":\"1\"}}]}", .production = production.write_missing_label },
    };
    for (cases) |c| {
        const reply = try b.raw(a, .POST, "timeSeries", try std.fmt.allocPrint(a, "{{\"timeSeries\":[{s}]}}", .{c.body}));
        try testing.expectEqual(400, reply.status);
        try testing.expectEqualStrings(reasonOf(try messageOf(a, c.production)), reasonOf(try messageOf(a, reply.body)));
    }
    // 31 labels: production's sentence, for this type.
    var labels: std.ArrayList(u8) = .empty;
    for (0..31) |i| try labels.print(a, "{s}\"l{d}\":\"v\"", .{ if (i == 0) "" else ",", i });
    const many = try b.raw(a, .POST, "timeSeries", try std.fmt.allocPrint(a, "{{\"timeSeries\":[{{\"metric\":{{\"type\":\"custom.googleapis.com/zigps-m0b-b66e4f/l31\",\"labels\":{{{s}}}}},{s},\"points\":[{{\"interval\":{{\"endTime\":\"2026-10-18T13:46:35Z\"}},\"value\":{{\"int64Value\":\"1\"}}}}]}}]}}", .{ labels.items, resource }));
    try testing.expectEqualStrings(reasonOf(try messageOf(a, production.write_31_labels)), reasonOf(try messageOf(a, many.body)));

    // A gauge with a start, a cumulative without an interval.
    const gauge_start = try b.raw(a, .POST, "timeSeries", "{\"timeSeries\":[{\"metric\":{\"type\":\"custom.googleapis.com/g\"}," ++ resource ++ ",\"metricKind\":\"GAUGE\",\"points\":[{\"interval\":{\"startTime\":\"2026-10-18T13:46:05.949Z\",\"endTime\":\"2026-10-18T13:46:35.949Z\"},\"value\":{\"int64Value\":\"1\"}}]}]}");
    try testing.expectEqualStrings("Field points[0].interval.start_time had an invalid value of \"2026-10-18T13:46:05.949Z\": The start time must be equal to the end time (2026-10-18T13:46:35.949Z) for the gauge metric 'custom.googleapis.com/g'.", reasonOf(try messageOf(a, gauge_start.body)));
    try testing.expect(std.mem.indexOf(u8, reasonOf(try messageOf(a, production.write_gauge_start)), "The start time must be equal to the end time (") != null);
    const flat = try b.raw(a, .POST, "timeSeries", "{\"timeSeries\":[{\"metric\":{\"type\":\"custom.googleapis.com/c\"}," ++ resource ++ ",\"metricKind\":\"CUMULATIVE\",\"points\":[{\"interval\":{\"startTime\":\"2026-10-18T13:46:35.949Z\",\"endTime\":\"2026-10-18T13:46:35.949Z\"},\"value\":{\"int64Value\":\"1\"}}]}]}");
    try testing.expectEqualStrings("Field points[0].interval.start_time had an invalid value of \"2026-10-18T13:46:35.949Z\": The start time must be before the end time (2026-10-18T13:46:35.949Z) for the non-gauge metric 'custom.googleapis.com/c'.", reasonOf(try messageOf(a, flat.body)));
    try testing.expect(std.mem.indexOf(u8, reasonOf(try messageOf(a, production.write_cumulative_no_interval)), "The start time must be before the end time (") != null);
    try testing.expectEqual(0, b.fake.pointCount());
}

test "a request refused whole, in production's words" {
    var b: Bench = undefined;
    try b.init(.{ .project_id = "extractctl" });
    defer b.deinit();
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const one = "{\"metric\":{\"type\":\"custom.googleapis.com/m\"},\"resource\":{\"type\":\"global\"},\"points\":[{\"interval\":{\"endTime\":\"2026-10-18T13:46:35Z\"},\"value\":{\"int64Value\":\"1\"}}]}";
    var many: std.ArrayList(u8) = .empty;
    try many.appendSlice(a, "{\"timeSeries\":[");
    for (0..201) |i| try many.print(a, "{s}{s}", .{ if (i == 0) "" else ",", one });
    try many.appendSlice(a, "]}");
    const cases = [_]struct { []const u8, []const u8 }{
        .{ "{\"timeSeries\":[]}", production.write_empty },
        .{ "{}", production.write_empty },
        .{ many.items, production.write_201_series },
        .{ "{\"timeSeries\":[{\"metric\":{\"type\":\"custom.googleapis.com/zigps-m0-62b2c8/delta\"},\"resource\":{\"type\":\"global\"},\"metricKind\":\"DELTA\",\"valueType\":\"INT64\",\"points\":[{\"interval\":{\"startTime\":\"2026-10-18T13:46:25Z\",\"endTime\":\"2026-10-18T13:46:35Z\"},\"value\":{\"int64Value\":\"1\"}}]}]}", production.write_delta_custom },
        .{ "{\"timeSeries\":[{\"metric\":{\"type\":\"custom.googleapis.com/zigps-m0b-b66e4f/str\"},\"resource\":{\"type\":\"global\"},\"metricKind\":\"GAUGE\",\"valueType\":\"STRING\",\"points\":[{\"interval\":{\"endTime\":\"2026-10-18T13:46:35Z\"},\"value\":{\"stringValue\":\"hi\"}}]}]}", production.write_string_custom },
        .{ "{\"timeSeries\":[{\"metric\":{\"type\":\"custom.googleapis.com/zigps-m0b-b66e4f/keys\",\"labels\":{\"" ++ test_util.repeat("k", 101) ++ "\":\"v\"}},\"resource\":{\"type\":\"global\"},\"points\":[{\"interval\":{\"endTime\":\"2026-10-18T13:46:35Z\"},\"value\":{\"int64Value\":\"1\"}}]}]}", production.write_label_key_long },
        .{ "{\"timeSeries\":[{\"metric\":{\"type\":\"custom.googleapis.com/m\",\"labels\":{\"k\":\"pid\"}},\"resource\":{\"type\":\"generic_task\",\"labels\":{\"project_id\":\"other-project\",\"location\":\"us-central1\",\"namespace\":\"zigps\",\"job\":\"m0\",\"task_id\":\"b66e4f\"}},\"points\":[{\"interval\":{\"endTime\":\"2026-10-18T13:46:35Z\"},\"value\":{\"int64Value\":\"1\"}}]}]}", production.write_foreign_project },
    };
    for (cases) |c| {
        const reply = try b.raw(a, .POST, "timeSeries", c[0]);
        try testing.expectEqual(400, reply.status);
        try testing.expectEqualStrings(try messageOf(a, c[1]), try messageOf(a, reply.body));
        try testing.expect(std.mem.indexOf(u8, reply.body, "CreateTimeSeriesSummary") == null);
    }
    try testing.expectEqual(0, b.fake.pointCount());
    try testing.expectEqual(null, try b.fake.descriptor(a, "custom.googleapis.com/zigps-m0-62b2c8/delta"));
    // Its own project is taken.
    const own = try b.raw(a, .POST, "timeSeries", "{\"timeSeries\":[{\"metric\":{\"type\":\"custom.googleapis.com/m\"},\"resource\":{\"type\":\"generic_task\",\"labels\":{\"project_id\":\"extractctl\",\"location\":\"us-central1\",\"namespace\":\"\",\"job\":\"m0\",\"task_id\":\"b66e4f\"}},\"points\":[{\"interval\":{\"endTime\":\"2026-10-18T13:46:35Z\"},\"value\":{\"int64Value\":\"1\"}}]}]}");
    try testing.expectEqual(200, own.status);
}

test "a mixed write: production's summary, the good points kept" {
    var b: Bench = undefined;
    try b.init(.{ .project_id = "extractctl" });
    defer b.deinit();
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const g = "custom.googleapis.com/zigps-m0-62b2c8/gauge";
    const reply = try b.raw(a, .POST, "timeSeries", try codecWrite(a, &.{
        gaugeAt(g, &.{.{ .key = "k", .value = "mix1" }}, b.at(0), 1),
        gaugeAt(g, &.{.{ .key = "k", .value = "mix2" }}, b.at(0), 1),
        gaugeAt(g, &.{.{ .key = "k", .value = "mix3" }}, b.at(6 * 60_000), 1),
    }));
    try testing.expectEqual(400, reply.status);
    const got = try std.json.parseFromSliceLeaky(JsonValue, a, reply.body, .{});
    const want = try std.json.parseFromSliceLeaky(JsonValue, a, production.write_mixed, .{});
    const ge = got.object.get("error").?.object;
    const we = want.object.get("error").?.object;
    try testing.expectEqualStrings(we.get("status").?.string, ge.get("status").?.string);
    try testing.expectEqual(we.get("code").?.integer, ge.get("code").?.integer);
    try testing.expect(std.mem.startsWith(u8, ge.get("message").?.string, "One or more TimeSeries could not be written: timeSeries[2] (metric.type=\"custom.googleapis.com/zigps-m0-62b2c8/gauge\", metric.labels={\"k\": \"mix3\"}, resource.type=\"generic_task\", resource.labels={"));
    var got_detail: std.Io.Writer.Allocating = .init(a);
    try std.json.Stringify.value(ge.get("details").?, .{}, &got_detail.writer);
    var want_detail: std.Io.Writer.Allocating = .init(a);
    try std.json.Stringify.value(we.get("details").?, .{}, &want_detail.writer);
    try testing.expectEqualStrings(want_detail.written(), got_detail.written());
    try testing.expectEqual(2, b.fake.pointCount());

    // The same series twice: the first written, the second refused.
    const dup = try b.raw(a, .POST, "timeSeries", try codecWrite(a, &.{
        gaugeAt(g, &.{.{ .key = "k", .value = "dup" }}, b.at(0), 1),
        gaugeAt(g, &.{.{ .key = "k", .value = "dup" }}, b.at(0), 1),
    }));
    try testing.expectEqualStrings(reasonOf(try messageOf(a, production.write_duplicate)), reasonOf(try messageOf(a, dup.body)));
    try testing.expect(std.mem.indexOf(u8, dup.body, "\"successPointCount\":1") != null);
    try testing.expect(std.mem.indexOf(u8, dup.body, "timeSeries[1]") != null);
    try testing.expectEqual(3, b.fake.pointCount());
}

fn codecWrite(a: Allocator, series: []const types.TimeSeries) ![]u8 {
    return @import("codec.zig").encodeWrite(a, series);
}

test "the sampling floor is 2.5 s from the series' last point, as production held it" {
    var b: Bench = undefined;
    try b.init(.{});
    defer b.deinit();
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const g = "custom.googleapis.com/floor";
    const labels: []const types.Label = &.{.{ .key = "k", .value = "a" }};
    // Each gap counted from the last point kept.
    const steps = [_]struct { i64, i64, bool }{
        .{ 0, 1, true },
        .{ 2_499, 1, false },
        .{ 2_500, 1, true },
        // The same point again: taken, and kept once, as production did.
        .{ 2_500, 1, true },
        // The same end with another value: too soon after itself.
        .{ 2_500, 2, false },
        .{ 4_999, 1, false },
        .{ 5_000, 1, true },
        .{ 1_000, 1, false }, // older: out of order
    };
    for (steps) |s| {
        var result = try b.client.write(&.{gaugeAt(g, labels, b.at(s[0]), s[1])});
        defer result.deinit();
        try testing.expectEqual(s[2], result.value.ok());
        if (!result.value.ok() and s[0] == 2_500) try testing.expectEqual(error.FailedPrecondition, result.value.refused[0].reason);
    }
    const kept = try b.fake.points(a, g, labels);
    try testing.expectEqual(3, kept.len);
    try testing.expectEqual(b.at(5_000).nanoseconds, kept[2].end.nanoseconds);
}

test "a cumulative series keeps its start, and starts over after its last end" {
    var b: Bench = undefined;
    try b.init(.{ .project_id = "extractctl" });
    defer b.deinit();
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const c = "custom.googleapis.com/zigps-m0b-b66e4f/cum";
    const cum = struct {
        fn at(bench: *const Bench, start: i64, end: i64, value: i64) types.TimeSeries {
            return .{ .metric_type = c, .resource = probe_task, .kind = .cumulative, .start = bench.at(start), .end = bench.at(end), .value = .{ .int64 = value } };
        }
    };
    var first = try b.client.write(&.{cum.at(&b, -120_000, -60_000, 10)});
    first.deinit();
    const earlier = try refusedReason(&b, &.{cum.at(&b, -150_000, -30_000, 20)});
    defer testing.allocator.free(earlier);
    try testing.expectEqualStrings(reasonOf(try messageOf(a, production.write_cumulative_earlier)), earlier);
    // A total that falls under the same start is taken, as production
    // took 10, 5, 7 and 0 on 2026-10-18.
    var falls = try b.client.write(&.{cum.at(&b, -120_000, -30_000, 2)});
    defer falls.deinit();
    try testing.expect(falls.value.ok());
    var more = try b.client.write(&.{cum.at(&b, -120_000, -25_000, 12)});
    defer more.deinit();
    try testing.expect(more.value.ok());
    // A reset: a new start 1 ms after the last end.
    var reset = try b.client.write(&.{cum.at(&b, -24_999, -20_000, 1)});
    defer reset.deinit();
    try testing.expect(reset.value.ok());
    const kept = try b.fake.points(a, c, &.{});
    try testing.expectEqual(4, kept.len);
    try testing.expectEqual(2, kept[1].value.int64);
    try testing.expectEqual(b.at(-24_999).nanoseconds, kept[3].start.?.nanoseconds);
    // A start moved later, inside the last interval: production took one
    // and lost a point; the fake says it does not model it.
    try testing.expectError(error.Unimplemented, b.client.write(&.{cum.at(&b, -22_000, -10_000, 5)}));
    try testing.expect(std.mem.indexOf(u8, b.diag.message(), "cumulative start moved later") != null);
    try testing.expectEqual(4, b.fake.pointCount());
}

test "descriptors: created, made again, refused with another kind, read, listed and deleted" {
    var b: Bench = undefined;
    try b.init(.{ .project_id = "extractctl" });
    defer b.deinit();
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const g = b.client.metric("custom.googleapis.com/zigps-m0b-b66e4f/gauge");
    var made = try g.create(.{ .kind = .gauge, .value_type = .int64, .unit = "1", .description = "zig-gcp milestone 0 probe", .labels = &.{.{ .key = "k" }} });
    made.deinit();
    var again = try g.create(.{ .kind = .gauge, .value_type = .int64, .unit = "By", .labels = &.{ .{ .key = "k" }, .{ .key = "n", .value_type = .int64 } } });
    defer again.deinit();
    try testing.expectEqualStrings("By", again.value.unit);
    try testing.expectEqual(types.LabelType.int64, again.value.label("n").?.value_type);
    try testing.expectError(error.AlreadyExists, g.create(.{ .kind = .cumulative, .value_type = .int64, .labels = &.{.{ .key = "k" }} }));
    try testing.expectEqualStrings(try messageOf(a, production.descriptor_other_kind), b.diag.message());

    // As production wrote one: the same fields, the name with the project.
    var read = try g.get();
    defer read.deinit();
    try testing.expectEqualStrings("custom.googleapis.com/zigps-m0b-b66e4f/gauge", read.value.type);
    const body = try b.raw(a, .GET, "metricDescriptors/custom.googleapis.com/zigps-m0b-b66e4f/gauge", null);
    try testing.expect(std.mem.startsWith(u8, body.body, "{\"name\":\"projects/extractctl/metricDescriptors/custom.googleapis.com/zigps-m0b-b66e4f/gauge\",\"labels\":[{\"key\":\"k\"}"));

    try testing.expectError(error.NotFound, b.client.metric("custom.googleapis.com/zigps-m0-62b2c8/gauge").get());
    try testing.expectEqualStrings(try messageOf(a, production.descriptor_missing), b.diag.message());
    try testing.expectError(error.NotFound, b.client.metric("custom.googleapis.com/zigps-m0b-b66e4f/nothing").delete());
    try testing.expectEqualStrings(try messageOf(a, production.descriptor_delete_missing), b.diag.message());
    const encoded = try b.raw(a, .GET, "metricDescriptors/custom.googleapis.com%2Fzigps-m0-62b2c8%2Fgauge", null);
    try testing.expectEqual(production.descriptor_encoded_slash_status, encoded.status);
    try testing.expectEqualStrings(try messageOf(a, production.descriptor_encoded_slash), try messageOf(a, encoded.body));

    // Listed by prefix, sorted, in pages; active ones only when asked.
    for ([_][]const u8{ "custom.googleapis.com/shop/c", "custom.googleapis.com/shop/a", "custom.googleapis.com/other", "custom.googleapis.com/shop/b" }) |t| {
        var m = try b.client.metric(t).create(.{ .kind = .gauge, .value_type = .double });
        m.deinit();
    }
    var w = try b.client.write(&.{.{ .metric_type = "custom.googleapis.com/shop/b", .resource = .global, .kind = .gauge, .end = b.at(0), .value = .{ .double = 1 } }});
    w.deinit();
    var page = try b.client.listMetrics(.{ .prefix = "custom.googleapis.com/shop/", .page_size = 2 });
    defer page.deinit();
    try testing.expectEqual(2, page.value.metrics.len);
    try testing.expectEqualStrings("custom.googleapis.com/shop/a", page.value.metrics[0].type);
    var rest = try b.client.listMetrics(.{ .prefix = "custom.googleapis.com/shop/", .page_size = 2, .page_token = page.value.next_page_token });
    defer rest.deinit();
    try testing.expectEqual(1, rest.value.metrics.len);
    try testing.expectEqualStrings("custom.googleapis.com/shop/c", rest.value.metrics[0].type);
    try testing.expectEqual(null, rest.value.next_page_token);
    var active = try b.client.listMetrics(.{ .active_only = true });
    defer active.deinit();
    try testing.expectEqual(1, active.value.metrics.len);
    // Google's own are listed too, as production lists them.
    var all = try b.client.listMetrics(.{});
    defer all.deinit();
    try testing.expectEqual(5 + google_metrics.len, all.value.metrics.len);
    try testing.expectError(error.InvalidArgument, b.client.listMetrics(.{ .page_token = "nonsense" }));

    // Deleting a descriptor makes its data unreadable.
    try b.client.metric("custom.googleapis.com/shop/b").delete();
    try testing.expectEqual(0, b.fake.pointCount());
    try testing.expectEqual(0, (try b.fake.points(a, "custom.googleapis.com/shop/b", &.{})).len);
}

test "a create production refuses, in its words" {
    var b: Bench = undefined;
    try b.init(.{ .project_id = "extractctl" });
    defer b.deinit();
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const delta = try b.raw(a, .POST, "metricDescriptors", "{\"type\":\"custom.googleapis.com/zigps-m0-62b2c8/delta\",\"metricKind\":\"DELTA\",\"valueType\":\"INT64\"}");
    try testing.expectEqualStrings(try messageOf(a, production.write_delta_custom), try messageOf(a, delta.body));
    const string = try b.raw(a, .POST, "metricDescriptors", "{\"type\":\"custom.googleapis.com/zigps-m0b-b66e4f/str\",\"metricKind\":\"GAUGE\",\"valueType\":\"STRING\"}");
    try testing.expectEqualStrings(try messageOf(a, production.write_string_custom), try messageOf(a, string.body));
    const key = try b.raw(a, .POST, "metricDescriptors", "{\"type\":\"custom.googleapis.com/zigps-m0b-b66e4f/keys\",\"metricKind\":\"GAUGE\",\"valueType\":\"INT64\",\"labels\":[{\"key\":\"" ++ test_util.repeat("k", 101) ++ "\"}]}");
    try testing.expectEqualStrings(try messageOf(a, production.write_label_key_long), try messageOf(a, key.body));
    const long_type = try b.raw(a, .POST, "metricDescriptors", "{\"type\":\"custom.googleapis.com/" ++ test_util.repeat("x", 491) ++ "\",\"metricKind\":\"GAUGE\",\"valueType\":\"INT64\"}");
    try testing.expectEqual(400, long_type.status);
    try testing.expect(std.mem.endsWith(u8, try messageOf(a, long_type.body), "the metric type is more than 512 characters long."));
    for ([_][]const u8{ "{\"metricKind\":\"GAUGE\"}", "{\"type\":\"custom.googleapis.com/x\"}", "{\"type\":\"custom.googleapis.com/x\",\"metricKind\":\"GAUGE\",\"valueType\":\"INT64\",\"labels\":[{\"key\":\"1k\"}]}" }) |body| {
        try testing.expectEqual(501, (try b.raw(a, .POST, "metricDescriptors", body)).status);
    }
    for ([_][]const u8{ "", "[", "[]", "{\"type\":\"custom.googleapis.com/x\",\"metricKind\":\"GAUGE\",\"valueType\":\"INT64\",\"labels\":{}}" }) |body| {
        try testing.expectEqual(400, (try b.raw(a, .POST, "metricDescriptors", body)).status);
    }
}

test "resource types: generic_task as production wrote it, the others, and one that is not" {
    var b: Bench = undefined;
    try b.init(.{ .project_id = "extractctl" });
    defer b.deinit();
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var generic = try b.client.resourceType("generic_task");
    defer generic.deinit();
    const want = try @import("codec.zig").decodeResourceType(a, a, production.resource_generic_task);
    try testing.expectEqualStrings(want.display_name, generic.value.display_name);
    try testing.expectEqualStrings(want.description, generic.value.description);
    try testing.expectEqual(want.labels.len, generic.value.labels.len);
    for (want.labels, generic.value.labels) |w, g| {
        try testing.expectEqualStrings(w.key, g.key);
        try testing.expectEqualStrings(w.description, g.description);
    }
    try testing.expectError(error.NotFound, b.client.resourceType("no_such_type"));
    try testing.expectEqualStrings(try messageOf(a, production.resource_missing), b.diag.message());
    var page = try b.client.listResourceTypes(.{ .page_size = 3 });
    defer page.deinit();
    try testing.expectEqual(3, page.value.types.len);
    var rest = try b.client.listResourceTypes(.{ .page_token = page.value.next_page_token });
    defer rest.deinit();
    try testing.expectEqual(6, rest.value.types.len);
    try testing.expectEqual(null, rest.value.next_page_token);
    // Every named resource writes; .other's types are not modelled.
    const resources = [_]types.Resource{
        .global,
        .{ .generic_node = .{ .location = "europe-west1-b", .namespace = "n", .node_id = "x" } },
        .{ .gce_instance = .{ .zone = "us-central1-a", .instance_id = "1" } },
        .{ .k8s_container = .{ .location = "asia-east2", .cluster_name = "c", .namespace_name = "n", .pod_name = "p", .container_name = "x" } },
        .{ .k8s_pod = .{ .location = "northamerica-northeast2", .cluster_name = "c", .namespace_name = "n", .pod_name = "p" } },
        .{ .k8s_node = .{ .location = "global", .cluster_name = "c", .node_name = "n" } },
    };
    for (resources) |r| {
        var result = try b.client.write(&.{.{ .metric_type = "custom.googleapis.com/every", .resource = r, .kind = .gauge, .end = b.at(0), .value = .{ .bool = true } }});
        defer result.deinit();
        try testing.expect(result.value.ok());
    }
    try testing.expectEqual(resources.len, b.fake.seriesCount());
    try testing.expectError(error.Unimplemented, b.client.write(&.{.{ .metric_type = "custom.googleapis.com/every", .resource = .{ .other = .{ .type = "aws_ec2_instance" } }, .kind = .gauge, .end = b.at(0), .value = .{ .bool = true } }}));
}

test "faults: refused, dropped, and served but answered with an error" {
    var b: Bench = undefined;
    try b.init(.{});
    defer b.deinit();
    const g = "custom.googleapis.com/faults";
    b.fake.refuseNext(1, 503);
    try testing.expectError(error.Unavailable, b.client.write(&.{gaugeAt(g, &.{}, b.at(0), 1)}));
    b.fake.dropNext(1);
    try testing.expectError(error.ConnectionResetByPeer, b.client.write(&.{gaugeAt(g, &.{}, b.at(0), 1)}));
    try testing.expectEqual(0, b.fake.pointCount());
    // A 504 that stored the point.
    b.fake.loseNext(1, 504);
    try testing.expectError(error.DeadlineExceeded, b.client.write(&.{gaugeAt(g, &.{}, b.at(0), 1)}));
    try testing.expectEqual(1, b.fake.pointCount());
    b.client.write_retries = .transient;
    b.fake.loseNext(1, 504);
    // Tried again, the same point is taken and kept once, as production
    // took a point sent twice on 2026-10-18.
    var replayed = try b.client.write(&.{gaugeAt(g, &.{}, b.at(5_000), 2)});
    defer replayed.deinit();
    try testing.expect(replayed.value.ok());
    try testing.expectEqual(2, b.fake.pointCount());
    b.fake.refuseNextWithDelay(1, 429, .{ .ms = 3, .form = .retry_after_ms });
    var after_delay = try b.client.write(&.{gaugeAt(g, &.{}, b.at(10_000), 3)});
    after_delay.deinit();
    try testing.expectEqual(3, b.fake.pointCount());
    // Refused, dropped, lost; lost then replayed; refused then retried.
    try testing.expectEqual(7, b.fake.callCount());
}

test "what the fake does not answer: no credentials, another project, other paths" {
    var b: Bench = undefined;
    try b.init(.{});
    defer b.deinit();
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const anonymous = try b.fake.serve(.{ .method = .GET, .url = "https://monitoring.googleapis.com/v3/projects/my-project/metricDescriptors" }, a);
    try testing.expectEqual(401, anonymous.status);
    const other = try b.fake.serve(.{ .method = .GET, .url = "https://monitoring.googleapis.com/v3/projects/someone-else/metricDescriptors", .bearer = "t" }, a);
    try testing.expectEqual(501, other.status);
    for ([_]struct { tp.Method, []const u8 }{
        .{ .DELETE, "timeSeries" },
        .{ .PUT, "metricDescriptors" },
        .{ .PATCH, "metricDescriptors/custom.googleapis.com/x" },
        .{ .POST, "monitoredResourceDescriptors" },
        .{ .POST, "timeSeries/x" },
        .{ .GET, "alertPolicies" },
    }) |c| try testing.expectEqual(501, (try b.raw(a, c[0], c[1], "{}")).status);
    try testing.expectEqual(400, (try b.raw(a, .GET, "metricDescriptors?pageSize", null)).status);
    try testing.expectEqual(501, (try b.raw(a, .GET, "metricDescriptors?filter=metric.type%3D%22x%22", null)).status);
    // Malformed writes.
    for ([_][]const u8{
        "",
        "{\"timeSeries\":{}}",
        "{\"timeSeries\":[1]}",
        "{\"timeSeries\":[{\"metric\":{\"type\":\"custom.googleapis.com/m\"},\"resource\":{\"type\":\"global\"},\"points\":[{\"interval\":{\"endTime\":\"yesterday\"},\"value\":{\"int64Value\":\"1\"}}]}]}",
        "{\"timeSeries\":[{\"metric\":{\"type\":\"custom.googleapis.com/m\"},\"resource\":{\"type\":\"global\"},\"points\":[{\"interval\":{\"endTime\":\"2026-10-18T13:46:35Z\"},\"value\":{\"int64Value\":\"x\"}}]}]}",
        "{\"timeSeries\":[{\"metric\":{\"type\":\"custom.googleapis.com/m\",\"labels\":{\"k\":1}},\"resource\":{\"type\":\"global\"},\"points\":[{\"interval\":{\"endTime\":\"2026-10-18T13:46:35Z\"},\"value\":{\"int64Value\":\"1\"}}]}]}",
    }) |body| try testing.expectEqual(400, (try b.raw(a, .POST, "timeSeries", body)).status);
    for ([_][]const u8{
        "{\"timeSeries\":[{\"metric\":{\"type\":\"custom.googleapis.com/m\"},\"resource\":{\"type\":\"global\"},\"points\":[]}]}",
        "{\"timeSeries\":[{\"metric\":{\"type\":\"custom.googleapis.com/m\"},\"resource\":{\"type\":\"global\"},\"metricKind\":\"SUMMARY\",\"points\":[{\"interval\":{\"endTime\":\"2026-10-18T13:46:35Z\"},\"value\":{\"int64Value\":\"1\"}}]}]}",
        "{\"timeSeries\":[{\"metric\":{\"type\":\"custom.googleapis.com/m\"},\"resource\":{\"type\":\"global\"},\"points\":[{\"interval\":{\"endTime\":\"2026-10-18T13:46:35Z\"},\"value\":{\"distributionValue\":{\"bucketOptions\":{\"explicitBuckets\":{\"bounds\":[2,1]}}}}}]}]}",
    }) |body| try testing.expectEqual(501, (try b.raw(a, .POST, "timeSeries", body)).status);
}

test "Duration and Stamp write times as production's messages do" {
    var buf: [64]u8 = undefined;
    const cases = [_]struct { i96, []const u8 }{
        .{ (5 * 60 + 59) * std.time.ns_per_s + 949 * std.time.ns_per_ms, "5m59.949s" },
        .{ 26 * std.time.ns_per_hour + 51 * std.time.ns_per_ms, "26h0.051s" },
        .{ (25 * 3600 + 10) * std.time.ns_per_s, "25h10s" },
        .{ 6 * std.time.ns_per_min, "6m" },
        .{ 500 * std.time.ns_per_ms, "0.5s" },
        .{ 0, "0" },
    };
    for (cases) |c| try testing.expectEqualStrings(c[1], try std.fmt.bufPrint(&buf, "{f}", .{Duration{ .ns = c[0] }}));
    try testing.expectEqualStrings("2026/10/18-13:46:35.949", try std.fmt.bufPrint(&buf, "{f}", .{Stamp{ .ns = now_ns }}));
    try testing.expectEqualStrings("2026/10/18-13:46:35.000", try std.fmt.bufPrint(&buf, "{f}", .{Stamp{ .ns = now_ns - 949 * std.time.ns_per_ms }}));
}

test "isLocation: regions, zones and global" {
    for ([_][]const u8{ "us-central1", "europe-west1-b", "northamerica-northeast2", "asia-east2-a", "global" }) |ok| try testing.expect(isLocation(ok));
    for ([_][]const u8{ "nowhere-1", "", "us", "us-central", "US-central1", "us-central1-ab", "us-central1-b-c", "-central1", "us-1central" }) |bad| try testing.expect(!isLocation(bad));
}

test "corners: two refusal codes in one summary, falling doubles, layouts, display names" {
    var b: Bench = undefined;
    try b.init(.{});
    defer b.deinit();
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const g = "custom.googleapis.com/corners";

    // A refusal of each code: the first one's status, both counted.
    var first = try b.client.write(&.{gaugeAt(g, &.{.{ .key = "k", .value = "a" }}, b.at(0), 1)});
    first.deinit();
    var both = try b.client.write(&.{
        gaugeAt(g, &.{.{ .key = "k", .value = "a" }}, b.at(1_000), 2),
        gaugeAt(g, &.{.{ .key = "k", .value = "b" }}, b.at(6 * 60_000), 2),
        gaugeAt(g, &.{.{ .key = "k", .value = "c" }}, b.at(9 * 60_000), 2),
    });
    defer both.deinit();
    try testing.expectEqual(0, both.value.written);
    try testing.expectEqual(2, both.value.refused.len);
    try testing.expectEqual(error.FailedPrecondition, both.value.refused[0].reason);
    try testing.expectEqual(1, both.value.refused[0].points);
    try testing.expectEqual(error.InvalidArgument, both.value.refused[1].reason);
    try testing.expectEqual(2, both.value.refused[1].points);
    try testing.expectEqualStrings("FAILED_PRECONDITION", b.diag.status());

    // A cumulative double, and a distribution, whose totals fell: taken.
    const cum: types.TimeSeries = .{ .metric_type = "custom.googleapis.com/seconds", .resource = probe_task, .kind = .cumulative, .start = b.at(-60_000), .end = b.at(-30_000), .value = .{ .double = 2.5 } };
    var ok = try b.client.write(&.{cum});
    ok.deinit();
    var lower = cum;
    lower.end = b.at(-20_000);
    lower.value = .{ .double = 1 };
    var fell_double = try b.client.write(&.{lower});
    defer fell_double.deinit();
    try testing.expect(fell_double.value.ok());
    const layout: types.Distribution.Buckets = .{ .exponential = .{ .num_finite = 3, .growth_factor = 2, .scale = 1 } };
    var dist = cum;
    dist.metric_type = "custom.googleapis.com/latency";
    dist.value = .{ .distribution = .{ .count = 2, .mean = 3, .buckets = layout, .bucket_counts = &.{ 0, 1, 1 } } };
    var d1 = try b.client.write(&.{dist});
    d1.deinit();
    dist.end = b.at(-20_000);
    dist.value = .{ .distribution = .{ .count = 1, .mean = 3, .buckets = layout, .bucket_counts = &.{ 0, 1 } } };
    var fell_count = try b.client.write(&.{dist});
    defer fell_count.deinit();
    try testing.expect(fell_count.value.ok());
    const kept = try b.fake.points(a, "custom.googleapis.com/latency", &.{});
    try testing.expectEqual(2, kept[0].value.distribution.count);
    try testing.expectEqual(2.0, kept[0].value.distribution.buckets.exponential.growth_factor);
    var latency = try b.client.metric("custom.googleapis.com/latency").read(.{ .start = b.at(-60_000), .end = b.at(0) });
    defer latency.deinit();
    // The older point, as written first: points come newest first.
    const read_back = latency.value.series[0].points[1].value.?.distribution;
    try testing.expectEqual(3, read_back.buckets.exponential.num_finite);
    try testing.expectEqual(2.0, read_back.buckets.exponential.growth_factor);
    try testing.expectEqual(1.0, read_back.buckets.exponential.scale);
    try testing.expectEqualSlices(u64, &.{ 0, 1, 1 }, read_back.bucket_counts);
    var linear = dist;
    linear.metric_type = "custom.googleapis.com/sizes";
    linear.value = .{ .distribution = .{ .buckets = .{ .linear = .{ .num_finite = 2, .width = 10, .offset = 0 } } } };
    var l1 = try b.client.write(&.{linear});
    l1.deinit();
    try testing.expectEqual(10.0, (try b.fake.points(a, "custom.googleapis.com/sizes", &.{}))[0].value.distribution.buckets.linear.width);

    // A display name, written back.
    var named = try b.client.metric("custom.googleapis.com/named").create(.{ .kind = .gauge, .value_type = .bool, .display_name = "Named" });
    defer named.deinit();
    try testing.expectEqualStrings("Named", named.value.display_name);

    // Deleting one metric keeps the others' points.
    const before = b.fake.pointCount();
    try b.client.metric("custom.googleapis.com/seconds").delete();
    try testing.expectEqual(before - 2, b.fake.pointCount());

    // Doubles spelled as production spells what JSON cannot.
    for ([_][]const u8{ "Infinity", "-Infinity" }, 0..) |spelled, i| {
        const body = try std.fmt.allocPrint(a, "{{\"timeSeries\":[{{\"metric\":{{\"type\":\"custom.googleapis.com/inf\",\"labels\":{{\"i\":\"{d}\"}}}},\"resource\":{{\"type\":\"global\"}},\"points\":[{{\"interval\":{{\"endTime\":\"2026-10-18T13:46:35Z\"}},\"value\":{{\"doubleValue\":\"{s}\"}}}}]}}]}}", .{ i, spelled });
        try testing.expectEqual(200, (try b.raw(a, .POST, "timeSeries", body)).status);
    }
    try testing.expect(std.math.isInf((try b.fake.points(a, "custom.googleapis.com/inf", &.{.{ .key = "i", .value = "1" }}))[0].value.double));
    for ([_][]const u8{ "{\"doubleValue\":true}", "{\"doubleValue\":\"inf\"}", "{\"moneyValue\":{}}", "{\"int64Value\":\"1\",\"boolValue\":true}", "{\"distributionValue\":{\"bucketOptions\":{}}}", "{\"distributionValue\":{\"bucketOptions\":{\"linearBuckets\":{}}}}" }) |value| {
        const body = try std.fmt.allocPrint(a, "{{\"timeSeries\":[{{\"metric\":{{\"type\":\"custom.googleapis.com/bad\"}},\"resource\":{{\"type\":\"global\"}},\"points\":[{{\"interval\":{{\"endTime\":\"2026-10-18T13:46:35Z\"}},\"value\":{s}}}]}}]}}", .{value});
        try testing.expectEqual(400, (try b.raw(a, .POST, "timeSeries", body)).status);
    }
    // A key past 100 bytes for a metric that exists: not measured.
    const long_key = try b.raw(a, .POST, "timeSeries", "{\"timeSeries\":[{\"metric\":{\"type\":\"custom.googleapis.com/named\",\"labels\":{\"" ++ test_util.repeat("k", 101) ++ "\":\"v\"}},\"resource\":{\"type\":\"global\"},\"points\":[{\"interval\":{\"endTime\":\"2026-10-18T13:46:35Z\"},\"value\":{\"boolValue\":true}}]}]}");
    try testing.expectEqual(501, long_key.status);
}

/// Writes a gauge point for each (labels, value), each on its own task.
fn seed(b: *Bench, metric_type: []const u8, points: []const struct { []const types.Label, i64, i64 }) !void {
    for (points, 0..) |p, i| {
        var id: [8]u8 = undefined;
        const task_id = try std.fmt.bufPrint(&id, "t{d}", .{i});
        var result = try b.client.write(&.{.{
            .metric_type = metric_type,
            .metric_labels = p[0],
            .resource = .{ .generic_task = .{ .location = "us-central1", .namespace = "zigps", .job = if (i % 2 == 0) "m0" else "m1", .task_id = task_id } },
            .kind = .gauge,
            .end = b.at(p[1]),
            .value = .{ .int64 = p[2] },
        }});
        defer result.deinit();
        try testing.expect(result.value.ok());
    }
}

test "reads: what a filter selects, newest first, (start, end]" {
    var b: Bench = undefined;
    try b.init(.{});
    defer b.deinit();
    const g = "custom.googleapis.com/reads";
    try seed(&b, g, &.{
        .{ &.{.{ .key = "path", .value = "/api/orders" }}, -60_000, 1 },
        .{ &.{.{ .key = "path", .value = "/web/home" }}, -50_000, 2 },
        .{ &.{.{ .key = "path", .value = "a\"b\\c" }}, -40_000, 3 },
    });
    // A second point for the first series, on its own task.
    var more = try b.client.write(&.{.{ .metric_type = g, .metric_labels = &.{.{ .key = "path", .value = "/api/orders" }}, .resource = .{ .generic_task = .{ .location = "us-central1", .namespace = "zigps", .job = "m0", .task_id = "t0" } }, .kind = .gauge, .end = b.at(-10_000), .value = .{ .int64 = 4 } }});
    more.deinit();
    const m = b.client.metric(g);
    const window: types.ReadOptions = .{ .start = b.at(-120_000), .end = b.at(0) };

    var all = try m.read(window);
    defer all.deinit();
    try testing.expectEqual(3, all.value.series.len);
    var points: usize = 0;
    for (all.value.series) |s| {
        points += s.points.len;
        try testing.expectEqualStrings("my-project", s.resourceLabel("project_id").?);
        try testing.expectEqual(types.Kind.gauge, s.kind);
    }
    try testing.expectEqual(4, points);

    const cases = [_]struct { types.Filter, usize }{
        .{ .{ .metric_labels = &.{.{ .key = "path", .op = .starts_with, .value = "/api" }} }, 1 },
        .{ .{ .metric_labels = &.{.{ .key = "path", .op = .ends_with, .value = "home" }} }, 1 },
        .{ .{ .metric_labels = &.{.{ .key = "path", .op = .has_substring, .value = "/" }} }, 2 },
        .{ .{ .metric_labels = &.{.{ .key = "path", .op = .not_equals, .value = "/web/home" }} }, 2 },
        .{ .{ .metric_labels = &.{.{ .key = "path", .value = "a\"b\\c" }} }, 1 },

        .{ .{ .resource_type = "generic_task", .resource_labels = &.{.{ .key = "job", .value = "m1" }} }, 1 },
        .{ .{ .resource_labels = &.{.{ .key = "project_id", .value = "my-project" }} }, 3 },
        .{ .{ .resource_type = "global" }, 0 },
    };
    for (cases) |c| {
        var opts = window;
        opts.filter = c[0];
        var page = try m.read(opts);
        defer page.deinit();
        try testing.expectEqual(c[1], page.value.series.len);
    }
    // A label the descriptor lacks, and a resource label no resource type
    // has, in production's words.
    var missing = window;
    missing.filter = .{ .metric_labels = &.{.{ .key = "missing", .op = .not_equals, .value = "x" }} };
    try testing.expectError(error.NotFound, m.read(missing));
    try testing.expectEqualStrings("Cannot find metric(s) that match type = \"custom.googleapis.com/reads\" label = \"missing\". If a metric was created recently, it could take up to 10 minutes to become available. Please try again soon.", b.diag.message());
    missing.filter = .{ .resource_labels = &.{.{ .key = "missing", .value = "x" }} };
    try testing.expectError(error.InvalidArgument, m.read(missing));
    try testing.expectEqualStrings("The supplied filter does not specify a valid combination of metric and monitored resource descriptors. The query will not return any time series.", b.diag.message());

    var orders = try m.read(.{ .start = window.start, .end = window.end, .filter = .{ .metric_labels = &.{.{ .key = "path", .value = "/api/orders" }} } });
    defer orders.deinit();
    const p = orders.value.series[0].points;
    try testing.expectEqual(4, p[0].value.?.int64);
    try testing.expectEqual(1, p[1].value.?.int64);
    // The start is out, the end in.
    var narrow = try m.read(.{ .start = b.at(-60_000), .end = b.at(-10_000) });
    defer narrow.deinit();
    var narrow_points: usize = 0;
    for (narrow.value.series) |s| narrow_points += s.points.len;
    try testing.expectEqual(3, narrow_points);
    // With no start, the instant at the end.
    var instant = try m.read(.{ .end = b.at(-40_000) });
    defer instant.deinit();
    try testing.expectEqual(1, instant.value.series.len);
    try testing.expectEqual(3, instant.value.series[0].points[0].value.?.int64);
}

test "reads: a series spans pages of points; headers page by series" {
    var b: Bench = undefined;
    try b.init(.{});
    defer b.deinit();
    const g = "custom.googleapis.com/pages";
    const labels: []const types.Label = &.{.{ .key = "k", .value = "mix1" }};
    for ([_]i64{ -20_000, -10_000, 0 }, 1..) |at, v| {
        var r = try b.client.write(&.{gaugeAt(g, labels, b.at(at), @intCast(v))});
        r.deinit();
    }
    try seed(&b, g, &.{.{ &.{.{ .key = "k", .value = "other" }}, -5_000, 9 }});
    const m = b.client.metric(g);
    var seen: std.ArrayList(i64) = .empty;
    defer seen.deinit(testing.allocator);
    var token: ?[]const u8 = null;
    var pages: usize = 0;
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    while (true) {
        var page = try m.read(.{ .start = b.at(-60_000), .end = b.at(0), .page_size = 2, .page_token = token });
        defer page.deinit();
        pages += 1;
        var on_page: usize = 0;
        for (page.value.series) |s| for (s.points) |pt| {
            try seen.append(testing.allocator, pt.value.?.int64);
            on_page += 1;
        };
        try testing.expect(on_page <= 2);
        token = if (page.value.next_page_token) |t| try arena.allocator().dupe(u8, t) else null;
        if (token == null) break;
    }
    try testing.expectEqual(2, pages);
    try testing.expectEqual(4, seen.items.len);

    var headers = try m.read(.{ .start = b.at(-60_000), .end = b.at(0), .view = .headers, .page_size = 1 });
    defer headers.deinit();
    try testing.expectEqual(1, headers.value.series.len);
    try testing.expectEqual(0, headers.value.series[0].points.len);
    try testing.expect(headers.value.next_page_token != null);
    try testing.expectError(error.InvalidArgument, m.read(.{ .end = b.at(0), .page_token = "p99" }));
}

test "reads: aligned and reduced as production answered, the fake's own reading of the rest" {
    var b: Bench = undefined;
    try b.init(.{});
    defer b.deinit();
    const g = "custom.googleapis.com/aligned";
    var made = try b.client.metric(g).create(.{ .kind = .gauge, .value_type = .int64, .unit = "1", .labels = &.{.{ .key = "region" }} });
    made.deinit();
    try seed(&b, g, &.{
        .{ &.{.{ .key = "region", .value = "eu" }}, -50_000, 30 },
        .{ &.{.{ .key = "region", .value = "eu" }}, -40_000, 20 },
        .{ &.{.{ .key = "region", .value = "us" }}, -30_000, 21 },
        .{ &.{.{ .key = "region", .value = "eu" }}, -90_000, 100 },
    });
    const m = b.client.metric(g);
    // As milestone 0 read: ALIGN_MAX over 60 s, REDUCE_SUM, no group-by:
    // one series, no metric labels, project_id alone, at the read's end.
    var summed = try m.read(.{ .start = b.at(-60_000), .end = b.at(0), .aggregation = .{ .alignment_period_s = 60, .aligner = .max, .reducer = .sum } });
    defer summed.deinit();
    try testing.expectEqual(1, summed.value.series.len);
    const s = summed.value.series[0];
    try testing.expectEqual(0, s.metric_labels.len);
    try testing.expectEqual(1, s.resource_labels.len);
    try testing.expectEqual(types.ValueType.int64, s.value_type);
    try testing.expectEqual(71, s.points[0].value.?.int64);
    try testing.expectEqual(b.at(0).nanoseconds, s.points[0].end.nanoseconds);
    try testing.expectEqual(b.at(0).nanoseconds, s.points[0].start.?.nanoseconds);
    try testing.expectEqualStrings("1", summed.value.unit);

    var by_region = try m.read(.{ .start = b.at(-60_000), .end = b.at(0), .aggregation = .{ .alignment_period_s = 60, .aligner = .mean, .reducer = .max, .group_by = &.{"metric.labels.region"} } });
    defer by_region.deinit();
    try testing.expectEqual(2, by_region.value.series.len);
    for (by_region.value.series) |r| {
        try testing.expectEqual(types.ValueType.double, r.value_type);
        // Each point is a series of its own task: eu's means are 30 and 20.
        const want: f64 = if (std.mem.eql(u8, r.label("region").?, "eu")) 30 else 21;
        try testing.expectEqual(want, r.points[0].value.?.double);
    }

    // Two periods over two minutes: one point each, newest first.
    var periods = try m.read(.{ .start = b.at(-120_000), .end = b.at(0), .aggregation = .{ .alignment_period_s = 60, .aligner = .count, .reducer = .sum } });
    defer periods.deinit();
    const pts = periods.value.series[0].points;
    try testing.expectEqual(2, pts.len);
    try testing.expectEqual(3, pts[0].value.?.int64);
    try testing.expectEqual(1, pts[1].value.?.int64);
    try testing.expectEqual(b.at(-60_000).nanoseconds, pts[1].end.nanoseconds);
    var counted = try m.read(.{ .start = b.at(-60_000), .end = b.at(0), .aggregation = .{ .alignment_period_s = 60, .aligner = .min, .reducer = .count, .group_by = &.{"resource.labels.job"} } });
    defer counted.deinit();
    try testing.expectEqual(2, counted.value.series.len);
    var mins = try m.read(.{ .start = b.at(-60_000), .end = b.at(0), .aggregation = .{ .alignment_period_s = 60, .aligner = .sum, .reducer = .min } });
    defer mins.deinit();
    try testing.expectEqual(20, mins.value.series[0].points[0].value.?.int64);
    var means = try m.read(.{ .start = b.at(-60_000), .end = b.at(0), .aggregation = .{ .alignment_period_s = 60, .aligner = .max, .reducer = .mean } });
    defer means.deinit();
    try testing.expectEqual(71.0 / 3.0, means.value.series[0].points[0].value.?.double);

    // ALIGN_RATE on a gauge is refused, as production refused it. Not
    // modelled: other aligners, cumulative metrics, a second aggregation.
    try testing.expectError(error.InvalidArgument, m.read(.{ .end = b.at(0), .aggregation = .{ .alignment_period_s = 60, .aligner = .rate } }));
    try testing.expectError(error.Unimplemented, m.read(.{ .end = b.at(0), .aggregation = .{ .alignment_period_s = 60, .aligner = .stddev } }));
    try testing.expectError(error.Unimplemented, m.read(.{ .end = b.at(0), .aggregation = .{ .alignment_period_s = 60, .aligner = .max, .reducer = .percentile_99 } }));
    try testing.expectError(error.Unimplemented, m.read(.{ .end = b.at(0), .aggregation = .{ .alignment_period_s = 60, .aligner = .max }, .secondary_aggregation = .{ .alignment_period_s = 120, .aligner = .max } }));
    try testing.expectError(error.Unimplemented, m.read(.{ .end = b.at(0), .filter = .{ .raw = "metric.labels.region = one_of(\"eu\")" } }));
    var cum = try b.client.write(&.{.{ .metric_type = "custom.googleapis.com/total", .resource = .global, .kind = .cumulative, .start = b.at(-60_000), .end = b.at(0), .value = .{ .int64 = 1 } }});
    cum.deinit();
    try testing.expectError(error.Unimplemented, b.client.metric("custom.googleapis.com/total").read(.{ .end = b.at(0), .aggregation = .{ .alignment_period_s = 60, .aligner = .max } }));
    var flags = try b.client.write(&.{.{ .metric_type = "custom.googleapis.com/flag", .resource = .global, .kind = .gauge, .end = b.at(0), .value = .{ .bool = true } }});
    flags.deinit();
    try testing.expectError(error.Unimplemented, b.client.metric("custom.googleapis.com/flag").read(.{ .end = b.at(0), .aggregation = .{ .alignment_period_s = 60, .aligner = .max } }));
    var flag_count = try b.client.metric("custom.googleapis.com/flag").read(.{ .start = b.at(-60_000), .end = b.at(0), .aggregation = .{ .alignment_period_s = 60, .aligner = .count } });
    defer flag_count.deinit();
    try testing.expectEqual(1, flag_count.value.series[0].points[0].value.?.int64);
}

test "reads refused in production's words" {
    var b: Bench = undefined;
    try b.init(.{ .project_id = "extractctl" });
    defer b.deinit();
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try testing.expectError(error.NotFound, b.client.metric("custom.googleapis.com/zigps-m0b-b66e4f/nothing").read(.{ .end = b.at(0) }));
    try testing.expectEqualStrings(try messageOf(a, production.read_unknown_type), b.diag.message());
    var made = try b.client.metric("custom.googleapis.com/zigps-m0-62b2c8/gauge").create(.{ .kind = .gauge, .value_type = .int64 });
    made.deinit();
    const base = "timeSeries?filter=metric.type%20%3D%20%22custom.googleapis.com%2Fzigps-m0-62b2c8%2Fgauge%22&interval.endTime=2026-10-18T13%3A46%3A35Z";
    const cases = [_]struct { []const u8, []const u8 }{
        .{ "timeSeries?interval.endTime=2026-10-18T13%3A46%3A35Z", production.read_no_type },
        .{ "timeSeries?filter=metric.labels.k%20%3D%20%22x%22&interval.endTime=2026-10-18T13%3A46%3A35Z", production.read_no_type },
        .{ base ++ "&aggregation.perSeriesAligner=ALIGN_MAX", production.read_no_period },
        .{ base ++ "&aggregation.perSeriesAligner=ALIGN_MAX&aggregation.alignmentPeriod=9s", production.read_period_9s },
        .{ base ++ "&aggregation.crossSeriesReducer=REDUCE_SUM", production.read_no_aligner },
        .{ base ++ "&interval.startTime=2026-10-18T13%3A46%3A36Z", production.read_start_after_end },
        .{ base ++ "&aggregation.perSeriesAligner=ALIGN_DELTA&aggregation.alignmentPeriod=60s", production.read_delta_on_gauge },
        .{ base ++ "&aggregation.perSeriesAligner=ALIGN_RATE&aggregation.alignmentPeriod=60s", production.read_rate_on_gauge },
    };
    for (cases) |c| {
        const reply = try b.raw(a, .GET, c[0], null);
        try testing.expectEqual(400, reply.status);
        try testing.expectEqualStrings(try messageOf(a, c[1]), try messageOf(a, reply.body));
    }
    for ([_][]const u8{
        "timeSeries?filter=metric.type%20%3D%20%22x%22",
        base ++ "&interval.startTime=yesterday",
        "timeSeries?filter=metric.type%20%3D%20%22x%22&interval.endTime=never",
        base ++ "&aggregation.perSeriesAligner=ALIGN_MAX&aggregation.alignmentPeriod=1m",
        base ++ "&aggregation.perSeriesAligner=ALIGN_STDDEV&aggregation.alignmentPeriod=60s",
        "timeSeries?filter=metric.type%20%3D%20%22x%22%20OR%20metric.type%20%3D%20%22y%22&interval.endTime=2026-10-18T13%3A46%3A35Z",
        "timeSeries?filter=metric.type%20!%3D%20%22x%22&interval.endTime=2026-10-18T13%3A46%3A35Z",
        "timeSeries?filter=metric.type%20%3D%20%22custom.googleapis.com%2Fzigps-m0-62b2c8%2Fgauge%22%20AND%20resource.type%20!%3D%20%22global%22&interval.endTime=2026-10-18T13%3A46%3A35Z",
    }) |path| try testing.expectEqual(501, (try b.raw(a, .GET, path, null)).status);
    try testing.expectEqual(400, (try b.raw(a, .GET, base ++ "&pageSize=x", null)).status);
}

fn filterProperty(_: void, input: []const u8) !void {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var g: test_util.ByteGen = .init(input);
    var metric: std.ArrayList(types.Match) = .empty;
    var resource: std.ArrayList(types.Match) = .empty;
    for (0..g.intRange(usize, 0, 4)) |_| {
        var buf: [16]u8 = undefined;
        const m: types.Match = .{
            .key = g.pick([]const u8, &.{ "k", "Region", "a_1", "1bad", "a.b" }),
            .op = g.pick(types.Match.Op, &.{ .equals, .not_equals, .starts_with, .ends_with, .has_substring }),
            .value = try a.dupe(u8, if (g.boolean()) g.utf8(&buf, 16) else g.slice(16)),
        };
        try (if (g.boolean()) &metric else &resource).append(a, m);
    }
    const f: types.Filter = .{
        .metric_labels = metric.items,
        .resource_labels = resource.items,
        .resource_type = if (g.boolean()) g.pick([]const u8, &.{ "generic_task", "global", "a b" }) else null,
    };
    if (filter_mod.problem(f) != null) return;
    const text = try filter_mod.build(a, "custom.googleapis.com/x", f);
    const parsed = (try parseFilter(a, text)).?;
    try testing.expectEqualStrings("custom.googleapis.com/x", parsed.metric_type.?);
    var want: std.ArrayList(Condition) = .empty;
    for (f.metric_labels) |m| try want.append(a, .{ .field = .metric_label, .key = m.key, .op = m.op, .value = m.value });
    if (f.resource_type) |t| try want.append(a, .{ .field = .resource_type, .op = .equals, .value = t });
    for (f.resource_labels) |m| try want.append(a, .{ .field = .resource_label, .key = m.key, .op = m.op, .value = m.value });
    try testing.expectEqual(want.items.len, parsed.conditions.len);
    for (want.items, parsed.conditions) |w, p| {
        try testing.expectEqual(w.field, p.field);
        try testing.expectEqualStrings(w.key, p.key);
        try testing.expectEqual(w.op, p.op);
        try testing.expectEqualStrings(w.value, p.value);
    }
}

test "fuzz filters: what the builder writes, the fake's own parser reads back as the same conditions" {
    try test_util.fuzzBytes({}, filterProperty, .{ .corpus = &.{ "", "\x03\x00\x01\x02\x05a\"b\\c" } });
}

const filter_mod = @import("filter.zig");

test "reads: a period's several points, group-by fields it does not know, an unclosed escape" {
    var b: Bench = undefined;
    try b.init(.{});
    defer b.deinit();
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const g = "custom.googleapis.com/several";
    for ([_]i64{ -50_000, -40_000, -30_000 }, [_]i64{ 5, 9, 7 }) |at, v| {
        var r = try b.client.write(&.{gaugeAt(g, &.{}, b.at(at), v)});
        r.deinit();
    }
    const m = b.client.metric(g);
    var max = try m.read(.{ .start = b.at(-60_000), .end = b.at(0), .aggregation = .{ .alignment_period_s = 60, .aligner = .max } });
    defer max.deinit();
    try testing.expectEqual(9, max.value.series[0].points[0].value.?.int64);
    var min = try m.read(.{ .start = b.at(-60_000), .end = b.at(0), .aggregation = .{ .alignment_period_s = 60, .aligner = .min } });
    defer min.deinit();
    try testing.expectEqual(5, min.value.series[0].points[0].value.?.int64);
    var sum = try m.read(.{ .start = b.at(-60_000), .end = b.at(0), .aggregation = .{ .alignment_period_s = 60, .aligner = .sum, .reducer = .sum, .group_by = &.{"metadata.user_labels.team"} } });
    defer sum.deinit();
    try testing.expectEqual(21, sum.value.series[0].points[0].value.?.int64);
    const unclosed = try b.raw(a, .GET, "timeSeries?filter=metric.type%20%3D%20%22a%5C&interval.endTime=2026-10-18T13%3A46%3A35Z", null);
    try testing.expectEqual(501, unclosed.status);
    const never_closed = try b.raw(a, .GET, "timeSeries?filter=metric.type%20%3D%20%22abc&interval.endTime=2026-10-18T13%3A46%3A35Z", null);
    try testing.expectEqual(501, never_closed.status);
    const bad_escape = try b.raw(a, .GET, "timeSeries?filter=metric.type%20%3D%20%22a%5Cn%22&interval.endTime=2026-10-18T13%3A46%3A35Z", null);
    try testing.expectEqual(501, bad_escape.status);
}

test "reads: a point on a period's start belongs to the period before, (start, end] as a read's interval" {
    var b: Bench = undefined;
    try b.init(.{});
    defer b.deinit();
    const g = "custom.googleapis.com/edges";
    for ([_]i64{ -60_000, -30_000 }, [_]i64{ 1, 2 }) |at, v| {
        var r = try b.client.write(&.{gaugeAt(g, &.{}, b.at(at), v)});
        r.deinit();
    }
    var periods = try b.client.metric(g).read(.{ .start = b.at(-120_000), .end = b.at(0), .aggregation = .{ .alignment_period_s = 60, .aligner = .count } });
    defer periods.deinit();
    const pts = periods.value.series[0].points;
    try testing.expectEqual(2, pts.len);
    try testing.expectEqual(1, pts[0].value.?.int64);
    try testing.expectEqual(b.at(-60_000).nanoseconds, pts[1].end.nanoseconds);
    try testing.expectEqual(1, pts[1].value.?.int64);
}

test "the same point twice, of each value type a program's metric has: kept once; changed, refused as too soon" {
    var b: Bench = undefined;
    try b.init(.{});
    defer b.deinit();
    const values = [_]types.Value{
        .{ .bool = true },
        .{ .double = 0.5 },
        .{ .distribution = .{ .count = 1, .mean = 2, .buckets = .{ .explicit = &.{1} }, .bucket_counts = &.{ 0, 1 } } },
    };
    const changed = [_]types.Value{
        .{ .bool = false },
        .{ .double = 0.25 },
        .{ .distribution = .{ .count = 2, .mean = 2, .buckets = .{ .explicit = &.{1} }, .bucket_counts = &.{ 0, 2 } } },
    };
    for (values, changed, 0..) |v, c, i| {
        // A metric of each value type but STRING, which production makes
        // for no program.
        var name: [40]u8 = undefined;
        const s: types.TimeSeries = .{ .metric_type = try std.fmt.bufPrint(&name, "external.googleapis.com/twice{d}", .{i}), .resource = .global, .kind = .gauge, .end = b.at(0), .value = v };
        for (0..2) |_| {
            var r = try b.client.write(&.{s});
            defer r.deinit();
            try testing.expect(r.value.ok());
        }
        var other = s;
        other.value = c;
        var r = try b.client.write(&.{other});
        defer r.deinit();
        try testing.expectEqual(error.FailedPrecondition, r.value.refused[0].reason);
    }
    try testing.expectEqual(3, b.fake.pointCount());
}

// Google's own metrics, put in by a test (issue #239).

const backlog_type = "pubsub.googleapis.com/subscription/num_undelivered_messages";
const sent_type = "pubsub.googleapis.com/subscription/sent_message_count";
const push_type = "pubsub.googleapis.com/subscription/push_request_count";
const dead_type = "pubsub.googleapis.com/subscription/dead_letter_message_count";
const publish_type = "pubsub.googleapis.com/topic/send_message_operation_count";

/// A gauge point `ms` from the bench's start.
fn gaugePoint(b: *const Bench, ms: i64, value: i64) FakeMonitoring.Point {
    return .{ .start = null, .end = b.at(ms), .value = .{ .int64 = value } };
}

/// A DELTA point for the minute that ends `ms` from the bench's start, as
/// Pub/Sub's are.
fn minute(b: *const Bench, ms: i64, value: i64) FakeMonitoring.Point {
    return .{ .start = b.at(ms - 60_000), .end = b.at(ms), .value = .{ .int64 = value } };
}

test "put: Pub/Sub's own metrics, read back as production answers them" {
    var b: Bench = undefined;
    try b.init(.{ .project_id = "atlas-prod" });
    defer b.deinit();
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    // The issue's repro: a program cannot write Google's metrics, and nor
    // can a test. Production's 403, in its words.
    const desktop: []const types.Label = &.{.{ .key = "subscription_id", .value = "orders-desktop" }};
    const desktop_match: []const types.Match = &.{.{ .key = "subscription_id", .value = "orders-desktop" }};
    try testing.expectError(error.PermissionDenied, b.client.write(&.{.{ .metric_type = backlog_type, .resource = .{ .other = .{ .type = "pubsub_subscription", .labels = desktop } }, .kind = .gauge, .end = b.at(0), .value = .{ .int64 = 14 } }}));
    try testing.expectEqualStrings(try messageOf(arena.allocator(), production.write_google_metric), b.diag.message());

    const desktop_backlog = [_]FakeMonitoring.Point{ gaugePoint(&b, -120_000, 9), gaugePoint(&b, -60_000, 14), gaugePoint(&b, -1_000, 12) };
    try b.fake.put(.{ .metric_type = backlog_type, .resource_type = "pubsub_subscription", .resource_labels = desktop, .kind = .gauge, .value_type = .int64, .points = &desktop_backlog });
    const audit_backlog = [_]FakeMonitoring.Point{gaugePoint(&b, -60_000, 2)};
    try b.fake.put(.{ .metric_type = backlog_type, .resource_type = "pubsub_subscription", .resource_labels = &.{ .{ .key = "project_id", .value = "atlas-prod" }, .{ .key = "subscription_id", .value = "orders-audit" } }, .kind = .gauge, .value_type = .int64, .points = &audit_backlog });
    try testing.expectEqual(2, b.fake.seriesCount());

    // Raw, filtered on the subscription, its resource as production gives
    // it back.
    const backlog = b.client.metric(backlog_type);
    var raw = try backlog.read(.{ .start = b.at(-180_000), .end = b.at(0), .filter = .{ .resource_labels = desktop_match } });
    defer raw.deinit();
    try testing.expectEqual(1, raw.value.series.len);
    const s = raw.value.series[0];
    try testing.expectEqualStrings("pubsub_subscription", s.resource_type);
    try testing.expectEqualStrings("atlas-prod", s.resourceLabel("project_id").?);
    try testing.expectEqualStrings("orders-desktop", s.resourceLabel("subscription_id").?);
    try testing.expectEqual(types.Kind.gauge, s.kind);
    try testing.expectEqual(3, s.points.len);
    try testing.expectEqual(12, s.points[0].value.?.int64);
    try testing.expectEqualStrings("1", raw.value.unit);

    // ALIGN_MAX answered GAUGE INT64. (-60 s, 0] holds 12; (-120 s, -60 s]
    // holds 14 and the audit's 2; the 9 at -120 s is before the read.
    var max = try backlog.read(.{ .start = b.at(-120_000), .end = b.at(0), .aggregation = .{ .alignment_period_s = 60, .aligner = .max, .reducer = .sum } });
    defer max.deinit();
    try testing.expectEqual(1, max.value.series.len);
    try testing.expectEqual(types.Kind.gauge, max.value.series[0].kind);
    try testing.expectEqual(types.ValueType.int64, max.value.series[0].value_type);
    try testing.expectEqual(2, max.value.series[0].points.len);
    try testing.expectEqual(12, max.value.series[0].points[0].value.?.int64);
    try testing.expectEqual(16, max.value.series[0].points[1].value.?.int64);

    // Sent counts, a minute a point, by delivery type.
    for ([_][]const u8{ "pull", "streaming pull" }, [_]i64{ 1, 10 }) |dt, k| {
        const labels = [_]types.Label{.{ .key = "delivery_type", .value = dt }};
        const pts = [_]FakeMonitoring.Point{ minute(&b, -120_000, 3 * k), minute(&b, -60_000, 5 * k), minute(&b, 0, 7 * k) };
        try b.fake.put(.{ .metric_type = sent_type, .metric_labels = &labels, .resource_type = "pubsub_subscription", .resource_labels = desktop, .kind = .delta, .value_type = .int64, .points = &pts });
    }
    const sent = b.client.metric(sent_type);
    var raw_sent = try sent.read(.{ .start = b.at(-180_000), .end = b.at(0), .filter = .{ .metric_labels = &.{.{ .key = "delivery_type", .value = "pull" }} } });
    defer raw_sent.deinit();
    try testing.expectEqual(types.Kind.delta, raw_sent.value.series[0].kind);
    try testing.expectEqual(b.at(-60_000).nanoseconds, raw_sent.value.series[0].points[0].start.?.nanoseconds);
    try testing.expectEqual(7, raw_sent.value.series[0].points[0].value.?.int64);

    // ALIGN_DELTA with REDUCE_SUM: a count a period, the metric labels
    // summed away, each point over its period.
    var deltas = try sent.read(.{ .start = b.at(-180_000), .end = b.at(0), .aggregation = .{ .alignment_period_s = 60, .aligner = .delta, .reducer = .sum } });
    defer deltas.deinit();
    try testing.expectEqual(1, deltas.value.series.len);
    const d = deltas.value.series[0];
    try testing.expectEqual(types.Kind.delta, d.kind);
    try testing.expectEqual(types.ValueType.int64, d.value_type);
    try testing.expectEqual(0, d.metric_labels.len);
    try testing.expectEqual(3, d.points.len);
    for (d.points, [_]i64{ 77, 55, 33 }, [_]i64{ 0, -60_000, -120_000 }) |p, want, end| {
        try testing.expectEqual(want, p.value.?.int64);
        try testing.expectEqual(b.at(end).nanoseconds, p.end.nanoseconds);
        try testing.expectEqual(b.at(end - 60_000).nanoseconds, p.start.?.nanoseconds);
    }
    // ALIGN_RATE with REDUCE_SUM: GAUGE DOUBLE, a second.
    var rates = try sent.read(.{ .start = b.at(-180_000), .end = b.at(0), .aggregation = .{ .alignment_period_s = 60, .aligner = .rate, .reducer = .sum } });
    defer rates.deinit();
    const r = rates.value.series[0];
    try testing.expectEqual(types.Kind.gauge, r.kind);
    try testing.expectEqual(types.ValueType.double, r.value_type);
    try testing.expectEqual(77.0 / 60.0, r.points[0].value.?.double);
    try testing.expectEqual(r.points[0].end.nanoseconds, r.points[0].start.?.nanoseconds);
    // Its unit a second, as production gave it.
    try testing.expectEqualStrings("1/s", rates.value.unit);
    try testing.expectEqualStrings("1", deltas.value.unit);
    // By delivery type: one series each, with its label.
    var by_type = try sent.read(.{ .start = b.at(-180_000), .end = b.at(0), .aggregation = .{ .alignment_period_s = 60, .aligner = .delta, .reducer = .sum, .group_by = &.{"metric.labels.delivery_type"} } });
    defer by_type.deinit();
    try testing.expectEqual(2, by_type.value.series.len);
    for (by_type.value.series) |t| {
        const k: i64 = if (std.mem.eql(u8, t.label("delivery_type").?, "pull")) 1 else 10;
        try testing.expectEqual(7 * k, t.points[0].value.?.int64);
        try testing.expectEqual(1, t.metric_labels.len);
    }
    // Two minutes a period: (-120 s, 0] holds two points of each.
    var wide = try sent.read(.{ .start = b.at(-180_000), .end = b.at(0), .aggregation = .{ .alignment_period_s = 120, .aligner = .delta, .reducer = .sum } });
    defer wide.deinit();
    try testing.expectEqual(2, wide.value.series[0].points.len);
    try testing.expectEqual(132, wide.value.series[0].points[0].value.?.int64);
    try testing.expectEqual(b.at(-120_000).nanoseconds, wide.value.series[0].points[0].start.?.nanoseconds);
    try testing.expectEqual(33, wide.value.series[0].points[1].value.?.int64);
    // Unreduced: each series aligned on its own, DELTA still.
    var each = try sent.read(.{ .start = b.at(-60_000), .end = b.at(0), .aggregation = .{ .alignment_period_s = 60, .aligner = .delta } });
    defer each.deinit();
    try testing.expectEqual(2, each.value.series.len);
    for (each.value.series) |t| {
        try testing.expectEqual(types.Kind.delta, t.kind);
        try testing.expectEqual(1, t.points.len);
        try testing.expectEqualStrings("orders-desktop", t.resourceLabel("subscription_id").?);
    }

    // Push requests by response class, as the console reads them.
    for ([_][]const u8{ "ack", "remote_server_5xx" }, [_][]const u8{ "success", "unavailable" }, [_]i64{ 40, 2 }) |class, code, n| {
        const labels = [_]types.Label{ .{ .key = "response_class", .value = class }, .{ .key = "response_code", .value = code }, .{ .key = "delivery_type", .value = "push" } };
        const pts = [_]FakeMonitoring.Point{minute(&b, 0, n)};
        try b.fake.put(.{ .metric_type = push_type, .metric_labels = &labels, .resource_type = "pubsub_subscription", .resource_labels = desktop, .kind = .delta, .value_type = .int64, .points = &pts });
    }
    var classes = try b.client.metric(push_type).read(.{ .start = b.at(-60_000), .end = b.at(0), .aggregation = .{ .alignment_period_s = 60, .aligner = .delta, .reducer = .sum, .group_by = &.{"metric.labels.response_class"} } });
    defer classes.deinit();
    try testing.expectEqual(2, classes.value.series.len);
    try testing.expectEqualStrings("ack", classes.value.series[0].label("response_class").?);
    try testing.expectEqual(40, classes.value.series[0].points[0].value.?.int64);
    try testing.expectEqual(2, classes.value.series[1].points[0].value.?.int64);

    // Nothing to count: no series at all, not zeros, and not 404.
    var dead = try b.client.metric(dead_type).read(.{ .start = b.at(-180_000), .end = b.at(0), .filter = .{ .resource_labels = desktop_match }, .aggregation = .{ .alignment_period_s = 60, .aligner = .delta, .reducer = .sum } });
    defer dead.deinit();
    try testing.expectEqual(0, dead.value.series.len);

    // A topic's publish rate.
    const pts = [_]FakeMonitoring.Point{ minute(&b, -60_000, 30), minute(&b, 0, 90) };
    try b.fake.put(.{ .metric_type = publish_type, .metric_labels = &.{.{ .key = "response_code", .value = "success" }}, .resource_type = "pubsub_topic", .resource_labels = &.{.{ .key = "topic_id", .value = "orders" }}, .kind = .delta, .value_type = .int64, .points = &pts });
    var publish = try b.client.metric(publish_type).read(.{ .start = b.at(-120_000), .end = b.at(0), .filter = .{ .resource_labels = &.{.{ .key = "topic_id", .value = "orders" }} }, .aggregation = .{ .alignment_period_s = 60, .aligner = .rate, .reducer = .sum } });
    defer publish.deinit();
    try testing.expectEqual(1.5, publish.value.series[0].points[0].value.?.double);
    try testing.expectEqual(0.5, publish.value.series[0].points[1].value.?.double);
}

test "Pub/Sub's descriptors and resource types: read and listed, never created, written or deleted" {
    var b: Bench = undefined;
    try b.init(.{});
    defer b.deinit();
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    // There before any request, as production's are.
    try testing.expectEqualStrings("Unacked messages", (try b.fake.descriptor(a, backlog_type)).?.display_name);

    var backlog = try b.client.metric(backlog_type).get();
    defer backlog.deinit();
    try testing.expectEqual(types.Kind.gauge, backlog.value.kind);
    try testing.expectEqual(types.ValueType.int64, backlog.value.value_type);
    try testing.expectEqualStrings("1", backlog.value.unit);
    try testing.expectEqualStrings("Unacked messages", backlog.value.display_name);
    try testing.expectEqualStrings("Number of unacknowledged messages (a.k.a. backlog messages) in a subscription.", backlog.value.description);
    try testing.expectEqual(0, backlog.value.labels.len);
    try testing.expectEqual(1, backlog.value.resource_types.len);
    try testing.expectEqualStrings("pubsub_subscription", backlog.value.resource_types[0]);
    var push = try b.client.metric(push_type).get();
    defer push.deinit();
    try testing.expectEqual(types.Kind.delta, push.value.kind);
    try testing.expectEqual(3, push.value.labels.len);
    try testing.expect(push.value.label("response_class") != null);
    try testing.expectEqualStrings("Push delivery mechanism.", push.value.label("delivery_type").?.description);
    var age = try b.client.metric("pubsub.googleapis.com/subscription/oldest_unacked_message_age").get();
    defer age.deinit();
    try testing.expectEqualStrings("s", age.value.unit);
    var bytes = try b.client.metric("pubsub.googleapis.com/topic/byte_cost").get();
    defer bytes.deinit();
    try testing.expectEqualStrings("By", bytes.value.unit);
    try testing.expectEqualStrings("pubsub_topic", bytes.value.resource_types[0]);
    try testing.expectEqual(types.Kind.gauge, (try b.fake.descriptor(a, backlog_type)).?.kind);
    // A user metric still lists only the types it may be written to.
    var made = try b.client.metric("custom.googleapis.com/mine").create(.{ .kind = .gauge, .value_type = .int64 });
    defer made.deinit();
    try testing.expectEqual(7, made.value.resource_types.len);

    var listed = try b.client.listMetrics(.{ .prefix = "pubsub.googleapis.com/subscription/" });
    defer listed.deinit();
    try testing.expectEqual(7, listed.value.metrics.len);
    try testing.expectEqualStrings("pubsub.googleapis.com/subscription/ack_message_count", listed.value.metrics[0].type);
    var none_active = try b.client.listMetrics(.{ .active_only = true });
    defer none_active.deinit();
    try testing.expectEqual(0, none_active.value.metrics.len);
    const one = [_]FakeMonitoring.Point{gaugePoint(&b, 0, 1)};
    try b.fake.put(.{ .metric_type = backlog_type, .resource_type = "pubsub_subscription", .resource_labels = &.{.{ .key = "subscription_id", .value = "s" }}, .kind = .gauge, .value_type = .int64, .points = &one });
    var active = try b.client.listMetrics(.{ .active_only = true });
    defer active.deinit();
    try testing.expectEqual(1, active.value.metrics.len);

    // Never created or written, as production answered: 403, in its
    // words. A delete is not modelled.
    const created = try b.raw(a, .POST, "metricDescriptors", "{\"type\":\"pubsub.googleapis.com/subscription/zigps_mon_517da9\",\"metricKind\":\"GAUGE\",\"valueType\":\"INT64\"}");
    try testing.expectEqual(production.create_google_descriptor_status, created.status);
    try testing.expectEqualStrings(try messageOf(a, production.create_google_descriptor), try messageOf(a, created.body));
    try testing.expectEqual(null, try b.fake.descriptor(a, "pubsub.googleapis.com/subscription/zigps_mon_517da9"));
    try testing.expectEqual(501, (try b.raw(a, .DELETE, "metricDescriptors/" ++ backlog_type, null)).status);
    var still = try b.client.metric(backlog_type).get();
    still.deinit();
    try testing.expectError(error.PermissionDenied, b.client.write(&.{
        .{ .metric_type = "custom.googleapis.com/mine", .resource = .global, .kind = .gauge, .end = b.at(0), .value = .{ .int64 = 1 } },
        .{ .metric_type = "pubsub.googleapis.com/subscription/mine", .resource = .global, .kind = .gauge, .end = b.at(0), .value = .{ .int64 = 1 } },
    }));
    try testing.expectEqualStrings("User does not have permission to write to metric pubsub.googleapis.com/subscription/mine.", b.diag.message());
    try testing.expectEqual(1, b.fake.pointCount());
    // A user metric on Pub/Sub's resource type: refused in the summary, in
    // production's words, its descriptor made all the same.
    var on_sub = try b.client.write(&.{.{ .metric_type = "custom.googleapis.com/zigps-mon-517da9/on_sub", .resource = .{ .other = .{ .type = "pubsub_subscription", .labels = &.{.{ .key = "subscription_id", .value = "zigps-mon-517da9-a" }} } }, .kind = .gauge, .end = b.at(0), .value = .{ .int64 = 1 } }});
    defer on_sub.deinit();
    try testing.expectEqual(0, on_sub.value.written);
    try testing.expectEqual(error.InvalidArgument, on_sub.value.refused[0].reason);
    try testing.expectEqualStrings(try messageOf(a, production.write_on_pubsub_subscription), on_sub.value.message);
    try testing.expectEqual(types.Kind.gauge, (try b.fake.descriptor(a, "custom.googleapis.com/zigps-mon-517da9/on_sub")).?.kind);
    try testing.expectEqual(1, b.fake.pointCount());

    var sub = try b.client.resourceType("pubsub_subscription");
    defer sub.deinit();
    try testing.expectEqualStrings("Cloud Pub/Sub Subscription", sub.value.display_name);
    try testing.expectEqual(2, sub.value.labels.len);
    try testing.expectEqualStrings("subscription_id", sub.value.labels[1].key);
    try testing.expectEqualStrings("A subscription in Google Cloud Pub/Sub.", sub.value.description);
    try testing.expectEqualStrings("The identifier of the subscription, such as \"my-subscription\".", sub.value.labels[1].description);
    var topic = try b.client.resourceType("pubsub_topic");
    defer topic.deinit();
    try testing.expectEqualStrings("topic_id", topic.value.labels[1].key);

    // A resource label the metric's resource types lack is 400, in
    // production's words; one they have selects.
    const m = b.client.metric(backlog_type);
    for ([_][]const u8{ "topic_id", "zone", "nothing_here" }) |key| {
        try testing.expectError(error.InvalidArgument, m.read(.{ .end = b.at(0), .filter = .{ .resource_labels = &.{.{ .key = key, .value = "x" }} } }));
        try testing.expectEqualStrings("The supplied filter does not specify a valid combination of metric and monitored resource descriptors. The query will not return any time series.", b.diag.message());
    }
    try testing.expectError(error.InvalidArgument, b.client.metric("custom.googleapis.com/mine").read(.{ .end = b.at(0), .filter = .{ .resource_labels = &.{.{ .key = "subscription_id", .value = "x" }} } }));
    try testing.expectError(error.InvalidArgument, b.client.metric(publish_type).read(.{ .end = b.at(0), .filter = .{ .resource_labels = &.{.{ .key = "subscription_id", .value = "x" }} } }));
    var by_project = try m.read(.{ .end = b.at(0), .filter = .{ .resource_labels = &.{ .{ .key = "project_id", .value = "my-project" }, .{ .key = "subscription_id", .value = "s" } } } });
    defer by_project.deinit();
    try testing.expectEqual(1, by_project.value.series.len);
    // A metric label it lacks is 404.
    try testing.expectError(error.NotFound, m.read(.{ .end = b.at(0), .filter = .{ .metric_labels = &.{.{ .key = "delivery_type", .value = "pull" }} } }));

    // A resource type the metric cannot be on is 400, in production's
    // words; its own selects; one the fake does not know is not modelled.
    // A type named narrows the labels to its own.
    for ([_][]const u8{ "pubsub_topic", "global", "gce_instance" }) |t| {
        try testing.expectError(error.InvalidArgument, m.read(.{ .end = b.at(0), .filter = .{ .resource_type = t } }));
        try testing.expectEqualStrings(try messageOf(a, production.read_other_resource_type), b.diag.message());
    }
    var own = try m.read(.{ .end = b.at(0), .filter = .{ .resource_type = "pubsub_subscription", .resource_labels = &.{.{ .key = "subscription_id", .value = "s" }} } });
    defer own.deinit();
    try testing.expectEqual(1, own.value.series.len);
    try testing.expectError(error.Unimplemented, m.read(.{ .end = b.at(0), .filter = .{ .resource_type = "cloud_run_revision" } }));
    const mine = b.client.metric("custom.googleapis.com/mine");
    try testing.expectError(error.InvalidArgument, mine.read(.{ .end = b.at(0), .filter = .{ .resource_type = "pubsub_subscription" } }));
    for ([_][]const u8{ "global", "gce_instance" }) |t| {
        var page = try mine.read(.{ .end = b.at(0), .filter = .{ .resource_type = t } });
        defer page.deinit();
        // A metric without a unit, as production read one.
        try testing.expectEqualStrings("{not_a_unit}", page.value.unit);
    }
    try testing.expectError(error.InvalidArgument, mine.read(.{ .end = b.at(0), .filter = .{ .resource_type = "global", .resource_labels = &.{.{ .key = "zone", .value = "x" }} } }));
    var zoned = try mine.read(.{ .end = b.at(0), .filter = .{ .resource_type = "gce_instance", .resource_labels = &.{.{ .key = "zone", .value = "x" }} } });
    zoned.deinit();
}

test "put: refused whole for what production could not hold" {
    var b: Bench = undefined;
    try b.init(.{});
    defer b.deinit();
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var made = try b.client.metric("custom.googleapis.com/made").create(.{ .kind = .gauge, .value_type = .int64 });
    made.deinit();
    const sub: []const types.Label = &.{.{ .key = "subscription_id", .value = "s" }};
    const gauge = [_]FakeMonitoring.Point{gaugePoint(&b, 0, 1)};
    const gauge_double = [_]FakeMonitoring.Point{.{ .start = null, .end = b.at(0), .value = .{ .double = 1 } }};
    const delta = [_]FakeMonitoring.Point{minute(&b, 0, 1)};
    const base: FakeMonitoring.PutSeries = .{ .metric_type = backlog_type, .resource_type = "pubsub_subscription", .resource_labels = sub, .kind = .gauge, .value_type = .int64, .points = &gauge };
    const sent_base: FakeMonitoring.PutSeries = .{ .metric_type = sent_type, .metric_labels = &.{.{ .key = "delivery_type", .value = "pull" }}, .resource_type = "pubsub_subscription", .resource_labels = sub, .kind = .delta, .value_type = .int64, .points = &delta };
    const global_base: FakeMonitoring.PutSeries = .{ .metric_type = "custom.googleapis.com/new", .resource_type = "global", .kind = .gauge, .value_type = .int64, .points = &gauge };
    // A series that is there already, to put points after.
    const earlier = [_]FakeMonitoring.Point{gaugePoint(&b, -60_000, 1)};
    var there = base;
    there.resource_labels = &.{.{ .key = "subscription_id", .value = "there" }};
    there.points = &earlier;
    try b.fake.put(there);

    // Points the cases below share, named so they outlive each case.
    const string = [_]FakeMonitoring.Point{.{ .start = null, .end = b.at(0), .value = .{ .string = "s" } }};
    const uneven = [_]FakeMonitoring.Point{.{ .start = null, .end = b.at(0), .value = .{ .distribution = .{ .count = 2, .buckets = .{ .explicit = &.{1} }, .bucket_counts = &.{ 0, 1 } } } }};
    const gauge_started = [_]FakeMonitoring.Point{.{ .start = b.at(-1), .end = b.at(0), .value = .{ .int64 = 1 } }};
    const unstarted = [_]FakeMonitoring.Point{.{ .start = null, .end = b.at(0), .value = .{ .int64 = 1 } }};
    const instant = [_]FakeMonitoring.Point{.{ .start = b.at(0), .end = b.at(0), .value = .{ .int64 = 1 } }};
    const same_end = [_]FakeMonitoring.Point{ gaugePoint(&b, 0, 1), gaugePoint(&b, 0, 2) };
    const overlapping = [_]FakeMonitoring.Point{ minute(&b, -60_000, 1), minute(&b, -30_000, 1) };
    const earlier_start = [_]FakeMonitoring.Point{ .{ .start = b.at(-120_000), .end = b.at(-60_000), .value = .{ .int64 = 1 } }, .{ .start = b.at(-180_000), .end = b.at(0), .value = .{ .int64 = 2 } } };
    const at_last = [_]FakeMonitoring.Point{gaugePoint(&b, -60_000, 2)};
    const before_last = [_]FakeMonitoring.Point{gaugePoint(&b, -90_000, 2)};

    var many: [31]types.Label = undefined;
    var names: [31][4]u8 = undefined;
    for (&many, &names, 0..) |*l, *n, i| l.* = .{ .key = try std.fmt.bufPrint(n, "k{d}", .{i}), .value = "v" };

    var cases: std.ArrayList(FakeMonitoring.PutSeries) = .empty;
    // The resource.
    try cases.append(a, with(base, .{ .resource_type = "cloud_run_revision" }));
    try cases.append(a, with(base, .{ .resource_labels = &.{} }));
    try cases.append(a, with(base, .{ .resource_labels = &.{ .{ .key = "subscription_id", .value = "s" }, .{ .key = "topic_id", .value = "t" } } }));
    try cases.append(a, with(base, .{ .resource_labels = &.{ .{ .key = "subscription_id", .value = "s" }, .{ .key = "project_id", .value = "another" } } }));
    try cases.append(a, with(base, .{ .resource_labels = &.{ .{ .key = "subscription_id", .value = "s" }, .{ .key = "subscription_id", .value = "s" } } }));
    // Google's metric, as Google holds it.
    try cases.append(a, with(base, .{ .kind = .delta, .points = &delta }));
    try cases.append(a, with(base, .{ .value_type = .double, .points = &gauge_double }));
    try cases.append(a, with(base, .{ .resource_type = "pubsub_topic", .resource_labels = &.{.{ .key = "topic_id", .value = "t" }} }));
    try cases.append(a, with(sent_base, .{ .metric_labels = &.{.{ .key = "response_code", .value = "success" }} }));
    try cases.append(a, with(global_base, .{ .metric_type = "pubsub.googleapis.com/subscription/num_outstanding_messages" }));
    // User metrics, as production would hold them.
    try cases.append(a, with(base, .{ .metric_type = "custom.googleapis.com/new" }));
    try cases.append(a, with(base, .{ .metric_type = "custom.googleapis.com/made" }));
    try cases.append(a, with(global_base, .{ .kind = .delta, .points = &delta }));
    try cases.append(a, with(global_base, .{ .value_type = .string, .points = &string }));
    try cases.append(a, with(global_base, .{ .metric_type = "workload.googleapis.com/new", .kind = .delta, .points = &delta }));
    try cases.append(a, with(global_base, .{ .metric_type = "external.googleapis.com/new", .value_type = .string, .points = &string }));
    try cases.append(a, with(global_base, .{ .metric_type = "custom.googleapis.com/made", .value_type = .double, .points = &gauge_double }));
    try cases.append(a, with(global_base, .{ .metric_type = "no-path" }));
    // Labels.
    try cases.append(a, with(global_base, .{ .metric_labels = &.{.{ .key = "1bad", .value = "v" }} }));
    try cases.append(a, with(global_base, .{ .metric_labels = &.{ .{ .key = "k", .value = "v" }, .{ .key = "k", .value = "w" } } }));
    try cases.append(a, with(global_base, .{ .metric_labels = &.{.{ .key = "k", .value = test_util.repeat("v", 1025) }} }));
    try cases.append(a, with(global_base, .{ .metric_labels = &many }));
    // Kinds and values.
    try cases.append(a, with(global_base, .{ .kind = .unknown, .points = &delta }));
    try cases.append(a, with(global_base, .{ .metric_type = "external.googleapis.com/money", .value_type = .money }));
    try cases.append(a, with(global_base, .{ .points = &.{} }));
    try cases.append(a, with(global_base, .{ .points = &gauge_double }));
    try cases.append(a, with(global_base, .{ .metric_type = "external.googleapis.com/dist", .value_type = .distribution, .points = &uneven }));
    // Intervals.
    try cases.append(a, with(global_base, .{ .points = &gauge_started }));
    try cases.append(a, with(sent_base, .{ .points = &unstarted }));
    try cases.append(a, with(sent_base, .{ .points = &instant }));
    try cases.append(a, with(global_base, .{ .points = &same_end }));
    try cases.append(a, with(sent_base, .{ .points = &overlapping }));
    try cases.append(a, with(global_base, .{ .kind = .cumulative, .metric_type = "custom.googleapis.com/total", .points = &earlier_start }));
    try cases.append(a, with(there, .{ .points = &at_last }));
    try cases.append(a, with(there, .{ .points = &before_last }));

    for (cases.items, 0..) |c, i| {
        b.fake.put(c) catch |err| {
            try testing.expectEqual(error.InvalidEntry, err);
            continue;
        };
        std.debug.print("case {d} was taken\n", .{i});
        return error.TestUnexpectedResult;
    }
    // Nothing kept: no series, no point, no descriptor.
    try testing.expectEqual(1, b.fake.seriesCount());
    try testing.expectEqual(1, b.fake.pointCount());
    for ([_][]const u8{ "custom.googleapis.com/new", "custom.googleapis.com/total", "workload.googleapis.com/new", "external.googleapis.com/new", "pubsub.googleapis.com/subscription/num_outstanding_messages" }) |t| {
        try testing.expectEqual(null, try b.fake.descriptor(a, t));
    }
    try testing.expectEqual(types.Kind.gauge, (try b.fake.descriptor(a, "custom.googleapis.com/made")).?.kind);

    // Taken: what only the write path refuses, the base cases themselves,
    // and points after a written series' last.
    const close = [_]FakeMonitoring.Point{ gaugePoint(&b, -30 * std.time.ms_per_hour, 1), gaugePoint(&b, -30 * std.time.ms_per_hour + 1, 2), gaugePoint(&b, 9 * std.time.ms_per_min, 3) };
    try b.fake.put(with(global_base, .{ .points = &close }));
    try b.fake.put(base);
    try b.fake.put(sent_base);
    try b.fake.put(with(sent_base, .{ .points = &.{ minute(&b, 60_000, 1), minute(&b, 180_000, 2) } }));
    try b.fake.put(with(global_base, .{ .kind = .cumulative, .metric_type = "custom.googleapis.com/total", .points = &.{ .{ .start = b.at(-120_000), .end = b.at(-60_000), .value = .{ .int64 = 5 } }, .{ .start = b.at(-120_000), .end = b.at(0), .value = .{ .int64 = 2 } }, .{ .start = b.at(1), .end = b.at(60_000), .value = .{ .int64 = 1 } } } }));
    try b.fake.put(with(there, .{ .resource_labels = &.{ .{ .key = "project_id", .value = "my-project" }, .{ .key = "subscription_id", .value = "there" } }, .points = &.{gaugePoint(&b, -59_999, 2)} }));
    var w = try b.client.write(&.{.{ .metric_type = "custom.googleapis.com/made", .resource = .global, .kind = .gauge, .end = b.at(-10_000), .value = .{ .int64 = 1 } }});
    w.deinit();
    try b.fake.put(with(global_base, .{ .metric_type = "custom.googleapis.com/made", .metric_labels = &.{}, .points = &.{gaugePoint(&b, -9_000, 2)} }));
    try testing.expectEqual(2, (try b.fake.points(a, "custom.googleapis.com/made", &.{})).len);
    try testing.expectEqual(2, (try b.fake.points(a, "pubsub.googleapis.com/subscription/num_undelivered_messages", &.{})).len);
    // Times kept to the microsecond, as production keeps them.
    try b.fake.put(with(global_base, .{ .metric_type = "custom.googleapis.com/fine", .points = &.{.{ .start = null, .end = .{ .nanoseconds = now_ns + 1_500 }, .value = .{ .int64 = 1 } }} }));
    try testing.expectEqual(now_ns + 1_000, (try b.fake.points(a, "custom.googleapis.com/fine", &.{}))[0].end.nanoseconds);
    const fine_delta = [_]FakeMonitoring.Point{.{ .start = .{ .nanoseconds = now_ns - 59_999_998_500 }, .end = .{ .nanoseconds = now_ns + 1_999 }, .value = .{ .int64 = 1 } }};
    const streaming: []const types.Label = &.{.{ .key = "delivery_type", .value = "streaming pull" }};
    try b.fake.put(with(sent_base, .{ .metric_labels = streaming, .points = &fine_delta }));
    const fine = (try b.fake.points(a, sent_type, streaming))[0];
    try testing.expectEqual(now_ns - 59_999_999_000, fine.start.?.nanoseconds);
    try testing.expectEqual(now_ns + 1_000, fine.end.nanoseconds);
    // A put adds a user metric's label, as a write does.
    try b.fake.put(with(global_base, .{ .metric_type = "custom.googleapis.com/made", .metric_labels = &.{.{ .key = "region", .value = "eu" }} }));
    try testing.expectEqualStrings("region", (try b.fake.descriptor(a, "custom.googleapis.com/made")).?.labels[0].key);
}

test "DELTA and STRING: refused for any metric a program makes, in production's words" {
    var b: Bench = undefined;
    try b.init(.{});
    defer b.deinit();
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    for ([_]struct { []const u8, types.Kind, types.ValueType, []const u8 }{
        .{ "workload.googleapis.com/zigps-mon3-2b2a2a/delta_int64", .delta, .int64, production.create_delta_workload },
        .{ "external.googleapis.com/zigps-mon3-2b2a2a/delta_int64", .delta, .int64, production.create_delta_external },
        .{ "external.googleapis.com/zigps-mon3-2b2a2a/gauge_string", .gauge, .string, production.create_string_external },
        .{ "workload.googleapis.com/zigps-mon3-2b2a2a/gauge_string", .gauge, .string, production.create_string_workload },
    }) |c| {
        try testing.expectError(error.InvalidArgument, b.client.metric(c[0]).create(.{ .kind = c[1], .value_type = c[2] }));
        try testing.expectEqualStrings(try messageOf(a, c[3]), b.diag.message());
        try testing.expectEqual(null, try b.fake.descriptor(a, c[0]));
    }
    // A write that would make one is refused whole, nothing made.
    try testing.expectError(error.InvalidArgument, b.client.write(&.{
        .{ .metric_type = "workload.googleapis.com/fine", .resource = .global, .kind = .gauge, .end = b.at(0), .value = .{ .int64 = 1 } },
        .{ .metric_type = "external.googleapis.com/d", .resource = .global, .kind = .delta, .start = b.at(-60_000), .end = b.at(0), .value = .{ .int64 = 1 } },
    }));
    try testing.expectEqual(null, try b.fake.descriptor(a, "external.googleapis.com/d"));
    try testing.expectEqual(0, b.fake.pointCount());
}

/// What `with` changes: each field that is not null.
const Changes = struct {
    metric_type: ?[]const u8 = null,
    metric_labels: ?[]const types.Label = null,
    resource_type: ?[]const u8 = null,
    resource_labels: ?[]const types.Label = null,
    kind: ?types.Kind = null,
    value_type: ?types.ValueType = null,
    points: ?[]const FakeMonitoring.Point = null,
};

/// `base` with the fields `changes` sets.
fn with(base: FakeMonitoring.PutSeries, changes: Changes) FakeMonitoring.PutSeries {
    var out = base;
    inline for (@typeInfo(Changes).@"struct".field_names) |name| {
        if (@field(changes, name)) |v| @field(out, name) = v;
    }
    return out;
}

test "reads of a DELTA metric: what is modelled, and what is not" {
    var b: Bench = undefined;
    try b.init(.{});
    defer b.deinit();
    const sub: []const types.Label = &.{.{ .key = "subscription_id", .value = "s" }};
    const pts = [_]FakeMonitoring.Point{ minute(&b, -120_000, 3), minute(&b, -60_000, 0), minute(&b, 0, 5) };
    try b.fake.put(.{ .metric_type = sent_type, .metric_labels = &.{.{ .key = "delivery_type", .value = "pull" }}, .resource_type = "pubsub_subscription", .resource_labels = sub, .kind = .delta, .value_type = .int64, .points = &pts });
    try b.fake.put(.{ .metric_type = sent_type, .metric_labels = &.{.{ .key = "delivery_type", .value = "push" }}, .resource_type = "pubsub_subscription", .resource_labels = sub, .kind = .delta, .value_type = .int64, .points = &.{minute(&b, 0, 4)} });
    const m = b.client.metric(sent_type);
    // A zero is a point; a point on a period's start belongs to the period
    // before, as a gauge's does.
    var zero = try m.read(.{ .start = b.at(-120_000), .end = b.at(0), .aggregation = .{ .alignment_period_s = 60, .aligner = .delta, .reducer = .sum } });
    defer zero.deinit();
    try testing.expectEqual(2, zero.value.series[0].points.len);
    try testing.expectEqual(0, zero.value.series[0].points[1].value.?.int64);
    // An instant read: the period that ends at the read's end.
    var instant = try m.read(.{ .end = b.at(0), .aggregation = .{ .alignment_period_s = 60, .aligner = .delta, .reducer = .sum } });
    defer instant.deinit();
    try testing.expectEqual(1, instant.value.series[0].points.len);
    try testing.expectEqual(9, instant.value.series[0].points[0].value.?.int64);
    // The other reducers keep the aligned kind and interval.
    for ([_]types.Reducer{ .max, .min, .count, .mean }, [_]types.Value{ .{ .int64 = 5 }, .{ .int64 = 4 }, .{ .int64 = 2 }, .{ .double = 4.5 } }) |reducer, want| {
        var page = try m.read(.{ .start = b.at(-60_000), .end = b.at(0), .aggregation = .{ .alignment_period_s = 60, .aligner = .delta, .reducer = reducer } });
        defer page.deinit();
        const s = page.value.series[0];
        try testing.expectEqual(types.Kind.delta, s.kind);
        try testing.expectEqual(b.at(-60_000).nanoseconds, s.points[0].start.?.nanoseconds);
        try testing.expect(sameValue(want, s.points[0].value.?));
    }
    // A period shorter than a point: the point is in the period its end
    // is in, whole.
    var short = try m.read(.{ .start = b.at(-60_000), .end = b.at(0), .aggregation = .{ .alignment_period_s = 20, .aligner = .rate, .reducer = .sum } });
    defer short.deinit();
    try testing.expectEqual(1, short.value.series[0].points.len);
    try testing.expectEqual(9.0 / 20.0, short.value.series[0].points[0].value.?.double);

    // Nothing in the read: no series, and the unit all the same.
    var empty_rate = try m.read(.{ .start = b.at(-200_000), .end = b.at(-190_000), .aggregation = .{ .alignment_period_s = 60, .aligner = .rate } });
    defer empty_rate.deinit();
    try testing.expectEqual(0, empty_rate.value.series.len);
    try testing.expectEqualStrings("1/s", empty_rate.value.unit);

    // ALIGN_SUM, as ALIGN_DELTA: a total over the period. (-120 s, 0]
    // holds pull's 0 and 5 and push's 4.
    var sums = try m.read(.{ .start = b.at(-120_000), .end = b.at(0), .aggregation = .{ .alignment_period_s = 120, .aligner = .sum, .reducer = .sum } });
    defer sums.deinit();
    try testing.expectEqual(types.Kind.delta, sums.value.series[0].kind);
    try testing.expectEqual(b.at(-120_000).nanoseconds, sums.value.series[0].points[0].start.?.nanoseconds);
    try testing.expectEqual(9, sums.value.series[0].points[0].value.?.int64);
    // The others: a gauge at the period's end, of pull's 0 and 5.
    const pull: []const types.Match = &.{.{ .key = "delivery_type", .value = "pull" }};
    for ([_]types.Aligner{ .min, .max, .mean, .count }, [_]types.Value{ .{ .int64 = 0 }, .{ .int64 = 5 }, .{ .double = 2.5 }, .{ .int64 = 2 } }) |aligner, want| {
        var page = try m.read(.{ .start = b.at(-120_000), .end = b.at(0), .filter = .{ .metric_labels = pull }, .aggregation = .{ .alignment_period_s = 120, .aligner = aligner } });
        defer page.deinit();
        const s = page.value.series[0];
        try testing.expectEqual(types.Kind.gauge, s.kind);
        try testing.expectEqual(s.points[0].end.nanoseconds, s.points[0].start.?.nanoseconds);
        try testing.expect(sameValue(want, s.points[0].value.?));
    }

    // The unit, as production gave it: `1` for a count, a second for a
    // rate, the metric's otherwise.
    const bytes_type = "pubsub.googleapis.com/topic/byte_cost";
    try b.fake.put(.{ .metric_type = bytes_type, .metric_labels = &.{ .{ .key = "operation_type", .value = "publish" }, .{ .key = "response_code", .value = "success" } }, .resource_type = "pubsub_topic", .resource_labels = &.{.{ .key = "topic_id", .value = "t" }}, .kind = .delta, .value_type = .int64, .points = &.{minute(&b, 0, 2048)} });
    for ([_]types.Aggregation{
        .{ .alignment_period_s = 60, .aligner = .delta },
        .{ .alignment_period_s = 60, .aligner = .sum },
        .{ .alignment_period_s = 60, .aligner = .mean },
        .{ .alignment_period_s = 60, .aligner = .max },
        .{ .alignment_period_s = 60, .aligner = .rate, .reducer = .mean },
        .{ .alignment_period_s = 60, .aligner = .count },
        .{ .alignment_period_s = 60, .aligner = .delta, .reducer = .count },
        .{ .alignment_period_s = 60, .aligner = .rate, .reducer = .count },
    }, [_][]const u8{ "By", "By", "By", "By", "By/s", "1", "1", "1" }) |agg, want| {
        var page = try b.client.metric(bytes_type).read(.{ .start = b.at(-60_000), .end = b.at(0), .aggregation = agg });
        defer page.deinit();
        try testing.expectEqualStrings(want, page.value.unit);
    }
    const age_type = "pubsub.googleapis.com/subscription/oldest_unacked_message_age";
    try b.fake.put(.{ .metric_type = age_type, .resource_type = "pubsub_subscription", .resource_labels = sub, .kind = .gauge, .value_type = .int64, .points = &.{gaugePoint(&b, 0, 38)} });
    for ([_]types.Aggregation{
        .{ .alignment_period_s = 60, .aligner = .mean },
        .{ .alignment_period_s = 60, .aligner = .count },
        .{ .alignment_period_s = 60, .aligner = .max, .reducer = .count },
        .{ .alignment_period_s = 60, .aligner = .max, .reducer = .mean },
    }, [_][]const u8{ "s", "1", "1", "s" }) |agg, want| {
        var page = try b.client.metric(age_type).read(.{ .start = b.at(-60_000), .end = b.at(0), .aggregation = agg });
        defer page.deinit();
        try testing.expectEqualStrings(want, page.value.unit);
    }
    // ALIGN_SUM on a gauge stays a gauge at the period's end, as
    // production answered.
    var gauge_sum = try b.client.metric(age_type).read(.{ .start = b.at(-60_000), .end = b.at(0), .aggregation = .{ .alignment_period_s = 60, .aligner = .sum } });
    defer gauge_sum.deinit();
    try testing.expectEqual(types.Kind.gauge, gauge_sum.value.series[0].kind);
    try testing.expectEqual(b.at(0).nanoseconds, gauge_sum.value.series[0].points[0].start.?.nanoseconds);
    try testing.expectEqual(38, gauge_sum.value.series[0].points[0].value.?.int64);

    // Refused as production refused them, in its words: the aligners a
    // DELTA metric does not take, and ALIGN_DELTA and ALIGN_RATE on a
    // gauge.
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const next_older = try messageOf(a, production.read_next_older_on_delta);
    for ([_]types.Aligner{ .next_older, .interpolate, .count_true, .count_false, .fraction_true, .percentile_99, .percentile_95, .percentile_50, .percentile_05 }) |aligner| {
        try testing.expectError(error.InvalidArgument, m.read(.{ .end = b.at(0), .aggregation = .{ .alignment_period_s = 60, .aligner = aligner } }));
        try testing.expectEqualStrings(try std.mem.replaceOwned(u8, a, next_older, "ALIGN_NEXT_OLDER", aligner.wire()), b.diag.message());
    }
    try testing.expectError(error.InvalidArgument, m.read(.{ .end = b.at(0), .aggregation = .{ .alignment_period_s = 60, .aligner = .percentile_99 } }));
    try testing.expectEqualStrings(try messageOf(a, production.read_percentile_on_delta), b.diag.message());
    for ([_]types.Aligner{ .delta, .rate }, [_][]const u8{ production.read_delta_on_gauge, production.read_rate_on_gauge }) |aligner, body| {
        try testing.expectError(error.InvalidArgument, b.client.metric(backlog_type).read(.{ .end = b.at(0), .aggregation = .{ .alignment_period_s = 60, .aligner = aligner } }));
        try testing.expectEqualStrings(try messageOf(a, body), b.diag.message());
    }
    var ratio = try b.client.metric("custom.googleapis.com/ratio").create(.{ .kind = .gauge, .value_type = .double });
    ratio.deinit();
    try testing.expectError(error.InvalidArgument, b.client.metric("custom.googleapis.com/ratio").read(.{ .end = b.at(0), .aggregation = .{ .alignment_period_s = 60, .aligner = .rate } }));
    try testing.expectEqualStrings(try messageOf(a, production.read_rate_on_double_gauge), b.diag.message());

    // Not modelled: ALIGN_STDDEV and ALIGN_PERCENT_CHANGE on a DELTA
    // metric, and aligning a cumulative metric.
    try testing.expectError(error.Unimplemented, m.read(.{ .end = b.at(0), .aggregation = .{ .alignment_period_s = 60, .aligner = .stddev } }));
    try testing.expectError(error.Unimplemented, m.read(.{ .end = b.at(0), .aggregation = .{ .alignment_period_s = 60, .aligner = .percent_change } }));
    try b.fake.put(.{ .metric_type = "custom.googleapis.com/total", .resource_type = "global", .kind = .cumulative, .value_type = .int64, .points = &.{minute(&b, 0, 1)} });
    try testing.expectError(error.Unimplemented, b.client.metric("custom.googleapis.com/total").read(.{ .end = b.at(0), .aggregation = .{ .alignment_period_s = 60, .aligner = .delta } }));
}

/// One DELTA point of the property's model: its series, its end in seconds
/// from the bench's start, its value.
const DeltaPoint = struct { series: usize, end_s: i64, value: i64 };

const delta_series = [_]struct { sub: []const u8, delivery: []const u8 }{
    .{ .sub = "a", .delivery = "pull" },
    .{ .sub = "a", .delivery = "push" },
    .{ .sub = "b", .delivery = "pull" },
    .{ .sub = "b", .delivery = "streaming pull" },
};

/// DELTA series put in with gaps and widths on a 10 s grid, then read with
/// ALIGN_DELTA, ALIGN_SUM, ALIGN_RATE, ALIGN_COUNT and ALIGN_MAX, reduced
/// or not, grouped or not: every answer agrees with the points put in,
/// and the answers with each other.
fn deltaReadProperty(_: void, input: []const u8) !void {
    const gpa = test_util.propertyAllocator();
    var g: test_util.ByteGen = .init(input);
    var clock: test_util.FakeClock = .{ .now_ns = now_ns };
    var fake: FakeMonitoring = .init(gpa, clock.io(), .{});
    defer fake.deinit();
    var token: core.StaticToken = .{ .token = "t" };
    var client = try Client.init(gpa, clock.io(), .{ .project_id = "my-project", .token_provider = token.provider(), .transport = fake.transport() });
    defer client.deinit();
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    const a = arena.allocator();

    var model: std.ArrayList(DeltaPoint) = .empty;
    for (delta_series, 0..) |ds, i| {
        if (!g.boolean()) continue;
        var pts: std.ArrayList(FakeMonitoring.Point) = .empty;
        var t: i64 = -600 + @as(i64, @intCast(g.intRange(usize, 0, 6))) * 10;
        for (0..g.intRange(usize, 0, 12)) |_| {
            const start = t + @as(i64, @intCast(g.intRange(usize, 0, 3))) * 10;
            const end = start + @as(i64, @intCast(g.intRange(usize, 1, 12))) * 10;
            if (end > 60) break;
            const value: i64 = @intCast(g.intRange(usize, 0, 1000));
            try pts.append(a, .{ .start = .{ .nanoseconds = now_ns + @as(i96, start) * std.time.ns_per_s }, .end = .{ .nanoseconds = now_ns + @as(i96, end) * std.time.ns_per_s }, .value = .{ .int64 = value } });
            try model.append(a, .{ .series = i, .end_s = end, .value = value });
            t = end;
        }
        if (pts.items.len == 0) continue;
        const labels = try a.dupe(types.Label, &.{.{ .key = "delivery_type", .value = ds.delivery }});
        const resource = try a.dupe(types.Label, &.{.{ .key = "subscription_id", .value = ds.sub }});
        try fake.put(.{ .metric_type = sent_type, .metric_labels = labels, .resource_type = "pubsub_subscription", .resource_labels = resource, .kind = .delta, .value_type = .int64, .points = pts.items });
    }

    const period: i64 = g.pick(i64, &.{ 10, 20, 30, 60, 90, 120, 180 });
    const end_s: i64 = 60 - @as(i64, @intCast(g.intRange(usize, 0, 40))) * 10 + if (g.boolean()) @as(i64, 5) else 0;
    const start_s: i64 = end_s - @as(i64, @intCast(g.intRange(usize, 1, 50))) * 10;
    const start: std.Io.Timestamp = .{ .nanoseconds = now_ns + @as(i96, start_s) * std.time.ns_per_s };
    const end: std.Io.Timestamp = .{ .nanoseconds = now_ns + @as(i96, end_s) * std.time.ns_per_s };
    const m = client.metric(sent_type);

    // The model: each period's total and how many series have a point in
    // it, newest first, for the points in (start, end].
    const Period = struct { end_s: i64, total: i64, series: usize, points: usize, max: i64 };
    var periods: std.ArrayList(Period) = .empty;
    var total: i64 = 0;
    var window_end = end_s;
    while (window_end > start_s) : (window_end -= period) {
        var p: Period = .{ .end_s = window_end, .total = 0, .series = 0, .points = 0, .max = 0 };
        var seen: [delta_series.len]bool = @splat(false);
        var any = false;
        for (model.items) |dp| {
            if (dp.end_s <= start_s or dp.end_s > end_s) continue;
            if (dp.end_s <= window_end - period or dp.end_s > window_end) continue;
            any = true;
            p.total += dp.value;
            p.points += 1;
            p.max = @max(p.max, dp.value);
            if (!seen[dp.series]) p.series += 1;
            seen[dp.series] = true;
        }
        total += p.total;
        if (any) try periods.append(a, p);
    }

    var summed = try m.read(.{ .start = start, .end = end, .aggregation = .{ .alignment_period_s = @intCast(period), .aligner = .delta, .reducer = .sum } });
    defer summed.deinit();
    var rated = try m.read(.{ .start = start, .end = end, .aggregation = .{ .alignment_period_s = @intCast(period), .aligner = .rate, .reducer = .sum } });
    defer rated.deinit();
    var counted = try m.read(.{ .start = start, .end = end, .aggregation = .{ .alignment_period_s = @intCast(period), .aligner = .delta, .reducer = .count } });
    defer counted.deinit();
    var sum_aligned = try m.read(.{ .start = start, .end = end, .aggregation = .{ .alignment_period_s = @intCast(period), .aligner = .sum, .reducer = .sum } });
    defer sum_aligned.deinit();
    var point_counts = try m.read(.{ .start = start, .end = end, .aggregation = .{ .alignment_period_s = @intCast(period), .aligner = .count, .reducer = .sum } });
    defer point_counts.deinit();
    var maxes = try m.read(.{ .start = start, .end = end, .aggregation = .{ .alignment_period_s = @intCast(period), .aligner = .max, .reducer = .max } });
    defer maxes.deinit();
    try testing.expectEqualStrings("1", summed.value.unit);
    try testing.expectEqualStrings("1/s", rated.value.unit);
    try testing.expectEqualStrings("1", counted.value.unit);
    try testing.expectEqualStrings("1", point_counts.value.unit);
    if (periods.items.len == 0) {
        // Nothing to count: no series, not zeros.
        for ([_][]const types.Series{ summed.value.series, rated.value.series, sum_aligned.value.series, point_counts.value.series, maxes.value.series }) |list| {
            try testing.expectEqual(0, list.len);
        }
        return;
    }
    try testing.expectEqual(1, summed.value.series.len);
    const s = summed.value.series[0];
    try testing.expectEqual(types.Kind.delta, s.kind);
    try testing.expectEqual(periods.items.len, s.points.len);
    const r = rated.value.series[0];
    try testing.expectEqual(types.Kind.gauge, r.kind);
    try testing.expectEqual(types.ValueType.double, r.value_type);
    try testing.expectEqual(types.Kind.delta, sum_aligned.value.series[0].kind);
    try testing.expectEqual(types.Kind.gauge, point_counts.value.series[0].kind);
    try testing.expectEqual(types.Kind.gauge, maxes.value.series[0].kind);
    for (periods.items, s.points, r.points, counted.value.series[0].points, sum_aligned.value.series[0].points, point_counts.value.series[0].points, maxes.value.series[0].points) |want, sp, rp, cp, ap, pp, mp| {
        try testing.expectEqual(sp.start.?.nanoseconds, ap.start.?.nanoseconds);
        try testing.expectEqual(sp.end.nanoseconds, ap.end.nanoseconds);
        try testing.expectEqual(want.total, ap.value.?.int64);
        try testing.expectEqual(sp.end.nanoseconds, pp.start.?.nanoseconds);
        try testing.expectEqual(@as(i64, @intCast(want.points)), pp.value.?.int64);
        try testing.expectEqual(want.max, mp.value.?.int64);
        const at = now_ns + @as(i96, want.end_s) * std.time.ns_per_s;
        try testing.expectEqual(at, sp.end.nanoseconds);
        try testing.expectEqual(at - @as(i96, period) * std.time.ns_per_s, sp.start.?.nanoseconds);
        try testing.expectEqual(want.total, sp.value.?.int64);
        try testing.expectEqual(at, rp.end.nanoseconds);
        try testing.expectApproxEqRel(@as(f64, @floatFromInt(want.total)), rp.value.?.double * @as(f64, @floatFromInt(period)), 1e-12);
        try testing.expectEqual(@as(i64, @intCast(want.series)), cp.value.?.int64);
    }

    // Grouped or unreduced, the totals add up to the same.
    var grouped = try m.read(.{ .start = start, .end = end, .aggregation = .{ .alignment_period_s = @intCast(period), .aligner = .delta, .reducer = .sum, .group_by = &.{"metric.labels.delivery_type"} } });
    defer grouped.deinit();
    var each = try m.read(.{ .start = start, .end = end, .aggregation = .{ .alignment_period_s = @intCast(period), .aligner = .delta } });
    defer each.deinit();
    for ([_][]const types.Series{ grouped.value.series, each.value.series }) |list| {
        var sum: i64 = 0;
        for (list) |series| {
            try testing.expectEqual(types.Kind.delta, series.kind);
            for (series.points) |p| sum += p.value.?.int64;
        }
        try testing.expectEqual(total, sum);
    }
    for (grouped.value.series) |series| try testing.expect(series.label("delivery_type") != null);
}

test "fuzz DELTA reads: each aligner a DELTA metric takes agrees with the points put in" {
    try test_util.fuzzBytes({}, deltaReadProperty, .{ .corpus = &.{
        "",
        "\x01\x00\x00\x00\x00\x00\x00\x00\x03\x00\x00\x00\x00\x00\x00\x00\x08",
        "\xff\xff\xff\xff\xff\xff\xff\xff\xff\xff\xff\xff\xff\xff\xff\xff\xff\xff\xff\xff\xff\xff\xff\xff\xff\xff\xff\xff\xff\xff\xff\xff",
    } });
}
