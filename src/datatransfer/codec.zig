//! Decoders for Data Transfer's JSON, lenient the way the other modules
//! are: unknown fields skipped, unknown enum values read as `.unknown`. A
//! config or a run without a name this library can take apart is
//! `error.InvalidResponse`, since every call about it takes that name.

const std = @import("std");
const Allocator = std.mem.Allocator;
const Value = std.json.Value;
const ObjectMap = std.json.ObjectMap;
const core = @import("core");
const names = @import("names.zig");
const types = @import("types.zig");

pub const DecodeError = error{ OutOfMemory, InvalidResponse };

/// A page of `projects.locations.list`.
pub fn decodeLocationPage(out: Allocator, scratch: Allocator, body: []const u8) DecodeError!types.LocationPage {
    const obj = try object(try parse(scratch, body));
    const list = try field(obj, "locations", .array);
    const locations = try out.alloc(types.Location, if (list) |l| l.items.len else 0);
    if (list) |l| for (l.items, locations) |v, *loc| {
        const o = try object(v);
        loc.* = .{
            .name = try string(out, o, "name") orelse return error.InvalidResponse,
            .id = try string(out, o, "locationId") orelse return error.InvalidResponse,
            .display_name = try string(out, o, "displayName") orelse "",
        };
    };
    return .{ .locations = locations, .next_page_token = try token(out, obj, "nextPageToken") };
}

/// A config, as get answers.
pub fn decodeConfig(out: Allocator, scratch: Allocator, body: []const u8) DecodeError!types.TransferConfig {
    return configOf(out, scratch, try object(try parse(scratch, body)));
}

/// A page of `transferConfigs.list`: no `transferConfigs` is an empty
/// last page.
pub fn decodeConfigPage(out: Allocator, scratch: Allocator, body: []const u8) DecodeError!types.TransferConfigPage {
    const obj = try object(try parse(scratch, body));
    const list = try field(obj, "transferConfigs", .array);
    const configs = try out.alloc(types.TransferConfig, if (list) |l| l.items.len else 0);
    if (list) |l| for (l.items, configs) |v, *c| {
        c.* = try configOf(out, scratch, try object(v));
    };
    return .{ .configs = configs, .next_page_token = try token(out, obj, "nextPageToken") };
}

/// A run, as get answers.
pub fn decodeRun(out: Allocator, scratch: Allocator, body: []const u8) DecodeError!types.TransferRun {
    return runOf(out, scratch, try object(try parse(scratch, body)));
}

/// A page of `runs.list`, newest run time first as production lists them.
pub fn decodeRunPage(out: Allocator, scratch: Allocator, body: []const u8) DecodeError!types.TransferRunPage {
    const obj = try object(try parse(scratch, body));
    const runs = try runList(out, scratch, obj, "transferRuns");
    return .{ .runs = runs, .next_page_token = try token(out, obj, "nextPageToken") };
}

/// A page of `transferLogs.list`, newest first as production lists them.
pub fn decodeMessagePage(out: Allocator, scratch: Allocator, body: []const u8) DecodeError!types.TransferMessagePage {
    const obj = try object(try parse(scratch, body));
    const list = try field(obj, "transferMessages", .array);
    const messages = try out.alloc(types.TransferMessage, if (list) |l| l.items.len else 0);
    if (list) |l| for (l.items, messages) |v, *m| {
        const o = try object(v);
        m.* = .{
            .time = try timestamp(o, "messageTime"),
            .severity = if (try field(o, "severity", .string)) |s| types.MessageSeverity.fromWire(s) else .unknown,
            .text = try string(out, o, "messageText") orelse "",
        };
    };
    return .{ .messages = messages, .next_page_token = try token(out, obj, "nextPageToken") };
}

fn runList(out: Allocator, scratch: Allocator, obj: ObjectMap, name: []const u8) DecodeError![]const types.TransferRun {
    const list = try field(obj, name, .array);
    const runs = try out.alloc(types.TransferRun, if (list) |l| l.items.len else 0);
    if (list) |l| for (l.items, runs) |v, *r| {
        r.* = try runOf(out, scratch, try object(v));
    };
    return runs;
}

fn configOf(out: Allocator, scratch: Allocator, obj: ObjectMap) DecodeError!types.TransferConfig {
    const name = try string(out, obj, "name") orelse return error.InvalidResponse;
    const parsed = names.parseConfig(name) catch return error.InvalidResponse;
    const data_source = try string(out, obj, "dataSourceId") orelse "";
    var config: types.TransferConfig = .{
        .name = name,
        .location = parsed.location,
        .id = parsed.id,
        .display_name = try string(out, obj, "displayName") orelse "",
        .data_source_id = data_source,
        .destination_dataset_id = try string(out, obj, "destinationDatasetId") orelse "",
        .dataset_region = try string(out, obj, "datasetRegion") orelse "",
        .schedule = try scheduleOf(out, obj),
        .next_run_time = try timestamp(obj, "nextRunTime"),
        .state = if (try field(obj, "state", .string)) |s| types.TransferState.fromWire(s) else .unknown,
        .disabled = try boolean(obj, "disabled") orelse false,
        .update_time = try timestamp(obj, "updateTime"),
        .@"error" = try statusOf(out, obj, "error"),
        .notification_topic = try string(out, obj, "notificationPubsubTopic") orelse "",
    };
    if (try field(obj, "ownerInfo", .object)) |owner| config.owner_email = try string(out, owner, "email") orelse "";
    if (try field(obj, "emailPreferences", .object)) |prefs| config.failure_email = try boolean(prefs, "enableFailureEmail") orelse false;
    if (try field(obj, "params", .object)) |params| {
        config.params = try paramList(out, scratch, params);
        if (std.mem.eql(u8, data_source, "scheduled_query")) config.scheduled_query = .{
            .query = try loose(out, params, "query"),
            .destination_table_name_template = try loose(out, params, "destination_table_name_template"),
            .write_disposition = try loose(out, params, "write_disposition"),
            .partitioning_field = try loose(out, params, "partitioning_field"),
        };
    } else if (std.mem.eql(u8, data_source, "scheduled_query")) config.scheduled_query = .{};
    return config;
}

/// The schedule from either shape: `scheduleOptionsV2` when it says one,
/// else `schedule` and `scheduleOptions`. Production answers both for a
/// config made with either (measured).
fn scheduleOf(out: Allocator, obj: ObjectMap) DecodeError!types.Schedule {
    if (try field(obj, "scheduleOptionsV2", .object)) |v2| {
        if (try field(v2, "timeBasedSchedule", .object)) |t| return .{ .time_based = .{
            .schedule = try string(out, t, "schedule") orelse "",
            .start_time = try timestamp(t, "startTime"),
            .end_time = try timestamp(t, "endTime"),
        } };
        if (try field(v2, "manualSchedule", .object) != null) return .manual;
        if (try field(v2, "eventDrivenSchedule", .object)) |e| return .{ .event_driven = try string(out, e, "pubsubSubscription") orelse "" };
    }
    var start: ?std.Io.Timestamp = null;
    var end: ?std.Io.Timestamp = null;
    if (try field(obj, "scheduleOptions", .object)) |options| {
        if (try boolean(options, "disableAutoScheduling") orelse false) return .manual;
        start = try timestamp(options, "startTime");
        end = try timestamp(options, "endTime");
    }
    const text = try string(out, obj, "schedule") orelse "";
    if (text.len == 0) return .default;
    return .{ .time_based = .{ .schedule = text, .start_time = start, .end_time = end } };
}

fn runOf(out: Allocator, scratch: Allocator, obj: ObjectMap) DecodeError!types.TransferRun {
    const name = try string(out, obj, "name") orelse return error.InvalidResponse;
    const parsed = names.parseRun(name) catch return error.InvalidResponse;
    return .{
        .name = name,
        .config_name = name[0 .. name.len - "/runs/".len - parsed.id.len],
        .id = parsed.id,
        .state = if (try field(obj, "state", .string)) |s| types.TransferState.fromWire(s) else .unknown,
        .schedule_time = try timestamp(obj, "scheduleTime"),
        .run_time = try timestamp(obj, "runTime"),
        .start_time = try timestamp(obj, "startTime"),
        .end_time = try timestamp(obj, "endTime"),
        .update_time = try timestamp(obj, "updateTime"),
        .@"error" = try statusOf(out, obj, "errorStatus"),
        .data_source_id = try string(out, obj, "dataSourceId") orelse "",
        .destination_dataset_id = try string(out, obj, "destinationDatasetId") orelse "",
        .schedule = try string(out, obj, "schedule") orelse "",
        .params = if (try field(obj, "params", .object)) |p| try paramList(out, scratch, p) else &.{},
    };
}

/// A `google.rpc.Status`, or null for none: production sends `{}` on a
/// run that succeeded (measured).
fn statusOf(out: Allocator, obj: ObjectMap, name: []const u8) DecodeError!?types.Status {
    const s = try field(obj, name, .object) orelse return null;
    const code = try int32(s, "code") orelse 0;
    const message = try string(out, s, "message") orelse "";
    if (code == 0 and message.len == 0) return null;
    return .{ .code = code, .message = message };
}

/// Each top-level param with its value's JSON text, in the order the
/// server wrote them.
fn paramList(out: Allocator, scratch: Allocator, params: ObjectMap) DecodeError![]const types.Param {
    const list = try out.alloc(types.Param, params.count());
    for (params.keys(), params.values(), list) |k, v, *p| {
        const text = std.json.Stringify.valueAlloc(scratch, v, .{}) catch return error.OutOfMemory;
        p.* = .{ .key = try out.dupe(u8, k), .json = try out.dupe(u8, text) };
    }
    return list;
}

/// A param's text when it is a string; "" when absent or another kind.
fn loose(out: Allocator, params: ObjectMap, name: []const u8) DecodeError![]const u8 {
    const v = params.get(name) orelse return "";
    return switch (v) {
        .string => |s| try out.dupe(u8, s),
        else => "",
    };
}

pub fn parse(scratch: Allocator, body: []const u8) DecodeError!Value {
    return std.json.parseFromSliceLeaky(Value, scratch, body, .{ .parse_numbers = false }) catch |err| switch (err) {
        error.OutOfMemory => error.OutOfMemory,
        else => error.InvalidResponse,
    };
}

pub fn object(v: Value) DecodeError!ObjectMap {
    return switch (v) {
        .object => |o| o,
        else => error.InvalidResponse,
    };
}

pub fn field(obj: ObjectMap, name: []const u8, comptime tag: std.meta.Tag(Value)) DecodeError!?@FieldType(Value, @tagName(tag)) {
    const v = obj.get(name) orelse return null;
    if (v == .null) return null;
    if (v != tag) return error.InvalidResponse;
    return @field(v, @tagName(tag));
}

pub fn string(out: Allocator, obj: ObjectMap, name: []const u8) DecodeError!?[]const u8 {
    const text = try field(obj, name, .string) orelse return null;
    return try out.dupe(u8, text);
}

fn boolean(obj: ObjectMap, name: []const u8) DecodeError!?bool {
    return try field(obj, name, .bool);
}

/// A page token: "" means the last page.
fn token(out: Allocator, obj: ObjectMap, name: []const u8) DecodeError!?[]const u8 {
    const text = try field(obj, name, .string) orelse return null;
    if (text.len == 0) return null;
    return try out.dupe(u8, text);
}

fn int32(obj: ObjectMap, name: []const u8) DecodeError!?i32 {
    const v = obj.get(name) orelse return null;
    const text = switch (v) {
        .null => return null,
        .number_string, .string => |s| s,
        else => return error.InvalidResponse,
    };
    return std.fmt.parseInt(i32, text, 10) catch error.InvalidResponse;
}

/// An RFC 3339 time, to the nanosecond as production writes a schedule
/// time.
fn timestamp(obj: ObjectMap, name: []const u8) DecodeError!?std.Io.Timestamp {
    const text = try field(obj, name, .string) orelse return null;
    return core.timestamp.parse(text) catch error.InvalidResponse;
}

const testing = std.testing;
const production = @import("production_bodies.zig");

fn at(text: []const u8) std.Io.Timestamp {
    return core.timestamp.parse(text) catch unreachable;
}

test "decodeLocationPage: every location, one page" {
    var out: std.heap.ArenaAllocator = .init(testing.allocator);
    defer out.deinit();
    var scratch: std.heap.ArenaAllocator = .init(testing.allocator);
    defer scratch.deinit();
    const page = try decodeLocationPage(out.allocator(), scratch.allocator(), production.locations_page);
    try testing.expectEqual(54, page.locations.len);
    try testing.expectEqualStrings("us", page.locations[0].id);
    try testing.expectEqualStrings("projects/extractctl/locations/us", page.locations[0].name);
    try testing.expectEqualStrings("europe", page.locations[1].id);
    try testing.expectEqual(null, page.next_page_token);
    var omni = false;
    for (page.locations) |l| omni = omni or std.mem.startsWith(u8, l.id, "aws-");
    try testing.expect(omni);
}

test "decodeConfig: a manual one, a scheduled one disabled, one after its runs" {
    var out: std.heap.ArenaAllocator = .init(testing.allocator);
    defer out.deinit();
    var scratch: std.heap.ArenaAllocator = .init(testing.allocator);
    defer scratch.deinit();
    const a = out.allocator();
    const s = scratch.allocator();

    const manual = try decodeConfig(a, s, production.config_manual);
    try testing.expectEqualStrings("projects/82150720798/locations/us/transferConfigs/6ad99c4e-0000-2bb7-b042-14223bbd2862", manual.name);
    try testing.expectEqualStrings("us", manual.location);
    try testing.expectEqualStrings("6ad99c4e-0000-2bb7-b042-14223bbd2862", manual.id);
    try testing.expectEqualStrings("zigps-bd4dcf-manual", manual.display_name);
    try testing.expectEqualStrings("scheduled_query", manual.data_source_id);
    try testing.expectEqualStrings("zigps_dt_bd4dcf", manual.destination_dataset_id);
    try testing.expectEqualStrings("us", manual.dataset_region);
    try testing.expectEqual(types.Schedule.manual, manual.schedule);
    try testing.expectEqual(null, manual.next_run_time);
    try testing.expectEqual(types.TransferState.unknown, manual.state);
    try testing.expect(!manual.disabled);
    try testing.expectEqualStrings("zig-gcp@extractctl.iam.gserviceaccount.com", manual.owner_email);
    try testing.expectEqual(at("2026-10-21T18:44:55.812597Z"), manual.update_time.?);
    const q = manual.scheduled_query.?;
    try testing.expectEqualStrings("SELECT @run_date AS d, @run_time AS t, 17 AS x", q.query);
    try testing.expectEqualStrings("zigps_manual_{run_date}", q.destination_table_name_template);
    try testing.expectEqualStrings("WRITE_TRUNCATE", q.write_disposition);
    try testing.expectEqualStrings("", q.partitioning_field);
    try testing.expectEqual(3, manual.params.len);
    for (manual.params) |p| {
        if (std.mem.eql(u8, p.key, "write_disposition")) try testing.expectEqualStrings("\"WRITE_TRUNCATE\"", p.json);
    }
    try testing.expectEqual(null, manual.@"error");

    const scheduled = try decodeConfig(a, s, production.config_scheduled);
    try testing.expectEqualStrings("every 24 hours", scheduled.schedule.time_based.schedule);
    try testing.expectEqual(null, scheduled.schedule.time_based.start_time);
    try testing.expect(scheduled.disabled);
    try testing.expectEqual(null, scheduled.next_run_time);
    try testing.expectEqualStrings("WRITE_APPEND", scheduled.scheduled_query.?.write_disposition);

    const after = try decodeConfig(a, s, production.config_after_runs);
    try testing.expectEqual(types.TransferState.succeeded, after.state);
}

test "decodeConfigPage: a list's configs carry no owner; a token pages" {
    var out: std.heap.ArenaAllocator = .init(testing.allocator);
    defer out.deinit();
    var scratch: std.heap.ArenaAllocator = .init(testing.allocator);
    defer scratch.deinit();
    const a = out.allocator();
    const s = scratch.allocator();
    const page = try decodeConfigPage(a, s, production.configs_page);
    try testing.expectEqual(3, page.configs.len);
    for (page.configs) |c| {
        try testing.expectEqualStrings("", c.owner_email);
        try testing.expect(c.scheduled_query != null);
    }
    try testing.expectEqual(null, page.next_page_token);
    const first = try decodeConfigPage(a, s, production.configs_page_token);
    try testing.expectEqual(1, first.configs.len);
    try testing.expect(first.next_page_token != null);
    try testing.expectEqual(0, (try decodeConfigPage(a, s, "{}")).configs.len);
}

test "decodeRun and its page: a success, a failure, newest run time first, LATEST one a day" {
    var out: std.heap.ArenaAllocator = .init(testing.allocator);
    defer out.deinit();
    var scratch: std.heap.ArenaAllocator = .init(testing.allocator);
    defer scratch.deinit();
    const a = out.allocator();
    const s = scratch.allocator();

    const ok = try decodeRun(a, s, production.run_succeeded);
    try testing.expect(ok.succeeded() and ok.ended());
    // `errorStatus: {}` is no error.
    try testing.expectEqual(null, ok.@"error");
    try testing.expectEqualStrings("projects/82150720798/locations/us/transferConfigs/6ad99c4e-0000-2bb7-b042-14223bbd2862", ok.config_name);
    try testing.expectEqualStrings("6ae65981-0000-2805-bdde-883d24fa83a4", ok.id);
    try testing.expectEqual(at("2026-10-21T18:44:58.873464Z"), ok.run_time.?);
    try testing.expectEqual(at("2026-10-21T18:44:59.282036Z"), ok.start_time.?);
    try testing.expectEqual(at("2026-10-21T18:46:14.215921Z"), ok.end_time.?);
    try testing.expectEqualStrings("", ok.schedule);
    try testing.expectEqualStrings("scheduled_query", ok.data_source_id);
    try testing.expectEqual(3, ok.params.len);

    const failed = try decodeRun(a, s, production.run_failed);
    try testing.expect(failed.failed());
    try testing.expectEqual(3, failed.@"error".?.code);
    try testing.expect(std.mem.startsWith(u8, failed.@"error".?.message, "division by zero: 1 / 0; JobID: 82150720798:US.scheduled_query_"));

    const page = try decodeRunPage(a, s, production.runs_page);
    try testing.expectEqual(8, page.runs.len);
    for (page.runs[0 .. page.runs.len - 1], page.runs[1..]) |newer, older| {
        try testing.expect(newer.run_time.?.nanoseconds >= older.run_time.?.nanoseconds);
    }
    const latest = try decodeRunPage(a, s, production.runs_latest);
    try testing.expectEqual(2, latest.runs.len);
    const paged = try decodeRunPage(a, s, production.runs_page_token);
    try testing.expectEqual(2, paged.runs.len);
    try testing.expect(paged.next_page_token != null);
}

test "decodeMessagePage: newest first, by severity" {
    var out: std.heap.ArenaAllocator = .init(testing.allocator);
    defer out.deinit();
    var scratch: std.heap.ArenaAllocator = .init(testing.allocator);
    defer scratch.deinit();
    const a = out.allocator();
    const s = scratch.allocator();
    const ok = try decodeMessagePage(a, s, production.messages_succeeded);
    try testing.expectEqual(5, ok.messages.len);
    try testing.expectEqualStrings("Summary: succeeded 1 jobs, failed 0 jobs.", ok.messages[0].text);
    try testing.expectEqual(types.MessageSeverity.info, ok.messages[0].severity);
    for (ok.messages[0 .. ok.messages.len - 1], ok.messages[1..]) |newer, older| {
        try testing.expect(newer.time.?.nanoseconds >= older.time.?.nanoseconds);
    }
    const failed = try decodeMessagePage(a, s, production.messages_failed_error);
    try testing.expectEqual(types.MessageSeverity.@"error", failed.messages[0].severity);
    try testing.expect(std.mem.indexOf(u8, failed.messages[0].text, "failed with error INVALID_ARGUMENT: division by zero") != null);
    try testing.expect((try decodeMessagePage(a, s, production.messages_page_token)).next_page_token != null);
}

test "the shapes production may send that milestone 0 did not, and what cannot be decoded" {
    var out: std.heap.ArenaAllocator = .init(testing.allocator);
    defer out.deinit();
    var scratch: std.heap.ArenaAllocator = .init(testing.allocator);
    defer scratch.deinit();
    const a = out.allocator();
    const s = scratch.allocator();
    const n = "projects/1/locations/europe/transferConfigs/c1";

    const timed = try decodeConfig(a, s, "{\"name\":\"" ++ n ++ "\",\"schedule\":\"every mon 09:00\",\"scheduleOptions\":{\"startTime\":\"2026-11-01T00:00:00Z\",\"endTime\":\"2027-01-01T00:00:00Z\"},\"nextRunTime\":\"2026-11-02T09:00:00Z\",\"state\":\"FAILED\",\"error\":{\"code\":7,\"message\":\"denied\"},\"emailPreferences\":{\"enableFailureEmail\":true},\"notificationPubsubTopic\":\"projects/p/topics/t\",\"dataSourceId\":\"google_cloud_storage\",\"params\":{\"max_bad_records\":\"0\",\"skip_leading_rows\":1,\"delete_source_files\":false}}");
    try testing.expectEqualStrings("every mon 09:00", timed.schedule.time_based.schedule);
    try testing.expectEqual(at("2026-11-01T00:00:00Z"), timed.schedule.time_based.start_time.?);
    try testing.expectEqual(at("2027-01-01T00:00:00Z"), timed.schedule.time_based.end_time.?);
    try testing.expectEqual(at("2026-11-02T09:00:00Z"), timed.next_run_time.?);
    try testing.expectEqual(types.TransferState.failed, timed.state);
    try testing.expectEqual(7, timed.@"error".?.code);
    try testing.expect(timed.failure_email);
    try testing.expectEqualStrings("projects/p/topics/t", timed.notification_topic);
    try testing.expectEqual(null, timed.scheduled_query);
    try testing.expectEqualStrings("1", timed.params[1].json);
    try testing.expectEqualStrings("false", timed.params[2].json);
    try testing.expectEqualStrings("europe", timed.location);

    const v2 = try decodeConfig(a, s, "{\"name\":\"" ++ n ++ "\",\"schedule\":\"ignored\",\"scheduleOptionsV2\":{\"timeBasedSchedule\":{\"schedule\":\"every 6 hours\",\"startTime\":\"2026-11-01T00:00:00Z\"}}}");
    try testing.expectEqualStrings("every 6 hours", v2.schedule.time_based.schedule);
    try testing.expectEqual(at("2026-11-01T00:00:00Z"), v2.schedule.time_based.start_time.?);
    const event = try decodeConfig(a, s, "{\"name\":\"" ++ n ++ "\",\"scheduleOptionsV2\":{\"eventDrivenSchedule\":{\"pubsubSubscription\":\"projects/p/subscriptions/s\"}}}");
    try testing.expectEqualStrings("projects/p/subscriptions/s", event.schedule.event_driven);
    try testing.expectEqual(types.Schedule.default, (try decodeConfig(a, s, "{\"name\":\"" ++ n ++ "\",\"scheduleOptions\":{}}")).schedule);
    // The old shape alone, as a config made before scheduleOptionsV2.
    try testing.expectEqual(types.Schedule.manual, (try decodeConfig(a, s, "{\"name\":\"" ++ n ++ "\",\"schedule\":\"every 24 hours\",\"scheduleOptions\":{\"disableAutoScheduling\":true}}")).schedule);
    // An empty page token is the last page.
    try testing.expectEqual(null, (try decodeConfigPage(a, s, "{\"nextPageToken\":\"\"}")).next_page_token);
    try testing.expectEqual(types.Schedule.default, (try decodeConfig(a, s, "{\"name\":\"" ++ n ++ "\",\"scheduleOptionsV2\":{}}")).schedule);
    // A scheduled query whose params are not all strings, or absent.
    const odd = try decodeConfig(a, s, "{\"name\":\"" ++ n ++ "\",\"dataSourceId\":\"scheduled_query\",\"params\":{\"query\":7}}");
    try testing.expectEqualStrings("", odd.scheduled_query.?.query);
    const bare = try decodeConfig(a, s, "{\"name\":\"" ++ n ++ "\",\"dataSourceId\":\"scheduled_query\"}");
    try testing.expectEqualStrings("", bare.scheduled_query.?.query);
    try testing.expectEqual(types.TransferState.unknown, (try decodeConfig(a, s, "{\"name\":\"" ++ n ++ "\",\"state\":\"TRANSFER_STATE_UNSPECIFIED\"}")).state);

    const cancelled = try decodeRun(a, s, "{\"name\":\"" ++ n ++ "/runs/r1\",\"state\":\"CANCELLED\",\"schedule\":\"every 24 hours\",\"errorStatus\":{\"message\":\"stopped\"}}");
    try testing.expect(cancelled.ended() and !cancelled.failed());
    try testing.expectEqualStrings("every 24 hours", cancelled.schedule);
    try testing.expectEqual(0, cancelled.@"error".?.code);
    try testing.expectEqualStrings(n, cancelled.config_name);

    for ([_][]const u8{
        "[]",
        "{}",
        "{\"name\":\"projects/p/transferConfigs/c\"}",
        "{\"name\":\"" ++ n ++ "\",\"updateTime\":\"yesterday\"}",
        "{\"name\":\"" ++ n ++ "\",\"disabled\":\"true\"}",
        "{\"name\":\"" ++ n ++ "\",\"error\":{\"code\":\"x\"}}",
        "{\"name\":\"" ++ n ++ "\",\"params\":[]}",
        "{\"name\":\"" ++ n ++ "\",\"scheduleOptionsV2\":{\"timeBasedSchedule\":{\"startTime\":7}}}",
    }) |body| try testing.expectError(error.InvalidResponse, decodeConfig(a, s, body));
    try testing.expectError(error.InvalidResponse, decodeRun(a, s, "{\"name\":\"" ++ n ++ "\"}"));
    try testing.expectError(error.InvalidResponse, decodeRun(a, s, "{\"name\":\"" ++ n ++ "/runs/r\",\"errorStatus\":{\"code\":99999999999}}"));
    try testing.expectError(error.InvalidResponse, decodeRunPage(a, s, "{\"transferRuns\":[{}]}"));
    try testing.expectError(error.InvalidResponse, decodeMessagePage(a, s, "{\"transferMessages\":[{\"messageTime\":1}]}"));
    try testing.expectError(error.InvalidResponse, decodeLocationPage(a, s, "{\"locations\":[{\"name\":\"projects/p/locations/us\"}]}"));
    try testing.expectEqual(types.MessageSeverity.unknown, (try decodeMessagePage(a, s, "{\"transferMessages\":[{\"severity\":\"DEBUG\"}]}")).messages[0].severity);
}

fn decodersProperty(_: void, input: []const u8) !void {
    const test_util = @import("test_util.zig");
    var out: std.heap.ArenaAllocator = .init(test_util.propertyAllocator());
    defer out.deinit();
    var scratch: std.heap.ArenaAllocator = .init(test_util.propertyAllocator());
    defer scratch.deinit();
    inline for (.{ decodeLocationPage, decodeConfig, decodeConfigPage, decodeRun, decodeRunPage, decodeMessagePage }) |decode| {
        if (decode(out.allocator(), scratch.allocator(), input)) |_| {} else |err| try testing.expectEqual(error.InvalidResponse, err);
    }
}

test "fuzz decoders: any body decodes or is InvalidResponse, never a crash or a leak" {
    try @import("test_util.zig").fuzzBytes({}, decodersProperty, .{ .corpus = &.{
        production.location_us,
        production.config_manual,
        production.config_scheduled,
        production.configs_page,
        production.run_succeeded,
        production.run_failed,
        production.runs_latest,
        production.messages_succeeded,
        production.messages_failed_error,
    } });
}
