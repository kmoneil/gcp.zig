//! `ReadBudget`: a count of `entries.list` calls against Logging's read
//! quota, 60 a minute per project, which the docs say cannot be raised. A
//! call past the count is not sent: the caller learns at once, and how long
//! to wait, where a 429 would cost the call and say nothing of when to try
//! again. A 429 from the server, which other programs reading the project
//! can cause, holds every call back for 5 seconds: measured on 2026-10-16,
//! the 63rd quick call was refused and a call 5.2 seconds later served, so
//! the quota refills within seconds rather than once a minute.
//!
//! Task-safe, so the clients of several tasks can share one: a table's and
//! a tail's, say, which read the same project.

const std = @import("std");
const types = @import("types.zig");
const validate = @import("validate.zig");

pub const ReadBudget = struct {
    mutex: std.Io.Mutex = .init,
    /// The most calls in any 60 seconds; 0 counts nothing.
    limit: u32,
    /// When each counted call went, on the awake clock, oldest first: a
    /// ring of `len` times from `head`.
    times: [validate.max_read_calls_per_minute]i96 = undefined,
    head: u32 = 0,
    len: u32 = 0,
    /// After a 429: no call goes before this.
    blocked_until: ?i96 = null,

    pub const window_ns: i96 = 60 * std.time.ns_per_s;
    /// How long a 429 holds calls back.
    pub const refusal_pause_ns: i96 = 5 * std.time.ns_per_s;

    /// `limit` is at most `validate.max_read_calls_per_minute`.
    pub fn init(limit: u32) ReadBudget {
        std.debug.assert(limit <= validate.max_read_calls_per_minute);
        return .{ .limit = limit };
    }

    /// Counts a call that goes now, or says how many milliseconds until
    /// one may: null when it was counted.
    pub fn take(self: *ReadBudget, io: std.Io) ?u64 {
        self.mutex.lockUncancelable(io);
        defer self.mutex.unlock(io);
        if (self.limit == 0) return null;
        const now = std.Io.Clock.awake.now(io).nanoseconds;
        if (self.waitNs(now)) |ns| return ceilMs(ns);
        self.times[(self.head + self.len) % self.times.len] = now;
        self.len += 1;
        return null;
    }

    /// The server refused a call for quota: nothing goes for
    /// `refusal_pause_ns`.
    pub fn pauseAfterRefusal(self: *ReadBudget, io: std.Io) void {
        self.pauseFor(io, refusal_pause_ns);
    }

    /// Nothing goes for `ns`, or for longer if an earlier pause says so.
    pub fn pauseFor(self: *ReadBudget, io: std.Io, ns: i96) void {
        self.mutex.lockUncancelable(io);
        defer self.mutex.unlock(io);
        if (self.limit == 0) return;
        const until = std.Io.Clock.awake.now(io).nanoseconds + ns;
        self.blocked_until = if (self.blocked_until) |b| @max(b, until) else until;
    }

    pub fn status(self: *ReadBudget, io: std.Io) types.ReadStatus {
        self.mutex.lockUncancelable(io);
        defer self.mutex.unlock(io);
        if (self.limit == 0) return .{ .used = 0, .limit = 0, .next_free_ms = 0 };
        const now = std.Io.Clock.awake.now(io).nanoseconds;
        const wait = self.waitNs(now);
        return .{ .used = self.len, .limit = self.limit, .next_free_ms = if (wait) |ns| ceilMs(ns) else 0 };
    }

    /// Forgets calls older than the window, then says how long until a call
    /// may go, or null when one may go now. Under the lock.
    fn waitNs(self: *ReadBudget, now: i96) ?i96 {
        while (self.len > 0 and self.times[self.head] + window_ns <= now) {
            self.head = @intCast((self.head + 1) % self.times.len);
            self.len -= 1;
        }
        var pause: ?i96 = null;
        if (self.blocked_until) |until| {
            if (now < until) pause = until - now else self.blocked_until = null;
        }
        const count: ?i96 = if (self.len < self.limit) null else self.times[self.head] + window_ns - now;
        // The longer of the two waits.
        if (pause) |a| return if (count) |b| @max(a, b) else a;
        return count;
    }

    fn ceilMs(ns: i96) u64 {
        return @intCast(@divFloor(ns + std.time.ns_per_ms - 1, std.time.ns_per_ms));
    }
};

const testing = std.testing;
const FakeClock = @import("core").testing.FakeClock;

fn advanceMs(clock: *FakeClock, ms: i96) void {
    clock.now_ns += ms * std.time.ns_per_ms;
}

test "the limit's calls go; the next waits for the oldest to leave the window" {
    var clock: FakeClock = .{};
    const io = clock.io();
    var budget: ReadBudget = .init(3);
    try testing.expectEqual(null, budget.take(io));
    advanceMs(&clock, 10_000);
    try testing.expectEqual(null, budget.take(io));
    try testing.expectEqual(null, budget.take(io));
    try testing.expectEqual(ReadStatusOf(3, 3, 50_000), budget.status(io));
    // The first call went 10 s ago: 50 s until it leaves the window.
    try testing.expectEqual(50_000, budget.take(io).?);
    advanceMs(&clock, 49_999);
    try testing.expectEqual(1, budget.take(io).?);
    advanceMs(&clock, 1);
    try testing.expectEqual(null, budget.take(io));
    // Now the two from t = 10 s are the oldest.
    try testing.expectEqual(10_000, budget.take(io).?);
}

fn ReadStatusOf(used: u32, limit: u32, next_free_ms: u64) types.ReadStatus {
    return .{ .used = used, .limit = limit, .next_free_ms = next_free_ms };
}

test "a 429 holds calls back for 5 seconds, then the count is as it was" {
    var clock: FakeClock = .{};
    const io = clock.io();
    var budget: ReadBudget = .init(60);
    try testing.expectEqual(null, budget.take(io));
    budget.pauseAfterRefusal(io);
    try testing.expectEqual(5_000, budget.take(io).?);
    advanceMs(&clock, 4_999);
    try testing.expectEqual(1, budget.status(io).next_free_ms);
    advanceMs(&clock, 1);
    try testing.expectEqual(ReadStatusOf(1, 60, 0), budget.status(io));
    try testing.expectEqual(null, budget.take(io));
    try testing.expectEqual(ReadStatusOf(2, 60, 0), budget.status(io));
    // A shorter pause does not cut a longer one short.
    advanceMs(&clock, 100);
    budget.pauseFor(io, 10 * std.time.ns_per_s);
    budget.pauseFor(io, 1 * std.time.ns_per_s);
    try testing.expectEqual(10_000, budget.status(io).next_free_ms);
    advanceMs(&clock, 10_000);
    // A pause shorter than the count's own wait changes nothing.
    var full: ReadBudget = .init(1);
    try testing.expectEqual(null, full.take(io));
    full.pauseAfterRefusal(io);
    try testing.expectEqual(60_000, full.take(io).?);
}

test "a limit of 0 counts nothing" {
    var clock: FakeClock = .{};
    const io = clock.io();
    var budget: ReadBudget = .init(0);
    for (0..2000) |_| try testing.expectEqual(null, budget.take(io));
    budget.pauseAfterRefusal(io);
    try testing.expectEqual(null, budget.take(io));
    try testing.expectEqual(ReadStatusOf(0, 0, 0), budget.status(io));
}

test "the ring holds the largest limit through many windows" {
    var clock: FakeClock = .{};
    const io = clock.io();
    var budget: ReadBudget = .init(validate.max_read_calls_per_minute);
    for (0..5) |_| {
        for (0..validate.max_read_calls_per_minute) |_| try testing.expectEqual(null, budget.take(io));
        try testing.expect(budget.take(io) != null);
        advanceMs(&clock, 60_000);
    }
}

test "a model: calls counted in any 60 s never pass the limit, and a refused one is told the true wait" {
    var clock: FakeClock = .{};
    const io = clock.io();
    var prng: std.Random.DefaultPrng = .init(0x6c6f67);
    const random = prng.random();
    var budget: ReadBudget = .init(7);
    var taken: std.ArrayList(i96) = .empty;
    defer taken.deinit(testing.allocator);
    for (0..5000) |_| {
        advanceMs(&clock, random.uintAtMost(u32, 15_000));
        const now = clock.now_ns;
        var in_window: usize = 0;
        for (taken.items) |t| if (t + ReadBudget.window_ns > now) {
            in_window += 1;
        };
        if (budget.take(io)) |wait_ms| {
            try testing.expectEqual(7, in_window);
            // The oldest in the window leaves it after exactly the wait.
            var oldest: i96 = now;
            for (taken.items) |t| if (t + ReadBudget.window_ns > now and t < oldest) {
                oldest = t;
            };
            try testing.expectEqual(ReadBudget.ceilMs(oldest + ReadBudget.window_ns - now), wait_ms);
        } else {
            try testing.expect(in_window < 7);
            try taken.append(testing.allocator, now);
        }
    }
}
