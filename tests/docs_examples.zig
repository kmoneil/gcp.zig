//! Code the documentation shows, compiled and run with the unit tests so
//! that it cannot drift from the library. tools/check_docs.py holds each
//! block marked `<!-- snippet: tests/docs_examples.zig#name -->` to the
//! lines between `// snippet: name` and `// end snippet` here.

// snippet: testing-with-fakes
const std = @import("std");
const core = @import("core");
const pubsub = @import("pubsub");

test "a publish, answered by a fake" {
    var fake: core.testing.FakeTransport = .init(std.testing.allocator, &.{
        .{ .respond = .{ .body = "{\"messageIds\":[\"1\"]}" } },
    });
    defer fake.deinit();
    var tokens: core.testing.FakeTokenProvider = .{};
    var client = try pubsub.Client.init(std.testing.allocator, std.testing.io, .{
        .project_id = "my-project",
        .token_provider = tokens.provider(),
        .transport = fake.transport(),
    });
    defer client.deinit();

    var sent = try client.topic("orders").publish(&.{.{ .data = "hello" }}, .{});
    defer sent.deinit();
    try std.testing.expectEqualStrings("1", sent.value.message_ids[0]);

    const request = try fake.request(0);
    try std.testing.expectEqualStrings(
        "https://pubsub.googleapis.com/v1/projects/my-project/topics/orders:publish",
        request.url,
    );
}
// end snippet

const secret_manager = @import("secret_manager");

// snippet: secret-set-label
/// Sets one label and keeps the others. The update replaces every label,
/// so it goes under the etag the read returned: another change made in
/// between is error.Aborted rather than lost, and the loop reads again.
fn setLabel(gpa: std.mem.Allocator, secret: secret_manager.Secret, key: []const u8, value: []const u8) !void {
    while (true) {
        var read = try secret.get();
        defer read.deinit();
        var labels: std.ArrayList(secret_manager.Label) = .empty;
        defer labels.deinit(gpa);
        for (read.value.labels) |l| {
            if (!std.mem.eql(u8, l.key, key)) try labels.append(gpa, l);
        }
        try labels.append(gpa, .{ .key = key, .value = value });

        var updated = secret.update(.{
            .labels = .{ .set = labels.items },
            .etag = read.value.etag,
        }) catch |err| switch (err) {
            error.Aborted => continue, // changed since the read
            else => return err,
        };
        updated.deinit();
        return;
    }
}
// end snippet

test "setLabel reads again when the secret changed in between" {
    var fake: core.testing.FakeTransport = .init(std.testing.allocator, &.{
        .{ .respond = .{ .body = "{\"name\":\"projects/1/secrets/db\",\"etag\":\"\\\"e1\\\"\",\"labels\":{\"team\":\"payments\"}}" } },
        .{ .respond = .{ .status = 400, .body = "{\"error\":{\"status\":\"FAILED_PRECONDITION\",\"message\":\"The etag provided in the request does not match the resource's current etag.\"}}" } },
        .{ .respond = .{ .body = "{\"name\":\"projects/1/secrets/db\",\"etag\":\"\\\"e2\\\"\",\"labels\":{\"team\":\"payments\",\"tier\":\"gold\"}}" } },
        .{ .respond = .{ .body = "{\"name\":\"projects/1/secrets/db\",\"etag\":\"\\\"e3\\\"\"}" } },
    });
    defer fake.deinit();
    var tokens: core.testing.FakeTokenProvider = .{};
    var client = try secret_manager.Client.init(std.testing.allocator, std.testing.io, .{
        .project_id = "my-project",
        .token_provider = tokens.provider(),
        .transport = fake.transport(),
    });
    defer client.deinit();

    try setLabel(std.testing.allocator, client.secret("db"), "env", "prod");
    try std.testing.expectEqual(4, fake.requests.items.len);
    try std.testing.expectEqualStrings(
        "{\"labels\":{\"team\":\"payments\",\"tier\":\"gold\",\"env\":\"prod\"},\"etag\":\"\\\"e2\\\"\"}",
        (try fake.request(3)).body.?,
    );
}

const firestore = @import("firestore");

// snippet: firestore-first
/// Writes a city, raises its population under the update time it was read
/// at, and lists the cities of over a million, largest first.
fn cities(client: *firestore.Client) !void {
    const la = client.collection("cities").doc("LA");
    _ = try la.set(&.{
        .{ .name = "name", .value = .{ .string = "Los Angeles" } },
        .{ .name = "population", .value = .{ .integer = 3_900_000 } },
    }, .{});

    var got = try la.get(.{});
    defer got.deinit();
    const population = got.value.get("population").?.integer;
    // error.FailedPrecondition if anyone wrote LA after this read.
    _ = try la.update(&.{
        .{ .name = "population", .value = .{ .integer = population + 100_000 } },
    }, .{ .precondition = .{ .update_time = got.value.update_time } });

    var big = try client.runQuery(.{
        .from = .{ .collection = "cities" },
        .where = &.{.{ .field = "population", .op = .greater_than, .value = .{ .integer = 1_000_000 } }},
        .order_by = &.{.{ .field = "population", .direction = .descending }},
    }, .{});
    defer big.deinit();
    for (big.value.documents) |city| std.log.info("{s}", .{city.id()});
}
// end snippet

// snippet: firestore-counter
/// Counts a visit on the server: concurrent visits never lose one, and the
/// document need not exist yet.
fn countVisit(client: *firestore.Client, page: []const u8) !void {
    _ = try client.doc(page).update(&.{}, .{
        .transforms = &.{
            .{ .field_path = "visits", .op = .{ .increment = .{ .integer = 1 } } },
            .{ .field_path = "last_visit", .op = .server_time },
        },
        // Created when missing, rather than error.NotFound.
        .precondition = null,
    });
}
// end snippet

// snippet: firestore-pages
/// Reads every city by population, 100 at a time. Each page starts after
/// the last document of the one before, by its population and then its
/// name, which breaks ties between equal populations.
fn everyCity(client: *firestore.Client, gpa: std.mem.Allocator) !usize {
    var seen: usize = 0;
    var after: ?[2]firestore.Value = null;
    var name_buf: std.ArrayList(u8) = .empty;
    defer name_buf.deinit(gpa);
    while (true) {
        var page = try client.runQuery(.{
            .from = .{ .collection = "cities" },
            .order_by = &.{ .{ .field = "population" }, .{ .field = "__name__" } },
            .start_at = if (after) |*a| .{ .values = a, .inclusive = false } else null,
            .limit = 100,
        }, .{});
        defer page.deinit();
        const docs = page.value.documents;
        seen += docs.len;
        if (docs.len < 100) return seen;
        // The cursor outlives the page, so it keeps a copy of the name.
        const last = docs[docs.len - 1];
        name_buf.clearRetainingCapacity();
        try name_buf.appendSlice(gpa, last.name);
        after = .{ last.get("population").?, .{ .reference = name_buf.items } };
    }
}
// end snippet

// snippet: firestore-each
/// Writes the id of every city to `out` as each arrives, however many
/// there are: memory holds one document at a time, not the answer.
fn exportCities(client: *firestore.Client, out: *std.Io.Writer) !u64 {
    const Export = struct {
        out: *std.Io.Writer,

        fn document(ptr: *anyopaque, snapshot: firestore.Owned(firestore.Snapshot)) anyerror!void {
            const self: *@This() = @ptrCast(@alignCast(ptr));
            var city = snapshot;
            defer city.deinit();
            try self.out.print("{s}\n", .{city.value.id()});
        }
    };
    var state: Export = .{ .out = out };
    const end = try client.runQueryEach(
        .{ .from = .{ .collection = "cities" } },
        .{},
        .{ .ptr = &state, .vtable = &.{ .document = Export.document } },
    );
    return end.documents;
}
// end snippet

test "the Firestore guides' code, against a fake" {
    const commit = "{\"writeResults\":[{\"updateTime\":\"2026-10-05T12:00:00.000001Z\"}],\"commitTime\":\"2026-10-05T12:00:00.000001Z\"}";
    const la = "{\"name\":\"projects/my-project/databases/(default)/documents/cities/LA\",\"fields\":{\"population\":{\"integerValue\":\"3900000\"}},\"createTime\":\"2026-10-05T12:00:00.000001Z\",\"updateTime\":\"2026-10-05T12:00:00.000001Z\"}";
    const one_city = "[{\"document\":" ++ la ++ ",\"readTime\":\"2026-10-05T12:00:01Z\",\"done\":true}]";
    var fake: core.testing.FakeTransport = .init(std.testing.allocator, &.{
        .{ .respond = .{ .body = commit } },
        .{ .respond = .{ .body = la } },
        .{ .respond = .{ .body = commit } },
        .{ .respond = .{ .body = one_city } },
        .{ .respond = .{ .body = "{\"writeResults\":[{\"updateTime\":\"2026-10-05T12:00:00.000001Z\",\"transformResults\":[{\"integerValue\":\"1\"},{\"timestampValue\":\"2026-10-05T12:00:00Z\"}]}],\"commitTime\":\"2026-10-05T12:00:00.000001Z\"}" } },
        .{ .respond = .{ .body = one_city } },
        .{ .respond = .{ .body = one_city } },
    });
    defer fake.deinit();
    var tokens: core.testing.FakeTokenProvider = .{};
    var client = try firestore.Client.init(std.testing.allocator, std.testing.io, .{
        .project_id = "my-project",
        .token_provider = tokens.provider(),
        .transport = fake.transport(),
    });
    defer client.deinit();
    try cities(&client);
    try std.testing.expect(std.mem.indexOf(u8, (try fake.request(2)).body.?, "\"currentDocument\":{\"updateTime\":\"2026-10-05T12:00:00.000001Z\"}") != null);
    try countVisit(&client, "pages/home");
    try std.testing.expect(std.mem.indexOf(u8, (try fake.request(4)).body.?, "\"updateMask\":{\"fieldPaths\":[]}") != null);
    try std.testing.expectEqual(1, try everyCity(&client, std.testing.allocator));
    var out_buf: [16]u8 = undefined;
    var out: std.Io.Writer = .fixed(&out_buf);
    try std.testing.expectEqual(1, try exportCities(&client, &out));
    try std.testing.expectEqualStrings("LA\n", out.buffered());
}

const storage = @import("storage");

// snippet: storage-acl-grant
/// Lets a team's group read one report and takes a former colleague's
/// access away: each a read of the list, a change, and a write guarded by
/// what was read, run again when another change came in between.
fn shareReport(gcs: *storage.Client) !void {
    const acl = gcs.bucket("reports").object("2026/q3.pdf").acl();
    var shared = try acl.grant(.{ .group = "finance@example.com" }, .reader);
    defer shared.deinit();
    var revoked = try acl.revoke(.{ .user = "former@example.com" });
    defer revoked.deinit();
}
// end snippet

// snippet: storage-hmac
/// Makes an HMAC key for a service account, signs a download URL with it,
/// and returns the URL in `gpa`'s memory. The secret is shown this once: a
/// real program stores it, as a credential, before `deinit` zeroes it.
fn signWithNewKey(gcs: *storage.Client, gpa: std.mem.Allocator, account: []const u8) ![]u8 {
    var key = try gcs.createHmacKey(account, .{});
    defer key.deinit();
    const signer: storage.UrlSigner = .{ .hmac = .{
        .access_id = key.value.info.access_id,
        .secret = key.value.secret,
    } };
    var url = try gcs.bucket("photos").object("cats/tom.jpg").signedUrl(signer, .{ .expires_in_s = 15 * 60 });
    defer url.deinit();
    return gpa.dupe(u8, url.value);
}

/// Retires a key: deactivated, then deleted. URLs it signed stop working
/// within minutes.
fn retireKey(gcs: *storage.Client, access_id: []const u8) !void {
    try gcs.hmacKey(access_id).deactivateAndDelete();
}
// end snippet

test "the Cloud Storage guides' code, against a scripted transport" {
    const object_list =
        \\{"name":"2026/q3.pdf","generation":"7","metageneration":"2","owner":{"entity":"user-w@example.com"},
        \\ "acl":[{"entity":"user-w@example.com","role":"OWNER"},{"entity":"user-former@example.com","role":"READER"}]}
    ;
    const with_group =
        \\{"name":"2026/q3.pdf","generation":"7","metageneration":"3","owner":{"entity":"user-w@example.com"},
        \\ "acl":[{"entity":"user-w@example.com","role":"OWNER"},{"entity":"user-former@example.com","role":"READER"},
        \\  {"entity":"group-finance@example.com","role":"READER"}]}
    ;
    // Made up, and shaped so no secret scanner takes it for a key.
    const created =
        \\{"kind":"storage#hmacKey","metadata":{"accessId":"GOOG1E-TEST-ONLY-NOT-A-REAL-ACCESS-ID","state":"ACTIVE","etag":"MQ=="},
        \\ "secret":"TEST_ONLY_not_a_real_secret_000000000000"}
    ;
    var fake: core.testing.FakeTransport = .init(std.testing.allocator, &.{
        .{ .respond = .{ .body = object_list } },
        .{ .respond = .{ .body = with_group } },
        .{ .respond = .{ .body = with_group } },
        .{ .respond = .{ .body = with_group } },
        .{ .respond = .{ .body = created } },
        .{ .respond = .{ .body = "{\"accessId\":\"GOOG1E-TEST-ONLY-NOT-A-REAL-ACCESS-ID\",\"state\":\"INACTIVE\",\"etag\":\"Mg==\"}" } },
        .{ .respond = .{ .status = 204, .body = "" } },
    });
    defer fake.deinit();
    var tokens: core.testing.FakeTokenProvider = .{};
    var gcs = try storage.Client.init(std.testing.allocator, std.testing.io, .{
        .project_id = "my-project",
        .token_provider = tokens.provider(),
        .transport = fake.transport(),
    });
    defer gcs.deinit();

    try shareReport(&gcs);
    // The grant wrote the whole list under the metageneration it read.
    try std.testing.expectEqualStrings(
        "https://storage.googleapis.com/storage/v1/b/reports/o/2026%2Fq3.pdf?projection=full&ifGenerationMatch=7&ifMetagenerationMatch=2",
        (try fake.request(1)).url,
    );

    const url = try signWithNewKey(&gcs, std.testing.allocator, "signer@my-project.iam.gserviceaccount.com");
    defer std.testing.allocator.free(url);
    try std.testing.expect(std.mem.indexOf(u8, url, "X-Goog-Algorithm=GOOG4-HMAC-SHA256&X-Goog-Credential=GOOG1E-TEST-ONLY-NOT-A-REAL-ACCESS-ID%2F") != null);
    try retireKey(&gcs, "GOOG1E-TEST-ONLY-NOT-A-REAL-ACCESS-ID");
    try std.testing.expectEqual(7, fake.requests.items.len);
}

// snippet: pubsub-snapshot
/// Before a risky deploy: keeps the backlog of `orders-worker` as it
/// stands.
fn keepBacklog(client: *pubsub.Client) !void {
    var kept = try client.snapshot("before-deploy").create(.{ .subscription = "orders-worker" });
    defer kept.deinit();
}

/// The deploy acknowledged what it should not have: back to the snapshot,
/// which stays until it is deleted or expires.
fn undoDeploy(client: *pubsub.Client) !void {
    try client.subscription("orders-worker").seek(.{ .snapshot = "before-deploy" });
}
// end snippet

// snippet: pubsub-seek-time
/// Replays what was published since `since`, as far back as the
/// subscription or its topic retains messages.
fn replaySince(client: *pubsub.Client, since: std.Io.Timestamp) !void {
    try client.subscription("orders-worker").seek(.{ .time = since });
}

/// Drops a backlog nobody wants. A minute ahead of this machine's clock,
/// to be past the server's: what is published afterwards is delivered.
fn purge(client: *pubsub.Client, io: std.Io) !void {
    const now = std.Io.Clock.real.now(io);
    try client.subscription("orders-worker").seek(.{ .time = .{ .nanoseconds = now.nanoseconds + std.time.ns_per_min } });
}
// end snippet

// snippet: pubsub-detach
/// A topic's owner cuts off a subscription for good. `consumers` is a
/// client for the project the subscription lives in.
fn cutOff(consumers: *pubsub.Client) !void {
    try consumers.subscription("stale-consumer").detach();
}
// end snippet

// snippet: pubsub-schema-create
/// Stores the contract, and makes a topic that holds every message to it.
fn makeOrders(client: *pubsub.Client, avro_json: []const u8) !void {
    var stored = try client.schema("order").create(.{ .type = .avro, .definition = avro_json });
    defer stored.deinit();
    var topic = try client.topic("orders").create(.{
        .schema = .{ .schema = "order", .encoding = .json },
    });
    defer topic.deinit();
}
// end snippet

// snippet: pubsub-schema-validate
/// In a test, or before a deploy: would Pub/Sub store this definition,
/// and would the topic take this message?
fn check(client: *pubsub.Client, avro_json: []const u8, message: []const u8) !void {
    try client.validateSchema(.{ .type = .avro, .definition = avro_json });
    try client.schema("order").validateMessage(message, .json, null);
}
// end snippet

// snippet: pubsub-schema-revise
/// A new shape for orders: one more revision. Messages of the old shape
/// are still taken.
fn addField(client: *pubsub.Client, avro_json_v2: []const u8) !void {
    var next = try client.schema("order").commit(.{ .type = .avro, .definition = avro_json_v2 });
    defer next.deinit();
}

/// The new shape was a mistake. The schema's latest is the good one
/// again, and the bad one is gone, so the topic stops taking it.
fn undo(client: *pubsub.Client, good: []const u8, bad: []const u8) !void {
    var back = try client.schema("order").rollback(good);
    defer back.deinit();
    try client.schema("order").deleteRevision(bad);
}
// end snippet

// snippet: pubsub-schema-receive
/// A handler's first question: how is this message written, and by which
/// revision? A subscriber that decodes keeps one decoder per revision,
/// each read once with `get(.{ .revision_id = ... })`.
fn describe(message: pubsub.ReceivedMessage, out: *std.Io.Writer) !void {
    const written = message.schema() orelse return out.writeAll("no schema\n");
    try out.print("{s} revision {s}, as {t}\n", .{ written.name, written.revision_id, written.encoding });
}
// end snippet

// snippet: pubsub-schema-topic
/// Stops taking newer shapes: only revisions up to `last` fit.
fn pin(client: *pubsub.Client, last: []const u8) !void {
    var pinned = try client.topic("orders").update(.{ .schema = .{ .set = .{
        .schema = "order",
        .encoding = .json,
        .last_revision_id = last,
    } } });
    defer pinned.deinit();
}

/// Any bytes again.
fn release(client: *pubsub.Client) !void {
    var plain = try client.topic("orders").update(.{ .schema = .clear });
    defer plain.deinit();
}
// end snippet

test "the schemas guide's code, against a scripted transport" {
    const order = "{\"name\":\"projects/my-project/schemas/order\",\"type\":\"AVRO\",\"definition\":\"\\\"string\\\"\",\"revisionId\":\"1b46a16a\",\"revisionCreateTime\":\"2026-10-11T23:15:46.447Z\"}";
    const topic = "{\"name\":\"projects/my-project/topics/orders\",\"schemaSettings\":{\"schema\":\"projects/my-project/schemas/order\",\"encoding\":\"JSON\"}}";
    var fake: core.testing.FakeTransport = .init(std.testing.allocator, &.{
        .{ .respond = .{ .body = order } },
        .{ .respond = .{ .body = topic } },
        .{ .respond = .{} },
        .{ .respond = .{} },
        .{ .respond = .{ .body = order } },
        .{ .respond = .{ .body = order } },
        .{ .respond = .{ .body = order } },
        .{ .respond = .{ .body = topic } },
        .{ .respond = .{ .body = "{\"name\":\"projects/my-project/topics/orders\"}" } },
    });
    defer fake.deinit();
    var tokens: core.testing.FakeTokenProvider = .{};
    var client = try pubsub.Client.init(std.testing.allocator, std.testing.io, .{
        .project_id = "my-project",
        .token_provider = tokens.provider(),
        .transport = fake.transport(),
    });
    defer client.deinit();
    const base = "https://pubsub.googleapis.com/v1/projects/my-project/";

    try makeOrders(&client, "\"string\"");
    try std.testing.expectEqualStrings(base ++ "schemas?schemaId=order", (try fake.request(0)).url);
    try std.testing.expectEqualStrings("{\"type\":\"AVRO\",\"definition\":\"\\\"string\\\"\"}", (try fake.request(0)).body.?);
    try std.testing.expectEqualStrings(base ++ "topics/orders", (try fake.request(1)).url);
    try std.testing.expectEqualStrings(
        "{\"schemaSettings\":{\"schema\":\"projects/my-project/schemas/order\",\"encoding\":\"JSON\"}}",
        (try fake.request(1)).body.?,
    );

    try check(&client, "\"string\"", "\"a\"");
    try std.testing.expectEqualStrings(base ++ "schemas:validate", (try fake.request(2)).url);
    try std.testing.expectEqualStrings(base ++ "schemas:validateMessage", (try fake.request(3)).url);
    try std.testing.expectEqualStrings(
        "{\"name\":\"projects/my-project/schemas/order\",\"message\":\"ImEi\",\"encoding\":\"JSON\"}",
        (try fake.request(3)).body.?,
    );

    try addField(&client, "\"bytes\"");
    try std.testing.expectEqualStrings(base ++ "schemas/order:commit", (try fake.request(4)).url);

    try undo(&client, "1b46a16a", "6f0519a4");
    try std.testing.expectEqualStrings(base ++ "schemas/order:rollback", (try fake.request(5)).url);
    try std.testing.expectEqualStrings("{\"revisionId\":\"1b46a16a\"}", (try fake.request(5)).body.?);
    try std.testing.expectEqualStrings(base ++ "schemas/order@6f0519a4:deleteRevision", (try fake.request(6)).url);

    try pin(&client, "1b46a16a");
    try std.testing.expectEqualStrings(
        "{\"topic\":{\"schemaSettings\":{\"schema\":\"projects/my-project/schemas/order\",\"encoding\":\"JSON\",\"lastRevisionId\":\"1b46a16a\"}},\"updateMask\":\"schemaSettings\"}",
        (try fake.request(7)).body.?,
    );
    try release(&client);
    try std.testing.expectEqualStrings("{\"topic\":{},\"updateMask\":\"schemaSettings\"}", (try fake.request(8)).body.?);
    try std.testing.expectEqual(9, fake.requests.items.len);

    // What a handler reads off a message, with and without a schema.
    var out: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer out.deinit();
    const plain: pubsub.ReceivedMessage = .{ .ack_id = "a", .message_id = "1", .data = "x", .attributes = &.{}, .publish_time = "", .ordering_key = "", .delivery_attempt = 0 };
    var written = plain;
    written.attributes = &.{
        .{ .key = "googclient_schemaencoding", .value = "JSON" },
        .{ .key = "googclient_schemaname", .value = "projects/my-project/schemas/order" },
        .{ .key = "googclient_schemarevisionid", .value = "1b46a16a" },
    };
    try describe(plain, &out.writer);
    try describe(written, &out.writer);
    try std.testing.expectEqualStrings("no schema\nprojects/my-project/schemas/order revision 1b46a16a, as json\n", out.written());
}

test "the replay guide's code, against a scripted transport" {
    var fake: core.testing.FakeTransport = .init(std.testing.allocator, &.{
        .{ .respond = .{ .body = "{\"name\":\"projects/my-project/snapshots/before-deploy\",\"topic\":\"projects/my-project/topics/orders\",\"expireTime\":\"2026-10-17T13:46:36.836Z\"}" } },
        .{ .respond = .{} },
        .{ .respond = .{} },
        .{ .respond = .{} },
        .{ .respond = .{} },
    });
    defer fake.deinit();
    var tokens: core.testing.FakeTokenProvider = .{};
    var client = try pubsub.Client.init(std.testing.allocator, std.testing.io, .{
        .project_id = "my-project",
        .token_provider = tokens.provider(),
        .transport = fake.transport(),
    });
    defer client.deinit();
    const base = "https://pubsub.googleapis.com/v1/projects/my-project/";

    try keepBacklog(&client);
    try std.testing.expectEqualStrings(base ++ "snapshots/before-deploy", (try fake.request(0)).url);
    try std.testing.expectEqualStrings("{\"subscription\":\"projects/my-project/subscriptions/orders-worker\"}", (try fake.request(0)).body.?);

    try undoDeploy(&client);
    try std.testing.expectEqualStrings(base ++ "subscriptions/orders-worker:seek", (try fake.request(1)).url);
    try std.testing.expectEqualStrings("{\"snapshot\":\"projects/my-project/snapshots/before-deploy\"}", (try fake.request(1)).body.?);

    try replaySince(&client, try core.timestamp.parse("2026-10-10T12:00:00Z"));
    try std.testing.expectEqualStrings("{\"time\":\"2026-10-10T12:00:00Z\"}", (try fake.request(2)).body.?);

    // The purge names a time ahead of now.
    const before = std.Io.Clock.real.now(std.testing.io);
    try purge(&client, std.testing.io);
    const sent = try std.json.parseFromSlice(struct { time: []const u8 }, std.testing.allocator, (try fake.request(3)).body.?, .{});
    defer sent.deinit();
    try std.testing.expect((try core.timestamp.parse(sent.value.time)).nanoseconds >= before.nanoseconds + 59 * std.time.ns_per_s);

    try cutOff(&client);
    try std.testing.expectEqualStrings(base ++ "subscriptions/stale-consumer:detach", (try fake.request(4)).url);
    try std.testing.expectEqual(null, (try fake.request(4)).body);
    try std.testing.expectEqual(5, fake.requests.items.len);
}

// snippet: pubsub-delivery-create
/// Each message of `orders` as a row of `sales.orders`, with its id,
/// publish time, ordering key and attributes in columns of their own.
fn tableOfOrders(client: *pubsub.Client) !void {
    var rows = try client.subscription("orders-to-warehouse").create(.{
        .topic_id = "orders",
        .delivery = .{ .bigquery = .{ .table = "my-project.sales.orders", .write_metadata = true } },
    });
    defer rows.deinit();
}

/// Each message POSTed to the shop's webhook, signed as its service
/// account, the data alone as the body and the metadata in headers.
fn pushToWebhook(client: *pubsub.Client) !void {
    var hook = try client.subscription("orders-hook").create(.{
        .topic_id = "orders",
        .delivery = .{ .push = .{
            .endpoint = "https://shop.example/pubsub",
            .oidc_token = .{ .service_account_email = "pusher@my-project.iam.gserviceaccount.com" },
            .body = .{ .unwrapped = .{ .write_metadata = true } },
        } },
    });
    defer hook.deinit();
}
// end snippet

// snippet: pubsub-delivery-update
/// Stop pushing, and pull instead. Google says the switch away from
/// push can take minutes to settle.
fn pullInstead(client: *pubsub.Client) !void {
    var pulled = try client.subscription("orders-hook").update(.{ .delivery = .pull });
    defer pulled.deinit();
}

/// Rotate the webhook's address. The config is replaced whole, so it
/// names everything it keeps, the token among it.
fn moveWebhook(client: *pubsub.Client) !void {
    var moved = try client.subscription("orders-hook").update(.{ .delivery = .{ .push = .{
        .endpoint = "https://shop2.example/pubsub",
        .oidc_token = .{ .service_account_email = "pusher@my-project.iam.gserviceaccount.com" },
    } } });
    defer moved.deinit();
}
// end snippet

test "the delivery guide's code, against a scripted transport" {
    var fake: core.testing.FakeTransport = .init(std.testing.allocator, &.{
        .{ .respond = .{ .body = "{\"name\":\"projects/my-project/subscriptions/orders-to-warehouse\",\"topic\":\"projects/my-project/topics/orders\",\"pushConfig\":{},\"bigqueryConfig\":{\"table\":\"my-project.sales.orders\",\"writeMetadata\":true,\"state\":\"ACTIVE\"}}" } },
        .{ .respond = .{ .body = "{\"name\":\"projects/my-project/subscriptions/orders-hook\",\"pushConfig\":{\"pushEndpoint\":\"https://shop.example/pubsub\"}}" } },
        .{ .respond = .{ .body = "{\"name\":\"projects/my-project/subscriptions/orders-hook\",\"pushConfig\":{}}" } },
        .{ .respond = .{ .body = "{\"name\":\"projects/my-project/subscriptions/orders-hook\",\"pushConfig\":{\"pushEndpoint\":\"https://shop2.example/pubsub\"}}" } },
    });
    defer fake.deinit();
    var tokens: core.testing.FakeTokenProvider = .{};
    var client = try pubsub.Client.init(std.testing.allocator, std.testing.io, .{
        .project_id = "my-project",
        .token_provider = tokens.provider(),
        .transport = fake.transport(),
    });
    defer client.deinit();
    const base = "https://pubsub.googleapis.com/v1/projects/my-project/subscriptions/";

    try tableOfOrders(&client);
    try std.testing.expectEqualStrings(base ++ "orders-to-warehouse", (try fake.request(0)).url);
    try std.testing.expectEqualStrings(
        "{\"topic\":\"projects/my-project/topics/orders\",\"enableMessageOrdering\":false,\"bigqueryConfig\":{\"table\":\"my-project.sales.orders\",\"writeMetadata\":true}}",
        (try fake.request(0)).body.?,
    );

    try pushToWebhook(&client);
    try std.testing.expectEqualStrings(
        "{\"topic\":\"projects/my-project/topics/orders\",\"enableMessageOrdering\":false,\"pushConfig\":{\"pushEndpoint\":\"https://shop.example/pubsub\",\"oidcToken\":{\"serviceAccountEmail\":\"pusher@my-project.iam.gserviceaccount.com\"},\"noWrapper\":{\"writeMetadata\":true}}}",
        (try fake.request(1)).body.?,
    );

    // The update masks every kind: the delivery is replaced whole.
    try pullInstead(&client);
    try std.testing.expectEqualStrings(base ++ "orders-hook", (try fake.request(2)).url);
    try std.testing.expectEqualStrings(
        "{\"subscription\":{},\"updateMask\":\"pushConfig,bigqueryConfig,cloudStorageConfig\"}",
        (try fake.request(2)).body.?,
    );

    try moveWebhook(&client);
    try std.testing.expectEqualStrings(
        "{\"subscription\":{\"pushConfig\":{\"pushEndpoint\":\"https://shop2.example/pubsub\",\"oidcToken\":{\"serviceAccountEmail\":\"pusher@my-project.iam.gserviceaccount.com\"}}},\"updateMask\":\"pushConfig,bigqueryConfig,cloudStorageConfig\"}",
        (try fake.request(3)).body.?,
    );
    try std.testing.expectEqual(4, fake.requests.items.len);
}

// snippet: pubsub-transform-topic
/// Every order leaves the topic without its card number, whoever
/// subscribes. `redact_js` is the source of a function named `redact`.
fn redactOrders(client: *pubsub.Client, redact_js: []const u8) !void {
    var topic = try client.topic("orders").create(.{
        .message_transforms = &.{.{ .kind = .{ .javascript_udf = .{
            .function_name = "redact",
            .code = redact_js,
        } } }},
    });
    defer topic.deinit();
}
// end snippet

// snippet: pubsub-transform-subscription
/// Only this subscriber is spared the test orders: its function returns
/// null for them, and Pub/Sub acknowledges them unseen.
fn skipTestOrders(client: *pubsub.Client, skip_js: []const u8) !void {
    var sub = try client.subscription("orders-billing").create(.{
        .topic_id = "orders",
        .message_transforms = &.{.{ .kind = .{ .javascript_udf = .{
            .function_name = "skipTests",
            .code = skip_js,
        } } }},
    });
    defer sub.deinit();
}
// end snippet

// snippet: pubsub-transform-update
/// A second function after the first, with the first switched off but
/// kept. The list is replaced whole, so it names everything it keeps.
fn addStamp(client: *pubsub.Client, redact_js: []const u8, stamp_js: []const u8) !void {
    var changed = try client.topic("orders").update(.{ .message_transforms = &.{
        .{ .kind = .{ .javascript_udf = .{ .function_name = "redact", .code = redact_js } }, .disabled = true },
        .{ .kind = .{ .javascript_udf = .{ .function_name = "stamp", .code = stamp_js } } },
    } });
    defer changed.deinit();
}

/// Every transform off the topic.
fn untransformed(client: *pubsub.Client) !void {
    var plain = try client.topic("orders").update(.{ .message_transforms = &.{} });
    defer plain.deinit();
}
// end snippet

test "the transforms guide's code, against a scripted transport" {
    const redact_js = "function redact(message, metadata) { const order = JSON.parse(message.data); delete order.card; message.data = JSON.stringify(order); return message; }";
    const topic = "{\"name\":\"projects/my-project/topics/orders\",\"messageTransforms\":[{\"javascriptUdf\":{\"functionName\":\"redact\",\"code\":\"function redact(message, metadata) { return message; }\"}}]}";
    var fake: core.testing.FakeTransport = .init(std.testing.allocator, &.{
        .{ .respond = .{ .body = topic } },
        .{ .respond = .{ .body = "{\"name\":\"projects/my-project/subscriptions/orders-billing\",\"topic\":\"projects/my-project/topics/orders\",\"pushConfig\":{},\"ackDeadlineSeconds\":10}" } },
        .{ .respond = .{ .body = topic } },
        .{ .respond = .{ .body = "{\"name\":\"projects/my-project/topics/orders\"}" } },
    });
    defer fake.deinit();
    var tokens: core.testing.FakeTokenProvider = .{};
    var client = try pubsub.Client.init(std.testing.allocator, std.testing.io, .{
        .project_id = "my-project",
        .token_provider = tokens.provider(),
        .transport = fake.transport(),
    });
    defer client.deinit();
    const base = "https://pubsub.googleapis.com/v1/projects/my-project/";

    try redactOrders(&client, redact_js);
    try std.testing.expectEqualStrings(base ++ "topics/orders", (try fake.request(0)).url);
    try std.testing.expectEqualStrings(
        "{\"messageTransforms\":[{\"javascriptUdf\":{\"functionName\":\"redact\",\"code\":\"" ++ redact_js ++ "\"}}]}",
        (try fake.request(0)).body.?,
    );

    try skipTestOrders(&client, "function skipTests(message, metadata) { return message.attributes.test ? null : message; }");
    try std.testing.expectEqualStrings(base ++ "subscriptions/orders-billing", (try fake.request(1)).url);
    try std.testing.expectEqualStrings(
        "{\"topic\":\"projects/my-project/topics/orders\",\"enableMessageOrdering\":false,\"messageTransforms\":[{\"javascriptUdf\":{\"functionName\":\"skipTests\",\"code\":\"function skipTests(message, metadata) { return message.attributes.test ? null : message; }\"}}]}",
        (try fake.request(1)).body.?,
    );

    try addStamp(&client, "function redact(m) { return m; }", "function stamp(m) { m.attributes.stamped = 'yes'; return m; }");
    try std.testing.expectEqualStrings(
        "{\"topic\":{\"messageTransforms\":[{\"javascriptUdf\":{\"functionName\":\"redact\",\"code\":\"function redact(m) { return m; }\"},\"disabled\":true},{\"javascriptUdf\":{\"functionName\":\"stamp\",\"code\":\"function stamp(m) { m.attributes.stamped = 'yes'; return m; }\"}}]},\"updateMask\":\"messageTransforms\"}",
        (try fake.request(2)).body.?,
    );
    try untransformed(&client);
    try std.testing.expectEqualStrings("{\"topic\":{},\"updateMask\":\"messageTransforms\"}", (try fake.request(3)).body.?);
    try std.testing.expectEqual(4, fake.requests.items.len);
}

// snippet: pubsub-import-bucket
/// A topic that fills itself from a bucket: each new object's lines
/// become messages. Pub/Sub's service agent must be able to read the
/// bucket, or the create is refused.
fn importUploads(client: *pubsub.Client) !void {
    var topic = try client.topic("uploads").create(.{
        .ingestion = .{ .source = .{ .cloud_storage = .{
            .bucket = "my-uploads",
            .match_glob = "incoming/**.txt",
        } } },
    });
    defer topic.deinit();
}
// end snippet

// snippet: pubsub-import-state
/// Is the topic still importing? `null` for a topic that is not an
/// import topic at all.
fn importing(client: *pubsub.Client) !?pubsub.IngestionState {
    var topic = try client.topic("uploads").get();
    defer topic.deinit();
    const settings = topic.value.ingestion orelse return null;
    return settings.state;
}
// end snippet

// snippet: pubsub-import-update
/// The same bucket, read as Avro from now on, with warnings logged. The
/// settings are replaced whole, so they name everything they keep.
fn importAvro(client: *pubsub.Client) !void {
    var changed = try client.topic("uploads").update(.{ .ingestion = .{ .set = .{
        .source = .{ .cloud_storage = .{ .bucket = "my-uploads", .format = .avro } },
        .log_severity = .warning,
    } } });
    defer changed.deinit();
}

/// A standard topic again: it keeps what it holds, and imports no more.
fn stopImporting(client: *pubsub.Client) !void {
    var standard = try client.topic("uploads").update(.{ .ingestion = .clear });
    defer standard.deinit();
}
// end snippet

// snippet: pubsub-tags
/// A topic bound to the tag `env: prod` as it is made. The key and the
/// value must already be there, in Resource Manager.
fn makeTagged(client: *pubsub.Client) !void {
    var topic = try client.topic("orders").create(.{
        .tags = &.{.{ .key = "my-project/env", .value = "prod" }},
    });
    defer topic.deinit();
}
// end snippet

test "the import topics guide's code and the tags example, against a scripted transport" {
    const importing_topic = "{\"name\":\"projects/my-project/topics/uploads\",\"ingestionDataSourceSettings\":{\"cloudStorage\":{\"state\":\"ACTIVE\",\"bucket\":\"my-uploads\",\"textFormat\":{\"delimiter\":\"\\n\"},\"matchGlob\":\"incoming/**.txt\"}}}";
    const standard_topic = "{\"name\":\"projects/my-project/topics/uploads\"}";
    var fake: core.testing.FakeTransport = .init(std.testing.allocator, &.{
        .{ .respond = .{ .body = importing_topic } },
        .{ .respond = .{ .body = importing_topic } },
        .{ .respond = .{ .body = "{\"name\":\"projects/my-project/topics/uploads\",\"state\":\"INGESTION_RESOURCE_ERROR\",\"ingestionDataSourceSettings\":{\"cloudStorage\":{\"state\":\"BUCKET_NOT_FOUND\",\"bucket\":\"my-uploads\",\"avroFormat\":{}},\"platformLogsSettings\":{\"severity\":\"WARNING\"}}}" } },
        .{ .respond = .{ .body = standard_topic } },
        .{ .respond = .{ .body = standard_topic } },
        .{ .respond = .{ .body = "{\"name\":\"projects/my-project/topics/orders\"}" } },
    });
    defer fake.deinit();
    var tokens: core.testing.FakeTokenProvider = .{};
    var client = try pubsub.Client.init(std.testing.allocator, std.testing.io, .{
        .project_id = "my-project",
        .token_provider = tokens.provider(),
        .transport = fake.transport(),
    });
    defer client.deinit();
    const base = "https://pubsub.googleapis.com/v1/projects/my-project/";

    try importUploads(&client);
    try std.testing.expectEqualStrings(base ++ "topics/uploads", (try fake.request(0)).url);
    try std.testing.expectEqualStrings(
        "{\"ingestionDataSourceSettings\":{\"cloudStorage\":{\"bucket\":\"my-uploads\",\"textFormat\":{\"delimiter\":\"\\n\"},\"matchGlob\":\"incoming/**.txt\"}}}",
        (try fake.request(0)).body.?,
    );

    try std.testing.expectEqual(pubsub.IngestionState.active, (try importing(&client)).?);
    try importAvro(&client);
    try std.testing.expectEqualStrings(
        "{\"topic\":{\"ingestionDataSourceSettings\":{\"cloudStorage\":{\"bucket\":\"my-uploads\",\"avroFormat\":{}},\"platformLogsSettings\":{\"severity\":\"WARNING\"}}},\"updateMask\":\"ingestionDataSourceSettings\"}",
        (try fake.request(2)).body.?,
    );
    try stopImporting(&client);
    try std.testing.expectEqualStrings("{\"topic\":{},\"updateMask\":\"ingestionDataSourceSettings\"}", (try fake.request(3)).body.?);
    try std.testing.expectEqual(null, try importing(&client));

    try makeTagged(&client);
    try std.testing.expectEqualStrings(base ++ "topics/orders", (try fake.request(5)).url);
    try std.testing.expectEqualStrings("{\"tags\":{\"my-project/env\":\"prod\"}}", (try fake.request(5)).body.?);
    try std.testing.expectEqual(6, fake.requests.items.len);
}
