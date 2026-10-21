//! Decoders for Cloud Run's proto3 JSON. The schemas are large; the
//! decode keeps what the types hold and skips the rest, lenient the way
//! the other modules are: unknown fields skipped, unknown enum values
//! read as `.unknown`, int64s taken as strings or numbers. A resource
//! without a name is `error.InvalidResponse`.

const std = @import("std");
const Allocator = std.mem.Allocator;
const Value = std.json.Value;
const core = @import("core");
const types = @import("types.zig");

pub const DecodeError = error{ OutOfMemory, InvalidResponse };

/// A service, as get answers.
pub fn decodeService(out: Allocator, scratch: Allocator, body: []const u8) DecodeError!types.Service {
    return serviceOf(out, try parse(scratch, body));
}

/// A page of `services.list`: `{}` is an empty last page, as production
/// answered one; a `-` location carries `unreachable`.
pub fn decodeServicePage(out: Allocator, scratch: Allocator, body: []const u8) DecodeError!types.ServicePage {
    const obj = try object(try parse(scratch, body));
    const list = try field(obj, "services", .array);
    const services = try out.alloc(types.Service, if (list) |l| l.items.len else 0);
    if (list) |l| for (l.items, services) |v, *s| {
        s.* = try serviceOf(out, v);
    };
    return .{
        .services = services,
        .next_page_token = try token(out, obj),
        .unreachable_regions = try stringList(out, obj, "unreachable"),
    };
}

/// A revision, as get answers.
pub fn decodeRevision(out: Allocator, scratch: Allocator, body: []const u8) DecodeError!types.Revision {
    return revisionOf(out, try parse(scratch, body));
}

/// A page of `revisions.list`: `{}` is an empty last page, and what a
/// service nobody has answers, as production did.
pub fn decodeRevisionPage(out: Allocator, scratch: Allocator, body: []const u8) DecodeError!types.RevisionPage {
    const obj = try object(try parse(scratch, body));
    const list = try field(obj, "revisions", .array);
    const revisions = try out.alloc(types.Revision, if (list) |l| l.items.len else 0);
    if (list) |l| for (l.items, revisions) |v, *r| {
        r.* = try revisionOf(out, v);
    };
    return .{ .revisions = revisions, .next_page_token = try token(out, obj) };
}

/// A page of v1's `locations.list`.
pub fn decodeLocationPage(out: Allocator, scratch: Allocator, body: []const u8) DecodeError!types.LocationPage {
    const obj = try object(try parse(scratch, body));
    const list = try field(obj, "locations", .array);
    const locations = try out.alloc(types.Location, if (list) |l| l.items.len else 0);
    if (list) |l| for (l.items, locations) |v, *loc| {
        const o = try object(v);
        const name = try string(out, o, "name") orelse return error.InvalidResponse;
        loc.* = .{
            .name = name,
            .id = if (try string(out, o, "locationId")) |id| id else trailing(name),
            .display_name = try string(out, o, "displayName") orelse "",
            .labels = try labelMap(out, o, "labels"),
        };
    };
    return .{ .locations = locations, .next_page_token = try token(out, obj) };
}

/// A job, as get answers.
pub fn decodeJob(out: Allocator, scratch: Allocator, body: []const u8) DecodeError!types.Job {
    return jobOf(out, try parse(scratch, body));
}

/// A page of `jobs.list`: `{}` is an empty last page, as production
/// answered one.
pub fn decodeJobPage(out: Allocator, scratch: Allocator, body: []const u8) DecodeError!types.JobPage {
    const obj = try object(try parse(scratch, body));
    const list = try field(obj, "jobs", .array);
    const jobs = try out.alloc(types.Job, if (list) |l| l.items.len else 0);
    if (list) |l| for (l.items, jobs) |v, *j| {
        j.* = try jobOf(out, v);
    };
    return .{ .jobs = jobs, .next_page_token = try token(out, obj) };
}

/// An execution, as get answers.
pub fn decodeExecution(out: Allocator, scratch: Allocator, body: []const u8) DecodeError!types.Execution {
    return executionOf(out, try parse(scratch, body));
}

/// A page of `executions.list`: `{}` is an empty last page, and what a
/// job nobody has answers, as production did.
pub fn decodeExecutionPage(out: Allocator, scratch: Allocator, body: []const u8) DecodeError!types.ExecutionPage {
    const obj = try object(try parse(scratch, body));
    const list = try field(obj, "executions", .array);
    const executions = try out.alloc(types.Execution, if (list) |l| l.items.len else 0);
    if (list) |l| for (l.items, executions) |v, *e| {
        e.* = try executionOf(out, v);
    };
    return .{ .executions = executions, .next_page_token = try token(out, obj) };
}

/// A long-running operation: its subject is the response once there is
/// one, the metadata before.
pub fn decodeOperation(out: Allocator, scratch: Allocator, body: []const u8) DecodeError!types.Operation {
    const obj = try object(try parse(scratch, body));
    const name = try string(out, obj, "name") orelse return error.InvalidResponse;
    var failure: ?types.Operation.Failure = null;
    if (try field(obj, "error", .object)) |e| failure = .{
        .code = try integer(i32, e, "code") orelse 0,
        .message = try string(out, e, "message") orelse "",
    };
    const source = try field(obj, "response", .object) orelse try field(obj, "metadata", .object);
    return .{
        .name = name,
        .done = try boolean(obj, "done") orelse false,
        .failure = failure,
        .subject = if (source) |s| try subjectOf(out, s) else .none,
    };
}

/// An operation's metadata or response, by its `@type`.
fn subjectOf(out: Allocator, obj: std.json.ObjectMap) DecodeError!types.Operation.Subject {
    const kind = try field(obj, "@type", .string) orelse return .none;
    const prefix = "type.googleapis.com/google.cloud.run.v2.";
    if (std.mem.eql(u8, kind, prefix ++ "Execution")) return .{ .execution = try executionOf(out, .{ .object = obj }) };
    if (std.mem.eql(u8, kind, prefix ++ "Service")) return .{ .service = try serviceOf(out, .{ .object = obj }) };
    return .{ .other = try out.dupe(u8, kind) };
}

fn jobOf(out: Allocator, v: Value) DecodeError!types.Job {
    const obj = try object(v);
    const name = try string(out, obj, "name") orelse return error.InvalidResponse;
    var job: types.Job = .{
        .name = name,
        .id = trailing(name),
        .location = segmentAfter(name, "/locations/"),
        .latest_created_execution = try executionReference(out, obj, name),
        .terminal_condition = if (try field(obj, "terminalCondition", .object)) |c| try conditionOf(out, c) else null,
        .conditions = try conditionList(out, obj),
        .execution_count = try integer(i32, obj, "executionCount") orelse 0,
        .create_time = try time(obj, "createTime"),
        .update_time = try time(obj, "updateTime"),
        .creator = try string(out, obj, "creator") orelse "",
        .last_modifier = try string(out, obj, "lastModifier") orelse "",
        .generation = try integer(i64, obj, "generation"),
        .observed_generation = try integer(i64, obj, "observedGeneration"),
        .reconciling = try boolean(obj, "reconciling") orelse false,
        .labels = try labelMap(out, obj, "labels"),
        .etag = try string(out, obj, "etag") orelse "",
    };
    // The execution template, and the task template inside it.
    if (try field(obj, "template", .object)) |execution| {
        job.task_count = try integer(i32, execution, "taskCount") orelse 0;
        job.parallelism = try integer(i32, execution, "parallelism") orelse 0;
        if (try field(execution, "template", .object)) |task| {
            job.task_timeout_s = try duration(task, "timeout");
            job.max_retries = try integer(i32, task, "maxRetries");
            job.containers = try containerList(out, task);
            job.service_account = try string(out, task, "serviceAccount") orelse "";
        }
    }
    return job;
}

/// `latestCreatedExecution`: null when absent, and when it is `{}`, as
/// production answers for a job never run. Its `name` is the id alone on
/// the wire; the full name is made from the job's.
fn executionReference(out: Allocator, obj: std.json.ObjectMap, job_name: []const u8) DecodeError!?types.ExecutionReference {
    const ref = try field(obj, "latestCreatedExecution", .object) orelse return null;
    const given = try field(ref, "name", .string) orelse return null;
    if (given.len == 0) return null;
    const name = if (std.mem.indexOfScalar(u8, given, '/') == null)
        try std.mem.concat(out, u8, &.{ job_name, "/executions/", given })
    else
        try out.dupe(u8, given);
    return .{
        .name = name,
        .id = trailing(name),
        .create_time = try time(ref, "createTime"),
        .completion_time = try time(ref, "completionTime"),
        .status = if (try field(ref, "completionStatus", .string)) |s| types.ExecutionStatus.fromWire(s) else .unspecified,
    };
}

fn executionOf(out: Allocator, v: Value) DecodeError!types.Execution {
    const obj = try object(v);
    const name = try string(out, obj, "name") orelse return error.InvalidResponse;
    return .{
        .name = name,
        .id = trailing(name),
        .job = try string(out, obj, "job") orelse "",
        .location = segmentAfter(name, "/locations/"),
        .create_time = try time(obj, "createTime"),
        .start_time = try time(obj, "startTime"),
        .completion_time = try time(obj, "completionTime"),
        .update_time = try time(obj, "updateTime"),
        .task_count = try integer(i32, obj, "taskCount") orelse 0,
        .parallelism = try integer(i32, obj, "parallelism") orelse 0,
        .running_count = try integer(i32, obj, "runningCount") orelse 0,
        .succeeded_count = try integer(i32, obj, "succeededCount") orelse 0,
        .failed_count = try integer(i32, obj, "failedCount") orelse 0,
        .cancelled_count = try integer(i32, obj, "cancelledCount") orelse 0,
        .retried_count = try integer(i32, obj, "retriedCount") orelse 0,
        .conditions = try conditionList(out, obj),
        .log_uri = try string(out, obj, "logUri") orelse "",
        .reconciling = try boolean(obj, "reconciling") orelse false,
        .generation = try integer(i64, obj, "generation"),
        .observed_generation = try integer(i64, obj, "observedGeneration"),
        .labels = try labelMap(out, obj, "labels"),
    };
}

fn serviceOf(out: Allocator, v: Value) DecodeError!types.Service {
    const obj = try object(v);
    const name = try string(out, obj, "name") orelse return error.InvalidResponse;
    return .{
        .name = name,
        .id = trailing(name),
        .location = segmentAfter(name, "/locations/"),
        .description = try string(out, obj, "description") orelse "",
        .uri = try string(out, obj, "uri") orelse "",
        .urls = try stringList(out, obj, "urls"),
        .latest_ready_revision = trailing(try string(out, obj, "latestReadyRevision") orelse ""),
        .latest_created_revision = trailing(try string(out, obj, "latestCreatedRevision") orelse ""),
        .traffic = try trafficList(out, obj, "traffic"),
        .traffic_statuses = try trafficList(out, obj, "trafficStatuses"),
        .terminal_condition = if (try field(obj, "terminalCondition", .object)) |c| try conditionOf(out, c) else null,
        .conditions = try conditionList(out, obj),
        .create_time = try time(obj, "createTime"),
        .update_time = try time(obj, "updateTime"),
        .creator = try string(out, obj, "creator") orelse "",
        .last_modifier = try string(out, obj, "lastModifier") orelse "",
        .generation = try integer(i64, obj, "generation"),
        .observed_generation = try integer(i64, obj, "observedGeneration"),
        .reconciling = try boolean(obj, "reconciling") orelse false,
        .labels = try labelMap(out, obj, "labels"),
        .etag = try string(out, obj, "etag") orelse "",
    };
}

fn revisionOf(out: Allocator, v: Value) DecodeError!types.Revision {
    const obj = try object(v);
    const name = try string(out, obj, "name") orelse return error.InvalidResponse;
    return .{
        .name = name,
        .id = trailing(name),
        .service = try string(out, obj, "service") orelse "",
        .location = segmentAfter(name, "/locations/"),
        .create_time = try time(obj, "createTime"),
        .update_time = try time(obj, "updateTime"),
        .generation = try integer(i64, obj, "generation"),
        .containers = try containerList(out, obj),
        .conditions = try conditionList(out, obj),
        .log_uri = try string(out, obj, "logUri") orelse "",
        .service_account = try string(out, obj, "serviceAccount") orelse "",
        .labels = try labelMap(out, obj, "labels"),
    };
}

fn containerList(out: Allocator, obj: std.json.ObjectMap) DecodeError![]const types.Container {
    const list = try field(obj, "containers", .array) orelse return &.{};
    const containers = try out.alloc(types.Container, list.items.len);
    for (list.items, containers) |item, *c| {
        const o = try object(item);
        c.* = .{
            .name = try string(out, o, "name") orelse "",
            .image = try string(out, o, "image") orelse "",
        };
    }
    return containers;
}

fn conditionList(out: Allocator, obj: std.json.ObjectMap) DecodeError![]const types.Condition {
    const list = try field(obj, "conditions", .array) orelse return &.{};
    const conditions = try out.alloc(types.Condition, list.items.len);
    for (list.items, conditions) |item, *c| c.* = try conditionOf(out, try object(item));
    return conditions;
}

fn conditionOf(out: Allocator, obj: std.json.ObjectMap) DecodeError!types.Condition {
    // The wire's one-of reasons, collapsed to whichever came.
    var reason: []const u8 = "";
    inline for (.{ "reason", "revisionReason", "executionReason", "instanceReason" }) |key| {
        if (reason.len == 0) {
            if (try string(out, obj, key)) |text| reason = text;
        }
    }
    return .{
        .type = try string(out, obj, "type") orelse "",
        .state = if (try field(obj, "state", .string)) |s| types.ConditionState.fromWire(s) else .unknown,
        .message = try string(out, obj, "message") orelse "",
        .reason = reason,
        .severity = if (try field(obj, "severity", .string)) |s| types.ConditionSeverity.fromWire(s) else .unspecified,
        .last_transition_time = try time(obj, "lastTransitionTime"),
    };
}

fn trafficList(out: Allocator, obj: std.json.ObjectMap, name: []const u8) DecodeError![]const types.TrafficTarget {
    const list = try field(obj, name, .array) orelse return &.{};
    const targets = try out.alloc(types.TrafficTarget, list.items.len);
    for (list.items, targets) |item, *t| {
        const o = try object(item);
        t.* = .{
            .type = if (try field(o, "type", .string)) |s| types.TrafficType.fromWire(s) else .unspecified,
            .revision = try string(out, o, "revision") orelse "",
            .percent = try integer(i64, o, "percent") orelse 0,
            .tag = try string(out, o, "tag") orelse "",
            .uri = try string(out, o, "uri") orelse "",
        };
    }
    return targets;
}

/// The segment after the last `/`, or the text itself; "" stays "".
fn trailing(name: []const u8) []const u8 {
    if (std.mem.lastIndexOfScalar(u8, name, '/')) |i| return name[i + 1 ..];
    return name;
}

/// The segment after `marker`, or "".
fn segmentAfter(name: []const u8, marker: []const u8) []const u8 {
    const head = std.mem.indexOf(u8, name, marker) orelse return "";
    const rest = name[head + marker.len ..];
    const end = std.mem.indexOfScalar(u8, rest, '/') orelse rest.len;
    return rest[0..end];
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

fn boolean(obj: std.json.ObjectMap, name: []const u8) DecodeError!?bool {
    return try field(obj, name, .bool);
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
/// JSON sends int64s ("generation": "1").
fn integer(comptime T: type, obj: std.json.ObjectMap, name: []const u8) DecodeError!?T {
    const v = obj.get(name) orelse return null;
    const text = switch (v) {
        .null => return null,
        .number_string, .string => |s| s,
        else => return error.InvalidResponse,
    };
    return std.fmt.parseInt(T, text, 10) catch error.InvalidResponse;
}

/// A proto duration: decimal seconds and a trailing `s`, such as "900s"
/// or "0.5s".
fn duration(obj: std.json.ObjectMap, name: []const u8) DecodeError!?f64 {
    const text = try field(obj, name, .string) orelse return null;
    if (text.len < 2 or text[text.len - 1] != 's') return error.InvalidResponse;
    const seconds = std.fmt.parseFloat(f64, text[0 .. text.len - 1]) catch return error.InvalidResponse;
    if (!std.math.isFinite(seconds)) return error.InvalidResponse;
    return seconds;
}

fn stringList(out: Allocator, obj: std.json.ObjectMap, name: []const u8) DecodeError![]const []const u8 {
    const list = try field(obj, name, .array) orelse return &.{};
    const items = try out.alloc([]const u8, list.items.len);
    for (list.items, items) |v, *s| s.* = switch (v) {
        .string => |text| try out.dupe(u8, text),
        else => return error.InvalidResponse,
    };
    return items;
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

test "decodeService: production's ready and failed services" {
    var out: std.heap.ArenaAllocator = .init(testing.allocator);
    defer out.deinit();
    var scratch: std.heap.ArenaAllocator = .init(testing.allocator);
    defer scratch.deinit();
    const a = out.allocator();
    const s = scratch.allocator();

    const ready = try decodeService(a, s, production.service_ready);
    try testing.expectEqualStrings("zigps-a12c61", ready.id);
    try testing.expectEqualStrings("us-central1", ready.location);
    try testing.expect(ready.ready());
    try testing.expectEqualStrings("Ready", ready.terminal_condition.?.type);
    try testing.expectEqual(types.ConditionState.succeeded, ready.terminal_condition.?.state);
    try testing.expectEqualStrings("https://zigps-a12c61-el44yx5gia-uc.a.run.app", ready.uri);
    try testing.expectEqual(2, ready.urls.len);
    try testing.expectEqualStrings("zigps-a12c61-00001-ct8", ready.latest_ready_revision);
    try testing.expectEqualStrings("zigps-a12c61-00001-ct8", ready.latest_created_revision);
    try testing.expectEqual(1, ready.traffic.len);
    try testing.expectEqual(types.TrafficType.latest, ready.traffic[0].type);
    try testing.expectEqual(100, ready.traffic[0].percent);
    try testing.expectEqualStrings("zigps-a12c61-00001-ct8", ready.traffic_statuses[0].revision);
    try testing.expectEqual(2, ready.conditions.len);
    try testing.expectEqual(1, ready.generation.?);
    try testing.expectEqual(1, ready.observed_generation.?);
    try testing.expect(!ready.reconciling);
    try testing.expectEqualStrings("probe", ready.labels[0].value);
    try testing.expect(ready.create_time != null);
    // The etag keeps its quote characters, as the wire carries them.
    try testing.expectEqualStrings("\"CM_g2dYGEKjFt8wB/cHJvamVjdHMvZXh0cmFjdGN0bC9sb2NhdGlvbnMvdXMtY2VudHJhbDEvc2VydmljZXMvemlncHMtYTEyYzYx\"", ready.etag);

    // After the bad deploy: failed, the reason kept, latestReady stays.
    const failed = try decodeService(a, s, production.service_failed);
    try testing.expect(!failed.ready());
    try testing.expectEqual(types.ConditionState.failed, failed.terminal_condition.?.state);
    try testing.expectEqualStrings("REVISION_FAILED", failed.terminal_condition.?.reason);
    try testing.expect(std.mem.indexOf(u8, failed.terminal_condition.?.message, "not found") != null);
    try testing.expectEqualStrings("zigps-a12c61-00001-ct8", failed.latest_ready_revision);
    try testing.expectEqualStrings("zigps-a12c61-00002-qmv", failed.latest_created_revision);
    // A change makes a new etag: the deploy moved it.
    try testing.expect(failed.etag.len > 0 and !std.mem.eql(u8, failed.etag, ready.etag));
}

test "decodeRevision and the pages: production's bodies" {
    var out: std.heap.ArenaAllocator = .init(testing.allocator);
    defer out.deinit();
    var scratch: std.heap.ArenaAllocator = .init(testing.allocator);
    defer scratch.deinit();
    const a = out.allocator();
    const s = scratch.allocator();

    const revision = try decodeRevision(a, s, production.revision_ready);
    try testing.expectEqualStrings("zigps-a12c61-00001-ct8", revision.id);
    try testing.expectEqualStrings("zigps-a12c61", revision.service);
    try testing.expectEqualStrings("us-central1", revision.location);
    try testing.expect(revision.ready());
    try testing.expectEqualStrings("Deploying revision succeeded in 3.77s.", revision.readyCondition().?.message);
    try testing.expectEqual(5, revision.conditions.len);
    try testing.expect(std.mem.startsWith(u8, revision.containers[0].image, "us-docker.pkg.dev/cloudrun/container/hello@sha256:"));
    try testing.expectEqualStrings("hello-1", revision.containers[0].name);
    try testing.expect(revision.log_uri.len > 0);
    try testing.expect(revision.create_time != null);
    try testing.expectEqual(1, revision.generation.?);

    // Both revisions after the bad deploy, newest first, the broken one
    // failed with the image's name in the message.
    const page = try decodeRevisionPage(a, s, production.revisions_failed);
    try testing.expectEqual(2, page.revisions.len);
    try testing.expect(!page.revisions[0].ready());
    try testing.expect(std.mem.indexOf(u8, page.revisions[0].readyCondition().?.message, "zigps-no-such-tag") != null);
    try testing.expect(page.revisions[1].ready());
    try testing.expectEqual(null, page.next_page_token);

    const services = try decodeServicePage(a, s, production.services_list);
    try testing.expectEqual(1, services.services.len);
    try testing.expectEqual(0, services.unreachable_regions.len);

    // The '-' location is not refused: an unreachable array while
    // nothing listed.
    const dash = try decodeServicePage(a, s, production.services_dash);
    try testing.expectEqual(0, dash.services.len);
    try testing.expectEqual(5, dash.unreachable_regions.len);
    try testing.expectEqualStrings("europe-west15", dash.unreachable_regions[0]);

    const locations = try decodeLocationPage(a, s, production.locations_v1);
    try testing.expectEqual(3, locations.locations.len);
    try testing.expectEqualStrings("africa-south1", locations.locations[0].id);

    const empty = try decodeServicePage(a, s, "{}");
    try testing.expectEqual(0, empty.services.len);
    try testing.expectEqual(null, empty.next_page_token);
    const empty_revisions = try decodeRevisionPage(a, s, "{}");
    try testing.expectEqual(0, empty_revisions.revisions.len);
    // proto3 JSON may send the default explicitly: "" is still the end.
    const explicit = try decodeRevisionPage(a, s, "{\"revisions\":[],\"nextPageToken\":\"\"}");
    try testing.expectEqual(null, explicit.next_page_token);

    // A tagged traffic status carries the tag's own uri.
    const tagged = try decodeServicePage(a, s,
        \\{"services":[{"name":"projects/p/locations/l/services/s","trafficStatuses":[{"type":"TRAFFIC_TARGET_ALLOCATION_TYPE_REVISION","revision":"s-00001-ab","percent":50,"tag":"blue","uri":"https://blue---s.run.app"}]}]}
    );
    const status = tagged.services[0].traffic_statuses[0];
    try testing.expectEqual(types.TrafficType.revision, status.type);
    try testing.expectEqual(50, status.percent);
    try testing.expectEqualStrings("blue", status.tag);
    try testing.expectEqualStrings("https://blue---s.run.app", status.uri);
}

test "decodeJob and its page: production's jobs, never run and after runs" {
    var out: std.heap.ArenaAllocator = .init(testing.allocator);
    defer out.deinit();
    var scratch: std.heap.ArenaAllocator = .init(testing.allocator);
    defer scratch.deinit();
    const a = out.allocator();
    const s = scratch.allocator();

    // Never run: no executionCount, and latestCreatedExecution is {}.
    const fresh = try decodeJob(a, s, production.job_fresh);
    try testing.expectEqual(null, fresh.latest_created_execution);
    try testing.expectEqual(0, fresh.execution_count);
    try testing.expect(fresh.ready());

    const job = try decodeJob(a, s, production.job_succeeded);
    try testing.expectEqualStrings("zigps-6b8297-quick", job.id);
    try testing.expectEqualStrings("us-central1", job.location);
    try testing.expectEqual(2, job.execution_count);
    // The wire names the latest execution by its id alone; the full name
    // is made from the job's.
    const latest = job.latest_created_execution.?;
    try testing.expectEqualStrings("projects/extractctl/locations/us-central1/jobs/zigps-6b8297-quick/executions/zigps-6b8297-quick-l4ffj", latest.name);
    try testing.expectEqualStrings("zigps-6b8297-quick-l4ffj", latest.id);
    try testing.expectEqual(types.ExecutionStatus.succeeded, latest.status);
    try testing.expect(latest.create_time != null and latest.completion_time != null);
    // The template, with production's defaults filled in.
    try testing.expectEqual(1, job.task_count);
    try testing.expectEqual(0, job.parallelism);
    try testing.expectEqual(900, job.task_timeout_s.?);
    try testing.expectEqual(0, job.max_retries.?);
    try testing.expectEqualStrings("us-docker.pkg.dev/cloudrun/container/job", job.containers[0].image);
    try testing.expect(std.mem.endsWith(u8, job.service_account, "-compute@developer.gserviceaccount.com"));
    try testing.expectEqualStrings("probe", job.labels[0].value);
    try testing.expect(job.etag.len > 0);
    try testing.expect(job.ready());

    // A failed run leaves the job itself ready.
    const failed = try decodeJob(a, s, production.job_failed);
    try testing.expectEqual(types.ExecutionStatus.failed, failed.latest_created_execution.?.status);
    try testing.expect(failed.ready());
    const cancelled = try decodeJob(a, s, production.job_cancelled);
    try testing.expectEqual(types.ExecutionStatus.cancelled, cancelled.latest_created_execution.?.status);

    const page = try decodeJobPage(a, s, production.jobs_page);
    try testing.expectEqual(1, page.jobs.len);
    try testing.expectEqualStrings("zigps-6b8297-fail", page.jobs[0].id);
    try testing.expect(page.next_page_token != null);
    const empty = try decodeJobPage(a, s, "{}");
    try testing.expectEqual(0, empty.jobs.len);
    try testing.expectEqual(null, empty.next_page_token);
}

test "decodeExecution and its page: production's executions, running, cancelled and listed" {
    var out: std.heap.ArenaAllocator = .init(testing.allocator);
    defer out.deinit();
    var scratch: std.heap.ArenaAllocator = .init(testing.allocator);
    defer scratch.deinit();
    const a = out.allocator();
    const s = scratch.allocator();

    const running = try decodeExecution(a, s, production.execution_running);
    try testing.expectEqualStrings("zigps-6b8297-slow-nlzdb", running.id);
    try testing.expectEqualStrings("zigps-6b8297-slow", running.job);
    try testing.expectEqualStrings("us-central1", running.location);
    try testing.expectEqual(1, running.running_count);
    try testing.expectEqual(1, running.task_count);
    try testing.expectEqual(1, running.parallelism);
    try testing.expect(running.log_uri.len > 0);
    try testing.expect(running.start_time != null);
    try testing.expectEqual(null, running.completion_time);
    try testing.expectEqual(types.ExecutionStatus.running, running.status());
    try testing.expect(running.cancellable());

    const cancelled = try decodeExecution(a, s, production.execution_cancelled);
    try testing.expectEqual(types.ExecutionStatus.cancelled, cancelled.status());
    try testing.expectEqual(1, cancelled.cancelled_count);
    try testing.expectEqualStrings("Cancelled by user.", cancelled.condition("Completed").?.message);
    try testing.expect(!cancelled.cancellable());

    // Cancelled before it started: ended, though it never got a
    // completion time.
    const early = try decodeExecution(a, s, production.execution_cancelled_pending);
    try testing.expectEqual(types.ExecutionStatus.cancelled, early.status());
    try testing.expectEqual(null, early.completion_time);
    try testing.expectEqual(null, early.start_time);

    const page = try decodeExecutionPage(a, s, production.executions_page);
    try testing.expectEqual(2, page.executions.len);
    try testing.expectEqualStrings("zigps-6b8297-slow-54x76", page.executions[0].id);
    try testing.expectEqual(null, page.next_page_token);
    const one = try decodeExecutionPage(a, s, production.executions_page_one);
    try testing.expectEqual(1, one.executions.len);
    try testing.expect(one.next_page_token != null);
    // jobs/- lists every job's, newest first.
    const every = try decodeExecutionPage(a, s, production.executions_dash);
    try testing.expectEqual(5, every.executions.len);
    try testing.expectEqualStrings("zigps-6b8297-slow", every.executions[0].job);
    try testing.expectEqualStrings("zigps-6b8297-quick", every.executions[4].job);
    try testing.expectEqual(0, (try decodeExecutionPage(a, s, "{}")).executions.len);
}

test "decodeOperation: the writes' operations as production answered them" {
    var out: std.heap.ArenaAllocator = .init(testing.allocator);
    defer out.deinit();
    var scratch: std.heap.ArenaAllocator = .init(testing.allocator);
    defer scratch.deinit();
    const a = out.allocator();
    const s = scratch.allocator();

    // A run's first answer: not done, the new execution in its metadata.
    const run = try decodeOperation(a, s, production.operation_run);
    try testing.expectEqualStrings("projects/extractctl/locations/us-central1/operations/6d1e1e32-b691-4524-b5e5-53a92d560cce", run.name);
    try testing.expect(!run.done);
    try testing.expectEqual(null, run.failure);
    try testing.expectEqualStrings("zigps-6b8297-quick-l4ffj", run.subject.execution.id);
    try testing.expectEqual(types.ExecutionStatus.pending, run.subject.execution.status());

    // Done when the execution ended: the response is the execution.
    const done = try decodeOperation(a, s, production.operation_run_done);
    try testing.expect(done.done);
    try testing.expectEqual(types.ExecutionStatus.succeeded, done.subject.execution.status());
    try testing.expectEqual(1, done.subject.execution.succeeded_count);

    // A failed execution: an error, and no response, so the metadata.
    const failed = try decodeOperation(a, s, production.operation_run_failed);
    try testing.expect(failed.done);
    try testing.expectEqual(10, failed.failure.?.code);
    try testing.expectEqualStrings("Task zigps-6b8297-fail-ldg9n-task0 failed with exit code: 1 and message: The container exited with an error.", failed.failure.?.message);
    try testing.expectEqualStrings("zigps-6b8297-fail-ldg9n", failed.subject.execution.id);

    const cancel = try decodeOperation(a, s, production.operation_cancel);
    try testing.expect(!cancel.done);
    try testing.expectEqualStrings("zigps-6b8297-slow-nlzdb", cancel.subject.execution.id);

    const traffic = try decodeOperation(a, s, production.operation_traffic_done);
    try testing.expect(traffic.done);
    const service = traffic.subject.service;
    try testing.expectEqualStrings("zigps-6b8297", service.id);
    try testing.expectEqual(1, service.traffic.len);
    try testing.expectEqual(types.TrafficType.revision, service.traffic[0].type);
    try testing.expectEqualStrings("zigps-6b8297-00001-527", service.traffic[0].revision);
    try testing.expectEqual(100, service.traffic[0].percent);

    const missing = try decodeOperation(a, s, production.operation_traffic_failed);
    try testing.expectEqual(9, missing.failure.?.code);
    try testing.expect(std.mem.startsWith(u8, missing.failure.?.message, "Revision 'zigps-6b8297-00009-zzz' does not exist"));
    try testing.expectEqualStrings("zigps-6b8297", missing.subject.service.id);

    // Another type is named; no metadata at all is no subject.
    const other = try decodeOperation(a, s, "{\"name\":\"o\",\"metadata\":{\"@type\":\"type.googleapis.com/google.cloud.run.v2.Job\",\"name\":\"j\"}}");
    try testing.expectEqualStrings("type.googleapis.com/google.cloud.run.v2.Job", other.subject.other);
    const bare = try decodeOperation(a, s, "{\"name\":\"o\",\"done\":true}");
    try testing.expectEqual(types.Operation.Subject.none, bare.subject);
    try testing.expect(bare.done);
    // The response, once there is one, wins over the metadata.
    const both = try decodeOperation(a, s,
        \\{"name":"o","done":true,
        \\ "metadata":{"@type":"type.googleapis.com/google.cloud.run.v2.Execution","name":"projects/p/locations/l/jobs/j/executions/j-before"},
        \\ "response":{"@type":"type.googleapis.com/google.cloud.run.v2.Execution","name":"projects/p/locations/l/jobs/j/executions/j-after"}}
    );
    try testing.expectEqualStrings("j-after", both.subject.execution.id);
}

test "lenient where it can be, InvalidResponse where it cannot" {
    var out: std.heap.ArenaAllocator = .init(testing.allocator);
    defer out.deinit();
    var scratch: std.heap.ArenaAllocator = .init(testing.allocator);
    defer scratch.deinit();
    const a = out.allocator();
    const s = scratch.allocator();

    const bare = try decodeService(a, s, "{\"name\":\"s\",\"unknownField\":1}");
    try testing.expectEqualStrings("s", bare.id);
    try testing.expectEqualStrings("", bare.location);
    try testing.expect(!bare.ready());
    const strange = try decodeRevision(a, s,
        \\{"name":"r","conditions":[{"type":"Ready","state":"CONDITION_MOODY","revisionReason":"EXPIRED","severity":"FATAL"}],"generation":7}
    );
    try testing.expectEqual(types.ConditionState.unknown, strange.conditions[0].state);
    try testing.expectEqualStrings("EXPIRED", strange.conditions[0].reason);
    try testing.expectEqual(types.ConditionSeverity.unknown, strange.conditions[0].severity);
    try testing.expectEqual(7, strange.generation.?);
    try testing.expect(!strange.ready());

    for ([_][]const u8{
        "[]",
        "{\"services\":1}",
        "{\"services\":[{\"uri\":\"u\"}]}",
        "{\"revisions\":[{\"generation\":\"1\"}]}",
        "{\"name\":\"s\",\"generation\":true}",
        "{\"name\":\"s\",\"createTime\":\"yesterday\"}",
        "{\"name\":\"s\",\"conditions\":[1]}",
        "{\"name\":\"s\",\"labels\":{\"k\":1}}",
        "{\"name\":\"s\",\"urls\":[1]}",
        "{\"locations\":[{\"displayName\":\"x\"}]}",
        "{\"unreachable\":[1]}",
    }) |body| {
        const service_err = decodeService(a, s, body);
        const service_page_err = decodeServicePage(a, s, body);
        const revision_page_err = decodeRevisionPage(a, s, body);
        const location_err = decodeLocationPage(a, s, body);
        try testing.expect(service_err == error.InvalidResponse or service_page_err == error.InvalidResponse or
            revision_page_err == error.InvalidResponse or location_err == error.InvalidResponse);
    }

    // Jobs, executions and operations: each shape the decode cannot use.
    for ([_][]const u8{
        "{\"executionCount\":3}",
        "{\"name\":\"j\",\"executionCount\":\"many\"}",
        "{\"name\":\"j\",\"template\":{\"template\":{\"timeout\":\"10m\"}}}",
        "{\"name\":\"j\",\"template\":{\"template\":{\"timeout\":\"infs\"}}}",
        "{\"name\":\"j\",\"template\":{\"taskCount\":true}}",
        "{\"name\":\"j\",\"template\":{\"template\":{\"containers\":[1]}}}",
        "{\"name\":\"j\",\"latestCreatedExecution\":{\"name\":\"e\",\"createTime\":\"soon\"}}",
        "{\"name\":\"j\",\"latestCreatedExecution\":[]}",
    }) |body| try testing.expectError(error.InvalidResponse, decodeJob(a, s, body));
    for ([_][]const u8{
        "{\"runningCount\":1}",
        "{\"name\":\"e\",\"cancelledCount\":2147483648}",
        "{\"name\":\"e\",\"startTime\":1}",
        "{\"executions\":[{}]}",
    }) |body| {
        const one = decodeExecution(a, s, body);
        const page = decodeExecutionPage(a, s, body);
        try testing.expect(one == error.InvalidResponse or page == error.InvalidResponse);
    }
    for ([_][]const u8{
        "{\"done\":true}",
        "{\"name\":\"o\",\"done\":\"yes\"}",
        "{\"name\":\"o\",\"error\":{\"code\":\"nine\"}}",
        "{\"name\":\"o\",\"metadata\":{\"@type\":\"type.googleapis.com/google.cloud.run.v2.Execution\"}}",
        "{\"name\":\"o\",\"response\":{\"@type\":\"type.googleapis.com/google.cloud.run.v2.Service\",\"traffic\":1}}",
        "{\"name\":\"o\",\"metadata\":{\"@type\":7}}",
    }) |body| try testing.expectError(error.InvalidResponse, decodeOperation(a, s, body));
    // An unknown completion status and an unknown field are no refusal.
    const odd = try decodeJob(a, s, "{\"name\":\"projects/p/locations/l/jobs/j\",\"latestCreatedExecution\":{\"name\":\"j-1\",\"completionStatus\":\"EXECUTION_PAUSED\"},\"functionalType\":\"FUNCTIONAL_TYPE_AGENT\"}");
    try testing.expectEqual(types.ExecutionStatus.unknown, odd.latest_created_execution.?.status);
    try testing.expectEqualStrings("projects/p/locations/l/jobs/j/executions/j-1", odd.latest_created_execution.?.name);
    // An empty name names no execution, as `{}` does.
    const unnamed = try decodeJob(a, s, "{\"name\":\"projects/p/locations/l/jobs/j\",\"latestCreatedExecution\":{\"name\":\"\",\"completionStatus\":\"EXECUTION_RUNNING\"}}");
    try testing.expectEqual(null, unnamed.latest_created_execution);
    // A full name on the wire is kept as it is.
    const full = try decodeJob(a, s, "{\"name\":\"projects/p/locations/l/jobs/j\",\"latestCreatedExecution\":{\"name\":\"projects/p/locations/l/jobs/j/executions/j-2\"}}");
    try testing.expectEqualStrings("projects/p/locations/l/jobs/j/executions/j-2", full.latest_created_execution.?.name);
    try testing.expectEqualStrings("j-2", full.latest_created_execution.?.id);
}

fn decodersProperty(_: void, input: []const u8) !void {
    const test_util = @import("test_util.zig");
    var out: std.heap.ArenaAllocator = .init(test_util.propertyAllocator());
    defer out.deinit();
    var scratch: std.heap.ArenaAllocator = .init(test_util.propertyAllocator());
    defer scratch.deinit();
    const a = out.allocator();
    const s = scratch.allocator();
    inline for (.{
        decodeService, decodeServicePage, decodeRevision,  decodeRevisionPage,  decodeLocationPage,
        decodeJob,     decodeJobPage,     decodeExecution, decodeExecutionPage, decodeOperation,
    }) |decode| {
        if (decode(a, s, input)) |_| {} else |err| try testing.expectEqual(error.InvalidResponse, err);
    }
}

test "fuzz decoders: any body decodes or is InvalidResponse, never a crash or a leak" {
    try @import("test_util.zig").fuzzBytes({}, decodersProperty, .{ .corpus = &.{
        production.service_ready,
        production.service_failed,
        production.revision_ready,
        production.revisions_failed,
        production.services_list,
        production.services_dash,
        production.locations_v1,
        production.job_fresh,
        production.job_succeeded,
        production.jobs_page,
        production.execution_running,
        production.execution_cancelled_pending,
        production.executions_dash,
        production.operation_run,
        production.operation_run_failed,
        production.operation_traffic_done,
        "{\"services\":[{\"name\":\"projects/p/locations/l/services/s\",\"trafficStatuses\":[{\"type\":\"TRAFFIC_TARGET_ALLOCATION_TYPE_REVISION\",\"revision\":\"r\",\"percent\":50,\"tag\":\"blue\",\"uri\":\"https://blue---s.run.app\"}]}],\"unreachable\":[\"us-east7\"]}",
    } });
}
