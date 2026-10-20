//! Decoders for Dataflow's proto3 JSON. The Job schema is large; the
//! decode keeps what the types hold and skips the rest, lenient the way
//! the other modules are: unknown fields skipped, unknown enum values
//! read as `.unknown`, timestamps parsed, maps kept as pairs. A job
//! without an id is `error.InvalidResponse`.

const std = @import("std");
const Allocator = std.mem.Allocator;
const Value = std.json.Value;
const core = @import("core");
const types = @import("types.zig");

pub const DecodeError = error{ OutOfMemory, InvalidResponse };

/// A job, as get answers it.
pub fn decodeJob(out: Allocator, scratch: Allocator, body: []const u8) DecodeError!types.Job {
    return jobOf(out, try parse(scratch, body));
}

/// A page of either list: `{}` is an empty last page, as production
/// answered one; `failedLocation` names the regions that did not
/// answer, so the page may be silently partial without it.
pub fn decodeJobPage(out: Allocator, scratch: Allocator, body: []const u8) DecodeError!types.JobPage {
    const obj = try object(try parse(scratch, body));
    const list = try field(obj, "jobs", .array);
    const jobs = try out.alloc(types.Job, if (list) |l| l.items.len else 0);
    if (list) |l| for (l.items, jobs) |v, *j| {
        j.* = try jobOf(out, v);
    };
    var failed: []const []const u8 = &.{};
    if (try field(obj, "failedLocation", .array)) |l| {
        const names = try out.alloc([]const u8, l.items.len);
        for (l.items, names) |v, *n| {
            const o = try object(v);
            n.* = try string(out, o, "name") orelse return error.InvalidResponse;
        }
        failed = names;
    }
    return .{
        .jobs = jobs,
        .next_page_token = try token(out, obj),
        .failed_locations = failed,
    };
}

/// A page of `messages.list`: `{}` is a job with nothing to say, and
/// the autoscaling events come regardless of the importance filter.
pub fn decodeMessagePage(out: Allocator, scratch: Allocator, body: []const u8) DecodeError!types.MessagePage {
    const obj = try object(try parse(scratch, body));
    var messages: []types.JobMessage = &.{};
    if (try field(obj, "jobMessages", .array)) |list| {
        messages = try out.alloc(types.JobMessage, list.items.len);
        for (list.items, messages) |item, *m| {
            const o = try object(item);
            m.* = .{
                .id = try string(out, o, "id") orelse "",
                .time = try time(o, "time"),
                .text = try string(out, o, "messageText") orelse "",
                .importance = if (try field(o, "messageImportance", .string)) |name| types.MessageImportance.fromWire(name) else .unspecified,
            };
        }
    }
    var events: []types.AutoscalingEvent = &.{};
    if (try field(obj, "autoscalingEvents", .array)) |list| {
        events = try out.alloc(types.AutoscalingEvent, list.items.len);
        for (list.items, events) |item, *e| {
            const o = try object(item);
            e.* = .{
                .event_type = try string(out, o, "eventType") orelse "",
                .time = try time(o, "time"),
                .description = if (try field(o, "description", .object)) |d| try string(out, d, "messageText") orelse "" else "",
                .current_num_workers = try integer(i64, o, "currentNumWorkers"),
                .target_num_workers = try integer(i64, o, "targetNumWorkers"),
                .worker_pool = try string(out, o, "workerPool") orelse "",
            };
        }
    }
    return .{
        .messages = messages,
        .autoscaling_events = events,
        .next_page_token = try token(out, obj),
    };
}

fn jobOf(out: Allocator, v: Value) DecodeError!types.Job {
    const obj = try object(v);
    const id = try string(out, obj, "id") orelse return error.InvalidResponse;
    var stages: []types.StageState = &.{};
    if (try field(obj, "stageStates", .array)) |list| {
        stages = try out.alloc(types.StageState, list.items.len);
        for (list.items, stages) |item, *s| {
            const o = try object(item);
            s.* = .{
                .stage = try string(out, o, "executionStageName") orelse "",
                .state = if (try field(o, "executionStageState", .string)) |name| types.JobState.fromWire(name) else .unknown,
                .current_state_time = try time(o, "currentStateTime"),
            };
        }
    }
    return .{
        .id = id,
        .name = try string(out, obj, "name") orelse "",
        .project = try string(out, obj, "projectId") orelse "",
        .location = try string(out, obj, "location") orelse "",
        .type = if (try field(obj, "type", .string)) |name| types.JobType.fromWire(name) else .unspecified,
        .current_state = if (try field(obj, "currentState", .string)) |name| types.JobState.fromWire(name) else .unspecified,
        .current_state_time = try time(obj, "currentStateTime"),
        .requested_state = if (try field(obj, "requestedState", .string)) |name| types.JobState.fromWire(name) else .unspecified,
        .create_time = try time(obj, "createTime"),
        .start_time = try time(obj, "startTime"),
        .labels = try labelMap(out, obj, "labels"),
        .stage_states = stages,
    };
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

fn field(obj: std.json.ObjectMap, name: []const u8, comptime tag: std.meta.Tag(Value)) DecodeError!?@FieldType(Value, @tagName(tag)) {
    const v = obj.get(name) orelse return null;
    if (v == .null) return null;
    if (v != tag) return error.InvalidResponse;
    return @field(v, @tagName(tag));
}

fn string(out: Allocator, obj: std.json.ObjectMap, name: []const u8) DecodeError!?[]const u8 {
    const text = try field(obj, name, .string) orelse return null;
    return try out.dupe(u8, text);
}

/// `nextPageToken`: "" means the last page.
fn token(out: Allocator, obj: std.json.ObjectMap) DecodeError!?[]const u8 {
    const text = try field(obj, "nextPageToken", .string) orelse return null;
    if (text.len == 0) return null;
    return try out.dupe(u8, text);
}

fn time(obj: std.json.ObjectMap, name: []const u8) DecodeError!?std.Io.Timestamp {
    const text = try field(obj, name, .string) orelse return null;
    return core.timestamp.parse(text) catch error.InvalidResponse;
}

/// An integer that may arrive as a JSON number or a string, as proto3
/// JSON sends int64s ("targetNumWorkers": "1").
fn integer(comptime T: type, obj: std.json.ObjectMap, name: []const u8) DecodeError!?T {
    const v = obj.get(name) orelse return null;
    const text = switch (v) {
        .null => return null,
        .number_string, .string => |s| s,
        else => return error.InvalidResponse,
    };
    return std.fmt.parseInt(T, text, 10) catch error.InvalidResponse;
}

/// A map of strings as pairs, in the order the server wrote them.
fn labelMap(out: Allocator, obj: std.json.ObjectMap, name: []const u8) DecodeError![]const types.Label {
    const map = try field(obj, name, .object) orelse return &.{};
    const items = try out.alloc(types.Label, map.count());
    for (map.keys(), map.values(), items) |k, v, *l| l.* = .{
        .key = try out.dupe(u8, k),
        .value = switch (v) {
            .string => |s| try out.dupe(u8, s),
            else => return error.InvalidResponse,
        },
    };
    return items;
}

const testing = std.testing;
const production = @import("production_bodies.zig");

test "decodeJob: production's pending, failed and done jobs" {
    var out: std.heap.ArenaAllocator = .init(testing.allocator);
    defer out.deinit();
    var scratch: std.heap.ArenaAllocator = .init(testing.allocator);
    defer scratch.deinit();
    const a = out.allocator();
    const s = scratch.allocator();

    const pending = try decodeJob(a, s, production.job_pending);
    try testing.expectEqualStrings("2026-10-20_07_11_01-16829577348630633066", pending.id);
    try testing.expectEqualStrings("zigps-df-05461", pending.name);
    try testing.expectEqualStrings("extractctl", pending.project);
    try testing.expectEqualStrings("us-central1", pending.location);
    try testing.expectEqual(types.JobType.batch, pending.type);
    try testing.expectEqual(types.JobState.pending, pending.current_state);
    try testing.expect(!pending.terminal());
    try testing.expect(pending.create_time != null);
    try testing.expect(pending.start_time != null);
    // The plain get carried the template's labels, though the discovery
    // document promises them only at DESCRIPTION or ALL.
    try testing.expectEqualStrings("word_count", pending.label("goog-dataflow-provided-template-name").?);

    const failed = try decodeJob(a, s, production.job_failed);
    try testing.expectEqual(types.JobState.failed, failed.current_state);
    try testing.expect(failed.terminal());
    try testing.expect(failed.failing());

    const done = try decodeJob(a, s, production.job_done);
    try testing.expectEqual(types.JobState.done, done.current_state);
    try testing.expect(done.terminal());
    try testing.expect(!done.failing());
    try testing.expectEqual(types.JobState.done, done.stage_states[0].state);
    try testing.expect(done.stage_states[0].stage.len > 0);
}

test "decodeJobPage: production's lists, the aggregated one, and the empty page" {
    var out: std.heap.ArenaAllocator = .init(testing.allocator);
    defer out.deinit();
    var scratch: std.heap.ArenaAllocator = .init(testing.allocator);
    defer scratch.deinit();
    const a = out.allocator();
    const s = scratch.allocator();

    const page = try decodeJobPage(a, s, production.jobs_list);
    try testing.expectEqual(2, page.jobs.len);
    try testing.expectEqual(null, page.next_page_token);
    try testing.expectEqual(0, page.failed_locations.len);
    // Summaries: no labels on a listed job.
    try testing.expectEqual(0, page.jobs[0].labels.len);

    const paged = try decodeJobPage(a, s, production.jobs_list_paged);
    try testing.expectEqual(1, paged.jobs.len);
    try testing.expect(paged.next_page_token != null);

    const everywhere = try decodeJobPage(a, s, production.jobs_aggregated);
    try testing.expectEqual(2, everywhere.jobs.len);
    try testing.expectEqualStrings("us-central1", everywhere.jobs[0].location);

    const red = try decodeMessagePage(a, s, production.messages_error_failed);
    try testing.expectEqual(1, red.messages.len);
    try testing.expectEqual(types.MessageImportance.@"error", red.messages[0].importance);
    try testing.expect(std.mem.indexOf(u8, red.messages[0].text, "service agent") != null);
    try testing.expect(red.messages[0].time != null);

    // The DONE job at ERROR: nothing to say, but the autoscaling
    // events come regardless of the filter.
    const quiet = try decodeMessagePage(a, s, production.messages_error_done);
    try testing.expectEqual(0, quiet.messages.len);
    try testing.expectEqual(6, quiet.autoscaling_events.len);
    try testing.expectEqualStrings("TARGET_NUM_WORKERS_CHANGED", quiet.autoscaling_events[0].event_type);
    try testing.expectEqual(1, quiet.autoscaling_events[0].target_num_workers.?);
    try testing.expect(std.mem.indexOf(u8, quiet.autoscaling_events[0].description, "Starting a pool") != null);
    const nothing = try decodeMessagePage(a, s, "{}");
    try testing.expectEqual(0, nothing.messages.len);
    try testing.expectEqual(0, nothing.autoscaling_events.len);

    // ACTIVE with nothing running answered a bare {}.
    const empty = try decodeJobPage(a, s, "{}");
    try testing.expectEqual(0, empty.jobs.len);
    try testing.expectEqual(null, empty.next_page_token);
    // proto3 JSON may send the default explicitly: "" is still the end.
    const explicit = try decodeJobPage(a, s, "{\"jobs\":[],\"nextPageToken\":\"\"}");
    try testing.expectEqual(null, explicit.next_page_token);

    const partial = try decodeJobPage(a, s,
        \\{"jobs":[{"id":"j1"}],"failedLocation":[{"name":"us-west1"},{"name":"asia-east1"}]}
    );
    try testing.expectEqual(2, partial.failed_locations.len);
    try testing.expectEqualStrings("us-west1", partial.failed_locations[0]);
}

test "lenient where it can be, InvalidResponse where it cannot" {
    var out: std.heap.ArenaAllocator = .init(testing.allocator);
    defer out.deinit();
    var scratch: std.heap.ArenaAllocator = .init(testing.allocator);
    defer scratch.deinit();
    const a = out.allocator();
    const s = scratch.allocator();

    const bare = try decodeJob(a, s, "{\"id\":\"j\",\"unknownField\":1}");
    try testing.expectEqualStrings("j", bare.id);
    try testing.expectEqual(types.JobState.unspecified, bare.current_state);
    try testing.expect(!bare.terminal());
    const strange = try decodeJob(a, s,
        \\{"id":"j","currentState":"JOB_STATE_MOODY","type":"JOB_TYPE_SQL","requestedState":"JOB_STATE_CANCELLED","stageStates":[{"executionStageState":"JOB_STATE_ODD"}]}
    );
    try testing.expectEqual(types.JobState.unknown, strange.current_state);
    try testing.expectEqual(types.JobType.unknown, strange.type);
    try testing.expectEqual(types.JobState.cancelled, strange.requested_state);
    try testing.expectEqual(types.JobState.unknown, strange.stage_states[0].state);

    for ([_][]const u8{
        "[]",
        "{\"jobs\":1}",
        "{\"jobs\":[{\"name\":\"no-id\"}]}",
        "{\"id\":true}",
        "{\"id\":\"j\",\"createTime\":\"yesterday\"}",
        "{\"id\":\"j\",\"labels\":{\"k\":1}}",
        "{\"id\":\"j\",\"stageStates\":[1]}",
        "{\"failedLocation\":[{}]}",
        "{\"failedLocation\":[1]}",
        "{\"jobs\":[],\"nextPageToken\":1}",
        "{\"jobMessages\":[1]}",
        "{\"jobMessages\":[{\"time\":\"soon\"}]}",
        "{\"autoscalingEvents\":[{\"targetNumWorkers\":true}]}",
        "{\"autoscalingEvents\":[{\"description\":1}]}",
    }) |body| {
        const job_err = decodeJob(a, s, body);
        const page_err = decodeJobPage(a, s, body);
        const message_err = decodeMessagePage(a, s, body);
        try testing.expect(job_err == error.InvalidResponse or page_err == error.InvalidResponse or message_err == error.InvalidResponse);
    }
}

fn decodersProperty(_: void, input: []const u8) !void {
    const test_util = @import("test_util.zig");
    var out: std.heap.ArenaAllocator = .init(test_util.propertyAllocator());
    defer out.deinit();
    var scratch: std.heap.ArenaAllocator = .init(test_util.propertyAllocator());
    defer scratch.deinit();
    const a = out.allocator();
    const s = scratch.allocator();
    inline for (.{ decodeJob, decodeJobPage, decodeMessagePage }) |decode| {
        if (decode(a, s, input)) |_| {} else |err| try testing.expectEqual(error.InvalidResponse, err);
    }
}

test "fuzz decoders: any body decodes or is InvalidResponse, never a crash or a leak" {
    try @import("test_util.zig").fuzzBytes({}, decodersProperty, .{ .corpus = &.{
        production.job_pending,
        production.job_failed,
        production.job_done,
        production.jobs_list,
        production.jobs_list_paged,
        production.jobs_aggregated,
        production.messages_error_failed,
        production.messages_error_done,
        "{\"jobs\":[{\"id\":\"j1\",\"stageStates\":[{\"executionStageName\":\"s01\",\"executionStageState\":\"JOB_STATE_DONE\",\"currentStateTime\":\"2026-10-20T14:20:00Z\"}]}],\"failedLocation\":[{\"name\":\"us-west1\"}],\"nextPageToken\":\"t\"}",
    } });
}
