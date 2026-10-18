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
//!   label the descriptor lacks adds it. DELTA and STRING are refused
//!   under `custom.googleapis.com/`.
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
//!   earlier, or a total that fell under the same start. A reset, a start
//!   1 ms or more after the series' last end, is taken.
//! - Requests refused whole, as production refused them: none or more than
//!   200 series, a resource `project_id` naming another project, a
//!   descriptor production would not create.
//! - Times kept to the microsecond, as production keeps them.
//! - Faults a test asks for, and a write served and then answered with an
//!   error, as a 504 that stored the points is.
//!
//! Where it differs: times in its messages are UTC, where production wrote
//! US Pacific; a descriptor just made reads back at once, where production
//! answered 404 for about 2 s; its resource types are the seven
//! `Resource` names, only generic_task's text production's. Not modelled,
//! each answered 501 with the reason: another project, a cumulative start
//! moved later but inside the series' last interval (production took one,
//! and the earlier point vanished), distribution rules production was not
//! asked about, more than one point in a series, and filters other than a
//! type prefix.

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
                    else => notModelled(arena, "reading time series"),
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
    /// description, display name, type, and every resource type a user
    /// metric may be written to.
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
        for (catalog) |r| try jw.write(r.type);
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

    const Verdict = union(enum) { ok, refused: struct { code: u8, reason: []const u8 } };

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
            if (v.* == .ok) try f.keep(s);
        }

        var written: u32 = 0;
        var first: ?usize = null;
        for (verdicts, 0..) |v, i| switch (v) {
            .ok => written += 1,
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
        if (end - last.end.nanoseconds < min_gap_ns) return refused(9, try arena.print("write for resource failed: One or more points were written more frequently than the maximum sampling period configured for the metric. {{Metric: {s}, Timestamps: {{Youngest Existing: '{f}', New: '{f}'}}}}", .{ s.metric_type, Stamp{ .ns = last.end.nanoseconds }, Stamp{ .ns = end } }));
        if (kind != .gauge) {
            const start = truncated(s.start.?);
            const series_start = last.start.?.nanoseconds;
            if (start < series_start) return refused(3, older_start);
            if (start == series_start and fell(last.value, s.value)) return refused(3, older_start);
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

    fn refused(code: u8, reason: []const u8) Verdict {
        return .{ .refused = .{ .code = code, .reason = reason } };
    }

    /// Keeps an accepted point: the descriptor made or widened, the series
    /// made, the point added.
    fn keep(f: *FakeMonitoring, s: Sent) Allocator.Error!void {
        const st = f.store.allocator();
        const d = f.descriptors.get(s.metric_type) orelse try f.addDescriptor(s.metric_type, s.kind orelse .gauge, s.value_type orelse s.value.valueType(), s.unit);
        for (s.metric_labels) |l| {
            for (d.labels.items) |have| {
                if (std.mem.eql(u8, have.key, l.key)) break;
            } else try d.labels.append(st, .{ .key = try st.dupe(u8, l.key) });
        }
        const key = try identity(st, s);
        const gop = try f.series.getOrPut(f.gpa, key);
        if (!gop.found_existing) {
            const series = try st.create(Series);
            series.* = .{
                .metric_type = d.type,
                .metric_labels = try dupeLabels(st, try sortedLabels(st, s.metric_labels)),
                .resource_type = try st.dupe(u8, s.resource_type),
                .resource_labels = try dupeLabels(st, try withoutProject(st, try sortedLabels(st, s.resource_labels))),
                .kind = d.kind,
                .value_type = d.value_type,
            };
            gop.value_ptr.* = series;
        }
        const series = gop.value_ptr.*;
        try series.points.append(st, .{
            .start = if (d.kind == .gauge) null else .{ .nanoseconds = truncated(s.start.?) },
            .end = .{ .nanoseconds = truncated(s.end) },
            .value = try copyValue(st, s.value),
        });
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

// The resource types it knows: the ones `Resource` names.

const CatalogType = struct {
    type: []const u8,
    display_name: []const u8,
    description: []const u8 = "",
    /// Key and description, `project_id` first, as production lists them.
    labels: []const [2][]const u8,
    /// The labels that must name a region or a zone.
    location_labels: []const []const u8,
};

const project_label = .{ "project_id", "The identifier of the GCP project associated with this resource, such as \"my-project\"." };

/// generic_task's text is production's, measured 2026-10-18; the others'
/// labels are the ones `Resource` names, with no descriptions.
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
};

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
fn creationRefusal(arena: Allocator, metric_type: []const u8, kind: types.Kind, value_type: types.ValueType, labels: []const types.LabelDescriptor) Allocator.Error!?FakeMonitoring.Reply {
    if (std.mem.startsWith(u8, metric_type, validate.custom_domain)) {
        if (kind == .delta) return try fail(arena, 400, "INVALID_ARGUMENT", try arena.print("Field metricDescriptor.metricKind had an invalid value of \"DELTA\": When creating metric {s}: the DELTA metric kind is not supported for custom metrics.", .{metric_type}));
        if (value_type == .string) return try fail(arena, 400, "INVALID_ARGUMENT", try arena.print("Field metricDescriptor.valueType had an invalid value of \"STRING\": When creating metric {s}: the value type is not supported for custom metrics.", .{metric_type}));
    }
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
    var out: std.Io.Writer.Allocating = .init(arena);
    const w = &out.writer;
    w.writeAll(s.metric_type) catch return error.OutOfMemory;
    for (try sortedLabels(arena, s.metric_labels)) |l| w.print("\x00{s}\x01{s}", .{ l.key, l.value }) catch return error.OutOfMemory;
    w.print("\x02{s}", .{s.resource_type}) catch return error.OutOfMemory;
    for (try withoutProject(arena, try sortedLabels(arena, s.resource_labels))) |l| w.print("\x00{s}\x01{s}", .{ l.key, l.value }) catch return error.OutOfMemory;
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

/// Whether a cumulative total fell from `before` to `after`.
fn fell(before: types.Value, after: types.Value) bool {
    return switch (after) {
        .int64 => |n| before == .int64 and n < before.int64,
        .double => |d| before == .double and d < before.double,
        .distribution => |d| before == .distribution and d.count < before.distribution.count,
        else => false,
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
    const steps = [_]struct { i64, bool }{
        .{ 0, true },
        .{ 2_499, false },
        .{ 2_500, true },
        .{ 2_500, false }, // the same end again
        .{ 4_999, false },
        .{ 5_000, true },
        .{ 1_000, false }, // older: out of order
    };
    for (steps) |s| {
        var result = try b.client.write(&.{gaugeAt(g, labels, b.at(s[0]), 1)});
        defer result.deinit();
        try testing.expectEqual(s[1], result.value.ok());
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
    const falls = try refusedReason(&b, &.{cum.at(&b, -120_000, -30_000, 2)});
    defer testing.allocator.free(falls);
    try testing.expectEqualStrings(reasonOf(try messageOf(a, production.write_cumulative_falls)), falls);
    var more = try b.client.write(&.{cum.at(&b, -120_000, -30_000, 12)});
    defer more.deinit();
    try testing.expect(more.value.ok());
    // A reset: a new start 1 ms after the last end.
    var reset = try b.client.write(&.{cum.at(&b, -29_999, -20_000, 1)});
    defer reset.deinit();
    try testing.expect(reset.value.ok());
    const kept = try b.fake.points(a, c, &.{});
    try testing.expectEqual(3, kept.len);
    try testing.expectEqual(b.at(-29_999).nanoseconds, kept[2].start.?.nanoseconds);
    // A start moved later, inside the last interval: production took one
    // and lost a point; the fake says it does not model it.
    try testing.expectError(error.Unimplemented, b.client.write(&.{cum.at(&b, -25_000, -10_000, 5)}));
    try testing.expect(std.mem.indexOf(u8, b.diag.message(), "cumulative start moved later") != null);
    try testing.expectEqual(3, b.fake.pointCount());
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
    var all = try b.client.listMetrics(.{});
    defer all.deinit();
    try testing.expectEqual(5, all.value.metrics.len);
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
    try testing.expectEqual(4, rest.value.types.len);
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
    // A 504 that stored the point: tried again, it is refused as too
    // soon, which is why writes are not retried by default.
    b.fake.loseNext(1, 504);
    try testing.expectError(error.DeadlineExceeded, b.client.write(&.{gaugeAt(g, &.{}, b.at(0), 1)}));
    try testing.expectEqual(1, b.fake.pointCount());
    b.client.write_retries = .transient;
    b.fake.loseNext(1, 504);
    var replayed = try b.client.write(&.{gaugeAt(g, &.{}, b.at(5_000), 2)});
    defer replayed.deinit();
    try testing.expectEqual(0, replayed.value.written);
    try testing.expectEqual(error.FailedPrecondition, replayed.value.refused[0].reason);
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
        .{ .GET, "timeSeries" },
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

    // A cumulative double, and a distribution, whose totals fell.
    const cum: types.TimeSeries = .{ .metric_type = "custom.googleapis.com/seconds", .resource = probe_task, .kind = .cumulative, .start = b.at(-60_000), .end = b.at(-30_000), .value = .{ .double = 2.5 } };
    var ok = try b.client.write(&.{cum});
    ok.deinit();
    var lower = cum;
    lower.end = b.at(-20_000);
    lower.value = .{ .double = 1 };
    var fell_double = try b.client.write(&.{lower});
    defer fell_double.deinit();
    try testing.expect(!fell_double.value.ok());
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
    try testing.expect(!fell_count.value.ok());
    const kept = try b.fake.points(a, "custom.googleapis.com/latency", &.{});
    try testing.expectEqual(2, kept[0].value.distribution.count);
    try testing.expectEqual(2.0, kept[0].value.distribution.buckets.exponential.growth_factor);
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
    try testing.expectEqual(before - 1, b.fake.pointCount());

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
