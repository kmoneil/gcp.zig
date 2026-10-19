//! JSON out: a write's series and a descriptor to create. JSON in: metric
//! and resource descriptors and their pages, and the summary a write that
//! refused points carries in its error. A body is parsed into a
//! `std.json.Value` in a scratch arena and read from there, every string
//! copied into the result's arena. `null` counts as absent (the proto3 JSON
//! rule), unknown fields are ignored, enums read as names with `.unknown`
//! for a name this library does not know, and int64s arrive as strings or
//! numbers.

const std = @import("std");
const Allocator = std.mem.Allocator;
const Value = std.json.Value;
const Stringify = std.json.Stringify;
const core = @import("core");
const types = @import("types.zig");

pub const DecodeError = error{ InvalidResponse, OutOfMemory };

// Requests

/// A `timeSeries.create` body: one point for each series, with its kind
/// and value type, which a descriptor the write creates takes.
pub fn encodeWrite(arena: Allocator, series: []const types.TimeSeries) Allocator.Error![]u8 {
    return render(arena, WriteBody{ .series = series });
}

const WriteBody = struct {
    series: []const types.TimeSeries,

    fn write(self: WriteBody, jw: *Stringify) Stringify.Error!void {
        try jw.beginObject();
        try jw.objectField("timeSeries");
        try jw.beginArray();
        for (self.series) |s| try writeSeries(jw, s);
        try jw.endArray();
        try jw.endObject();
    }
};

fn writeSeries(jw: *Stringify, s: types.TimeSeries) Stringify.Error!void {
    try jw.beginObject();
    try jw.objectField("metric");
    try jw.beginObject();
    try jw.objectField("type");
    try jw.write(s.metric_type);
    try writeLabels(jw, s.metric_labels);
    try jw.endObject();
    try jw.objectField("resource");
    try jw.beginObject();
    try jw.objectField("type");
    try jw.write(s.resource.typeName());
    var buf: [types.Resource.max_named_labels]types.Label = undefined;
    try writeLabels(jw, s.resource.labels(&buf));
    try jw.endObject();
    try jw.objectField("metricKind");
    try jw.write(s.kind.wire());
    try jw.objectField("valueType");
    try jw.write(s.value.valueType().wire());
    if (s.unit.len > 0) {
        try jw.objectField("unit");
        try jw.write(s.unit);
    }
    try jw.objectField("points");
    try jw.beginArray();
    try jw.beginObject();
    try jw.objectField("interval");
    try jw.beginObject();
    // A gauge's start is its end, which the server takes as left out.
    if (s.kind != .gauge) if (s.start) |start| {
        try jw.objectField("startTime");
        try writeTimestamp(jw, start);
    };
    try jw.objectField("endTime");
    try writeTimestamp(jw, s.end);
    try jw.endObject();
    try jw.objectField("value");
    try writeValue(jw, s.value);
    try jw.endObject();
    try jw.endArray();
    try jw.endObject();
}

/// `labels` as an object, left out when empty.
fn writeLabels(jw: *Stringify, labels: []const types.Label) Stringify.Error!void {
    if (labels.len == 0) return;
    try jw.objectField("labels");
    try jw.beginObject();
    for (labels) |l| {
        try jw.objectField(l.key);
        try jw.write(l.value);
    }
    try jw.endObject();
}

fn writeValue(jw: *Stringify, v: types.Value) Stringify.Error!void {
    try jw.beginObject();
    switch (v) {
        .bool => |b| {
            try jw.objectField("boolValue");
            try jw.write(b);
        },
        .int64 => |n| {
            try jw.objectField("int64Value");
            try writeInt(jw, n);
        },
        .double => |d| {
            try jw.objectField("doubleValue");
            try writeDouble(jw, d);
        },
        .string => |text| {
            try jw.objectField("stringValue");
            try jw.write(text);
        },
        .distribution => |d| {
            try jw.objectField("distributionValue");
            try writeDistribution(jw, d);
        },
    }
    try jw.endObject();
}

fn writeDistribution(jw: *Stringify, d: types.Distribution) Stringify.Error!void {
    try jw.beginObject();
    if (d.count != 0) {
        try jw.objectField("count");
        try writeInt(jw, d.count);
    }
    if (d.mean != 0) {
        try jw.objectField("mean");
        try writeDouble(jw, d.mean);
    }
    if (d.sum_of_squared_deviation != 0) {
        try jw.objectField("sumOfSquaredDeviation");
        try writeDouble(jw, d.sum_of_squared_deviation);
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
            try writeDouble(jw, l.width);
            try jw.objectField("offset");
            try writeDouble(jw, l.offset);
            try jw.endObject();
        },
        .exponential => |e| {
            try jw.objectField("exponentialBuckets");
            try jw.beginObject();
            try jw.objectField("numFiniteBuckets");
            try jw.write(e.num_finite);
            try jw.objectField("growthFactor");
            try writeDouble(jw, e.growth_factor);
            try jw.objectField("scale");
            try writeDouble(jw, e.scale);
            try jw.endObject();
        },
        .explicit => |bounds| {
            try jw.objectField("explicitBuckets");
            try jw.beginObject();
            try jw.objectField("bounds");
            try jw.beginArray();
            for (bounds) |b| try writeDouble(jw, b);
            try jw.endArray();
            try jw.endObject();
        },
    }
    try jw.endObject();
    if (d.bucket_counts.len > 0) {
        try jw.objectField("bucketCounts");
        try jw.beginArray();
        for (d.bucket_counts) |c| try writeInt(jw, c);
        try jw.endArray();
    }
    try jw.endObject();
}

/// A `metricDescriptors.create` body.
pub fn encodeDescriptor(arena: Allocator, metric_type: []const u8, config: types.MetricConfig) Allocator.Error![]u8 {
    return render(arena, DescriptorBody{ .metric_type = metric_type, .config = config });
}

const DescriptorBody = struct {
    metric_type: []const u8,
    config: types.MetricConfig,

    fn write(self: DescriptorBody, jw: *Stringify) Stringify.Error!void {
        const c = self.config;
        try jw.beginObject();
        try jw.objectField("type");
        try jw.write(self.metric_type);
        try jw.objectField("metricKind");
        try jw.write(c.kind.wire());
        try jw.objectField("valueType");
        try jw.write(c.value_type.wire());
        if (c.unit.len > 0) {
            try jw.objectField("unit");
            try jw.write(c.unit);
        }
        if (c.description.len > 0) {
            try jw.objectField("description");
            try jw.write(c.description);
        }
        if (c.display_name.len > 0) {
            try jw.objectField("displayName");
            try jw.write(c.display_name);
        }
        if (c.labels.len > 0) {
            try jw.objectField("labels");
            try jw.beginArray();
            for (c.labels) |l| {
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
            try jw.endArray();
        }
        try jw.endObject();
    }
};

fn render(arena: Allocator, body: anytype) Allocator.Error![]u8 {
    var out: std.Io.Writer.Allocating = .init(arena);
    var jw: Stringify = .{ .writer = &out.writer };
    body.write(&jw) catch return error.OutOfMemory;
    return out.toOwnedSlice();
}

/// An int64 as proto3 JSON writes one: a decimal string.
fn writeInt(jw: *Stringify, n: anytype) Stringify.Error!void {
    var buf: [24]u8 = undefined;
    try jw.write(std.fmt.bufPrint(&buf, "{d}", .{n}) catch unreachable);
}

/// A double as JSON allows: a number, exact, in plain decimal where that
/// stays short and in exponent form elsewhere, or one of the three strings
/// proto3 JSON uses for what JSON has no number for, which production took
/// in a written point.
pub fn writeDouble(jw: *Stringify, d: f64) Stringify.Error!void {
    if (std.math.isNan(d)) return jw.write("NaN");
    if (std.math.isInf(d)) return jw.write(if (d > 0) "Infinity" else "-Infinity");
    const magnitude = @abs(d);
    if (magnitude == 0 or (magnitude >= 1e-6 and magnitude < 1e21)) {
        try jw.print("{d}", .{d});
    } else {
        try jw.print("{e}", .{d});
    }
}

/// RFC 3339 in UTC. The timestamp has been checked to be in range.
fn writeTimestamp(jw: *Stringify, ts: std.Io.Timestamp) Stringify.Error!void {
    var buf: [core.timestamp.max_len]u8 = undefined;
    try jw.write(core.timestamp.format(&buf, ts));
}

// Responses

/// A metric descriptor, as create and get answer.
pub fn decodeMetricInfo(out: Allocator, scratch: Allocator, body: []const u8) DecodeError!types.MetricInfo {
    return metricInfo(out, try parse(scratch, body));
}

/// A page of `metricDescriptors.list`: `{}` is an empty last page.
pub fn decodeMetricPage(out: Allocator, scratch: Allocator, body: []const u8) DecodeError!types.MetricPage {
    const obj = try object(try parse(scratch, body));
    const list = try field(obj, "metricDescriptors", .array);
    const metrics = try out.alloc(types.MetricInfo, if (list) |l| l.items.len else 0);
    if (list) |l| for (l.items, metrics) |v, *m| {
        m.* = try metricInfo(out, v);
    };
    return .{ .metrics = metrics, .next_page_token = try token(out, obj) };
}

/// A monitored resource descriptor, as get answers.
pub fn decodeResourceType(out: Allocator, scratch: Allocator, body: []const u8) DecodeError!types.ResourceTypeInfo {
    return resourceType(out, try parse(scratch, body));
}

/// A page of `monitoredResourceDescriptors.list`.
pub fn decodeResourceTypePage(out: Allocator, scratch: Allocator, body: []const u8) DecodeError!types.ResourceTypePage {
    const obj = try object(try parse(scratch, body));
    const list = try field(obj, "resourceDescriptors", .array);
    const items = try out.alloc(types.ResourceTypeInfo, if (list) |l| l.items.len else 0);
    if (list) |l| for (l.items, items) |v, *r| {
        r.* = try resourceType(out, v);
    };
    return .{ .types = items, .next_page_token = try token(out, obj) };
}

/// An alert, as get answers.
pub fn decodeAlert(out: Allocator, scratch: Allocator, body: []const u8) DecodeError!types.Alert {
    return alertOf(out, scratch, try parse(scratch, body));
}

/// A page of `alerts.list`: `{}` is an empty last page.
pub fn decodeAlertPage(out: Allocator, scratch: Allocator, body: []const u8) DecodeError!types.AlertPage {
    const obj = try object(try parse(scratch, body));
    const list = try field(obj, "alerts", .array);
    const alerts = try out.alloc(types.Alert, if (list) |l| l.items.len else 0);
    if (list) |l| for (l.items, alerts) |v, *a| {
        a.* = try alertOf(out, scratch, v);
    };
    return .{
        .alerts = alerts,
        .next_page_token = try token(out, obj),
        .total_size = try integer(i64, obj, "totalSize"),
    };
}

fn alertOf(out: Allocator, scratch: Allocator, v: Value) DecodeError!types.Alert {
    const obj = try object(v);
    const name = try string(out, obj, "name") orelse return error.InvalidResponse;
    var alert: types.Alert = .{
        .name = name,
        .id = if (std.mem.lastIndexOfScalar(u8, name, '/')) |i| name[i + 1 ..] else name,
        .state = if (try field(obj, "state", .string)) |s| types.AlertState.fromWire(s) else .unknown,
        .open_time = try time(obj, "openTime") orelse return error.InvalidResponse,
        .close_time = try time(obj, "closeTime"),
    };
    if (try field(obj, "policy", .object)) |p| alert.policy = .{
        .name = try string(out, p, "name") orelse "",
        .display_name = try string(out, p, "displayName") orelse "",
        .severity = if (try field(p, "severity", .string)) |s| types.Severity.fromWire(s) else .unspecified,
        .user_labels = try labelMapNamed(out, p, "userLabels"),
    };
    if (try field(obj, "metric", .object)) |m| {
        alert.metric_type = try string(out, m, "type") orelse "";
        alert.metric_labels = try labelMapNamed(out, m, "labels");
    }
    if (try field(obj, "resource", .object)) |r| {
        alert.resource_type = try string(out, r, "type") orelse "";
        alert.resource_labels = try labelMapNamed(out, r, "labels");
    }
    if (try field(obj, "metadata", .object)) |m| {
        alert.metadata_user_labels = try labelMapNamed(out, m, "userLabels");
        if (m.get("systemLabels")) |sl| alert.system_labels = try jsonCopy(out, scratch, sl);
    }
    if (try field(obj, "log", .object)) |l| {
        alert.log_labels = try labelMapNamed(out, l, "extractedLabels");
    }
    return alert;
}

fn metricInfo(out: Allocator, v: Value) DecodeError!types.MetricInfo {
    const obj = try object(v);
    const type_name = try string(out, obj, "type") orelse return error.InvalidResponse;
    var resource_types: []const []const u8 = &.{};
    if (try field(obj, "monitoredResourceTypes", .array)) |list| {
        const names = try out.alloc([]const u8, list.items.len);
        for (list.items, names) |item, *n| n.* = switch (item) {
            .string => |s| try out.dupe(u8, s),
            else => return error.InvalidResponse,
        };
        resource_types = names;
    }
    return .{
        .type = type_name,
        .kind = if (try field(obj, "metricKind", .string)) |k| types.Kind.fromWire(k) else .unknown,
        .value_type = if (try field(obj, "valueType", .string)) |t| types.ValueType.fromWire(t) else .unknown,
        .unit = try string(out, obj, "unit") orelse "",
        .description = try string(out, obj, "description") orelse "",
        .display_name = try string(out, obj, "displayName") orelse "",
        .labels = try labelDescriptors(out, obj),
        .resource_types = resource_types,
    };
}

fn resourceType(out: Allocator, v: Value) DecodeError!types.ResourceTypeInfo {
    const obj = try object(v);
    return .{
        .type = try string(out, obj, "type") orelse return error.InvalidResponse,
        .display_name = try string(out, obj, "displayName") orelse "",
        .description = try string(out, obj, "description") orelse "",
        .labels = try labelDescriptors(out, obj),
    };
}

/// `labels`: a missing `valueType` is a string, the proto's default.
fn labelDescriptors(out: Allocator, obj: std.json.ObjectMap) DecodeError![]const types.LabelDescriptor {
    const list = try field(obj, "labels", .array) orelse return &.{};
    const labels = try out.alloc(types.LabelDescriptor, list.items.len);
    for (list.items, labels) |item, *l| {
        const o = try object(item);
        l.* = .{
            .key = try string(out, o, "key") orelse return error.InvalidResponse,
            .value_type = if (try field(o, "valueType", .string)) |t| types.LabelType.fromWire(t) else .string,
            .description = try string(out, o, "description") orelse "",
        };
    }
    return labels;
}

/// A page of `timeSeries.list`: `{}` is an empty last page. Points stay
/// newest first, as the server sends them.
pub fn decodeSeriesPage(out: Allocator, scratch: Allocator, body: []const u8) DecodeError!types.SeriesPage {
    const obj = try object(try parse(scratch, body));
    const list = try field(obj, "timeSeries", .array);
    const series = try out.alloc(types.Series, if (list) |l| l.items.len else 0);
    if (list) |l| for (l.items, series) |v, *s| {
        s.* = try seriesOf(out, v);
    };
    var execution_errors: []const types.ExecutionError = &.{};
    if (try field(obj, "executionErrors", .array)) |errs| {
        const items = try out.alloc(types.ExecutionError, errs.items.len);
        for (errs.items, items) |e, *x| {
            const eo = try object(e);
            x.* = .{
                .reason = core.errors.fromRpcCode(try integer(i64, eo, "code") orelse 0),
                .message = try string(out, eo, "message") orelse "",
            };
        }
        execution_errors = items;
    }
    var unreachable_regions: []const []const u8 = &.{};
    if (try field(obj, "unreachable", .array)) |regions| {
        const items = try out.alloc([]const u8, regions.items.len);
        for (regions.items, items) |r, *x| x.* = switch (r) {
            .string => |text| try out.dupe(u8, text),
            else => return error.InvalidResponse,
        };
        unreachable_regions = items;
    }
    return .{
        .series = series,
        .next_page_token = try token(out, obj),
        .execution_errors = execution_errors,
        .unreachable_regions = unreachable_regions,
        .unit = try string(out, obj, "unit") orelse "",
    };
}

fn seriesOf(out: Allocator, v: Value) DecodeError!types.Series {
    const obj = try object(v);
    const metric = try field(obj, "metric", .object) orelse return error.InvalidResponse;
    const resource = try field(obj, "resource", .object) orelse return error.InvalidResponse;
    var points: []const types.ReadPoint = &.{};
    if (try field(obj, "points", .array)) |list| {
        const items = try out.alloc(types.ReadPoint, list.items.len);
        for (list.items, items) |p, *x| x.* = try pointOf(out, p);
        points = items;
    }
    return .{
        .metric_type = try string(out, metric, "type") orelse return error.InvalidResponse,
        .metric_labels = try labelMap(out, metric),
        .resource_type = try string(out, resource, "type") orelse return error.InvalidResponse,
        .resource_labels = try labelMap(out, resource),
        .kind = if (try field(obj, "metricKind", .string)) |k| types.Kind.fromWire(k) else .unknown,
        .value_type = if (try field(obj, "valueType", .string)) |t| types.ValueType.fromWire(t) else .unknown,
        .unit = try string(out, obj, "unit") orelse "",
        .points = points,
    };
}

/// `labels` as pairs, in the order the server wrote them.
fn labelMap(out: Allocator, obj: std.json.ObjectMap) DecodeError![]const types.Label {
    return labelMapNamed(out, obj, "labels");
}

/// A map field's pairs, in the order the server wrote them.
fn labelMapNamed(out: Allocator, obj: std.json.ObjectMap, name: []const u8) DecodeError![]const types.Label {
    const labels = try field(obj, name, .object) orelse return &.{};
    const items = try out.alloc(types.Label, labels.count());
    for (labels.keys(), labels.values(), items) |k, v, *l| l.* = .{
        .key = try out.dupe(u8, k),
        .value = switch (v) {
            .string => |s| try out.dupe(u8, s),
            else => return error.InvalidResponse,
        },
    };
    return items;
}

/// A deep copy of `v` into `out`, for a subtree kept as it came.
fn jsonCopy(out: Allocator, scratch: Allocator, v: Value) DecodeError!Value {
    var w: std.Io.Writer.Allocating = .init(scratch);
    var jw: Stringify = .{ .writer = &w.writer };
    jw.write(v) catch return error.OutOfMemory;
    return std.json.parseFromSliceLeaky(Value, out, w.written(), .{ .parse_numbers = false }) catch |err| switch (err) {
        error.OutOfMemory => error.OutOfMemory,
        else => error.InvalidResponse,
    };
}

fn pointOf(out: Allocator, v: Value) DecodeError!types.ReadPoint {
    const obj = try object(v);
    const interval = try field(obj, "interval", .object) orelse return error.InvalidResponse;
    const value = try field(obj, "value", .object) orelse return error.InvalidResponse;
    return .{
        .start = try time(interval, "startTime"),
        .end = try time(interval, "endTime") orelse return error.InvalidResponse,
        .value = try valueOf(out, value),
    };
}

fn time(obj: std.json.ObjectMap, name: []const u8) DecodeError!?std.Io.Timestamp {
    const text = try field(obj, name, .string) orelse return null;
    return core.timestamp.parse(text) catch error.InvalidResponse;
}

/// A point's value, or null for one this library does not read.
fn valueOf(out: Allocator, obj: std.json.ObjectMap) DecodeError!?types.Value {
    if (obj.get("boolValue")) |v| return .{ .bool = switch (v) {
        .bool => |b| b,
        else => return error.InvalidResponse,
    } };
    if (try integer(i64, obj, "int64Value")) |n| return .{ .int64 = n };
    if (obj.get("doubleValue")) |v| return .{ .double = try doubleOf(v) };
    if (try string(out, obj, "stringValue")) |s| return .{ .string = s };
    if (try field(obj, "distributionValue", .object)) |d| return .{ .distribution = try distributionOf(out, d) };
    return null;
}

/// A double: a number, or one of the strings proto3 JSON uses for what JSON
/// has no number for.
fn doubleOf(v: Value) DecodeError!f64 {
    switch (v) {
        .string => |s| {
            if (std.mem.eql(u8, s, "NaN")) return std.math.nan(f64);
            if (std.mem.eql(u8, s, "Infinity")) return std.math.inf(f64);
            if (std.mem.eql(u8, s, "-Infinity")) return -std.math.inf(f64);
            return error.InvalidResponse;
        },
        // A JSON number's own text, so never "inf" or hex.
        .number_string => |s| return std.fmt.parseFloat(f64, s) catch error.InvalidResponse,
        else => return error.InvalidResponse,
    }
}

fn optionalDouble(obj: std.json.ObjectMap, name: []const u8) DecodeError!f64 {
    const v = obj.get(name) orelse return 0;
    if (v == .null) return 0;
    return doubleOf(v);
}

/// A distribution. One without `bucketOptions` has no buckets, which reads
/// as an explicit layout with no bounds.
fn distributionOf(out: Allocator, obj: std.json.ObjectMap) DecodeError!types.Distribution {
    var d: types.Distribution = .{
        .count = try integer(u64, obj, "count") orelse 0,
        .mean = try optionalDouble(obj, "mean"),
        .sum_of_squared_deviation = try optionalDouble(obj, "sumOfSquaredDeviation"),
        .buckets = .{ .explicit = &.{} },
    };
    if (try field(obj, "bucketOptions", .object)) |options| {
        if (try field(options, "linearBuckets", .object)) |l| {
            d.buckets = .{ .linear = .{ .num_finite = try integer(u32, l, "numFiniteBuckets") orelse 0, .width = try optionalDouble(l, "width"), .offset = try optionalDouble(l, "offset") } };
        } else if (try field(options, "exponentialBuckets", .object)) |e| {
            d.buckets = .{ .exponential = .{ .num_finite = try integer(u32, e, "numFiniteBuckets") orelse 0, .growth_factor = try optionalDouble(e, "growthFactor"), .scale = try optionalDouble(e, "scale") } };
        } else if (try field(options, "explicitBuckets", .object)) |e| {
            const bounds_v = try field(e, "bounds", .array) orelse return error.InvalidResponse;
            const bounds = try out.alloc(f64, bounds_v.items.len);
            for (bounds_v.items, bounds) |b, *x| x.* = try doubleOf(b);
            d.buckets = .{ .explicit = bounds };
        } else return error.InvalidResponse;
    }
    if (try field(obj, "bucketCounts", .array)) |counts_v| {
        const counts = try out.alloc(u64, counts_v.items.len);
        for (counts_v.items, counts) |c, *x| x.* = switch (c) {
            .number_string, .string => |s| std.fmt.parseInt(u64, s, 10) catch return error.InvalidResponse,
            else => return error.InvalidResponse,
        };
        d.bucket_counts = counts;
    }
    return d;
}

/// What a write's error said about its points: the `CreateTimeSeriesSummary`
/// production puts in the error's `details` whenever it judged the points
/// one by one, at HTTP 400 when measured, whatever else the request held.
pub const Summary = struct {
    total: u32,
    written: u32,
    refused: []const types.WriteResult.Refusal,
    message: []const u8,
};

/// The summary in a write's error body, or null when it has none: a body
/// that is not Google's error, or an error about the request as a whole,
/// such as a descriptor production would not create.
pub fn decodeSummary(out: Allocator, scratch: Allocator, body: []const u8) DecodeError!?Summary {
    const root = parse(scratch, body) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        error.InvalidResponse => return null,
    };
    if (root != .object) return null;
    const err_v = root.object.get("error") orelse return null;
    if (err_v != .object) return null;
    const details = (field(err_v.object, "details", .array) catch return null) orelse return null;
    for (details.items) |d| {
        if (d != .object) continue;
        const t = (field(d.object, "@type", .string) catch continue) orelse continue;
        if (!std.mem.endsWith(u8, t, "/google.monitoring.v3.CreateTimeSeriesSummary")) continue;
        const total = try count(d.object, "totalPointCount");
        const written = try count(d.object, "successPointCount");
        if (written > total) return error.InvalidResponse;
        var refused: std.ArrayList(types.WriteResult.Refusal) = .empty;
        if (try field(d.object, "errors", .array)) |errors| for (errors.items) |e| {
            const eo = try object(e);
            const status = try field(eo, "status", .object);
            const code: i64 = if (status) |s| try integer(i64, s, "code") orelse 0 else 0;
            try refused.append(out, .{ .reason = core.errors.fromRpcCode(code), .points = try count(eo, "pointCount") });
        };
        return .{
            .total = total,
            .written = written,
            .refused = refused.items,
            .message = try string(out, err_v.object, "message") orelse "",
        };
    }
    return null;
}

/// A point count: absent when 0, as proto3 JSON leaves zeros out.
fn count(obj: std.json.ObjectMap, name: []const u8) DecodeError!u32 {
    return try integer(u32, obj, name) orelse 0;
}

fn parse(scratch: Allocator, body: []const u8) DecodeError!Value {
    return std.json.parseFromSliceLeaky(Value, scratch, body, .{ .parse_numbers = false }) catch |err| switch (err) {
        error.OutOfMemory => error.OutOfMemory,
        else => error.InvalidResponse,
    };
}

fn object(v: Value) DecodeError!std.json.ObjectMap {
    return switch (v) {
        .object => |o| o,
        else => error.InvalidResponse,
    };
}

/// The field's value when it holds `tag`, null when absent or `null`, and
/// `InvalidResponse` when it holds anything else.
fn field(obj: std.json.ObjectMap, name: []const u8, comptime tag: std.meta.Tag(Value)) DecodeError!?@FieldType(Value, @tagName(tag)) {
    const v = obj.get(name) orelse return null;
    if (v == .null) return null;
    if (v != tag) return error.InvalidResponse;
    return @field(v, @tagName(tag));
}

fn string(out: Allocator, obj: std.json.ObjectMap, name: []const u8) DecodeError!?[]const u8 {
    const s = try field(obj, name, .string) orelse return null;
    return try out.dupe(u8, s);
}

/// `nextPageToken`: absent or "" ends the list.
fn token(out: Allocator, obj: std.json.ObjectMap) DecodeError!?[]const u8 {
    const t = try field(obj, "nextPageToken", .string) orelse return null;
    if (t.len == 0) return null;
    return try out.dupe(u8, t);
}

/// An integer that may arrive as a string, as int64s do, or as a number,
/// which the parser keeps as its text.
fn integer(comptime T: type, obj: std.json.ObjectMap, name: []const u8) DecodeError!?T {
    const v = obj.get(name) orelse return null;
    const text = switch (v) {
        .null => return null,
        .number_string, .string => |s| s,
        else => return error.InvalidResponse,
    };
    return std.fmt.parseInt(T, text, 10) catch error.InvalidResponse;
}

const testing = std.testing;
const production = @import("production_bodies.zig");

const t0: std.Io.Timestamp = .{ .nanoseconds = 1_792_144_800 * std.time.ns_per_s };
const t1: std.Io.Timestamp = .{ .nanoseconds = 1_792_145_100 * std.time.ns_per_s + 123 * std.time.ns_per_ms };
const task: types.Resource = .{ .generic_task = .{ .location = "europe-west1", .namespace = "shop", .job = "api", .task_id = "7f9c2a" } };

test "golden: the spec's write, a cumulative int64 to generic_task" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const body = try encodeWrite(arena.allocator(), &.{.{
        .metric_type = "custom.googleapis.com/shop/orders",
        .metric_labels = &.{.{ .key = "region", .value = "eu" }},
        .resource = task,
        .kind = .cumulative,
        .unit = "{order}",
        .start = t0,
        .end = t1,
        .value = .{ .int64 = 4217 },
    }});
    try testing.expectEqualStrings(
        \\{"timeSeries":[{"metric":{"type":"custom.googleapis.com/shop/orders","labels":{"region":"eu"}},"resource":{"type":"generic_task","labels":{"location":"europe-west1","namespace":"shop","job":"api","task_id":"7f9c2a"}},"metricKind":"CUMULATIVE","valueType":"INT64","unit":"{order}","points":[{"interval":{"startTime":"2026-10-16T10:00:00Z","endTime":"2026-10-16T10:05:00.123Z"},"value":{"int64Value":"4217"}}]}]}
    , body);
}

test "golden: every value type, a gauge's start left out, global with no labels" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const cases = [_]struct { types.Value, []const u8 }{
        .{ .{ .bool = true }, "{\"boolValue\":true}" },
        .{ .{ .int64 = -9223372036854775808 }, "{\"int64Value\":\"-9223372036854775808\"}" },
        .{ .{ .double = 1.5 }, "{\"doubleValue\":1.5}" },
        .{ .{ .double = 1e300 }, "{\"doubleValue\":1e300}" },
        .{ .{ .double = std.math.nan(f64) }, "{\"doubleValue\":\"NaN\"}" },
        .{ .{ .double = std.math.inf(f64) }, "{\"doubleValue\":\"Infinity\"}" },
        .{ .{ .double = -std.math.inf(f64) }, "{\"doubleValue\":\"-Infinity\"}" },
        .{ .{ .string = "say \"hi\"" }, "{\"stringValue\":\"say \\\"hi\\\"\"}" },
    };
    for (cases) |c| {
        const body = try encodeWrite(a, &.{.{ .metric_type = "external.googleapis.com/x", .resource = .global, .kind = .gauge, .start = t1, .end = t1, .value = c[0] }});
        const want = try std.fmt.allocPrint(a, "{{\"timeSeries\":[{{\"metric\":{{\"type\":\"external.googleapis.com/x\"}},\"resource\":{{\"type\":\"global\"}},\"metricKind\":\"GAUGE\",\"valueType\":\"{s}\",\"points\":[{{\"interval\":{{\"endTime\":\"2026-10-16T10:05:00.123Z\"}},\"value\":{s}}}]}}]}}", .{ c[0].valueType().wire(), c[1] });
        try testing.expectEqualStrings(want, body);
    }
}

test "golden: distributions in each layout, zeros left out" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const cases = [_]struct { types.Distribution, []const u8 }{
        .{ .{ .count = 3, .mean = 2, .sum_of_squared_deviation = 2, .buckets = .{ .explicit = &.{ 1, 2.5 } }, .bucket_counts = &.{ 0, 2, 1 } }, "{\"count\":\"3\",\"mean\":2,\"sumOfSquaredDeviation\":2,\"bucketOptions\":{\"explicitBuckets\":{\"bounds\":[1,2.5]}},\"bucketCounts\":[\"0\",\"2\",\"1\"]}" },
        .{ .{ .buckets = .{ .linear = .{ .num_finite = 4, .width = 0.5, .offset = -1 } } }, "{\"bucketOptions\":{\"linearBuckets\":{\"numFiniteBuckets\":4,\"width\":0.5,\"offset\":-1}}}" },
        .{ .{ .count = 1, .mean = 10, .buckets = .{ .exponential = .{ .num_finite = 8, .growth_factor = 2, .scale = 1 } }, .bucket_counts = &.{ 0, 0, 0, 0, 0, 1 } }, "{\"count\":\"1\",\"mean\":10,\"bucketOptions\":{\"exponentialBuckets\":{\"numFiniteBuckets\":8,\"growthFactor\":2,\"scale\":1}},\"bucketCounts\":[\"0\",\"0\",\"0\",\"0\",\"0\",\"1\"]}" },
    };
    for (cases) |c| {
        const body = try encodeWrite(a, &.{.{ .metric_type = "custom.googleapis.com/h", .resource = .global, .kind = .cumulative, .start = t0, .end = t1, .value = .{ .distribution = c[0] } }});
        const at = std.mem.indexOf(u8, body, "\"distributionValue\":").? + "\"distributionValue\":".len;
        try testing.expectEqualStrings(c[1], body[at .. body.len - "}}]}]}".len]);
    }
}

test "golden: a descriptor to create, defaults left out" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try testing.expectEqualStrings(
        \\{"type":"custom.googleapis.com/shop/orders","metricKind":"CUMULATIVE","valueType":"INT64","unit":"{order}","description":"Orders taken","displayName":"Orders","labels":[{"key":"region","description":"Where"},{"key":"paid","valueType":"BOOL"},{"key":"items","valueType":"INT64"}]}
    , try encodeDescriptor(a, "custom.googleapis.com/shop/orders", .{
        .kind = .cumulative,
        .value_type = .int64,
        .unit = "{order}",
        .description = "Orders taken",
        .display_name = "Orders",
        .labels = &.{ .{ .key = "region", .description = "Where" }, .{ .key = "paid", .value_type = .bool }, .{ .key = "items", .value_type = .int64 } },
    }));
    try testing.expectEqualStrings(
        \\{"type":"custom.googleapis.com/g","metricKind":"GAUGE","valueType":"DOUBLE"}
    , try encodeDescriptor(a, "custom.googleapis.com/g", .{ .kind = .gauge, .value_type = .double }));
}

test "decodeMetricInfo: production's descriptor, label types defaulted, unknown enums" {
    var out: std.heap.ArenaAllocator = .init(testing.allocator);
    defer out.deinit();
    var scratch: std.heap.ArenaAllocator = .init(testing.allocator);
    defer scratch.deinit();
    const info = try decodeMetricInfo(out.allocator(), scratch.allocator(), production.descriptor_get);
    try testing.expectEqualStrings("custom.googleapis.com/zigps-m0-62b2c8/gauge", info.type);
    try testing.expectEqual(types.Kind.gauge, info.kind);
    try testing.expectEqual(types.ValueType.int64, info.value_type);
    try testing.expectEqualStrings("1", info.unit);
    try testing.expectEqualStrings("zig-gcp milestone 0 probe", info.description);
    try testing.expectEqual(1, info.labels.len);
    try testing.expectEqualStrings("k", info.labels[0].key);
    try testing.expectEqual(types.LabelType.string, info.labels[0].value_type);

    const odd = try decodeMetricInfo(out.allocator(), scratch.allocator(),
        \\{"type":"t","metricKind":"SOMETHING_NEW","valueType":"INT128","labels":[{"key":"a","valueType":"DOUBLE"}],"monitoredResourceTypes":["generic_task","global"],"launchStage":"GA","unknown":{"x":1}}
    );
    try testing.expectEqual(types.Kind.unknown, odd.kind);
    try testing.expectEqual(types.ValueType.unknown, odd.value_type);
    try testing.expectEqual(types.LabelType.unknown, odd.labels[0].value_type);
    try testing.expectEqualStrings("global", odd.resource_types[1]);
    for ([_][]const u8{ "", "[]", "{}", "{\"type\":1}", "{\"type\":\"t\",\"labels\":[{}]}", "{\"type\":\"t\",\"labels\":{}}", "{\"type\":\"t\",\"monitoredResourceTypes\":[1]}" }) |bad| {
        try testing.expectError(error.InvalidResponse, decodeMetricInfo(out.allocator(), scratch.allocator(), bad));
    }
}

test "decodeMetricPage and the resource type decoders" {
    var out: std.heap.ArenaAllocator = .init(testing.allocator);
    defer out.deinit();
    var scratch: std.heap.ArenaAllocator = .init(testing.allocator);
    defer scratch.deinit();
    const a = out.allocator();
    const s = scratch.allocator();
    const page = try decodeMetricPage(a, s, "{\"metricDescriptors\":[{\"type\":\"a/b\",\"metricKind\":\"GAUGE\",\"valueType\":\"BOOL\"},{\"type\":\"c/d\"}],\"nextPageToken\":\"tok\"}");
    try testing.expectEqual(2, page.metrics.len);
    try testing.expectEqual(types.ValueType.bool, page.metrics[0].value_type);
    try testing.expectEqual(types.Kind.unknown, page.metrics[1].kind);
    try testing.expectEqualStrings("tok", page.next_page_token.?);
    const last = try decodeMetricPage(a, s, "{}");
    try testing.expectEqual(0, last.metrics.len);
    try testing.expectEqual(null, last.next_page_token);
    try testing.expectEqual(null, (try decodeMetricPage(a, s, "{\"nextPageToken\":\"\"}")).next_page_token);

    const generic = try decodeResourceType(a, s, production.resource_generic_task);
    try testing.expectEqualStrings("generic_task", generic.type);
    try testing.expectEqual(5, generic.labels.len);
    try testing.expectEqualStrings("project_id", generic.labels[0].key);
    try testing.expectEqualStrings("task_id", generic.labels[4].key);
    const rpage = try decodeResourceTypePage(a, s, "{\"resourceDescriptors\":[{\"type\":\"global\",\"labels\":[{\"key\":\"project_id\"}]}],\"nextPageToken\":\"n\"}");
    try testing.expectEqualStrings("global", rpage.types[0].type);
    try testing.expectEqualStrings("n", rpage.next_page_token.?);
    try testing.expectError(error.InvalidResponse, decodeResourceTypePage(a, s, "{\"resourceDescriptors\":{}}"));
    try testing.expectError(error.InvalidResponse, decodeResourceType(a, s, "{}"));
}

test "decodeSummary: production's bodies, each refusal it gave" {
    var out: std.heap.ArenaAllocator = .init(testing.allocator);
    defer out.deinit();
    var scratch: std.heap.ArenaAllocator = .init(testing.allocator);
    defer scratch.deinit();
    const a = out.allocator();
    const s = scratch.allocator();

    const frequent = (try decodeSummary(a, s, production.write_too_frequent)).?;
    try testing.expectEqual(1, frequent.total);
    try testing.expectEqual(0, frequent.written);
    try testing.expectEqual(1, frequent.refused.len);
    try testing.expectEqual(error.FailedPrecondition, frequent.refused[0].reason);
    try testing.expectEqual(1, frequent.refused[0].points);
    try testing.expect(std.mem.indexOf(u8, frequent.message, "more frequently than the maximum sampling period") != null);

    const mixed = (try decodeSummary(a, s, production.write_mixed)).?;
    try testing.expectEqual(3, mixed.total);
    try testing.expectEqual(2, mixed.written);
    try testing.expectEqual(error.InvalidArgument, mixed.refused[0].reason);

    const dup = (try decodeSummary(a, s, production.write_duplicate)).?;
    try testing.expectEqual(1, dup.written);
    try testing.expect(std.mem.indexOf(u8, dup.message, "Duplicate TimeSeries encountered") != null);

    // A request refused whole has no summary.
    for ([_][]const u8{ production.write_delta_custom, production.write_201_series, production.write_empty, "", "not json", "[]", "{\"error\":1}", "{\"error\":{\"details\":[1,{\"@type\":2}]}}" }) |body| {
        try testing.expectEqual(null, try decodeSummary(a, s, body));
    }
    // Codes the research quoted: a 500 with INTERNAL, and both codes at once.
    const both = (try decodeSummary(a, s,
        \\{"error":{"code":500,"message":"m","status":"INTERNAL","details":[{"@type":"type.googleapis.com/google.monitoring.v3.CreateTimeSeriesSummary","totalPointCount":"5","successPointCount":1,"errors":[{"status":{"code":9},"pointCount":2},{"status":{"code":13},"pointCount":"2"},{"pointCount":0}]}]}}
    )).?;
    try testing.expectEqual(5, both.total);
    try testing.expectEqual(error.FailedPrecondition, both.refused[0].reason);
    try testing.expectEqual(error.Internal, both.refused[1].reason);
    try testing.expectEqual(2, both.refused[1].points);
    try testing.expectEqual(error.Unknown, both.refused[2].reason);
    try testing.expectError(error.InvalidResponse, decodeSummary(a, s,
        \\{"error":{"details":[{"@type":"type.googleapis.com/google.monitoring.v3.CreateTimeSeriesSummary","totalPointCount":1,"successPointCount":2}]}}
    ));
    try testing.expectError(error.InvalidResponse, decodeSummary(a, s,
        \\{"error":{"details":[{"@type":"type.googleapis.com/google.monitoring.v3.CreateTimeSeriesSummary","totalPointCount":-1}]}}
    ));
    try testing.expectError(error.InvalidResponse, decodeSummary(a, s,
        \\{"error":{"details":[{"@type":"type.googleapis.com/google.monitoring.v3.CreateTimeSeriesSummary","totalPointCount":true}]}}
    ));
    // null is absent, as proto3 JSON has it.
    const nulls = (try decodeSummary(a, s,
        \\{"error":{"message":null,"details":[{"@type":"type.googleapis.com/google.monitoring.v3.CreateTimeSeriesSummary","totalPointCount":2,"successPointCount":null,"errors":[{"status":null,"pointCount":2}]}]}}
    )).?;
    try testing.expectEqual(0, nulls.written);
    try testing.expectEqual(error.Unknown, nulls.refused[0].reason);
    try testing.expectEqualStrings("", nulls.message);
}

fn decodersProperty(_: void, input: []const u8) !void {
    var out: std.heap.ArenaAllocator = .init(testing.allocator);
    defer out.deinit();
    var scratch: std.heap.ArenaAllocator = .init(testing.allocator);
    defer scratch.deinit();
    const a = out.allocator();
    const s = scratch.allocator();
    if (decodeSummary(a, s, input)) |summary| {
        if (summary) |sum| try testing.expect(sum.written <= sum.total);
    } else |err| try testing.expectEqual(error.InvalidResponse, err);
    inline for (.{ decodeMetricInfo, decodeMetricPage, decodeResourceType, decodeResourceTypePage, decodeSeriesPage, decodeAlert, decodeAlertPage }) |decode| {
        if (decode(a, s, input)) |_| {} else |err| try testing.expectEqual(error.InvalidResponse, err);
    }
}

test "fuzz decoders: any body decodes or is InvalidResponse, never a crash or a leak" {
    try @import("test_util.zig").fuzzBytes({}, decodersProperty, .{ .corpus = &.{
        production.descriptor_get,
        production.resource_generic_task,
        production.write_mixed,
        production.write_too_frequent,
        production.write_201_series,
        production.read_full,
        production.read_aligned,
        "{\"metricDescriptors\":[{\"type\":\"t\"}],\"nextPageToken\":\"x\"}",
        production.alerts_list,
        "{\"alerts\":[{\"name\":\"projects/p/alerts/9\",\"state\":\"OPEN\",\"openTime\":\"2026-10-19T14:02:11.311Z\",\"policy\":{\"severity\":\"WARNING\",\"userLabels\":{\"team\":\"ingest\"}},\"metadata\":{\"systemLabels\":{\"spot\":false,\"groups\":[\"a\"]}}}],\"totalSize\":7}",
        "{\"error\":{\"details\":[{\"@type\":\"type.googleapis.com/google.monitoring.v3.CreateTimeSeriesSummary\",\"totalPointCount\":\"x\"}]}}",
        "{\"error\":{\"details\":[{\"@type\":\"type.googleapis.com/google.monitoring.v3.CreateTimeSeriesSummary\",\"totalPointCount\":\"3\",\"errors\":[{\"status\":{\"code\":9},\"pointCount\":3}]}]}}",
    } });
}

test "decodeAlert: every field as the discovery document shapes them" {
    var out: std.heap.ArenaAllocator = .init(testing.allocator);
    defer out.deinit();
    var scratch: std.heap.ArenaAllocator = .init(testing.allocator);
    defer scratch.deinit();
    const alert = try decodeAlert(out.allocator(), scratch.allocator(),
        \\{"name":"projects/my-project/alerts/12861813965583532163","state":"OPEN",
        \\ "openTime":"2026-10-19T14:02:11.311Z",
        \\ "policy":{"name":"projects/my-project/alertPolicies/5308","displayName":"Backlog too deep","severity":"WARNING","userLabels":{"team":"ingest"}},
        \\ "metric":{"type":"pubsub.googleapis.com/subscription/num_undelivered_messages","labels":{"delivery_type":"pull"}},
        \\ "resource":{"type":"pubsub_subscription","labels":{"project_id":"my-project","subscription_id":"orders"}},
        \\ "metadata":{"userLabels":{"env":"prod"},"systemLabels":{"name":"inst","spot_instance":false,"security_group":["a","b"]}},
        \\ "log":{"extractedLabels":{"path":"/checkout"}},
        \\ "unknownField":1}
    );
    try testing.expectEqualStrings("12861813965583532163", alert.id);
    try testing.expectEqual(types.AlertState.open, alert.state);
    try testing.expectEqual(null, alert.close_time);
    try testing.expect(alert.open_time.nanoseconds > 0);
    try testing.expectEqualStrings("Backlog too deep", alert.policy.display_name);
    try testing.expectEqual(types.Severity.warning, alert.policy.severity);
    try testing.expectEqualStrings("ingest", alert.policy.userLabel("team").?);
    try testing.expectEqualStrings("pubsub.googleapis.com/subscription/num_undelivered_messages", alert.metric_type);
    try testing.expectEqualStrings("pull", alert.metricLabel("delivery_type").?);
    try testing.expectEqualStrings("pubsub_subscription", alert.resource_type);
    try testing.expectEqualStrings("orders", alert.resourceLabel("subscription_id").?);
    try testing.expectEqualStrings("prod", alert.metadata_user_labels[0].value);
    try testing.expectEqualStrings("inst", alert.system_labels.object.get("name").?.string);
    try testing.expectEqual(false, alert.system_labels.object.get("spot_instance").?.bool);
    try testing.expectEqual(2, alert.system_labels.object.get("security_group").?.array.items.len);
    try testing.expectEqualStrings("/checkout", alert.log_labels[0].value);

    // A closed alert keeps its close time; unknown enum values decode.
    const closed = try decodeAlert(out.allocator(), scratch.allocator(),
        \\{"name":"projects/p/alerts/9","state":"CLOSED","openTime":"2026-10-19T14:02:11Z","closeTime":"2026-10-19T15:00:00Z","policy":{"severity":"FATAL"}}
    );
    try testing.expectEqual(types.AlertState.closed, closed.state);
    try testing.expect(closed.close_time != null);
    try testing.expectEqual(types.Severity.unknown, closed.policy.severity);
    const strange = try decodeAlert(out.allocator(), scratch.allocator(),
        \\{"name":"9","state":"SNOOZED","openTime":"2026-10-19T14:02:11Z"}
    );
    try testing.expectEqual(types.AlertState.unknown, strange.state);
    try testing.expectEqualStrings("9", strange.id);
    // No policy in the answer: the snapshot stays at its defaults.
    try testing.expectEqual(types.Severity.unspecified, strange.policy.severity);
    try testing.expectEqual(0, strange.policy.user_labels.len);
}

test "decodeAlert and decodeAlertPage: production's own bodies, open and closed" {
    var out: std.heap.ArenaAllocator = .init(testing.allocator);
    defer out.deinit();
    var scratch: std.heap.ArenaAllocator = .init(testing.allocator);
    defer scratch.deinit();
    const open = try decodeAlert(out.allocator(), scratch.allocator(), production.alert_open);
    try testing.expectEqualStrings("0.oe0ehmpm95z2", open.id);
    try testing.expectEqual(types.AlertState.open, open.state);
    try testing.expectEqual(null, open.close_time);
    try testing.expectEqual(types.Severity.warning, open.policy.severity);
    try testing.expectEqualStrings("zigps-alerts-0ea66e", open.policy.display_name);
    try testing.expectEqualStrings("zigps", open.policy.userLabel("team").?);
    try testing.expectEqualStrings("global", open.resource_type);
    try testing.expectEqualStrings("extractctl", open.resourceLabel("project_id").?);
    try testing.expectEqual(0, open.metric_labels.len);
    const closed = try decodeAlert(out.allocator(), scratch.allocator(), production.alert_closed);
    try testing.expectEqual(types.AlertState.closed, closed.state);
    try testing.expect(closed.close_time.?.nanoseconds > closed.open_time.nanoseconds);
    try testing.expectEqualStrings(closed.metric_type, open.metric_type);
    const page = try decodeAlertPage(out.allocator(), scratch.allocator(), production.alerts_list);
    try testing.expectEqual(1, page.alerts.len);
    try testing.expectEqual(1, page.total_size.?);
    try testing.expectEqual(null, page.next_page_token);
}

test "decodeAlertPage: pages, totals, and what neither decoder takes" {
    var out: std.heap.ArenaAllocator = .init(testing.allocator);
    defer out.deinit();
    var scratch: std.heap.ArenaAllocator = .init(testing.allocator);
    defer scratch.deinit();
    const a = out.allocator();
    const s = scratch.allocator();
    const page = try decodeAlertPage(a, s,
        \\{"alerts":[{"name":"projects/p/alerts/1","state":"OPEN","openTime":"2026-10-19T14:02:11Z","policy":{"displayName":"d"}}],"nextPageToken":"n","totalSize":7}
    );
    try testing.expectEqual(1, page.alerts.len);
    try testing.expectEqualStrings("n", page.next_page_token.?);
    try testing.expectEqual(7, page.total_size.?);
    // A policy without a severity is the proto's default, not unknown.
    try testing.expectEqual(types.Severity.unspecified, page.alerts[0].policy.severity);
    try testing.expectEqualStrings("d", page.alerts[0].policy.display_name);
    const empty = try decodeAlertPage(a, s, "{}");
    try testing.expectEqual(0, empty.alerts.len);
    try testing.expectEqual(null, empty.next_page_token);
    try testing.expectEqual(null, empty.total_size);

    // Without a name or an open time there is no alert to hold.
    for ([_][]const u8{
        "[]",
        "{\"alerts\":1}",
        "{\"alerts\":[{\"state\":\"OPEN\",\"openTime\":\"2026-10-19T14:02:11Z\"}]}",
        "{\"alerts\":[{\"name\":\"projects/p/alerts/1\"}]}",
        "{\"alerts\":[{\"name\":\"projects/p/alerts/1\",\"openTime\":\"yesterday\"}]}",
        "{\"alerts\":[{\"name\":\"projects/p/alerts/1\",\"openTime\":\"2026-10-19T14:02:11Z\",\"policy\":1}]}",
        "{\"alerts\":[{\"name\":\"projects/p/alerts/1\",\"openTime\":\"2026-10-19T14:02:11Z\",\"policy\":{\"userLabels\":{\"k\":1}}}]}",
    }) |body| {
        try testing.expectError(error.InvalidResponse, decodeAlertPage(a, s, body));
    }
}

test "decodeSeriesPage: production's reads, points newest first, project_id among the resource labels" {
    var out: std.heap.ArenaAllocator = .init(testing.allocator);
    defer out.deinit();
    var scratch: std.heap.ArenaAllocator = .init(testing.allocator);
    defer scratch.deinit();
    const a = out.allocator();
    const s = scratch.allocator();

    const full = try decodeSeriesPage(a, s, production.read_full);
    try testing.expectEqual(1, full.series.len);
    const one = full.series[0];
    try testing.expectEqualStrings("custom.googleapis.com/zigps-m0-62b2c8/gauge", one.metric_type);
    try testing.expectEqualStrings("mix1", one.label("k").?);
    try testing.expectEqualStrings("generic_task", one.resource_type);
    try testing.expectEqualStrings("extractctl", one.resourceLabel("project_id").?);
    try testing.expectEqual(types.Kind.gauge, one.kind);
    try testing.expectEqual(types.ValueType.int64, one.value_type);
    try testing.expectEqual(2, one.points.len);
    try testing.expectEqual(2, one.points[0].value.?.int64);
    try testing.expectEqual(1, one.points[1].value.?.int64);
    try testing.expect(one.points[0].end.nanoseconds > one.points[1].end.nanoseconds);
    // A gauge's start comes back as its end.
    try testing.expectEqual(one.points[0].end.nanoseconds, one.points[0].start.?.nanoseconds);
    try testing.expectEqualStrings("1", full.unit);
    try testing.expectEqual(null, full.next_page_token);
    try testing.expect(!full.incomplete());

    // A series spans pages: the same series on each, a point at a time.
    const p1 = try decodeSeriesPage(a, s, production.read_page_1);
    const p2 = try decodeSeriesPage(a, s, production.read_page_2);
    try testing.expectEqual(1, p1.series[0].points.len);
    try testing.expect(p1.next_page_token != null);
    try testing.expectEqual(1, p2.series[0].points.len);
    try testing.expectEqual(null, p2.next_page_token);
    try testing.expectEqual(2, p1.series[0].points[0].value.?.int64);
    try testing.expectEqual(1, p2.series[0].points[0].value.?.int64);

    const headers = try decodeSeriesPage(a, s, production.read_headers);
    try testing.expectEqual(0, headers.series[0].points.len);
    try testing.expectEqualStrings("", headers.series[0].resourceLabel("namespace").?);

    const aligned = try decodeSeriesPage(a, s, production.read_aligned);
    try testing.expectEqual(0, aligned.series[0].metric_labels.len);
    try testing.expectEqual(71, aligned.series[0].points[0].value.?.int64);

    const escaped = try decodeSeriesPage(a, s, production.read_escaped);
    try testing.expectEqualStrings("a\"b\\c", escaped.series[0].label("k").?);
}

test "decodeSeriesPage: every value type, incomplete answers, and what it refuses" {
    var out: std.heap.ArenaAllocator = .init(testing.allocator);
    defer out.deinit();
    var scratch: std.heap.ArenaAllocator = .init(testing.allocator);
    defer scratch.deinit();
    const a = out.allocator();
    const s = scratch.allocator();
    const page = try decodeSeriesPage(a, s,
        \\{"timeSeries":[{"metric":{"type":"m"},"resource":{"type":"global"},"metricKind":"CUMULATIVE","valueType":"DISTRIBUTION","unit":"ms","points":[
        \\ {"interval":{"startTime":"2026-10-18T13:00:00Z","endTime":"2026-10-18T13:01:00Z"},"value":{"distributionValue":{"count":"3","mean":2,"sumOfSquaredDeviation":0.5,"bucketOptions":{"explicitBuckets":{"bounds":[1,"Infinity"]}},"bucketCounts":["0","3"]}}},
        \\ {"interval":{"endTime":"2026-10-18T13:00:30Z"},"value":{"distributionValue":{"count":1,"bucketOptions":{"linearBuckets":{"numFiniteBuckets":2,"width":1.5}}}}},
        \\ {"interval":{"endTime":"2026-10-18T13:00:20Z"},"value":{"distributionValue":{"bucketOptions":{"exponentialBuckets":{"numFiniteBuckets":3,"growthFactor":2,"scale":0.5}},"mean":null}}},
        \\ {"interval":{"endTime":"2026-10-18T13:00:10Z"},"value":{"distributionValue":{}}},
        \\ {"interval":{"endTime":"2026-10-18T13:00:09Z"},"value":{"boolValue":true}},
        \\ {"interval":{"endTime":"2026-10-18T13:00:08Z"},"value":{"int64Value":-7}},
        \\ {"interval":{"endTime":"2026-10-18T13:00:07Z"},"value":{"doubleValue":"-Infinity"}},
        \\ {"interval":{"endTime":"2026-10-18T13:00:06Z"},"value":{"doubleValue":1e-7}},
        \\ {"interval":{"endTime":"2026-10-18T13:00:05Z"},"value":{"stringValue":"s"}},
        \\ {"interval":{"endTime":"2026-10-18T13:00:04Z"},"value":{"moneyValue":{"currencyCode":"USD"}}}
        \\]}],"executionErrors":[{"code":14,"message":"region down"},{}],"unreachable":["asia-east1"],"nextPageToken":"n"}
    );
    const p = page.series[0].points;
    try testing.expectEqualStrings("ms", page.series[0].unit);
    try testing.expectEqual(3, p[0].value.?.distribution.count);
    try testing.expect(std.math.isInf(p[0].value.?.distribution.buckets.explicit[1]));
    try testing.expectEqual(1.5, p[1].value.?.distribution.buckets.linear.width);
    try testing.expectEqual(0, p[1].value.?.distribution.buckets.linear.offset);
    try testing.expectEqual(2, p[2].value.?.distribution.buckets.exponential.growth_factor);
    try testing.expectEqual(0, p[3].value.?.distribution.buckets.explicit.len);
    try testing.expect(p[4].value.?.bool);
    try testing.expectEqual(-7, p[5].value.?.int64);
    try testing.expect(std.math.isNegativeInf(p[6].value.?.double));
    try testing.expectEqual(1e-7, p[7].value.?.double);
    try testing.expectEqualStrings("s", p[8].value.?.string);
    try testing.expectEqual(null, p[9].value);
    try testing.expectEqual(null, p[9].start);
    try testing.expect(page.incomplete());
    try testing.expectEqual(error.Unavailable, page.execution_errors[0].reason);
    try testing.expectEqualStrings("region down", page.execution_errors[0].message);
    try testing.expectEqual(error.Unknown, page.execution_errors[1].reason);
    try testing.expectEqualStrings("asia-east1", page.unreachable_regions[0]);

    for ([_][]const u8{
        "[]",
        "{\"timeSeries\":{}}",
        "{\"timeSeries\":[{\"resource\":{\"type\":\"g\"}}]}",
        "{\"timeSeries\":[{\"metric\":{\"type\":\"m\"}}]}",
        "{\"timeSeries\":[{\"metric\":{},\"resource\":{\"type\":\"g\"}}]}",
        "{\"timeSeries\":[{\"metric\":{\"type\":\"m\",\"labels\":{\"k\":1}},\"resource\":{\"type\":\"g\"}}]}",
        "{\"timeSeries\":[{\"metric\":{\"type\":\"m\"},\"resource\":{\"type\":\"g\"},\"points\":[{\"value\":{}}]}]}",
        "{\"timeSeries\":[{\"metric\":{\"type\":\"m\"},\"resource\":{\"type\":\"g\"},\"points\":[{\"interval\":{}}]}]}",
        "{\"timeSeries\":[{\"metric\":{\"type\":\"m\"},\"resource\":{\"type\":\"g\"},\"points\":[{\"interval\":{\"endTime\":\"x\"},\"value\":{}}]}]}",
        "{\"timeSeries\":[{\"metric\":{\"type\":\"m\"},\"resource\":{\"type\":\"g\"},\"points\":[{\"interval\":{\"endTime\":\"2026-10-18T13:00:04Z\"},\"value\":{\"boolValue\":1}}]}]}",
        "{\"timeSeries\":[{\"metric\":{\"type\":\"m\"},\"resource\":{\"type\":\"g\"},\"points\":[{\"interval\":{\"endTime\":\"2026-10-18T13:00:04Z\"},\"value\":{\"doubleValue\":\"inf\"}}]}]}",
        "{\"timeSeries\":[{\"metric\":{\"type\":\"m\"},\"resource\":{\"type\":\"g\"},\"points\":[{\"interval\":{\"endTime\":\"2026-10-18T13:00:04Z\"},\"value\":{\"doubleValue\":true}}]}]}",
        "{\"timeSeries\":[{\"metric\":{\"type\":\"m\"},\"resource\":{\"type\":\"g\"},\"points\":[{\"interval\":{\"endTime\":\"2026-10-18T13:00:04Z\"},\"value\":{\"distributionValue\":{\"bucketOptions\":{}}}}]}]}",
        "{\"timeSeries\":[{\"metric\":{\"type\":\"m\"},\"resource\":{\"type\":\"g\"},\"points\":[{\"interval\":{\"endTime\":\"2026-10-18T13:00:04Z\"},\"value\":{\"distributionValue\":{\"bucketOptions\":{\"explicitBuckets\":{}}}}}]}]}",
        "{\"timeSeries\":[{\"metric\":{\"type\":\"m\"},\"resource\":{\"type\":\"g\"},\"points\":[{\"interval\":{\"endTime\":\"2026-10-18T13:00:04Z\"},\"value\":{\"distributionValue\":{\"bucketCounts\":[true]}}}]}]}",
        "{\"timeSeries\":[{\"metric\":{\"type\":\"m\"},\"resource\":{\"type\":\"g\"},\"points\":[{\"interval\":{\"endTime\":\"2026-10-18T13:00:04Z\"},\"value\":{\"distributionValue\":{\"bucketCounts\":[\"-1\"]}}}]}]}",
        "{\"executionErrors\":[1]}",
        "{\"unreachable\":[1]}",
    }) |bad| try testing.expectError(error.InvalidResponse, decodeSeriesPage(a, s, bad));
}
