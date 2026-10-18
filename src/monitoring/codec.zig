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
    inline for (.{ decodeMetricInfo, decodeMetricPage, decodeResourceType, decodeResourceTypePage }) |decode| {
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
        "{\"metricDescriptors\":[{\"type\":\"t\"}],\"nextPageToken\":\"x\"}",
        "{\"error\":{\"details\":[{\"@type\":\"type.googleapis.com/google.monitoring.v3.CreateTimeSeriesSummary\",\"totalPointCount\":\"x\"}]}}",
        "{\"error\":{\"details\":[{\"@type\":\"type.googleapis.com/google.monitoring.v3.CreateTimeSeriesSummary\",\"totalPointCount\":\"3\",\"errors\":[{\"status\":{\"code\":9},\"pointCount\":3}]}]}}",
    } });
}
