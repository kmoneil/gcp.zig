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

// snippet: pubsub-fake
test "a message that is not acknowledged comes again when its lease lapses" {
    var clock: pubsub.testing.FakeClock = .{};
    var fake: pubsub.testing.FakePubSub = .init(std.testing.allocator, clock.io(), .{});
    defer fake.deinit();
    // Any token: the fake checks none.
    var token: pubsub.StaticToken = .{ .token = "unchecked" };
    var client = try pubsub.Client.init(std.testing.allocator, clock.io(), .{
        .project_id = "my-project",
        .token_provider = token.provider(),
        .transport = fake.transport(),
    });
    defer client.deinit();

    var topic = try client.topic("orders").create(.{});
    defer topic.deinit();
    const worker = client.subscription("orders-worker");
    var made = try worker.create(.{ .topic_id = "orders", .ack_deadline_seconds = 30 });
    defer made.deinit();
    var sent = try client.topic("orders").publish(&.{.{ .data = "hello" }}, .{});
    defer sent.deinit();

    var first = try worker.pull(.{});
    defer first.deinit();
    try std.testing.expectEqualStrings("hello", first.value.messages[0].data);

    // Not acknowledged. Half a minute passes on the test's clock, with no
    // sleep, and the message comes again.
    clock.now_ns += 31 * std.time.ns_per_s;
    var again = try worker.pull(.{});
    defer again.deinit();
    try std.testing.expectEqualStrings("hello", again.value.messages[0].data);
    try worker.ack(&.{again.value.messages[0].ack_id});
    try std.testing.expectEqual(0, fake.backlog("my-project", "orders-worker"));
}
// end snippet

// snippet: pubsub-fake-faults
/// Two refusals, then the publish lands, once: what the caller's retries
/// are for.
fn publishThroughAnOutage(fake: *pubsub.testing.FakePubSub, client: *pubsub.Client) !void {
    fake.refuseNext(2, 503, .publish);
    var sent = try client.topic("orders").publish(&.{.{ .data = "hello" }}, .{});
    defer sent.deinit();
    try std.testing.expectEqual(3, fake.requestCount(.publish));
    try std.testing.expectEqual(1, fake.publishedCount("my-project", "orders"));
}

/// The answer is lost and the publish has landed: sent again, the topic
/// holds the message twice, as production's would.
fn publishTwice(fake: *pubsub.testing.FakePubSub, client: *pubsub.Client) !void {
    const before = fake.publishedCount("my-project", "orders");
    fake.loseAnswers(1, .publish);
    var sent = try client.topic("orders").publish(&.{.{ .data = "hello" }}, .{});
    defer sent.deinit();
    try std.testing.expectEqual(before + 2, fake.publishedCount("my-project", "orders"));
}

/// A refusal that asks for longer than the client waits: not retried, and
/// the delay is there for the app to schedule its next try by.
fn askedToWait(fake: *pubsub.testing.FakePubSub, client: *pubsub.Client, diag: *const pubsub.Diagnostics) !void {
    const sent = fake.requestCount(.publish);
    fake.refuseNextWithDelay(1, 503, .publish, .{ .ms = 30_000 });
    try std.testing.expectError(error.Unavailable, client.topic("orders").publish(&.{.{ .data = "later" }}, .{}));
    try std.testing.expectEqual(sent + 1, fake.requestCount(.publish));
    try std.testing.expectEqual(30_000, diag.retry_after_ms.?);
}
// end snippet

// snippet: pubsub-fake-state
/// What production would learn by writing rows, the test says: here,
/// that the table is gone.
fn tableGone(fake: *pubsub.testing.FakePubSub, client: *pubsub.Client) !void {
    var made = try client.subscription("orders-rows").create(.{
        .topic_id = "orders",
        .delivery = .{ .bigquery = .{ .table = "my-project.sales.orders" } },
    });
    defer made.deinit();
    fake.setExportState("my-project", "orders-rows", .not_found);

    var read = try client.subscription("orders-rows").get();
    defer read.deinit();
    try std.testing.expectEqual(pubsub.ExportState.not_found, read.value.delivery.bigquery.state);
    try std.testing.expectEqual(.resource_error, read.value.state);
}
// end snippet

/// A fake on a clock that stands still, and a production client over it.
const InMemory = struct {
    clock: pubsub.testing.FakeClock = .{},
    fake: pubsub.testing.FakePubSub = undefined,
    token: pubsub.StaticToken = .{ .token = "none" },
    diag: pubsub.Diagnostics = .{},
    client: pubsub.Client = undefined,

    fn init(m: *InMemory) !void {
        m.fake = .init(std.testing.allocator, m.clock.io(), .{});
        errdefer m.fake.deinit();
        m.client = try .init(std.testing.allocator, m.clock.io(), .{
            .project_id = "my-project",
            .token_provider = m.token.provider(),
            .transport = m.fake.transport(),
            .diagnostics = &m.diag,
        });
    }

    fn deinit(m: *InMemory) void {
        m.client.deinit();
        m.fake.deinit();
    }
};

test "the testing guide's code" {
    var m: InMemory = .{};
    try m.init();
    defer m.deinit();
    var topic = try m.client.topic("orders").create(.{});
    topic.deinit();
    try publishThroughAnOutage(&m.fake, &m.client);
    try publishTwice(&m.fake, &m.client);
    try std.testing.expectEqual(3, m.fake.publishedCount("my-project", "orders"));
    try askedToWait(&m.fake, &m.client, &m.diag);
    try std.testing.expectEqual(3, m.fake.publishedCount("my-project", "orders"));
    try tableGone(&m.fake, &m.client);
}

test "every Pub/Sub guide's code, against the in-memory Pub/Sub as well" {
    // Replaying and purging.
    {
        var m: InMemory = .{};
        try m.init();
        defer m.deinit();
        const client = &m.client;
        var topic = try client.topic("orders").create(.{});
        topic.deinit();
        for ([_][]const u8{ "orders-worker", "stale-consumer" }) |id| {
            var sub = try client.subscription(id).create(.{ .topic_id = "orders" });
            sub.deinit();
        }
        var sent = try client.topic("orders").publish(&.{.{ .data = "kept" }}, .{});
        sent.deinit();
        try keepBacklog(client);
        var pulled = try client.subscription("orders-worker").pull(.{});
        defer pulled.deinit();
        try client.subscription("orders-worker").ack(&.{pulled.value.messages[0].ack_id});
        try std.testing.expectEqual(0, m.fake.backlog("my-project", "orders-worker"));
        // Back to the snapshot: the message is there again.
        try undoDeploy(client);
        try std.testing.expectEqual(1, m.fake.backlog("my-project", "orders-worker"));
        // A purge acknowledges it, and a replay finds nothing kept.
        try purge(client, m.clock.io());
        try std.testing.expectEqual(0, m.fake.backlog("my-project", "orders-worker"));
        try replaySince(client, .{ .nanoseconds = 0 });
        try std.testing.expectEqual(0, m.fake.backlog("my-project", "orders-worker"));
        try cutOff(client);
        var cut = try client.subscription("stale-consumer").get();
        defer cut.deinit();
        try std.testing.expect(cut.value.detached);
    }
    // Schemas.
    {
        var m: InMemory = .{};
        try m.init();
        defer m.deinit();
        const client = &m.client;
        const v1 = "{\"type\":\"record\",\"name\":\"Order\",\"fields\":[{\"name\":\"id\",\"type\":\"string\"}]}";
        const v2 = "{\"type\":\"record\",\"name\":\"Order\",\"fields\":[{\"name\":\"id\",\"type\":\"string\"},{\"name\":\"note\",\"type\":\"string\",\"default\":\"\"}]}";
        try makeOrders(client, v1);
        try check(client, v1, "{\"id\":\"7\"}");
        try addField(client, v2);
        var revisions = try client.schema("order").listRevisions(.{});
        defer revisions.deinit();
        try std.testing.expectEqual(2, revisions.value.schemas.len);
        const bad = revisions.value.schemas[0].revision_id;
        const good = revisions.value.schemas[1].revision_id;
        try undo(client, good, bad);
        var now = try client.schema("order").get(.{});
        defer now.deinit();
        try std.testing.expectEqualStrings(v1, now.value.definition);
        try pin(client, now.value.revision_id);

        var sub = try client.subscription("orders-worker").create(.{ .topic_id = "orders" });
        sub.deinit();
        var sent = try client.topic("orders").publish(&.{.{ .data = "{\"id\":\"7\"}" }}, .{});
        sent.deinit();
        var pulled = try client.subscription("orders-worker").pull(.{});
        defer pulled.deinit();
        var buf: [128]u8 = undefined;
        var out: std.Io.Writer = .fixed(&buf);
        try describe(pulled.value.messages[0], &out);
        var expected: [128]u8 = undefined;
        try std.testing.expectEqualStrings(
            try std.fmt.bufPrint(&expected, "projects/my-project/schemas/order revision {s}, as json\n", .{now.value.revision_id}),
            out.buffered(),
        );
        try release(client);
        var plain = try client.topic("orders").get();
        defer plain.deinit();
        try std.testing.expect(plain.value.schema == null);
    }
    // Delivery.
    {
        var m: InMemory = .{};
        try m.init();
        defer m.deinit();
        const client = &m.client;
        var topic = try client.topic("orders").create(.{});
        topic.deinit();
        try tableOfOrders(client);
        try pushToWebhook(client);
        try std.testing.expectError(error.FailedPrecondition, client.subscription("orders-hook").pull(.{ .return_immediately = true }));
        try pullInstead(client);
        var empty = try client.subscription("orders-hook").pull(.{ .return_immediately = true });
        empty.deinit();
        try moveWebhook(client);
        var hook = try client.subscription("orders-hook").get();
        defer hook.deinit();
        try std.testing.expectEqualStrings("https://shop2.example/pubsub", hook.value.delivery.push.endpoint);
        var rows = try client.subscription("orders-to-warehouse").get();
        defer rows.deinit();
        try std.testing.expectEqual(pubsub.ExportState.active, rows.value.delivery.bigquery.state);
    }
    // Message transforms: kept, and run on nothing.
    {
        var m: InMemory = .{};
        try m.init();
        defer m.deinit();
        const client = &m.client;
        const redact_js = "function redact(message, metadata) { return message; }";
        try redactOrders(client, redact_js);
        try skipTestOrders(client, "function skipTests(message, metadata) { return null; }");
        try addStamp(client, redact_js, "function stamp(message, metadata) { return message; }");
        var topic = try client.topic("orders").get();
        defer topic.deinit();
        try std.testing.expectEqual(2, topic.value.message_transforms.len);
        try std.testing.expect(topic.value.message_transforms[0].disabled);
        var sent = try client.topic("orders").publish(&.{.{ .data = "a test order" }}, .{});
        sent.deinit();
        try std.testing.expectEqual(1, m.fake.backlog("my-project", "orders-billing"));
        try untransformed(client);
        var plain = try client.topic("orders").get();
        defer plain.deinit();
        try std.testing.expectEqual(0, plain.value.message_transforms.len);
    }
    // Import topics, and tags.
    {
        var m: InMemory = .{};
        try m.init();
        defer m.deinit();
        const client = &m.client;
        try importUploads(client);
        try std.testing.expectEqual(pubsub.IngestionState.active, (try importing(client)).?);
        m.fake.setIngestionState("my-project", "uploads", .bucket_not_found);
        try std.testing.expectEqual(pubsub.IngestionState.bucket_not_found, (try importing(client)).?);
        try importAvro(client);
        try std.testing.expectEqual(pubsub.IngestionState.active, (try importing(client)).?);
        try stopImporting(client);
        try std.testing.expectEqual(null, try importing(client));
        try makeTagged(client);
        try std.testing.expectEqualStrings("prod", m.fake.tagValue("projects/my-project/topics/orders", "my-project/env").?);
    }
}

// snippet: pubsub-ack-outcome
/// Ships each order once. What can be done twice comes before the ack;
/// what must happen once waits for the ack to be taken.
const Shipping = struct {
    gpa: std.mem.Allocator,
    mutex: std.Io.Mutex = .init,
    /// By message id. A real one is a database.
    orders: std.StringHashMapUnmanaged(enum { reserved, shipped }) = .empty,

    fn handler(self: *Shipping) pubsub.Subscriber.DeliveryHandler {
        return .{ .ptr = self, .vtable = &.{ .handle = handle } };
    }

    fn handle(ptr: *anyopaque, io: std.Io, delivery: *pubsub.Subscriber.Delivery) anyerror!void {
        const self: *Shipping = @ptrCast(@alignCast(ptr));
        const id = delivery.message.message_id;
        try self.reserve(io, id); // harmless when the message comes again
        switch (try delivery.ack(io)) {
            // With exactly-once delivery, it will not come again.
            .taken => self.ship(io, id),
            // It may come again, and will find its reservation.
            .refused, .unknown => {},
        }
    }

    fn reserve(self: *Shipping, io: std.Io, id: []const u8) !void {
        self.mutex.lockUncancelable(io);
        defer self.mutex.unlock(io);
        if (self.orders.contains(id)) return;
        const owned = try self.gpa.dupe(u8, id);
        errdefer self.gpa.free(owned);
        try self.orders.put(self.gpa, owned, .reserved);
    }

    fn ship(self: *Shipping, io: std.Io, id: []const u8) void {
        self.mutex.lockUncancelable(io);
        defer self.mutex.unlock(io);
        self.orders.getPtr(id).?.* = .shipped;
    }
};
// end snippet

fn shippedCount(shipping: *Shipping, io: std.Io) usize {
    shipping.mutex.lockUncancelable(io);
    defer shipping.mutex.unlock(io);
    var n: usize = 0;
    var it = shipping.orders.valueIterator();
    while (it.next()) |state| {
        if (state.* == .shipped) n += 1;
    }
    return n;
}

test "the subscribing guide's code, against the in-memory Pub/Sub" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var fake: pubsub.testing.FakePubSub = .init(gpa, io, .{ .empty_pull_hold = .fromMilliseconds(20) });
    defer fake.deinit();
    var token: pubsub.StaticToken = .{ .token = "none" };
    const options: pubsub.Client.Options = .{
        .project_id = "my-project",
        .token_provider = token.provider(),
        .transport = fake.transport(),
    };
    var client = try pubsub.Client.init(gpa, io, options);
    defer client.deinit();
    var topic = try client.topic("orders").create(.{});
    topic.deinit();
    var made = try client.subscription("orders-worker").create(.{ .topic_id = "orders", .enable_exactly_once_delivery = true });
    made.deinit();
    var sent = try client.topic("orders").publish(&.{ .{ .data = "a" }, .{ .data = "b" }, .{ .data = "c" } }, .{});
    sent.deinit();

    var shipping: Shipping = .{ .gpa = gpa };
    defer {
        var it = shipping.orders.keyIterator();
        while (it.next()) |key| gpa.free(key.*);
        shipping.orders.deinit(gpa);
    }
    var subscriber = try pubsub.Subscriber.init(gpa, io, .{ .subscription_id = "orders-worker", .client = options });
    defer subscriber.deinit();
    var running = try io.concurrent(pubsub.Subscriber.runDeliveries, .{ &subscriber, shipping.handler() });
    var waited_ms: usize = 0;
    while (shippedCount(&shipping, io) < 3) : (waited_ms += 5) {
        if (waited_ms > 10_000) {
            subscriber.stop();
            running.await(io) catch {};
            return error.TestNotShipped;
        }
        try io.sleep(.fromMilliseconds(5), .awake);
    }
    subscriber.stop();
    try running.await(io);
    try std.testing.expectEqual(3, shipping.orders.count());
    try std.testing.expectEqual(0, fake.backlog("my-project", "orders-worker"));
}

// snippet: pubsub-publish-request
/// Writes the request a publish of `messages` will send, then sends it.
fn showAndPublish(
    topic: pubsub.Topic,
    messages: []const pubsub.Message,
    options: pubsub.PublishOptions,
    out: *std.Io.Writer,
) !pubsub.Owned(pubsub.PublishResult) {
    var request = try topic.publishRequest(messages, options);
    defer request.deinit();
    try out.print("{t} {s}\n{s}\n", .{ request.value.method, request.value.url, request.value.body });
    if (request.value.gzip) try out.writeAll("(sent gzip-compressed)\n");
    return topic.publish(messages, options);
}
// end snippet

test "the publishing guide's request preview, against the in-memory Pub/Sub" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var fake: pubsub.testing.FakePubSub = .init(gpa, io, .{});
    defer fake.deinit();
    var token: pubsub.StaticToken = .{ .token = "none" };
    var client = try pubsub.Client.init(gpa, io, .{
        .project_id = "my-project",
        .token_provider = token.provider(),
        .transport = fake.transport(),
    });
    defer client.deinit();
    var topic = try client.topic("orders").create(.{});
    topic.deinit();

    var out: std.Io.Writer.Allocating = .init(gpa);
    defer out.deinit();
    var sent = try showAndPublish(client.topic("orders"), &.{.{ .data = "hello", .attributes = &.{.{ .key = "origin", .value = "zig" }} }}, .{ .ordering_key = "user-42" }, &out.writer);
    sent.deinit();
    try std.testing.expectEqualStrings(
        \\POST https://pubsub.googleapis.com/v1/projects/my-project/topics/orders:publish
        \\{"messages":[{"data":"aGVsbG8=","attributes":{"origin":"zig"},"orderingKey":"user-42"}]}
        \\
    , out.written());

    out.clearRetainingCapacity();
    const long: [300]u8 = @splat('x');
    var big = try showAndPublish(client.topic("orders"), &.{.{ .data = &long }}, .{ .compression = .{} }, &out.writer);
    big.deinit();
    try std.testing.expect(std.mem.endsWith(u8, out.written(), "\n(sent gzip-compressed)\n"));

    // Refused before sending, the same way publish refuses it.
    try std.testing.expectError(error.InvalidMessage, showAndPublish(client.topic("orders"), &.{.{}}, .{}, &out.writer));
}

const logging = @import("logging");

/// How many entries the Logging guides' code showed.
var shown: usize = 0;

fn show(entry: logging.Entry) void {
    _ = entry;
    shown += 1;
}

fn note(what: []const u8) void {
    _ = what;
}

// snippet: logging-first
/// The last hour's errors from Cloud Run, newest first, two pages of them.
fn newestErrors(client: *logging.Client, now: std.Io.Timestamp) !void {
    var query = try client.query(.{
        .filter = "resource.type = \"cloud_run_revision\"",
        .min_severity = .@"error",
        .since = .{ .nanoseconds = now.nanoseconds - std.time.ns_per_hour },
        .until = now,
    });
    defer query.deinit();

    var first = try query.page(null);
    defer first.deinit();
    for (first.value.entries) |entry| show(entry);
    // An empty page with a token is the server out of time, not out of
    // entries: only a null token ends the listing.
    if (first.value.next_page_token) |token| {
        var second = try query.page(token);
        defer second.deinit();
        for (second.value.entries) |entry| show(entry);
    }
}
// end snippet

// snippet: logging-pages
/// Every entry of a query, page after page, stopping after `max_empty`
/// empty pages in a row.
fn readAll(query: *logging.Query, max_empty: usize, seen: *usize) !void {
    var token: ?[]const u8 = null;
    var empty_in_a_row: usize = 0;
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    while (true) {
        var page = try query.page(token);
        defer page.deinit();
        seen.* += page.value.entries.len;
        empty_in_a_row = if (page.value.entries.len == 0) empty_in_a_row + 1 else 0;
        const next = page.value.next_page_token orelse return;
        if (empty_in_a_row >= max_empty) return;
        token = try arena.allocator().dupe(u8, next);
    }
}
// end snippet

fn sharedBudget(gpa: std.mem.Allocator, io: std.Io, token: logging.TokenProvider) !void {
    // snippet: logging-budget
    var budget: logging.ReadBudget = .init(60);
    var table = try logging.Client.init(gpa, io, .{
        .project_id = "my-project",
        .token_provider = token,
        .read_budget = &budget,
    });
    defer table.deinit();
    var tail = try logging.Client.init(gpa, io, .{
        .project_id = "my-project",
        .token_provider = token,
        .read_budget = &budget,
    });
    defer tail.deinit();
    // end snippet
    try std.testing.expectEqual(table.budget, tail.budget);
}

fn tailFor(client: *logging.Client, io: std.Io, polls: usize) !void {
    var polls_left = polls;
    // snippet: logging-tail
    var tail = try client.tail(.{
        .filter = "resource.type = \"cloud_run_revision\"",
        .min_severity = .warning,
    });
    defer tail.deinit();
    while (polls_left > 0) : (polls_left -= 1) {
        try io.sleep(.fromSeconds(5), .awake);
        var batch = try tail.poll();
        defer batch.deinit();
        for (batch.value.entries) |entry| show(entry);
        if (batch.value.behind) note("catching up");
        if (batch.value.stopped) |_| note("paused for the read quota");
    }
    // end snippet
}

fn pick(client: *logging.Client, gpa: std.mem.Allocator, arena: std.mem.Allocator, choices: *std.ArrayList([]const u8)) !void {
    // snippet: logging-picker
    var picker = try client.picker(.{ .project = "my-project" });
    defer picker.deinit();
    if (picker.value.list_denied) {
        // A Logs View Accessor may read views but not list them.
        return error.AskForViewNames;
    }
    // The picker's memory goes with it: keep copies.
    for (picker.value.buckets) |b| {
        for (b.views) |v| try choices.append(gpa, try arena.dupe(u8, v.name.view));
    }
    // end snippet
}

test "the Logging guides' code, against a fake" {
    var clock: logging.testing.FakeClock = .{ .now_ns = 1_792_141_200 * std.time.ns_per_s };
    const io = clock.io();
    var fake: logging.testing.FakeLogging = .init(std.testing.allocator, io);
    defer fake.deinit();
    const name = try fake.logName(.{ .project = "my-project" }, "run.googleapis.com/stderr");
    for (0..3) |i| try fake.write(.{
        .log_name = name,
        .timestamp = .{ .nanoseconds = clock.now_ns - @as(i96, @intCast(i + 1)) * std.time.ns_per_min },
        .severity = .@"error",
        .resource_type = "cloud_run_revision",
        .payload = .{ .text = "payment failed" },
    });
    var token: logging.StaticToken = .{ .token = "test" };
    var client = try logging.Client.init(std.testing.allocator, io, .{
        .project_id = "my-project",
        .token_provider = token.provider(),
        .transport = fake.transport(),
    });
    defer client.deinit();

    shown = 0;
    fake.shortenNext(1, 2);
    try newestErrors(&client, .{ .nanoseconds = clock.now_ns });
    try std.testing.expectEqual(3, shown);

    var query = try client.query(.{ .page_size = 1 });
    defer query.deinit();
    var seen: usize = 0;
    fake.searchingNext(1);
    try readAll(&query, 2, &seen);
    try std.testing.expectEqual(3, seen);

    try sharedBudget(std.testing.allocator, io, token.provider());

    shown = 0;
    try fake.write(.{ .log_name = name, .timestamp = .{ .nanoseconds = clock.now_ns + std.time.ns_per_s }, .severity = .warning, .resource_type = "cloud_run_revision" });
    try tailFor(&client, io, 2);
    try std.testing.expectEqual(1, shown);

    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    var choices: std.ArrayList([]const u8) = .empty;
    defer choices.deinit(std.testing.allocator);
    try pick(&client, std.testing.allocator, arena.allocator(), &choices);
    try std.testing.expectEqual(3, choices.items.len);
    try std.testing.expectEqualStrings("_Default", choices.items[0]);
    try std.testing.expectEqualStrings("_AllLogs", choices.items[1]);
}

// snippet: logging-fake
test "the newest error, from a fake" {
    var clock: logging.testing.FakeClock = .{ .now_ns = 1_792_141_200 * std.time.ns_per_s };
    var fake: logging.testing.FakeLogging = .init(std.testing.allocator, clock.io());
    defer fake.deinit();
    const name = try fake.logName(.{ .project = "test" }, "app");
    try fake.write(.{ .log_name = name, .timestamp = .{ .nanoseconds = clock.now_ns - std.time.ns_per_s }, .severity = .@"error", .payload = .{ .text = "boom" } });

    var token: logging.StaticToken = .{ .token = "test" };
    var client = try logging.Client.init(std.testing.allocator, clock.io(), .{
        .project_id = "test",
        .token_provider = token.provider(),
        .transport = fake.transport(),
    });
    defer client.deinit();
    var query = try client.query(.{ .min_severity = .warning });
    defer query.deinit();
    var page = try query.page(null);
    defer page.deinit();
    try std.testing.expectEqualStrings("boom", page.value.entries[0].payload.text);
}
// end snippet

const rm = @import("resource_manager");

// snippet: rm-first
/// The switcher's list: every project the credentials can see, and where
/// each sits, refreshed every 15 minutes or so and filtered locally.
fn refresh(client: *rm.Client, gpa: std.mem.Allocator) !void {
    var list = try client.allProjects(.{});
    defer list.deinit();
    var names = try client.parentNames(.{});
    defer names.deinit();
    for (list.value.projects) |p| {
        const where = if (p.parent) |parent| names.value.label(parent) else "";
        try remember(gpa, p.project_id, p.label(), where);
    }
}
// end snippet

/// What the Resource Manager guides' code kept, as an app's cache would.
var remembered: std.ArrayList([3][]const u8) = .empty;

fn remember(gpa: std.mem.Allocator, id: []const u8, label: []const u8, where: []const u8) !void {
    try remembered.append(gpa, .{ try gpa.dupe(u8, id), try gpa.dupe(u8, label), try gpa.dupe(u8, where) });
}

fn forget(gpa: std.mem.Allocator) void {
    for (remembered.items) |r| for (r) |s| gpa.free(s);
    remembered.clearAndFree(gpa);
}

// snippet: rm-match
/// What a switcher matches as a person types: the letters anywhere in the
/// display name, the project id or the number, case aside.
fn matches(p: rm.Project, letters: []const u8) bool {
    if (std.ascii.findIgnoreCase(p.label(), letters) != null) return true;
    if (std.ascii.findIgnoreCase(p.project_id, letters) != null) return true;
    var buf: [20]u8 = undefined;
    const number = std.fmt.bufPrint(&buf, "{d}", .{p.number}) catch unreachable;
    return std.mem.indexOf(u8, number, letters) != null;
}
// end snippet

fn countPages(client: *rm.Client, arena: std.mem.Allocator) !usize {
    var count: usize = 0;
    // snippet: rm-pages
    var search = try client.searchProjects(.{ .query = "labels.team:payments", .page_size = 100 });
    defer search.deinit();
    var token: ?[]const u8 = null;
    while (true) {
        var page = try search.page(token);
        defer page.deinit();
        count += page.value.items.len;
        // Only a null token ends a search; keep the next one past deinit.
        token = if (page.value.next_page_token) |t| try arena.dupe(u8, t) else break;
    }
    // end snippet
    return count;
}

fn explain(client: *rm.Client, gpa: std.mem.Allocator) !?[]const u8 {
    // snippet: rm-refusal
    var list = client.allProjects(.{}) catch |err| switch (err) {
        error.ServiceDisabled, error.QuotaProjectDenied => {
            const r = client.lastConsumerRefusal().?;
            return try std.fmt.allocPrint(gpa, "{s} cannot be charged for this call: {s}", .{
                r.consumer, r.link orelse "no link sent",
            });
        },
        else => return err,
    };
    defer list.deinit();
    // end snippet
    return null;
}

test "the Resource Manager guides' code, against a fake" {
    const gpa = std.testing.allocator;
    var clock: rm.testing.FakeClock = .{ .now_ns = 1_792_141_200 * std.time.ns_per_s };
    var fake: rm.testing.FakeResourceManager = .init(gpa, clock.io(), .{});
    defer fake.deinit();
    try fake.addOrganization(.{ .name = "organizations/1", .domain = "example.com" });
    try fake.addFolder(.{ .name = "folders/2", .parent = "organizations/1", .display_name = "Payments" });
    try fake.addProject(.{ .number = 41, .project_id = "pay-prod", .display_name = "Payments (prod)", .parent = "folders/2", .labels = &.{.{ .key = "team", .value = "payments" }} });
    try fake.addProject(.{ .number = 42, .project_id = "web", .parent = "organizations/1" });
    try fake.addProject(.{ .number = 43, .project_id = "oauth-client", .api_enabled = false });
    try fake.addPrincipal("person", "my-home");
    try fake.grant("person", "organizations/1");
    var token: rm.StaticToken = .{ .token = "person" };
    var client = try rm.Client.init(gpa, clock.io(), .{ .token_provider = token.provider(), .transport = fake.transport() });
    defer client.deinit();

    defer forget(gpa);
    try refresh(&client, gpa);
    try std.testing.expectEqual(2, remembered.items.len);
    try std.testing.expectEqualStrings("Payments", remembered.items[0][2]);
    try std.testing.expectEqualStrings("example.com", remembered.items[1][2]);

    var page = try client.getProject("pay-prod");
    defer page.deinit();
    try std.testing.expect(matches(page.value, "PAY"));
    try std.testing.expect(matches(page.value, "41"));
    try std.testing.expect(!matches(page.value, "web"));

    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    try std.testing.expectEqual(1, try countPages(&client, arena.allocator()));

    try std.testing.expectEqual(null, try explain(&client, gpa));
    // A person whose OAuth client's project has the API off.
    try fake.addPrincipal("app-user", "oauth-client");
    token.token = "app-user";
    const why = (try explain(&client, gpa)).?;
    defer gpa.free(why);
    try std.testing.expect(std.mem.startsWith(u8, why, "projects/43 cannot be charged"));
}

// snippet: rm-fake
test "the switcher finds a project by a few letters, from a fake" {
    var clock: rm.testing.FakeClock = .{};
    var fake: rm.testing.FakeResourceManager = .init(std.testing.allocator, clock.io(), .{});
    defer fake.deinit();
    try fake.addProject(.{ .number = 1, .project_id = "payments-prod", .display_name = "Payments" });
    try fake.addProject(.{ .number = 2, .project_id = "web-front", .display_name = "Web" });
    try fake.addPrincipal("person", "payments-prod");
    try fake.grant("person", "payments-prod");
    try fake.grant("person", "web-front");

    var token: rm.StaticToken = .{ .token = "person" };
    var client = try rm.Client.init(std.testing.allocator, clock.io(), .{
        .token_provider = token.provider(),
        .transport = fake.transport(),
    });
    defer client.deinit();
    var list = try client.allProjects(.{});
    defer list.deinit();
    try std.testing.expectEqual(2, list.value.projects.len);
    try std.testing.expect(matches(list.value.projects[0], "pay"));
}
// end snippet

const auth = @import("auth");

// snippet: auth-account
/// Who the app is signed in as, for its status bar. When the credentials
/// cannot name an account, Diagnostics say why.
fn signedInAs(creds: auth.Credentials, io: std.Io, arena: std.mem.Allocator) ![]const u8 {
    return try creds.account(io, arena) orelse "an account the credentials cannot name";
}
// end snippet

test "the auth guide's code: the account a gcloud login names" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = auth.Lookup.adc_file_name, .data =
        \\{"type": "authorized_user", "account": "", "client_id": "gcloud.apps.googleusercontent.com",
        \\ "client_secret": "s", "refresh_token": "r"}
    });
    var dir_buf: [128]u8 = undefined;
    const dir = try std.fmt.bufPrint(&dir_buf, ".zig-cache/tmp/{s}", .{&tmp.sub_path});
    // The token endpoint's answer to a refresh, its id_token naming the
    // login's account for gcloud's client.
    var fake: core.testing.FakeTransport = .init(std.testing.allocator, &.{.{ .respond = .{
        .body = "{\"access_token\":\"ya29.x\",\"expires_in\":3599,\"token_type\":\"Bearer\",\"id_token\":\"eyJhbGciOiJSUzI1NiIsImtpZCI6ImsxIiwidHlwIjoiSldUIn0.eyJpc3MiOiJodHRwczovL2FjY291bnRzLmdvb2dsZS5jb20iLCJhdWQiOiJnY2xvdWQuYXBwcy5nb29nbGV1c2VyY29udGVudC5jb20iLCJhenAiOiJnY2xvdWQuYXBwcy5nb29nbGV1c2VyY29udGVudC5jb20iLCJzdWIiOiIxMDQyMjM0OTc1NTMxMDgwMTExMTEiLCJlbWFpbCI6InBlcnNvbkBleGFtcGxlLmNvbSIsImVtYWlsX3ZlcmlmaWVkIjp0cnVlfQ.c2lnbmF0dXJl\"}",
    } }});
    defer fake.deinit();
    var creds = try auth.findDefault(std.testing.allocator, std.testing.io, .{ .gcloud_config_dir = dir }, .{ .transport = fake.transport() });
    defer creds.deinit();
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    try std.testing.expectEqualStrings("person@example.com", try signedInAs(creds, std.testing.io, arena.allocator()));
    try std.testing.expectEqual(1, fake.requests.items.len);
}

const er = @import("error_reporting");

// snippet: er-dashboard
/// The dashboard's table: the busiest groups over a day, each with its
/// hourly counts for a trend chart, and whether it is new in the period.
fn dashboard(client: *er.Client, rows: *std.ArrayList(Row), gpa: std.mem.Allocator) !void {
    var query = try client.groupStats(.{ .period = .day, .timed_count_seconds = 3600, .page_size = 20 });
    defer query.deinit();
    var page = try query.page(null);
    defer page.deinit();
    const begin = page.value.time_range_begin.?;
    for (page.value.items) |s| {
        const new = if (s.first_seen) |f| f.nanoseconds >= begin.nanoseconds else false;
        var trend: [24]u64 = @splat(0);
        for (s.timed_counts, 0..) |t, i| if (i < trend.len) {
            trend[i] = t.count;
        };
        try rows.append(gpa, .{
            .group_id = try gpa.dupe(u8, s.group.id),
            .headline = try gpa.dupe(u8, if (s.representative) |r| r.headline() else ""),
            .count = s.count,
            .new = new,
            .trend = trend,
        });
    }
}
// end snippet

// snippet: er-resolve
/// Marks a group resolved, keeping its tracking issues: a new error will
/// open it again on its own.
fn resolve(client: *er.Client, group_id: []const u8) !void {
    var group = try client.group(group_id).setStatus(.resolved);
    defer group.deinit();
}
// end snippet

const Row = struct { group_id: []const u8, headline: []const u8, count: u64, new: bool, trend: [24]u64 };

// snippet: er-fake
/// A dashboard test with deterministic data: errors reported to the fake,
/// on a clock the test sets, read back through a real client.
fn dashboardTest(gpa: std.mem.Allocator) !void {
    var clock: er.testing.FakeClock = .{ .now_ns = 1_792_324_800 * std.time.ns_per_s };
    var fake: er.testing.FakeErrorReporting = .init(gpa, clock.io(), .{ .project_id = "my-project" });
    defer fake.deinit();
    const trace = "java.lang.NullPointerException: customer is null\n\tat Billing.charge(Billing.java:88)";
    for (0..3) |i| _ = try fake.report(.{
        .message = trace,
        .time = .{ .nanoseconds = (1_792_324_800 - @as(i96, @intCast(i)) * 3600) * std.time.ns_per_s },
        .service = .{ .service = "billing" },
    });
    var token: er.StaticToken = .{ .token = "test" };
    var client = try er.Client.init(gpa, clock.io(), .{
        .project_id = "my-project",
        .token_provider = token.provider(),
        .transport = fake.transport(),
    });
    defer client.deinit();

    var rows: std.ArrayList(Row) = .empty;
    defer {
        for (rows.items) |r| {
            gpa.free(r.group_id);
            gpa.free(r.headline);
        }
        rows.deinit(gpa);
    }
    try dashboard(&client, &rows, gpa);
    try std.testing.expectEqual(1, rows.items.len);
    try std.testing.expectEqual(3, rows.items[0].count);
    try std.testing.expectEqualStrings("java.lang.NullPointerException: customer is null", rows.items[0].headline);
}
// end snippet

test "the Error Reporting guides' code, against a fake" {
    try dashboardTest(std.testing.allocator);
    var clock: er.testing.FakeClock = .{ .now_ns = 1_792_324_800 * std.time.ns_per_s };
    var fake: er.testing.FakeErrorReporting = .init(std.testing.allocator, clock.io(), .{});
    defer fake.deinit();
    const id = try fake.report(.{ .message = "TypeError: x" });
    var token: er.StaticToken = .{ .token = "test" };
    var client = try er.Client.init(std.testing.allocator, clock.io(), .{ .project_id = "my-project", .token_provider = token.provider(), .transport = fake.transport() });
    defer client.deinit();
    try resolve(&client, id);
    try std.testing.expectEqual(.resolved, fake.status(id).?);
}
