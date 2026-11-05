//! A metadata server in memory, for tests of code that reads one: a
//! worker's preemption path, the attributes its controller set, its
//! project, zone and account, with no VM. It goes behind
//! `MetadataServer.Options.transport` and answers as Compute Engine's
//! metadata server answered when measured on 2026-11-05:
//!
//! - a key: 200 with `Metadata-Flavor: Google`, `application/text`, an
//!   `ETag` of 16 hex digits that changes with the value, and the value as
//!   set, a trailing newline included; `?alt=json` quotes it;
//! - a directory's path ending in `/`: its names, one a line, sorted, a
//!   subdirectory's with its `/`; without the `/`, a 301 to it;
//! - a key not set, or no such path: 404, flavor header and all;
//! - no `Metadata-Flavor: Google` (the value's case counts) or any
//!   `X-Forwarded-For`: 403; a method other than GET: 405;
//! - `?wait_for_change=true`: held until the key's ETag differs from
//!   `last_etag` (from the value at the time of asking, without one) or
//!   `timeout_sec` runs out, then answered as above; `last_etag=0` or any
//!   other ETag answers at once, `timeout_sec=0` too, and one that is not
//!   a whole number waits for good, as production's does. A directory
//!   cannot be watched (400), nor the token (400).
//!
//! It starts with `project/project-id`, `project/numeric-project-id`,
//! `instance/zone`, `instance/preempted` (`FALSE`),
//! `instance/maintenance-event` (`NONE`), and the attached account's
//! `email` and `token` under both `default` and its email, so
//! `MetadataServer.provider()` and `projectId` work against it too.
//! `set` puts any other key in and replaces these, waking a watch on it;
//! `preempt` sets `instance/preempted` to `TRUE`, as Compute Engine does
//! when it takes a spot VM back.
//!
//! Its waits are on the `io` it is given, which must be one that blocks
//! (`std.testing.io` does). Not modelled, answered 501 with the reason:
//! `?recursive=true` and `?alt=json` on a directory. Google's error pages
//! are given their title and first line, not their styling.

const FakeMetadataServer = @This();

const std = @import("std");
const Allocator = std.mem.Allocator;
const core = @import("core");
const tp = core.transport;
const MetadataServer = @import("MetadataServer.zig");

gpa: Allocator,
io: std.Io,
options: Options,
mutex: std.Io.Mutex = .init,
/// Broadcast whenever a key changes, for the watches waiting on one.
changed: std.Io.Condition = .init,
/// Owned paths and values, filled with the defaults at the first use.
keys: std.StringArrayHashMapUnmanaged(Value) = .empty,
loaded: bool = false,
refusals: usize = 0,
refusal_status: u16 = 0,
calls: usize = 0,

const Value = struct {
    bytes: []u8,
    /// Served as `application/json` with no ETag, as the token is.
    json: bool = false,
};

pub const Options = struct {
    project_id: []const u8 = "my-project",
    project_number: []const u8 = "123456789012",
    zone: []const u8 = "us-central1-a",
    /// The attached service account, which `default` names as well.
    email: []const u8 = "123456789012-compute@developer.gserviceaccount.com",
    /// What the token path hands out.
    access_token: []const u8 = "ya29.fake-metadata-token",
};

pub const SetError = Allocator.Error || error{
    /// A path `MetadataServer.get` would refuse, or a directory's.
    InvalidPath,
};

pub fn init(gpa: Allocator, io: std.Io, options: Options) FakeMetadataServer {
    return .{ .gpa = gpa, .io = io, .options = options };
}

pub fn deinit(f: *FakeMetadataServer) void {
    var it = f.keys.iterator();
    while (it.next()) |e| {
        f.gpa.free(e.key_ptr.*);
        f.gpa.free(e.value_ptr.bytes);
    }
    f.keys.deinit(f.gpa);
    f.* = undefined;
}

/// Goes into `MetadataServer.Options.transport`.
pub fn transport(f: *FakeMetadataServer) tp.Transport {
    return .{ .ptr = f, .vtable = &.{ .send = send } };
}

/// Sets the key at `path`, such as `instance/attributes/job`, replacing
/// what it held, and wakes every watch on it.
pub fn set(f: *FakeMetadataServer, path: []const u8, value: []const u8) SetError!void {
    if (!MetadataServer.isValidPath(path) or path[path.len - 1] == '/') return error.InvalidPath;
    f.mutex.lockUncancelable(f.io);
    defer f.mutex.unlock(f.io);
    try f.load();
    try f.put(path, value, false);
    f.changed.broadcast(f.io);
}

/// Takes the key at `path` out, if it is there; a watch on it answers 404.
pub fn remove(f: *FakeMetadataServer, path: []const u8) void {
    f.mutex.lockUncancelable(f.io);
    defer f.mutex.unlock(f.io);
    // Loading first, so a default removed stays removed.
    f.load() catch {};
    if (f.keys.fetchOrderedRemove(path)) |e| {
        f.gpa.free(e.key);
        f.gpa.free(e.value.bytes);
    }
    f.changed.broadcast(f.io);
}

/// `instance/preempted` turns `TRUE`, as Compute Engine sets it when it
/// takes a spot VM back; a watch on it wakes.
pub fn preempt(f: *FakeMetadataServer) Allocator.Error!void {
    f.set("instance/preempted", "TRUE") catch |err| switch (err) {
        error.InvalidPath => unreachable,
        error.OutOfMemory => |e| return e,
    };
}

/// Answers the next `n` requests with `status` (503 or 429, say), before
/// looking at them.
pub fn refuseNext(f: *FakeMetadataServer, n: usize, status: u16) void {
    f.mutex.lockUncancelable(f.io);
    defer f.mutex.unlock(f.io);
    f.refusals = n;
    f.refusal_status = status;
}

/// Requests answered, refusals included: a test of a watch can see it did
/// not poll.
pub fn callCount(f: *FakeMetadataServer) usize {
    f.mutex.lockUncancelable(f.io);
    defer f.mutex.unlock(f.io);
    return f.calls;
}

fn load(f: *FakeMetadataServer) Allocator.Error!void {
    if (f.loaded) return;
    var scratch: std.heap.ArenaAllocator = .init(f.gpa);
    defer scratch.deinit();
    const a = scratch.allocator();
    const o = f.options;
    try f.putDefault("project/project-id", o.project_id, false);
    try f.putDefault("project/numeric-project-id", o.project_number, false);
    try f.putDefault("instance/zone", try std.fmt.allocPrint(a, "projects/{s}/zones/{s}", .{ o.project_number, o.zone }), false);
    try f.putDefault("instance/preempted", "FALSE", false);
    try f.putDefault("instance/maintenance-event", "NONE", false);
    const token = try std.fmt.allocPrint(a, "{{\"access_token\":\"{s}\",\"expires_in\":3599,\"token_type\":\"Bearer\"}}", .{o.access_token});
    for ([_][]const u8{ "default", o.email }) |account| {
        try f.putDefault(try std.fmt.allocPrint(a, "instance/service-accounts/{s}/email", .{account}), o.email, false);
        try f.putDefault(try std.fmt.allocPrint(a, "instance/service-accounts/{s}/token", .{account}), token, true);
    }
    f.loaded = true;
}

/// Puts a default unless a test's `set` got there first.
fn putDefault(f: *FakeMetadataServer, path: []const u8, value: []const u8, json: bool) Allocator.Error!void {
    if (f.keys.contains(path)) return;
    try f.put(path, value, json);
}

fn put(f: *FakeMetadataServer, path: []const u8, value: []const u8, json: bool) Allocator.Error!void {
    const bytes = try f.gpa.dupe(u8, value);
    errdefer f.gpa.free(bytes);
    const gop = try f.keys.getOrPut(f.gpa, path);
    if (gop.found_existing) {
        f.gpa.free(gop.value_ptr.bytes);
    } else {
        gop.key_ptr.* = f.gpa.dupe(u8, path) catch |err| {
            _ = f.keys.orderedRemove(path);
            return err;
        };
    }
    gop.value_ptr.* = .{ .bytes = bytes, .json = json };
}

fn send(ptr: *anyopaque, req: tp.Request, arena: Allocator) tp.Error!tp.Response {
    const f: *FakeMetadataServer = @ptrCast(@alignCast(ptr));
    try f.mutex.lock(f.io);
    defer f.mutex.unlock(f.io);
    f.calls += 1;
    try f.load();
    if (f.refusals > 0) {
        f.refusals -= 1;
        return respond(arena, f.refusal_status, "text/html; charset=UTF-8", null, "");
    }
    return f.answer(req, arena);
}

/// What one request asked, from its URL.
const Asked = struct {
    /// The URL's path, `/` and all.
    path: []const u8,
    host: []const u8,
    wait: bool = false,
    last_etag: ?[]const u8 = null,
    /// Null waits for good.
    timeout_s: ?u64 = null,
    json: bool = false,
    recursive: bool = false,
};

fn parse(url: []const u8) Asked {
    const after_scheme = if (std.mem.indexOf(u8, url, "://")) |i| url[i + 3 ..] else url;
    const slash = std.mem.indexOfScalar(u8, after_scheme, '/') orelse after_scheme.len;
    const rest = after_scheme[slash..];
    const q = std.mem.indexOfScalar(u8, rest, '?');
    var asked: Asked = .{ .host = after_scheme[0..slash], .path = if (q) |i| rest[0..i] else rest };
    if (asked.path.len == 0) asked.path = "/";
    var params = std.mem.splitScalar(u8, if (q) |i| rest[i + 1 ..] else "", '&');
    while (params.next()) |param| {
        const eq = std.mem.indexOfScalar(u8, param, '=') orelse param.len;
        take(&asked, param[0..eq], if (eq < param.len) param[eq + 1 ..] else "");
    }
    return asked;
}

/// One query parameter; the server ignores those it does not know.
fn take(asked: *Asked, name: []const u8, value: []const u8) void {
    const eql = std.mem.eql;
    if (eql(u8, name, "wait_for_change")) asked.wait = eql(u8, value, "true") or eql(u8, value, "1");
    if (eql(u8, name, "last_etag")) asked.last_etag = value;
    // A whole number of seconds, or the server waits for good.
    if (eql(u8, name, "timeout_sec")) asked.timeout_s = std.fmt.parseInt(u64, value, 10) catch null;
    if (eql(u8, name, "alt")) asked.json = eql(u8, value, "json");
    if (eql(u8, name, "recursive")) asked.recursive = eql(u8, value, "true");
}

const v1 = "/computeMetadata/v1/";

fn answer(f: *FakeMetadataServer, req: tp.Request, arena: Allocator) tp.Error!tp.Response {
    const asked = parse(req.url);
    if (try refusal(req, arena)) |refused| return refused;
    if (std.mem.eql(u8, asked.path, "/")) return respond(arena, 200, "application/text", null, "computeMetadata/\n");
    if (!std.mem.startsWith(u8, asked.path, v1)) return page(arena, 404, "Not Found");
    // The server reads `a//b` as `a/b`.
    const path = try collapse(arena, asked.path[v1.len..]);
    if (asked.recursive) return respond(arena, 501, "application/text", null, "recursive=true is not modelled by FakeMetadataServer");
    if (path.len == 0 or path[path.len - 1] == '/') return f.directory(arena, path, asked);
    if (f.keys.get(path) == null) return f.notKey(arena, path, asked);
    return f.keyAnswer(arena, path, asked);
}

/// 403 for a request without the flavor header, its value `Google`
/// exactly, or with `X-Forwarded-For`; 405 for any method but GET.
fn refusal(req: tp.Request, arena: Allocator) Allocator.Error!?tp.Response {
    const flavor = headerOf(req.headers, "Metadata-Flavor") orelse return try page(arena, 403, "Forbidden");
    // The value's case counts, unlike the header's name.
    if (!std.mem.eql(u8, flavor, "Google") or headerOf(req.headers, "X-Forwarded-For") != null) return try page(arena, 403, "Forbidden");
    if (req.method != .GET) return try page(arena, 405, "Method Not Allowed");
    return null;
}

/// A directory's path without its `/` is a redirect to it; anything
/// else no key has is 404.
fn notKey(f: *FakeMetadataServer, arena: Allocator, path: []const u8, asked: Asked) Allocator.Error!tp.Response {
    if (!f.isDirectory(try std.fmt.allocPrint(arena, "{s}/", .{path}))) return page(arena, 404, "Not Found");
    const location = try std.fmt.allocPrint(arena, "http://{s}{s}{s}/", .{ asked.host, v1, path });
    const body = try std.fmt.allocPrint(arena, "{s}{s}/\n", .{ v1, path });
    return .{ .status = 301, .body = body, .headers = try arena.dupe(tp.Header, &.{
        .{ .name = "Metadata-Flavor", .value = "Google" },
        .{ .name = "Location", .value = location },
        .{ .name = "Content-Type", .value = "text/html" },
    }) };
}

/// A key's value, once it has changed when the request waits for that.
fn keyAnswer(f: *FakeMetadataServer, arena: Allocator, path: []const u8, asked: Asked) tp.Error!tp.Response {
    if (asked.wait) {
        if (f.keys.get(path).?.json) return respond(arena, 400, "application/text", null, "Wait for change is not supported on token.");
        try f.waitForChange(path, asked);
    }
    // A watch whose key was removed while it waited.
    const value = f.keys.get(path) orelse return page(arena, 404, "Not Found");
    if (value.json) return respond(arena, 200, "application/json", null, try arena.dupe(u8, value.bytes));
    const etag = try etagOf(arena, path, value.bytes);
    if (asked.json) {
        const quoted = try std.json.Stringify.valueAlloc(arena, value.bytes, .{});
        return respond(arena, 200, "application/json", etag, quoted);
    }
    return respond(arena, 200, "application/text", etag, try arena.dupe(u8, value.bytes));
}

/// Holds the request, the mutex released, until the key's ETag is not
/// the one asked about, the key goes, or the timeout runs out.
fn waitForChange(f: *FakeMetadataServer, path: []const u8, asked: Asked) tp.Error!void {
    var scratch: [16]u8 = undefined;
    const now_etag = etagHex(&scratch, path, f.keys.get(path).?.bytes);
    // Without last_etag, the wait is for a change from now.
    var target_buf: [64]u8 = undefined;
    const target = target_buf[0..@min((asked.last_etag orelse now_etag).len, target_buf.len)];
    @memcpy(target, (asked.last_etag orelse now_etag)[0..target.len]);
    const timeout: std.Io.Timeout = if (asked.timeout_s) |s| t: {
        if (s == 0) return;
        const seconds: i64 = @intCast(@min(s, std.math.maxInt(u32)));
        break :t .{ .deadline = .fromNow(f.io, .{ .raw = .fromSeconds(seconds), .clock = .awake }) };
    } else .none;
    while (true) {
        const value = f.keys.get(path) orelse return;
        var buf: [16]u8 = undefined;
        if (!std.mem.eql(u8, etagHex(&buf, path, value.bytes), target)) return;
        f.changed.waitTimeout(f.io, &f.mutex, timeout) catch |err| switch (err) {
            error.Timeout => return,
            error.Canceled => |e| return e,
        };
    }
}

fn directory(f: *FakeMetadataServer, arena: Allocator, dir: []const u8, asked: Asked) tp.Error!tp.Response {
    if (!f.isDirectory(dir)) return page(arena, 404, "Not Found");
    if (asked.wait) return respond(arena, 400, "text/html", null, "Wait for change is not supported on directory listings.  Did you mean to request recursive contents?");
    if (asked.json) return respond(arena, 501, "application/text", null, "alt=json on a directory is not modelled by FakeMetadataServer");
    var names: std.ArrayList([]const u8) = .empty;
    for (known_directories) |known| try addChild(arena, &names, dir, known);
    for (f.keys.keys()) |key| try addChild(arena, &names, dir, key);
    std.mem.sort([]const u8, names.items, {}, lessThan);
    var listing: std.Io.Writer.Allocating = .init(arena);
    for (names.items) |name| listing.writer.print("{s}\n", .{name}) catch return error.OutOfMemory;
    const body = listing.written();
    return respond(arena, 200, "application/text", try etagOf(arena, dir, body), body);
}

/// The directories that are there with nothing in them.
const known_directories = [_][]const u8{
    "instance/attributes/",
    "instance/service-accounts/",
    "project/attributes/",
};

fn isDirectory(f: *FakeMetadataServer, dir: []const u8) bool {
    if (dir.len == 0) return true;
    for (known_directories) |known| if (std.mem.startsWith(u8, known, dir)) return true;
    for (f.keys.keys()) |key| if (std.mem.startsWith(u8, key, dir)) return true;
    return false;
}

/// The name under `dir` that `key` makes: its next name, with a `/` when
/// more follows; each once.
fn addChild(arena: Allocator, names: *std.ArrayList([]const u8), dir: []const u8, key: []const u8) Allocator.Error!void {
    if (!std.mem.startsWith(u8, key, dir) or key.len == dir.len) return;
    const rest = key[dir.len..];
    const name = if (std.mem.indexOfScalar(u8, rest, '/')) |i| rest[0 .. i + 1] else rest;
    for (names.items) |seen| if (std.mem.eql(u8, seen, name)) return;
    try names.append(arena, name);
}

fn lessThan(_: void, a: []const u8, b: []const u8) bool {
    return std.mem.order(u8, a, b) == .lt;
}

fn collapse(arena: Allocator, path: []const u8) Allocator.Error![]const u8 {
    var out: std.ArrayList(u8) = try .initCapacity(arena, path.len);
    for (path, 0..) |c, i| {
        if (c == '/' and (i == 0 or path[i - 1] == '/')) continue;
        out.appendAssumeCapacity(c);
    }
    return out.items;
}

/// 16 lowercase hex digits, as the metadata server's are, the same for
/// the same path and value.
fn etagHex(buf: *[16]u8, path: []const u8, value: []const u8) []const u8 {
    const h = std.hash.Wyhash.hash(0, path) ^ std.hash.Wyhash.hash(1, value);
    return std.fmt.bufPrint(buf, "{x:0>16}", .{h}) catch unreachable;
}

fn etagOf(arena: Allocator, path: []const u8, value: []const u8) Allocator.Error![]const u8 {
    var buf: [16]u8 = undefined;
    return arena.dupe(u8, etagHex(&buf, path, value));
}

fn headerOf(headers: []const tp.Header, name: []const u8) ?[]const u8 {
    for (headers) |h| if (std.ascii.eqlIgnoreCase(h.name, name)) return h.value;
    return null;
}

fn respond(arena: Allocator, status: u16, content_type: []const u8, etag: ?[]const u8, body: []const u8) Allocator.Error!tp.Response {
    var headers: std.ArrayList(tp.Header) = .empty;
    try headers.append(arena, .{ .name = "Metadata-Flavor", .value = "Google" });
    try headers.append(arena, .{ .name = "Content-Type", .value = content_type });
    if (etag) |e| try headers.append(arena, .{ .name = "ETag", .value = e });
    return .{ .status = status, .body = body, .headers = headers.items };
}

/// Google's error page, its title and first line.
fn page(arena: Allocator, status: u16, reason: []const u8) Allocator.Error!tp.Response {
    const body = try std.fmt.allocPrint(arena, "<!DOCTYPE html>\n<html lang=en>\n  <title>Error {d} ({s})!!1</title>\n  <p><b>{d}.</b> <ins>That\u{2019}s an error.</ins>\n", .{ status, reason, status });
    return respond(arena, status, "text/html; charset=UTF-8", null, body);
}

const testing = std.testing;
const flavor_header: []const tp.Header = &.{.{ .name = "Metadata-Flavor", .value = "Google" }};

/// A `MetadataServer` over the fake, both on `std.testing.io`, whose
/// waits block as a real task's do.
const Harness = struct {
    fake: FakeMetadataServer,
    diag: core.Diagnostics,
    arena: std.heap.ArenaAllocator,
    metadata: MetadataServer,

    fn init(h: *Harness, options: Options) !void {
        h.* = .{
            .fake = .init(testing.allocator, testing.io, options),
            .diag = .{},
            .arena = .init(testing.allocator),
            .metadata = undefined,
        };
        errdefer h.fake.deinit();
        errdefer h.arena.deinit();
        h.metadata = try .init(testing.allocator, testing.io, .{
            .diagnostics = &h.diag,
            .transport = h.fake.transport(),
            .retry = .{ .max_attempts = 3, .initial_backoff_ms = 1, .max_backoff_ms = 2 },
        });
    }

    fn deinit(h: *Harness) void {
        h.metadata.deinit();
        h.arena.deinit();
        h.fake.deinit();
    }

    fn a(h: *Harness) Allocator {
        return h.arena.allocator();
    }

    /// One request as any HTTP client might send it.
    fn raw(h: *Harness, method: tp.Method, target: []const u8, headers: []const tp.Header) !tp.Response {
        const url = try std.fmt.allocPrint(h.a(), "http://metadata.google.internal{s}", .{target});
        return h.fake.transport().send(.{ .method = method, .url = url, .headers = headers }, h.a());
    }
};

fn elapsedMs(since: std.Io.Timestamp) i64 {
    return since.durationTo(std.Io.Clock.awake.now(testing.io)).toMilliseconds();
}

test "FakeMetadataServer: a workload's project, zone, account and token, as Compute Engine's gives them" {
    var h: Harness = undefined;
    try h.init(.{ .project_id = "shop-prod", .project_number = "42", .zone = "europe-west1-b", .email = "worker@shop-prod.iam.gserviceaccount.com" });
    defer h.deinit();
    const io = testing.io;
    try testing.expectEqualStrings("shop-prod", try h.metadata.projectId(io, h.a()));
    try testing.expectEqualStrings("worker@shop-prod.iam.gserviceaccount.com", try h.metadata.email(io, h.a()));
    try testing.expectEqualStrings("ya29.fake-metadata-token", try h.metadata.provider().getToken(io, h.a(), &.{"https://www.googleapis.com/auth/cloud-platform"}));
    try testing.expectEqualStrings("projects/42/zones/europe-west1-b", try h.metadata.get(io, h.a(), "instance/zone"));
    try testing.expectEqualStrings("42", try h.metadata.get(io, h.a(), "project/numeric-project-id"));
    try testing.expectEqualStrings("NONE", try h.metadata.get(io, h.a(), "instance/maintenance-event"));
    try testing.expect(!try h.metadata.preempted(io));
    // The account by its email, as by `default`.
    try testing.expectEqualStrings("worker@shop-prod.iam.gserviceaccount.com", try h.metadata.get(io, h.a(), "instance/service-accounts/worker@shop-prod.iam.gserviceaccount.com/email"));
    try testing.expectEqualStrings("default/\nworker@shop-prod.iam.gserviceaccount.com/\n", try h.metadata.get(io, h.a(), "instance/service-accounts/"));
}

test "FakeMetadataServer: attributes set, read, listed and removed" {
    var h: Harness = undefined;
    try h.init(.{});
    defer h.deinit();
    const io = testing.io;
    try h.fake.set("instance/attributes/job", "fuzz-codec");
    try h.fake.set("instance/attributes/job-args", "600\n");
    try h.fake.set("project/attributes/env", "staging");
    try testing.expectEqualStrings("fuzz-codec", (try h.metadata.instanceAttribute(io, h.a(), "job")).?);
    try testing.expectEqualStrings("600\n", (try h.metadata.instanceAttribute(io, h.a(), "job-args")).?);
    try testing.expectEqualStrings("staging", try h.metadata.get(io, h.a(), "project/attributes/env"));
    try testing.expectEqualStrings("job\njob-args\n", try h.metadata.get(io, h.a(), "instance/attributes/"));
    try testing.expectEqualStrings("attributes/\nmaintenance-event\npreempted\nservice-accounts/\nzone\n", try h.metadata.get(io, h.a(), "instance/"));
    try testing.expectEqual(null, try h.metadata.instanceAttribute(io, h.a(), "shard"));
    h.fake.remove("instance/attributes/job");
    try testing.expectEqual(null, try h.metadata.instanceAttribute(io, h.a(), "job"));
    // A default replaced, and one taken out.
    try h.fake.set("project/project-id", "other");
    try testing.expectEqualStrings("other", try h.metadata.projectId(io, h.a()));
    h.fake.remove("instance/preempted");
    try testing.expectError(error.NotFound, h.metadata.preempted(io));
    // Empty, but there.
    h.fake.remove("project/attributes/env");
    try testing.expectEqualStrings("", try h.metadata.get(io, h.a(), "project/attributes/"));
    for ([_][]const u8{ "", "instance/attributes/", "/instance/zone", "instance/../zone", "a?b" }) |path| {
        try testing.expectError(error.InvalidPath, h.fake.set(path, "x"));
    }
}

fn preemptSoon(fake: *FakeMetadataServer) void {
    testing.io.sleep(.fromMilliseconds(50), .awake) catch {};
    fake.preempt() catch {};
}

fn removeSoon(fake: *FakeMetadataServer) void {
    testing.io.sleep(.fromMilliseconds(50), .awake) catch {};
    fake.remove("instance/attributes/job");
}

test "FakeMetadataServer: a watch on instance/preempted wakes when the VM is preempted, with no polling" {
    var h: Harness = undefined;
    try h.init(.{});
    defer h.deinit();
    const io = testing.io;
    const first = try h.metadata.watch(io, h.a(), "instance/preempted", .{});
    try testing.expectEqualStrings("FALSE", first.value);
    try testing.expectEqual(16, first.etag.len);
    const started = std.Io.Clock.awake.now(io);
    const thread = try std.Thread.spawn(.{}, preemptSoon, .{&h.fake});
    defer thread.join();
    const woken = try h.metadata.watch(io, h.a(), "instance/preempted", .{ .last_etag = first.etag, .timeout_s = 60 });
    try testing.expectEqualStrings("TRUE", woken.value);
    try testing.expect(!std.mem.eql(u8, first.etag, woken.etag));
    try testing.expect(elapsedMs(started) < 30_000);
    // One request held, not one a poll.
    try testing.expectEqual(2, h.fake.callCount());
    try testing.expect(try h.metadata.preempted(io));
}

test "FakeMetadataServer: a watch that runs out answers the value unchanged, with the same ETag" {
    var h: Harness = undefined;
    try h.init(.{});
    defer h.deinit();
    const io = testing.io;
    const first = try h.metadata.watch(io, h.a(), "instance/maintenance-event", .{});
    const started = std.Io.Clock.awake.now(io);
    const again = try h.metadata.watch(io, h.a(), "instance/maintenance-event", .{ .last_etag = first.etag, .timeout_s = 1 });
    try testing.expect(elapsedMs(started) >= 900);
    try testing.expectEqualStrings("NONE", again.value);
    try testing.expectEqualStrings(first.etag, again.etag);
}

test "FakeMetadataServer: an ETag follows the value: a change of the same length moves it, the same value back restores it" {
    var h: Harness = undefined;
    try h.init(.{});
    defer h.deinit();
    try h.fake.set("instance/attributes/shard", "a");
    const a1 = try h.metadata.watch(testing.io, h.a(), "instance/attributes/shard", .{});
    try h.fake.set("instance/attributes/shard", "b");
    const b = try h.metadata.watch(testing.io, h.a(), "instance/attributes/shard", .{});
    try testing.expect(!std.mem.eql(u8, a1.etag, b.etag));
    try h.fake.set("instance/attributes/shard", "a");
    const a2 = try h.metadata.watch(testing.io, h.a(), "instance/attributes/shard", .{});
    try testing.expectEqualStrings(a1.etag, a2.etag);
}

test "FakeMetadataServer: wait_for_change with no last_etag waits for the next change, as production's does" {
    var h: Harness = undefined;
    try h.init(.{});
    defer h.deinit();
    const started = std.Io.Clock.awake.now(testing.io);
    const res = try h.raw(.GET, "/computeMetadata/v1/instance/preempted?wait_for_change=true&timeout_sec=1", flavor_header);
    try testing.expect(elapsedMs(started) >= 900);
    try testing.expectEqualStrings("FALSE", res.body);
}

test "FakeMetadataServer: a watch on a key removed while it waits is NotFound, and on one never set at once" {
    var h: Harness = undefined;
    try h.init(.{});
    defer h.deinit();
    const io = testing.io;
    try h.fake.set("instance/attributes/job", "a");
    const first = try h.metadata.watch(io, h.a(), "instance/attributes/job", .{});
    const thread = try std.Thread.spawn(.{}, removeSoon, .{&h.fake});
    defer thread.join();
    try testing.expectError(error.NotFound, h.metadata.watch(io, h.a(), "instance/attributes/job", .{ .last_etag = first.etag, .timeout_s = 60 }));
    try testing.expectError(error.NotFound, h.metadata.watch(io, h.a(), "instance/attributes/shard", .{ .timeout_s = 60 }));
}

fn watchForever(h: *Harness, etag: []const u8) MetadataServer.GetError!MetadataServer.Watched {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    return h.metadata.watch(testing.io, arena.allocator(), "instance/preempted", .{ .last_etag = etag, .timeout_s = 3600 });
}

test "FakeMetadataServer: a watch's task, canceled, ends with Canceled" {
    var h: Harness = undefined;
    try h.init(.{});
    defer h.deinit();
    const io = testing.io;
    const first = try h.metadata.watch(io, h.a(), "instance/preempted", .{});
    var watching = try io.concurrent(watchForever, .{ &h, first.etag });
    io.sleep(.fromMilliseconds(50), .awake) catch {};
    try testing.expectError(error.Canceled, watching.cancel(io));
}

test "FakeMetadataServer: the refusals, redirects and listings production gave" {
    var h: Harness = undefined;
    try h.init(.{});
    defer h.deinit();
    // The flavor header: missing, its value lowercased, or a forwarded
    // request's.
    for ([_][]const tp.Header{
        &.{},
        &.{.{ .name = "Metadata-Flavor", .value = "google" }},
        &.{ .{ .name = "Metadata-Flavor", .value = "Google" }, .{ .name = "X-Forwarded-For", .value = "10.0.0.1" } },
    }) |headers| {
        const res = try h.raw(.GET, "/computeMetadata/v1/instance/preempted", headers);
        try testing.expectEqual(403, res.status);
        try testing.expectEqualStrings("Google", res.header("Metadata-Flavor").?);
        try testing.expect(std.mem.indexOf(u8, res.body, "<title>Error 403 (Forbidden)!!1</title>") != null);
    }
    // The header's name in any case.
    try testing.expectEqual(200, (try h.raw(.GET, "/computeMetadata/v1/instance/preempted", &.{.{ .name = "metadata-flavor", .value = "Google" }})).status);
    try testing.expectEqual(405, (try h.raw(.POST, "/computeMetadata/v1/instance/preempted", flavor_header)).status);

    const moved = try h.raw(.GET, "/computeMetadata/v1/instance/attributes", flavor_header);
    try testing.expectEqual(301, moved.status);
    try testing.expectEqualStrings("http://metadata.google.internal/computeMetadata/v1/instance/attributes/", moved.header("Location").?);
    try testing.expectEqualStrings("Google", moved.header("Metadata-Flavor").?);

    const key = try h.raw(.GET, "/computeMetadata/v1/instance//preempted?foo=bar", flavor_header);
    try testing.expectEqual(200, key.status);
    try testing.expectEqualStrings("FALSE", key.body);
    try testing.expectEqualStrings("application/text", key.header("Content-Type").?);
    const quoted = try h.raw(.GET, "/computeMetadata/v1/instance/preempted?alt=json", flavor_header);
    try testing.expectEqualStrings("\"FALSE\"", quoted.body);
    try testing.expectEqualStrings("application/json", quoted.header("Content-Type").?);
    try testing.expectEqualStrings(key.header("ETag").?, quoted.header("ETag").?);

    const root = try h.raw(.GET, "/", flavor_header);
    try testing.expectEqualStrings("computeMetadata/\n", root.body);
    try testing.expectEqual(null, root.header("ETag"));
    const v1_root = try h.raw(.GET, "/computeMetadata/v1/", flavor_header);
    try testing.expectEqualStrings("instance/\nproject/\n", v1_root.body);
    try testing.expect(v1_root.header("ETag") != null);

    for ([_][]const u8{ "/computeMetadata/v1/instance/no-such-path", "/computeMetadata/v1/instance/zone/", "/computeMetadata/v1/instance%2Fzone", "/elsewhere" }) |target| {
        const missing = try h.raw(.GET, target, flavor_header);
        try testing.expectEqual(404, missing.status);
        try testing.expectEqualStrings("Google", missing.header("Metadata-Flavor").?);
        try testing.expectEqualStrings("text/html; charset=UTF-8", missing.header("Content-Type").?);
    }

    const token = try h.raw(.GET, "/computeMetadata/v1/instance/service-accounts/default/token", flavor_header);
    try testing.expectEqualStrings("application/json", token.header("Content-Type").?);
    try testing.expectEqual(null, token.header("ETag"));
    const token_watch = try h.raw(.GET, "/computeMetadata/v1/instance/service-accounts/default/token?wait_for_change=true&timeout_sec=2", flavor_header);
    try testing.expectEqual(400, token_watch.status);
    try testing.expectEqualStrings("Wait for change is not supported on token.", token_watch.body);
    const listing_watch = try h.raw(.GET, "/computeMetadata/v1/instance/attributes/?wait_for_change=true&timeout_sec=2", flavor_header);
    try testing.expectEqual(400, listing_watch.status);
    try testing.expectEqualStrings("Wait for change is not supported on directory listings.  Did you mean to request recursive contents?", listing_watch.body);
    try testing.expectEqual(501, (try h.raw(.GET, "/computeMetadata/v1/instance/attributes/?recursive=true", flavor_header)).status);
}

test "FakeMetadataServer: wait_for_change answers at once unless the ETag asked about is the current one" {
    var h: Harness = undefined;
    try h.init(.{});
    defer h.deinit();
    const etag = (try h.raw(.GET, "/computeMetadata/v1/instance/preempted", flavor_header)).header("ETag").?;
    const started = std.Io.Clock.awake.now(testing.io);
    for ([_][]const u8{
        "?wait_for_change=true&last_etag=0&timeout_sec=30",
        "?wait_for_change=true&last_etag=0123456789abcdef&timeout_sec=30",
        try std.fmt.allocPrint(h.a(), "?wait_for_change=true&last_etag={s}&timeout_sec=0", .{etag}),
        try std.fmt.allocPrint(h.a(), "?wait_for_change=false&last_etag={s}&timeout_sec=30", .{etag}),
    }) |query| {
        const res = try h.raw(.GET, try std.fmt.allocPrint(h.a(), "/computeMetadata/v1/instance/preempted{s}", .{query}), flavor_header);
        try testing.expectEqual(200, res.status);
        try testing.expectEqualStrings("FALSE", res.body);
    }
    try testing.expect(elapsedMs(started) < 10_000);
}

fn rawForever(h: *Harness, etag: []const u8) tp.Error!u16 {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const url = std.fmt.allocPrint(arena.allocator(), "http://metadata.google.internal/computeMetadata/v1/instance/preempted?wait_for_change=true&last_etag={s}&timeout_sec=1.5", .{etag}) catch return error.OutOfMemory;
    const res = try h.fake.transport().send(.{ .method = .GET, .url = url, .headers = flavor_header }, arena.allocator());
    return res.status;
}

test "FakeMetadataServer: a timeout_sec that is not a whole number waits for good, as production's does" {
    var h: Harness = undefined;
    try h.init(.{});
    defer h.deinit();
    const io = testing.io;
    const etag = try h.a().dupe(u8, (try h.raw(.GET, "/computeMetadata/v1/instance/preempted", flavor_header)).header("ETag").?);
    var waiting = try io.concurrent(rawForever, .{ &h, etag });
    // Well past 1.5 s, and still held.
    io.sleep(.fromMilliseconds(2_000), .awake) catch {};
    try testing.expectError(error.Canceled, waiting.cancel(io));
}

test "FakeMetadataServer: refuseNext answers busy, and the client's retry gets through" {
    var h: Harness = undefined;
    try h.init(.{});
    defer h.deinit();
    h.fake.refuseNext(2, 503);
    try testing.expectEqualStrings("FALSE", try h.metadata.get(testing.io, h.a(), "instance/preempted"));
    try testing.expectEqual(3, h.fake.callCount());
    h.fake.refuseNext(3, 429);
    try testing.expectError(error.MetadataRefused, h.metadata.get(testing.io, h.a(), "instance/preempted"));
    try testing.expectEqual(429, h.diag.http_status);
}
