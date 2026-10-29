//! A Cloud KMS client: configuration, the HTTP connection pool, and the
//! entry points to key rings, keys and the project's locations.
//!
//! Every call blocks the calling task until it completes, using the
//! `std.Io` and allocator passed to `init`. A client must not be used from
//! two tasks at once; give each task its own.

const Client = @This();

const std = @import("std");
const Allocator = std.mem.Allocator;
const core = @import("core");
const codec = @import("codec.zig");
const errors = @import("errors.zig");
const integrity = @import("integrity.zig");
const Key = @import("Key.zig");
const KeyRing = @import("KeyRing.zig");
const names = @import("names.zig");
const rpc = @import("rpc.zig");
const types = @import("types.zig");
const validate = @import("validate.zig");
const Diagnostics = core.Diagnostics;
const Error = errors.Error;
const HttpTransport = core.transport.HttpTransport;
const RetryPolicy = core.RetryPolicy;
const TokenProvider = core.TokenProvider;
const Transport = core.transport.Transport;

gpa: Allocator,
io: std.Io,
/// Owned. Scheme, host and port.
base_url: []const u8,
token_provider: TokenProvider,
/// Owned copy of `Options.project_id`.
project: []const u8,
/// Owned copy of `Options.location`.
location: []const u8,
send_quota_project: bool,
retry: RetryPolicy,
request_timeout_ms: u32,
max_response_bytes: usize,
diagnostics: ?*Diagnostics,
transport: Transport,
/// The built-in transport, when `Options.transport` was null.
http: ?*HttpTransport,
/// Owned copy of `Options.user_agent`.
user_agent: []const u8,
/// The delay the last refused attempt asked for, kept by the engine.
server_delay_ms: ?u32 = null,

pub const default_endpoint = "https://cloudkms.googleapis.com";

pub const Options = struct {
    /// Required: the project whose keys are used and managed, an id or a
    /// number.
    project_id: []const u8,
    /// Required: where key rings are made and found. A region
    /// ("us-central1"), a multi-region ("us") or "global". A key named in
    /// full may be anywhere (`keyNamed`).
    location: []const u8,
    /// Required. Cloud KMS has no emulator, so there is no unauthenticated
    /// mode.
    token_provider: TokenProvider,
    /// Overrides the host: a test server, say. Must be `https`, since it
    /// receives credentials.
    endpoint: ?[]const u8 = null,
    /// Sends the credentials' quota project as `x-goog-user-project`, as
    /// every module does.
    send_quota_project: bool = true,
    /// 5xx, 429 and dropped connections are retried, except where a repeat
    /// would make something new: a version is created once.
    retry: RetryPolicy = .{},
    /// How long one request may take before it is `error.TimedOut`. Google's
    /// own clients give every KMS call 60 s. 0 removes the limit.
    request_timeout_ms: u32 = 60_000,
    /// A response whose decompressed body is larger fails with
    /// `error.ResponseTooLarge`. Used by the built-in transport; a transport
    /// passed in keeps its own limit.
    max_response_bytes: usize = core.transport.default_max_response_bytes,
    /// Printable ASCII.
    user_agent: []const u8 = "gcp-zig-kms/0.61",
    /// Filled with details of every failed call; cleared by each new call.
    diagnostics: ?*Diagnostics = null,
    /// Sends requests through this instead of `std.http.Client`. Useful for
    /// tests, including tests of code that uses this library.
    transport: ?Transport = null,
};

/// Copies what it keeps from `options`; nothing borrowed outlives the call
/// except `diagnostics`, the token provider and the transport.
pub fn init(gpa: Allocator, io: std.Io, options: Options) Error!Client {
    const diag = options.diagnostics;
    if (diag) |d| d.clear();
    if (!validate.isProject(options.project_id)) {
        if (diag) |d| d.print("invalid project: expected a project id or number", .{});
        return error.InvalidName;
    }
    if (!validate.isLocation(options.location)) {
        if (diag) |d| d.print("invalid location: expected a region such as us-central1, a multi-region such as us, or global", .{});
        return error.InvalidName;
    }
    if (!options.retry.isValid()) {
        if (diag) |d| d.print("invalid retry policy: max_attempts must be at least 1, multiplier finite and at least 1", .{});
        return error.InvalidOptions;
    }
    if (!validate.isUserAgent(options.user_agent)) {
        if (diag) |d| d.print("invalid user agent: expected printable ASCII", .{});
        return error.InvalidOptions;
    }
    if (options.max_response_bytes == 0) {
        if (diag) |d| d.print("invalid max_response_bytes: 0 would refuse every answer", .{});
        return error.InvalidOptions;
    }

    const base_url = core.endpoint.baseUrl(gpa, options.endpoint orelse default_endpoint, .https) catch |err| {
        if (err == error.InvalidEndpoint) if (diag) |d| d.print("invalid endpoint: expected https://host[:port]", .{});
        return err;
    };
    errdefer gpa.free(base_url);
    // Every request carries a bearer token, which must not travel in cleartext.
    if (!std.mem.startsWith(u8, base_url, "https://")) {
        if (diag) |d| d.print("invalid endpoint: endpoints that receive credentials must use https", .{});
        return error.InvalidEndpoint;
    }
    const project = try gpa.dupe(u8, options.project_id);
    errdefer gpa.free(project);
    const location = try gpa.dupe(u8, options.location);
    errdefer gpa.free(location);
    const user_agent = try gpa.dupe(u8, options.user_agent);
    errdefer gpa.free(user_agent);

    var http: ?*HttpTransport = null;
    const transport = options.transport orelse t: {
        const h = try gpa.create(HttpTransport);
        h.* = .init(gpa, io, user_agent);
        h.max_response_bytes = options.max_response_bytes;
        http = h;
        break :t h.transport();
    };
    return .{
        .gpa = gpa,
        .io = io,
        .base_url = base_url,
        .token_provider = options.token_provider,
        .project = project,
        .location = location,
        .send_quota_project = options.send_quota_project,
        .retry = options.retry,
        .request_timeout_ms = options.request_timeout_ms,
        .max_response_bytes = options.max_response_bytes,
        .diagnostics = diag,
        .transport = transport,
        .http = http,
        .user_agent = user_agent,
    };
}

pub fn deinit(self: *Client) void {
    if (self.http) |h| {
        h.deinit();
        self.gpa.destroy(h);
    }
    self.gpa.free(self.user_agent);
    self.gpa.free(self.location);
    self.gpa.free(self.project);
    self.gpa.free(self.base_url);
    self.* = undefined;
}

/// A handle on the key ring `id` in the client's location. Makes no call;
/// `id` is borrowed for as long as the handle is used.
pub fn keyRing(self: *Client, id: []const u8) KeyRing {
    return .{ .client = self, .target = .{ .project = self.project, .location = self.location, .key_ring = id } };
}

/// A handle on a key named in full,
/// `projects/P/locations/L/keyRings/R/cryptoKeys/K`, as a bucket or a
/// secret names its key: it may be in another project or location than the
/// client's. Makes no call; `name` is borrowed for as long as the handle is
/// used. A name of another form, or with a part this client will not put
/// in a path, is `error.InvalidName`.
pub fn keyNamed(self: *Client, name: []const u8) Error!Key {
    rpc.begin(self);
    const parsed = core.names.KmsKeyName.parse(name) orelse {
        if (self.diagnostics) |d| d.print("not a key's name: expected projects/P/locations/L/keyRings/R/cryptoKeys/K", .{});
        return error.InvalidName;
    };
    if (parsed.version != null) {
        if (self.diagnostics) |d| d.print("a version's name, not a key's: name the key, and the version with Key.version", .{});
        return error.InvalidName;
    }
    if (!validate.isProject(parsed.project) or !validate.isLocation(parsed.location) or !validate.isId(parsed.key_ring) or !validate.isId(parsed.key)) {
        if (self.diagnostics) |d| d.print("a key's name with a part this client will not put in a path", .{});
        return error.InvalidName;
    }
    return .{ .client = self, .target = .{ .project = parsed.project, .location = parsed.location, .key_ring = parsed.key_ring, .key = parsed.key } };
}

/// One page of the key rings in the client's location.
pub fn listKeyRings(self: *Client, options: types.ListOptions) Error!types.Owned(types.KeyRingPage) {
    rpc.begin(self);
    var scratch: std.heap.ArenaAllocator = .init(self.gpa);
    defer scratch.deinit();
    const target: names.Target = .{ .project = self.project, .location = self.location };
    const path = try self.listPath(scratch.allocator(), target, "/keyRings", options);
    var result: types.Owned(types.KeyRingPage) = try .init(self.gpa);
    errdefer result.deinit();
    const body = try rpc.execute(self, result.arena, .{ .method = .GET, .path = path });
    result.value = codec.decodeKeyRingPage(result.arena.allocator(), scratch.allocator(), body) catch |err|
        return rpc.decodeFailed(self, err, "key ring list");
    return result;
}

/// One page of the locations Cloud KMS offers the project, each with
/// whether it has Cloud HSM and Cloud EKM.
pub fn listLocations(self: *Client, options: types.ListOptions) Error!types.Owned(types.LocationPage) {
    rpc.begin(self);
    try self.checkList(options);
    var scratch: std.heap.ArenaAllocator = .init(self.gpa);
    defer scratch.deinit();
    const a = scratch.allocator();
    var w: std.Io.Writer.Allocating = .init(a);
    w.writer.writeAll(try names.locations(a, self.project)) catch return error.OutOfMemory;
    try writeListParams(&w.writer, options);
    var result: types.Owned(types.LocationPage) = try .init(self.gpa);
    errdefer result.deinit();
    const body = try rpc.execute(self, result.arena, .{ .method = .GET, .path = w.written() });
    result.value = codec.decodeLocationPage(result.arena.allocator(), a, body) catch |err|
        return rpc.decodeFailed(self, err, "location list");
    return result;
}

/// `len` random bytes, 8 to 1,024, from a Cloud HSM in the client's
/// location, checked against their checksum. Billed as a crypto operation;
/// software and external keys have no such call.
pub fn randomBytes(self: *Client, len: u16) Error!types.Owned([]const u8) {
    rpc.begin(self);
    if (len < validate.min_random_bytes or len > validate.max_random_bytes) {
        if (self.diagnostics) |d| d.print("random bytes come 8 to 1,024 at a time; {d} asked", .{len});
        return if (len > validate.max_random_bytes) error.TooLarge else error.InvalidOptions;
    }
    var scratch: std.heap.ArenaAllocator = .init(self.gpa);
    defer scratch.deinit();
    const a = scratch.allocator();
    const target: names.Target = .{ .project = self.project, .location = self.location };
    const path = try target.path(a, ":generateRandomBytes");
    const body = try codec.encodeRandom(a, len);
    var tries: integrity.Attempts = .{ .client = self, .what = "randomBytes" };
    while (true) {
        tries.next();
        var result: types.Owned([]const u8) = try .init(self.gpa);
        const answer_body = rpc.execute(self, result.arena, .{ .method = .POST, .path = path, .body = body }) catch |err| {
            result.deinit();
            return err;
        };
        const answer = codec.decodeRandom(result.arena.allocator(), a, answer_body) catch |err| {
            result.deinit();
            return rpc.decodeFailed(self, err, "random bytes");
        };
        const problem: ?[]const u8 = if (!integrity.matches(answer.data, answer.data_crc32c))
            "the bytes do not match their checksum"
        else if (answer.data.len != len)
            "the answer holds another number of bytes than asked"
        else
            null;
        if (problem) |reason| {
            result.deinit();
            try tries.failed(reason);
            continue;
        }
        result.value = answer.data;
        return result;
    }
}

/// One page of the keys deleted in the client's location. A deleted key's
/// id can never be used again in its project; these records say which.
pub fn listRetiredKeys(self: *Client, options: types.ListOptions) Error!types.Owned(types.RetiredKeyPage) {
    rpc.begin(self);
    if (options.filter != null or options.order_by != null) {
        if (self.diagnostics) |d| d.print("retired keys take no filter and no order", .{});
        return error.InvalidOptions;
    }
    var scratch: std.heap.ArenaAllocator = .init(self.gpa);
    defer scratch.deinit();
    const target: names.Target = .{ .project = self.project, .location = self.location };
    const path = try self.listPath(scratch.allocator(), target, "/retiredResources", options);
    var result: types.Owned(types.RetiredKeyPage) = try .init(self.gpa);
    errdefer result.deinit();
    const body = try rpc.execute(self, result.arena, .{ .method = .GET, .path = path });
    result.value = codec.decodeRetiredKeyPage(result.arena.allocator(), scratch.allocator(), body) catch |err|
        return rpc.decodeFailed(self, err, "retired key list");
    return result;
}

/// `target`'s path, then `collection`, then the list's parameters, after
/// checking them.
pub fn listPath(self: *Client, arena: Allocator, target: names.Target, collection: []const u8, options: types.ListOptions) Error![]const u8 {
    try self.checkList(options);
    var w: std.Io.Writer.Allocating = .init(arena);
    target.writePath(&w.writer, collection) catch return error.OutOfMemory;
    try writeListParams(&w.writer, options);
    return w.written();
}

fn writeListParams(w: *std.Io.Writer, options: types.ListOptions) Error!void {
    var params: core.query.Params = .init(w);
    params.addNonZero("pageSize", options.page_size) catch return error.OutOfMemory;
    params.addOptional("pageToken", options.page_token) catch return error.OutOfMemory;
    params.addOptional("filter", options.filter) catch return error.OutOfMemory;
    params.addOptional("orderBy", options.order_by) catch return error.OutOfMemory;
}

fn checkList(self: *Client, options: types.ListOptions) Error!void {
    if (options.page_token) |t| if (!validate.isPageToken(t)) {
        if (self.diagnostics) |d| d.print("invalid page token: expected printable ASCII", .{});
        return error.InvalidName;
    };
    inline for (.{ "filter", "order_by" }) |name| {
        if (@field(options, name)) |text| if (validate.queryTextProblem(text)) |p| {
            if (self.diagnostics) |d| d.print("invalid {s}: {s}", .{ name, p });
            return error.InvalidOptions;
        };
    }
}

/// Checks the ids `target` names, the client's own project and location
/// aside, which `init` checked; a key named in full was checked whole.
pub fn checkTarget(self: *Client, target: names.Target) Error!void {
    if (target.key_ring) |r| if (!validate.isId(r)) {
        if (self.diagnostics) |d| d.print("invalid key ring id: 1 to 63 letters, digits, _ and -", .{});
        return error.InvalidName;
    };
    if (target.key) |k| if (!validate.isId(k)) {
        if (self.diagnostics) |d| d.print("invalid key id: 1 to 63 letters, digits, _ and -", .{});
        return error.InvalidName;
    };
    if (target.version) |v| if (v == 0) {
        if (self.diagnostics) |d| d.print("invalid version: versions are numbered from 1", .{});
        return error.InvalidName;
    };
}

const testing = std.testing;
const test_util = @import("test_util.zig");
const Harness = test_util.Harness;
const base = test_util.base;

test "init: each option this client will not use is refused with its reason" {
    var token: test_util.FakeTokenProvider = .{ .token = "t" };
    var clock: test_util.FakeClock = .{};
    var diag: Diagnostics = .{};
    const cases = [_]struct { Options, Error, []const u8 }{
        .{ .{ .project_id = "", .location = "global", .token_provider = token.provider(), .diagnostics = &diag }, error.InvalidName, "invalid project" },
        .{ .{ .project_id = "p", .location = "US", .token_provider = token.provider(), .diagnostics = &diag }, error.InvalidName, "invalid location" },
        .{ .{ .project_id = "p", .location = "", .token_provider = token.provider(), .diagnostics = &diag }, error.InvalidName, "invalid location" },
        .{ .{ .project_id = "p", .location = "global", .token_provider = token.provider(), .retry = .{ .max_attempts = 0 }, .diagnostics = &diag }, error.InvalidOptions, "invalid retry policy" },
        .{ .{ .project_id = "p", .location = "global", .token_provider = token.provider(), .user_agent = "a\nb", .diagnostics = &diag }, error.InvalidOptions, "invalid user agent" },
        .{ .{ .project_id = "p", .location = "global", .token_provider = token.provider(), .max_response_bytes = 0, .diagnostics = &diag }, error.InvalidOptions, "max_response_bytes" },
        .{ .{ .project_id = "p", .location = "global", .token_provider = token.provider(), .endpoint = "http://localhost:8080", .diagnostics = &diag }, error.InvalidEndpoint, "must use https" },
    };
    for (cases) |case| {
        try testing.expectError(case[1], Client.init(testing.allocator, clock.io(), case[0]));
        try testing.expect(std.mem.indexOf(u8, diag.message(), case[2]) != null);
    }
}

test "init: every allocation failure is OutOfMemory without leaks" {
    const S = struct {
        fn run(gpa: Allocator) !void {
            var token: test_util.FakeTokenProvider = .{ .token = "t" };
            var clock: test_util.FakeClock = .{};
            var c = try Client.init(gpa, clock.io(), .{ .project_id = "p", .location = "global", .token_provider = token.provider() });
            c.deinit();
        }
    };
    try testing.checkAllAllocationFailures(test_util.no_grow_allocator, S.run, .{});
}

test "golden: lists of key rings, locations and retired keys" {
    var h: Harness = undefined;
    try h.init(&.{
        .{ .respond = .{ .body = "{\"keyRings\":[{\"name\":\"projects/my-project/locations/us-central1/keyRings/r\"}],\"nextPageToken\":\"n\"}" } },
        .{ .respond = .{ .body = "{\"locations\":[{\"name\":\"projects/my-project/locations/global\",\"locationId\":\"global\",\"metadata\":{\"hsmAvailable\":true}}]}" } },
        .{ .respond = .{ .body = "{\"retiredResources\":[{\"name\":\"projects/my-project/locations/us-central1/retiredResources/x\",\"originalResource\":\"projects/my-project/locations/us-central1/keyRings/r/cryptoKeys/k\"}]}" } },
    }, .{});
    defer h.deinit();
    var rings = try h.client.listKeyRings(.{ .page_size = 2 });
    defer rings.deinit();
    try h.expectRequest(0, .GET, base ++ "/keyRings?pageSize=2", null);
    try testing.expectEqualStrings("n", rings.value.next_page_token.?);
    var locs = try h.client.listLocations(.{});
    defer locs.deinit();
    try h.expectRequest(1, .GET, "https://cloudkms.googleapis.com/v1/projects/my-project/locations", null);
    try testing.expect(locs.value.locations[0].hsm_available);
    var retired = try h.client.listRetiredKeys(.{ .page_token = "abc" });
    defer retired.deinit();
    try h.expectRequest(2, .GET, base ++ "/retiredResources?pageToken=abc", null);
    try testing.expectEqualStrings("projects/my-project/locations/us-central1/keyRings/r/cryptoKeys/k", retired.value.retired_keys[0].original_name);
    // Retired keys take no filter; a page token or filter with control
    // characters is refused before sending.
    try testing.expectError(error.InvalidOptions, h.client.listRetiredKeys(.{ .filter = "a" }));
    try testing.expectError(error.InvalidName, h.client.listKeyRings(.{ .page_token = "a b" }));
    try testing.expectError(error.InvalidOptions, h.client.listKeyRings(.{ .filter = "a\nb" }));
    try h.expectRequestCount(3);
}

test "a delete's operation is polled until done, and one that failed is its status's error" {
    var h: Harness = undefined;
    const op = "projects/my-project/locations/us-central1/operations/op1";
    try h.init(&.{
        .{ .respond = .{ .body = "{\"name\":\"" ++ op ++ "\"}" } },
        .{ .respond = .{ .body = "{\"name\":\"" ++ op ++ "\",\"done\":false}" } },
        .{ .respond = .{ .body = "{\"name\":\"" ++ op ++ "\",\"done\":true}" } },
        .{ .respond = .{ .body = "{\"name\":\"" ++ op ++ "\",\"done\":true,\"error\":{\"code\":9,\"message\":\"the key ring is not empty\"}}" } },
    }, .{ .retry = .{ .max_attempts = 3, .initial_backoff_ms = 1, .max_backoff_ms = 2 } });
    defer h.deinit();
    try h.client.keyRing("r").key("k").delete();
    try h.expectRequest(1, .GET, "https://cloudkms.googleapis.com/v1/" ++ op, null);
    try h.expectRequest(2, .GET, "https://cloudkms.googleapis.com/v1/" ++ op, null);
    try testing.expectError(error.FailedPrecondition, h.client.keyRing("r").key("k").delete());
    try testing.expect(std.mem.indexOf(u8, h.diag.message(), "the key ring is not empty") != null);
    try h.expectRequestCount(4);
}

test "a delete that outlasts the attempts, or names an operation this client will not follow, says so" {
    var h: Harness = undefined;
    const pending = "{\"name\":\"projects/my-project/locations/us-central1/operations/op1\"}";
    try h.init(&.{
        .{ .respond = .{ .body = pending } },
        .{ .respond = .{ .body = pending } },
        .{ .respond = .{ .body = "{\"name\":\"https://evil.example/x\"}" } },
    }, .{ .retry = .{ .max_attempts = 1, .initial_backoff_ms = 1, .max_backoff_ms = 2 } });
    defer h.deinit();
    try testing.expectError(error.DeadlineExceeded, h.client.keyRing("r").key("k").delete());
    try testing.expect(std.mem.indexOf(u8, h.diag.message(), "still running as operation projects/my-project/locations/us-central1/operations/op1") != null);
    try testing.expectError(error.InvalidResponse, h.client.keyRing("r").key("k").delete());
    try h.expectRequestCount(3);
}

test "a delete whose operation cannot be read is InvalidResponse, and an error without a code is UNKNOWN" {
    var h: Harness = undefined;
    try h.init(&.{
        .{ .respond = .{ .body = "{\"done\":true}" } },
        .{ .respond = .{ .body = "{\"name\":\"projects/my-project/locations/us-central1/operations/o\",\"done\":true,\"error\":{\"code\":null}}" } },
    }, .{});
    defer h.deinit();
    try testing.expectError(error.InvalidResponse, h.client.keyRing("r").delete());
    try testing.expect(std.mem.indexOf(u8, h.diag.message(), "delete operation") != null);
    try testing.expectError(error.Unknown, h.client.keyRing("r").delete());
}

test "production's answers: a delete not done at first and done when read, a retired id refused" {
    const production = @import("production_bodies.zig");
    var h: Harness = undefined;
    try h.init(&.{
        .{ .respond = .{ .body = production.delete_key_started } },
        .{ .respond = .{ .body = production.delete_key_done } },
        .{ .respond = .{ .status = 400, .body = production.create_retired_key } },
    }, .{ .retry = .{ .max_attempts = 3, .initial_backoff_ms = 1, .max_backoff_ms = 2 } });
    defer h.deinit();
    try h.client.keyRing("zigps-kms").key("zigps-m0-fe7c50-bare").delete();
    try h.expectRequest(1, .GET, "https://cloudkms.googleapis.com/v1/projects/extractctl/locations/us-central1/operations/6f74f131-e1d9-404a-b8af-1b71cc214ada", null);
    try testing.expectError(error.AlreadyExists, h.client.keyRing("zigps-kms").key("zigps-m0-fe7c50-bare").create(.{ .purpose = .encrypt_decrypt }));
    try testing.expect(std.mem.indexOf(u8, h.diag.message(), "has already been deleted") != null);
}

test "a delete retried after a lost answer: NOT_FOUND then means the first one landed" {
    var h: Harness = undefined;
    const not_found = "{\"error\":{\"code\":404,\"status\":\"NOT_FOUND\"}}";
    try h.init(&.{
        .{ .fail = error.ConnectionResetByPeer },
        .{ .respond = .{ .status = 404, .body = not_found } },
        .{ .respond = .{ .status = 404, .body = not_found } },
    }, .{ .retry = .{ .max_attempts = 3, .initial_backoff_ms = 1, .max_backoff_ms = 2 } });
    defer h.deinit();
    try h.client.keyRing("r").key("k").delete();
    try testing.expectEqualStrings("", h.diag.message());
    // On the first attempt, it is the caller's.
    try testing.expectError(error.NotFound, h.client.keyRing("r").key("k").delete());
    try h.expectRequestCount(3);
}

test "golden: randomBytes asks an HSM for 8 to 1,024 bytes and checks them" {
    var h: Harness = undefined;
    const good = "{\"data\":\"MDEyMzQ1Njc4OWFiY2RlZg==\",\"dataCrc32c\":\"1121128862\"}";
    try h.init(&.{
        // 32 asked, 16 sent, twice.
        .{ .respond = .{ .body = good } },
        .{ .respond = .{ .body = good } },
        .{ .respond = .{ .body = good } },
        // A checksum that does not match, then a good answer.
        .{ .respond = .{ .body = "{\"data\":\"MDEyMzQ1Njc4OWFiY2RlZg==\",\"dataCrc32c\":\"9\"}" } },
        .{ .respond = .{ .body = good } },
        // 8 asked, 16 sent, twice.
        .{ .respond = .{ .body = good } },
        .{ .respond = .{ .body = good } },
    }, .{ .retry = .{ .max_attempts = 2, .initial_backoff_ms = 1, .max_backoff_ms = 2 } });
    defer h.deinit();
    // Fewer bytes than asked is refused as more is.
    try testing.expectError(error.IntegrityCheckFailed, h.client.randomBytes(32));
    var r = try h.client.randomBytes(16);
    defer r.deinit();
    try testing.expectEqualStrings("0123456789abcdef", r.value);
    try h.expectRequest(2, .POST, base ++ ":generateRandomBytes", "{\"lengthBytes\":16,\"protectionLevel\":\"HSM\"}");
    // A checksum that does not match is fetched again.
    var again = try h.client.randomBytes(16);
    again.deinit();
    // Another number of bytes than asked is refused.
    try testing.expectError(error.IntegrityCheckFailed, h.client.randomBytes(8));
    try testing.expect(std.mem.indexOf(u8, h.diag.message(), "another number of bytes") != null);
    try testing.expectError(error.InvalidOptions, h.client.randomBytes(7));
    try testing.expectError(error.TooLarge, h.client.randomBytes(1025));
    try h.expectRequestCount(7);
}
