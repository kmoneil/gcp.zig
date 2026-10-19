//! Decoders for Cloud Scheduler's proto3 JSON. Lenient where the server
//! may grow (unknown fields skipped, unknown enum values read as
//! `.unknown`), strict where a field identifies the answer: a job without
//! a name is `error.InvalidResponse`.

const std = @import("std");
const Allocator = std.mem.Allocator;
const Value = std.json.Value;
const core = @import("core");
const types = @import("types.zig");

pub const DecodeError = error{ OutOfMemory, InvalidResponse };

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

/// A page of `locations.list`.
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

fn jobOf(out: Allocator, v: Value) DecodeError!types.Job {
    const obj = try object(v);
    const name = try string(out, obj, "name") orelse return error.InvalidResponse;
    var job: types.Job = .{
        .name = name,
        .id = trailing(name),
        .location = locationOf(name),
        .description = try string(out, obj, "description") orelse "",
        .schedule = try string(out, obj, "schedule") orelse "",
        .time_zone = try string(out, obj, "timeZone") orelse "",
        .state = if (try field(obj, "state", .string)) |s| types.JobState.fromWire(s) else .unknown,
        .last_attempt_time = try time(obj, "lastAttemptTime"),
        .schedule_time = try time(obj, "scheduleTime"),
        .user_update_time = try time(obj, "userUpdateTime"),
        .attempt_deadline_s = try duration(obj, "attemptDeadline"),
    };
    if (try field(obj, "status", .object)) |status| {
        // A job is born with code -1, a sentinel no gRPC code names,
        // before any attempt (measured 2026-10-19): that is "no attempt",
        // not an attempt that failed.
        const code = try integer(i64, status, "code") orelse 0;
        if (code != -1) job.last_attempt = .{
            .code = code,
            .message = try string(out, status, "message") orelse "",
        };
    }
    if (try field(obj, "retryConfig", .object)) |retry| {
        job.retry = .{
            .retry_count = try integer(i64, retry, "retryCount"),
            .max_retry_duration_s = try duration(retry, "maxRetryDuration"),
            .min_backoff_duration_s = try duration(retry, "minBackoffDuration"),
            .max_backoff_duration_s = try duration(retry, "maxBackoffDuration"),
            .max_doublings = try integer(i64, retry, "maxDoublings"),
        };
    }
    if (try field(obj, "httpTarget", .object)) |t| {
        var auth: types.HttpAuth = .none;
        if (try field(t, "oauthToken", .object)) |o| auth = .{ .oauth = .{
            .service_account_email = try string(out, o, "serviceAccountEmail") orelse "",
            .scope = try string(out, o, "scope") orelse "",
        } };
        if (try field(t, "oidcToken", .object)) |o| auth = .{ .oidc = .{
            .service_account_email = try string(out, o, "serviceAccountEmail") orelse "",
            .audience = try string(out, o, "audience") orelse "",
        } };
        job.target = .{ .http = .{
            .uri = try string(out, t, "uri") orelse "",
            .method = if (try field(t, "httpMethod", .string)) |m| types.HttpMethod.fromWire(m) else .unspecified,
            .headers = try labelMap(out, t, "headers"),
            .body = try bytes(out, t, "body"),
            .auth = auth,
        } };
    } else if (try field(obj, "pubsubTarget", .object)) |t| {
        job.target = .{ .pubsub = .{
            .topic_name = try string(out, t, "topicName") orelse "",
            .data = try bytes(out, t, "data"),
            .attributes = try labelMap(out, t, "attributes"),
        } };
    } else if (try field(obj, "appEngineHttpTarget", .object)) |t| {
        var target: types.AppEngineTarget = .{
            .relative_uri = try string(out, t, "relativeUri") orelse "",
            .method = if (try field(t, "httpMethod", .string)) |m| types.HttpMethod.fromWire(m) else .unspecified,
            .headers = try labelMap(out, t, "headers"),
            .body = try bytes(out, t, "body"),
        };
        if (try field(t, "appEngineRouting", .object)) |r| {
            target.service = try string(out, r, "service") orelse "";
            target.version = try string(out, r, "version") orelse "";
            target.instance = try string(out, r, "instance") orelse "";
            target.host = try string(out, r, "host") orelse "";
        }
        job.target = .{ .app_engine = target };
    }
    return job;
}

/// The segment after the last `/`, or the whole name.
fn trailing(name: []const u8) []const u8 {
    if (std.mem.lastIndexOfScalar(u8, name, '/')) |i| return name[i + 1 ..];
    return name;
}

/// The `L` of `projects/P/locations/L/jobs/J`, or "".
fn locationOf(name: []const u8) []const u8 {
    const head = std.mem.indexOf(u8, name, "/locations/") orelse return "";
    const rest = name[head + "/locations/".len ..];
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

/// `nextPageToken`: "" means the last page, as proto3 JSON leaves the
/// default out or sends it empty.
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
/// JSON allows.
fn integer(comptime T: type, obj: std.json.ObjectMap, name: []const u8) DecodeError!?T {
    const v = obj.get(name) orelse return null;
    const text = switch (v) {
        .null => return null,
        .number_string, .string => |s| s,
        else => return error.InvalidResponse,
    };
    return std.fmt.parseInt(T, text, 10) catch error.InvalidResponse;
}

/// A proto duration: decimal seconds and a trailing `s`, such as "180s"
/// or "0.5s".
fn duration(obj: std.json.ObjectMap, name: []const u8) DecodeError!?f64 {
    const text = try field(obj, name, .string) orelse return null;
    if (text.len < 2 or text[text.len - 1] != 's') return error.InvalidResponse;
    const seconds = std.fmt.parseFloat(f64, text[0 .. text.len - 1]) catch return error.InvalidResponse;
    if (!std.math.isFinite(seconds)) return error.InvalidResponse;
    return seconds;
}

/// A bytes field, base64 on the wire; proto3 JSON takes the URL-safe
/// alphabet too.
fn bytes(out: Allocator, obj: std.json.ObjectMap, name: []const u8) DecodeError![]const u8 {
    const text = try field(obj, name, .string) orelse return "";
    inline for (.{ std.base64.standard, std.base64.url_safe, std.base64.url_safe_no_pad }) |codec_| {
        decode: {
            const len = codec_.Decoder.calcSizeForSlice(text) catch break :decode;
            const buf = try out.alloc(u8, len);
            codec_.Decoder.decode(buf, text) catch break :decode;
            return buf;
        }
    }
    return error.InvalidResponse;
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

test "decodeJob: production's own bodies, born, failed, failed Pub/Sub and paused" {
    var out: std.heap.ArenaAllocator = .init(testing.allocator);
    defer out.deinit();
    var scratch: std.heap.ArenaAllocator = .init(testing.allocator);
    defer scratch.deinit();
    const a = out.allocator();
    const s = scratch.allocator();

    // Born: status code -1 is "no attempt", not a failure.
    const born = try decodeJob(a, s, production.job_created);
    try testing.expectEqualStrings("zigps-399f5c-http", born.id);
    try testing.expectEqualStrings("us-central1", born.location);
    try testing.expectEqual(types.JobState.enabled, born.state);
    try testing.expectEqual(null, born.last_attempt);
    try testing.expectEqual(null, born.last_attempt_time);
    try testing.expect(born.schedule_time != null);
    try testing.expect(!born.failing());
    try testing.expectEqual(180.0, born.attempt_deadline_s.?);
    try testing.expectEqual(1, born.retry.retry_count.?);
    try testing.expectEqual(5.0, born.retry.min_backoff_duration_s.?);
    try testing.expectEqual(3600.0, born.retry.max_backoff_duration_s.?);
    try testing.expectEqual(5, born.retry.max_doublings.?);
    try testing.expectEqualStrings("https://zigps-399f5c-nowhere.invalid/hook", born.target.http.uri);
    try testing.expectEqual(types.HttpMethod.post, born.target.http.method);
    try testing.expectEqualStrings("Google-Cloud-Scheduler", born.header("User-Agent").?);
    try testing.expectEqual(types.HttpAuth.none, born.target.http.auth);

    // After the run that could not resolve its host: the widget's red.
    const failed = try decodeJob(a, s, production.job_failed_http);
    try testing.expectEqual(2, failed.last_attempt.?.code);
    try testing.expectEqualStrings("", failed.last_attempt.?.message);
    try testing.expect(failed.last_attempt_time != null);
    try testing.expect(failed.failing());
    try testing.expectEqual(types.JobState.enabled, failed.state);

    // The Pub/Sub job on a topic nobody has: code 5, its data decoded,
    // and no retry keys at all in the answer.
    const ps = try decodeJob(a, s, production.job_failed_pubsub);
    try testing.expectEqual(5, ps.last_attempt.?.code);
    try testing.expect(ps.failing());
    try testing.expectEqualStrings("projects/extractctl/topics/zigps-399f5c-missing", ps.target.pubsub.topic_name);
    try testing.expectEqualStrings("zigps", ps.target.pubsub.data);
    try testing.expectEqual(null, ps.retry.retry_count);
    try testing.expectEqual(null, ps.attempt_deadline_s);

    // Paused: scheduleTime gone, the body decoded, headers kept.
    const paused = try decodeJob(a, s, production.job_paused);
    try testing.expectEqual(types.JobState.paused, paused.state);
    try testing.expectEqual(null, paused.schedule_time);
    try testing.expect(!paused.failing());
    try testing.expectEqualStrings("{\"probe\":true}", paused.target.http.body);
    try testing.expectEqualStrings("probe", paused.header("X-Zigps").?);
    try testing.expectEqualStrings("zig-gcp scheduler probe, deleted by the probe", paused.description);
}

test "decodeJobPage and decodeLocationPage: production's pages" {
    var out: std.heap.ArenaAllocator = .init(testing.allocator);
    defer out.deinit();
    var scratch: std.heap.ArenaAllocator = .init(testing.allocator);
    defer scratch.deinit();
    const a = out.allocator();
    const s = scratch.allocator();

    const page = try decodeJobPage(a, s, production.jobs_page);
    try testing.expectEqual(1, page.jobs.len);
    try testing.expectEqualStrings("zigps-d8a22f-ps", page.jobs[0].id);
    try testing.expect(page.next_page_token != null);
    const empty = try decodeJobPage(a, s, "{}");
    try testing.expectEqual(0, empty.jobs.len);
    try testing.expectEqual(null, empty.next_page_token);

    const locations = try decodeLocationPage(a, s, production.locations_page);
    try testing.expectEqual(2, locations.locations.len);
    try testing.expectEqualStrings("us-central1", locations.locations[0].id);
    try testing.expectEqualStrings("projects/extractctl/locations/us-central1", locations.locations[0].name);
    try testing.expectEqualStrings("us-central1", locations.locations[0].labels[0].value);
    try testing.expectEqualStrings("p2", locations.next_page_token.?);
}

test "decodeJob: lenient where it can be, InvalidResponse where it cannot" {
    var out: std.heap.ArenaAllocator = .init(testing.allocator);
    defer out.deinit();
    var scratch: std.heap.ArenaAllocator = .init(testing.allocator);
    defer scratch.deinit();
    const a = out.allocator();
    const s = scratch.allocator();

    // The minimum: a name. Everything else has a resting value.
    const bare = try decodeJob(a, s, "{\"name\":\"j\",\"unknownField\":1}");
    try testing.expectEqualStrings("j", bare.id);
    try testing.expectEqualStrings("", bare.location);
    try testing.expectEqual(types.JobState.unknown, bare.state);
    try testing.expectEqual(types.Target.unknown, bare.target);
    try testing.expect(!bare.failing());

    // Unknown enum values, a successful attempt, OAuth and OIDC.
    const strange = try decodeJob(a, s,
        \\{"name":"projects/p/locations/l/jobs/j","state":"SLEEPING","status":{"code":0},
        \\ "httpTarget":{"uri":"https://x","httpMethod":"BREW","oidcToken":{"serviceAccountEmail":"sa@p.iam.gserviceaccount.com","audience":"https://x"}}}
    );
    try testing.expectEqual(types.JobState.unknown, strange.state);
    try testing.expectEqual(0, strange.last_attempt.?.code);
    try testing.expect(!strange.failing());
    try testing.expectEqual(types.HttpMethod.unknown, strange.target.http.method);
    try testing.expectEqualStrings("sa@p.iam.gserviceaccount.com", strange.target.http.auth.oidc.service_account_email);
    const oauth = try decodeJob(a, s,
        \\{"name":"j","httpTarget":{"uri":"https://x","oauthToken":{"serviceAccountEmail":"sa@p.iam.gserviceaccount.com"}}}
    );
    try testing.expectEqualStrings("sa@p.iam.gserviceaccount.com", oauth.target.http.auth.oauth.service_account_email);

    // An App Engine target with routing.
    const gae = try decodeJob(a, s,
        \\{"name":"j","appEngineHttpTarget":{"relativeUri":"/tick","httpMethod":"GET","appEngineRouting":{"service":"worker","version":"v2"}}}
    );
    try testing.expectEqualStrings("/tick", gae.target.app_engine.relative_uri);
    try testing.expectEqualStrings("worker", gae.target.app_engine.service);
    try testing.expectEqualStrings("v2", gae.target.app_engine.version);

    // What it refuses.
    for ([_][]const u8{
        "[]",
        "{\"jobs\":1}",
        "{\"jobs\":[{\"state\":\"ENABLED\"}]}",
        "{\"name\":\"j\",\"status\":{\"code\":true}}",
        "{\"name\":\"j\",\"attemptDeadline\":\"180\"}",
        "{\"name\":\"j\",\"attemptDeadline\":\"xs\"}",
        "{\"name\":\"j\",\"httpTarget\":{\"uri\":\"u\",\"body\":\"not base64!\"}}",
        "{\"name\":\"j\",\"httpTarget\":{\"headers\":{\"k\":1}}}",
        "{\"name\":\"j\",\"lastAttemptTime\":\"yesterday\"}",
        "{\"locations\":[{\"locationId\":\"x\"}]}",
    }) |body| {
        const job_err = decodeJob(a, s, body);
        const page_err = decodeJobPage(a, s, body);
        const loc_err = decodeLocationPage(a, s, body);
        try testing.expect(job_err == error.InvalidResponse or page_err == error.InvalidResponse or loc_err == error.InvalidResponse);
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
    inline for (.{ decodeJob, decodeJobPage, decodeLocationPage }) |decode| {
        if (decode(a, s, input)) |_| {} else |err| try testing.expectEqual(error.InvalidResponse, err);
    }
}

test "fuzz decoders: any body decodes or is InvalidResponse, never a crash or a leak" {
    try @import("test_util.zig").fuzzBytes({}, decodersProperty, .{ .corpus = &.{
        production.job_created,
        production.job_failed_http,
        production.job_failed_pubsub,
        production.job_paused,
        production.jobs_page,
        production.locations_page,
        "{\"jobs\":[{\"name\":\"projects/p/locations/l/jobs/j\",\"pubsubTarget\":{\"topicName\":\"t\",\"data\":\"emlncHM=\",\"attributes\":{\"k\":\"v\"}},\"status\":{\"code\":-1}}]}",
        "{\"name\":\"j\",\"appEngineHttpTarget\":{\"relativeUri\":\"/t\",\"appEngineRouting\":{\"host\":\"h\"}},\"retryConfig\":{\"retryCount\":\"2\",\"maxRetryDuration\":\"0.5s\"}}",
    } });
}
