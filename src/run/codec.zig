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
    };
}

fn revisionOf(out: Allocator, v: Value) DecodeError!types.Revision {
    const obj = try object(v);
    const name = try string(out, obj, "name") orelse return error.InvalidResponse;
    var containers: []types.Container = &.{};
    if (try field(obj, "containers", .array)) |list| {
        containers = try out.alloc(types.Container, list.items.len);
        for (list.items, containers) |item, *c| {
            const o = try object(item);
            c.* = .{
                .name = try string(out, o, "name") orelse "",
                .image = try string(out, o, "image") orelse "",
            };
        }
    }
    return .{
        .name = name,
        .id = trailing(name),
        .service = try string(out, obj, "service") orelse "",
        .location = segmentAfter(name, "/locations/"),
        .create_time = try time(obj, "createTime"),
        .update_time = try time(obj, "updateTime"),
        .generation = try integer(i64, obj, "generation"),
        .containers = containers,
        .conditions = try conditionList(out, obj),
        .log_uri = try string(out, obj, "logUri") orelse "",
        .service_account = try string(out, obj, "serviceAccount") orelse "",
        .labels = try labelMap(out, obj, "labels"),
    };
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

    // After the bad deploy: failed, the reason kept, latestReady stays.
    const failed = try decodeService(a, s, production.service_failed);
    try testing.expect(!failed.ready());
    try testing.expectEqual(types.ConditionState.failed, failed.terminal_condition.?.state);
    try testing.expectEqualStrings("REVISION_FAILED", failed.terminal_condition.?.reason);
    try testing.expect(std.mem.indexOf(u8, failed.terminal_condition.?.message, "not found") != null);
    try testing.expectEqualStrings("zigps-a12c61-00001-ct8", failed.latest_ready_revision);
    try testing.expectEqualStrings("zigps-a12c61-00002-qmv", failed.latest_created_revision);
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
}

fn decodersProperty(_: void, input: []const u8) !void {
    const test_util = @import("test_util.zig");
    var out: std.heap.ArenaAllocator = .init(test_util.propertyAllocator());
    defer out.deinit();
    var scratch: std.heap.ArenaAllocator = .init(test_util.propertyAllocator());
    defer scratch.deinit();
    const a = out.allocator();
    const s = scratch.allocator();
    inline for (.{ decodeService, decodeServicePage, decodeRevision, decodeRevisionPage, decodeLocationPage }) |decode| {
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
        "{\"services\":[{\"name\":\"projects/p/locations/l/services/s\",\"trafficStatuses\":[{\"type\":\"TRAFFIC_TARGET_ALLOCATION_TYPE_REVISION\",\"revision\":\"r\",\"percent\":50,\"tag\":\"blue\",\"uri\":\"https://blue---s.run.app\"}]}],\"unreachable\":[\"us-east7\"]}",
    } });
}
