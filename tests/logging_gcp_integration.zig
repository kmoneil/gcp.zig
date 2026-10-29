//! Integration tests against real Cloud Logging, which has no emulator:
//! milestone 4 of the Logging spec. They need a project and a token that
//! may write and read logs:
//!
//!     GCP_TEST_PROJECT=extractctl GCP_TEST_TOKEN=$(cat token.txt) \
//!     zig build test-integration-gcp -Dtest-filter=logging
//!
//! Without both variables every test skips. Each test writes its entries
//! to a log of its own, `zigps-lg-` and random hex, through
//! `entries:write`, which the library does not offer and this file sends
//! by hand, and deletes the log when it ends. Entries left by a run that
//! failed expire with `_Default`'s 30 days. Reads are free; a few hundred
//! small entries are far inside the free 50 GiB a month of ingestion.
//!
//! Logging takes about 13 seconds to show what was written, as measured,
//! so the tests poll, under the client's read budget. The last test runs
//! the same scripts against production and against `FakeLogging`, and
//! holds the fake to what production answered.

const std = @import("std");
const core = @import("core");
const logging = @import("logging");
const testing = std.testing;

const Fixture = struct {
    env: std.process.Environ.Map,
    token: core.StaticToken,
    diag: logging.Diagnostics,
    client: logging.Client,
    project: []const u8,
    /// "zigps-lg-" plus 8 random hex digits: the test's log.
    log_id: [17]u8,
    log_name: []u8,

    fn init(f: *Fixture) !bool {
        const gpa = testing.allocator;
        f.env = try testing.environ.createMap(gpa);
        errdefer f.env.deinit();
        f.project = f.env.get("GCP_TEST_PROJECT") orelse return f.skip();
        const token = f.env.get("GCP_TEST_TOKEN") orelse return f.skip();
        f.token = .{ .token = std.mem.trim(u8, token, &std.ascii.whitespace) };
        f.diag = .{};
        var random: [4]u8 = undefined;
        testing.io.random(&random);
        _ = try std.fmt.bufPrint(&f.log_id, "zigps-lg-{x}", .{random});
        f.log_name = try std.fmt.allocPrint(gpa, "projects/{s}/logs/{s}", .{ f.project, &f.log_id });
        errdefer gpa.free(f.log_name);
        f.client = try .init(gpa, testing.io, .{
            .project_id = f.project,
            .token_provider = f.token.provider(),
            .diagnostics = &f.diag,
            .user_agent = "gcp-zig-logging-gcp-integration/0.1",
        });
        return true;
    }

    fn skip(f: *Fixture) bool {
        f.env.deinit();
        return false;
    }

    fn deinit(f: *Fixture) void {
        var arena: std.heap.ArenaAllocator = .init(testing.allocator);
        defer arena.deinit();
        const path = std.fmt.allocPrint(arena.allocator(), "/v2/projects/{s}/logs/{s}", .{ f.project, &f.log_id }) catch "";
        if (f.raw(arena.allocator(), .DELETE, path, null)) |res| {
            if (res.status != 200) fact("cleanup of {s}: HTTP {d}", .{ &f.log_id, res.status });
        } else |err| fact("cleanup of {s}: {t}", .{ &f.log_id, err });
        f.client.deinit();
        testing.allocator.free(f.log_name);
        f.env.deinit();
    }

    fn raw(f: *Fixture, arena: std.mem.Allocator, method: core.transport.Method, path: []const u8, body: ?[]const u8) !core.transport.Response {
        const url = try std.fmt.allocPrint(arena, "{s}{s}", .{ f.client.base_url, path });
        return f.client.transport.send(.{ .method = method, .url = url, .bearer = f.token.token, .body = body, .timeout_ms = 30_000 }, arena);
    }

    /// Writes `entries`, a JSON array of LogEntry objects without a log
    /// name, to the test's log.
    fn write(f: *Fixture, entries: []const u8) !void {
        var arena: std.heap.ArenaAllocator = .init(testing.allocator);
        defer arena.deinit();
        const a = arena.allocator();
        const body = try std.fmt.allocPrint(a, "{{\"logName\":\"{s}\",\"resource\":{{\"type\":\"global\"}},\"entries\":{s}}}", .{ f.log_name, entries });
        const res = try f.raw(a, .POST, "/v2/entries:write", body);
        if (res.status != 200) {
            std.debug.print("entries:write: HTTP {d} {s}\n", .{ res.status, res.body });
            return error.WriteFailed;
        }
    }

    fn ourFilter(f: *Fixture, a: std.mem.Allocator, extra: []const u8) ![]const u8 {
        return std.fmt.allocPrint(a, "logName = \"{s}\"{s}{s}", .{ f.log_name, if (extra.len > 0) "\n" else "", extra });
    }

    /// The insert ids of every page of `options`, joined by spaces, in
    /// `a`. Waits out the read budget when it is spent.
    fn ids(f: *Fixture, a: std.mem.Allocator, options: logging.QueryOptions) ![]const u8 {
        var q = try f.client.query(options);
        defer q.deinit();
        var out: std.ArrayList(u8) = .empty;
        var token: ?[]const u8 = null;
        while (true) {
            var page = q.page(token) catch |err| {
                if (err == error.ResourceExhausted) {
                    try testing.io.sleep(.fromMilliseconds(@intCast(@max(1000, f.client.readBudget().next_free_ms))), .awake);
                    continue;
                }
                return err;
            };
            defer page.deinit();
            for (page.value.entries) |e| {
                if (out.items.len > 0) try out.append(a, ' ');
                try out.appendSlice(a, e.insert_id);
            }
            token = if (page.value.next_page_token) |t| try a.dupe(u8, t) else break;
        }
        return out.items;
    }

    /// Polls until `want` entries match `filter_extra`, or 90 s pass.
    fn waitFor(f: *Fixture, want: usize, since: std.Io.Timestamp, filter_extra: []const u8) !void {
        const started = std.Io.Clock.awake.now(testing.io);
        while (true) {
            var arena: std.heap.ArenaAllocator = .init(testing.allocator);
            defer arena.deinit();
            const a = arena.allocator();
            const got = try f.ids(a, .{ .filter = try f.ourFilter(a, filter_extra), .since = since, .page_size = 1000 });
            const n = if (got.len == 0) 0 else std.mem.count(u8, got, " ") + 1;
            if (n >= want) {
                fact("{d} entries listed {d} ms after writing", .{ n, started.durationTo(std.Io.Clock.awake.now(testing.io)).toMilliseconds() });
                return;
            }
            if (started.durationTo(std.Io.Clock.awake.now(testing.io)).toSeconds() > 90) {
                std.debug.print("only {d} of {d} entries after 90 s\n", .{ n, want });
                return error.EntriesNeverCame;
            }
            try testing.io.sleep(.fromSeconds(3), .awake);
        }
    }
};

fn fact(comptime fmt: []const u8, args: anytype) void {
    std.debug.print("fact: " ++ fmt ++ "\n", args);
}

fn rfc3339(buf: *[core.timestamp.max_len]u8, ns: i96) []const u8 {
    return core.timestamp.format(buf, .{ .nanoseconds = ns });
}

fn nowNs() i96 {
    return std.Io.Clock.real.now(testing.io).nanoseconds;
}

test "logging: every field written comes back, in both orders" {
    var f: Fixture = undefined;
    if (!try f.init()) return error.SkipZigTest;
    defer f.deinit();
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const base = nowNs() - 30 * std.time.ns_per_s;
    var b: [5][core.timestamp.max_len]u8 = undefined;
    try f.write(try std.fmt.allocPrint(a,
        \\[{{"insertId":"text","timestamp":"{s}","severity":"WARNING","textPayload":"disk nearly full","labels":{{"zone":"eu","q":"a\"b"}}}},
        \\ {{"insertId":"json","timestamp":"{s}","severity":"ERROR","jsonPayload":{{"message":"payment failed","n":7}},"trace":"projects/{s}/traces/4bf92f3577b34da6a3ce929d0e0e4736","spanId":"00f067aa0ba902b7"}},
        \\ {{"insertId":"http","timestamp":"{s}","httpRequest":{{"requestMethod":"GET","requestUrl":"https://example.com/x","status":503,"latency":"0.25s"}}}},
        \\ {{"insertId":"tie-b","timestamp":"{s}"}},
        \\ {{"insertId":"tie-a","timestamp":"{s}"}}]
    , .{
        rfc3339(&b[0], base + 1 * std.time.ns_per_s),
        rfc3339(&b[1], base + 2 * std.time.ns_per_s + 123_456_789),
        f.project,
        rfc3339(&b[2], base + 3 * std.time.ns_per_s),
        rfc3339(&b[3], base + 4 * std.time.ns_per_s),
        rfc3339(&b[4], base + 4 * std.time.ns_per_s),
    }));
    const since: std.Io.Timestamp = .{ .nanoseconds = base };
    try f.waitFor(5, since, "");
    try testing.expectEqualStrings("tie-b tie-a http json text", try f.ids(a, .{ .filter = try f.ourFilter(a, ""), .since = since }));
    try testing.expectEqualStrings("text json http tie-a tie-b", try f.ids(a, .{ .filter = try f.ourFilter(a, ""), .since = since, .order = .oldest_first }));

    var q = try f.client.query(.{ .filter = try f.ourFilter(a, ""), .since = since, .order = .oldest_first });
    defer q.deinit();
    var page = try q.page(null);
    defer page.deinit();
    const e = page.value.entries;
    try testing.expectEqualStrings("disk nearly full", e[0].payload.text);
    try testing.expectEqual(.warning, e[0].severity);
    try testing.expectEqualStrings(&f.log_id, e[0].log_id);
    try testing.expectEqual(2, e[0].labels.len);
    try testing.expectEqual(.@"error", e[1].severity);
    try testing.expectEqual(base + 2 * std.time.ns_per_s + 123_456_789, e[1].timestamp.nanoseconds);
    var parsed = try e[1].payload.parse(testing.allocator);
    defer parsed.deinit();
    try testing.expectEqualStrings("payment failed", parsed.value.object.get("message").?.string);
    try testing.expectEqualStrings("00f067aa0ba902b7", e[1].span_id);
    try testing.expectEqual(503, e[2].http_request.?.status);
    try testing.expectEqual(250 * std.time.ns_per_ms, e[2].http_request.?.latency.?.nanoseconds);
    try testing.expect(e[2].receive_timestamp != null);
    try testing.expectEqualStrings("global", e[3].resource_type);
}

test "logging: 250 entries in pages of 100, a token fetched again, a page of 2000" {
    var f: Fixture = undefined;
    if (!try f.init()) return error.SkipZigTest;
    defer f.deinit();
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const base = nowNs() - 60 * std.time.ns_per_s;
    var body: std.ArrayList(u8) = .empty;
    try body.append(a, '[');
    var buf: [core.timestamp.max_len]u8 = undefined;
    for (0..250) |i| {
        if (i > 0) try body.append(a, ',');
        try body.print(a, "{{\"insertId\":\"p{d:0>3}\",\"timestamp\":\"{s}\"}}", .{ i, rfc3339(&buf, base + @as(i96, @intCast(i)) * std.time.ns_per_ms) });
    }
    try body.append(a, ']');
    try f.write(body.items);
    const since: std.Io.Timestamp = .{ .nanoseconds = base };
    try f.waitFor(250, since, "");

    var q = try f.client.query(.{ .filter = try f.ourFilter(a, ""), .since = since, .order = .oldest_first, .page_size = 100 });
    defer q.deinit();
    var first = try q.page(null);
    defer first.deinit();
    const token = first.value.next_page_token.?;
    var second = try q.page(token);
    defer second.deinit();
    var again = try q.page(token);
    defer again.deinit();
    try testing.expectEqual(second.value.entries.len, again.value.entries.len);
    for (second.value.entries, again.value.entries) |x, y| try testing.expectEqualStrings(x.insert_id, y.insert_id);
    try testing.expectEqualStrings("p100", second.value.entries[0].insert_id);

    var large = try f.client.query(.{ .filter = try f.ourFilter(a, ""), .since = since, .page_size = 2000 });
    defer large.deinit();
    var all = try large.page(null);
    defer all.deinit();
    fact("a page size of 2000 gave {d} entries, token {}", .{ all.value.entries.len, all.value.next_page_token != null });
    try testing.expectEqual(250, all.value.entries.len);
}

test "logging: clauses, an OR before an AND, and production's refusals" {
    var f: Fixture = undefined;
    if (!try f.init()) return error.SkipZigTest;
    defer f.deinit();
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const base = nowNs() - 30 * std.time.ns_per_s;
    var b: [3][core.timestamp.max_len]u8 = undefined;
    try f.write(try std.fmt.allocPrint(a,
        \\[{{"insertId":"x","timestamp":"{s}","severity":"INFO"}},
        \\ {{"insertId":"y","timestamp":"{s}","severity":"ERROR"}},
        \\ {{"insertId":"z","timestamp":"{s}","severity":"ERROR","labels":{{"t":"a\tb"}}}}]
    , .{ rfc3339(&b[0], base + std.time.ns_per_s), rfc3339(&b[1], base + 2 * std.time.ns_per_s), rfc3339(&b[2], base + 3 * std.time.ns_per_s) }));
    const since: std.Io.Timestamp = .{ .nanoseconds = base };
    try f.waitFor(3, since, "");
    // (x OR y) AND severity >= ERROR: y alone. The usual precedence would
    // take x too.
    try testing.expectEqualStrings("y", try f.ids(a, .{ .filter = try f.ourFilter(a, "insertId = \"x\" OR insertId = \"y\" AND severity >= ERROR"), .since = since }));
    try testing.expectEqualStrings("z y", try f.ids(a, .{ .filter = try f.ourFilter(a, "-- errors only"), .since = since, .min_severity = .@"error", .log_id = &f.log_id, .resource_type = "global" }));
    try testing.expectEqualStrings("y", try f.ids(a, .{ .filter = try f.ourFilter(a, ""), .since = .{ .nanoseconds = base + 2 * std.time.ns_per_s }, .until = .{ .nanoseconds = base + 3 * std.time.ns_per_s } }));
    // A tab, written \t.
    var q = try f.client.query(.{ .filter = try f.ourFilter(a, "labels.t = \"a\\tb\""), .since = since });
    defer q.deinit();
    var page = try q.page(null);
    defer page.deinit();
    try testing.expectEqualStrings("z", page.value.entries[0].insert_id);

    for ([_][]const u8{ "thud = 1", "AND insertId = x", "(insertId = x" }) |bad| {
        var r = try f.client.query(.{ .filter = bad, .since = since });
        defer r.deinit();
        try testing.expectError(error.InvalidFilter, r.page(null));
        fact("filter {s}: {s}", .{ bad, f.diag.message() });
    }
}

test "logging: a tail returns each entry once, and catches a late one" {
    var f: Fixture = undefined;
    if (!try f.init()) return error.SkipZigTest;
    defer f.deinit();
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var tail = try f.client.tail(.{ .filter = try f.ourFilter(a, ""), .settle_ms = 2_000, .overlap_ms = 60_000 });
    defer tail.deinit();
    var seen: std.StringHashMapUnmanaged(void) = .empty;
    var buf: [core.timestamp.max_len]u8 = undefined;
    const started = std.Io.Clock.awake.now(testing.io);
    var round: usize = 0;
    while (round < 30) : (round += 1) {
        if (round < 4) {
            // On the fourth round, one stamped 6 s back: after the tail
            // began, before its cursor, and so late. Logging's own delay
            // in showing an entry, some 13 s, makes the others late too.
            const stamp = if (round == 3) nowNs() - 6 * std.time.ns_per_s else nowNs();
            try f.write(try std.fmt.allocPrint(a, "[{{\"insertId\":\"t{d}\",\"timestamp\":\"{s}\"}}]", .{ round, rfc3339(&buf, stamp) }));
        }
        try testing.io.sleep(.fromSeconds(3), .awake);
        var batch = try tail.poll();
        defer batch.deinit();
        for (batch.value.entries) |e| {
            const gop = try seen.getOrPut(a, try a.dupe(u8, e.insert_id));
            try testing.expect(!gop.found_existing);
        }
        if (seen.count() == 4) break;
    }
    const s = tail.stats();
    fact("tail: {d} entries in {d} polls, {d} calls, {d} seen again, {d} late (latest {d} ms behind), {d} s", .{ s.entries, s.polls, s.calls, s.duplicates, s.late, s.latest_late_ms, started.durationTo(std.Io.Clock.awake.now(testing.io)).toSeconds() });
    try testing.expectEqual(4, seen.count());
}

test "logging: the test's log is listed; the picker has _Default and _Required" {
    var f: Fixture = undefined;
    if (!try f.init()) return error.SkipZigTest;
    defer f.deinit();
    var buf: [core.timestamp.max_len]u8 = undefined;
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    try f.write(try std.fmt.allocPrint(arena.allocator(), "[{{\"insertId\":\"one\",\"timestamp\":\"{s}\"}}]", .{rfc3339(&buf, nowNs())}));
    const started = std.Io.Clock.awake.now(testing.io);
    listed: while (true) {
        var token: ?[]const u8 = null;
        var pages: std.heap.ArenaAllocator = .init(testing.allocator);
        defer pages.deinit();
        while (true) {
            var page = try f.client.listLogs(.{ .page_token = token });
            defer page.deinit();
            for (page.value.log_ids) |id| if (std.mem.eql(u8, id, &f.log_id)) break :listed;
            token = if (page.value.next_page_token) |t| try pages.allocator().dupe(u8, t) else break;
        }
        if (started.durationTo(std.Io.Clock.awake.now(testing.io)).toSeconds() > 180) return error.LogNeverListed;
        try testing.io.sleep(.fromSeconds(10), .awake);
    }
    fact("the new log was listed {d} s after its first entry", .{started.durationTo(std.Io.Clock.awake.now(testing.io)).toSeconds()});

    var picker = try f.client.picker(.{ .project = f.project });
    defer picker.deinit();
    try testing.expect(!picker.value.list_denied);
    try testing.expectEqualStrings("_Default", picker.value.buckets[0].info.name.bucket);
    try testing.expectEqualStrings("_Default", picker.value.buckets[0].views[0].name.view);
    try testing.expectEqualStrings("_AllLogs", picker.value.buckets[0].views[1].name.view);
    try testing.expectEqualStrings("_Required", picker.value.buckets[1].info.name.bucket);
    try testing.expect(picker.value.buckets[1].info.locked);
}

/// One script of the replay: a query, and what it should be compared on.
const Script = struct {
    name: []const u8,
    filter: []const u8 = "",
    order: logging.Order = .oldest_first,
    page_size: u32 = 100,
    min_severity: ?logging.Severity = null,
};

const replay_entries =
    \\[{"insertId":"a","timestamp":"@1@","severity":"WARNING","textPayload":"Disk Nearly Full","labels":{"k":"V"}},
    \\ {"insertId":"B","timestamp":"@2@","severity":"ERROR","jsonPayload":{"n":7,"s":"Value"}},
    \\ {"insertId":"c","timestamp":"@2@","severity":"INFO","textPayload":"Été"},
    \\ {"insertId":"d","timestamp":"@3@","labels":{"k":"other"}},
    \\ {"insertId":"e","timestamp":"@4@","severity":"DEBUG","jsonPayload":{"n":3}}]
;

const scripts = [_]Script{
    .{ .name = "oldest first, ties by insertId" },
    .{ .name = "newest first", .order = .newest_first },
    .{ .name = "pages of two", .page_size = 2 },
    .{ .name = "severity", .min_severity = .warning },
    .{ .name = "has, ignoring case", .filter = "textPayload:\"nearly\"" },
    .{ .name = "equality past ASCII", .filter = "textPayload = \"\u{e9}t\u{e9}\"" },
    .{ .name = "a JSON number", .filter = "jsonPayload.n > 5" },
    .{ .name = "a JSON string, ignoring case", .filter = "jsonPayload.s = \"value\"" },
    .{ .name = "a label, ignoring case", .filter = "labels.k = \"v\"" },
    .{ .name = "!= on a missing label", .filter = "labels.missing != \"x\"" },
    .{ .name = "NOT on a missing label", .filter = "NOT labels.missing = \"x\"" },
    .{ .name = "insertId ignoring case", .filter = "insertId = \"b\"" },
    .{ .name = "OR before AND", .filter = "insertId = \"a\" OR insertId = \"d\" AND severity >= WARNING" },
    .{ .name = "an unknown field", .filter = "thud = 1" },
    .{ .name = "a leading AND", .filter = "AND insertId = \"a\"" },
    .{ .name = "an unclosed parenthesis", .filter = "(insertId = \"a\"" },
    .{ .name = "a trailing OR", .filter = "insertId = \"a\" OR" },
};

/// What a script got: the ids in order, or the error and its message.
fn runScript(a: std.mem.Allocator, client: *logging.Client, diag: *const logging.Diagnostics, log_filter: []const u8, since: std.Io.Timestamp, s: Script) ![]const u8 {
    const filter = if (s.filter.len == 0) log_filter else try std.fmt.allocPrint(a, "{s}\n{s}", .{ log_filter, s.filter });
    var q = try client.query(.{ .filter = filter, .since = since, .order = s.order, .page_size = s.page_size, .min_severity = s.min_severity });
    defer q.deinit();
    var out: std.ArrayList(u8) = .empty;
    var token: ?[]const u8 = null;
    while (true) {
        var page = q.page(token) catch |err| {
            if (err == error.ResourceExhausted) {
                try testing.io.sleep(.fromMilliseconds(@intCast(@max(1000, client.readBudget().next_free_ms))), .awake);
                continue;
            }
            // The message names a line and column in the joined filter,
            // which both sides join the same way.
            return std.fmt.allocPrint(a, "error.{t}: {s}", .{ err, diag.message() });
        };
        defer page.deinit();
        for (page.value.entries) |e| {
            if (out.items.len > 0) try out.append(a, ' ');
            try out.appendSlice(a, e.insert_id);
        }
        token = if (page.value.next_page_token) |t| try a.dupe(u8, t) else break;
    }
    return out.items;
}

test "logging: the fake against production, script by script" {
    var f: Fixture = undefined;
    if (!try f.init()) return error.SkipZigTest;
    defer f.deinit();
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const base = nowNs() - 60 * std.time.ns_per_s;
    var stamps: [4][core.timestamp.max_len]u8 = undefined;
    var entries: []const u8 = replay_entries;
    inline for (.{ "@1@", "@2@", "@3@", "@4@" }, 0..) |t, i| {
        entries = try std.mem.replaceOwned(u8, a, entries, t, rfc3339(&stamps[i], base + @as(i96, i + 1) * std.time.ns_per_s));
    }
    try f.write(entries);
    const since: std.Io.Timestamp = .{ .nanoseconds = base };
    try f.waitFor(5, since, "");

    // The same entries in the fake, from the same JSON.
    var clock: core.testing.FakeClock = .{ .now_ns = nowNs() };
    var fake: logging.testing.FakeLogging = .init(testing.allocator, clock.io());
    defer fake.deinit();
    const list = try std.json.parseFromSliceLeaky(std.json.Value, a, entries, .{});
    for (list.array.items) |item| {
        const o = item.object;
        var labels: std.ArrayList(logging.Label) = .empty;
        if (o.get("labels")) |l| {
            var it = l.object.iterator();
            while (it.next()) |kv| try labels.append(a, .{ .key = kv.key_ptr.*, .value = kv.value_ptr.string });
        }
        const payload: logging.testing.FakeLogging.Entry.Payload = if (o.get("textPayload")) |t|
            .{ .text = t.string }
        else if (o.get("jsonPayload")) |j|
            .{ .json = try std.json.Stringify.valueAlloc(a, j, .{}) }
        else
            .none;
        try fake.write(.{
            .log_name = f.log_name,
            .timestamp = try core.timestamp.parse(o.get("timestamp").?.string),
            .receive_timestamp = .{ .nanoseconds = base },
            .severity = if (o.get("severity")) |s| logging.Severity.fromName(s.string) else .default,
            .insert_id = o.get("insertId").?.string,
            .labels = labels.items,
            .payload = payload,
        });
    }
    var fake_diag: logging.Diagnostics = .{};
    var fake_token: core.StaticToken = .{ .token = "fake" };
    var fake_client = try logging.Client.init(testing.allocator, clock.io(), .{
        .project_id = f.project,
        .token_provider = fake_token.provider(),
        .transport = fake.transport(),
        .diagnostics = &fake_diag,
        .read_calls_per_minute = 0,
    });
    defer fake_client.deinit();

    const log_filter = try f.ourFilter(a, "");
    var differences: usize = 0;
    for (scripts) |s| {
        const theirs = try runScript(a, &f.client, &f.diag, log_filter, since, s);
        const ours = try runScript(a, &fake_client, &fake_diag, log_filter, since, s);
        if (std.mem.eql(u8, theirs, ours)) {
            fact("replay {s}: {s}", .{ s.name, theirs });
        } else {
            differences += 1;
            std.debug.print("replay {s}:\n  production: {s}\n  fake:       {s}\n", .{ s.name, theirs, ours });
        }
    }
    try testing.expectEqual(0, differences);
}
