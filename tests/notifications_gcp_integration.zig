//! Cloud Storage's Pub/Sub notifications against Google: GCP_TEST_PROJECT,
//! GCP_TEST_BUCKET (a bucket in that project) and GCP_TEST_TOKEN, allowed
//! to manage the bucket's notifications and to create Pub/Sub topics and
//! subscriptions and set their policies. Each test makes a topic and a
//! subscription named `zigps-ntf-` and 8 hex digits, and a configuration
//! for objects under that name, and deletes them all, even when it fails.
//! With any variable unset, every test skips.
//!
//! The import topic test meets Cloud Storage from Pub/Sub's side, and
//! needs two variables more: GCP_TEST_IMPORT_BUCKET, a bucket Pub/Sub's
//! service agent may read (storage.buckets.get, storage.objects.list and
//! storage.objects.get), and GCP_TEST_PROJECT_NUMBER, for that agent's
//! address. It grants the agent nothing on the bucket: it makes it a
//! publisher of its own topic, which goes with the topic.

const std = @import("std");
const pubsub = @import("pubsub");
const storage = @import("storage");
const testing = std.testing;
const gpa = testing.allocator;

const Fixture = struct {
    env: std.process.Environ.Map,
    token: storage.StaticToken,
    gcs_diag: storage.Diagnostics,
    ps_diag: pubsub.Diagnostics,
    gcs: storage.Client,
    ps: pubsub.Client,
    project: []const u8,
    bucket_name: []const u8,
    /// `zigps-ntf-` and 8 hex digits: the topic, the subscription, and the
    /// objects' prefix without its slash.
    name: [18]u8,

    fn init(f: *Fixture) !bool {
        f.env = try testing.environ.createMap(gpa);
        errdefer f.env.deinit();
        const project = f.env.get("GCP_TEST_PROJECT");
        const bucket = f.env.get("GCP_TEST_BUCKET");
        const token = f.env.get("GCP_TEST_TOKEN");
        if (project == null or bucket == null or token == null) {
            f.env.deinit();
            return false;
        }
        f.project = project.?;
        f.bucket_name = bucket.?;
        f.token = .{ .token = std.mem.trim(u8, token.?, &std.ascii.whitespace) };
        var random: [4]u8 = undefined;
        testing.io.random(&random);
        _ = try std.fmt.bufPrint(&f.name, "zigps-ntf-{x}", .{random});
        f.gcs_diag = .{};
        f.ps_diag = .{};
        f.gcs = try .init(gpa, testing.io, .{ .project_id = f.project, .token_provider = f.token.provider(), .diagnostics = &f.gcs_diag });
        errdefer f.gcs.deinit();
        f.ps = try .init(gpa, testing.io, .{ .project_id = f.project, .token_provider = f.token.provider(), .diagnostics = &f.ps_diag });
        return true;
    }

    fn deinit(f: *Fixture) void {
        f.ps.subscription(&f.name).delete() catch {};
        f.ps.topic(&f.name).delete() catch {};
        f.ps.deinit();
        f.gcs.deinit();
        f.env.deinit();
    }

    fn prefixed(f: *const Fixture, buf: []u8, rest: []const u8) []const u8 {
        return std.fmt.bufPrint(buf, "{s}/{s}", .{ &f.name, rest }) catch unreachable;
    }
};

const Seen = struct {
    kind: storage.EventType,
    generation: u64,
    overwrote: ?u64,
    overwritten_by: ?u64,
};

test "notifications against Google: the grant, a create, each kind of change decoded, and the cleanup" {
    var f: Fixture = undefined;
    if (!try f.init()) return error.SkipZigTest;
    defer f.deinit();

    const topic = f.ps.topic(&f.name);
    var made_topic = try topic.create(.{});
    made_topic.deinit();
    var made_sub = try f.ps.subscription(&f.name).create(.{ .topic_id = &f.name });
    made_sub.deinit();

    // The service agent publishes; grant it, once.
    var agent = try f.gcs.serviceAgent();
    defer agent.deinit();
    var member_buf: [160]u8 = undefined;
    const member = try std.fmt.bufPrint(&member_buf, "serviceAccount:{s}", .{agent.value});
    var policy = try topic.addIamBinding("roles/pubsub.publisher", member);
    try testing.expect(policy.value.grants("roles/pubsub.publisher", member));
    policy.deinit();
    var again = try topic.addIamBinding("roles/pubsub.publisher", member);
    again.deinit();

    var prefix_buf: [32]u8 = undefined;
    const bucket = f.gcs.bucket(f.bucket_name);
    // A fresh grant took a few seconds to reach Cloud Storage.
    var waited_ms: u32 = 0;
    var config = while (true) {
        break bucket.createNotification(.{
            .topic = .{ .project = f.project, .topic = &f.name },
            .custom_attributes = &.{.{ .key = "team", .value = "data" }},
            .object_name_prefix = f.prefixed(&prefix_buf, ""),
        }) catch |err| {
            if (err != error.TopicNotPublishable or waited_ms >= 90_000) return err;
            try testing.io.sleep(.fromMilliseconds(3000), .awake);
            waited_ms += 3000;
            continue;
        };
    };
    defer config.deinit();
    defer bucket.deleteNotification(config.value.id) catch {};
    try testing.expectEqualStrings(config.value.id, config.value.etag.?);

    var listed = try bucket.listNotifications();
    defer listed.deinit();
    const found = for (listed.value) |n| {
        if (std.mem.eql(u8, n.id, config.value.id)) break true;
    } else false;
    try testing.expect(found);

    // Messages flowed within seconds of a create, when measured: wait a
    // little before the first change.
    try testing.io.sleep(.fromMilliseconds(10_000), .awake);
    var name_buf: [32]u8 = undefined;
    const object = bucket.object(f.prefixed(&name_buf, "a.txt"));
    var first = try object.upload("one", .{ .content_type = "text/plain" });
    defer first.deinit();
    var second = try object.upload("two", .{ .content_type = "text/plain" });
    defer second.deinit();
    var patched = try object.updateMetadata(.{ .edit = .{ .change = &.{.{ .key = "k", .value = "v" }} } });
    patched.deinit();
    try object.delete(.{});

    const g1 = first.value.generation;
    const g2 = second.value.generation;
    const want = [_]Seen{
        .{ .kind = .finalize, .generation = g1, .overwrote = null, .overwritten_by = null },
        .{ .kind = .delete, .generation = g1, .overwrote = null, .overwritten_by = g2 },
        .{ .kind = .finalize, .generation = g2, .overwrote = g1, .overwritten_by = null },
        .{ .kind = .metadata_update, .generation = g2, .overwrote = null, .overwritten_by = null },
        .{ .kind = .delete, .generation = g2, .overwrote = null, .overwritten_by = null },
    };

    var seen: std.ArrayList(Seen) = .empty;
    defer seen.deinit(gpa);
    var keys: std.StringHashMapUnmanaged(void) = .empty;
    defer {
        var it = keys.keyIterator();
        while (it.next()) |k| gpa.free(k.*);
        keys.deinit(gpa);
    }
    const sub = f.ps.subscription(&f.name);
    const deadline = std.Io.Clock.awake.now(testing.io).toMilliseconds() + 120_000;
    while (seen.items.len < want.len and std.Io.Clock.awake.now(testing.io).toMilliseconds() < deadline) {
        var pulled = try sub.pull(.{ .max_messages = 50, .return_immediately = true });
        defer pulled.deinit();
        if (pulled.value.messages.len == 0) {
            try testing.io.sleep(.fromMilliseconds(500), .awake);
            continue;
        }
        var ids: std.ArrayList([]const u8) = .empty;
        defer ids.deinit(gpa);
        for (pulled.value.messages) |message| {
            try ids.append(gpa, message.ack_id);
            var event = try storage.decodeEvent(gpa, message, .{});
            defer event.deinit();
            const e = event.value;
            try testing.expectEqualStrings(f.bucket_name, e.bucket);
            try testing.expectEqualStrings(config.value.id, e.config.?.id);
            try testing.expectEqualStrings(f.bucket_name, e.config.?.bucket);
            try testing.expectEqualStrings("team", e.custom_attributes[0].key);
            try testing.expectEqualStrings(object.name, e.info.?.name);
            const gop = try keys.getOrPut(gpa, e.key);
            if (gop.found_existing) continue;
            gop.key_ptr.* = try gpa.dupe(u8, e.key);
            try seen.append(gpa, .{ .kind = e.kind, .generation = e.generation, .overwrote = e.overwrote_generation, .overwritten_by = e.overwritten_by_generation });
        }
        try sub.ack(ids.items);
    }
    try testing.expectEqual(want.len, seen.items.len);
    for (want) |w| {
        const ok = for (seen.items) |s| {
            if (std.meta.eql(s, w)) break true;
        } else false;
        if (!ok) {
            std.debug.print("missing {any}; saw {any}\n", .{ w, seen.items });
            return error.TestExpectedEqual;
        }
    }

    var got = try bucket.getNotification(config.value.id);
    got.deinit();
    try bucket.deleteNotification(config.value.id);
    try testing.expectError(error.NotFound, bucket.getNotification(config.value.id));
    try testing.expectEqualStrings("The requested resource was not found.", f.gcs_diag.message());
}

test "notifications against Google: a topic Cloud Storage cannot publish to" {
    var f: Fixture = undefined;
    if (!try f.init()) return error.SkipZigTest;
    defer f.deinit();
    const bucket = f.gcs.bucket(f.bucket_name);

    // No such topic: 400, as measured.
    try testing.expectError(error.TopicNotPublishable, bucket.createNotification(.{ .topic = .{ .project = f.project, .topic = &f.name } }));
    try testing.expectEqual(400, f.gcs_diag.http_status);

    // A topic the service agent was never granted: 403 forbidden.
    var made_topic = try f.ps.topic(&f.name).create(.{});
    made_topic.deinit();
    try testing.expectError(error.TopicNotPublishable, bucket.createNotification(.{ .topic = .{ .project = f.project, .topic = &f.name } }));
    try testing.expectEqualStrings("forbidden", f.gcs_diag.status());
}

test "an import topic against Google: an uploaded object's lines arrive as messages" {
    var f: Fixture = undefined;
    if (!try f.init()) return error.SkipZigTest;
    defer f.deinit();
    const import_bucket = f.env.get("GCP_TEST_IMPORT_BUCKET") orelse return error.SkipZigTest;
    const number = f.env.get("GCP_TEST_PROJECT_NUMBER") orelse return error.SkipZigTest;

    const topic = f.ps.topic(&f.name);
    var made_topic = try topic.create(.{});
    made_topic.deinit();
    const sub = f.ps.subscription(&f.name);
    var made_sub = try sub.create(.{ .topic_id = &f.name });
    made_sub.deinit();

    // Pub/Sub imports as its service agent, which must be a publisher of
    // the topic. Without that the topic is made all the same, and then
    // reads `.publish_permission_denied` (measured 2026-10-12).
    var member_buf: [160]u8 = undefined;
    const member = try std.fmt.bufPrint(&member_buf, "serviceAccount:service-{s}@gcp-sa-pubsub.iam.gserviceaccount.com", .{number});
    var policy = try topic.addIamBinding("roles/pubsub.publisher", member);
    policy.deinit();

    // An object that is there before the topic imports, with no newline
    // after its last line.
    var name_buf: [40]u8 = undefined;
    const object = f.gcs.bucket(import_bucket).object(f.prefixed(&name_buf, "a.txt"));
    var uploaded = try object.upload("one\ntwo\nthree", .{ .content_type = "text/plain" });
    uploaded.deinit();
    defer object.delete(.{}) catch {};

    var glob_buf: [32]u8 = undefined;
    const glob = f.prefixed(&glob_buf, "**");
    var importing = try topic.update(.{ .ingestion = .{ .set = .{
        .source = .{ .cloud_storage = .{ .bucket = import_bucket, .match_glob = glob } },
    } } });
    defer importing.deinit();
    const made = importing.value.ingestion orelse return error.TestExpectedEqual;
    try testing.expectEqualStrings(import_bucket, made.source.?.cloud_storage.bucket);
    try testing.expectEqualStrings(glob, made.source.?.cloud_storage.match_glob);
    try testing.expectEqualStrings("\n", made.source.?.cloud_storage.format.text.delimiter);
    try testing.expectEqual(pubsub.IngestionState.active, made.state);

    // The three lines, in any order: 73 seconds after the topic was made
    // to import, when measured.
    const lines = [_][]const u8{ "one", "two", "three" };
    var seen = [_]bool{ false, false, false };
    var count: usize = 0;
    var waited_ms: u32 = 0;
    while (count < lines.len and waited_ms < 300_000) {
        var batch = try sub.pull(.{ .max_messages = 10, .return_immediately = true });
        defer batch.deinit();
        for (batch.value.messages) |m| {
            try sub.ack(&.{m.ack_id});
            const i = for (lines, 0..) |line, i| {
                if (std.mem.eql(u8, m.data, line)) break i;
            } else return error.TestUnexpectedMessage;
            if (!seen[i]) count += 1;
            seen[i] = true;
        }
        if (batch.value.messages.len == 0) {
            try testing.io.sleep(.fromMilliseconds(2000), .awake);
            waited_ms += 2000;
        }
    }
    try testing.expectEqual(lines.len, count);

    var read = try topic.get();
    defer read.deinit();
    try testing.expectEqual(pubsub.TopicInfo.State.active, read.value.state);
    try testing.expectEqual(pubsub.IngestionState.active, read.value.ingestion.?.state);
    try testing.expectEqual(pubsub.Ingestion.LogSeverity.disabled, read.value.ingestion.?.log_severity);

    // A standard topic again.
    var standard = try topic.update(.{ .ingestion = .clear });
    defer standard.deinit();
    try testing.expectEqual(null, standard.value.ingestion);
}
