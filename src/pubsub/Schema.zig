//! A schema handle: a client pointer and a short id such as "order-v1".
//! Making one sends nothing. It borrows both, so it must not outlive the
//! client or the memory behind `id`.
//!
//! A schema is a contract Pub/Sub holds for a topic: an Avro or Protocol
//! Buffer definition, stored in the project under a name. A topic that
//! names one refuses a publish whose message does not fit it, so every
//! subscriber gets messages it can decode. This client writes no Avro and
//! no Protocol Buffers: the caller's own encoder makes a message's bytes,
//! and `validateMessage` asks Pub/Sub whether they fit.
//!
//! The emulator serves Avro schemas, and answers every call that names a
//! Protocol Buffer schema `error.Unimplemented`.

const Schema = @This();

const std = @import("std");
const core = @import("core");

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
/// The client builds the full name, `projects/{project}/schemas/{id}`.
id: []const u8,

/// Stores `definition` as the schema's first revision. Pub/Sub parses it,
/// and a definition that does not parse is `error.InvalidArgument` in its
/// words. If a lost first attempt already created it, the retry reports
/// `error.AlreadyExists`. The id, the type and the definition's size and
/// UTF-8 are checked first. Needs `pubsub.schemas.create` on the project.
pub fn create(self: Schema, definition: types.SchemaDefinition) Error!Owned(types.SchemaInfo) {
    const c = self.client;
    rpc.begin(c);
    try rpc.checkId(c, "schema", self.id);
    try validate.schemaDefinition(definition, c.diagnostics);
    var scratch: std.heap.ArenaAllocator = .init(c.gpa);
    defer scratch.deinit();
    const a = scratch.allocator();
    const path = try url.schemaCreatePath(a, c.project_id, self.id);
    const body = try codec.encodeSchema(a, definition);
    return fetch(c, .{ .method = .POST, .path = path, .body = body });
}

/// The schema's latest revision, or the one `options.revision_id` names,
/// with its definition unless `options.view` is `.basic`. A schema or a
/// revision that is not there is `error.NotFound`. Needs
/// `pubsub.schemas.get`.
pub fn get(self: Schema, options: types.SchemaGetOptions) Error!Owned(types.SchemaInfo) {
    const c = self.client;
    rpc.begin(c);
    try rpc.checkId(c, "schema", self.id);
    if (options.revision_id) |revision| try validate.revisionId(revision, c.diagnostics);
    var scratch: std.heap.ArenaAllocator = .init(c.gpa);
    defer scratch.deinit();
    const view = switch (options.view) {
        .basic => "?view=BASIC",
        .full => "?view=FULL",
    };
    const path = try url.schemaPath(scratch.allocator(), c.project_id, self.id, options.revision_id, view);
    return fetch(c, .{ .method = .GET, .path = path });
}

/// Deletes the schema and every revision of it. A topic that named it
/// then reads `_deleted-schema_` and refuses every publish, and a schema
/// made again under the id is not the one the topic had: take the schema
/// off its topics first. If a lost first attempt already deleted it, the
/// retry reports `error.NotFound`. Needs `pubsub.schemas.delete`.
pub fn delete(self: Schema) Error!void {
    const c = self.client;
    rpc.begin(c);
    try rpc.checkId(c, "schema", self.id);
    var scratch: std.heap.ArenaAllocator = .init(c.gpa);
    defer scratch.deinit();
    const path = try url.schemaPath(scratch.allocator(), c.project_id, self.id, null, "");
    return rpc.executeDiscard(c, .{ .method = .DELETE, .path = path });
}

/// Asks Pub/Sub whether `data`, read in `encoding`, fits the schema: its
/// latest revision, or the one `revision_id` names. Nothing is published.
/// A message that does not fit is `error.InvalidArgument` in the server's
/// words, as a publish of it to a topic with this schema would be. Needs
/// `pubsub.schemas.validate` on the project.
pub fn validateMessage(
    self: Schema,
    data: []const u8,
    encoding: types.SchemaEncoding,
    revision_id: ?[]const u8,
) Error!void {
    const c = self.client;
    rpc.begin(c);
    try rpc.checkId(c, "schema", self.id);
    try validate.schemaEncoding(encoding, c.diagnostics);
    if (revision_id) |revision| try validate.revisionId(revision, c.diagnostics);
    var scratch: std.heap.ArenaAllocator = .init(c.gpa);
    defer scratch.deinit();
    const a = scratch.allocator();
    const path = try url.schemasMethodPath(a, c.project_id, ":validateMessage");
    var name = try url.resourceName(a, c.project_id, .schemas, self.id);
    if (revision_id) |revision| name = try std.mem.concat(a, u8, &.{ name, "@", revision });
    const body = try codec.encodeValidateMessage(a, .{ .name = name }, data, encoding);
    return rpc.executeDiscard(c, .{ .method = .POST, .path = path, .body = body });
}

/// The schema's IAM policy, asked for as version 3. Needs
/// `pubsub.schemas.getIamPolicy`. The emulator serves no IAM call on a
/// schema, and answers this one `error.InvalidArgument`.
pub fn iamPolicy(self: Schema) Error!Owned(core.iam.Policy) {
    const r = try self.iamResource();
    return r.readPolicy();
}

/// Writes `policy` as the schema's, whole, and returns it as stored, as
/// `Topic.setIamPolicy` does. Needs `pubsub.schemas.setIamPolicy`.
pub fn setIamPolicy(self: Schema, policy: core.iam.Policy) Error!Owned(core.iam.Policy) {
    const r = try self.iamResource();
    return iam.set(r, policy);
}

/// Grants `member` the role `role` on the schema, unless it holds it
/// already without a condition, as `Topic.addIamBinding` does. Naming a
/// schema in a topic needs `pubsub.schemas.attach` on it, which
/// `roles/pubsub.editor` carries. Needs `pubsub.schemas.getIamPolicy` and
/// `setIamPolicy`.
pub fn addIamBinding(self: Schema, role: []const u8, member: []const u8) Error!Owned(core.iam.Policy) {
    const r = try self.iamResource();
    return iam.change(r, .{ .grant = .{ .role = role, .member = member } });
}

/// Takes `member` out of the schema's binding of `role` without a
/// condition, unless it is not there, as `Topic.removeIamBinding` does.
pub fn removeIamBinding(self: Schema, role: []const u8, member: []const u8) Error!Owned(core.iam.Policy) {
    const r = try self.iamResource();
    return iam.change(r, .{ .revoke = .{ .role = role, .member = member } });
}

/// The permissions the caller holds on the schema, of `permissions`, as
/// `Topic.testIamPermissions` answers them: such as
/// `pubsub.schemas.attach`.
pub fn testIamPermissions(self: Schema, permissions: []const []const u8) Error!Owned([]const []const u8) {
    const r = try self.iamResource();
    return iam.testPermissions(r, permissions);
}

fn iamResource(self: Schema) Error!iam.Resource {
    const c = self.client;
    rpc.begin(c);
    try rpc.checkId(c, "schema", self.id);
    return .{ .client = c, .collection = .schemas, .id = self.id };
}

fn fetch(c: *Client, call: rpc.Call) Error!Owned(types.SchemaInfo) {
    var result: Owned(types.SchemaInfo) = try .init(c.gpa);
    errdefer result.deinit();
    const body = try rpc.execute(c, result.arena, call);
    result.value = codec.decodeSchema(result.arena.allocator(), body) catch |err|
        return rpc.decodeFailed(c, err, "schema");
    return result;
}

const testing = std.testing;
const test_util = @import("test_util.zig");
const Harness = test_util.Harness;

const avro: types.SchemaDefinition = .{ .type = .avro, .definition = "{\"type\":\"record\",\"name\":\"M\",\"fields\":[]}" };

/// A schema as the emulator answered one on 2026-10-11, shortened.
const stored =
    \\{"name":"projects/p/schemas/order-v1","type":"AVRO","definition":"{\"type\":\"record\",\"name\":\"M\",\"fields\":[]}","revisionId":"1b46a16a","revisionCreateTime":"1970-01-17T11:51:58.663505750Z"}
;
const stored_basic =
    \\{"name":"projects/p/schemas/order-v1","type":"AVRO","revisionId":"1b46a16a","revisionCreateTime":"1970-01-17T11:51:58.663505750Z"}
;

test "golden: create, get in both views and of one revision, and delete send the right requests" {
    var h: Harness = undefined;
    try h.init(&.{
        .{ .respond = .{ .body = stored } },
        .{ .respond = .{ .body = stored } },
        .{ .respond = .{ .body = stored_basic } },
        .{ .respond = .{ .body = stored } },
        .{ .respond = .{ .body = "{}" } },
    }, .{});
    defer h.deinit();
    const order = h.client.schema("order-v1");
    const base = "http://localhost:8085/v1/projects/p/schemas";

    var created = try order.create(avro);
    defer created.deinit();
    try h.expectRequest(0, .POST, base ++ "?schemaId=order-v1",
        \\{"type":"AVRO","definition":"{\"type\":\"record\",\"name\":\"M\",\"fields\":[]}"}
    );
    try testing.expectEqualStrings("projects/p/schemas/order-v1", created.value.name);
    try testing.expectEqual(types.SchemaType.avro, created.value.type);
    try testing.expectEqualStrings(avro.definition, created.value.definition);
    try testing.expectEqualStrings("1b46a16a", created.value.revision_id);
    try testing.expectEqual(try core.timestamp.parse("1970-01-17T11:51:58.663505750Z"), created.value.revision_create_time.?);

    // The view is always said, so Google's two texts on its default agree.
    var got = try order.get(.{});
    defer got.deinit();
    try h.expectRequest(1, .GET, base ++ "/order-v1?view=FULL", null);
    try testing.expectEqualStrings(avro.definition, got.value.definition);

    var basic = try order.get(.{ .view = .basic });
    defer basic.deinit();
    try h.expectRequest(2, .GET, base ++ "/order-v1?view=BASIC", null);
    try testing.expectEqualStrings("", basic.value.definition);
    try testing.expectEqualStrings("1b46a16a", basic.value.revision_id);

    var one = try order.get(.{ .revision_id = "1b46a16a" });
    defer one.deinit();
    try h.expectRequest(3, .GET, base ++ "/order-v1@1b46a16a?view=FULL", null);

    try order.delete();
    try h.expectRequest(4, .DELETE, base ++ "/order-v1", null);
    try h.expectRequestCount(5);
}

test "golden: validateMessage names the schema in full, a revision after an @, and sends the message as base64" {
    var h: Harness = undefined;
    try h.init(&.{
        .{ .respond = .{ .body = "{}" } },
        .{ .respond = .{ .body = "{}" } },
        // Nothing at all is an answer too.
        .{ .respond = .{ .body = "" } },
    }, .{ .project_id = "example.com:proj" });
    defer h.deinit();
    const order = h.client.schema("a%41b");
    const path = "http://localhost:8085/v1/projects/example.com:proj/schemas:validateMessage";

    try order.validateMessage("{\"name\":\"a\"}", .json, null);
    // The name in a body is not encoded, as no name in a body is.
    try h.expectRequest(0, .POST, path,
        \\{"name":"projects/example.com:proj/schemas/a%41b","message":"eyJuYW1lIjoiYSJ9","encoding":"JSON"}
    );
    try order.validateMessage("\x02a\x02", .binary, "c7cfa2a8");
    try h.expectRequest(1, .POST, path,
        \\{"name":"projects/example.com:proj/schemas/a%41b@c7cfa2a8","message":"AmEC","encoding":"BINARY"}
    );
    try order.validateMessage("", .json, null);
    try h.expectRequestCount(3);
}

test "a bad id, definition, revision or encoding fails before any request" {
    var h: Harness = undefined;
    try h.init(&.{}, .{});
    defer h.deinit();

    try testing.expectError(error.InvalidResourceId, h.client.schema("go").get(.{}));
    try testing.expect(std.mem.indexOf(u8, h.diag.message(), "invalid schema id") != null);
    try testing.expectError(error.InvalidResourceId, h.client.schema("googschema").create(avro));
    try testing.expectError(error.InvalidResourceId, h.client.schema("a/b").delete());
    try testing.expectError(error.InvalidResourceId, h.client.schema("1st").validateMessage("{}", .json, null));
    try testing.expectError(error.InvalidResourceId, h.client.schema("x y z").iamPolicy());
    // A revision is never part of the id: the `@` is the client's to write.
    try testing.expectError(error.InvalidResourceId, h.client.schema("order-v1@c7cfa2a8").get(.{}));

    const order = h.client.schema("order-v1");
    try testing.expectError(error.InvalidArgument, order.create(.{ .type = .avro, .definition = "" }));
    try testing.expectEqualStrings("the schema definition is empty", h.diag.message());
    try testing.expectError(error.InvalidArgument, order.create(.{ .type = .unknown, .definition = "{}" }));
    try testing.expectError(error.InvalidArgument, order.create(.{ .type = .avro, .definition = "\xff" }));
    try testing.expectEqualStrings("the schema definition is not valid UTF-8", h.diag.message());

    // A revision that would make the path another call's.
    try testing.expectError(error.InvalidArgument, order.get(.{ .revision_id = "c7cfa2a8:rollback" }));
    try testing.expectError(error.InvalidArgument, order.get(.{ .revision_id = "" }));
    try testing.expectError(error.InvalidArgument, order.validateMessage("{}", .json, "a@b"));
    try testing.expectError(error.InvalidArgument, order.validateMessage("{}", .unknown, null));
    try testing.expectEqualStrings("the encoding is .unknown, which is only ever read", h.diag.message());
    try h.expectRequestCount(0);
}

test "refusals: an id taken, a schema or a revision that is not there, what does not parse or fit, and what the emulator has not got" {
    var h: Harness = undefined;
    try h.init(&.{
        // The emulator's words, 2026-10-11.
        .{ .respond = .{ .status = 409, .body = "{\"error\":{\"code\":409,\"message\":\"Schema already exists\",\"status\":\"ALREADY_EXISTS\"}}" } },
        .{ .respond = .{ .status = 400, .body = "{\"error\":{\"code\":400,\"message\":\"Could not parse schema definition\",\"status\":\"INVALID_ARGUMENT\"}}" } },
        .{ .respond = .{ .status = 501, .body = "{\"error\":{\"code\":501,\"message\":\"Protocol buffer support not implemented in emulator\",\"status\":\"UNIMPLEMENTED\"}}" } },
        .{ .respond = .{ .status = 404, .body = "{\"error\":{\"code\":404,\"message\":\"Schema not found\",\"status\":\"NOT_FOUND\"}}" } },
        .{ .respond = .{ .status = 404, .body = "{\"error\":{\"code\":404,\"message\":\"Schema revision not found\",\"status\":\"NOT_FOUND\"}}" } },
        .{ .respond = .{ .status = 404, .body = "{\"error\":{\"code\":404,\"message\":\"Schema not found\",\"status\":\"NOT_FOUND\"}}" } },
        .{ .respond = .{ .status = 400, .body = "{\"error\":{\"code\":400,\"message\":\"Could not parse JSON Avro message\",\"status\":\"INVALID_ARGUMENT\"}}" } },
        .{ .respond = .{ .status = 400, .body = "{\"error\":{\"code\":400,\"message\":\"Could not parse binary Avro message\",\"status\":\"INVALID_ARGUMENT\"}}" } },
    }, .{});
    defer h.deinit();
    const order = h.client.schema("order-v1");

    try testing.expectError(error.AlreadyExists, order.create(avro));
    try testing.expectEqual(409, h.diag.http_status);
    try testing.expectEqualStrings("Schema already exists", h.diag.message());
    try testing.expectError(error.InvalidArgument, order.create(.{ .type = .avro, .definition = "{nope" }));
    try testing.expectEqualStrings("Could not parse schema definition", h.diag.message());
    try testing.expectError(error.Unimplemented, order.create(.{ .type = .protocol_buffer, .definition = "message M {}" }));
    try testing.expectEqualStrings("Protocol buffer support not implemented in emulator", h.diag.message());
    try testing.expectError(error.NotFound, order.get(.{}));
    try testing.expectError(error.NotFound, order.get(.{ .revision_id = "deadbeef" }));
    try testing.expectEqualStrings("Schema revision not found", h.diag.message());
    try testing.expectError(error.NotFound, order.delete());
    try testing.expectError(error.InvalidArgument, order.validateMessage("{\"age\":\"one\"}", .json, null));
    try testing.expectEqualStrings("Could not parse JSON Avro message", h.diag.message());
    try testing.expectError(error.InvalidArgument, order.validateMessage("\xff\xff\xff", .binary, null));
    // None of them is an answer a second attempt would change.
    try h.expectRequestCount(8);
}

test "a create whose first answer is lost is sent again, and the id it took is reported as taken" {
    var h: Harness = undefined;
    try h.init(&.{
        .{ .fail = error.ConnectionResetByPeer },
        .{ .respond = .{ .status = 409, .body = "{\"error\":{\"code\":409,\"message\":\"Schema already exists\",\"status\":\"ALREADY_EXISTS\"}}" } },
        .{ .respond = .{ .status = 503, .body = "{\"error\":{\"code\":503,\"message\":\"try again\",\"status\":\"UNAVAILABLE\"}}" } },
        .{ .respond = .{ .body = "{}" } },
    }, .{});
    defer h.deinit();
    const order = h.client.schema("order-v1");
    try testing.expectError(error.AlreadyExists, order.create(avro));
    try h.expectRequestCount(2);
    // A check changes nothing, so it is simply asked again.
    try order.validateMessage("{}", .json, null);
    try h.expectRequestCount(4);
}

test "an answer that is no schema is InvalidResponse, and says what it was not" {
    var h: Harness = undefined;
    try h.init(&.{
        .{ .respond = .{ .body = "{\"type\":\"AVRO\"}" } },
        .{ .respond = .{ .body = "{\"name\":\"projects/p/schemas/order-v1\",\"revisionCreateTime\":\"soon\"}" } },
    }, .{});
    defer h.deinit();
    try testing.expectError(error.InvalidResponse, h.client.schema("order-v1").get(.{}));
    try testing.expectEqualStrings("the schema response could not be decoded", h.diag.message());
    try testing.expectError(error.InvalidResponse, h.client.schema("order-v1").create(avro));
}

test "IAM on a schema: read, grant, revoke and test, on the paths Pub/Sub serves them" {
    const member = "serviceAccount:publisher@p.iam.gserviceaccount.com";
    const granted_body = "{\"version\":1,\"etag\":\"BwX1\",\"bindings\":[{\"role\":\"roles/pubsub.viewer\",\"members\":[\"" ++ member ++ "\"]}]}";
    var h: Harness = undefined;
    try h.init(&.{
        .{ .respond = .{ .body = "{\"etag\":\"ACAB\"}" } },
        .{ .respond = .{ .body = "{\"etag\":\"ACAB\"}" } },
        .{ .respond = .{ .body = granted_body } },
        .{ .respond = .{ .body = granted_body } },
        .{ .respond = .{ .body = "{\"version\":1,\"etag\":\"BwX2\"}" } },
        .{ .respond = .{ .body = "{\"permissions\":[\"pubsub.schemas.attach\"]}" } },
        .{ .respond = .{ .body = "{\"version\":1,\"etag\":\"BwX3\"}" } },
        // The emulator's words for the read, 2026-10-11.
        .{ .respond = .{ .status = 400, .body = "{\"error\":{\"code\":400,\"message\":\"Invalid [schemas] name: (name=projects/p/schemas/order-v1:getIamPolicy)\",\"status\":\"INVALID_ARGUMENT\"}}" } },
    }, .{});
    defer h.deinit();
    const order = h.client.schema("order-v1");
    const base = "http://localhost:8085/v1/projects/p/schemas/order-v1";

    var fresh = try order.iamPolicy();
    defer fresh.deinit();
    try testing.expectEqualStrings("ACAB", fresh.value.etag.?);
    try h.expectRequest(0, .GET, base ++ ":getIamPolicy?options.requestedPolicyVersion=3", null);

    // Who may read the schema, as a subscriber in another project must.
    var granted = try order.addIamBinding("roles/pubsub.viewer", member);
    defer granted.deinit();
    try testing.expect(granted.value.grants("roles/pubsub.viewer", member));
    try h.expectRequest(2, .POST, base ++ ":setIamPolicy",
        \\{"policy":{"version":1,"etag":"ACAB","bindings":[{"role":"roles/pubsub.viewer","members":["serviceAccount:publisher@p.iam.gserviceaccount.com"]}]}}
    );

    var revoked = try order.removeIamBinding("roles/pubsub.viewer", member);
    defer revoked.deinit();
    try testing.expect(!revoked.value.grants("roles/pubsub.viewer", member));
    try h.expectRequest(4, .POST, base ++ ":setIamPolicy",
        \\{"policy":{"version":1,"etag":"BwX1","bindings":[]}}
    );

    var held = try order.testIamPermissions(&.{ "pubsub.schemas.attach", "pubsub.schemas.delete" });
    defer held.deinit();
    try testing.expectEqual(1, held.value.len);
    try testing.expectEqualStrings("pubsub.schemas.attach", held.value[0]);
    try h.expectRequest(5, .POST, base ++ ":testIamPermissions",
        \\{"permissions":["pubsub.schemas.attach","pubsub.schemas.delete"]}
    );

    var written = try order.setIamPolicy(.{ .etag = "BwX2", .bindings = &.{} });
    defer written.deinit();
    try testing.expectEqualStrings("BwX3", written.value.etag.?);

    try testing.expectError(error.InvalidArgument, order.iamPolicy());
    try h.expectRequestCount(8);
}

/// No id and revision the checks pass can build a path that reads as
/// another call: the path is the collection, the id as one segment, an
/// `@`, the revision as one more, and the suffix, with no `:`, `?`, `#`
/// or `/` anywhere the client did not write one.
fn pathProperty(_: void, input: []const u8) !void {
    var g: test_util.ByteGen = .init(input);
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    // Mostly what an id and a revision may hold, with what they may not
    // mixed in, and raw bytes now and then.
    var id_buf: [24]u8 = undefined;
    var revision_buf: [12]u8 = undefined;
    const id = if (g.intRange(u8, 0, 7) == 0)
        g.take(g.intRange(u8, 0, 24))
    else
        drawFrom(&g, &id_buf, "abcdefghXYZabcdefgh0123456789-_.~+%@:/ ");
    const revision = if (g.intRange(u8, 0, 7) == 0)
        g.take(g.intRange(u8, 0, 12))
    else
        drawFrom(&g, &revision_buf, "0123456789abcdef0123456789abcdefAZ-_.~+%@:/?# ");
    const suffix: []const u8 = switch (g.intRange(u8, 0, 3)) {
        0 => "",
        1 => "?view=FULL",
        2 => ":rollback",
        else => ":deleteRevision",
    };
    const id_ok = validate.isResourceId(id);
    const revision_ok = validate.isRevisionId(revision);

    var d: core.Diagnostics = .{};
    const accepted = if (validate.revisionId(revision, &d)) |_| true else |_| false;
    try testing.expectEqual(revision_ok, accepted);
    if (!id_ok or !revision_ok) return;

    const path = try url.schemaPath(a, "p", id, revision, suffix);
    const prefix = "/v1/projects/p/schemas/";
    try testing.expect(std.mem.startsWith(u8, path, prefix));
    try testing.expect(std.mem.endsWith(u8, path, suffix));
    const middle = path[prefix.len .. path.len - suffix.len];
    // One `@`, and nothing a server would split on in either half.
    const at = std.mem.indexOfScalar(u8, middle, '@').?;
    try testing.expectEqual(at, std.mem.lastIndexOfScalar(u8, middle, '@').?);
    try testing.expect(std.mem.indexOfAny(u8, middle, "/?#:") == null);
    // Each half decodes to what it was: a `%` is the one byte of either
    // that is encoded.
    try testing.expectEqualStrings(id, std.Uri.percentDecodeInPlace(try a.dupe(u8, middle[0..at])));
    try testing.expectEqualStrings(revision, std.Uri.percentDecodeInPlace(try a.dupe(u8, middle[at + 1 ..])));
}

fn drawFrom(g: *test_util.ByteGen, buf: []u8, alphabet: []const u8) []const u8 {
    const n = g.intRange(u8, 0, @intCast(buf.len));
    for (buf[0..n]) |*c| c.* = alphabet[g.intRange(u8, 0, @intCast(alphabet.len - 1))];
    return buf[0..n];
}

test "fuzz schema paths: an id and a revision the checks pass never build another call's path" {
    try test_util.fuzzBytes({}, pathProperty, .{
        .corpus = &.{
            "",
            // An id and a revision that pass, from each alphabet.
            "\x01\x08\x00\x01\x02\x1e\x0b\x14\x15\x16\x01\x08\x0c\x07\x0c\x0f\x0a\x02\x0a\x08\x02",
            // An id with a `%`, and a revision with a `:`.
            "\x01\x05\x00\x23\x14\x15\x01\x01\x04\x0c\x07\x29\x0a\x03",
            // Raw bytes for both.
            "\x00\x06abc@de\x00\x03a/b\x00",
            "\xff\xff\xff\xff\xff\xff\xff\xff\xff\xff\xff\xff\xff\xff\xff\xff\xff\xff\xff\xff",
        },
    });
}

fn schemaAllocations(gpa: std.mem.Allocator) !void {
    var fake: test_util.FakeTransport = .init(testing.allocator, &.{
        .{ .respond = .{ .status = 503, .body = "{\"error\":{\"code\":503,\"message\":\"try again\",\"status\":\"UNAVAILABLE\"}}" } },
        .{ .respond = .{ .body = stored } },
        .{ .respond = .{ .body = stored } },
        .{ .respond = .{ .body = stored_basic } },
        .{ .respond = .{ .body = "{}" } },
        .{ .respond = .{ .body = "{\"schemas\":[" ++ stored ++ "," ++ stored_basic ++ "],\"nextPageToken\":\"n\"}" } },
        .{ .respond = .{ .body = "{}" } },
        .{ .respond = .{ .body = "{}" } },
        .{ .respond = .{ .body = "{}" } },
    });
    defer fake.deinit();
    var clock: test_util.FakeClock = .{};
    var client = try Client.init(gpa, clock.io(), .{
        .project_id = "p",
        .endpoint = .{ .url = "localhost:8085", .emulator = true },
        .transport = fake.transport(),
    });
    defer client.deinit();
    const order = client.schema("order-v1");
    var created = try order.create(avro); // after one retry
    created.deinit();
    var got = try order.get(.{});
    got.deinit();
    var one = try order.get(.{ .revision_id = "1b46a16a", .view = .basic });
    one.deinit();
    try order.validateMessage("{\"name\":\"a\"}", .json, "1b46a16a");
    var page = try client.listSchemas(.{ .view = .full, .page = .{ .page_token = "m" } });
    page.deinit();
    try client.validateSchema(avro);
    try client.validateMessage(avro, "\x02a\x02", .binary);
    try order.delete();
    // The calls above used the whole script, so none was skipped.
    try testing.expectEqual(9, fake.requests.items.len);
}

test "allocation failures: every schema call fails cleanly at each allocation" {
    try testing.checkAllAllocationFailures(test_util.no_grow_allocator, schemaAllocations, .{});
}
