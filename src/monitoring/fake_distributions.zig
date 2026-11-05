//! Distributions merged and their percentiles, as Cloud Monitoring
//! computed them for `pubsub.googleapis.com/topic/message_sizes` on
//! 2026-11-05 (issue #315): `FakeMonitoring`'s aligners and reducers on a
//! DELTA distribution. Every form here gave milestone 0's 154 values to
//! the last bit, where the nearest other forms did not (below). Over
//! busier minutes production's merged means and squared deviations
//! moved in the last place or two with the period asked for, even of a
//! period holding one minute (up to 7.6e-16 of the value in the replay
//! of 2026-11-05): it merges what it holds under each minute's point,
//! which a test does not have. Counts, bucket counts and percentiles
//! were exact there too.

const std = @import("std");
const Allocator = std.mem.Allocator;
const types = @import("types.zig");
const Distribution = types.Distribution;

pub const Error = error{
    /// Members of one merge with different buckets: production was not
    /// asked about one.
    MixedLayouts,
    /// A percentile of linear or explicit buckets, or one whose rank falls
    /// in the underflow or overflow bucket: production was measured on
    /// exponential buckets' finite ones only.
    UnmodelledPercentile,
};

/// Whether two layouts are the same buckets.
pub fn sameLayout(a: Distribution.Buckets, b: Distribution.Buckets) bool {
    return switch (a) {
        .linear => |x| b == .linear and x.num_finite == b.linear.num_finite and x.width == b.linear.width and x.offset == b.linear.offset,
        .exponential => |x| b == .exponential and x.num_finite == b.exponential.num_finite and x.growth_factor == b.exponential.growth_factor and x.scale == b.exponential.scale,
        .explicit => |x| b == .explicit and std.mem.eql(f64, x, b.explicit),
    };
}

/// `values`, every one a distribution and at least one, merged: the
/// counts summed, the mean `sum(n_i * mean_i) / n`, the squared deviations
/// `sum(ssd_i + n_i * (mean_i - mean)^2)`, the bucket counts summed. A
/// running update, `mean + delta * n_b / n`, was off in the last place
/// twice. One member with values is kept as it is; none, the empty
/// distribution in the first one's buckets.
pub fn merge(arena: Allocator, values: []const types.Value) (Allocator.Error || Error)!Distribution {
    const layout = values[0].distribution.buckets;
    var n: u64 = 0;
    var live: usize = 0;
    var only: Distribution = .{ .buckets = layout };
    var width: usize = 0;
    for (values) |v| {
        const d = v.distribution;
        if (!sameLayout(d.buckets, layout)) return error.MixedLayouts;
        if (d.count == 0) continue;
        n += d.count;
        live += 1;
        only = d;
        width = @max(width, d.bucket_counts.len);
    }
    if (live <= 1) return only;
    var total: f64 = 0;
    for (values) |v| if (v.distribution.count != 0) {
        total += asF64(v.distribution.count) * v.distribution.mean;
    };
    const merged_mean = total / asF64(n);
    var ssd: f64 = 0;
    const counts = try arena.alloc(u64, width);
    @memset(counts, 0);
    for (values) |v| if (v.distribution.count != 0) {
        const d = v.distribution;
        const off = d.mean - merged_mean;
        ssd += d.sum_of_squared_deviation + asF64(d.count) * (off * off);
        for (d.bucket_counts, 0..) |c, i| counts[i] += c;
    };
    return .{ .count = n, .mean = merged_mean, .sum_of_squared_deviation = ssd, .buckets = layout, .bucket_counts = counts };
}

/// The mean of `d`, null for an empty one.
pub fn mean(d: Distribution) ?f64 {
    return if (d.count == 0) null else d.mean;
}

/// The population standard deviation of `d`, `sqrt(ssd / count)`, null
/// for an empty one: 0 for one value, as production gave.
pub fn stddev(d: Distribution) ?f64 {
    if (d.count == 0) return null;
    return @sqrt(d.sum_of_squared_deviation / asF64(d.count));
}

/// The `p`th percentile of `d` (99, 95, 50 or 5), null for an empty one:
/// the rank `p * count / 100` (`0.95 * count` was off in the last place
/// twice), the first bucket whose running count reaches it, and there its
/// bounds interpolated, `lo + (hi - lo) * ((rank - below) / in_bucket)`.
/// A rank on a bucket's top is that bucket's upper bound, as production
/// gave 1.2^22 for one value in bucket 22.
pub fn percentile(d: Distribution, p: u8) Error!?f64 {
    if (d.count == 0) return null;
    const e = switch (d.buckets) {
        .exponential => |e| e,
        else => return error.UnmodelledPercentile,
    };
    const rank = asF64(@as(u128, p) * d.count) / 100;
    var below: u64 = 0;
    for (d.bucket_counts, 0..) |c, i| {
        if (c != 0 and asF64(below + c) >= rank) {
            if (i == 0 or i > e.num_finite) return error.UnmodelledPercentile;
            const lo = e.scale * power(e.growth_factor, @intCast(i - 1));
            const hi = e.scale * power(e.growth_factor, @intCast(i));
            return lo + (hi - lo) * ((rank - asF64(below)) / asF64(c));
        }
        below += c;
    }
    // Counts short of the count: `put` and writes refuse those.
    return error.UnmodelledPercentile;
}

/// `growth^i` rounded once to f64: squared in f128, so it is the correctly
/// rounded power, which is what libm's `pow` gave for 1.2^0 to 1.2^123
/// and what production's bounds were. `std.math.pow` was off in the last
/// places for 120 of those 124.
fn power(growth: f64, i: u32) f64 {
    var result: f128 = 1;
    var base: f128 = growth;
    var e = i;
    while (e != 0) : (e >>= 1) {
        if (e & 1 != 0) result *= base;
        base *= base;
    }
    return @floatCast(result);
}

fn asF64(n: anytype) f64 {
    return @floatFromInt(n);
}

const testing = std.testing;

/// Pub/Sub's message sizes' buckets.
const sizes: Distribution.Buckets = .{ .exponential = .{ .num_finite = 122, .growth_factor = 1.2, .scale = 1 } };

fn at(comptime index: usize, n: u64) [index + 1]u64 {
    var counts: [index + 1]u64 = @splat(0);
    counts[index] = n;
    return counts;
}

test "merge: production's two topics in one minute, to the last bit" {
    // Minute 1 of milestone 0: 111 bytes on -a, five of 303 on -b.
    const a_counts = at(26, 1);
    const b_counts = at(32, 5);
    const values = [_]types.Value{
        .{ .distribution = .{ .count = 1, .mean = 111, .buckets = sizes, .bucket_counts = &a_counts } },
        .{ .distribution = .{ .count = 5, .mean = 303, .buckets = sizes, .bucket_counts = &b_counts } },
    };
    const m = try merge(testing.allocator, &values);
    defer testing.allocator.free(m.bucket_counts);
    try testing.expectEqual(6, m.count);
    try testing.expectEqual(271.0, m.mean);
    try testing.expectEqual(30720.0, m.sum_of_squared_deviation);
    try testing.expectEqual(33, m.bucket_counts.len);
    try testing.expectEqual(1, m.bucket_counts[26]);
    try testing.expectEqual(5, m.bucket_counts[32]);
    // Its 99th percentile, as REDUCE_PERCENTILE_99 gave it.
    try testing.expectEqual(341.1382480879248, (try percentile(m, 99)).?);
    try testing.expectEqual(71.55417527999327, stddev(m).?);
}

test "merge: the mean summed then divided, which the running update is not" {
    // Run d75912's -a, 21:14 to 21:16: three values then twenty.
    var three: [65]u64 = @splat(0);
    three[14] = 1;
    three[38] = 1;
    three[64] = 1;
    const twenty = at(38, 20);
    const values = [_]types.Value{
        .{ .distribution = .{ .count = 3, .mean = 33673, .sum_of_squared_deviation = 6600193382, .buckets = sizes, .bucket_counts = &three } },
        .{ .distribution = .{ .count = 20, .mean = 527.9, .sum_of_squared_deviation = 1664301.7999999998, .buckets = sizes, .bucket_counts = &twenty } },
    };
    const m = try merge(testing.allocator, &values);
    defer testing.allocator.free(m.bucket_counts);
    try testing.expectEqual(4851.173913043478, m.mean);
    try testing.expectEqual(9467764607.304348, m.sum_of_squared_deviation);
}

test "merge: empty members, one with values kept as it is, none" {
    const counts = at(7, 1);
    const one: Distribution = .{ .count = 1, .mean = 3, .buckets = sizes, .bucket_counts = &counts };
    const empty: Distribution = .{ .buckets = sizes };
    const kept = try merge(testing.allocator, &.{ .{ .distribution = empty }, .{ .distribution = one }, .{ .distribution = empty } });
    try testing.expectEqual(one.count, kept.count);
    try testing.expectEqual(one.bucket_counts.ptr, kept.bucket_counts.ptr);
    const none = try merge(testing.allocator, &.{ .{ .distribution = empty }, .{ .distribution = empty } });
    try testing.expectEqual(0, none.count);
    try testing.expectEqual(0, none.bucket_counts.len);
    try testing.expect(sameLayout(none.buckets, sizes));
    try testing.expectEqual(null, mean(none));
    try testing.expectEqual(null, stddev(none));
    try testing.expectEqual(null, try percentile(none, 50));
    try testing.expectEqual(0.0, stddev(one).?);
}

test "merge: different buckets refused" {
    const values = [_]types.Value{
        .{ .distribution = .{ .buckets = sizes } },
        .{ .distribution = .{ .buckets = .{ .exponential = .{ .num_finite = 122, .growth_factor = 1.2, .scale = 2 } } } },
    };
    try testing.expectError(error.MixedLayouts, merge(testing.allocator, &values));
    const explicit_a: Distribution.Buckets = .{ .explicit = &.{ 1, 2 } };
    try testing.expect(sameLayout(explicit_a, .{ .explicit = &.{ 1, 2 } }));
    try testing.expect(!sameLayout(explicit_a, .{ .explicit = &.{ 1, 3 } }));
    try testing.expect(!sameLayout(explicit_a, sizes));
    const linear: Distribution.Buckets = .{ .linear = .{ .num_finite = 2, .width = 1, .offset = 0 } };
    try testing.expect(sameLayout(linear, linear));
    try testing.expect(!sameLayout(linear, .{ .linear = .{ .num_finite = 2, .width = 1, .offset = 1 } }));
    try testing.expect(!sameLayout(sizes, .{ .exponential = .{ .num_finite = 121, .growth_factor = 1.2, .scale = 1 } }));
    try testing.expect(!sameLayout(sizes, .{ .exponential = .{ .num_finite = 122, .growth_factor = 1.25, .scale = 1 } }));
}

test "percentile: one value, production's four, and a rank on a bucket's top" {
    // 102 bytes alone, in bucket 26: [1.2^25, 1.2^26).
    const counts = at(26, 1);
    const d: Distribution = .{ .count = 1, .mean = 102, .buckets = sizes, .bucket_counts = &counts };
    try testing.expectEqual(114.28466753959457, (try percentile(d, 99)).?);
    try testing.expectEqual(113.52149780644201, (try percentile(d, 95)).?);
    try testing.expectEqual(104.93583830847581, (try percentile(d, 50)).?);
    try testing.expectEqual(96.35017881050962, (try percentile(d, 5)).?);
    // Twenty values, the first alone in bucket 22: the 5th percentile's
    // rank, 1, is that bucket's top, 1.2^22.
    var twenty: [39]u64 = @splat(0);
    for ([_]usize{ 22, 26, 28, 30, 31, 32, 34 }) |i| twenty[i] = 1;
    twenty[33] = 2;
    twenty[35] = 2;
    twenty[36] = 3;
    twenty[37] = 2;
    twenty[38] = 4;
    const many: Distribution = .{ .count = 20, .mean = 527.9, .buckets = sizes, .bucket_counts = &twenty };
    try testing.expectEqual(55.2061438912436, (try percentile(many, 5)).?);
    try testing.expectEqual(541.4458767247222, (try percentile(many, 50)).?);
    try testing.expectEqual(978.1465874794254, (try percentile(many, 95)).?);
    try testing.expectEqual(1012.1690774787098, (try percentile(many, 99)).?);
}

test "percentile: the two ranks 0.95 * n gets wrong in the last place" {
    // -a's 21:14 minute (12, 1003, 100004 bytes): 95 * 3 / 100 is 2.85,
    // and 0.95 * 3 is 2.8499999999999996.
    var three: [65]u64 = @splat(0);
    three[14] = 1;
    three[38] = 1;
    three[64] = 1;
    const d: Distribution = .{ .count = 3, .mean = 33673, .buckets = sizes, .bucket_counts = &three };
    try testing.expectEqual(113921.15061865821, (try percentile(d, 95)).?);
}

test "percentile: what production was not measured on" {
    const linear: Distribution = .{ .count = 1, .buckets = .{ .linear = .{ .num_finite = 2, .width = 1, .offset = 0 } }, .bucket_counts = &.{ 0, 1 } };
    try testing.expectError(error.UnmodelledPercentile, percentile(linear, 50));
    const explicit: Distribution = .{ .count = 1, .buckets = .{ .explicit = &.{ 1, 2 } }, .bucket_counts = &.{ 0, 1 } };
    try testing.expectError(error.UnmodelledPercentile, percentile(explicit, 50));
    const under: Distribution = .{ .count = 1, .buckets = sizes, .bucket_counts = &.{1} };
    try testing.expectError(error.UnmodelledPercentile, percentile(under, 50));
    const over = at(123, 1);
    try testing.expectError(error.UnmodelledPercentile, percentile(.{ .count = 1, .buckets = sizes, .bucket_counts = &over }, 50));
    // One value in the last finite bucket is modelled.
    const last = at(122, 1);
    try testing.expect((try percentile(.{ .count = 1, .buckets = sizes, .bucket_counts = &last }, 50)) != null);
    // Counts short of the count.
    const short = at(5, 1);
    try testing.expectError(error.UnmodelledPercentile, percentile(.{ .count = 2, .buckets = sizes, .bucket_counts = &short }, 99));
    // The underflow bucket's values below a rank that falls past them.
    var low: [3]u64 = .{ 1, 0, 3 };
    try testing.expect((try percentile(.{ .count = 4, .buckets = sizes, .bucket_counts = &low }, 50)) != null);
    try testing.expectError(error.UnmodelledPercentile, percentile(.{ .count = 4, .buckets = sizes, .bucket_counts = &low }, 5));
}

test "power: correctly rounded, where std.math.pow is not" {
    // libm's 1.2^120 and 1.2^122, bit for bit.
    try testing.expectEqual(@as(u64, 0x41e7a7e9a8b8f868), @as(u64, @bitCast(power(1.2, 120))));
    try testing.expectEqual(@as(u64, 0x41f10841d5a3e60d), @as(u64, @bitCast(power(1.2, 122))));
    try testing.expectEqual(1.0, power(1.2, 0));
    try testing.expectEqual(1.2, power(1.2, 1));
}
