//! A server's retry delay: how long a refused response asked its client to
//! wait before trying again. rest-core reads the headers (`Retry-After`, in
//! delay-seconds or as an HTTP-date, and `retry-after-ms`, which Google's
//! front end sends beside it); this adds `google.rpc.RetryInfo` in a JSON
//! error body's `details`, whose `retryDelay` is a Duration such as "30s"
//! or "0.830956646s". The largest valid one is kept, since each means "at
//! least this long".
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
const rest_core = @import("rest_core");
const transport = rest_core.transport;
const neutral = rest_core.retry_after;

const max_ms = std.math.maxInt(u32);

/// The delay a refused response asked for, in milliseconds, from its
/// headers, as rest-core reads them, and, when it is Google's JSON error
/// shape, its body; null when it asked for none. `received_at` is the wall
/// clock when it arrived.
pub fn serverDelayMs(arena: Allocator, headers: []const transport.Header, body: []const u8, received_at: std.Io.Timestamp) Allocator.Error!?u32 {
    return neutral.larger(neutral.serverDelayMs(transport.Header, headers, received_at), try errors.decodeRetryDelayMs(arena, body));
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
    try testing.checkAllAllocationFailures(std.testing.allocator, Run.run, .{});
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
    try testing.checkAllAllocationFailures(std.testing.allocator, Run.run, .{});
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

fn delayProperty(_: void, input: []const u8) !void {
    var arena: std.heap.ArenaAllocator = .init(std.heap.smp_allocator);
    defer arena.deinit();
    var g: test_util.ByteGen = .init(input);
    // Arbitrary headers and body: never a crash, and the answer is the
    // larger of what the headers ask and what the body does.
    var headers: [4]transport.Header = undefined;
    const n = g.intRange(usize, 0, headers.len);
    for (headers[0..n]) |*h| h.* = .{
        .name = g.pick([]const u8, &.{ "Retry-After", "retry-after-ms", "Date", "X-Other" }),
        .value = g.slice(40),
    };
    const body = g.rest();
    const now = at(1_792_255_951);
    const got = try serverDelayMs(arena.allocator(), headers[0..n], body, now);
    const want = neutral.larger(
        neutral.serverDelayMs(transport.Header, headers[0..n], now),
        try errors.decodeRetryDelayMs(arena.allocator(), body),
    );
    try testing.expectEqual(want, got);
}

test "fuzz serverDelayMs: arbitrary headers and bodies, the largest of each source alone" {
    try test_util.fuzzBytes({}, delayProperty, .{ .corpus = &.{
        "",
        "\x02\x00\x033\x00\x00",
        "{\"error\":{\"details\":[{\"@type\":\"type.googleapis.com/google.rpc.RetryInfo\",\"retryDelay\":\"1.5s\"}]}}",
    } });
}
