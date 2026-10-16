//! Answers production gave on 2026-10-16, measured in milestone 0 of the
//! Logging spec (`_tmp/logging-m0/`), for tests: the probe's own `zigps-`
//! entries and refusals, verbatim but for a final line break. Test code only.

/// A page of the probe's own entries, oldest first: text, JSON, labels with escapes, nanoseconds, none. HTTP 200.
pub const readback_page_status = 200;
pub const readback_page =
    \\{"entries":[{"textPayload":"entry 1","insertId":"a1","resource":{"type":"global","labels":{"project_id":"extractctl"}},"timestamp":"2026-10-16T21:44:34.537032Z","logName":"projects/extractctl/logs/zigps-m0-64e74c43","receiveTimestamp":"2026-10-16T21:45:33.621611426Z"},{"textPayload":"entry 2","insertId":"a2","resource":{"type":"global","labels":{"project_id":"extractctl"}},"timestamp":"2026-10-16T21:44:35.537032Z","logName":"projects/extractctl/logs/zigps-m0-64e74c43","receiveTimestamp":"2026-10-16T21:45:33.621611426Z"},{"textPayload":"entry 3","insertId":"a3","resource":{"type":"global","labels":{"project_id":"extractctl"}},"timestamp":"2026-10-16T21:44:36.537032Z","logName":"projects/extractctl/logs/zigps-m0-64e74c43","receiveTimestamp":"2026-10-16T21:45:33.621611426Z"},{"textPayload":"entry 4","insertId":"a4","resource":{"type":"global","labels":{"project_id":"extractctl"}},"timestamp":"2026-10-16T21:44:37.537032Z","logName":"projects/extractctl/logs/zigps-m0-64e74c43","receiveTimestamp":"2026-10-16T21:45:33.621611426Z"},{"textPayload":"entry 5","insertId":"a5","resource":{"type":"global","labels":{"project_id":"extractctl"}},"timestamp":"2026-10-16T21:44:38.537032Z","logName":"projects/extractctl/logs/zigps-m0-64e74c43","receiveTimestamp":"2026-10-16T21:45:33.621611426Z"},{"textPayload":"escapes","insertId":"esc","resource":{"type":"global","labels":{"project_id":"extractctl"}},"timestamp":"2026-10-16T21:44:40.537032Z","labels":{"q":"a\"b\\c\td é x"},"logName":"projects/extractctl/logs/zigps-m0-64e74c43","receiveTimestamp":"2026-10-16T21:45:33.621611426Z"},{"textPayload":"nanoseconds","insertId":"ns","resource":{"type":"global","labels":{"project_id":"extractctl"}},"timestamp":"2026-10-16T21:44:41.123456789Z","logName":"projects/extractctl/logs/zigps-m0-64e74c43","receiveTimestamp":"2026-10-16T21:45:33.621611426Z"},{"insertId":"json","jsonPayload":{"big":1.2345678901234567e+19,"s":"Value","exact":0.1,"n":7},"resource":{"type":"global","labels":{"project_id":"extractctl"}},"timestamp":"2026-10-16T21:44:42.537032Z","logName":"projects/extractctl/logs/zigps-m0-64e74c43","receiveTimestamp":"2026-10-16T21:45:33.621611426Z"},{"textPayload":"MixedCase Été","insertId":"CaseID","resource":{"type":"global","labels":{"project_id":"extractctl"}},"timestamp":"2026-10-16T21:44:43.537032Z","logName":"projects/extractctl/logs/zigps-m0-64e74c43","receiveTimestamp":"2026-10-16T21:45:33.621611426Z"},{"textPayload":"dup in a","insertId":"dup","resource":{"type":"global","labels":{"project_id":"extractctl"}},"timestamp":"2026-10-16T21:44:44.537032Z","logName":"projects/extractctl/logs/zigps-m0-64e74c43","receiveTimestamp":"2026-10-16T21:45:33.621611426Z"},{"insertId":"nopayload","resource":{"type":"global","labels":{"project_id":"extractctl"}},"timestamp":"2026-10-16T21:44:45.537032Z","logName":"projects/extractctl/logs/zigps-m0-64e74c43","receiveTimestamp":"2026-10-16T21:45:33.621611426Z"}]}
;

/// `resourceNames: ["projects"]`. HTTP 400.
pub const refused_name_status = 400;
pub const refused_name =
    \\{
    \\  "error": {
    \\    "code": 400,
    \\    "message": "Name \"projects\" is missing the parent component. Expected the form projects/[PROJECT_ID]",
    \\    "status": "INVALID_ARGUMENT",
    \\    "details": [
    \\      {
    \\        "@type": "type.googleapis.com/google.rpc.ErrorInfo",
    \\        "reason": "QUERY_INVALID_RESOURCE_NAME",
    \\        "domain": "logging.googleapis.com",
    \\        "metadata": {
    \\          "resource": "projects"
    \\        }
    \\      }
    \\    ]
    \\  }
    \\}
;

/// 101 resource names. HTTP 400.
pub const refused_101_names_status = 400;
pub const refused_101_names =
    \\{
    \\  "error": {
    \\    "code": 400,
    \\    "message": "Request exceeds maximum number of resource names.",
    \\    "status": "INVALID_ARGUMENT",
    \\    "details": [
    \\      {
    \\        "@type": "type.googleapis.com/google.rpc.ErrorInfo",
    \\        "reason": "QUERY_TOO_MANY_RESOURCES",
    \\        "domain": "logging.googleapis.com",
    \\        "metadata": {
    \\          "max_resources": "100",
    \\          "num_resources": "101"
    \\        }
    \\      }
    \\    ]
    \\  }
    \\}
;

/// No resource names. HTTP 400.
pub const refused_no_names_status = 400;
pub const refused_no_names =
    \\{
    \\  "error": {
    \\    "code": 400,
    \\    "message": "At least one resource name is needed.",
    \\    "status": "INVALID_ARGUMENT"
    \\  }
    \\}
;

/// A token production did not issue. HTTP 400.
pub const refused_token_status = 400;
pub const refused_token =
    \\{
    \\  "error": {
    \\    "code": 400,
    \\    "message": "Invalid page_token",
    \\    "status": "INVALID_ARGUMENT"
    \\  }
    \\}
;

/// A token sent with another filter. HTTP 400.
pub const refused_token_filter_status = 400;
pub const refused_token_filter =
    \\{
    \\  "error": {
    \\    "code": 400,
    \\    "message": "page_token doesn't match arguments from the request",
    \\    "status": "INVALID_ARGUMENT"
    \\  }
    \\}
;

/// `pageSize: -1`. HTTP 400.
pub const refused_page_size_status = 400;
pub const refused_page_size =
    \\{
    \\  "error": {
    \\    "code": 400,
    \\    "message": "page_size must not be negative",
    \\    "status": "INVALID_ARGUMENT"
    \\  }
    \\}
;

/// `orderBy: "timestamp DESC"`. HTTP 400.
pub const refused_order_status = 400;
pub const refused_order =
    \\{
    \\  "error": {
    \\    "code": 400,
    \\    "message": "order_by must be \"asc\" or \"desc\"",
    \\    "status": "INVALID_ARGUMENT"
    \\  }
    \\}
;

/// `orderBy: "insertId"`. HTTP 400.
pub const refused_order_field_status = 400;
pub const refused_order_field =
    \\{
    \\  "error": {
    \\    "code": 400,
    \\    "message": "order_by must be on timestamp",
    \\    "status": "INVALID_ARGUMENT"
    \\  }
    \\}
;

/// The filter `thud = 1`. HTTP 400.
pub const refused_unknown_field_status = 400;
pub const refused_unknown_field =
    \\{
    \\  "error": {
    \\    "code": 400,
    \\    "message": "Field not found: 'thud'.",
    \\    "status": "INVALID_ARGUMENT"
    \\  }
    \\}
;

/// The filter `AND insertId = x`. HTTP 400.
pub const refused_syntax_status = 400;
pub const refused_syntax =
    \\{
    \\  "error": {
    \\    "code": 400,
    \\    "message": "Unparseable filter: syntax error at line 1, column 4, token ' '",
    \\    "status": "INVALID_ARGUMENT"
    \\  }
    \\}
;

/// The 63rd quick call. HTTP 429.
pub const refused_quota_status = 429;
pub const refused_quota =
    \\{
    \\  "error": {
    \\    "code": 429,
    \\    "message": "Quota exceeded for quota metric 'Read requests' and limit 'Read requests per minute' of service 'logging.googleapis.com' for consumer 'project_number:82150720798'.",
    \\    "status": "RESOURCE_EXHAUSTED",
    \\    "details": [
    \\      {
    \\        "@type": "type.googleapis.com/google.rpc.ErrorInfo",
    \\        "reason": "RATE_LIMIT_EXCEEDED",
    \\        "domain": "googleapis.com",
    \\        "metadata": {
    \\          "quota_location": "global",
    \\          "consumer": "projects/82150720798",
    \\          "service": "logging.googleapis.com",
    \\          "quota_unit": "1/min/{project}",
    \\          "quota_metric": "logging.googleapis.com/read_requests",
    \\          "quota_limit": "ReadRequestsPerMinutePerProject",
    \\          "window_start_time": "1792187613",
    \\          "quota_limit_value": "60"
    \\        }
    \\      },
    \\      {
    \\        "@type": "type.googleapis.com/google.rpc.Help",
    \\        "links": [
    \\          {
    \\            "description": "Request a higher quota limit.",
    \\            "url": "https://cloud.google.com/docs/quotas/help/request_increase"
    \\          }
    \\        ]
    \\      }
    \\    ]
    \\  }
    \\}
;

/// A project that does not exist. HTTP 404.
pub const not_found_project_status = 404;
pub const not_found_project =
    \\{
    \\  "error": {
    \\    "code": 404,
    \\    "message": "projects/zigps-no-such-project-8c1f does not exist",
    \\    "status": "NOT_FOUND",
    \\    "details": [
    \\      {
    \\        "@type": "type.googleapis.com/google.rpc.ErrorInfo",
    \\        "reason": "QUERY_INVALID_RESOURCE_NAME",
    \\        "domain": "logging.googleapis.com",
    \\        "metadata": {
    \\          "resource": "projects/zigps-no-such-project-8c1f"
    \\        }
    \\      }
    \\    ]
    \\  }
    \\}
;

/// A view that does not exist. HTTP 404.
pub const not_found_view_status = 404;
pub const not_found_view =
    \\{
    \\  "error": {
    \\    "code": 404,
    \\    "message": "projects/extractctl/locations/global/buckets/_Default/views/zigps-none does not exist",
    \\    "status": "NOT_FOUND"
    \\  }
    \\}
;

/// A filter with no time bound, ascending: the server ran out of time. HTTP 200.
pub const searching_status = 200;
pub const searching =
    \\{"nextPageToken":"ep0BCpgBAdjKCLpWPoVEPPMkdeoYVoX4AMGaf3DFl0QRHpe4lxxJoQoI9cAKlrp6Qs6oSKHPk5VqcmpA1Q8qqBndawK4-QuQBJFtlLpNdgDOkSWr16ppDgXtVipwToCZVZeGoKI4bPvYML6WCru5MOSfYL-eFWIHoqN33lODT_cNKqVG2Vi63ElVp_ERKRxRYzq62z2zt9puMFDpNAkQAA"}
;

const std = @import("std");
const core = @import("core");
const codec = @import("codec.zig");
const test_util = @import("test_util.zig");
const FakeLogging = @import("fake_logging.zig").FakeLogging;
const testing = std.testing;

test "production: a page of the probe's own entries decodes field by field" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const page = try codec.decodeEntryPage(arena.allocator(), readback_page);
    try testing.expectEqual(null, page.next_page_token);
    try testing.expectEqual(11, page.entries.len);
    const first = page.entries[0];
    try testing.expectEqualStrings("a1", first.insert_id);
    try testing.expectEqualStrings("entry 1", first.payload.text);
    try testing.expectEqualStrings("zigps-m0-64e74c43", first.log_id);
    // Production fills in `project_id` for a global resource.
    try testing.expectEqualStrings("global", first.resource_type);
    try testing.expectEqualStrings("project_id", first.resource_labels[0].key);
    try testing.expectEqualStrings("extractctl", first.resource_labels[0].value);
    try testing.expectEqual(.default, first.severity);
    try testing.expect(first.receive_timestamp != null);
    var seen: usize = 0;
    for (page.entries) |e| {
        if (std.mem.eql(u8, e.insert_id, "esc")) {
            try testing.expectEqualStrings("a\"b\\c\td \u{e9} x", e.labels[0].value);
            seen += 1;
        } else if (std.mem.eql(u8, e.insert_id, "ns")) {
            try testing.expectEqual(123_456_789, @mod(e.timestamp.nanoseconds, std.time.ns_per_s));
            seen += 1;
        } else if (std.mem.eql(u8, e.insert_id, "json")) {
            // Production keeps JSON payloads as doubles and writes them
            // its own way: 12345678901234567890 came back so.
            try testing.expectEqualStrings("{\"big\":1.2345678901234567e+19,\"s\":\"Value\",\"exact\":0.1,\"n\":7}", e.payload.json);
            seen += 1;
        } else if (std.mem.eql(u8, e.insert_id, "nopayload")) {
            try testing.expect(e.payload == .none);
            seen += 1;
        } else if (std.mem.eql(u8, e.insert_id, "CaseID")) {
            try testing.expectEqualStrings("MixedCase \u{c9}t\u{e9}", e.payload.text);
            seen += 1;
        }
    }
    try testing.expectEqual(5, seen);
}

test "production: the server running out of time is an empty page with a token" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const page = try codec.decodeEntryPage(arena.allocator(), searching);
    try testing.expectEqual(0, page.entries.len);
    try testing.expect(page.next_page_token.?.len > 100);
}

test "production: each refusal maps to its error, and none is tried again" {
    const cases = [_]struct { u16, []const u8, anyerror }{
        .{ refused_unknown_field_status, refused_unknown_field, error.InvalidFilter },
        .{ refused_syntax_status, refused_syntax, error.InvalidFilter },
        .{ refused_token_status, refused_token, error.InvalidPageToken },
        .{ refused_token_filter_status, refused_token_filter, error.InvalidPageToken },
        .{ refused_name_status, refused_name, error.InvalidArgument },
        .{ refused_101_names_status, refused_101_names, error.InvalidArgument },
        .{ refused_no_names_status, refused_no_names, error.InvalidArgument },
        .{ refused_page_size_status, refused_page_size, error.InvalidArgument },
        .{ refused_order_status, refused_order, error.InvalidArgument },
        .{ refused_order_field_status, refused_order_field, error.InvalidArgument },
        .{ not_found_project_status, not_found_project, error.NotFound },
        .{ not_found_view_status, not_found_view, error.NotFound },
    };
    for (cases) |case| {
        var h: test_util.Harness = undefined;
        try h.init(&.{.{ .respond = .{ .status = case[0], .body = case[1] } }}, .{});
        defer h.deinit();
        var q = try h.client.query(.{});
        defer q.deinit();
        try testing.expectError(case[2], q.page(null));
        try h.expectRequestCount(1);
    }
}

test "production: a 429 holds calls back until the quota window it names ends" {
    var h: test_util.Harness = undefined;
    try h.init(&.{.{ .respond = .{ .status = refused_quota_status, .body = refused_quota } }}, .{});
    defer h.deinit();
    // The body's window began at 1792187613; 50 s into it, 10 s are left.
    h.clock.now_ns = (1_792_187_613 + 50) * std.time.ns_per_s;
    var q = try h.client.query(.{});
    defer q.deinit();
    try testing.expectError(error.ResourceExhausted, q.page(null));
    try testing.expectEqual(10_000, h.client.readBudget().next_free_ms);
    // Long past the window, a second still.
    var late: test_util.Harness = undefined;
    try late.init(&.{.{ .respond = .{ .status = refused_quota_status, .body = refused_quota } }}, .{});
    defer late.deinit();
    late.clock.now_ns = (1_792_187_613 + 3600) * std.time.ns_per_s;
    var q2 = try late.client.query(.{});
    defer q2.deinit();
    try testing.expectError(error.ResourceExhausted, q2.page(null));
    try testing.expectEqual(1_000, late.client.readBudget().next_free_ms);
    // A 429 that names no window: 5 s.
    var plain: test_util.Harness = undefined;
    try plain.init(&.{.{ .respond = .{ .status = 429, .body = "{\"error\":{\"code\":429,\"status\":\"RESOURCE_EXHAUSTED\"}}" } }}, .{});
    defer plain.deinit();
    var q3 = try plain.client.query(.{});
    defer q3.deinit();
    try testing.expectError(error.ResourceExhausted, q3.page(null));
    try testing.expectEqual(5_000, plain.client.readBudget().next_free_ms);
}

/// The fake's answer to `body`, and production's, agree on status,
/// message and any `ErrorInfo`.
fn expectFakeSays(fake: *FakeLogging, body: []const u8, status: u16, production: []const u8) !void {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const reply = try fake.serve(.POST, "https://logging.googleapis.com/v2/entries:list", body, a);
    try testing.expectEqual(status, reply.status);
    const ours = (try core.errors.decodeErrorBody(a, reply.body)).?;
    const theirs = (try core.errors.decodeErrorBody(a, production)).?;
    try testing.expectEqualStrings(theirs.status, ours.status);
    try testing.expectEqualStrings(theirs.message, ours.message);
    const our_infos = try core.errors.decodeErrorInfos(a, reply.body);
    const their_infos = try core.errors.decodeErrorInfos(a, production);
    try testing.expectEqual(their_infos.len, our_infos.len);
    for (their_infos, our_infos) |t, o| {
        try testing.expectEqualStrings(t.reason, o.reason);
        try testing.expectEqualStrings(t.domain, o.domain);
        try testing.expectEqual(t.metadata.len, o.metadata.len);
        for (t.metadata) |tm| {
            for (o.metadata) |om| {
                if (std.mem.eql(u8, tm.key, om.key)) {
                    try testing.expectEqualStrings(tm.value, om.value);
                    break;
                }
            } else return error.TestMissingMetadata;
        }
    }
}

test "production: the fake refuses what production refused, in its words" {
    var clock: test_util.FakeClock = .{};
    var fake: FakeLogging = .init(testing.allocator, clock.io());
    defer fake.deinit();
    try expectFakeSays(&fake, "{\"resourceNames\":[\"projects\"]}", refused_name_status, refused_name);
    try expectFakeSays(&fake, "{}", refused_no_names_status, refused_no_names);
    try expectFakeSays(&fake, "{\"resourceNames\":[\"projects/p\"],\"pageToken\":\"bm90LWEtdG9rZW4\"}", refused_token_status, refused_token);
    try expectFakeSays(&fake, "{\"resourceNames\":[\"projects/p\"],\"pageSize\":-1}", refused_page_size_status, refused_page_size);
    try expectFakeSays(&fake, "{\"resourceNames\":[\"projects/p\"],\"orderBy\":\"timestamp DESC\"}", refused_order_status, refused_order);
    try expectFakeSays(&fake, "{\"resourceNames\":[\"projects/p\"],\"orderBy\":\"insertId\"}", refused_order_field_status, refused_order_field);
    try expectFakeSays(&fake, "{\"resourceNames\":[\"projects/p\"],\"filter\":\"thud = 1\"}", refused_unknown_field_status, refused_unknown_field);
    try expectFakeSays(&fake, "{\"resourceNames\":[\"projects/p\"],\"filter\":\"AND insertId = x\"}", refused_syntax_status, refused_syntax);
    var names: std.Io.Writer.Allocating = .init(testing.allocator);
    defer names.deinit();
    try names.writer.writeAll("{\"resourceNames\":[");
    for (0..101) |i| try names.writer.print("{s}\"projects/extractctl\"", .{if (i == 0) "" else ","});
    try names.writer.writeAll("]}");
    try expectFakeSays(&fake, names.written(), refused_101_names_status, refused_101_names);
    fake.refuseNext(1, 429);
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const quota = try fake.serve(.POST, "https://logging.googleapis.com/v2/entries:list", "{\"resourceNames\":[\"projects/p\"]}", arena.allocator());
    try testing.expectEqualStrings((try core.errors.decodeErrorBody(arena.allocator(), refused_quota)).?.message, (try core.errors.decodeErrorBody(arena.allocator(), quota.body)).?.message);
}
