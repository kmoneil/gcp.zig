//! A Pub/Sub for tests, behind the `Transport` seam: topics and
//! subscriptions kept in memory, and messages that go from a publish to
//! every subscription's pulls, answered and refused as production answered
//! and refused when measured on 2026-10-12
//! (`_tmp/pubsub-extras/production-fake-1.txt` to `-3.txt`). It is written
//! from what production did, not from this library's encoder: it parses
//! request JSON and masks with code of its own, so a body or a mask the
//! encoder gets wrong is refused or misapplied here as production would.
//! Test code only.
//!
//! What it models:
//!
//! - Topics: create, get, update, delete, a project's list in pages, and a
//!   topic's list of subscriptions. Labels, message retention, a KMS key
//!   name and a storage policy are kept and read back; nothing is enforced
//!   from the last three.
//! - Subscriptions: create, get, update, delete and the list, with the
//!   defaults production fills in (a 10 second ack deadline, 7 days of
//!   retention, expiry after 31 days), its bounds on each, and the fields
//!   it will not change. A deleted topic leaves its subscriptions reading
//!   `_deleted-topic_`, with what they hold.
//! - Publish: ids, decimal and consecutive; the limits on a request, its
//!   messages, their attributes and their ordering key, each refused in
//!   production's words; one ordering key a request.
//! - Pull, acknowledge and modifyAckDeadline. A subscription gets what is
//!   published after it is made. A pulled message is out on a lease until
//!   its deadline on the fake's clock, then comes again. **An ack takes
//!   only while the message is out on a lease**: after a lapse, or after
//!   a nack, an ack with the old id is answered 200 and forgotten, as
//!   production's was, and once the message is out again an old id
//!   acknowledges it. So an ack id names the message, and the lease
//!   decides.
//! - Order: none. Production returned twelve messages published one by
//!   one as 03, 11, 00, 06 and so on, so a pull here returns what it has
//!   in an order of the fake's choosing, unless `Options.shuffle` is off.
//! - Faults, on command: `refuseNext`, `loseAnswers`, `dropNext`.
//!
//! Its clock is the `io` it is given: with `core.testing.FakeClock`, a
//! lease lapses when the test moves the clock and not before. It is safe
//! to use from several tasks at once.
//!
//! Not modelled yet, and answered 501 with a message that says so, never
//! guessed at: ordering keys on a subscription, filters, dead letters,
//! retry policies, exactly-once delivery, push and export deliveries,
//! snapshots, seek, detach, schemas, transforms, import settings, tags and
//! IAM. Production's delays (a deleted topic that still takes a publish)
//! are not modelled at all: everything holds at once.

const std = @import("std");
const Allocator = std.mem.Allocator;
const Stringify = std.json.Stringify;
const Value = std.json.Value;
const core = @import("core");
const tp = core.transport;
const timestamp = core.timestamp;

pub const FakePubSub = struct {
    gpa: Allocator,
    io: std.Io,
    options: Options,
    mutex: std.Io.Mutex = .init,
    /// Holds everything stored. What is deleted stays in it until `deinit`.
    store: std.heap.ArenaAllocator,
    /// By full name, `projects/p/topics/id`, in name order.
    topics: std.StringArrayHashMapUnmanaged(*Topic) = .empty,
    /// By full name, in name order.
    subscriptions: std.StringArrayHashMapUnmanaged(*Subscription) = .empty,
    next_message_id: u64 = 1,
    next_uid: u64 = 1,
    prng: std.Random.DefaultPrng = .init(0x5eed),
    faults: [3]Fault = @splat(.{}),
    /// Requests served, by the kind of call, faults included.
    counts: [@typeInfo(Calls).@"enum".field_names.len]usize = @splat(0),
    /// Deleted topics and subscriptions, whose lists are freed at `deinit`.
    orphans: std.ArrayList(*Topic) = .empty,
    dropped: std.ArrayList(*Subscription) = .empty,

    pub const Options = struct {
        /// How long a pull with nothing to give is held. Production holds
        /// one about 20 seconds. Zero: it answers at once.
        empty_pull_hold: std.Io.Duration = .zero,
        /// A pull returns what it has in an order of the fake's choosing,
        /// as production gives no order without an ordering key. Off: in
        /// the order published, which no test should lean on.
        shuffle: bool = true,
    };

    /// The kinds of call a fault or a count can be about.
    pub const Calls = enum { all, publish, pull, acknowledge, modify_ack_deadline, admin };

    const Fault = struct { n: usize = 0, which: Calls = .all, status: u16 = 503 };
    const refuse = 0;
    const lose = 1;
    const drop = 2;

    pub const Reply = struct { status: u16, body: []const u8 };

    const Label = struct { key: []const u8, value: []const u8 };

    const Topic = struct {
        name: []const u8,
        labels: []const Label = &.{},
        /// Seconds. Null: the topic keeps nothing itself.
        retention_s: ?i64 = null,
        kms_key_name: ?[]const u8 = null,
        /// As it was sent, re-rendered: nothing reads it but a `get`.
        storage_policy: ?StoragePolicy = null,
        /// Every message published, oldest first.
        messages: std.ArrayList(*const Message) = .empty,
    };

    const StoragePolicy = struct { regions: []const []const u8, enforce_in_transit: bool };

    const Message = struct {
        id: u64,
        data: []const u8,
        attributes: []const Label,
        ordering_key: []const u8,
        publish_time: std.Io.Timestamp,
    };

    const Subscription = struct {
        name: []const u8,
        uid: u64,
        /// Null once its topic is deleted.
        topic: ?*Topic,
        ack_deadline_s: u32 = 10,
        labels: []const Label = &.{},
        retention_s: i64 = 604_800,
        retain_acked: bool = false,
        /// Seconds. Null: it never expires.
        expiration_ttl_s: ?i64 = 2_678_400,
        /// Production answers a different `pushConfig` once a subscription
        /// has been updated.
        updated: bool = false,
        /// What it has not had acknowledged, by a number of the entry's
        /// own, in the order it arrived.
        entries: std.AutoArrayHashMapUnmanaged(u64, Entry) = .empty,
        next_seq: u64 = 1,
    };

    const Entry = struct {
        message: *const Message,
        /// Out on a lease until then, on the awake clock. Null: waiting.
        lease_until: ?i96 = null,
        /// How many times it was delivered.
        deliveries: u32 = 0,
    };

    pub fn init(gpa: Allocator, io: std.Io, options: Options) FakePubSub {
        return .{ .gpa = gpa, .io = io, .options = options, .store = .init(gpa) };
    }

    pub fn deinit(f: *FakePubSub) void {
        for (f.topics.values()) |t| t.messages.deinit(f.gpa);
        for (f.orphans.items) |t| t.messages.deinit(f.gpa);
        f.orphans.deinit(f.gpa);
        for (f.subscriptions.values()) |s| s.entries.deinit(f.gpa);
        for (f.dropped.items) |s| s.entries.deinit(f.gpa);
        f.dropped.deinit(f.gpa);
        f.topics.deinit(f.gpa);
        f.subscriptions.deinit(f.gpa);
        f.store.deinit();
        f.* = undefined;
    }

    /// Goes into `Client.Options.transport`.
    pub fn transport(f: *FakePubSub) tp.Transport {
        return .{ .ptr = f, .vtable = &.{ .send = send } };
    }

    // Faults, each for the next `n` requests that `which` matches.

    /// Answers them with `status` and changes nothing.
    pub fn refuseNext(f: *FakePubSub, n: usize, status: u16, which: Calls) void {
        f.setFault(refuse, .{ .n = n, .which = which, .status = status });
    }

    /// Lets them land, and answers 503: an answer lost on the way back.
    pub fn loseAnswers(f: *FakePubSub, n: usize, which: Calls) void {
        f.setFault(lose, .{ .n = n, .which = which });
    }

    /// Closes their connection before any answer, and changes nothing.
    pub fn dropNext(f: *FakePubSub, n: usize, which: Calls) void {
        f.setFault(drop, .{ .n = n, .which = which });
    }

    fn setFault(f: *FakePubSub, slot: usize, fault: Fault) void {
        f.mutex.lockUncancelable(f.io);
        defer f.mutex.unlock(f.io);
        f.faults[slot] = fault;
    }

    fn takeFault(f: *FakePubSub, slot: usize, call: Calls) bool {
        const fault = &f.faults[slot];
        if (fault.n == 0 or (fault.which != .all and fault.which != call)) return false;
        fault.n -= 1;
        return true;
    }

    // What a test asks of it. Each takes a full name, or an id in `project`.

    /// How many messages the subscription has not had acknowledged, out on
    /// a lease or not. Zero for one that is not there.
    pub fn backlog(f: *FakePubSub, project: []const u8, subscription: []const u8) usize {
        f.mutex.lockUncancelable(f.io);
        defer f.mutex.unlock(f.io);
        const s = f.findSubscription(project, subscription) orelse return 0;
        return s.entries.count();
    }

    /// Of those, how many are out on a lease now.
    pub fn outstanding(f: *FakePubSub, project: []const u8, subscription: []const u8) usize {
        f.mutex.lockUncancelable(f.io);
        defer f.mutex.unlock(f.io);
        const s = f.findSubscription(project, subscription) orelse return 0;
        const now = f.awakeNow();
        var n: usize = 0;
        for (s.entries.values()) |e| {
            if (e.lease_until) |until| {
                if (until > now) n += 1;
            }
        }
        return n;
    }

    /// How many messages the topic was sent. Zero for one that is not there.
    pub fn publishedCount(f: *FakePubSub, project: []const u8, topic: []const u8) usize {
        f.mutex.lockUncancelable(f.io);
        defer f.mutex.unlock(f.io);
        var buf: [1024]u8 = undefined;
        const name = fullName(&buf, project, "topics", topic) orelse return 0;
        const t = f.topics.get(name) orelse return 0;
        return t.messages.items.len;
    }

    /// Requests served of that kind, the ones a fault answered included.
    pub fn requestCount(f: *FakePubSub, which: Calls) usize {
        f.mutex.lockUncancelable(f.io);
        defer f.mutex.unlock(f.io);
        return f.counts[@backingInt(which)];
    }

    fn findSubscription(f: *FakePubSub, project: []const u8, subscription: []const u8) ?*Subscription {
        var buf: [1024]u8 = undefined;
        const name = fullName(&buf, project, "subscriptions", subscription) orelse return null;
        return f.subscriptions.get(name);
    }

    fn fullName(buf: []u8, project: []const u8, comptime collection: []const u8, name_or_id: []const u8) ?[]const u8 {
        if (std.mem.startsWith(u8, name_or_id, "projects/")) return name_or_id;
        return std.fmt.bufPrint(buf, "projects/{s}/" ++ collection ++ "/{s}", .{ project, name_or_id }) catch null;
    }

    fn awakeNow(f: *const FakePubSub) i96 {
        return std.Io.Clock.awake.now(f.io).nanoseconds;
    }

    // The transport.

    fn send(ptr: *anyopaque, req: tp.Request, arena: Allocator) tp.Error!tp.Response {
        const f: *FakePubSub = @ptrCast(@alignCast(ptr));
        const reply = try f.serve(req.method, req.url, req.body orelse "", arena);
        return .{ .status = reply.status, .body = reply.body };
    }

    const Route = struct {
        project: []const u8,
        collection: enum { topics, subscriptions },
        /// Decoded. "" for the collection itself.
        id: []const u8,
        /// After the id: `:publish`, `/subscriptions`, or "".
        rest: []const u8,
        query: []const u8,
    };

    /// One request, as `send` serves it: for a test that wants to send
    /// what no client would.
    pub fn serve(f: *FakePubSub, method: tp.Method, url: []const u8, body: []const u8, arena: Allocator) tp.Error!Reply {
        const route = (try parseUrl(arena, url)) orelse return fail(arena, 404, "NOT_FOUND", "fake: no such route");
        const call = classify(method, route);

        f.mutex.lockUncancelable(f.io);
        defer f.mutex.unlock(f.io);
        f.counts[@backingInt(Calls.all)] += 1;
        f.counts[@backingInt(call)] += 1;
        if (f.takeFault(drop, call)) return error.ConnectionResetByPeer;
        if (f.takeFault(refuse, call)) {
            const status = f.faults[refuse].status;
            return fail(arena, status, statusName(status), "The service is currently unavailable.");
        }
        const reply = try f.dispatch(method, route, body, arena);
        if (f.takeFault(lose, call)) return fail(arena, 503, "UNAVAILABLE", "The service is currently unavailable.");
        return reply;
    }

    fn classify(method: tp.Method, route: Route) Calls {
        if (method != .POST) return .admin;
        if (std.mem.eql(u8, route.rest, ":publish")) return .publish;
        if (std.mem.eql(u8, route.rest, ":pull")) return .pull;
        if (std.mem.eql(u8, route.rest, ":acknowledge")) return .acknowledge;
        if (std.mem.eql(u8, route.rest, ":modifyAckDeadline")) return .modify_ack_deadline;
        return .admin;
    }

    fn dispatch(f: *FakePubSub, method: tp.Method, route: Route, body: []const u8, arena: Allocator) tp.Error!Reply {
        const none = route.rest.len == 0;
        switch (route.collection) {
            .topics => {
                if (route.id.len == 0) return if (method == .GET and none) f.listTopics(arena, route) else notModelled(arena, "this call on topics");
                if (none) return switch (method) {
                    .PUT => f.createTopic(arena, route, body),
                    .GET => f.getTopic(arena, route),
                    .PATCH => f.updateTopic(arena, route, body),
                    .DELETE => f.deleteTopic(arena, route),
                    .POST => notModelled(arena, "this call on a topic"),
                };
                if (method == .POST and std.mem.eql(u8, route.rest, ":publish")) return f.publish(arena, route, body);
                if (method == .GET and std.mem.eql(u8, route.rest, "/subscriptions")) return f.listTopicSubscriptions(arena, route);
                return notModelled(arena, route.rest);
            },
            .subscriptions => {
                if (route.id.len == 0) return if (method == .GET and none) f.listSubscriptions(arena, route) else notModelled(arena, "this call on subscriptions");
                if (none) return switch (method) {
                    .PUT => f.createSubscription(arena, route, body),
                    .GET => f.getSubscription(arena, route),
                    .PATCH => f.updateSubscription(arena, route, body),
                    .DELETE => f.deleteSubscription(arena, route),
                    .POST => notModelled(arena, "this call on a subscription"),
                };
                if (method == .POST and std.mem.eql(u8, route.rest, ":pull")) return f.pull(arena, route, body);
                if (method == .POST and std.mem.eql(u8, route.rest, ":acknowledge")) return f.acknowledge(arena, route, body);
                if (method == .POST and std.mem.eql(u8, route.rest, ":modifyAckDeadline")) return f.modifyAckDeadline(arena, route, body);
                return notModelled(arena, route.rest);
            },
        }
    }

    // Topics.

    fn createTopic(f: *FakePubSub, arena: Allocator, route: Route, body: []const u8) Allocator.Error!Reply {
        const name = try resourceName(arena, route);
        if (!isResourceId(route.id)) return invalidName(arena, name);
        const object = switch (try parseObject(arena, body)) {
            .ok => |o| o,
            .refused => |r| return r,
        };
        var topic: Topic = .{ .name = name };
        var it = object.iterator();
        while (it.next()) |field| {
            const key = field.key_ptr.*;
            const value = field.value_ptr.*;
            if (isField(key, "name")) continue;
            if (isField(key, "labels")) {
                topic.labels = switch (try labelsOf(arena, value)) {
                    .ok => |l| l,
                    .refused => |r| return r,
                };
            } else if (isField(key, "messageRetentionDuration")) {
                topic.retention_s = switch (try retentionOf(arena, value)) {
                    .ok => |s| s,
                    .refused => |r| return r,
                };
            } else if (isField(key, "kmsKeyName")) {
                topic.kms_key_name = stringOf(value) orelse return badValue(arena, key);
            } else if (isField(key, "messageStoragePolicy")) {
                topic.storage_policy = (try storagePolicyOf(arena, value)) orelse return badValue(arena, key);
            } else if (isAnyField(key, &.{ "schemaSettings", "messageTransforms", "ingestionDataSourceSettings", "tags" })) {
                return notModelled(arena, key);
            } else return unknownName(arena, key);
        }
        if (f.topics.contains(name)) return alreadyExists(arena, route.id);
        const stored = try f.keepTopic(topic);
        try f.insertSorted(Topic, &f.topics, stored);
        return ok(try renderTopic(arena, stored));
    }

    fn getTopic(f: *FakePubSub, arena: Allocator, route: Route) Allocator.Error!Reply {
        const topic = f.topics.get(try resourceName(arena, route)) orelse return notFound(arena, route.id);
        return ok(try renderTopic(arena, topic));
    }

    fn deleteTopic(f: *FakePubSub, arena: Allocator, route: Route) Allocator.Error!Reply {
        const name = try resourceName(arena, route);
        const topic = f.topics.get(name) orelse return notFound(arena, route.id);
        try f.orphans.append(f.gpa, topic);
        _ = f.topics.orderedRemove(name);
        // Its subscriptions stay, with what they hold, and no topic.
        for (f.subscriptions.values()) |s| {
            if (s.topic == topic) s.topic = null;
        }
        return ok("{}");
    }

    fn updateTopic(f: *FakePubSub, arena: Allocator, route: Route, body: []const u8) Allocator.Error!Reply {
        const update = switch (try parseUpdate(arena, body, "topic", "UpdateTopicRequest")) {
            .ok => |u| u,
            .refused => |r| return r,
        };
        const topic = f.topics.get(try resourceName(arena, route)) orelse return notFound(arena, route.id);
        var next = topic.*;
        for (update.paths) |path| {
            const given = fieldOf(update.resource, path);
            if (isPath(path, "name")) {
                return immutable(arena, "UpdateTopicRequest", "name", "Topic");
            } else if (isPath(path, "labels")) {
                next.labels = if (given) |v| switch (try labelsOf(arena, v)) {
                    .ok => |l| try f.keepLabels(l),
                    .refused => |r| return r,
                } else &.{};
            } else if (isPath(path, "messageRetentionDuration")) {
                next.retention_s = if (given) |v| switch (try retentionOf(arena, v)) {
                    .ok => |s| s,
                    .refused => |r| return r,
                } else null;
            } else if (isPath(path, "kmsKeyName")) {
                next.kms_key_name = if (given) |v| try f.keep(stringOf(v) orelse return badValue(arena, path)) else null;
            } else if (isPath(path, "messageStoragePolicy")) {
                next.storage_policy = if (given) |v| try f.keepPolicy((try storagePolicyOf(arena, v)) orelse return badValue(arena, path)) else null;
            } else if (isAnyPath(path, &.{ "schemaSettings", "messageTransforms", "ingestionDataSourceSettings" })) {
                return notModelled(arena, path);
            } else return unknownPath(arena, "UpdateTopicRequest", path, "Topic");
        }
        topic.* = next;
        return ok(try renderTopic(arena, topic));
    }

    fn listTopics(f: *FakePubSub, arena: Allocator, route: Route) Allocator.Error!Reply {
        const page = switch (try pageOf(arena, route.query)) {
            .ok => |p| p,
            .refused => |r| return r,
        };
        const prefix = try std.fmt.allocPrint(arena, "projects/{s}/topics/", .{route.project});
        var out: std.Io.Writer.Allocating = .init(arena);
        var jw: Stringify = .{ .writer = &out.writer };
        jw.beginObject() catch return error.OutOfMemory;
        var written: usize = 0;
        var next: ?[]const u8 = null;
        for (f.topics.keys(), f.topics.values()) |name, topic| {
            if (!std.mem.startsWith(u8, name, prefix)) continue;
            if (page.after) |after| {
                if (std.mem.order(u8, name, after) == .lt) continue;
            }
            if (written == page.size) {
                next = name;
                break;
            }
            if (written == 0) {
                jw.objectField("topics") catch return error.OutOfMemory;
                jw.beginArray() catch return error.OutOfMemory;
            }
            writeTopic(&jw, topic) catch return error.OutOfMemory;
            written += 1;
        }
        if (written > 0) jw.endArray() catch return error.OutOfMemory;
        if (next) |name| {
            jw.objectField("nextPageToken") catch return error.OutOfMemory;
            jw.write(try pageToken(arena, name)) catch return error.OutOfMemory;
        }
        jw.endObject() catch return error.OutOfMemory;
        return ok(out.written());
    }

    fn listTopicSubscriptions(f: *FakePubSub, arena: Allocator, route: Route) Allocator.Error!Reply {
        const topic = f.topics.get(try resourceName(arena, route)) orelse return notFound(arena, route.id);
        const page = switch (try pageOf(arena, route.query)) {
            .ok => |p| p,
            .refused => |r| return r,
        };
        var out: std.Io.Writer.Allocating = .init(arena);
        var jw: Stringify = .{ .writer = &out.writer };
        jw.beginObject() catch return error.OutOfMemory;
        var written: usize = 0;
        var next: ?[]const u8 = null;
        for (f.subscriptions.keys(), f.subscriptions.values()) |name, s| {
            if (s.topic != topic) continue;
            if (page.after) |after| {
                if (std.mem.order(u8, name, after) == .lt) continue;
            }
            if (written == page.size) {
                next = name;
                break;
            }
            if (written == 0) {
                jw.objectField("subscriptions") catch return error.OutOfMemory;
                jw.beginArray() catch return error.OutOfMemory;
            }
            jw.write(name) catch return error.OutOfMemory;
            written += 1;
        }
        if (written > 0) jw.endArray() catch return error.OutOfMemory;
        if (next) |name| {
            jw.objectField("nextPageToken") catch return error.OutOfMemory;
            jw.write(try pageToken(arena, name)) catch return error.OutOfMemory;
        }
        jw.endObject() catch return error.OutOfMemory;
        return ok(out.written());
    }

    // Publish.

    fn publish(f: *FakePubSub, arena: Allocator, route: Route, body: []const u8) Allocator.Error!Reply {
        // Production's limit is on the request as it arrives.
        if (body.len > max_publish_bytes) return fail(arena, 400, "INVALID_ARGUMENT", "Request payload size exceeds the limit: 10485760 bytes.");
        const object = switch (try parseObject(arena, body)) {
            .ok => |o| o,
            .refused => |r| return r,
        };
        const topic = f.topics.get(try resourceName(arena, route)) orelse return notFound(arena, route.id);
        const list: []const Value = if (object.get("messages")) |m| switch (m) {
            .array => |a| a.items,
            else => return badValue(arena, "messages"),
        } else &.{};
        if (list.len == 0) return fail(arena, 400, "INVALID_ARGUMENT", "The value for message_count is too small. You passed 0 in the request, but the minimum value is 1.");
        if (list.len > 1000) return fail(arena, 400, "INVALID_ARGUMENT", try std.fmt.allocPrint(arena, "The value for message_count is too large. You passed {d} in the request, but the maximum value is 1000.", .{list.len}));

        const parsed = try arena.alloc(Message, list.len);
        for (list, parsed, 0..) |item, *message, index| {
            const m = switch (item) {
                .object => |o| o,
                else => return badValue(arena, "messages"),
            };
            message.* = .{ .id = 0, .data = "", .attributes = &.{}, .ordering_key = "", .publish_time = undefined };
            var it = m.iterator();
            while (it.next()) |field| {
                const key = field.key_ptr.*;
                const value = field.value_ptr.*;
                if (isField(key, "data")) {
                    const text = stringOf(value) orelse return badValue(arena, "data");
                    message.data = (try decodeBase64(arena, text)) orelse return fail(arena, 400, "INVALID_ARGUMENT", try std.fmt.allocPrint(arena, "Invalid value at 'messages[{d}].data' (TYPE_BYTES), Base64 decoding failed for \"{s}\"", .{ index, text }));
                } else if (isField(key, "attributes")) {
                    message.attributes = (try stringMapOf(arena, value)) orelse return badValue(arena, "attributes");
                } else if (isField(key, "orderingKey")) {
                    message.ordering_key = stringOf(value) orelse return badValue(arena, "orderingKey");
                } else if (isAnyField(key, &.{ "messageId", "publishTime" })) {
                    // Taken and ignored: the server chooses both.
                } else return unknownName(arena, key);
            }
            if (message.data.len == 0 and message.attributes.len == 0) return fail(arena, 400, "INVALID_ARGUMENT", "One or more messages in the publish request is empty. Each message must contain either non-empty data, or at least one attribute.");
            if (message.attributes.len > 100) return fail(arena, 400, "INVALID_ARGUMENT", try std.fmt.allocPrint(arena, "There are too many attributes in the request. The request contains {d} attributes, but the maximum allowed is 100. Refer to https://cloud.google.com/pubsub/quotas for more information.", .{message.attributes.len}));
            for (message.attributes) |a| {
                if (a.key.len == 0 or (startsWithGoog(a.key) and !isSchemaAttribute(a.key))) return fail(arena, 400, "INVALID_ARGUMENT", try std.fmt.allocPrint(arena, "The request contains an attribute key that is not valid (key={s}). Attribute keys must be non-empty and must not begin with 'goog' (case-insensitive).", .{a.key}));
                // The fake's words, after production's for a value: the
                // probe cut production's own short.
                if (a.key.len > 256) return fail(arena, 400, "INVALID_ARGUMENT", try std.fmt.allocPrint(arena, "The attribute \"{s}\" in the request has a key that is too large. The size is {d} bytes, but the maximum allowed is 256. Refer to https://cloud.google.com/pubsub/quotas for more information.", .{ a.key, a.key.len }));
                if (a.value.len > 1024) return fail(arena, 400, "INVALID_ARGUMENT", try std.fmt.allocPrint(arena, "The attribute \"{s}\" in the request has a value that is too large. The size is {d} bytes, but the maximum allowed is 1024. Refer to https://cloud.google.com/pubsub/quotas for more information.", .{ a.key, a.value.len }));
            }
            if (message.ordering_key.len > 1024) return fail(arena, 400, "INVALID_ARGUMENT", try std.fmt.allocPrint(arena, "An ordering key in the request is too long. The length is {d} characters, but the maximum allowed is 1024. Refer to https://cloud.google.com/pubsub/quotas for more information.", .{message.ordering_key.len}));
            if (!std.mem.eql(u8, message.ordering_key, parsed[0].ordering_key)) return fail(arena, 400, "FAILED_PRECONDITION", "In a single publish request, all messages must have no ordering key or they must all have the same ordering key. [code=539b]");
        }

        const now = std.Io.Clock.real.now(f.io);
        var out: std.Io.Writer.Allocating = .init(arena);
        var jw: Stringify = .{ .writer = &out.writer };
        jw.beginObject() catch return error.OutOfMemory;
        jw.objectField("messageIds") catch return error.OutOfMemory;
        jw.beginArray() catch return error.OutOfMemory;
        // Stored first, whole, so that a failure midway leaves nothing.
        const stored = try arena.alloc(*Message, parsed.len);
        for (parsed, stored) |m, *slot| {
            const kept = try f.store.allocator().create(Message);
            kept.* = .{
                .id = 0,
                .data = try f.keep(m.data),
                .attributes = try f.keepLabels(m.attributes),
                .ordering_key = try f.keep(m.ordering_key),
                .publish_time = now,
            };
            slot.* = kept;
        }
        try topic.messages.ensureUnusedCapacity(f.gpa, stored.len);
        for (f.subscriptions.values()) |s| {
            if (s.topic == topic) try s.entries.ensureUnusedCapacity(f.gpa, stored.len);
        }
        for (stored) |kept| {
            const id = f.next_message_id;
            f.next_message_id += 1;
            kept.id = id;
            topic.messages.appendAssumeCapacity(kept);
            for (f.subscriptions.values()) |s| {
                if (s.topic != topic) continue;
                s.entries.putAssumeCapacity(s.next_seq, .{ .message = kept });
                s.next_seq += 1;
            }
            var buf: [20]u8 = undefined;
            jw.write(std.fmt.bufPrint(&buf, "{d}", .{id}) catch unreachable) catch return error.OutOfMemory;
        }
        jw.endArray() catch return error.OutOfMemory;
        jw.endObject() catch return error.OutOfMemory;
        return ok(out.written());
    }

    // Subscriptions.

    fn createSubscription(f: *FakePubSub, arena: Allocator, route: Route, body: []const u8) Allocator.Error!Reply {
        const name = try resourceName(arena, route);
        if (!isResourceId(route.id)) return invalidName(arena, name);
        const object = switch (try parseObject(arena, body)) {
            .ok => |o| o,
            .refused => |r| return r,
        };
        var sub: Subscription = .{ .name = name, .uid = 0, .topic = null };
        var topic_name: []const u8 = "";
        var expiration_given = false;
        var it = object.iterator();
        while (it.next()) |field| {
            const key = field.key_ptr.*;
            const value = field.value_ptr.*;
            if (isField(key, "name")) continue;
            if (isField(key, "topic")) {
                topic_name = stringOf(value) orelse return badValue(arena, key);
            } else if (isField(key, "ackDeadlineSeconds")) {
                const seconds = intOf(value) orelse return badValue(arena, key);
                // 0 is "not said", and gets the default.
                if (seconds != 0) {
                    if (seconds < 10 or seconds > 600) return fail(arena, 400, "INVALID_ARGUMENT", try std.fmt.allocPrint(arena, "Invalid ack deadline given (ack_deadline={d}). The ack deadline must be between 10 and 600 seconds.", .{seconds}));
                    sub.ack_deadline_s = @intCast(seconds);
                }
            } else if (isField(key, "labels")) {
                sub.labels = switch (try labelsOf(arena, value)) {
                    .ok => |l| l,
                    .refused => |r| return r,
                };
            } else if (isField(key, "messageRetentionDuration")) {
                sub.retention_s = switch (try retentionOf(arena, value)) {
                    .ok => |s| s,
                    .refused => |r| return r,
                };
            } else if (isField(key, "retainAckedMessages")) {
                sub.retain_acked = boolOf(value) orelse return badValue(arena, key);
            } else if (isField(key, "expirationPolicy")) {
                expiration_given = true;
                sub.expiration_ttl_s = switch (try expirationOf(arena, value)) {
                    .ok => |ttl| ttl,
                    .refused => |r| return r,
                };
            } else if (isField(key, "pushConfig")) {
                // An empty one is what a pull subscription has.
                const push = switch (value) {
                    .object => |o| o,
                    else => return badValue(arena, key),
                };
                if (push.count() != 0) return notModelled(arena, "a push subscription");
            } else if (isField(key, "enableMessageOrdering") or isField(key, "enableExactlyOnceDelivery")) {
                if (boolOf(value) orelse return badValue(arena, key)) return notModelled(arena, key);
            } else if (isField(key, "filter")) {
                if ((stringOf(value) orelse return badValue(arena, key)).len != 0) return notModelled(arena, key);
            } else if (isAnyField(key, &.{ "deadLetterPolicy", "retryPolicy", "bigqueryConfig", "cloudStorageConfig", "messageTransforms", "tags" })) {
                return notModelled(arena, key);
            } else return unknownName(arena, key);
        }
        if (!isResourceName(topic_name, "topics")) return invalidName(arena, topic_name);
        if (expirationRefusal(arena, sub.retention_s, sub.expiration_ttl_s, expiration_given)) |refusal| return try refusal;
        if (f.subscriptions.contains(name)) return alreadyExists(arena, route.id);
        const topic = f.topics.get(topic_name) orelse return notFound(arena, idOf(topic_name));
        sub.topic = topic;
        sub.uid = f.next_uid;
        f.next_uid += 1;
        const stored = try f.keepSubscription(sub);
        try f.insertSorted(Subscription, &f.subscriptions, stored);
        return ok(try renderSubscription(arena, stored));
    }

    fn getSubscription(f: *FakePubSub, arena: Allocator, route: Route) Allocator.Error!Reply {
        const sub = f.subscriptions.get(try resourceName(arena, route)) orelse return notFound(arena, route.id);
        return ok(try renderSubscription(arena, sub));
    }

    fn deleteSubscription(f: *FakePubSub, arena: Allocator, route: Route) Allocator.Error!Reply {
        const name = try resourceName(arena, route);
        const sub = f.subscriptions.get(name) orelse return notFound(arena, route.id);
        try f.dropped.append(f.gpa, sub);
        _ = f.subscriptions.orderedRemove(name);
        return ok("{}");
    }

    fn updateSubscription(f: *FakePubSub, arena: Allocator, route: Route, body: []const u8) Allocator.Error!Reply {
        const update = switch (try parseUpdate(arena, body, "subscription", "UpdateSubscriptionRequest")) {
            .ok => |u| u,
            .refused => |r| return r,
        };
        const sub = f.subscriptions.get(try resourceName(arena, route)) orelse return notFound(arena, route.id);
        var next = sub.*;
        var expiration_given = false;
        for (update.paths) |path| {
            const given = fieldOf(update.resource, path);
            if (isPath(path, "name")) {
                return immutable(arena, "UpdateSubscriptionRequest", "name", "Subscription");
            } else if (isPath(path, "topic")) {
                return immutable(arena, "UpdateSubscriptionRequest", "topic", "Subscription");
            } else if (isPath(path, "filter")) {
                return immutable(arena, "UpdateSubscriptionRequest", "filter", "Subscription");
            } else if (isPath(path, "enableMessageOrdering")) {
                return immutable(arena, "UpdateSubscriptionRequest", "enable_message_ordering", "Subscription");
            } else if (isPath(path, "ackDeadlineSeconds")) {
                const seconds = if (given) |v| intOf(v) orelse return badValue(arena, path) else 10;
                if (seconds < 10 or seconds > 600) return fail(arena, 400, "INVALID_ARGUMENT", try std.fmt.allocPrint(arena, "Invalid ack deadline given (ack_deadline={d}). The ack deadline must be between 10 and 600 seconds.", .{seconds}));
                next.ack_deadline_s = @intCast(seconds);
            } else if (isPath(path, "labels")) {
                next.labels = if (given) |v| switch (try labelsOf(arena, v)) {
                    .ok => |l| try f.keepLabels(l),
                    .refused => |r| return r,
                } else &.{};
            } else if (isPath(path, "messageRetentionDuration")) {
                next.retention_s = if (given) |v| switch (try retentionOf(arena, v)) {
                    .ok => |s| s,
                    .refused => |r| return r,
                } else 604_800;
            } else if (isPath(path, "retainAckedMessages")) {
                next.retain_acked = if (given) |v| boolOf(v) orelse return badValue(arena, path) else false;
            } else if (isPath(path, "expirationPolicy")) {
                expiration_given = given != null;
                next.expiration_ttl_s = if (given) |v| switch (try expirationOf(arena, v)) {
                    .ok => |ttl| ttl,
                    .refused => |r| return r,
                } else 2_678_400;
            } else if (isAnyPath(path, &.{ "pushConfig", "bigqueryConfig", "cloudStorageConfig", "deadLetterPolicy", "retryPolicy", "enableExactlyOnceDelivery", "messageTransforms" })) {
                return notModelled(arena, path);
            } else return unknownPath(arena, "UpdateSubscriptionRequest", path, "Subscription");
        }
        if (expirationRefusal(arena, next.retention_s, next.expiration_ttl_s, expiration_given)) |refusal| return try refusal;
        next.updated = true;
        sub.* = next;
        return ok(try renderSubscription(arena, sub));
    }

    fn listSubscriptions(f: *FakePubSub, arena: Allocator, route: Route) Allocator.Error!Reply {
        const page = switch (try pageOf(arena, route.query)) {
            .ok => |p| p,
            .refused => |r| return r,
        };
        const prefix = try std.fmt.allocPrint(arena, "projects/{s}/subscriptions/", .{route.project});
        var out: std.Io.Writer.Allocating = .init(arena);
        var jw: Stringify = .{ .writer = &out.writer };
        jw.beginObject() catch return error.OutOfMemory;
        var written: usize = 0;
        var next: ?[]const u8 = null;
        for (f.subscriptions.keys(), f.subscriptions.values()) |name, sub| {
            if (!std.mem.startsWith(u8, name, prefix)) continue;
            if (page.after) |after| {
                if (std.mem.order(u8, name, after) == .lt) continue;
            }
            if (written == page.size) {
                next = name;
                break;
            }
            if (written == 0) {
                jw.objectField("subscriptions") catch return error.OutOfMemory;
                jw.beginArray() catch return error.OutOfMemory;
            }
            writeSubscription(&jw, sub) catch return error.OutOfMemory;
            written += 1;
        }
        if (written > 0) jw.endArray() catch return error.OutOfMemory;
        if (next) |name| {
            jw.objectField("nextPageToken") catch return error.OutOfMemory;
            jw.write(try pageToken(arena, name)) catch return error.OutOfMemory;
        }
        jw.endObject() catch return error.OutOfMemory;
        return ok(out.written());
    }

    // Pull, acknowledge, and leases.

    fn pull(f: *FakePubSub, arena: Allocator, route: Route, body: []const u8) tp.Error!Reply {
        const object = switch (try parseObject(arena, body)) {
            .ok => |o| o,
            .refused => |r| return r,
        };
        const name = try resourceName(arena, route);
        if (!f.subscriptions.contains(name)) return notFound(arena, route.id);
        var wanted: i64 = 0;
        var it = object.iterator();
        while (it.next()) |field| {
            const key = field.key_ptr.*;
            if (isField(key, "maxMessages")) {
                wanted = intOf(field.value_ptr.*) orelse return badValue(arena, key);
            } else if (isField(key, "returnImmediately")) {
                _ = boolOf(field.value_ptr.*) orelse return badValue(arena, key);
            } else return unknownName(arena, key);
        }
        if (wanted <= 0) return fail(arena, 400, "INVALID_ARGUMENT", "You have passed an invalid argument to the service (argument=max_messages).");
        // Production takes 1001 and more; what it then returns is its own
        // affair, and here it is at most 1000.
        const max: usize = @intCast(@min(wanted, 1000));

        const hold_until = f.awakeNow() + f.options.empty_pull_hold.nanoseconds;
        while (true) {
            // Looked up each time round: the subscription may be deleted
            // while a pull is held.
            const sub = f.subscriptions.get(name) orelse return notFound(arena, route.id);
            const now = f.awakeNow();
            const ready = try f.readyEntries(arena, sub, now);
            if (ready.len > 0) return f.deliver(arena, sub, ready[0..@min(ready.len, max)], now);
            if (now >= hold_until) return ok("{}");
            // Nothing wakes a held pull but time: it looks again shortly,
            // which a test's clock can bring about as well as a real one.
            const step: i96 = @min(hold_until - now, 5 * std.time.ns_per_ms);
            f.mutex.unlock(f.io);
            const slept = f.io.sleep(.{ .nanoseconds = step }, .awake);
            f.mutex.lockUncancelable(f.io);
            slept catch return error.Canceled;
        }
    }

    /// The numbers of the entries a pull may give now: the ones waiting,
    /// and the ones whose lease has lapsed. In an order of the fake's
    /// choosing when `shuffle` is on.
    fn readyEntries(f: *FakePubSub, arena: Allocator, sub: *Subscription, now: i96) Allocator.Error![]u64 {
        var ready: std.ArrayList(u64) = .empty;
        for (sub.entries.keys(), sub.entries.values()) |seq, entry| {
            if (entry.lease_until) |until| {
                if (until > now) continue;
            }
            try ready.append(arena, seq);
        }
        if (f.options.shuffle) f.prng.random().shuffle(u64, ready.items);
        return ready.items;
    }

    fn deliver(f: *FakePubSub, arena: Allocator, sub: *Subscription, seqs: []const u64, now: i96) Allocator.Error!Reply {
        _ = f;
        var out: std.Io.Writer.Allocating = .init(arena);
        var jw: Stringify = .{ .writer = &out.writer };
        jw.beginObject() catch return error.OutOfMemory;
        jw.objectField("receivedMessages") catch return error.OutOfMemory;
        jw.beginArray() catch return error.OutOfMemory;
        const until = now + @as(i96, sub.ack_deadline_s) * std.time.ns_per_s;
        for (seqs) |seq| {
            const entry = sub.entries.getPtr(seq).?;
            const m = entry.message;
            jw.beginObject() catch return error.OutOfMemory;
            jw.objectField("ackId") catch return error.OutOfMemory;
            jw.write(try ackId(arena, sub.uid, seq, entry.deliveries + 1)) catch return error.OutOfMemory;
            jw.objectField("message") catch return error.OutOfMemory;
            jw.beginObject() catch return error.OutOfMemory;
            if (m.data.len > 0) {
                jw.objectField("data") catch return error.OutOfMemory;
                const encoded = try arena.alloc(u8, std.base64.standard.Encoder.calcSize(m.data.len));
                jw.write(std.base64.standard.Encoder.encode(encoded, m.data)) catch return error.OutOfMemory;
            }
            if (m.attributes.len > 0) {
                jw.objectField("attributes") catch return error.OutOfMemory;
                writeLabels(&jw, m.attributes) catch return error.OutOfMemory;
            }
            var id_buf: [20]u8 = undefined;
            jw.objectField("messageId") catch return error.OutOfMemory;
            jw.write(std.fmt.bufPrint(&id_buf, "{d}", .{m.id}) catch unreachable) catch return error.OutOfMemory;
            var time_buf: [timestamp.max_len]u8 = undefined;
            jw.objectField("publishTime") catch return error.OutOfMemory;
            jw.write(timestamp.format(&time_buf, m.publish_time)) catch return error.OutOfMemory;
            if (m.ordering_key.len > 0) {
                jw.objectField("orderingKey") catch return error.OutOfMemory;
                jw.write(m.ordering_key) catch return error.OutOfMemory;
            }
            jw.endObject() catch return error.OutOfMemory;
            jw.endObject() catch return error.OutOfMemory;
        }
        jw.endArray() catch return error.OutOfMemory;
        jw.endObject() catch return error.OutOfMemory;
        // The answer is whole: only now are the messages out.
        for (seqs) |seq| {
            const entry = sub.entries.getPtr(seq).?;
            entry.lease_until = until;
            entry.deliveries += 1;
        }
        return ok(out.written());
    }

    const AckRequest = struct { seqs: []const u64, seconds: ?i64 };

    /// The ids of an acknowledge or a modifyAckDeadline, each checked as
    /// production checks it, before any is acted on.
    fn ackRequest(f: *FakePubSub, arena: Allocator, route: Route, body: []const u8) Allocator.Error!union(enum) { ok: struct { sub: *Subscription, request: AckRequest }, refused: Reply } {
        const object = switch (try parseObject(arena, body)) {
            .ok => |o| o,
            .refused => |r| return .{ .refused = r },
        };
        const sub = f.subscriptions.get(try resourceName(arena, route)) orelse return .{ .refused = try notFound(arena, route.id) };
        var ids: []const Value = &.{};
        var seconds: ?i64 = null;
        var it = object.iterator();
        while (it.next()) |field| {
            const key = field.key_ptr.*;
            if (isField(key, "ackIds")) {
                ids = switch (field.value_ptr.*) {
                    .array => |a| a.items,
                    else => return .{ .refused = try badValue(arena, key) },
                };
            } else if (isField(key, "ackDeadlineSeconds")) {
                seconds = intOf(field.value_ptr.*) orelse return .{ .refused = try badValue(arena, key) };
            } else return .{ .refused = try unknownName(arena, key) };
        }
        if (ids.len == 0) return .{ .refused = try fail(arena, 400, "INVALID_ARGUMENT", "You have not specified an ack ID in the request.") };
        const seqs = try arena.alloc(u64, ids.len);
        for (ids, seqs) |id, *seq| {
            const text = stringOf(id) orelse return .{ .refused = try badValue(arena, "ackIds") };
            const parsed = parseAckId(text) orelse return .{ .refused = try fail(arena, 400, "INVALID_ARGUMENT", try std.fmt.allocPrint(arena, "You have passed an invalid ack ID to the service (ack_id={s}).", .{text})) };
            if (parsed.uid != sub.uid) return .{ .refused = try fail(arena, 400, "INVALID_ARGUMENT", try std.fmt.allocPrint(arena, "You have passed a subscription that does not belong to the given ack ID (resource={s}).", .{sub.name})) };
            seq.* = parsed.seq;
        }
        return .{ .ok = .{ .sub = sub, .request = .{ .seqs = seqs, .seconds = seconds } } };
    }

    fn acknowledge(f: *FakePubSub, arena: Allocator, route: Route, body: []const u8) Allocator.Error!Reply {
        const checked = switch (try f.ackRequest(arena, route, body)) {
            .ok => |c| c,
            .refused => |r| return r,
        };
        const now = f.awakeNow();
        for (checked.request.seqs) |seq| {
            const entry = checked.sub.entries.get(seq) orelse continue;
            // Taken only while the message is out: after a lapse or a
            // nack the ack is answered and forgotten, and the message
            // comes again.
            const until = entry.lease_until orelse continue;
            if (until <= now) continue;
            _ = checked.sub.entries.orderedRemove(seq);
        }
        return ok("{}");
    }

    fn modifyAckDeadline(f: *FakePubSub, arena: Allocator, route: Route, body: []const u8) Allocator.Error!Reply {
        const checked = switch (try f.ackRequest(arena, route, body)) {
            .ok => |c| c,
            .refused => |r| return r,
        };
        const seconds = checked.request.seconds orelse 0;
        if (seconds < 0 or seconds > 600) return fail(arena, 400, "INVALID_ARGUMENT", try std.fmt.allocPrint(arena, "Invalid ack deadline given (ack_deadline={d}). The ack deadline must be between 0 and 600 seconds.", .{seconds}));
        const now = f.awakeNow();
        for (checked.request.seqs) |seq| {
            const entry = checked.sub.entries.getPtr(seq) orelse continue;
            const until = entry.lease_until orelse continue;
            if (until <= now) continue;
            // Zero gives the message back at once: a nack.
            entry.lease_until = if (seconds == 0) null else now + @as(i96, seconds) * std.time.ns_per_s;
        }
        return ok("{}");
    }

    // Keeping what a request held, past the request.

    fn keep(f: *FakePubSub, text: []const u8) Allocator.Error![]const u8 {
        return f.store.allocator().dupe(u8, text);
    }

    fn keepLabels(f: *FakePubSub, labels: []const Label) Allocator.Error![]const Label {
        const kept = try f.store.allocator().alloc(Label, labels.len);
        for (labels, kept) |l, *slot| slot.* = .{ .key = try f.keep(l.key), .value = try f.keep(l.value) };
        return kept;
    }

    fn keepPolicy(f: *FakePubSub, policy: StoragePolicy) Allocator.Error!StoragePolicy {
        const regions = try f.store.allocator().alloc([]const u8, policy.regions.len);
        for (policy.regions, regions) |r, *slot| slot.* = try f.keep(r);
        return .{ .regions = regions, .enforce_in_transit = policy.enforce_in_transit };
    }

    fn keepTopic(f: *FakePubSub, topic: Topic) Allocator.Error!*Topic {
        const kept = try f.store.allocator().create(Topic);
        kept.* = topic;
        kept.name = try f.keep(topic.name);
        kept.labels = try f.keepLabels(topic.labels);
        if (topic.kms_key_name) |k| kept.kms_key_name = try f.keep(k);
        if (topic.storage_policy) |p| kept.storage_policy = try f.keepPolicy(p);
        return kept;
    }

    fn keepSubscription(f: *FakePubSub, sub: Subscription) Allocator.Error!*Subscription {
        const kept = try f.store.allocator().create(Subscription);
        kept.* = sub;
        kept.name = try f.keep(sub.name);
        kept.labels = try f.keepLabels(sub.labels);
        return kept;
    }

    /// Lists come back in name order, as production's did.
    fn insertSorted(f: *FakePubSub, comptime T: type, map: *std.StringArrayHashMapUnmanaged(*T), item: *T) Allocator.Error!void {
        try map.put(f.gpa, item.name, item);
        const Sorter = struct {
            keys: []const []const u8,
            pub fn lessThan(ctx: @This(), a: usize, b: usize) bool {
                return std.mem.order(u8, ctx.keys[a], ctx.keys[b]) == .lt;
            }
        };
        map.sortUnstable(Sorter{ .keys = map.keys() });
    }
};

/// The size of a publish request production takes, counted on the request
/// as it arrives.
const max_publish_bytes = 10 * 1024 * 1024;

// Requests: the URL, the body, and what a field of it holds.

fn parseUrl(arena: Allocator, url: []const u8) Allocator.Error!?FakePubSub.Route {
    const marker = "/v1/projects/";
    const at = std.mem.indexOf(u8, url, marker) orelse return null;
    var path = url[at + marker.len ..];
    var query: []const u8 = "";
    if (std.mem.indexOfScalar(u8, path, '?')) |q| {
        query = path[q + 1 ..];
        path = path[0..q];
    }
    var parts = std.mem.splitScalar(u8, path, '/');
    const project = try percentDecode(arena, parts.next() orelse return null);
    const collection_text = parts.next() orelse return null;
    const collection: @FieldType(FakePubSub.Route, "collection") = if (std.mem.eql(u8, collection_text, "topics"))
        .topics
    else if (std.mem.eql(u8, collection_text, "subscriptions"))
        .subscriptions
    else
        return null;
    const id_part = parts.next() orelse return .{ .project = project, .collection = collection, .id = "", .rest = "", .query = query };
    const after = parts.rest();
    // A method follows the id after a colon: an id holds none.
    if (std.mem.indexOfScalar(u8, id_part, ':')) |colon| {
        if (after.len != 0) return null;
        return .{ .project = project, .collection = collection, .id = try percentDecode(arena, id_part[0..colon]), .rest = id_part[colon..], .query = query };
    }
    const rest = if (after.len == 0) "" else try std.fmt.allocPrint(arena, "/{s}", .{after});
    return .{ .project = project, .collection = collection, .id = try percentDecode(arena, id_part), .rest = rest, .query = query };
}

fn percentDecode(arena: Allocator, text: []const u8) Allocator.Error![]const u8 {
    if (std.mem.indexOfScalar(u8, text, '%') == null) return text;
    var out: std.ArrayList(u8) = .empty;
    var i: usize = 0;
    while (i < text.len) : (i += 1) {
        if (text[i] == '%' and i + 2 < text.len) {
            if (std.fmt.parseInt(u8, text[i + 1 .. i + 3], 16)) |byte| {
                try out.append(arena, byte);
                i += 2;
                continue;
            } else |_| {}
        }
        try out.append(arena, text[i]);
    }
    return out.items;
}

fn resourceName(arena: Allocator, route: FakePubSub.Route) Allocator.Error![]const u8 {
    return std.fmt.allocPrint(arena, "projects/{s}/{t}/{s}", .{ route.project, route.collection, route.id });
}

/// The id at the end of a full name.
fn idOf(name: []const u8) []const u8 {
    const slash = std.mem.lastIndexOfScalar(u8, name, '/') orelse return name;
    return name[slash + 1 ..];
}

/// 3 to 255 characters from `[A-Za-z0-9-_.~+%]`, the first a letter, and
/// not beginning `goog` in any case.
fn isResourceId(id: []const u8) bool {
    if (id.len < 3 or id.len > 255) return false;
    if (!std.ascii.isAlphabetic(id[0])) return false;
    if (startsWithGoog(id)) return false;
    for (id) |c| {
        if (!std.ascii.isAlphanumeric(c) and std.mem.indexOfScalar(u8, "-_.~+%", c) == null) return false;
    }
    return true;
}

fn isResourceName(name: []const u8, comptime collection: []const u8) bool {
    const prefix = "projects/";
    if (!std.mem.startsWith(u8, name, prefix)) return false;
    const rest = name[prefix.len..];
    const middle = "/" ++ collection ++ "/";
    const at = std.mem.indexOf(u8, rest, middle) orelse return false;
    if (at == 0) return false;
    return isResourceId(rest[at + middle.len ..]);
}

fn startsWithGoog(text: []const u8) bool {
    return text.len >= 4 and std.ascii.eqlIgnoreCase(text[0..4], "goog");
}

/// The three keys a schema topic writes, which production takes from any
/// publisher.
fn isSchemaAttribute(key: []const u8) bool {
    for ([_][]const u8{ "googclient_schemaname", "googclient_schemaencoding", "googclient_schemarevisionid" }) |k| {
        if (std.mem.eql(u8, key, k)) return true;
    }
    return false;
}

fn Parsed(comptime T: type) type {
    return union(enum) { ok: T, refused: FakePubSub.Reply };
}

fn parseObject(arena: Allocator, body: []const u8) Allocator.Error!Parsed(std.json.ObjectMap) {
    const text = if (std.mem.trim(u8, body, " \t\r\n").len == 0) "{}" else body;
    const value = std.json.parseFromSliceLeaky(Value, arena, text, .{}) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        // Production says where the text went wrong; the fake only that
        // it did.
        else => return .{ .refused = try fail(arena, 400, "INVALID_ARGUMENT", "Invalid JSON payload received.") },
    };
    return switch (value) {
        .object => |o| .{ .ok = o },
        else => .{ .refused = try fail(arena, 400, "INVALID_ARGUMENT", "Invalid JSON payload received.") },
    };
}

const Update = struct { resource: std.json.ObjectMap, paths: []const []const u8 };

/// A patch's body: the resource under `field`, and the mask's paths.
fn parseUpdate(arena: Allocator, body: []const u8, comptime field: []const u8, comptime request: []const u8) Allocator.Error!Parsed(Update) {
    const object = switch (try parseObject(arena, body)) {
        .ok => |o| o,
        .refused => |r| return .{ .refused = r },
    };
    var resource: std.json.ObjectMap = .empty;
    var mask: []const u8 = "";
    var it = object.iterator();
    while (it.next()) |entry| {
        const key = entry.key_ptr.*;
        if (isField(key, field)) {
            resource = switch (entry.value_ptr.*) {
                .object => |o| o,
                else => return .{ .refused = try badValue(arena, key) },
            };
        } else if (isField(key, "updateMask")) {
            mask = stringOf(entry.value_ptr.*) orelse return .{ .refused = try badValue(arena, key) };
        } else return .{ .refused = try unknownName(arena, key) };
    }
    var paths: std.ArrayList([]const u8) = .empty;
    var parts = std.mem.splitScalar(u8, mask, ',');
    while (parts.next()) |part| {
        const path = std.mem.trim(u8, part, " ");
        if (path.len > 0) try paths.append(arena, path);
    }
    if (paths.items.len == 0) return .{ .refused = try fail(arena, 400, "INVALID_ARGUMENT", "The update_mask in the " ++ request ++ " must be set, and must contain a non-empty paths list.") };
    return .{ .ok = .{ .resource = resource, .paths = paths.items } };
}

/// A JSON name in either of the spellings proto3 takes: `ackDeadlineSeconds`
/// or `ack_deadline_seconds`.
fn isField(key: []const u8, comptime camel: []const u8) bool {
    return std.mem.eql(u8, key, camel) or std.mem.eql(u8, key, comptime snakeOf(camel));
}

fn isAnyField(key: []const u8, comptime camels: []const []const u8) bool {
    inline for (camels) |camel| if (isField(key, camel)) return true;
    return false;
}

/// A mask path, which production takes in either spelling too.
const isPath = isField;
const isAnyPath = isAnyField;

fn snakeOf(comptime camel: []const u8) []const u8 {
    comptime {
        var out: []const u8 = "";
        for (camel) |c| {
            if (std.ascii.isUpper(c)) {
                out = out ++ "_" ++ [_]u8{std.ascii.toLower(c)};
            } else out = out ++ [_]u8{c};
        }
        return out;
    }
}

/// What the resource in a patch holds under a mask path, in either
/// spelling; null when it holds nothing there, which clears the field.
fn fieldOf(resource: std.json.ObjectMap, path: []const u8) ?Value {
    var it = resource.iterator();
    while (it.next()) |entry| {
        if (sameField(entry.key_ptr.*, path)) return switch (entry.value_ptr.*) {
            .null => null,
            else => entry.value_ptr.*,
        };
    }
    return null;
}

/// Two spellings of one field: compared with underscores dropped and case
/// ignored.
fn sameField(a: []const u8, b: []const u8) bool {
    var i: usize = 0;
    var j: usize = 0;
    while (true) {
        while (i < a.len and a[i] == '_') i += 1;
        while (j < b.len and b[j] == '_') j += 1;
        if (i == a.len or j == b.len) return i == a.len and j == b.len;
        if (std.ascii.toLower(a[i]) != std.ascii.toLower(b[j])) return false;
        i += 1;
        j += 1;
    }
}

fn stringOf(value: Value) ?[]const u8 {
    return switch (value) {
        .string => |s| s,
        else => null,
    };
}

fn boolOf(value: Value) ?bool {
    return switch (value) {
        .bool => |b| b,
        else => null,
    };
}

/// An integer, as a number or as the string proto3 JSON also takes.
fn intOf(value: Value) ?i64 {
    return switch (value) {
        .integer => |i| i,
        .string, .number_string => |s| std.fmt.parseInt(i64, s, 10) catch null,
        else => null,
    };
}

fn stringMapOf(arena: Allocator, value: Value) Allocator.Error!?[]const FakePubSub.Label {
    const object = switch (value) {
        .object => |o| o,
        else => return null,
    };
    const out = try arena.alloc(FakePubSub.Label, object.count());
    var it = object.iterator();
    var i: usize = 0;
    while (it.next()) |entry| : (i += 1) {
        out[i] = .{ .key = entry.key_ptr.*, .value = stringOf(entry.value_ptr.*) orelse return null };
    }
    return out;
}

fn storagePolicyOf(arena: Allocator, value: Value) Allocator.Error!?FakePubSub.StoragePolicy {
    const object = switch (value) {
        .object => |o| o,
        else => return null,
    };
    var policy: FakePubSub.StoragePolicy = .{ .regions = &.{}, .enforce_in_transit = false };
    var it = object.iterator();
    while (it.next()) |entry| {
        if (isField(entry.key_ptr.*, "allowedPersistenceRegions")) {
            const list = switch (entry.value_ptr.*) {
                .array => |a| a.items,
                else => return null,
            };
            const regions = try arena.alloc([]const u8, list.len);
            for (list, regions) |item, *slot| slot.* = stringOf(item) orelse return null;
            policy.regions = regions;
        } else if (isField(entry.key_ptr.*, "enforceInTransit")) {
            policy.enforce_in_transit = boolOf(entry.value_ptr.*) orelse return null;
        } else return null;
    }
    return policy;
}

/// Standard base64, or the URL-safe alphabet, with or without padding, as
/// proto3 JSON reads bytes.
fn decodeBase64(arena: Allocator, text: []const u8) Allocator.Error!?[]const u8 {
    const trimmed = std.mem.trimEnd(u8, text, "=");
    const normal = try arena.dupe(u8, trimmed);
    for (normal) |*c| switch (c.*) {
        '-' => c.* = '+',
        '_' => c.* = '/',
        else => {},
    };
    const decoder = std.base64.standard_no_pad.Decoder;
    const size = decoder.calcSizeForSlice(normal) catch return null;
    const out = try arena.alloc(u8, size);
    decoder.decode(out, normal) catch return null;
    return out;
}

// Rules of production's, each in its words.

/// At most 64; a key of 1 to 63 lowercase letters, digits, `_` and `-`,
/// beginning with a letter; a value of up to 63 of the same. Any
/// character outside ASCII counts as a lowercase letter here.
fn labelsOf(arena: Allocator, value: Value) Allocator.Error!Parsed([]const FakePubSub.Label) {
    const labels = (try stringMapOf(arena, value)) orelse return .{ .refused = try badValue(arena, "labels") };
    if (labels.len > 64) return .{ .refused = try fail(arena, 400, "INVALID_ARGUMENT", try std.fmt.allocPrint(arena, "You have passed an invalid argument to the service (argument=Invalid labels: Invalid field \"labels\"; at most 64 entries allowed but found {d}).", .{labels.len})) };
    for (labels) |label| {
        if (!isLabelText(label.key, true)) {
            // Production's words for a first character in capitals; for
            // the other ways a key can be wrong, the fake's own after them.
            const first_upper = label.key.len > 0 and std.ascii.isUpper(label.key[0]);
            const why = if (first_upper)
                try std.fmt.allocPrint(arena, "first character \"{c}\" is not a non-uppercased letter (Unicode character class Ll or Lo)", .{label.key[0]})
            else
                "fake: the key is empty, too long, or holds a character outside the expression";
            return .{ .refused = try fail(arena, 400, "INVALID_ARGUMENT", try std.fmt.allocPrint(arena, "You have passed an invalid argument to the service (argument=Invalid labels: Invalid field \"labels\"; key \"{s}\" does not conform to regular expression \"[\\p{{Ll}}\\p{{Lo}}][\\p{{Ll}}\\p{{Lo}}\\p{{N}}_-]{{0,62}}\"; {s}).", .{ label.key, why })) };
        }
        if (!isLabelText(label.value, false)) return .{ .refused = try fail(arena, 400, "INVALID_ARGUMENT", try std.fmt.allocPrint(arena, "You have passed an invalid argument to the service (argument=Invalid labels: Invalid field \"labels\"; value \"{s}\" does not conform to regular expression \"[\\p{{Ll}}\\p{{Lo}}\\p{{N}}_-]{{0,63}}\"; fake: the value is too long or holds a character outside the expression).", .{label.value})) };
    }
    return .{ .ok = labels };
}

fn isLabelText(text: []const u8, is_key: bool) bool {
    if (!std.unicode.utf8ValidateSlice(text)) return false;
    var view = std.unicode.Utf8View.initUnchecked(text).iterator();
    var count: usize = 0;
    while (view.nextCodepoint()) |cp| : (count += 1) {
        const letter = cp >= 0x80 or (cp >= 'a' and cp <= 'z');
        const later = letter or (cp >= '0' and cp <= '9') or cp == '_' or cp == '-';
        if (is_key and count == 0) {
            if (!letter) return false;
        } else if (!later) return false;
    }
    return if (is_key) count >= 1 and count <= 63 else count <= 63;
}

/// A duration as proto3 JSON writes one, in whole seconds: `600s`.
fn secondsOf(value: Value) ?i64 {
    const text = stringOf(value) orelse return null;
    if (text.len < 2 or text[text.len - 1] != 's') return null;
    const number = text[0 .. text.len - 1];
    const whole = if (std.mem.indexOfScalar(u8, number, '.')) |dot| number[0..dot] else number;
    return std.fmt.parseInt(i64, whole, 10) catch null;
}

/// 10 minutes to 31 days, for a topic's retention and a subscription's.
fn retentionOf(arena: Allocator, value: Value) Allocator.Error!Parsed(i64) {
    const seconds = secondsOf(value) orelse return .{ .refused = try badValue(arena, "messageRetentionDuration") };
    if (seconds < 600 or seconds > 2_678_400) return .{ .refused = try fail(arena, 400, "INVALID_ARGUMENT", try std.fmt.allocPrint(arena, "The value for message retention duration is out of bounds. You passed {s} in the request, but the value must be between 10m and 744h.", .{try goDuration(arena, seconds)})) };
    return .{ .ok = seconds };
}

/// `{}` never expires; a `ttl` is a day at least.
fn expirationOf(arena: Allocator, value: Value) Allocator.Error!Parsed(?i64) {
    const object = switch (value) {
        .object => |o| o,
        else => return .{ .refused = try badValue(arena, "expirationPolicy") },
    };
    const ttl = object.get("ttl") orelse return .{ .ok = null };
    const seconds = secondsOf(ttl) orelse return .{ .refused = try badValue(arena, "ttl") };
    if (seconds < 86_400) return .{ .refused = try fail(arena, 400, "INVALID_ARGUMENT", try std.fmt.allocPrint(arena, "The value for expiration duration is too small. You passed {s} in the request, but the minimum value is 24h.", .{try goDuration(arena, seconds)})) };
    return .{ .ok = seconds };
}

/// A subscription cannot keep messages past its own expiry. Production
/// holds a create and an update to that when the expiry was given.
fn expirationRefusal(arena: Allocator, retention_s: i64, ttl_s: ?i64, given: bool) ?Allocator.Error!FakePubSub.Reply {
    const ttl = ttl_s orelse return null;
    if (!given or retention_s <= ttl) return null;
    const message = std.fmt.allocPrint(arena, "The subscription's message retention duration ({d} seconds) cannot be greater than the TTL in the subscription's expiration policy ({d} seconds), since messages cannot be retained past subscription expiration.", .{ retention_s, ttl }) catch return error.OutOfMemory;
    return fail(arena, 400, "INVALID_ARGUMENT", message);
}

/// A duration as production's refusals write one: `9m59s`, `744h1s`, `1h`.
fn goDuration(arena: Allocator, seconds: i64) Allocator.Error![]const u8 {
    if (seconds <= 0) return "0s";
    const h = @divTrunc(seconds, 3600);
    const m = @divTrunc(@mod(seconds, 3600), 60);
    const s = @mod(seconds, 60);
    var out: std.ArrayList(u8) = .empty;
    if (h > 0) try out.print(arena, "{d}h", .{h});
    if (m > 0) try out.print(arena, "{d}m", .{m});
    if (s > 0) try out.print(arena, "{d}s", .{s});
    return out.items;
}

const Page = struct { size: usize, after: ?[]const u8 };

/// A list's page: `pageSize` of 0 to 1000, where 0 and none are the
/// default, and a `pageToken` this fake gave.
fn pageOf(arena: Allocator, query: []const u8) Allocator.Error!Parsed(Page) {
    var page: Page = .{ .size = 100, .after = null };
    var parts = std.mem.splitScalar(u8, query, '&');
    while (parts.next()) |part| {
        const eq = std.mem.indexOfScalar(u8, part, '=') orelse continue;
        const key = part[0..eq];
        const value = try percentDecode(arena, part[eq + 1 ..]);
        if (std.mem.eql(u8, key, "pageSize")) {
            const size = std.fmt.parseInt(i64, value, 10) catch return .{ .refused = try badValue(arena, "pageSize") };
            if (size < 0 or size > 1000) return .{ .refused = try fail(arena, 400, "INVALID_ARGUMENT", try std.fmt.allocPrint(arena, "The value for page_size is out of bounds. You passed {d} in the request, but the value must be between 0 and 1000.", .{size})) };
            if (size > 0) page.size = @intCast(size);
        } else if (std.mem.eql(u8, key, "pageToken")) {
            if (value.len == 0) continue;
            page.after = (try nameOfToken(arena, value)) orelse return .{ .refused = try fail(arena, 400, "INVALID_ARGUMENT", try std.fmt.allocPrint(arena, "Invalid page token given (token={s}).", .{value})) };
        }
    }
    return .{ .ok = page };
}

const token_prefix = "fake-";

/// A page token says which name the next page begins with, in a form no
/// test should read.
fn pageToken(arena: Allocator, name: []const u8) Allocator.Error![]const u8 {
    const encoder = std.base64.url_safe_no_pad.Encoder;
    const out = try arena.alloc(u8, token_prefix.len + encoder.calcSize(name.len));
    @memcpy(out[0..token_prefix.len], token_prefix);
    _ = encoder.encode(out[token_prefix.len..], name);
    return out;
}

fn nameOfToken(arena: Allocator, token: []const u8) Allocator.Error!?[]const u8 {
    if (!std.mem.startsWith(u8, token, token_prefix)) return null;
    const decoder = std.base64.url_safe_no_pad.Decoder;
    const text = token[token_prefix.len..];
    const size = decoder.calcSizeForSlice(text) catch return null;
    const out = try arena.alloc(u8, size);
    decoder.decode(out, text) catch return null;
    return out;
}

const ack_prefix = "FAKE";

/// An ack id names the subscription, the message's place in it and which
/// delivery it was, in a form no test should read.
fn ackId(arena: Allocator, uid: u64, seq: u64, delivery: u32) Allocator.Error![]const u8 {
    var plain: [64]u8 = undefined;
    const text = std.fmt.bufPrint(&plain, "{d}:{d}:{d}", .{ uid, seq, delivery }) catch unreachable;
    const encoder = std.base64.url_safe_no_pad.Encoder;
    const out = try arena.alloc(u8, ack_prefix.len + encoder.calcSize(text.len));
    @memcpy(out[0..ack_prefix.len], ack_prefix);
    _ = encoder.encode(out[ack_prefix.len..], text);
    return out;
}

fn parseAckId(id: []const u8) ?struct { uid: u64, seq: u64 } {
    if (!std.mem.startsWith(u8, id, ack_prefix)) return null;
    const decoder = std.base64.url_safe_no_pad.Decoder;
    const text = id[ack_prefix.len..];
    var plain: [64]u8 = undefined;
    const size = decoder.calcSizeForSlice(text) catch return null;
    if (size > plain.len) return null;
    decoder.decode(plain[0..size], text) catch return null;
    var parts = std.mem.splitScalar(u8, plain[0..size], ':');
    const uid = std.fmt.parseInt(u64, parts.next() orelse return null, 10) catch return null;
    const seq = std.fmt.parseInt(u64, parts.next() orelse return null, 10) catch return null;
    _ = std.fmt.parseInt(u32, parts.next() orelse return null, 10) catch return null;
    if (parts.next() != null) return null;
    return .{ .uid = uid, .seq = seq };
}

// Answers.

fn ok(body: []const u8) FakePubSub.Reply {
    return .{ .status = 200, .body = body };
}

fn fail(arena: Allocator, code: u16, status: []const u8, message: []const u8) Allocator.Error!FakePubSub.Reply {
    return .{ .status = code, .body = try Stringify.valueAlloc(arena, .{ .@"error" = .{
        .code = code,
        .message = message,
        .status = status,
    } }, .{}) };
}

fn statusName(code: u16) []const u8 {
    return switch (code) {
        400 => "INVALID_ARGUMENT",
        401 => "UNAUTHENTICATED",
        403 => "PERMISSION_DENIED",
        404 => "NOT_FOUND",
        409 => "ABORTED",
        429 => "RESOURCE_EXHAUSTED",
        500 => "INTERNAL",
        504 => "DEADLINE_EXCEEDED",
        else => "UNAVAILABLE",
    };
}

fn notFound(arena: Allocator, id: []const u8) Allocator.Error!FakePubSub.Reply {
    return fail(arena, 404, "NOT_FOUND", try std.fmt.allocPrint(arena, "Resource not found (resource={s}).", .{id}));
}

fn alreadyExists(arena: Allocator, id: []const u8) Allocator.Error!FakePubSub.Reply {
    return fail(arena, 409, "ALREADY_EXISTS", try std.fmt.allocPrint(arena, "Resource already exists in the project (resource={s}).", .{id}));
}

fn invalidName(arena: Allocator, name: []const u8) Allocator.Error!FakePubSub.Reply {
    return fail(arena, 400, "INVALID_ARGUMENT", try std.fmt.allocPrint(arena, "Invalid resource name given (name={s}). Refer to https://cloud.google.com/pubsub/docs/pubsub-basics#resource_names for more information.", .{name}));
}

fn unknownName(arena: Allocator, name: []const u8) Allocator.Error!FakePubSub.Reply {
    return fail(arena, 400, "INVALID_ARGUMENT", try std.fmt.allocPrint(arena, "Invalid JSON payload received. Unknown name \"{s}\": Cannot find field.", .{name}));
}

/// A field of the wrong JSON type. Production's words name the type it
/// wanted; the fake's only the field.
fn badValue(arena: Allocator, name: []const u8) Allocator.Error!FakePubSub.Reply {
    return fail(arena, 400, "INVALID_ARGUMENT", try std.fmt.allocPrint(arena, "Invalid value at '{s}'", .{name}));
}

fn unknownPath(arena: Allocator, comptime request: []const u8, path: []const u8, comptime resource: []const u8) Allocator.Error!FakePubSub.Reply {
    return fail(arena, 400, "INVALID_ARGUMENT", try std.fmt.allocPrint(arena, "Invalid update_mask provided in the " ++ request ++ ": '{s}' is not a known " ++ resource ++ " field. Note that field paths must be of the form 'push_config' rather than 'pushConfig'.", .{path}));
}

fn immutable(arena: Allocator, comptime request: []const u8, comptime field: []const u8, comptime resource: []const u8) Allocator.Error!FakePubSub.Reply {
    return fail(arena, 400, "INVALID_ARGUMENT", "Invalid update_mask provided in the " ++ request ++ ": the '" ++ field ++ "' field in the " ++ resource ++ " is not mutable.");
}

/// What this fake has no answer for: said, never guessed at.
fn notModelled(arena: Allocator, what: []const u8) Allocator.Error!FakePubSub.Reply {
    return fail(arena, 501, "UNIMPLEMENTED", try std.fmt.allocPrint(arena, "fake: {s} is not modelled yet", .{what}));
}

fn renderTopic(arena: Allocator, topic: *const FakePubSub.Topic) Allocator.Error![]const u8 {
    var out: std.Io.Writer.Allocating = .init(arena);
    var jw: Stringify = .{ .writer = &out.writer };
    writeTopic(&jw, topic) catch return error.OutOfMemory;
    return out.written();
}

fn writeTopic(jw: *Stringify, topic: *const FakePubSub.Topic) Stringify.Error!void {
    try jw.beginObject();
    try jw.objectField("name");
    try jw.write(topic.name);
    if (topic.labels.len > 0) {
        try jw.objectField("labels");
        try writeLabels(jw, topic.labels);
    }
    if (topic.storage_policy) |policy| {
        try jw.objectField("messageStoragePolicy");
        try jw.beginObject();
        try jw.objectField("allowedPersistenceRegions");
        try jw.write(policy.regions);
        if (policy.enforce_in_transit) {
            try jw.objectField("enforceInTransit");
            try jw.write(true);
        }
        try jw.endObject();
    }
    if (topic.kms_key_name) |key| {
        try jw.objectField("kmsKeyName");
        try jw.write(key);
    }
    if (topic.retention_s) |seconds| {
        try jw.objectField("messageRetentionDuration");
        try writeSeconds(jw, seconds);
    }
    try jw.endObject();
}

fn renderSubscription(arena: Allocator, sub: *const FakePubSub.Subscription) Allocator.Error![]const u8 {
    var out: std.Io.Writer.Allocating = .init(arena);
    var jw: Stringify = .{ .writer = &out.writer };
    writeSubscription(&jw, sub) catch return error.OutOfMemory;
    return out.written();
}

/// In the order production writes the fields.
fn writeSubscription(jw: *Stringify, sub: *const FakePubSub.Subscription) Stringify.Error!void {
    try jw.beginObject();
    try jw.objectField("name");
    try jw.write(sub.name);
    try jw.objectField("topic");
    try jw.write(if (sub.topic) |t| t.name else "_deleted-topic_");
    try jw.objectField("pushConfig");
    try jw.beginObject();
    if (sub.updated) {
        try jw.objectField("attributes");
        try jw.beginObject();
        try jw.objectField("x-goog-version");
        try jw.write("v1");
        try jw.endObject();
    }
    try jw.endObject();
    try jw.objectField("ackDeadlineSeconds");
    try jw.write(sub.ack_deadline_s);
    if (sub.retain_acked) {
        try jw.objectField("retainAckedMessages");
        try jw.write(true);
    }
    try jw.objectField("messageRetentionDuration");
    try writeSeconds(jw, sub.retention_s);
    if (sub.labels.len > 0) {
        try jw.objectField("labels");
        try writeLabels(jw, sub.labels);
    }
    try jw.objectField("expirationPolicy");
    try jw.beginObject();
    if (sub.expiration_ttl_s) |ttl| {
        try jw.objectField("ttl");
        try writeSeconds(jw, ttl);
    }
    try jw.endObject();
    try jw.objectField("state");
    try jw.write("ACTIVE");
    try jw.endObject();
}

fn writeLabels(jw: *Stringify, labels: []const FakePubSub.Label) Stringify.Error!void {
    try jw.beginObject();
    for (labels) |label| {
        try jw.objectField(label.key);
        try jw.write(label.value);
    }
    try jw.endObject();
}

fn writeSeconds(jw: *Stringify, seconds: i64) Stringify.Error!void {
    var buf: [24]u8 = undefined;
    try jw.write(std.fmt.bufPrint(&buf, "{d}s", .{seconds}) catch unreachable);
}

// Tests.

const testing = std.testing;
const test_util = @import("test_util.zig");
const Client = @import("Client.zig");
const types = @import("types.zig");

/// A fake, a clock the test moves, and a client of production's kind over
/// both.
const Bench = struct {
    clock: test_util.FakeClock,
    fake: FakePubSub,
    tokens: test_util.FakeTokenProvider,
    diag: core.Diagnostics,
    client: Client,

    fn init(b: *Bench, options: FakePubSub.Options) !void {
        b.clock = .{};
        b.fake = .init(testing.allocator, b.clock.io(), options);
        errdefer b.fake.deinit();
        b.tokens = .{};
        b.diag = .{};
        b.client = try .init(testing.allocator, b.clock.io(), .{
            .project_id = "p",
            .token_provider = b.tokens.provider(),
            .transport = b.fake.transport(),
            .diagnostics = &b.diag,
        });
    }

    fn deinit(b: *Bench) void {
        b.client.deinit();
        b.fake.deinit();
    }

    fn advance(b: *Bench, seconds: i64) void {
        b.clock.now_ns += @as(i96, seconds) * std.time.ns_per_s;
    }

    /// One raw request, for what no client would send.
    fn raw(b: *Bench, arena: Allocator, method: tp.Method, path: []const u8, body: []const u8) !FakePubSub.Reply {
        const url = try std.fmt.allocPrint(arena, "https://pubsub.googleapis.com/v1/{s}", .{path});
        return b.fake.serve(method, url, body, arena);
    }
};

test "a message goes from a publish to a pull, and an ack takes it away" {
    var b: Bench = undefined;
    try b.init(.{});
    defer b.deinit();
    var topic = try b.client.topic("orders").create(.{});
    defer topic.deinit();
    try testing.expectEqualStrings("projects/p/topics/orders", topic.value.name);
    var sub = try b.client.subscription("worker").create(.{ .topic_id = "orders" });
    defer sub.deinit();
    try testing.expectEqual(10, sub.value.ack_deadline_seconds);
    try testing.expectEqual(std.Io.Duration.fromSeconds(604_800), sub.value.message_retention.?);

    var sent = try b.client.topic("orders").publish(&.{.{ .data = "hello", .attributes = &.{.{ .key = "k", .value = "v" }} }}, .{});
    defer sent.deinit();
    try testing.expectEqualStrings("1", sent.value.message_ids[0]);
    try testing.expectEqual(1, b.fake.backlog("p", "worker"));

    var got = try b.client.subscription("worker").pull(.{});
    defer got.deinit();
    try testing.expectEqual(1, got.value.messages.len);
    try testing.expectEqualStrings("hello", got.value.messages[0].data);
    try testing.expectEqualStrings("v", got.value.messages[0].attribute("k").?);
    try testing.expectEqualStrings("1", got.value.messages[0].message_id);
    try testing.expectEqual(1, b.fake.outstanding("p", "worker"));

    try b.client.subscription("worker").ack(&.{got.value.messages[0].ack_id});
    try testing.expectEqual(0, b.fake.backlog("p", "worker"));
    var none = try b.client.subscription("worker").pull(.{ .return_immediately = true });
    defer none.deinit();
    try testing.expectEqual(0, none.value.messages.len);
}

/// Asserts a refusal's HTTP code, status and words.
fn expectRefused(reply: FakePubSub.Reply, code: u16, status: []const u8, message: []const u8) !void {
    try testing.expectEqual(code, reply.status);
    const parsed = try std.json.parseFromSlice(struct { @"error": struct { code: u16, message: []const u8, status: []const u8 } }, testing.allocator, reply.body, .{});
    defer parsed.deinit();
    try testing.expectEqual(code, parsed.value.@"error".code);
    try testing.expectEqualStrings(status, parsed.value.@"error".status);
    try testing.expectEqualStrings(message, parsed.value.@"error".message);
}

test "topics: made, read, changed and deleted, and refused in production's words" {
    var b: Bench = undefined;
    try b.init(.{});
    defer b.deinit();
    var scratch: std.heap.ArenaAllocator = .init(testing.allocator);
    defer scratch.deinit();
    const a = scratch.allocator();

    // Production's answers, 2026-10-12.
    try testing.expectEqualStrings("{\"name\":\"projects/p/topics/zigps-a\"}", (try b.raw(a, .PUT, "projects/p/topics/zigps-a", "{}")).body);
    try expectRefused(try b.raw(a, .PUT, "projects/p/topics/zigps-a", "{}"), 409, "ALREADY_EXISTS", "Resource already exists in the project (resource=zigps-a).");
    try expectRefused(try b.raw(a, .PUT, "projects/p/topics/zigps-x", "{\"nonsense\":1}"), 400, "INVALID_ARGUMENT", "Invalid JSON payload received. Unknown name \"nonsense\": Cannot find field.");
    try testing.expectEqual(400, (try b.raw(a, .PUT, "projects/p/topics/zigps-x", "{")).status);
    // A name in the body is ignored: the path names the topic.
    try testing.expectEqualStrings("{\"name\":\"projects/p/topics/zigps-x3\"}", (try b.raw(a, .PUT, "projects/p/topics/zigps-x3", "{\"name\":\"projects/p/topics/other\"}")).body);
    try testing.expectEqualStrings(
        \\{"name":"projects/p/topics/zigps-b","labels":{"env":"test"},"messageRetentionDuration":"600s"}
    , (try b.raw(a, .PUT, "projects/p/topics/zigps-b", "{\"labels\":{\"env\":\"test\"},\"messageRetentionDuration\":\"600s\"}")).body);
    for ([_]tp.Method{ .GET, .DELETE }) |method| {
        try expectRefused(try b.raw(a, method, "projects/p/topics/zigps-nope", ""), 404, "NOT_FOUND", "Resource not found (resource=zigps-nope).");
    }
    try expectRefused(try b.raw(a, .PATCH, "projects/p/topics/zigps-nope", "{\"topic\":{\"labels\":{\"a\":\"b\"}},\"updateMask\":\"labels\"}"), 404, "NOT_FOUND", "Resource not found (resource=zigps-nope).");

    // Updates: a mask is required, names fields in either spelling, and a
    // field outside it is ignored.
    try testing.expectEqualStrings(
        \\{"name":"projects/p/topics/zigps-b","labels":{"env":"prod","team":"x"},"messageRetentionDuration":"600s"}
    , (try b.raw(a, .PATCH, "projects/p/topics/zigps-b", "{\"topic\":{\"labels\":{\"env\":\"prod\",\"team\":\"x\"}},\"updateMask\":\"labels\"}")).body);
    for ([_][]const u8{ "{\"topic\":{\"labels\":{\"a\":\"b\"}}}", "{\"topic\":{\"labels\":{\"a\":\"b\"}},\"updateMask\":\"\"}" }) |body| {
        try expectRefused(try b.raw(a, .PATCH, "projects/p/topics/zigps-b", body), 400, "INVALID_ARGUMENT", "The update_mask in the UpdateTopicRequest must be set, and must contain a non-empty paths list.");
    }
    try expectRefused(try b.raw(a, .PATCH, "projects/p/topics/zigps-b", "{\"topic\":{},\"updateMask\":\"nonsense\"}"), 400, "INVALID_ARGUMENT", "Invalid update_mask provided in the UpdateTopicRequest: 'nonsense' is not a known Topic field. Note that field paths must be of the form 'push_config' rather than 'pushConfig'.");
    try expectRefused(try b.raw(a, .PATCH, "projects/p/topics/zigps-b", "{\"topic\":{\"name\":\"projects/p/topics/other\"},\"updateMask\":\"name\"}"), 400, "INVALID_ARGUMENT", "Invalid update_mask provided in the UpdateTopicRequest: the 'name' field in the Topic is not mutable.");
    try testing.expectEqualStrings(
        \\{"name":"projects/p/topics/zigps-b","labels":{"only":"this"},"messageRetentionDuration":"600s"}
    , (try b.raw(a, .PATCH, "projects/p/topics/zigps-b", "{\"topic\":{\"labels\":{\"only\":\"this\"},\"messageRetentionDuration\":\"1200s\"},\"updateMask\":\"labels\"}")).body);
    try testing.expectEqualStrings(
        \\{"name":"projects/p/topics/zigps-b","labels":{"only":"this"},"messageRetentionDuration":"1200s"}
    , (try b.raw(a, .PATCH, "projects/p/topics/zigps-b", "{\"topic\":{\"messageRetentionDuration\":\"1200s\"},\"updateMask\":\"message_retention_duration\"}")).body);
    // A path the body leaves out clears its field.
    try testing.expectEqualStrings("{\"name\":\"projects/p/topics/zigps-b\"}", (try b.raw(a, .PATCH, "projects/p/topics/zigps-b", "{\"topic\":{},\"updateMask\":\"labels,messageRetentionDuration\"}")).body);

    // Bounds and names.
    try expectRefused(try b.raw(a, .PUT, "projects/p/topics/zigps-x4", "{\"messageRetentionDuration\":\"599s\"}"), 400, "INVALID_ARGUMENT", "The value for message retention duration is out of bounds. You passed 9m59s in the request, but the value must be between 10m and 744h.");
    try expectRefused(try b.raw(a, .PUT, "projects/p/topics/zigps-x5", "{\"messageRetentionDuration\":\"2678401s\"}"), 400, "INVALID_ARGUMENT", "The value for message retention duration is out of bounds. You passed 744h1s in the request, but the value must be between 10m and 744h.");
    try expectRefused(try b.raw(a, .PUT, "projects/p/topics/zigps-x6", "{\"labels\":{\"Env\":\"x\"}}"), 400, "INVALID_ARGUMENT", "You have passed an invalid argument to the service (argument=Invalid labels: Invalid field \"labels\"; key \"Env\" does not conform to regular expression \"[\\p{Ll}\\p{Lo}][\\p{Ll}\\p{Lo}\\p{N}_-]{0,62}\"; first character \"E\" is not a non-uppercased letter (Unicode character class Ll or Lo)).");
    var many: std.Io.Writer.Allocating = .init(a);
    try many.writer.writeAll("{\"labels\":{");
    for (0..65) |i| try many.writer.print("{s}\"k{d}\":\"v\"", .{ if (i == 0) "" else ",", i });
    try many.writer.writeAll("}}");
    try expectRefused(try b.raw(a, .PUT, "projects/p/topics/zigps-x7", many.written()), 400, "INVALID_ARGUMENT", "You have passed an invalid argument to the service (argument=Invalid labels: Invalid field \"labels\"; at most 64 entries allowed but found 65).");
    for ([_][]const u8{ "ab", "1zigps", "googzigps", "GOOGzigps", "zigps!x" }) |id| {
        const path = try std.fmt.allocPrint(a, "projects/p/topics/{s}", .{id});
        const reply = try b.raw(a, .PUT, path, "{}");
        try expectRefused(reply, 400, "INVALID_ARGUMENT", try std.fmt.allocPrint(a, "Invalid resource name given (name=projects/p/topics/{s}). Refer to https://cloud.google.com/pubsub/docs/pubsub-basics#resource_names for more information.", .{id}));
    }
    const long_id = try a.alloc(u8, 256);
    @memset(long_id, 'b');
    long_id[0] = 'a';
    try testing.expectEqual(400, (try b.raw(a, .PUT, try std.fmt.allocPrint(a, "projects/p/topics/{s}", .{long_id}), "{}")).status);
    try testing.expectEqual(200, (try b.raw(a, .PUT, try std.fmt.allocPrint(a, "projects/p/topics/{s}", .{long_id[0..255]}), "{}")).status);
    // An id with the characters a path must encode reaches it decoded.
    try testing.expectEqualStrings("{\"name\":\"projects/p/topics/a%b+c~d.e\"}", (try b.raw(a, .PUT, "projects/p/topics/a%25b%2Bc~d.e", "{}")).body);

    // Through the client: what it sends is what the fake keeps.
    var made = try b.client.topic("orders").create(.{
        .labels = &.{.{ .key = "env", .value = "test" }},
        .message_retention = .fromSeconds(3600),
        .kms_key_name = "projects/p/locations/l/keyRings/r/cryptoKeys/k",
        .message_storage_policy = .{ .allowed_persistence_regions = &.{ "europe-west1", "europe-west4" }, .enforce_in_transit = true },
    });
    defer made.deinit();
    var read = try b.client.topic("orders").get();
    defer read.deinit();
    try testing.expectEqualStrings("test", read.value.label("env").?);
    try testing.expectEqual(std.Io.Duration.fromSeconds(3600), read.value.message_retention.?);
    try testing.expectEqualStrings("projects/p/locations/l/keyRings/r/cryptoKeys/k", read.value.kms_key_name.?);
    try testing.expectEqual(2, read.value.message_storage_policy.?.allowed_persistence_regions.len);
    try testing.expect(read.value.message_storage_policy.?.enforce_in_transit);
    var changed = try b.client.topic("orders").update(.{ .labels = &.{}, .message_retention = .clear, .kms_key_name = .clear, .message_storage_policy = .clear });
    defer changed.deinit();
    try testing.expectEqual(0, changed.value.labels.len);
    try testing.expectEqual(null, changed.value.message_retention);
    try testing.expectEqual(null, changed.value.kms_key_name);
    try testing.expectEqual(null, changed.value.message_storage_policy);
    try testing.expectError(error.AlreadyExists, b.client.topic("orders").create(.{}));
    try testing.expectEqualStrings("Resource already exists in the project (resource=orders).", b.diag.message());
    try b.client.topic("orders").delete();
    try testing.expectError(error.NotFound, b.client.topic("orders").get());
    try testing.expectEqualStrings("Resource not found (resource=orders).", b.diag.message());
    // What is not modelled yet says so, and guesses nothing.
    try testing.expectError(error.Unimplemented, b.client.topic("typed").create(.{ .schema = .{ .schema = "order", .encoding = .json } }));
    try testing.expectEqualStrings("fake: schemaSettings is not modelled yet", b.diag.message());
}

test "lists: in name order, in pages, with tokens only this fake gave" {
    var b: Bench = undefined;
    try b.init(.{});
    defer b.deinit();
    var scratch: std.heap.ArenaAllocator = .init(testing.allocator);
    defer scratch.deinit();
    const a = scratch.allocator();

    // An empty project answers `{}`.
    try testing.expectEqualStrings("{}", (try b.raw(a, .GET, "projects/p/topics", "")).body);
    try testing.expectEqualStrings("{}", (try b.raw(a, .GET, "projects/p/subscriptions?pageSize=2", "")).body);
    for ([_][]const u8{ "delta", "alpha", "echo", "charlie", "bravo" }) |id| {
        var made = try b.client.topic(id).create(.{});
        made.deinit();
    }
    // Another project's topics are no part of this one's list.
    try testing.expectEqual(200, (try b.raw(a, .PUT, "projects/other/topics/aardvark", "{}")).status);

    var names: std.ArrayList([]const u8) = .empty;
    var token: ?[]const u8 = null;
    var pages: usize = 0;
    while (true) : (pages += 1) {
        var page = try b.client.listTopics(.{ .page_size = 2, .page_token = token });
        defer page.deinit();
        try testing.expect(page.value.topics.len <= 2);
        for (page.value.topics) |t| try names.append(a, try a.dupe(u8, t.name));
        token = try a.dupe(u8, page.value.next_page_token orelse break);
    }
    try testing.expectEqual(2, pages);
    try testing.expectEqual(5, names.items.len);
    for ([_][]const u8{ "alpha", "bravo", "charlie", "delta", "echo" }, names.items) |id, name| {
        try testing.expect(std.mem.endsWith(u8, name, id));
    }
    // No page size, or 0, is the default: all five.
    var all = try b.client.listTopics(.{});
    defer all.deinit();
    try testing.expectEqual(5, all.value.topics.len);
    try testing.expectEqual(null, all.value.next_page_token);

    try expectRefused(try b.raw(a, .GET, "projects/p/topics?pageSize=-1", ""), 400, "INVALID_ARGUMENT", "The value for page_size is out of bounds. You passed -1 in the request, but the value must be between 0 and 1000.");
    try expectRefused(try b.raw(a, .GET, "projects/p/topics?pageSize=1001", ""), 400, "INVALID_ARGUMENT", "The value for page_size is out of bounds. You passed 1001 in the request, but the value must be between 0 and 1000.");
    try expectRefused(try b.raw(a, .GET, "projects/p/topics?pageToken=not-a-token", ""), 400, "INVALID_ARGUMENT", "Invalid page token given (token=not-a-token).");
    try testing.expectEqual(200, (try b.raw(a, .GET, "projects/p/topics?pageSize=1000", "")).status);

    // Subscriptions, and the ones of a topic, by name.
    for ([_][]const u8{ "s-two", "s-one", "s-three" }) |id| {
        var made = try b.client.subscription(id).create(.{ .topic_id = if (std.mem.eql(u8, id, "s-two")) "bravo" else "alpha" });
        made.deinit();
    }
    var subs = try b.client.listSubscriptions(.{ .page_size = 2 });
    defer subs.deinit();
    try testing.expectEqual(2, subs.value.subscriptions.len);
    try testing.expectEqualStrings("projects/p/subscriptions/s-one", subs.value.subscriptions[0].name);
    try testing.expectEqualStrings("projects/p/subscriptions/s-three", subs.value.subscriptions[1].name);
    var rest = try b.client.listSubscriptions(.{ .page_size = 2, .page_token = subs.value.next_page_token.? });
    defer rest.deinit();
    try testing.expectEqual(1, rest.value.subscriptions.len);
    try testing.expectEqual(null, rest.value.next_page_token);
    var attached = try b.client.topic("alpha").listSubscriptions(.{ .page_size = 1 });
    defer attached.deinit();
    try testing.expectEqualStrings("projects/p/subscriptions/s-one", attached.value.names[0]);
    var attached_rest = try b.client.topic("alpha").listSubscriptions(.{ .page_token = attached.value.next_page_token.? });
    defer attached_rest.deinit();
    try testing.expectEqual(1, attached_rest.value.names.len);
    try testing.expectEqualStrings("projects/p/subscriptions/s-three", attached_rest.value.names[0]);
    var nothing = try b.client.topic("echo").listSubscriptions(.{});
    defer nothing.deinit();
    try testing.expectEqual(0, nothing.value.names.len);
    try testing.expectError(error.NotFound, b.client.topic("missing").listSubscriptions(.{}));
}

test "publish: ids in order, and every refusal in production's words" {
    var b: Bench = undefined;
    try b.init(.{});
    defer b.deinit();
    var scratch: std.heap.ArenaAllocator = .init(testing.allocator);
    defer scratch.deinit();
    const a = scratch.allocator();
    var made = try b.client.topic("orders").create(.{});
    made.deinit();
    const path = "projects/p/topics/orders:publish";

    try testing.expectEqualStrings("{\"messageIds\":[\"1\"]}", (try b.raw(a, .POST, path, "{\"messages\":[{\"data\":\"aGVsbG8=\",\"attributes\":{\"k\":\"v\"}}]}")).body);
    try testing.expectEqualStrings("{\"messageIds\":[\"2\",\"3\",\"4\"]}", (try b.raw(a, .POST, path, "{\"messages\":[{\"data\":\"YQ==\",\"orderingKey\":\"k\"},{\"data\":\"Yg==\",\"orderingKey\":\"k\"},{\"data\":\"Yw==\",\"orderingKey\":\"k\"}]}")).body);
    // Attributes alone are a message; an id and a time given are ignored.
    try testing.expectEqual(200, (try b.raw(a, .POST, path, "{\"messages\":[{\"attributes\":{\"k\":\"v\"}}]}")).status);
    try testing.expectEqualStrings("{\"messageIds\":[\"6\"]}", (try b.raw(a, .POST, path, "{\"messages\":[{\"data\":\"YQ==\",\"messageId\":\"7\",\"publishTime\":\"2020-01-01T00:00:00Z\"}]}")).body);
    try testing.expectEqual(6, b.fake.publishedCount("p", "orders"));

    try expectRefused(try b.raw(a, .POST, "projects/p/topics/nope:publish", "{\"messages\":[{\"data\":\"eA==\"}]}"), 404, "NOT_FOUND", "Resource not found (resource=nope).");
    for ([_][]const u8{ "{\"messages\":[]}", "{}" }) |body| {
        try expectRefused(try b.raw(a, .POST, path, body), 400, "INVALID_ARGUMENT", "The value for message_count is too small. You passed 0 in the request, but the minimum value is 1.");
    }
    try expectRefused(try b.raw(a, .POST, path, "{\"messages\":[{}]}"), 400, "INVALID_ARGUMENT", "One or more messages in the publish request is empty. Each message must contain either non-empty data, or at least one attribute.");
    try expectRefused(try b.raw(a, .POST, path, "{\"messages\":[{\"data\":\"!!!\"}]}"), 400, "INVALID_ARGUMENT", "Invalid value at 'messages[0].data' (TYPE_BYTES), Base64 decoding failed for \"!!!\"");
    for ([_][]const u8{
        "{\"messages\":[{\"data\":\"YQ==\",\"orderingKey\":\"k1\"},{\"data\":\"Yg==\",\"orderingKey\":\"k2\"}]}",
        "{\"messages\":[{\"data\":\"YQ==\",\"orderingKey\":\"k1\"},{\"data\":\"Yg==\"}]}",
    }) |body| {
        try expectRefused(try b.raw(a, .POST, path, body), 400, "FAILED_PRECONDITION", "In a single publish request, all messages must have no ordering key or they must all have the same ordering key. [code=539b]");
    }
    try expectRefused(try b.raw(a, .POST, path, "{\"messages\":[{\"data\":\"YQ==\",\"attributes\":{\"\":\"v\"}}]}"), 400, "INVALID_ARGUMENT", "The request contains an attribute key that is not valid (key=). Attribute keys must be non-empty and must not begin with 'goog' (case-insensitive).");
    try expectRefused(try b.raw(a, .POST, path, "{\"messages\":[{\"data\":\"YQ==\",\"attributes\":{\"GooGx\":\"v\"}}]}"), 400, "INVALID_ARGUMENT", "The request contains an attribute key that is not valid (key=GooGx). Attribute keys must be non-empty and must not begin with 'goog' (case-insensitive).");
    // The three keys a schema topic writes are taken from any publisher.
    try testing.expectEqual(200, (try b.raw(a, .POST, path, "{\"messages\":[{\"data\":\"YQ==\",\"attributes\":{\"googclient_schemaname\":\"x\"}}]}")).status);
    const long_value = try a.alloc(u8, 1025);
    @memset(long_value, 'v');
    try expectRefused(try b.raw(a, .POST, path, try std.fmt.allocPrint(a, "{{\"messages\":[{{\"data\":\"YQ==\",\"attributes\":{{\"k\":\"{s}\"}}}}]}}", .{long_value})), 400, "INVALID_ARGUMENT", "The attribute \"k\" in the request has a value that is too large. The size is 1025 bytes, but the maximum allowed is 1024. Refer to https://cloud.google.com/pubsub/quotas for more information.");
    try testing.expectEqual(200, (try b.raw(a, .POST, path, try std.fmt.allocPrint(a, "{{\"messages\":[{{\"data\":\"YQ==\",\"attributes\":{{\"k\":\"{s}\"}}}}]}}", .{long_value[0..1024]}))).status);
    try testing.expectEqual(400, (try b.raw(a, .POST, path, try std.fmt.allocPrint(a, "{{\"messages\":[{{\"data\":\"YQ==\",\"attributes\":{{\"{s}\":\"v\"}}}}]}}", .{long_value[0..257]}))).status);
    try testing.expectEqual(200, (try b.raw(a, .POST, path, try std.fmt.allocPrint(a, "{{\"messages\":[{{\"data\":\"YQ==\",\"attributes\":{{\"{s}\":\"v\"}}}}]}}", .{long_value[0..256]}))).status);
    try expectRefused(try b.raw(a, .POST, path, try std.fmt.allocPrint(a, "{{\"messages\":[{{\"data\":\"YQ==\",\"orderingKey\":\"{s}\"}}]}}", .{long_value})), 400, "INVALID_ARGUMENT", "An ordering key in the request is too long. The length is 1025 characters, but the maximum allowed is 1024. Refer to https://cloud.google.com/pubsub/quotas for more information.");
    var attrs: std.Io.Writer.Allocating = .init(a);
    try attrs.writer.writeAll("{\"messages\":[{\"data\":\"YQ==\",\"attributes\":{");
    for (0..101) |i| try attrs.writer.print("{s}\"k{d}\":\"v\"", .{ if (i == 0) "" else ",", i });
    try attrs.writer.writeAll("}}]}");
    try expectRefused(try b.raw(a, .POST, path, attrs.written()), 400, "INVALID_ARGUMENT", "There are too many attributes in the request. The request contains 101 attributes, but the maximum allowed is 100. Refer to https://cloud.google.com/pubsub/quotas for more information.");
    var bulk: std.Io.Writer.Allocating = .init(a);
    try bulk.writer.writeAll("{\"messages\":[");
    for (0..1001) |i| try bulk.writer.print("{s}{{\"data\":\"YQ==\"}}", .{if (i == 0) "" else ","});
    try bulk.writer.writeAll("]}");
    try expectRefused(try b.raw(a, .POST, path, bulk.written()), 400, "INVALID_ARGUMENT", "The value for message_count is too large. You passed 1001 in the request, but the maximum value is 1000.");
    // A refused request stores nothing, whichever message was at fault.
    const before = b.fake.publishedCount("p", "orders");
    try testing.expectEqual(400, (try b.raw(a, .POST, path, "{\"messages\":[{\"data\":\"YQ==\"},{}]}")).status);
    try testing.expectEqual(before, b.fake.publishedCount("p", "orders"));
    // The request's own limit, on the body as it arrives.
    const big = try a.alloc(u8, max_publish_bytes + 1);
    @memset(big, ' ');
    try expectRefused(try b.raw(a, .POST, path, big), 400, "INVALID_ARGUMENT", "Request payload size exceeds the limit: 10485760 bytes.");
}

test "subscriptions: production's defaults, its bounds, what an update may change, and a topic deleted under one" {
    var b: Bench = undefined;
    try b.init(.{});
    defer b.deinit();
    var scratch: std.heap.ArenaAllocator = .init(testing.allocator);
    defer scratch.deinit();
    const a = scratch.allocator();
    for ([_][]const u8{ "zigps-a", "zigps-b" }) |id| {
        var made = try b.client.topic(id).create(.{});
        made.deinit();
    }
    const topic = "\"topic\":\"projects/p/topics/zigps-a\"";

    // Production's answers, 2026-10-12, with its defaults filled in.
    const fresh =
        \\{"name":"projects/p/subscriptions/zigps-s","topic":"projects/p/topics/zigps-a","pushConfig":{},"ackDeadlineSeconds":10,"messageRetentionDuration":"604800s","expirationPolicy":{"ttl":"2678400s"},"state":"ACTIVE"}
    ;
    try testing.expectEqualStrings(fresh, (try b.raw(a, .PUT, "projects/p/subscriptions/zigps-s", "{" ++ topic ++ "}")).body);
    try testing.expectEqualStrings(fresh, (try b.raw(a, .GET, "projects/p/subscriptions/zigps-s", "")).body);
    for ([_][]const u8{ "zigps-a", "zigps-b" }) |other| {
        try expectRefused(try b.raw(a, .PUT, "projects/p/subscriptions/zigps-s", try std.fmt.allocPrint(a, "{{\"topic\":\"projects/p/topics/{s}\"}}", .{other})), 409, "ALREADY_EXISTS", "Resource already exists in the project (resource=zigps-s).");
    }
    try expectRefused(try b.raw(a, .PUT, "projects/p/subscriptions/zigps-x1", "{\"topic\":\"projects/p/topics/zigps-nope\"}"), 404, "NOT_FOUND", "Resource not found (resource=zigps-nope).");
    try expectRefused(try b.raw(a, .PUT, "projects/p/subscriptions/zigps-x2", "{}"), 400, "INVALID_ARGUMENT", "Invalid resource name given (name=). Refer to https://cloud.google.com/pubsub/docs/pubsub-basics#resource_names for more information.");
    try expectRefused(try b.raw(a, .PUT, "projects/p/subscriptions/zigps-x3", "{\"topic\":\"orders\"}"), 400, "INVALID_ARGUMENT", "Invalid resource name given (name=orders). Refer to https://cloud.google.com/pubsub/docs/pubsub-basics#resource_names for more information.");
    for ([_]tp.Method{ .GET, .DELETE }) |method| {
        try expectRefused(try b.raw(a, method, "projects/p/subscriptions/zigps-nope", ""), 404, "NOT_FOUND", "Resource not found (resource=zigps-nope).");
    }
    try testing.expectEqualStrings(
        \\{"name":"projects/p/subscriptions/zigps-full","topic":"projects/p/topics/zigps-a","pushConfig":{},"ackDeadlineSeconds":60,"retainAckedMessages":true,"messageRetentionDuration":"1200s","labels":{"env":"test"},"expirationPolicy":{"ttl":"86400s"},"state":"ACTIVE"}
    , (try b.raw(a, .PUT, "projects/p/subscriptions/zigps-full", "{" ++ topic ++ ",\"ackDeadlineSeconds\":60,\"messageRetentionDuration\":\"1200s\",\"retainAckedMessages\":true,\"expirationPolicy\":{\"ttl\":\"86400s\"},\"labels\":{\"env\":\"test\"}}")).body);
    try testing.expectEqualStrings(
        \\{"name":"projects/p/subscriptions/zigps-never","topic":"projects/p/topics/zigps-a","pushConfig":{},"ackDeadlineSeconds":10,"messageRetentionDuration":"604800s","expirationPolicy":{},"state":"ACTIVE"}
    , (try b.raw(a, .PUT, "projects/p/subscriptions/zigps-never", "{" ++ topic ++ ",\"expirationPolicy\":{}}")).body);

    // Bounds, each in production's words.
    for ([_]struct { []const u8, []const u8 }{
        .{ "\"ackDeadlineSeconds\":9", "Invalid ack deadline given (ack_deadline=9). The ack deadline must be between 10 and 600 seconds." },
        .{ "\"ackDeadlineSeconds\":601", "Invalid ack deadline given (ack_deadline=601). The ack deadline must be between 10 and 600 seconds." },
        .{ "\"messageRetentionDuration\":\"540s\"", "The value for message retention duration is out of bounds. You passed 9m in the request, but the value must be between 10m and 744h." },
        .{ "\"messageRetentionDuration\":\"2764800s\"", "The value for message retention duration is out of bounds. You passed 768h in the request, but the value must be between 10m and 744h." },
        .{ "\"expirationPolicy\":{\"ttl\":\"3600s\"}", "The value for expiration duration is too small. You passed 1h in the request, but the minimum value is 24h." },
        .{ "\"messageRetentionDuration\":\"172800s\",\"expirationPolicy\":{\"ttl\":\"86400s\"}", "The subscription's message retention duration (172800 seconds) cannot be greater than the TTL in the subscription's expiration policy (86400 seconds), since messages cannot be retained past subscription expiration." },
    }) |case| {
        const setting, const words = case;
        try expectRefused(try b.raw(a, .PUT, "projects/p/subscriptions/zigps-bad", try std.fmt.allocPrint(a, "{{" ++ topic ++ ",{s}}}", .{setting})), 400, "INVALID_ARGUMENT", words);
    }
    try testing.expectEqual(404, (try b.raw(a, .GET, "projects/p/subscriptions/zigps-bad", "")).status);
    // A deadline of 0 is one not said, and exactly 10 and 600 are taken.
    for ([_]u32{ 0, 10, 600 }, 0..) |seconds, i| {
        const reply = try b.raw(a, .PUT, try std.fmt.allocPrint(a, "projects/p/subscriptions/zigps-d{d}", .{i}), try std.fmt.allocPrint(a, "{{" ++ topic ++ ",\"ackDeadlineSeconds\":{d}}}", .{seconds}));
        try testing.expectEqual(200, reply.status);
        try testing.expect(std.mem.indexOf(u8, reply.body, try std.fmt.allocPrint(a, "\"ackDeadlineSeconds\":{d},", .{if (seconds == 0) 10 else seconds})) != null);
    }

    // Updates. After any, production writes `pushConfig` another way.
    try testing.expectEqualStrings(
        \\{"name":"projects/p/subscriptions/zigps-s","topic":"projects/p/topics/zigps-a","pushConfig":{"attributes":{"x-goog-version":"v1"}},"ackDeadlineSeconds":30,"messageRetentionDuration":"604800s","expirationPolicy":{"ttl":"2678400s"},"state":"ACTIVE"}
    , (try b.raw(a, .PATCH, "projects/p/subscriptions/zigps-s", "{\"subscription\":{\"ackDeadlineSeconds\":30},\"updateMask\":\"ackDeadlineSeconds\"}")).body);
    for ([_]struct { []const u8, []const u8 }{
        .{ "{\"subscription\":{\"filter\":\"attributes.k = \\\"v\\\"\"},\"updateMask\":\"filter\"}", "Invalid update_mask provided in the UpdateSubscriptionRequest: the 'filter' field in the Subscription is not mutable." },
        .{ "{\"subscription\":{\"topic\":\"projects/p/topics/zigps-b\"},\"updateMask\":\"topic\"}", "Invalid update_mask provided in the UpdateSubscriptionRequest: the 'topic' field in the Subscription is not mutable." },
        .{ "{\"subscription\":{\"enableMessageOrdering\":true},\"updateMask\":\"enableMessageOrdering\"}", "Invalid update_mask provided in the UpdateSubscriptionRequest: the 'enable_message_ordering' field in the Subscription is not mutable." },
        .{ "{\"subscription\":{\"ackDeadlineSeconds\":30}}", "The update_mask in the UpdateSubscriptionRequest must be set, and must contain a non-empty paths list." },
        .{ "{\"subscription\":{},\"updateMask\":\"nonsense\"}", "Invalid update_mask provided in the UpdateSubscriptionRequest: 'nonsense' is not a known Subscription field. Note that field paths must be of the form 'push_config' rather than 'pushConfig'." },
    }) |case| {
        const body, const words = case;
        try expectRefused(try b.raw(a, .PATCH, "projects/p/subscriptions/zigps-s", body), 400, "INVALID_ARGUMENT", words);
    }
    try expectRefused(try b.raw(a, .PATCH, "projects/p/subscriptions/zigps-nope", "{\"subscription\":{\"ackDeadlineSeconds\":30},\"updateMask\":\"ackDeadlineSeconds\"}"), 404, "NOT_FOUND", "Resource not found (resource=zigps-nope).");
    // A path the body leaves out goes back to production's default.
    try testing.expectEqualStrings(
        \\{"name":"projects/p/subscriptions/zigps-full","topic":"projects/p/topics/zigps-a","pushConfig":{"attributes":{"x-goog-version":"v1"}},"ackDeadlineSeconds":60,"retainAckedMessages":true,"messageRetentionDuration":"1200s","labels":{"env":"test"},"expirationPolicy":{"ttl":"2678400s"},"state":"ACTIVE"}
    , (try b.raw(a, .PATCH, "projects/p/subscriptions/zigps-full", "{\"subscription\":{},\"updateMask\":\"expirationPolicy\"}")).body);
    try testing.expectEqualStrings(
        \\{"name":"projects/p/subscriptions/zigps-full","topic":"projects/p/topics/zigps-a","pushConfig":{"attributes":{"x-goog-version":"v1"}},"ackDeadlineSeconds":60,"messageRetentionDuration":"604800s","expirationPolicy":{"ttl":"2678400s"},"state":"ACTIVE"}
    , (try b.raw(a, .PATCH, "projects/p/subscriptions/zigps-full", "{\"subscription\":{},\"updateMask\":\"messageRetentionDuration,retain_acked_messages,labels\"}")).body);
    // A refused update changes nothing.
    try testing.expectEqual(400, (try b.raw(a, .PATCH, "projects/p/subscriptions/zigps-full", "{\"subscription\":{\"ackDeadlineSeconds\":30,\"messageRetentionDuration\":\"1s\"},\"updateMask\":\"ackDeadlineSeconds,messageRetentionDuration\"}")).status);
    try testing.expect(std.mem.indexOf(u8, (try b.raw(a, .GET, "projects/p/subscriptions/zigps-full", "")).body, "\"ackDeadlineSeconds\":60,") != null);

    // Through the client.
    var made = try b.client.subscription("worker").create(.{
        .topic_id = "zigps-b",
        .ack_deadline_seconds = 45,
        .message_retention = .fromSeconds(3600),
        .retain_acked_messages = true,
        .expiration = .never,
        .labels = &.{.{ .key = "env", .value = "test" }},
    });
    defer made.deinit();
    try testing.expectEqual(45, made.value.ack_deadline_seconds);
    try testing.expectEqual(types.Expiration.never, made.value.expiration);
    try testing.expect(made.value.retain_acked_messages);
    try testing.expectEqualStrings("test", made.value.label("env").?);
    var changed = try b.client.subscription("worker").update(.{ .ack_deadline_seconds = 20, .expiration = .{ .after = .fromSeconds(172_800) }, .labels = &.{} });
    defer changed.deinit();
    try testing.expectEqual(20, changed.value.ack_deadline_seconds);
    try testing.expectEqual(std.Io.Duration.fromSeconds(172_800), changed.value.expiration.after);
    try testing.expectEqual(0, changed.value.labels.len);
    try testing.expectEqual(types.DeliveryInfo.pull, changed.value.delivery);
    // What is not modelled yet says so.
    try testing.expectError(error.Unimplemented, b.client.subscription("ordered").create(.{ .topic_id = "zigps-b", .enable_message_ordering = true }));
    try testing.expectEqualStrings("fake: enableMessageOrdering is not modelled yet", b.diag.message());
    try testing.expectError(error.Unimplemented, b.client.subscription("filtered").create(.{ .topic_id = "zigps-b", .filter = "attributes:k" }));

    // A topic deleted under its subscription leaves it, and what it holds.
    var sent = try b.client.topic("zigps-b").publish(&.{.{ .data = "kept" }}, .{});
    sent.deinit();
    try b.client.topic("zigps-b").delete();
    var orphan = try b.client.subscription("worker").get();
    defer orphan.deinit();
    try testing.expectEqualStrings("_deleted-topic_", orphan.value.topic);
    var got = try b.client.subscription("worker").pull(.{});
    defer got.deinit();
    try testing.expectEqualStrings("kept", got.value.messages[0].data);
    // A topic made again under the name is another topic: nothing reaches
    // the old subscription.
    var again = try b.client.topic("zigps-b").create(.{});
    again.deinit();
    var later = try b.client.topic("zigps-b").publish(&.{.{ .data = "new" }}, .{});
    later.deinit();
    try testing.expectEqual(1, b.fake.backlog("p", "worker"));
    try b.client.subscription("worker").delete();
    try testing.expectError(error.NotFound, b.client.subscription("worker").pull(.{}));
    try testing.expectEqual(0, b.fake.backlog("p", "worker"));
}

test "leases: a message out on one comes again when it lapses, and an ack takes only while it is out" {
    var b: Bench = undefined;
    try b.init(.{});
    defer b.deinit();
    var made = try b.client.topic("orders").create(.{});
    made.deinit();
    var early = try b.client.topic("orders").publish(&.{.{ .data = "early" }}, .{});
    early.deinit();
    const worker = b.client.subscription("worker");
    var subscribed = try worker.create(.{ .topic_id = "orders" });
    subscribed.deinit();
    // A subscription gets what is published after it is made.
    try testing.expectEqual(0, b.fake.backlog("p", "worker"));
    var sent = try b.client.topic("orders").publish(&.{.{ .data = "m" }}, .{});
    sent.deinit();

    var first = try worker.pull(.{});
    defer first.deinit();
    const old = first.value.messages[0].ack_id;
    // Out on a lease: a second pull has nothing.
    var none = try worker.pull(.{});
    defer none.deinit();
    try testing.expectEqual(0, none.value.messages.len);
    b.advance(9);
    var still_none = try worker.pull(.{});
    defer still_none.deinit();
    try testing.expectEqual(0, still_none.value.messages.len);
    try testing.expectEqual(1, b.fake.outstanding("p", "worker"));

    // The lease lapses at 10 seconds. An ack with the old id is then
    // answered and forgotten, as production's was: the message comes again.
    b.advance(1);
    try testing.expectEqual(0, b.fake.outstanding("p", "worker"));
    try worker.ack(&.{old});
    try testing.expectEqual(1, b.fake.backlog("p", "worker"));
    var second = try worker.pull(.{});
    defer second.deinit();
    try testing.expectEqualStrings("m", second.value.messages[0].data);
    try testing.expect(!std.mem.eql(u8, old, second.value.messages[0].ack_id));
    // Out again, the old id does acknowledge it: the id names the message,
    // and the lease decides.
    try worker.ack(&.{old});
    try testing.expectEqual(0, b.fake.backlog("p", "worker"));
    // A second ack of it, and a lease change on it, are taken and forgotten.
    try worker.ack(&.{ old, second.value.messages[0].ack_id });
    try worker.modifyAckDeadline(&.{old}, 30);

    // An extension moves the deadline from now.
    var more = try b.client.topic("orders").publish(&.{.{ .data = "n" }}, .{});
    more.deinit();
    var third = try worker.pull(.{});
    defer third.deinit();
    b.advance(8);
    try worker.modifyAckDeadline(&.{third.value.messages[0].ack_id}, 30);
    b.advance(29);
    try testing.expectEqual(1, b.fake.outstanding("p", "worker"));
    b.advance(1);
    try testing.expectEqual(0, b.fake.outstanding("p", "worker"));

    // A nack gives it back at once, and an ack after the nack is forgotten.
    var fourth = try worker.pull(.{});
    defer fourth.deinit();
    try worker.nack(&.{fourth.value.messages[0].ack_id});
    try worker.ack(&.{fourth.value.messages[0].ack_id});
    var fifth = try worker.pull(.{});
    defer fifth.deinit();
    try testing.expectEqualStrings("n", fifth.value.messages[0].data);
    try worker.ack(&.{fifth.value.messages[0].ack_id});
    try testing.expectEqual(0, b.fake.backlog("p", "worker"));
}

test "ack ids and pulls: what production refuses, in its words" {
    var b: Bench = undefined;
    try b.init(.{});
    defer b.deinit();
    var scratch: std.heap.ArenaAllocator = .init(testing.allocator);
    defer scratch.deinit();
    const a = scratch.allocator();
    var made = try b.client.topic("orders").create(.{});
    made.deinit();
    for ([_][]const u8{ "sub-a", "sub-b" }) |id| {
        var s = try b.client.subscription(id).create(.{ .topic_id = "orders" });
        s.deinit();
    }
    var sent = try b.client.topic("orders").publish(&.{.{ .data = "x", .attributes = &.{.{ .key = "k", .value = "v" }} }}, .{ .ordering_key = "o" });
    sent.deinit();
    const ack_a = "projects/p/subscriptions/sub-a:acknowledge";
    const mod_a = "projects/p/subscriptions/sub-a:modifyAckDeadline";

    // A pulled message, as production writes one.
    const pulled = (try b.raw(a, .POST, "projects/p/subscriptions/sub-b:pull", "{\"maxMessages\":5,\"returnImmediately\":true}")).body;
    const Wire = struct { receivedMessages: []const struct { ackId: []const u8, message: struct { data: []const u8, attributes: struct { k: []const u8 }, messageId: []const u8, publishTime: []const u8, orderingKey: []const u8 } } };
    const message = try std.json.parseFromSliceLeaky(Wire, a, pulled, .{});
    try testing.expectEqualStrings("eA==", message.receivedMessages[0].message.data);
    try testing.expectEqualStrings("v", message.receivedMessages[0].message.attributes.k);
    try testing.expectEqualStrings("1", message.receivedMessages[0].message.messageId);
    try testing.expectEqualStrings("1970-01-01T00:00:00Z", message.receivedMessages[0].message.publishTime);
    try testing.expectEqualStrings("o", message.receivedMessages[0].message.orderingKey);
    const from_b = message.receivedMessages[0].ackId;
    // Nothing to give answers `{}`.
    try testing.expectEqualStrings("{}", (try b.raw(a, .POST, "projects/p/subscriptions/sub-b:pull", "{\"maxMessages\":5}")).body);

    try expectRefused(try b.raw(a, .POST, ack_a, "{\"ackIds\":[\"not-an-ack-id\"]}"), 400, "INVALID_ARGUMENT", "You have passed an invalid ack ID to the service (ack_id=not-an-ack-id).");
    try expectRefused(try b.raw(a, .POST, mod_a, "{\"ackIds\":[\"not-an-ack-id\"],\"ackDeadlineSeconds\":30}"), 400, "INVALID_ARGUMENT", "You have passed an invalid ack ID to the service (ack_id=not-an-ack-id).");
    try expectRefused(try b.raw(a, .POST, mod_a, "{\"ackIds\":[\"x\"]}"), 400, "INVALID_ARGUMENT", "You have passed an invalid ack ID to the service (ack_id=x).");
    for ([_][]const u8{ "{\"ackIds\":[]}", "{}" }) |body| {
        try expectRefused(try b.raw(a, .POST, ack_a, body), 400, "INVALID_ARGUMENT", "You have not specified an ack ID in the request.");
    }
    // An id another subscription gave is refused, and that message stays
    // with the other subscription.
    try expectRefused(try b.raw(a, .POST, ack_a, try std.fmt.allocPrint(a, "{{\"ackIds\":[\"{s}\"]}}", .{from_b})), 400, "INVALID_ARGUMENT", "You have passed a subscription that does not belong to the given ack ID (resource=projects/p/subscriptions/sub-a).");
    try testing.expectEqual(1, b.fake.backlog("p", "sub-b"));
    for ([_]i32{ 601, -1 }) |seconds| {
        try expectRefused(try b.raw(a, .POST, "projects/p/subscriptions/sub-b:modifyAckDeadline", try std.fmt.allocPrint(a, "{{\"ackIds\":[\"{s}\"],\"ackDeadlineSeconds\":{d}}}", .{ from_b, seconds })), 400, "INVALID_ARGUMENT", try std.fmt.allocPrint(a, "Invalid ack deadline given (ack_deadline={d}). The ack deadline must be between 0 and 600 seconds.", .{seconds}));
    }
    try testing.expectEqualStrings("{}", (try b.raw(a, .POST, "projects/p/subscriptions/sub-b:modifyAckDeadline", try std.fmt.allocPrint(a, "{{\"ackIds\":[\"{s}\"],\"ackDeadlineSeconds\":600}}", .{from_b}))).body);
    // One bad id refuses the request whole: the good one is not taken.
    try testing.expectEqual(400, (try b.raw(a, .POST, "projects/p/subscriptions/sub-b:acknowledge", try std.fmt.allocPrint(a, "{{\"ackIds\":[\"{s}\",\"nope\"]}}", .{from_b}))).status);
    try testing.expectEqual(1, b.fake.backlog("p", "sub-b"));
    try testing.expectEqualStrings("{}", (try b.raw(a, .POST, "projects/p/subscriptions/sub-b:acknowledge", try std.fmt.allocPrint(a, "{{\"ackIds\":[\"{s}\"]}}", .{from_b}))).body);
    try testing.expectEqual(0, b.fake.backlog("p", "sub-b"));

    for ([_][]const u8{ "{\"maxMessages\":0,\"returnImmediately\":true}", "{\"returnImmediately\":true}", "{\"maxMessages\":-1}" }) |body| {
        try expectRefused(try b.raw(a, .POST, "projects/p/subscriptions/sub-a:pull", body), 400, "INVALID_ARGUMENT", "You have passed an invalid argument to the service (argument=max_messages).");
    }
    // 1001 is taken, as production takes it, and gives a thousand at most.
    var bulk: std.Io.Writer.Allocating = .init(a);
    try bulk.writer.writeAll("{\"messages\":[");
    for (0..1000) |i| try bulk.writer.print("{s}{{\"data\":\"YQ==\"}}", .{if (i == 0) "" else ","});
    try bulk.writer.writeAll("]}");
    for (0..2) |_| try testing.expectEqual(200, (try b.raw(a, .POST, "projects/p/topics/orders:publish", bulk.written())).status);
    const thousand = try b.raw(a, .POST, "projects/p/subscriptions/sub-a:pull", "{\"maxMessages\":1001}");
    try testing.expectEqual(200, thousand.status);
    try testing.expectEqual(1000, std.mem.count(u8, thousand.body, "\"ackId\""));
    try testing.expectEqual(1000, b.fake.outstanding("p", "sub-a"));
    try testing.expectEqual(2001, b.fake.backlog("p", "sub-a"));
    for ([_][]const u8{ ":pull", ":acknowledge", ":modifyAckDeadline" }) |call| {
        try expectRefused(try b.raw(a, .POST, try std.fmt.allocPrint(a, "projects/p/subscriptions/nope{s}", .{call}), "{\"maxMessages\":1,\"ackIds\":[\"x\"]}"), 404, "NOT_FOUND", "Resource not found (resource=nope).");
    }
    // An id from a subscription deleted and made again under the name is
    // not that subscription's.
    var more = try b.client.topic("orders").publish(&.{.{ .data = "y" }}, .{});
    more.deinit();
    var got = try b.client.subscription("sub-b").pull(.{});
    defer got.deinit();
    try b.client.subscription("sub-b").delete();
    var remade = try b.client.subscription("sub-b").create(.{ .topic_id = "orders" });
    remade.deinit();
    try testing.expectError(error.InvalidArgument, b.client.subscription("sub-b").ack(&.{got.value.messages[0].ack_id}));
    // Routes this fake has not got.
    try testing.expectEqual(501, (try b.raw(a, .POST, "projects/p/subscriptions/sub-a:seek", "{}")).status);
    try testing.expectEqual(404, (try b.raw(a, .GET, "projects/p/snapshots", "")).status);
}

test "order: none without an ordering key, so a pull's is the fake's own unless asked for the published one" {
    for ([_]bool{ true, false }) |shuffle| {
        var b: Bench = undefined;
        try b.init(.{ .shuffle = shuffle });
        defer b.deinit();
        var made = try b.client.topic("orders").create(.{});
        made.deinit();
        var subscribed = try b.client.subscription("worker").create(.{ .topic_id = "orders" });
        subscribed.deinit();
        for (0..12) |i| {
            var buf: [2]u8 = undefined;
            var sent = try b.client.topic("orders").publish(&.{.{ .data = try std.fmt.bufPrint(&buf, "{d:0>2}", .{i}) }}, .{});
            sent.deinit();
        }
        var seen: [12]bool = @splat(false);
        var in_order = true;
        var last: i32 = -1;
        var pulls: usize = 0;
        while (b.fake.backlog("p", "worker") > 0) : (pulls += 1) {
            var got = try b.client.subscription("worker").pull(.{ .max_messages = 5 });
            defer got.deinit();
            try testing.expect(got.value.messages.len <= 5);
            for (got.value.messages) |m| {
                const n = try std.fmt.parseInt(u8, m.data, 10);
                try testing.expect(!seen[n]);
                seen[n] = true;
                if (n < last) in_order = false;
                last = n;
                try b.client.subscription("worker").ack(&.{m.ack_id});
            }
        }
        try testing.expectEqual(3, pulls);
        for (seen) |s| try testing.expect(s);
        try testing.expectEqual(!shuffle, in_order);
    }
}

test "faults: a refusal changes nothing, a lost answer lands, a drop is a broken connection, each on the calls asked for" {
    var b: Bench = undefined;
    try b.init(.{});
    defer b.deinit();
    // One attempt a call, so that each fault is seen as it is.
    b.client.retry.max_attempts = 1;
    var made = try b.client.topic("orders").create(.{});
    made.deinit();
    var subscribed = try b.client.subscription("worker").create(.{ .topic_id = "orders" });
    subscribed.deinit();

    b.fake.refuseNext(2, 503, .publish);
    try testing.expectError(error.Unavailable, b.client.topic("orders").publish(&.{.{ .data = "a" }}, .{}));
    // Another kind of call is not the fault's to answer.
    var read = try b.client.topic("orders").get();
    read.deinit();
    try testing.expectError(error.Unavailable, b.client.topic("orders").publish(&.{.{ .data = "a" }}, .{}));
    try testing.expectEqual(0, b.fake.publishedCount("p", "orders"));
    var taken = try b.client.topic("orders").publish(&.{.{ .data = "a" }}, .{});
    taken.deinit();
    try testing.expectEqual(1, b.fake.publishedCount("p", "orders"));

    // A lost answer: the publish landed, and the caller was told 503.
    b.fake.loseAnswers(1, .publish);
    try testing.expectError(error.Unavailable, b.client.topic("orders").publish(&.{.{ .data = "b" }}, .{}));
    try testing.expectEqual(2, b.fake.publishedCount("p", "orders"));
    try testing.expectEqual(2, b.fake.backlog("p", "worker"));

    b.fake.dropNext(1, .pull);
    try testing.expectError(error.ConnectionResetByPeer, b.client.subscription("worker").pull(.{}));
    try testing.expectEqual(0, b.fake.outstanding("p", "worker"));
    var got = try b.client.subscription("worker").pull(.{});
    defer got.deinit();
    try testing.expectEqual(2, got.value.messages.len);

    // A lost ack still acknowledged; a refused one did not.
    b.fake.loseAnswers(1, .acknowledge);
    try testing.expectError(error.Unavailable, b.client.subscription("worker").ack(&.{got.value.messages[0].ack_id}));
    try testing.expectEqual(1, b.fake.backlog("p", "worker"));
    b.fake.refuseNext(1, 429, .acknowledge);
    try testing.expectError(error.ResourceExhausted, b.client.subscription("worker").ack(&.{got.value.messages[1].ack_id}));
    try testing.expectEqual(1, b.fake.backlog("p", "worker"));
    b.fake.refuseNext(1, 500, .modify_ack_deadline);
    try testing.expectError(error.Internal, b.client.subscription("worker").nack(&.{got.value.messages[1].ack_id}));
    b.fake.refuseNext(1, 503, .all);
    try testing.expectError(error.Unavailable, b.client.subscription("worker").get());
    b.fake.refuseNext(1, 403, .admin);
    try testing.expectError(error.PermissionDenied, b.client.subscription("worker").delete());
    var still = try b.client.subscription("worker").get();
    still.deinit();

    // With the client's retries on, a fault or two is ridden out.
    b.client.retry.max_attempts = 3;
    b.fake.refuseNext(2, 503, .acknowledge);
    try b.client.subscription("worker").ack(&.{got.value.messages[1].ack_id});
    try testing.expectEqual(0, b.fake.backlog("p", "worker"));

    try testing.expectEqual(4, b.fake.requestCount(.publish));
    try testing.expectEqual(2, b.fake.requestCount(.pull));
    try testing.expectEqual(5, b.fake.requestCount(.acknowledge));
    try testing.expectEqual(1, b.fake.requestCount(.modify_ack_deadline));
    try testing.expectEqual(6, b.fake.requestCount(.admin));
    try testing.expectEqual(18, b.fake.requestCount(.all));
}

test "a pull with nothing to give is held as long as asked, on the fake's clock" {
    var b: Bench = undefined;
    try b.init(.{ .empty_pull_hold = .fromSeconds(20) });
    defer b.deinit();
    var made = try b.client.topic("orders").create(.{});
    made.deinit();
    var subscribed = try b.client.subscription("worker").create(.{ .topic_id = "orders" });
    subscribed.deinit();
    const before = b.clock.now_ns;
    var none = try b.client.subscription("worker").pull(.{});
    defer none.deinit();
    try testing.expectEqual(0, none.value.messages.len);
    try testing.expectEqual(20 * std.time.ns_per_s, b.clock.now_ns - before);
    // With a message waiting it answers at once.
    var sent = try b.client.topic("orders").publish(&.{.{ .data = "m" }}, .{});
    sent.deinit();
    const then = b.clock.now_ns;
    var got = try b.client.subscription("worker").pull(.{});
    defer got.deinit();
    try testing.expectEqual(1, got.value.messages.len);
    try testing.expectEqual(then, b.clock.now_ns);
    // A held pull gives a lapsed message when its lease runs out.
    var again = try b.client.subscription("worker").pull(.{});
    defer again.deinit();
    try testing.expectEqual(1, again.value.messages.len);
    try testing.expectEqual(10 * std.time.ns_per_s, b.clock.now_ns - then);
    // A canceled wait is a canceled call.
    b.clock.cancel_sleep = true;
    try testing.expectError(error.Canceled, b.client.subscription("worker").pull(.{}));
}

/// What each subscription should hold, said again in as few lines as it
/// takes: the fake is held to this after every step of a script.
const Reference = struct {
    const Held = struct { id: u64, lease_until: ?i96 = null };
    const max_held = 256;

    held: [3][max_held]Held = undefined,
    counts: [3]usize = @splat(0),
    /// Which topic a subscription listens to; null once that topic is gone.
    topic: [3]?u8 = .{ 0, 0, 1 },
    deadline_s: [3]u32 = .{ 10, 20, 10 },

    fn publish(r: *Reference, topic: u8, id: u64) void {
        for (0..3) |s| {
            if (r.topic[s] != topic) continue;
            r.held[s][r.counts[s]] = .{ .id = id };
            r.counts[s] += 1;
        }
    }

    fn find(r: *Reference, s: usize, id: u64) ?*Held {
        for (r.held[s][0..r.counts[s]]) |*h| if (h.id == id) return h;
        return null;
    }

    fn out(h: Held, now: i96) bool {
        return if (h.lease_until) |until| until > now else false;
    }

    fn ready(r: *const Reference, s: usize, now: i96) usize {
        var n: usize = 0;
        for (r.held[s][0..r.counts[s]]) |h| n += @intFromBool(!out(h, now));
        return n;
    }

    fn outstanding(r: *const Reference, s: usize, now: i96) usize {
        return r.counts[s] - r.ready(s, now);
    }

    fn ack(r: *Reference, s: usize, id: u64, now: i96) void {
        const h = r.find(s, id) orelse return;
        if (!out(h.*, now)) return;
        h.* = r.held[s][r.counts[s] - 1];
        r.counts[s] -= 1;
    }

    fn modify(r: *Reference, s: usize, id: u64, seconds: u32, now: i96) void {
        const h = r.find(s, id) orelse return;
        if (!out(h.*, now)) return;
        h.lease_until = if (seconds == 0) null else now + @as(i96, seconds) * std.time.ns_per_s;
    }
};

const sub_ids = [3][]const u8{ "sub0", "sub1", "sub2" };
const topic_ids = [2][]const u8{ "top0", "top1" };

fn modelProperty(_: void, input: []const u8) !void {
    var g: test_util.ByteGen = .init(input);
    var b: Bench = undefined;
    try b.init(.{ .shuffle = g.boolean() });
    defer b.deinit();
    var scratch: std.heap.ArenaAllocator = .init(testing.allocator);
    defer scratch.deinit();
    const a = scratch.allocator();

    var ref: Reference = .{};
    for (topic_ids) |id| {
        var made = try b.client.topic(id).create(.{});
        made.deinit();
    }
    for (sub_ids, 0..) |id, s| {
        var made = try b.client.subscription(id).create(.{ .topic_id = topic_ids[ref.topic[s].?], .ack_deadline_seconds = ref.deadline_s[s] });
        made.deinit();
    }
    // Every delivery's ack id, with the subscription's incarnation then.
    const Delivery = struct { sub: usize, incarnation: u32, id: u64, ack_id: []const u8 };
    var deliveries: std.ArrayList(Delivery) = .empty;
    var incarnation: [3]u32 = @splat(0);
    var published: usize = 0;

    var steps: usize = 0;
    while (steps < 60 and g.pos < g.bytes.len) : (steps += 1) {
        const now = b.clock.now_ns;
        switch (g.intRange(u8, 0, 9)) {
            0, 1 => {
                const topic = g.intRange(u8, 0, 1);
                const count = g.intRange(u8, 1, 3);
                if (published + count > Reference.max_held / 2) continue;
                var messages: [3]types.Message = undefined;
                var bufs: [3][8]u8 = undefined;
                for (messages[0..count], bufs[0..count]) |*m, *buf| {
                    m.* = .{ .data = try std.fmt.bufPrint(buf, "m{d}", .{published}) };
                    published += 1;
                }
                var sent = try b.client.topic(topic_ids[topic]).publish(messages[0..count], .{});
                defer sent.deinit();
                for (sent.value.message_ids) |text| ref.publish(topic, try std.fmt.parseInt(u64, text, 10));
            },
            2, 3, 4 => {
                const s = g.intRange(u8, 0, 2);
                const max = g.intRange(u8, 1, 4);
                var got = try b.client.subscription(sub_ids[s]).pull(.{ .max_messages = max });
                defer got.deinit();
                // As many as it has ready, up to what was asked: no fewer.
                try testing.expectEqual(@min(max, ref.ready(s, now)), got.value.messages.len);
                for (got.value.messages) |m| {
                    const id = try std.fmt.parseInt(u64, m.message_id, 10);
                    // Never one it does not hold, and never one that is
                    // out on a live lease.
                    const held = ref.find(s, id) orelse return error.TestUnexpectedMessage;
                    try testing.expect(!Reference.out(held.*, now));
                    held.lease_until = now + @as(i96, ref.deadline_s[s]) * std.time.ns_per_s;
                    try deliveries.append(a, .{ .sub = s, .incarnation = incarnation[s], .id = id, .ack_id = try a.dupe(u8, m.ack_id) });
                }
            },
            5, 6, 7 => |op| {
                if (deliveries.items.len == 0) continue;
                const d = deliveries.items[g.intRange(u16, 0, @intCast(deliveries.items.len - 1))];
                const sub = b.client.subscription(sub_ids[d.sub]);
                const seconds: u32 = switch (op) {
                    6 => 0,
                    else => g.pick(u32, &.{ 5, 30, 600 }),
                };
                const result = if (op == 5) sub.ack(&.{d.ack_id}) else sub.modifyAckDeadline(&.{d.ack_id}, seconds);
                // An id from before the subscription was made again is
                // not this subscription's.
                if (d.incarnation != incarnation[d.sub]) {
                    try testing.expectError(error.InvalidArgument, result);
                    continue;
                }
                try result;
                if (op == 5) ref.ack(d.sub, d.id, now) else ref.modify(d.sub, d.id, seconds, now);
            },
            8 => b.advance(g.intRange(u8, 1, 15)),
            else => switch (g.intRange(u8, 0, 3)) {
                // A subscription deleted and made again: it holds nothing.
                0, 1 => {
                    const s = g.intRange(u8, 0, 2);
                    const topic = g.intRange(u8, 0, 1);
                    try b.client.subscription(sub_ids[s]).delete();
                    var made = try b.client.subscription(sub_ids[s]).create(.{ .topic_id = topic_ids[topic], .ack_deadline_seconds = ref.deadline_s[s] });
                    made.deinit();
                    ref.counts[s] = 0;
                    ref.topic[s] = topic;
                    incarnation[s] += 1;
                },
                // A topic deleted and made again: its subscriptions keep
                // what they hold, and get nothing more.
                else => {
                    const topic = g.intRange(u8, 0, 1);
                    try b.client.topic(topic_ids[topic]).delete();
                    var made = try b.client.topic(topic_ids[topic]).create(.{});
                    made.deinit();
                    for (&ref.topic) |*t| {
                        if (t.* == topic) t.* = null;
                    }
                },
            },
        }
        for (sub_ids, 0..) |id, s| {
            try testing.expectEqual(ref.counts[s], b.fake.backlog("p", id));
            try testing.expectEqual(ref.outstanding(s, b.clock.now_ns), b.fake.outstanding("p", id));
        }
    }

    // In the end: every lease lapses, and each subscription gives exactly
    // what it should hold, once, and then nothing.
    b.advance(601);
    for (sub_ids, 0..) |id, s| {
        var left = ref.counts[s];
        while (left > 0) {
            var got = try b.client.subscription(id).pull(.{ .max_messages = 1000 });
            defer got.deinit();
            try testing.expectEqual(left, got.value.messages.len);
            for (got.value.messages) |m| {
                const held = ref.find(s, try std.fmt.parseInt(u64, m.message_id, 10)) orelse return error.TestUnexpectedMessage;
                // Once each: one already seen here is marked.
                const seen_now = std.math.maxInt(i96);
                try testing.expect(held.lease_until != seen_now);
                held.lease_until = seen_now;
                try b.client.subscription(id).ack(&.{m.ack_id});
                left -= 1;
            }
        }
        try testing.expectEqual(0, b.fake.backlog("p", id));
    }
}

// These two are named apart from the `fuzz` properties on purpose. A run
// of the model property is a whole session of calls, about 25 ms under
// the fuzzer (measured 2026-10-12), so at the pubsub fuzz job's count it
// alone would outlast the job: they have a nightly job of their own.

test "fake property: after any script of calls each subscription holds exactly what a reference says" {
    try test_util.fuzzBytes({}, modelProperty, .{
        .corpus = &.{
            "",
            // Publish, pull, let the lease lapse, ack late, pull again, ack.
            "\x00\x00\x00\x00\x02\x00\x03\x08\x0b\x05\x00\x00\x02\x00\x03\x05\x00\x00",
            // Publish to both, pull from all three, nack one, extend one.
            "\x01\x00\x00\x02\x00\x01\x02\x02\x00\x03\x03\x01\x03\x04\x02\x03\x06\x00\x00\x07\x00\x01\x01\x08\x1e\x02\x00\x03",
            // A subscription made again, then an old id.
            "\x01\x00\x00\x00\x02\x00\x02\x09\x00\x00\x00\x05\x00\x00\x00\x00\x00\x02\x00\x02",
            // A topic deleted and made again under a subscription.
            "\x01\x00\x00\x01\x09\x02\x00\x00\x00\x00\x02\x02\x00\x03\x02\x01\x03",
        },
        .random_runs = 400,
        .max_len = 160,
    });
}

/// Any bytes on any route: an answer, never a crash and never a leak.
fn arbitraryRequest(_: void, input: []const u8) !void {
    var g: test_util.ByteGen = .init(input);
    var b: Bench = undefined;
    try b.init(.{});
    defer b.deinit();
    var scratch: std.heap.ArenaAllocator = .init(testing.allocator);
    defer scratch.deinit();
    const a = scratch.allocator();
    try testing.expectEqual(200, (try b.raw(a, .PUT, "projects/p/topics/orders", "{}")).status);
    try testing.expectEqual(200, (try b.raw(a, .PUT, "projects/p/subscriptions/worker", "{\"topic\":\"projects/p/topics/orders\"}")).status);
    try testing.expectEqual(200, (try b.raw(a, .POST, "projects/p/topics/orders:publish", "{\"messages\":[{\"data\":\"eA==\"}]}")).status);
    const paths = [_][]const u8{
        "projects/p/topics",                                 "projects/p/topics/orders",
        "projects/p/topics/orders:publish",                  "projects/p/topics/orders/subscriptions",
        "projects/p/subscriptions",                          "projects/p/subscriptions/worker",
        "projects/p/subscriptions/worker:pull",              "projects/p/subscriptions/worker:acknowledge",
        "projects/p/subscriptions/worker:modifyAckDeadline", "projects/p/topics/new",
        "projects/p/subscriptions/new",                      "projects/p/topics?pageSize=1&pageToken=",
    };
    const bodies = [_][]const u8{
        "{\"messages\":[{\"data\":\"", "{\"topic\":\"projects/p/topics/orders\",",
        "{\"subscription\":{",         "{\"topic\":{",
        "{\"ackIds\":[\"",             "{\"maxMessages\":",
        "{\"updateMask\":\"",          "",
    };
    for (0..8) |_| {
        const method = g.pick(tp.Method, &.{ .GET, .PUT, .POST, .PATCH, .DELETE });
        const tail = g.slice(40);
        const path = try std.fmt.allocPrint(a, "{s}{s}", .{ g.pick([]const u8, &paths), if (g.boolean()) tail else "" });
        // A body that starts as a real one would and ends anywhere.
        const body = try std.fmt.allocPrint(a, "{s}{s}", .{ g.pick([]const u8, &bodies), g.slice(120) });
        const reply = try b.fake.serve(method, try std.fmt.allocPrint(a, "https://pubsub.googleapis.com/v1/{s}", .{path}), body, a);
        try testing.expect(reply.status == 200 or reply.status == 400 or reply.status == 404 or reply.status == 409 or reply.status == 501);
        // Every answer is JSON, a refusal with its code inside.
        const parsed = try std.json.parseFromSliceLeaky(std.json.Value, a, reply.body, .{});
        if (reply.status != 200) try testing.expectEqual(@as(i64, reply.status), parsed.object.get("error").?.object.get("code").?.integer);
    }
}

test "fake property: arbitrary requests on every route are answered, never crashed on" {
    try test_util.fuzzBytes({}, arbitraryRequest, .{ .corpus = &.{
        "",
        "\x00\x00\x00\x00\x00\x00\x00\x02\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x04\x7d\x7d\x7d\x7d",
        "\x02\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x06\x01\x00\x00\x00\x00\x00\x00\x00\x05\x00\x00\x00\x00\x00\x00\x00\x03\x31\x7d",
    }, .random_runs = 300 });
}

/// A session of every kind of call, with the fake's own memory failing
/// anywhere: the call fails or is answered, and nothing leaks.
fn sessionAllocations(gpa: Allocator) !void {
    var clock: test_util.FakeClock = .{};
    var fake: FakePubSub = .init(gpa, clock.io(), .{});
    defer fake.deinit();
    var scratch: std.heap.ArenaAllocator = .init(gpa);
    defer scratch.deinit();
    const a = scratch.allocator();
    const base = "https://pubsub.googleapis.com/v1/projects/p/";
    const steps = [_]struct { tp.Method, []const u8, []const u8 }{
        .{ .PUT, "topics/orders", "{\"labels\":{\"env\":\"test\"},\"messageRetentionDuration\":\"600s\",\"kmsKeyName\":\"k\",\"messageStoragePolicy\":{\"allowedPersistenceRegions\":[\"europe-west1\"]}}" },
        .{ .PUT, "topics/other", "{}" },
        .{ .PUT, "subscriptions/worker", "{\"topic\":\"projects/p/topics/orders\",\"labels\":{\"a\":\"b\"},\"expirationPolicy\":{}}" },
        .{ .PUT, "subscriptions/second", "{\"topic\":\"projects/p/topics/orders\"}" },
        .{ .PATCH, "topics/orders", "{\"topic\":{\"labels\":{\"env\":\"prod\"},\"kmsKeyName\":\"k2\"},\"updateMask\":\"labels,kmsKeyName,messageStoragePolicy\"}" },
        .{ .PATCH, "subscriptions/worker", "{\"subscription\":{\"labels\":{\"c\":\"d\"},\"ackDeadlineSeconds\":30},\"updateMask\":\"labels,ackDeadlineSeconds\"}" },
        .{ .POST, "topics/orders:publish", "{\"messages\":[{\"data\":\"aGVsbG8=\",\"attributes\":{\"k\":\"v\"},\"orderingKey\":\"o\"},{\"data\":\"eA==\",\"orderingKey\":\"o\"}]}" },
        .{ .GET, "topics?pageSize=1", "" },
        .{ .GET, "subscriptions", "" },
        .{ .GET, "topics/orders/subscriptions?pageSize=1", "" },
        .{ .POST, "subscriptions/worker:pull", "{\"maxMessages\":5}" },
        .{ .DELETE, "topics/other", "" },
        .{ .DELETE, "subscriptions/second", "" },
        .{ .GET, "topics/nope", "" },
        .{ .PUT, "topics/bad", "{\"labels\":{\"Env\":\"x\"}}" },
    };
    for (steps) |step| {
        const method, const path, const body = step;
        const reply = try fake.serve(method, try std.fmt.allocPrint(a, "{s}{s}", .{ base, path }), body, a);
        try testing.expect(reply.status < 500);
        if (std.mem.endsWith(u8, path, ":pull")) {
            const Wire = struct { receivedMessages: []const struct { ackId: []const u8 } = &.{} };
            const got = try std.json.parseFromSliceLeaky(Wire, a, reply.body, .{ .ignore_unknown_fields = true });
            try testing.expectEqual(2, got.receivedMessages.len);
            const ids = try std.fmt.allocPrint(a, "{{\"ackIds\":[\"{s}\",\"{s}\"],\"ackDeadlineSeconds\":20}}", .{ got.receivedMessages[0].ackId, got.receivedMessages[1].ackId });
            try testing.expectEqual(200, (try fake.serve(.POST, base ++ "subscriptions/worker:modifyAckDeadline", ids, a)).status);
            try testing.expectEqual(200, (try fake.serve(.POST, base ++ "subscriptions/worker:acknowledge", ids, a)).status);
        }
    }
    try testing.expectEqual(0, fake.backlog("p", "worker"));
}

test "allocation failures: a session of every call leaks nothing and breaks nothing" {
    try testing.checkAllAllocationFailures(test_util.no_grow_allocator, sessionAllocations, .{});
}

test "many tasks at once: every message published is pulled and acknowledged exactly once" {
    const io = testing.io;
    var fake: FakePubSub = .init(testing.allocator, io, .{});
    defer fake.deinit();
    var tokens: test_util.FakeTokenProvider = .{};
    var client = try Client.init(testing.allocator, io, .{ .project_id = "p", .token_provider = tokens.provider(), .transport = fake.transport() });
    defer client.deinit();
    var made = try client.topic("orders").create(.{});
    made.deinit();
    var subscribed = try client.subscription("worker").create(.{ .topic_id = "orders", .ack_deadline_seconds = 600 });
    subscribed.deinit();

    const publishers = 4;
    const each = 60;
    const Tasks = struct {
        fn publish(c: *Client, task: usize) !void {
            for (0..each) |i| {
                var buf: [16]u8 = undefined;
                var sent = try c.topic("orders").publish(&.{.{ .data = try std.fmt.bufPrint(&buf, "{d}-{d}", .{ task, i }) }}, .{});
                sent.deinit();
            }
        }

        fn consume(c: *Client, f: *FakePubSub, seen: *std.atomic.Value(usize)) !void {
            while (seen.load(.monotonic) < publishers * each) {
                var got = try c.subscription("worker").pull(.{ .max_messages = 7, .return_immediately = true });
                defer got.deinit();
                for (got.value.messages) |m| {
                    try c.subscription("worker").ack(&.{m.ack_id});
                    _ = seen.fetchAdd(1, .monotonic);
                }
                if (got.value.messages.len == 0 and f.publishedCount("p", "orders") == publishers * each and f.backlog("p", "worker") == 0) return;
            }
        }
    };
    var seen: std.atomic.Value(usize) = .init(0);
    var sending: [publishers]std.Io.Future(@typeInfo(@TypeOf(Tasks.publish)).@"fn".return_type.?) = undefined;
    for (&sending, 0..) |*task, t| task.* = try io.concurrent(Tasks.publish, .{ &client, t });
    var pulling: [3]std.Io.Future(@typeInfo(@TypeOf(Tasks.consume)).@"fn".return_type.?) = undefined;
    for (&pulling) |*task| task.* = try io.concurrent(Tasks.consume, .{ &client, &fake, &seen });
    for (&sending) |*task| try task.await(io);
    for (&pulling) |*task| try task.await(io);
    // 600 second leases: none lapsed, so none was delivered twice.
    try testing.expectEqual(publishers * each, seen.load(.monotonic));
    try testing.expectEqual(publishers * each, fake.publishedCount("p", "orders"));
    try testing.expectEqual(0, fake.backlog("p", "worker"));
}
