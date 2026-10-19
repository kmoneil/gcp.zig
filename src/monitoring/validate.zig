//! The limits and naming rules the client checks before sending, each as
//! production enforced it when measured on 2026-10-18 (milestone 0 of the
//! Monitoring spec), or as Google documents it where production was not
//! asked. A check returns the reason for people, or null; the caller names
//! the series and raises the error.

const std = @import("std");
const core = @import("core");
const types = @import("types.zig");

/// Series in one `timeSeries.create`: production refused 201.
pub const max_series_per_write = 200;
/// Production took a 512-character metric type and refused 1,024 ("more
/// than 512 characters long"); the docs say 200, which it does not hold to.
pub const max_metric_type_len = 512;
/// Production took a 100-byte label key and refused 101.
pub const max_label_key_len = 100;
/// Production took a 1,024-byte label value and refused 1,025.
pub const max_label_value_len = 1024;
/// Production refused a metric with 31 labels.
pub const max_metric_labels = 30;
/// Production refused a 1,025-byte string point.
pub const max_string_value_len = 1024;
/// Buckets in a distribution, underflow and overflow included, as Google
/// documents.
pub const max_buckets = 200;
/// The domain whose metrics are a program's own. Production refuses to
/// create a DELTA or STRING metric under it.
pub const custom_domain = "custom.googleapis.com/";

/// A project as the API names it: a project number, or a project id, which
/// is 6 to 30 lowercase letters, digits and hyphens for a new project and
/// may be older, such as the domain-scoped `example.com:my-project`.
/// Checked loosely, so the name is safe as one path segment; the server
/// decides whether it exists.
pub fn isProject(ref: []const u8) bool {
    if (ref.len == 0 or ref.len > 100) return false;
    if (!std.ascii.isLower(ref[0]) and !std.ascii.isDigit(ref[0])) return false;
    for (ref) |c| switch (c) {
        'a'...'z', '0'...'9', '-', '.', ':' => {},
        else => return false,
    };
    return true;
}

/// Why a metric type will not be sent, or null. Letters, digits and
/// `._:-`, path elements separated by `/`, each starting with a letter or a
/// digit, a domain and at least one path element, at most 512 characters.
pub fn metricTypeProblem(t: []const u8) ?[]const u8 {
    if (t.len == 0) return "a metric type is required";
    if (t.len > max_metric_type_len) return "a metric type is at most 512 characters";
    var elements: usize = 0;
    var it = std.mem.splitScalar(u8, t, '/');
    while (it.next()) |element| {
        if (element.len == 0) return "a metric type has no empty path elements";
        if (!std.ascii.isAlphanumeric(element[0])) return "each path element of a metric type starts with a letter or a digit";
        for (element) |c| switch (c) {
            'a'...'z', 'A'...'Z', '0'...'9', '.', '_', ':', '-' => {},
            else => return "a metric type holds only letters, digits and ._:-/",
        };
        elements += 1;
    }
    if (elements < 2) return "a metric type is a domain and a path, such as custom.googleapis.com/shop/orders";
    return null;
}

/// A metric type's start, for listing: the type's characters, any number of
/// them, slashes included.
pub fn prefixProblem(prefix: []const u8) ?[]const u8 {
    if (prefix.len == 0) return "a prefix is not empty; leave it null to list every metric";
    if (prefix.len > max_metric_type_len) return "a prefix is at most 512 characters";
    for (prefix) |c| switch (c) {
        'a'...'z', 'A'...'Z', '0'...'9', '.', '_', ':', '-', '/' => {},
        else => return "a prefix holds only letters, digits and ._:-/",
    };
    return null;
}

/// A label key: a letter, then letters, digits and underscores, at most
/// 100 bytes. Production refused a key starting with a digit and took upper
/// case.
pub fn isLabelKey(key: []const u8) bool {
    if (key.len == 0 or key.len > max_label_key_len) return false;
    if (!std.ascii.isAlphabetic(key[0])) return false;
    for (key) |c| if (!std.ascii.isAlphanumeric(c) and c != '_') return false;
    return true;
}

/// Why a set of labels will not be sent, or null: keys, value lengths, at
/// most `max` of them, no key twice.
pub fn labelsProblem(labels: []const types.Label, max: usize) ?[]const u8 {
    if (labels.len > max) return "more than 30 labels";
    for (labels, 0..) |l, i| {
        if (!isLabelKey(l.key)) return "a label key is a letter, then letters, digits and _, at most 100 bytes";
        if (l.value.len > max_label_value_len) return "a label value is at most 1024 bytes";
        if (!std.unicode.utf8ValidateSlice(l.value)) return "a label value is UTF-8";
        for (labels[0..i]) |earlier| if (std.mem.eql(u8, earlier.key, l.key)) return "a label key appears twice";
    }
    return null;
}

/// A resource type's name: letters, digits, `_` and `.`, at most 256.
pub fn isResourceType(name: []const u8) bool {
    if (name.len == 0 or name.len > 256) return false;
    for (name) |c| switch (c) {
        'a'...'z', 'A'...'Z', '0'...'9', '_', '.' => {},
        else => return false,
    };
    return true;
}

/// Why a resource will not be sent, or null.
pub fn resourceProblem(r: types.Resource) ?[]const u8 {
    var buf: [types.Resource.max_named_labels]types.Label = undefined;
    const labels = r.labels(&buf);
    if (r == .other) {
        if (!isResourceType(r.other.type)) return "a resource type is letters, digits, _ and ., at most 256";
        if (labelsProblem(labels, 64)) |p| return p;
    }
    for (labels) |l| {
        if (std.mem.eql(u8, l.key, "project_id")) return "a resource's project_id is the server's to fill in; leave it out";
        if (l.value.len > max_label_value_len) return "a resource label value is at most 1024 bytes";
        if (!std.unicode.utf8ValidateSlice(l.value)) return "a resource label value is UTF-8";
    }
    return null;
}

/// Why a distribution will not be sent, or null: the rules production
/// refused points for, and Google's documented ones.
pub fn distributionProblem(d: types.Distribution) ?[]const u8 {
    switch (d.buckets) {
        .linear => |l| {
            if (l.num_finite == 0) return "a linear layout has at least one finite bucket";
            if (!std.math.isFinite(l.width) or l.width <= 0) return "a linear layout's width is finite and above 0";
            if (!std.math.isFinite(l.offset)) return "a linear layout's offset is finite";
        },
        .exponential => |e| {
            if (e.num_finite == 0) return "an exponential layout has at least one finite bucket";
            if (!std.math.isFinite(e.growth_factor) or e.growth_factor <= 1) return "an exponential layout's growth factor is finite and above 1";
            if (!std.math.isFinite(e.scale) or e.scale <= 0) return "an exponential layout's scale is finite and above 0";
        },
        .explicit => |bounds| {
            if (bounds.len == 0) return "an explicit layout has at least one bound";
            for (bounds, 0..) |b, i| {
                if (!std.math.isFinite(b)) return "an explicit layout's bounds are finite";
                if (i > 0 and b <= bounds[i - 1]) return "an explicit layout's bounds strictly increase";
            }
        },
    }
    if (d.buckets.total() > max_buckets) return "a distribution has at most 200 buckets, underflow and overflow included";
    if (d.bucket_counts.len > d.buckets.total()) return "a distribution has more bucket counts than buckets";
    if (!std.math.isFinite(d.mean) or !std.math.isFinite(d.sum_of_squared_deviation)) return "a distribution's mean and sum of squared deviation are finite";
    if (d.sum_of_squared_deviation < 0) return "a distribution's sum of squared deviation is not negative";
    if (d.count == 0 and (d.mean != 0 or d.sum_of_squared_deviation != 0)) return "an empty distribution has a mean and sum of squared deviation of 0";
    if (d.bucket_counts.len > 0) {
        var sum: u64 = 0;
        for (d.bucket_counts) |c| sum = std.math.add(u64, sum, c) catch return "a distribution's bucket counts sum to its count";
        if (sum != d.count) return "a distribution's bucket counts sum to its count";
    }
    return null;
}

/// A unit: printable ASCII without spaces. The server reads the grammar.
pub fn isUnit(unit: []const u8) bool {
    for (unit) |c| if (c <= ' ' or c >= 0x7f) return false;
    return true;
}

pub const Problem = struct {
    err: Kind,
    reason: []const u8,

    pub const Kind = enum { metric_type, label, point, resource };
};

/// Why one series will not be written, or null.
pub fn seriesProblem(s: types.TimeSeries) ?Problem {
    if (metricTypeProblem(s.metric_type)) |r| return .{ .err = .metric_type, .reason = r };
    if (labelsProblem(s.metric_labels, max_metric_labels)) |r| return .{ .err = .label, .reason = r };
    if (resourceProblem(s.resource)) |r| return .{ .err = .resource, .reason = r };
    if (pointProblem(s)) |r| return .{ .err = .point, .reason = r };
    return null;
}

fn pointProblem(s: types.TimeSeries) ?[]const u8 {
    if (!isUnit(s.unit)) return "a unit is printable ASCII without spaces";
    if (!core.timestamp.inRange(s.end)) return "an end time is between years 1 and 9999";
    if (s.start) |start| if (!core.timestamp.inRange(start)) return "a start time is between years 1 and 9999";
    const custom = std.mem.startsWith(u8, s.metric_type, custom_domain);
    switch (s.kind) {
        .gauge => if (s.start) |start| {
            if (start.nanoseconds != s.end.nanoseconds) return "a gauge's start is its end: leave it null";
        },
        .delta, .cumulative => {
            if (custom and s.kind == .delta) return "custom.googleapis.com/ takes no DELTA metrics";
            const start = s.start orelse return "a cumulative or delta point needs a start";
            if (start.nanoseconds >= s.end.nanoseconds) return "a cumulative or delta point starts before it ends";
        },
        .unknown => return "a kind of gauge, delta or cumulative",
    }
    switch (s.value) {
        .string => |text| {
            if (custom) return "custom.googleapis.com/ takes no STRING metrics";
            if (text.len > max_string_value_len) return "a string point is at most 1024 bytes";
            if (!std.unicode.utf8ValidateSlice(text)) return "a string point is UTF-8";
        },
        .distribution => |d| if (distributionProblem(d)) |r| return r,
        .bool, .int64, .double => {},
    }
    return null;
}

/// Whether two series are one: the same metric type and labels, and the
/// same resource. Label order does not matter.
pub fn sameSeries(a: types.TimeSeries, b: types.TimeSeries) bool {
    if (!std.mem.eql(u8, a.metric_type, b.metric_type)) return false;
    if (!std.mem.eql(u8, a.resource.typeName(), b.resource.typeName())) return false;
    if (!sameLabels(a.metric_labels, b.metric_labels)) return false;
    var buf_a: [types.Resource.max_named_labels]types.Label = undefined;
    var buf_b: [types.Resource.max_named_labels]types.Label = undefined;
    return sameLabels(a.resource.labels(&buf_a), b.resource.labels(&buf_b));
}

fn sameLabels(a: []const types.Label, b: []const types.Label) bool {
    if (a.len != b.len) return false;
    for (a) |x| {
        const y = for (b) |l| {
            if (std.mem.eql(u8, l.key, x.key)) break l;
        } else return false;
        if (!std.mem.eql(u8, x.value, y.value)) return false;
    }
    return true;
}

/// Why a descriptor will not be created, or null.
pub fn configProblem(metric_type: []const u8, config: types.MetricConfig) ?Problem {
    if (metricTypeProblem(metric_type)) |r| return .{ .err = .metric_type, .reason = r };
    if (config.labels.len > max_metric_labels) return .{ .err = .label, .reason = "more than 30 labels" };
    for (config.labels, 0..) |l, i| {
        if (!isLabelKey(l.key)) return .{ .err = .label, .reason = "a label key is a letter, then letters, digits and _, at most 100 bytes" };
        if (l.value_type == .unknown) return .{ .err = .label, .reason = "a label's type is string, bool or int64" };
        for (config.labels[0..i]) |earlier| if (std.mem.eql(u8, earlier.key, l.key)) return .{ .err = .label, .reason = "a label key appears twice" };
    }
    if (!isUnit(config.unit)) return .{ .err = .point, .reason = "a unit is printable ASCII without spaces" };
    if (config.kind == .unknown) return .{ .err = .point, .reason = "a kind of gauge, delta or cumulative" };
    switch (config.value_type) {
        .unknown, .money => return .{ .err = .point, .reason = "a value type of bool, int64, double, string or distribution" },
        else => {},
    }
    if (std.mem.startsWith(u8, metric_type, custom_domain)) {
        if (config.kind == .delta) return .{ .err = .point, .reason = "custom.googleapis.com/ takes no DELTA metrics" };
        if (config.value_type == .string) return .{ .err = .point, .reason = "custom.googleapis.com/ takes no STRING metrics" };
    }
    return null;
}

/// Production refused an alignment period of 9 s ("must be greater than or
/// equal to 10s") and took 10 s; Google documents 60.
pub const min_alignment_period_s = 10;

/// Why an aggregation is always wrong, or null. Which aligner suits which
/// kind of metric is the server's to say.
pub fn aggregationProblem(a: types.Aggregation) ?[]const u8 {
    if (a.reducer != .none and a.aligner == .none) return "a reducer needs an aligner other than none";
    if (a.aligner != .none and a.alignment_period_s == 0) return "an aligner other than none needs an alignment period";
    if (a.alignment_period_s != 0 and a.alignment_period_s < min_alignment_period_s) return "an alignment period is at least 10 s";
    for (a.group_by) |field| {
        if (field.len == 0) return "a group-by field is not empty";
        for (field) |c| if (c <= ' ' or c >= 0x7f or c == '"') return "a group-by field is printable ASCII without spaces or quotes, such as metric.labels.region";
    }
    return null;
}

/// A page token as production writes them: printable ASCII.
pub fn isPageToken(token: []const u8) bool {
    if (token.len == 0) return false;
    for (token) |c| if (c <= ' ' or c >= 0x7f) return false;
    return true;
}

/// An alert id goes into the path as one segment: visible ASCII without
/// `/`, as the system-assigned ids are.
pub fn isAlertId(id: []const u8) bool {
    if (id.len == 0 or id.len > 256) return false;
    for (id) |c| if (c <= ' ' or c >= 0x7f or c == '/') return false;
    return true;
}

/// An alerts filter is sent as written, since production matches it
/// against the alert's fields: any text short of control characters.
pub fn isAlertFilter(filter: []const u8) bool {
    if (filter.len == 0 or filter.len > 4096) return false;
    for (filter) |c| if (c < ' ' or c == 0x7f) return false;
    return true;
}

test "alert ids and filters" {
    try @import("std").testing.expect(isAlertId("12861813965583532163"));
    try @import("std").testing.expect(!isAlertId(""));
    try @import("std").testing.expect(!isAlertId("a/b"));
    try @import("std").testing.expect(!isAlertId("a b"));
    try @import("std").testing.expect(isAlertFilter("state=\"OPEN\" or zigps"));
    try @import("std").testing.expect(!isAlertFilter(""));
    try @import("std").testing.expect(!isAlertFilter("a\nb"));
}

/// A user agent goes into a header, so it must be printable ASCII.
pub fn isUserAgent(agent: []const u8) bool {
    if (agent.len == 0) return false;
    for (agent) |c| if (c < 0x20 or c > 0x7e) return false;
    return true;
}

const testing = std.testing;
const repeat = core.testing.repeat;

test "metricTypeProblem: production's characters and length, a domain and a path" {
    for ([_][]const u8{
        "custom.googleapis.com/shop/orders",
        "custom.googleapis.com/Upper/Case",
        "workload.googleapis.com/a:b/c-d_e.f",
        "external.googleapis.com/prometheus/up",
        "custom.googleapis.com/1st",
    }) |ok| try testing.expectEqual(null, metricTypeProblem(ok));
    const domain = "custom.googleapis.com/";
    try testing.expectEqual(null, metricTypeProblem(domain ++ repeat("x", max_metric_type_len - domain.len)));
    try testing.expect(std.mem.indexOf(u8, metricTypeProblem(domain ++ repeat("x", max_metric_type_len - domain.len + 1)).?, "512") != null);
    const cases = [_]struct { []const u8, []const u8 }{
        .{ "", "required" },
        .{ "custom.googleapis.com", "a domain and a path" },
        .{ "custom.googleapis.com/", "empty" },
        .{ "custom.googleapis.com//x", "empty" },
        .{ "/x", "empty" },
        .{ "custom.googleapis.com/_x", "starts with" },
        .{ "custom.googleapis.com/.x", "starts with" },
        .{ "custom.googleapis.com/a b", "only letters" },
        .{ "custom.googleapis.com/a%2Fb", "only letters" },
        .{ "custom.googleapis.com/caf\xc3\xa9", "only letters" },
        .{ "custom.googleapis.com/a?b", "only letters" },
    };
    for (cases) |c| try testing.expect(std.mem.indexOf(u8, metricTypeProblem(c[0]).?, c[1]) != null);
}

test "prefixProblem: any start of a type" {
    try testing.expectEqual(null, prefixProblem("custom.googleapis.com/"));
    try testing.expectEqual(null, prefixProblem("custom.googleapis.com/shop/or"));
    try testing.expectEqual(null, prefixProblem("c"));
    try testing.expect(prefixProblem("") != null);
    try testing.expect(prefixProblem("a\"b") != null);
    try testing.expect(prefixProblem(repeat("a", max_metric_type_len + 1)) != null);
}

test "isLabelKey: a letter, then letters, digits and _, at most 100 bytes" {
    for ([_][]const u8{ "region", "Region", "a", "a_1", "http_status_code" }) |ok| try testing.expect(isLabelKey(ok));
    for ([_][]const u8{ "", "1k", "_k", "http.scheme", "a-b", "a b", "é" }) |bad| try testing.expect(!isLabelKey(bad));
    try testing.expect(isLabelKey(repeat("k", max_label_key_len)));
    try testing.expect(!isLabelKey(repeat("k", max_label_key_len + 1)));
}

test "labelsProblem: keys, value lengths, count, and no key twice" {
    try testing.expectEqual(null, labelsProblem(&.{ .{ .key = "a", .value = "" }, .{ .key = "b", .value = repeat("v", max_label_value_len) } }, 30));
    try testing.expect(labelsProblem(&.{.{ .key = "a", .value = repeat("v", max_label_value_len + 1) }}, 30) != null);
    try testing.expect(labelsProblem(&.{.{ .key = "1a", .value = "v" }}, 30) != null);
    try testing.expect(labelsProblem(&.{ .{ .key = "a", .value = "1" }, .{ .key = "a", .value = "2" } }, 30) != null);
    try testing.expect(labelsProblem(&.{.{ .key = "a", .value = "\xff" }}, 30) != null);
    var many: [31]types.Label = undefined;
    var names: [31][4]u8 = undefined;
    for (&many, &names, 0..) |*l, *n, i| {
        l.* = .{ .key = std.fmt.bufPrint(n, "l{d}", .{i}) catch unreachable, .value = "v" };
    }
    try testing.expectEqual(null, labelsProblem(many[0..30], 30));
    try testing.expect(std.mem.indexOf(u8, labelsProblem(&many, 30).?, "30") != null);
}

test "resourceProblem: no project_id, values at most 1024, a type for .other" {
    try testing.expectEqual(null, resourceProblem(.global));
    try testing.expectEqual(null, resourceProblem(.{ .generic_task = .{ .location = "us-central1", .namespace = "", .job = "j", .task_id = "t" } }));
    try testing.expect(resourceProblem(.{ .generic_task = .{ .location = "us-central1", .namespace = "n", .job = repeat("j", 1025), .task_id = "t" } }) != null);
    try testing.expectEqual(null, resourceProblem(.{ .other = .{ .type = "aws_ec2_instance", .labels = &.{.{ .key = "region", .value = "aws:us-east-1" }} } }));
    try testing.expect(std.mem.indexOf(u8, resourceProblem(.{ .other = .{ .type = "generic_task", .labels = &.{.{ .key = "project_id", .value = "other" }} } }).?, "project_id") != null);
    try testing.expect(resourceProblem(.{ .other = .{ .type = "a/b" } }) != null);
    try testing.expect(resourceProblem(.{ .other = .{ .type = "" } }) != null);
}

test "distributionProblem: each rule on its own" {
    const ok: types.Distribution = .{ .count = 3, .mean = 2, .sum_of_squared_deviation = 2, .buckets = .{ .explicit = &.{ 1, 2, 3 } }, .bucket_counts = &.{ 0, 1, 1, 1 } };
    try testing.expectEqual(null, distributionProblem(ok));
    // Trailing zeros left off, as production took.
    var short = ok;
    short.bucket_counts = &.{ 0, 1, 2 };
    try testing.expectEqual(null, distributionProblem(short));
    var empty: types.Distribution = .{ .buckets = .{ .linear = .{ .num_finite = 2, .width = 1, .offset = 0 } } };
    try testing.expectEqual(null, distributionProblem(empty));
    const cases = [_]struct { types.Distribution, []const u8 }{
        .{ .{ .count = 4, .buckets = ok.buckets, .bucket_counts = ok.bucket_counts, .mean = 2, .sum_of_squared_deviation = 2 }, "sum to its count" },
        .{ .{ .count = 0, .mean = 1, .buckets = ok.buckets }, "empty distribution" },
        .{ .{ .count = 0, .sum_of_squared_deviation = 1, .buckets = ok.buckets }, "empty distribution" },
        .{ .{ .count = 1, .mean = std.math.nan(f64), .buckets = ok.buckets }, "finite" },
        .{ .{ .count = 1, .sum_of_squared_deviation = -1, .buckets = ok.buckets }, "not negative" },
        .{ .{ .buckets = .{ .explicit = &.{} } }, "at least one bound" },
        .{ .{ .buckets = .{ .explicit = &.{ 1, 1 } } }, "strictly increase" },
        .{ .{ .buckets = .{ .explicit = &.{ 2, 1 } } }, "strictly increase" },
        .{ .{ .buckets = .{ .explicit = &.{std.math.inf(f64)} } }, "finite" },
        .{ .{ .buckets = .{ .linear = .{ .num_finite = 2, .width = 0, .offset = 0 } } }, "width" },
        .{ .{ .buckets = .{ .linear = .{ .num_finite = 0, .width = 1, .offset = 0 } } }, "at least one finite" },
        .{ .{ .buckets = .{ .linear = .{ .num_finite = 2, .width = 1, .offset = std.math.inf(f64) } } }, "offset" },
        .{ .{ .buckets = .{ .exponential = .{ .num_finite = 2, .growth_factor = 1, .scale = 1 } } }, "growth factor" },
        .{ .{ .buckets = .{ .exponential = .{ .num_finite = 2, .growth_factor = 2, .scale = 0 } } }, "scale" },
        .{ .{ .buckets = .{ .exponential = .{ .num_finite = 0, .growth_factor = 2, .scale = 1 } } }, "at least one finite" },
        .{ .{ .buckets = .{ .linear = .{ .num_finite = 199, .width = 1, .offset = 0 } } }, "200 buckets" },
        .{ .{ .count = 1, .buckets = .{ .explicit = &.{1} }, .bucket_counts = &.{ 0, 0, 1 } }, "more bucket counts" },
        .{ .{ .count = std.math.maxInt(u64), .buckets = .{ .explicit = &.{1} }, .bucket_counts = &.{ std.math.maxInt(u64), 1 } }, "sum to its count" },
    };
    for (cases) |c| try testing.expect(std.mem.indexOf(u8, distributionProblem(c[0]).?, c[1]) != null);
    empty.buckets = .{ .linear = .{ .num_finite = 198, .width = 1, .offset = 0 } };
    try testing.expectEqual(null, distributionProblem(empty));
}

const t0: std.Io.Timestamp = .{ .nanoseconds = 1_792_000_000 * std.time.ns_per_s };
const t1: std.Io.Timestamp = .{ .nanoseconds = 1_792_000_060 * std.time.ns_per_s };
const task: types.Resource = .{ .generic_task = .{ .location = "us-central1", .namespace = "n", .job = "j", .task_id = "t" } };

test "seriesProblem: intervals by kind, as production refused them" {
    const gauge: types.TimeSeries = .{ .metric_type = "custom.googleapis.com/g", .resource = task, .kind = .gauge, .end = t1, .value = .{ .int64 = 1 } };
    try testing.expectEqual(null, seriesProblem(gauge));
    var s = gauge;
    s.start = t1;
    try testing.expectEqual(null, seriesProblem(s));
    s.start = t0;
    try testing.expectEqual(.point, seriesProblem(s).?.err);
    s = gauge;
    s.kind = .cumulative;
    try testing.expect(std.mem.indexOf(u8, seriesProblem(s).?.reason, "needs a start") != null);
    s.start = t1;
    try testing.expect(std.mem.indexOf(u8, seriesProblem(s).?.reason, "starts before") != null);
    s.start = t0;
    try testing.expectEqual(null, seriesProblem(s));
    s.kind = .delta;
    try testing.expect(std.mem.indexOf(u8, seriesProblem(s).?.reason, "DELTA") != null);
    s.metric_type = "external.googleapis.com/x";
    try testing.expectEqual(null, seriesProblem(s));
    s.kind = .unknown;
    try testing.expectEqual(.point, seriesProblem(s).?.err);
}

test "seriesProblem: values, units, and which error each check raises" {
    const base: types.TimeSeries = .{ .metric_type = "custom.googleapis.com/g", .resource = task, .kind = .gauge, .end = t1, .value = .{ .double = std.math.nan(f64) } };
    try testing.expectEqual(null, seriesProblem(base));
    var s = base;
    s.value = .{ .string = "x" };
    try testing.expect(std.mem.indexOf(u8, seriesProblem(s).?.reason, "STRING") != null);
    s.metric_type = "external.googleapis.com/x";
    try testing.expectEqual(null, seriesProblem(s));
    s.value = .{ .string = repeat("s", max_string_value_len + 1) };
    try testing.expect(std.mem.indexOf(u8, seriesProblem(s).?.reason, "1024") != null);
    s = base;
    s.unit = "a b";
    try testing.expectEqual(.point, seriesProblem(s).?.err);
    s = base;
    s.metric_type = "x";
    try testing.expectEqual(.metric_type, seriesProblem(s).?.err);
    s = base;
    s.metric_labels = &.{.{ .key = "1", .value = "v" }};
    try testing.expectEqual(.label, seriesProblem(s).?.err);
    s = base;
    s.resource = .{ .other = .{ .type = "generic_task", .labels = &.{.{ .key = "project_id", .value = "p" }} } };
    try testing.expectEqual(.resource, seriesProblem(s).?.err);
    s = base;
    s.value = .{ .distribution = .{ .buckets = .{ .explicit = &.{} } } };
    try testing.expectEqual(.point, seriesProblem(s).?.err);
    s = base;
    s.end = .{ .nanoseconds = core.timestamp.max.nanoseconds + 1 };
    try testing.expectEqual(.point, seriesProblem(s).?.err);
}

test "sameSeries: type, labels in any order, and resource" {
    const a: types.TimeSeries = .{ .metric_type = "custom.googleapis.com/g", .metric_labels = &.{ .{ .key = "a", .value = "1" }, .{ .key = "b", .value = "2" } }, .resource = task, .kind = .gauge, .end = t1, .value = .{ .int64 = 1 } };
    var b = a;
    b.metric_labels = &.{ .{ .key = "b", .value = "2" }, .{ .key = "a", .value = "1" } };
    b.value = .{ .int64 = 2 };
    try testing.expect(sameSeries(a, b));
    b.metric_labels = &.{ .{ .key = "b", .value = "2" }, .{ .key = "a", .value = "3" } };
    try testing.expect(!sameSeries(a, b));
    b = a;
    b.metric_labels = a.metric_labels[0..1];
    try testing.expect(!sameSeries(a, b));
    b = a;
    b.resource = .{ .generic_task = .{ .location = "us-central1", .namespace = "n", .job = "j", .task_id = "u" } };
    try testing.expect(!sameSeries(a, b));
    b.resource = .global;
    try testing.expect(!sameSeries(a, b));
    b = a;
    b.metric_type = "custom.googleapis.com/h";
    try testing.expect(!sameSeries(a, b));
}

test "configProblem: what a descriptor create refuses" {
    try testing.expectEqual(null, configProblem("custom.googleapis.com/g", .{ .kind = .gauge, .value_type = .int64, .labels = &.{.{ .key = "region" }} }));
    try testing.expectEqual(.metric_type, configProblem("g", .{ .kind = .gauge, .value_type = .int64 }).?.err);
    try testing.expectEqual(.label, configProblem("custom.googleapis.com/g", .{ .kind = .gauge, .value_type = .int64, .labels = &.{.{ .key = "1" }} }).?.err);
    try testing.expectEqual(.label, configProblem("custom.googleapis.com/g", .{ .kind = .gauge, .value_type = .int64, .labels = &.{ .{ .key = "a" }, .{ .key = "a" } } }).?.err);
    try testing.expectEqual(.label, configProblem("custom.googleapis.com/g", .{ .kind = .gauge, .value_type = .int64, .labels = &.{.{ .key = "a", .value_type = .unknown }} }).?.err);
    try testing.expectEqual(.point, configProblem("custom.googleapis.com/g", .{ .kind = .delta, .value_type = .int64 }).?.err);
    try testing.expectEqual(.point, configProblem("custom.googleapis.com/g", .{ .kind = .gauge, .value_type = .string }).?.err);
    try testing.expectEqual(null, configProblem("external.googleapis.com/g", .{ .kind = .delta, .value_type = .string }));
    try testing.expectEqual(.point, configProblem("custom.googleapis.com/g", .{ .kind = .unknown, .value_type = .int64 }).?.err);
    try testing.expectEqual(.point, configProblem("custom.googleapis.com/g", .{ .kind = .gauge, .value_type = .money }).?.err);
    try testing.expectEqual(.point, configProblem("custom.googleapis.com/g", .{ .kind = .gauge, .value_type = .int64, .unit = "a b" }).?.err);
}

test "aggregationProblem: what production refused, and group-by fields" {
    try testing.expectEqual(null, aggregationProblem(.{}));
    try testing.expectEqual(null, aggregationProblem(.{ .alignment_period_s = 10, .aligner = .max, .reducer = .sum, .group_by = &.{ "metric.labels.region", "resource.labels.zone" } }));
    try testing.expect(std.mem.indexOf(u8, aggregationProblem(.{ .reducer = .sum }).?, "needs an aligner") != null);
    try testing.expect(std.mem.indexOf(u8, aggregationProblem(.{ .aligner = .max }).?, "needs an alignment period") != null);
    try testing.expect(std.mem.indexOf(u8, aggregationProblem(.{ .alignment_period_s = 9, .aligner = .max }).?, "at least 10 s") != null);
    try testing.expect(aggregationProblem(.{ .alignment_period_s = 60, .aligner = .max, .group_by = &.{""} }) != null);
    try testing.expect(aggregationProblem(.{ .alignment_period_s = 60, .aligner = .max, .group_by = &.{"a b"} }) != null);
    try testing.expect(aggregationProblem(.{ .alignment_period_s = 60, .aligner = .max, .group_by = &.{"a\"b"} }) != null);
    // A period alone, with no aligner, is the server's to judge.
    try testing.expectEqual(null, aggregationProblem(.{ .alignment_period_s = 60 }));
}

test "isProject, isResourceType, isUnit, isPageToken and isUserAgent" {
    for ([_][]const u8{ "82150720798", "extractctl", "example.com:my-project" }) |ok| try testing.expect(isProject(ok));
    for ([_][]const u8{ "", "Bad", "a/b", "-a", repeat("a", 101) }) |bad| try testing.expect(!isProject(bad));
    for ([_][]const u8{ "generic_task", "k8s_container", "aws_ec2_instance", "a.b" }) |ok| try testing.expect(isResourceType(ok));
    for ([_][]const u8{ "", "a/b", "a b", "a%41", repeat("a", 257) }) |bad| try testing.expect(!isResourceType(bad));
    for ([_][]const u8{ "", "By", "{request}", "1", "ms", "kBy/s" }) |ok| try testing.expect(isUnit(ok));
    for ([_][]const u8{ "a b", "\t", "é" }) |bad| try testing.expect(!isUnit(bad));
    try testing.expect(isPageToken("EicxMDEw="));
    try testing.expect(!isPageToken(""));
    try testing.expect(!isPageToken("a b"));
    try testing.expect(isUserAgent("zig-gcp-monitoring/0.47"));
    try testing.expect(!isUserAgent("a\r\nb"));
}

/// The metric type rule written another way: a state machine over the
/// characters, where `metricTypeProblem` splits on slashes.
fn modelMetricType(t: []const u8) bool {
    if (t.len == 0 or t.len > max_metric_type_len) return false;
    var at_element_start = true;
    var elements: usize = 0;
    for (t) |c| {
        if (c == '/') {
            if (at_element_start) return false;
            at_element_start = true;
            continue;
        }
        const ok = (c >= 'a' and c <= 'z') or (c >= 'A' and c <= 'Z') or (c >= '0' and c <= '9') or c == '.' or c == '_' or c == ':' or c == '-';
        if (!ok) return false;
        if (at_element_start) {
            const alnum = (c >= 'a' and c <= 'z') or (c >= 'A' and c <= 'Z') or (c >= '0' and c <= '9');
            if (!alnum) return false;
            elements += 1;
            at_element_start = false;
        }
    }
    return !at_element_start and elements >= 2;
}

fn namesProperty(_: void, input: []const u8) !void {
    var g: core.testing.ByteGen = .init(input);
    var buf: [600]u8 = undefined;
    const alphabet = "aZ09._:-/ %\xc3";
    const n = g.intRange(usize, 0, 40);
    for (buf[0..n]) |*c| c.* = if (g.boolean()) alphabet[g.intRange(usize, 0, alphabet.len - 1)] else g.int(u8);
    const t = buf[0..n];
    try testing.expectEqual(modelMetricType(t), metricTypeProblem(t) == null);
    // Keys: the same bytes, held to the regular expression production
    // follows.
    var model_key = n > 0 and n <= max_label_key_len and std.ascii.isAlphabetic(t[0]);
    for (t) |c| model_key = model_key and (std.ascii.isAlphanumeric(c) or c == '_');
    try testing.expectEqual(model_key, isLabelKey(t));
}

test "fuzz names: metric types and label keys checked as a plain model checks them" {
    try core.testing.fuzzBytes({}, namesProperty, .{ .corpus = &.{ "", "\x05custom.googleapis.com/a", "\x02a/" } });
}
