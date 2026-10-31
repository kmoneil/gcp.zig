//! A Pub/Sub client: configuration, the HTTP connection pool, and the entry
//! point for `Topic` and `Subscription` handles.
//!
//! Every call blocks the calling task until it completes, using the `std.Io`
//! and allocator passed to `init`. A client must not be used from two tasks
//! at once; give each task its own. Time limits come from the caller: run a
//! call in `io.async` or `io.concurrent` and cancel it, and it returns
//! `error.Canceled`.

const Client = @This();

const std = @import("std");
const Allocator = std.mem.Allocator;

const Endpoint = @import("Endpoint.zig");
const Schema = @import("Schema.zig");
const Snapshot = @import("Snapshot.zig");
const Subscription = @import("Subscription.zig");
const Topic = @import("Topic.zig");
const codec = @import("codec.zig");
const errors = @import("errors.zig");
const rpc = @import("rpc.zig");
const types = @import("types.zig");
const url = @import("url.zig");
const validate = @import("validate.zig");
const Diagnostics = @import("core").Diagnostics;
const Error = errors.Error;
const HttpTransport = @import("core").transport.HttpTransport;
const RetryPolicy = @import("core").RetryPolicy;
const TokenProvider = @import("core").TokenProvider;
const Transport = @import("core").transport.Transport;

gpa: Allocator,
io: std.Io,
/// Owned copy of `Options.project_id`.
project_id: []const u8,
/// Owned. Scheme, host and port, such as `https://pubsub.googleapis.com`.
base_url: []const u8,
emulator: bool,
token_provider: ?TokenProvider,
retry: RetryPolicy,
retry_publish: bool,
send_quota_project: bool,
request_timeout_ms: u32,
diagnostics: ?*Diagnostics,
/// The delay the last failed attempt's response asked for, or null, as
/// the engine leaves it: this module's own retry loops wait by it.
server_delay_ms: ?u32 = null,
transport: Transport,
/// The built-in transport, when `Options.transport` was null.
http: ?*HttpTransport,
/// Owned copy of `Options.user_agent`.
user_agent: []const u8,

pub const Options = struct {
    /// Project id or number, such as `my-project`.
    project_id: []const u8,
    /// Null means production. `Endpoint.fromEnv(environ)` honors
    /// `PUBSUB_EMULATOR_HOST`.
    endpoint: ?Endpoint = null,
    /// Required, except for the emulator, which never receives credentials.
    token_provider: ?TokenProvider = null,
    retry: RetryPolicy = .{},
    /// A retried publish can store messages twice: after a 504, say, the
    /// server may already have them. Subscribers must tolerate duplicates
    /// anyway; set false to never retry a publish.
    retry_publish: bool = true,
    /// How long one request may take before it is `error.TimedOut`, which
    /// is retried like any other transient failure. Generous by default,
    /// because a pull with nothing to return is held open: about 20
    /// seconds in production and 90 by the emulator. 0 removes the limit,
    /// and nothing bounds a call then but the caller's own `std.Io`.
    request_timeout_ms: u32 = 180_000,
    /// Sends `x-goog-user-project` when the credentials name a project to
    /// charge for quota, as a user's own credentials do. Set false where
    /// the project owning the resources should pay instead.
    send_quota_project: bool = true,
    /// Printable ASCII.
    user_agent: []const u8 = "gcp-zig-pubsub/0.62",
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
    if (!validate.isProjectId(options.project_id)) {
        if (diag) |d| d.print("invalid project id: expected 1 to 100 letters, digits, '-', '.', ':' or '_'", .{});
        return error.InvalidResourceId;
    }
    if (!options.retry.isValid()) {
        if (diag) |d| d.print("invalid retry policy: max_attempts must be at least 1, multiplier finite and at least 1", .{});
        return error.InvalidOptions;
    }
    if (!isValidUserAgent(options.user_agent)) {
        if (diag) |d| d.print("invalid user agent: expected printable ASCII", .{});
        return error.InvalidOptions;
    }
    const endpoint = options.endpoint orelse Endpoint.production;
    if (!endpoint.emulator and options.token_provider == null) {
        if (diag) |d| d.print("this endpoint needs credentials: set token_provider, or use the emulator", .{});
        return error.MissingCredentials;
    }
    const base_url = endpoint.baseUrl(gpa) catch |err| {
        if (err == error.InvalidEndpoint) {
            if (diag) |d| d.print("invalid endpoint: expected http(s)://host[:port], or host:port for the emulator", .{});
        }
        return err;
    };
    errdefer gpa.free(base_url);
    // Everything but the emulator gets a bearer token, which must not travel
    // in cleartext.
    if (!endpoint.emulator and !std.mem.startsWith(u8, base_url, "https://")) {
        if (diag) |d| d.print("invalid endpoint: endpoints that receive credentials must use https", .{});
        return error.InvalidEndpoint;
    }
    const project_id = try gpa.dupe(u8, options.project_id);
    errdefer gpa.free(project_id);
    const user_agent = try gpa.dupe(u8, options.user_agent);
    errdefer gpa.free(user_agent);

    var http: ?*HttpTransport = null;
    const transport = options.transport orelse t: {
        const h = try gpa.create(HttpTransport);
        h.* = .init(gpa, io, user_agent);
        http = h;
        break :t h.transport();
    };
    return .{
        .gpa = gpa,
        .io = io,
        .project_id = project_id,
        .base_url = base_url,
        .emulator = endpoint.emulator,
        .token_provider = options.token_provider,
        .retry = options.retry,
        .retry_publish = options.retry_publish,
        .send_quota_project = options.send_quota_project,
        .request_timeout_ms = options.request_timeout_ms,
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
    self.gpa.free(self.project_id);
    self.gpa.free(self.base_url);
    self.* = undefined;
}

/// A handle for the topic `id`, such as "orders". Sends nothing. The handle
/// borrows the client and `id`, and must not outlive either.
pub fn topic(self: *Client, id: []const u8) Topic {
    return .{ .client = self, .id = id };
}

/// A handle for the subscription `id`. Sends nothing. The handle borrows the
/// client and `id`, and must not outlive either.
pub fn subscription(self: *Client, id: []const u8) Subscription {
    return .{ .client = self, .id = id };
}

/// A handle for the snapshot `id`, such as "before-deploy". Sends nothing.
/// The handle borrows the client and `id`, and must not outlive either.
pub fn snapshot(self: *Client, id: []const u8) Snapshot {
    return .{ .client = self, .id = id };
}

/// A handle for the schema `id`, such as "order-v1". Sends nothing. The
/// handle borrows the client and `id`, and must not outlive either.
pub fn schema(self: *Client, id: []const u8) Schema {
    return .{ .client = self, .id = id };
}

/// One page of the project's topics.
pub fn listTopics(self: *Client, page: types.PageOptions) Error!types.Owned(types.TopicPage) {
    rpc.begin(self);
    var scratch: std.heap.ArenaAllocator = .init(self.gpa);
    defer scratch.deinit();
    const path = try url.listPath(scratch.allocator(), self.project_id, .topics, page.page_size, page.page_token);
    var result: types.Owned(types.TopicPage) = try .init(self.gpa);
    errdefer result.deinit();
    const body = try rpc.execute(self, result.arena, .{ .method = .GET, .path = path });
    result.value = codec.decodeTopicPage(result.arena.allocator(), body) catch |err|
        return rpc.decodeFailed(self, err, "topic list");
    return result;
}

/// One page of the project's subscriptions.
pub fn listSubscriptions(self: *Client, page: types.PageOptions) Error!types.Owned(types.SubscriptionPage) {
    rpc.begin(self);
    var scratch: std.heap.ArenaAllocator = .init(self.gpa);
    defer scratch.deinit();
    const path = try url.listPath(scratch.allocator(), self.project_id, .subscriptions, page.page_size, page.page_token);
    var result: types.Owned(types.SubscriptionPage) = try .init(self.gpa);
    errdefer result.deinit();
    const body = try rpc.execute(self, result.arena, .{ .method = .GET, .path = path });
    result.value = codec.decodeSubscriptionPage(result.arena.allocator(), body) catch |err|
        return rpc.decodeFailed(self, err, "subscription list");
    return result;
}

/// One page of the project's snapshots, each as `Snapshot.get` reads it.
/// Needs `pubsub.snapshots.list`.
pub fn listSnapshots(self: *Client, page: types.PageOptions) Error!types.Owned(types.SnapshotPage) {
    rpc.begin(self);
    var scratch: std.heap.ArenaAllocator = .init(self.gpa);
    defer scratch.deinit();
    const path = try url.listPath(scratch.allocator(), self.project_id, .snapshots, page.page_size, page.page_token);
    var result: types.Owned(types.SnapshotPage) = try .init(self.gpa);
    errdefer result.deinit();
    const body = try rpc.execute(self, result.arena, .{ .method = .GET, .path = path });
    result.value = codec.decodeSnapshotPage(result.arena.allocator(), body) catch |err|
        return rpc.decodeFailed(self, err, "snapshot list");
    return result;
}

/// One page of the project's schemas, the latest revision of each, without
/// their definitions unless `options.view` is `.full`. Needs
/// `pubsub.schemas.list`.
pub fn listSchemas(self: *Client, options: types.SchemaListOptions) Error!types.Owned(types.SchemaPage) {
    rpc.begin(self);
    var scratch: std.heap.ArenaAllocator = .init(self.gpa);
    defer scratch.deinit();
    const path = try url.schemaListPath(
        scratch.allocator(),
        self.project_id,
        codec.schemaViewName(options.view),
        options.page.page_size,
        options.page.page_token,
    );
    var result: types.Owned(types.SchemaPage) = try .init(self.gpa);
    errdefer result.deinit();
    const body = try rpc.execute(self, result.arena, .{ .method = .GET, .path = path });
    result.value = codec.decodeSchemaPage(result.arena.allocator(), body) catch |err|
        return rpc.decodeFailed(self, err, "schema list");
    return result;
}

/// Asks Pub/Sub whether `definition` is a schema it would store: whether
/// it parses as its type. Nothing is stored. One that does not parse is
/// `error.InvalidArgument` in the server's words. This does not say
/// whether it could become a revision of a schema that is there: only a
/// commit checks one revision against the others. Needs
/// `pubsub.schemas.validate`.
pub fn validateSchema(self: *Client, definition: types.SchemaDefinition) Error!void {
    rpc.begin(self);
    try validate.schemaDefinition(definition, self.diagnostics);
    var scratch: std.heap.ArenaAllocator = .init(self.gpa);
    defer scratch.deinit();
    const a = scratch.allocator();
    const path = try url.schemasMethodPath(a, self.project_id, ":validate");
    const body = try codec.encodeValidateSchema(a, definition);
    return rpc.executeDiscard(self, .{ .method = .POST, .path = path, .body = body });
}

/// Asks Pub/Sub whether `data`, read in `encoding`, fits `definition`, a
/// schema that need not be stored; `Schema.validateMessage` asks it of one
/// that is. Nothing is stored or published. A message that does not fit,
/// and a definition that does not parse, are `error.InvalidArgument` in
/// the server's words. Needs `pubsub.schemas.validate`.
pub fn validateMessage(
    self: *Client,
    definition: types.SchemaDefinition,
    data: []const u8,
    encoding: types.SchemaEncoding,
) Error!void {
    rpc.begin(self);
    try validate.schemaDefinition(definition, self.diagnostics);
    try validate.schemaEncoding(encoding, self.diagnostics);
    var scratch: std.heap.ArenaAllocator = .init(self.gpa);
    defer scratch.deinit();
    const a = scratch.allocator();
    const path = try url.schemasMethodPath(a, self.project_id, ":validateMessage");
    const body = try codec.encodeValidateMessage(a, .{ .definition = definition }, data, encoding);
    return rpc.executeDiscard(self, .{ .method = .POST, .path = path, .body = body });
}

fn isValidUserAgent(user_agent: []const u8) bool {
    if (user_agent.len == 0) return false;
    for (user_agent) |c| if (c < ' ' or c >= 0x7f) return false;
    return true;
}

const testing = std.testing;
const test_util = @import("test_util.zig");
const StaticToken = @import("core").StaticToken;

const local_emulator: Endpoint = .{ .url = "localhost:8085", .emulator = true };

test "init rejects bad options before allocating" {
    const gpa = testing.failing_allocator;
    const io = testing.io;
    var diag: Diagnostics = .{};
    try testing.expectError(error.MissingCredentials, Client.init(gpa, io, .{ .project_id = "p", .diagnostics = &diag }));
    try testing.expect(std.mem.indexOf(u8, diag.message(), "needs credentials") != null);
    try testing.expectError(error.InvalidResourceId, Client.init(gpa, io, .{ .project_id = "", .endpoint = local_emulator }));
    try testing.expectError(error.InvalidResourceId, Client.init(gpa, io, .{ .project_id = "a/b", .endpoint = local_emulator }));
    try testing.expectError(error.InvalidOptions, Client.init(gpa, io, .{ .project_id = "p", .endpoint = local_emulator, .retry = .{ .max_attempts = 0 } }));
    try testing.expectError(error.InvalidOptions, Client.init(gpa, io, .{ .project_id = "p", .endpoint = local_emulator, .retry = .{ .multiplier = 0.5 } }));
    try testing.expectError(error.InvalidOptions, Client.init(gpa, io, .{ .project_id = "p", .endpoint = local_emulator, .user_agent = "" }));
    try testing.expectError(error.InvalidOptions, Client.init(gpa, io, .{ .project_id = "p", .endpoint = local_emulator, .user_agent = "ua\r\nX: y" }));
}

test "init reports a bad endpoint" {
    var diag: Diagnostics = .{};
    try testing.expectError(error.InvalidEndpoint, Client.init(testing.allocator, testing.io, .{
        .project_id = "p",
        .endpoint = .{ .url = "ftp://host", .emulator = true },
        .diagnostics = &diag,
    }));
    try testing.expect(std.mem.indexOf(u8, diag.message(), "invalid endpoint") != null);
}

test "init and deinit with the built-in transport" {
    var client: Client = try .init(testing.allocator, testing.io, .{ .project_id = "p", .endpoint = local_emulator });
    defer client.deinit();
    try testing.expectEqualStrings("http://localhost:8085", client.base_url);
    try testing.expect(client.http != null);
    try testing.expect(client.emulator);
}

test "credentials never go to a plain-http endpoint" {
    var static: StaticToken = .{ .token = "t" };
    var diag: Diagnostics = .{};
    try testing.expectError(error.InvalidEndpoint, Client.init(testing.allocator, testing.io, .{
        .project_id = "p",
        .endpoint = .{ .url = "http://proxy.internal:8080" },
        .token_provider = static.provider(),
        .diagnostics = &diag,
    }));
    try testing.expect(std.mem.indexOf(u8, diag.message(), "must use https") != null);
}

test "production needs a token provider and uses https" {
    var static: StaticToken = .{ .token = "t" };
    var client: Client = try .init(testing.allocator, testing.io, .{ .project_id = "p", .token_provider = static.provider() });
    defer client.deinit();
    try testing.expectEqualStrings("https://pubsub.googleapis.com", client.base_url);
    try testing.expect(!client.emulator);
}

test "init copies the strings it keeps" {
    var project = "project-1".*;
    var agent = "agent/1".*;
    var host = "localhost:9999".*;
    var client: Client = try .init(testing.allocator, testing.io, .{
        .project_id = &project,
        .user_agent = &agent,
        .endpoint = .{ .url = &host, .emulator = true },
    });
    defer client.deinit();
    @memset(&project, 'x');
    @memset(&agent, 'x');
    @memset(&host, 'x');
    try testing.expectEqualStrings("project-1", client.project_id);
    try testing.expectEqualStrings("agent/1", client.user_agent);
    try testing.expectEqualStrings("http://localhost:9999", client.base_url);
}

test "init: every allocation failure is OutOfMemory without leaks" {
    const Run = struct {
        fn run(gpa: Allocator) !void {
            var client: Client = try .init(gpa, testing.io, .{ .project_id = "p", .endpoint = local_emulator });
            client.deinit();
        }
    };
    try testing.checkAllAllocationFailures(test_util.no_grow_allocator, Run.run, .{});
}

test "every public call: every allocation failure is OutOfMemory without leaks" {
    const Reply = test_util.FakeTransport.Reply;
    const topic_body = "{\"name\":\"projects/p/topics/orders\"}";
    const sub_body = "{\"name\":\"projects/p/subscriptions/orders-worker\",\"topic\":\"projects/p/topics/orders\",\"ackDeadlineSeconds\":10}";
    const snap_body = "{\"name\":\"projects/p/snapshots/before\",\"topic\":\"projects/p/topics/orders\",\"expireTime\":\"2026-10-17T13:46:36.836Z\",\"labels\":{\"k\":\"v\"}}";
    const ok: Reply = .{ .respond = .{ .body = "{}" } };
    // One reply per request, in the order the calls below make them.
    const script = [_]Reply{
        .{ .respond = .{ .status = 503, .body = "{\"error\":{\"status\":\"UNAVAILABLE\"}}" } },
        .{ .respond = .{ .body = topic_body } },
        .{ .respond = .{ .body = topic_body } },
        .{ .respond = .{ .body = "{\"messageIds\":[\"1\"]}" } },
        .{ .respond = .{ .body = "{\"topics\":[" ++ topic_body ++ "],\"nextPageToken\":\"n\"}" } },
        .{ .respond = .{ .body = sub_body } },
        .{ .respond = .{ .body = sub_body } },
        .{ .respond = .{ .body = "{\"subscriptions\":[" ++ sub_body ++ "]}" } },
        .{ .respond = .{ .body = "{\"receivedMessages\":[{\"ackId\":\"a1\",\"message\":{\"data\":\"aGk=\",\"attributes\":{\"k\":\"v\"},\"messageId\":\"1\",\"publishTime\":\"2026-09-19T00:00:00Z\",\"orderingKey\":\"o\"},\"deliveryAttempt\":1}]}" } },
        ok, ok, // ack takes two requests
        ok,                                                                                                                      ok, // modifyAckDeadline, nack
        .{ .respond = .{ .body = snap_body } },                                                                                  .{ .respond = .{ .body = snap_body } },
        .{ .respond = .{ .body = snap_body } },                                                                                  .{ .respond = .{ .body = "{\"snapshots\":[" ++ snap_body ++ "],\"nextPageToken\":\"n\"}" } },
        .{ .respond = .{ .body = "{\"subscriptions\":[\"projects/p/subscriptions/orders-worker\"],\"nextPageToken\":\"n\"}" } }, .{ .respond = .{ .body = "{\"snapshots\":[\"projects/p/snapshots/before\"]}" } },
        ok, ok, ok, // the three deletes
    };
    const Run = struct {
        /// One more id than a request may carry.
        const many_ids: [validate.max_ack_ids_per_request + 1][]const u8 = @splat("a1");

        fn all(gpa: Allocator, replies: []const Reply) !void {
            var fake: test_util.FakeTransport = .init(testing.allocator, replies);
            defer fake.deinit();
            var clock: test_util.FakeClock = .{};
            var token: StaticToken = .{ .token = "ya29.token" };
            var client: Client = try .init(gpa, clock.io(), .{
                .project_id = "p",
                .token_provider = token.provider(),
                .transport = fake.transport(),
            });
            defer client.deinit();

            const t = client.topic("orders");
            var created = try t.create(.{}); // after one retry
            created.deinit();
            var got = try t.get();
            got.deinit();
            var sent = try t.publish(&.{.{ .data = "hi", .attributes = &.{.{ .key = "k", .value = "v" }} }}, .{ .ordering_key = "o" });
            sent.deinit();
            var topics = try client.listTopics(.{ .page_size = 1 });
            topics.deinit();

            const s = client.subscription("orders-worker");
            var sub = try s.create(.{ .topic_id = "orders" });
            sub.deinit();
            var sub_got = try s.get();
            sub_got.deinit();
            var subs = try client.listSubscriptions(.{ .page_token = "n" });
            subs.deinit();
            var batch = try s.pull(.{ .max_messages = 10 });
            batch.deinit();
            try s.ack(&many_ids);
            try s.modifyAckDeadline(&.{"a1"}, 30);
            try s.nack(&.{"a1"});

            const snap = client.snapshot("before");
            var kept = try snap.create(.{ .subscription = "orders-worker", .labels = &.{.{ .key = "k", .value = "v" }} });
            kept.deinit();
            var kept_got = try snap.get();
            kept_got.deinit();
            var relabelled = try snap.update(.{ .labels = &.{.{ .key = "k", .value = "w" }} });
            relabelled.deinit();
            var snaps = try client.listSnapshots(.{ .page_size = 1 });
            snaps.deinit();
            var attached = try t.listSubscriptions(.{});
            attached.deinit();
            var kept_of = try t.listSnapshots(.{ .page_token = "n" });
            kept_of.deinit();
            try snap.delete();
            try s.delete();
            try t.delete();
            // The calls above used the whole script, so none was skipped.
            try testing.expectEqual(replies.len, fake.requests.items.len);
        }
    };
    try testing.checkAllAllocationFailures(test_util.no_grow_allocator, Run.all, .{@as([]const Reply, &script)});
}

test "golden: listTopics and listSubscriptions pass page options" {
    var h: test_util.Harness = undefined;
    try h.init(&.{
        .{ .respond = .{ .body =
        \\{"topics":[{"name":"projects/p/topics/page-1"},{"name":"projects/p/topics/page-2"}],
        \\"nextPageToken":"projects/p/topics/page-3"}
        } },
        .{ .respond = .{ .body = "{\"topics\":[{\"name\":\"projects/p/topics/page-3\"}]}" } },
        .{ .respond = .{ .body = "{\"subscriptions\":[{\"name\":\"projects/p/subscriptions/s\",\"topic\":\"projects/p/topics/t\",\"ackDeadlineSeconds\":10}]}" } },
        .{ .respond = .{ .body = "{}" } },
    }, .{});
    defer h.deinit();

    var first = try h.client.listTopics(.{ .page_size = 2 });
    defer first.deinit();
    try h.expectRequest(0, .GET, "http://localhost:8085/v1/projects/p/topics?pageSize=2", null);
    try testing.expectEqual(2, first.value.topics.len);
    try testing.expectEqualStrings("projects/p/topics/page-3", first.value.next_page_token.?);

    var second = try h.client.listTopics(.{ .page_size = 2, .page_token = first.value.next_page_token });
    defer second.deinit();
    try h.expectRequest(1, .GET, "http://localhost:8085/v1/projects/p/topics?pageSize=2&pageToken=projects%2Fp%2Ftopics%2Fpage-3", null);
    try testing.expectEqual(null, second.value.next_page_token);

    var subs = try h.client.listSubscriptions(.{});
    defer subs.deinit();
    try h.expectRequest(2, .GET, "http://localhost:8085/v1/projects/p/subscriptions?pageSize=100", null);
    try testing.expectEqual(10, subs.value.subscriptions[0].ack_deadline_seconds);

    // An empty project lists as `{}`.
    var none = try h.client.listSubscriptions(.{ .page_size = 0 });
    defer none.deinit();
    try h.expectRequest(3, .GET, "http://localhost:8085/v1/projects/p/subscriptions", null);
    try testing.expectEqual(0, none.value.subscriptions.len);
}

test "domain-scoped project ids keep their colon in paths and bodies" {
    var h: test_util.Harness = undefined;
    try h.init(&.{.{ .respond = .{ .body = "{}" } }}, .{ .project_id = "example.com:proj" });
    defer h.deinit();
    var created = try h.client.subscription("work").create(.{ .topic_id = "orders" });
    defer created.deinit();
    try h.expectRequest(
        0,
        .PUT,
        "http://localhost:8085/v1/projects/example.com:proj/subscriptions/work",
        "{\"topic\":\"projects/example.com:proj/topics/orders\",\"enableMessageOrdering\":false}",
    );
}

test "golden: listSnapshots passes page options, and reads whole snapshots" {
    var h: test_util.Harness = undefined;
    try h.init(&.{
        .{ .respond = .{ .body =
        \\{"snapshots":[{"name":"projects/p/snapshots/a","topic":"projects/p/topics/t","expireTime":"2026-10-17T13:46:36.836Z","labels":{"k":"v"}}],
        \\"nextPageToken":"next"}
        } },
        .{ .respond = .{ .body = "{}" } },
        .{ .respond = .{ .body = "{\"snapshots\":[{\"name\":\"projects/p/snapshots/a\"}]}" } },
    }, .{});
    defer h.deinit();

    var first = try h.client.listSnapshots(.{ .page_size = 1 });
    defer first.deinit();
    try h.expectRequest(0, .GET, "http://localhost:8085/v1/projects/p/snapshots?pageSize=1", null);
    try testing.expectEqual(1, first.value.snapshots.len);
    try testing.expectEqualStrings("projects/p/topics/t", first.value.snapshots[0].topic);
    try testing.expectEqualStrings("v", first.value.snapshots[0].label("k").?);
    try testing.expectEqualStrings("next", first.value.next_page_token.?);

    // A project with none lists as `{}`.
    var none = try h.client.listSnapshots(.{ .page_token = first.value.next_page_token });
    defer none.deinit();
    try h.expectRequest(1, .GET, "http://localhost:8085/v1/projects/p/snapshots?pageSize=100&pageToken=next", null);
    try testing.expectEqual(0, none.value.snapshots.len);
    try testing.expectEqual(null, none.value.next_page_token);

    try testing.expectError(error.InvalidResponse, h.client.listSnapshots(.{}));
    try testing.expectEqualStrings("the snapshot list response could not be decoded", h.diag.message());
}

test "golden: listSchemas says its view and passes page options, and the two validations name no stored schema" {
    var h: test_util.Harness = undefined;
    try h.init(&.{
        .{ .respond = .{ .body =
        \\{"schemas":[{"name":"projects/p/schemas/a","type":"AVRO","revisionId":"1b46a16a","revisionCreateTime":"2026-10-11T23:15:46.447Z"}],
        \\"nextPageToken":"next"}
        } },
        .{ .respond = .{ .body = "{}" } },
        .{ .respond = .{ .body = "{\"schemas\":[{\"type\":\"AVRO\"}]}" } },
        .{ .respond = .{ .body = "{}" } },
        .{ .respond = .{ .body = "{}" } },
        // The emulator's words for a message that does not fit, 2026-10-11.
        .{ .respond = .{ .status = 400, .body = "{\"error\":{\"code\":400,\"message\":\"Could not parse binary Avro message\",\"status\":\"INVALID_ARGUMENT\"}}" } },
    }, .{});
    defer h.deinit();
    const base = "http://localhost:8085/v1/projects/p/schemas";

    var first = try h.client.listSchemas(.{ .page = .{ .page_size = 1 } });
    defer first.deinit();
    try h.expectRequest(0, .GET, base ++ "?view=BASIC&pageSize=1", null);
    try testing.expectEqual(1, first.value.schemas.len);
    try testing.expectEqualStrings("projects/p/schemas/a", first.value.schemas[0].name);
    try testing.expectEqualStrings("", first.value.schemas[0].definition);
    try testing.expectEqualStrings("1b46a16a", first.value.schemas[0].revision_id);
    try testing.expectEqualStrings("next", first.value.next_page_token.?);

    // A project with none lists as `{}`.
    var none = try h.client.listSchemas(.{ .view = .full, .page = .{ .page_token = first.value.next_page_token } });
    defer none.deinit();
    try h.expectRequest(1, .GET, base ++ "?view=FULL&pageSize=100&pageToken=next", null);
    try testing.expectEqual(0, none.value.schemas.len);
    try testing.expectEqual(null, none.value.next_page_token);

    try testing.expectError(error.InvalidResponse, h.client.listSchemas(.{}));
    try testing.expectEqualStrings("the schema list response could not be decoded", h.diag.message());

    const avro: types.SchemaDefinition = .{ .type = .avro, .definition = "\"string\"" };
    try h.client.validateSchema(avro);
    try h.expectRequest(3, .POST, base ++ ":validate",
        \\{"schema":{"type":"AVRO","definition":"\"string\""}}
    );
    try h.client.validateMessage(avro, "\"a\"", .json);
    try h.expectRequest(4, .POST, base ++ ":validateMessage",
        \\{"schema":{"type":"AVRO","definition":"\"string\""},"message":"ImEi","encoding":"JSON"}
    );
    try testing.expectError(error.InvalidArgument, h.client.validateMessage(avro, "\xff", .binary));
    try testing.expectEqualStrings("Could not parse binary Avro message", h.diag.message());
    try h.expectRequestCount(6);

    // What the checks refuse is never sent.
    try testing.expectError(error.InvalidArgument, h.client.validateSchema(.{ .type = .avro, .definition = "" }));
    try testing.expectError(error.InvalidArgument, h.client.validateMessage(.{ .type = .unknown, .definition = "{}" }, "x", .json));
    try testing.expectError(error.InvalidArgument, h.client.validateMessage(avro, "x", .unknown));
    try h.expectRequestCount(6);
}
