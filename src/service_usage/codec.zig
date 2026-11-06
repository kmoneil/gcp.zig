//! Decoders for Service Usage's JSON, lenient the way the other modules
//! are: unknown fields skipped, an unknown state read as `.unknown`. A
//! service without a name this library can take apart is
//! `error.InvalidResponse`, since every call about it takes that name.
//!
//! The client asks for only what it decodes (`fields`, below): a service's
//! whole configuration is large (Compute Engine's was 1.39 MB, 293 bytes
//! under the mask, measured).

const std = @import("std");
const Allocator = std.mem.Allocator;
const Value = std.json.Value;
const ObjectMap = std.json.ObjectMap;
const types = @import("types.zig");

pub const DecodeError = error{ OutOfMemory, InvalidResponse };

/// The fields mask of a get: a service's name, title, summary and state.
pub const service_fields = "name,config(name,title,documentation/summary),state";
/// The fields mask of a list: each service's, and the next page's token.
pub const list_fields = "services(" ++ service_fields ++ "),nextPageToken";
/// The fields mask of a batch get.
pub const batch_fields = "services(" ++ service_fields ++ ")";

/// A service, as get answers.
pub fn decodeService(out: Allocator, scratch: Allocator, body: []const u8) DecodeError!types.Service {
    return serviceOf(out, try object(try parse(scratch, body)));
}

/// A page of `services.list`: no `services` is an empty page.
pub fn decodeServicePage(out: Allocator, scratch: Allocator, body: []const u8) DecodeError!types.ServicePage {
    const obj = try object(try parse(scratch, body));
    return .{ .services = try serviceList(out, obj), .next_page_token = try token(out, obj, "nextPageToken") };
}

/// `services.batchGet`'s answer: the services in the order asked.
pub fn decodeServices(out: Allocator, scratch: Allocator, body: []const u8) DecodeError![]const types.Service {
    return serviceList(out, try object(try parse(scratch, body)));
}

fn serviceList(out: Allocator, obj: ObjectMap) DecodeError![]const types.Service {
    const list = try field(obj, "services", .array);
    const services = try out.alloc(types.Service, if (list) |l| l.items.len else 0);
    if (list) |l| for (l.items, services) |v, *s| {
        s.* = try serviceOf(out, try object(v));
    };
    return services;
}

/// `projects/{number}/services/{name}`, as production names every service.
pub const ServiceName = struct { project: []const u8, service: []const u8 };

pub fn parseName(name: []const u8) ?ServiceName {
    const prefix = "projects/";
    if (!std.mem.startsWith(u8, name, prefix)) return null;
    const rest = name[prefix.len..];
    const slash = std.mem.indexOf(u8, rest, "/services/") orelse return null;
    const project = rest[0..slash];
    const service = rest[slash + "/services/".len ..];
    if (project.len == 0 or service.len == 0) return null;
    if (std.mem.indexOfScalar(u8, project, '/') != null or std.mem.indexOfScalar(u8, service, '/') != null) return null;
    return .{ .project = project, .service = service };
}

fn serviceOf(out: Allocator, obj: ObjectMap) DecodeError!types.Service {
    const name = try field(obj, "name", .string) orelse return error.InvalidResponse;
    const parsed = parseName(name) orelse return error.InvalidResponse;
    var service: types.Service = .{
        .name = try out.dupe(u8, parsed.service),
        .project_number = try out.dupe(u8, parsed.project),
        .state = if (try field(obj, "state", .string)) |s| types.State.fromWire(s) else .unknown,
    };
    if (try field(obj, "config", .object)) |config| {
        service.title = try string(out, config, "title") orelse "";
        if (try field(config, "documentation", .object)) |doc| service.summary = try string(out, doc, "summary") orelse "";
    }
    return service;
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

/// A page token: "" or none means the last page.
fn token(out: Allocator, obj: ObjectMap, name: []const u8) DecodeError!?[]const u8 {
    const text = try field(obj, name, .string) orelse return null;
    if (text.len == 0) return null;
    return try out.dupe(u8, text);
}

const testing = std.testing;
const production = @import("production_bodies.zig");

test "production's answers decode: names, titles, summaries as given, states and pages" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const pubsub = try decodeService(a, a, production.get_enabled);
    try testing.expectEqualStrings("pubsub.googleapis.com", pubsub.name);
    try testing.expectEqualStrings("Cloud Pub/Sub API", pubsub.title);
    try testing.expectEqualStrings("Provides reliable, many-to-many, asynchronous messaging between applications.\n", pubsub.summary);
    try testing.expectEqual(types.State.enabled, pubsub.state);
    try testing.expectEqualStrings("82150720798", pubsub.project_number);

    const bare = try decodeService(a, a, production.get_no_summary);
    try testing.expectEqualStrings("Backup and DR Service API", bare.title);
    try testing.expectEqualStrings("", bare.summary);
    const off = try decodeService(a, a, production.get_disabled);
    try testing.expectEqual(types.State.disabled, off.state);
    try testing.expectEqualStrings("a10-thunder-adc-601b150-byol.endpoints.a10networks-public-396315.cloud.goog", off.name);
    // The alias asked for is answered under the service's own name.
    try testing.expectEqualStrings("pubsub.googleapis.com", (try decodeService(a, a, production.get_alias)).name);

    const first = try decodeServicePage(a, a, production.list_enabled_page);
    try testing.expectEqual(3, first.services.len);
    try testing.expectEqualStrings("analyticshub.googleapis.com", first.services[0].name);
    try testing.expectEqualStrings("ZW5hYmxlZC1zZXJ2aWNlcy1vZmZzZXQ6Mw==", first.next_page_token.?);
    const every = try decodeServicePage(a, a, production.list_enabled_all);
    try testing.expectEqual(45, every.services.len);
    try testing.expectEqual(null, every.next_page_token);
    var summaries: usize = 0;
    var newlines: usize = 0;
    for (every.services, 0..) |s, i| {
        try testing.expectEqual(types.State.enabled, s.state);
        if (i > 0) try testing.expect(std.mem.lessThan(u8, every.services[i - 1].name, s.name));
        if (s.summary.len > 0) summaries += 1;
        if (std.mem.endsWith(u8, s.summary, "\n")) newlines += 1;
    }
    try testing.expectEqual(43, summaries);
    try testing.expectEqual(13, newlines);
    const disabled = try decodeServicePage(a, a, production.list_disabled_page);
    try testing.expectEqual(2, disabled.services.len);
    try testing.expect(disabled.next_page_token.?.len > 100);

    const two = try decodeServices(a, a, production.batch_two);
    try testing.expectEqual(2, two.len);
    try testing.expectEqualStrings("pubsub.googleapis.com", two[0].name);
    try testing.expectEqual(types.State.disabled, two[1].state);
}

test "what a decoder will not take, and what it reads leniently" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try testing.expectError(error.InvalidResponse, decodeService(a, a, "{}"));
    try testing.expectError(error.InvalidResponse, decodeService(a, a, "{\"name\":\"pubsub.googleapis.com\"}"));
    try testing.expectError(error.InvalidResponse, decodeService(a, a, "{\"name\":\"projects/1/services/\"}"));
    try testing.expectError(error.InvalidResponse, decodeService(a, a, "{\"name\":\"projects//services/x\"}"));
    try testing.expectError(error.InvalidResponse, decodeService(a, a, "{\"name\":\"projects/1/services/a/b\"}"));
    try testing.expectError(error.InvalidResponse, decodeService(a, a, "{\"name\":7}"));
    try testing.expectError(error.InvalidResponse, decodeService(a, a, "{\"name\":\"projects/1/services/x\",\"config\":[]}"));
    try testing.expectError(error.InvalidResponse, decodeServicePage(a, a, "{\"services\":{}}"));
    try testing.expectError(error.InvalidResponse, decodeServicePage(a, a, "{\"services\":[1]}"));
    try testing.expectError(error.InvalidResponse, decodeServices(a, a, "[]"));
    try testing.expectError(error.InvalidResponse, decodeServices(a, a, "{"));
    const odd = try decodeService(a, a, "{\"name\":\"projects/1/services/x\",\"state\":\"STATE_UNSPECIFIED\",\"extra\":1}");
    try testing.expectEqual(types.State.unknown, odd.state);
    try testing.expectEqualStrings("", odd.title);
    try testing.expectEqual(types.State.unknown, (try decodeService(a, a, "{\"name\":\"projects/1/services/x\",\"state\":\"PAUSED\"}")).state);
    const empty = try decodeServicePage(a, a, "{\"nextPageToken\":\"\"}");
    try testing.expectEqual(0, empty.services.len);
    try testing.expectEqual(null, empty.next_page_token);
    try testing.expectEqual(0, (try decodeServices(a, a, "{}")).len);
}

fn decodersProperty(_: void, input: []const u8) !void {
    const test_util = @import("test_util.zig");
    var out: std.heap.ArenaAllocator = .init(test_util.propertyAllocator());
    defer out.deinit();
    var scratch: std.heap.ArenaAllocator = .init(test_util.propertyAllocator());
    defer scratch.deinit();
    inline for (.{ decodeService, decodeServicePage, decodeServices }) |decode| {
        if (decode(out.allocator(), scratch.allocator(), input)) |_| {} else |err| try testing.expectEqual(error.InvalidResponse, err);
    }
}

test "fuzz decoders: any body decodes or is InvalidResponse, never a crash or a leak" {
    try @import("test_util.zig").fuzzBytes({}, decodersProperty, .{ .corpus = &.{
        production.get_enabled,
        production.get_no_summary,
        production.list_enabled_page,
        production.list_disabled_page,
        production.batch_two,
        production.get_unknown,
    } });
}
