//! A tail by polling: the newest entries of a filter, each once, as they
//! arrive. Milestone 0 found REST tail unusable over HTTP/1.1, so this is
//! the tail: `entries.list` again and again, over a window that moves.
//!
//! Each `poll` makes one fresh query, oldest first, bounded by literal
//! times: from the cursor less `overlap_ms`, for entries that arrived late,
//! to now less `settle_ms`, so the newest have time to come in. It drains
//! the window's pages up to `max_calls_per_poll`, drops what it returned
//! before (by log name, timestamp and insertId, the server's own key for
//! duplicates, which it applies only within one result), and moves the
//! cursor: to the end of the window when the window was drained, or to the
//! last entry returned when calls ran out, which `behind` reports.
//!
//! An entry that arrives later than the overlap is never returned: every
//! poller has that trade, gcloud's included. `stats().latest_late_ms` says
//! how close the latest late one came. The keys kept against duplicates
//! are those of the overlap, at most `max_seen`: past that many entries in
//! one overlap, the oldest keys go, and their entries can come twice.
//!
//! A tail borrows its client and must not outlive it, nor be used from
//! two tasks at once.

const Tail = @This();

const std = @import("std");
const Allocator = std.mem.Allocator;
const core = @import("core");

const Client = @import("Client.zig");
const errors = @import("errors.zig");
const types = @import("types.zig");
const Error = errors.Error;

client: *Client,
/// Holds the options' copies.
arena: std.heap.ArenaAllocator,
options: types.TailOptions,
/// Entries before this are never returned: the tail's start.
begin_ns: i96,
/// Where the next window starts, before the overlap.
cursor_ns: i96,
/// The insertId of the last entry returned at `cursor_ns`, when calls ran
/// out mid-window; "" after a drained window.
cursor_insert_id: std.ArrayList(u8) = .empty,
/// The last poll ran out of calls: the next reads on from the cursor
/// itself, without the overlap, to catch up.
was_behind: bool = false,
/// Keys returned within the overlap, so a second sight is dropped; in
/// `seen_order` oldest first, for pruning.
seen: std.StringHashMapUnmanaged(i96) = .empty,
seen_order: std.ArrayList([]u8) = .empty,
seen_head: usize = 0,
counters: types.TailStats = .{},
/// The most keys kept for de-duplication; past it the oldest go first.
seen_cap: usize = max_seen,

pub const max_seen = 100_000;

pub fn init(client: *Client, options: types.TailOptions) Error!Tail {
    const diag = client.diagnostics;
    if (diag) |d| d.clear();
    if (options.overlap_ms < options.settle_ms) {
        if (diag) |d| d.print("invalid tail options: overlap_ms must be at least settle_ms", .{});
        return error.InvalidOptions;
    }
    if (options.max_calls_per_poll == 0 or options.page_size == 0) {
        if (diag) |d| d.print("invalid tail options: max_calls_per_poll and page_size must be at least 1", .{});
        return error.InvalidOptions;
    }
    var arena: std.heap.ArenaAllocator = .init(client.gpa);
    errdefer arena.deinit();
    const a = arena.allocator();
    var copied = options;
    copied.filter = try a.dupe(u8, options.filter);
    if (options.log_id) |v| copied.log_id = try a.dupe(u8, v);
    if (options.resource_type) |v| copied.resource_type = try a.dupe(u8, v);
    copied.scopes = try copyScopes(a, options.scopes);
    copied.from = null;
    // Checked once here, as each poll's query would check it.
    var probe = try client.query(queryOptions(copied, 0, 1));
    probe.deinit();

    const now = std.Io.Clock.real.now(client.io).nanoseconds;
    var tail: Tail = .{
        .client = client,
        .arena = arena,
        .options = copied,
        .begin_ns = if (options.from) |f| f.timestamp.nanoseconds else now - @as(i96, options.settle_ms) * std.time.ns_per_ms,
        .cursor_ns = undefined,
    };
    tail.cursor_ns = tail.begin_ns;
    if (options.from) |f| {
        try tail.cursor_insert_id.appendSlice(client.gpa, f.insert_id);
        // A kept cursor resumes as if calls had run out there: from the
        // cursor itself, with no overlap of what the last run returned.
        tail.was_behind = f.insert_id.len > 0;
    }
    return tail;
}

pub fn deinit(self: *Tail) void {
    const gpa = self.client.gpa;
    for (self.seen_order.items[self.seen_head..]) |key| gpa.free(key);
    self.seen_order.deinit(gpa);
    self.seen.deinit(gpa);
    self.cursor_insert_id.deinit(gpa);
    self.arena.deinit();
    self.* = undefined;
}

/// Where the next poll begins, to keep and resume from. Valid until the
/// next poll.
pub fn cursor(self: *const Tail) types.Cursor {
    return .{ .timestamp = .{ .nanoseconds = self.cursor_ns }, .insert_id = self.cursor_insert_id.items };
}

pub fn stats(self: *const Tail) types.TailStats {
    return self.counters;
}

/// One poll: entries not returned before, oldest first. Makes 0 to
/// `max_calls_per_poll` calls: none when the window has not opened yet.
/// When the read budget or the server's quota stops it, or a call fails
/// after entries came, it returns what it has with `stopped` set; a first
/// call that fails otherwise is the error.
pub fn poll(self: *Tail) Error!types.Owned(types.TailBatch) {
    const client = self.client;
    var result: types.Owned(types.TailBatch) = try .init(client.gpa);
    errdefer result.deinit();
    const a = result.arena.allocator();
    self.counters.polls += 1;

    const now = std.Io.Clock.real.now(client.io).nanoseconds;
    const upper = now - @as(i96, self.options.settle_ms) * std.time.ns_per_ms;
    const overlap: i96 = if (self.was_behind) 0 else @as(i96, self.options.overlap_ms) * std.time.ns_per_ms;
    const lower = @max(self.begin_ns, self.cursor_ns - overlap);
    const cursor_at_start = self.cursor_ns;
    // Reading on from a cursor that stopped partway through a timestamp:
    // what came at that timestamp up to its entry was returned already,
    // by this tail or by the one whose cursor was kept. The server orders
    // ties by insertId.
    const returned_through: ?[]const u8 = if (self.was_behind and self.cursor_insert_id.items.len > 0)
        try a.dupe(u8, self.cursor_insert_id.items)
    else
        null;
    if (upper <= lower) {
        result.value = .{ .entries = &.{}, .behind = false, .stopped = null };
        return result;
    }

    var q = try client.query(queryOptions(self.options, lower, upper));
    defer q.deinit();
    var out: std.ArrayList(types.Entry) = .empty;
    var token: ?[]const u8 = null;
    var calls: u32 = 0;
    var last: ?struct { ns: i96, insert_id: []const u8 } = null;
    var stopped: ?anyerror = null;
    var drained = false;
    while (calls < self.options.max_calls_per_poll) {
        calls += 1;
        self.counters.calls += 1;
        var page = q.page(token) catch |err| {
            if (out.items.len == 0 and calls == 1 and err != error.ResourceExhausted) return err;
            stopped = err;
            break;
        };
        defer page.deinit();
        for (page.value.entries) |e| {
            last = .{ .ns = e.timestamp.nanoseconds, .insert_id = try a.dupe(u8, e.insert_id) };
            if (returned_through) |id| if (e.timestamp.nanoseconds == cursor_at_start and std.mem.order(u8, e.insert_id, id) != .gt) {
                self.counters.duplicates += 1;
                continue;
            };
            const key = try keyOf(client.gpa, e);
            if (self.seen.contains(key)) {
                client.gpa.free(key);
                self.counters.duplicates += 1;
                continue;
            }
            try self.remember(key, e.timestamp.nanoseconds);
            if (e.timestamp.nanoseconds < cursor_at_start) {
                self.counters.late += 1;
                const late_ms: u64 = @intCast(@divFloor(cursor_at_start - e.timestamp.nanoseconds, std.time.ns_per_ms));
                self.counters.latest_late_ms = @max(self.counters.latest_late_ms, late_ms);
            }
            try out.append(a, try copyEntry(a, e));
        }
        token = if (page.value.next_page_token) |t| try a.dupe(u8, t) else {
            drained = true;
            break;
        };
    }
    self.counters.entries += out.items.len;

    if (drained) {
        self.cursor_ns = upper;
        self.cursor_insert_id.clearRetainingCapacity();
        self.was_behind = false;
    } else if (last) |l| {
        self.cursor_ns = l.ns;
        self.cursor_insert_id.clearRetainingCapacity();
        try self.cursor_insert_id.appendSlice(client.gpa, l.insert_id);
        self.was_behind = true;
    } else {
        // Nothing came and calls ran out, or the first was refused: the
        // next poll tries the same window again.
        self.was_behind = stopped == null;
    }
    self.prune(self.cursor_ns - @as(i96, self.options.overlap_ms) * std.time.ns_per_ms);
    result.value = .{ .entries = out.items, .behind = !drained and stopped == null, .stopped = stopped };
    return result;
}

fn queryOptions(o: types.TailOptions, lower: i96, upper: i96) types.QueryOptions {
    return .{
        .scopes = o.scopes,
        .filter = o.filter,
        .since = if (upper > lower) .{ .nanoseconds = lower } else null,
        .until = if (upper > lower) .{ .nanoseconds = upper } else null,
        .min_severity = o.min_severity,
        .log_id = o.log_id,
        .resource_type = o.resource_type,
        .order = .oldest_first,
        .page_size = o.page_size,
        .server_timeout_s = o.server_timeout_s,
    };
}

/// The server's key for a duplicate, with the log name for the project.
fn keyOf(gpa: Allocator, e: types.Entry) Allocator.Error![]u8 {
    return std.fmt.allocPrint(gpa, "{s}\x00{d}\x00{s}", .{ e.log_name, e.timestamp.nanoseconds, e.insert_id });
}

fn remember(self: *Tail, key: []u8, ns: i96) Allocator.Error!void {
    const gpa = self.client.gpa;
    errdefer gpa.free(key);
    try self.seen_order.ensureUnusedCapacity(gpa, 1);
    try self.seen.put(gpa, key, ns);
    self.seen_order.appendAssumeCapacity(key);
    if (self.seen.count() > self.seen_cap) self.dropOldest();
}

fn dropOldest(self: *Tail) void {
    const key = self.seen_order.items[self.seen_head];
    _ = self.seen.remove(key);
    self.client.gpa.free(key);
    self.seen_head += 1;
}

/// Forgets keys older than the next window: they cannot come again.
fn prune(self: *Tail, bound: i96) void {
    while (self.seen_head < self.seen_order.items.len) {
        const key = self.seen_order.items[self.seen_head];
        const ns = self.seen.get(key).?;
        if (ns >= bound) break;
        self.dropOldest();
    }
    // Compact now and then, so the order list does not grow without end.
    if (self.seen_head > 1024 and self.seen_head * 2 > self.seen_order.items.len) {
        const rest = self.seen_order.items[self.seen_head..];
        std.mem.copyForwards([]u8, self.seen_order.items[0..rest.len], rest);
        self.seen_order.shrinkRetainingCapacity(rest.len);
        self.seen_head = 0;
    }
}

fn copyScopes(a: Allocator, scopes: []const types.Scope) Allocator.Error![]const types.Scope {
    const out = try a.alloc(types.Scope, scopes.len);
    for (scopes, out) |s, *o| o.* = switch (s) {
        .parent => |p| .{ .parent = try copyParent(a, p) },
        .view => |v| .{ .view = .{ .parent = try copyParent(a, v.parent), .location = try a.dupe(u8, v.location), .bucket = try a.dupe(u8, v.bucket), .view = try a.dupe(u8, v.view) } },
    };
    return out;
}

fn copyParent(a: Allocator, p: types.Parent) Allocator.Error!types.Parent {
    return switch (p) {
        .project => |id| .{ .project = try a.dupe(u8, id) },
        .folder => |id| .{ .folder = try a.dupe(u8, id) },
        .organization => |id| .{ .organization = try a.dupe(u8, id) },
        .billing_account => |id| .{ .billing_account = try a.dupe(u8, id) },
    };
}

fn copyLabels(a: Allocator, labels: []const types.Label) Allocator.Error![]const types.Label {
    const out = try a.alloc(types.Label, labels.len);
    for (labels, out) |l, *o| o.* = .{ .key = try a.dupe(u8, l.key), .value = try a.dupe(u8, l.value) };
    return out;
}

/// `e` in `a`: every string its own, the payload pointing into the copied
/// raw bytes as it pointed into the page's.
fn copyEntry(a: Allocator, e: types.Entry) Allocator.Error!types.Entry {
    var out = e;
    const raw = try a.dupe(u8, e.raw);
    out.raw = raw;
    out.log_name = try a.dupe(u8, e.log_name);
    out.log_id = try a.dupe(u8, e.log_id);
    out.resource_type = try a.dupe(u8, e.resource_type);
    out.resource_labels = try copyLabels(a, e.resource_labels);
    out.insert_id = try a.dupe(u8, e.insert_id);
    out.labels = try copyLabels(a, e.labels);
    out.trace = try a.dupe(u8, e.trace);
    out.span_id = try a.dupe(u8, e.span_id);
    out.payload = switch (e.payload) {
        .none => .none,
        .text => |t| .{ .text = try a.dupe(u8, t) },
        .json => |j| .{ .json = within(e.raw, raw, j) },
        .proto => |p| .{ .proto = .{ .type_url = try a.dupe(u8, p.type_url), .json = within(e.raw, raw, p.json) } },
    };
    if (e.http_request) |h| {
        var c = h;
        c.method = try a.dupe(u8, h.method);
        c.url = try a.dupe(u8, h.url);
        c.user_agent = try a.dupe(u8, h.user_agent);
        c.remote_ip = try a.dupe(u8, h.remote_ip);
        c.server_ip = try a.dupe(u8, h.server_ip);
        c.referer = try a.dupe(u8, h.referer);
        c.protocol = try a.dupe(u8, h.protocol);
        out.http_request = c;
    }
    if (e.operation) |o| out.operation = .{ .id = try a.dupe(u8, o.id), .producer = try a.dupe(u8, o.producer), .first = o.first, .last = o.last };
    if (e.source_location) |s| out.source_location = .{ .file = try a.dupe(u8, s.file), .line = s.line, .function = try a.dupe(u8, s.function) };
    if (e.split) |s| out.split = .{ .uid = try a.dupe(u8, s.uid), .index = s.index, .total = s.total };
    return out;
}

/// The slice of `copy` where `part` lies in `original`.
fn within(original: []const u8, copy: []const u8, part: []const u8) []const u8 {
    const offset = @intFromPtr(part.ptr) - @intFromPtr(original.ptr);
    return copy[offset..][0..part.len];
}

const testing = std.testing;
const test_util = @import("test_util.zig");
const FakeLogging = @import("fake_logging.zig").FakeLogging;

const base_s: i96 = 1_792_141_200;

fn at(s: i96) std.Io.Timestamp {
    return .{ .nanoseconds = (base_s + s) * std.time.ns_per_s };
}

/// A client and a fake on one clock a test moves, in seconds from base_s.
const Rig = struct {
    clock: test_util.FakeClock,
    fake: FakeLogging,
    token: test_util.FakeTokenProvider,
    diag: core.Diagnostics,
    client: Client,

    fn init(r: *Rig, read_calls_per_minute: u32) !void {
        return r.initWith(testing.allocator, read_calls_per_minute);
    }

    fn initWith(r: *Rig, gpa: Allocator, read_calls_per_minute: u32) !void {
        r.* = .{ .clock = .{ .now_ns = base_s * std.time.ns_per_s }, .fake = undefined, .token = .{}, .diag = .{}, .client = undefined };
        r.fake = .init(gpa, r.clock.io());
        errdefer r.fake.deinit();
        r.client = try .init(gpa, r.clock.io(), .{
            .project_id = "p",
            .token_provider = r.token.provider(),
            .transport = r.fake.transport(),
            .diagnostics = &r.diag,
            .read_calls_per_minute = read_calls_per_minute,
        });
    }

    fn deinit(r: *Rig) void {
        r.client.deinit();
        r.fake.deinit();
    }

    fn now(r: *Rig, s: i96) void {
        r.clock.now_ns = (base_s + s) * std.time.ns_per_s;
    }

    /// An entry stamped at `ts`, visible from `visible`, both in seconds.
    fn write(r: *Rig, id: []const u8, ts: i96, visible: i96) !void {
        try r.fake.write(.{
            .log_name = "projects/p/logs/app",
            .timestamp = at(ts),
            .receive_timestamp = at(visible),
            .insert_id = id,
            .payload = .{ .json = "{\"n\":1}" },
        });
    }

    /// The insert ids one poll returns, joined by spaces.
    fn poll(r: *Rig, tail: *Tail, out: *std.ArrayList(u8)) !types.TailBatch {
        out.clearRetainingCapacity();
        var batch = try tail.poll();
        defer batch.deinit();
        for (batch.value.entries, 0..) |e, i| {
            if (i > 0) try out.append(testing.allocator, ' ');
            try out.appendSlice(testing.allocator, e.insert_id);
            // The payload still points into the entry's own raw bytes.
            try testing.expect(std.mem.indexOf(u8, e.raw, e.payload.json) != null);
        }
        _ = r;
        return .{ .entries = &.{}, .behind = batch.value.behind, .stopped = batch.value.stopped };
    }
};

test "tail: each entry once, after it settles, and nothing from before the tail began" {
    var r: Rig = undefined;
    try r.init(0);
    defer r.deinit();
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(testing.allocator);
    try r.write("before", -30, -29);
    var tail = try r.client.tail(.{ .settle_ms = 5_000, .overlap_ms = 60_000 });
    defer tail.deinit();
    // The window opens at -5 s; nothing is there yet.
    r.now(1);
    _ = try r.poll(&tail, &out);
    try testing.expectEqualStrings("", out.items);
    try r.write("a", 2, 2);
    try r.write("b", 3, 3);
    // At 6 s, the window ends at 1 s: a and b have not settled.
    r.now(6);
    _ = try r.poll(&tail, &out);
    try testing.expectEqualStrings("", out.items);
    r.now(9);
    _ = try r.poll(&tail, &out);
    try testing.expectEqualStrings("a b", out.items);
    // A drained window moves the cursor to its end.
    try testing.expectEqual(at(4).nanoseconds, tail.cursor().timestamp.nanoseconds);
    try testing.expectEqualStrings("", tail.cursor().insert_id);
    // Again: the overlap reads them, and they are dropped.
    r.now(20);
    try r.write("c", 12, 12);
    _ = try r.poll(&tail, &out);
    try testing.expectEqualStrings("c", out.items);
    const s = tail.stats();
    try testing.expectEqual(4, s.polls);
    try testing.expectEqual(3, s.entries);
    try testing.expectEqual(2, s.duplicates);
    try testing.expectEqual(0, s.late);
}

test "tail: a late entry inside the overlap comes, counted late; one past it never does" {
    var r: Rig = undefined;
    try r.init(0);
    defer r.deinit();
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(testing.allocator);
    var tail = try r.client.tail(.{ .settle_ms = 5_000, .overlap_ms = 30_000 });
    defer tail.deinit();
    try r.write("on-time", 10, 10);
    r.now(20);
    _ = try r.poll(&tail, &out);
    try testing.expectEqualStrings("on-time", out.items);
    // The cursor is at 15 s. One stamped 11 s arrives at 25 s.
    try r.write("late", 11, 25);
    r.now(30);
    _ = try r.poll(&tail, &out);
    try testing.expectEqualStrings("late", out.items);
    try testing.expectEqual(1, tail.stats().late);
    try testing.expectEqual(4_000, tail.stats().latest_late_ms);
    // The cursor is at 25 s. One stamped 20 s comes in at 85 s: by then the
    // windows start at 25 s, past the overlap of 30 s, and never reach it.
    try r.write("too-late", 20, 85);
    r.now(60);
    _ = try r.poll(&tail, &out);
    try testing.expectEqualStrings("", out.items);
    r.now(90);
    _ = try r.poll(&tail, &out);
    try testing.expectEqualStrings("", out.items);
}

test "tail: behind when calls run out, then on from the cursor without the overlap, each entry once" {
    var r: Rig = undefined;
    try r.init(0);
    defer r.deinit();
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(testing.allocator);
    var tail = try r.client.tail(.{ .page_size = 2, .max_calls_per_poll = 2 });
    defer tail.deinit();
    for (0..9) |i| try r.write(&.{@as(u8, 'a') + @as(u8, @intCast(i))}, @intCast(i), @intCast(i));
    r.now(30);
    const first = try r.poll(&tail, &out);
    try testing.expectEqualStrings("a b c d", out.items);
    try testing.expect(first.behind);
    try testing.expectEqualStrings("d", tail.cursor().insert_id);
    var all: std.ArrayList(u8) = .empty;
    defer all.deinit(testing.allocator);
    try all.appendSlice(testing.allocator, out.items);
    var polls: usize = 0;
    while (polls < 10) : (polls += 1) {
        const b = try r.poll(&tail, &out);
        if (out.items.len > 0) {
            try all.append(testing.allocator, ' ');
            try all.appendSlice(testing.allocator, out.items);
        }
        if (!b.behind) break;
    }
    try testing.expectEqualStrings("a b c d e f g h i", all.items);
    try testing.expectEqualStrings("", tail.cursor().insert_id);
}

test "tail: resumes from a kept cursor, and stops on a spent budget without losing anything" {
    var r: Rig = undefined;
    try r.init(1);
    defer r.deinit();
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(testing.allocator);
    try r.write("x", -100, -100);
    try r.write("y", -50, -50);
    try r.write("z", -20, -20);
    var tail = try r.client.tail(.{ .from = .{ .timestamp = at(-60) } });
    defer tail.deinit();
    r.now(10);
    _ = try r.poll(&tail, &out);
    try testing.expectEqualStrings("y z", out.items);
    // One call a minute: the next poll is refused here, unsent.
    try r.write("w", 7, 7);
    r.now(20);
    const refused = try r.poll(&tail, &out);
    try testing.expectEqualStrings("", out.items);
    try testing.expectEqual(error.ResourceExhausted, refused.stopped.?);
    r.now(80);
    _ = try r.poll(&tail, &out);
    try testing.expectEqualStrings("w", out.items);
    // A cursor kept mid-window resumes after its entry, with no overlap.
    var resumed = try r.client.tail(.{ .from = .{ .timestamp = at(-50), .insert_id = "y" } });
    defer resumed.deinit();
    r.now(150);
    _ = try r.poll(&resumed, &out);
    try testing.expectEqualStrings("z w", out.items);
}

test "tail: a first call that fails is the error; a later one stops the poll with what came" {
    var r: Rig = undefined;
    try r.init(0);
    defer r.deinit();
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(testing.allocator);
    var tail = try r.client.tail(.{ .page_size = 1, .max_calls_per_poll = 3 });
    defer tail.deinit();
    try r.write("a", 1, 1);
    try r.write("b", 2, 2);
    r.now(20);
    r.fake.refuseNext(1, 403);
    try testing.expectError(error.PermissionDenied, tail.poll());
    // The cursor did not move: the next poll reads the same window.
    try testing.expectEqual(at(-5).nanoseconds, tail.cursor().timestamp.nanoseconds);
    r.fake.shortenNext(1, 1);
    var batch = try tail.poll();
    defer batch.deinit();
    try testing.expectEqual(2, batch.value.entries.len);
    // Two pages of one: a, then b, and a third call that drains.
}

test "tail: options it refuses, and a window not open yet costs no call" {
    var r: Rig = undefined;
    try r.init(0);
    defer r.deinit();
    try testing.expectError(error.InvalidOptions, r.client.tail(.{ .settle_ms = 10_000, .overlap_ms = 5_000 }));
    try testing.expectError(error.InvalidOptions, r.client.tail(.{ .max_calls_per_poll = 0 }));
    try testing.expectError(error.InvalidOptions, r.client.tail(.{ .page_size = 0 }));
    try testing.expectError(error.InvalidFilter, r.client.tail(.{ .log_id = "a\nb" }));
    try testing.expectError(error.InvalidScope, r.client.tail(.{ .scopes = &.{.{ .parent = .{ .folder = "x" } }} }));
    var tail = try r.client.tail(.{});
    defer tail.deinit();
    var batch = try tail.poll();
    defer batch.deinit();
    try testing.expectEqual(0, batch.value.entries.len);
    try testing.expectEqual(0, tail.stats().calls);
    try testing.expectEqual(0, r.fake.listCalls());
}

test "tail: past the cap, the oldest keys go, and their entries can come again" {
    var r: Rig = undefined;
    try r.init(0);
    defer r.deinit();
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(testing.allocator);
    var tail = try r.client.tail(.{ .settle_ms = 1_000, .overlap_ms = 60_000 });
    defer tail.deinit();
    tail.seen_cap = 3;
    for (0..5) |i| try r.write(&.{@as(u8, 'a') + @as(u8, @intCast(i))}, @intCast(i), @intCast(i));
    r.now(10);
    _ = try r.poll(&tail, &out);
    try testing.expectEqualStrings("a b c d e", out.items);
    try testing.expectEqual(3, tail.seen.count());
    // The overlap reads all five again; each one taken back in pushes an
    // older key out, so all five come twice. Memory stays at the cap.
    r.now(20);
    _ = try r.poll(&tail, &out);
    try testing.expectEqualStrings("a b c d e", out.items);
    try testing.expectEqual(3, tail.seen.count());
}

test "tail: keys older than the window are forgotten" {
    var r: Rig = undefined;
    try r.init(0);
    defer r.deinit();
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(testing.allocator);
    var tail = try r.client.tail(.{ .settle_ms = 1_000, .overlap_ms = 10_000 });
    defer tail.deinit();
    for (0..50) |i| try r.write(try std.fmt.allocPrint(r.fake.store.allocator(), "e{d}", .{i}), @intCast(i), @intCast(i));
    var s: i96 = 5;
    while (s <= 120) : (s += 5) {
        r.now(s);
        _ = try r.poll(&tail, &out);
    }
    try testing.expectEqual(50, tail.stats().entries);
    // Only keys inside the last window are kept.
    try testing.expectEqual(0, tail.seen.count());
}

test "tail: every allocation failure in a poll is OutOfMemory without leaks" {
    const Run = struct {
        fn run(gpa: Allocator) !void {
            var clock: test_util.FakeClock = .{ .now_ns = base_s * std.time.ns_per_s };
            var fake: FakeLogging = .init(testing.allocator, clock.io());
            defer fake.deinit();
            for (0..3) |i| try fake.write(.{ .log_name = "projects/p/logs/a", .timestamp = at(@intCast(i)), .payload = .{ .json = "{\"k\":1}" }, .labels = &.{.{ .key = "a", .value = "b" }}, .resource_labels = &.{.{ .key = "c", .value = "d" }} });
            var token: test_util.FakeTokenProvider = .{};
            var client = try Client.init(gpa, clock.io(), .{ .project_id = "p", .token_provider = token.provider(), .transport = fake.transport(), .read_calls_per_minute = 0 });
            defer client.deinit();
            var tail = try client.tail(.{ .from = .{ .timestamp = at(-1) }, .page_size = 2 });
            defer tail.deinit();
            clock.now_ns = at(20).nanoseconds;
            var batch = try tail.poll();
            batch.deinit();
        }
    };
    try testing.checkAllAllocationFailures(test_util.no_grow_allocator, Run.run, .{});
}

const Arrival = struct { id: [4]u8, ts_ms: i64, visible_ms: i64 };

fn tailProperty(_: void, input: []const u8) !void {
    var g: test_util.ByteGen = .init(input);
    var r: Rig = undefined;
    try r.initWith(test_util.propertyAllocator(), 0);
    defer r.deinit();
    const settle_s: i64 = g.pick(i64, &.{ 1, 2, 5 });
    const overlap_s: i64 = settle_s + g.pick(i64, &.{ 0, 5, 20 });
    var tail = try r.client.tail(.{
        .settle_ms = @intCast(settle_s * 1000),
        .overlap_ms = @intCast(overlap_s * 1000),
        .page_size = g.intRange(u32, 1, 4),
        .max_calls_per_poll = g.intRange(u32, 1, 3),
    });
    defer tail.deinit();
    const begin_ms: i64 = -settle_s * 1000;

    // Entries stamped from 10 s before the tail to 2 minutes after,
    // arriving after a delay of up to twice the overlap.
    var arrivals: [40]Arrival = undefined;
    const n = g.intRange(usize, 0, arrivals.len);
    for (arrivals[0..n], 0..) |*a, i| {
        const ts_ms: i64 = @as(i64, g.intRange(u32, 0, 130_000)) - 10_000;
        // Some share a timestamp.
        const ts = if (i > 0 and g.int(u8) < 40) arrivals[i - 1].ts_ms else ts_ms;
        const delay: i64 = g.intRange(u32, 0, @intCast(overlap_s * 2000));
        a.* = .{ .id = .{ 'e', '0' + @as(u8, @intCast(i / 10)), '0' + @as(u8, @intCast(i % 10)), 0 }, .ts_ms = ts, .visible_ms = ts + delay };
        try r.fake.write(.{
            .log_name = "projects/p/logs/app",
            .timestamp = .{ .nanoseconds = (base_s * 1000 + ts) * std.time.ns_per_ms },
            .receive_timestamp = .{ .nanoseconds = (base_s * 1000 + a.visible_ms) * std.time.ns_per_ms },
            .insert_id = a.id[0..3],
        });
    }

    var returned: [40]bool = @splat(false);
    var clean = true;
    var now_ms: i64 = 0;
    while (now_ms < 400_000) : (now_ms += @as(i64, g.intRange(u32, 500, 10_000))) {
        r.clock.now_ns = (base_s * 1000 + now_ms) * std.time.ns_per_ms;
        var batch = try tail.poll();
        defer batch.deinit();
        if (batch.value.behind or batch.value.stopped != null) clean = false;
        for (batch.value.entries) |e| {
            const i = (e.insert_id[1] - '0') * 10 + (e.insert_id[2] - '0');
            const a = arrivals[i];
            // Never twice, never before it is there, settled, and after
            // the tail began.
            try testing.expect(!returned[i]);
            returned[i] = true;
            try testing.expect(a.ts_ms >= begin_ms);
            try testing.expect(a.visible_ms <= now_ms);
            try testing.expect(a.ts_ms < now_ms - settle_s * 1000);
        }
    }
    // Every entry from the tail's start that arrived within the overlap
    // and the settle time came, when no poll fell behind or stopped.
    if (!clean) return;
    for (arrivals[0..n], returned[0..n]) |a, got| {
        if (a.ts_ms < begin_ms) continue;
        if (a.visible_ms - a.ts_ms > (overlap_s + settle_s) * 1000) continue;
        if (!got) {
            std.debug.print("missed {s}: stamped {d} ms, visible {d} ms, settle {d} s, overlap {d} s\n", .{ a.id[0..3], a.ts_ms, a.visible_ms, settle_s, overlap_s });
            return error.TestEntryMissed;
        }
    }
}

test "slow property Tail: each entry once, never early, none missed within the overlap" {
    try test_util.fuzzBytes({}, tailProperty, .{
        .corpus = &.{ "", "\x00\x00\x03\x03\x28", "\x02\x02\x01\x01\x10\xff\xff\x00\x00\x40" },
        // Each run polls through some 400 s of entries; the nightly
        // `slow-logging` job fuzzes it far longer.
        .random_runs = 12,
        .max_len = 400,
    });
}

test "tail: every scope kind, and entries of every shape, copied out of their pages" {
    const page =
        \\{"entries":[{"timestamp":"2026-10-16T09:00:01Z","insertId":"p","logName":"folders/1/logs/a",
        \\ "protoPayload":{"@type":"type.googleapis.com/google.cloud.audit.AuditLog","methodName":"m"},
        \\ "httpRequest":{"requestMethod":"GET","requestUrl":"u","status":200,"userAgent":"ua","remoteIp":"r","serverIp":"s","referer":"f","protocol":"HTTP/2"},
        \\ "operation":{"id":"o","producer":"pr","first":true},"sourceLocation":{"file":"x.zig","line":"3","function":"f"},
        \\ "split":{"uid":"u1","index":1,"totalSplits":2},"labels":{"k":"v"},"resource":{"type":"t","labels":{"a":"b"}},"trace":"tr","spanId":"sp"},
        \\ {"timestamp":"2026-10-16T09:00:02Z","insertId":"t","logName":"folders/1/logs/a","textPayload":"hello"}]}
    ;
    var h: test_util.Harness = undefined;
    try h.init(&.{.{ .respond = .{ .body = page } }}, .{});
    defer h.deinit();
    var tail = try h.client.tail(.{
        .scopes = &.{
            .{ .parent = .{ .folder = "1" } },
            .{ .parent = .{ .organization = "2" } },
            .{ .parent = .{ .billing_account = "012345-567890-ABCDEF" } },
            .{ .parent = .{ .project = "p" } },
            .{ .view = .{ .parent = .{ .project = "p" }, .location = "global", .bucket = "_Default", .view = "_AllLogs" } },
        },
        .from = .{ .timestamp = .{ .nanoseconds = 1_792_141_200 * std.time.ns_per_s } },
    });
    defer tail.deinit();
    h.clock.now_ns = (1_792_141_200 + 60) * std.time.ns_per_s;
    var batch = try tail.poll();
    defer batch.deinit();
    try testing.expect(std.mem.startsWith(u8, (try h.fake.request(0)).body.?,
        \\{"resourceNames":["folders/1","organizations/2","billingAccounts/012345-567890-ABCDEF","projects/p","projects/p/locations/global/buckets/_Default/views/_AllLogs"],
    ));
    const e = batch.value.entries[0];
    try testing.expectEqualStrings("type.googleapis.com/google.cloud.audit.AuditLog", e.payload.proto.type_url);
    try testing.expect(std.mem.indexOf(u8, e.raw, e.payload.proto.json) != null);
    try testing.expectEqualStrings("HTTP/2", e.http_request.?.protocol);
    try testing.expectEqualStrings("ua", e.http_request.?.user_agent);
    try testing.expectEqualStrings("pr", e.operation.?.producer);
    try testing.expectEqualStrings("x.zig", e.source_location.?.file);
    try testing.expectEqualStrings("u1", e.split.?.uid);
    try testing.expectEqualStrings("v", e.labels[0].value);
    try testing.expectEqualStrings("b", e.resource_labels[0].value);
    try testing.expectEqualStrings("hello", batch.value.entries[1].payload.text);
}

test "tail: the list of kept keys is compacted as old ones go" {
    var r: Rig = undefined;
    try r.init(0);
    defer r.deinit();
    var tail = try r.client.tail(.{ .settle_ms = 1_000, .overlap_ms = 2_000, .from = .{ .timestamp = at(0) } });
    defer tail.deinit();
    const a = r.fake.store.allocator();
    for (0..1500) |i| try r.fake.write(.{ .log_name = "projects/p/logs/a", .timestamp = .{ .nanoseconds = at(0).nanoseconds + @as(i96, @intCast(i)) * std.time.ns_per_ms }, .receive_timestamp = at(0), .insert_id = try std.fmt.allocPrint(a, "k{d:0>4}", .{i}) });
    r.now(10);
    var first = try tail.poll();
    first.deinit();
    try testing.expectEqual(1500, tail.stats().entries);
    r.now(20);
    var second = try tail.poll();
    second.deinit();
    try testing.expectEqual(0, tail.seen.count());
    try testing.expectEqual(0, tail.seen_head);
    try testing.expectEqual(0, tail.seen_order.items.len);
}
