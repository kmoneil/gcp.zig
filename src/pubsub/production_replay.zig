//! The reference that FakePubSub is held to, held to production in its
//! turn: a script of the fake's model property, replayed against a real
//! project, with `Reference` saying what each subscription should hold.
//! One test replays every script against the fake on a clock of its own,
//! in every run. The other skips unless PUBSUB_TEST_PROJECT and
//! PUBSUB_TEST_TOKEN name a project and a token for it, and PUBSUB_REPLAY
//! a script:
//!
//!     PUBSUB_REPLAY=corpus:3    the fourth script of `model_corpus`
//!     PUBSUB_REPLAY=seed:17     240 random bytes from that seed
//!     PUBSUB_REPLAY=hex:000001  the bytes given
//!
//! It makes two topics, three subscriptions and up to three snapshots,
//! named `zigps-f-<random>-...`, deletes them at the end, and grants
//! nothing. A script takes from five minutes to half an hour.
//!
//! Production cannot be replayed call for call, as the fake is, so the
//! replay is slow where the property is exact:
//!
//! - **A pull gives what production chooses of what is ready**, in its own
//!   time. The replay pulls until it has what was asked for or the
//!   reference has nothing ready, takes whichever came, and fails when one
//!   comes that the reference holds back, or when nothing has come for a
//!   minute and a half of what it has ready.
//! - **A lease's end is not asked about.** Production's lease begins when
//!   it sends a message and the replay's when the answer is in, so within
//!   a few seconds of a lease's end, on the subscription, nothing is
//!   acknowledged, given back, extended, sought or put in a snapshot: the
//!   replay waits it out. A message may come again two seconds before the
//!   reference says its lease is over.
//! - **A backoff is somewhere from the retry policy's minimum to its
//!   maximum** in production, and the fake's rule, doubling, is its own:
//!   the reference here asks for the minimum alone.
//! - **Without the grants nothing is forwarded** to a dead-letter topic,
//!   and the replay grants nothing: the reference has forwarding off, as
//!   the fake has with `Options.service_agent`.
//! - **A seek takes up to a minute to hold** (2 to 50 seconds, measured
//!   2026-10-10), so the replay waits a minute after one. Before a seek
//!   or a snapshot it waits for what was acknowledged to land.
//! - **A subscription made again under its name is two for about two
//!   minutes**, the old one and the new, and which of them answers an
//!   ack is chance. The replay waits two and a half.
//! - **A time sought to is kept clear** of every publish by a few seconds,
//!   and of every message a topic's retention is about to let go.
//! - **Production forgets, and the reference does not.** A message's
//!   deliveries are counted from one again when it has not come for
//!   about two minutes: the replay takes that count for the reference's.
//!   With exactly-once delivery the id that acknowledged a message is
//!   taken again for a time and then refused: of an ack that rests on
//!   that the replay takes either answer.
//! - **An ack that comes to nothing is given time**, since one with a
//!   pull right behind it acknowledged the message as it went out again.
//! - **With exactly-once delivery, no lease change and no nack is sent
//!   by an id from before a seek**: what those are answered production
//!   did not say the same way twice. An ack by one is sent.
//!
//! What the first replays found, 2026-10-13, is in the fake now: a seek
//! ends no ack id (`FakePubSub.judge`), and an ack in a script takes no
//! byte for a lease's length (`modelProperty`).

const std = @import("std");
const core = @import("core");

const Client = @import("Client.zig");
const model = @import("fake_pubsub.zig");
const test_util = @import("test_util.zig");
const types = @import("types.zig");
const testing = std.testing;
const Allocator = std.mem.Allocator;
const FakePubSub = model.FakePubSub;
const Reference = model.Reference;

const second = std.time.ns_per_s;

/// How near a lease's end nothing is asked of its subscription.
const margin_ns = 4 * second;
/// How far ahead of this machine production may be on a lease: the time
/// an answer took to come.
const early_ns = 2 * second;
/// How long production may give nothing of what the reference has ready.
/// A backoff is 20 seconds at most, and a nacked message came again
/// after about 2.
const patience_ns = 90 * second;
/// What a seek may take to hold.
const seek_lag_s = 60;
/// How long a subscription made again under its name is two. For about
/// two minutes production answers now as the old one and now as the
/// new: an ack by an id the new one gave was refused 108 seconds on,
/// "You have passed a subscription that does not belong to the given ack
/// ID", and one by an id of the old one taken 103 seconds on (measured
/// 2026-10-13, `probe18.py`). After that the old one's ids are refused
/// and the new one's taken, every time, in 220 seconds of asking.
const remade_lag_s = 150;
/// What an ack, a subscription made or a topic made is given to land.
const settle_s = 5;
/// How long a subscription that should hold nothing is watched.
const quiet_s = 25;
/// How long production goes on counting a message's deliveries after
/// the last: it counted on 107 seconds after one, and from one again 137
/// seconds after (2026-10-13). The reference counts on.
const counting_ns = 100 * second;
/// How long before a topic's retention lets a message go, and how long
/// after, a seek keeps clear of the message.
const fading_before_s = 60;
const fading_after_s = 300;

const long_ago = std.math.minInt(i64);

const Span = struct { from: i96, to: i96 };

/// Every delivery's ack id, with the subscription's incarnation then and
/// which delivery of the message it was.
/// With exactly-once delivery, and once a seek has come: until when the
/// lease it had then runs, and whether an ack by its id has been
/// answered.
const Delivery = struct { sub: usize, incarnation: u32, id: u64, attempt: u32, ack_id: []const u8, until: ?i96 = null, answered: bool = false };

const Act = union(enum) {
    ack,
    /// A lease of so many seconds from now. None: a nack.
    lease: u32,
};

const Round = enum { until_quiet, one_answer };

/// What a replay came to.
const Done = struct {
    steps: usize = 0,
    published: usize = 0,
    deliveries: usize = 0,
    /// Acks and lease changes production refused, as the reference said
    /// it would.
    refused: usize = 0,
    snapshots: usize = 0,
    seeks: usize = 0,

    fn add(total: *Done, one: Done) void {
        inline for (@typeInfo(Done).@"struct".field_names) |name| @field(total, name) += @field(one, name);
    }
};

const Replay = struct {
    a: Allocator,
    io: std.Io,
    client: *Client,
    diag: *core.Diagnostics,
    /// Says what it does as it goes: for a run against production.
    loud: bool,
    topics: [2][]const u8,
    subs: [3][]const u8,
    snapshots: [3][]const u8,
    started: i96,
    ref: Reference = .{ .forwards = false, .doubles = false },
    /// Production's message ids, each with the reference's.
    ids: std.StringHashMapUnmanaged(u64) = .empty,
    /// When each message was published, by this machine's clock: not
    /// before `from`, when it was sent, and not after `to`.
    published_at: [2 * Reference.max_held]Span = undefined,
    /// The `n` of each message's data, `m{n}`.
    number: [2 * Reference.max_held]usize = undefined,
    /// For each subscription and message, when its lease last ended or is
    /// to end, as far as the replay can know.
    edges: [3][2 * Reference.max_held]i96 = @splat(@splat(long_ago)),
    /// On the third subscription, which alone is sent attempts: when
    /// each message last came, and how many of its deliveries production
    /// has stopped counting.
    came_at: [2 * Reference.max_held]i96 = @splat(long_ago),
    uncounted: [2 * Reference.max_held]u32 = @splat(0),
    deliveries: std.ArrayList(Delivery) = .empty,
    incarnation: [3]u32 = @splat(0),
    /// Deliveries before this one are from before a seek of the
    /// subscription: their ids are answered and forgotten.
    stale_before: [3]usize = @splat(0),
    published: usize = 0,
    done: Done = .{},

    fn now(w: *Replay) i96 {
        return std.Io.Clock.real.now(w.io).nanoseconds;
    }

    fn sleepUntil(w: *Replay, time: i96) !void {
        const left = time - w.now();
        if (left > 0) try w.io.sleep(.{ .nanoseconds = left }, .awake);
    }

    /// Waits, and then ends in the reference every lease that has run out.
    fn pause(w: *Replay, seconds: i64) !void {
        try w.sleepUntil(w.now() + seconds * second);
        _ = w.settled();
    }

    /// Now, to which the reference is settled.
    fn settled(w: *Replay) i96 {
        const time = w.now();
        w.ref.clock = time;
        w.ref.settle(time);
        return time;
    }

    fn say(w: *Replay, comptime fmt: []const u8, args: anytype) void {
        if (!w.loud) return;
        w.stamp();
        std.debug.print(fmt ++ "\n", args);
    }

    fn stamp(w: *Replay) void {
        const tenths: u64 = @intCast(@max(0, @divTrunc(w.now() - w.started, std.time.ns_per_s / 10)));
        std.debug.print("[{d:>5}.{d}s] ", .{ @divTrunc(tenths, 10), @mod(tenths, 10) });
    }

    /// Says where production and the reference part, and what the
    /// reference holds of the subscription.
    fn parted(w: *Replay, s: usize, comptime fmt: []const u8, args: anytype) error{ProductionAndTheReferencePart} {
        w.stamp();
        std.debug.print("PARTED on {s}: " ++ fmt ++ "\n", .{w.subs[s]} ++ args);
        if (w.diag.message().len > 0) std.debug.print("  the last refusal: {s}\n", .{w.diag.message()});
        const time = w.now();
        std.debug.print("  the reference holds {d}:\n", .{w.ref.counts[s]});
        for (w.ref.all(s)) |h| {
            std.debug.print("    m{d} key {d} deliveries {d}", .{ w.number[h.id], w.ref.key(s, h), h.deliveries });
            if (h.acked) std.debug.print(" acknowledged", .{});
            if (h.lease_until) |until| std.debug.print(" out for {d} ms more", .{@divTrunc(until - time, std.time.ns_per_ms)});
            if (h.not_before > time) std.debug.print(" held back for {d} ms more", .{@divTrunc(h.not_before - time, std.time.ns_per_ms)});
            std.debug.print("\n", .{});
        }
        return error.ProductionAndTheReferencePart;
    }

    fn makeTopic(w: *Replay, topic: u8) !void {
        var made = try w.client.topic(w.topics[topic]).create(model.modelTopic(topic));
        made.deinit();
    }

    fn makeSubscription(w: *Replay, s: usize, topic: u8) !void {
        var made = try w.client.subscription(w.subs[s]).create(model.modelSubscription(s, w.topics[topic], w.topics[0]));
        made.deinit();
    }

    /// Waits until no lease of the subscription is within the margin of
    /// its end, on either side.
    fn clearOfEdges(w: *Replay, s: usize) !void {
        while (true) {
            const time = w.now();
            var until = time;
            for (w.edges[s][0..w.ref.next_id]) |edge| {
                if (edge > time - margin_ns and edge < time + margin_ns) until = @max(until, edge + margin_ns);
            }
            if (until == time) return;
            try w.sleepUntil(until);
        }
    }

    /// The time nearest after `wanted` that production and the reference
    /// cannot read two ways: none within the margin of a message's
    /// publish, on the subscription's topic, and none at or before a
    /// message that the topic's retention is letting go about now.
    fn clearTime(w: *Replay, s: usize, wanted: i96, at: i96) i96 {
        var time = wanted;
        var moved = true;
        while (moved) {
            moved = false;
            for (1..w.ref.next_id) |id| {
                if (!w.ref.sameTopic(w.ref.on[s], id)) continue;
                const span = w.published_at[id];
                const near = time > span.from - margin_ns and time < span.to + margin_ns;
                const fading = if (Reference.topic_retention_s[w.ref.sent[id].topic]) |seconds|
                    time <= span.to and at - span.from > (seconds - fading_before_s) * second and at - span.to < (seconds + fading_after_s) * second
                else
                    false;
                if (near or fading) {
                    time = span.to + margin_ns;
                    moved = true;
                }
            }
        }
        return time;
    }

    fn publish(w: *Replay, topic: u8, k: u8, skips: []const bool) !void {
        var messages: [3]types.Message = undefined;
        var bufs: [3][8]u8 = undefined;
        for (messages[0..skips.len], bufs[0..skips.len], skips, 0..) |*m, *buf, skip, n| {
            m.* = .{ .data = try std.fmt.bufPrint(buf, "m{d}", .{w.published + n}), .attributes = if (skip) &.{.{ .key = "skip", .value = "1" }} else &.{} };
        }
        const from = w.now();
        var sent = w.client.topic(w.topics[topic]).publish(messages[0..skips.len], .{ .ordering_key = model.key_names[k] }) catch |err|
            return w.parted(0, "a publish to {s} failed: {s}", .{ w.topics[topic], @errorName(err) });
        defer sent.deinit();
        const to = w.settled();
        for (sent.value.message_ids, skips) |text, skip| {
            const id = w.ref.arrive(topic, k, skip);
            try w.ids.put(w.a, try w.a.dupe(u8, text), id);
            w.published_at[id] = .{ .from = from, .to = to };
            w.number[id] = w.published;
            w.published += 1;
        }
        w.say("publish to {s}, key {d}: m{d} to m{d}", .{ w.topics[topic], k, w.published - skips.len, w.published - 1 });
    }

    /// Takes up to `max` of what the subscription has ready, as
    /// production gives them: until it has that many or the reference
    /// has nothing ready, or, a round at a time, until one answer has
    /// brought some. Each that comes is one the reference has ready, a
    /// key's in their order, and is marked out.
    fn pull(w: *Replay, s: usize, max: u32, round: Round) !usize {
        const sub = w.client.subscription(w.subs[s]);
        var was_ready: [Reference.max_held]bool = undefined;
        var got: usize = 0;
        var empty: usize = 0;
        var nothing_since = w.now();
        while (got < max) {
            // Production holds a pull that has nothing to give, and one
            // it has nothing for is not worth the wait.
            const expected = w.ref.readySet(s, w.settled(), &was_ready);
            var answer = sub.pull(.{ .max_messages = @intCast(max - got), .return_immediately = expected == 0 }) catch |err|
                return w.parted(s, "a pull failed: {s}", .{@errorName(err)});
            defer answer.deinit();
            const time = w.now();
            w.ref.clock = time;
            w.ref.settle(time + early_ns);
            const ready = w.ref.readySet(s, time + early_ns, &was_ready);
            if (answer.value.messages.len == 0) {
                if (ready == 0) {
                    empty += 1;
                    if (empty == 3) break;
                } else {
                    empty = 0;
                    if (time - nothing_since > patience_ns) return w.parted(s, "production gives nothing, and the reference has had {d} ready for {d} seconds", .{ ready, @divTrunc(time - nothing_since, second) });
                }
                try w.sleepUntil(time + second);
                continue;
            }
            empty = 0;
            nothing_since = time;
            for (answer.value.messages) |m| {
                const id = w.ids.get(m.message_id) orelse return w.parted(s, "production gave a message that was not published here: {s}, id {s}", .{ m.data, m.message_id });
                const index = w.ref.indexOf(s, id) orelse return w.parted(s, "production gave m{d}, which the reference does not hold", .{w.number[id]});
                if (!was_ready[index]) return w.parted(s, "production gave m{d}, which the reference holds back", .{w.number[id]});
                const held = &w.ref.held[s][index];
                // In its key's order: every earlier one of the key that
                // was ready came before it in this answer.
                const k = w.ref.key(s, held.*);
                if (k != 0) for (w.ref.all(s)[0..index], was_ready[0..index]) |e, e_ready| {
                    if (w.ref.key(s, e) == k and e_ready and e.lease_until == null) return w.parted(s, "production gave m{d} before m{d}, an earlier one of its key", .{ w.number[id], w.number[e.id] });
                };
                held.lease_until = time + @as(i96, Reference.deadline_s[s]) * second;
                held.deliveries += 1;
                w.edges[s][id] = held.lease_until.?;
                // The attempt is sent with a dead-letter policy alone.
                if (s == 2) {
                    // Production counts from one again when the message
                    // has not come for about two minutes.
                    if (m.delivery_attempt == 1 and held.deliveries - w.uncounted[id] > 1 and time - w.came_at[id] > counting_ns) {
                        w.say("  production counts the deliveries of m{d} from one again, {d} seconds after the last", .{ w.number[id], @divTrunc(time - w.came_at[id], second) });
                        w.uncounted[id] = held.deliveries - 1;
                    }
                    w.came_at[id] = time;
                }
                const attempt = if (s == 2) held.deliveries - w.uncounted[id] else 0;
                if (m.delivery_attempt != attempt) return w.parted(s, "production says m{d} is on attempt {d}, and the reference {d}", .{ w.number[id], m.delivery_attempt, attempt });
                if (!std.mem.eql(u8, model.key_names[w.ref.sent[id].key] orelse "", m.ordering_key)) return w.parted(s, "m{d} came with the ordering key {s}", .{ w.number[id], m.ordering_key });
                if (w.ref.sent[id].skip != (m.attribute("skip") != null)) return w.parted(s, "m{d} came with another's attributes", .{w.number[id]});
                // This machine's clock and production's agree on when it
                // was published: a seek to a time rests on that.
                const stamped = (core.timestamp.parse(m.publish_time) catch return w.parted(s, "m{d} came with the publish time {s}", .{ w.number[id], m.publish_time })).nanoseconds;
                const span = w.published_at[id];
                if (stamped < span.from - early_ns or stamped > span.to + early_ns) return w.parted(s, "m{d} was published at {s}, {d} ms from when it was sent", .{ w.number[id], m.publish_time, @divTrunc(stamped - span.from, std.time.ns_per_ms) });
                try w.deliveries.append(w.a, .{ .sub = s, .incarnation = w.incarnation[s], .id = id, .attempt = held.deliveries, .ack_id = try w.a.dupe(u8, m.ack_id) });
                w.say("  {s} gave m{d}, delivery {d} of it", .{ w.subs[s], w.number[id], held.deliveries });
                got += 1;
            }
            if (round == .one_answer) break;
        }
        return got;
    }

    /// An ack, a nack or a lease change of a delivery made so far, taken
    /// or refused as the reference says.
    fn act(w: *Replay, which: usize, what: Act) !void {
        const d = &w.deliveries.items[which];
        const s = d.sub;
        const sub = w.client.subscription(w.subs[s]);
        const name: []const u8 = switch (what) {
            .ack => "an ack",
            .lease => |seconds| if (seconds == 0) "a nack" else "a lease change",
        };
        // An id from before the subscription was made again is not this
        // subscription's.
        const ours = d.incarnation == w.incarnation[s];
        // With exactly-once delivery, an id from before a seek: the
        // delivery it is of goes on being out, on the lease it had.
        const old = ours and s == 2 and which < w.stale_before[s];
        if (old and what != .ack) {
            // What a lease change or a nack by such an id is answered,
            // and what it then does, production did not say the same way
            // twice (2026-10-13): the replay sends none.
            w.say("{s} of m{d} on {s}, by an id from before a seek: not sent", .{ name, w.number[d.id], w.subs[s] });
            return;
        }
        if (ours) {
            // Nor is the lease such an id had asked about near its end.
            if (old) if (d.until) |until| {
                const time = w.now();
                if (until > time - margin_ns and until < time + margin_ns) try w.sleepUntil(until + margin_ns);
            };
            try w.clearOfEdges(s);
        }
        const result = switch (what) {
            .ack => sub.ack(&.{d.ack_id}),
            .lease => |seconds| sub.modifyAckDeadline(&.{d.ack_id}, seconds),
        };
        const time = w.settled();
        // Whether production may answer either way, and whether what was
        // sent came to nothing.
        var either = false;
        var forgotten = false;
        const taken = taken: {
            if (!ours) break :taken false;
            const held: ?Reference.Held = if (w.ref.indexOf(s, d.id)) |index| w.ref.held[s][index] else null;
            const out = if (held) |h| h.lease_until != null else false;
            if (old) {
                // While the lease it had runs an ack by it is answered,
                // and acknowledges the message if the message is out
                // again, by no delivery of its own. After, it is refused,
                // unless an ack by it was answered before: that
                // production remembers for a while and no longer.
                if (d.until == null or d.until.? <= time) {
                    either = d.answered;
                    break :taken d.answered;
                }
                d.answered = true;
                d.until = null;
                if (out) {
                    _ = w.ref.ack(s, d.id, held.?.deliveries);
                    w.ref.acknowledged_by[d.id] = 0;
                    w.syncEdges(s, time);
                }
                break :taken true;
            }
            forgotten = s != 2 and held != null and !out;
            // Refused only with exactly-once delivery, when it comes too
            // late.
            const taken = switch (what) {
                .ack => w.ref.ack(s, d.id, d.attempt),
                .lease => |seconds| w.ref.modify(s, d.id, d.attempt, seconds, time),
            };
            // With exactly-once delivery the id that acknowledged a
            // message is taken again, for as long as production
            // remembers it: 180 seconds and more, but with ordering and
            // dead letters too, as here, between 93 and 121, and after a
            // seek under 31 (2026-10-13).
            either = s == 2 and what == .ack and !out and taken;
            w.syncEdges(s, time);
            break :taken taken;
        };
        w.say("{s} of m{d} on {s}, by its delivery {d}: {s}{s}", .{ name, w.number[d.id], w.subs[s], d.attempt, if (taken) "taken" else "refused", if (either) ", or as production remembers" else "" });
        if (result) |_| {
            if (!taken and !either) return w.parted(s, "production took {s} of m{d} by its delivery {d}, which the reference refuses", .{ name, w.number[d.id], d.attempt });
        } else |err| {
            if (err != error.InvalidArgument or (taken and !either)) return w.parted(s, "production answered {s} of m{d} by its delivery {d} with {s}, which the reference {s}", .{ name, w.number[d.id], d.attempt, @errorName(err), if (taken) "takes" else "refuses" });
            w.done.refused += 1;
        }
        // What comes when the message is not out is answered and
        // forgotten. But an ack with a pull right behind it, on the same
        // connection, caught the message as it went out again
        // (2026-10-13): nothing follows one at once.
        if (forgotten) try w.pause(settle_s);
    }

    /// After an ack, a nack or a lease change: no lease of the
    /// subscription was near its end, so what ended one just now was
    /// that, and that is no end to keep clear of. They are answered when
    /// they are done.
    fn syncEdges(w: *Replay, s: usize, time: i96) void {
        for (1..w.ref.next_id) |id| {
            const lease = if (w.ref.indexOf(s, id)) |index| w.ref.held[s][index].lease_until else null;
            if (lease) |until| {
                w.edges[s][id] = until;
            } else if (w.edges[s][id] > time) w.edges[s][id] = long_ago;
        }
    }

    /// Watches a subscription that should hold nothing.
    fn nothingMore(w: *Replay, s: usize) !void {
        const until = w.now() + quiet_s * second;
        while (w.now() < until) {
            var got = w.client.subscription(w.subs[s]).pull(.{ .return_immediately = true }) catch |err|
                return w.parted(s, "a pull failed: {s}", .{@errorName(err)});
            defer got.deinit();
            if (got.value.messages.len > 0) return w.parted(s, "production gave {s} when the reference held nothing more", .{got.value.messages[0].data});
            try w.sleepUntil(w.now() + 2 * second);
        }
    }

    /// When the subscription next has something end by itself: a lease
    /// or a backoff. Null when nothing is to.
    fn nextEnd(w: *Replay, s: usize, time: i96) ?i96 {
        var next: ?i96 = null;
        for (w.ref.all(s)) |h| {
            for ([2]?i96{ h.lease_until, h.not_before }) |end| {
                const e = end orelse continue;
                if (e > time and (next == null or e < next.?)) next = e;
            }
        }
        return next;
    }

    /// Leaves the project as it was found.
    fn clear(w: *Replay) void {
        for (w.snapshots) |id| w.client.snapshot(id).delete() catch {};
        for (w.subs) |id| w.client.subscription(id).delete() catch {};
        for (w.topics) |id| w.client.topic(id).delete() catch {};
    }
};

/// One script, as `modelProperty` reads it, against whatever the client
/// is of. Every name it makes begins with `prefix`.
fn replay(a: Allocator, io: std.Io, client: *Client, diag: *core.Diagnostics, prefix: []const u8, script: []const u8, loud: bool) !Done {
    var w: Replay = .{
        .a = a,
        .io = io,
        .client = client,
        .diag = diag,
        .loud = loud,
        .topics = undefined,
        .subs = undefined,
        .snapshots = undefined,
        .started = std.Io.Clock.real.now(io).nanoseconds,
    };
    for (&w.topics, 0..) |*id, n| id.* = try std.fmt.allocPrint(a, "{s}top{d}", .{ prefix, n });
    for (&w.subs, 0..) |*id, n| id.* = try std.fmt.allocPrint(a, "{s}sub{d}", .{ prefix, n });
    for (&w.snapshots, 0..) |*id, n| id.* = try std.fmt.allocPrint(a, "{s}snap{d}", .{ prefix, n });
    defer w.clear();

    var g: test_util.ByteGen = .init(script);
    // The order of the fake's pulls, and whether its service agent has
    // its grants: neither is production's to be told.
    _ = g.byte();
    for (0..2) |topic| try w.makeTopic(@intCast(topic));
    for (0..3) |s| try w.makeSubscription(s, w.ref.on[s].topic);
    w.say("made {s} and {s}, and three subscriptions", .{ w.topics[0], w.topics[1] });
    try w.pause(settle_s);

    var steps: usize = 0;
    while (steps < 60 and g.pos < g.bytes.len) : (steps += 1) {
        _ = w.settled();
        switch (g.intRange(u8, 0, 11)) {
            0, 1 => {
                const topic = g.intRange(u8, 0, 1);
                const count = g.intRange(u8, 1, 3);
                // One ordering key a request, as production has it.
                const k = g.intRange(u8, 0, 2);
                if (w.published + count > Reference.max_held / 2) continue;
                var skips: [3]bool = undefined;
                for (skips[0..count]) |*skip| skip.* = g.boolean();
                try w.publish(topic, k, skips[0..count]);
            },
            2, 3, 4 => {
                const s = g.intRange(u8, 0, 2);
                const max = g.intRange(u8, 1, 4);
                w.say("pull {s}, {d} at most", .{ w.subs[s], max });
                _ = try w.pull(s, max, .until_quiet);
            },
            5, 6, 7 => |op| {
                if (w.deliveries.items.len == 0) continue;
                const which = g.intRange(u16, 0, @intCast(w.deliveries.items.len - 1));
                const seconds: u32 = switch (op) {
                    7 => ([_]u32{ 5, 30, 600 })[g.intRange(u8, 0, 2)],
                    else => 0,
                };
                try w.act(which, if (op == 5) .ack else .{ .lease = seconds });
            },
            8 => {
                const seconds = g.intRange(u8, 1, 15);
                w.say("wait {d} seconds", .{seconds});
                try w.pause(seconds);
            },
            // A snapshot taken, in place of the one of its name.
            10 => {
                const slot = g.intRange(u8, 0, 2);
                const s = g.intRange(u8, 0, 2);
                const snapshot = w.client.snapshot(w.snapshots[slot]);
                const deleted = snapshot.delete();
                if (w.ref.taken[slot] != null) {
                    deleted catch |err| return w.parted(s, "{s} is not deleted: {s}", .{ w.snapshots[slot], @errorName(err) });
                } else if (deleted != error.NotFound) return w.parted(s, "{s} was never taken, and deleting it is not refused as not found", .{w.snapshots[slot]});
                w.ref.taken[slot] = null;
                try w.pause(settle_s);
                try w.clearOfEdges(s);
                _ = w.settled();
                var made = snapshot.create(.{ .subscription = w.subs[s] });
                defer if (made) |*info| info.deinit() else |_| {};
                // None is taken of a subscription whose topic is gone.
                const orphan = w.ref.on[s].made != w.ref.made[w.ref.on[s].topic];
                w.say("snapshot {s} of {s}{s}", .{ w.snapshots[slot], w.subs[s], if (orphan) ", whose topic is gone" else "" });
                if (made) |_| {
                    if (orphan) return w.parted(s, "production took {s} of a subscription whose topic is gone", .{w.snapshots[slot]});
                } else |err| {
                    if (!orphan or err != error.FailedPrecondition) return w.parted(s, "production refused {s}: {s}", .{ w.snapshots[slot], @errorName(err) });
                    continue;
                }
                w.ref.take(slot, s);
                w.done.snapshots += 1;
            },
            // A seek: to a snapshot, to a time some way back, or ahead.
            11 => {
                const s = g.intRange(u8, 0, 2);
                const sub = w.client.subscription(w.subs[s]);
                const choice = g.intRange(u8, 0, 4);
                const back = if (choice < 3) 0 else @as(i96, g.intRange(u8, 0, 60)) * 20 * second;
                try w.pause(settle_s);
                try w.clearOfEdges(s);
                const time = w.settled();
                // What is out, by which delivery, and which id has
                // acknowledged its message: asked of the reference before
                // the seek does away with it.
                const Before = struct { until: ?i96, answered: bool };
                const before = try a.alloc(Before, w.deliveries.items.len - w.stale_before[s]);
                for (before, w.deliveries.items[w.stale_before[s]..]) |*slot, d| {
                    slot.* = .{ .until = null, .answered = false };
                    if (d.sub != s or d.incarnation != w.incarnation[s]) continue;
                    slot.answered = w.ref.acknowledged_by[d.id] == d.attempt;
                    const held = w.ref.held[s][w.ref.indexOf(s, d.id) orelse continue];
                    if (held.deliveries == d.attempt and !held.acked) slot.until = held.lease_until;
                }
                if (choice < 3) {
                    const result = sub.seek(.{ .snapshot = w.snapshots[choice] });
                    const why: ?anyerror = if (w.ref.taken[choice] == null)
                        error.NotFound
                    else if (!w.ref.seekTo(s, choice))
                        error.FailedPrecondition
                    else
                        null;
                    w.say("seek {s} to {s}: {s}", .{ w.subs[s], w.snapshots[choice], if (why) |err| @errorName(err) else "taken" });
                    if (result) |_| {
                        if (why != null) return w.parted(s, "production took a seek to {s}, which the reference refuses", .{w.snapshots[choice]});
                    } else |err| {
                        if (why == null or err != why.?) return w.parted(s, "production answered a seek to {s} with {s}", .{ w.snapshots[choice], @errorName(err) });
                        continue;
                    }
                } else {
                    const to = w.clearTime(s, if (choice == 3) @max(0, time - back) else time + back, time);
                    w.say("seek {s} to {d} ms from now", .{ w.subs[s], @divTrunc(to - time, std.time.ns_per_ms) });
                    sub.seek(.{ .time = .{ .nanoseconds = to } }) catch |err| return w.parted(s, "production refused a seek to a time: {s}", .{@errorName(err)});
                    w.ref.seekAt(s, to);
                }
                for (before, w.deliveries.items[w.stale_before[s]..]) |was, *d| {
                    if (d.sub != s or d.incarnation != w.incarnation[s]) continue;
                    d.until = was.until;
                    d.answered = was.answered;
                }
                w.stale_before[s] = w.deliveries.items.len;
                if (s == 2) {
                    w.ref.acknowledged_by = @splat(0);
                    w.came_at = @splat(long_ago);
                    w.uncounted = @splat(0);
                }
                w.edges[s] = @splat(long_ago);
                w.done.seeks += 1;
                try w.pause(seek_lag_s);
            },
            else => switch (g.intRange(u8, 0, 3)) {
                // A subscription deleted and made again: it holds nothing.
                0, 1 => {
                    const s = g.intRange(u8, 0, 2);
                    const topic = g.intRange(u8, 0, 1);
                    w.say("{s} made again, on {s}", .{ w.subs[s], w.topics[topic] });
                    w.client.subscription(w.subs[s]).delete() catch |err| return w.parted(s, "it is not deleted: {s}", .{@errorName(err)});
                    try w.pause(settle_s);
                    w.makeSubscription(s, topic) catch |err| return w.parted(s, "it is not made again: {s}", .{@errorName(err)});
                    w.ref.counts[s] = 0;
                    w.ref.on[s] = .{ .topic = topic, .made = w.ref.made[topic] };
                    w.ref.joined[s] = w.ref.next_id;
                    w.incarnation[s] += 1;
                    w.edges[s] = @splat(long_ago);
                    if (s == 2) {
                        w.came_at = @splat(long_ago);
                        w.uncounted = @splat(0);
                    }
                    try w.pause(remade_lag_s);
                },
                // A topic deleted and made again: its subscriptions keep
                // what they hold, and get nothing more.
                else => {
                    const topic = g.intRange(u8, 0, 1);
                    w.say("{s} made again", .{w.topics[topic]});
                    w.client.topic(w.topics[topic]).delete() catch |err| return w.parted(0, "{s} is not deleted: {s}", .{ w.topics[topic], @errorName(err) });
                    try w.pause(settle_s);
                    w.makeTopic(topic) catch |err| return w.parted(0, "{s} is not made again: {s}", .{ w.topics[topic], @errorName(err) });
                    w.ref.made[topic] += 1;
                    try w.pause(settle_s);
                },
            },
        }
    }

    // In the end each subscription gives exactly what it should hold, a
    // key's in their order, each acknowledged as it comes, until it holds
    // nothing. What is out or held back is waited for.
    w.say("the script is over after {d} steps: {d} published, {d} deliveries, {d} refusals", .{ steps, w.published, w.deliveries.items.len, w.done.refused });
    for (0..3) |s| {
        while (w.ref.counts[s] > 0) {
            const before = w.deliveries.items.len;
            if (try w.pull(s, 1000, .one_answer) == 0) {
                const time = w.settled();
                const next = w.nextEnd(s, time) orelse return w.parted(s, "the reference has nothing ready and nothing that will be", .{});
                w.say("  {s}: {d} held, the next ready in {d} seconds", .{ w.subs[s], w.ref.counts[s], @divTrunc(next - time, second) });
                try w.sleepUntil(next + second);
                continue;
            }
            for (before..w.deliveries.items.len) |which| try w.act(which, .ack);
        }
        try w.nothingMore(s);
        w.say("{s} holds nothing more", .{w.subs[s]});
    }
    w.done.steps = steps;
    w.done.published = w.published;
    w.done.deliveries = w.deliveries.items.len;
    return w.done;
}

/// The script PUBSUB_REPLAY names.
fn scriptOf(a: Allocator, what: []const u8) ![]const u8 {
    const colon = std.mem.indexOfScalar(u8, what, ':') orelse return error.NoSuchScript;
    const kind = what[0..colon];
    const rest = what[colon + 1 ..];
    if (std.mem.eql(u8, kind, "corpus")) {
        const index = try std.fmt.parseInt(usize, rest, 10);
        if (index >= model.model_corpus.len) return error.NoSuchScript;
        return model.model_corpus[index];
    }
    if (std.mem.eql(u8, kind, "seed")) {
        var prng: std.Random.DefaultPrng = .init(try std.fmt.parseInt(u64, rest, 0));
        const bytes = try a.alloc(u8, 240);
        prng.random().bytes(bytes);
        return bytes;
    }
    if (std.mem.eql(u8, kind, "hex")) {
        if (rest.len % 2 != 0) return error.NoSuchScript;
        return std.fmt.hexToBytes(try a.alloc(u8, rest.len / 2), rest);
    }
    return error.NoSuchScript;
}

test "production replay: a script of the fake's model property, slowly, against a real project" {
    const gpa = testing.allocator;
    var env = try testing.environ.createMap(gpa);
    defer env.deinit();
    const what = env.get("PUBSUB_REPLAY") orelse return error.SkipZigTest;
    const project = env.get("PUBSUB_TEST_PROJECT") orelse return error.SkipZigTest;
    const token_text = env.get("PUBSUB_TEST_TOKEN") orelse return error.SkipZigTest;
    var arena_state: std.heap.ArenaAllocator = .init(gpa);
    defer arena_state.deinit();
    const a = arena_state.allocator();

    var token: core.StaticToken = .{ .token = std.mem.trim(u8, token_text, &std.ascii.whitespace) };
    var diag: core.Diagnostics = .{};
    var client: Client = try .init(gpa, testing.io, .{
        .project_id = project,
        .token_provider = token.provider(),
        .diagnostics = &diag,
        .user_agent = "zig-pubsub-replay/0.1",
    });
    defer client.deinit();
    var random: [3]u8 = undefined;
    testing.io.random(&random);
    const prefix = try std.fmt.allocPrint(a, "zigps-f-{x}-", .{random});
    std.debug.print("replaying {s} in {s}, as {s}...\n", .{ what, project, prefix });
    const done = try replay(a, testing.io, &client, &diag, prefix, try scriptOf(a, what), true);
    std.debug.print("production and the reference agree: {any}\n", .{done});
}

/// A script against the fake, its service agent named with no grant, on
/// a clock that a wait moves.
fn replayFake(gpa: Allocator, script: []const u8) !Done {
    var clock: test_util.FakeClock = .{ .now_ns = 100_000 * second };
    var fake: FakePubSub = .init(gpa, clock.io(), .{ .shuffle = script.len > 0 and script[0] & 1 == 1, .service_agent = model.model_agent });
    defer fake.deinit();
    var token: core.StaticToken = .{ .token = "fake" };
    var diag: core.Diagnostics = .{};
    var client: Client = try .init(gpa, clock.io(), .{
        .project_id = "p",
        .token_provider = token.provider(),
        .transport = fake.transport(),
        .diagnostics = &diag,
    });
    defer client.deinit();
    var arena_state: std.heap.ArenaAllocator = .init(gpa);
    defer arena_state.deinit();
    return replay(arena_state.allocator(), clock.io(), &client, &diag, "", script, false) catch |err| {
        std.debug.print("the script, against the fake: {x}\n", .{script});
        return err;
    };
}

test "fake, the reference replayed as it is against production: the property's corpus and random scripts" {
    const gpa = testing.allocator;
    var total: Done = .{};
    for (model.model_corpus) |script| total.add(try replayFake(gpa, script));
    var prng: std.Random.DefaultPrng = .init(0x5eed_f00d);
    var bytes: [240]u8 = undefined;
    for (0..100) |_| {
        prng.random().bytes(&bytes);
        total.add(try replayFake(gpa, &bytes));
    }
    // Scripts that agreed on little would have shown little.
    try testing.expect(total.steps > 5000 and total.published > 1500 and total.deliveries > 2000);
    try testing.expect(total.refused > 400 and total.snapshots > 250 and total.seeks > 150);
}

test "the script a replay is asked for by name" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    try testing.expectEqualStrings(model.model_corpus[1], try scriptOf(a, "corpus:1"));
    try testing.expectEqualStrings("\x00\x0b\xff", try scriptOf(a, "hex:000bff"));
    const random = try scriptOf(a, "seed:7");
    try testing.expectEqual(240, random.len);
    try testing.expectEqualStrings(random, try scriptOf(a, "seed:0x7"));
    for ([_][]const u8{ "", "corpus", "corpus:999", "hex:0", "hex:zz", "seed:x", "other:1" }) |bad| {
        try testing.expect(std.meta.isError(scriptOf(a, bad)));
    }
}
