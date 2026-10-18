//! A handle on one metric type: its descriptor, created, read and deleted.
//! Making one sends nothing. It borrows the client and the type, so it must
//! not outlive either.

const Metric = @This();

const std = @import("std");

const core = @import("core");
const Client = @import("Client.zig");
const codec = @import("codec.zig");
const filter_mod = @import("filter.zig");
const names = @import("names.zig");
const rpc = @import("rpc.zig");
const types = @import("types.zig");
const validate = @import("validate.zig");
const Error = @import("errors.zig").Error;

client: *Client,
/// A whole type, such as "custom.googleapis.com/shop/orders".
type: []const u8,

/// Creates the metric's descriptor, which says its kind, value type, unit,
/// description and labels; or, when it exists with the same kind and value
/// type, answers it, as production did when measured. One with another kind
/// or value type is `error.AlreadyExists`. A first write creates a
/// descriptor too, with string labels and no description: create one first
/// for a unit, a description or labels of another type.
///
/// A descriptor just made may not read back for about 2 s: production
/// answered 404 for its first 1.4 s when measured, and once 404 again after
/// a 200. A write straight after the create was taken.
pub fn create(self: Metric, config: types.MetricConfig) Error!types.Owned(types.MetricInfo) {
    const c = self.client;
    rpc.begin(c);
    if (validate.configProblem(self.type, config)) |p| {
        if (c.diagnostics) |d| d.print("invalid descriptor: {s}", .{p.reason});
        return switch (p.err) {
            .metric_type => error.InvalidMetricType,
            .label => error.InvalidLabel,
            .point, .resource => error.InvalidOptions,
        };
    }
    var scratch: std.heap.ArenaAllocator = .init(c.gpa);
    defer scratch.deinit();
    const a = scratch.allocator();
    const path = try names.collection(a, c.project, .metric_descriptors);
    const body = try codec.encodeDescriptor(a, self.type, config);
    return fetch(c, a, .{ .method = .POST, .path = path, .body = body });
}

/// The metric's descriptor. `error.NotFound` when it has none, which a
/// descriptor created moments ago can still be.
pub fn get(self: Metric) Error!types.Owned(types.MetricInfo) {
    const c = self.client;
    rpc.begin(c);
    try self.checkType();
    var scratch: std.heap.ArenaAllocator = .init(c.gpa);
    defer scratch.deinit();
    const a = scratch.allocator();
    return fetch(c, a, .{ .method = .GET, .path = try names.metricDescriptor(a, c.project, self.type) });
}

/// Deletes the metric's descriptor, which makes its data unreadable. A
/// later write creates it again, with string labels and no unit; so can a
/// create at once, of another kind if need be. `error.NotFound` when it has
/// none.
pub fn delete(self: Metric) Error!void {
    const c = self.client;
    rpc.begin(c);
    try self.checkType();
    var scratch: std.heap.ArenaAllocator = .init(c.gpa);
    defer scratch.deinit();
    const a = scratch.allocator();
    try rpc.executeDiscard(c, .{ .method = .DELETE, .path = try names.metricDescriptor(a, c.project, self.type) });
}

/// One page of this metric's series: their points in (start, end], newest
/// first, or with `.headers` only which series there are. `filter` narrows
/// them; `aggregation` turns each series' points into one per alignment
/// period, and can reduce the series to fewer. A type with no descriptor
/// is `error.NotFound`.
///
/// A 200 can still be incomplete: check `SeriesPage.incomplete()`. With
/// `.full` a page holds at most `page_size` points, so one series can come
/// on several pages, the same series again on each. A page token lasts
/// 24 hours. Since 2025-10-02 reads are billed per series returned, after
/// a free million a month; descriptor reads are free.
///
/// Points were readable 0.2 s after their write when measured, where
/// Google says 3 to 7 s.
pub fn read(self: Metric, options: types.ReadOptions) Error!types.Owned(types.SeriesPage) {
    const c = self.client;
    rpc.begin(c);
    try self.checkType();
    if (filter_mod.problem(options.filter)) |reason| {
        if (c.diagnostics) |d| d.print("invalid filter: {s}", .{reason});
        return error.InvalidFilter;
    }
    if (options.secondary_aggregation != null and options.aggregation == null) {
        if (c.diagnostics) |d| d.print("invalid options: a secondary aggregation needs a first one", .{});
        return error.InvalidOptions;
    }
    inline for (.{ options.aggregation, options.secondary_aggregation }) |agg| if (agg) |a| if (validate.aggregationProblem(a)) |reason| {
        if (c.diagnostics) |d| d.print("invalid aggregation: {s}", .{reason});
        return error.InvalidOptions;
    };
    if (options.page_token) |t| if (!validate.isPageToken(t)) {
        if (c.diagnostics) |d| d.print("invalid page token: expected printable ASCII", .{});
        return error.InvalidName;
    };
    const end = options.end orelse std.Io.Clock.real.now(c.io);
    const start = options.start orelse end;
    if (!core.timestamp.inRange(start) or !core.timestamp.inRange(end) or start.nanoseconds > end.nanoseconds) {
        if (c.diagnostics) |d| d.print("invalid options: a read's start is at most its end, both between years 1 and 9999", .{});
        return error.InvalidOptions;
    }

    var scratch: std.heap.ArenaAllocator = .init(c.gpa);
    defer scratch.deinit();
    const a = scratch.allocator();
    var w: std.Io.Writer.Allocating = .init(a);
    names.writeCollection(&w.writer, c.project, .time_series) catch return error.OutOfMemory;
    var params: core.query.Params = .init(&w.writer);
    params.add("filter", try filter_mod.build(a, self.type, options.filter)) catch return error.OutOfMemory;
    var start_buf: [core.timestamp.max_len]u8 = undefined;
    var end_buf: [core.timestamp.max_len]u8 = undefined;
    params.add("interval.startTime", core.timestamp.format(&start_buf, start)) catch return error.OutOfMemory;
    params.add("interval.endTime", core.timestamp.format(&end_buf, end)) catch return error.OutOfMemory;
    if (options.aggregation) |agg| addAggregation(&params, "aggregation.", agg) catch return error.OutOfMemory;
    if (options.secondary_aggregation) |agg| addAggregation(&params, "secondaryAggregation.", agg) catch return error.OutOfMemory;
    if (options.view == .headers) params.add("view", "HEADERS") catch return error.OutOfMemory;
    params.addNonZero("pageSize", options.page_size) catch return error.OutOfMemory;
    params.addOptional("pageToken", options.page_token) catch return error.OutOfMemory;

    var result: types.Owned(types.SeriesPage) = try .init(c.gpa);
    errdefer result.deinit();
    const body = try rpc.execute(c, result.arena, .{ .method = .GET, .path = w.written() });
    result.value = codec.decodeSeriesPage(result.arena.allocator(), a, body) catch |err|
        return rpc.decodeFailed(c, err, "time series");
    return result;
}

/// The aggregation's fields under `prefix`, what is at its default left
/// out; one `groupByFields` per field, as the API repeats it.
fn addAggregation(params: *core.query.Params, comptime prefix: []const u8, agg: types.Aggregation) std.Io.Writer.Error!void {
    if (agg.alignment_period_s != 0) {
        var buf: [16]u8 = undefined;
        try params.add(prefix ++ "alignmentPeriod", std.fmt.bufPrint(&buf, "{d}s", .{agg.alignment_period_s}) catch unreachable);
    }
    if (agg.aligner != .none) try params.add(prefix ++ "perSeriesAligner", agg.aligner.wire());
    if (agg.reducer != .none) try params.add(prefix ++ "crossSeriesReducer", agg.reducer.wire());
    for (agg.group_by) |field| try params.add(prefix ++ "groupByFields", field);
}

fn checkType(self: Metric) Error!void {
    if (validate.metricTypeProblem(self.type)) |reason| {
        if (self.client.diagnostics) |d| d.print("invalid metric type: {s}", .{reason});
        return error.InvalidMetricType;
    }
}

fn fetch(c: *Client, scratch: std.mem.Allocator, call: rpc.Call) Error!types.Owned(types.MetricInfo) {
    var result: types.Owned(types.MetricInfo) = try .init(c.gpa);
    errdefer result.deinit();
    const body = try rpc.execute(c, result.arena, call);
    result.value = codec.decodeMetricInfo(result.arena.allocator(), scratch, body) catch |err|
        return rpc.decodeFailed(c, err, "metric descriptor");
    return result;
}

const testing = std.testing;
const test_util = @import("test_util.zig");
const production = @import("production_bodies.zig");

test "golden: a read's request, every option in the query" {
    var h: test_util.Harness = undefined;
    try h.init(&.{
        .{ .respond = .{ .body = production.read_full } },
        .{ .respond = .{ .body = "{}" } },
    }, .{});
    defer h.deinit();
    const m = h.client.metric("custom.googleapis.com/zigps-m0-62b2c8/gauge");
    var page = try m.read(.{
        .start = .{ .nanoseconds = 1_792_330_895 * std.time.ns_per_s },
        .end = .{ .nanoseconds = 1_792_331_195 * std.time.ns_per_s + 949 * std.time.ns_per_ms },
        .filter = .{ .metric_labels = &.{.{ .key = "k", .value = "a\"b\\c" }}, .resource_type = "generic_task", .resource_labels = &.{.{ .key = "job", .op = .starts_with, .value = "m" }} },
        .aggregation = .{ .alignment_period_s = 60, .aligner = .max, .reducer = .sum, .group_by = &.{ "metric.labels.k", "resource.labels.job" } },
        .secondary_aggregation = .{ .alignment_period_s = 120, .aligner = .mean },
        .view = .headers,
        .page_size = 50,
        .page_token = "tok+/",
    });
    defer page.deinit();
    try h.expectRequest(0, .GET, "https://monitoring.googleapis.com/v3/projects/my-project/timeSeries" ++
        "?filter=metric.type%20%3D%20%22custom.googleapis.com%2Fzigps-m0-62b2c8%2Fgauge%22%20AND%20metric.labels.k%20%3D%20%22a%5C%22b%5C%5Cc%22%20AND%20resource.type%20%3D%20%22generic_task%22%20AND%20resource.labels.job%20%3D%20starts_with%28%22m%22%29" ++
        "&interval.startTime=2026-10-18T13%3A41%3A35Z&interval.endTime=2026-10-18T13%3A46%3A35.949Z" ++
        "&aggregation.alignmentPeriod=60s&aggregation.perSeriesAligner=ALIGN_MAX&aggregation.crossSeriesReducer=REDUCE_SUM" ++
        "&aggregation.groupByFields=metric.labels.k&aggregation.groupByFields=resource.labels.job" ++
        "&secondaryAggregation.alignmentPeriod=120s&secondaryAggregation.perSeriesAligner=ALIGN_MEAN" ++
        "&view=HEADERS&pageSize=50&pageToken=tok%2B%2F", null);
    try testing.expectEqual(2, page.value.series[0].points.len);

    // The defaults: end now, start at the end, FULL, nothing else.
    h.clock.now_ns = 1_792_331_195 * std.time.ns_per_s;
    var plain = try m.read(.{});
    defer plain.deinit();
    try h.expectRequest(1, .GET, "https://monitoring.googleapis.com/v3/projects/my-project/timeSeries?filter=metric.type%20%3D%20%22custom.googleapis.com%2Fzigps-m0-62b2c8%2Fgauge%22&interval.startTime=2026-10-18T13%3A46%3A35Z&interval.endTime=2026-10-18T13%3A46%3A35Z", null);
    try testing.expectEqual(0, plain.value.series.len);
}

test "read refuses what it will not send" {
    var h: test_util.Harness = undefined;
    try h.init(&.{}, .{});
    defer h.deinit();
    const m = h.client.metric("custom.googleapis.com/g");
    const t: std.Io.Timestamp = .{ .nanoseconds = 1_792_331_195 * std.time.ns_per_s };
    try testing.expectError(error.InvalidFilter, m.read(.{ .filter = .{ .metric_labels = &.{.{ .key = "a.b", .value = "v" }} } }));
    try testing.expectEqualStrings("invalid filter: a label key is a letter, then letters, digits and _, at most 100 bytes", h.diag.message());
    try testing.expectError(error.InvalidOptions, m.read(.{ .aggregation = .{ .reducer = .sum } }));
    try testing.expectEqualStrings("invalid aggregation: a reducer needs an aligner other than none", h.diag.message());
    try testing.expectError(error.InvalidOptions, m.read(.{ .aggregation = .{ .aligner = .max, .alignment_period_s = 60 }, .secondary_aggregation = .{ .alignment_period_s = 9, .aligner = .max } }));
    try testing.expectError(error.InvalidOptions, m.read(.{ .secondary_aggregation = .{} }));
    try testing.expectError(error.InvalidOptions, m.read(.{ .start = .{ .nanoseconds = t.nanoseconds + 1 }, .end = t }));
    try testing.expectError(error.InvalidOptions, m.read(.{ .end = .{ .nanoseconds = core.timestamp.max.nanoseconds + 1 } }));
    try testing.expectError(error.InvalidName, m.read(.{ .end = t, .page_token = "a b" }));
    try testing.expectError(error.InvalidMetricType, h.client.metric("no-path").read(.{}));
    try h.expectRequestCount(0);
}

test "read: an answer that cannot be decoded is InvalidResponse" {
    var h: test_util.Harness = undefined;
    try h.init(&.{.{ .respond = .{ .body = "{\"timeSeries\":1}" } }}, .{});
    defer h.deinit();
    try testing.expectError(error.InvalidResponse, h.client.metric("custom.googleapis.com/g").read(.{ .end = .{ .nanoseconds = 0 } }));
    try testing.expectEqualStrings("the time series response could not be decoded", h.diag.message());
}

test "read: every allocation failure is OutOfMemory without leaks" {
    const Run = struct {
        fn read(gpa: std.mem.Allocator) !void {
            var fake: test_util.FakeTransport = .init(testing.allocator, &.{.{ .respond = .{ .body = production.read_full } }});
            defer fake.deinit();
            var tokens: test_util.FakeTokenProvider = .{};
            var clock: test_util.FakeClock = .{};
            var client = try Client.init(gpa, clock.io(), .{ .project_id = "my-project", .token_provider = tokens.provider(), .transport = fake.transport() });
            defer client.deinit();
            var page = try client.metric("custom.googleapis.com/g").read(.{
                .filter = .{ .metric_labels = &.{.{ .key = "k", .value = "v" }} },
                .aggregation = .{ .alignment_period_s = 60, .aligner = .max, .group_by = &.{"metric.labels.k"} },
            });
            page.deinit();
        }
    };
    try testing.checkAllAllocationFailures(test_util.no_grow_allocator, Run.read, .{});
}
