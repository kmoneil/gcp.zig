//! What the client checks before sending, so a bad name costs no request,
//! and the Los Angeles calendar the catalog holds a time range to.

const std = @import("std");
const core = @import("core");
const Timestamp = std.Io.Timestamp;

/// The largest page either list takes, and its default: 5000. A
/// `pageSize` of 5001, or below 0, is production's bare 400 (measured
/// 2026-11-04).
pub const max_page_size = 5000;

/// A service id, as `services.list` answers every one of its 1,781:
/// three groups of four uppercase hex digits, such as `6F81-5844-456A`.
/// SKU ids have the same form. Production answers anything else, or an
/// id nobody has, with 404.
pub fn isServiceId(id: []const u8) bool {
    if (id.len != 14) return false;
    for (id, 0..) |c, i| switch (i) {
        4, 9 => if (c != '-') return false,
        else => switch (c) {
            '0'...'9', 'A'...'F' => {},
            else => return false,
        },
    };
    return true;
}

/// An ISO 4217 code as production takes it: three uppercase letters.
/// `eur` is refused, as an unknown code is, with a bare 400.
pub fn isCurrencyCode(code: []const u8) bool {
    if (code.len != 3) return false;
    for (code) |c| if (c < 'A' or c > 'Z') return false;
    return true;
}

/// A page token travels as a query parameter; production's are the
/// offset in base64 (`Mg==` for 2), but opaque to callers.
pub fn isPageToken(token: []const u8) bool {
    if (token.len == 0) return false;
    for (token) |c| if (c <= ' ' or c >= 0x7f) return false;
    return true;
}

/// A user agent goes into a header, so it must be printable ASCII.
pub fn isUserAgent(agent: []const u8) bool {
    if (agent.len == 0) return false;
    for (agent) |c| if (c < ' ' or c >= 0x7f) return false;
    return true;
}

/// Why a time range is refused, or null when the catalog takes it.
/// `now` is the reader's clock. The rules, from the discovery document and
/// measured: no timestamp in the future; an end needs a start, and comes
/// after it; both fall in one calendar month in Los Angeles. A start alone
/// reads up to now, so it must fall in this month.
pub fn rangeProblem(start: ?Timestamp, end: ?Timestamp, now: Timestamp) ?[]const u8 {
    const s = start orelse return if (end != null) "an end_time needs a start_time" else null;
    if (!core.timestamp.inRange(s)) return "start_time is out of range";
    if (s.nanoseconds > now.nanoseconds) return "start_time is in the future";
    const e = end orelse now;
    if (!core.timestamp.inRange(e)) return "end_time is out of range";
    if (e.nanoseconds > now.nanoseconds) return "end_time is in the future";
    if (e.nanoseconds <= s.nanoseconds) return "end_time must come after start_time";
    if (!std.meta.eql(pacificMonth(s), pacificMonth(e))) {
        return if (end == null)
            "start_time must fall in this month in Los Angeles, since the range runs to now"
        else
            "start_time and end_time must fall in one calendar month in Los Angeles";
    }
    return null;
}

/// How far Los Angeles is behind UTC at `ts`, in seconds: 8 hours in
/// standard time, 7 in daylight time, by the US rule since 2007: daylight
/// time from the second Sunday in March at 2:00 standard time (10:00 UTC)
/// to the first Sunday in November at 2:00 daylight time (09:00 UTC).
pub fn pacificOffsetSeconds(ts: Timestamp) i64 {
    const s = seconds(ts);
    const year = core.timestamp.civilFromDays(@divFloor(s, std.time.s_per_day)).year;
    const begins = sunday(year, 3, 2) * std.time.s_per_day + 10 * 3600;
    const ends = sunday(year, 11, 1) * std.time.s_per_day + 9 * 3600;
    return if (s >= begins and s < ends) 7 * 3600 else 8 * 3600;
}

pub const Month = struct { year: i64, month: i64 };

/// The calendar month `ts` falls in, in Los Angeles.
pub fn pacificMonth(ts: Timestamp) Month {
    const local = seconds(ts) - pacificOffsetSeconds(ts);
    const date = core.timestamp.civilFromDays(@divFloor(local, std.time.s_per_day));
    return .{ .year = date.year, .month = date.month };
}

/// Midnight in Los Angeles on the day `ts` falls in there: when a price
/// read with no time range says it took effect (production's
/// `2026-11-04T08:00:00Z`).
pub fn pacificDayStart(ts: Timestamp) Timestamp {
    const local_day = @divFloor(seconds(ts) - pacificOffsetSeconds(ts), std.time.s_per_day);
    const midnight = local_day * std.time.s_per_day;
    // Midnight is before either change of clocks, which happen at 2:00,
    // so its offset is the one in force just after it, standard or not.
    const offset = pacificOffsetSeconds(.{ .nanoseconds = @as(i96, midnight + 8 * 3600) * std.time.ns_per_s });
    return .{ .nanoseconds = @as(i96, midnight + offset) * std.time.ns_per_s };
}

fn seconds(ts: Timestamp) i64 {
    return @intCast(@divFloor(ts.nanoseconds, std.time.ns_per_s));
}

/// Days since 1970-01-01 of the `nth` Sunday of `month` in `year`.
fn sunday(year: i64, month: i64, nth: i64) i64 {
    const first = core.timestamp.daysFromCivil(year, month, 1);
    // 1970-01-01 was a Thursday: day 0 has weekday 4, counting Sunday as 0.
    const weekday = @mod(first + 4, 7);
    return first + @mod(7 - weekday, 7) + (nth - 1) * 7;
}

const testing = std.testing;

fn at(text: []const u8) Timestamp {
    return core.timestamp.parse(text) catch unreachable;
}

test "service ids, currencies, tokens and agents" {
    try testing.expect(isServiceId("6F81-5844-456A"));
    try testing.expect(isServiceId("0017-8C5E-5B91"));
    try testing.expect(!isServiceId("6f81-5844-456a"));
    try testing.expect(!isServiceId("not-a-service"));
    try testing.expect(!isServiceId("6F81-5844-456A0"));
    try testing.expect(!isServiceId("6F81-5844_456A"));
    try testing.expect(!isServiceId(""));
    try testing.expect(isCurrencyCode("USD"));
    try testing.expect(isCurrencyCode("EUR"));
    try testing.expect(!isCurrencyCode("eur"));
    try testing.expect(!isCurrencyCode("EURO"));
    try testing.expect(!isCurrencyCode("E1R"));
    try testing.expect(isPageToken("NTAwMA=="));
    try testing.expect(!isPageToken("a b"));
    try testing.expect(!isPageToken(""));
    try testing.expect(isUserAgent("gcp-zig-billing/0.67"));
    try testing.expect(!isUserAgent("a\nb"));
}

test "Los Angeles time: the 2026 changes of clocks, months and midnights" {
    // Daylight time began 2026-03-08 at 10:00 UTC and ends 2026-11-01 at
    // 09:00 UTC.
    try testing.expectEqual(8 * 3600, pacificOffsetSeconds(at("2026-03-08T09:59:59Z")));
    try testing.expectEqual(7 * 3600, pacificOffsetSeconds(at("2026-03-08T10:00:00Z")));
    try testing.expectEqual(7 * 3600, pacificOffsetSeconds(at("2026-11-01T08:59:59Z")));
    try testing.expectEqual(8 * 3600, pacificOffsetSeconds(at("2026-11-01T09:00:00Z")));
    try testing.expectEqual(8 * 3600, pacificOffsetSeconds(at("2026-01-15T12:00:00Z")));

    // October in Los Angeles: 2026-10-01T07:00:00Z to 2026-11-01T07:00:00Z.
    try testing.expectEqual(Month{ .year = 2026, .month = 9 }, pacificMonth(at("2026-10-01T06:59:59Z")));
    try testing.expectEqual(Month{ .year = 2026, .month = 10 }, pacificMonth(at("2026-10-01T07:00:00Z")));
    try testing.expectEqual(Month{ .year = 2026, .month = 10 }, pacificMonth(at("2026-11-01T06:59:59Z")));
    try testing.expectEqual(Month{ .year = 2026, .month = 11 }, pacificMonth(at("2026-11-01T07:00:00Z")));
    // New Year's in Los Angeles is 08:00 UTC.
    try testing.expectEqual(Month{ .year = 2026, .month = 12 }, pacificMonth(at("2027-01-01T07:59:59Z")));
    try testing.expectEqual(Month{ .year = 2027, .month = 1 }, pacificMonth(at("2027-01-01T08:00:00Z")));

    // Production's effective time for prices read on 2026-11-04.
    try testing.expectEqual(at("2026-11-04T08:00:00Z"), pacificDayStart(at("2026-11-04T19:30:00Z")));
    try testing.expectEqual(at("2026-11-04T08:00:00Z"), pacificDayStart(at("2026-11-05T07:59:59Z")));
    // The day clocks go back starts in daylight time; the next does not.
    try testing.expectEqual(at("2026-11-01T07:00:00Z"), pacificDayStart(at("2026-11-01T20:00:00Z")));
    try testing.expectEqual(at("2026-11-02T08:00:00Z"), pacificDayStart(at("2026-11-02T08:00:00Z")));
    // The day clocks go forward starts in standard time.
    try testing.expectEqual(at("2026-03-08T08:00:00Z"), pacificDayStart(at("2026-03-08T20:00:00Z")));
    try testing.expectEqual(at("2026-03-09T07:00:00Z"), pacificDayStart(at("2026-03-09T12:00:00Z")));
}

test "rangeProblem: the ranges production took and refused" {
    const now = at("2026-11-04T19:30:00Z");
    // Taken: October as milestone 0 read it, a start alone this month.
    try testing.expectEqual(null, rangeProblem(at("2026-10-01T07:00:00Z"), at("2026-10-31T06:59:59Z"), now));
    try testing.expectEqual(null, rangeProblem(at("2026-11-01T08:00:00Z"), null, now));
    try testing.expectEqual(null, rangeProblem(null, null, now));
    // Refused by production with a bare 400.
    try testing.expect(rangeProblem(null, at("2026-11-02T08:00:00Z"), now) != null);
    try testing.expect(rangeProblem(at("2026-11-03T00:00:00Z"), at("2026-11-02T00:00:00Z"), now) != null);
    try testing.expect(rangeProblem(at("2026-09-15T00:00:00Z"), at("2026-10-15T00:00:00Z"), now) != null);
    try testing.expect(rangeProblem(at("2027-01-01T00:00:00Z"), at("2027-01-02T00:00:00Z"), now) != null);
    // Each refusal names its own reason, which `Diagnostics` carries.
    try testing.expectEqualStrings("start_time is in the future", rangeProblem(at("2027-01-01T00:00:00Z"), null, now).?);
    try testing.expectEqualStrings("start_time is in the future", rangeProblem(at("2027-01-01T00:00:00Z"), at("2027-01-02T00:00:00Z"), now).?);
    try testing.expectEqualStrings("end_time is in the future", rangeProblem(at("2026-11-02T00:00:00Z"), at("2026-11-05T00:00:00Z"), now).?);
    try testing.expectEqualStrings("end_time must come after start_time", rangeProblem(at("2026-11-03T00:00:00Z"), at("2026-11-02T00:00:00Z"), now).?);
    // A start alone last month would run across this month's start.
    try testing.expect(rangeProblem(at("2026-10-20T00:00:00Z"), null, now) != null);
    // An end at the start, or in the future.
    try testing.expect(rangeProblem(at("2026-11-02T00:00:00Z"), at("2026-11-02T00:00:00Z"), now) != null);
    try testing.expect(rangeProblem(at("2026-11-02T00:00:00Z"), at("2026-11-05T00:00:00Z"), now) != null);
}

fn pacificProperty(_: void, input: []const u8) !void {
    var g: core.testing.ByteGen = .init(input);
    // Any second from 1970 to 2100.
    const s: i64 = @intCast(g.intRange(u64, 0, 4_102_444_800));
    const ts: Timestamp = .{ .nanoseconds = @as(i96, s) * std.time.ns_per_s };
    const offset = pacificOffsetSeconds(ts);
    try testing.expect(offset == 7 * 3600 or offset == 8 * 3600);
    // Midnight comes at or before the moment, less than a day (25 hours
    // on the day the clocks go back) before, and is midnight there.
    const day = pacificDayStart(ts);
    try testing.expect(day.nanoseconds <= ts.nanoseconds);
    try testing.expect(ts.nanoseconds - day.nanoseconds < 25 * std.time.ns_per_hour);
    const local = @divFloor(day.nanoseconds, std.time.ns_per_s) - pacificOffsetSeconds(day);
    try testing.expectEqual(0, @mod(local, std.time.s_per_day));
    // The day's start is in the moment's month.
    try testing.expectEqual(pacificMonth(ts), pacificMonth(day));
}

test "fuzz Los Angeles time: offsets, midnights and months agree for any moment" {
    try core.testing.fuzzBytes({}, pacificProperty, .{ .corpus = &.{
        "\x00\x00\x00\x00\x00\x00\x00\x00",
        "\xff\xff\xff\xff\xff\xff\xff\xff",
    } });
}
