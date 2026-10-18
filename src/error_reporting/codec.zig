//! JSON in: pages of group stats and of events, and groups; JSON out: a
//! group to put back. A body is parsed into a `std.json.Value` in a scratch
//! arena and read from there, every string copied into the result's arena,
//! so the response can go when the result is made. Every field is optional
//! but a group's name and id, `null` counts as absent (the proto3 JSON
//! rule), unknown fields are ignored (the service has fields its proto does
//! not publish), counts are read from a string or a number, as int64s
//! travel as strings, and a status from a name or a number, as a client
//! that asks for `enum-encoding=int` gets it.

const std = @import("std");
const Allocator = std.mem.Allocator;
const Value = std.json.Value;
const core = @import("core");
const types = @import("types.zig");

pub const DecodeError = error{ InvalidResponse, OutOfMemory };

/// A page of `groupStats.list`: `{}` is an empty last page.
pub fn decodeGroupStatsPage(out: Allocator, scratch: Allocator, body: []const u8) DecodeError!types.GroupStatsPage {
    const obj = try object(try parse(scratch, body));
    const list = try field(obj, "errorGroupStats", .array);
    const items = try out.alloc(types.GroupStats, if (list) |l| l.items.len else 0);
    if (list) |l| for (l.items, items) |v, *s| {
        s.* = try groupStats(out, v);
    };
    return .{ .items = items, .next_page_token = try token(out, obj), .time_range_begin = try time(obj, "timeRangeBegin") };
}

/// A page of `events.list`: `{}` is an empty last page.
pub fn decodeEventPage(out: Allocator, scratch: Allocator, body: []const u8) DecodeError!types.EventPage {
    const obj = try object(try parse(scratch, body));
    const list = try field(obj, "errorEvents", .array);
    const items = try out.alloc(types.Event, if (list) |l| l.items.len else 0);
    if (list) |l| for (l.items, items) |v, *e| {
        e.* = try event(out, v);
    };
    return .{ .items = items, .next_page_token = try token(out, obj), .time_range_begin = try time(obj, "timeRangeBegin") };
}

/// A group, as `groups.get` and `groups.update` answer.
pub fn decodeGroup(out: Allocator, scratch: Allocator, body: []const u8) DecodeError!types.Group {
    return group(out, try parse(scratch, body));
}

/// `group` as `groups.update` takes it, the whole group with `status`:
/// a PUT replaces what it leaves out, so the tracking issues go back too.
pub fn encodeGroup(arena: Allocator, g: types.Group, new_status: types.Status) Allocator.Error![]u8 {
    var out: std.Io.Writer.Allocating = .init(arena);
    var jw: std.json.Stringify = .{ .writer = &out.writer };
    writeGroup(&jw, g, new_status) catch return error.OutOfMemory;
    return out.toOwnedSlice();
}

fn writeGroup(jw: *std.json.Stringify, g: types.Group, new_status: types.Status) std.json.Stringify.Error!void {
    try jw.beginObject();
    try jw.objectField("name");
    try jw.write(g.name);
    try jw.objectField("groupId");
    try jw.write(g.id);
    if (g.tracking_issues.len > 0) {
        try jw.objectField("trackingIssues");
        try jw.beginArray();
        for (g.tracking_issues) |issue| {
            try jw.beginObject();
            try jw.objectField("url");
            try jw.write(issue.url);
            try jw.endObject();
        }
        try jw.endArray();
    }
    try jw.objectField("resolutionStatus");
    try jw.write(new_status.wire());
    try jw.endObject();
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

/// `nextPageToken`: absent or "" ends the query.
fn token(out: Allocator, obj: std.json.ObjectMap) DecodeError!?[]const u8 {
    const t = try field(obj, "nextPageToken", .string) orelse return null;
    if (t.len == 0) return null;
    return try out.dupe(u8, t);
}

fn time(obj: std.json.ObjectMap, name: []const u8) DecodeError!?std.Io.Timestamp {
    const text = try field(obj, name, .string) orelse return null;
    return core.timestamp.parse(text) catch error.InvalidResponse;
}

/// An integer that may arrive as a string, as int64s do, or as a number.
fn integer(comptime T: type, obj: std.json.ObjectMap, name: []const u8) DecodeError!?T {
    const v = obj.get(name) orelse return null;
    const text = switch (v) {
        .null => return null,
        .string, .number_string => |s| s,
        else => return error.InvalidResponse,
    };
    return std.fmt.parseInt(T, text, 10) catch error.InvalidResponse;
}

fn status(obj: std.json.ObjectMap) DecodeError!types.Status {
    const v = obj.get("resolutionStatus") orelse return .open;
    return switch (v) {
        .null => .open,
        .string => |s| types.Status.fromWire(s),
        .number_string => |s| if (std.fmt.parseInt(i64, s, 10)) |n| types.Status.fromNumber(n) else |_| .unknown,
        else => error.InvalidResponse,
    };
}

fn group(out: Allocator, v: Value) DecodeError!types.Group {
    const obj = try object(v);
    const name = try string(out, obj, "name") orelse return error.InvalidResponse;
    const id = try string(out, obj, "groupId") orelse return error.InvalidResponse;
    const list = try field(obj, "trackingIssues", .array);
    const issues = try out.alloc(types.TrackingIssue, if (list) |l| l.items.len else 0);
    if (list) |l| for (l.items, issues) |item, *issue| {
        issue.* = .{ .url = try string(out, try object(item), "url") orelse "" };
    };
    return .{ .name = name, .id = id, .status = try status(obj), .tracking_issues = issues };
}

fn service(out: Allocator, v: Value) DecodeError!types.ServiceContext {
    const obj = try object(v);
    return .{
        .service = try string(out, obj, "service"),
        .version = try string(out, obj, "version"),
        .resource_type = try string(out, obj, "resourceType"),
    };
}

fn timedCount(v: Value) DecodeError!types.TimedCount {
    const obj = try object(v);
    return .{
        .start = try time(obj, "startTime") orelse return error.InvalidResponse,
        .end = try time(obj, "endTime") orelse return error.InvalidResponse,
        // Production leaves out an empty bucket's count.
        .count = try integer(u64, obj, "count") orelse 0,
    };
}

fn groupStats(out: Allocator, v: Value) DecodeError!types.GroupStats {
    const obj = try object(v);
    const group_value = obj.get("group") orelse return error.InvalidResponse;
    const counts = try field(obj, "timedCounts", .array);
    const timed = try out.alloc(types.TimedCount, if (counts) |c| c.items.len else 0);
    if (counts) |c| for (c.items, timed) |item, *t| {
        t.* = try timedCount(item);
    };
    const services = try field(obj, "affectedServices", .array);
    const affected = try out.alloc(types.ServiceContext, if (services) |s| s.items.len else 0);
    if (services) |s| for (s.items, affected) |item, *a| {
        a.* = try service(out, item);
    };
    return .{
        .group = try group(out, group_value),
        .count = try integer(u64, obj, "count") orelse 0,
        .affected_users = try integer(u64, obj, "affectedUsersCount") orelse 0,
        .timed_counts = timed,
        .first_seen = try time(obj, "firstSeenTime"),
        .last_seen = try time(obj, "lastSeenTime"),
        .affected_services = affected,
        .affected_service_count = try integer(u32, obj, "numAffectedServices") orelse 0,
        .representative = if (obj.get("representative")) |r| if (r == .null) null else try event(out, r) else null,
    };
}

fn event(out: Allocator, v: Value) DecodeError!types.Event {
    const obj = try object(v);
    return .{
        .time = try time(obj, "eventTime"),
        .service = if (obj.get("serviceContext")) |s| if (s == .null) .{} else try service(out, s) else .{},
        .message = try string(out, obj, "message") orelse "",
        .context = if (obj.get("context")) |c| if (c == .null) .{} else try context(out, c) else .{},
    };
}

fn context(out: Allocator, v: Value) DecodeError!types.ErrorContext {
    const obj = try object(v);
    const refs = try field(obj, "sourceReferences", .array);
    const references = try out.alloc(types.SourceReference, if (refs) |r| r.items.len else 0);
    if (refs) |r| for (r.items, references) |item, *ref| {
        const o = try object(item);
        ref.* = .{ .repository = try string(out, o, "repository"), .revision_id = try string(out, o, "revisionId") };
    };
    return .{
        .http_request = if (try field(obj, "httpRequest", .object)) |h| .{
            .method = try string(out, h, "method"),
            .url = try string(out, h, "url"),
            .user_agent = try string(out, h, "userAgent"),
            .referrer = try string(out, h, "referrer"),
            .response_status_code = try integer(i32, h, "responseStatusCode"),
            .remote_ip = try string(out, h, "remoteIp"),
        } else null,
        .user = try string(out, obj, "user"),
        .report_location = if (try field(obj, "reportLocation", .object)) |l| .{
            .file_path = try string(out, l, "filePath"),
            .line_number = try integer(i32, l, "lineNumber"),
            .function_name = try string(out, l, "functionName"),
        } else null,
        .source_references = references,
    };
}

const testing = std.testing;
const bodies = @import("production_bodies.zig");

/// Decodes `body` with `decode` into an arena the caller frees.
fn decoded(comptime T: type, comptime decode: fn (Allocator, Allocator, []const u8) DecodeError!T, body: []const u8) !struct { arena: std.heap.ArenaAllocator, value: T } {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    errdefer arena.deinit();
    var scratch: std.heap.ArenaAllocator = .init(testing.allocator);
    defer scratch.deinit();
    const value = try decode(arena.allocator(), scratch.allocator(), body);
    return .{ .arena = arena, .value = value };
}

fn expectTime(text: []const u8, got: ?std.Io.Timestamp) !void {
    try testing.expectEqual((try core.timestamp.parse(text)).nanoseconds, got.?.nanoseconds);
}

test "production's group stats: every field, counts from strings, the representative" {
    var d = try decoded(types.GroupStatsPage, decodeGroupStatsPage, bodies.group_stats_30_days);
    defer d.arena.deinit();
    const page = d.value;
    try testing.expectEqual(2, page.items.len);
    try testing.expectEqual(null, page.next_page_token);
    try expectTime("2026-09-18T01:34:57Z", page.time_range_begin);
    const s = page.items[0];
    try testing.expectEqualStrings("projects/extractctl/groups/COiYvODSyMz2Bg", s.group.name);
    try testing.expectEqualStrings("COiYvODSyMz2Bg", s.group.id);
    try testing.expectEqual(.open, s.group.status);
    try testing.expectEqual(0, s.group.tracking_issues.len);
    try testing.expectEqual(6, s.count);
    try testing.expectEqual(3, s.affected_users);
    try testing.expectEqual(0, s.timed_counts.len);
    try expectTime("2026-10-18T01:28:29.345667Z", s.first_seen);
    try expectTime("2026-10-18T01:28:29Z", s.last_seen);
    try testing.expectEqual(1, s.affected_services.len);
    try testing.expectEqualStrings("zigps-er-f2e07a-a", s.affected_services[0].service.?);
    try testing.expectEqualStrings("v1", s.affected_services[0].version.?);
    try testing.expectEqualStrings("reported_errors", s.affected_services[0].resource_type.?);
    try testing.expectEqual(1, s.affected_service_count);
    const r = s.representative.?;
    try testing.expectEqualStrings("ValueError: order has no lines", r.headline());
    try testing.expectEqualStrings("zigps-er-f2e07a-a", r.service.service.?);
    try testing.expect(std.mem.startsWith(u8, r.message, "Traceback (most recent call last):\n"));
    try testing.expectEqualStrings("GET", r.context.http_request.?.method.?);
    try testing.expectEqual(500, r.context.http_request.?.response_status_code.?);
    try testing.expect(r.context.user != null);
    try testing.expectEqualStrings("java.lang.NullPointerException: customer is null", page.items[1].representative.?.headline());
}

test "production's timed counts: every bucket, an empty one with no count, at the end or rounded" {
    {
        var d = try decoded(types.GroupStatsPage, decodeGroupStatsPage, bodies.group_stats_timed_end);
        defer d.arena.deinit();
        const timed = d.value.items[0].timed_counts;
        try testing.expectEqual(6, timed.len);
        const want = [_]u64{ 0, 2, 0, 1, 1, 2 };
        for (timed, want) |t, n| {
            try testing.expectEqual(n, t.count);
            try testing.expectEqual(3600 * std.time.ns_per_s, t.end.nanoseconds - t.start.nanoseconds);
        }
        try expectTime("2026-10-17T19:34:49Z", timed[0].start);
        try expectTime("2026-10-18T01:34:49Z", timed[5].end);
    }
    {
        var d = try decoded(types.GroupStatsPage, decodeGroupStatsPage, bodies.group_stats_timed_rounded);
        defer d.arena.deinit();
        const timed = d.value.items[0].timed_counts;
        try testing.expectEqual(7, timed.len);
        try expectTime("2026-10-17T19:34:50Z", timed[0].start);
        try expectTime("2026-10-17T20:00:00Z", timed[0].end);
        try expectTime("2026-10-18T01:00:00Z", timed[6].start);
        try expectTime("2026-10-18T01:34:50Z", timed[6].end);
        var total: u64 = 0;
        for (timed) |t| total += t.count;
        try testing.expectEqual(d.value.items[0].count, total);
    }
}

test "production's events: newest first, each with its context; a page token" {
    {
        var d = try decoded(types.EventPage, decodeEventPage, bodies.events_page);
        defer d.arena.deinit();
        const events = d.value.items;
        try testing.expectEqual(6, events.len);
        for (events[0 .. events.len - 1], events[1..]) |a, b| try testing.expect(a.time.?.nanoseconds > b.time.?.nanoseconds);
        try testing.expectEqualStrings("/zigps/py", events[0].context.http_request.?.url.?);
        try testing.expectEqualStrings("user-0", events[0].context.user.?);
        try testing.expectEqualStrings("ValueError: order has no lines", events[0].headline());
        try expectTime("2026-09-18T01:34:48Z", d.value.time_range_begin);
    }
    {
        var d = try decoded(types.EventPage, decodeEventPage, bodies.events_page_with_token);
        defer d.arena.deinit();
        try testing.expectEqual(2, d.value.items.len);
        try testing.expect(d.value.next_page_token != null);
    }
    {
        var d = try decoded(types.GroupStatsPage, decodeGroupStatsPage, bodies.group_stats_page_1);
        defer d.arena.deinit();
        try testing.expectEqualStrings("EicxMDEwODQxMzg5NjIwNDQ3NzQwNjE3OTIyOTA5Nzg3MzUzMjgwODQ=", d.value.next_page_token.?);
    }
}

test "production's groups: a status by name or number, tracking issues" {
    {
        var d = try decoded(types.Group, decodeGroup, bodies.group_get);
        defer d.arena.deinit();
        try testing.expectEqualStrings("COiYvODSyMz2Bg", d.value.id);
        try testing.expectEqual(.open, d.value.status);
    }
    {
        var d = try decoded(types.Group, decodeGroup, bodies.group_with_issue);
        defer d.arena.deinit();
        try testing.expectEqual(.acknowledged, d.value.status);
        try testing.expectEqual(1, d.value.tracking_issues.len);
        try testing.expectEqualStrings("https://example.com/issues/zigps-2", d.value.tracking_issues[0].url);
    }
    {
        var d = try decoded(types.Group, decodeGroup, bodies.group_int_enums);
        defer d.arena.deinit();
        try testing.expectEqual(.open, d.value.status);
    }
}

test "encodeGroup: the whole group, its issues kept, with the new status" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try testing.expectEqualStrings(
        "{\"name\":\"projects/p/groups/G1\",\"groupId\":\"G1\",\"trackingIssues\":[{\"url\":\"https://example.com/1\"},{\"url\":\"https://example.com/\\\"2\\\"\"}],\"resolutionStatus\":\"RESOLVED\"}",
        try encodeGroup(a, .{ .name = "projects/p/groups/G1", .id = "G1", .tracking_issues = &.{ .{ .url = "https://example.com/1" }, .{ .url = "https://example.com/\"2\"" } } }, .resolved),
    );
    try testing.expectEqualStrings(
        "{\"name\":\"projects/p/groups/G1\",\"groupId\":\"G1\",\"resolutionStatus\":\"MUTED\"}",
        try encodeGroup(a, .{ .name = "projects/p/groups/G1", .id = "G1" }, .muted),
    );
    // What it writes, it reads back.
    var scratch: std.heap.ArenaAllocator = .init(testing.allocator);
    defer scratch.deinit();
    const g = try decodeGroup(a, scratch.allocator(), try encodeGroup(a, .{ .name = "n", .id = "i", .tracking_issues = &.{.{ .url = "u" }} }, .acknowledged));
    try testing.expectEqual(.acknowledged, g.status);
    try testing.expectEqualStrings("u", g.tracking_issues[0].url);
}

test "an event's source references and report location, as discovery has them" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    var scratch: std.heap.ArenaAllocator = .init(testing.allocator);
    defer scratch.deinit();
    const page = try decodeEventPage(arena.allocator(), scratch.allocator(),
        \\{"errorEvents":[{"eventTime":"2026-10-18T00:00:00Z","message":"m","context":{"reportLocation":{"filePath":"a.go","lineNumber":9,"functionName":"main"},"sourceReferences":[{"repository":"https://github.com/x/y","revisionId":"abc123"},{"revisionId":"def"}]}}]}
    );
    const c = page.items[0].context;
    try testing.expectEqualStrings("a.go", c.report_location.?.file_path.?);
    try testing.expectEqual(9, c.report_location.?.line_number.?);
    try testing.expectEqualStrings("main", c.report_location.?.function_name.?);
    try testing.expectEqual(2, c.source_references.len);
    try testing.expectEqualStrings("https://github.com/x/y", c.source_references[0].repository.?);
    try testing.expectEqualStrings("abc123", c.source_references[0].revision_id.?);
    try testing.expectEqual(null, c.source_references[1].repository);
}

test "decoding: what is absent, null, a number or a name, and what is not an answer" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var scratch: std.heap.ArenaAllocator = .init(testing.allocator);
    defer scratch.deinit();
    const s = scratch.allocator();
    // An empty last page.
    try testing.expectEqual(0, (try decodeGroupStatsPage(a, s, "{}")).items.len);
    const empty_events = try decodeEventPage(a, s, "{\"errorEvents\":null,\"nextPageToken\":\"\"}");
    try testing.expectEqual(0, empty_events.items.len);
    // An empty token ends the list, as an absent one does.
    try testing.expectEqual(null, empty_events.next_page_token);
    // Counts as numbers too, a null representative, an unknown field.
    const page = try decodeGroupStatsPage(a, s,
        \\{"errorGroupStats":[{"group":{"name":"n","groupId":"i","resolutionStatus":4},"count":7,"affectedUsersCount":null,"representative":null,"unpublished":{"x":1}}]}
    );
    try testing.expectEqual(7, page.items[0].count);
    try testing.expectEqual(0, page.items[0].affected_users);
    try testing.expectEqual(null, page.items[0].representative);
    try testing.expectEqual(.muted, page.items[0].group.status);
    const unknown = try decodeGroup(a, s, "{\"name\":\"n\",\"groupId\":\"i\",\"resolutionStatus\":\"WONTFIX\"}");
    try testing.expectEqual(.unknown, unknown.status);

    for ([_][]const u8{
        "",
        "[]",
        "{\"errorGroupStats\":{}}",
        "{\"errorGroupStats\":[{\"count\":\"1\"}]}",
        "{\"errorGroupStats\":[{\"group\":{\"groupId\":\"i\"}}]}",
        "{\"errorGroupStats\":[{\"group\":{\"name\":\"n\",\"groupId\":\"i\"},\"count\":\"-1\"}]}",
        "{\"errorGroupStats\":[{\"group\":{\"name\":\"n\",\"groupId\":\"i\"},\"count\":\"x\"}]}",
        "{\"errorGroupStats\":[{\"group\":{\"name\":\"n\",\"groupId\":\"i\"},\"timedCounts\":[{\"count\":\"1\"}]}]}",
        "{\"errorGroupStats\":[{\"group\":{\"name\":\"n\",\"groupId\":\"i\"},\"firstSeenTime\":\"yesterday\"}]}",
        "{\"errorGroupStats\":[{\"group\":{\"name\":\"n\",\"groupId\":\"i\",\"resolutionStatus\":true}}]}",
        "{\"timeRangeBegin\":7}",
    }) |body| try testing.expectError(error.InvalidResponse, decodeGroupStatsPage(a, s, body));
    for ([_][]const u8{ "{\"errorEvents\":[1]}", "{\"errorEvents\":[{\"context\":{\"httpRequest\":{\"responseStatusCode\":\"x\"}}}]}", "{\"errorEvents\":[{\"serviceContext\":[]}]}" }) |body|
        try testing.expectError(error.InvalidResponse, decodeEventPage(a, s, body));
    try testing.expectError(error.InvalidResponse, decodeGroup(a, s, "{\"name\":\"n\"}"));
}

test "decoding: every allocation failure is OutOfMemory without leaks" {
    const Run = struct {
        fn run(gpa: Allocator) !void {
            var arena: std.heap.ArenaAllocator = .init(gpa);
            defer arena.deinit();
            var scratch: std.heap.ArenaAllocator = .init(gpa);
            defer scratch.deinit();
            _ = try decodeGroupStatsPage(arena.allocator(), scratch.allocator(), bodies.group_stats_timed_end);
            _ = try decodeEventPage(arena.allocator(), scratch.allocator(), bodies.events_page_with_token);
            _ = try decodeGroup(arena.allocator(), scratch.allocator(), bodies.group_with_issue);
            _ = try encodeGroup(arena.allocator(), .{ .name = "n", .id = "i", .tracking_issues = &.{.{ .url = "u" }} }, .open);
        }
    };
    try testing.checkAllAllocationFailures(core.testing.no_grow_allocator, Run.run, .{});
}

fn arbitraryProperty(_: void, input: []const u8) !void {
    var arena: std.heap.ArenaAllocator = .init(std.heap.smp_allocator);
    defer arena.deinit();
    // Total: every body is a page or InvalidResponse, never a crash.
    _ = decodeGroupStatsPage(arena.allocator(), arena.allocator(), input) catch |err| try testing.expectEqual(error.InvalidResponse, err);
    _ = decodeEventPage(arena.allocator(), arena.allocator(), input) catch |err| try testing.expectEqual(error.InvalidResponse, err);
    _ = decodeGroup(arena.allocator(), arena.allocator(), input) catch |err| try testing.expectEqual(error.InvalidResponse, err);
}

test "fuzz codec: arbitrary bodies decode or are InvalidResponse" {
    try core.testing.fuzzBytes({}, arbitraryProperty, .{ .corpus = &.{
        bodies.group_stats_timed_rounded,
        bodies.events_page_with_token,
        bodies.group_with_issue,
        "{\"errorGroupStats\":[{\"group\":{\"name\":\"n\",\"groupId\":\"i\"},\"count\":\"99999999999999999999\"}]}",
    } });
}
