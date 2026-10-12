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
//! - Order: none without an ordering key. Production returned twelve
//!   messages published one by one as 03, 11, 00, 06 and so on, so a pull
//!   here returns what it has in an order of the fake's choosing, unless
//!   `Options.shuffle` is off.
//! - A subscription's rules, each as production showed it:
//!   - A filter (`fake_filter.zig`). What does not pass is never held: it
//!     is no backlog, and never comes.
//!   - Ordering keys. With `enableMessageOrdering` a key's messages come
//!     in the order published. What a key has waiting comes together, in
//!     one pull, and then **the key gives nothing more while one of its
//!     messages is out**: one published meanwhile waits for the ack.
//!     **A nack or a lapse of one brings back every later message of its
//!     key, the acknowledged ones included**: an acknowledged message can
//!     come a second time. With exactly-once delivery as well, a key
//!     gives one message at a time.
//!   - Dead letters. Every delivery is an attempt, sent as
//!     `deliveryAttempt` with a policy alone. A message released after
//!     its last attempt moves to the dead-letter topic, marked as
//!     production marks one. Production forwards only when its service
//!     agent holds two grants, and otherwise goes on delivering; the fake
//!     has no IAM yet and always forwards.
//!   - A retry policy. A message given back, or lapsed, waits the minimum
//!     backoff, doubled with each delivery up to the maximum: the fake's
//!     own rule, inside the delays production showed. With ordering it
//!     holds the later messages of its key behind it.
//!   - Retention. A message older than `messageRetentionDuration` is gone
//!     from the subscription, out on a lease or not.
//!   - Exactly-once delivery. An ack or a lease change that comes after
//!     the lease lapsed is refused, id by id, in production's body, and
//!     so is one with the id of an earlier delivery, then and ever after.
//!     A second ack with the id that acknowledged the message is taken,
//!     and a lease change on an acknowledged message is not.
//! - Faults, on command: `refuseNext`, `loseAnswers`, `dropNext`.
//!
//! Its clock is the `io` it is given: with `core.testing.FakeClock`, a
//! lease lapses when the test moves the clock and not before. It is safe
//! to use from several tasks at once.
//!
//! Not modelled yet, and answered 501 with a message that says so, never
//! guessed at: push and export deliveries, snapshots, seek, detach,
//! schemas, transforms, import settings, tags and IAM. A filter of a
//! shape production was not shown, or that production itself fails on,
//! is answered the same way. Production's
//! delays (a deleted topic that still takes a publish, the two seconds
//! before a nacked message comes again) are not modelled at all:
//! everything holds at once.

const std = @import("std");
const Allocator = std.mem.Allocator;
const Stringify = std.json.Stringify;
const Value = std.json.Value;
const core = @import("core");
const tp = core.transport;
const timestamp = core.timestamp;
const fake_filter = @import("fake_filter.zig");

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
        dead_letter: ?DeadLetter = null,
        retry: ?Retry = null,
        /// Messages with an ordering key come in the key's order.
        ordered: bool = false,
        exactly_once: bool = false,
        /// As it was sent. "": none.
        filter_text: []const u8 = "",
        filter: ?fake_filter.Filter = null,
        /// What it has not had acknowledged, by a number of the entry's
        /// own, in the order it arrived.
        entries: std.AutoArrayHashMapUnmanaged(u64, Entry) = .empty,
        next_seq: u64 = 1,
        /// By an entry's number, the delivery whose id acknowledged it.
        /// With exactly-once delivery that id is taken a second time, and
        /// an id of an earlier delivery is not.
        acknowledged: std.AutoHashMapUnmanaged(u64, u32) = .empty,

        /// Whether a message published to its topic reaches it. Production
        /// tries the filter as the message arrives: what does not pass is
        /// never held, and never comes.
        fn takes(s: *const Subscription, m: *const Message) bool {
            return if (s.filter) |filter| filter.matches(m.attributes) else true;
        }

        /// Whether the entry's place among the messages of its ordering
        /// key matters here.
        fn keyed(s: *const Subscription, entry: Entry) bool {
            return s.ordered and entry.message.ordering_key.len > 0;
        }

        /// Whether `id` may still act on the entry: the message is out on
        /// a lease, and with exactly-once delivery the id is that
        /// delivery's own. Without it an old id acts on a later delivery,
        /// as production's did. (That an id is one delivery's alone under
        /// exactly-once delivery is Google's documentation, not measured.)
        fn live(s: *const Subscription, index: usize, id: AckId, now: i96) bool {
            const entry = s.entries.values()[index];
            const until = entry.lease_until orelse return false;
            if (until <= now) return false;
            return !s.exactly_once or id.delivery == entry.deliveries;
        }

        /// An acknowledgement that took, by the id of `delivery`. With
        /// ordering, a message of a key is kept, acknowledged, while an
        /// earlier one of its key is not: that one's nack or lapse brings
        /// it back.
        fn take(s: *Subscription, gpa: Allocator, index: usize, delivery: u32) Allocator.Error!void {
            try s.acknowledged.put(gpa, s.entries.keys()[index], delivery);
            const entry = &s.entries.values()[index];
            if (!s.keyed(entry.*)) return s.entries.orderedRemoveAt(index);
            entry.acked = true;
            entry.lease_until = null;
            s.prune(entry.message.ordering_key);
        }

        /// Lets go of the acknowledged messages of a key that nothing can
        /// bring back: the ones before its first unacknowledged message.
        fn prune(s: *Subscription, key: []const u8) void {
            var i: usize = 0;
            while (i < s.entries.count()) {
                const entry = s.entries.values()[i];
                if (!std.mem.eql(u8, entry.message.ordering_key, key)) {
                    i += 1;
                } else if (entry.acked) {
                    s.entries.orderedRemoveAt(i);
                } else return;
            }
        }
    };

    const DeadLetter = struct {
        /// The topic's full name. Looked up when a message is forwarded:
        /// it may be deleted in the meantime.
        topic: []const u8,
        max_attempts: u32,
    };

    /// Seconds, each 0 to 600.
    const Retry = struct { min_s: i64, max_s: i64 };

    const Entry = struct {
        message: *const Message,
        /// Out on a lease until then, on the awake clock. Null: waiting.
        lease_until: ?i96 = null,
        /// How many times it was delivered.
        deliveries: u32 = 0,
        /// Not to be delivered again before then: a retry policy's backoff.
        not_before: i96 = 0,
        /// Acknowledged, and kept for now: see `Subscription.take`.
        acked: bool = false,
    };

    const AckId = struct { text: []const u8, seq: u64, delivery: u32 };

    pub fn init(gpa: Allocator, io: std.Io, options: Options) FakePubSub {
        return .{ .gpa = gpa, .io = io, .options = options, .store = .init(gpa) };
    }

    pub fn deinit(f: *FakePubSub) void {
        for (f.topics.values()) |t| t.messages.deinit(f.gpa);
        for (f.orphans.items) |t| t.messages.deinit(f.gpa);
        f.orphans.deinit(f.gpa);
        for ([_][]const *Subscription{ f.subscriptions.values(), f.dropped.items }) |list| {
            for (list) |s| {
                s.entries.deinit(f.gpa);
                s.acknowledged.deinit(f.gpa);
            }
        }
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
        // Out of memory here leaves a dead letter where it was, for the
        // next call to forward.
        f.settleAll(f.awakeNow()) catch {};
        const s = f.findSubscription(project, subscription) orelse return 0;
        var n: usize = 0;
        for (s.entries.values()) |e| n += @intFromBool(!e.acked);
        return n;
    }

    /// Of those, how many are out on a lease now.
    pub fn outstanding(f: *FakePubSub, project: []const u8, subscription: []const u8) usize {
        f.mutex.lockUncancelable(f.io);
        defer f.mutex.unlock(f.io);
        const now = f.awakeNow();
        f.settleAll(now) catch {};
        const s = f.findSubscription(project, subscription) orelse return 0;
        var n: usize = 0;
        for (s.entries.values()) |e| {
            if (e.lease_until) |until| {
                if (until > now) n += 1;
            }
        }
        return n;
    }

    /// How many messages the topic was sent, the dead letters forwarded to
    /// it included. Zero for one that is not there.
    pub fn publishedCount(f: *FakePubSub, project: []const u8, topic: []const u8) usize {
        f.mutex.lockUncancelable(f.io);
        defer f.mutex.unlock(f.io);
        f.settleAll(f.awakeNow()) catch {};
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
        // What production does on its own, it does here before each call.
        try f.settleAll(f.awakeNow());
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
                if (s.topic != topic or !s.takes(kept)) continue;
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
        var deadline_given = false;
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
                    deadline_given = true;
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
            } else if (isField(key, "enableMessageOrdering")) {
                sub.ordered = boolOf(value) orelse return badValue(arena, key);
            } else if (isField(key, "enableExactlyOnceDelivery")) {
                sub.exactly_once = boolOf(value) orelse return badValue(arena, key);
            } else if (isField(key, "filter")) {
                sub.filter_text = stringOf(value) orelse return badValue(arena, key);
            } else if (isField(key, "deadLetterPolicy")) {
                sub.dead_letter = switch (try deadLetterOf(arena, value)) {
                    .ok => |policy| policy,
                    .refused => |r| return r,
                };
            } else if (isField(key, "retryPolicy")) {
                sub.retry = switch (try retryOf(arena, value)) {
                    .ok => |policy| policy,
                    .refused => |r| return r,
                };
            } else if (isAnyField(key, &.{ "bigqueryConfig", "cloudStorageConfig", "messageTransforms", "tags" })) {
                return notModelled(arena, key);
            } else return unknownName(arena, key);
        }
        if (!isResourceName(topic_name, "topics")) return invalidName(arena, topic_name);
        if (sub.filter_text.len > 0) switch (try fake_filter.parse(arena, sub.filter_text)) {
            // Read again into the store when the subscription is kept.
            .ok => |filter| sub.filter = filter,
            .refused => |words| return fail(arena, 400, "INVALID_ARGUMENT", words),
            .not_modelled => |words| return fail(arena, 501, "UNIMPLEMENTED", words),
        };
        // With exactly-once delivery production's own deadline is a minute.
        if (sub.exactly_once and !deadline_given) sub.ack_deadline_s = 60;
        if (sub.dead_letter) |policy| {
            if (!f.topics.contains(policy.topic)) return notFound(arena, idOf(policy.topic));
        }
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
            } else if (isPath(path, "deadLetterPolicy")) {
                next.dead_letter = if (given) |v| switch (try deadLetterOf(arena, v)) {
                    .ok => |policy| policy: {
                        if (!f.topics.contains(policy.topic)) return notFound(arena, idOf(policy.topic));
                        break :policy .{ .topic = try f.keep(policy.topic), .max_attempts = policy.max_attempts };
                    },
                    .refused => |r| return r,
                } else null;
            } else if (isPath(path, "retryPolicy")) {
                next.retry = if (given) |v| switch (try retryOf(arena, v)) {
                    .ok => |policy| policy,
                    .refused => |r| return r,
                } else null;
            } else if (isPath(path, "enableExactlyOnceDelivery")) {
                next.exactly_once = if (given) |v| boolOf(v) orelse return badValue(arena, path) else false;
            } else if (isAnyPath(path, &.{ "pushConfig", "bigqueryConfig", "cloudStorageConfig", "messageTransforms" })) {
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
            // A lease that lapses while the pull is held is settled as at
            // any other time.
            const now = f.awakeNow();
            try f.settleAll(now);
            // Looked up each time round: the subscription may be deleted
            // while a pull is held.
            const sub = f.subscriptions.get(name) orelse return notFound(arena, route.id);
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

    /// Brings every subscription up to `now`. Leases lapse with time and
    /// nothing else, and what follows a lapse (a dead letter forwarded, a
    /// message past its retention gone) production does without being
    /// asked, so it is done before each request.
    fn settleAll(f: *FakePubSub, now: i96) Allocator.Error!void {
        // By index: a forwarded dead letter may add to another's entries,
        // never to the list of subscriptions.
        var i: usize = 0;
        while (i < f.subscriptions.count()) : (i += 1) try f.settle(f.subscriptions.values()[i], now);
    }

    /// One subscription, brought up to `now`: messages past its retention
    /// go, lapsed leases end, and a message that has had its last attempt
    /// moves to the dead-letter topic.
    fn settle(f: *FakePubSub, sub: *Subscription, now: i96) Allocator.Error!void {
        const wall = std.Io.Clock.real.now(f.io).nanoseconds;
        const keep_ns = @as(i96, sub.retention_s) * std.time.ns_per_s;
        var i: usize = 0;
        while (i < sub.entries.count()) {
            const entry = sub.entries.values()[i];
            if (wall - entry.message.publish_time.nanoseconds >= keep_ns) {
                // An acknowledged one kept behind it is younger, and goes
                // the same way in its turn.
                sub.entries.orderedRemoveAt(i);
                continue;
            }
            if (entry.lease_until) |until| {
                // The backoff runs from the lapse, not from when it was
                // noticed.
                if (until <= now and try f.released(sub, i, until)) continue;
            }
            i += 1;
        }
    }

    /// A delivery that ended without an ack, by a lapse or a nack, at
    /// `at`. After its last attempt the message is forwarded to the
    /// dead-letter topic; otherwise it waits again, as long as the retry
    /// policy says. On a subscription with ordering every later message
    /// of its key is taken back with it, the acknowledged ones included:
    /// production delivered k2 to k5 again after a nack of k2 alone, with
    /// k3 to k5 acknowledged. (That a forwarded one takes them back too
    /// is the fake's own choice.) True when the entry at `index` is gone.
    /// A failure leaves everything as it was.
    fn released(f: *FakePubSub, sub: *Subscription, index: usize, at: i96) Allocator.Error!bool {
        const entry = sub.entries.values()[index];
        var gone = false;
        if (sub.dead_letter) |policy| forwarded: {
            if (entry.deliveries < policy.max_attempts) break :forwarded;
            // Production forwards only when its service agent may publish
            // there and acknowledge here, and otherwise goes on delivering.
            // With no topic to forward to, the fake goes on delivering too.
            const dead = f.topics.get(policy.topic) orelse break :forwarded;
            try f.forward(sub, entry, dead);
            sub.entries.orderedRemoveAt(index);
            gone = true;
        }
        if (!gone) {
            const waiting = &sub.entries.values()[index];
            waiting.lease_until = null;
            if (sub.retry) |retry| waiting.not_before = at + backoff(retry, entry.deliveries) * std.time.ns_per_s;
        }
        if (sub.keyed(entry)) {
            // What it remembers of the ids that acknowledged them is
            // written over when they are acknowledged again.
            for (sub.entries.values()[index + @intFromBool(!gone) ..]) |*later| {
                if (!std.mem.eql(u8, later.message.ordering_key, entry.message.ordering_key)) continue;
                later.lease_until = null;
                later.acked = false;
            }
        }
        return gone;
    }

    /// The fake's own rule, inside what production showed: the minimum,
    /// doubling with each delivery, up to the maximum. Production's delays
    /// under a 10 to 20 second policy were 10, 11.5, 17 and 16.5 seconds
    /// after a nack, and 15 and 16 after a lapse.
    fn backoff(retry: Retry, deliveries: u32) i96 {
        const doublings: u6 = @intCast(@min(deliveries -| 1, 20));
        return @min(retry.max_s, retry.min_s << doublings);
    }

    /// A dead letter: the message again, on the dead-letter topic, marked
    /// with where it came from. The first two attributes are as production
    /// wrote them (2026-09-28); the other two are Google's documentation.
    fn forward(f: *FakePubSub, sub: *const Subscription, entry: Entry, dead: *Topic) Allocator.Error!void {
        const store = f.store.allocator();
        const m = entry.message;
        const attributes = try store.alloc(Label, m.attributes.len + 4);
        @memcpy(attributes[0..m.attributes.len], m.attributes);
        var time_buf: [timestamp.max_len]u8 = undefined;
        const rest = idOf(sub.name);
        const project = sub.name["projects/".len .. sub.name.len - "/subscriptions/".len - rest.len];
        attributes[m.attributes.len..][0..4].* = .{
            .{ .key = "CloudPubSubDeadLetterSourceDeliveryCount", .value = try std.fmt.allocPrint(store, "{d}", .{entry.deliveries}) },
            .{ .key = "CloudPubSubDeadLetterSourceSubscription", .value = rest },
            .{ .key = "CloudPubSubDeadLetterSourceSubscriptionProject", .value = project },
            .{ .key = "CloudPubSubDeadLetterSourceTopicPublishTime", .value = try store.dupe(u8, timestamp.format(&time_buf, m.publish_time)) },
        };
        const kept = try store.create(Message);
        kept.* = .{ .id = f.next_message_id, .data = m.data, .attributes = attributes, .ordering_key = m.ordering_key, .publish_time = std.Io.Clock.real.now(f.io) };
        try dead.messages.ensureUnusedCapacity(f.gpa, 1);
        for (f.subscriptions.values()) |s| {
            if (s.topic == dead) try s.entries.ensureUnusedCapacity(f.gpa, 1);
        }
        f.next_message_id += 1;
        dead.messages.appendAssumeCapacity(kept);
        for (f.subscriptions.values()) |s| {
            if (s.topic != dead or !s.takes(kept)) continue;
            s.entries.putAssumeCapacity(s.next_seq, .{ .message = kept });
            s.next_seq += 1;
        }
    }

    /// The numbers of the entries a pull may give at `now`, to which the
    /// subscription is settled: the ones waiting whose backoff, if any,
    /// has run, and that ordering does not hold back. In an order of the
    /// fake's choosing when `shuffle` is on.
    fn readyEntries(f: *FakePubSub, arena: Allocator, sub: *Subscription, now: i96) Allocator.Error![]u64 {
        var ready: std.ArrayList(u64) = .empty;
        // The keys that give nothing more, with ordering. A key with a
        // message out gives none until that one is acknowledged or comes
        // back: production held k2 fourteen seconds behind k1, and gave
        // it a second after k1's ack. What a key has waiting it gives
        // together, in one pull. A message waiting out its backoff holds
        // the later ones of its key behind it. And with exactly-once
        // delivery as well a key gives one message at a time, as
        // production gave m1 alone of three published together.
        var held: std.StringHashMapUnmanaged(void) = .empty;
        if (sub.ordered) for (sub.entries.values()) |entry| {
            if (entry.lease_until != null and sub.keyed(entry)) try held.put(arena, entry.message.ordering_key, {});
        };
        for (sub.entries.keys(), sub.entries.values()) |seq, entry| {
            if (entry.acked or entry.lease_until != null) continue;
            const key = entry.message.ordering_key;
            if (sub.keyed(entry) and held.contains(key)) continue;
            if (entry.not_before > now) {
                if (sub.keyed(entry)) try held.put(arena, key, {});
                continue;
            }
            try ready.append(arena, seq);
            if (sub.keyed(entry) and sub.exactly_once) try held.put(arena, key, {});
        }
        if (f.options.shuffle) try f.mix(arena, sub, ready.items);
        return ready.items;
    }

    /// Puts `ready`, which is in the order published, in an order of the
    /// fake's choosing. On a subscription with ordering each key's
    /// messages still come in their own order, as production's did: the
    /// keys among themselves and the messages without one in any.
    fn mix(f: *FakePubSub, arena: Allocator, sub: *const Subscription, ready: []u64) Allocator.Error!void {
        if (!sub.ordered) return f.prng.random().shuffle(u64, ready);
        const published = try arena.dupe(u64, ready);
        f.prng.random().shuffle(u64, ready);
        // Each key's places in the new order, filled with its messages in
        // the old one.
        const Places = struct { at: std.ArrayList(usize) = .empty, filled: usize = 0 };
        var places: std.StringHashMapUnmanaged(Places) = .empty;
        for (ready, 0..) |seq, at| {
            const key = sub.entries.get(seq).?.message.ordering_key;
            if (key.len == 0) continue;
            const slot = try places.getOrPutValue(arena, key, .{});
            try slot.value_ptr.at.append(arena, at);
        }
        for (published) |seq| {
            const key = sub.entries.get(seq).?.message.ordering_key;
            if (key.len == 0) continue;
            const slot = places.getPtr(key).?;
            ready[slot.at.items[slot.filled]] = seq;
            slot.filled += 1;
        }
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
            // Sent only with a dead-letter policy, as production sends it.
            if (sub.dead_letter != null) {
                jw.objectField("deliveryAttempt") catch return error.OutOfMemory;
                jw.write(entry.deliveries + 1) catch return error.OutOfMemory;
            }
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

    const AckRequest = struct { ids: []const AckId, seconds: ?i64 };

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
        const parsed_ids = try arena.alloc(AckId, ids.len);
        for (ids, parsed_ids) |id, *slot| {
            const text = stringOf(id) orelse return .{ .refused = try badValue(arena, "ackIds") };
            const parsed = parseAckId(text) orelse return .{ .refused = try fail(arena, 400, "INVALID_ARGUMENT", try std.fmt.allocPrint(arena, "You have passed an invalid ack ID to the service (ack_id={s}).", .{text})) };
            if (parsed.uid != sub.uid) return .{ .refused = try fail(arena, 400, "INVALID_ARGUMENT", try std.fmt.allocPrint(arena, "You have passed a subscription that does not belong to the given ack ID (resource={s}).", .{sub.name})) };
            slot.* = .{ .text = text, .seq = parsed.seq, .delivery = parsed.delivery };
        }
        return .{ .ok = .{ .sub = sub, .request = .{ .ids = parsed_ids, .seconds = seconds } } };
    }

    const Judged = struct {
        /// For each id of the request: whether it may act.
        live: []const bool,
        /// The ids an exactly-once refusal names, each once.
        refused: []const []const u8,
    };

    /// Says of each id of an acknowledge or a modifyAckDeadline whether it
    /// may act, as the request finds things, before any of them acts:
    /// with ordering a nack takes the later messages of its key back, and
    /// their own ids in the same request come no later for that.
    ///
    /// An id that may not act is answered and forgotten: the message is
    /// taken only while it is out, and after a lapse or a nack it comes
    /// again. With exactly-once delivery the id is refused instead, a
    /// lapsed message's and an acknowledged one's alike. Production took
    /// one such: a second ack with the very id that acknowledged the
    /// message. With an id of an earlier delivery of it, it refused.
    fn judge(arena: Allocator, sub: *const Subscription, ids: []const AckId, now: i96, lease_change: bool) Allocator.Error!Judged {
        const live = try arena.alloc(bool, ids.len);
        var refused: std.ArrayList([]const u8) = .empty;
        each: for (ids, live) |id, *slot| {
            const index = sub.entries.getIndex(id.seq);
            // Gone, or kept behind an earlier one of its key.
            const acknowledged = if (index) |i| sub.entries.values()[i].acked else true;
            slot.* = !acknowledged and sub.live(index.?, id, now);
            if (slot.* or !sub.exactly_once) continue;
            if (acknowledged and !lease_change and sub.acknowledged.get(id.seq) == id.delivery) continue;
            for (refused.items) |named| {
                if (std.mem.eql(u8, named, id.text)) continue :each;
            }
            try refused.append(arena, id.text);
        }
        return .{ .live = live, .refused = refused.items };
    }

    fn acknowledge(f: *FakePubSub, arena: Allocator, route: Route, body: []const u8) Allocator.Error!Reply {
        const checked = switch (try f.ackRequest(arena, route, body)) {
            .ok => |c| c,
            .refused => |r| return r,
        };
        const sub = checked.sub;
        const judged = try judge(arena, sub, checked.request.ids, f.awakeNow(), false);
        for (checked.request.ids, judged.live) |id, live| {
            if (!live) continue;
            // Looked up for each: the one before it may have been the
            // same id.
            const index = sub.entries.getIndex(id.seq) orelse continue;
            if (!sub.entries.values()[index].acked) try sub.take(f.gpa, index, id.delivery);
        }
        // The ids it does not name were taken.
        if (judged.refused.len > 0) return exactlyOnceRefusal(arena, judged.refused);
        return ok("{}");
    }

    fn modifyAckDeadline(f: *FakePubSub, arena: Allocator, route: Route, body: []const u8) Allocator.Error!Reply {
        const checked = switch (try f.ackRequest(arena, route, body)) {
            .ok => |c| c,
            .refused => |r| return r,
        };
        const seconds = checked.request.seconds orelse 0;
        if (seconds < 0 or seconds > 600) return fail(arena, 400, "INVALID_ARGUMENT", try std.fmt.allocPrint(arena, "Invalid ack deadline given (ack_deadline={d}). The ack deadline must be between 0 and 600 seconds.", .{seconds}));
        const sub = checked.sub;
        const now = f.awakeNow();
        const judged = try judge(arena, sub, checked.request.ids, now, true);
        for (checked.request.ids, judged.live) |id, live| {
            if (!live) continue;
            // Looked up for each: a nack before it may have moved it, or
            // forwarded it, the same id sent twice.
            const index = sub.entries.getIndex(id.seq) orelse continue;
            // Zero gives the message back at once: a nack. One that an
            // earlier nack of the request took back is released all the
            // same: it was out, and it is given back.
            if (seconds == 0) {
                _ = try f.released(sub, index, now);
            } else sub.entries.values()[index].lease_until = now + @as(i96, seconds) * std.time.ns_per_s;
        }
        if (judged.refused.len > 0) return exactlyOnceRefusal(arena, judged.refused);
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
        if (sub.dead_letter) |policy| kept.dead_letter = .{ .topic = try f.keep(policy.topic), .max_attempts = policy.max_attempts };
        kept.filter_text = try f.keep(sub.filter_text);
        if (sub.filter != null) kept.filter = switch (try fake_filter.parse(f.store.allocator(), kept.filter_text)) {
            .ok => |filter| filter,
            // It was read once already, and reads the same again.
            .refused, .not_modelled => unreachable,
        };
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

/// A dead-letter policy: a topic by its full name, and 5 to 100 delivery
/// attempts, 5 when none is said.
fn deadLetterOf(arena: Allocator, value: Value) Allocator.Error!Parsed(FakePubSub.DeadLetter) {
    const object = switch (value) {
        .object => |o| o,
        else => return .{ .refused = try badValue(arena, "deadLetterPolicy") },
    };
    var topic: []const u8 = "";
    var attempts: i64 = 0;
    var it = object.iterator();
    while (it.next()) |entry| {
        const key = entry.key_ptr.*;
        if (isField(key, "deadLetterTopic")) {
            topic = stringOf(entry.value_ptr.*) orelse return .{ .refused = try badValue(arena, key) };
        } else if (isField(key, "maxDeliveryAttempts")) {
            attempts = intOf(entry.value_ptr.*) orelse return .{ .refused = try badValue(arena, key) };
        } else return .{ .refused = try unknownName(arena, key) };
    }
    if (!isResourceName(topic, "topics")) return .{ .refused = try invalidName(arena, topic) };
    if (attempts == 0) attempts = 5;
    if (attempts < 5) return .{ .refused = try fail(arena, 400, "INVALID_ARGUMENT", try std.fmt.allocPrint(arena, "The value for max_delivery_attempts is too small. You passed {d} in the request, but the minimum value is 5.", .{attempts})) };
    if (attempts > 100) return .{ .refused = try fail(arena, 400, "INVALID_ARGUMENT", try std.fmt.allocPrint(arena, "The value for max_delivery_attempts is too large. You passed {d} in the request, but the maximum value is 100.", .{attempts})) };
    return .{ .ok = .{ .topic = topic, .max_attempts = @intCast(attempts) } };
}

/// A retry policy: each backoff 0 to 600 seconds, 10 and 600 when not
/// said, and the minimum no greater than the maximum.
fn retryOf(arena: Allocator, value: Value) Allocator.Error!Parsed(FakePubSub.Retry) {
    const object = switch (value) {
        .object => |o| o,
        else => return .{ .refused = try badValue(arena, "retryPolicy") },
    };
    var policy: FakePubSub.Retry = .{ .min_s = 10, .max_s = 600 };
    var it = object.iterator();
    while (it.next()) |entry| {
        const key = entry.key_ptr.*;
        const minimum = isField(key, "minimumBackoff");
        if (!minimum and !isField(key, "maximumBackoff")) return .{ .refused = try unknownName(arena, key) };
        const seconds = secondsOf(entry.value_ptr.*) orelse return .{ .refused = try badValue(arena, key) };
        if (seconds < 0 or seconds > 600) return .{ .refused = try fail(arena, 400, "INVALID_ARGUMENT", try std.fmt.allocPrint(arena, "The value for {s} is out of bounds. You passed {s} in the request, but the value must be between 0 and 10m.", .{ if (minimum) "minimum_backoff" else "maximum_backoff", try goDuration(arena, seconds) })) };
        if (minimum) policy.min_s = seconds else policy.max_s = seconds;
    }
    if (policy.max_s < policy.min_s) return .{ .refused = try fail(arena, 400, "INVALID_ARGUMENT", try std.fmt.allocPrint(arena, "The specified maximum_backoff {s} cannot be smaller than minimum_backoff {s}.", .{ try goDuration(arena, policy.max_s), try goDuration(arena, policy.min_s) })) };
    return .{ .ok = policy };
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

fn parseAckId(id: []const u8) ?struct { uid: u64, seq: u64, delivery: u32 } {
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
    const delivery = std.fmt.parseInt(u32, parts.next() orelse return null, 10) catch return null;
    if (parts.next() != null) return null;
    return .{ .uid = uid, .seq = seq, .delivery = delivery };
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

/// Production's refusal of ack ids on a subscription with exactly-once
/// delivery, whole, as it answered on 2026-09-27: each id it did not
/// take, and why.
fn exactlyOnceRefusal(arena: Allocator, ids: []const []const u8) Allocator.Error!FakePubSub.Reply {
    var out: std.Io.Writer.Allocating = .init(arena);
    var jw: Stringify = .{ .writer = &out.writer };
    writeExactlyOnceRefusal(&jw, ids) catch return error.OutOfMemory;
    return .{ .status = 400, .body = out.written() };
}

fn writeExactlyOnceRefusal(jw: *Stringify, ids: []const []const u8) Stringify.Error!void {
    try jw.beginObject();
    try jw.objectField("error");
    try jw.beginObject();
    try jw.objectField("code");
    try jw.write(400);
    try jw.objectField("message");
    try jw.write("Some acknowledgement ids in the request were invalid. This could be because the acknowledgement ids have expired or the acknowledgement ids were malformed.");
    try jw.objectField("status");
    try jw.write("INVALID_ARGUMENT");
    try jw.objectField("details");
    try jw.beginArray();
    try jw.beginObject();
    try jw.objectField("@type");
    try jw.write("type.googleapis.com/google.rpc.ErrorInfo");
    try jw.objectField("reason");
    try jw.write("EXACTLY_ONCE_ACKID_FAILURE");
    try jw.objectField("domain");
    try jw.write("pubsub.googleapis.com");
    try jw.objectField("metadata");
    try jw.beginObject();
    for (ids) |id| {
        try jw.objectField(id);
        try jw.write("PERMANENT_FAILURE_INVALID_ACK_ID");
    }
    try jw.endObject();
    try jw.endObject();
    try jw.endArray();
    try jw.endObject();
    try jw.endObject();
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
    if (sub.ordered) {
        try jw.objectField("enableMessageOrdering");
        try jw.write(true);
    }
    try jw.objectField("expirationPolicy");
    try jw.beginObject();
    if (sub.expiration_ttl_s) |ttl| {
        try jw.objectField("ttl");
        try writeSeconds(jw, ttl);
    }
    try jw.endObject();
    if (sub.filter_text.len > 0) {
        try jw.objectField("filter");
        try jw.write(sub.filter_text);
    }
    if (sub.dead_letter) |policy| {
        try jw.objectField("deadLetterPolicy");
        try jw.beginObject();
        try jw.objectField("deadLetterTopic");
        try jw.write(policy.topic);
        try jw.objectField("maxDeliveryAttempts");
        try jw.write(policy.max_attempts);
        try jw.endObject();
    }
    if (sub.retry) |policy| {
        try jw.objectField("retryPolicy");
        try jw.beginObject();
        try jw.objectField("minimumBackoff");
        try writeSeconds(jw, policy.min_s);
        try jw.objectField("maximumBackoff");
        try writeSeconds(jw, policy.max_s);
        try jw.endObject();
    }
    if (sub.exactly_once) {
        try jw.objectField("enableExactlyOnceDelivery");
        try jw.write(true);
    }
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
        return b.initIn(testing.allocator, options);
    }

    fn initIn(b: *Bench, gpa: Allocator, options: FakePubSub.Options) !void {
        b.clock = .{};
        b.fake = .init(gpa, b.clock.io(), options);
        errdefer b.fake.deinit();
        b.tokens = .{};
        b.diag = .{};
        b.client = try .init(gpa, b.clock.io(), .{
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

/// `n` of the letter x, for text of a chosen length.
fn xs(comptime n: usize) [n]u8 {
    return @splat('x');
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

    // With no page size, or 0, a page is a hundred: the fake's own number,
    // which production was not asked for. This client always says one.
    for (0..96) |i| {
        var made = try b.client.topic(try std.fmt.allocPrint(a, "t{d:0>3}", .{i})).create(.{});
        made.deinit();
    }
    for ([_][]const u8{ "projects/p/topics", "projects/p/topics?pageSize=0" }) |path| {
        const page = (try b.raw(a, .GET, path, "")).body;
        try testing.expectEqual(100, std.mem.count(u8, page, "\"name\""));
        try testing.expect(std.mem.indexOf(u8, page, "\"nextPageToken\"") != null);
    }
    try testing.expectEqual(101, std.mem.count(u8, (try b.raw(a, .GET, "projects/p/topics?pageSize=1000", "")).body, "\"name\""));
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
    try testing.expectError(error.Unimplemented, b.client.subscription("pushed").create(.{ .topic_id = "zigps-b", .delivery = .{ .push = .{ .endpoint = "https://example.com/hook" } } }));
    try testing.expectEqualStrings("fake: a push subscription is not modelled yet", b.diag.message());

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

/// Pulls with nothing to give, and says so.
fn expectNothing(sub: anytype) !void {
    var got = try sub.pull(.{ .return_immediately = true });
    defer got.deinit();
    try testing.expectEqual(0, got.value.messages.len);
}

test "a subscription's rules: read back as production reads them back, and refused in its words" {
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
    const dead = "\"deadLetterTopic\":\"projects/p/topics/zigps-b\"";

    // Production's answers, 2026-10-12, in the order it writes the fields.
    try testing.expectEqualStrings(
        \\{"name":"projects/p/subscriptions/zigps-full","topic":"projects/p/topics/zigps-a","pushConfig":{},"ackDeadlineSeconds":60,"retainAckedMessages":true,"messageRetentionDuration":"1200s","labels":{"env":"test"},"enableMessageOrdering":true,"expirationPolicy":{"ttl":"86400s"},"filter":"attributes.k = \"v\"","deadLetterPolicy":{"deadLetterTopic":"projects/p/topics/zigps-b","maxDeliveryAttempts":7},"retryPolicy":{"minimumBackoff":"5s","maximumBackoff":"60s"},"state":"ACTIVE"}
    , (try b.raw(a, .PUT, "projects/p/subscriptions/zigps-full", "{" ++ topic ++ ",\"ackDeadlineSeconds\":60,\"enableMessageOrdering\":true,\"filter\":\"attributes.k = \\\"v\\\"\",\"retryPolicy\":{\"minimumBackoff\":\"5s\",\"maximumBackoff\":\"60s\"},\"deadLetterPolicy\":{" ++ dead ++ ",\"maxDeliveryAttempts\":7},\"retainAckedMessages\":true,\"messageRetentionDuration\":\"1200s\",\"labels\":{\"env\":\"test\"},\"expirationPolicy\":{\"ttl\":\"86400s\"}}")).body);
    // With exactly-once delivery its own deadline is a minute.
    try testing.expectEqualStrings(
        \\{"name":"projects/p/subscriptions/zigps-eo","topic":"projects/p/topics/zigps-a","pushConfig":{},"ackDeadlineSeconds":60,"messageRetentionDuration":"604800s","expirationPolicy":{"ttl":"2678400s"},"enableExactlyOnceDelivery":true,"state":"ACTIVE"}
    , (try b.raw(a, .PUT, "projects/p/subscriptions/zigps-eo", "{" ++ topic ++ ",\"enableExactlyOnceDelivery\":true}")).body);
    // Five attempts when none is said.
    try testing.expectEqualStrings(
        \\{"name":"projects/p/subscriptions/zigps-dl","topic":"projects/p/topics/zigps-a","pushConfig":{},"ackDeadlineSeconds":10,"messageRetentionDuration":"604800s","expirationPolicy":{"ttl":"2678400s"},"deadLetterPolicy":{"deadLetterTopic":"projects/p/topics/zigps-b","maxDeliveryAttempts":5},"state":"ACTIVE"}
    , (try b.raw(a, .PUT, "projects/p/subscriptions/zigps-dl", "{" ++ topic ++ ",\"deadLetterPolicy\":{" ++ dead ++ "}}")).body);
    // Dead letters to its own topic are taken.
    try testing.expectEqual(200, (try b.raw(a, .PUT, "projects/p/subscriptions/zigps-own", "{" ++ topic ++ ",\"deadLetterPolicy\":{\"deadLetterTopic\":\"projects/p/topics/zigps-a\"}}")).status);
    // A retry policy with nothing in it is 10 seconds to 600.
    try testing.expectEqualStrings(
        \\{"name":"projects/p/subscriptions/zigps-rp","topic":"projects/p/topics/zigps-a","pushConfig":{},"ackDeadlineSeconds":10,"messageRetentionDuration":"604800s","expirationPolicy":{"ttl":"2678400s"},"retryPolicy":{"minimumBackoff":"10s","maximumBackoff":"600s"},"state":"ACTIVE"}
    , (try b.raw(a, .PUT, "projects/p/subscriptions/zigps-rp", "{" ++ topic ++ ",\"retryPolicy\":{}}")).body);

    // Its refusals, each in its words.
    for ([_]struct { []const u8, []const u8 }{
        .{ "\"deadLetterPolicy\":{" ++ dead ++ ",\"maxDeliveryAttempts\":4}", "The value for max_delivery_attempts is too small. You passed 4 in the request, but the minimum value is 5." },
        .{ "\"deadLetterPolicy\":{" ++ dead ++ ",\"maxDeliveryAttempts\":101}", "The value for max_delivery_attempts is too large. You passed 101 in the request, but the maximum value is 100." },
        .{ "\"retryPolicy\":{\"minimumBackoff\":\"30s\",\"maximumBackoff\":\"10s\"}", "The specified maximum_backoff 10s cannot be smaller than minimum_backoff 30s." },
        .{ "\"retryPolicy\":{\"minimumBackoff\":\"1s\",\"maximumBackoff\":\"601s\"}", "The value for maximum_backoff is out of bounds. You passed 10m1s in the request, but the value must be between 0 and 10m." },
        .{ "\"filter\":\"attributes.k = \\\"" ++ comptime xs(240) ++ "\\\"\"", "Invalid filter expression: length 257 exceeds maximum allowed length of 256." },
        .{ "\"filter\":\"attributes.kind > \\\"a\\\"\"", "Invalid filter expression: Invalid operator (line 1, columns 1 to 21)." },
    }) |case| {
        const setting, const words = case;
        try expectRefused(try b.raw(a, .PUT, "projects/p/subscriptions/zigps-bad", try std.fmt.allocPrint(a, "{{" ++ topic ++ ",{s}}}", .{setting})), 400, "INVALID_ARGUMENT", words);
    }
    try expectRefused(try b.raw(a, .PUT, "projects/p/subscriptions/zigps-bad", "{" ++ topic ++ ",\"deadLetterPolicy\":{\"deadLetterTopic\":\"projects/p/topics/zigps-nope\"}}"), 404, "NOT_FOUND", "Resource not found (resource=zigps-nope).");
    // The fake's own words where production was not asked: a minimum out
    // of bounds, after production's for the maximum.
    try expectRefused(try b.raw(a, .PUT, "projects/p/subscriptions/zigps-bad", "{" ++ topic ++ ",\"retryPolicy\":{\"minimumBackoff\":\"601s\",\"maximumBackoff\":\"600s\"}}"), 400, "INVALID_ARGUMENT", "The value for minimum_backoff is out of bounds. You passed 10m1s in the request, but the value must be between 0 and 10m.");
    try expectRefused(try b.raw(a, .PUT, "projects/p/subscriptions/zigps-bad", "{" ++ topic ++ ",\"filter\":\"attributes.kind\"}"), 400, "INVALID_ARGUMENT", "Invalid filter expression: Expected either a function call or an expression with an operator (line 1, columns 1 to 15).");
    // A filter of a shape production was not shown, or one it failed on
    // itself, is not guessed at.
    try expectRefused(try b.raw(a, .PUT, "projects/p/subscriptions/zigps-bad", "{" ++ topic ++ ",\"filter\":\"--attributes:kind\"}"), 501, "UNIMPLEMENTED", "fake: this filter is not modelled: a minus after a minus, which production answers with an internal error, at column 2");
    try testing.expectEqual(404, (try b.raw(a, .GET, "projects/p/subscriptions/zigps-bad", "")).status);
    // The bounds themselves are taken: 5 and 100 attempts, 0 and 600 seconds.
    for ([_][]const u8{ "\"deadLetterPolicy\":{" ++ dead ++ ",\"maxDeliveryAttempts\":5}", "\"deadLetterPolicy\":{" ++ dead ++ ",\"maxDeliveryAttempts\":100}", "\"retryPolicy\":{\"minimumBackoff\":\"0s\",\"maximumBackoff\":\"0s\"}", "\"retryPolicy\":{\"minimumBackoff\":\"600s\",\"maximumBackoff\":\"600s\"}" }, 0..) |setting, i| {
        try testing.expectEqual(200, (try b.raw(a, .PUT, try std.fmt.allocPrint(a, "projects/p/subscriptions/zigps-edge{d}", .{i}), try std.fmt.allocPrint(a, "{{" ++ topic ++ ",{s}}}", .{setting}))).status);
    }

    // Updates, as production answered them: a path the body leaves out
    // goes back to its default, and a policy that way is gone.
    try testing.expectEqualStrings(
        \\{"name":"projects/p/subscriptions/zigps-full","topic":"projects/p/topics/zigps-a","pushConfig":{"attributes":{"x-goog-version":"v1"}},"ackDeadlineSeconds":60,"retainAckedMessages":true,"messageRetentionDuration":"1200s","labels":{"env":"test"},"enableMessageOrdering":true,"expirationPolicy":{"ttl":"2678400s"},"filter":"attributes.k = \"v\"","deadLetterPolicy":{"deadLetterTopic":"projects/p/topics/zigps-b","maxDeliveryAttempts":7},"retryPolicy":{"minimumBackoff":"5s","maximumBackoff":"60s"},"state":"ACTIVE"}
    , (try b.raw(a, .PATCH, "projects/p/subscriptions/zigps-full", "{\"subscription\":{},\"updateMask\":\"expirationPolicy\"}")).body);
    try testing.expectEqualStrings(
        \\{"name":"projects/p/subscriptions/zigps-full","topic":"projects/p/topics/zigps-a","pushConfig":{"attributes":{"x-goog-version":"v1"}},"ackDeadlineSeconds":60,"retainAckedMessages":true,"messageRetentionDuration":"604800s","labels":{"env":"test"},"enableMessageOrdering":true,"expirationPolicy":{"ttl":"2678400s"},"filter":"attributes.k = \"v\"","state":"ACTIVE"}
    , (try b.raw(a, .PATCH, "projects/p/subscriptions/zigps-full", "{\"subscription\":{},\"updateMask\":\"messageRetentionDuration,retryPolicy,deadLetterPolicy\"}")).body);
    // Set by an update, each is checked as on a create, and a refused
    // update changes nothing.
    try testing.expectEqual(200, (try b.raw(a, .PATCH, "projects/p/subscriptions/zigps-full", "{\"subscription\":{\"deadLetterPolicy\":{" ++ dead ++ ",\"maxDeliveryAttempts\":6},\"retryPolicy\":{\"maximumBackoff\":\"30s\"}},\"updateMask\":\"deadLetterPolicy,retryPolicy\"}")).status);
    const policies = "\"deadLetterPolicy\":{\"deadLetterTopic\":\"projects/p/topics/zigps-b\",\"maxDeliveryAttempts\":6},\"retryPolicy\":{\"minimumBackoff\":\"10s\",\"maximumBackoff\":\"30s\"},\"state\"";
    try testing.expect(std.mem.indexOf(u8, (try b.raw(a, .GET, "projects/p/subscriptions/zigps-full", "")).body, policies) != null);
    try expectRefused(try b.raw(a, .PATCH, "projects/p/subscriptions/zigps-full", "{\"subscription\":{\"deadLetterPolicy\":{\"deadLetterTopic\":\"projects/p/topics/zigps-nope\"}},\"updateMask\":\"deadLetterPolicy\"}"), 404, "NOT_FOUND", "Resource not found (resource=zigps-nope).");
    try expectRefused(try b.raw(a, .PATCH, "projects/p/subscriptions/zigps-full", "{\"subscription\":{\"deadLetterPolicy\":{" ++ dead ++ ",\"maxDeliveryAttempts\":4}},\"updateMask\":\"deadLetterPolicy\"}"), 400, "INVALID_ARGUMENT", "The value for max_delivery_attempts is too small. You passed 4 in the request, but the minimum value is 5.");
    try expectRefused(try b.raw(a, .PATCH, "projects/p/subscriptions/zigps-full", "{\"subscription\":{\"ackDeadlineSeconds\":30,\"retryPolicy\":{\"minimumBackoff\":\"30s\",\"maximumBackoff\":\"10s\"}},\"updateMask\":\"ackDeadlineSeconds,retryPolicy\"}"), 400, "INVALID_ARGUMENT", "The specified maximum_backoff 10s cannot be smaller than minimum_backoff 30s.");
    const kept = (try b.raw(a, .GET, "projects/p/subscriptions/zigps-full", "")).body;
    try testing.expect(std.mem.indexOf(u8, kept, policies) != null);
    try testing.expect(std.mem.indexOf(u8, kept, "\"ackDeadlineSeconds\":60,") != null);
    // Exactly-once delivery is turned on and off by an update, and the
    // deadline stays what it was.
    try testing.expectEqualStrings(
        \\{"name":"projects/p/subscriptions/zigps-eo","topic":"projects/p/topics/zigps-a","pushConfig":{"attributes":{"x-goog-version":"v1"}},"ackDeadlineSeconds":60,"messageRetentionDuration":"604800s","expirationPolicy":{"ttl":"2678400s"},"state":"ACTIVE"}
    , (try b.raw(a, .PATCH, "projects/p/subscriptions/zigps-eo", "{\"subscription\":{},\"updateMask\":\"enableExactlyOnceDelivery\"}")).body);
    try testing.expect(std.mem.indexOf(u8, (try b.raw(a, .PATCH, "projects/p/subscriptions/zigps-dl", "{\"subscription\":{\"enableExactlyOnceDelivery\":true},\"updateMask\":\"enable_exactly_once_delivery\"}")).body, "\"ackDeadlineSeconds\":10,\"messageRetentionDuration\":\"604800s\",\"expirationPolicy\":{\"ttl\":\"2678400s\"},\"deadLetterPolicy\":{\"deadLetterTopic\":\"projects/p/topics/zigps-b\",\"maxDeliveryAttempts\":5},\"enableExactlyOnceDelivery\":true,\"state\"") != null);
    // A deadline that is said is kept with exactly-once delivery too.
    try testing.expect(std.mem.indexOf(u8, (try b.raw(a, .PUT, "projects/p/subscriptions/zigps-eo10", "{" ++ topic ++ ",\"ackDeadlineSeconds\":10,\"enableExactlyOnceDelivery\":true}")).body, "\"ackDeadlineSeconds\":10,") != null);

    // Through the client.
    var made = try b.client.subscription("worker").create(.{
        .topic_id = "zigps-a",
        .enable_message_ordering = true,
        .enable_exactly_once_delivery = true,
        .filter = "attributes:k",
        .dead_letter_policy = .{ .topic = "zigps-b", .max_delivery_attempts = 9 },
        .retry_policy = .{ .minimum = .fromSeconds(1), .maximum = .fromSeconds(2) },
    });
    defer made.deinit();
    try testing.expect(made.value.enable_message_ordering);
    try testing.expect(made.value.enable_exactly_once_delivery);
    try testing.expectEqualStrings("attributes:k", made.value.filter);
    try testing.expectEqualStrings("projects/p/topics/zigps-b", made.value.dead_letter_policy.?.topic);
    try testing.expectEqual(9, made.value.dead_letter_policy.?.max_delivery_attempts);
    try testing.expectEqual(std.Io.Duration.fromSeconds(1), made.value.retry_policy.?.minimum);
    try testing.expectEqual(std.Io.Duration.fromSeconds(2), made.value.retry_policy.?.maximum);
    try testing.expectEqual(60, made.value.ack_deadline_seconds);
    try testing.expectError(error.InvalidArgument, b.client.subscription("mixed").create(.{ .topic_id = "zigps-a", .filter = "attributes:a AND attributes:b OR attributes:c" }));
    try testing.expectEqualStrings("Invalid filter expression: failed to parse (syntax error at line 1, column 31, token 'OR').", b.diag.message());
    try testing.expectError(error.InvalidArgument, b.client.subscription("bare").create(.{ .topic_id = "zigps-a", .filter = "order" }));
    try testing.expectError(error.Unimplemented, b.client.subscription("twice").create(.{ .topic_id = "zigps-a", .filter = "--attributes:k" }));
}

test "a filter: a subscription holds what passes it, of what is published and of what is forwarded to its topic" {
    var b: Bench = undefined;
    try b.init(.{ .shuffle = false });
    defer b.deinit();
    for ([_][]const u8{ "orders", "dead" }) |id| {
        var made = try b.client.topic(id).create(.{});
        made.deinit();
    }
    for ([_]struct { []const u8, types.SubscriptionConfig }{
        .{ "everything", .{ .topic_id = "orders" } },
        .{ "eu-orders", .{ .topic_id = "orders", .filter = "attributes.kind = \"order\" AND attributes.region = \"eu\"" } },
        .{ "not-orders", .{ .topic_id = "orders", .filter = "NOT attributes.kind = \"order\"" } },
        .{ "poison", .{ .topic_id = "orders", .filter = "hasPrefix(attributes.kind, \"ref\")", .dead_letter_policy = .{ .topic = "dead" } } },
        .{ "dead-refunds", .{ .topic_id = "dead", .filter = "attributes.CloudPubSubDeadLetterSourceDeliveryCount = \"5\" AND attributes.kind = \"refund\"" } },
        .{ "dead-orders", .{ .topic_id = "dead", .filter = "attributes.kind = \"order\"" } },
    }) |case| {
        var made = try b.client.subscription(case[0]).create(case[1]);
        made.deinit();
    }
    // The eight messages production was sent under each of its filters.
    const sent = [_]types.Message{
        .{ .data = "m1", .attributes = &.{ .{ .key = "kind", .value = "order" }, .{ .key = "region", .value = "eu" } } },
        .{ .data = "m2", .attributes = &.{ .{ .key = "kind", .value = "order" }, .{ .key = "region", .value = "us" } } },
        .{ .data = "m3", .attributes = &.{ .{ .key = "kind", .value = "refund" }, .{ .key = "region", .value = "eu" } } },
        .{ .data = "m4", .attributes = &.{.{ .key = "region", .value = "us" }} },
        .{ .data = "m5", .attributes = &.{.{ .key = "kind", .value = "" }} },
        .{ .data = "m6" },
        .{ .data = "m7", .attributes = &.{ .{ .key = "kind", .value = "ORDER" }, .{ .key = "KIND", .value = "order" } } },
        .{ .data = "m8", .attributes = &.{ .{ .key = "kind", .value = "a\"b" }, .{ .key = "a b", .value = "x" } } },
    };
    var published = try b.client.topic("orders").publish(&sent, .{});
    published.deinit();
    try testing.expectEqual(8, b.fake.publishedCount("p", "orders"));
    // What does not pass is never held: it is no backlog, and never comes.
    try testing.expectEqual(8, b.fake.backlog("p", "everything"));
    try testing.expectEqual(1, b.fake.backlog("p", "eu-orders"));
    try testing.expectEqual(6, b.fake.backlog("p", "not-orders"));
    try testing.expectEqual(1, b.fake.backlog("p", "poison"));
    var got = try b.client.subscription("eu-orders").pull(.{});
    defer got.deinit();
    try testing.expectEqual(1, got.value.messages.len);
    try testing.expectEqualStrings("m1", got.value.messages[0].data);
    var others = try b.client.subscription("not-orders").pull(.{});
    defer others.deinit();
    try testing.expectEqual(6, others.value.messages.len);
    for (others.value.messages, [_][]const u8{ "m3", "m4", "m5", "m6", "m7", "m8" }) |m, data| try testing.expectEqualStrings(data, m.data);

    // A dead letter is a message to the dead-letter topic like any other:
    // its subscriptions' filters are tried on it, the attributes that mark
    // it included.
    for (0..5) |_| {
        var refund = try b.client.subscription("poison").pull(.{});
        defer refund.deinit();
        try testing.expectEqualStrings("m3", refund.value.messages[0].data);
        try b.client.subscription("poison").nack(&.{refund.value.messages[0].ack_id});
    }
    try testing.expectEqual(0, b.fake.backlog("p", "poison"));
    try testing.expectEqual(1, b.fake.publishedCount("p", "dead"));
    try testing.expectEqual(1, b.fake.backlog("p", "dead-refunds"));
    try testing.expectEqual(0, b.fake.backlog("p", "dead-orders"));
}

test "ordering keys: a key gives what it has waiting together and in order, and no more until that is acknowledged or comes back" {
    for ([_]bool{ true, false }) |shuffle| {
        var b: Bench = undefined;
        try b.init(.{ .shuffle = shuffle });
        defer b.deinit();
        var scratch: std.heap.ArenaAllocator = .init(testing.allocator);
        defer scratch.deinit();
        const a = scratch.allocator();
        const orders = b.client.topic("orders");
        var made = try orders.create(.{});
        made.deinit();
        const ordered = b.client.subscription("ordered");
        const plain = b.client.subscription("plain");
        var first_made = try ordered.create(.{ .topic_id = "orders", .enable_message_ordering = true });
        first_made.deinit();
        var second_made = try plain.create(.{ .topic_id = "orders" });
        second_made.deinit();
        var published: usize = 0;

        // As production was put to it on 2026-10-12: one of a key out,
        // and then a second published. The second waited fourteen seconds
        // behind the first, and came a second after the first's ack.
        var k1 = try orders.publish(&.{.{ .data = "k1" }}, .{ .ordering_key = "k" });
        k1.deinit();
        var first = try ordered.pull(.{});
        defer first.deinit();
        try testing.expectEqualStrings("k1", first.value.messages[0].data);
        try testing.expectEqualStrings("k", first.value.messages[0].ordering_key);
        var k2 = try orders.publish(&.{.{ .data = "k2" }}, .{ .ordering_key = "k" });
        k2.deinit();
        try expectNothing(ordered);
        // Another key, and a message with none, wait for nothing.
        var j1 = try orders.publish(&.{.{ .data = "j1" }}, .{ .ordering_key = "j" });
        j1.deinit();
        var free1 = try orders.publish(&.{.{ .data = "free1" }}, .{});
        free1.deinit();
        {
            var others = try ordered.pull(.{});
            defer others.deinit();
            try testing.expectEqual(2, others.value.messages.len);
            for (others.value.messages) |m| {
                try testing.expect(m.data[0] != 'k');
                try ordered.ack(&.{m.ack_id});
            }
        }
        b.advance(9);
        try expectNothing(ordered);
        try testing.expectEqual(2, b.fake.backlog("p", "ordered"));
        try ordered.ack(&.{first.value.messages[0].ack_id});
        {
            var second = try ordered.pull(.{});
            defer second.deinit();
            try testing.expectEqual(1, second.value.messages.len);
            try testing.expectEqualStrings("k2", second.value.messages[0].data);
            try ordered.ack(&.{second.value.messages[0].ack_id});
        }
        published += 4;

        // Three of a key published together came together, in order. With
        // the first acknowledged and the second given back, the second and
        // the third came again together: the third was out, and was taken
        // back with the second.
        var three = try orders.publish(&.{ .{ .data = "m1" }, .{ .data = "m2" }, .{ .data = "m3" } }, .{ .ordering_key = "m" });
        three.deinit();
        published += 3;
        {
            var got = try ordered.pull(.{});
            defer got.deinit();
            try testing.expectEqual(3, got.value.messages.len);
            for (got.value.messages, [_][]const u8{ "m1", "m2", "m3" }) |m, data| try testing.expectEqualStrings(data, m.data);
            try ordered.ack(&.{got.value.messages[0].ack_id});
            try expectNothing(ordered);
            try ordered.nack(&.{got.value.messages[1].ack_id});
            try testing.expectEqual(2, b.fake.backlog("p", "ordered"));
            try testing.expectEqual(0, b.fake.outstanding("p", "ordered"));
            var again = try ordered.pull(.{});
            defer again.deinit();
            try testing.expectEqual(2, again.value.messages.len);
            for (again.value.messages, [_][]const u8{ "m2", "m3" }) |m, data| try testing.expectEqualStrings(data, m.data);
            try ordered.ack(&.{ again.value.messages[0].ack_id, again.value.messages[1].ack_id });
            try testing.expectEqual(0, b.fake.backlog("p", "ordered"));
        }

        // Production's first case: five of a key, all acknowledged but the
        // second, and the second nacked. It came again with the third,
        // fourth and fifth, acknowledged though they were.
        var five = try orders.publish(&.{ .{ .data = "n1" }, .{ .data = "n2" }, .{ .data = "n3" }, .{ .data = "n4" }, .{ .data = "n5" } }, .{ .ordering_key = "n" });
        five.deinit();
        published += 5;
        {
            var got = try ordered.pull(.{});
            defer got.deinit();
            try testing.expectEqual(5, got.value.messages.len);
            const ids = got.value.messages;
            try ordered.ack(&.{ ids[4].ack_id, ids[0].ack_id, ids[2].ack_id, ids[3].ack_id });
            try testing.expectEqual(1, b.fake.backlog("p", "ordered"));
            try testing.expectEqual(1, b.fake.outstanding("p", "ordered"));
            try ordered.nack(&.{ids[1].ack_id});
            try testing.expectEqual(4, b.fake.backlog("p", "ordered"));
            try testing.expectEqual(0, b.fake.outstanding("p", "ordered"));
            var again = try ordered.pull(.{});
            defer again.deinit();
            try testing.expectEqual(4, again.value.messages.len);
            for (again.value.messages, [_][]const u8{ "n2", "n3", "n4", "n5" }) |m, data| try testing.expectEqualStrings(data, m.data);
            // Acknowledged behind one that is not, the later ones are kept
            // back, and not counted.
            const later = again.value.messages;
            try ordered.ack(&.{ later[3].ack_id, later[1].ack_id, later[2].ack_id });
            try testing.expectEqual(1, b.fake.backlog("p", "ordered"));
            // A second ack of one of those, and a lease change, are
            // answered and forgotten.
            try ordered.ack(&.{later[2].ack_id});
            try ordered.modifyAckDeadline(&.{later[2].ack_id}, 30);
            try ordered.nack(&.{later[3].ack_id});
            try testing.expectEqual(1, b.fake.backlog("p", "ordered"));
            // With the second acknowledged all four are gone.
            try ordered.ack(&.{later[0].ack_id});
            try testing.expectEqual(0, b.fake.backlog("p", "ordered"));
            b.advance(700);
            try expectNothing(ordered);
        }

        // A lapse does as a nack does: all three of a key came again in
        // production, none acknowledged.
        var more = try orders.publish(&.{ .{ .data = "k6" }, .{ .data = "k7" }, .{ .data = "k8" } }, .{ .ordering_key = "k" });
        more.deinit();
        published += 3;
        for (0..2) |_| {
            var got = try ordered.pull(.{});
            defer got.deinit();
            try testing.expectEqual(3, got.value.messages.len);
            for (got.value.messages, [_][]const u8{ "k6", "k7", "k8" }) |m, data| try testing.expectEqualStrings(data, m.data);
            try expectNothing(ordered);
            b.advance(10);
        }
        // With the later two acknowledged, the lapse of the first brings
        // all three: an acknowledged message is given a second time.
        {
            var got = try ordered.pull(.{});
            defer got.deinit();
            try ordered.ack(&.{ got.value.messages[2].ack_id, got.value.messages[1].ack_id });
            try testing.expectEqual(1, b.fake.backlog("p", "ordered"));
            b.advance(10);
            try testing.expectEqual(3, b.fake.backlog("p", "ordered"));
        }
        {
            // The first, acknowledged, is gone for good. Of the two left,
            // the lapse of the earlier takes the later back out of a
            // longer lease.
            var got = try ordered.pull(.{});
            defer got.deinit();
            try testing.expectEqual(3, got.value.messages.len);
            try ordered.ack(&.{got.value.messages[0].ack_id});
            try testing.expectEqual(2, b.fake.backlog("p", "ordered"));
            try ordered.modifyAckDeadline(&.{got.value.messages[2].ack_id}, 600);
            b.advance(10);
            try testing.expectEqual(0, b.fake.outstanding("p", "ordered"));
            var both = try ordered.pull(.{});
            defer both.deinit();
            try testing.expectEqual(2, both.value.messages.len);
            for (both.value.messages, [_][]const u8{ "k7", "k8" }) |m, data| try testing.expectEqualStrings(data, m.data);
            // The other way about, a later one's lapse leaves the earlier
            // out, and the later one waits behind it.
            try ordered.modifyAckDeadline(&.{both.value.messages[0].ack_id}, 600);
            b.advance(10);
            try testing.expectEqual(1, b.fake.outstanding("p", "ordered"));
            try expectNothing(ordered);
            try ordered.ack(&.{both.value.messages[0].ack_id});
            var last = try ordered.pull(.{});
            defer last.deinit();
            try testing.expectEqual(1, last.value.messages.len);
            try testing.expectEqualStrings("k8", last.value.messages[0].data);
            try ordered.ack(&.{last.value.messages[0].ack_id});
            try testing.expectEqual(0, b.fake.backlog("p", "ordered"));
        }

        // A pull's limit may cut a key's messages short. The rest wait
        // until every one of those given is acknowledged.
        var cut = try orders.publish(&.{ .{ .data = "q1" }, .{ .data = "q2" }, .{ .data = "q3" } }, .{ .ordering_key = "q" });
        cut.deinit();
        published += 3;
        {
            var got = try ordered.pull(.{ .max_messages = 2 });
            defer got.deinit();
            try testing.expectEqual(2, got.value.messages.len);
            for (got.value.messages, [_][]const u8{ "q1", "q2" }) |m, data| try testing.expectEqualStrings(data, m.data);
            try expectNothing(ordered);
            try ordered.ack(&.{got.value.messages[0].ack_id});
            try expectNothing(ordered);
            try ordered.ack(&.{got.value.messages[1].ack_id});
            var rest = try ordered.pull(.{});
            defer rest.deinit();
            try testing.expectEqual(1, rest.value.messages.len);
            try testing.expectEqualStrings("q3", rest.value.messages[0].data);
            try ordered.ack(&.{rest.value.messages[0].ack_id});
        }

        // Among themselves the keys have no order, nor have the messages
        // with none: one pull gives all nine in an order of the fake's
        // own, each key's still in theirs.
        const Sent = struct { ?[]const u8, []const types.Message };
        for ([_]Sent{
            .{ null, &.{ .{ .data = "f1" }, .{ .data = "f2" }, .{ .data = "f3" } } },
            .{ "x", &.{ .{ .data = "x1" }, .{ .data = "x2" }, .{ .data = "x3" } } },
            .{ "y", &.{ .{ .data = "y1" }, .{ .data = "y2" }, .{ .data = "y3" } } },
        }) |request| {
            var sent = try orders.publish(request[1], .{ .ordering_key = request[0] });
            sent.deinit();
        }
        published += 9;
        {
            var got = try ordered.pull(.{});
            defer got.deinit();
            try testing.expectEqual(9, got.value.messages.len);
            var order: std.ArrayList(u8) = .empty;
            for (got.value.messages) |m| try order.appendSlice(a, m.data);
            for ([_][]const u8{ "x1x2x3", "y1y2y3" }) |key_order| {
                var seen: std.ArrayList(u8) = .empty;
                for (got.value.messages) |m| {
                    if (m.data[0] == key_order[0]) try seen.appendSlice(a, m.data);
                }
                try testing.expectEqualStrings(key_order, seen.items);
            }
            try testing.expectEqual(!shuffle, std.mem.eql(u8, order.items, "f1f2f3x1x2x3y1y2y3"));
            // A message with no key is on its own, with ordering too: its
            // nack brings back no other.
            for (got.value.messages) |m| {
                if (!std.mem.eql(u8, m.data, "f2")) try ordered.ack(&.{m.ack_id});
            }
            for (got.value.messages) |m| {
                if (std.mem.eql(u8, m.data, "f2")) try ordered.nack(&.{m.ack_id});
            }
            try testing.expectEqual(1, b.fake.backlog("p", "ordered"));
        }

        // Without ordering a key means nothing: all come at once, a nack
        // brings back the one message, and what was acknowledged stays so.
        {
            var got = try plain.pull(.{});
            defer got.deinit();
            try testing.expectEqual(published, got.value.messages.len);
            var nacked: []const u8 = "";
            for (got.value.messages) |m| {
                if (std.mem.eql(u8, m.data, "n2")) nacked = m.ack_id else try plain.ack(&.{m.ack_id});
            }
            try plain.nack(&.{nacked});
            try testing.expectEqual(1, b.fake.backlog("p", "plain"));
            var again = try plain.pull(.{});
            defer again.deinit();
            try testing.expectEqual(1, again.value.messages.len);
            try testing.expectEqualStrings("n2", again.value.messages[0].data);
        }
    }
}

test "ordering with exactly-once delivery: a key gives one message at a time, the next after an ack" {
    var b: Bench = undefined;
    try b.init(.{});
    defer b.deinit();
    const orders = b.client.topic("orders");
    var made = try orders.create(.{});
    made.deinit();
    const strict = b.client.subscription("strict");
    var subscribed = try strict.create(.{ .topic_id = "orders", .enable_message_ordering = true, .enable_exactly_once_delivery = true });
    subscribed.deinit();

    // As production did on 2026-10-12, of three published together: the
    // first alone, the second after the first's ack, the second again
    // after its nack, and the third after the second's ack.
    var three = try orders.publish(&.{ .{ .data = "m1" }, .{ .data = "m2" }, .{ .data = "m3" } }, .{ .ordering_key = "m" });
    three.deinit();
    var free = try orders.publish(&.{ .{ .data = "free1" }, .{ .data = "free2" } }, .{});
    free.deinit();
    var other = try orders.publish(&.{ .{ .data = "j1" }, .{ .data = "j2" } }, .{ .ordering_key = "j" });
    other.deinit();
    var held: []const u8 = "";
    {
        // The first of each key, and every message with none.
        var got = try strict.pull(.{});
        defer got.deinit();
        try testing.expectEqual(4, got.value.messages.len);
        for (got.value.messages) |m| {
            if (std.mem.eql(u8, m.data, "m1")) {
                held = try testing.allocator.dupe(u8, m.ack_id);
            } else {
                try testing.expect(std.mem.eql(u8, m.data, "j1") or m.data[0] == 'f');
                if (m.data[0] == 'f') try strict.ack(&.{m.ack_id});
            }
        }
    }
    defer testing.allocator.free(held);
    try testing.expectEqual(5, b.fake.backlog("p", "strict"));
    try testing.expectEqual(2, b.fake.outstanding("p", "strict"));
    b.advance(30);
    try expectNothing(strict);
    try strict.ack(&.{held});
    for ([_][]const u8{ "m2", "m2", "m3" }, 0..) |data, round| {
        var got = try strict.pull(.{});
        defer got.deinit();
        try testing.expectEqual(1, got.value.messages.len);
        try testing.expectEqualStrings(data, got.value.messages[0].data);
        try expectNothing(strict);
        if (round == 0) try strict.nack(&.{got.value.messages[0].ack_id}) else try strict.ack(&.{got.value.messages[0].ack_id});
    }
    // The other key's first lapses, and comes again alone.
    try testing.expectEqual(2, b.fake.backlog("p", "strict"));
    b.advance(30);
    var again = try strict.pull(.{});
    defer again.deinit();
    try testing.expectEqual(1, again.value.messages.len);
    try testing.expectEqualStrings("j1", again.value.messages[0].data);
}

test "dead letters: every delivery is an attempt, sent with a policy alone, and after the last the message moves to the dead-letter topic" {
    var b: Bench = undefined;
    try b.init(.{});
    defer b.deinit();
    var scratch: std.heap.ArenaAllocator = .init(testing.allocator);
    defer scratch.deinit();
    const a = scratch.allocator();
    for ([_][]const u8{ "orders", "dead", "ring" }) |id| {
        var made = try b.client.topic(id).create(.{});
        made.deinit();
    }
    const worker = b.client.subscription("worker");
    const morgue = b.client.subscription("morgue");
    for ([_]struct { []const u8, types.SubscriptionConfig }{
        .{ "worker", .{ .topic_id = "orders", .dead_letter_policy = .{ .topic = "dead" } } },
        .{ "plain", .{ .topic_id = "orders" } },
        .{ "morgue", .{ .topic_id = "dead" } },
        .{ "loop", .{ .topic_id = "ring", .dead_letter_policy = .{ .topic = "ring", .max_delivery_attempts = 6 } } },
    }) |case| {
        var made = try b.client.subscription(case[0]).create(case[1]);
        made.deinit();
    }
    b.advance(40);
    var sent = try b.client.topic("orders").publish(&.{.{ .data = "poison", .attributes = &.{.{ .key = "kind", .value = "order" }} }}, .{ .ordering_key = "o" });
    sent.deinit();
    b.advance(2);

    // Nacked each time, as production counted them: 1 to 5. With no
    // policy no attempt is sent at all.
    try testing.expect(std.mem.indexOf(u8, (try b.raw(a, .POST, "projects/p/subscriptions/plain:pull", "{\"maxMessages\":1}")).body, "deliveryAttempt") == null);
    for (1..6) |attempt| {
        try testing.expectEqual(0, b.fake.backlog("p", "morgue"));
        var got = try worker.pull(.{});
        defer got.deinit();
        try testing.expectEqual(attempt, got.value.messages[0].delivery_attempt);
        try worker.nack(&.{got.value.messages[0].ack_id});
    }
    // After the fifth it is forwarded, and comes here no more.
    try testing.expectEqual(0, b.fake.backlog("p", "worker"));
    try expectNothing(worker);
    try testing.expectEqual(1, b.fake.publishedCount("p", "dead"));
    {
        // As production marked one: a new id, its own data and attributes,
        // and where it came from.
        var got = try morgue.pull(.{});
        defer got.deinit();
        const m = got.value.messages[0];
        try testing.expectEqualStrings("poison", m.data);
        try testing.expectEqualStrings("2", m.message_id);
        try testing.expectEqualStrings("o", m.ordering_key);
        try testing.expectEqual(5, m.attributes.len);
        try testing.expectEqualStrings("order", m.attribute("kind").?);
        try testing.expectEqualStrings("5", m.attribute("CloudPubSubDeadLetterSourceDeliveryCount").?);
        try testing.expectEqualStrings("worker", m.attribute("CloudPubSubDeadLetterSourceSubscription").?);
        try testing.expectEqualStrings("p", m.attribute("CloudPubSubDeadLetterSourceSubscriptionProject").?);
        try testing.expectEqualStrings("1970-01-01T00:00:40Z", m.attribute("CloudPubSubDeadLetterSourceTopicPublishTime").?);
        // Published when it was forwarded, and delivered like any other.
        try testing.expectEqualStrings("1970-01-01T00:00:42Z", m.publish_time);
        try testing.expectEqual(0, m.delivery_attempt);
        try morgue.ack(&.{m.ack_id});
    }

    // A lapse is an attempt as a nack is: the fifth lease to run out
    // forwards the message, at the moment it runs out.
    var slow = try b.client.topic("orders").publish(&.{.{ .data = "slow" }}, .{});
    slow.deinit();
    for (1..6) |attempt| {
        var got = try worker.pull(.{});
        defer got.deinit();
        try testing.expectEqual(attempt, got.value.messages[0].delivery_attempt);
        b.advance(9);
        try testing.expectEqual(1, b.fake.backlog("p", "worker"));
        try testing.expectEqual(0, b.fake.backlog("p", "morgue"));
        b.advance(1);
    }
    // Whatever is asked first after the lapse finds it forwarded.
    try testing.expectEqual(2, b.fake.publishedCount("p", "dead"));
    try testing.expectEqual(0, b.fake.backlog("p", "worker"));
    try testing.expectEqual(1, b.fake.backlog("p", "morgue"));
    // An ack in time ends it: four attempts and an ack forward nothing.
    var fine = try b.client.topic("orders").publish(&.{.{ .data = "fine" }}, .{});
    fine.deinit();
    for (1..5) |attempt| {
        var got = try worker.pull(.{});
        defer got.deinit();
        try testing.expectEqual(attempt, got.value.messages[0].delivery_attempt);
        if (attempt < 4) try worker.nack(&.{got.value.messages[0].ack_id}) else try worker.ack(&.{got.value.messages[0].ack_id});
    }
    try testing.expectEqual(0, b.fake.backlog("p", "worker"));
    try testing.expectEqual(2, b.fake.publishedCount("p", "dead"));

    // What time has done is done before a request is served: a publish
    // that comes after the last lapse gets an id after the dead letter's.
    var slower = try b.client.topic("orders").publish(&.{.{ .data = "slower" }}, .{});
    defer slower.deinit();
    for (1..6) |attempt| {
        var got = try worker.pull(.{});
        defer got.deinit();
        try testing.expectEqual(attempt, got.value.messages[0].delivery_attempt);
        b.advance(10);
    }
    var next = try b.client.topic("orders").publish(&.{.{ .data = "next" }}, .{});
    defer next.deinit();
    try testing.expectEqual(try std.fmt.parseInt(u64, slower.value.message_ids[0], 10) + 2, try std.fmt.parseInt(u64, next.value.message_ids[0], 10));
    {
        var got = try worker.pull(.{});
        defer got.deinit();
        try testing.expectEqualStrings("next", got.value.messages[0].data);
        try worker.ack(&.{got.value.messages[0].ack_id});
    }
    try testing.expectEqual(3, b.fake.publishedCount("p", "dead"));

    // With the dead-letter topic gone the message goes on coming, as
    // production's did for want of the grants: a sixth time, a seventh.
    try b.client.topic("dead").delete();
    var stuck = try b.client.topic("orders").publish(&.{.{ .data = "stuck" }}, .{});
    stuck.deinit();
    for (1..8) |attempt| {
        var got = try worker.pull(.{});
        defer got.deinit();
        try testing.expectEqual(attempt, got.value.messages[0].delivery_attempt);
        try worker.nack(&.{got.value.messages[0].ack_id});
    }
    try testing.expectEqual(1, b.fake.backlog("p", "worker"));
    // A policy names its topic: one made again under the name gets the
    // next that is released. The old one's subscription gets nothing.
    var remade = try b.client.topic("dead").create(.{});
    remade.deinit();
    try testing.expectEqual(1, b.fake.backlog("p", "worker"));
    {
        var got = try worker.pull(.{});
        defer got.deinit();
        try testing.expectEqual(8, got.value.messages[0].delivery_attempt);
        b.advance(10);
    }
    try testing.expectEqual(0, b.fake.backlog("p", "worker"));
    try testing.expectEqual(1, b.fake.publishedCount("p", "dead"));
    try testing.expectEqual(2, b.fake.backlog("p", "morgue"));

    // A policy set by an update counts the deliveries made before it, and
    // one taken away sends no more attempts.
    var late = try b.client.topic("orders").publish(&.{.{ .data = "late" }}, .{});
    late.deinit();
    try testing.expectEqual(200, (try b.raw(a, .PATCH, "projects/p/subscriptions/worker", "{\"subscription\":{},\"updateMask\":\"deadLetterPolicy\"}")).status);
    for (0..6) |_| {
        var got = try worker.pull(.{});
        defer got.deinit();
        try testing.expectEqual(0, got.value.messages[0].delivery_attempt);
        try worker.nack(&.{got.value.messages[0].ack_id});
    }
    try testing.expectEqual(200, (try b.raw(a, .PATCH, "projects/p/subscriptions/worker", "{\"subscription\":{\"deadLetterPolicy\":{\"deadLetterTopic\":\"projects/p/topics/dead\",\"maxDeliveryAttempts\":8}},\"updateMask\":\"deadLetterPolicy\"}")).status);
    for (7..9) |attempt| {
        try testing.expectEqual(1, b.fake.backlog("p", "worker"));
        var got = try worker.pull(.{});
        defer got.deinit();
        try testing.expectEqual(attempt, got.value.messages[0].delivery_attempt);
        try worker.nack(&.{got.value.messages[0].ack_id});
    }
    try testing.expectEqual(0, b.fake.backlog("p", "worker"));
    try testing.expectEqual(2, b.fake.publishedCount("p", "dead"));

    // Dead letters to its own topic, which production takes: the message
    // comes round again as a new one, counted from one.
    var round = try b.client.topic("ring").publish(&.{.{ .data = "round" }}, .{});
    defer round.deinit();
    const loop = b.client.subscription("loop");
    for (1..7) |attempt| {
        var got = try loop.pull(.{});
        defer got.deinit();
        try testing.expectEqualStrings(round.value.message_ids[0], got.value.messages[0].message_id);
        try testing.expectEqual(attempt, got.value.messages[0].delivery_attempt);
        try loop.nack(&.{got.value.messages[0].ack_id});
    }
    try testing.expectEqual(2, b.fake.publishedCount("p", "ring"));
    try testing.expectEqual(1, b.fake.backlog("p", "loop"));
    var returned = try loop.pull(.{});
    defer returned.deinit();
    try testing.expect(!std.mem.eql(u8, round.value.message_ids[0], returned.value.messages[0].message_id));
    try testing.expectEqualStrings("round", returned.value.messages[0].data);
    try testing.expectEqual(1, returned.value.messages[0].delivery_attempt);
    try testing.expectEqualStrings("6", returned.value.messages[0].attribute("CloudPubSubDeadLetterSourceDeliveryCount").?);
    try testing.expectEqualStrings("loop", returned.value.messages[0].attribute("CloudPubSubDeadLetterSourceSubscription").?);
}

test "a retry policy: a message given back or lapsed waits out its backoff, and with ordering holds its key behind it" {
    var b: Bench = undefined;
    try b.init(.{ .shuffle = false });
    defer b.deinit();
    var made = try b.client.topic("orders").create(.{});
    made.deinit();
    const slow = b.client.subscription("slow");
    const fast = b.client.subscription("fast");
    const none = b.client.subscription("none");
    for ([_]struct { []const u8, types.SubscriptionConfig }{
        .{ "slow", .{ .topic_id = "orders", .retry_policy = .{ .minimum = .fromSeconds(10), .maximum = .fromSeconds(20) } } },
        .{ "fast", .{ .topic_id = "orders", .retry_policy = .{ .minimum = .zero, .maximum = .fromSeconds(600) } } },
        .{ "none", .{ .topic_id = "orders" } },
    }) |case| {
        var subscribed = try b.client.subscription(case[0]).create(case[1]);
        subscribed.deinit();
    }
    var sent = try b.client.topic("orders").publish(&.{.{ .data = "m" }}, .{});
    sent.deinit();

    // Without a policy, and with one of no seconds, it comes again at
    // once. (Production's came about two seconds on, its own delay.)
    for ([_]@TypeOf(none){ none, fast }) |sub| {
        for (0..3) |_| {
            var got = try sub.pull(.{});
            defer got.deinit();
            try testing.expectEqual(1, got.value.messages.len);
            try sub.nack(&.{got.value.messages[0].ack_id});
        }
    }

    // 10 to 20 seconds: the minimum after the first delivery, twice that
    // after the second, and no more than the maximum after the third.
    for ([_]i64{ 10, 20, 20 }) |backoff| {
        var got = try slow.pull(.{});
        defer got.deinit();
        try testing.expectEqual(1, got.value.messages.len);
        try slow.nack(&.{got.value.messages[0].ack_id});
        try expectNothing(slow);
        b.advance(backoff - 1);
        try expectNothing(slow);
        // Waiting, it is held and not out.
        try testing.expectEqual(1, b.fake.backlog("p", "slow"));
        try testing.expectEqual(0, b.fake.outstanding("p", "slow"));
        b.advance(1);
    }
    // After a lapse the backoff runs from the lapse, whenever that is
    // noticed: a 10 second lease, then 20 seconds more.
    {
        var got = try slow.pull(.{});
        defer got.deinit();
        try testing.expectEqual(1, got.value.messages.len);
        b.advance(29);
        try expectNothing(slow);
        b.advance(1);
        var again = try slow.pull(.{});
        defer again.deinit();
        try testing.expectEqual(1, again.value.messages.len);
        // An ack with an id of an earlier delivery ends it all the same.
        try slow.ack(&.{got.value.messages[0].ack_id});
        try testing.expectEqual(0, b.fake.backlog("p", "slow"));
    }

    // With ordering, a message waiting out its backoff holds the later
    // ones of its key behind it, and no other.
    const ordered = b.client.subscription("ordered");
    var subscribed = try ordered.create(.{ .topic_id = "orders", .enable_message_ordering = true, .retry_policy = .{ .minimum = .fromSeconds(10), .maximum = .fromSeconds(20) } });
    subscribed.deinit();
    var keyed = try b.client.topic("orders").publish(&.{ .{ .data = "r1" }, .{ .data = "r2" } }, .{ .ordering_key = "r" });
    keyed.deinit();
    {
        var got = try ordered.pull(.{});
        defer got.deinit();
        try testing.expectEqual(2, got.value.messages.len);
        try ordered.nack(&.{got.value.messages[0].ack_id});
        // r2 was taken back with r1, and is not given past it.
        try expectNothing(ordered);
        var other = try b.client.topic("orders").publish(&.{.{ .data = "s1" }}, .{ .ordering_key = "s" });
        other.deinit();
        var free = try b.client.topic("orders").publish(&.{.{ .data = "free" }}, .{});
        free.deinit();
        var unheld = try ordered.pull(.{});
        defer unheld.deinit();
        try testing.expectEqual(2, unheld.value.messages.len);
        try testing.expectEqualStrings("s1", unheld.value.messages[0].data);
        try testing.expectEqualStrings("free", unheld.value.messages[1].data);
        b.advance(9);
        try expectNothing(ordered);
        b.advance(1);
        var again = try ordered.pull(.{});
        defer again.deinit();
        try testing.expectEqual(2, again.value.messages.len);
        try testing.expectEqualStrings("r1", again.value.messages[0].data);
        try testing.expectEqualStrings("r2", again.value.messages[1].data);
    }
}

test "a retry policy: a held pull waits a backoff out on the fake's clock" {
    var b: Bench = undefined;
    try b.init(.{ .empty_pull_hold = .fromSeconds(30) });
    defer b.deinit();
    var made = try b.client.topic("orders").create(.{});
    made.deinit();
    const slow = b.client.subscription("slow");
    var subscribed = try slow.create(.{ .topic_id = "orders", .retry_policy = .{ .minimum = .fromSeconds(10), .maximum = .fromSeconds(20) }, .dead_letter_policy = .{ .topic = "orders" } });
    subscribed.deinit();
    var sent = try b.client.topic("orders").publish(&.{.{ .data = "m" }}, .{});
    sent.deinit();
    var got = try slow.pull(.{});
    defer got.deinit();
    try slow.nack(&.{got.value.messages[0].ack_id});
    const before = b.clock.now_ns;
    var again = try slow.pull(.{});
    defer again.deinit();
    try testing.expectEqual(1, again.value.messages.len);
    try testing.expectEqual(2, again.value.messages[0].delivery_attempt);
    try testing.expectEqual(10 * std.time.ns_per_s, b.clock.now_ns - before);
    // A lease that lapses while a pull is held is settled as at any other
    // time: its backoff runs from the lapse, 10 seconds in and 20 long.
    const then = b.clock.now_ns;
    var third = try slow.pull(.{});
    defer third.deinit();
    try testing.expectEqual(1, third.value.messages.len);
    try testing.expectEqual(3, third.value.messages[0].delivery_attempt);
    try testing.expectEqual(30 * std.time.ns_per_s, b.clock.now_ns - then);
}

test "retention: a message older than the subscription keeps messages is gone, out on a lease or not" {
    var b: Bench = undefined;
    try b.init(.{});
    defer b.deinit();
    var made = try b.client.topic("orders").create(.{});
    made.deinit();
    const brief = b.client.subscription("brief");
    var first_made = try brief.create(.{ .topic_id = "orders", .message_retention = .fromSeconds(600) });
    first_made.deinit();
    var second_made = try b.client.subscription("week").create(.{ .topic_id = "orders" });
    second_made.deinit();
    var first = try b.client.topic("orders").publish(&.{.{ .data = "a" }}, .{});
    first.deinit();
    b.advance(300);
    var second = try b.client.topic("orders").publish(&.{.{ .data = "b" }}, .{});
    second.deinit();

    var got = try brief.pull(.{});
    defer got.deinit();
    try testing.expectEqual(2, got.value.messages.len);
    const a_first: usize = if (std.mem.eql(u8, got.value.messages[0].data, "a")) 0 else 1;
    try brief.modifyAckDeadline(&.{ got.value.messages[0].ack_id, got.value.messages[1].ack_id }, 600);
    b.advance(299);
    try testing.expectEqual(2, b.fake.backlog("p", "brief"));
    // Ten minutes after it was published the first is gone, though out.
    b.advance(1);
    try testing.expectEqual(1, b.fake.backlog("p", "brief"));
    try testing.expectEqual(1, b.fake.outstanding("p", "brief"));
    // An ack of it, and a nack, are answered and forgotten.
    try brief.ack(&.{got.value.messages[a_first].ack_id});
    try brief.nack(&.{got.value.messages[a_first].ack_id});
    try testing.expectEqual(1, b.fake.backlog("p", "brief"));
    // The second, given back, waits; and at its ten minutes is gone too.
    try brief.nack(&.{got.value.messages[1 - a_first].ack_id});
    b.advance(299);
    try testing.expectEqual(1, b.fake.backlog("p", "brief"));
    b.advance(1);
    try testing.expectEqual(0, b.fake.backlog("p", "brief"));
    try expectNothing(brief);
    // The other subscription keeps its own time: seven days.
    try testing.expectEqual(2, b.fake.backlog("p", "week"));
    b.advance(604_800 - 900 - 1);
    try testing.expectEqual(2, b.fake.backlog("p", "week"));
    b.advance(1);
    try testing.expectEqual(1, b.fake.backlog("p", "week"));
    b.advance(300);
    try testing.expectEqual(0, b.fake.backlog("p", "week"));
}

test "exactly-once delivery: an ack or a lease change that comes too late is refused, id by id, in production's words" {
    var b: Bench = undefined;
    try b.init(.{ .shuffle = false });
    defer b.deinit();
    var scratch: std.heap.ArenaAllocator = .init(testing.allocator);
    defer scratch.deinit();
    const a = scratch.allocator();
    var made = try b.client.topic("orders").create(.{});
    made.deinit();
    const once = b.client.subscription("once");
    var subscribed = try once.create(.{ .topic_id = "orders", .ack_deadline_seconds = 10, .enable_exactly_once_delivery = true });
    subscribed.deinit();
    var sent = try b.client.topic("orders").publish(&.{ .{ .data = "a" }, .{ .data = "b" } }, .{});
    sent.deinit();
    const ack = "projects/p/subscriptions/once:acknowledge";
    const modack = "projects/p/subscriptions/once:modifyAckDeadline";
    // Production's refusal, whole, 2026-09-27.
    const refusal = "{{\"error\":{{\"code\":400,\"message\":\"Some acknowledgement ids in the request were invalid. This could be because the acknowledgement ids have expired or the acknowledgement ids were malformed.\",\"status\":\"INVALID_ARGUMENT\",\"details\":[{{\"@type\":\"type.googleapis.com/google.rpc.ErrorInfo\",\"reason\":\"EXACTLY_ONCE_ACKID_FAILURE\",\"domain\":\"pubsub.googleapis.com\",\"metadata\":{{\"{s}\":\"PERMANENT_FAILURE_INVALID_ACK_ID\"}}}}]}}}}";

    var got = try once.pull(.{});
    defer got.deinit();
    const id_a = got.value.messages[0].ack_id;
    const id_b = got.value.messages[1].ack_id;
    // In time, every call is taken.
    try once.modifyAckDeadline(&.{id_a}, 600);
    b.advance(10);
    // One live id and one lapsed in one ack: refused naming the lapsed
    // one alone, and the live one was taken.
    const mixed = try b.raw(a, .POST, ack, try std.fmt.allocPrint(a, "{{\"ackIds\":[\"{s}\",\"{s}\"]}}", .{ id_a, id_b }));
    try testing.expectEqual(400, mixed.status);
    try testing.expectEqualStrings(try std.fmt.allocPrint(a, refusal, .{id_b}), mixed.body);
    try testing.expectEqual(1, b.fake.backlog("p", "once"));
    // A second ack of an acknowledged message is taken.
    try testing.expectEqualStrings("{}", (try b.raw(a, .POST, ack, try std.fmt.allocPrint(a, "{{\"ackIds\":[\"{s}\"]}}", .{id_a}))).body);
    // A lease change is not: on an acknowledged message, or on a lapsed
    // one, to extend it or to give it back.
    for ([_]struct { []const u8, u32 }{ .{ id_a, 30 }, .{ id_b, 30 }, .{ id_b, 0 } }) |case| {
        const late = try b.raw(a, .POST, modack, try std.fmt.allocPrint(a, "{{\"ackIds\":[\"{s}\"],\"ackDeadlineSeconds\":{d}}}", .{ case[0], case[1] }));
        try testing.expectEqual(400, late.status);
        try testing.expectEqualStrings(try std.fmt.allocPrint(a, refusal, .{case[0]}), late.body);
    }
    // An id that is none is refused in the plain words, with no details.
    try expectRefused(try b.raw(a, .POST, ack, "{\"ackIds\":[\"garbage\"]}"), 400, "INVALID_ARGUMENT", "You have passed an invalid ack ID to the service (ack_id=garbage).");
    try testing.expectEqual(1, b.fake.backlog("p", "once"));

    // The message comes again under a new id, and the old one is no
    // longer its id, out though the message is: the client is told which
    // of its ids were taken.
    var again = try once.pull(.{});
    defer again.deinit();
    try testing.expectEqualStrings("b", again.value.messages[0].data);
    try testing.expectError(error.InvalidArgument, once.ack(&.{id_b}));
    try testing.expectError(error.InvalidArgument, once.modifyAckDeadline(&.{id_b}, 30));
    try testing.expectError(error.InvalidArgument, once.nack(&.{id_b}));
    try testing.expectEqual(1, b.fake.outstanding("p", "once"));
    var results: [2]types.AckResult = undefined;
    try once.ackWithResults(&.{ id_b, again.value.messages[0].ack_id }, &results);
    try testing.expectEqual(types.AckResult.invalid_ack_id, results[0]);
    try testing.expectEqual(types.AckResult.ok, results[1]);
    try testing.expectEqual(0, b.fake.backlog("p", "once"));
    // Acknowledged, the id that acknowledged it is taken again, and the
    // id of the earlier delivery is refused as before: production's
    // answers to both, 2026-10-12.
    try once.ack(&.{again.value.messages[0].ack_id});
    try testing.expectError(error.InvalidArgument, once.ack(&.{id_b}));
    try once.ackWithResults(&.{ again.value.messages[0].ack_id, id_b }, &results);
    try testing.expectEqual(types.AckResult.ok, results[0]);
    try testing.expectEqual(types.AckResult.invalid_ack_id, results[1]);

    // An id twice in a request is named once.
    var third = try b.client.topic("orders").publish(&.{.{ .data = "c" }}, .{});
    third.deinit();
    var pulled = try once.pull(.{});
    defer pulled.deinit();
    const id_c = pulled.value.messages[0].ack_id;
    try once.nack(&.{id_c});
    const twice = try b.raw(a, .POST, ack, try std.fmt.allocPrint(a, "{{\"ackIds\":[\"{s}\",\"{s}\"]}}", .{ id_c, id_c }));
    try testing.expectEqualStrings(try std.fmt.allocPrint(a, refusal, .{id_c}), twice.body);
    const twice_more = try b.raw(a, .POST, modack, try std.fmt.allocPrint(a, "{{\"ackIds\":[\"{s}\",\"{s}\"],\"ackDeadlineSeconds\":5}}", .{ id_c, id_c }));
    try testing.expectEqualStrings(try std.fmt.allocPrint(a, refusal, .{id_c}), twice_more.body);

    // Without exactly-once delivery the same late calls are answered and
    // forgotten, as ever.
    try testing.expectEqual(200, (try b.raw(a, .PATCH, "projects/p/subscriptions/once", "{\"subscription\":{},\"updateMask\":\"enableExactlyOnceDelivery\"}")).status);
    try once.ack(&.{id_c});
    try once.modifyAckDeadline(&.{id_c}, 30);
    try testing.expectEqual(1, b.fake.backlog("p", "once"));
    try testing.expectEqual(0, b.fake.outstanding("p", "once"));
}

test "ids of one request: each is judged as the request finds it, before any of them acts" {
    var b: Bench = undefined;
    try b.init(.{ .shuffle = false });
    defer b.deinit();
    for ([_][]const u8{ "orders", "dead" }) |id| {
        var made = try b.client.topic(id).create(.{});
        made.deinit();
    }
    const worker = b.client.subscription("worker");
    var worker_made = try worker.create(.{ .topic_id = "orders", .enable_message_ordering = true, .dead_letter_policy = .{ .topic = "dead" } });
    worker_made.deinit();
    var morgue_made = try b.client.subscription("morgue").create(.{ .topic_id = "dead" });
    morgue_made.deinit();

    // Two of a key nacked in one request, as production took them: the
    // nack of the first takes the second back with it, and the second's
    // own nack comes no later for that. Each is counted as given back, so
    // that after five rounds both have had their attempts, and both move
    // to the dead-letter topic.
    var pair = try b.client.topic("orders").publish(&.{ .{ .data = "q1" }, .{ .data = "q2" } }, .{ .ordering_key = "q" });
    pair.deinit();
    for (1..6) |attempt| {
        try testing.expectEqual(0, b.fake.backlog("p", "morgue"));
        var got = try worker.pull(.{});
        defer got.deinit();
        try testing.expectEqual(2, got.value.messages.len);
        for (got.value.messages, [_][]const u8{ "q1", "q2" }) |m, data| {
            try testing.expectEqualStrings(data, m.data);
            try testing.expectEqual(attempt, m.delivery_attempt);
        }
        // The first id a second time changes nothing.
        try worker.nack(&.{ got.value.messages[0].ack_id, got.value.messages[1].ack_id, got.value.messages[0].ack_id });
        try testing.expectEqual(0, b.fake.outstanding("p", "worker"));
    }
    try testing.expectEqual(0, b.fake.backlog("p", "worker"));
    try testing.expectEqual(2, b.fake.backlog("p", "morgue"));
}

/// What each subscription should hold, said again in as few lines as it
/// takes: the fake is held to this after every step of a script. Three
/// subscriptions, each with rules of its own. The first has none. The
/// second has ordering, a filter that passes what has no `skip`, and a
/// retry policy of 5 to 20 seconds. The third has ordering, exactly-once
/// delivery, and dead letters to the first topic after five attempts.
const Reference = struct {
    const Held = struct { id: u64, lease_until: ?i96 = null, deliveries: u32 = 0, not_before: i96 = 0, acked: bool = false };
    /// What the rules ask of a message: its ordering key, 0 for none, and
    /// whether the second subscription's filter stops it.
    const Sent = struct { key: u8 = 0, skip: bool = false };
    const max_held = 256;
    const deadline_s = [3]u32{ 10, 20, 10 };
    const ordered = [3]bool{ false, true, true };
    const max_attempts = 5;

    held: [3][max_held]Held = undefined,
    counts: [3]usize = @splat(0),
    /// Which topic a subscription listens to; null once that topic is gone.
    topic: [3]?u8 = .{ 0, 0, 1 },
    /// By message id.
    sent: [2 * max_held]Sent = undefined,
    /// By message id: which delivery's id acknowledged it on the third
    /// subscription. 0: none has.
    acknowledged_by: [2 * max_held]u32 = @splat(0),
    next_id: u64 = 1,

    /// A message comes to a topic, published or forwarded, and gets the
    /// next id.
    fn arrive(r: *Reference, topic: u8, what: Sent) u64 {
        const id = r.next_id;
        r.next_id += 1;
        r.sent[id] = what;
        for (0..3) |s| {
            if (r.topic[s] != topic or (s == 1 and what.skip)) continue;
            r.held[s][r.counts[s]] = .{ .id = id };
            r.counts[s] += 1;
        }
        return id;
    }

    fn all(r: *Reference, s: usize) []Held {
        return r.held[s][0..r.counts[s]];
    }

    fn indexOf(r: *Reference, s: usize, id: u64) ?usize {
        for (r.all(s), 0..) |h, i| {
            if (h.id == id) return i;
        }
        return null;
    }

    /// The key that orders it on subscription `s`, or 0.
    fn key(r: *const Reference, s: usize, h: Held) u8 {
        return if (ordered[s]) r.sent[h.id].key else 0;
    }

    fn remove(r: *Reference, s: usize, index: usize) void {
        const held = r.all(s);
        std.mem.copyForwards(Held, held[index .. held.len - 1], held[index + 1 ..]);
        r.counts[s] -= 1;
    }

    /// A delivery over with no ack, by a nack or a lapse, at `at`. True
    /// when the message moved on to the dead-letter topic.
    fn release(r: *Reference, s: usize, index: usize, at: i96) bool {
        const h = r.held[s][index];
        const gone = s == 2 and h.deliveries >= max_attempts;
        if (gone) {
            r.remove(s, index);
            _ = r.arrive(0, r.sent[h.id]);
        } else {
            r.held[s][index].lease_until = null;
            const doublings: u5 = @intCast(@min(h.deliveries - 1, 3));
            if (s == 1) r.held[s][index].not_before = at + @as(i96, @min(20, @as(u32, 5) << doublings)) * std.time.ns_per_s;
        }
        // The later ones of its key come back with it.
        const k = r.key(s, h);
        if (k != 0) for (r.all(s)[index + @intFromBool(!gone) ..]) |*later| {
            if (r.key(s, later.*) != k) continue;
            later.lease_until = null;
            later.acked = false;
        };
        return gone;
    }

    /// Ends every lease that has run out by `now`: the subscriptions by
    /// name, each one's messages as they came.
    fn settle(r: *Reference, now: i96) void {
        for (0..3) |s| {
            var i: usize = 0;
            while (i < r.counts[s]) {
                if (r.held[s][i].lease_until) |until| {
                    if (until <= now and r.release(s, i, until)) continue;
                }
                i += 1;
            }
        }
    }

    /// Whether a pull may give it at `now`, to which all is settled.
    fn ready(r: *Reference, s: usize, index: usize, now: i96) bool {
        const h = r.held[s][index];
        if (h.acked or h.lease_until != null or h.not_before > now) return false;
        const k = r.key(s, h);
        if (k == 0) return true;
        // A key gives nothing while one of its messages is out.
        for (r.all(s)) |e| {
            if (r.key(s, e) == k and e.lease_until != null) return false;
        }
        // Nor does one come past an earlier one of its key that waits out
        // a backoff. With exactly-once delivery, the third subscription's,
        // none comes past an earlier one at all.
        for (r.all(s)[0..index]) |e| {
            if (r.key(s, e) == k and !e.acked and (s == 2 or e.not_before > now)) return false;
        }
        return true;
    }

    /// Which of subscription `s` a pull may give at `now`, and how many.
    fn readySet(r: *Reference, s: usize, now: i96, set: *[max_held]bool) usize {
        var n: usize = 0;
        for (0..r.counts[s]) |i| {
            set[i] = r.ready(s, i, now);
            n += @intFromBool(set[i]);
        }
        return n;
    }

    fn backlog(r: *Reference, s: usize) usize {
        var n: usize = 0;
        for (r.all(s)) |h| n += @intFromBool(!h.acked);
        return n;
    }

    fn outstanding(r: *Reference, s: usize) usize {
        var n: usize = 0;
        for (r.all(s)) |h| n += @intFromBool(h.lease_until != null);
        return n;
    }

    /// Whether the id of delivery `attempt` may still act on it: it is
    /// out, and with exactly-once delivery this is that delivery.
    fn live(s: usize, h: Held, attempt: u32) bool {
        return h.lease_until != null and (s != 2 or attempt == h.deliveries);
    }

    /// An ack. False when the subscription refuses it.
    fn ack(r: *Reference, s: usize, id: u64, attempt: u32) bool {
        // Gone: with exactly-once delivery taken again only with the id
        // that acknowledged it.
        const index = r.indexOf(s, id) orelse return s != 2 or r.acknowledged_by[id] == attempt;
        const h = &r.held[s][index];
        if (h.acked) return true;
        if (!live(s, h.*, attempt)) return s != 2;
        if (s == 2) r.acknowledged_by[id] = attempt;
        const k = r.key(s, h.*);
        if (k == 0) {
            r.remove(s, index);
            return true;
        }
        // Kept while an earlier one of its key is not acknowledged.
        h.acked = true;
        h.lease_until = null;
        var i: usize = 0;
        while (i < r.counts[s]) {
            const e = r.held[s][i];
            if (r.key(s, e) != k) {
                i += 1;
            } else if (e.acked) r.remove(s, i) else break;
        }
        return true;
    }

    /// A lease change, a nack when `seconds` is 0. False when refused.
    fn modify(r: *Reference, s: usize, id: u64, attempt: u32, seconds: u32, now: i96) bool {
        const index = r.indexOf(s, id) orelse return s != 2;
        const h = &r.held[s][index];
        if (h.acked or !live(s, h.*, attempt)) return s != 2;
        if (seconds == 0) {
            _ = r.release(s, index, now);
        } else h.lease_until = now + @as(i96, seconds) * std.time.ns_per_s;
        return true;
    }
};

const sub_ids = [3][]const u8{ "sub0", "sub1", "sub2" };
const topic_ids = [2][]const u8{ "top0", "top1" };
const key_names = [3]?[]const u8{ null, "a", "b" };

/// Makes subscription `s` of the model on `topic`, with its rules.
fn makeModelSubscription(b: *Bench, s: usize, topic: u8) !void {
    var made = try b.client.subscription(sub_ids[s]).create(switch (s) {
        0 => .{ .topic_id = topic_ids[topic], .ack_deadline_seconds = Reference.deadline_s[0] },
        1 => .{
            .topic_id = topic_ids[topic],
            .ack_deadline_seconds = Reference.deadline_s[1],
            .enable_message_ordering = true,
            .filter = "NOT attributes:skip",
            .retry_policy = .{ .minimum = .fromSeconds(5), .maximum = .fromSeconds(20) },
        },
        else => .{
            .topic_id = topic_ids[topic],
            .ack_deadline_seconds = Reference.deadline_s[2],
            .enable_message_ordering = true,
            .enable_exactly_once_delivery = true,
            .dead_letter_policy = .{ .topic = topic_ids[0], .max_delivery_attempts = Reference.max_attempts },
        },
    });
    made.deinit();
}

/// One pull of the model: as many as the reference has ready, up to
/// `max`, each of them ready, and a key's in their order. Marks them out.
fn modelPull(b: *Bench, ref: *Reference, s: usize, max: u32, deliveries: *std.ArrayList(ModelDelivery), a: Allocator, incarnation: u32) !usize {
    const now = b.clock.now_ns;
    var was_ready: [Reference.max_held]bool = undefined;
    const ready = ref.readySet(s, now, &was_ready);
    var got = try b.client.subscription(sub_ids[s]).pull(.{ .max_messages = max });
    defer got.deinit();
    // No fewer than it has ready, up to what was asked.
    try testing.expectEqual(@min(max, ready), got.value.messages.len);
    for (got.value.messages) |m| {
        const id = try std.fmt.parseInt(u64, m.message_id, 10);
        // Never one it does not hold, and never one that is out,
        // acknowledged, waiting out a backoff, or behind another of its
        // key.
        const index = ref.indexOf(s, id) orelse return error.TestUnexpectedMessage;
        try testing.expect(was_ready[index]);
        const held = &ref.held[s][index];
        try testing.expectEqual(null, held.lease_until);
        // In its key's order: every earlier one of the key that was ready
        // came before it in this pull.
        const k = ref.key(s, held.*);
        if (k != 0) for (ref.all(s)[0..index], was_ready[0..index]) |e, e_ready| {
            if (ref.key(s, e) == k and e_ready) try testing.expect(e.lease_until != null);
        };
        held.lease_until = now + @as(i96, Reference.deadline_s[s]) * std.time.ns_per_s;
        held.deliveries += 1;
        // The attempt is sent with a dead-letter policy alone.
        try testing.expectEqual(if (s == 2) held.deliveries else 0, m.delivery_attempt);
        try testing.expectEqualStrings(key_names[ref.sent[id].key] orelse "", m.ordering_key);
        try testing.expectEqual(ref.sent[id].skip, m.attribute("skip") != null);
        try deliveries.append(a, .{ .sub = s, .incarnation = incarnation, .id = id, .attempt = held.deliveries, .ack_id = try a.dupe(u8, m.ack_id) });
    }
    return got.value.messages.len;
}

/// Every delivery's ack id, with the subscription's incarnation then and
/// which delivery of the message it was.
const ModelDelivery = struct { sub: usize, incarnation: u32, id: u64, attempt: u32, ack_id: []const u8 };

fn modelProperty(_: void, input: []const u8) !void {
    var g: test_util.ByteGen = .init(input);
    // A run is a whole session of calls. The fuzzer makes tens of
    // thousands a night, and the allocator that looks for leaks, which
    // records where each allocation was made, was most of a run's cost:
    // under the fuzzer the session has a plain one. The corpus and the
    // random runs of every test run keep the one that looks.
    const gpa = if (@import("builtin").fuzz) std.heap.smp_allocator else testing.allocator;
    var b: Bench = undefined;
    try b.initIn(gpa, .{ .shuffle = g.boolean() });
    defer b.deinit();
    var scratch: std.heap.ArenaAllocator = .init(gpa);
    defer scratch.deinit();
    const a = scratch.allocator();

    var ref: Reference = .{};
    for (topic_ids) |id| {
        var made = try b.client.topic(id).create(.{});
        made.deinit();
    }
    for (0..3) |s| try makeModelSubscription(&b, s, ref.topic[s].?);
    var deliveries: std.ArrayList(ModelDelivery) = .empty;
    var incarnation: [3]u32 = @splat(0);
    var published: usize = 0;

    var steps: usize = 0;
    while (steps < 60 and g.pos < g.bytes.len) : (steps += 1) {
        const now = b.clock.now_ns;
        switch (g.intRange(u8, 0, 9)) {
            0, 1 => {
                const topic = g.intRange(u8, 0, 1);
                const count = g.intRange(u8, 1, 3);
                // One ordering key a request, as production has it.
                const k = g.intRange(u8, 0, 2);
                if (published + count > Reference.max_held / 2) continue;
                var messages: [3]types.Message = undefined;
                var bufs: [3][8]u8 = undefined;
                var skips: [3]bool = undefined;
                for (messages[0..count], bufs[0..count], skips[0..count]) |*m, *buf, *skip| {
                    skip.* = g.boolean();
                    m.* = .{ .data = try std.fmt.bufPrint(buf, "m{d}", .{published}), .attributes = if (skip.*) &.{.{ .key = "skip", .value = "1" }} else &.{} };
                    published += 1;
                }
                var sent = try b.client.topic(topic_ids[topic]).publish(messages[0..count], .{ .ordering_key = key_names[k] });
                defer sent.deinit();
                // Ids in order, the dead letters' among them.
                for (sent.value.message_ids, skips[0..count]) |text, skip| {
                    try testing.expectEqual(ref.arrive(topic, .{ .key = k, .skip = skip }), try std.fmt.parseInt(u64, text, 10));
                }
            },
            2, 3, 4 => {
                const s = g.intRange(u8, 0, 2);
                _ = try modelPull(&b, &ref, s, g.intRange(u8, 1, 4), &deliveries, a, incarnation[s]);
            },
            5, 6, 7 => |op| {
                if (deliveries.items.len == 0) continue;
                const d = deliveries.items[g.intRange(u16, 0, @intCast(deliveries.items.len - 1))];
                const sub = b.client.subscription(sub_ids[d.sub]);
                const seconds: u32 = switch (op) {
                    6 => 0,
                    else => ([_]u32{ 5, 30, 600 })[g.intRange(u8, 0, 2)],
                };
                const result = if (op == 5) sub.ack(&.{d.ack_id}) else sub.modifyAckDeadline(&.{d.ack_id}, seconds);
                // An id from before the subscription was made again is
                // not this subscription's.
                if (d.incarnation != incarnation[d.sub]) {
                    try testing.expectError(error.InvalidArgument, result);
                    continue;
                }
                // Refused only with exactly-once delivery, when it comes
                // too late.
                const taken = if (op == 5) ref.ack(d.sub, d.id, d.attempt) else ref.modify(d.sub, d.id, d.attempt, seconds, now);
                if (taken) try result else try testing.expectError(error.InvalidArgument, result);
            },
            8 => {
                b.advance(g.intRange(u8, 1, 15));
                ref.settle(b.clock.now_ns);
            },
            else => switch (g.intRange(u8, 0, 3)) {
                // A subscription deleted and made again: it holds nothing.
                0, 1 => {
                    const s = g.intRange(u8, 0, 2);
                    const topic = g.intRange(u8, 0, 1);
                    try b.client.subscription(sub_ids[s]).delete();
                    try makeModelSubscription(&b, s, topic);
                    ref.counts[s] = 0;
                    ref.topic[s] = topic;
                    incarnation[s] += 1;
                },
                // A topic deleted and made again: its subscriptions keep
                // what they hold, and get nothing more. Dead letters go
                // to the one that has the name now.
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
            try testing.expectEqual(ref.backlog(s), b.fake.backlog("p", id));
            try testing.expectEqual(ref.outstanding(s), b.fake.outstanding("p", id));
        }
    }

    // In the end: every lease lapses, of 600 seconds at most, and then
    // every backoff runs out, of 20. Each subscription gives exactly what
    // it should hold, a key's in their order, each acknowledged as it
    // comes, until it holds nothing.
    b.advance(600 + 20 + 1);
    ref.settle(b.clock.now_ns);
    for (sub_ids, 0..) |id, s| {
        const sub = b.client.subscription(id);
        try testing.expectEqual(ref.counts[s], b.fake.backlog("p", id));
        while (ref.counts[s] > 0) {
            const before = deliveries.items.len;
            // Each round takes at least one away: with exactly-once
            // delivery a key gives one message a round.
            try testing.expect(try modelPull(&b, &ref, s, 1000, &deliveries, a, incarnation[s]) > 0);
            for (deliveries.items[before..]) |d| {
                try sub.ack(&.{d.ack_id});
                try testing.expect(ref.ack(s, d.id, d.attempt));
            }
        }
        try testing.expectEqual(0, b.fake.backlog("p", id));
        try expectNothing(sub);
    }
}

// These two are named apart from the `fuzz` properties on purpose. A run
// of the model property is a whole session of calls: under the fuzzer,
// on its plain allocator, the two together cost about 0.6 ms a run
// (measured 2026-10-12), several times what a codec's property does.
// They have a nightly job of their own, sized on its own.

test "fake property: after any script of calls each subscription holds exactly what a reference says" {
    try test_util.fuzzBytes({}, modelProperty, .{
        // A script is a byte for the order of pulls, and then steps: a
        // publish (0, topic, count less one, key, a byte a message for
        // `skip`), a pull (2, subscription, most less one), an ack, a
        // nack or a lease change of a delivery made so far (5, 6 or 7,
        // two bytes of which, and for 7 how long), the clock moved (8,
        // seconds less one), a subscription made again (9, 0, which, on
        // which topic) or a topic (9, 2, which).
        .corpus = &.{
            "",
            // Publish, pull, let the lease lapse, ack late, pull again, ack.
            "\x00\x00\x00\x00\x00\x00\x02\x00\x03\x08\x0b\x05\x00\x00\x02\x00\x03\x05\x00\x00",
            // Dead letters: one message to the third subscription, nacked
            // five times, then pulled from the first and acknowledged.
            "\x00\x00\x01\x00\x01\x00\x02\x02\x00\x06\x00\x00\x02\x02\x00\x06\x00\x01\x02\x02\x00\x06\x00\x02\x02\x02\x00\x06\x00\x03\x02\x02\x00\x06\x00\x04\x02\x00\x03\x05\x00\x05",
            // Ordering with a backoff: three of a key to the second
            // subscription, the third acknowledged and the first nacked,
            // nothing for five seconds, then all three again.
            "\x00\x00\x00\x02\x02\x00\x00\x00\x02\x01\x03\x05\x00\x02\x06\x00\x00\x02\x01\x03\x08\x04\x02\x01\x03",
            // Exactly-once: a late ack refused, the message again, its old
            // id refused and its new one taken, then a lease change on it.
            "\x00\x00\x01\x00\x00\x00\x02\x02\x00\x08\x09\x05\x00\x00\x02\x02\x00\x05\x00\x00\x05\x00\x01\x07\x00\x01\x00",
            // Ordering with exactly-once: of two of a key the second comes
            // only when the first is acknowledged, and again when nacked.
            "\x00\x00\x01\x01\x01\x00\x00\x02\x02\x03\x02\x02\x03\x05\x00\x00\x02\x02\x03\x06\x00\x01\x02\x02\x03\x05\x00\x02",
            // Ordering alone: a second of a key, published while the first
            // is out, waits for the first's ack.
            "\x00\x00\x00\x00\x02\x00\x02\x01\x00\x00\x00\x00\x02\x00\x02\x01\x03\x05\x00\x00\x02\x01\x03",
            // A filter: of two messages the second subscription gets one.
            "\x01\x00\x00\x01\x00\x01\x00\x02\x01\x03\x02\x00\x03",
            // A subscription made again, then an old id.
            "\x00\x00\x00\x00\x00\x00\x02\x00\x00\x09\x00\x00\x00\x05\x00\x00\x00\x00\x00\x00\x00\x02\x00\x00",
            // The dead-letter topic made again: five nacks forward to the
            // new one, where no subscription of the old listens. Then the
            // other topic made again under the third subscription.
            "\x00\x00\x01\x00\x00\x00\x09\x02\x00\x02\x02\x00\x06\x00\x00\x02\x02\x00\x06\x00\x01\x02\x02\x00\x06\x00\x02\x02\x02\x00\x06\x00\x03\x02\x02\x00\x06\x00\x04\x02\x00\x03\x09\x02\x01\x00\x01\x00\x00\x00\x02\x02\x03",
            // Found by the random runs: a backoff still running when the
            // last lease has lapsed, with later messages of its key behind.
            "\xfa\x33\xa2\x88\xe9\x5a\xc3\xa6\x7a\xa3\xb1\x6b\x59\xd6\xa7\x86\xf8\x48\x15\xae\x08\x17\xbe\xdf\xb0\xc2\x11\x8f",
        },
        .random_runs = 400,
        .max_len = 240,
    });
}

/// Any bytes on any route: an answer, never a crash and never a leak.
fn arbitraryRequest(_: void, input: []const u8) !void {
    var g: test_util.ByteGen = .init(input);
    // As the model property: a plain allocator under the fuzzer.
    const gpa = if (@import("builtin").fuzz) std.heap.smp_allocator else testing.allocator;
    var b: Bench = undefined;
    try b.initIn(gpa, .{});
    defer b.deinit();
    var scratch: std.heap.ArenaAllocator = .init(gpa);
    defer scratch.deinit();
    const a = scratch.allocator();
    try testing.expectEqual(200, (try b.raw(a, .PUT, "projects/p/topics/orders", "{}")).status);
    try testing.expectEqual(200, (try b.raw(a, .PUT, "projects/p/subscriptions/worker", "{\"topic\":\"projects/p/topics/orders\"}")).status);
    try testing.expectEqual(200, (try b.raw(a, .PUT, "projects/p/subscriptions/rules", "{\"topic\":\"projects/p/topics/orders\",\"enableMessageOrdering\":true,\"enableExactlyOnceDelivery\":true,\"filter\":\"attributes:k OR NOT attributes:k\",\"deadLetterPolicy\":{\"deadLetterTopic\":\"projects/p/topics/orders\"},\"retryPolicy\":{}}")).status);
    try testing.expectEqual(200, (try b.raw(a, .POST, "projects/p/topics/orders:publish", "{\"messages\":[{\"data\":\"eA==\",\"orderingKey\":\"o\"}]}")).status);
    const paths = [_][]const u8{
        "projects/p/topics",                                 "projects/p/topics/orders",
        "projects/p/topics/orders:publish",                  "projects/p/topics/orders/subscriptions",
        "projects/p/subscriptions",                          "projects/p/subscriptions/worker",
        "projects/p/subscriptions/worker:pull",              "projects/p/subscriptions/worker:acknowledge",
        "projects/p/subscriptions/worker:modifyAckDeadline", "projects/p/topics/new",
        "projects/p/subscriptions/new",                      "projects/p/topics?pageSize=1&pageToken=",
        "projects/p/subscriptions/rules",                    "projects/p/subscriptions/rules:pull",
        "projects/p/subscriptions/rules:acknowledge",        "projects/p/subscriptions/rules:modifyAckDeadline",
    };
    const bodies = [_][]const u8{
        "{\"messages\":[{\"data\":\"",                                    "{\"topic\":\"projects/p/topics/orders\",",
        "{\"subscription\":{",                                            "{\"topic\":{",
        "{\"ackIds\":[\"",                                                "{\"maxMessages\":",
        "{\"updateMask\":\"",                                             "",
        "{\"topic\":\"projects/p/topics/orders\",\"filter\":\"",          "{\"topic\":\"projects/p/topics/orders\",\"deadLetterPolicy\":{",
        "{\"topic\":\"projects/p/topics/orders\",\"retryPolicy\":{",      "{\"maxMessages\":3}",
        "{\"messages\":[{\"orderingKey\":\"o\",\"attributes\":{\"k\":\"", "{\"ackIds\":[\"FAKE",
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

    // A subscription with every rule: a filter read and kept, a key's
    // messages pulled in order, and five nacks that make dead letters.
    const rules = [_]struct { tp.Method, []const u8, []const u8 }{
        .{ .PUT, "topics/dead", "{}" },
        .{ .PUT, "subscriptions/rules", "{\"topic\":\"projects/p/topics/orders\",\"enableMessageOrdering\":true,\"filter\":\"attributes:k OR NOT (hasPrefix(attributes.\\\"a b\\\", \\\"c\\\\n\\\") AND attributes.d != \\\"e\\\")\",\"deadLetterPolicy\":{\"deadLetterTopic\":\"projects/p/topics/dead\"},\"retryPolicy\":{\"minimumBackoff\":\"0s\"}}" },
        .{ .PUT, "subscriptions/morgue", "{\"topic\":\"projects/p/topics/dead\",\"filter\":\"attributes.CloudPubSubDeadLetterSourceSubscription = \\\"rules\\\"\"}" },
        .{ .PUT, "subscriptions/bad", "{\"topic\":\"projects/p/topics/orders\",\"filter\":\"attributes.k = \\\"v\\\" AND\"}" },
        .{ .PATCH, "subscriptions/rules", "{\"subscription\":{\"deadLetterPolicy\":{\"deadLetterTopic\":\"projects/p/topics/dead\",\"maxDeliveryAttempts\":5},\"retryPolicy\":{\"maximumBackoff\":\"0s\",\"minimumBackoff\":\"0s\"}},\"updateMask\":\"deadLetterPolicy,retryPolicy,enableExactlyOnceDelivery\"}" },
        .{ .POST, "topics/orders:publish", "{\"messages\":[{\"data\":\"YQ==\",\"attributes\":{\"k\":\"v\"},\"orderingKey\":\"o\"},{\"data\":\"Yg==\",\"orderingKey\":\"o\"}]}" },
    };
    for (rules) |step| {
        const method, const path, const body = step;
        const reply = try fake.serve(method, try std.fmt.allocPrint(a, "{s}{s}", .{ base, path }), body, a);
        try testing.expectEqual(@as(u16, if (std.mem.endsWith(u8, path, "/bad")) 400 else 200), reply.status);
    }
    var last: []const u8 = "";
    for (0..5) |_| {
        const reply = try fake.serve(.POST, base ++ "subscriptions/rules:pull", "{\"maxMessages\":5}", a);
        const Wire = struct { receivedMessages: []const struct { ackId: []const u8 } = &.{} };
        const got = try std.json.parseFromSliceLeaky(Wire, a, reply.body, .{ .ignore_unknown_fields = true });
        try testing.expectEqual(2, got.receivedMessages.len);
        // With no seconds said, a nack.
        last = try std.fmt.allocPrint(a, "{{\"ackIds\":[\"{s}\",\"{s}\"]}}", .{ got.receivedMessages[0].ackId, got.receivedMessages[1].ackId });
        try testing.expectEqual(200, (try fake.serve(.POST, base ++ "subscriptions/rules:modifyAckDeadline", last, a)).status);
    }
    // Forwarded, both.
    try testing.expectEqual(0, fake.backlog("p", "rules"));
    try testing.expectEqual(2, fake.backlog("p", "morgue"));
    // With exactly-once delivery: an ack that takes, the same again, and
    // a lease change on what is gone, which is refused, id by id.
    try testing.expectEqual(200, (try fake.serve(.PATCH, base ++ "subscriptions/morgue", "{\"subscription\":{\"enableExactlyOnceDelivery\":true},\"updateMask\":\"enableExactlyOnceDelivery\"}", a)).status);
    const dead = try fake.serve(.POST, base ++ "subscriptions/morgue:pull", "{\"maxMessages\":5}", a);
    const Dead = struct { receivedMessages: []const struct { ackId: []const u8 } };
    const letters = try std.json.parseFromSliceLeaky(Dead, a, dead.body, .{ .ignore_unknown_fields = true });
    try testing.expectEqual(2, letters.receivedMessages.len);
    const both = try std.fmt.allocPrint(a, "{{\"ackIds\":[\"{s}\",\"{s}\"]}}", .{ letters.receivedMessages[0].ackId, letters.receivedMessages[1].ackId });
    for (0..2) |_| try testing.expectEqual(200, (try fake.serve(.POST, base ++ "subscriptions/morgue:acknowledge", both, a)).status);
    try testing.expectEqual(400, (try fake.serve(.POST, base ++ "subscriptions/morgue:modifyAckDeadline", both, a)).status);
    try testing.expectEqual(0, fake.backlog("p", "morgue"));
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
