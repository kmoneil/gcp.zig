//! FakePubSub held against the emulator: the same script of calls to both
//! through the client, whose answers must agree, call for call. A unit
//! test that skips unless PUBSUB_EMULATOR_HOST names an emulator; CI's
//! integration step runs it with one. PUBSUB_DIFF_SEED replays a seed.
//!
//! The fake answers as production does, and the emulator is not
//! production, so a script keeps to what the two were measured to agree
//! on: topics, subscriptions and snapshots made, read, listed and
//! deleted; publishes; pulls, acks and nacks of messages that are out on
//! a lease; filters of the plain shapes; ordering keys; a seek to a
//! snapshot. It keeps away from where they part: a lease left to lapse
//! (the emulator takes a late ack, production forgets one), a filter
//! production refuses (the emulator answers 500), updates (the emulator
//! knows fewer masks), and everything Pub/Sub does on its own.
//!
//! What this test found, and now steers round, each settled by what
//! production did:
//!
//! - **A seek to a snapshot gives an emulator's subscription only
//!   messages it was itself sent.** In production a snapshot is its
//!   topic's, and a subscription made after the snapshot's messages gets
//!   them by seeking to it (measured 2026-10-10); on the emulator it gets
//!   none. So a script seeks a subscription only to a snapshot that was
//!   taken of it.
//! - **Once a topic is deleted the emulator goes on knowing it by name.**
//!   A snapshot of it keeps the name, where production's reads
//!   `_deleted-topic_`; a subscription of it may have a new snapshot
//!   taken, which production refuses; and the subscription may no longer
//!   seek to a snapshot taken of it before, which production takes
//!   (measured 2026-10-12, after this test showed the fake wrong on the
//!   second). So a script takes no snapshot of, and seeks no,
//!   subscription whose topic is gone.
//! - **Of a topic that is not there production's lists are 404**, and the
//!   emulator's empty (measured 2026-10-10).

const std = @import("std");
const core = @import("core");

const Client = @import("Client.zig");
const Endpoint = @import("Endpoint.zig");
const FakePubSub = @import("fake_pubsub.zig").FakePubSub;
const types = @import("types.zig");
const testing = std.testing;
const Allocator = std.mem.Allocator;

const topic_ids = [_][]const u8{ "topic-0", "topic-1", "topic-2" };
const sub_ids = [_][]const u8{ "sub-0", "sub-1", "sub-2", "sub-3", "sub-4" };
const snap_ids = [_][]const u8{ "snap-0", "snap-1" };

/// How a subscription is made. A deadline of ten minutes, so that no
/// lease lapses while a script runs.
const kinds = [_]struct { ordered: bool = false, filter: []const u8 = "" }{
    .{},
    .{ .ordered = true },
    .{ .filter = "attributes:flag" },
    .{ .filter = "NOT attributes:flag" },
    .{ .filter = "attributes.kind = \"a\"" },
    .{ .filter = "attributes.kind != \"a\" OR hasPrefix(attributes.kind, \"a\")" },
    .{ .ordered = true, .filter = "attributes.kind = \"b\"" },
};

/// One of the two: its client, and what it has out on a lease.
const Side = struct {
    client: *Client,
    /// For each subscription, the messages out, each with its ack id.
    out: [sub_ids.len]std.ArrayList(Out) = @splat(.empty),

    const Out = struct { data: []const u8, ack_id: []const u8 };
};

/// What a call came to, as far as the two must agree: that it went
/// through, with the texts it answered, or the error it failed with.
const Outcome = union(enum) {
    ok: []const []const u8,
    failed: anyerror,

    fn expectEqual(emulator: Outcome, fake: Outcome) !void {
        switch (emulator) {
            .failed => |err| switch (fake) {
                .failed => |other| try testing.expectEqual(err, other),
                .ok => return error.TheFakeTookWhatTheEmulatorRefused,
            },
            .ok => |texts| switch (fake) {
                .failed => return error.TheFakeRefusedWhatTheEmulatorTook,
                .ok => |others| {
                    try testing.expectEqual(texts.len, others.len);
                    for (texts, others) |text, other| try testing.expectEqualStrings(text, other);
                },
            },
        }
    }
};

const Op = union(enum) {
    create_topic: usize,
    delete_topic: usize,
    get_topic: usize,
    create_sub: struct { sub: usize, topic: usize, kind: usize },
    delete_sub: usize,
    get_sub: usize,
    publish: struct { topic: usize, first: u32, count: u32, key: u8, attributes: u8 },
    /// Pulls a subscription empty, then gives back the messages whose
    /// number shares no bit with `nack`, and acknowledges the rest.
    drain: struct { sub: usize, nack: u32 },
    snapshot: struct { snap: usize, sub: usize },
    delete_snapshot: usize,
    seek: struct { sub: usize, snap: usize },
    list_topics,
    list_subs,
    list_snaps,
    topic_subs: usize,
};

fn sorted(texts: [][]const u8) []const []const u8 {
    std.mem.sort([]const u8, texts, {}, struct {
        fn lessThan(_: void, x: []const u8, y: []const u8) bool {
            return std.mem.order(u8, x, y) == .lt;
        }
    }.lessThan);
    return texts;
}

/// The number in a message's data, `m12`.
fn numberOf(data: []const u8) u32 {
    return std.fmt.parseInt(u32, data[1..], 10) catch 0;
}

fn run(a: Allocator, side: *Side, ordered: *const [sub_ids.len]bool, op: Op) !Outcome {
    const client = side.client;
    switch (op) {
        .create_topic => |i| {
            var made = client.topic(topic_ids[i]).create(.{}) catch |err| return .{ .failed = err };
            defer made.deinit();
            return .{ .ok = try a.dupe([]const u8, &.{try a.dupe(u8, std.fs.path.basename(made.value.name))}) };
        },
        .delete_topic => |i| {
            client.topic(topic_ids[i]).delete() catch |err| return .{ .failed = err };
            return .{ .ok = &.{} };
        },
        .get_topic => |i| {
            var got = client.topic(topic_ids[i]).get() catch |err| return .{ .failed = err };
            defer got.deinit();
            return .{ .ok = try a.dupe([]const u8, &.{try a.dupe(u8, std.fs.path.basename(got.value.name))}) };
        },
        .create_sub => |c| {
            var made = client.subscription(sub_ids[c.sub]).create(.{
                .topic_id = topic_ids[c.topic],
                .ack_deadline_seconds = 600,
                .enable_message_ordering = kinds[c.kind].ordered,
                .filter = kinds[c.kind].filter,
            }) catch |err| return .{ .failed = err };
            defer made.deinit();
            side.out[c.sub].clearRetainingCapacity();
            return .{ .ok = try describe(a, made.value) };
        },
        .delete_sub => |j| {
            client.subscription(sub_ids[j]).delete() catch |err| return .{ .failed = err };
            return .{ .ok = &.{} };
        },
        .get_sub => |j| {
            var got = client.subscription(sub_ids[j]).get() catch |err| return .{ .failed = err };
            defer got.deinit();
            return .{ .ok = try describe(a, got.value) };
        },
        .publish => |p| {
            const messages = try a.alloc(types.Message, p.count);
            for (messages, 0..) |*m, n| {
                const attributes = try a.alloc(types.Attribute, 2);
                attributes[0] = .{ .key = "kind", .value = if ((p.attributes >> @intCast(n)) & 1 == 0) "a" else "b" };
                attributes[1] = .{ .key = "flag", .value = "set" };
                m.* = .{
                    .data = try std.fmt.allocPrint(a, "m{d}", .{p.first + n}),
                    .attributes = attributes[0 .. 1 + @as(usize, (p.attributes >> @intCast(n + 3)) & 1)],
                };
            }
            const key: ?[]const u8 = ([_]?[]const u8{ null, "k1", "k2" })[p.key];
            var sent = client.topic(topic_ids[p.topic]).publish(messages, .{ .ordering_key = key }) catch |err| return .{ .failed = err };
            defer sent.deinit();
            return .{ .ok = try a.dupe([]const u8, &.{try std.fmt.allocPrint(a, "{d} ids", .{sent.value.message_ids.len})}) };
        },
        .drain => |d| {
            const sub = client.subscription(sub_ids[d.sub]);
            var texts: std.ArrayList([]const u8) = .empty;
            const out = &side.out[d.sub];
            while (true) {
                var got = sub.pull(.{ .max_messages = 1000, .return_immediately = true }) catch |err| return .{ .failed = err };
                defer got.deinit();
                if (got.value.messages.len == 0) break;
                for (got.value.messages) |m| {
                    // With ordering, a key's messages in the order they
                    // came; without, what came, in any order.
                    try texts.append(a, try std.fmt.allocPrint(a, "{s}{s}{s}", .{ m.ordering_key, if (ordered[d.sub]) ">" else "", m.data }));
                    try out.append(a, .{ .data = try a.dupe(u8, m.data), .ack_id = try a.dupe(u8, m.ack_id) });
                }
                // With ordering a key gives no more while one of its
                // messages is out: each round is acknowledged before the
                // next.
                if (ordered[d.sub]) {
                    for (out.items) |o| sub.ack(&.{o.ack_id}) catch |err| return .{ .failed = err };
                    out.clearRetainingCapacity();
                }
            }
            for (out.items) |o| {
                if (numberOf(o.data) & d.nack == 0) {
                    sub.nack(&.{o.ack_id}) catch |err| return .{ .failed = err };
                } else sub.ack(&.{o.ack_id}) catch |err| return .{ .failed = err };
            }
            out.clearRetainingCapacity();
            if (ordered[d.sub]) return .{ .ok = try byKey(a, texts.items) };
            return .{ .ok = sorted(texts.items) };
        },
        .snapshot => |s| {
            var made = client.snapshot(snap_ids[s.snap]).create(.{ .subscription = sub_ids[s.sub] }) catch |err| return .{ .failed = err };
            defer made.deinit();
            return .{ .ok = try a.dupe([]const u8, &.{try a.dupe(u8, std.fs.path.basename(made.value.topic))}) };
        },
        .delete_snapshot => |k| {
            client.snapshot(snap_ids[k]).delete() catch |err| return .{ .failed = err };
            return .{ .ok = &.{} };
        },
        .seek => |s| {
            client.subscription(sub_ids[s.sub]).seek(.{ .snapshot = snap_ids[s.snap] }) catch |err| return .{ .failed = err };
            return .{ .ok = &.{} };
        },
        .list_topics => {
            var page = client.listTopics(.{ .page_size = 1000 }) catch |err| return .{ .failed = err };
            defer page.deinit();
            const names = try a.alloc([]const u8, page.value.topics.len);
            for (page.value.topics, names) |t, *slot| slot.* = try a.dupe(u8, std.fs.path.basename(t.name));
            return .{ .ok = sorted(names) };
        },
        .list_subs => {
            var page = client.listSubscriptions(.{ .page_size = 1000 }) catch |err| return .{ .failed = err };
            defer page.deinit();
            const names = try a.alloc([]const u8, page.value.subscriptions.len);
            for (page.value.subscriptions, names) |s, *slot| slot.* = try a.dupe(u8, std.fs.path.basename(s.name));
            return .{ .ok = sorted(names) };
        },
        .list_snaps => {
            var page = client.listSnapshots(.{ .page_size = 1000 }) catch |err| return .{ .failed = err };
            defer page.deinit();
            const names = try a.alloc([]const u8, page.value.snapshots.len);
            for (page.value.snapshots, names) |s, *slot| slot.* = try a.dupe(u8, std.fs.path.basename(s.name));
            return .{ .ok = sorted(names) };
        },
        .topic_subs => |i| {
            var page = client.topic(topic_ids[i]).listSubscriptions(.{ .page_size = 1000 }) catch |err| return .{ .failed = err };
            defer page.deinit();
            const names = try a.alloc([]const u8, page.value.names.len);
            for (page.value.names, names) |name, *slot| slot.* = try a.dupe(u8, std.fs.path.basename(name));
            return .{ .ok = sorted(names) };
        },
    }
}

/// What both must say of a subscription.
fn describe(a: Allocator, info: types.SubscriptionInfo) ![]const []const u8 {
    return a.dupe([]const u8, &.{
        try a.dupe(u8, std.fs.path.basename(info.name)),
        try a.dupe(u8, std.fs.path.basename(info.topic)),
        try std.fmt.allocPrint(a, "deadline {d}", .{info.ack_deadline_seconds}),
        if (info.enable_message_ordering) "ordered" else "unordered",
        try a.dupe(u8, info.filter),
    });
}

/// The messages of each ordering key, in the order they came: `k1> m3 m7`.
/// Keys come in no order of their own, so they are sorted, and so are the
/// messages that have no key, which have no order either.
fn byKey(a: Allocator, arrivals: []const []const u8) ![]const []const u8 {
    var keys: std.StringArrayHashMapUnmanaged(std.ArrayList([]const u8)) = .empty;
    for (arrivals) |arrival| {
        const cut = std.mem.indexOfScalar(u8, arrival, '>').?;
        const entry = try keys.getOrPutValue(a, arrival[0..cut], .empty);
        try entry.value_ptr.append(a, arrival[cut + 1 ..]);
    }
    const texts = try a.alloc([]const u8, keys.count());
    for (keys.keys(), keys.values(), texts) |key, *list, *slot| {
        if (key.len == 0) _ = sorted(list.items);
        slot.* = try std.fmt.allocPrint(a, "{s}> {s}", .{ key, try std.mem.join(a, " ", list.items) });
    }
    return sorted(texts);
}

fn randomOp(r: std.Random, next_message: *u32) Op {
    const topic = r.uintLessThan(usize, topic_ids.len);
    const sub = r.uintLessThan(usize, sub_ids.len);
    const snap = r.uintLessThan(usize, snap_ids.len);
    return switch (r.uintLessThan(u8, 40)) {
        0...2 => .{ .create_topic = topic },
        3 => .{ .delete_topic = topic },
        4 => .{ .get_topic = topic },
        5...8 => .{ .create_sub = .{ .sub = sub, .topic = topic, .kind = r.uintLessThan(usize, kinds.len) } },
        9 => .{ .delete_sub = sub },
        10 => .{ .get_sub = sub },
        11...20 => publish: {
            const count = r.intRangeAtMost(u32, 1, 3);
            defer next_message.* += count;
            break :publish .{ .publish = .{ .topic = topic, .first = next_message.*, .count = count, .key = r.uintLessThan(u8, 3), .attributes = r.int(u8) } };
        },
        21...30 => .{ .drain = .{ .sub = sub, .nack = r.uintLessThan(u32, 4) } },
        31, 32 => .{ .snapshot = .{ .snap = snap, .sub = sub } },
        33 => .{ .delete_snapshot = snap },
        34, 35 => .{ .seek = .{ .sub = sub, .snap = snap } },
        36 => .list_topics,
        37 => .list_subs,
        38 => .list_snaps,
        else => .{ .topic_subs = topic },
    };
}

test "emulator differential: the fake answers a random script of calls as the emulator does" {
    const gpa = testing.allocator;
    var env = try testing.environ.createMap(gpa);
    defer env.deinit();
    const endpoint = Endpoint.fromEnv(&env) orelse return error.SkipZigTest;
    const seeds: []const u64 = &.{ 0x5eed_f00d, 1, 2, 3, 5, 7, 11, 13 };
    if (env.get("PUBSUB_DIFF_SEED")) |text| {
        try differential(gpa, endpoint, try std.fmt.parseInt(u64, text, 0), false);
    } else for (seeds) |seed| try differential(gpa, endpoint, seed, true);
}

/// One run: a project of its own on the emulator, a fake of its own, and
/// one script of 400 calls to both, which begins by making every topic
/// and a subscription of each kind but two.
fn differential(gpa: Allocator, endpoint: Endpoint, seed: u64, chosen: bool) !void {
    var project_buf: [14]u8 = undefined;
    var random_id: [4]u8 = undefined;
    testing.io.random(&random_id);
    const project = try std.fmt.bufPrint(&project_buf, "zigps-{x}", .{random_id});
    var diag: core.Diagnostics = .{};
    var emulator: Client = try .init(gpa, testing.io, .{ .project_id = project, .endpoint = endpoint, .diagnostics = &diag });
    defer emulator.deinit();
    var fake: FakePubSub = .init(gpa, testing.io, .{});
    defer fake.deinit();
    var token: core.StaticToken = .{ .token = "fake" };
    var fake_diag: core.Diagnostics = .{};
    var other: Client = try .init(gpa, testing.io, .{
        .project_id = project,
        .token_provider = token.provider(),
        .transport = fake.transport(),
        .diagnostics = &fake_diag,
    });
    defer other.deinit();
    defer clear(&emulator);

    var prng: std.Random.DefaultPrng = .init(seed);
    const r = prng.random();
    var arena_state: std.heap.ArenaAllocator = .init(gpa);
    defer arena_state.deinit();
    const a = arena_state.allocator();

    var sides: [2]Side = .{ .{ .client = &emulator }, .{ .client = &other } };
    var ordered: [sub_ids.len]bool = @splat(false);
    // How many times each subscription has been made, and which making
    // of which subscription each snapshot was taken of.
    var made: [sub_ids.len]u32 = @splat(0);
    var taken_of: [snap_ids.len]?struct { sub: usize, made: u32 } = @splat(null);
    // Which topics are there, and whether each subscription's topic
    // still is.
    var there: [topic_ids.len]bool = @splat(false);
    var topic_of: [sub_ids.len]?usize = @splat(null);
    var next_message: u32 = 0;
    var script: std.ArrayList(Op) = .empty;
    var went_through: usize = 0;
    var drained: usize = 0;
    for (0..400) |step| {
        const op: Op = if (step < topic_ids.len)
            .{ .create_topic = step }
        else if (step < topic_ids.len + sub_ids.len)
            .{ .create_sub = .{ .sub = step - topic_ids.len, .topic = r.uintLessThan(usize, topic_ids.len), .kind = step - topic_ids.len } }
        else
            randomOp(r, &next_message);
        switch (op) {
            // Only to a snapshot taken of this very subscription, or to
            // one that is not there.
            .seek => |s| if (taken_of[s.snap]) |source| {
                if (source.sub != s.sub or source.made != made[s.sub]) continue;
                // Nor once their topic is gone: the emulator then holds
                // the subscription's topic and the snapshot's to be two.
                if (topic_of[s.sub] == null) continue;
            },
            // Not of a subscription whose topic is gone: production
            // refuses one, and the emulator takes it.
            .snapshot => |s| if (made[s.sub] > 0 and topic_of[s.sub] == null) continue,
            // Of a topic that is not there production's list is 404, and
            // the emulator's an empty one (measured 2026-10-10).
            .topic_subs => |i| if (!there[i]) continue,
            else => {},
        }
        try script.append(a, op);
        const first = try run(a, &sides[0], &ordered, op);
        const second = try run(a, &sides[1], &ordered, op);
        Outcome.expectEqual(first, second) catch |err| {
            std.debug.print("seed {d}: the two part at call {d} of this script:\n", .{ seed, script.items.len });
            for (script.items) |done| std.debug.print("  {any}\n", .{done});
            std.debug.print("emulator: {any} ({s})\nfake: {any} ({s})\n", .{ first, diag.message(), second, fake_diag.message() });
            return err;
        };
        if (first == .ok) went_through += 1;
        if (op == .drain and first == .ok) drained += first.ok.len;
        // What the script knows of a subscription, for the calls after.
        switch (op) {
            .create_sub => |c| if (first == .ok) {
                ordered[c.sub] = kinds[c.kind].ordered;
                made[c.sub] += 1;
                topic_of[c.sub] = c.topic;
            },
            .create_topic => |i| if (first == .ok) {
                there[i] = true;
            },
            .delete_topic => |i| if (first == .ok) {
                there[i] = false;
                for (&topic_of) |*of| {
                    if (of.* == i) of.* = null;
                }
            },
            .snapshot => |s| if (first == .ok) {
                taken_of[s.snap] = .{ .sub = s.sub, .made = made[s.sub] };
            },
            .delete_snapshot => |k| if (first == .ok) {
                taken_of[k] = null;
            },
            else => {},
        }
    }
    // A script that agreed on refusals alone would have shown nothing:
    // the seeds this test runs by itself are held to doing work.
    if (chosen and (went_through < 150 or drained < 30)) {
        std.debug.print("seed {d}: {d} calls of 400 went through, and {d} messages were pulled\n", .{ seed, went_through, drained });
        return error.TheScriptDidTooLittle;
    }
}

/// Leaves the emulator as it was found: a run's project is its own.
fn clear(emulator: *Client) void {
    for (snap_ids) |id| emulator.snapshot(id).delete() catch {};
    for (sub_ids) |id| emulator.subscription(id).delete() catch {};
    for (topic_ids) |id| emulator.topic(id).delete() catch {};
}
