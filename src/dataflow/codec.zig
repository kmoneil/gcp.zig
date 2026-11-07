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

/// `getMetrics`' answer: a time past every update answers the time and
/// no `metrics` (measured 2026-11-07).
pub fn decodeMetrics(out: Allocator, scratch: Allocator, body: []const u8) DecodeError!types.JobMetrics {
    const obj = try object(try parse(scratch, body));
    var updates: []types.MetricUpdate = &.{};
    if (try field(obj, "metrics", .array)) |list| {
        updates = try out.alloc(types.MetricUpdate, list.items.len);
        for (list.items, updates) |v, *u| u.* = try metricOf(out, try object(v));
    }
    return .{ .metric_time = try time(obj, "metricTime"), .updates = updates };
}

/// Checks a cancel's or a drain's answer, which carries nothing to keep:
/// production answered `{"type":"JOB_TYPE_BATCH"}` alone, the job's type
/// and no id or state (measured 2026-10-20). Anything but an object is
/// `error.InvalidResponse`, so a 200 from something that is not the API
/// is not taken for a stop.
pub fn checkStopAnswer(scratch: Allocator, body: []const u8) DecodeError!void {
    _ = try object(try parse(scratch, body));
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
        .pipeline = try pipelineOf(out, obj),
        .environment = try environmentOf(out, obj),
        .sdk = try sdkOf(out, obj),
        .steps = try stepsOf(out, obj),
    };
}

/// `pipelineDescription`, which a get at DESCRIPTION or ALL carries.
fn pipelineOf(out: Allocator, obj: std.json.ObjectMap) DecodeError!types.Pipeline {
    const pd = try field(obj, "pipelineDescription", .object) orelse return .{};
    return .{
        .transforms = try transformsOf(out, pd),
        .stages = try stagesOf(out, pd),
        .display_data = try displayDataOf(out, pd),
        .step_names_hash = try text(out, pd, "stepNamesHash"),
    };
}

fn transformsOf(out: Allocator, pd: std.json.ObjectMap) DecodeError![]const types.Transform {
    const list = try field(pd, "originalPipelineTransform", .array) orelse return &.{};
    const items = try out.alloc(types.Transform, list.items.len);
    for (list.items, items) |v, *t| {
        const o = try object(v);
        t.* = .{
            .id = try text(out, o, "id"),
            .name = try text(out, o, "name"),
            .kind = try kindOf(o),
            .input_collections = try strings(out, o, "inputCollectionName"),
            .output_collections = try strings(out, o, "outputCollectionName"),
            .display_data = try displayDataOf(out, o),
        };
    }
    return items;
}

fn stagesOf(out: Allocator, pd: std.json.ObjectMap) DecodeError![]const types.Stage {
    const list = try field(pd, "executionPipelineStage", .array) orelse return &.{};
    const items = try out.alloc(types.Stage, list.items.len);
    for (list.items, items) |v, *s| {
        const o = try object(v);
        s.* = .{
            .id = try text(out, o, "id"),
            .name = try text(out, o, "name"),
            .kind = try kindOf(o),
            .inputs = try sourcesOf(out, o, "inputSource"),
            .outputs = try sourcesOf(out, o, "outputSource"),
            .prerequisites = try strings(out, o, "prerequisiteStage"),
            .transforms = try componentsOf(out, o, "componentTransform", "originalTransform"),
            .sources = try componentsOf(out, o, "componentSource", "originalTransformOrCollection"),
        };
    }
    return items;
}

fn kindOf(o: std.json.ObjectMap) DecodeError!types.TransformKind {
    return if (try field(o, "kind", .string)) |name| types.TransformKind.fromWire(name) else .unknown;
}

fn sourcesOf(out: Allocator, o: std.json.ObjectMap, name: []const u8) DecodeError![]const types.StageSource {
    const list = try field(o, name, .array) orelse return &.{};
    const items = try out.alloc(types.StageSource, list.items.len);
    for (list.items, items) |v, *s| {
        const so = try object(v);
        s.* = .{
            .name = try text(out, so, "name"),
            .user_name = try text(out, so, "userName"),
            .original = try text(out, so, "originalTransformOrCollection"),
            .size_bytes = try integer(i64, so, "sizeBytes"),
        };
    }
    return items;
}

fn componentsOf(out: Allocator, o: std.json.ObjectMap, name: []const u8, original: []const u8) DecodeError![]const types.StageComponent {
    const list = try field(o, name, .array) orelse return &.{};
    const items = try out.alloc(types.StageComponent, list.items.len);
    for (list.items, items) |v, *c| {
        const co = try object(v);
        c.* = .{
            .name = try text(out, co, "name"),
            .user_name = try text(out, co, "userName"),
            .original = try text(out, co, original),
        };
    }
    return items;
}

/// An object's `displayData` list.
fn displayDataOf(out: Allocator, o: std.json.ObjectMap) DecodeError![]const types.DisplayData {
    const list = try field(o, "displayData", .array) orelse return &.{};
    const items = try out.alloc(types.DisplayData, list.items.len);
    for (list.items, items) |v, *d| {
        const dd = try object(v);
        d.* = .{
            .key = try text(out, dd, "key"),
            .namespace = try text(out, dd, "namespace"),
            .label = try text(out, dd, "label"),
            .url = try text(out, dd, "url"),
            .value = try displayValueOf(out, dd),
            .short = try text(out, dd, "shortStrValue"),
        };
    }
    return items;
}

/// A datum's value, from the first of the wire's value fields it has.
fn displayValueOf(out: Allocator, dd: std.json.ObjectMap) DecodeError!types.DisplayValue {
    if (try string(out, dd, "strValue")) |s| return .{ .string = s };
    if (try integer(i64, dd, "int64Value")) |n| return .{ .integer = n };
    if (try float(dd, "floatValue")) |f| return .{ .float = f };
    if (try field(dd, "boolValue", .bool)) |b| return .{ .boolean = b };
    if (try time(dd, "timestampValue")) |t| return .{ .timestamp = t };
    if (try string(out, dd, "durationValue")) |s| return .{ .duration = s };
    if (try string(out, dd, "javaClassValue")) |s| return .{ .java_class = s };
    return .none;
}

/// `environment`, keeping the named fields and skipping the raw pipeline
/// options, user agent and version maps.
fn environmentOf(out: Allocator, obj: std.json.ObjectMap) DecodeError!types.Environment {
    const e = try field(obj, "environment", .object) orelse return .{};
    return .{
        .service_account = try text(out, e, "serviceAccountEmail"),
        .worker_region = try text(out, e, "workerRegion"),
        .worker_zone = try text(out, e, "workerZone"),
        .experiments = try strings(out, e, "experiments"),
        .service_options = try strings(out, e, "serviceOptions"),
        .shuffle_mode = try text(out, e, "shuffleMode"),
        .streaming_mode = try text(out, e, "streamingMode"),
        .flex_resource_scheduling_goal = try text(out, e, "flexResourceSchedulingGoal"),
        .temp_storage_prefix = try text(out, e, "tempStoragePrefix"),
        .dataset = try text(out, e, "dataset"),
        .service_kms_key_name = try text(out, e, "serviceKmsKeyName"),
        .use_public_ips = try field(e, "usePublicIps", .bool),
        .worker_pools = try poolsOf(out, e),
    };
}

/// The worker pools, skipping each pool's packages and metadata.
fn poolsOf(out: Allocator, e: std.json.ObjectMap) DecodeError![]const types.WorkerPool {
    const list = try field(e, "workerPools", .array) orelse return &.{};
    const items = try out.alloc(types.WorkerPool, list.items.len);
    for (list.items, items) |v, *p| {
        const o = try object(v);
        const scaling = try field(o, "autoscalingSettings", .object);
        p.* = .{
            .kind = try text(out, o, "kind"),
            .machine_type = try text(out, o, "machineType"),
            .num_workers = try integer(i64, o, "numWorkers"),
            .max_workers = if (scaling) |s| try integer(i64, s, "maxNumWorkers") else null,
            .autoscaling_algorithm = if (scaling) |s| try text(out, s, "algorithm") else "",
            .disk_size_gb = try integer(i64, o, "diskSizeGb"),
            .disk_type = try text(out, o, "diskType"),
            .zone = try text(out, o, "zone"),
            .network = try text(out, o, "network"),
            .subnetwork = try text(out, o, "subnetwork"),
            .ip_configuration = try text(out, o, "ipConfiguration"),
            .teardown_policy = try text(out, o, "teardownPolicy"),
            .on_host_maintenance = try text(out, o, "onHostMaintenance"),
            .harness_image = try text(out, o, "workerHarnessContainerImage"),
        };
    }
    return items;
}

/// `jobMetadata.sdkVersion`.
fn sdkOf(out: Allocator, obj: std.json.ObjectMap) DecodeError!types.Sdk {
    const meta = try field(obj, "jobMetadata", .object) orelse return .{};
    const sdk = try field(meta, "sdkVersion", .object) orelse return .{};
    return .{
        .version = try text(out, sdk, "version"),
        .name = try text(out, sdk, "versionDisplayName"),
        .support = if (try field(sdk, "sdkSupportStatus", .string)) |name| types.SdkSupportStatus.fromWire(name) else .unknown,
    };
}

/// `steps`, which only ALL carries, each step's properties as JSON text.
fn stepsOf(out: Allocator, obj: std.json.ObjectMap) DecodeError![]const types.Step {
    const list = try field(obj, "steps", .array) orelse return &.{};
    const items = try out.alloc(types.Step, list.items.len);
    for (list.items, items) |v, *s| {
        const o = try object(v);
        s.* = .{
            .kind = try text(out, o, "kind"),
            .name = try text(out, o, "name"),
            .properties = if (try field(o, "properties", .object)) |p| try json(out, .{ .object = p }) else "",
        };
    }
    return items;
}

fn metricOf(out: Allocator, o: std.json.ObjectMap) DecodeError!types.MetricUpdate {
    const name = try field(o, "name", .object);
    const context = if (name) |n| try labelMap(out, n, "context") else &.{};
    var tentative = false;
    for (context) |c| {
        if (std.mem.eql(u8, c.key, "tentative") and std.mem.eql(u8, c.value, "true")) tentative = true;
    }
    return .{
        .origin = if (name) |n| try text(out, n, "origin") else "",
        .name = if (name) |n| try text(out, n, "name") else "",
        .context = context,
        .tentative = tentative,
        .value = try metricValueOf(out, o),
        .update_time = try time(o, "updateTime"),
        .kind = try text(out, o, "kind"),
        .cumulative = try field(o, "cumulative", .bool),
    };
}

/// The update's value: `scalar` typed when it is a number or a Boolean,
/// a mean as its sum and count together, anything else as its field's
/// JSON text.
fn metricValueOf(out: Allocator, o: std.json.ObjectMap) DecodeError!types.MetricValue {
    if (o.get("scalar")) |v| switch (v) {
        .null => {},
        .number_string => |s| return numberValue(s),
        .bool => |b| return .{ .boolean = b },
        else => return .{ .other = .{ .field = "scalar", .json = try json(out, v) } },
    };
    const sum = o.get("meanSum");
    const count = o.get("meanCount");
    if (sum != null or count != null) return .{ .other = .{
        .field = "mean",
        .json = try std.fmt.allocPrint(out, "{{\"meanSum\":{s},\"meanCount\":{s}}}", .{
            if (sum) |s| try json(out, s) else "null",
            if (count) |c| try json(out, c) else "null",
        }),
    } };
    inline for (.{ "distribution", "set", "gauge", "trie", "boundedTrie", "internal" }) |name| {
        if (o.get(name)) |v| if (v != .null) return .{ .other = .{ .field = name, .json = try json(out, v) } };
    }
    return .none;
}

/// A JSON number as an integer when it is one that fits, else a float.
fn numberValue(s: []const u8) DecodeError!types.MetricValue {
    if (std.fmt.parseInt(i64, s, 10)) |n| return .{ .integer = n } else |_| {}
    const f = std.fmt.parseFloat(f64, s) catch return error.InvalidResponse;
    return .{ .float = f };
}

/// A value written back as JSON, in `out`.
fn json(out: Allocator, v: Value) DecodeError![]const u8 {
    return std.json.Stringify.valueAlloc(out, v, .{});
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
    const value = try field(obj, name, .string) orelse return null;
    return try out.dupe(u8, value);
}

/// A string field, or "" when it is absent.
fn text(out: Allocator, obj: std.json.ObjectMap, name: []const u8) DecodeError![]const u8 {
    return try string(out, obj, name) orelse "";
}

/// A list of strings, empty when absent.
fn strings(out: Allocator, obj: std.json.ObjectMap, name: []const u8) DecodeError![]const []const u8 {
    const list = try field(obj, name, .array) orelse return &.{};
    const items = try out.alloc([]const u8, list.items.len);
    for (list.items, items) |v, *s| s.* = switch (v) {
        .string => |t| try out.dupe(u8, t),
        else => return error.InvalidResponse,
    };
    return items;
}

/// A double, which proto3 JSON sends as a number or as a string ("NaN").
fn float(obj: std.json.ObjectMap, name: []const u8) DecodeError!?f64 {
    const v = obj.get(name) orelse return null;
    const t = switch (v) {
        .null => return null,
        .number_string, .string => |s| s,
        else => return error.InvalidResponse,
    };
    return std.fmt.parseFloat(f64, t) catch error.InvalidResponse;
}

/// `nextPageToken`: "" means the last page.
fn token(out: Allocator, obj: std.json.ObjectMap) DecodeError!?[]const u8 {
    const value = try field(obj, "nextPageToken", .string) orelse return null;
    if (value.len == 0) return null;
    return try out.dupe(u8, value);
}

fn time(obj: std.json.ObjectMap, name: []const u8) DecodeError!?std.Io.Timestamp {
    const value = try field(obj, name, .string) orelse return null;
    return core.timestamp.parse(value) catch error.InvalidResponse;
}

/// An integer that may arrive as a JSON number or a string, as proto3
/// JSON sends int64s ("targetNumWorkers": "1").
fn integer(comptime T: type, obj: std.json.ObjectMap, name: []const u8) DecodeError!?T {
    const v = obj.get(name) orelse return null;
    const digits = switch (v) {
        .null => return null,
        .number_string, .string => |s| s,
        else => return error.InvalidResponse,
    };
    return std.fmt.parseInt(T, digits, 10) catch error.InvalidResponse;
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

test "decodeJob: a job in full at ALL, as production answered it" {
    var out: std.heap.ArenaAllocator = .init(testing.allocator);
    defer out.deinit();
    var scratch: std.heap.ArenaAllocator = .init(testing.allocator);
    defer scratch.deinit();
    const job = try decodeJob(out.allocator(), scratch.allocator(), production.job_detail_all);
    try testing.expectEqualStrings("2026-11-07_12_14_27-5029885235339452204", job.id);
    try testing.expectEqual(types.JobState.done, job.current_state);

    // The graph: the user's transforms (trimmed to 4 of 36) and the
    // stages the service fused them into (3 of 16).
    const p = job.pipeline;
    try testing.expectEqual(4, p.transforms.len);
    try testing.expectEqual(types.TransformKind.group_by_key, p.transforms[0].kind);
    try testing.expectEqual(types.TransformKind.par_do, p.transforms[1].kind);
    try testing.expectEqual(2, p.transforms[2].output_collections.len);
    try testing.expectEqual(1, p.transforms[2].input_collections.len);
    try testing.expectEqual(2, p.transforms[3].display_data.len);
    try testing.expectEqual(3, p.stages.len);
    try testing.expectEqualStrings("S16", p.stages[0].id);
    try testing.expectEqualStrings("F56", p.stages[0].name);
    try testing.expectEqual(types.TransformKind.par_do, p.stages[0].kind);
    try testing.expectEqual(67108864, p.stages[0].inputs[0].size_bytes.?);
    try testing.expectEqual(134217728, p.stages[2].inputs[1].size_bytes.?);
    try testing.expectEqual(1, p.stages[1].outputs.len);
    try testing.expectEqual(1, p.stages[0].prerequisites.len);
    try testing.expectEqual(2, p.stages[0].transforms.len);
    try testing.expect(p.stages[0].transforms[0].original.len > 0);
    try testing.expectEqual(2, p.stages[0].sources.len);
    try testing.expectEqualStrings("2b3e50bcca87d926a47ca95eba4872b6c66f175d9d03e2be69a3a0e02944bcfc", p.step_names_hash);

    // The settings it was launched with: Beam's options under their
    // namespaces, the template service's under its own, the template's
    // parameters under none.
    try testing.expectEqual(19, p.display_data.len);
    try testing.expectEqualStrings("gs://dataflow-samples/shakespeare/kinglear.txt", job.parameter("inputFile").?.string);
    try testing.expectEqualStrings("gs://zigps-df-detail-82456/out/wc", job.parameter("output").?.string);
    try testing.expectEqual(null, job.parameter("region"));
    try testing.expectEqual(null, job.parameter("maxNumWorkers"));
    for (p.display_data) |d| {
        if (std.mem.eql(u8, d.key, "maxNumWorkers")) {
            try testing.expectEqualStrings("google.dataflow.v1beta3.TemplatesService", d.namespace);
            try testing.expectEqual(1, d.value.integer);
        }
        if (std.mem.eql(u8, d.key, "region")) try testing.expectEqualStrings("us-central1", d.value.string);
    }
    const template = job.template().?;
    try testing.expectEqualStrings("word_count", template.name);
    try testing.expectEqualStrings("2026-10-27-00_rc00", template.version);
    try testing.expectEqualStrings("legacy", template.type);

    // Where and as whom it ran, the pool's packages and metadata skipped.
    const e = job.environment;
    try testing.expectEqualStrings("82150720798-compute@developer.gserviceaccount.com", e.service_account);
    try testing.expectEqual(6, e.experiments.len);
    try testing.expectEqualStrings("enable_oom_sampler", e.experiments[0]);
    try testing.expectEqualStrings("SERVICE_BASED", e.shuffle_mode);
    try testing.expectEqual(true, e.use_public_ips.?);
    try testing.expectEqualStrings("bigquery.googleapis.com/cloud_dataflow", e.dataset);
    try testing.expectEqual(1, e.worker_pools.len);
    const pool = e.worker_pools[0];
    try testing.expectEqualStrings("harness", pool.kind);
    try testing.expectEqualStrings("n1-standard-1", pool.machine_type);
    try testing.expectEqual(2, pool.num_workers.?);
    try testing.expectEqual(1, pool.max_workers.?);
    try testing.expectEqual(30, pool.disk_size_gb.?);
    try testing.expectEqualStrings("default", pool.network);
    try testing.expectEqualStrings("TEARDOWN_ALWAYS", pool.teardown_policy);
    try testing.expectEqualStrings("gcr.io/cloud-dataflow/v1beta3/beam-java17-batch:2.77.0", pool.harness_image);
    try testing.expectEqualStrings("", pool.zone);

    try testing.expectEqualStrings("2.77.0", job.sdk.version);
    try testing.expectEqualStrings("Apache Beam SDK for Java", job.sdk.name);
    try testing.expectEqual(types.SdkSupportStatus.supported, job.sdk.support);

    // ALL's steps, their properties kept as JSON text that reads back.
    try testing.expectEqual(3, job.steps.len);
    try testing.expectEqualStrings("ParallelRead", job.steps[0].kind);
    try testing.expectEqualStrings("ReadLines-Read-Impulse", job.steps[0].name);
    const props = try std.json.parseFromSliceLeaky(Value, scratch.allocator(), job.steps[2].properties, .{});
    try testing.expect(props.object.get("serialized_fn") != null);
    try testing.expectEqualStrings("ParallelDo", job.steps[2].kind);
}

test "decodeJob: a summary carries no pipeline, environment or steps, but the SDK" {
    var out: std.heap.ArenaAllocator = .init(testing.allocator);
    defer out.deinit();
    var scratch: std.heap.ArenaAllocator = .init(testing.allocator);
    defer scratch.deinit();
    const page = try decodeJobPage(out.allocator(), scratch.allocator(), production.jobs_list);
    for (page.jobs) |job| {
        try testing.expectEqual(0, job.pipeline.transforms.len);
        try testing.expectEqual(0, job.pipeline.display_data.len);
        try testing.expectEqual(0, job.environment.worker_pools.len);
        try testing.expectEqual(0, job.steps.len);
        // Lists answer `jobMetadata`, and with it the SDK (measured
        // 2026-10-20).
        try testing.expectEqualStrings("2.76.0", job.sdk.version);
        try testing.expectEqual(null, job.parameter("inputFile"));
    }
    // A job no template labels: no template.
    const bare = try decodeJob(out.allocator(), scratch.allocator(), "{\"id\":\"j\",\"labels\":{\"team\":\"data\"}}");
    try testing.expectEqual(null, bare.template());
}

test "decodeMetrics: production's updates, each beside its tentative twin, integers and floats" {
    var out: std.heap.ArenaAllocator = .init(testing.allocator);
    defer out.deinit();
    var scratch: std.heap.ArenaAllocator = .init(testing.allocator);
    defer scratch.deinit();
    const m = try decodeMetrics(out.allocator(), scratch.allocator(), production.metrics_done);
    try testing.expect(m.metric_time != null);
    try testing.expectEqual(12, m.updates.len);

    const first = m.updates[0];
    try testing.expectEqualStrings("dataflow/v1b3", first.origin);
    try testing.expectEqualStrings("TotalVcpuTime", first.name);
    try testing.expect(first.tentative);
    try testing.expectEqual(103, first.value.integer);
    try testing.expectEqualStrings("Service-cpu_num_seconds", first.contextValue("original_name").?);
    try testing.expect(first.update_time != null);
    try testing.expectEqualStrings("", first.kind);
    try testing.expectEqual(null, first.cumulative);
    // Its committed twin: the same value, no tentative key.
    const committed = m.updates[1];
    try testing.expect(!committed.tentative);
    try testing.expectEqual(null, committed.contextValue("tentative"));
    try testing.expectEqual(103, committed.value.integer);

    // The template's own counter, under its namespace and step.
    const user = m.updates[7];
    try testing.expectEqualStrings("user", user.origin);
    try testing.expectEqualStrings("emptyLines", user.name);
    try testing.expect(!user.tentative);
    try testing.expectEqual(1663, user.value.integer);
    try testing.expectEqualStrings("com.google.cloud.teleport.templates.WordCount$ExtractWordsFn", user.contextValue("namespace").?);
    try testing.expect(std.mem.startsWith(u8, user.contextValue("step").?, "WordCount-CountWords"));

    // A float, as production sent four of them.
    try testing.expectEqualStrings("TotalShuffleDataProcessed", m.updates[9].name);
    try testing.expectApproxEqRel(6.410107016563416e-05, m.updates[9].value.float, 1e-12);

    // A start past every update: the time, and nothing else.
    const none = try decodeMetrics(out.allocator(), scratch.allocator(), production.metrics_future_start);
    try testing.expectEqual(0, none.updates.len);
    try testing.expect(none.metric_time != null);
}

test "decodeMetrics: the value forms production did not send" {
    var out: std.heap.ArenaAllocator = .init(testing.allocator);
    defer out.deinit();
    var scratch: std.heap.ArenaAllocator = .init(testing.allocator);
    defer scratch.deinit();
    const m = try decodeMetrics(out.allocator(), scratch.allocator(),
        \\{"metrics":[
        \\ {"name":{"origin":"user","name":"allOk"},"scalar":true,"kind":"And","cumulative":true},
        \\ {"name":{"name":"meanLatency"},"meanSum":12.5,"meanCount":"5"},
        \\ {"name":{"name":"sizes"},"distribution":{"count":3,"min":1}},
        \\ {"name":{"name":"tags"},"set":["a","b"]},
        \\ {"name":{"name":"odd"},"scalar":"7"},
        \\ {"name":{"name":"big"},"scalar":12345678901234567890},
        \\ {"name":{"name":"empty"}}
        \\]}
    );
    try testing.expect(m.updates[0].value.boolean);
    try testing.expectEqualStrings("And", m.updates[0].kind);
    try testing.expect(m.updates[0].cumulative.?);
    try testing.expectEqualStrings("mean", m.updates[1].value.other.field);
    try testing.expectEqualStrings("{\"meanSum\":12.5,\"meanCount\":\"5\"}", m.updates[1].value.other.json);
    try testing.expectEqualStrings("distribution", m.updates[2].value.other.field);
    try testing.expectEqualStrings("{\"count\":3,\"min\":1}", m.updates[2].value.other.json);
    try testing.expectEqualStrings("set", m.updates[3].value.other.field);
    try testing.expectEqualStrings("scalar", m.updates[4].value.other.field);
    try testing.expectEqualStrings("\"7\"", m.updates[4].value.other.json);
    // Past i64: a float, not a refusal.
    try testing.expectApproxEqRel(12345678901234567890.0, m.updates[5].value.float, 1e-15);
    try testing.expectEqual(MetricValueTag.none, std.meta.activeTag(m.updates[6].value));
    try testing.expectEqualStrings("", m.updates[6].origin);
}

const MetricValueTag = std.meta.Tag(types.MetricValue);

test "decodeJob and decodeMetrics: a detail or a metric of the wrong shape is InvalidResponse" {
    var out: std.heap.ArenaAllocator = .init(testing.allocator);
    defer out.deinit();
    var scratch: std.heap.ArenaAllocator = .init(testing.allocator);
    defer scratch.deinit();
    const a = out.allocator();
    const s = scratch.allocator();
    for ([_][]const u8{
        "{\"id\":\"j\",\"pipelineDescription\":1}",
        "{\"id\":\"j\",\"pipelineDescription\":{\"originalPipelineTransform\":[1]}}",
        "{\"id\":\"j\",\"pipelineDescription\":{\"originalPipelineTransform\":[{\"inputCollectionName\":[1]}]}}",
        "{\"id\":\"j\",\"pipelineDescription\":{\"executionPipelineStage\":[{\"inputSource\":[{\"sizeBytes\":\"big\"}]}]}}",
        "{\"id\":\"j\",\"pipelineDescription\":{\"displayData\":[{\"int64Value\":true}]}}",
        "{\"id\":\"j\",\"pipelineDescription\":{\"displayData\":[{\"floatValue\":\"x\"}]}}",
        "{\"id\":\"j\",\"pipelineDescription\":{\"displayData\":[{\"timestampValue\":\"soon\"}]}}",
        "{\"id\":\"j\",\"environment\":[]}",
        "{\"id\":\"j\",\"environment\":{\"experiments\":[1]}}",
        "{\"id\":\"j\",\"environment\":{\"workerPools\":[{\"numWorkers\":true}]}}",
        "{\"id\":\"j\",\"environment\":{\"workerPools\":[{\"autoscalingSettings\":1}]}}",
        "{\"id\":\"j\",\"environment\":{\"usePublicIps\":\"yes\"}}",
        "{\"id\":\"j\",\"jobMetadata\":{\"sdkVersion\":{\"version\":2}}}",
        "{\"id\":\"j\",\"steps\":[{\"properties\":[]}]}",
    }) |body| try testing.expectError(error.InvalidResponse, decodeJob(a, s, body));
    for ([_][]const u8{
        "[]",
        "{\"metrics\":1}",
        "{\"metrics\":[1]}",
        "{\"metricTime\":\"soon\"}",
        "{\"metrics\":[{\"name\":1}]}",
        "{\"metrics\":[{\"name\":{\"context\":{\"k\":1}}}]}",
        "{\"metrics\":[{\"updateTime\":\"soon\"}]}",
        "{\"metrics\":[{\"cumulative\":\"yes\"}]}",
    }) |body| try testing.expectError(error.InvalidResponse, decodeMetrics(a, s, body));
}

test "decodeJob and decodeMetrics: every allocation failure is OutOfMemory without leaks" {
    const Run = struct {
        fn decode(gpa: Allocator) !void {
            var out: std.heap.ArenaAllocator = .init(gpa);
            defer out.deinit();
            var scratch: std.heap.ArenaAllocator = .init(gpa);
            defer scratch.deinit();
            _ = try decodeJob(out.allocator(), scratch.allocator(), production.job_detail_all);
            _ = try decodeMetrics(out.allocator(), scratch.allocator(), production.metrics_done);
        }
    };
    try testing.checkAllAllocationFailures(testing.allocator, Run.decode, .{});
}

fn decodersProperty(_: void, input: []const u8) !void {
    const test_util = @import("test_util.zig");
    var out: std.heap.ArenaAllocator = .init(test_util.propertyAllocator());
    defer out.deinit();
    var scratch: std.heap.ArenaAllocator = .init(test_util.propertyAllocator());
    defer scratch.deinit();
    const a = out.allocator();
    const s = scratch.allocator();
    inline for (.{ decodeJob, decodeJobPage, decodeMessagePage, decodeMetrics }) |decode| {
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
        production.job_detail_all,
        production.metrics_done,
        production.metrics_future_start,
        "{\"metrics\":[{\"name\":{\"name\":\"m\"},\"meanSum\":1,\"meanCount\":2},{\"scalar\":true},{\"distribution\":{}}]}",
        "{\"jobs\":[{\"id\":\"j1\",\"stageStates\":[{\"executionStageName\":\"s01\",\"executionStageState\":\"JOB_STATE_DONE\",\"currentStateTime\":\"2026-10-20T14:20:00Z\"}]}],\"failedLocation\":[{\"name\":\"us-west1\"}],\"nextPageToken\":\"t\"}",
    } });
}
