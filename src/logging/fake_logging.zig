//! A Cloud Logging for tests, behind the `Transport` seam: entries a test
//! writes, listed through `entries.list` as production listed them when
//! measured on 2026-10-16 (milestone 0 of the Logging spec,
//! `_tmp/logging-m0/`; the answers are kept verbatim in
//! `production_bodies.zig`, and a test holds this fake's refusals to them
//! word for word). It is written from what production did, not from this
//! library's encoder: it parses request JSON with code of its own, so a
//! body the encoder gets wrong is refused here as production would. Test
//! code only.
//!
//! What it models:
//!
//! - Entries by scope: a container (`projects/P`, `folders/F`,
//!   `organizations/O`, `billingAccounts/B`) gives every entry whose log
//!   name is under it; a view gives the entries of its bucket, `_AllLogs`
//!   of any bucket and `_Default` of `_Default`. `projectIds`, deprecated,
//!   adds projects, as production still did. A global resource written
//!   without labels reads back with `project_id`, as production's did.
//! - Order: `timestamp asc` (also when absent, "" or plain "timestamp") or
//!   `timestamp desc`, ties in `insertId` order; any other is refused in
//!   production's words ("order_by must be \"asc\" or \"desc\"", "order_by
//!   must be on timestamp"). Entries with the same parent, timestamp and
//!   `insertId` are one in a result, as production returned one of two.
//! - Late arrivals: an entry can be visible only from a time after its
//!   timestamp, and after entries with later timestamps, as Logging takes
//!   in entries out of order. Production showed the probe's entries about
//!   13 s after writing them.
//! - Paging: 50 when absent or 0, any size above, as production served
//!   2000; a negative one refused. A token resumes after the last entry it
//!   returned, as production's did: an entry written later, past that
//!   point, came on the next page. **A token is bound to the filter, to
//!   the byte, and the order**: another of either is the 400
//!   "page_token doesn't match arguments from the request", while another
//!   page size or other resource names kept it good. One it did not issue
//!   is "Invalid page_token". Tokens last 24 hours on the fake's clock.
//! - The server running out of time (`searchingNext`): an empty page with
//!   a token, as production answered a filter with no time bound after
//!   about 5 s, and short pages (`shortenNext`). The `X-Server-Timeout`
//!   that lengthens production's search is not read here.
//! - Filters, by `fake_filter.zig`'s subset of the query language, refused
//!   where production refused them, in its sentences.
//! - Faults: refused calls with any status, a 429 carrying production's
//!   `ErrorInfo` with a quota window ending 5 s on, and dropped
//!   connections.
//!
//! Not modelled, each answered 501 with the reason: a resource name it
//! cannot read beyond the one shape measured, a token past its 24 hours,
//! the calls of later milestones, and what `fake_filter.zig` does not read.
//! JSON payloads are kept as written, where production keeps them as
//! doubles and writes them back its own way (12345678901234567890 as
//! 1.2345678901234567e+19, keys in another order).

const std = @import("std");
const Allocator = std.mem.Allocator;
const Stringify = std.json.Stringify;
const core = @import("core");
const tp = core.transport;
const fake_filter = @import("fake_filter.zig");
const names = @import("names.zig");
const types = @import("types.zig");

pub const FakeLogging = struct {
    gpa: Allocator,
    io: std.Io,
    mutex: std.Io.Mutex = .init,
    /// Holds every entry written, until `deinit`.
    store: std.heap.ArenaAllocator,
    entries: std.ArrayList(*const Stored) = .empty,
    next_insert_id: u64 = 1,
    faults: [4]Fault = @splat(.{}),
    /// `entries.list` calls served, faults included.
    list_calls: usize = 0,
    /// Buckets by full name, in the order made: a parent's `_Default` and
    /// `_Required` first, made when the parent is first seen. In `store`.
    buckets: std.StringArrayHashMapUnmanaged(*Bucket) = .empty,
    /// Parents whose bucket list is refused, and buckets whose view list
    /// is, by name. In `store`.
    denied: std.StringHashMapUnmanaged(void) = .empty,

    /// An entry as a test writes it.
    pub const Entry = struct {
        /// As Logging keeps it, its log id URL-encoded:
        /// "projects/p/logs/run.googleapis.com%2Fstderr". `logName` makes
        /// one from a plain id.
        log_name: []const u8,
        timestamp: std.Io.Timestamp,
        /// When Logging received it. Null: the fake's clock at `write`.
        receive_timestamp: ?std.Io.Timestamp = null,
        /// When `entries.list` first shows it. Null: when it was received.
        visible_at: ?std.Io.Timestamp = null,
        severity: types.Severity = .default,
        /// Null: one is assigned, as Logging assigns one.
        insert_id: ?[]const u8 = null,
        resource_type: []const u8 = "global",
        resource_labels: []const types.Label = &.{},
        labels: []const types.Label = &.{},
        payload: Payload = .none,
        trace: []const u8 = "",
        span_id: []const u8 = "",
        /// The bucket the entry was routed to.
        location: []const u8 = "global",
        bucket: []const u8 = "_Default",

        pub const Payload = union(enum) {
            none,
            text: []const u8,
            /// A JSON object, as it would be written.
            json: []const u8,
        };
    };

    const Stored = struct {
        log_name: []const u8,
        /// Before `/logs/`: "projects/p".
        parent: []const u8,
        log_id: []const u8,
        timestamp: i96,
        receive_timestamp: i96,
        visible_at: i96,
        severity: types.Severity,
        insert_id: []const u8,
        resource_type: []const u8,
        resource_labels: []const types.Label,
        labels: []const types.Label,
        payload: Entry.Payload,
        json: ?std.json.Value,
        trace: []const u8,
        span_id: []const u8,
        location: []const u8,
        bucket: []const u8,
    };

    const Bucket = struct {
        name: []const u8,
        /// "projects/p".
        parent: []const u8,
        location: []const u8,
        id: []const u8,
        description: []const u8,
        retention_days: u32,
        locked: bool,
        state: types.BucketState,
        /// Null for the two a parent is made with.
        create_ns: ?i96,
        analytics_enabled: bool,
        restricted_fields: []const []const u8,
        views: std.ArrayListUnmanaged(View) = .empty,
    };

    const View = struct {
        /// The full name: "projects/p/locations/global/buckets/b/views/v".
        name: []const u8,
        id: []const u8,
        description: []const u8,
        filter: []const u8,
        create_ns: ?i96,
    };

    /// The filter of `_Default`'s own `_Default` view, as production
    /// listed it on 2026-10-16.
    const default_view_filter = "NOT LOG_ID(\"cloudaudit.googleapis.com/data_access\") AND NOT LOG_ID(\"externalaudit.googleapis.com/data_access\")";

    /// A bucket a test adds. It gets an `_AllLogs` view, as Logging gives
    /// every bucket one.
    pub const BucketOptions = struct {
        parent: types.Parent,
        location: []const u8 = "global",
        id: []const u8,
        description: []const u8 = "",
        retention_days: u32 = 30,
        locked: bool = false,
        state: types.BucketState = .active,
        analytics_enabled: bool = false,
        restricted_fields: []const []const u8 = &.{},
    };

    const Fault = struct { n: usize = 0, status: u16 = 0, max: usize = 0 };
    const refuse = 0;
    const drop = 1;
    const searching = 2;
    const short = 3;

    pub const Reply = struct { status: u16, body: []const u8 };

    pub const WriteError = error{ OutOfMemory, InvalidEntry };

    pub fn init(gpa: Allocator, io: std.Io) FakeLogging {
        return .{ .gpa = gpa, .io = io, .store = .init(gpa) };
    }

    pub fn deinit(f: *FakeLogging) void {
        f.entries.deinit(f.gpa);
        f.store.deinit();
        f.* = undefined;
    }

    /// Goes into `Client.Options.transport`.
    pub fn transport(f: *FakeLogging) tp.Transport {
        return .{ .ptr = f, .vtable = &.{ .send = send } };
    }

    /// A log name for a plain log id, as the server keeps it.
    pub fn logName(f: *FakeLogging, parent: types.Parent, log_id: []const u8) Allocator.Error![]const u8 {
        f.mutex.lockUncancelable(f.io);
        defer f.mutex.unlock(f.io);
        return names.logName(f.store.allocator(), parent, log_id);
    }

    /// Stores `entry`, copying everything it holds. `error.InvalidEntry`
    /// for a log name with no `/logs/`, or a JSON payload that is not an
    /// object.
    pub fn write(f: *FakeLogging, entry: Entry) WriteError!void {
        f.mutex.lockUncancelable(f.io);
        defer f.mutex.unlock(f.io);
        const a = f.store.allocator();
        const logs_at = std.mem.indexOf(u8, entry.log_name, "/logs/") orelse return error.InvalidEntry;
        if (logs_at == 0 or logs_at + "/logs/".len == entry.log_name.len) return error.InvalidEntry;
        const json: ?std.json.Value = switch (entry.payload) {
            .json => |bytes| j: {
                const value = std.json.parseFromSliceLeaky(std.json.Value, a, bytes, .{ .parse_numbers = false }) catch |err| switch (err) {
                    error.OutOfMemory => return error.OutOfMemory,
                    else => return error.InvalidEntry,
                };
                if (value != .object) return error.InvalidEntry;
                break :j value;
            },
            else => null,
        };
        const received = if (entry.receive_timestamp) |t| t.nanoseconds else f.now();
        const insert_id = if (entry.insert_id) |id| try a.dupe(u8, id) else id: {
            defer f.next_insert_id += 1;
            break :id try std.fmt.allocPrint(a, "{x:0>16}", .{f.next_insert_id});
        };
        const log_name = try a.dupe(u8, entry.log_name);
        const stored = try a.create(Stored);
        stored.* = .{
            .log_name = log_name,
            .parent = log_name[0..logs_at],
            .log_id = try names.logIdOf(a, log_name),
            .timestamp = entry.timestamp.nanoseconds,
            .receive_timestamp = received,
            .visible_at = if (entry.visible_at) |t| t.nanoseconds else received,
            .severity = entry.severity,
            .insert_id = insert_id,
            .resource_type = try a.dupe(u8, entry.resource_type),
            // Production filled in `project_id` for a global resource
            // written without labels, on 2026-10-16.
            .resource_labels = if (entry.resource_labels.len == 0 and std.mem.eql(u8, entry.resource_type, "global") and std.mem.startsWith(u8, log_name, "projects/"))
                try dupeLabels(a, &.{.{ .key = "project_id", .value = log_name["projects/".len..logs_at] }})
            else
                try dupeLabels(a, entry.resource_labels),
            .labels = try dupeLabels(a, entry.labels),
            .payload = switch (entry.payload) {
                .none => .none,
                .text => |t| .{ .text = try a.dupe(u8, t) },
                .json => |j| .{ .json = try a.dupe(u8, j) },
            },
            .json = json,
            .trace = try a.dupe(u8, entry.trace),
            .span_id = try a.dupe(u8, entry.span_id),
            .location = try a.dupe(u8, entry.location),
            .bucket = try a.dupe(u8, entry.bucket),
        };
        try f.entries.append(f.gpa, stored);
        try f.ensureParent(stored.parent);
    }

    /// Makes `parent`'s `_Default` and `_Required`, as production has them,
    /// the first time the parent is seen.
    fn ensureParent(f: *FakeLogging, parent: []const u8) Allocator.Error!void {
        const a = f.store.allocator();
        const default_name = try std.fmt.allocPrint(a, "{s}/locations/global/buckets/_Default", .{parent});
        if (f.buckets.contains(default_name)) return;
        const owned_parent = try a.dupe(u8, parent);
        const default_bucket = try a.create(Bucket);
        default_bucket.* = .{ .name = default_name, .parent = owned_parent, .location = "global", .id = "_Default", .description = "Default bucket", .retention_days = 30, .locked = false, .state = .active, .create_ns = null, .analytics_enabled = false, .restricted_fields = &.{} };
        try default_bucket.views.append(a, .{ .name = try std.fmt.allocPrint(a, "{s}/views/_AllLogs", .{default_name}), .id = "_AllLogs", .description = "Access to all logs", .filter = "", .create_ns = null });
        try default_bucket.views.append(a, .{ .name = try std.fmt.allocPrint(a, "{s}/views/_Default", .{default_name}), .id = "_Default", .description = "Access to all logs except data access logs", .filter = default_view_filter, .create_ns = null });
        try f.buckets.put(a, default_name, default_bucket);
        const required_name = try std.fmt.allocPrint(a, "{s}/locations/global/buckets/_Required", .{parent});
        const required = try a.create(Bucket);
        required.* = .{ .name = required_name, .parent = owned_parent, .location = "global", .id = "_Required", .description = "Audit bucket", .retention_days = 400, .locked = true, .state = .active, .create_ns = null, .analytics_enabled = false, .restricted_fields = &.{} };
        try required.views.append(a, .{ .name = try std.fmt.allocPrint(a, "{s}/views/_AllLogs", .{required_name}), .id = "_AllLogs", .description = "Access to all logs", .filter = "", .create_ns = null });
        try f.buckets.put(a, required_name, required);
    }

    fn parentText(a: Allocator, parent: types.Parent) Allocator.Error![]const u8 {
        var out: std.Io.Writer.Allocating = .init(a);
        names.writeParent(&out.writer, parent) catch return error.OutOfMemory;
        return out.toOwnedSlice();
    }

    fn bucketText(a: Allocator, name: types.BucketName) Allocator.Error![]const u8 {
        var out: std.Io.Writer.Allocating = .init(a);
        names.writeBucket(&out.writer, name) catch return error.OutOfMemory;
        return out.toOwnedSlice();
    }

    /// Adds a bucket, with an `_AllLogs` view. `error.InvalidEntry` for one
    /// that is there already.
    pub fn addBucket(f: *FakeLogging, options: BucketOptions) WriteError!void {
        f.mutex.lockUncancelable(f.io);
        defer f.mutex.unlock(f.io);
        const a = f.store.allocator();
        const parent = try parentText(a, options.parent);
        try f.ensureParent(parent);
        const name = try bucketText(a, .{ .parent = options.parent, .location = options.location, .bucket = options.id });
        if (f.buckets.contains(name)) return error.InvalidEntry;
        const fields = try a.alloc([]const u8, options.restricted_fields.len);
        for (options.restricted_fields, fields) |s, *o| o.* = try a.dupe(u8, s);
        const b = try a.create(Bucket);
        b.* = .{
            .name = name,
            .parent = parent,
            .location = try a.dupe(u8, options.location),
            .id = try a.dupe(u8, options.id),
            .description = try a.dupe(u8, options.description),
            .retention_days = options.retention_days,
            .locked = options.locked,
            .state = options.state,
            .create_ns = f.now(),
            .analytics_enabled = options.analytics_enabled,
            .restricted_fields = fields,
        };
        try b.views.append(a, .{ .name = try std.fmt.allocPrint(a, "{s}/views/_AllLogs", .{name}), .id = "_AllLogs", .description = "Access to all logs", .filter = "", .create_ns = f.now() });
        try f.buckets.put(a, name, b);
    }

    /// Adds a view to a bucket that exists. `error.InvalidEntry` otherwise,
    /// or for a view that is there already.
    pub fn addView(f: *FakeLogging, bucket_name: types.BucketName, id: []const u8, filter: []const u8) WriteError!void {
        f.mutex.lockUncancelable(f.io);
        defer f.mutex.unlock(f.io);
        const a = f.store.allocator();
        try f.ensureParent(try parentText(a, bucket_name.parent));
        const b = f.buckets.get(try bucketText(a, bucket_name)) orelse return error.InvalidEntry;
        for (b.views.items) |v| if (std.mem.eql(u8, v.id, id)) return error.InvalidEntry;
        try b.views.append(a, .{ .name = try std.fmt.allocPrint(a, "{s}/views/{s}", .{ b.name, id }), .id = try a.dupe(u8, id), .description = "", .filter = try a.dupe(u8, filter), .create_ns = f.now() });
    }

    /// Removes a view, as production lets `_AllLogs` be deleted.
    /// `error.InvalidEntry` for one that is not there.
    pub fn removeView(f: *FakeLogging, name: types.ViewName) WriteError!void {
        f.mutex.lockUncancelable(f.io);
        defer f.mutex.unlock(f.io);
        const a = f.store.allocator();
        try f.ensureParent(try parentText(a, name.parent));
        const b = f.buckets.get(try bucketText(a, .{ .parent = name.parent, .location = name.location, .bucket = name.bucket })) orelse return error.InvalidEntry;
        for (b.views.items, 0..) |v, i| if (std.mem.eql(u8, v.id, name.view)) {
            _ = b.views.orderedRemove(i);
            return;
        };
        return error.InvalidEntry;
    }

    /// Sets a bucket's lifecycle state, such as `.delete_requested`.
    pub fn setBucketState(f: *FakeLogging, name: types.BucketName, state: types.BucketState) WriteError!void {
        f.mutex.lockUncancelable(f.io);
        defer f.mutex.unlock(f.io);
        const a = f.store.allocator();
        try f.ensureParent(try parentText(a, name.parent));
        const b = f.buckets.get(try bucketText(a, name)) orelse return error.InvalidEntry;
        b.state = state;
    }

    /// Refuses `parent`'s bucket list from now on, 403, as a caller with
    /// only a view accessor's role is refused.
    pub fn denyBucketList(f: *FakeLogging, parent: types.Parent) Allocator.Error!void {
        f.mutex.lockUncancelable(f.io);
        defer f.mutex.unlock(f.io);
        const a = f.store.allocator();
        try f.denied.put(a, try parentText(a, parent), {});
    }

    /// Refuses a bucket's view list from now on, 403.
    pub fn denyViewList(f: *FakeLogging, bucket_name: types.BucketName) Allocator.Error!void {
        f.mutex.lockUncancelable(f.io);
        defer f.mutex.unlock(f.io);
        const a = f.store.allocator();
        try f.denied.put(a, try bucketText(a, bucket_name), {});
    }

    fn dupeLabels(a: Allocator, labels: []const types.Label) Allocator.Error![]const types.Label {
        const out = try a.alloc(types.Label, labels.len);
        for (labels, out) |l, *o| o.* = .{ .key = try a.dupe(u8, l.key), .value = try a.dupe(u8, l.value) };
        return out;
    }

    fn now(f: *const FakeLogging) i96 {
        return std.Io.Clock.real.now(f.io).nanoseconds;
    }

    // Faults, each for the next `n` entries.list calls.

    /// Answers them with `status` and production's words for it.
    pub fn refuseNext(f: *FakeLogging, n: usize, status: u16) void {
        f.setFault(refuse, .{ .n = n, .status = status });
    }

    /// Closes their connection before any answer.
    pub fn dropNext(f: *FakeLogging, n: usize) void {
        f.setFault(drop, .{ .n = n });
    }

    /// Answers them with no entries and a token that goes on from where
    /// they were: the server's search ran out of time.
    pub fn searchingNext(f: *FakeLogging, n: usize) void {
        f.setFault(searching, .{ .n = n });
    }

    /// Answers them with at most `max` entries, and a token when more wait.
    pub fn shortenNext(f: *FakeLogging, n: usize, max: usize) void {
        f.setFault(short, .{ .n = n, .max = max });
    }

    fn setFault(f: *FakeLogging, slot: usize, fault: Fault) void {
        f.mutex.lockUncancelable(f.io);
        defer f.mutex.unlock(f.io);
        f.faults[slot] = fault;
    }

    fn takeFault(f: *FakeLogging, slot: usize) ?Fault {
        const fault = &f.faults[slot];
        if (fault.n == 0) return null;
        fault.n -= 1;
        return fault.*;
    }

    /// How many `entries.list` calls it has served.
    pub fn listCalls(f: *FakeLogging) usize {
        f.mutex.lockUncancelable(f.io);
        defer f.mutex.unlock(f.io);
        return f.list_calls;
    }

    // The transport.

    fn send(ptr: *anyopaque, req: tp.Request, arena: Allocator) tp.Error!tp.Response {
        const f: *FakeLogging = @ptrCast(@alignCast(ptr));
        const reply = try f.serve(req.method, req.url, req.body orelse "", arena);
        return .{ .status = reply.status, .body = reply.body };
    }

    /// One request, as `send` serves it: for a test that wants to send
    /// what no client would.
    pub fn serve(f: *FakeLogging, method: tp.Method, url: []const u8, body: []const u8, arena: Allocator) tp.Error!Reply {
        const path = pathOf(url);
        const route = path[0 .. std.mem.indexOfScalar(u8, path, '?') orelse path.len];
        f.mutex.lockUncancelable(f.io);
        defer f.mutex.unlock(f.io);
        if (method == .POST and std.mem.eql(u8, route, "/v2/entries:list")) {
            f.list_calls += 1;
            if (f.takeFault(drop) != null) return error.ConnectionResetByPeer;
            if (f.takeFault(refuse)) |fault| return refusal(arena, fault.status, @intCast(@divFloor(f.now(), std.time.ns_per_s)));
            return f.list(arena, body);
        }
        if (method == .GET and std.mem.startsWith(u8, route, "/v2/")) {
            const query = if (std.mem.indexOfScalar(u8, path, '?')) |q| path[q + 1 ..] else "";
            return f.config(arena, route["/v2/".len..], query);
        }
        return notModelled(arena, "this call");
    }

    /// The calls of `config.zig`: logs, buckets, views.
    fn config(f: *FakeLogging, arena: Allocator, name: []const u8, query: []const u8) Allocator.Error!Reply {
        const page_size = std.fmt.parseInt(usize, queryValue(query, "pageSize") orelse "0", 10) catch return notModelled(arena, "a pageSize that is no number");
        const offset: usize = if (queryValue(query, "pageToken")) |t| decodeOffset(arena, t) orelse return notModelled(arena, "a page token this fake did not issue") else 0;
        if (std.mem.endsWith(u8, name, "/logs")) return f.listLogNames(arena, name[0 .. name.len - "/logs".len], page_size, offset);
        if (std.mem.endsWith(u8, name, "/buckets")) {
            const parent_part = name[0 .. name.len - "/buckets".len];
            const loc_at = std.mem.lastIndexOf(u8, parent_part, "/locations/") orelse return notModelled(arena, "a bucket list this fake cannot read");
            const parent = parent_part[0..loc_at];
            const location = parent_part[loc_at + "/locations/".len ..];
            if (names.parseParent(parent) == null or names.parseParent(parent).?.rest.len != 0) return notModelled(arena, "a bucket list this fake cannot read");
            try f.ensureParent(parent);
            if (f.denied.contains(parent)) return fail(arena, 403, "PERMISSION_DENIED", "The caller does not have permission");
            var found: std.ArrayList(*const Bucket) = .empty;
            for (f.buckets.values()) |b| {
                if (!std.mem.eql(u8, b.parent, parent)) continue;
                if (!std.mem.eql(u8, location, "-") and !std.mem.eql(u8, location, b.location)) continue;
                try found.append(arena, b);
            }
            return f.renderList(arena, "buckets", found.items, page_size, offset);
        }
        if (std.mem.endsWith(u8, name, "/views")) {
            const bucket_part = name[0 .. name.len - "/views".len];
            const parsed = names.parseBucketName(bucket_part) orelse return notModelled(arena, "a view list this fake cannot read");
            if (std.mem.eql(u8, parsed.location, "-")) return fail(arena, 404, "NOT_FOUND", "Cloud Logging does not support location: -");
            try f.ensureParent(try parentText(arena, parsed.parent));
            const b = f.buckets.get(bucket_part) orelse return missingBucket(arena, parsed);
            if (f.denied.contains(bucket_part)) return fail(arena, 403, "PERMISSION_DENIED", "The caller does not have permission");
            var found: std.ArrayList(ViewRef) = .empty;
            for (b.views.items) |*v| try found.append(arena, .{ .bucket = b, .view = v });
            return f.renderList(arena, "views", found.items, page_size, offset);
        }
        if (names.parseViewName(name)) |v| {
            try f.ensureParent(try parentText(arena, v.parent));
            const b = f.buckets.get(name[0..std.mem.lastIndexOf(u8, name, "/views/").?]) orelse return missingBucket(arena, .{ .parent = v.parent, .location = v.location, .bucket = v.bucket });
            for (b.views.items) |*view| if (std.mem.eql(u8, view.id, v.view)) {
                return ok(try renderOne(arena, ViewRef{ .bucket = b, .view = view }));
            };
            return fail(arena, 404, "NOT_FOUND", try std.fmt.allocPrint(arena, "{s} does not exist", .{name}));
        }
        if (names.parseBucketName(name)) |parsed| {
            try f.ensureParent(try parentText(arena, parsed.parent));
            const b = f.buckets.get(name) orelse return missingBucket(arena, parsed);
            return ok(try renderOne(arena, @as(*const Bucket, b)));
        }
        return notModelled(arena, "this call");
    }

    const ViewRef = struct { bucket: *const Bucket, view: *const View };

    /// Production's words, measured on 2026-10-16.
    fn missingBucket(arena: Allocator, name: types.BucketName) Allocator.Error!Reply {
        return fail(arena, 404, "NOT_FOUND", try std.fmt.allocPrint(arena, "Bucket `{s}` in location `{s}` does not exist", .{ name.bucket, name.location }));
    }

    /// The names of the logs that have entries in `scope_name`, a parent
    /// or a view, in byte order, as production listed them.
    fn listLogNames(f: *FakeLogging, arena: Allocator, scope_name: []const u8, page_size: usize, offset: usize) Allocator.Error!Reply {
        var scope = parseScope(scope_name) orelse return notModelled(arena, "a log list this fake cannot read");
        try f.ensureParent(scope.parent);
        if (try f.resolveView(arena, &scope)) |refused| return refused;
        const now_ns = f.now();
        var seen: std.StringArrayHashMapUnmanaged(void) = .empty;
        for (f.entries.items) |e| {
            if (e.visible_at > now_ns or !inAnyScope(e, &.{scope})) continue;
            try seen.put(arena, e.log_name, {});
        }
        const log_names = seen.keys();
        std.mem.sort([]const u8, log_names, {}, struct {
            fn less(_: void, x: []const u8, y: []const u8) bool {
                return std.mem.order(u8, x, y) == .lt;
            }
        }.less);
        return f.renderList(arena, "logNames", log_names, page_size, offset);
    }

    /// Checks a view scope against the views that exist, and reads its
    /// filter: null when it may be read, or the refusal to answer with.
    fn resolveView(f: *FakeLogging, arena: Allocator, scope: *Scope) Allocator.Error!?Reply {
        const v = scope.view orelse return null;
        const bucket_name = try std.fmt.allocPrint(arena, "{s}/locations/{s}/buckets/{s}", .{ scope.parent, v.location, v.bucket });
        const view_name = try std.fmt.allocPrint(arena, "{s}/views/{s}", .{ bucket_name, v.view });
        const b = f.buckets.get(bucket_name) orelse return try fail(arena, 404, "NOT_FOUND", try std.fmt.allocPrint(arena, "{s} does not exist", .{view_name}));
        for (b.views.items) |view| if (std.mem.eql(u8, view.id, v.view)) {
            if (view.filter.len == 0) return null;
            if (std.mem.eql(u8, view.filter, default_view_filter)) {
                scope.exclude_data_access = true;
                return null;
            }
            return try notModelled(arena, "a view with a filter of its own");
        };
        return try fail(arena, 404, "NOT_FOUND", try std.fmt.allocPrint(arena, "{s} does not exist", .{view_name}));
    }

    fn renderList(f: *FakeLogging, arena: Allocator, comptime field: []const u8, items: anytype, page_size: usize, offset: usize) Allocator.Error!Reply {
        _ = f;
        const start = @min(offset, items.len);
        const end = if (page_size == 0) items.len else @min(items.len, start + page_size);
        var out: std.Io.Writer.Allocating = .init(arena);
        var jw: Stringify = .{ .writer = &out.writer };
        writeList(&jw, field, items[start..end], if (end < items.len) try encodeOffset(arena, end) else null) catch return error.OutOfMemory;
        return ok(try out.toOwnedSlice());
    }

    fn writeList(jw: *Stringify, comptime field: []const u8, items: anytype, token: ?[]const u8) Stringify.Error!void {
        try jw.beginObject();
        if (items.len > 0) {
            try jw.objectField(field);
            try jw.beginArray();
            for (items) |item| try writeItem(jw, item);
            try jw.endArray();
        }
        if (token) |t| {
            try jw.objectField("nextPageToken");
            try jw.write(t);
        }
        try jw.endObject();
    }

    fn renderOne(arena: Allocator, item: anytype) Allocator.Error![]const u8 {
        var out: std.Io.Writer.Allocating = .init(arena);
        var jw: Stringify = .{ .writer = &out.writer };
        writeItem(&jw, item) catch return error.OutOfMemory;
        return out.toOwnedSlice();
    }

    /// A log name, a bucket or a view, with the fields production sent.
    fn writeItem(jw: *Stringify, item: anytype) Stringify.Error!void {
        switch (@TypeOf(item)) {
            []const u8 => try jw.write(item),
            *const Bucket => {
                const b = item;
                try jw.beginObject();
                try jw.objectField("name");
                try jw.write(b.name);
                try jw.objectField("description");
                try jw.write(b.description);
                if (b.create_ns) |t| try writeTime(jw, "createTime", t);
                if (b.locked) {
                    try jw.objectField("locked");
                    try jw.write(true);
                }
                try jw.objectField("retentionDays");
                try jw.write(b.retention_days);
                try jw.objectField("lifecycleState");
                try jw.write(switch (b.state) {
                    .active => "ACTIVE",
                    .delete_requested => "DELETE_REQUESTED",
                    .updating => "UPDATING",
                    .creating => "CREATING",
                    .failed => "FAILED",
                    .unspecified, .unknown => "LIFECYCLE_STATE_UNSPECIFIED",
                });
                if (b.analytics_enabled) {
                    try jw.objectField("analyticsEnabled");
                    try jw.write(true);
                }
                if (b.restricted_fields.len > 0) {
                    try jw.objectField("restrictedFields");
                    try jw.write(b.restricted_fields);
                }
                try jw.endObject();
            },
            ViewRef => {
                try jw.beginObject();
                try jw.objectField("name");
                try jw.write(item.view.name);
                try jw.objectField("description");
                try jw.write(item.view.description);
                if (item.view.filter.len > 0) {
                    try jw.objectField("filter");
                    try jw.write(item.view.filter);
                }
                if (item.view.create_ns) |t| try writeTime(jw, "createTime", t);
                try jw.endObject();
            },
            else => @compileError("no rendering for " ++ @typeName(@TypeOf(item))),
        }
    }

    fn queryValue(query: []const u8, name: []const u8) ?[]const u8 {
        var it = std.mem.splitScalar(u8, query, '&');
        while (it.next()) |pair| {
            const eq = std.mem.indexOfScalar(u8, pair, '=') orelse continue;
            if (std.mem.eql(u8, pair[0..eq], name)) return pair[eq + 1 ..];
        }
        return null;
    }

    fn encodeOffset(arena: Allocator, offset: usize) Allocator.Error![]const u8 {
        return std.fmt.allocPrint(arena, "fake-offset-{d}", .{offset});
    }

    fn decodeOffset(arena: Allocator, token: []const u8) ?usize {
        _ = arena;
        const prefix = "fake-offset-";
        if (!std.mem.startsWith(u8, token, prefix)) return null;
        return std.fmt.parseInt(usize, token[prefix.len..], 10) catch null;
    }

    fn pathOf(url: []const u8) []const u8 {
        const scheme_end = (std.mem.indexOf(u8, url, "://") orelse return url) + 3;
        const slash = std.mem.indexOfScalarPos(u8, url, scheme_end, '/') orelse return "/";
        return url[slash..];
    }

    const known_fields = [_][]const u8{ "resourceNames", "projectIds", "filter", "orderBy", "pageSize", "pageToken" };

    const WireList = struct {
        resourceNames: ?[]const []const u8 = null,
        projectIds: ?[]const []const u8 = null,
        filter: ?[]const u8 = null,
        orderBy: ?[]const u8 = null,
        pageSize: ?i64 = null,
        pageToken: ?[]const u8 = null,
    };

    const Scope = struct {
        /// "projects/p".
        parent: []const u8,
        /// For a view: which bucket, and which view.
        view: ?struct { location: []const u8, bucket: []const u8, view: []const u8 } = null,
        /// `_Default`'s `_Default` view leaves data access audit logs out.
        exclude_data_access: bool = false,
    };

    fn list(f: *FakeLogging, arena: Allocator, body: []const u8) Allocator.Error!Reply {
        // Production refuses a field it does not know, by name.
        const value = std.json.parseFromSliceLeaky(std.json.Value, arena, body, .{}) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            else => return fail(arena, 400, "INVALID_ARGUMENT", "Invalid JSON payload received."),
        };
        if (value != .object) return fail(arena, 400, "INVALID_ARGUMENT", "Invalid JSON payload received.");
        var keys = value.object.iterator();
        while (keys.next()) |kv| {
            for (known_fields) |k| {
                if (std.mem.eql(u8, k, kv.key_ptr.*)) break;
            } else return fail(arena, 400, "INVALID_ARGUMENT", try std.fmt.allocPrint(arena, "Invalid JSON payload received. Unknown name \"{s}\": Cannot find field.", .{kv.key_ptr.*}));
        }
        const req = std.json.parseFromValueLeaky(WireList, arena, value, .{}) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            else => return fail(arena, 400, "INVALID_ARGUMENT", "Invalid JSON payload received."),
        };
        // Deprecated, and still served on 2026-10-16: "Projects listed in
        // the project_ids field are added to this list."
        var names_list: std.ArrayList([]const u8) = .empty;
        try names_list.appendSlice(arena, req.resourceNames orelse &.{});
        for (req.projectIds orelse &.{}) |id| try names_list.append(arena, try std.fmt.allocPrint(arena, "projects/{s}", .{id}));
        const resource_names = names_list.items;
        if (resource_names.len == 0) return fail(arena, 400, "INVALID_ARGUMENT", "At least one resource name is needed.");
        if (resource_names.len > 100) return failInfo(arena, 400, "INVALID_ARGUMENT", "Request exceeds maximum number of resource names.", "QUERY_TOO_MANY_RESOURCES", &.{
            .{ "max_resources", "100" },
            .{ "num_resources", try std.fmt.allocPrint(arena, "{d}", .{resource_names.len}) },
        });
        const scopes = try arena.alloc(Scope, resource_names.len);
        for (resource_names, scopes) |name, *scope| {
            if (std.mem.eql(u8, name, "projects")) return failInfo(arena, 400, "INVALID_ARGUMENT", "Name \"projects\" is missing the parent component. Expected the form projects/[PROJECT_ID]", "QUERY_INVALID_RESOURCE_NAME", &.{.{ "resource", "projects" }});
            scope.* = parseScope(name) orelse return notModelled(arena, "a resource name this fake cannot read");
            try f.ensureParent(scope.parent);
            if (try f.resolveView(arena, scope)) |refused| return refused;
        }
        // As production answered each on 2026-10-16: no order, "" and
        // "timestamp" are ascending, and the direction is lowercase.
        const order: types.Order = o: {
            const o = req.orderBy orelse break :o .oldest_first;
            if (o.len == 0 or std.mem.eql(u8, o, "timestamp") or std.mem.eql(u8, o, "timestamp asc")) break :o .oldest_first;
            if (std.mem.eql(u8, o, "timestamp desc")) break :o .newest_first;
            if (!std.mem.startsWith(u8, o, "timestamp")) return fail(arena, 400, "INVALID_ARGUMENT", "order_by must be on timestamp");
            return fail(arena, 400, "INVALID_ARGUMENT", "order_by must be \"asc\" or \"desc\"");
        };
        const page_size: usize = if (req.pageSize) |s| (if (s == 0) 50 else if (s < 0) return fail(arena, 400, "INVALID_ARGUMENT", "page_size must not be negative") else @intCast(s)) else 50;
        const filter_text = req.filter orelse "";
        const node = switch (try fake_filter.read(arena, filter_text)) {
            .ok => |n| n,
            .unparseable, .refused => |message| return fail(arena, 400, "INVALID_ARGUMENT", message),
            .not_modelled => |why| return notModelled(arena, why),
        };

        // Production took a token with another page size on 2026-10-16:
        // only the rest of the request binds it.
        const fingerprint = fingerprintOf(filter_text, order);
        const now_ns = f.now();
        var after: ?Key = null;
        if (req.pageToken) |token| {
            const t = decodeToken(arena, token) orelse return fail(arena, 400, "INVALID_ARGUMENT", "Invalid page_token");
            if (t.fingerprint != fingerprint) return fail(arena, 400, "INVALID_ARGUMENT", "page_token doesn't match arguments from the request");
            if (now_ns - t.issued > token_lifetime_ns) return notModelled(arena, "a page token past its 24 hours");
            after = t.after;
        }

        // What the request sees now, in its order, duplicates removed.
        var found: std.ArrayList(*const Stored) = .empty;
        for (f.entries.items) |e| {
            if (e.visible_at > now_ns) continue;
            if (!inAnyScope(e, scopes)) continue;
            if (node) |n| switch (fake_filter.matches(n, &subjectOf(e))) {
                .pass => |passed| if (!passed) continue,
                .not_modelled => |why| return notModelled(arena, why),
            };
            try found.append(arena, e);
        }
        std.mem.sort(*const Stored, found.items, order, lessInOrder);
        var seen: std.StringHashMapUnmanaged(void) = .empty;
        var unique: std.ArrayList(*const Stored) = .empty;
        for (found.items) |e| {
            const key = try std.fmt.allocPrint(arena, "{s}\x00{d}\x00{s}", .{ e.parent, e.timestamp, e.insert_id });
            const gop = try seen.getOrPut(arena, key);
            if (gop.found_existing) continue;
            try unique.append(arena, e);
        }

        var start: usize = 0;
        if (after) |key| {
            while (start < unique.items.len and !isPast(order, keyOf(unique.items[start]), key)) start += 1;
        }
        if (f.takeFault(searching) != null) {
            return ok(try renderPage(arena, &.{}, try encodeToken(arena, fingerprint, now_ns, after)));
        }
        var limit = page_size;
        if (f.takeFault(short)) |fault| limit = @min(limit, fault.max);
        const end = @min(unique.items.len, start + limit);
        const taken = unique.items[start..end];
        const token: ?[]const u8 = if (end < unique.items.len)
            try encodeToken(arena, fingerprint, now_ns, if (taken.len > 0) keyOf(taken[taken.len - 1]) else after)
        else
            null;
        return ok(try renderPage(arena, taken, token));
    }

    const token_lifetime_ns: i96 = 24 * 3600 * std.time.ns_per_s;

    fn parseScope(name: []const u8) ?Scope {
        var it = std.mem.splitScalar(u8, name, '/');
        const kind = it.next() orelse return null;
        const id = it.next() orelse return null;
        if (id.len == 0) return null;
        for ([_][]const u8{ "projects", "folders", "organizations", "billingAccounts" }) |k| {
            if (std.mem.eql(u8, k, kind)) break;
        } else return null;
        const parent = name[0 .. kind.len + 1 + id.len];
        const rest = it.rest();
        if (it.index == null) return .{ .parent = parent };
        var parts = std.mem.splitScalar(u8, rest, '/');
        const words = [_][]const u8{ "locations", "buckets", "views" };
        var got: [3][]const u8 = undefined;
        for (words, &got) |word, *slot| {
            const w = parts.next() orelse return null;
            if (!std.mem.eql(u8, w, word)) return null;
            slot.* = parts.next() orelse return null;
            if (slot.len == 0) return null;
        }
        if (parts.next() != null) return null;
        return .{ .parent = parent, .view = .{ .location = got[0], .bucket = got[1], .view = got[2] } };
    }

    /// Whether `e` is in one of `scopes`, each view checked by
    /// `resolveView` already.
    fn inAnyScope(e: *const Stored, scopes: []const Scope) bool {
        for (scopes) |s| {
            if (!std.mem.eql(u8, s.parent, e.parent)) continue;
            const v = s.view orelse return true;
            if (!std.mem.eql(u8, v.location, e.location) or !std.mem.eql(u8, v.bucket, e.bucket)) continue;
            if (s.exclude_data_access and (std.mem.eql(u8, e.log_id, "cloudaudit.googleapis.com/data_access") or std.mem.eql(u8, e.log_id, "externalaudit.googleapis.com/data_access"))) continue;
            return true;
        }
        return false;
    }

    fn subjectOf(e: *const Stored) fake_filter.Subject {
        return .{
            .timestamp = e.timestamp,
            .receive_timestamp = e.receive_timestamp,
            .severity = @backingInt(e.severity),
            .log_name = e.log_name,
            .log_id = e.log_id,
            .insert_id = e.insert_id,
            .trace = e.trace,
            .span_id = e.span_id,
            .text_payload = switch (e.payload) {
                .text => |t| t,
                else => null,
            },
            .resource_type = e.resource_type,
            .resource_labels = e.resource_labels,
            .labels = e.labels,
            .json = e.json,
        };
    }

    /// Where an entry stands in a listing: its timestamp, then its
    /// `insertId`, then its log name, so the order is total.
    const Key = struct { timestamp: i96, insert_id: []const u8, log_name: []const u8 };

    fn keyOf(e: *const Stored) Key {
        return .{ .timestamp = e.timestamp, .insert_id = e.insert_id, .log_name = e.log_name };
    }

    fn orderKeys(a: Key, b: Key) std.math.Order {
        if (a.timestamp != b.timestamp) return std.math.order(a.timestamp, b.timestamp);
        const by_id = std.mem.order(u8, a.insert_id, b.insert_id);
        if (by_id != .eq) return by_id;
        return std.mem.order(u8, a.log_name, b.log_name);
    }

    fn lessInOrder(order: types.Order, a: *const Stored, b: *const Stored) bool {
        const o = orderKeys(keyOf(a), keyOf(b));
        return if (order == .oldest_first) o == .lt else o == .gt;
    }

    /// Whether `key` comes after `after` in `order`.
    fn isPast(order: types.Order, key: Key, after: Key) bool {
        const o = orderKeys(key, after);
        return if (order == .oldest_first) o == .gt else o == .lt;
    }

    /// What binds a token, as production showed on 2026-10-16: the filter,
    /// to the byte (one more space was refused), and the order. Another
    /// page size, or other resource names, kept the token good.
    fn fingerprintOf(filter_text: []const u8, order: types.Order) u64 {
        var h: std.hash.Wyhash = .init(0x6c6f6773);
        h.update(filter_text);
        h.update(&.{@backingInt(order)});
        return h.final();
    }

    const WireToken = struct {
        v: u8,
        fingerprint: u64,
        issued: i128,
        after: ?struct { timestamp: i128, insert_id: []const u8, log_name: []const u8 } = null,
    };

    const Token = struct { fingerprint: u64, issued: i96, after: ?Key };

    fn encodeToken(arena: Allocator, fingerprint: u64, issued: i96, after: ?Key) Allocator.Error![]const u8 {
        const json = try Stringify.valueAlloc(arena, WireToken{
            .v = 1,
            .fingerprint = fingerprint,
            .issued = issued,
            .after = if (after) |k| .{ .timestamp = k.timestamp, .insert_id = k.insert_id, .log_name = k.log_name } else null,
        }, .{});
        const codec = std.base64.url_safe_no_pad;
        const out = try arena.alloc(u8, codec.Encoder.calcSize(json.len));
        return codec.Encoder.encode(out, json);
    }

    fn decodeToken(arena: Allocator, token: []const u8) ?Token {
        const codec = std.base64.url_safe_no_pad;
        const len = codec.Decoder.calcSizeForSlice(token) catch return null;
        const json = arena.alloc(u8, len) catch return null;
        codec.Decoder.decode(json, token) catch return null;
        const t = std.json.parseFromSliceLeaky(WireToken, arena, json, .{}) catch return null;
        if (t.v != 1) return null;
        return .{
            .fingerprint = t.fingerprint,
            .issued = std.math.cast(i96, t.issued) orelse return null,
            .after = if (t.after) |k| .{ .timestamp = std.math.cast(i96, k.timestamp) orelse return null, .insert_id = k.insert_id, .log_name = k.log_name } else null,
        };
    }

    fn renderPage(arena: Allocator, entries: []const *const Stored, token: ?[]const u8) Allocator.Error![]const u8 {
        var out: std.Io.Writer.Allocating = .init(arena);
        var jw: Stringify = .{ .writer = &out.writer };
        writePage(&jw, entries, token) catch return error.OutOfMemory;
        return out.toOwnedSlice();
    }

    fn writePage(jw: *Stringify, entries: []const *const Stored, token: ?[]const u8) Stringify.Error!void {
        try jw.beginObject();
        if (entries.len > 0) {
            try jw.objectField("entries");
            try jw.beginArray();
            for (entries) |e| try writeEntry(jw, e);
            try jw.endArray();
        }
        if (token) |t| {
            try jw.objectField("nextPageToken");
            try jw.write(t);
        }
        try jw.endObject();
    }

    /// An entry in the order production's recorded answers put fields.
    fn writeEntry(jw: *Stringify, e: *const Stored) Stringify.Error!void {
        try jw.beginObject();
        try jw.objectField("insertId");
        try jw.write(e.insert_id);
        switch (e.payload) {
            .none => {},
            .text => |t| {
                try jw.objectField("textPayload");
                try jw.write(t);
            },
            .json => |bytes| {
                try jw.objectField("jsonPayload");
                try jw.beginWriteRaw();
                try jw.writer.writeAll(bytes);
                jw.endWriteRaw();
            },
        }
        try jw.objectField("resource");
        try jw.beginObject();
        try jw.objectField("type");
        try jw.write(e.resource_type);
        if (e.resource_labels.len > 0) try writeLabels(jw, e.resource_labels);
        try jw.endObject();
        try writeTime(jw, "timestamp", e.timestamp);
        // proto3 JSON leaves the default out.
        if (e.severity != .default) {
            try jw.objectField("severity");
            if (e.severity.name()) |n| try jw.write(n) else try jw.write(@backingInt(e.severity));
        }
        if (e.labels.len > 0) try writeLabels(jw, e.labels);
        try jw.objectField("logName");
        try jw.write(e.log_name);
        if (e.trace.len > 0) {
            try jw.objectField("trace");
            try jw.write(e.trace);
        }
        if (e.span_id.len > 0) {
            try jw.objectField("spanId");
            try jw.write(e.span_id);
        }
        try writeTime(jw, "receiveTimestamp", e.receive_timestamp);
        try jw.endObject();
    }

    fn writeLabels(jw: *Stringify, labels: []const types.Label) Stringify.Error!void {
        try jw.objectField("labels");
        try jw.beginObject();
        for (labels) |l| {
            try jw.objectField(l.key);
            try jw.write(l.value);
        }
        try jw.endObject();
    }

    fn writeTime(jw: *Stringify, name: []const u8, ns: i96) Stringify.Error!void {
        var buf: [core.timestamp.max_len]u8 = undefined;
        try jw.objectField(name);
        try jw.write(core.timestamp.format(&buf, .{ .nanoseconds = ns }));
    }
};

fn ok(body: []const u8) FakeLogging.Reply {
    return .{ .status = 200, .body = body };
}

fn fail(arena: Allocator, code: u16, status: []const u8, message: []const u8) Allocator.Error!FakeLogging.Reply {
    return .{ .status = code, .body = try Stringify.valueAlloc(arena, .{ .@"error" = .{
        .code = code,
        .message = message,
        .status = status,
    } }, .{}) };
}

/// `fail`, with one `google.rpc.ErrorInfo` in `details`, as production sends
/// for the refusals of a request's resource names.
fn failInfo(arena: Allocator, code: u16, status: []const u8, message: []const u8, reason: []const u8, metadata: []const [2][]const u8) Allocator.Error!FakeLogging.Reply {
    return failInfoDomain(arena, code, status, message, reason, "logging.googleapis.com", metadata);
}

fn failInfoDomain(arena: Allocator, code: u16, status: []const u8, message: []const u8, reason: []const u8, domain: []const u8, metadata: []const [2][]const u8) Allocator.Error!FakeLogging.Reply {
    var out: std.Io.Writer.Allocating = .init(arena);
    var jw: Stringify = .{ .writer = &out.writer };
    writeFailInfo(&jw, code, status, message, reason, domain, metadata) catch return error.OutOfMemory;
    return .{ .status = code, .body = try out.toOwnedSlice() };
}

fn writeFailInfo(jw: *Stringify, code: u16, status: []const u8, message: []const u8, reason: []const u8, domain: []const u8, metadata: []const [2][]const u8) Stringify.Error!void {
    try jw.beginObject();
    try jw.objectField("error");
    try jw.beginObject();
    try jw.objectField("code");
    try jw.write(code);
    try jw.objectField("message");
    try jw.write(message);
    try jw.objectField("status");
    try jw.write(status);
    try jw.objectField("details");
    try jw.beginArray();
    try jw.beginObject();
    try jw.objectField("@type");
    try jw.write("type.googleapis.com/google.rpc.ErrorInfo");
    try jw.objectField("reason");
    try jw.write(reason);
    try jw.objectField("domain");
    try jw.write(domain);
    try jw.objectField("metadata");
    try jw.beginObject();
    for (metadata) |kv| {
        try jw.objectField(kv[0]);
        try jw.write(kv[1]);
    }
    try jw.endObject();
    try jw.endObject();
    try jw.endArray();
    try jw.endObject();
    try jw.endObject();
}

/// A refusal with production's words for its status, where they are known.
/// A 429 carries production's `ErrorInfo`, its window ending 5 s after
/// `now_s`, as production's 429 of 2026-10-16 did.
fn refusal(arena: Allocator, status: u16, now_s: i64) Allocator.Error!FakeLogging.Reply {
    return switch (status) {
        429 => failInfoDomain(arena, 429, "RESOURCE_EXHAUSTED", "Quota exceeded for quota metric 'Read requests' and limit 'Read requests per minute' of service 'logging.googleapis.com' for consumer 'project_number:82150720798'.", "RATE_LIMIT_EXCEEDED", "googleapis.com", &.{
            .{ "quota_location", "global" },
            .{ "consumer", "projects/82150720798" },
            .{ "service", "logging.googleapis.com" },
            .{ "quota_unit", "1/min/{project}" },
            .{ "quota_metric", "logging.googleapis.com/read_requests" },
            .{ "quota_limit", "ReadRequestsPerMinutePerProject" },
            .{ "window_start_time", try std.fmt.allocPrint(arena, "{d}", .{now_s - 55}) },
            .{ "quota_limit_value", "60" },
        }),
        403 => fail(arena, 403, "PERMISSION_DENIED", "The caller does not have permission"),
        500 => fail(arena, 500, "INTERNAL", "Internal error encountered."),
        503 => fail(arena, 503, "UNAVAILABLE", "The service is currently unavailable."),
        504 => fail(arena, 504, "DEADLINE_EXCEEDED", "The request timed out."),
        else => fail(arena, status, "UNKNOWN", "fake: refused"),
    };
}

/// What this fake has no answer for: said, never guessed at.
fn notModelled(arena: Allocator, what: []const u8) Allocator.Error!FakeLogging.Reply {
    return fail(arena, 501, "UNIMPLEMENTED", try std.fmt.allocPrint(arena, "fake: {s} is not modelled yet", .{what}));
}

const testing = std.testing;
const test_util = @import("test_util.zig");
const Client = @import("Client.zig");

const base_s: i96 = 1_792_141_200;

fn at(s: i96) std.Io.Timestamp {
    return .{ .nanoseconds = (base_s + s) * std.time.ns_per_s };
}

/// A client on the fake, and the fake on a clock a test moves.
const Rig = struct {
    clock: test_util.FakeClock,
    fake: FakeLogging,
    token: test_util.FakeTokenProvider,
    diag: core.Diagnostics,
    client: Client,

    fn init(r: *Rig) !void {
        return r.initWith(testing.allocator);
    }

    fn initWith(r: *Rig, gpa: Allocator) !void {
        r.* = .{ .clock = .{ .now_ns = base_s * std.time.ns_per_s }, .fake = undefined, .token = .{}, .diag = .{}, .client = undefined };
        r.fake = .init(gpa, r.clock.io());
        errdefer r.fake.deinit();
        r.client = try .init(gpa, r.clock.io(), .{
            .project_id = "p",
            .token_provider = r.token.provider(),
            .transport = r.fake.transport(),
            .diagnostics = &r.diag,
            .read_calls_per_minute = 0,
        });
    }

    fn deinit(r: *Rig) void {
        r.client.deinit();
        r.fake.deinit();
    }

    fn writeAt(r: *Rig, log_id: []const u8, s: i96, insert_id: []const u8) !void {
        try r.fake.write(.{ .log_name = try r.fake.logName(.{ .project = "p" }, log_id), .timestamp = at(s), .insert_id = insert_id });
    }

    /// The insert ids of every page of `options`, joined by spaces, with
    /// `|` between pages.
    fn listAll(r: *Rig, arena: Allocator, options: types.QueryOptions) ![]const u8 {
        var q = try r.client.query(options);
        defer q.deinit();
        var out: std.ArrayList(u8) = .empty;
        var token: ?[]const u8 = null;
        var pages: usize = 0;
        while (true) : (pages += 1) {
            var page = try q.page(token);
            defer page.deinit();
            if (pages > 0) try out.append(arena, '|');
            for (page.value.entries, 0..) |e, i| {
                if (i > 0) try out.append(arena, ' ');
                try out.appendSlice(arena, e.insert_id);
            }
            token = if (page.value.next_page_token) |t| try arena.dupe(u8, t) else break;
        }
        return out.items;
    }
};

test "fake: entries come in either order, ties by insertId, paged, through the real client" {
    var r: Rig = undefined;
    try r.init();
    defer r.deinit();
    try r.writeAt("a", 3, "c");
    try r.writeAt("a", 1, "a");
    try r.writeAt("b/x", 2, "b2");
    try r.writeAt("a", 2, "b1");
    try r.writeAt("a", 5, "e");
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try testing.expectEqualStrings("e c b2 b1 a", try r.listAll(a, .{}));
    try testing.expectEqualStrings("a b1 b2 c e", try r.listAll(a, .{ .order = .oldest_first }));
    try testing.expectEqualStrings("e c|b2 b1|a", try r.listAll(a, .{ .page_size = 2 }));
    // Five fit a page of five: no token, no empty last page.
    try testing.expectEqualStrings("e c b2 b1 a", try r.listAll(a, .{ .page_size = 5 }));
    try testing.expectEqualStrings("b2", try r.listAll(a, .{ .log_id = "b/x" }));
    try testing.expectEqualStrings("c b2 b1", try r.listAll(a, .{ .since = at(2), .until = at(4) }));
    try testing.expectEqualStrings("", try r.listAll(a, .{ .scopes = &.{.{ .parent = .{ .project = "q" } }} }));
}

test "fake: a token is bound to its filter and order, and resumes past entries that arrive behind it" {
    var r: Rig = undefined;
    try r.init();
    defer r.deinit();
    for (0..4) |i| try r.writeAt("a", @intCast(i), &.{@as(u8, 'a') + @as(u8, @intCast(i))});
    var q = try r.client.query(.{ .page_size = 2, .order = .oldest_first });
    defer q.deinit();
    var first = try q.page(null);
    defer first.deinit();
    try testing.expectEqualStrings("b", first.value.entries[1].insert_id);
    // An entry behind the token, and one ahead of it.
    try r.writeAt("a", 0, "a0");
    try r.writeAt("a", 9, "z");
    var second = try q.page(first.value.next_page_token);
    defer second.deinit();
    try testing.expectEqualStrings("c", second.value.entries[0].insert_id);
    try testing.expectEqualStrings("d", second.value.entries[1].insert_id);

    // Another page size, or other scopes, keep the token good.
    var larger = try r.client.query(.{ .page_size = 3, .order = .oldest_first, .scopes = &.{ .{ .parent = .{ .project = "p" } }, .{ .parent = .{ .project = "q" } } } });
    defer larger.deinit();
    var resumed = try larger.page(first.value.next_page_token);
    defer resumed.deinit();
    try testing.expectEqualStrings("c", resumed.value.entries[0].insert_id);
    // Another filter, or another order, do not.
    for ([_]types.QueryOptions{
        .{ .page_size = 2, .order = .oldest_first, .filter = "severity >= DEFAULT" },
        .{ .page_size = 2, .order = .newest_first },
    }) |options| {
        var other = try r.client.query(options);
        defer other.deinit();
        try testing.expectError(error.InvalidPageToken, other.page(first.value.next_page_token));
        try testing.expect(std.mem.indexOf(u8, r.diag.message(), "page_token doesn't match") != null);
    }
    // A token it did not issue, in production's words.
    try testing.expectError(error.InvalidPageToken, q.page("bm90LWEtdG9rZW4"));
    try testing.expectEqualStrings("Invalid page_token", r.diag.message());
    // After 24 hours, the fake will not say what production does.
    r.clock.now_ns += 24 * 3600 * std.time.ns_per_s + 1;
    try testing.expectError(error.Unimplemented, q.page(first.value.next_page_token));
}

test "fake: late entries are not seen until they arrive; duplicates in one result are one" {
    var r: Rig = undefined;
    try r.init();
    defer r.deinit();
    const name = try r.fake.logName(.{ .project = "p" }, "a");
    try r.fake.write(.{ .log_name = name, .timestamp = at(-10), .insert_id = "late", .visible_at = at(30) });
    try r.fake.write(.{ .log_name = name, .timestamp = at(-5), .insert_id = "dup" });
    // The same parent, timestamp and insertId in another log: a duplicate.
    try r.fake.write(.{ .log_name = try r.fake.logName(.{ .project = "p" }, "b"), .timestamp = at(-5), .insert_id = "dup" });
    // Another project's, at the same moment, is its own.
    try r.fake.write(.{ .log_name = try r.fake.logName(.{ .project = "q" }, "b"), .timestamp = at(-5), .insert_id = "dup" });
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const both: []const types.Scope = &.{ .{ .parent = .{ .project = "p" } }, .{ .parent = .{ .project = "q" } } };
    try testing.expectEqualStrings("dup dup", try r.listAll(a, .{ .scopes = both }));
    r.clock.now_ns = at(30).nanoseconds;
    try testing.expectEqualStrings("dup dup late", try r.listAll(a, .{ .scopes = both }));
}

test "fake: the server running out of time, and short pages" {
    var r: Rig = undefined;
    try r.init();
    defer r.deinit();
    for (0..5) |i| try r.writeAt("a", @intCast(i), &.{@as(u8, 'a') + @as(u8, @intCast(i))});
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    r.fake.searchingNext(2);
    // Two empty pages with tokens, then the listing from where it was.
    try testing.expectEqualStrings("||e d c b a", try r.listAll(a, .{}));
    r.fake.shortenNext(1, 1);
    try testing.expectEqualStrings("e|d c b a", try r.listAll(a, .{}));
    // Searching mid-listing goes on from the same place.
    var q = try r.client.query(.{ .page_size = 2 });
    defer q.deinit();
    var p1 = try q.page(null);
    defer p1.deinit();
    r.fake.searchingNext(1);
    var p2 = try q.page(p1.value.next_page_token);
    defer p2.deinit();
    try testing.expectEqual(0, p2.value.entries.len);
    var p3 = try q.page(p2.value.next_page_token);
    defer p3.deinit();
    try testing.expectEqualStrings("c", p3.value.entries[0].insert_id);
}

test "fake: views, other parents, and every entry field read back through the client" {
    var r: Rig = undefined;
    try r.init();
    defer r.deinit();
    try r.fake.write(.{
        .log_name = try r.fake.logName(.{ .folder = "12" }, "run.googleapis.com/stderr"),
        .timestamp = at(1),
        .receive_timestamp = at(2),
        .severity = .@"error",
        .insert_id = "full",
        .resource_type = "cloud_run_revision",
        .resource_labels = &.{.{ .key = "service_name", .value = "api" }},
        .labels = &.{.{ .key = "env", .value = "prod" }},
        .payload = .{ .json = "{\"message\":\"payment failed\",\"big\":12345678901234567890}" },
        .trace = "projects/p/traces/t",
        .span_id = "00f067aa0ba902b7",
        .bucket = "audit",
        .location = "europe-west1",
    });
    try r.fake.write(.{ .log_name = try r.fake.logName(.{ .folder = "12" }, "x"), .timestamp = at(3), .insert_id = "default-bucket", .payload = .{ .text = "hi" } });
    // The first was received at 2 s: listings see it from then.
    r.clock.now_ns = at(10).nanoseconds;
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const folder: types.Parent = .{ .folder = "12" };
    try r.fake.addBucket(.{ .parent = folder, .location = "europe-west1", .id = "audit" });
    try testing.expectEqualStrings("default-bucket full", try r.listAll(a, .{ .scopes = &.{.{ .parent = folder }} }));
    try testing.expectEqualStrings("full", try r.listAll(a, .{ .scopes = &.{.{ .view = .{ .parent = folder, .location = "europe-west1", .bucket = "audit", .view = "_AllLogs" } }} }));
    try testing.expectEqualStrings("default-bucket", try r.listAll(a, .{ .scopes = &.{.{ .view = .{ .parent = folder, .location = "global", .bucket = "_Default", .view = "_Default" } }} }));
    // A view the bucket does not have, in production's words.
    try testing.expectError(error.NotFound, r.listAll(a, .{ .scopes = &.{.{ .view = .{ .parent = folder, .location = "europe-west1", .bucket = "audit", .view = "_Default" } }} }));
    try testing.expectEqualStrings("folders/12/locations/europe-west1/buckets/audit/views/_Default does not exist", r.diag.message());

    var q = try r.client.query(.{ .scopes = &.{.{ .parent = folder }}, .min_severity = .warning });
    defer q.deinit();
    var page = try q.page(null);
    defer page.deinit();
    const e = page.value.entries[0];
    try testing.expectEqualStrings("folders/12/logs/run.googleapis.com%2Fstderr", e.log_name);
    try testing.expectEqualStrings("run.googleapis.com/stderr", e.log_id);
    try testing.expectEqual(at(1).nanoseconds, e.timestamp.nanoseconds);
    try testing.expectEqual(at(2).nanoseconds, e.receive_timestamp.?.nanoseconds);
    try testing.expectEqual(.@"error", e.severity);
    try testing.expectEqualStrings("cloud_run_revision", e.resource_type);
    try testing.expectEqualStrings("api", e.resource_labels[0].value);
    try testing.expectEqualStrings("prod", e.labels[0].value);
    try testing.expectEqualStrings("{\"message\":\"payment failed\",\"big\":12345678901234567890}", e.payload.json);
    try testing.expectEqualStrings("projects/p/traces/t", e.trace);
    try testing.expectEqualStrings("00f067aa0ba902b7", e.span_id);
}

test "fake: filters it reads, refuses and does not model" {
    var r: Rig = undefined;
    try r.init();
    defer r.deinit();
    const name = try r.fake.logName(.{ .project = "p" }, "a");
    try r.fake.write(.{ .log_name = name, .timestamp = at(1), .insert_id = "warn", .severity = .warning, .payload = .{ .text = "disk nearly full" } });
    try r.fake.write(.{ .log_name = name, .timestamp = at(2), .insert_id = "err", .severity = .@"error", .payload = .{ .json = "{\"code\":7}" } });
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try testing.expectEqualStrings("warn", try r.listAll(a, .{ .filter = "textPayload:\"nearly\"" }));
    try testing.expectEqualStrings("err", try r.listAll(a, .{ .filter = "jsonPayload.code = 7 OR textPayload: nope" }));
    try testing.expectEqualStrings("err warn", try r.listAll(a, .{ .filter = "severity >= WARNING -- both" }));
    try testing.expectError(error.InvalidFilter, r.listAll(a, .{ .filter = "severity >=" }));
    try testing.expect(std.mem.indexOf(u8, r.diag.message(), "Unparseable filter: syntax error at line 3, column 1, token ')'") != null);
    try testing.expectError(error.Unimplemented, r.listAll(a, .{ .filter = "textPayload =~ \"disk\"" }));
    try testing.expect(std.mem.indexOf(u8, r.diag.message(), "a regular expression") != null);
    // As production answered: != on a field an entry lacks is false.
    try testing.expectEqualStrings("", try r.listAll(a, .{ .filter = "labels.env != prod" }));
    try testing.expectError(error.InvalidFilter, r.listAll(a, .{ .filter = "thud = 1" }));
    try testing.expect(std.mem.indexOf(u8, r.diag.message(), "Field not found: 'thud'.") != null);
}

test "fake: refusals, a 429 in the quota's words, dropped connections" {
    var r: Rig = undefined;
    try r.init();
    defer r.deinit();
    try r.writeAt("a", 1, "a");
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    r.fake.refuseNext(1, 429);
    try testing.expectError(error.ResourceExhausted, r.listAll(a, .{}));
    try testing.expect(std.mem.indexOf(u8, r.diag.message(), "Read requests per minute") != null);
    try testing.expectEqual(1, r.fake.listCalls());
    // A drop and a 503 are retried by the client, and the third try lands.
    r.fake.dropNext(1);
    r.fake.refuseNext(1, 503);
    try testing.expectEqualStrings("a", try r.listAll(a, .{}));
    try testing.expectEqual(4, r.fake.listCalls());
    r.fake.refuseNext(1, 403);
    try testing.expectError(error.PermissionDenied, r.listAll(a, .{}));
}

test "fake: requests no client sends" {
    var r: Rig = undefined;
    try r.init();
    defer r.deinit();
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const url = "https://logging.googleapis.com/v2/entries:list";
    const cases = [_]struct { []const u8, u16, []const u8 }{
        .{ "{\"resourceNames\":[\"projects/p\"],\"limit\":3}", 400, "Unknown name \\\"limit\\\": Cannot find field." },
        .{ "[]", 400, "Invalid JSON payload received." },
        .{ "{", 400, "Invalid JSON payload received." },
        .{ "{\"resourceNames\":\"projects/p\"}", 400, "Invalid JSON payload received." },
        .{ "{}", 400, "At least one resource name is needed." },
        .{ "{\"resourceNames\":[\"projects\"]}", 400, "Name \\\"projects\\\" is missing the parent component. Expected the form projects/[PROJECT_ID]" },
        .{ "{\"resourceNames\":[\"folders\"]}", 501, "resource name" },
        .{ "{\"resourceNames\":[\"projects/p/locations/global\"]}", 501, "resource name" },
        .{ "{\"resourceNames\":[\"projects/p/locations/global/buckets/b/views/v/x\"]}", 501, "resource name" },
        .{ "{\"resourceNames\":[\"projects/p\"],\"orderBy\":\"timestamp DESC\"}", 400, "order_by must be \\\"asc\\\" or \\\"desc\\\"" },
        .{ "{\"resourceNames\":[\"projects/p\"],\"orderBy\":\"insertId\"}", 400, "order_by must be on timestamp" },
        .{ "{\"resourceNames\":[\"projects/p\"],\"pageToken\":\"bm90LWEtdG9rZW4\"}", 400, "Invalid page_token" },

        .{ "{\"resourceNames\":[\"projects/p\"],\"pageSize\":-1}", 400, "page_size must not be negative" },
    };
    for (cases) |case| {
        const reply = try r.fake.serve(.POST, url, case[0], a);
        try testing.expectEqual(case[1], reply.status);
        if (std.mem.indexOf(u8, reply.body, case[2]) == null) {
            std.debug.print("{s}: {s}\n", .{ case[0], reply.body });
            return error.TestExpectedEqual;
        }
    }
    // Absent order and page size are the API's defaults.
    const defaults = try r.fake.serve(.POST, url, "{\"resourceNames\":[\"projects/p\"]}", a);
    try testing.expectEqual(200, defaults.status);
    try testing.expectEqualStrings("{}", defaults.body);
    // A plain "timestamp" is ascending, as production read it.
    try r.fake.write(.{ .log_name = "projects/p/logs/a", .timestamp = at(2), .insert_id = "late" });
    try r.fake.write(.{ .log_name = "projects/p/logs/a", .timestamp = at(1), .insert_id = "early" });
    const plain_order = try r.fake.serve(.POST, url, "{\"resourceNames\":[\"projects/p\"],\"orderBy\":\"timestamp\"}", a);
    try testing.expectEqual(200, plain_order.status);
    try testing.expect(std.mem.indexOf(u8, plain_order.body, "early").? < std.mem.indexOf(u8, plain_order.body, "late").?);
    const other = try r.fake.serve(.GET, "https://logging.googleapis.com/v2/projects/p/sinks", "", a);
    try testing.expectEqual(501, other.status);
    try testing.expectError(error.InvalidEntry, r.fake.write(.{ .log_name = "projects/p", .timestamp = at(0) }));
    try testing.expectError(error.InvalidEntry, r.fake.write(.{ .log_name = "projects/p/logs/a", .timestamp = at(0), .payload = .{ .json = "[1]" } }));
    try testing.expectError(error.InvalidEntry, r.fake.write(.{ .log_name = "/logs/a", .timestamp = at(0) }));
}

test "fake: insert ids are assigned when a test gives none, and every page is valid JSON" {
    var r: Rig = undefined;
    try r.init();
    defer r.deinit();
    const name = try r.fake.logName(.{ .project = "p" }, "a");
    try r.fake.write(.{ .log_name = name, .timestamp = at(1), .payload = .{ .text = "q\"uote" } });
    try r.fake.write(.{ .log_name = name, .timestamp = at(1), .severity = @fromBackingInt(@intCast(450)) });
    var q = try r.client.query(.{ .order = .oldest_first });
    defer q.deinit();
    var page = try q.page(null);
    defer page.deinit();
    try testing.expectEqualStrings("0000000000000001", page.value.entries[0].insert_id);
    try testing.expectEqualStrings("0000000000000002", page.value.entries[1].insert_id);
    try testing.expectEqualStrings("q\"uote", page.value.entries[0].payload.text);
    try testing.expectEqual(@as(types.Severity, @fromBackingInt(@intCast(450))), page.value.entries[1].severity);
}

fn roundTripProperty(_: void, input: []const u8) !void {
    var g: test_util.ByteGen = .init(input);
    var r: Rig = undefined;
    try r.initWith(test_util.propertyAllocator());
    defer r.deinit();
    var arena: std.heap.ArenaAllocator = .init(test_util.propertyAllocator());
    defer arena.deinit();
    const a = arena.allocator();

    const severities = [_]types.Severity{ .default, .info, .warning, .@"error", .emergency, @fromBackingInt(@intCast(450)), @fromBackingInt(@intCast(1)) };
    const log_ids = [_][]const u8{ "a", "run.googleapis.com/stderr", "b/c/d" };
    const jsons = [_][]const u8{ "{}", "{\"m\":\"x\",\"n\":12345678901234567890}", "{\"a\":{\"b\":[1,2.5e3,null,true]}}" };
    const n = g.intRange(u8, 0, 12);
    const written = try a.alloc(FakeLogging.Entry, n);
    for (written, 0..) |*e, i| {
        const text_buf = try a.alloc(u8, 32);
        const label_buf = try a.alloc(u8, 16);
        e.* = .{
            .log_name = try r.fake.logName(.{ .project = "p" }, g.pick([]const u8, &log_ids)),
            .timestamp = .{ .nanoseconds = at(g.intRange(u8, 0, 5)).nanoseconds + g.intRange(u32, 0, 999_999_999) },
            .severity = g.pick(types.Severity, &severities),
            .insert_id = try std.fmt.allocPrint(a, "id{d:0>2}", .{i}),
            .resource_type = g.pick([]const u8, &.{ "global", "cloud_run_revision" }),
            .labels = if (g.boolean()) &.{} else try a.dupe(types.Label, &.{ .{ .key = "a", .value = g.utf8(label_buf, 16) }, .{ .key = "b.c/d", .value = "\"q\"" } }),
            .payload = switch (g.intRange(u8, 0, 2)) {
                0 => .none,
                1 => .{ .text = g.utf8(text_buf, 32) },
                else => .{ .json = g.pick([]const u8, &jsons) },
            },
            .trace = g.pick([]const u8, &.{ "", "projects/p/traces/t" }),
            .span_id = g.pick([]const u8, &.{ "", "000000000000004a" }),
        };
        try r.fake.write(e.*);
    }
    // The fake lists oldest first by timestamp, then insertId.
    std.mem.sort(FakeLogging.Entry, written, {}, struct {
        fn less(_: void, x: FakeLogging.Entry, y: FakeLogging.Entry) bool {
            if (x.timestamp.nanoseconds != y.timestamp.nanoseconds) return x.timestamp.nanoseconds < y.timestamp.nanoseconds;
            return std.mem.order(u8, x.insert_id.?, y.insert_id.?) == .lt;
        }
    }.less);

    var q = try r.client.query(.{ .order = .oldest_first, .page_size = g.intRange(u8, 1, 5) });
    defer q.deinit();
    var token: ?[]const u8 = null;
    var seen: usize = 0;
    while (true) {
        var page = try q.page(token);
        defer page.deinit();
        for (page.value.entries) |got| {
            const want = written[seen];
            seen += 1;
            try testing.expectEqualStrings(want.insert_id.?, got.insert_id);
            try testing.expectEqualStrings(want.log_name, got.log_name);
            try testing.expectEqual(want.timestamp.nanoseconds, got.timestamp.nanoseconds);
            try testing.expectEqual(want.severity, got.severity);
            try testing.expectEqualStrings(want.resource_type, got.resource_type);
            try testing.expectEqual(want.labels.len, got.labels.len);
            for (want.labels, got.labels) |wl, gl| {
                try testing.expectEqualStrings(wl.key, gl.key);
                try testing.expectEqualStrings(wl.value, gl.value);
            }
            try testing.expectEqualStrings(want.trace, got.trace);
            try testing.expectEqualStrings(want.span_id, got.span_id);
            switch (want.payload) {
                .none => try testing.expect(got.payload == .none),
                .text => |t| try testing.expectEqualStrings(t, got.payload.text),
                .json => |j| try testing.expectEqualStrings(j, got.payload.json),
            }
        }
        token = if (page.value.next_page_token) |t| try a.dupe(u8, t) else break;
    }
    try testing.expectEqual(written.len, seen);
}

test "fuzz fake round trip: what a test writes, the client reads back through every page" {
    try test_util.fuzzBytes({}, roundTripProperty, .{ .corpus = &.{ "", "\x0c\xff\x00\x01\x02\x03\x04\x05\x06\x07\x08\x09", "\x05\x01\x01\x01\x01" } });
}

test "fake: every refusal status, and a payload that is no JSON" {
    var r: Rig = undefined;
    try r.init();
    defer r.deinit();
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const url = "https://logging.googleapis.com/v2/entries:list";
    const body = "{\"resourceNames\":[\"projects/p\"]}";
    for ([_]struct { u16, []const u8 }{ .{ 500, "INTERNAL" }, .{ 504, "DEADLINE_EXCEEDED" }, .{ 418, "UNKNOWN" } }) |case| {
        r.fake.refuseNext(1, case[0]);
        const reply = try r.fake.serve(.POST, url, body, a);
        try testing.expectEqual(case[0], reply.status);
        try testing.expect(std.mem.indexOf(u8, reply.body, case[1]) != null);
    }
    try testing.expectError(error.InvalidEntry, r.fake.write(.{ .log_name = "projects/p/logs/a", .timestamp = at(0), .payload = .{ .json = "{" } }));
}

test "fake: every allocation failure in a listing is OutOfMemory without leaks" {
    try testing.checkAllAllocationFailures(testing.allocator, struct {
        fn run(gpa: Allocator) !void {
            var clock: test_util.FakeClock = .{ .now_ns = base_s * std.time.ns_per_s };
            var fake: FakeLogging = .init(testing.allocator, clock.io());
            defer fake.deinit();
            const name = try fake.logName(.{ .project = "p" }, "a/b");
            try fake.write(.{ .log_name = name, .timestamp = at(1), .insert_id = "x", .payload = .{ .json = "{\"k\":1}" } });
            try fake.write(.{ .log_name = name, .timestamp = at(2), .insert_id = "y" });
            var arena: std.heap.ArenaAllocator = .init(gpa);
            defer arena.deinit();
            const reply = try fake.serve(.POST, "https://logging.googleapis.com/v2/entries:list", "{\"resourceNames\":[\"projects/p\"],\"filter\":\"jsonPayload.k = 1 OR insertId = y\",\"pageSize\":1}", arena.allocator());
            if (reply.status != 200) return error.TestUnexpectedStatus;
        }
    }.run, .{});
}

test "fake: a 429 names a window ending 5 s later, global resources get project_id, large pages are served" {
    var clock: test_util.FakeClock = .{ .now_ns = base_s * std.time.ns_per_s };
    var fake: FakeLogging = .init(testing.allocator, clock.io());
    defer fake.deinit();
    var token: test_util.FakeTokenProvider = .{};
    var client: Client = try .init(testing.allocator, clock.io(), .{ .project_id = "p", .token_provider = token.provider(), .transport = fake.transport() });
    defer client.deinit();
    fake.refuseNext(1, 429);
    var q = try client.query(.{ .page_size = 2000, .order = .oldest_first });
    defer q.deinit();
    try testing.expectError(error.ResourceExhausted, q.page(null));
    try testing.expectEqual(5_000, client.readBudget().next_free_ms);
    clock.now_ns += 5 * std.time.ns_per_s;
    const name = try fake.logName(.{ .project = "p" }, "a");
    for (0..1200) |i| try fake.write(.{ .log_name = name, .timestamp = at(@intCast(i)) });
    try fake.write(.{ .log_name = name, .timestamp = at(9000), .resource_type = "gce_instance" });
    var page = try q.page(null);
    defer page.deinit();
    try testing.expectEqual(1201, page.value.entries.len);
    try testing.expectEqual(null, page.value.next_page_token);
    try testing.expectEqualStrings("project_id", page.value.entries[0].resource_labels[0].key);
    try testing.expectEqualStrings("p", page.value.entries[0].resource_labels[0].value);
    try testing.expectEqual(0, page.value.entries[1200].resource_labels.len);
}

test "fake: a filter it can read but not try on an entry is not modelled" {
    var r: Rig = undefined;
    try r.init();
    defer r.deinit();
    try r.fake.write(.{ .log_name = "projects/p/logs/a", .timestamp = at(1), .payload = .{ .json = "{\"list\":[1]}" } });
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    try testing.expectError(error.Unimplemented, r.listAll(arena.allocator(), .{ .filter = "jsonPayload.list = 1" }));
    try testing.expect(std.mem.indexOf(u8, r.diag.message(), "JSON array or object") != null);
}

test "fake: buckets and views, made, listed, changed and refused through the client" {
    var r: Rig = undefined;
    try r.init();
    defer r.deinit();
    const p: types.Parent = .{ .project = "p" };
    try r.fake.addBucket(.{ .parent = p, .location = "europe-west1", .id = "audit", .description = "for auditors", .retention_days = 90, .restricted_fields = &.{"jsonPayload.ssn"} });
    try r.fake.addBucket(.{ .parent = p, .location = "us", .id = "app", .analytics_enabled = true });
    const audit: types.BucketName = .{ .parent = p, .location = "europe-west1", .bucket = "audit" };
    try r.fake.addView(audit, "only-errors", "");
    try testing.expectError(error.InvalidEntry, r.fake.addView(audit, "only-errors", ""));
    try testing.expectError(error.InvalidEntry, r.fake.addBucket(.{ .parent = p, .location = "us", .id = "app" }));
    try testing.expectError(error.InvalidEntry, r.fake.addView(.{ .parent = p, .location = "us", .bucket = "none" }, "v", ""));
    try r.fake.setBucketState(.{ .parent = p, .location = "us", .bucket = "app" }, .delete_requested);
    // _AllLogs can be deleted.
    try r.fake.removeView(.{ .parent = p, .location = "us", .bucket = "app", .view = "_AllLogs" });
    try testing.expectError(error.InvalidEntry, r.fake.removeView(.{ .parent = p, .location = "us", .bucket = "app", .view = "_AllLogs" }));

    var all = try r.client.listBuckets(.{});
    defer all.deinit();
    try testing.expectEqual(4, all.value.buckets.len);
    var eu = try r.client.listBuckets(.{ .location = "europe-west1" });
    defer eu.deinit();
    try testing.expectEqual(1, eu.value.buckets.len);
    const b = eu.value.buckets[0];
    try testing.expectEqualStrings("for auditors", b.description);
    try testing.expectEqual(90, b.retention_days);
    try testing.expectEqualStrings("jsonPayload.ssn", b.restricted_fields[0]);
    try testing.expect(b.create_time != null);

    var picker = try r.client.picker(p);
    defer picker.deinit();
    const got = picker.value.buckets;
    try testing.expectEqualStrings("_Default", got[0].info.name.bucket);
    try testing.expectEqual(2, got[0].views.len);
    try testing.expectEqualStrings("_Default", got[0].views[0].name.view);
    try testing.expectEqualStrings("_AllLogs", got[0].views[1].name.view);
    try testing.expectEqualStrings("_Required", got[1].info.name.bucket);
    try testing.expectEqualStrings("audit", got[2].info.name.bucket);
    try testing.expectEqual(2, got[2].views.len);
    try testing.expectEqualStrings("app", got[3].info.name.bucket);
    try testing.expectEqual(.delete_requested, got[3].info.state);
    try testing.expect(got[3].info.analytics_enabled);
    try testing.expectEqual(0, got[3].views.len);

    var one = try r.client.view(.{ .parent = p, .location = "europe-west1", .bucket = "audit", .view = "only-errors" });
    defer one.deinit();
    try testing.expectEqualStrings("p", one.value.name.parent.project);
    var bucket_one = try r.client.bucket(audit);
    defer bucket_one.deinit();
    try testing.expectEqualStrings("audit", bucket_one.value.name.bucket);

    try r.fake.denyViewList(audit);
    var partly = try r.client.picker(p);
    defer partly.deinit();
    try testing.expect(partly.value.buckets[2].views_denied);
    try r.fake.denyBucketList(p);
    var refused = try r.client.picker(p);
    defer refused.deinit();
    try testing.expect(refused.value.list_denied);
    try testing.expectError(error.PermissionDenied, r.client.listViews(audit, .{}));
}

test "fake: log names in byte order, a view's leaving out data access logs, paged" {
    var r: Rig = undefined;
    try r.init();
    defer r.deinit();
    const p: types.Parent = .{ .project = "p" };
    for ([_][]const u8{ "ping", "cloudaudit.googleapis.com/data_access", "GCEGuestAgent", "cloudaudit.googleapis.com/activity", "ping" }, 0..) |id, i| {
        try r.fake.write(.{ .log_name = try r.fake.logName(p, id), .timestamp = at(@intCast(i)) });
    }
    try r.fake.write(.{ .log_name = try r.fake.logName(p, "late"), .timestamp = at(9), .visible_at = at(60) });
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var all = try r.client.listLogs(.{});
    defer all.deinit();
    const want = [_][]const u8{ "GCEGuestAgent", "cloudaudit.googleapis.com/activity", "cloudaudit.googleapis.com/data_access", "ping" };
    try testing.expectEqual(want.len, all.value.log_ids.len);
    for (want, all.value.log_ids) |w, g| try testing.expectEqualStrings(w, g);

    const default_view: types.Scope = .{ .view = .{ .parent = p, .location = "global", .bucket = "_Default", .view = "_Default" } };
    var of_view = try r.client.listLogs(.{ .scope = default_view });
    defer of_view.deinit();
    try testing.expectEqual(3, of_view.value.log_ids.len);
    for (of_view.value.log_ids) |id| try testing.expect(!std.mem.endsWith(u8, id, "data_access"));
    // The same view filters entries too.
    var q = try r.client.query(.{ .scopes = &.{default_view}, .order = .oldest_first });
    defer q.deinit();
    var page = try q.page(null);
    defer page.deinit();
    try testing.expectEqual(4, page.value.entries.len);

    // A page of two, then the rest.
    var pages: std.ArrayList(u8) = .empty;
    var token: ?[]const u8 = null;
    while (true) {
        var lp = try r.client.listLogs(.{ .page_size = 2, .page_token = token });
        defer lp.deinit();
        for (lp.value.log_ids) |id| try pages.appendSlice(a, id[0..1]);
        try pages.append(a, '|');
        token = if (lp.value.next_page_token) |t| try a.dupe(u8, t) else break;
    }
    try testing.expectEqualStrings("Gc|cp|", pages.items);
    r.clock.now_ns = at(60).nanoseconds;
    var later = try r.client.listLogs(.{});
    defer later.deinit();
    try testing.expectEqual(5, later.value.log_ids.len);
}

test "fake: views of a location '-', and requests it does not model" {
    var r: Rig = undefined;
    try r.init();
    defer r.deinit();
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const cases = [_]struct { []const u8, u16, []const u8 }{
        .{ "/v2/projects/p/locations/-/buckets/-/views", 404, "Cloud Logging does not support location: -" },
        .{ "/v2/projects/p/locations/global/buckets/none/views", 404, "Bucket `none` in location `global` does not exist" },
        .{ "/v2/projects/p/locations/global/buckets/none/views/v", 404, "Bucket `none` in location `global` does not exist" },
        .{ "/v2/projects/p/logs?pageToken=garbage", 501, "page token" },
        .{ "/v2/projects/p/logs?pageSize=x", 501, "pageSize" },
        .{ "/v2/teams/t/logs", 501, "log list" },
        .{ "/v2/teams/t/locations/global/buckets", 501, "bucket list" },
        .{ "/v2/projects/p/places/global/buckets", 501, "bucket list" },
        .{ "/v2/projects/p/locations/global/buckets/b/extra/views", 501, "view list" },
        .{ "/v2/projects/p/locations/global/buckets/_Default/views/_AllLogs/logs/x", 501, "this call" },
    };
    for (cases) |case| {
        const reply = try r.fake.serve(.GET, try std.fmt.allocPrint(a, "https://logging.googleapis.com{s}", .{case[0]}), "", a);
        try testing.expectEqual(case[1], reply.status);
        if (std.mem.indexOf(u8, reply.body, case[2]) == null) {
            std.debug.print("{s}: {s}\n", .{ case[0], reply.body });
            return error.TestExpectedEqual;
        }
    }
    // A view with a filter of its own is not read.
    try r.fake.addView(.{ .parent = .{ .project = "p" }, .location = "global", .bucket = "_Default" }, "mine", "resource.type = \"gce_instance\"");
    try testing.expectError(error.Unimplemented, r.listAll(a, .{ .scopes = &.{.{ .view = .{ .parent = .{ .project = "p" }, .location = "global", .bucket = "_Default", .view = "mine" } }} }));
}
