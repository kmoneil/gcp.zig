//! JSON: the `entries.list` request out, pages of entries in.
//!
//! Pages are read with std's token scanner rather than parsed into structs,
//! so an entry keeps what a struct would lose: the bytes of its JSON and
//! proto payloads, numbers as written, and the whole entry's bytes, for the
//! fields not typed here. The smaller parts (a resource, an HTTP request)
//! are parsed from their own bytes into private `Wire*` structs. Every
//! field is optional, `null` counts as absent (the proto3 JSON rule),
//! unknown fields are ignored, int64 fields are read from a string or a
//! number, and enums from a name or a number, as a REST client that asks
//! for `enum-encoding=int` would get them.

const std = @import("std");
const Allocator = std.mem.Allocator;
const Stringify = std.json.Stringify;
const Scanner = std.json.Scanner;
const Writer = std.Io.Writer;
const core = @import("core");
const names = @import("names.zig");
const types = @import("types.zig");

pub const DecodeError = error{ InvalidResponse, OutOfMemory };

// Requests

/// What one `entries.list` sends, but for the page token.
pub const ListRequest = struct {
    resource_names: []const []const u8,
    /// "" sends none.
    filter: []const u8,
    order: types.Order,
    page_size: u32,
};

/// The `entries.list` body. The same request gives the same bytes, and a
/// token changes nothing but its own field, so every page of a query sends
/// what its first did.
pub fn encodeListRequest(arena: Allocator, request: ListRequest, page_token: ?[]const u8) Allocator.Error![]u8 {
    var out: Writer.Allocating = .init(arena);
    var jw: Stringify = .{ .writer = &out.writer };
    writeListRequest(&jw, request, page_token) catch return error.OutOfMemory;
    return out.toOwnedSlice();
}

fn writeListRequest(jw: *Stringify, request: ListRequest, page_token: ?[]const u8) Stringify.Error!void {
    try jw.beginObject();
    try jw.objectField("resourceNames");
    try jw.beginArray();
    for (request.resource_names) |name| try jw.write(name);
    try jw.endArray();
    if (request.filter.len > 0) {
        try jw.objectField("filter");
        try jw.write(request.filter);
    }
    try jw.objectField("orderBy");
    try jw.write(request.order.wire());
    try jw.objectField("pageSize");
    try jw.write(request.page_size);
    if (page_token) |token| {
        try jw.objectField("pageToken");
        try jw.write(token);
    }
    try jw.endObject();
}

// Responses

/// A page of entries. Every slice in it points into `body` or `arena`, so
/// `body` must live as long as the page: the response arena holds both.
pub fn decodeEntryPage(arena: Allocator, body: []const u8) DecodeError!types.EntryPage {
    return decodePage(arena, body) catch |err| switch (err) {
        error.OutOfMemory => error.OutOfMemory,
        else => error.InvalidResponse,
    };
}

const ScanError = Scanner.NextError || Scanner.AllocError || Scanner.PeekError || Scanner.SkipError || error{ InvalidResponse, OutOfMemory };

fn decodePage(arena: Allocator, body: []const u8) ScanError!types.EntryPage {
    var scanner: Scanner = .initCompleteInput(arena, body);
    defer scanner.deinit();
    if (try scanner.next() != .object_begin) return error.InvalidResponse;
    var entries: std.ArrayList(types.Entry) = .empty;
    var token: ?[]const u8 = null;
    while (true) {
        const key = (try nextKey(arena, &scanner, body.len)) orelse break;
        if (std.mem.eql(u8, key, "entries")) {
            switch (try scanner.peekNextTokenType()) {
                .null => _ = try scanner.next(),
                .array_begin => {
                    _ = try scanner.next();
                    while (try scanner.peekNextTokenType() != .array_end) {
                        try entries.append(arena, try decodeEntry(arena, &scanner, body));
                    }
                    _ = try scanner.next();
                },
                else => return error.InvalidResponse,
            }
        } else if (std.mem.eql(u8, key, "nextPageToken")) {
            const text = try stringOrNull(arena, rawValue(&scanner, body) catch |e| return e);
            // An empty token ends the listing, as an absent one does.
            token = if (text) |t| (if (t.len == 0) null else t) else null;
        } else {
            try scanner.skipValue();
        }
    }
    if (try scanner.next() != .end_of_document) return error.InvalidResponse;
    return .{ .entries = entries.items, .next_page_token = token };
}

/// The next key of the object being read, or null at its end.
fn nextKey(arena: Allocator, scanner: *Scanner, max: usize) ScanError!?[]const u8 {
    return switch (try scanner.nextAllocMax(arena, .alloc_if_needed, max)) {
        .object_end => null,
        .string => |s| s,
        .allocated_string => |s| s,
        else => error.InvalidResponse,
    };
}

/// The bytes of the next value, which the scanner then steps past.
fn rawValue(scanner: *Scanner, body: []const u8) ScanError![]const u8 {
    _ = try scanner.peekNextTokenType();
    const start = scanner.cursor;
    try scanner.skipValue();
    return body[start..scanner.cursor];
}

/// One entry, from the object the scanner is at.
fn decodeEntry(arena: Allocator, scanner: *Scanner, body: []const u8) ScanError!types.Entry {
    if (try scanner.peekNextTokenType() != .object_begin) return error.InvalidResponse;
    const start = scanner.cursor;
    _ = try scanner.next();
    var entry: types.Entry = .{
        .log_name = "",
        .log_id = "",
        .resource_type = "",
        .resource_labels = &.{},
        .timestamp = undefined,
        .receive_timestamp = null,
        .severity = .default,
        .insert_id = "",
        .payload = .none,
        .labels = &.{},
        .http_request = null,
        .operation = null,
        .trace = "",
        .span_id = "",
        .trace_sampled = false,
        .source_location = null,
        .split = null,
        .raw = "",
    };
    var timestamp: ?std.Io.Timestamp = null;
    while (try nextKey(arena, scanner, body.len)) |key| {
        const raw = try rawValue(scanner, body);
        if (isNull(raw)) continue;
        const field = fields.get(key) orelse continue;
        switch (field) {
            .log_name => entry.log_name = try string(arena, raw),
            .resource => {
                const r = try parse(WireResource, arena, raw);
                entry.resource_type = r.type orelse "";
                entry.resource_labels = try labelsOf(arena, r.labels);
            },
            .timestamp => timestamp = try time(arena, raw),
            .receive_timestamp => entry.receive_timestamp = try time(arena, raw),
            .severity => entry.severity = try severity(arena, raw),
            .insert_id => entry.insert_id = try string(arena, raw),
            .text_payload => entry.payload = .{ .text = try string(arena, raw) },
            .json_payload => {
                if (raw[0] != '{') return error.InvalidResponse;
                entry.payload = .{ .json = raw };
            },
            .proto_payload => {
                if (raw[0] != '{') return error.InvalidResponse;
                entry.payload = .{ .proto = .{ .type_url = try typeUrl(arena, raw), .json = raw } };
            },
            .labels => entry.labels = try labelsOf(arena, try parse(std.json.ArrayHashMap([]const u8), arena, raw)),
            .http_request => entry.http_request = try httpRequest(arena, raw),
            .operation => {
                const o = try parse(WireOperation, arena, raw);
                entry.operation = .{ .id = o.id orelse "", .producer = o.producer orelse "", .first = o.first orelse false, .last = o.last orelse false };
            },
            .trace => entry.trace = try string(arena, raw),
            .span_id => entry.span_id = try string(arena, raw),
            .trace_sampled => entry.trace_sampled = try parse(bool, arena, raw),
            .source_location => {
                const s = try parse(WireSourceLocation, arena, raw);
                entry.source_location = .{ .file = s.file orelse "", .line = if (s.line) |l| l.value else 0, .function = s.function orelse "" };
            },
            .split => {
                const s = try parse(WireSplit, arena, raw);
                entry.split = .{ .uid = s.uid orelse "", .index = try count32(s.index), .total = try count32(s.totalSplits) };
            },
        }
    }
    // Logging assigns a timestamp to every entry it stores.
    entry.timestamp = timestamp orelse return error.InvalidResponse;
    entry.log_id = try names.logIdOf(arena, entry.log_name);
    entry.raw = body[start..scanner.cursor];
    return entry;
}

const Field = enum {
    log_name,
    resource,
    timestamp,
    receive_timestamp,
    severity,
    insert_id,
    text_payload,
    json_payload,
    proto_payload,
    labels,
    http_request,
    operation,
    trace,
    span_id,
    trace_sampled,
    source_location,
    split,
};

const fields = std.StaticStringMap(Field).initComptime(.{
    .{ "logName", .log_name },
    .{ "resource", .resource },
    .{ "timestamp", .timestamp },
    .{ "receiveTimestamp", .receive_timestamp },
    .{ "severity", .severity },
    .{ "insertId", .insert_id },
    .{ "textPayload", .text_payload },
    .{ "jsonPayload", .json_payload },
    .{ "protoPayload", .proto_payload },
    .{ "labels", .labels },
    .{ "httpRequest", .http_request },
    .{ "operation", .operation },
    .{ "trace", .trace },
    .{ "spanId", .span_id },
    .{ "traceSampled", .trace_sampled },
    .{ "sourceLocation", .source_location },
    .{ "split", .split },
});

fn isNull(raw: []const u8) bool {
    return std.mem.eql(u8, raw, "null");
}

const parse_options: std.json.ParseOptions = .{
    .ignore_unknown_fields = true,
    .duplicate_field_behavior = .use_last,
};

fn parse(comptime T: type, arena: Allocator, raw: []const u8) ScanError!T {
    return std.json.parseFromSliceLeaky(T, arena, raw, parse_options) catch |err| switch (err) {
        error.OutOfMemory => error.OutOfMemory,
        else => error.InvalidResponse,
    };
}

fn string(arena: Allocator, raw: []const u8) ScanError![]const u8 {
    return parse([]const u8, arena, raw);
}

fn stringOrNull(arena: Allocator, raw: []const u8) ScanError!?[]const u8 {
    if (isNull(raw)) return null;
    return try string(arena, raw);
}

fn time(arena: Allocator, raw: []const u8) ScanError!std.Io.Timestamp {
    return core.timestamp.parse(try string(arena, raw)) catch error.InvalidResponse;
}

/// A name, or a number as `enum-encoding=int` sends it. One this version
/// does not know is kept, never refused.
fn severity(arena: Allocator, raw: []const u8) ScanError!types.Severity {
    if (raw[0] == '"') return .fromName(try string(arena, raw));
    const number = std.fmt.parseInt(i64, raw, 10) catch return .unknown;
    return .fromNumber(number);
}

/// The top-level `"@type"` of a proto payload, "" when it has none.
fn typeUrl(arena: Allocator, raw: []const u8) ScanError![]const u8 {
    var scanner: Scanner = .initCompleteInput(arena, raw);
    defer scanner.deinit();
    _ = try scanner.next();
    var found: []const u8 = "";
    while (try nextKey(arena, &scanner, raw.len)) |key| {
        const value = try rawValue(&scanner, raw);
        if (std.mem.eql(u8, key, "@type")) found = (try stringOrNull(arena, value)) orelse "";
    }
    return found;
}

fn labelsOf(arena: Allocator, map: ?std.json.ArrayHashMap([]const u8)) Allocator.Error![]const types.Label {
    const m = map orelse return &.{};
    const out = try arena.alloc(types.Label, m.map.count());
    for (m.map.keys(), m.map.values(), out) |k, v, *label| label.* = .{ .key = k, .value = v };
    return out;
}

fn count32(value: ?Int64) ScanError!u32 {
    const v = value orelse return 0;
    return std.math.cast(u32, v.value) orelse error.InvalidResponse;
}

fn httpRequest(arena: Allocator, raw: []const u8) ScanError!types.HttpRequest {
    const h = try parse(WireHttpRequest, arena, raw);
    return .{
        .method = h.requestMethod orelse "",
        .url = h.requestUrl orelse "",
        .status = if (h.status) |s| (std.math.cast(u16, s.value) orelse return error.InvalidResponse) else 0,
        .request_size = if (h.requestSize) |v| v.value else null,
        .response_size = if (h.responseSize) |v| v.value else null,
        .latency = if (h.latency) |l| (core.duration.parse(l) catch return error.InvalidResponse) else null,
        .user_agent = h.userAgent orelse "",
        .remote_ip = h.remoteIp orelse "",
        .server_ip = h.serverIp orelse "",
        .referer = h.referer orelse "",
        .protocol = h.protocol orelse "",
        .cache_lookup = h.cacheLookup orelse false,
        .cache_hit = h.cacheHit orelse false,
        .cache_validated_with_origin_server = h.cacheValidatedWithOriginServer orelse false,
        .cache_fill_bytes = if (h.cacheFillBytes) |v| v.value else null,
    };
}

/// An int64 or int32 field: proto3 JSON writes int64 as a string and
/// int32 as a number, and readers take either.
const Int64 = struct {
    value: i64,

    pub fn jsonParse(allocator: Allocator, source: anytype, options: std.json.ParseOptions) !Int64 {
        const text = switch (try source.nextAllocMax(allocator, .alloc_if_needed, options.max_value_len.?)) {
            .number, .string => |t| t,
            .allocated_number, .allocated_string => |t| t,
            else => return error.UnexpectedToken,
        };
        return .{ .value = std.fmt.parseInt(i64, text, 10) catch return error.InvalidNumber };
    }
};

const WireLabels = std.json.ArrayHashMap([]const u8);

const WireResource = struct {
    type: ?[]const u8 = null,
    labels: ?WireLabels = null,
};

const WireOperation = struct {
    id: ?[]const u8 = null,
    producer: ?[]const u8 = null,
    first: ?bool = null,
    last: ?bool = null,
};

const WireSourceLocation = struct {
    file: ?[]const u8 = null,
    line: ?Int64 = null,
    function: ?[]const u8 = null,
};

const WireSplit = struct {
    uid: ?[]const u8 = null,
    index: ?Int64 = null,
    totalSplits: ?Int64 = null,
};

const WireHttpRequest = struct {
    requestMethod: ?[]const u8 = null,
    requestUrl: ?[]const u8 = null,
    requestSize: ?Int64 = null,
    status: ?Int64 = null,
    responseSize: ?Int64 = null,
    userAgent: ?[]const u8 = null,
    remoteIp: ?[]const u8 = null,
    serverIp: ?[]const u8 = null,
    referer: ?[]const u8 = null,
    latency: ?[]const u8 = null,
    cacheLookup: ?bool = null,
    cacheHit: ?bool = null,
    cacheValidatedWithOriginServer: ?bool = null,
    cacheFillBytes: ?Int64 = null,
    protocol: ?[]const u8 = null,
};

const testing = std.testing;

test "golden: the request, with and without a filter and a token" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const request: ListRequest = .{
        .resource_names = &.{ "projects/my-project", "folders/12" },
        .filter = "severity >= WARNING\nAND log_id(\"a\\\"b\")",
        .order = .newest_first,
        .page_size = 100,
    };
    try testing.expectEqualStrings(
        \\{"resourceNames":["projects/my-project","folders/12"],"filter":"severity >= WARNING\nAND log_id(\"a\\\"b\")","orderBy":"timestamp desc","pageSize":100}
    , try encodeListRequest(a, request, null));
    try testing.expectEqualStrings(
        \\{"resourceNames":["projects/my-project","folders/12"],"filter":"severity >= WARNING\nAND log_id(\"a\\\"b\")","orderBy":"timestamp desc","pageSize":100,"pageToken":"EAE4"}
    , try encodeListRequest(a, request, "EAE4"));
    try testing.expectEqualStrings(
        \\{"resourceNames":["projects/p"],"orderBy":"timestamp asc","pageSize":1}
    , try encodeListRequest(a, .{ .resource_names = &.{"projects/p"}, .filter = "", .order = .oldest_first, .page_size = 1 }, null));
}

/// The shortened entry of the spec's section 3, with everything a page can
/// carry around it.
const spec_page =
    \\{
    \\  "entries": [
    \\    {
    \\      "insertId": "6710f3a2000c4b8e9d1a7c2f",
    \\      "logName": "projects/my-project/logs/run.googleapis.com%2Fstderr",
    \\      "resource": {"type": "cloud_run_revision", "labels": {"service_name": "api", "location": "europe-west1"}},
    \\      "timestamp": "2026-10-16T09:41:07.123456789Z",
    \\      "receiveTimestamp": "2026-10-16T09:41:07.301Z",
    \\      "severity": "ERROR",
    \\      "jsonPayload": {"message": "payment failed", "order": 4217, "big": 12345678901234567890, "exact": 0.1000000000000000055511151231257827},
    \\      "trace": "projects/my-project/traces/4bf92f3577b34da6a3ce929d0e0e4736",
    \\      "spanId": "00f067aa0ba902b7",
    \\      "traceSampled": true,
    \\      "sourceLocation": {"file": "pay.go", "line": "88", "function": "charge"},
    \\      "otel": {"future": [1, 2, {"x": "y"}]}
    \\    }
    \\  ],
    \\  "nextPageToken": "EAE4uP-t"
    \\}
;

test "golden: the spec's entry, every field, and the raw bytes kept" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const page = try decodeEntryPage(arena.allocator(), spec_page);
    try testing.expectEqualStrings("EAE4uP-t", page.next_page_token.?);
    try testing.expectEqual(1, page.entries.len);
    const e = page.entries[0];
    try testing.expectEqualStrings("6710f3a2000c4b8e9d1a7c2f", e.insert_id);
    try testing.expectEqualStrings("projects/my-project/logs/run.googleapis.com%2Fstderr", e.log_name);
    try testing.expectEqualStrings("run.googleapis.com/stderr", e.log_id);
    try testing.expectEqualStrings("cloud_run_revision", e.resource_type);
    try testing.expectEqual(2, e.resource_labels.len);
    try testing.expectEqualStrings("service_name", e.resource_labels[0].key);
    try testing.expectEqualStrings("europe-west1", e.resource_labels[1].value);
    try testing.expectEqual(1_792_143_667_123_456_789, e.timestamp.nanoseconds);
    try testing.expectEqual(1_792_143_667_301_000_000, e.receive_timestamp.?.nanoseconds);
    try testing.expectEqual(.@"error", e.severity);
    // The JSON payload's bytes, numbers as written, nothing rounded.
    try testing.expectEqualStrings(
        \\{"message": "payment failed", "order": 4217, "big": 12345678901234567890, "exact": 0.1000000000000000055511151231257827}
    , e.payload.json);
    try testing.expectEqualStrings("projects/my-project/traces/4bf92f3577b34da6a3ce929d0e0e4736", e.trace);
    try testing.expectEqualStrings("00f067aa0ba902b7", e.span_id);
    try testing.expect(e.trace_sampled);
    try testing.expectEqualStrings("pay.go", e.source_location.?.file);
    try testing.expectEqual(88, e.source_location.?.line);
    try testing.expectEqualStrings("charge", e.source_location.?.function);
    // The whole entry, the field this version does not know included.
    try testing.expect(std.mem.startsWith(u8, e.raw, "{\n      \"insertId\""));
    try testing.expect(std.mem.endsWith(u8, e.raw, "{\"x\": \"y\"}]}\n    }"));
    try testing.expect(std.mem.indexOf(u8, e.raw, "\"otel\"") != null);
    try testing.expectEqual(null, e.http_request);
    try testing.expectEqual(null, e.operation);
    try testing.expectEqual(null, e.split);

    var parsed = try e.payload.parse(testing.allocator);
    defer parsed.deinit();
    try testing.expectEqualStrings("12345678901234567890", parsed.value.object.get("big").?.number_string);
    try testing.expectEqualStrings("0.1000000000000000055511151231257827", parsed.value.object.get("exact").?.number_string);
    try testing.expectEqualStrings("payment failed", parsed.value.object.get("message").?.string);
}

test "golden: proto payloads, their @type, nested ones left in the bytes" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const page = try decodeEntryPage(arena.allocator(),
        \\{"entries":[{"timestamp":"2026-10-16T09:00:00Z","logName":"projects/p/logs/cloudaudit.googleapis.com%2Factivity",
        \\ "protoPayload":{"serviceName":"pubsub.googleapis.com","request":{"@type":"type.googleapis.com/google.pubsub.v1.Topic","name":"t"},
        \\  "@type":"type.googleapis.com/google.cloud.audit.AuditLog","numResponseItems":"3"}},
        \\ {"timestamp":"2026-10-16T09:00:01Z","protoPayload":{"a":1}},
        \\ {"timestamp":"2026-10-16T09:00:02Z","textPayload":"plain \"text\"\n"},
        \\ {"timestamp":"2026-10-16T09:00:03Z"}]}
    );
    try testing.expectEqual(null, page.next_page_token);
    try testing.expectEqual(4, page.entries.len);
    const audit = page.entries[0].payload.proto;
    try testing.expectEqualStrings("type.googleapis.com/google.cloud.audit.AuditLog", audit.type_url);
    try testing.expect(std.mem.indexOf(u8, audit.json, "google.pubsub.v1.Topic") != null);
    try testing.expectEqualStrings("cloudaudit.googleapis.com/activity", page.entries[0].log_id);
    try testing.expectEqualStrings("", page.entries[1].payload.proto.type_url);
    try testing.expectEqualStrings("plain \"text\"\n", page.entries[2].payload.text);
    try testing.expectEqual(.none, std.meta.activeTag(page.entries[3].payload));
    try testing.expectError(error.NotJson, page.entries[2].payload.parse(testing.allocator));
    try testing.expectError(error.NotJson, page.entries[3].payload.parse(testing.allocator));
    // Absent fields read as their defaults.
    const bare = page.entries[3];
    try testing.expectEqual(.default, bare.severity);
    try testing.expectEqualStrings("", bare.log_name);
    try testing.expectEqualStrings("", bare.log_id);
    try testing.expectEqual(0, bare.labels.len);
    try testing.expect(!bare.trace_sampled);
    try testing.expectEqual(null, bare.receive_timestamp);
}

test "golden: an HTTP request, an operation and a split, int64 as strings and numbers" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const page = try decodeEntryPage(arena.allocator(),
        \\{"entries":[{"timestamp":"2026-10-16T09:00:00.5Z","severity":500,
        \\ "httpRequest":{"requestMethod":"GET","requestUrl":"https://x/y?z","requestSize":"120","status":503,
        \\  "responseSize":4096,"userAgent":"curl/8","remoteIp":"[::1]:443","serverIp":"10.0.0.1","referer":"r",
        \\  "latency":"0.123s","cacheLookup":true,"cacheHit":false,"cacheValidatedWithOriginServer":true,"cacheFillBytes":"7","protocol":"HTTP/2"},
        \\ "operation":{"id":"op1","producer":"github.com/x","first":true},
        \\ "split":{"uid":"u1","index":2,"totalSplits":"3"},
        \\ "labels":{"b":"2","a":"1"}}]}
    );
    const e = page.entries[0];
    try testing.expectEqual(.@"error", e.severity);
    const h = e.http_request.?;
    try testing.expectEqualStrings("GET", h.method);
    try testing.expectEqualStrings("https://x/y?z", h.url);
    try testing.expectEqual(120, h.request_size.?);
    try testing.expectEqual(503, h.status);
    try testing.expectEqual(4096, h.response_size.?);
    try testing.expectEqualStrings("curl/8", h.user_agent);
    try testing.expectEqualStrings("[::1]:443", h.remote_ip);
    try testing.expectEqualStrings("10.0.0.1", h.server_ip);
    try testing.expectEqualStrings("r", h.referer);
    try testing.expectEqual(123 * std.time.ns_per_ms, h.latency.?.nanoseconds);
    try testing.expect(h.cache_lookup and !h.cache_hit and h.cache_validated_with_origin_server);
    try testing.expectEqual(7, h.cache_fill_bytes.?);
    try testing.expectEqualStrings("HTTP/2", h.protocol);
    try testing.expectEqualStrings("op1", e.operation.?.id);
    try testing.expectEqualStrings("github.com/x", e.operation.?.producer);
    try testing.expect(e.operation.?.first and !e.operation.?.last);
    try testing.expectEqualDeep(types.Split{ .uid = "u1", .index = 2, .total = 3 }, e.split.?);
    // Labels in the order sent.
    try testing.expectEqualStrings("b", e.labels[0].key);
    try testing.expectEqualStrings("1", e.labels[1].value);
}

test "golden: severities by name and number, known and not" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const page = try decodeEntryPage(arena.allocator(),
        \\{"entries":[{"timestamp":"2026-10-16T09:00:00Z","severity":"WARNING"},
        \\ {"timestamp":"2026-10-16T09:00:00Z","severity":"SEVERE"},
        \\ {"timestamp":"2026-10-16T09:00:00Z","severity":450},
        \\ {"timestamp":"2026-10-16T09:00:00Z","severity":800},
        \\ {"timestamp":"2026-10-16T09:00:00Z","severity":-1},
        \\ {"timestamp":"2026-10-16T09:00:00Z","severity":70000},
        \\ {"timestamp":"2026-10-16T09:00:00Z","severity":1.5},
        \\ {"timestamp":"2026-10-16T09:00:00Z","severity":null}]}
    );
    const want = [_]types.Severity{ .warning, .unknown, @fromBackingInt(@intCast(450)), .emergency, .unknown, .unknown, .unknown, .default };
    for (want, page.entries) |w, e| try testing.expectEqual(w, e.severity);
    try testing.expectEqual(null, page.entries[2].severity.name());
    try testing.expectEqualStrings("EMERGENCY", page.entries[3].severity.name().?);
}

test "golden: timestamps with 0 to 9 digits and an offset" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const page = try decodeEntryPage(arena.allocator(),
        \\{"entries":[{"timestamp":"2026-10-16T09:00:00Z"},{"timestamp":"2026-10-16T09:00:00.1Z"},
        \\ {"timestamp":"2026-10-16T09:00:00.123456Z"},{"timestamp":"2026-10-16T11:00:00.000000001+02:00"}]}
    );
    const base: i96 = 1_792_141_200 * std.time.ns_per_s;
    try testing.expectEqual(base, page.entries[0].timestamp.nanoseconds);
    try testing.expectEqual(base + 100_000_000, page.entries[1].timestamp.nanoseconds);
    try testing.expectEqual(base + 123_456_000, page.entries[2].timestamp.nanoseconds);
    try testing.expectEqual(base + 1, page.entries[3].timestamp.nanoseconds);
}

test "golden: empty pages, with and without a token, and nulls" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    // The server ran out of time: no entries, and a token to go on.
    const searching = try decodeEntryPage(a, "{\"nextPageToken\":\"EAA\"}");
    try testing.expectEqual(0, searching.entries.len);
    try testing.expectEqualStrings("EAA", searching.next_page_token.?);
    const done = try decodeEntryPage(a, "{}");
    try testing.expectEqual(0, done.entries.len);
    try testing.expectEqual(null, done.next_page_token);
    const nulls = try decodeEntryPage(a, "{\"entries\":null,\"nextPageToken\":null,\"other\":[1,{}]}");
    try testing.expectEqual(0, nulls.entries.len);
    try testing.expectEqual(null, nulls.next_page_token);
    try testing.expectEqual(null, (try decodeEntryPage(a, "{\"nextPageToken\":\"\"}")).next_page_token);
    // A token sent before the entries, and escapes in keys and values.
    const early = try decodeEntryPage(a, "{\"next\\u0050ageToken\":\"a\\/b\",\"entries\":[{\"timestamp\":\"2026-10-16T09:00:00Z\",\"insertId\":\"\\u00e9\"}]}");
    try testing.expectEqualStrings("a/b", early.next_page_token.?);
    try testing.expectEqualStrings("\u{e9}", early.entries[0].insert_id);
}

test "golden: what is no page is InvalidResponse" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    for ([_][]const u8{
        "",
        "[]",
        "{",
        "{}x",
        "{\"entries\":{}}",
        "{\"entries\":[1]}",
        "{\"entries\":[{}]}",
        "{\"entries\":[{\"timestamp\":\"yesterday\"}]}",
        "{\"entries\":[{\"timestamp\":1}]}",
        "{\"entries\":[{\"timestamp\":\"2026-10-16T09:00:00Z\",\"jsonPayload\":[1]}]}",
        "{\"entries\":[{\"timestamp\":\"2026-10-16T09:00:00Z\",\"protoPayload\":\"x\"}]}",
        "{\"entries\":[{\"timestamp\":\"2026-10-16T09:00:00Z\",\"labels\":{\"a\":1}}]}",
        "{\"entries\":[{\"timestamp\":\"2026-10-16T09:00:00Z\",\"httpRequest\":{\"status\":70000}}]}",
        "{\"entries\":[{\"timestamp\":\"2026-10-16T09:00:00Z\",\"httpRequest\":{\"latency\":\"soon\"}}]}",
        "{\"entries\":[{\"timestamp\":\"2026-10-16T09:00:00Z\",\"split\":{\"index\":-1}}]}",
        "{\"entries\":[{\"timestamp\":\"2026-10-16T09:00:00Z\",\"sourceLocation\":{\"line\":\"8.5\"}}]}",
        "{\"entries\":[{\"timestamp\":\"2026-10-16T09:00:00Z\",\"traceSampled\":\"yes\"}]}",
        "{\"nextPageToken\":7}",
    }) |body| {
        if (decodeEntryPage(a, body)) |_| {
            std.debug.print("decoded: {s}\n", .{body});
            return error.TestExpectedError;
        } else |err| try testing.expectEqual(error.InvalidResponse, err);
    }
}

test "decode: every allocation failure is OutOfMemory without leaks" {
    try testing.checkAllAllocationFailures(testing.allocator, struct {
        fn run(gpa: Allocator) !void {
            var arena: std.heap.ArenaAllocator = .init(gpa);
            defer arena.deinit();
            _ = try decodeEntryPage(arena.allocator(), spec_page);
        }
    }.run, .{});
}

const test_util = @import("test_util.zig");

fn within(body: []const u8, part: []const u8) bool {
    const lo = @intFromPtr(body.ptr);
    const p = @intFromPtr(part.ptr);
    return p >= lo and p + part.len <= lo + body.len;
}

fn decodeProperty(_: void, input: []const u8) !void {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const page = decodeEntryPage(arena.allocator(), input) catch |err| switch (err) {
        error.InvalidResponse => return,
        else => return err,
    };
    for (page.entries) |e| {
        // What an entry keeps as bytes is the body's own, in order.
        try testing.expect(within(input, e.raw));
        try testing.expect(e.raw.len >= 2 and e.raw[0] == '{' and e.raw[e.raw.len - 1] == '}');
        switch (e.payload) {
            .json => |j| try testing.expect(within(e.raw, j)),
            .proto => |p| try testing.expect(within(e.raw, p.json)),
            else => {},
        }
        if (e.payload == .json or e.payload == .proto) {
            var parsed = try e.payload.parse(testing.allocator);
            parsed.deinit();
        }
    }
}

test "fuzz decodeEntryPage: arbitrary bodies never crash, and what an entry keeps lies in the body" {
    try test_util.fuzzBytes({}, decodeProperty, .{ .corpus = &.{
        spec_page,
        "{\"entries\":[{\"timestamp\":\"2026-10-16T09:00:00Z\",\"protoPayload\":{\"@type\":\"t\",\"x\":{\"@type\":\"u\"}}}]}",
        "{\"entries\":[{\"timestamp\":\"2026-10-16T09:00:00Z\",\"severity\":99999999999999999999999}]}",
        "{\"entries\":[{\"timestamp\":\"2026-10-16T09:00:00Z\",\"httpRequest\":{\"requestSize\":\"-9223372036854775808\"}}]}",
        "{\"entries\":[{\"timestamp\":\"2026-10-16T09:00:00Z\",\"labels\":{\"a\":\"1\",\"a\":\"2\"}}]}",
        "{\"entries\":[],\"nextPageToken\":\"\\ud800\"}",
        "{\"a\":[[[[[[[[[[[[[[[[[[[[1]]]]]]]]]]]]]]]]]]]}",
        "",
        "null",
    } });
}
