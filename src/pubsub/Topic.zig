//! A topic handle: a client pointer and a short id such as "orders". Making
//! one sends nothing. It borrows both, so it must not outlive the client or
//! the memory behind `id`.

const Topic = @This();

const std = @import("std");

const Client = @import("Client.zig");
const codec = @import("codec.zig");
const iam = @import("iam.zig");
const rpc = @import("rpc.zig");
const types = @import("types.zig");
const url = @import("url.zig");
const validate = @import("validate.zig");
const Error = @import("errors.zig").Error;
const Owned = types.Owned;

client: *Client,
/// The client builds the full name, `projects/{project}/topics/{id}`.
id: []const u8,

/// Creates the topic. If a lost first attempt already created it, the retry
/// reports `error.AlreadyExists`. Every setting is checked first.
///
/// With `config.schema`, the topic takes only messages that fit the
/// schema, and a publish of one that does not is `error.InvalidArgument`.
/// A schema or a revision that is not there is `error.NotFound`, and
/// naming a schema needs `pubsub.schemas.attach` on it.
pub fn create(self: Topic, config: types.TopicConfig) Error!Owned(types.TopicInfo) {
    const c = self.client;
    rpc.begin(c);
    try rpc.checkId(c, "topic", self.id);
    try validate.topicConfig(config, c.diagnostics);
    var scratch: std.heap.ArenaAllocator = .init(c.gpa);
    defer scratch.deinit();
    const a = scratch.allocator();
    const path = try url.resourcePath(a, c.project_id, .topics, self.id, "");
    var full = config;
    if (config.schema) |settings| full.schema = try schemaInFull(a, c.project_id, settings);
    const body = try codec.encodeTopic(a, full);
    return fetch(c, .{ .method = .PUT, .path = path, .body = body });
}

/// Changes what `changes` names, and nothing else, and returns the topic as
/// it is then. A storage policy is replaced whole, and labels as a set.
///
/// A schema's settings are replaced whole too: the encoding and the
/// revisions are then what `changes.schema` gives, and `.clear` leaves the
/// topic taking any bytes. Google says a change to them can take a few
/// minutes to hold.
pub fn update(self: Topic, changes: types.TopicUpdate) Error!Owned(types.TopicInfo) {
    const c = self.client;
    rpc.begin(c);
    try rpc.checkId(c, "topic", self.id);
    try validate.topicUpdate(changes, c.diagnostics);
    var scratch: std.heap.ArenaAllocator = .init(c.gpa);
    defer scratch.deinit();
    const a = scratch.allocator();
    const path = try url.resourcePath(a, c.project_id, .topics, self.id, "");
    var full = changes;
    switch (changes.schema) {
        .set => |settings| full.schema = .{ .set = try schemaInFull(a, c.project_id, settings) },
        else => {},
    }
    const body = try codec.encodeTopicUpdate(a, full);
    return fetch(c, .{ .method = .PATCH, .path = path, .body = body });
}

/// The settings with their schema named in full: as given, or an id in the
/// client's project.
fn schemaInFull(arena: std.mem.Allocator, project: []const u8, settings: types.SchemaSettings) std.mem.Allocator.Error!types.SchemaSettings {
    if (validate.isSchemaName(settings.schema)) return settings;
    var full = settings;
    full.schema = try url.resourceName(arena, project, .schemas, settings.schema);
    return full;
}

pub fn get(self: Topic) Error!Owned(types.TopicInfo) {
    const c = self.client;
    rpc.begin(c);
    try rpc.checkId(c, "topic", self.id);
    var scratch: std.heap.ArenaAllocator = .init(c.gpa);
    defer scratch.deinit();
    const path = try url.resourcePath(scratch.allocator(), c.project_id, .topics, self.id, "");
    return fetch(c, .{ .method = .GET, .path = path });
}

/// Deletes the topic. Its subscriptions stay, detached. If a lost first
/// attempt already deleted it, the retry reports `error.NotFound`.
pub fn delete(self: Topic) Error!void {
    const c = self.client;
    rpc.begin(c);
    try rpc.checkId(c, "topic", self.id);
    var scratch: std.heap.ArenaAllocator = .init(c.gpa);
    defer scratch.deinit();
    const path = try url.resourcePath(scratch.allocator(), c.project_id, .topics, self.id, "");
    return rpc.executeDiscard(c, .{ .method = .DELETE, .path = path });
}

/// The topic's IAM policy, asked for as version 3. A fresh topic's is
/// empty, with the etag "ACAB". Needs `pubsub.topics.getIamPolicy`. The
/// emulator answers every IAM call `error.Unimplemented`.
pub fn iamPolicy(self: Topic) Error!Owned(core.iam.Policy) {
    const r = try self.iamResource();
    return r.readPolicy();
}

/// Writes `policy` as the topic's, whole, and returns it as stored. Pass a
/// policy `iamPolicy` read, changed: its etag makes the write fail with
/// `error.Aborted` if the policy changed since, rather than undo that
/// change. A write that carries an etag is retried; one whose first answer
/// was lost then reports `error.Aborted` although it landed, so read the
/// policy again. One without an etag is sent once. Pub/Sub takes no
/// conditional bindings: one is `error.InvalidArgument`, before sending.
/// Needs `pubsub.topics.setIamPolicy`.
pub fn setIamPolicy(self: Topic, policy: core.iam.Policy) Error!Owned(core.iam.Policy) {
    const r = try self.iamResource();
    return iam.set(r, policy);
}

/// Grants `member` the role `role` on the topic, unless it holds it
/// already without a condition, and returns the policy as it then is. It
/// reads the policy, adds the member, and writes it back under the read's
/// etag, starting over after a jittered wait when another change came in
/// between, up to the retry policy's attempts. Members compare as Pub/Sub
/// stores them, the address of a `user:`, `serviceAccount:`, `group:` or
/// `domain:` member in any case. A bucket's notifications need it: `role`
/// is `roles/pubsub.publisher`, and `member` is `serviceAccount:` and the
/// address `storage.Client.serviceAgent` gives. A fresh grant took a few
/// seconds to apply when measured. Needs `pubsub.topics.getIamPolicy` and
/// `pubsub.topics.setIamPolicy`.
pub fn addIamBinding(self: Topic, role: []const u8, member: []const u8) Error!Owned(core.iam.Policy) {
    const r = try self.iamResource();
    return iam.change(r, .{ .grant = .{ .role = role, .member = member } });
}

/// Takes `member` out of the topic's binding of `role` without a
/// condition, unless it is not there, and returns the policy as it then
/// is, the same way `addIamBinding` grants.
pub fn removeIamBinding(self: Topic, role: []const u8, member: []const u8) Error!Owned(core.iam.Policy) {
    const r = try self.iamResource();
    return iam.change(r, .{ .revoke = .{ .role = role, .member = member } });
}

/// The permissions the caller holds on the topic, of `permissions`: 1 to
/// 100 of Pub/Sub's own, such as `pubsub.topics.publish`. A permission of
/// another service, or one that does not exist, is refused with
/// `error.InvalidArgument`; a missing topic is `error.NotFound`. Meant for
/// building permission-aware tools, not for authorization checks: Google
/// says it may "fail open".
pub fn testIamPermissions(self: Topic, permissions: []const []const u8) Error!Owned([]const []const u8) {
    const r = try self.iamResource();
    return iam.testPermissions(r, permissions);
}

fn iamResource(self: Topic) Error!iam.Resource {
    const c = self.client;
    rpc.begin(c);
    try rpc.checkId(c, "topic", self.id);
    return .{ .client = c, .collection = .topics, .id = self.id };
}

/// Publishes `messages` in one HTTP request. The returned ids match the order
/// of `messages`. Limits are checked first (`error.InvalidMessage`), on the
/// request as it is before any compression.
/// A retried publish can store messages twice; see `Client.Options.retry_publish`.
pub fn publish(
    self: Topic,
    messages: []const types.Message,
    options: types.PublishOptions,
) Error!Owned(types.PublishResult) {
    const c = self.client;
    rpc.begin(c);
    var scratch: std.heap.ArenaAllocator = .init(c.gpa);
    defer scratch.deinit();
    const built = try self.buildPublish(scratch.allocator(), messages, options);
    // Compressed once: a retry sends the same bytes. Apart from the arena,
    // so the compressor's memory is back before the request goes.
    const compressed = try rpc.compressBody(c.gpa, built.body, options.compression);
    defer if (compressed) |bytes| c.gpa.free(bytes);

    var result: Owned(types.PublishResult) = try .init(c.gpa);
    errdefer result.deinit();
    const response = try rpc.execute(c, result.arena, .{
        .method = .POST,
        .path = built.path,
        .body = compressed orelse built.body,
        .headers = if (compressed != null) rpc.gzip_headers else &.{},
        .retry = c.retry_publish,
        .retryable = rpc.isPublishRetryable,
    });
    result.value = codec.decodePublish(result.arena.allocator(), response, messages.len) catch |err|
        return rpc.decodeFailed(c, err, "publish");
    return result;
}

/// The request `publish` sends for the same `messages` and `options`, built
/// without sending it: to show before the call, or to record after it.
/// `publish` builds its request the same way, so the URL and the body are
/// byte for byte what it sends, the body before any compression (see
/// `PublishRequest.gzip`). The same checks run first and fail with the
/// same errors, so a request built here is one `publish` will send.
/// Credentials and other headers are not part of it.
pub fn publishRequest(
    self: Topic,
    messages: []const types.Message,
    options: types.PublishOptions,
) Error!Owned(types.PublishRequest) {
    const c = self.client;
    rpc.begin(c);
    var result: Owned(types.PublishRequest) = try .init(c.gpa);
    errdefer result.deinit();
    const a = result.arena.allocator();
    const built = try self.buildPublish(a, messages, options);
    result.value = .{
        .method = .POST,
        .url = try std.mem.concat(a, u8, &.{ c.base_url, built.path }),
        .body = built.body,
        .gzip = rpc.compresses(built.body.len, options.compression),
    };
    return result;
}

const BuiltPublish = struct { path: []const u8, body: []const u8 };

/// A publish's checks, then its path and body: what `publish` sends and
/// `publishRequest` shows.
fn buildPublish(
    self: Topic,
    arena: std.mem.Allocator,
    messages: []const types.Message,
    options: types.PublishOptions,
) Error!BuiltPublish {
    const c = self.client;
    try rpc.checkId(c, "topic", self.id);
    try validate.publish(messages, options.ordering_key, c.diagnostics);
    if (options.compression) |compression| try validate.compression(compression, c.diagnostics);
    return .{
        .path = try url.resourcePath(arena, c.project_id, .topics, self.id, ":publish"),
        .body = try codec.encodePublish(arena, messages, options.ordering_key),
    };
}

/// One page of the subscriptions attached to the topic, each by its full
/// name. A detached subscription is not among them, and one that is may
/// lie in another project.
pub fn listSubscriptions(self: Topic, page: types.PageOptions) Error!Owned(types.NamePage) {
    return self.attached(.subscriptions, page);
}

/// One page of the snapshots kept of the topic, each by its full name:
/// `Snapshot.get` reads one. A deleted topic has no list, though its
/// snapshots outlive it.
pub fn listSnapshots(self: Topic, page: types.PageOptions) Error!Owned(types.NamePage) {
    return self.attached(.snapshots, page);
}

fn attached(self: Topic, list: codec.NameList, page: types.PageOptions) Error!Owned(types.NamePage) {
    const c = self.client;
    rpc.begin(c);
    try rpc.checkId(c, "topic", self.id);
    var scratch: std.heap.ArenaAllocator = .init(c.gpa);
    defer scratch.deinit();
    const kind: url.Collection = switch (list) {
        .subscriptions => .subscriptions,
        .snapshots => .snapshots,
    };
    const path = try url.attachedPath(scratch.allocator(), c.project_id, self.id, kind, page.page_size, page.page_token);
    var result: Owned(types.NamePage) = try .init(c.gpa);
    errdefer result.deinit();
    const body = try rpc.execute(c, result.arena, .{ .method = .GET, .path = path });
    result.value = codec.decodeNamePage(result.arena.allocator(), body, list) catch |err|
        return rpc.decodeFailed(c, err, "name list");
    return result;
}

fn fetch(c: *Client, call: rpc.Call) Error!Owned(types.TopicInfo) {
    var result: Owned(types.TopicInfo) = try .init(c.gpa);
    errdefer result.deinit();
    const body = try rpc.execute(c, result.arena, call);
    result.value = codec.decodeTopic(result.arena.allocator(), body) catch |err|
        return rpc.decodeFailed(c, err, "topic");
    return result;
}

const testing = std.testing;
const test_util = @import("test_util.zig");
const Harness = test_util.Harness;

test "golden: create, get, delete and publish send the right requests" {
    var h: Harness = undefined;
    try h.init(&.{
        .{ .respond = .{ .body = "{\n  \"name\": \"projects/p/topics/orders\"\n}\n" } },
        .{ .respond = .{ .body = "{\"name\":\"projects/p/topics/orders\"}" } },
        .{ .respond = .{ .body = "{\n}\n" } },
        .{ .respond = .{ .body = "{\n  \"messageIds\": [\"11\", \"12\"]\n}\n" } },
    }, .{});
    defer h.deinit();
    const orders = h.client.topic("orders");

    var created = try orders.create(.{});
    defer created.deinit();
    try testing.expectEqualStrings("projects/p/topics/orders", created.value.name);
    try h.expectRequest(0, .PUT, "http://localhost:8085/v1/projects/p/topics/orders", "{}");

    var got = try orders.get();
    defer got.deinit();
    try h.expectRequest(1, .GET, "http://localhost:8085/v1/projects/p/topics/orders", null);

    try orders.delete();
    try h.expectRequest(2, .DELETE, "http://localhost:8085/v1/projects/p/topics/orders", null);

    var sent = try orders.publish(&.{
        .{ .data = "hello", .attributes = &.{.{ .key = "origin", .value = "zig" }} },
        .{ .attributes = &.{.{ .key = "only", .value = "attr" }} },
    }, .{ .ordering_key = "user-42" });
    defer sent.deinit();
    try h.expectRequest(
        3,
        .POST,
        "http://localhost:8085/v1/projects/p/topics/orders:publish",
        "{\"messages\":[{\"data\":\"aGVsbG8=\",\"attributes\":{\"origin\":\"zig\"},\"orderingKey\":\"user-42\"}," ++
            "{\"attributes\":{\"only\":\"attr\"},\"orderingKey\":\"user-42\"}]}",
    );
    try testing.expectEqual(2, sent.value.message_ids.len);
    try testing.expectEqualStrings("11", sent.value.message_ids[0]);
    try testing.expectEqualStrings("12", sent.value.message_ids[1]);
    try h.expectRequestCount(4);
}

test "ids with % and + reach the path the way the server decodes them" {
    var h: Harness = undefined;
    try h.init(&.{.{ .respond = .{ .body = "{\"name\":\"projects/p/topics/a%41+b\"}" } }}, .{});
    defer h.deinit();
    var got = try h.client.topic("a%41+b").get();
    defer got.deinit();
    try h.expectRequest(0, .GET, "http://localhost:8085/v1/projects/p/topics/a%2541+b", null);
    try testing.expectEqualStrings("projects/p/topics/a%41+b", got.value.name);
}

test "invalid ids and messages fail before any request" {
    var h: Harness = undefined;
    try h.init(&.{}, .{});
    defer h.deinit();

    try testing.expectError(error.InvalidResourceId, h.client.topic("go").get());
    try testing.expect(std.mem.indexOf(u8, h.diag.message(), "invalid topic id") != null);
    try testing.expectError(error.InvalidResourceId, h.client.topic("googthing").create(.{}));
    try testing.expectError(error.InvalidResourceId, h.client.topic("9lives").delete());
    try testing.expectError(error.InvalidResourceId, h.client.topic("a/b/c").publish(&.{.{ .data = "x" }}, .{}));

    const orders = h.client.topic("orders");
    try testing.expectError(error.InvalidMessage, orders.publish(&.{}, .{}));
    try testing.expectError(error.InvalidMessage, orders.publish(&.{.{}}, .{}));
    try testing.expectEqualStrings("message 0 has no data and no attributes", h.diag.message());
    try testing.expectError(error.InvalidMessage, orders.publish(&.{.{ .data = "x" }}, .{ .ordering_key = "\xff" }));
    try h.expectRequestCount(0);
}

test "publish: retry_publish = false makes exactly one attempt" {
    var h: Harness = undefined;
    try h.init(&.{
        .{ .respond = .{ .status = 504, .body = "{\"error\":{\"status\":\"DEADLINE_EXCEEDED\"}}" } },
        .{ .respond = .{ .body = "{\"messageIds\":[\"1\"]}" } },
    }, .{ .retry_publish = false });
    defer h.deinit();
    try testing.expectError(error.DeadlineExceeded, h.client.topic("orders").publish(&.{.{ .data = "x" }}, .{}));
    try h.expectRequestCount(1);
}

test "publish: retried by default" {
    var h: Harness = undefined;
    try h.init(&.{
        .{ .respond = .{ .status = 504, .body = "{\"error\":{\"status\":\"DEADLINE_EXCEEDED\"}}" } },
        .{ .respond = .{ .body = "{\"messageIds\":[\"1\"]}" } },
    }, .{});
    defer h.deinit();
    var sent = try h.client.topic("orders").publish(&.{.{ .data = "x" }}, .{});
    defer sent.deinit();
    try h.expectRequestCount(2);
}

test "publish: ABORTED, CANCELLED and a 5xx UNKNOWN are retried, as Google's clients retry Publish" {
    var h: Harness = undefined;
    try h.init(&.{
        .{ .respond = .{ .status = 409, .body = "{\"error\":{\"code\":409,\"status\":\"ABORTED\"}}" } },
        .{ .respond = .{ .status = 499, .body = "{\"error\":{\"code\":499,\"status\":\"CANCELLED\"}}" } },
        .{ .respond = .{ .status = 500, .body = "{\"error\":{\"code\":500,\"status\":\"UNKNOWN\"}}" } },
        .{ .respond = .{ .body = "{\"messageIds\":[\"1\"]}" } },
    }, .{});
    defer h.deinit();
    var sent = try h.client.topic("orders").publish(&.{.{ .data = "x" }}, .{});
    defer sent.deinit();
    try h.expectRequestCount(4);
}

test "publish: an HTTP status the client cannot place is Unknown and not retried" {
    // A proxy's 405 page maps to error.Unknown, like the server's UNKNOWN
    // status, but nothing about it will change on a second attempt.
    var h: Harness = undefined;
    try h.init(&.{
        .{ .respond = .{ .status = 405, .body = "<html>Method Not Allowed</html>" } },
        .{ .respond = .{ .body = "{\"messageIds\":[\"1\"]}" } },
    }, .{});
    defer h.deinit();
    try testing.expectError(error.Unknown, h.client.topic("orders").publish(&.{.{ .data = "x" }}, .{}));
    try h.expectRequestCount(1);
    try testing.expectEqual(405, h.diag.http_status);
}

test "publish: the wider retry set is still off with retry_publish = false" {
    var h: Harness = undefined;
    try h.init(&.{
        .{ .respond = .{ .status = 409, .body = "{\"error\":{\"status\":\"ABORTED\"}}" } },
        .{ .respond = .{ .body = "{\"messageIds\":[\"1\"]}" } },
    }, .{ .retry_publish = false });
    defer h.deinit();
    try testing.expectError(error.Aborted, h.client.topic("orders").publish(&.{.{ .data = "x" }}, .{}));
    try h.expectRequestCount(1);
}

test "publish: a response with the wrong number of ids is InvalidResponse" {
    var h: Harness = undefined;
    try h.init(&.{.{ .respond = .{ .body = "{\"messageIds\":[\"1\"]}" } }}, .{});
    defer h.deinit();
    try testing.expectError(
        error.InvalidResponse,
        h.client.topic("orders").publish(&.{ .{ .data = "x" }, .{ .data = "y" } }, .{}),
    );
    try testing.expectEqualStrings("the publish response could not be decoded", h.diag.message());
}

test "create reports AlreadyExists with the server's message" {
    var h: Harness = undefined;
    try h.init(&.{.{ .respond = .{
        .status = 409,
        .body = "{\"error\":{\"code\":409,\"message\":\"Topic already exists\",\"status\":\"ALREADY_EXISTS\"}}",
    } }}, .{});
    defer h.deinit();
    try testing.expectError(error.AlreadyExists, h.client.topic("orders").create(.{}));
    try testing.expectEqual(409, h.diag.http_status);
    try testing.expectEqualStrings("Topic already exists", h.diag.message());
}

test "Owned results survive later calls and free independently" {
    var h: Harness = undefined;
    try h.init(&.{
        .{ .respond = .{ .body = "{\"messageIds\":[\"first\"]}" } },
        .{ .respond = .{ .body = "{\"messageIds\":[\"second\"]}" } },
    }, .{});
    defer h.deinit();
    const orders = h.client.topic("orders");
    var a = try orders.publish(&.{.{ .data = "1" }}, .{});
    var b = try orders.publish(&.{.{ .data = "2" }}, .{});
    a.deinit();
    try testing.expectEqualStrings("second", b.value.message_ids[0]);
    b.deinit();
}

test "every allocation failure is reported as OutOfMemory without leaks" {
    const Run = struct {
        fn publish(gpa: std.mem.Allocator) !void {
            var fake: test_util.FakeTransport = .init(testing.allocator, &.{
                .{ .respond = .{ .status = 503, .body = "{\"error\":{\"status\":\"UNAVAILABLE\"}}" } },
                .{ .respond = .{ .body = "{\"messageIds\":[\"1\",\"2\"]}" } },
            });
            defer fake.deinit();
            var clock: test_util.FakeClock = .{};
            var client = try Client.init(gpa, clock.io(), .{
                .project_id = "p",
                .endpoint = .{ .url = "localhost:8085", .emulator = true },
                .transport = fake.transport(),
            });
            defer client.deinit();
            var sent = try client.topic("orders").publish(&.{
                .{ .data = "hello", .attributes = &.{.{ .key = "k", .value = "v" }} },
                .{ .data = "world" },
            }, .{ .ordering_key = "key" });
            sent.deinit();
        }
    };
    try testing.checkAllAllocationFailures(test_util.no_grow_allocator, Run.publish, .{});
}

test "golden: create a topic with settings, and update it" {
    var h: Harness = undefined;
    try h.init(&.{
        .{ .respond = .{ .body = "{\"name\":\"projects/p/topics/orders\",\"labels\":{\"env\":\"test\"},\"messageRetentionDuration\":\"3600s\"}" } },
        .{ .respond = .{ .body = "{\"name\":\"projects/p/topics/orders\",\"labels\":{\"env\":\"prod\"}}" } },
    }, .{});
    defer h.deinit();
    const orders = h.client.topic("orders");
    var created = try orders.create(.{ .labels = &.{.{ .key = "env", .value = "test" }}, .message_retention = .fromSeconds(3600) });
    defer created.deinit();
    try h.expectRequest(0, .PUT, "http://localhost:8085/v1/projects/p/topics/orders", "{\"labels\":{\"env\":\"test\"},\"messageRetentionDuration\":\"3600s\"}");
    try testing.expectEqual(std.Io.Duration.fromSeconds(3600), created.value.message_retention.?);

    var updated = try orders.update(.{ .labels = &.{.{ .key = "env", .value = "prod" }}, .message_retention = .clear });
    defer updated.deinit();
    try h.expectRequest(1, .PATCH, "http://localhost:8085/v1/projects/p/topics/orders", "{\"topic\":{\"labels\":{\"env\":\"prod\"}},\"updateMask\":\"labels,messageRetentionDuration\"}");
    try testing.expectEqualStrings("prod", updated.value.label("env").?);
    try testing.expectEqual(null, updated.value.message_retention);

    try testing.expectError(error.InvalidArgument, orders.update(.{}));
    try testing.expectError(error.InvalidArgument, orders.create(.{ .kms_key_name = "not a key" }));
    try h.expectRequestCount(2);
}

const core = @import("core");
const logging = @import("logging.zig");
const FakeReply = test_util.FakeTransport.Reply;

/// The body a publish of `messages` sends before any compression.
fn plainBody(messages: []const types.Message) ![]u8 {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    return testing.allocator.dupe(u8, try codec.encodePublish(arena.allocator(), messages, null));
}

/// A gzip body decompressed, as Pub/Sub decompresses one.
fn gunzip(body: []const u8) ![]u8 {
    var in: std.Io.Reader = .fixed(body);
    var window: [core.flate.max_window_len]u8 = undefined;
    var inflate: core.flate.Decompress = .init(&in, .gzip, &window);
    return inflate.reader.allocRemaining(testing.allocator, .unlimited);
}

test "publish: compression gzips a body of min_bytes or more, marked Content-Encoding: gzip" {
    var h: Harness = undefined;
    const replies: [5]FakeReply = @splat(.{ .respond = .{ .body = "{\"messageIds\":[\"1\",\"2\",\"3\",\"4\",\"5\"]}" } });
    try h.init(&replies, .{});
    defer h.deinit();
    const orders = h.client.topic("orders");
    const messages: []const types.Message = &.{
        .{ .data = "{\"order\":1001,\"customer\":\"c-0042\",\"items\":3,\"status\":\"paid\"}" },
        .{ .data = "{\"order\":1002,\"customer\":\"c-0977\",\"items\":1,\"status\":\"shipped\"}" },
        .{ .data = "{\"order\":1003,\"customer\":\"c-0042\",\"items\":12,\"status\":\"refunded\"}" },
        .{ .data = "{\"order\":1004,\"customer\":\"c-0513\",\"items\":2,\"status\":\"paid\"}" },
        .{ .data = "{\"order\":1005,\"customer\":\"c-0977\",\"items\":7,\"status\":\"pending\"}" },
    };
    const plain = try plainBody(messages);
    defer testing.allocator.free(plain);
    const len: u32 = @intCast(plain.len);
    try testing.expect(len >= 240);
    // Levels 1 and 6 make different bytes of it, so the golden shows which
    // level was used.
    const fast = try core.gzip.compress(testing.allocator, plain, 1);
    defer testing.allocator.free(fast);
    const default = try core.gzip.compress(testing.allocator, plain, 6);
    defer testing.allocator.free(default);
    try testing.expect(!std.mem.eql(u8, fast, default));

    // The defaults (level 6, from 240 bytes), a body of exactly
    // min_bytes, and another level.
    for ([_]types.Compression{ .{}, .{ .min_bytes = len }, .{ .level = 1, .min_bytes = len } }, 0..) |compression, i| {
        var sent = try orders.publish(messages, .{ .compression = compression });
        sent.deinit();
        const r = try h.fake.request(i);
        try testing.expectEqualStrings("gzip", r.header("content-encoding").?);
        const made = try core.gzip.compress(testing.allocator, plain, compression.level);
        defer testing.allocator.free(made);
        try testing.expectEqualSlices(u8, made, r.body.?);
        const back = try gunzip(r.body.?);
        defer testing.allocator.free(back);
        try testing.expectEqualStrings(plain, back);
    }
    // A byte short of min_bytes, and no compression at all: as it is.
    for ([_]?types.Compression{ .{ .min_bytes = len + 1 }, null }, 3..) |compression, i| {
        var sent = try orders.publish(messages, .{ .compression = compression });
        sent.deinit();
        const r = try h.fake.request(i);
        try testing.expectEqual(null, r.header("content-encoding"));
        try testing.expectEqualStrings(plain, r.body.?);
    }
    try h.expectRequestCount(5);
}

test "publish: a compression level outside 1 to 9 fails before any request" {
    var h: Harness = undefined;
    try h.init(&.{}, .{});
    defer h.deinit();
    const orders = h.client.topic("orders");
    // Even for a body too short to be compressed.
    for ([_]u4{ 0, 10, 15 }) |level| {
        try testing.expectError(error.InvalidArgument, orders.publish(&.{.{ .data = "x" }}, .{ .compression = .{ .level = level } }));
    }
    try testing.expectEqualStrings("compression level 15 is outside 1 to 9", h.diag.message());
    try h.expectRequestCount(0);
}

test "publish: a compressed body that fails its check goes uncompressed, with a warning" {
    var h: Harness = undefined;
    try h.init(&.{.{ .respond = .{ .body = "{\"messageIds\":[\"1\"]}" } }}, .{});
    defer h.deinit();
    const messages: []const types.Message = &.{.{ .data = test_util.repeat("x", 300) }};
    const plain = try plainBody(messages);
    defer testing.allocator.free(plain);
    core.gzip.test_corrupt_trailer = true;
    defer core.gzip.test_corrupt_trailer = false;
    logging.capture.reset();
    var sent = try h.client.topic("orders").publish(messages, .{ .compression = .{} });
    sent.deinit();
    const r = try h.fake.request(0);
    try testing.expectEqual(null, r.header("content-encoding"));
    try testing.expectEqualStrings(plain, r.body.?);
    try testing.expect(std.mem.indexOf(u8, logging.capture.text(), "did not decompress to itself") != null);
}

test "publish: running out of memory while compressing fails the publish, rather than sending it uncompressed" {
    var fake: test_util.FakeTransport = .init(testing.allocator, &.{.{ .respond = .{ .body = "{\"messageIds\":[\"1\"]}" } }});
    defer fake.deinit();
    var clock: test_util.FakeClock = .{};
    // The compressor's state is over 200 KiB; nothing else here comes near.
    var refuse: core.testing.RefuseOver = .{ .child = testing.allocator, .limit = 128 * 1024 };
    var client = try Client.init(refuse.allocator(), clock.io(), .{
        .project_id = "p",
        .endpoint = .{ .url = "localhost:8085", .emulator = true },
        .transport = fake.transport(),
    });
    defer client.deinit();
    const orders = client.topic("orders");
    try testing.expectError(error.OutOfMemory, orders.publish(&.{.{ .data = test_util.repeat("compress me ", 40) }}, .{ .compression = .{} }));
    try testing.expect(refuse.refused > 0);
    try testing.expectEqual(0, fake.requests.items.len);
    // Uncompressed, the same publish needs no such block.
    var sent = try orders.publish(&.{.{ .data = test_util.repeat("compress me ", 40) }}, .{});
    sent.deinit();
}

test "publish: a compressed publish is retried with the same bytes and the same header" {
    var h: Harness = undefined;
    try h.init(&.{
        .{ .respond = .{ .status = 503, .body = "{\"error\":{\"status\":\"UNAVAILABLE\"}}" } },
        .{ .fail = error.ConnectionResetByPeer },
        .{ .respond = .{ .body = "{\"messageIds\":[\"1\"]}" } },
    }, .{});
    defer h.deinit();
    var sent = try h.client.topic("orders").publish(&.{.{ .data = test_util.repeat("retried ", 50) }}, .{ .compression = .{} });
    sent.deinit();
    try h.expectRequestCount(3);
    const first = try h.fake.request(0);
    for (1..3) |i| {
        const again = try h.fake.request(i);
        try testing.expectEqualStrings("gzip", again.header("content-encoding").?);
        try testing.expectEqualSlices(u8, first.body.?, again.body.?);
    }
}

test "publish: every allocation failure with compression is OutOfMemory without leaks" {
    const Run = struct {
        fn publish(gpa: std.mem.Allocator) !void {
            var fake: test_util.FakeTransport = .init(testing.allocator, &.{
                .{ .respond = .{ .status = 503, .body = "{\"error\":{\"status\":\"UNAVAILABLE\"}}" } },
                .{ .respond = .{ .body = "{\"messageIds\":[\"1\"]}" } },
            });
            defer fake.deinit();
            var clock: test_util.FakeClock = .{};
            var client = try Client.init(gpa, clock.io(), .{
                .project_id = "p",
                .endpoint = .{ .url = "localhost:8085", .emulator = true },
                .transport = fake.transport(),
            });
            defer client.deinit();
            var sent = try client.topic("orders").publish(&.{.{ .data = test_util.repeat("compress me ", 40) }}, .{ .compression = .{} });
            sent.deinit();
            try testing.expectEqualStrings("gzip", (try fake.request(1)).header("content-encoding").?);
        }
    };
    try testing.checkAllAllocationFailures(test_util.no_grow_allocator, Run.publish, .{});
}

/// Asserts that request `index` is the one `want` describes: its method
/// and URL, `Content-Encoding: gzip` exactly when `want.gzip`, and a body
/// that is `want.body`, decompressed first when gzipped.
fn expectSent(h: *const Harness, index: usize, want: types.PublishRequest) !void {
    const r = try h.fake.request(index);
    try testing.expectEqual(want.method, r.method);
    try testing.expectEqualStrings(want.url, r.url);
    if (want.gzip) {
        try testing.expectEqualStrings("gzip", r.header("content-encoding").?);
        const back = try gunzip(r.body.?);
        defer testing.allocator.free(back);
        try testing.expectEqualStrings(want.body, back);
    } else {
        try testing.expectEqual(null, r.header("content-encoding"));
        try testing.expectEqualStrings(want.body, r.body.?);
    }
}

test "publishRequest: the URL and body are what publish sends, a quote, a non-ASCII character and an ordering key among them" {
    const messages: []const types.Message = &.{
        .{ .data = "say \"hi\" \\ to Zoë ✓", .attributes = &.{ .{ .key = "z-first", .value = "a \"quoted\" é" }, .{ .key = "a-second", .value = "" } } },
        .{ .attributes = &.{.{ .key = "only", .value = "attr" }} },
        .{ .data = "\x00\xff binary" },
    };
    // The emulator, then production: the URL carries the client's endpoint.
    for ([_]?[]const u8{ null, "token" }, [_][]const u8{ "http://localhost:8085", "https://pubsub.googleapis.com" }) |token, base| {
        var h: Harness = undefined;
        try h.init(&.{.{ .respond = .{ .body = "{\"messageIds\":[\"1\",\"2\",\"3\"]}" } }}, .{ .token = token });
        defer h.deinit();
        const orders = h.client.topic("orders");
        var preview = try orders.publishRequest(messages, .{ .ordering_key = "user-✓" });
        defer preview.deinit();
        try h.expectRequestCount(0);
        const want_url = try std.mem.concat(testing.allocator, u8, &.{ base, "/v1/projects/p/topics/orders:publish" });
        defer testing.allocator.free(want_url);
        try testing.expectEqual(.POST, preview.value.method);
        try testing.expectEqualStrings(want_url, preview.value.url);
        try testing.expectEqualStrings(
            "{\"messages\":[{\"data\":\"c2F5ICJoaSIgXCB0byBab8OrIOKckw==\",\"attributes\":{\"z-first\":\"a \\\"quoted\\\" é\",\"a-second\":\"\"},\"orderingKey\":\"user-✓\"}," ++
                "{\"attributes\":{\"only\":\"attr\"},\"orderingKey\":\"user-✓\"}," ++
                "{\"data\":\"AP8gYmluYXJ5\",\"orderingKey\":\"user-✓\"}]}",
            preview.value.body,
        );
        try testing.expect(!preview.value.gzip);

        var sent = try orders.publish(messages, .{ .ordering_key = "user-✓" });
        sent.deinit();
        try expectSent(&h, 0, preview.value);
        try h.expectRequestCount(1);
    }
}

test "publishRequest: gzip says whether publish compresses, and the body is what a compressed one decompresses to" {
    var h: Harness = undefined;
    const replies: [4]FakeReply = @splat(.{ .respond = .{ .body = "{\"messageIds\":[\"1\"]}" } });
    try h.init(&replies, .{});
    defer h.deinit();
    const orders = h.client.topic("orders");
    const messages: []const types.Message = &.{.{ .data = test_util.repeat("compress me ", 40) }};
    const plain = try plainBody(messages);
    defer testing.allocator.free(plain);
    const len: u32 = @intCast(plain.len);
    // At min_bytes, past it, a byte short of it, and no compression.
    const cases = [_]struct { ?types.Compression, bool }{
        .{ .{ .min_bytes = len }, true },
        .{ .{ .level = 1 }, true },
        .{ .{ .min_bytes = len + 1 }, false },
        .{ null, false },
    };
    for (cases, 0..) |case, i| {
        var preview = try orders.publishRequest(messages, .{ .compression = case[0] });
        defer preview.deinit();
        try testing.expectEqual(case[1], preview.value.gzip);
        try testing.expectEqualStrings(plain, preview.value.body);
        var sent = try orders.publish(messages, .{ .compression = case[0] });
        sent.deinit();
        try expectSent(&h, i, preview.value);
    }
    try h.expectRequestCount(4);
}

test "publishRequest: the checks publish makes fail it the same way, and nothing is sent" {
    var h: Harness = undefined;
    try h.init(&.{}, .{});
    defer h.deinit();
    const orders = h.client.topic("orders");
    try testing.expectError(error.InvalidResourceId, h.client.topic("a/b/c").publishRequest(&.{.{ .data = "x" }}, .{}));
    try testing.expect(std.mem.indexOf(u8, h.diag.message(), "invalid topic id") != null);
    try testing.expectError(error.InvalidMessage, orders.publishRequest(&.{}, .{}));
    try testing.expectError(error.InvalidMessage, orders.publishRequest(&.{.{}}, .{}));
    try testing.expectEqualStrings("message 0 has no data and no attributes", h.diag.message());
    try testing.expectError(error.InvalidMessage, orders.publishRequest(&.{.{ .data = "x" }}, .{ .ordering_key = "\xff" }));
    // Even for a body too short to be compressed.
    try testing.expectError(error.InvalidArgument, orders.publishRequest(&.{.{ .data = "x" }}, .{ .compression = .{ .level = 0 } }));
    try testing.expectEqualStrings("compression level 0 is outside 1 to 9", h.diag.message());
    try h.expectRequestCount(0);

    // A later success leaves no message from the failure before it.
    var preview = try orders.publishRequest(&.{.{ .data = "x" }}, .{});
    defer preview.deinit();
    try testing.expectEqualStrings("", h.diag.message());
}

test "publishRequest: every allocation failure is OutOfMemory without leaks" {
    const Run = struct {
        fn build(gpa: std.mem.Allocator) !void {
            var fake: test_util.FakeTransport = .init(testing.allocator, &.{});
            defer fake.deinit();
            var clock: test_util.FakeClock = .{};
            var client = try Client.init(gpa, clock.io(), .{
                .project_id = "p",
                .endpoint = .{ .url = "localhost:8085", .emulator = true },
                .transport = fake.transport(),
            });
            defer client.deinit();
            var preview = try client.topic("orders").publishRequest(&.{
                .{ .data = "hello", .attributes = &.{.{ .key = "k", .value = "v" }} },
                .{ .data = "world" },
            }, .{ .ordering_key = "key", .compression = .{} });
            preview.deinit();
        }
    };
    try testing.checkAllAllocationFailures(test_util.no_grow_allocator, Run.build, .{});
}

/// Any topic id, messages and options: `publishRequest` fails exactly when
/// `publish` fails before sending, with the same error, and otherwise
/// describes the one request `publish` then sends.
fn publishRequestProperty(_: void, input: []const u8) !void {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    var g: test_util.ByteGen = .init(input);

    const id = g.pick([]const u8, &.{ "orders", "a%41+b", "x.y~z_1", "go", "googthing", "a/b", "Orders-2" });
    const messages = try a.alloc(types.Message, g.intRange(usize, 0, 4));
    for (messages) |*m| {
        var attrs: std.ArrayList(types.Attribute) = .empty;
        for (0..g.intRange(usize, 0, 3)) |_| {
            var key_buf: [12]u8 = undefined;
            var value_buf: [16]u8 = undefined;
            // Raw bytes now and then, so invalid UTF-8 reaches the checks.
            const key = try a.dupe(u8, if (g.intRange(u8, 0, 7) == 0) g.slice(12) else g.utf8(&key_buf, 12));
            const value = try a.dupe(u8, g.utf8(&value_buf, 16));
            try attrs.append(a, .{ .key = key, .value = value });
        }
        m.* = .{ .data = try a.dupe(u8, g.slice(g.pick(usize, &.{ 0, 8, 80, 400 }))), .attributes = attrs.items };
    }
    var key_buf: [16]u8 = undefined;
    const ordering_key: ?[]const u8 = switch (g.intRange(u8, 0, 3)) {
        0 => null,
        1 => "",
        2 => try a.dupe(u8, g.utf8(&key_buf, 16)),
        else => try a.dupe(u8, g.slice(16)),
    };
    const compression: ?types.Compression = if (g.boolean()) .{
        .level = g.int(u4),
        .min_bytes = g.pick(u32, &.{ 0, 1, 64, 240, 1000 }),
    } else null;
    const options: types.PublishOptions = .{ .ordering_key = ordering_key, .compression = compression };

    var ids: std.ArrayList(u8) = .empty;
    try ids.appendSlice(a, "{\"messageIds\":[");
    for (0..messages.len) |i| try ids.appendSlice(a, if (i == 0) "\"1\"" else ",\"1\"");
    try ids.appendSlice(a, "]}");
    const replies = [_]FakeReply{.{ .respond = .{ .body = ids.items } }};
    var h: Harness = undefined;
    try h.init(&replies, .{ .token = if (g.boolean()) "token" else null });
    defer h.deinit();
    const topic = h.client.topic(id);

    var preview = topic.publishRequest(messages, options) catch |err| {
        const message = try a.dupe(u8, h.diag.message());
        try testing.expectError(err, topic.publish(messages, options));
        try testing.expectEqualStrings(message, h.diag.message());
        try h.expectRequestCount(0);
        return;
    };
    defer preview.deinit();
    var sent = try topic.publish(messages, options);
    sent.deinit();
    try h.expectRequestCount(1);
    try expectSent(&h, 0, preview.value);
}

test "fuzz publishRequest: a request built is the one publish sends, and one refused is refused by publish alike" {
    try test_util.fuzzBytes({}, publishRequestProperty, .{ .corpus = &.{
        "",
        "\x00\x02\x01\x41\x42\x00\x03\x02\x05",
        "\x06\x01\x00\x03\xff\xfe\x01\x01\x06\x00\x10\x00",
    } });
}

const agent = "serviceAccount:service-82150720798@gs-project-accounts.iam.gserviceaccount.com";
const aborted =
    \\{"error":{"code":409,"message":"There were concurrent policy changes. Please retry the whole read-modify-write with exponential backoff.","status":"ABORTED"}}
;

test "IAM: read, write, and grant once, on the paths Pub/Sub serves them" {
    var h: Harness = undefined;
    try h.init(&.{
        .{ .respond = .{ .body = "{\"etag\":\"ACAB\"}" } },
        .{ .respond = .{ .body = "{\"version\":1,\"etag\":\"BwX1\",\"bindings\":[{\"role\":\"roles/pubsub.viewer\",\"members\":[\"user:a@x.com\"]}]}" } },
        .{ .respond = .{ .body = "{\"etag\":\"BwX1\",\"bindings\":[{\"role\":\"roles/pubsub.viewer\",\"members\":[\"user:a@x.com\"]}]}" } },
        .{ .respond = .{ .body = "{\"etag\":\"BwX2\",\"bindings\":[{\"role\":\"roles/pubsub.viewer\",\"members\":[\"user:a@x.com\"]},{\"role\":\"roles/pubsub.publisher\",\"members\":[\"" ++ agent ++ "\"]}]}" } },
        .{ .respond = .{ .body = "{\"etag\":\"BwX2\",\"bindings\":[{\"role\":\"roles/pubsub.publisher\",\"members\":[\"" ++ agent ++ "\"]}]}" } },
    }, .{});
    defer h.deinit();
    const orders = h.client.topic("orders");

    var empty = try orders.iamPolicy();
    defer empty.deinit();
    try testing.expectEqualStrings("ACAB", empty.value.etag.?);
    try h.expectRequest(0, .GET, "http://localhost:8085/v1/projects/p/topics/orders:getIamPolicy?options.requestedPolicyVersion=3", null);

    var written = try orders.setIamPolicy(.{ .etag = "ACAB", .bindings = &.{.{ .role = "roles/pubsub.viewer", .members = &.{"user:a@x.com"} }} });
    defer written.deinit();
    try h.expectRequest(1, .POST, "http://localhost:8085/v1/projects/p/topics/orders:setIamPolicy",
        \\{"policy":{"version":1,"etag":"ACAB","bindings":[{"role":"roles/pubsub.viewer","members":["user:a@x.com"]}]}}
    );

    // Not held: read, then written under the read's etag.
    var granted = try orders.addIamBinding("roles/pubsub.publisher", agent);
    defer granted.deinit();
    try testing.expect(granted.value.grants("roles/pubsub.publisher", agent));
    try h.expectRequest(3, .POST, "http://localhost:8085/v1/projects/p/topics/orders:setIamPolicy",
        \\{"policy":{"version":1,"etag":"BwX1","bindings":[{"role":"roles/pubsub.viewer","members":["user:a@x.com"]},{"role":"roles/pubsub.publisher","members":["serviceAccount:service-82150720798@gs-project-accounts.iam.gserviceaccount.com"]}]}}
    );
    // Held already: read, and nothing written.
    var again = try orders.addIamBinding("roles/pubsub.publisher", agent);
    defer again.deinit();
    try h.expectRequestCount(5);

    try testing.expectError(error.InvalidArgument, orders.addIamBinding("", agent));
    try testing.expectError(error.InvalidArgument, orders.addIamBinding("roles/pubsub.publisher", ""));
    try testing.expectError(error.InvalidResourceId, h.client.topic("a/b").iamPolicy());
    try h.expectRequestCount(5);
}

test "IAM: a grant that meets another change starts over, and stops at the retry policy's attempts" {
    {
        var h: Harness = undefined;
        try h.init(&.{
            .{ .respond = .{ .body = "{\"etag\":\"E1\"}" } },
            .{ .respond = .{ .status = 409, .body = aborted } },
            // Read again: the other change was this very grant.
            .{ .respond = .{ .body = "{\"etag\":\"E2\",\"bindings\":[{\"role\":\"roles/pubsub.publisher\",\"members\":[\"" ++ agent ++ "\"]}]}" } },
        }, .{});
        defer h.deinit();
        var granted = try h.client.topic("orders").addIamBinding("roles/pubsub.publisher", agent);
        defer granted.deinit();
        try testing.expectEqualStrings("E2", granted.value.etag.?);
        try h.expectRequestCount(3);
    }
    {
        var h: Harness = undefined;
        try h.init(&.{
            .{ .respond = .{ .body = "{\"etag\":\"E1\"}" } },
            .{ .respond = .{ .status = 409, .body = aborted } },
            .{ .respond = .{ .body = "{\"etag\":\"E2\"}" } },
            .{ .respond = .{ .status = 409, .body = aborted } },
        }, .{ .retry = .{ .max_attempts = 2, .initial_backoff_ms = 1, .max_backoff_ms = 1 } });
        defer h.deinit();
        try testing.expectError(error.Aborted, h.client.topic("orders").addIamBinding("roles/pubsub.publisher", agent));
        try h.expectRequestCount(4);
    }
}

test "golden: a topic's subscriptions and snapshots, by name and in pages" {
    var h: Harness = undefined;
    try h.init(&.{
        // Production's answers, 2026-10-10: names alone, and a token that
        // is no name.
        .{ .respond = .{ .body = "{\"subscriptions\":[\"projects/p/subscriptions/orders-worker\"],\"nextPageToken\":\"enhhcGpTGwQLRFJ7VwwbBVEOGA\"}" } },
        .{ .respond = .{ .body = "{\"subscriptions\":[\"projects/other-project/subscriptions/far\"]}" } },
        .{ .respond = .{ .body = "{\"snapshots\":[\"projects/p/snapshots/before\"]}" } },
        .{ .respond = .{ .body = "{}" } },
        .{ .respond = .{ .status = 404, .body = "{\"error\":{\"code\":404,\"message\":\"Resource not found (resource=orders).\",\"status\":\"NOT_FOUND\"}}" } },
        .{ .respond = .{ .body = "{\"snapshots\":[17]}" } },
    }, .{});
    defer h.deinit();
    const orders = h.client.topic("orders");
    const base = "http://localhost:8085/v1/projects/p/topics/orders";

    var first = try orders.listSubscriptions(.{ .page_size = 1 });
    defer first.deinit();
    try h.expectRequest(0, .GET, base ++ "/subscriptions?pageSize=1", null);
    try testing.expectEqual(1, first.value.names.len);
    try testing.expectEqualStrings("projects/p/subscriptions/orders-worker", first.value.names[0]);
    var second = try orders.listSubscriptions(.{ .page_size = 1, .page_token = first.value.next_page_token });
    defer second.deinit();
    try h.expectRequest(1, .GET, base ++ "/subscriptions?pageSize=1&pageToken=enhhcGpTGwQLRFJ7VwwbBVEOGA", null);
    // A subscription of another project, attached to this topic.
    try testing.expectEqualStrings("projects/other-project/subscriptions/far", second.value.names[0]);
    try testing.expectEqual(null, second.value.next_page_token);

    var kept = try orders.listSnapshots(.{});
    defer kept.deinit();
    try h.expectRequest(2, .GET, base ++ "/snapshots?pageSize=100", null);
    try testing.expectEqualStrings("projects/p/snapshots/before", kept.value.names[0]);
    // A topic with nothing attached lists as `{}`.
    var none = try orders.listSnapshots(.{ .page_size = 0 });
    defer none.deinit();
    try h.expectRequest(3, .GET, base ++ "/snapshots", null);
    try testing.expectEqual(0, none.value.names.len);

    // A deleted topic has no list.
    try testing.expectError(error.NotFound, orders.listSnapshots(.{}));
    try testing.expectError(error.InvalidResponse, orders.listSnapshots(.{}));
    try testing.expectEqualStrings("the name list response could not be decoded", h.diag.message());
    try testing.expectError(error.InvalidResourceId, h.client.topic("go").listSubscriptions(.{}));
    try h.expectRequestCount(6);
}

test "golden: a topic's schema is named in full on create and in an update, and cleared by a mask alone" {
    const with_schema =
        \\{"name":"projects/p/topics/orders","schemaSettings":{"schema":"projects/p/schemas/order-v1","encoding":"JSON"}}
    ;
    var h: Harness = undefined;
    try h.init(&.{
        .{ .respond = .{ .body = with_schema } },
        .{ .respond = .{ .body = "{\"name\":\"projects/p/topics/orders\",\"schemaSettings\":{\"schema\":\"projects/other/schemas/order-v1\",\"encoding\":\"BINARY\",\"firstRevisionId\":\"1b46a16a\"}}" } },
        .{ .respond = .{ .body = "{\"name\":\"projects/p/topics/orders\"}" } },
        .{ .respond = .{ .body = "{\"name\":\"projects/p/topics/orders\",\"schemaSettings\":{\"schema\":\"_deleted-schema_\",\"encoding\":\"JSON\"}}" } },
        .{ .respond = .{ .body = with_schema } },
    }, .{});
    defer h.deinit();
    const orders = h.client.topic("orders");
    const path = "http://localhost:8085/v1/projects/p/topics/orders";

    // An id is one of the client's own project.
    var created = try orders.create(.{ .schema = .{ .schema = "order-v1", .encoding = .json } });
    defer created.deinit();
    try h.expectRequest(0, .PUT, path,
        \\{"schemaSettings":{"schema":"projects/p/schemas/order-v1","encoding":"JSON"}}
    );
    try testing.expectEqualStrings("projects/p/schemas/order-v1", created.value.schema.?.schema);
    try testing.expectEqual(types.SchemaEncoding.json, created.value.schema.?.encoding);

    // A full name goes as given, and the settings are replaced whole.
    var changed = try orders.update(.{ .schema = .{ .set = .{
        .schema = "projects/other/schemas/order-v1",
        .encoding = .binary,
        .first_revision_id = "1b46a16a",
    } } });
    defer changed.deinit();
    try h.expectRequest(1, .PATCH, path,
        \\{"topic":{"schemaSettings":{"schema":"projects/other/schemas/order-v1","encoding":"BINARY","firstRevisionId":"1b46a16a"}},"updateMask":"schemaSettings"}
    );
    try testing.expectEqualStrings("1b46a16a", changed.value.schema.?.first_revision_id.?);
    try testing.expectEqual(null, changed.value.schema.?.last_revision_id);

    var cleared = try orders.update(.{ .schema = .clear });
    defer cleared.deinit();
    try h.expectRequest(2, .PATCH, path, "{\"topic\":{},\"updateMask\":\"schemaSettings\"}");
    try testing.expectEqual(null, cleared.value.schema);

    var orphan = try orders.get();
    defer orphan.deinit();
    try testing.expect(orphan.value.schema.?.isDeleted());

    // An id in an update is one of the client's own project too.
    var renamed = try orders.update(.{ .schema = .{ .set = .{ .schema = "order-v1", .encoding = .json } } });
    defer renamed.deinit();
    try h.expectRequest(4, .PATCH, path,
        \\{"topic":{"schemaSettings":{"schema":"projects/p/schemas/order-v1","encoding":"JSON"}},"updateMask":"schemaSettings"}
    );
    try h.expectRequestCount(5);
}

test "a topic's schema: what the checks refuse is never sent, and what the server refuses is said in its words" {
    var h: Harness = undefined;
    try h.init(&.{
        // The emulator's words, 2026-10-11.
        .{ .respond = .{ .status = 404, .body = "{\"error\":{\"code\":404,\"message\":\"Schema could not be found\",\"status\":\"NOT_FOUND\"}}" } },
        .{ .respond = .{ .status = 404, .body = "{\"error\":{\"code\":404,\"message\":\"First revision could not be found\",\"status\":\"NOT_FOUND\"}}" } },
        .{ .respond = .{ .status = 400, .body = "{\"error\":{\"code\":400,\"message\":\"Could not parse message\",\"status\":\"INVALID_ARGUMENT\"}}" } },
        .{ .respond = .{ .status = 404, .body = "{\"error\":{\"code\":404,\"message\":\"Schema associated with topic deleted.\",\"status\":\"NOT_FOUND\"}}" } },
    }, .{});
    defer h.deinit();
    const orders = h.client.topic("orders");

    try testing.expectError(error.InvalidArgument, orders.create(.{ .schema = .{ .schema = "order-v1@1b46a16a", .encoding = .json } }));
    try testing.expectEqualStrings("the schema is neither a schema id nor projects/{project}/schemas/{id}", h.diag.message());
    try testing.expectError(error.InvalidArgument, orders.create(.{ .schema = .{ .schema = "order-v1", .encoding = .unknown } }));
    try testing.expectError(error.InvalidArgument, orders.update(.{ .schema = .{ .set = .{ .schema = "_deleted-schema_", .encoding = .json } } }));
    try testing.expect(std.mem.startsWith(u8, h.diag.message(), "the schema is _deleted-schema_"));
    try testing.expectError(error.InvalidArgument, orders.update(.{ .schema = .{ .set = .{ .schema = "order-v1", .encoding = .json, .last_revision_id = "a:b" } } }));
    try h.expectRequestCount(0);

    try testing.expectError(error.NotFound, orders.create(.{ .schema = .{ .schema = "order-v1", .encoding = .json } }));
    try testing.expectEqualStrings("Schema could not be found", h.diag.message());
    try testing.expectError(error.NotFound, orders.update(.{ .schema = .{ .set = .{ .schema = "order-v1", .encoding = .json, .first_revision_id = "deadbeef" } } }));
    try testing.expectEqualStrings("First revision could not be found", h.diag.message());
    // A message that does not fit is refused as any bad message is, and a
    // topic whose schema is gone refuses every one.
    try testing.expectError(error.InvalidArgument, orders.publish(&.{.{ .data = "{\"quantity\":\"one\"}" }}, .{}));
    try testing.expectEqualStrings("Could not parse message", h.diag.message());
    try testing.expectError(error.NotFound, orders.publish(&.{.{ .data = "{}" }}, .{}));
    try testing.expectEqualStrings("Schema associated with topic deleted.", h.diag.message());
    try h.expectRequestCount(4);
}

fn topicSchemaAllocations(gpa: std.mem.Allocator) !void {
    var fake: test_util.FakeTransport = .init(testing.allocator, &.{
        .{ .respond = .{ .body = "{\"name\":\"projects/p/topics/orders\",\"schemaSettings\":{\"schema\":\"projects/p/schemas/order-v1\",\"encoding\":\"JSON\",\"firstRevisionId\":\"1b46a16a\",\"lastRevisionId\":\"6f0519a4\"}}" } },
        .{ .respond = .{ .body = "{\"name\":\"projects/p/topics/orders\",\"schemaSettings\":{\"schema\":\"projects/p/schemas/order-v1\",\"encoding\":\"BINARY\"}}" } },
        .{ .respond = .{ .body = "{\"name\":\"projects/p/topics/orders\"}" } },
    });
    defer fake.deinit();
    var clock: test_util.FakeClock = .{};
    var client = try Client.init(gpa, clock.io(), .{
        .project_id = "p",
        .endpoint = .{ .url = "localhost:8085", .emulator = true },
        .transport = fake.transport(),
    });
    defer client.deinit();
    const orders = client.topic("orders");
    var created = try orders.create(.{ .schema = .{ .schema = "order-v1", .encoding = .json, .first_revision_id = "1b46a16a", .last_revision_id = "6f0519a4" } });
    created.deinit();
    var changed = try orders.update(.{ .schema = .{ .set = .{ .schema = "order-v1", .encoding = .binary } } });
    changed.deinit();
    var cleared = try orders.update(.{ .schema = .clear });
    cleared.deinit();
    try testing.expectEqual(3, fake.requests.items.len);
}

test "allocation failures: a topic's schema on create and in an update" {
    try testing.checkAllAllocationFailures(test_util.no_grow_allocator, topicSchemaAllocations, .{});
}

const redact: types.MessageTransform = .{ .kind = .{ .javascript_udf = .{
    .function_name = "redact",
    .code = "function redact(message, metadata) { delete message.attributes['card']; return message; }",
} } };
const redact_json =
    \\{"javascriptUdf":{"functionName":"redact","code":"function redact(message, metadata) { delete message.attributes['card']; return message; }"}}
;

test "golden: a topic's transforms on create, as read, and replaced and cleared by an update" {
    var h: Harness = undefined;
    try h.init(&.{
        .{ .respond = .{ .body = "{\"name\":\"projects/p/topics/orders\",\"messageTransforms\":[" ++ redact_json ++ "]}" } },
        .{ .respond = .{ .body = "{\"name\":\"projects/p/topics/orders\",\"messageTransforms\":[" ++ redact_json ++
            ",{\"aiInference\":{\"endpoint\":\"projects/p/locations/us-central1/endpoints/e\"}}" ++
            ",{\"javascriptUdf\":{\"functionName\":\"stamp\",\"code\":\"function stamp(m) { return m; }\"},\"disabled\":true}]}" } },
        .{ .respond = .{ .body = "{\"name\":\"projects/p/topics/orders\",\"messageTransforms\":[{\"javascriptUdf\":{\"functionName\":\"stamp\",\"code\":\"function stamp(m) { return m; }\"},\"disabled\":true}," ++ redact_json ++ "]}" } },
        .{ .respond = .{ .body = "{\"name\":\"projects/p/topics/orders\"}" } },
    }, .{});
    defer h.deinit();
    const orders = h.client.topic("orders");
    const path = "http://localhost:8085/v1/projects/p/topics/orders";

    var created = try orders.create(.{ .message_transforms = &.{redact} });
    defer created.deinit();
    try h.expectRequest(0, .PUT, path, "{\"messageTransforms\":[" ++ redact_json ++ "]}");
    try testing.expectEqual(1, created.value.message_transforms.len);
    try testing.expectEqualStrings("redact", created.value.message_transforms[0].kind.javascript_udf.function_name);
    try testing.expectEqualStrings(redact.kind.javascript_udf.code, created.value.message_transforms[0].kind.javascript_udf.code);
    try testing.expect(!created.value.message_transforms[0].disabled);

    // As read: in the server's order, a kind this client does not model
    // in its place, and each one's switch.
    var read = try orders.get();
    defer read.deinit();
    try testing.expectEqual(3, read.value.message_transforms.len);
    try testing.expect(read.value.message_transforms[0].kind == .javascript_udf);
    try testing.expect(read.value.message_transforms[1].kind == .other);
    try testing.expectEqualStrings("stamp", read.value.message_transforms[2].kind.javascript_udf.function_name);
    try testing.expect(read.value.message_transforms[2].disabled);

    // An update replaces the list whole, in the order given.
    const stamp: types.MessageTransform = .{
        .kind = .{ .javascript_udf = .{ .function_name = "stamp", .code = "function stamp(m) { return m; }" } },
        .disabled = true,
    };
    var replaced = try orders.update(.{ .message_transforms = &.{ stamp, redact } });
    defer replaced.deinit();
    try h.expectRequest(2, .PATCH, path, "{\"topic\":{\"messageTransforms\":[{\"javascriptUdf\":{\"functionName\":\"stamp\",\"code\":\"function stamp(m) { return m; }\"},\"disabled\":true}," ++ redact_json ++ "]},\"updateMask\":\"messageTransforms\"}");
    try testing.expectEqual(2, replaced.value.message_transforms.len);
    try testing.expect(replaced.value.message_transforms[0].disabled);

    // An empty list clears: named in the mask, and nothing in the body.
    var cleared = try orders.update(.{ .message_transforms = &.{} });
    defer cleared.deinit();
    try h.expectRequest(3, .PATCH, path, "{\"topic\":{},\"updateMask\":\"messageTransforms\"}");
    try testing.expectEqual(0, cleared.value.message_transforms.len);
    try h.expectRequestCount(4);
}

test "a topic's transforms: what the checks refuse is never sent, a list read with a kind not modelled is not written back, and the server's refusals come in its words" {
    var h: Harness = undefined;
    try h.init(&.{
        .{ .respond = .{ .body = "{\"name\":\"projects/p/topics/orders\",\"messageTransforms\":[" ++ redact_json ++ ",{\"aiInference\":{}}]}" } },
        // Production's words, 2026-10-12.
        .{ .respond = .{ .status = 400, .body = "{\"error\":{\"code\":400,\"message\":\"Provided message transform configuration is invalid: Failed to create JavaScript UDF: `f`. SyntaxError: Unexpected end of input at f line 1, columns 31-31\",\"status\":\"FAILED_PRECONDITION\"}}" } },
        .{ .respond = .{ .status = 400, .body = "{\"error\":{\"code\":400,\"message\":\"Provided message transform configuration is invalid: Failed to create JavaScript UDF: `g`. Failed to find function in provided code\",\"status\":\"FAILED_PRECONDITION\"}}" } },
        .{ .respond = .{ .status = 400, .body = "{\"error\":{\"code\":400,\"message\":\"Pub/Sub failed to apply a message transformation to one or more messages in the publish request. Error: Failed to execute JavaScript UDF: `boom`. Error: no at boom line 1, columns 35-36..\",\"status\":\"INVALID_ARGUMENT\",\"details\":[{\"@type\":\"type.googleapis.com/google.rpc.ErrorInfo\",\"reason\":\"SMT_FAILURE\",\"domain\":\"pubsub.googleapis.com\"}]}}" } },
    }, .{ .token = "t" });
    defer h.deinit();
    const orders = h.client.topic("orders");
    const f: types.MessageTransform = .{ .kind = .{ .javascript_udf = .{ .function_name = "f", .code = "function f(message, metadata) {" } } };

    try testing.expectError(error.InvalidArgument, orders.create(.{ .message_transforms = &.{.{ .kind = .{ .javascript_udf = .{ .function_name = "", .code = "function f() {}" } } }} }));
    try testing.expectEqualStrings("message transform 0 has no function name", h.diag.message());
    try testing.expectError(error.InvalidArgument, orders.create(.{ .message_transforms = &.{ f, redact, f } }));
    try testing.expectEqualStrings("message transforms 0 and 2 have the same function name", h.diag.message());
    try testing.expectError(error.InvalidArgument, orders.update(.{ .message_transforms = &.{.{ .kind = .{ .javascript_udf = .{ .function_name = "f", .code = "" } } }} }));
    try testing.expectEqualStrings("message transform 0 has no code", h.diag.message());
    try h.expectRequestCount(0);

    // A list as read cannot go back as it is while it holds a kind this
    // client cannot write: sent without it, the topic would lose it.
    var read = try orders.get();
    defer read.deinit();
    try testing.expectError(error.InvalidArgument, orders.update(.{ .message_transforms = read.value.message_transforms }));
    try testing.expect(std.mem.startsWith(u8, h.diag.message(), "message transform 1 is of a kind this client does not model"));
    try h.expectRequestCount(1);

    // Whether the code parses, and holds the function, is the server's
    // to say.
    try testing.expectError(error.FailedPrecondition, orders.create(.{ .message_transforms = &.{f} }));
    try testing.expectEqualStrings("Provided message transform configuration is invalid: Failed to create JavaScript UDF: `f`. SyntaxError: Unexpected end of input at f line 1, columns 31-31", h.diag.message());
    try testing.expectError(error.FailedPrecondition, orders.update(.{ .message_transforms = &.{.{ .kind = .{ .javascript_udf = .{ .function_name = "g", .code = "function f(message, metadata) { return message; }" } } }} }));
    try testing.expect(std.mem.endsWith(u8, h.diag.message(), "Failed to find function in provided code"));

    // A function that throws refuses the whole publish, once: it is a bad
    // request, not an outage.
    try testing.expectError(error.InvalidArgument, orders.publish(&.{ .{ .data = "a" }, .{ .data = "b" } }, .{}));
    try testing.expect(std.mem.startsWith(u8, h.diag.message(), "Pub/Sub failed to apply a message transformation to one or more messages in the publish request."));
    try h.expectRequestCount(4);
}

fn topicTransformsAllocations(gpa: std.mem.Allocator) !void {
    var fake: test_util.FakeTransport = .init(testing.allocator, &.{
        .{ .respond = .{ .body = "{\"name\":\"projects/p/topics/orders\",\"messageTransforms\":[" ++ redact_json ++ ",{\"aiInference\":{}},{\"javascriptUdf\":{\"functionName\":\"stamp\",\"code\":\"function stamp(m) {\\n  return m;\\n}\"},\"disabled\":true}]}" } },
        .{ .respond = .{ .body = "{\"name\":\"projects/p/topics/orders\",\"messageTransforms\":[" ++ redact_json ++ "]}" } },
        .{ .respond = .{ .body = "{\"name\":\"projects/p/topics/orders\",\"messageTransforms\":[" ++ redact_json ++ "]}" } },
        .{ .respond = .{ .body = "{\"name\":\"projects/p/topics/orders\"}" } },
    });
    defer fake.deinit();
    var clock: test_util.FakeClock = .{};
    var client = try Client.init(gpa, clock.io(), .{
        .project_id = "p",
        .endpoint = .{ .url = "localhost:8085", .emulator = true },
        .transport = fake.transport(),
    });
    defer client.deinit();
    const orders = client.topic("orders");
    const stamp: types.MessageTransform = .{
        .kind = .{ .javascript_udf = .{ .function_name = "stamp", .code = "function stamp(m) {\n  return m;\n}" } },
        .disabled = true,
    };
    var created = try orders.create(.{ .message_transforms = &.{ redact, stamp } });
    created.deinit();
    var read = try orders.get();
    read.deinit();
    var replaced = try orders.update(.{ .message_transforms = &.{redact} });
    replaced.deinit();
    var cleared = try orders.update(.{ .message_transforms = &.{} });
    cleared.deinit();
    try testing.expectEqual(4, fake.requests.items.len);
}

test "allocation failures: a topic's transforms on create, as read, and in an update" {
    try testing.checkAllAllocationFailures(test_util.no_grow_allocator, topicTransformsAllocations, .{});
}

const import_account = "importer@my-project.iam.gserviceaccount.com";
const kinesis_source: types.Ingestion.Source = .{ .aws_kinesis = .{
    .stream_arn = "arn:aws:kinesis:us-east-1:111111111111:stream/orders",
    .consumer_arn = "arn:aws:kinesis:us-east-1:111111111111:stream/orders/consumer/c:1",
    .aws_role_arn = "arn:aws:iam::111111111111:role/pubsub",
    .gcp_service_account = import_account,
} };
const kinesis_json =
    \\{"awsKinesis":{"streamArn":"arn:aws:kinesis:us-east-1:111111111111:stream/orders","consumerArn":"arn:aws:kinesis:us-east-1:111111111111:stream/orders/consumer/c:1","awsRoleArn":"arn:aws:iam::111111111111:role/pubsub","gcpServiceAccount":"importer@my-project.iam.gserviceaccount.com"},"platformLogsSettings":{"severity":"INFO"}}
;

test "golden: an import topic is made, read with its state, given another source whole, and made a standard topic again" {
    var h: Harness = undefined;
    try h.init(&.{
        .{ .respond = .{ .body = "{\"name\":\"projects/p/topics/uploads\",\"ingestionDataSourceSettings\":{\"cloudStorage\":{\"state\":\"ACTIVE\",\"bucket\":\"my-uploads\",\"textFormat\":{\"delimiter\":\"\\n\"}}}}" } },
        .{ .respond = .{ .body = "{\"name\":\"projects/p/topics/uploads\",\"state\":\"INGESTION_RESOURCE_ERROR\",\"ingestionDataSourceSettings\":{\"cloudStorage\":{\"state\":\"BUCKET_NOT_FOUND\",\"bucket\":\"my-uploads\",\"textFormat\":{\"delimiter\":\"\\n\"}}}}" } },
        .{ .respond = .{ .body = "{\"name\":\"projects/p/topics/uploads\",\"ingestionDataSourceSettings\":{\"awsKinesis\":{\"state\":\"ACTIVE\",\"streamArn\":\"arn:aws:kinesis:us-east-1:111111111111:stream/orders\",\"consumerArn\":\"arn:aws:kinesis:us-east-1:111111111111:stream/orders/consumer/c:1\",\"awsRoleArn\":\"arn:aws:iam::111111111111:role/pubsub\",\"gcpServiceAccount\":\"importer@my-project.iam.gserviceaccount.com\"},\"platformLogsSettings\":{\"severity\":\"INFO\"}}}" } },
        .{ .respond = .{ .body = "{\"name\":\"projects/p/topics/uploads\"}" } },
    }, .{});
    defer h.deinit();
    const uploads = h.client.topic("uploads");
    const path = "http://localhost:8085/v1/projects/p/topics/uploads";

    var created = try uploads.create(.{ .ingestion = .{ .source = .{ .cloud_storage = .{ .bucket = "my-uploads" } } } });
    defer created.deinit();
    try h.expectRequest(0, .PUT, path,
        \\{"ingestionDataSourceSettings":{"cloudStorage":{"bucket":"my-uploads","textFormat":{"delimiter":"\n"}}}}
    );
    try testing.expectEqualStrings("my-uploads", created.value.ingestion.?.source.?.cloud_storage.bucket);
    try testing.expectEqualStrings("\n", created.value.ingestion.?.source.?.cloud_storage.format.text.delimiter);
    try testing.expectEqual(types.IngestionState.active, created.value.ingestion.?.state);
    try testing.expectEqual(types.TopicInfo.State.active, created.value.state);

    // A source that has gone shows in its state, and in the topic's.
    var read = try uploads.get();
    defer read.deinit();
    try testing.expectEqual(types.IngestionState.bucket_not_found, read.value.ingestion.?.state);
    try testing.expectEqual(types.TopicInfo.State.ingestion_resource_error, read.value.state);

    // An update replaces the settings whole: another source, with logs.
    var changed = try uploads.update(.{ .ingestion = .{ .set = .{ .source = kinesis_source, .log_severity = .info } } });
    defer changed.deinit();
    try h.expectRequest(2, .PATCH, path, "{\"topic\":{\"ingestionDataSourceSettings\":" ++ kinesis_json ++ "},\"updateMask\":\"ingestionDataSourceSettings\"}");
    try testing.expectEqualStrings("arn:aws:iam::111111111111:role/pubsub", changed.value.ingestion.?.source.?.aws_kinesis.aws_role_arn);
    try testing.expectEqual(types.Ingestion.LogSeverity.info, changed.value.ingestion.?.log_severity);

    var standard = try uploads.update(.{ .ingestion = .clear });
    defer standard.deinit();
    try h.expectRequest(3, .PATCH, path, "{\"topic\":{},\"updateMask\":\"ingestionDataSourceSettings\"}");
    try testing.expectEqual(null, standard.value.ingestion);
    try h.expectRequestCount(4);
}

test "an import topic: what the checks refuse is never sent, and a source production cannot reach is refused in its words when the topic is made" {
    var h: Harness = undefined;
    try h.init(&.{
        // Production's words, 2026-10-12.
        .{ .respond = .{ .status = 403, .body = "{\"error\":{\"code\":403,\"message\":\"Cloud Pub/Sub does not have the necessary permissions settings on the ingestion data source: AccessDenied: Not authorized to perform sts:AssumeRoleWithWebIdentity.\",\"status\":\"PERMISSION_DENIED\"}}" } },
        .{ .respond = .{ .status = 404, .body = "{\"error\":{\"code\":404,\"message\":\"Cloud Pub/Sub encountered a not-found error while trying to connect to the ingestion data source: Bucket \\\"my-uploads\\\" not found for operation OP_TEST_IAM_PERMISSIONS.\",\"status\":\"NOT_FOUND\"}}" } },
        .{ .respond = .{ .status = 404, .body = "{\"error\":{\"code\":404,\"message\":\"Cloud Pub/Sub encountered a not-found error while trying to connect to the ingestion data source: Failed to resolve bootstrap server ns.servicebus.windows.net to an IP.\",\"status\":\"NOT_FOUND\"}}" } },
        .{ .respond = .{ .status = 400, .body = "{\"error\":{\"code\":400,\"message\":\"Cloud Pub/Sub received invalid argument/s for the ingestion data source: Unreachable bootstrap server.\",\"status\":\"INVALID_ARGUMENT\"}}" } },
    }, .{ .token = "t" });
    defer h.deinit();
    const uploads = h.client.topic("uploads");

    try testing.expectError(error.InvalidArgument, uploads.create(.{ .ingestion = .{ .source = .{ .cloud_storage = .{ .bucket = "" } } } }));
    try testing.expectEqualStrings("the import topic's bucket is empty", h.diag.message());
    var no_arn = kinesis_source;
    no_arn.aws_kinesis.stream_arn = "orders";
    try testing.expectError(error.InvalidArgument, uploads.create(.{ .ingestion = .{ .source = no_arn } }));
    try testing.expectEqualStrings("the Kinesis stream ARN does not begin arn:", h.diag.message());
    try testing.expectError(error.InvalidArgument, uploads.update(.{ .ingestion = .{ .set = .{ .source = kinesis_source, .log_severity = .unknown } } }));
    try testing.expectEqualStrings("the log severity is .unknown, which is only ever read", h.diag.message());
    try h.expectRequestCount(0);

    // A role Pub/Sub may not assume, a bucket and a namespace that are
    // not there, and a server it cannot reach: each refuses the create,
    // once.
    try testing.expectError(error.PermissionDenied, uploads.create(.{ .ingestion = .{ .source = kinesis_source } }));
    try testing.expect(std.mem.endsWith(u8, h.diag.message(), "Not authorized to perform sts:AssumeRoleWithWebIdentity."));
    try testing.expectError(error.NotFound, uploads.create(.{ .ingestion = .{ .source = .{ .cloud_storage = .{ .bucket = "my-uploads" } } } }));
    try testing.expectEqualStrings("Cloud Pub/Sub encountered a not-found error while trying to connect to the ingestion data source: Bucket \"my-uploads\" not found for operation OP_TEST_IAM_PERMISSIONS.", h.diag.message());
    try testing.expectError(error.NotFound, uploads.update(.{ .ingestion = .{ .set = .{ .source = .{ .azure_event_hubs = .{
        .resource_group = "rg",
        .namespace = "ns",
        .event_hub = "eh",
        .client_id = "11111111-1111-1111-1111-111111111111",
        .tenant_id = "22222222-2222-2222-2222-222222222222",
        .subscription_id = "33333333-3333-3333-3333-333333333333",
        .gcp_service_account = import_account,
    } } } } }));
    try testing.expect(std.mem.endsWith(u8, h.diag.message(), "Failed to resolve bootstrap server ns.servicebus.windows.net to an IP."));
    try testing.expectError(error.InvalidArgument, uploads.create(.{ .ingestion = .{ .source = .{ .confluent_cloud = .{
        .bootstrap_server = "pkc-xxxx.us-east-1.aws.confluent.cloud:9092",
        .cluster_id = "lkc-xxxx",
        .topic = "orders",
        .identity_pool_id = "pool-xxxx",
        .gcp_service_account = import_account,
    } } } }));
    try testing.expect(std.mem.endsWith(u8, h.diag.message(), "Unreachable bootstrap server."));
    try h.expectRequestCount(4);
}

fn importTopicAllocations(gpa: std.mem.Allocator) !void {
    var fake: test_util.FakeTransport = .init(testing.allocator, &.{
        .{ .respond = .{ .body = "{\"name\":\"projects/p/topics/uploads\",\"ingestionDataSourceSettings\":{\"cloudStorage\":{\"state\":\"ACTIVE\",\"bucket\":\"my-uploads\",\"textFormat\":{\"delimiter\":\"\\t\"},\"minimumObjectCreateTime\":\"2026-10-12T02:33:53.500Z\",\"matchGlob\":\"logs/**.txt\"},\"platformLogsSettings\":{\"severity\":\"WARNING\"}}}" } },
        .{ .respond = .{ .body = "{\"name\":\"projects/p/topics/uploads\",\"ingestionDataSourceSettings\":{\"awsKinesis\":{\"state\":\"KINESIS_PERMISSION_DENIED\",\"streamArn\":\"arn:aws:kinesis:us-east-1:111111111111:stream/or\\u0064ers\",\"consumerArn\":\"arn:c\",\"awsRoleArn\":\"arn:r\",\"gcpServiceAccount\":\"importer@my-project.iam.gserviceaccount.com\"}}}" } },
        .{ .respond = .{ .body = "{\"name\":\"projects/p/topics/uploads\",\"ingestionDataSourceSettings\":{\"awsKinesis\":{\"streamArn\":\"arn:s\",\"consumerArn\":\"arn:c\",\"awsRoleArn\":\"arn:r\",\"gcpServiceAccount\":\"importer@my-project.iam.gserviceaccount.com\"}}}" } },
        .{ .respond = .{ .body = "{\"name\":\"projects/p/topics/uploads\"}" } },
    });
    defer fake.deinit();
    var clock: test_util.FakeClock = .{};
    var client = try Client.init(gpa, clock.io(), .{
        .project_id = "p",
        .endpoint = .{ .url = "localhost:8085", .emulator = true },
        .transport = fake.transport(),
    });
    defer client.deinit();
    const uploads = client.topic("uploads");
    var created = try uploads.create(.{ .ingestion = .{
        .source = .{ .cloud_storage = .{
            .bucket = "my-uploads",
            .format = .{ .text = .{ .delimiter = "\t" } },
            .minimum_object_create_time = .{ .nanoseconds = 1_791_772_433_500_000_000 },
            .match_glob = "logs/**.txt",
        } },
        .log_severity = .warning,
    } });
    created.deinit();
    var read = try uploads.get();
    read.deinit();
    var changed = try uploads.update(.{ .ingestion = .{ .set = .{ .source = kinesis_source } } });
    changed.deinit();
    var standard = try uploads.update(.{ .ingestion = .clear });
    standard.deinit();
    try testing.expectEqual(4, fake.requests.items.len);
}

test "allocation failures: an import topic on create, as read, and in an update" {
    try testing.checkAllAllocationFailures(test_util.no_grow_allocator, importTopicAllocations, .{});
}
