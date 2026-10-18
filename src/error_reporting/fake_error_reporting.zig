//! Cloud Error Reporting for tests, behind the `Transport` seam: errors a
//! test reports, grouped and counted, listed and read as production
//! answered when measured on 2026-10-18 (milestone 0 of the Error Reporting
//! spec, `_tmp/er-m0/`; the answers are kept verbatim in
//! `production_bodies.zig`, and a test holds this fake's refusals to them
//! word for word). It parses requests with code of its own, so a request
//! this library builds wrong is refused here as production would refuse it.
//!
//! What it models:
//!
//! - Groups: errors with the same `Report.group` key share a group, or with
//!   the same stack trace when no key is given. Production groups by
//!   exception type and top frames, which a test says with its own keys.
//! - Group stats computed from the events, as production's came out: the
//!   period ends now, in whole seconds, 7 days when none is asked; counts,
//!   distinct users (by user, or an HTTP request's remote address), every
//!   timed bucket in both alignments, at most 100 a period; first seen is
//!   the time of the group's first error to arrive, last seen the latest
//!   error's time in whole seconds, both whatever the period; the services
//!   with errors, in the order they first had one; every order, ties in the
//!   order the groups were made; groups with no errors in the period left
//!   out unless asked for by id.
//! - Status: a muted group is left out of group stats, even asked for by
//!   id, and its new errors are dropped; a resolved group with a new error
//!   is open again; an update replaces the tracking issues it leaves out.
//! - Events: newest first, 30 days when no period is asked.
//! - Paging: the server's default of 20, tokens that are positions. One it
//!   did not issue is production's 400.
//! - Locations: none, `global` and `-` read the same groups; any other
//!   region holds none.
//! - Refusals in production's words: an id that names no group (400, never
//!   404), events without a group id, buckets too narrow, a status that is
//!   not one; the API off (`setApiEnabled`); the per-user quota as an
//!   option; and faults a test asks for.
//!
//! The representative is the group's first error to arrive in the period,
//! where production chose one of its own. Not modelled, each answered 501
//! with the reason: another project, events or groups at `-`, reporting
//! and deleting errors.

const std = @import("std");
const Allocator = std.mem.Allocator;
const Stringify = std.json.Stringify;
const core = @import("core");
const tp = core.transport;
const types = @import("types.zig");
const validate = @import("validate.zig");

pub const FakeErrorReporting = struct {
    gpa: Allocator,
    io: std.Io,
    mutex: std.Io.Mutex = .init,
    options: Options,
    /// Strings and events, freed with the fake.
    store: std.heap.ArenaAllocator,
    /// In the order they were made.
    groups: std.ArrayList(*Stored) = .empty,
    serial: u64 = 0,
    api_enabled: bool = true,
    faults: [2]Fault = .{ .{}, .{} },
    calls: usize = 0,
    minute_start_ns: i96 = 0,
    minute_calls: u32 = 0,

    const Fault = struct { n: usize = 0, status: u16 = 0, delay: ?core.retry_after.Asked = null };
    const refuse = 0;
    const drop = 1;

    pub const Options = struct {
        /// The project it answers for, by id.
        project_id: []const u8 = "my-project",
        /// Calls a minute before a 429, as the per-user quota of 60 is; 0
        /// for none. Counted in fixed minutes.
        calls_per_minute: u32 = 0,
    };

    /// One error, as a test reports it.
    pub const Report = struct {
        /// The stack trace.
        message: []const u8,
        /// When it happened; null for now, on the fake's clock.
        time: ?std.Io.Timestamp = null,
        service: types.ServiceContext = .{ .service = "default", .resource_type = "reported_errors" },
        user: ?[]const u8 = null,
        http_request: ?types.HttpRequest = null,
        report_location: ?types.SourceLocation = null,
        /// Reports with the same key share a group; null groups by the
        /// stack trace's text.
        group: ?[]const u8 = null,
    };

    pub const Reply = struct { status: u16, headers: []const tp.Header = &.{}, body: []const u8 };

    const Stored = struct {
        id: []const u8,
        /// "projects/P/groups/ID", as production names a group.
        name: []const u8,
        key: []const u8,
        status: types.Status = .open,
        issues: []const []const u8 = &.{},
        /// Arrival order: the first is the one that made the group.
        events: std.ArrayList(types.Event) = .empty,
        order: u64,
    };

    pub fn init(gpa: Allocator, io: std.Io, options: Options) FakeErrorReporting {
        return .{ .gpa = gpa, .io = io, .options = options, .store = .init(gpa) };
    }

    pub fn deinit(f: *FakeErrorReporting) void {
        f.store.deinit();
        f.* = undefined;
    }

    /// Goes into `Client.Options.transport`.
    pub fn transport(f: *FakeErrorReporting) tp.Transport {
        return .{ .ptr = f, .vtable = &.{ .send = send } };
    }

    fn nowNs(f: *const FakeErrorReporting) i96 {
        return std.Io.Clock.real.now(f.io).nanoseconds;
    }

    // What a test does.

    /// Reports an error into its group, made if new. A muted group's error
    /// is dropped; a resolved group's reopens it. Answers the group's id,
    /// held by the fake.
    pub fn report(f: *FakeErrorReporting, r: Report) Allocator.Error![]const u8 {
        f.mutex.lockUncancelable(f.io);
        defer f.mutex.unlock(f.io);
        const a = f.store.allocator();
        const key = r.group orelse r.message;
        const g = for (f.groups.items) |existing| {
            if (std.mem.eql(u8, existing.key, key)) break existing;
        } else made: {
            f.serial += 1;
            const fresh = try a.create(Stored);
            const id = try groupId(a, f.serial);
            fresh.* = .{
                .id = id,
                .name = try a.print("projects/{s}/groups/{s}", .{ f.options.project_id, id }),
                .key = try a.dupe(u8, key),
                .order = f.serial,
            };
            try f.groups.append(a, fresh);
            break :made fresh;
        };
        if (g.status == .muted) return g.id;
        if (g.status == .resolved) g.status = .open;
        try g.events.append(a, .{
            .time = r.time orelse .{ .nanoseconds = f.nowNs() },
            .service = try dupeService(a, r.service),
            .message = try a.dupe(u8, r.message),
            .context = .{
                .user = if (r.user) |u| try a.dupe(u8, u) else null,
                .http_request = if (r.http_request) |h| try dupeHttp(a, h) else null,
                .report_location = if (r.report_location) |l| .{
                    .file_path = if (l.file_path) |p| try a.dupe(u8, p) else null,
                    .line_number = l.line_number,
                    .function_name = if (l.function_name) |n| try a.dupe(u8, n) else null,
                } else null,
            },
        });
        return g.id;
    }

    /// A group's status as the fake holds it; null for an id it does not know.
    pub fn status(f: *FakeErrorReporting, id: []const u8) ?types.Status {
        f.mutex.lockUncancelable(f.io);
        defer f.mutex.unlock(f.io);
        const g = f.byId(id) orelse return null;
        return g.status;
    }

    /// Turns the API off, or on again: off, every call is production's 403
    /// `SERVICE_DISABLED`.
    pub fn setApiEnabled(f: *FakeErrorReporting, enabled: bool) void {
        f.mutex.lockUncancelable(f.io);
        defer f.mutex.unlock(f.io);
        f.api_enabled = enabled;
    }

    // Faults, each for the next `n` calls.

    /// Answers them with `status`, and changes nothing.
    pub fn refuseNext(f: *FakeErrorReporting, n: usize, code: u16) void {
        f.setFault(refuse, .{ .n = n, .status = code });
    }

    /// Answers them as `refuseNext` does, and asks the client to wait
    /// `delay.ms` before trying again, in `delay.form`.
    pub fn refuseNextWithDelay(f: *FakeErrorReporting, n: usize, code: u16, delay: core.retry_after.Asked) void {
        f.setFault(refuse, .{ .n = n, .status = code, .delay = delay });
    }

    /// Closes their connection before any answer.
    pub fn dropNext(f: *FakeErrorReporting, n: usize) void {
        f.setFault(drop, .{ .n = n });
    }

    fn setFault(f: *FakeErrorReporting, slot: usize, fault: Fault) void {
        f.mutex.lockUncancelable(f.io);
        defer f.mutex.unlock(f.io);
        f.faults[slot] = fault;
    }

    fn takeFault(f: *FakeErrorReporting, slot: usize) ?Fault {
        const fault = &f.faults[slot];
        if (fault.n == 0) return null;
        fault.n -= 1;
        return fault.*;
    }

    /// Calls served, refusals included.
    pub fn callCount(f: *FakeErrorReporting) usize {
        f.mutex.lockUncancelable(f.io);
        defer f.mutex.unlock(f.io);
        return f.calls;
    }

    fn byId(f: *const FakeErrorReporting, id: []const u8) ?*Stored {
        for (f.groups.items) |g| if (std.mem.eql(u8, g.id, id)) return g;
        return null;
    }

    // The transport.

    fn send(ptr: *anyopaque, req: tp.Request, arena: Allocator) tp.Error!tp.Response {
        const f: *FakeErrorReporting = @ptrCast(@alignCast(ptr));
        const reply = try f.serve(req, arena);
        return .{ .status = reply.status, .headers = reply.headers, .body = reply.body };
    }

    /// One request, as `send` serves it: for a test that wants to send
    /// what no client would.
    pub fn serve(f: *FakeErrorReporting, req: tp.Request, arena: Allocator) tp.Error!Reply {
        const path = pathOf(req.url);
        const q_at = std.mem.indexOfScalar(u8, path, '?');
        const route = path[0 .. q_at orelse path.len];
        const query = if (q_at) |q| path[q + 1 ..] else "";
        f.mutex.lockUncancelable(f.io);
        defer f.mutex.unlock(f.io);
        f.calls += 1;
        if (f.takeFault(drop) != null) return error.ConnectionResetByPeer;
        if (f.takeFault(refuse)) |fault| return asking(arena, try refusal(arena, fault.status), fault.delay);
        if (req.bearer == null) return fail(arena, 401, "UNAUTHENTICATED", "Request is missing required authentication credential. Expected OAuth 2 access token, login cookie or other valid authentication credential. See https://developers.google.com/identity/sign-in/web/devconsole-project.");
        if (!f.api_enabled) return disabled(arena, f.options.project_id);
        if (f.options.calls_per_minute != 0) {
            const now = f.nowNs();
            if (now - f.minute_start_ns >= 60 * std.time.ns_per_s) {
                f.minute_start_ns = now;
                f.minute_calls = 0;
            }
            f.minute_calls += 1;
            if (f.minute_calls > f.options.calls_per_minute) return quotaRefusal(arena, f.options.project_id);
        }

        const target = parseRoute(route) orelse return notModelled(arena, "this path");
        if (!std.mem.eql(u8, target.project, f.options.project_id)) return notModelled(arena, "a project other than the fake's own");
        const somewhere_else = if (target.location) |l| !std.mem.eql(u8, l, "global") and !std.mem.eql(u8, l, "-") else false;
        const every_region = if (target.location) |l| std.mem.eql(u8, l, "-") else false;
        const params = try parseParams(arena, query) orelse return fail(arena, 400, "INVALID_ARGUMENT", "Invalid query string.");
        switch (target.kind) {
            .group_stats => {
                if (req.method != .GET) return notModelled(arena, "this method on groupStats");
                return f.groupStats(arena, params, somewhere_else);
            },
            .events => {
                if (req.method != .GET) return notModelled(arena, "reporting or deleting events");
                if (every_region) return notModelled(arena, "events at -");
                return f.listEvents(arena, params, somewhere_else);
            },
            .group => |id| {
                if (every_region) return notModelled(arena, "a group at -");
                const g = (if (somewhere_else) null else f.byId(id)) orelse return groupRefusal(arena, id);
                return switch (req.method) {
                    .GET => .{ .status = 200, .body = try render(arena, g) },
                    .PUT => f.update(arena, g, req.body orelse ""),
                    else => notModelled(arena, "this method on a group"),
                };
            },
        }
    }

    const Range = struct { begin_s: i64, now_s: i64 };

    fn range(f: *const FakeErrorReporting, params: []const Param, default: types.Period) ?Range {
        const period = if (paramOf(params, "timeRange.period")) |p| periodOf(p) orelse return null else default;
        const now_s: i64 = @intCast(@divFloor(f.nowNs(), std.time.ns_per_s));
        return .{ .begin_s = now_s - period.seconds(), .now_s = now_s };
    }

    fn matches(e: types.Event, params: []const Param) bool {
        const pairs = [_]struct { []const u8, ?[]const u8 }{
            .{ "serviceFilter.service", e.service.service },
            .{ "serviceFilter.version", e.service.version },
            .{ "serviceFilter.resourceType", e.service.resource_type },
        };
        for (pairs) |pair| if (paramOf(params, pair[0])) |want| {
            const got = pair[1] orelse return false;
            if (!std.mem.eql(u8, want, got)) return false;
        };
        return true;
    }

    fn inRange(e: types.Event, r: Range) bool {
        const ns = e.time.?.nanoseconds;
        return ns >= @as(i96, r.begin_s) * std.time.ns_per_s and ns < @as(i96, r.now_s + 1) * std.time.ns_per_s;
    }

    const Computed = struct {
        g: *Stored,
        count: u64,
        users: u64,
        last_in_range_ns: i96,
        first_seen: ?i96,
        last_seen: ?i96,
        services: []const types.ServiceContext,
        representative: ?types.Event,
        buckets: []const types.TimedCount,
    };

    fn groupStats(f: *FakeErrorReporting, arena: Allocator, params: []const Param, somewhere_else: bool) Allocator.Error!Reply {
        const r = f.range(params, types.Period.default) orelse return periodRefusal(arena, paramOf(params, "timeRange.period").?);
        var grid: ?Grid = null;
        if (paramOf(params, "timedCountDuration")) |text| {
            const width = durationSeconds(text) orelse return fieldRefusal(arena, "timed_count_duration", "Invalid value at 'timed_count_duration' (type.googleapis.com/google.protobuf.Duration), Field 'timed_count_duration', Illegal duration format; duration must end with 's'");
            if (width <= 0 or width * 100 < r.now_s - r.begin_s) return fail(arena, 400, "INVALID_ARGUMENT", "'timed_count_duration' is too short for the requested period");
            const rounded = if (paramOf(params, "alignment")) |a| std.mem.eql(u8, a, "ALIGNMENT_EQUAL_ROUNDED") or std.mem.eql(u8, a, "2") else false;
            const origin: i64 = if (rounded) at: {
                const text_at = paramOf(params, "alignmentTime") orelse "1970-01-01T00:00:00Z";
                const t = core.timestamp.parse(text_at) catch return fail(arena, 400, "INVALID_ARGUMENT", "Invalid value at 'alignment_time'.");
                break :at @intCast(@divFloor(t.nanoseconds, std.time.ns_per_s));
            } else r.now_s;
            grid = .{ .width = width, .origin = origin };
        }
        const named = try namedIds(arena, params);
        var list: std.ArrayList(Computed) = .empty;
        for (f.groups.items) |g| {
            if (g.status == .muted or somewhere_else) continue;
            const asked = if (named) |ids| contains(ids, g.id) else false;
            if (named != null and !asked) continue;
            const c = try compute(arena, g, params, r, grid);
            if (c.count == 0 and !asked) continue;
            try list.append(arena, c);
        }
        const order = paramOf(params, "order") orelse "COUNT_DESC";
        const key: OrderKey = if (std.mem.eql(u8, order, "COUNT_DESC") or std.mem.eql(u8, order, "1"))
            .count
        else if (std.mem.eql(u8, order, "LAST_SEEN_DESC") or std.mem.eql(u8, order, "2"))
            .last_seen
        else if (std.mem.eql(u8, order, "CREATED_DESC") or std.mem.eql(u8, order, "3"))
            .created
        else if (std.mem.eql(u8, order, "AFFECTED_USERS_DESC") or std.mem.eql(u8, order, "4"))
            .affected_users
        else
            return fieldRefusal(arena, "order", try arena.print("Invalid value at 'order' (type.googleapis.com/google.devtools.clouderrorreporting.v1beta1.ErrorGroupOrder), \"{s}\"", .{order}));
        std.mem.sort(Computed, list.items, key, before);
        const window = try pageOf(params, list.items.len) orelse return fail(arena, 400, "INVALID_ARGUMENT", "Error while unescaping page_token in request.");
        var out: std.Io.Writer.Allocating = .init(arena);
        var jw: Stringify = .{ .writer = &out.writer };
        writeStatsPage(&jw, list.items[window.from..window.to], window.next, r.begin_s) catch return error.OutOfMemory;
        return .{ .status = 200, .body = try out.toOwnedSlice() };
    }

    fn listEvents(f: *FakeErrorReporting, arena: Allocator, params: []const Param, somewhere_else: bool) Allocator.Error!Reply {
        const id = paramOf(params, "groupId") orelse return fail(arena, 400, "INVALID_ARGUMENT", "Missing group_id.");
        const g = (if (somewhere_else) null else f.byId(id)) orelse return groupRefusal(arena, id);
        const r = f.range(params, .thirty_days) orelse return periodRefusal(arena, paramOf(params, "timeRange.period").?);
        var list: std.ArrayList(types.Event) = .empty;
        for (g.events.items) |e| if (matches(e, params) and inRange(e, r)) try list.append(arena, e);
        std.mem.sort(types.Event, list.items, {}, newerFirst);
        const window = try pageOf(params, list.items.len) orelse return fail(arena, 400, "INVALID_ARGUMENT", "Error while unescaping page_token in request.");
        var out: std.Io.Writer.Allocating = .init(arena);
        var jw: Stringify = .{ .writer = &out.writer };
        writeEventsPage(&jw, list.items[window.from..window.to], window.next, r.begin_s) catch return error.OutOfMemory;
        return .{ .status = 200, .body = try out.toOwnedSlice() };
    }

    fn update(f: *FakeErrorReporting, arena: Allocator, g: *Stored, body: []const u8) Allocator.Error!Reply {
        const value = std.json.parseFromSliceLeaky(std.json.Value, arena, body, .{}) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            else => return fail(arena, 400, "INVALID_ARGUMENT", "Invalid JSON payload received."),
        };
        if (value != .object) return fail(arena, 400, "INVALID_ARGUMENT", "Invalid JSON payload received.");
        var new_status: types.Status = .open;
        if (value.object.get("resolutionStatus")) |s| switch (s) {
            .string => |name| {
                new_status = types.Status.fromWire(name);
                if (new_status == .unknown) return fieldRefusal(arena, "group.resolution_status", try arena.print("Invalid value at 'group.resolution_status' (type.googleapis.com/google.devtools.clouderrorreporting.v1beta1.ResolutionStatus), \"{s}\"", .{name}));
            },
            .integer => |n| {
                new_status = types.Status.fromNumber(n);
                if (new_status == .unknown) return fieldRefusal(arena, "group.resolution_status", try arena.print("Invalid value at 'group.resolution_status' (type.googleapis.com/google.devtools.clouderrorreporting.v1beta1.ResolutionStatus), {d}", .{n}));
            },
            .null => {},
            else => return fail(arena, 400, "INVALID_ARGUMENT", "Invalid JSON payload received."),
        };
        // Production replaces what an update leaves out: no issues sent is
        // none kept.
        var issues: std.ArrayList([]const u8) = .empty;
        if (value.object.get("trackingIssues")) |list| {
            if (list != .array and list != .null) return fail(arena, 400, "INVALID_ARGUMENT", "Invalid JSON payload received.");
            if (list == .array) for (list.array.items) |item| {
                if (item != .object) return fail(arena, 400, "INVALID_ARGUMENT", "Invalid JSON payload received.");
                const url = item.object.get("url") orelse continue;
                if (url != .string) return fail(arena, 400, "INVALID_ARGUMENT", "Invalid JSON payload received.");
                try issues.append(f.store.allocator(), try f.store.allocator().dupe(u8, url.string));
            };
        }
        g.status = new_status;
        g.issues = issues.items;
        return .{ .status = 200, .body = try render(arena, g) };
    }
};

// Grouping and counting.

const OrderKey = enum { count, last_seen, created, affected_users };

fn before(key: OrderKey, a: FakeErrorReporting.Computed, b: FakeErrorReporting.Computed) bool {
    const x: i128, const y: i128 = switch (key) {
        .count => .{ a.count, b.count },
        .last_seen => .{ a.last_in_range_ns, b.last_in_range_ns },
        .created => .{ a.g.order, b.g.order },
        .affected_users => .{ a.users, b.users },
    };
    if (x != y) return x > y;
    return a.g.order < b.g.order;
}

fn newerFirst(_: void, a: types.Event, b: types.Event) bool {
    return a.time.?.nanoseconds > b.time.?.nanoseconds;
}

const Grid = struct { width: i64, origin: i64 };

fn compute(arena: Allocator, g: *FakeErrorReporting.Stored, params: []const Param, r: FakeErrorReporting.Range, grid: ?Grid) Allocator.Error!FakeErrorReporting.Computed {
    var count: u64 = 0;
    var users: std.ArrayList([]const u8) = .empty;
    var services: std.ArrayList(types.ServiceContext) = .empty;
    var representative: ?types.Event = null;
    var first_seen: ?i96 = null;
    var last_seen: ?i96 = null;
    var last_in_range: i96 = std.math.minInt(i96);
    for (g.events.items) |e| {
        if (!FakeErrorReporting.matches(e, params)) continue;
        const ns = e.time.?.nanoseconds;
        if (first_seen == null) first_seen = ns;
        last_seen = if (last_seen) |l| @max(l, ns) else ns;
        if (!FakeErrorReporting.inRange(e, r)) continue;
        count += 1;
        last_in_range = @max(last_in_range, ns);
        if (representative == null) representative = e;
        const who = e.context.user orelse if (e.context.http_request) |h| h.remote_ip else null;
        if (who) |u| if (u.len > 0 and !contains(users.items, u)) try users.append(arena, u);
        if (!hasService(services.items, e.service)) try services.append(arena, e.service);
    }
    return .{
        .g = g,
        .count = count,
        .users = users.items.len,
        .last_in_range_ns = last_in_range,
        .first_seen = first_seen,
        .last_seen = if (last_seen) |l| @divFloor(l, std.time.ns_per_s) * std.time.ns_per_s else null,
        .services = services.items,
        .representative = representative,
        .buckets = if (grid) |gr| try buckets(arena, g, params, r, gr) else &.{},
    };
}

/// Every bucket of the period, in order: equal widths ending at now for
/// `.end`, on the grid through the origin for `.rounded`, the first and
/// last cut to the period. The last counts the current second too, as the
/// period does, so the buckets always sum to the group's count.
fn buckets(arena: Allocator, g: *FakeErrorReporting.Stored, params: []const Param, r: FakeErrorReporting.Range, grid: Grid) Allocator.Error![]const types.TimedCount {
    var list: std.ArrayList(types.TimedCount) = .empty;
    // The first edge after the period's start.
    const offset = @mod(r.begin_s - grid.origin, grid.width);
    var start = r.begin_s;
    var end = r.begin_s - offset + grid.width;
    while (start < r.now_s) {
        const stop = @min(end, r.now_s);
        const upper = if (stop == r.now_s) stop + 1 else stop;
        var n: u64 = 0;
        for (g.events.items) |e| {
            if (!FakeErrorReporting.matches(e, params)) continue;
            const ns = e.time.?.nanoseconds;
            if (ns >= @as(i96, start) * std.time.ns_per_s and ns < @as(i96, upper) * std.time.ns_per_s) n += 1;
        }
        try list.append(arena, .{ .start = .{ .nanoseconds = @as(i96, start) * std.time.ns_per_s }, .end = .{ .nanoseconds = @as(i96, stop) * std.time.ns_per_s }, .count = n });
        start = stop;
        end = stop + grid.width;
    }
    return list.items;
}

fn hasService(list: []const types.ServiceContext, s: types.ServiceContext) bool {
    for (list) |t| if (optEql(t.service, s.service) and optEql(t.version, s.version) and optEql(t.resource_type, s.resource_type)) return true;
    return false;
}

fn optEql(a: ?[]const u8, b: ?[]const u8) bool {
    if (a == null or b == null) return a == null and b == null;
    return std.mem.eql(u8, a.?, b.?);
}

fn contains(list: []const []const u8, item: []const u8) bool {
    for (list) |s| if (std.mem.eql(u8, s, item)) return true;
    return false;
}

/// The ids a request names with `groupId`, in any number; null when it
/// names none.
fn namedIds(arena: Allocator, params: []const Param) Allocator.Error!?[]const []const u8 {
    var list: std.ArrayList([]const u8) = .empty;
    for (params) |p| if (std.mem.eql(u8, p.name, "groupId")) try list.append(arena, p.value);
    return if (list.items.len == 0) null else list.items;
}

/// "fakeG1", "fakeG2", ...: base64url characters, as production's are.
fn groupId(arena: Allocator, serial: u64) Allocator.Error![]const u8 {
    return arena.print("fakeG{d}", .{serial});
}

fn periodOf(name: []const u8) ?types.Period {
    const periods = [_]struct { []const u8, []const u8, types.Period }{
        .{ "PERIOD_1_HOUR", "1", .hour },
        .{ "PERIOD_6_HOURS", "2", .six_hours },
        .{ "PERIOD_1_DAY", "3", .day },
        .{ "PERIOD_1_WEEK", "4", .week },
        .{ "PERIOD_30_DAYS", "5", .thirty_days },
    };
    for (periods) |p| if (std.mem.eql(u8, name, p[0]) or std.mem.eql(u8, name, p[1])) return p[2];
    return null;
}

/// A Duration as the query carries it, whole seconds: "3600s".
fn durationSeconds(text: []const u8) ?i64 {
    if (text.len < 2 or text[text.len - 1] != 's') return null;
    return std.fmt.parseInt(i64, text[0 .. text.len - 1], 10) catch null;
}

const Window = struct { from: usize, to: usize, next: ?usize };

/// The page a request asks for, out of `len` items; null for a token the
/// fake did not issue.
fn pageOf(params: []const Param, len: usize) Allocator.Error!?Window {
    const size: usize = if (paramOf(params, "pageSize")) |s| std.fmt.parseInt(u31, s, 10) catch 20 else 20;
    const from: usize = if (paramOf(params, "pageToken")) |t| decodeToken(t) orelse return null else 0;
    const start = @min(from, len);
    const to = @min(start + @max(size, 1), len);
    return .{ .from = start, .to = to, .next = if (to < len) to else null };
}

fn decodeToken(token: []const u8) ?usize {
    if (!std.mem.startsWith(u8, token, "fake-page-")) return null;
    return std.fmt.parseInt(usize, token["fake-page-".len..], 10) catch null;
}

// Rendering.

fn render(arena: Allocator, g: *const FakeErrorReporting.Stored) Allocator.Error![]const u8 {
    var out: std.Io.Writer.Allocating = .init(arena);
    var jw: Stringify = .{ .writer = &out.writer };
    writeGroup(&jw, g) catch return error.OutOfMemory;
    return out.toOwnedSlice();
}

fn writeGroup(jw: *Stringify, g: *const FakeErrorReporting.Stored) Stringify.Error!void {
    try jw.beginObject();
    try jw.objectField("name");
    try jw.write(g.name);
    try jw.objectField("groupId");
    try jw.write(g.id);
    if (g.issues.len > 0) {
        try jw.objectField("trackingIssues");
        try jw.beginArray();
        for (g.issues) |url| {
            try jw.beginObject();
            try jw.objectField("url");
            try jw.write(url);
            try jw.endObject();
        }
        try jw.endArray();
    }
    try jw.objectField("resolutionStatus");
    try jw.write(g.status.wire());
    try jw.endObject();
}

fn writeTime(jw: *Stringify, name: []const u8, ns: i96) Stringify.Error!void {
    var buf: [core.timestamp.max_len]u8 = undefined;
    try jw.objectField(name);
    try jw.write(core.timestamp.format(&buf, .{ .nanoseconds = ns }));
}

fn writeService(jw: *Stringify, s: types.ServiceContext) Stringify.Error!void {
    try jw.beginObject();
    if (s.service) |v| {
        try jw.objectField("service");
        try jw.write(v);
    }
    if (s.version) |v| {
        try jw.objectField("version");
        try jw.write(v);
    }
    if (s.resource_type) |v| {
        try jw.objectField("resourceType");
        try jw.write(v);
    }
    try jw.endObject();
}

fn writeEvent(jw: *Stringify, e: types.Event) Stringify.Error!void {
    try jw.beginObject();
    try writeTime(jw, "eventTime", e.time.?.nanoseconds);
    try jw.objectField("serviceContext");
    try writeService(jw, e.service);
    try jw.objectField("message");
    try jw.write(e.message);
    try jw.objectField("context");
    try jw.beginObject();
    if (e.context.http_request) |h| {
        try jw.objectField("httpRequest");
        try jw.beginObject();
        inline for (.{ .{ "method", h.method }, .{ "url", h.url }, .{ "userAgent", h.user_agent }, .{ "referrer", h.referrer }, .{ "remoteIp", h.remote_ip } }) |pair| {
            if (pair[1]) |v| {
                try jw.objectField(pair[0]);
                try jw.write(v);
            }
        }
        if (h.response_status_code) |code| {
            try jw.objectField("responseStatusCode");
            try jw.write(code);
        }
        try jw.endObject();
    }
    if (e.context.user) |u| {
        try jw.objectField("user");
        try jw.write(u);
    }
    if (e.context.report_location) |l| {
        try jw.objectField("reportLocation");
        try jw.beginObject();
        if (l.file_path) |p| {
            try jw.objectField("filePath");
            try jw.write(p);
        }
        if (l.line_number) |n| {
            try jw.objectField("lineNumber");
            try jw.write(n);
        }
        if (l.function_name) |n| {
            try jw.objectField("functionName");
            try jw.write(n);
        }
        try jw.endObject();
    }
    try jw.endObject();
    try jw.endObject();
}

fn writeStatsPage(jw: *Stringify, items: []const FakeErrorReporting.Computed, next: ?usize, begin_s: i64) Stringify.Error!void {
    try jw.beginObject();
    if (items.len > 0) {
        try jw.objectField("errorGroupStats");
        try jw.beginArray();
        for (items) |c| {
            try jw.beginObject();
            try jw.objectField("group");
            try writeGroup(jw, c.g);
            // Counts travel as strings, as int64s do.
            try jw.objectField("count");
            try jw.print("\"{d}\"", .{c.count});
            try jw.objectField("affectedUsersCount");
            try jw.print("\"{d}\"", .{c.users});
            if (c.buckets.len > 0) {
                try jw.objectField("timedCounts");
                try jw.beginArray();
                for (c.buckets) |t| {
                    try jw.beginObject();
                    // Production leaves out an empty bucket's count.
                    if (t.count > 0) {
                        try jw.objectField("count");
                        try jw.print("\"{d}\"", .{t.count});
                    }
                    try writeTime(jw, "startTime", t.start.nanoseconds);
                    try writeTime(jw, "endTime", t.end.nanoseconds);
                    try jw.endObject();
                }
                try jw.endArray();
            }
            if (c.first_seen) |ns| try writeTime(jw, "firstSeenTime", ns);
            if (c.last_seen) |ns| try writeTime(jw, "lastSeenTime", ns);
            if (c.services.len > 0) {
                try jw.objectField("affectedServices");
                try jw.beginArray();
                for (c.services) |s| try writeService(jw, s);
                try jw.endArray();
            }
            try jw.objectField("numAffectedServices");
            try jw.write(c.services.len);
            if (c.representative) |e| {
                try jw.objectField("representative");
                try writeEvent(jw, e);
            }
            try jw.endObject();
        }
        try jw.endArray();
    }
    if (next) |n| {
        try jw.objectField("nextPageToken");
        try jw.print("\"fake-page-{d}\"", .{n});
    }
    try writeTime(jw, "timeRangeBegin", @as(i96, begin_s) * std.time.ns_per_s);
    try jw.endObject();
}

fn writeEventsPage(jw: *Stringify, items: []const types.Event, next: ?usize, begin_s: i64) Stringify.Error!void {
    try jw.beginObject();
    if (items.len > 0) {
        try jw.objectField("errorEvents");
        try jw.beginArray();
        for (items) |e| try writeEvent(jw, e);
        try jw.endArray();
    }
    if (next) |n| {
        try jw.objectField("nextPageToken");
        try jw.print("\"fake-page-{d}\"", .{n});
    }
    try writeTime(jw, "timeRangeBegin", @as(i96, begin_s) * std.time.ns_per_s);
    try jw.endObject();
}

fn dupeService(a: Allocator, s: types.ServiceContext) Allocator.Error!types.ServiceContext {
    return .{
        .service = if (s.service) |v| try a.dupe(u8, v) else null,
        .version = if (s.version) |v| try a.dupe(u8, v) else null,
        .resource_type = if (s.resource_type) |v| try a.dupe(u8, v) else null,
    };
}

fn dupeHttp(a: Allocator, h: types.HttpRequest) Allocator.Error!types.HttpRequest {
    return .{
        .method = if (h.method) |v| try a.dupe(u8, v) else null,
        .url = if (h.url) |v| try a.dupe(u8, v) else null,
        .user_agent = if (h.user_agent) |v| try a.dupe(u8, v) else null,
        .referrer = if (h.referrer) |v| try a.dupe(u8, v) else null,
        .response_status_code = h.response_status_code,
        .remote_ip = if (h.remote_ip) |v| try a.dupe(u8, v) else null,
    };
}

// Requests.

const Route = struct {
    project: []const u8,
    location: ?[]const u8,
    kind: union(enum) { group_stats, events, group: []const u8 },
};

/// `/v1beta1/projects/P[/locations/L]/groupStats`, `.../events` or
/// `.../groups/ID`; null for anything else.
fn parseRoute(route: []const u8) ?Route {
    const prefix = "/v1beta1/projects/";
    if (!std.mem.startsWith(u8, route, prefix)) return null;
    var parts = std.mem.splitScalar(u8, route[prefix.len..], '/');
    const project = parts.next() orelse return null;
    var next = parts.next() orelse return null;
    var location: ?[]const u8 = null;
    if (std.mem.eql(u8, next, "locations")) {
        location = parts.next() orelse return null;
        next = parts.next() orelse return null;
    }
    const kind: @FieldType(Route, "kind") = if (std.mem.eql(u8, next, "groupStats"))
        .group_stats
    else if (std.mem.eql(u8, next, "events"))
        .events
    else if (std.mem.eql(u8, next, "groups"))
        .{ .group = parts.next() orelse return null }
    else
        return null;
    if (parts.next() != null) return null;
    return .{ .project = project, .location = location, .kind = kind };
}

const Param = struct { name: []const u8, value: []const u8 };

/// The query string's parameters, percent-decoded, `groupId` as often as
/// given; null for one that does not decode.
fn parseParams(arena: Allocator, query: []const u8) Allocator.Error!?[]const Param {
    var list: std.ArrayList(Param) = .empty;
    if (query.len == 0) return list.items;
    var it = std.mem.splitScalar(u8, query, '&');
    while (it.next()) |pair| {
        const eq = std.mem.indexOfScalar(u8, pair, '=') orelse return null;
        const name = try decode(arena, pair[0..eq]) orelse return null;
        const value = try decode(arena, pair[eq + 1 ..]) orelse return null;
        try list.append(arena, .{ .name = name, .value = value });
    }
    return list.items;
}

fn decode(arena: Allocator, text: []const u8) Allocator.Error!?[]const u8 {
    const out = try arena.alloc(u8, text.len);
    var n: usize = 0;
    var i: usize = 0;
    while (i < text.len) : (i += 1) {
        if (text[i] == '%') {
            if (i + 3 > text.len) return null;
            out[n] = std.fmt.parseInt(u8, text[i + 1 .. i + 3], 16) catch return null;
            i += 2;
        } else {
            out[n] = text[i];
        }
        n += 1;
    }
    return out[0..n];
}

/// The last value given for `name`.
fn paramOf(params: []const Param, name: []const u8) ?[]const u8 {
    var found: ?[]const u8 = null;
    for (params) |p| if (std.mem.eql(u8, p.name, name)) {
        found = p.value;
    };
    return found;
}

fn pathOf(url: []const u8) []const u8 {
    const scheme = std.mem.indexOf(u8, url, "://") orelse return url;
    const rest = url[scheme + 3 ..];
    const slash = std.mem.indexOfScalar(u8, rest, '/') orelse return "/";
    return rest[slash..];
}

// Refusals, in production's words.

fn fail(arena: Allocator, code: u16, status: []const u8, message: []const u8) Allocator.Error!FakeErrorReporting.Reply {
    return .{ .status = code, .body = try Stringify.valueAlloc(arena, .{ .@"error" = .{
        .code = code,
        .message = message,
        .status = status,
    } }, .{}) };
}

fn groupRefusal(arena: Allocator, id: []const u8) Allocator.Error!FakeErrorReporting.Reply {
    return fail(arena, 400, "INVALID_ARGUMENT", try arena.print("Invalid group id: {s}", .{id}));
}

fn periodRefusal(arena: Allocator, name: []const u8) Allocator.Error!FakeErrorReporting.Reply {
    return fieldRefusal(arena, "time_range.period", try arena.print("Invalid value at 'time_range.period' (type.googleapis.com/google.devtools.clouderrorreporting.v1beta1.QueryTimeRange.Period), \"{s}\"", .{name}));
}

/// A 400 with a `BadRequest` naming `field`, as production refuses a value
/// that is not one.
fn fieldRefusal(arena: Allocator, field: []const u8, message: []const u8) Allocator.Error!FakeErrorReporting.Reply {
    return .{ .status = 400, .body = try Stringify.valueAlloc(arena, .{ .@"error" = .{
        .code = 400,
        .message = message,
        .status = "INVALID_ARGUMENT",
        .details = .{.{
            .@"@type" = "type.googleapis.com/google.rpc.BadRequest",
            .fieldViolations = .{.{ .field = field, .description = message }},
        }},
    } }, .{}) };
}

/// Production's 403 for the API off, its consumer the fake's project.
fn disabled(arena: Allocator, project: []const u8) Allocator.Error!FakeErrorReporting.Reply {
    const link = try arena.print("https://console.developers.google.com/apis/api/clouderrorreporting.googleapis.com/overview?project={s}", .{project});
    const message = try arena.print("Error Reporting API has not been used in project {s} before or it is disabled. Enable it by visiting {s} then retry. If you enabled this API recently, wait a few minutes for the action to propagate to our systems and retry.", .{ project, link });
    return .{ .status = 403, .body = try Stringify.valueAlloc(arena, .{ .@"error" = .{
        .code = 403,
        .message = message,
        .status = "PERMISSION_DENIED",
        .details = .{.{
            .@"@type" = "type.googleapis.com/google.rpc.ErrorInfo",
            .reason = "SERVICE_DISABLED",
            .domain = "googleapis.com",
            .metadata = .{
                .activationUrl = link,
                .consumer = try arena.print("projects/{s}", .{project}),
                .containerInfo = project,
                .service = "clouderrorreporting.googleapis.com",
                .serviceTitle = "Error Reporting API",
            },
        }},
    } }, .{}) };
}

/// A 429 for the per-user quota, its names from the quotas page, as no
/// production 429 was met.
fn quotaRefusal(arena: Allocator, project: []const u8) Allocator.Error!FakeErrorReporting.Reply {
    return .{ .status = 429, .body = try Stringify.valueAlloc(arena, .{ .@"error" = .{
        .code = 429,
        .message = try arena.print("Quota exceeded for quota metric 'Error event data requests' and limit 'Error event data requests per minute per user' of service 'clouderrorreporting.googleapis.com' for consumer 'project:{s}'.", .{project}),
        .status = "RESOURCE_EXHAUSTED",
        .details = .{.{
            .@"@type" = "type.googleapis.com/google.rpc.ErrorInfo",
            .reason = "RATE_LIMIT_EXCEEDED",
            .domain = "googleapis.com",
            .metadata = .{ .service = "clouderrorreporting.googleapis.com", .quota_limit_value = "60" },
        }},
    } }, .{}) };
}

fn refusal(arena: Allocator, code: u16) Allocator.Error!FakeErrorReporting.Reply {
    return switch (code) {
        403 => fail(arena, 403, "PERMISSION_DENIED", "The caller does not have permission"),
        429 => quotaRefusal(arena, "my-project"),
        500 => fail(arena, 500, "INTERNAL", "Internal error encountered."),
        503 => fail(arena, 503, "UNAVAILABLE", "The service is currently unavailable."),
        504 => fail(arena, 504, "DEADLINE_EXCEEDED", "The request timed out."),
        else => fail(arena, code, "UNKNOWN", "fake: refused"),
    };
}

/// `reply`, asking for the delay a scripted refusal carries, if any.
fn asking(arena: Allocator, reply: FakeErrorReporting.Reply, delay: ?core.retry_after.Asked) Allocator.Error!FakeErrorReporting.Reply {
    const d = delay orelse return reply;
    return .{ .status = reply.status, .headers = try d.headers(arena), .body = try d.intoBody(arena, reply.body) };
}

/// What this fake has no answer for: said, never guessed at.
fn notModelled(arena: Allocator, what: []const u8) Allocator.Error!FakeErrorReporting.Reply {
    return fail(arena, 501, "UNIMPLEMENTED", try arena.print("fake: {s} is not modelled", .{what}));
}

const testing = std.testing;
const Client = @import("Client.zig");
const bodies = @import("production_bodies.zig");
const test_util = @import("test_util.zig");

/// 2026-10-18T12:00:00Z.
const noon_s: i64 = 1792324800;

fn at(seconds_before_noon: i64) std.Io.Timestamp {
    return .{ .nanoseconds = @as(i96, noon_s - seconds_before_noon) * std.time.ns_per_s };
}

/// A client on the fake, on a clock that stands at noon until a test moves it.
const Rig = struct {
    clock: test_util.FakeClock,
    fake: FakeErrorReporting,
    token: core.StaticToken,
    diag: core.Diagnostics,
    client: Client,

    fn init(r: *Rig, options: FakeErrorReporting.Options, location: ?[]const u8) !void {
        r.clock = .{ .now_ns = @as(i96, noon_s) * std.time.ns_per_s };
        r.fake = .init(testing.allocator, r.clock.io(), options);
        errdefer r.fake.deinit();
        r.token = .{ .token = "ya29.test" };
        r.diag = .{};
        r.client = try .init(testing.allocator, r.clock.io(), .{
            .project_id = options.project_id,
            .location = location,
            .token_provider = r.token.provider(),
            .transport = r.fake.transport(),
            .diagnostics = &r.diag,
            .calls_per_minute = 0,
        });
    }

    fn deinit(r: *Rig) void {
        r.client.deinit();
        r.fake.deinit();
    }

    /// The first page of group stats.
    fn stats(r: *Rig, options: types.GroupStatsOptions) !types.Owned(types.GroupStatsPage) {
        var q = try r.client.groupStats(options);
        defer q.deinit();
        return q.page(null);
    }

    /// A raw GET of `path_and_query`, as no client would send it.
    fn raw(r: *Rig, arena: Allocator, method: tp.Method, path_and_query: []const u8, body: ?[]const u8) !FakeErrorReporting.Reply {
        return r.fake.serve(.{
            .method = method,
            .url = try arena.print("https://clouderrorreporting.googleapis.com{s}", .{path_and_query}),
            .bearer = "ya29.test",
            .body = body,
        }, arena);
    }

    /// Three groups: a Python one (three errors, two users, service a v1),
    /// a Java one (one error, service a v2), a Node one (two errors,
    /// service b).
    fn fill(r: *Rig) !struct { py: []const u8, java: []const u8, node: []const u8 } {
        const py_trace = "Traceback (most recent call last):\n  File \"orders.py\", line 12, in price\nValueError: order has no lines";
        const a_v1: types.ServiceContext = .{ .service = "a", .version = "v1", .resource_type = "reported_errors" };
        const py = try r.fake.report(.{ .message = py_trace, .time = at(3 * 3600), .service = a_v1, .user = "u1" });
        _ = try r.fake.report(.{ .message = py_trace, .time = at(600), .service = a_v1, .user = "u1" });
        _ = try r.fake.report(.{ .message = py_trace, .time = at(2 * 3600), .service = a_v1, .http_request = .{ .remote_ip = "192.0.2.7" } });
        const java = try r.fake.report(.{ .message = "java.lang.NullPointerException: customer is null\n\tat Billing.charge(Billing.java:88)", .time = at(3601), .service = .{ .service = "a", .version = "v2" } });
        const node = try r.fake.report(.{ .message = "TypeError: x is undefined", .group = "node", .time = at(1800), .service = .{ .service = "b" } });
        _ = try r.fake.report(.{ .message = "TypeError: y is undefined", .group = "node", .time = at(1700), .service = .{ .service = "b" } });
        return .{ .py = py, .java = java, .node = node };
    }
};

fn idsOf(page: types.GroupStatsPage) ![]const []const u8 {
    const out = try testing.allocator.alloc([]const u8, page.items.len);
    for (page.items, out) |s, *id| id.* = s.group.id;
    return out;
}

fn expectIds(page: types.GroupStatsPage, want: []const []const u8) !void {
    const got = try idsOf(page);
    defer testing.allocator.free(got);
    try testing.expectEqual(want.len, got.len);
    for (got, want) |g, w| try testing.expectEqualStrings(w, g);
}

test "through the client: errors grouped and counted, as production counts them" {
    var r: Rig = undefined;
    try r.init(.{}, null);
    defer r.deinit();
    const g = try r.fill();
    var page = try r.stats(.{ .period = .day });
    defer page.deinit();
    try expectIds(page.value, &.{ g.py, g.node, g.java });
    const py = page.value.items[0];
    try testing.expectEqualStrings("projects/my-project/groups/fakeG1", py.group.name);
    try testing.expectEqual(.open, py.group.status);
    try testing.expectEqual(3, py.count);
    // A user and an address: two.
    try testing.expectEqual(2, py.affected_users);
    // First seen is the first to arrive; last seen the latest, in whole
    // seconds.
    try testing.expectEqual(at(3 * 3600).nanoseconds, py.first_seen.?.nanoseconds);
    try testing.expectEqual(at(600).nanoseconds, py.last_seen.?.nanoseconds);
    try testing.expectEqual(1, py.affected_service_count);
    try testing.expectEqualStrings("v1", py.affected_services[0].version.?);
    try testing.expectEqualStrings("ValueError: order has no lines", py.representative.?.headline());
    try testing.expectEqual(0, page.value.items[2].affected_users);
    try testing.expectEqual(at(noon_s - (noon_s - 24 * 3600)).nanoseconds, page.value.time_range_begin.?.nanoseconds);
    // The same trace text groups, as does the same key.
    try testing.expectEqual(2, page.value.items[1].count);
}

test "through the client: first seen is the first error to arrive, last seen the latest in whole seconds" {
    var r: Rig = undefined;
    try r.init(.{}, null);
    defer r.deinit();
    const g = try r.fill();
    // A report backdated past the group's first, as production's probe
    // sent: first seen does not move.
    _ = try r.fake.report(.{ .message = "TypeError: w", .group = "node", .time = at(5 * 3600), .service = .{ .service = "b" } });
    _ = try r.fake.report(.{ .message = "TypeError: v", .group = "node", .time = .{ .nanoseconds = @as(i96, noon_s) * std.time.ns_per_s - 500 * std.time.ns_per_ms }, .service = .{ .service = "b" } });
    var page = try r.stats(.{ .period = .day, .group_ids = &.{g.node} });
    defer page.deinit();
    const node = page.value.items[0];
    try testing.expectEqual(at(1800).nanoseconds, node.first_seen.?.nanoseconds);
    try testing.expectEqual(at(1).nanoseconds, node.last_seen.?.nanoseconds);
    try testing.expectEqual(4, node.count);
}

test "through the client: each order, a service filter, a shorter period, groups by id" {
    var r: Rig = undefined;
    try r.init(.{}, null);
    defer r.deinit();
    const g = try r.fill();
    inline for (.{
        .{ types.Order.created, &[_][]const u8{ g.node, g.java, g.py } },
        .{ types.Order.last_seen, &[_][]const u8{ g.py, g.node, g.java } },
        // Two users, then a tie at none, broken by age.
        .{ types.Order.affected_users, &[_][]const u8{ g.py, g.java, g.node } },
    }) |case| {
        var page = try r.stats(.{ .period = .day, .order = case[0] });
        defer page.deinit();
        try expectIds(page.value, case[1]);
    }
    {
        var page = try r.stats(.{ .period = .day, .service = .{ .service = "a", .version = "v2" } });
        defer page.deinit();
        try expectIds(page.value, &.{g.java});
    }
    {
        // An hour back: the Java error is a second too old.
        var page = try r.stats(.{ .period = .hour });
        defer page.deinit();
        try expectIds(page.value, &.{ g.node, g.py });
    }
    {
        // Asked for by id, a group with no errors in the period is there.
        var page = try r.stats(.{ .period = .hour, .group_ids = &.{ g.java, g.py } });
        defer page.deinit();
        try expectIds(page.value, &.{ g.py, g.java });
        try testing.expectEqual(0, page.value.items[1].count);
        try testing.expectEqual(null, page.value.items[1].representative);
        try testing.expectEqual(at(3601).nanoseconds, page.value.items[1].first_seen.?.nanoseconds);
    }
    {
        // No period: the last 7 days.
        var page = try r.stats(.{});
        defer page.deinit();
        try testing.expectEqual(at(7 * 24 * 3600).nanoseconds, page.value.time_range_begin.?.nanoseconds);
    }
}

test "through the client: timed counts, every bucket, at the end or rounded, summing to the count" {
    var r: Rig = undefined;
    try r.init(.{}, null);
    defer r.deinit();
    const g = try r.fill();
    r.clock.now_ns += 1234 * std.time.ns_per_ms;
    {
        var page = try r.stats(.{ .period = .six_hours, .timed_count_seconds = 3600, .group_ids = &.{g.py} });
        defer page.deinit();
        const timed = page.value.items[0].timed_counts;
        try testing.expectEqual(6, timed.len);
        var total: u64 = 0;
        for (timed, 0..) |t, i| {
            total += t.count;
            try testing.expectEqual(3600 * std.time.ns_per_s, t.end.nanoseconds - t.start.nanoseconds);
            if (i > 0) try testing.expectEqual(timed[i - 1].end.nanoseconds, t.start.nanoseconds);
        }
        try testing.expectEqual(page.value.items[0].count, total);
        // Ending at now, in whole seconds.
        try testing.expectEqual(@as(i96, noon_s + 1) * std.time.ns_per_s, timed[5].end.nanoseconds);
    }
    {
        // On the hour, from 06:00:01: the first bucket and the last cut short.
        var page = try r.stats(.{ .period = .six_hours, .timed_count_seconds = 3600, .alignment = .{ .rounded = .{ .nanoseconds = 0 } }, .group_ids = &.{g.py} });
        defer page.deinit();
        const timed = page.value.items[0].timed_counts;
        try testing.expectEqual(7, timed.len);
        try testing.expectEqual(3599 * std.time.ns_per_s, timed[0].end.nanoseconds - timed[0].start.nanoseconds);
        try testing.expectEqual(1 * std.time.ns_per_s, timed[6].end.nanoseconds - timed[6].start.nanoseconds);
        var total: u64 = 0;
        for (timed) |t| total += t.count;
        try testing.expectEqual(3, total);
    }
    {
        // A width that does not divide the period: the first bucket short.
        var page = try r.stats(.{ .period = .hour, .timed_count_seconds = 1000, .group_ids = &.{g.py} });
        defer page.deinit();
        const timed = page.value.items[0].timed_counts;
        try testing.expectEqual(4, timed.len);
        try testing.expectEqual(600 * std.time.ns_per_s, timed[0].end.nanoseconds - timed[0].start.nanoseconds);
    }
}

test "through the client: events newest first, page by page; 30 days by default" {
    var r: Rig = undefined;
    try r.init(.{}, null);
    defer r.deinit();
    const g = try r.fill();
    var q = try r.client.events(g.py, .{ .page_size = 2 });
    defer q.deinit();
    var first = try q.page(null);
    defer first.deinit();
    try testing.expectEqual(2, first.value.items.len);
    try testing.expectEqual(at(600).nanoseconds, first.value.items[0].time.?.nanoseconds);
    try testing.expectEqual(at(2 * 3600).nanoseconds, first.value.items[1].time.?.nanoseconds);
    try testing.expectEqual(at(30 * 24 * 3600).nanoseconds, first.value.time_range_begin.?.nanoseconds);
    var second = try q.page(first.value.next_page_token);
    defer second.deinit();
    try testing.expectEqual(1, second.value.items.len);
    try testing.expectEqual(null, second.value.next_page_token);
    try testing.expectEqualStrings("u1", second.value.items[0].context.user.?);
    try testing.expectEqualStrings("a", second.value.items[0].service.service.?);
}

test "through the client: muted groups vanish, even by id; resolved ones reopen; an update keeps what it sends" {
    var r: Rig = undefined;
    try r.init(.{}, null);
    defer r.deinit();
    const g = try r.fill();
    var muted = try r.client.group(g.node).setStatus(.muted);
    muted.deinit();
    {
        var page = try r.stats(.{ .period = .day, .group_ids = &.{ g.node, g.py } });
        defer page.deinit();
        try expectIds(page.value, &.{g.py});
    }
    // Its new errors are dropped; get still reads it.
    _ = try r.fake.report(.{ .message = "TypeError: z", .group = "node", .service = .{ .service = "b" } });
    var read = try r.client.group(g.node).get();
    defer read.deinit();
    try testing.expectEqual(.muted, read.value.status);
    var open = try r.client.group(g.node).setStatus(.open);
    open.deinit();
    {
        var page = try r.stats(.{ .period = .day, .group_ids = &.{g.node} });
        defer page.deinit();
        try testing.expectEqual(2, page.value.items[0].count);
    }
    var resolved = try r.client.group(g.py).setStatus(.resolved);
    resolved.deinit();
    try testing.expectEqual(.resolved, r.fake.status(g.py).?);
    _ = try r.fake.report(.{ .message = "Traceback (most recent call last):\n  File \"orders.py\", line 12, in price\nValueError: order has no lines", .service = .{ .service = "a", .version = "v1", .resource_type = "reported_errors" } });
    try testing.expectEqual(.open, r.fake.status(g.py).?);

    // A PUT that leaves out the tracking issues clears them, as production's
    // did; setStatus puts them back.
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const path = try a.print("/v1beta1/projects/my-project/groups/{s}", .{g.java});
    _ = try r.raw(a, .PUT, path, "{\"trackingIssues\":[{\"url\":\"https://example.com/1\"}],\"resolutionStatus\":\"ACKNOWLEDGED\"}");
    var kept = try r.client.group(g.java).setStatus(.resolved);
    defer kept.deinit();
    try testing.expectEqualStrings("https://example.com/1", kept.value.tracking_issues[0].url);
    const cleared = try r.raw(a, .PUT, path, "{\"resolutionStatus\":\"OPEN\"}");
    try testing.expect(std.mem.indexOf(u8, cleared.body, "trackingIssues") == null);
    // UNSPECIFIED is stored as open.
    _ = try r.raw(a, .PUT, path, "{\"resolutionStatus\":\"RESOLUTION_STATUS_UNSPECIFIED\"}");
    try testing.expectEqual(.open, r.fake.status(g.java).?);
}

/// The message of an error body.
fn messageOf(arena: Allocator, body: []const u8) ![]const u8 {
    const parsed = try core.errors.decodeErrorBody(arena, body);
    return parsed.?.message;
}

test "refusals in production's words, held to what production sent" {
    var r: Rig = undefined;
    try r.init(.{}, null);
    defer r.deinit();
    _ = try r.fill();
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const cases = [_]struct { tp.Method, []const u8, ?[]const u8, []const u8, u16 }{
        .{ .GET, "/v1beta1/projects/my-project/groups/zigps-no-such-group", null, bodies.refused_group_id, 400 },
        .{ .GET, "/v1beta1/projects/my-project/events", null, bodies.refused_missing_group_id, 400 },
        .{ .GET, "/v1beta1/projects/my-project/groupStats?pageToken=zigps-not-a-token", null, bodies.refused_page_token, 400 },
        .{ .GET, "/v1beta1/projects/my-project/groupStats?timeRange.period=PERIOD_30_DAYS&timedCountDuration=60s", null, bodies.refused_too_short, 400 },
        .{ .GET, "/v1beta1/projects/my-project/groupStats?timeRange.period=PERIOD_2_DAYS", null, bodies.refused_bad_period, 400 },
        .{ .PUT, "/v1beta1/projects/my-project/groups/fakeG2", "{\"groupId\":\"fakeG2\",\"resolutionStatus\":\"WONTFIX\"}", bodies.refused_bad_status, 400 },
    };
    for (cases) |case| {
        const reply = try r.raw(a, case[0], case[1], case[2]);
        try testing.expectEqual(case[4], reply.status);
        try testing.expectEqualStrings(try messageOf(a, case[3]), try messageOf(a, reply.body));
    }
    // 100 buckets a period is the most.
    try testing.expectEqual(200, (try r.raw(a, .GET, "/v1beta1/projects/my-project/groupStats?timeRange.period=PERIOD_1_DAY&timedCountDuration=864s", null)).status);
    try testing.expectEqual(400, (try r.raw(a, .GET, "/v1beta1/projects/my-project/groupStats?timeRange.period=PERIOD_1_DAY&timedCountDuration=863s", null)).status);
    // Through the client, an unknown group is NotFound.
    try testing.expectError(error.NotFound, r.client.group("CAAAAAAAAAAAAA").get());
    var q = try r.client.events("CAAAAAAAAAAAAA", .{});
    defer q.deinit();
    try testing.expectError(error.NotFound, q.page(null));
}

test "the API off, the per-user quota, and the faults a test asks for" {
    var r: Rig = undefined;
    try r.init(.{ .project_id = "82150720798", .calls_per_minute = 2 }, null);
    defer r.deinit();
    _ = try r.fill();
    r.fake.setApiEnabled(false);
    try testing.expectError(error.ServiceDisabled, r.stats(.{}));
    try testing.expectEqualStrings("projects/82150720798", r.client.lastConsumerRefusal().?.consumer);
    r.fake.setApiEnabled(true);
    for (0..2) |_| {
        var page = try r.stats(.{});
        page.deinit();
    }
    // The third call of the minute is a 429, not retried.
    try testing.expectError(error.ResourceExhausted, r.stats(.{}));
    try testing.expectEqual(4, r.fake.callCount());
    r.clock.now_ns += 60 * std.time.ns_per_s;
    r.fake.refuseNext(1, 503);
    r.fake.dropNext(1);
    var after = try r.stats(.{});
    after.deinit();
    try testing.expectEqual(7, r.fake.callCount());
    r.clock.now_ns += 60 * std.time.ns_per_s;
    r.fake.refuseNextWithDelay(1, 503, .{ .ms = 30_000 });
    try testing.expectError(error.Unavailable, r.stats(.{}));
    try testing.expectEqual(30_000, r.diag.retry_after_ms.?);
}

test "locations: none, global and every region read the same groups; another region none" {
    for ([_]?[]const u8{ null, "global", "-" }) |location| {
        var r: Rig = undefined;
        try r.init(.{}, location);
        defer r.deinit();
        const g = try r.fill();
        var page = try r.stats(.{ .period = .day });
        defer page.deinit();
        try expectIds(page.value, &.{ g.py, g.node, g.java });
        try testing.expectEqualStrings("projects/my-project/groups/fakeG1", page.value.items[0].group.name);
    }
    var r: Rig = undefined;
    try r.init(.{}, "us-central1");
    defer r.deinit();
    const g = try r.fill();
    var page = try r.stats(.{ .period = .day });
    defer page.deinit();
    try testing.expectEqual(0, page.value.items.len);
    try testing.expectError(error.NotFound, r.client.group(g.py).get());
}

test "through the client: an event's whole context comes back as reported" {
    var r: Rig = undefined;
    try r.init(.{}, null);
    defer r.deinit();
    const id = try r.fake.report(.{
        .message = "Error: boom\n    at main (/srv/a.js:1:1)",
        .time = at(60),
        .service = .{ .service = "web", .version = "v3", .resource_type = "cloud_run_revision" },
        .user = "ana",
        .http_request = .{ .method = "POST", .url = "/pay", .user_agent = "curl/8", .referrer = "https://example.com/", .response_status_code = 502, .remote_ip = "192.0.2.1" },
        .report_location = .{ .file_path = "/srv/a.js", .line_number = 1, .function_name = "main" },
    });
    var q = try r.client.events(id, .{});
    defer q.deinit();
    var page = try q.page(null);
    defer page.deinit();
    const e = page.value.items[0];
    try testing.expectEqualStrings("cloud_run_revision", e.service.resource_type.?);
    const h = e.context.http_request.?;
    try testing.expectEqualStrings("POST", h.method.?);
    try testing.expectEqualStrings("/pay", h.url.?);
    try testing.expectEqualStrings("curl/8", h.user_agent.?);
    try testing.expectEqualStrings("https://example.com/", h.referrer.?);
    try testing.expectEqual(502, h.response_status_code.?);
    try testing.expectEqualStrings("192.0.2.1", h.remote_ip.?);
    const l = e.context.report_location.?;
    try testing.expectEqualStrings("/srv/a.js", l.file_path.?);
    try testing.expectEqual(1, l.line_number.?);
    try testing.expectEqualStrings("main", l.function_name.?);
}

test "updates as production takes them: a status by number, and what is not a group" {
    var r: Rig = undefined;
    try r.init(.{}, null);
    defer r.deinit();
    const g = try r.fill();
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const path = try a.print("/v1beta1/projects/my-project/groups/{s}", .{g.py});
    try testing.expectEqual(200, (try r.raw(a, .PUT, path, "{\"resolutionStatus\":3}")).status);
    try testing.expectEqual(.resolved, r.fake.status(g.py).?);
    const bad = try r.raw(a, .PUT, path, "{\"resolutionStatus\":9}");
    try testing.expectEqual(400, bad.status);
    try testing.expect(std.mem.startsWith(u8, try messageOf(a, bad.body), "Invalid value at 'group.resolution_status'"));
    for ([_][]const u8{ "[]", "{\"resolutionStatus\":true}", "{\"trackingIssues\":7}", "{\"trackingIssues\":[1]}", "{\"trackingIssues\":[{\"url\":1}]}", "{" }) |body| {
        try testing.expectEqual(400, (try r.raw(a, .PUT, path, body)).status);
    }
    try testing.expectEqual(501, (try r.raw(a, .POST, path, "{}")).status);
    try testing.expectEqual(501, (try r.raw(a, .DELETE, "/v1beta1/projects/my-project/groupStats", null)).status);
    try testing.expectEqual(null, r.fake.status("fakeG99"));
}

test "a refusal a test asks for, in production's shape for each status" {
    var r: Rig = undefined;
    try r.init(.{}, null);
    defer r.deinit();
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    for ([_]struct { u16, []const u8 }{ .{ 403, "PERMISSION_DENIED" }, .{ 429, "RESOURCE_EXHAUSTED" }, .{ 500, "INTERNAL" }, .{ 503, "UNAVAILABLE" }, .{ 504, "DEADLINE_EXCEEDED" }, .{ 418, "UNKNOWN" } }) |case| {
        r.fake.refuseNext(1, case[0]);
        const reply = try r.raw(a, .GET, "/v1beta1/projects/my-project/groupStats", null);
        try testing.expectEqual(case[0], reply.status);
        try testing.expectEqualStrings(case[1], (try core.errors.decodeErrorBody(a, reply.body)).?.status);
    }
    // No token is production's 401.
    const unauthenticated = try r.fake.serve(.{ .method = .GET, .url = "https://clouderrorreporting.googleapis.com/v1beta1/projects/my-project/groupStats" }, a);
    try testing.expectEqual(401, unauthenticated.status);
}

test "what it does not model, it says" {
    var r: Rig = undefined;
    try r.init(.{}, null);
    defer r.deinit();
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    for ([_]struct { tp.Method, []const u8 }{
        .{ .GET, "/v1beta1/projects/other-project/groupStats" },
        .{ .POST, "/v1beta1/projects/my-project/events:report" },
        .{ .DELETE, "/v1beta1/projects/my-project/events" },
        .{ .GET, "/v1beta1/projects/my-project/locations/-/events?groupId=G" },
        .{ .GET, "/v2/projects/my-project/groupStats" },
    }) |case| {
        const reply = try r.raw(a, case[0], case[1], null);
        try testing.expectEqual(501, reply.status);
        try testing.expect(std.mem.startsWith(u8, try messageOf(a, reply.body), "fake: "));
    }
}

fn statsProperty(_: void, input: []const u8) !void {
    const gpa = test_util.propertyAllocator();
    var g: test_util.ByteGen = .init(input);
    var clock: test_util.FakeClock = .{ .now_ns = @as(i96, noon_s) * std.time.ns_per_s };
    var fake: FakeErrorReporting = .init(gpa, clock.io(), .{});
    defer fake.deinit();
    var token: core.StaticToken = .{ .token = "t" };
    var client = try Client.init(gpa, clock.io(), .{ .project_id = "my-project", .token_provider = token.provider(), .transport = fake.transport(), .calls_per_minute = 0 });
    defer client.deinit();
    // Errors at random times in the last 8 days, in a few groups,
    // services and users.
    const n = g.intRange(usize, 0, 40);
    const keys = [_][]const u8{ "k1", "k2", "k3", "k4" };
    const services = [_][]const u8{ "a", "b" };
    var times: [40]i64 = undefined;
    var groups_of: [40]usize = undefined;
    var services_of: [40]usize = undefined;
    for (0..n) |i| {
        const back: i64 = @intCast(g.intRange(u64, 0, 8 * 24 * 3600));
        const k = g.intRange(usize, 0, keys.len - 1);
        const s = g.intRange(usize, 0, services.len - 1);
        times[i] = back;
        groups_of[i] = k;
        services_of[i] = s;
        _ = try fake.report(.{ .message = "boom", .group = keys[k], .time = at(back), .service = .{ .service = services[s] }, .user = if (g.boolean()) "u" else null });
    }
    const period = g.pick(types.Period, &.{ .hour, .six_hours, .day, .week });
    const width: u32 = @intCast(@divFloor(period.seconds(), @as(i64, @intCast(g.intRange(u64, 1, 100)))) + 1);
    const filter: ?[]const u8 = if (g.boolean()) services[g.intRange(usize, 0, 1)] else null;
    const order = g.pick(types.Order, &.{ .count, .last_seen, .created, .affected_users });
    const rounded = g.boolean();
    var q = try client.groupStats(.{
        .period = period,
        .timed_count_seconds = width,
        .alignment = if (rounded) .{ .rounded = .{ .nanoseconds = @as(i96, g.intRange(u64, 0, 86400)) * std.time.ns_per_s } } else .end,
        .order = order,
        .service = .{ .service = filter },
        .page_size = g.intRange(u31, 1, 5),
    });
    defer q.deinit();
    // Every page, gathered.
    var counts: [4]u64 = @splat(0);
    var seen: usize = 0;
    var token_text: ?[]u8 = null;
    defer if (token_text) |t| gpa.free(t);
    var previous: ?types.GroupStats = null;
    var keep: std.heap.ArenaAllocator = .init(gpa);
    defer keep.deinit();
    // At most 40 errors in pages of at least 1: a token that does not move
    // the list on fails here rather than hanging.
    var pages: usize = 0;
    while (true) : (pages += 1) {
        if (pages > 41) return error.TestPagingDidNotEnd;
        var page = try q.page(token_text);
        defer page.deinit();
        for (page.value.items) |s| {
            seen += 1;
            var total: u64 = 0;
            for (s.timed_counts, 0..) |t, i| {
                total += t.count;
                try testing.expect(t.end.nanoseconds > t.start.nanoseconds);
                if (i > 0) try testing.expectEqual(s.timed_counts[i - 1].end.nanoseconds, t.start.nanoseconds);
            }
            try testing.expectEqual(s.count, total);
            try testing.expect(s.count > 0);
            const k = (std.fmt.parseInt(usize, s.group.id["fakeG".len..], 10) catch unreachable) - 1;
            counts[k] = s.count;
            if (previous) |p| if (order == .count) try testing.expect(p.count >= s.count);
            previous = .{ .group = .{ .name = "", .id = "" }, .count = s.count };
        }
        if (token_text) |t| gpa.free(t);
        token_text = if (page.value.next_page_token) |t| try gpa.dupe(u8, t) else null;
        if (token_text == null) break;
    }
    // The model: errors in the period, by group, under the filter.
    var want: [4]u64 = @splat(0);
    var order_of: [4]usize = @splat(std.math.maxInt(usize));
    for (0..n) |i| {
        if (order_of[groups_of[i]] == std.math.maxInt(usize)) order_of[groups_of[i]] = i;
        if (filter) |f| if (!std.mem.eql(u8, services[services_of[i]], f)) continue;
        if (times[i] <= period.seconds()) want[groups_of[i]] += 1;
    }
    // Groups are numbered in the order they were made.
    var by_serial: [4]u64 = @splat(0);
    var made: usize = 0;
    var serial_of: [4]usize = undefined;
    for (0..n) |i| {
        const k = groups_of[i];
        if (order_of[k] == i) {
            serial_of[k] = made;
            made += 1;
        }
    }
    for (0..keys.len) |k| if (order_of[k] != std.math.maxInt(usize)) {
        by_serial[serial_of[k]] = want[k];
    };
    try testing.expectEqualSlices(u64, &by_serial, &counts);
    var nonzero: usize = 0;
    for (want) |w| nonzero += @intFromBool(w > 0);
    try testing.expectEqual(nonzero, seen);
}

test "fuzz fake: group stats over pages are the model's counts, buckets sum to them" {
    try test_util.fuzzBytes({}, statsProperty, .{ .corpus = &.{ "", "\x05\x00\x00\x00\x01\x02\x03\x04" } });
}
