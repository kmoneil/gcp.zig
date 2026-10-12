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
//! A schema is never changed, only revised: `commit` adds a revision,
//! which a read then gives, and the earlier ones stay, each under an id
//! the server chose, until `deleteRevision` takes one away. A schema holds
//! 20. A topic takes a message that fits any revision in the range its
//! settings allow, so one that was valid before a commit stays valid.
//!
//! The emulator serves Avro schemas, and answers every call that names a
//! Protocol Buffer schema `error.Unimplemented`.

const Schema = @This();

const std = @import("std");
const core = @import("core");

const Client = @import("Client.zig");
const codec = @import("codec.zig");
const iam = @import("iam.zig");
const logging = @import("logging.zig");
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

/// Commits `definition` as the schema's next revision, the one a read then
/// gives. Pub/Sub checks it against the revisions before it and refuses
/// one that is not compatible with them, or of another type, as
/// `error.FailedPrecondition`; the emulator checks only that it parses.
/// A schema holds 20 revisions, and a 21st is `error.ResourceExhausted`,
/// which the client, as for any quota, tries a few times before giving.
///
/// A repeat of a commit that landed would spend a second of the schema's
/// 20 revisions, so a failed attempt is not simply sent again. The latest
/// revision is read first, and if it already holds this type and
/// definition it is the answer: the attempt landed, and only its answer
/// was lost. That read needs `pubsub.schemas.get`; if it fails, the
/// commit's own failure is returned, and the diagnostics say that it may
/// have landed. Needs `pubsub.schemas.commit`.
pub fn commit(self: Schema, definition: types.SchemaDefinition) Error!Owned(types.SchemaInfo) {
    const c = self.client;
    rpc.begin(c);
    try rpc.checkId(c, "schema", self.id);
    try validate.schemaDefinition(definition, c.diagnostics);
    var scratch: std.heap.ArenaAllocator = .init(c.gpa);
    defer scratch.deinit();
    const a = scratch.allocator();
    const path = try url.schemaPath(a, c.project_id, self.id, null, ":commit");
    const name = try url.resourceName(a, c.project_id, .schemas, self.id);
    const body = try codec.encodeCommit(a, name, definition);
    return self.revise(.{ .method = .POST, .path = path, .body = body, .retry = false }, .{ .commit = definition });
}

/// Makes a new revision that holds what the revision `revision_id` held,
/// and returns it: the schema's latest is then that definition again, under
/// a new id, and the revisions in between stay. A revision that is not
/// there is `error.NotFound`, and production refuses a rollback to the
/// latest revision itself, where the emulator makes one more of it.
///
/// As with `commit`, a failed attempt is not simply sent again: the
/// revision rolled back to and the latest one are read, and if the latest
/// already holds what the other holds, it is the answer. Needs
/// `pubsub.schemas.rollback`, and `pubsub.schemas.get` for those reads.
pub fn rollback(self: Schema, revision_id: []const u8) Error!Owned(types.SchemaInfo) {
    const c = self.client;
    rpc.begin(c);
    try rpc.checkId(c, "schema", self.id);
    try validate.revisionId(revision_id, c.diagnostics);
    var scratch: std.heap.ArenaAllocator = .init(c.gpa);
    defer scratch.deinit();
    const a = scratch.allocator();
    const path = try url.schemaPath(a, c.project_id, self.id, null, ":rollback");
    const body = try codec.encodeRollback(a, revision_id);
    return self.revise(.{ .method = .POST, .path = path, .body = body, .retry = false }, .{ .rollback = revision_id });
}

/// Deletes one revision. The others stay, and a topic whose range began
/// or ended at this one then uses the next one inward. A schema's only
/// revision cannot be deleted, which production says as
/// `error.FailedPrecondition` and the emulator as
/// `error.InvalidArgument`: delete the schema. If a lost first attempt
/// already deleted it, the retry reports `error.NotFound`. Needs
/// `pubsub.schemas.delete`.
pub fn deleteRevision(self: Schema, revision_id: []const u8) Error!void {
    const c = self.client;
    rpc.begin(c);
    try rpc.checkId(c, "schema", self.id);
    try validate.revisionId(revision_id, c.diagnostics);
    var scratch: std.heap.ArenaAllocator = .init(c.gpa);
    defer scratch.deinit();
    const path = try url.schemaPath(scratch.allocator(), c.project_id, self.id, revision_id, ":deleteRevision");
    return rpc.executeDiscard(c, .{ .method = .DELETE, .path = path });
}

/// One page of the schema's revisions, without their definitions unless
/// `options.view` is `.full`. Production lists the newest first, and the
/// emulator the oldest. Needs `pubsub.schemas.listRevisions`.
pub fn listRevisions(self: Schema, options: types.SchemaListOptions) Error!Owned(types.SchemaPage) {
    const c = self.client;
    rpc.begin(c);
    try rpc.checkId(c, "schema", self.id);
    var scratch: std.heap.ArenaAllocator = .init(c.gpa);
    defer scratch.deinit();
    const path = try url.schemaRevisionsPath(
        scratch.allocator(),
        c.project_id,
        self.id,
        codec.schemaViewName(options.view),
        options.page.page_size,
        options.page.page_token,
    );
    var result: Owned(types.SchemaPage) = try .init(c.gpa);
    errdefer result.deinit();
    const body = try rpc.execute(c, result.arena, .{ .method = .GET, .path = path });
    result.value = codec.decodeSchemaPage(result.arena.allocator(), body) catch |err|
        return rpc.decodeFailed(c, err, "schema revision list");
    return result;
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

/// What a call that makes a revision asks for: a definition to commit, or
/// the id of a revision to hold again.
const Revision = union(enum) {
    commit: types.SchemaDefinition,
    rollback: []const u8,
};

/// Sends a call that makes a revision. The engine's retry is off for it,
/// and this loop decides what a failure means: sent again blindly, a call
/// that landed would make a second revision.
fn revise(self: Schema, call: rpc.Call, what: Revision) Error!Owned(types.SchemaInfo) {
    const c = self.client;
    var attempt: u32 = 0;
    while (true) {
        attempt += 1;
        return fetch(c, call) catch |err| {
            if (!core.isRetryable(err) or attempt >= c.retry.max_attempts) return err;
            // A refusal for quota is an answer: the attempt did not land,
            // and a latest revision that happens to hold the same
            // definition would not make it one that did.
            if (err != error.ResourceExhausted) {
                if (try self.landed(what, err)) |latest| return latest;
            }
            const delay_ms = c.retry.backoffMs(attempt, core.rpc.entropy(c.io));
            logging.warn("revising schema {s} failed with {t}; trying again in {d} ms", .{ self.id, err, delay_ms });
            try c.io.sleep(.fromMilliseconds(delay_ms), .awake);
            continue;
        };
    }
}

/// An attempt to make a revision failed in a way a second might mend, so
/// it may have landed with its answer lost. A read says whether it did:
/// the latest revision then holds what was asked for, and is the answer.
/// Null when it does not, and the attempt is worth making again.
fn landed(self: Schema, what: Revision, failure: Error) Error!?Owned(types.SchemaInfo) {
    // The reads begin calls of their own and take the diagnostics over,
    // and whatever follows, an answer or another attempt, sets them anew.
    var held: ?Owned(types.SchemaInfo) = null;
    defer if (held) |*h| h.deinit();
    const wanted: types.SchemaDefinition = switch (what) {
        .commit => |definition| definition,
        .rollback => |revision_id| target: {
            held = self.get(.{ .revision_id = revision_id }) catch |err| return self.unsettled(err, failure);
            break :target .{ .type = held.?.value.type, .definition = held.?.value.definition };
        },
    };
    var latest = self.get(.{}) catch |err| return self.unsettled(err, failure);
    if (latest.value.type == wanted.type and std.mem.eql(u8, latest.value.definition, wanted.definition)) return latest;
    latest.deinit();
    return null;
}

/// The read that would have settled a failed attempt failed itself. That
/// the schema or the revision is not there is an answer, and the read's
/// own; anything else leaves the attempt's failure standing.
fn unsettled(self: Schema, read_error: Error, failure: Error) Error {
    switch (read_error) {
        error.OutOfMemory, error.Canceled, error.NotFound => return read_error,
        else => {},
    }
    if (self.client.diagnostics) |d| d.print(
        "making a revision failed, and reading the schema to see whether the attempt landed failed with {t}: it may have landed",
        .{read_error},
    );
    return failure;
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

const avro_v2: types.SchemaDefinition = .{ .type = .avro, .definition = "{\"type\":\"record\",\"name\":\"M\",\"fields\":[{\"name\":\"note\",\"type\":\"string\",\"default\":\"\"}]}" };

/// The second revision, as a commit answers it and as a read then gives it.
const stored_v2 =
    \\{"name":"projects/p/schemas/order-v1","type":"AVRO","definition":"{\"type\":\"record\",\"name\":\"M\",\"fields\":[{\"name\":\"note\",\"type\":\"string\",\"default\":\"\"}]}","revisionId":"6f0519a4","revisionCreateTime":"1970-01-17T11:51:58.808910083Z"}
;
const unavailable: test_util.FakeTransport.Reply = .{ .respond = .{ .status = 503, .body = "{\"error\":{\"code\":503,\"message\":\"try again\",\"status\":\"UNAVAILABLE\"}}" } };

test "golden: commit, rollback, deleteRevision and listRevisions send the right requests" {
    var h: Harness = undefined;
    try h.init(&.{
        .{ .respond = .{ .body = stored_v2 } },
        .{ .respond = .{ .body = stored } },
        .{ .respond = .{ .body = stored_v2 } },
        .{ .respond = .{ .body = "{\"schemas\":[" ++ stored_basic ++ "],\"nextPageToken\":\"next\"}" } },
        .{ .respond = .{ .body = "{}" } },
    }, .{});
    defer h.deinit();
    const order = h.client.schema("order-v1");
    const base = "http://localhost:8085/v1/projects/p/schemas/order-v1";

    var second = try order.commit(avro_v2);
    defer second.deinit();
    try h.expectRequest(0, .POST, base ++ ":commit",
        \\{"schema":{"name":"projects/p/schemas/order-v1","type":"AVRO","definition":"{\"type\":\"record\",\"name\":\"M\",\"fields\":[{\"name\":\"note\",\"type\":\"string\",\"default\":\"\"}]}"}}
    );
    try testing.expectEqualStrings("6f0519a4", second.value.revision_id);
    try testing.expectEqualStrings(avro_v2.definition, second.value.definition);

    // The revision goes in the body, and the answer is a new one.
    var back = try order.rollback("1b46a16a");
    defer back.deinit();
    try h.expectRequest(1, .POST, base ++ ":rollback", "{\"revisionId\":\"1b46a16a\"}");
    try testing.expectEqualStrings(avro.definition, back.value.definition);

    // The answer, the revision deleted, is not kept.
    try order.deleteRevision("6f0519a4");
    try h.expectRequest(2, .DELETE, base ++ "@6f0519a4:deleteRevision", null);

    var page = try order.listRevisions(.{ .page = .{ .page_size = 1 } });
    defer page.deinit();
    try h.expectRequest(3, .GET, base ++ ":listRevisions?view=BASIC&pageSize=1", null);
    try testing.expectEqual(1, page.value.schemas.len);
    try testing.expectEqualStrings("1b46a16a", page.value.schemas[0].revision_id);
    try testing.expectEqualStrings("", page.value.schemas[0].definition);
    var rest = try order.listRevisions(.{ .view = .full, .page = .{ .page_token = page.value.next_page_token } });
    defer rest.deinit();
    try h.expectRequest(4, .GET, base ++ ":listRevisions?view=FULL&pageSize=100&pageToken=next", null);
    try testing.expectEqual(0, rest.value.schemas.len);
    try h.expectRequestCount(5);
}

test "a bad id, definition or revision fails before a revision is asked for" {
    var h: Harness = undefined;
    try h.init(&.{}, .{});
    defer h.deinit();
    try testing.expectError(error.InvalidResourceId, h.client.schema("go").commit(avro));
    try testing.expectError(error.InvalidResourceId, h.client.schema("a@b").rollback("1b46a16a"));
    try testing.expectError(error.InvalidResourceId, h.client.schema("1st").deleteRevision("1b46a16a"));
    try testing.expectError(error.InvalidResourceId, h.client.schema("x y z").listRevisions(.{}));

    const order = h.client.schema("order-v1");
    try testing.expectError(error.InvalidArgument, order.commit(.{ .type = .avro, .definition = "" }));
    try testing.expectError(error.InvalidArgument, order.commit(.{ .type = .unknown, .definition = "{}" }));
    try testing.expectError(error.InvalidArgument, order.rollback(""));
    try testing.expectError(error.InvalidArgument, order.rollback("1b46a16a:commit"));
    try testing.expectError(error.InvalidArgument, order.deleteRevision("a/b"));
    try testing.expectError(error.InvalidArgument, order.deleteRevision("1b46a16a@x"));
    try testing.expect(std.mem.startsWith(u8, h.diag.message(), "the revision id is empty, or holds"));
    try h.expectRequestCount(0);
}

test "refusals: a schema or a revision that is not there, a definition that does not parse, and a schema's only revision" {
    var h: Harness = undefined;
    try h.init(&.{
        // The emulator's words, 2026-10-11.
        .{ .respond = .{ .status = 404, .body = "{\"error\":{\"code\":404,\"message\":\"Schema not found\",\"status\":\"NOT_FOUND\"}}" } },
        .{ .respond = .{ .status = 400, .body = "{\"error\":{\"code\":400,\"message\":\"Could not parse schema definition\",\"status\":\"INVALID_ARGUMENT\"}}" } },
        .{ .respond = .{ .status = 404, .body = "{\"error\":{\"code\":404,\"message\":\"Revision not found\",\"status\":\"NOT_FOUND\"}}" } },
        .{ .respond = .{ .status = 400, .body = "{\"error\":{\"code\":400,\"message\":\"Cannot delete last revision. Please use DeleteSchema.\",\"status\":\"INVALID_ARGUMENT\"}}" } },
        .{ .respond = .{ .status = 404, .body = "{\"error\":{\"code\":404,\"message\":\"Schema revision not found\",\"status\":\"NOT_FOUND\"}}" } },
        .{ .respond = .{ .status = 404, .body = "{\"error\":{\"code\":404,\"message\":\"Schema not found\",\"status\":\"NOT_FOUND\"}}" } },
        .{ .respond = .{ .body = "{\"schemas\":[{\"type\":\"AVRO\"}]}" } },
    }, .{});
    defer h.deinit();
    const order = h.client.schema("order-v1");

    try testing.expectError(error.NotFound, order.commit(avro_v2));
    try testing.expectError(error.InvalidArgument, order.commit(.{ .type = .avro, .definition = "{nope" }));
    try testing.expectEqualStrings("Could not parse schema definition", h.diag.message());
    try testing.expectError(error.NotFound, order.rollback("deadbeef"));
    try testing.expectEqualStrings("Revision not found", h.diag.message());
    try testing.expectError(error.InvalidArgument, order.deleteRevision("1b46a16a"));
    try testing.expectEqualStrings("Cannot delete last revision. Please use DeleteSchema.", h.diag.message());
    try testing.expectError(error.NotFound, order.deleteRevision("1b46a16a"));
    try testing.expectError(error.NotFound, order.listRevisions(.{}));
    try testing.expectError(error.InvalidResponse, order.listRevisions(.{}));
    try testing.expectEqualStrings("the schema revision list response could not be decoded", h.diag.message());
    // None of them is an answer a second attempt would change, and none
    // made the client read the schema to find out.
    try h.expectRequestCount(7);
}

test "commit: a failed attempt that did not land is made again, after a read that shows it did not" {
    var h: Harness = undefined;
    try h.init(&.{
        unavailable,
        // The latest revision is still the first.
        .{ .respond = .{ .body = stored } },
        .{ .respond = .{ .body = stored_v2 } },
    }, .{});
    defer h.deinit();
    var second = try h.client.schema("order-v1").commit(avro_v2);
    defer second.deinit();
    try testing.expectEqualStrings("6f0519a4", second.value.revision_id);
    const base = "http://localhost:8085/v1/projects/p/schemas/order-v1";
    try testing.expectEqual(.POST, (try h.fake.request(0)).method);
    try h.expectRequest(1, .GET, base ++ "?view=FULL", null);
    try testing.expectEqual(.POST, (try h.fake.request(2)).method);
    try testing.expectEqualStrings((try h.fake.request(0)).body.?, (try h.fake.request(2)).body.?);
    try h.expectRequestCount(3);
    // After the read, and before the second attempt, one backoff.
    try testing.expectEqual(1, h.clock.sleep_count);
    try testing.expect(h.clock.sleepMs(0) <= 100);
}

test "commit: a failed attempt that landed is not made again, and the revision it made is the answer" {
    var h: Harness = undefined;
    try h.init(&.{
        .{ .fail = error.ConnectionResetByPeer },
        // The latest revision already holds what was committed.
        .{ .respond = .{ .body = stored_v2 } },
    }, .{});
    defer h.deinit();
    var second = try h.client.schema("order-v1").commit(avro_v2);
    defer second.deinit();
    try testing.expectEqualStrings("6f0519a4", second.value.revision_id);
    try testing.expectEqualStrings(avro_v2.definition, second.value.definition);
    // The failure the read settled is not left in the diagnostics, and
    // nothing was waited for.
    try testing.expectEqualStrings("", h.diag.message());
    try h.expectRequestCount(2);
    try testing.expectEqual(0, h.clock.sleep_count);
}

test "commit: the same definition under another type is not the commit, and a definition one byte off or one byte longer is not it" {
    var h: Harness = undefined;
    try h.init(&.{
        unavailable,
        .{ .respond = .{ .body = "{\"name\":\"projects/p/schemas/order-v1\",\"type\":\"PROTOCOL_BUFFER\",\"definition\":\"message M {}\",\"revisionId\":\"aaaaaaaa\"}" } },
        unavailable,
        .{ .respond = .{ .body = "{\"name\":\"projects/p/schemas/order-v1\",\"type\":\"AVRO\",\"definition\":\"message M {} \",\"revisionId\":\"bbbbbbbb\"}" } },
        unavailable,
        .{ .respond = .{ .body = "{\"name\":\"projects/p/schemas/order-v1\",\"type\":\"AVRO\",\"definition\":\"message N {}\",\"revisionId\":\"dddddddd\"}" } },
        .{ .respond = .{ .body = "{\"name\":\"projects/p/schemas/order-v1\",\"type\":\"AVRO\",\"definition\":\"message M {}\",\"revisionId\":\"cccccccc\"}" } },
    }, .{});
    defer h.deinit();
    var made = try h.client.schema("order-v1").commit(.{ .type = .avro, .definition = "message M {}" });
    defer made.deinit();
    try testing.expectEqualStrings("cccccccc", made.value.revision_id);
    try h.expectRequestCount(7);
}

test "commit: when the read that would settle a failure is refused, the failure stands and says the commit may have landed" {
    var h: Harness = undefined;
    try h.init(&.{
        unavailable,
        .{ .respond = .{ .status = 403, .body = "{\"error\":{\"code\":403,\"message\":\"User not authorized to perform this action.\",\"status\":\"PERMISSION_DENIED\"}}" } },
    }, .{});
    defer h.deinit();
    try testing.expectError(error.Unavailable, h.client.schema("order-v1").commit(avro_v2));
    try testing.expectEqualStrings(
        "making a revision failed, and reading the schema to see whether the attempt landed failed with PermissionDenied: it may have landed",
        h.diag.message(),
    );
    try h.expectRequestCount(2);
}

test "commit: a schema that is gone by the read is NotFound, in the read's words" {
    var h: Harness = undefined;
    try h.init(&.{
        .{ .fail = error.ConnectionResetByPeer },
        .{ .respond = .{ .status = 404, .body = "{\"error\":{\"code\":404,\"message\":\"Schema not found\",\"status\":\"NOT_FOUND\"}}" } },
    }, .{});
    defer h.deinit();
    try testing.expectError(error.NotFound, h.client.schema("order-v1").commit(avro_v2));
    try testing.expectEqualStrings("Schema not found", h.diag.message());
    try h.expectRequestCount(2);
}

test "commit: attempts run out with the last failure, its diagnostics restored after the read, and no read once none is left" {
    var h: Harness = undefined;
    try h.init(&.{
        unavailable,
        .{ .respond = .{ .body = stored } },
        .{ .respond = .{ .status = 503, .body = "{\"error\":{\"code\":503,\"message\":\"still down\",\"status\":\"UNAVAILABLE\"}}" } },
    }, .{ .retry = .{ .max_attempts = 2 } });
    defer h.deinit();
    try testing.expectError(error.Unavailable, h.client.schema("order-v1").commit(avro_v2));
    try testing.expectEqualStrings("still down", h.diag.message());
    try testing.expectEqual(503, h.diag.http_status);
    try h.expectRequestCount(3);
}

test "commit: a refusal for quota is tried again without a read, and a latest revision that holds the same definition is not taken for the commit" {
    // Production's words for a 21st revision, 2026-10-12.
    const exhausted: test_util.FakeTransport.Reply = .{ .respond = .{ .status = 429, .body = "{\"error\":{\"code\":429,\"message\":\"You have exceeded your revisions per schema quota (schema=\\\"projects/p/schemas/order-v1\\\"). Refer to https://cloud.google.com/pubsub/quotas for more information.\",\"status\":\"RESOURCE_EXHAUSTED\"}}" } };
    var h: Harness = undefined;
    try h.init(&.{ exhausted, exhausted, .{ .respond = .{ .body = stored_v2 } }, exhausted, exhausted }, .{ .retry = .{ .max_attempts = 2 } });
    defer h.deinit();
    const order = h.client.schema("order-v1");

    // A rate limit passes: the third attempt of three is answered.
    h.client.retry.max_attempts = 3;
    var second = try order.commit(avro_v2);
    defer second.deinit();
    try testing.expectEqualStrings("6f0519a4", second.value.revision_id);
    try h.expectRequestCount(3);
    for (0..3) |i| try testing.expectEqual(.POST, (try h.fake.request(i)).method);
    try testing.expectEqual(2, h.clock.sleep_count);

    // A schema that is full stays full: the refusal stands, in its words,
    // though the latest revision holds this very definition.
    h.client.retry.max_attempts = 2;
    try testing.expectError(error.ResourceExhausted, order.commit(avro_v2));
    try testing.expect(std.mem.startsWith(u8, h.diag.message(), "You have exceeded your revisions per schema quota"));
    try testing.expectEqual(429, h.diag.http_status);
    try h.expectRequestCount(5);
    for (3..5) |i| try testing.expectEqual(.POST, (try h.fake.request(i)).method);
}

test "refusals in production's words: a revision that is not compatible, a schema's only revision, and a rollback to the latest" {
    var h: Harness = undefined;
    try h.init(&.{
        // Measured 2026-10-12.
        .{ .respond = .{ .status = 400, .body = "{\"error\":{\"code\":400,\"message\":\"Compatibility checking failed to commit a schema revision for (schema=\\\"projects/p/schemas/order-v1\\\"). (reason=\\\"Revision is incompatible with previous revision: 6e3214ab. Failed with error: Field age has type mismatch: Types do not match.). Refer to https://cloud.google.com/pubsub/docs/schemas for more information.\",\"status\":\"FAILED_PRECONDITION\"}}" } },
        .{ .respond = .{ .status = 400, .body = "{\"error\":{\"code\":400,\"message\":\"This schema contains only one revision, which can only be deleted by deleting the parent schema: (schema=\\\"projects/p/schemas/order-v1@12b2a799\\\"). Refer to https://cloud.google.com/pubsub/docs/schemas for more information.\",\"status\":\"FAILED_PRECONDITION\"}}" } },
        .{ .respond = .{ .status = 409, .body = "{\"error\":{\"code\":409,\"message\":\"Resource already exists in the project (resource=projects/p/schemas/order-v1).\",\"status\":\"ALREADY_EXISTS\"}}" } },
        .{ .respond = .{ .status = 404, .body = "{\"error\":{\"code\":404,\"message\":\"Resource not found (resource=projects/p/schemas/order-v1@deadbeef).\",\"status\":\"NOT_FOUND\"}}" } },
        .{ .respond = .{ .status = 400, .body = "{\"error\":{\"code\":400,\"message\":\"Invalid data in message: JSON object with type string does not match schema which expected number_integer.\",\"status\":\"INVALID_ARGUMENT\",\"details\":[{\"@type\":\"type.googleapis.com/google.rpc.ErrorInfo\",\"reason\":\"INVALID_JSON_AVRO_MESSAGE\",\"domain\":\"pubsub.googleapis.com\"}]}}" } },
    }, .{});
    defer h.deinit();
    const order = h.client.schema("order-v1");

    try testing.expectError(error.FailedPrecondition, order.commit(avro_v2));
    try testing.expect(std.mem.indexOf(u8, h.diag.message(), "Revision is incompatible with previous revision: 6e3214ab") != null);
    try testing.expectError(error.FailedPrecondition, order.deleteRevision("12b2a799"));
    try testing.expect(std.mem.startsWith(u8, h.diag.message(), "This schema contains only one revision"));
    try testing.expectError(error.AlreadyExists, order.create(avro));
    try testing.expectError(error.NotFound, order.get(.{ .revision_id = "deadbeef" }));
    try testing.expectError(error.InvalidArgument, order.validateMessage("{\"age\":\"one\"}", .json, null));
    try testing.expectEqualStrings("Invalid data in message: JSON object with type string does not match schema which expected number_integer.", h.diag.message());
    // Each is an answer: none is asked a second time, and none read for.
    try h.expectRequestCount(5);
}

test "commit: with retries off, a failure is returned as it is, with no read" {
    var h: Harness = undefined;
    try h.init(&.{unavailable}, .{ .retry = .{ .max_attempts = 1 } });
    defer h.deinit();
    try testing.expectError(error.Unavailable, h.client.schema("order-v1").commit(avro_v2));
    try testing.expectEqualStrings("try again", h.diag.message());
    try h.expectRequestCount(1);
}

test "rollback: a failed attempt is settled by reading the revision rolled back to and the latest" {
    var h: Harness = undefined;
    try h.init(&.{
        // It landed: the latest holds what the first revision holds.
        .{ .fail = error.ConnectionResetByPeer },
        .{ .respond = .{ .body = stored } },
        .{ .respond = .{ .body = "{\"name\":\"projects/p/schemas/order-v1\",\"type\":\"AVRO\",\"definition\":\"{\\\"type\\\":\\\"record\\\",\\\"name\\\":\\\"M\\\",\\\"fields\\\":[]}\",\"revisionId\":\"3566a360\"}" } },
        // It did not: the latest is still the second revision, so it is
        // asked for again.
        unavailable,
        .{ .respond = .{ .body = stored } },
        .{ .respond = .{ .body = stored_v2 } },
        .{ .respond = .{ .body = "{\"name\":\"projects/p/schemas/order-v1\",\"type\":\"AVRO\",\"definition\":\"{\\\"type\\\":\\\"record\\\",\\\"name\\\":\\\"M\\\",\\\"fields\\\":[]}\",\"revisionId\":\"ef37675d\"}" } },
    }, .{});
    defer h.deinit();
    const order = h.client.schema("order-v1");
    const base = "http://localhost:8085/v1/projects/p/schemas/order-v1";

    var landed_one = try order.rollback("1b46a16a");
    defer landed_one.deinit();
    try testing.expectEqualStrings("3566a360", landed_one.value.revision_id);
    try h.expectRequest(1, .GET, base ++ "@1b46a16a?view=FULL", null);
    try h.expectRequest(2, .GET, base ++ "?view=FULL", null);
    try h.expectRequestCount(3);

    var again = try order.rollback("1b46a16a");
    defer again.deinit();
    try testing.expectEqualStrings("ef37675d", again.value.revision_id);
    try h.expectRequest(6, .POST, base ++ ":rollback", "{\"revisionId\":\"1b46a16a\"}");
    try h.expectRequestCount(7);
}

test "rollback: a revision that is gone by the read is NotFound, and a refused read leaves the failure standing" {
    var h: Harness = undefined;
    try h.init(&.{
        unavailable,
        .{ .respond = .{ .status = 404, .body = "{\"error\":{\"code\":404,\"message\":\"Schema revision not found\",\"status\":\"NOT_FOUND\"}}" } },
        unavailable,
        .{ .respond = .{ .body = stored } },
        .{ .respond = .{ .status = 403, .body = "{\"error\":{\"code\":403,\"message\":\"no\",\"status\":\"PERMISSION_DENIED\"}}" } },
    }, .{});
    defer h.deinit();
    const order = h.client.schema("order-v1");
    try testing.expectError(error.NotFound, order.rollback("1b46a16a"));
    try testing.expectEqualStrings("Schema revision not found", h.diag.message());
    try testing.expectError(error.Unavailable, order.rollback("1b46a16a"));
    try testing.expect(std.mem.endsWith(u8, h.diag.message(), "failed with PermissionDenied: it may have landed"));
    try h.expectRequestCount(5);
}

fn revisionAllocations(gpa: std.mem.Allocator) !void {
    var fake: test_util.FakeTransport = .init(testing.allocator, &.{
        // A commit that fails, is read as not landed, and is made again.
        unavailable,
        .{ .respond = .{ .body = stored } },
        .{ .respond = .{ .body = stored_v2 } },
        // A rollback that fails and is read as landed.
        .{ .fail = error.ConnectionResetByPeer },
        .{ .respond = .{ .body = stored } },
        .{ .respond = .{ .body = stored } },
        .{ .respond = .{ .body = "{\"schemas\":[" ++ stored ++ "," ++ stored_v2 ++ "],\"nextPageToken\":\"n\"}" } },
        .{ .respond = .{ .body = stored_v2 } },
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
    var second = try order.commit(avro_v2);
    second.deinit();
    var back = try order.rollback("1b46a16a");
    back.deinit();
    var page = try order.listRevisions(.{ .view = .full, .page = .{ .page_token = "m" } });
    page.deinit();
    try order.deleteRevision("6f0519a4");
    // The calls above used the whole script, so none was skipped.
    try testing.expectEqual(8, fake.requests.items.len);
}

test "allocation failures: commit, rollback and their reads fail cleanly at each allocation" {
    try testing.checkAllAllocationFailures(test_util.no_grow_allocator, revisionAllocations, .{});
}
