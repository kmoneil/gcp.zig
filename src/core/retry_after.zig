//! A server's retry delay: how long a refused response asked its client to
//! wait before trying again. Three forms are read, and the largest valid one
//! is kept, since each means "at least this long":
//!
//! - `Retry-After`, RFC 9110 section 10.2.3: delay-seconds, or an HTTP-date
//!   in any of the three formats a recipient must accept, read against the
//!   response's own `Date` when it has one (RFC 9111 measures a server's
//!   dates that way, to cancel clock skew), else against when the response
//!   arrived;
//! - `retry-after-ms`, milliseconds, which Google's front end sends beside
//!   `Retry-After` and Azure defines;
//! - `google.rpc.RetryInfo` in a JSON error body's `details`, whose
//!   `retryDelay` is a Duration such as "30s" or "0.830956646s".
//!
//! A malformed, negative or empty value is ignored, never an error, and a
//! delay past `maxInt(u32)` milliseconds (49.7 days) saturates there with no
//! overflow on the way. Measured on 2026-10-17, none of the services this
//! library covers sends any of the three: Logging's and Cloud Storage's 429s
//! carry neither header and no RetryInfo. Google's front end sends all three
//! for Gemini-family hosts, and Spanner sends RetryInfo on ABORTED.
//!
//! `Asked` writes a delay in any of the forms, for the fakes, whose scripted
//! refusals stand in for a server that asks.

const std = @import("std");
const Allocator = std.mem.Allocator;
const duration = @import("duration.zig");
const errors = @import("errors.zig");
const transport = @import("transport.zig");

const max_ms = std.math.maxInt(u32);

/// The delay a refused response asked for, in milliseconds, from its
/// headers and, when it is Google's JSON error shape, its body; null when
/// it asked for none. `received_at` is the wall clock when it arrived.
pub fn serverDelayMs(arena: Allocator, headers: []const transport.Header, body: []const u8, received_at: std.Io.Timestamp) Allocator.Error!?u32 {
    var best: ?u32 = null;
    const date = header(headers, "date");
    for (headers) |h| {
        const found: ?u32 = if (std.ascii.eqlIgnoreCase(h.name, "retry-after"))
            retryAfterMs(h.value, date, received_at)
        else if (std.ascii.eqlIgnoreCase(h.name, "retry-after-ms"))
            millisecondsMs(h.value)
        else
            continue;
        best = larger(best, found);
    }
    return larger(best, try errors.decodeRetryDelayMs(arena, body));
}

fn larger(a: ?u32, b: ?u32) ?u32 {
    const x = a orelse return b;
    const y = b orelse return x;
    return @max(x, y);
}

fn header(headers: []const transport.Header, name: []const u8) ?[]const u8 {
    for (headers) |h| if (std.ascii.eqlIgnoreCase(h.name, name)) return h.value;
    return null;
}

const ows = " \t";

/// A `Retry-After` value: delay-seconds, or an HTTP-date measured from the
/// response's `Date` (`date`, when present and valid) or else from
/// `received_at`. A date in the past is 0.
pub fn retryAfterMs(value: []const u8, date: ?[]const u8, received_at: std.Io.Timestamp) ?u32 {
    const text = std.mem.trim(u8, value, ows);
    if (digitsMs(text, 1000)) |ms| return ms;
    const target = httpDate(text) orelse return null;
    const base: i64 = if (date) |d| httpDate(std.mem.trim(u8, d, ows)) orelse nowSeconds(received_at) else nowSeconds(received_at);
    if (target <= base) return 0;
    const seconds: u64 = @intCast(target - base);
    return saturate(@as(u128, seconds) * 1000);
}

fn nowSeconds(t: std.Io.Timestamp) i64 {
    return @intCast(@divFloor(t.nanoseconds, std.time.ns_per_s));
}

/// A `retry-after-ms` value: a non-negative integer of milliseconds.
pub fn millisecondsMs(value: []const u8) ?u32 {
    return digitsMs(std.mem.trim(u8, value, ows), 1);
}

/// `1*DIGIT` times `unit_ms`, saturating; null for anything else.
fn digitsMs(text: []const u8, unit_ms: u32) ?u32 {
    if (text.len == 0) return null;
    var n: u128 = 0;
    for (text) |c| {
        if (!std.ascii.isDigit(c)) return null;
        // Past this the result saturates whatever digits follow.
        if (n <= max_ms) n = n * 10 + (c - '0');
    }
    return saturate(n * unit_ms);
}

fn saturate(n: u128) u32 {
    return if (n > max_ms) max_ms else @intCast(n);
}

/// A Duration in ProtoJSON form, as `core.duration` reads it, rounded up
/// to milliseconds: seconds, up to nine fractional digits, and "s", as
/// "30s", "1.5s" or "0.830956646s". Null for a negative one, and for one
/// that is malformed or past Duration's 10,000 years.
pub fn durationMs(text: []const u8) ?u32 {
    const d = duration.parse(text) catch return null;
    if (d.nanoseconds < 0) return null;
    const ns: u128 = @intCast(d.nanoseconds);
    return saturate((ns + std.time.ns_per_ms - 1) / std.time.ns_per_ms);
}

const months = [_][]const u8{ "Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec" };
const day_names = [_][]const u8{ "Mon", "Tue", "Wed", "Thu", "Fri", "Sat", "Sun" };
const long_day_names = [_][]const u8{ "Monday", "Tuesday", "Wednesday", "Thursday", "Friday", "Saturday", "Sunday" };

/// An HTTP-date in Unix seconds, in any of RFC 9110's three formats:
/// IMF-fixdate "Sun, 06 Nov 1994 08:49:37 GMT", rfc850-date
/// "Sunday, 06-Nov-94 08:49:37 GMT", and asctime-date
/// "Sun Nov  6 08:49:37 1994". Case-sensitive, as RFC 9110 says. The
/// weekday is not checked against the date. A two-digit year is read in
/// 1950 to 2049, which is RFC 9110's rule ("more than 50 years in the
/// future" is the past) for any year this library will run in.
pub fn httpDate(text: []const u8) ?i64 {
    if (imfFixdate(text)) |t| return t;
    if (rfc850Date(text)) |t| return t;
    return asctimeDate(text);
}

fn imfFixdate(t: []const u8) ?i64 {
    // "Sun, 06 Nov 1994 08:49:37 GMT"
    if (t.len != 29 or !isOneOf(t[0..3], &day_names) or !std.mem.eql(u8, t[3..5], ", ") or t[7] != ' ' or t[11] != ' ' or t[16] != ' ' or !std.mem.eql(u8, t[25..], " GMT")) return null;
    const day = number(t[5..7]) orelse return null;
    const month = monthOf(t[8..11]) orelse return null;
    const year = number(t[12..16]) orelse return null;
    return civil(year, month, day, t[17..25]);
}

fn rfc850Date(t: []const u8) ?i64 {
    // "Sunday, 06-Nov-94 08:49:37 GMT"
    const comma = std.mem.indexOfScalar(u8, t, ',') orelse return null;
    if (!isOneOf(t[0..comma], &long_day_names)) return null;
    const rest = t[comma..];
    if (rest.len != 24 or rest[1] != ' ' or rest[4] != '-' or rest[8] != '-' or rest[11] != ' ' or !std.mem.eql(u8, rest[20..], " GMT")) return null;
    const day = number(rest[2..4]) orelse return null;
    const month = monthOf(rest[5..8]) orelse return null;
    const yy = number(rest[9..11]) orelse return null;
    const year = if (yy < 50) 2000 + yy else 1900 + yy;
    return civil(year, month, day, rest[12..20]);
}

fn asctimeDate(t: []const u8) ?i64 {
    // "Sun Nov  6 08:49:37 1994"
    if (t.len != 24 or !isOneOf(t[0..3], &day_names) or t[3] != ' ' or t[7] != ' ' or t[10] != ' ' or t[19] != ' ') return null;
    const month = monthOf(t[4..7]) orelse return null;
    const day = if (t[8] == ' ') number(t[9..10]) orelse return null else number(t[8..10]) orelse return null;
    const year = number(t[20..24]) orelse return null;
    return civil(year, month, day, t[11..19]);
}

fn isOneOf(text: []const u8, names: []const []const u8) bool {
    for (names) |n| if (std.mem.eql(u8, text, n)) return true;
    return false;
}

fn monthOf(text: []const u8) ?i64 {
    for (months, 1..) |m, i| if (std.mem.eql(u8, text, m)) return @intCast(i);
    return null;
}

fn number(text: []const u8) ?i64 {
    var n: i64 = 0;
    for (text) |c| {
        if (!std.ascii.isDigit(c)) return null;
        n = n * 10 + (c - '0');
    }
    return n;
}

/// "08:49:37" on a date, in Unix seconds; a leap second (60) is read as 59.
fn civil(year: i64, month: i64, day: i64, time: []const u8) ?i64 {
    if (time.len != 8 or time[2] != ':' or time[5] != ':') return null;
    const hour = number(time[0..2]) orelse return null;
    const minute = number(time[3..5]) orelse return null;
    const second = number(time[6..8]) orelse return null;
    if (hour > 23 or minute > 59 or second > 60) return null;
    if (day < 1 or day > daysIn(year, month)) return null;
    return daysFromCivil(year, month, day) * std.time.s_per_day + hour * 3600 + minute * 60 + @min(second, 59);
}

fn daysIn(year: i64, month: i64) i64 {
    return switch (month) {
        2 => if (@mod(year, 4) == 0 and (@mod(year, 100) != 0 or @mod(year, 400) == 0)) 29 else 28,
        4, 6, 9, 11 => 30,
        else => 31,
    };
}

/// Days since 1970-01-01, Howard Hinnant's algorithm, as core.timestamp's.
fn daysFromCivil(year: i64, month: i64, day: i64) i64 {
    const y = if (month <= 2) year - 1 else year;
    const era = @divFloor(y, 400);
    const yoe = y - era * 400;
    const mp = if (month > 2) month - 3 else month + 9;
    const doy = @divFloor(153 * mp + 2, 5) + day - 1;
    const doe = yoe * 365 + @divFloor(yoe, 4) - @divFloor(yoe, 100) + doy;
    return era * 146097 + doe - 719468;
}

/// A delay a server asks for, and the form or forms it asks in: what the
/// fakes script on the refusals they inject, so that a caller's offline
/// checks can drive its own scheduling.
pub const Asked = struct {
    ms: u32,
    form: Form = .all,

    pub const Form = enum {
        /// `Retry-After`, in whole seconds, rounded up.
        retry_after,
        /// `retry-after-ms`.
        retry_after_ms,
        /// A `google.rpc.RetryInfo` detail in the error body.
        retry_info,
        /// All three at once, as Google's front end sends them.
        all,
    };

    /// The headers that carry it, in `arena`.
    pub fn headers(a: Asked, arena: Allocator) Allocator.Error![]const transport.Header {
        var list: std.ArrayList(transport.Header) = .empty;
        if (a.form == .retry_after or a.form == .all) {
            try list.append(arena, .{ .name = "Retry-After", .value = try arena.print("{d}", .{a.seconds()}) });
        }
        if (a.form == .retry_after_ms or a.form == .all) {
            try list.append(arena, .{ .name = "retry-after-ms", .value = try arena.print("{d}", .{a.ms}) });
        }
        return list.items;
    }

    /// `body` with a RetryInfo detail added to its `error.details` when the
    /// form has one, in `arena`. A body that is not a Google API error body
    /// comes back as it is.
    pub fn intoBody(a: Asked, arena: Allocator, body: []const u8) Allocator.Error![]const u8 {
        if (a.form != .retry_info and a.form != .all) return body;
        var root = std.json.parseFromSliceLeaky(std.json.Value, arena, body, .{}) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            else => return body,
        };
        if (root != .object) return body;
        const err_value = root.object.getPtr("error") orelse return body;
        if (err_value.* != .object) return body;
        const details: *std.json.Array = details: {
            if (err_value.object.getPtr("details")) |d| if (d.* == .array) break :details &d.array;
            try err_value.object.put(arena, "details", .{ .array = .init(arena) });
            break :details &err_value.object.getPtr("details").?.array;
        };
        var detail: std.json.ObjectMap = .empty;
        try detail.put(arena, "@type", .{ .string = "type.googleapis.com/google.rpc.RetryInfo" });
        try detail.put(arena, "retryDelay", .{ .string = try a.retryDelay(arena) });
        try details.append(.{ .object = detail });
        return std.json.Stringify.valueAlloc(arena, root, .{});
    }

    /// What a client that reads every form, as `serverDelayMs` does, takes
    /// it for: the header's seconds are rounded up, and the largest wins.
    pub fn readMs(a: Asked) u32 {
        return switch (a.form) {
            .retry_after, .all => saturate(@as(u128, a.seconds()) * std.time.ms_per_s),
            .retry_after_ms, .retry_info => a.ms,
        };
    }

    fn seconds(a: Asked) u32 {
        return a.ms / std.time.ms_per_s + @intFromBool(a.ms % std.time.ms_per_s != 0);
    }

    /// A Duration as Google writes one: "2s", or "1.500s".
    fn retryDelay(a: Asked, arena: Allocator) Allocator.Error![]const u8 {
        const whole = a.ms / std.time.ms_per_s;
        const part = a.ms % std.time.ms_per_s;
        if (part == 0) return arena.print("{d}s", .{whole});
        return arena.print("{d}.{d:0>3}s", .{ whole, part });
    }
};

const testing = std.testing;
const test_util = @import("testing.zig");

fn at(seconds: i64) std.Io.Timestamp {
    return .{ .nanoseconds = @as(i96, seconds) * std.time.ns_per_s };
}

/// 1994-11-06T08:49:37Z, RFC 9110's example.
const example: i64 = 784111777;

test "httpDate: RFC 9110's three formats, its example, and what is not one" {
    try testing.expectEqual(example, httpDate("Sun, 06 Nov 1994 08:49:37 GMT").?);
    try testing.expectEqual(example, httpDate("Sunday, 06-Nov-94 08:49:37 GMT").?);
    try testing.expectEqual(example, httpDate("Sun Nov  6 08:49:37 1994").?);
    try testing.expectEqual(example, httpDate("Sun Nov 06 08:49:37 1994").?);
    // Two-digit years: 49 is 2049, 50 is 1950.
    try testing.expectEqual(httpDate("Wed, 01 Jan 2049 00:00:00 GMT").?, httpDate("Wednesday, 01-Jan-49 00:00:00 GMT").?);
    try testing.expectEqual(httpDate("Sun, 01 Jan 1950 00:00:00 GMT").?, httpDate("Sunday, 01-Jan-50 00:00:00 GMT").?);
    try testing.expectEqual(@as(i64, 0), httpDate("Thu, 01 Jan 1970 00:00:00 GMT").?);
    // Leap days, century years by the Gregorian rule, and a leap second
    // read as the second before.
    try testing.expect(httpDate("Thu, 29 Feb 2024 12:00:00 GMT") != null);
    try testing.expect(httpDate("Tue, 29 Feb 2000 12:00:00 GMT") != null);
    try testing.expectEqual(null, httpDate("Thu, 29 Feb 2100 12:00:00 GMT"));
    try testing.expectEqual(null, httpDate("Thu, 29 Feb 1900 12:00:00 GMT"));
    try testing.expectEqual(httpDate("Wed, 31 Dec 2025 23:59:59 GMT").?, httpDate("Wed, 31 Dec 2025 23:59:60 GMT").?);
    for ([_][]const u8{
        "",                                 "Sun, 06 Nov 1994 08:49:37 UTC",  "sun, 06 Nov 1994 08:49:37 GMT",
        "Sun, 06 nov 1994 08:49:37 GMT",    "Sun, 6 Nov 1994 08:49:37 GMT",   "Sun, 06 Nov 1994 8:49:37 GMT",
        "Sun, 31 Feb 1994 08:49:37 GMT",    "Sun, 29 Feb 2023 08:49:37 GMT",  "Sun, 06 Nov 1994 24:00:00 GMT",
        "Sun, 06 Nov 1994 08:60:00 GMT",    "Sun, 06 Nov 1994 08:49:61 GMT",  "Sun, 00 Nov 1994 08:49:37 GMT",
        "Sunday, 06-Nov-1994 08:49:37 GMT", "Sun, 06-Nov-94 08:49:37 GMT",    "Sun Nov 6 08:49:37 1994",
        "Sun Nov  6 08:49:37 94",           "Sun, 06 Nov 1994 08:49:37 GMT ", "Sun, 06 Nov 1994 08:49:37 GMTX",
        "120",                              "Funday, 06-Nov-94 08:49:37 GMT", "Sun, 06 Nov 19x4 08:49:37 GMT",
    }) |bad| {
        if (httpDate(bad) != null) {
            std.debug.print("read: {s}\n", .{bad});
            return error.TestExpectedNull;
        }
    }
}

test "retryAfterMs: seconds, saturating; a date against the response's Date, else the clock" {
    const now = at(example);
    try testing.expectEqual(120_000, retryAfterMs("120", null, now).?);
    try testing.expectEqual(0, retryAfterMs("0", null, now).?);
    try testing.expectEqual(1_000, retryAfterMs(" 1\t", null, now).?);
    try testing.expectEqual(5_000, retryAfterMs("0005", null, now).?);
    // GoDaddy's, and far past it: saturated, never wrapped.
    try testing.expectEqual(std.math.maxInt(u32), retryAfterMs("9223372037", null, now).?);
    try testing.expectEqual(std.math.maxInt(u32), retryAfterMs("99999999999999999999999999999999999999999", null, now).?);
    try testing.expectEqual(4_294_967_000, retryAfterMs("4294967", null, now).?);
    try testing.expectEqual(std.math.maxInt(u32), retryAfterMs("4294968", null, now).?);
    for ([_][]const u8{ "", " ", "-1", "1.5", "+1", "1e3", "1 2", "soon" }) |bad| try testing.expectEqual(null, retryAfterMs(bad, null, now));

    // A date: from the response's Date when it has one, which cancels a
    // client clock that is an hour fast.
    const date = "Sun, 06 Nov 1994 08:49:37 GMT";
    const later = "Sun, 06 Nov 1994 08:50:07 GMT";
    try testing.expectEqual(30_000, retryAfterMs(later, date, at(example + 3600)).?);
    try testing.expectEqual(30_000, retryAfterMs(later, null, now).?);
    // A broken Date falls back to the clock; a date in the past is now.
    try testing.expectEqual(30_000, retryAfterMs(later, "yesterday", now).?);
    try testing.expectEqual(0, retryAfterMs(date, null, at(example + 1)).?);
    try testing.expectEqual(0, retryAfterMs(date, later, now).?);
    try testing.expectEqual(std.math.maxInt(u32), retryAfterMs("Fri, 31 Dec 9999 23:59:59 GMT", null, now).?);
}

test "millisecondsMs" {
    try testing.expectEqual(831, millisecondsMs("831").?);
    try testing.expectEqual(0, millisecondsMs("0").?);
    try testing.expectEqual(std.math.maxInt(u32), millisecondsMs("4294967296").?);
    for ([_][]const u8{ "", "-1", "1.5", "831ms" }) |bad| try testing.expectEqual(null, millisecondsMs(bad));
}

test "durationMs: ProtoJSON Durations, rounded up to milliseconds" {
    for ([_]struct { []const u8, u32 }{
        .{ "30s", 30_000 },                 .{ "0s", 0 },
        .{ "1.5s", 1_500 },                 .{ "1.500s", 1_500 },
        .{ "0.830956646s", 831 },           .{ "0.000000001s", 1 },
        .{ "0.011158286s", 12 },            .{ "539420.179078308s", 539_420_180 },
        .{ "3.000001s", 3_001 },            .{ "315576000000s", std.math.maxInt(u32) },
        .{ "4294967.295s", 4_294_967_295 }, .{ "4294967.2951s", std.math.maxInt(u32) },
    }) |case| try testing.expectEqual(case[1], durationMs(case[0]).?);
    for ([_][]const u8{ "", "s", "30", "-1s", "-0.5s", "+1s", "1e1s", "1.s", ".5s", "1.0000000001s", "1.5ms", "30 s", "1,5s", "1.5.5s", "315576000001s", "99999999999999999999999999999s" }) |bad| {
        try testing.expectEqual(null, durationMs(bad));
    }
}

test "serverDelayMs: the largest of the three forms, as Google's front end sends them together" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const now = at(1_792_255_951);
    // jenslys/opencode-gemini-auth#48: one 429 from ESF with all three.
    const esf_body =
        \\{"error":{"code":429,"message":"Your quota will reset after 0s.","status":"RESOURCE_EXHAUSTED","details":[
        \\ {"@type":"type.googleapis.com/google.rpc.ErrorInfo","reason":"RATE_LIMIT_EXCEEDED","domain":"cloudcode-pa.googleapis.com","metadata":{"quotaResetDelay":"830.956646ms"}},
        \\ {"@type":"type.googleapis.com/google.rpc.RetryInfo","retryDelay":"0.830956646s"}]}}
    ;
    try testing.expectEqual(1_000, (try serverDelayMs(a, &.{
        .{ .name = "date", .value = "Sat, 07 Feb 2026 15:08:40 GMT" },
        .{ .name = "retry-after", .value = "1" },
        .{ .name = "retry-after-ms", .value = "831" },
        .{ .name = "server", .value = "ESF" },
    }, esf_body, now)).?);
    try testing.expectEqual(831, (try serverDelayMs(a, &.{.{ .name = "Retry-After-Ms", .value = "831" }}, "", now)).?);
    try testing.expectEqual(831, (try serverDelayMs(a, &.{}, esf_body, now)).?);
    // Two Retry-After headers: the larger.
    try testing.expectEqual(7_000, (try serverDelayMs(a, &.{ .{ .name = "Retry-After", .value = "7" }, .{ .name = "Retry-After", .value = "2" } }, "", now)).?);
    // An invalid one beside a valid one is ignored.
    try testing.expectEqual(2_000, (try serverDelayMs(a, &.{ .{ .name = "Retry-After", .value = "soon" }, .{ .name = "Retry-After", .value = "2" } }, "", now)).?);
}

test "serverDelayMs: what production sent on 2026-10-16 and 17 asks for nothing" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const now = at(1_792_255_951);
    // Logging's quota 429, from ESF, with every header it carried.
    const logging_429 =
        \\{"error":{"code":429,"message":"Quota exceeded for quota metric 'Read requests' and limit 'Read requests per minute' of service 'logging.googleapis.com' for consumer 'project_number:82150720798'.","status":"RESOURCE_EXHAUSTED","details":[{"@type":"type.googleapis.com/google.rpc.ErrorInfo","reason":"RATE_LIMIT_EXCEEDED","domain":"googleapis.com","metadata":{"window_start_time":"1792255952","quota_limit_value":"60"}},{"@type":"type.googleapis.com/google.rpc.Help","links":[{"description":"Request a higher quota limit.","url":"https://cloud.google.com/docs/quotas/help/request_increase"}]}]}}
    ;
    try testing.expectEqual(null, try serverDelayMs(a, &.{
        .{ .name = "Vary", .value = "X-Origin" },
        .{ .name = "Content-Type", .value = "application/json; charset=UTF-8" },
        .{ .name = "Date", .value = "Sat, 17 Oct 2026 16:53:10 GMT" },
        .{ .name = "Server", .value = "ESF" },
        .{ .name = "Server-Timing", .value = "gfet4t7; dur=19" },
    }, logging_429, now));
    // Cloud Storage's XML 429.
    try testing.expectEqual(null, try serverDelayMs(a, &.{
        .{ .name = "Content-Type", .value = "application/xml; charset=UTF-8" },
        .{ .name = "Date", .value = "Sat, 17 Oct 2026 16:52:31 GMT" },
        .{ .name = "Server", .value = "UploadServer" },
    }, "<?xml version='1.0' encoding='UTF-8'?><Error><Code>SlowDown</Code><Message>The object exceeded the rate limit for object mutation operations (create, update, and delete).</Message></Error>", now));
}

test "serverDelayMs: every allocation failure is OutOfMemory without leaks" {
    const Run = struct {
        fn run(gpa: Allocator) !void {
            var arena: std.heap.ArenaAllocator = .init(gpa);
            defer arena.deinit();
            _ = try serverDelayMs(arena.allocator(), &.{.{ .name = "retry-after", .value = "3" }},
                \\{"error":{"details":[{"@type":"type.googleapis.com/google.rpc.RetryInfo","retryDelay":"5s"},{"@type":"x","a":[1,2,3]}]}}
            , at(0));
        }
    };
    try testing.checkAllAllocationFailures(test_util.no_grow_allocator, Run.run, .{});
}

test "Asked: each form, written as servers write it, and read back" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const body = "{\"error\":{\"code\":503,\"message\":\"busy\",\"status\":\"UNAVAILABLE\"}}";

    const header_only: Asked = .{ .ms = 1_500, .form = .retry_after };
    const sent = try header_only.headers(a);
    try testing.expectEqual(1, sent.len);
    try testing.expectEqualStrings("Retry-After", sent[0].name);
    try testing.expectEqualStrings("2", sent[0].value);
    try testing.expectEqualStrings(body, try header_only.intoBody(a, body));
    try testing.expectEqual(2_000, header_only.readMs());

    const ms_only: Asked = .{ .ms = 1_500, .form = .retry_after_ms };
    try testing.expectEqualStrings("retry-after-ms", (try ms_only.headers(a))[0].name);
    try testing.expectEqualStrings("1500", (try ms_only.headers(a))[0].value);
    try testing.expectEqual(1_500, ms_only.readMs());

    const info: Asked = .{ .ms = 1_500, .form = .retry_info };
    try testing.expectEqual(0, (try info.headers(a)).len);
    try testing.expectEqualStrings(
        "{\"error\":{\"code\":503,\"message\":\"busy\",\"status\":\"UNAVAILABLE\",\"details\":[{\"@type\":\"type.googleapis.com/google.rpc.RetryInfo\",\"retryDelay\":\"1.500s\"}]}}",
        try info.intoBody(a, body),
    );
    try testing.expectEqual(1_500, info.readMs());
    // Whole seconds are written as such, and details already there stay.
    try testing.expectEqualStrings(
        "{\"error\":{\"details\":[{\"@type\":\"x\"},{\"@type\":\"type.googleapis.com/google.rpc.RetryInfo\",\"retryDelay\":\"30s\"}]}}",
        try (Asked{ .ms = 30_000, .form = .retry_info }).intoBody(a, "{\"error\":{\"details\":[{\"@type\":\"x\"}]}}"),
    );
    // Not an error body: left alone.
    for ([_][]const u8{ "", "nope", "[1]", "{\"error\":\"busy\"}" }) |other| {
        try testing.expectEqualStrings(other, try info.intoBody(a, other));
    }

    const all: Asked = .{ .ms = 1_500 };
    try testing.expectEqual(2, (try all.headers(a)).len);
    // All three: the body carries the delay too, unrounded.
    try testing.expectEqual(1_500, try errors.decodeRetryDelayMs(a, try all.intoBody(a, body)));
    try testing.expectEqual(2_000, all.readMs());
    try testing.expectEqual(2_000, try serverDelayMs(a, try all.headers(a), try all.intoBody(a, body), at(0)));
    // The longest delay there is: the header's seconds saturate.
    try testing.expectEqual(max_ms, (Asked{ .ms = max_ms }).readMs());
    try testing.expectEqual(0, (Asked{ .ms = 0 }).readMs());
}

test "Asked: every allocation failure is OutOfMemory without leaks" {
    const Run = struct {
        fn run(gpa: Allocator) !void {
            var arena: std.heap.ArenaAllocator = .init(gpa);
            defer arena.deinit();
            const a: Asked = .{ .ms = 2_250 };
            _ = try a.headers(arena.allocator());
            _ = try a.intoBody(arena.allocator(), "{\"error\":{\"code\":429,\"details\":[{\"@type\":\"x\"}]}}");
        }
    };
    try testing.checkAllAllocationFailures(test_util.no_grow_allocator, Run.run, .{});
}

fn askedProperty(_: void, input: []const u8) !void {
    var arena: std.heap.ArenaAllocator = .init(std.heap.smp_allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var g: test_util.ByteGen = .init(input);
    // Whatever is asked, in whatever form, on whatever body: what is read
    // back is `readMs`, or, from a body that holds no error, the headers'.
    const asked: Asked = .{ .ms = g.int(u32), .form = g.pick(Asked.Form, &.{ .retry_after, .retry_after_ms, .retry_info, .all }) };
    const body = g.pick([]const u8, &.{
        "{\"error\":{\"code\":503,\"status\":\"UNAVAILABLE\"}}",
        "{\"error\":{\"code\":429,\"details\":[{\"@type\":\"type.googleapis.com/google.rpc.ErrorInfo\",\"reason\":\"RATE_LIMIT_EXCEEDED\"}]}}",
        "{\"error\":{\"details\":[{\"@type\":\"type.googleapis.com/google.rpc.RetryInfo\",\"retryDelay\":\"0s\"}]}}",
        "Service Unavailable",
        "",
    });
    const got = try serverDelayMs(a, try asked.headers(a), try asked.intoBody(a, body), at(1_792_255_951));
    const errored = std.mem.startsWith(u8, body, "{");
    const want: ?u32 = if (errored or asked.form != .retry_info) asked.readMs() else null;
    try testing.expectEqual(want, got);
}

test "fuzz Asked: any delay in any form reads back as readMs says" {
    try test_util.fuzzBytes({}, askedProperty, .{ .corpus = &.{ "", "\xff\xff\xff\xff\x03", "\xdc\x05\x00\x00\x02\x00" } });
}

fn durationProperty(_: void, input: []const u8) !void {
    var g: test_util.ByteGen = .init(input);
    // A plain model: seconds and nanoseconds, written as ProtoJSON writes
    // them, read back.
    const seconds = g.intRange(u64, 0, 5_000_000);
    const nanos = g.intRange(u32, 0, 999_999_999);
    var buf: [64]u8 = undefined;
    const digits_kept = g.pick(u8, &.{ 0, 3, 6, 9 });
    const text = switch (digits_kept) {
        0 => std.fmt.bufPrint(&buf, "{d}s", .{seconds}) catch unreachable,
        3 => std.fmt.bufPrint(&buf, "{d}.{d:0>3}s", .{ seconds, nanos / 1_000_000 }) catch unreachable,
        6 => std.fmt.bufPrint(&buf, "{d}.{d:0>6}s", .{ seconds, nanos / 1_000 }) catch unreachable,
        else => std.fmt.bufPrint(&buf, "{d}.{d:0>9}s", .{ seconds, nanos }) catch unreachable,
    };
    const kept_nanos: u64 = switch (digits_kept) {
        0 => 0,
        3 => nanos / 1_000_000 * 1_000_000,
        6 => nanos / 1_000 * 1_000,
        else => nanos,
    };
    const want = @min(seconds * 1000 + (kept_nanos + 999_999) / 1_000_000, std.math.maxInt(u32));
    try testing.expectEqual(@as(u32, @intCast(want)), durationMs(text).?);
    // And arbitrary text never crashes.
    _ = durationMs(g.rest());
}

test "fuzz durationMs: a plain model of seconds and nanoseconds, and arbitrary text" {
    try test_util.fuzzBytes({}, durationProperty, .{ .corpus = &.{ "", "\xff\xff\xff\xff\xff\xff\xff\xff\xff\xff\xff\xff\x03" } });
}

fn dateProperty(_: void, input: []const u8) !void {
    var g: test_util.ByteGen = .init(input);
    // Any second from 1950 to 2049, written in each format, reads back.
    const t: i64 = -631152000 + @as(i64, @intCast(g.intRange(u32, 0, 3155759999)));
    const days = @divFloor(t, std.time.s_per_day);
    const secs = @mod(t, std.time.s_per_day);
    const c = civilFromDays(days);
    const weekday: usize = @intCast(@mod(days + 3, 7)); // 1970-01-01 was a Thursday.
    var buf: [64]u8 = undefined;
    const hh = @divFloor(secs, 3600);
    const mm = @divFloor(@mod(secs, 3600), 60);
    const ss = @mod(secs, 60);
    const imf = std.fmt.bufPrint(&buf, "{s}, {d:0>2} {s} {d:0>4} {d:0>2}:{d:0>2}:{d:0>2} GMT", .{ day_names[weekday], @as(u64, @intCast(c.day)), months[@intCast(c.month - 1)], @as(u64, @intCast(c.year)), @as(u64, @intCast(hh)), @as(u64, @intCast(mm)), @as(u64, @intCast(ss)) }) catch unreachable;
    try testing.expectEqual(t, httpDate(imf).?);
    var buf2: [64]u8 = undefined;
    const rfc850 = std.fmt.bufPrint(&buf2, "{s}, {d:0>2}-{s}-{d:0>2} {d:0>2}:{d:0>2}:{d:0>2} GMT", .{ long_day_names[weekday], @as(u64, @intCast(c.day)), months[@intCast(c.month - 1)], @as(u64, @intCast(@mod(c.year, 100))), @as(u64, @intCast(hh)), @as(u64, @intCast(mm)), @as(u64, @intCast(ss)) }) catch unreachable;
    try testing.expectEqual(t, httpDate(rfc850).?);
    var buf3: [64]u8 = undefined;
    const asc = std.fmt.bufPrint(&buf3, "{s} {s} {d: >2} {d:0>2}:{d:0>2}:{d:0>2} {d:0>4}", .{ day_names[weekday], months[@intCast(c.month - 1)], @as(u64, @intCast(c.day)), @as(u64, @intCast(hh)), @as(u64, @intCast(mm)), @as(u64, @intCast(ss)), @as(u64, @intCast(c.year)) }) catch unreachable;
    try testing.expectEqual(t, httpDate(asc).?);
    _ = httpDate(g.rest());
}

/// The inverse of `daysFromCivil`, for the property alone.
fn civilFromDays(days: i64) struct { year: i64, month: i64, day: i64 } {
    const z = days + 719468;
    const era = @divFloor(z, 146097);
    const doe = z - era * 146097;
    const yoe = @divFloor(doe - @divFloor(doe, 1460) + @divFloor(doe, 36524) - @divFloor(doe, 146096), 365);
    const doy = doe - (365 * yoe + @divFloor(yoe, 4) - @divFloor(yoe, 100));
    const mp = @divFloor(5 * doy + 2, 153);
    const day = doy - @divFloor(153 * mp + 2, 5) + 1;
    const month = if (mp < 10) mp + 3 else mp - 9;
    return .{ .year = yoe + era * 400 + (if (month <= 2) @as(i64, 1) else 0), .month = month, .day = day };
}

test "fuzz httpDate: any second from 1950 to 2049 reads back in all three formats" {
    try test_util.fuzzBytes({}, dateProperty, .{ .corpus = &.{ "", "\xff\xff\xff\xff", "\x00\x00\x00\x00" } });
}

fn delayProperty(_: void, input: []const u8) !void {
    var arena: std.heap.ArenaAllocator = .init(std.heap.smp_allocator);
    defer arena.deinit();
    var g: test_util.ByteGen = .init(input);
    // Arbitrary headers and body: never a crash, and the answer is the
    // largest each source gives alone.
    var headers: [4]transport.Header = undefined;
    const n = g.intRange(usize, 0, headers.len);
    for (headers[0..n]) |*h| h.* = .{
        .name = g.pick([]const u8, &.{ "Retry-After", "retry-after-ms", "Date", "X-Other" }),
        .value = g.slice(40),
    };
    const body = g.rest();
    const now = at(1_792_255_951);
    const got = try serverDelayMs(arena.allocator(), headers[0..n], body, now);
    var want: ?u32 = try errors.decodeRetryDelayMs(arena.allocator(), body);
    const date = header(headers[0..n], "date");
    for (headers[0..n]) |h| {
        const one = if (std.mem.eql(u8, h.name, "Retry-After")) retryAfterMs(h.value, date, now) else if (std.mem.eql(u8, h.name, "retry-after-ms")) millisecondsMs(h.value) else null;
        want = larger(want, one);
    }
    try testing.expectEqual(want, got);
}

test "fuzz serverDelayMs: arbitrary headers and bodies, the largest of each source alone" {
    try test_util.fuzzBytes({}, delayProperty, .{ .corpus = &.{
        "",
        "\x02\x00\x033\x00\x00",
        "{\"error\":{\"details\":[{\"@type\":\"type.googleapis.com/google.rpc.RetryInfo\",\"retryDelay\":\"1.5s\"}]}}",
    } });
}
