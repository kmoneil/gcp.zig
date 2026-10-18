//! One list request, fixed when `Client.groupStats` or `Client.events` made
//! it: every page sends the same path, the token after it. Production
//! answered a token sent with another period as if it belonged there, so the
//! client keeps each token to the request it came from.

const std = @import("std");
const Allocator = std.mem.Allocator;
const core = @import("core");

const Client = @import("Client.zig");
const codec = @import("codec.zig");
const errors = @import("errors.zig");
const rpc = @import("rpc.zig");
const types = @import("types.zig");
const validate = @import("validate.zig");
const Error = errors.Error;

/// A list of `T`s: `types.GroupStats` or `types.Event`.
pub fn Query(comptime T: type) type {
    return struct {
        client: *Client,
        /// Holds `path`.
        arena: std.heap.ArenaAllocator,
        /// The request's path and query, but for the token: the same bytes
        /// for every page.
        path: []const u8,

        const Self = @This();

        /// What a decoding failure calls the response.
        const what = switch (T) {
            types.GroupStats => "group stats",
            types.Event => "events",
            else => @compileError("no list of " ++ @typeName(T)),
        };

        pub fn deinit(self: *Self) void {
            self.arena.deinit();
            self.* = undefined;
        }

        /// One page. `items` may be empty while `next_page_token` is set;
        /// only a null token ends the list. Pass null for the first page.
        pub fn page(self: *Self, page_token: ?[]const u8) Error!types.Owned(types.Page(T)) {
            const client = self.client;
            rpc.begin(client);
            if (page_token) |t| if (!validate.isPageToken(t)) {
                if (client.diagnostics) |d| d.print("invalid page token: expected the next_page_token of an earlier page", .{});
                return error.InvalidPageToken;
            };
            var result: types.Owned(types.Page(T)) = try .init(client.gpa);
            errdefer result.deinit();
            var response: std.heap.ArenaAllocator = .init(client.gpa);
            defer response.deinit();
            const path = if (page_token) |t| p: {
                var w: std.Io.Writer.Allocating = .init(response.allocator());
                w.writer.writeAll(self.path) catch return error.OutOfMemory;
                w.writer.writeAll("&pageToken=") catch return error.OutOfMemory;
                core.query.writeValue(&w.writer, t) catch return error.OutOfMemory;
                break :p w.written();
            } else self.path;
            const body = try rpc.call(client, &response, .GET, path, null, page_token != null);
            var scratch: std.heap.ArenaAllocator = .init(client.gpa);
            defer scratch.deinit();
            const out = result.arena.allocator();
            result.value = switch (T) {
                types.GroupStats => codec.decodeGroupStatsPage(out, scratch.allocator(), body),
                types.Event => codec.decodeEventPage(out, scratch.allocator(), body),
                else => unreachable,
            } catch |err| return rpc.decodeFailed(client, err, what);
            return result;
        }
    };
}

/// The most buckets production gives one period, measured on 2026-10-18: a
/// width is refused exactly when the period over it is more than 100.
pub const max_buckets = 100;

/// Builds a group-stats request's path under `parent`, checked. Writes
/// only what differs from the server's defaults.
pub fn groupStatsPath(arena: Allocator, diag: ?*core.Diagnostics, parent: []const u8, options: types.GroupStatsOptions) Error![]const u8 {
    for (options.group_ids) |id| if (!validate.isGroupId(id)) {
        if (diag) |d| d.print("invalid group id: expected one Error Reporting assigned, base64url characters", .{});
        return error.InvalidName;
    };
    if (options.timed_count_seconds) |s| {
        if (s == 0) {
            if (diag) |d| d.print("invalid timed_count_seconds: 0; leave it null for no buckets", .{});
            return error.InvalidOptions;
        }
        const period = options.period orelse types.Period.default;
        if (@as(i64, s) * max_buckets < period.seconds()) {
            if (diag) |d| d.print("invalid timed_count_seconds: at most {d} buckets a period, so at least {d} s for this one", .{ max_buckets, std.math.divCeil(i64, period.seconds(), max_buckets) catch unreachable });
            return error.InvalidOptions;
        }
    }
    try checkPageSize(diag, options.page_size);
    try checkFilter(diag, options.service);

    var w: std.Io.Writer.Allocating = .init(arena);
    writeGroupStatsPath(&w.writer, parent, options) catch return error.OutOfMemory;
    return w.written();
}

fn writeGroupStatsPath(w: *std.Io.Writer, parent: []const u8, options: types.GroupStatsOptions) std.Io.Writer.Error!void {
    try w.print("/v1beta1/{s}/groupStats?prettyPrint=false", .{parent});
    var q: core.query.Params = .{ .w = w, .separator = '&' };
    if (options.period) |p| try q.add("timeRange.period", p.wire());
    if (options.timed_count_seconds) |s| {
        var buf: [16]u8 = undefined;
        try q.add("timedCountDuration", std.fmt.bufPrint(&buf, "{d}s", .{s}) catch unreachable);
        switch (options.alignment) {
            .end => {},
            .rounded => |at| {
                var tbuf: [core.timestamp.max_len]u8 = undefined;
                try q.add("alignment", "ALIGNMENT_EQUAL_ROUNDED");
                try q.add("alignmentTime", core.timestamp.format(&tbuf, at));
            },
        }
    }
    if (options.order != .count) try q.add("order", options.order.wire());
    try writeFilter(&q, options.service);
    for (options.group_ids) |id| try q.add("groupId", id);
    if (options.page_size) |n| try q.addInt("pageSize", n);
}

/// Builds an events request's path under `parent`, checked.
pub fn eventsPath(arena: Allocator, diag: ?*core.Diagnostics, parent: []const u8, group_id: []const u8, options: types.EventsOptions) Error![]const u8 {
    if (!validate.isGroupId(group_id)) {
        if (diag) |d| d.print("invalid group id: expected one Error Reporting assigned, base64url characters", .{});
        return error.InvalidName;
    }
    try checkPageSize(diag, options.page_size);
    try checkFilter(diag, options.service);
    var w: std.Io.Writer.Allocating = .init(arena);
    writeEventsPath(&w.writer, parent, group_id, options) catch return error.OutOfMemory;
    return w.written();
}

fn writeEventsPath(w: *std.Io.Writer, parent: []const u8, group_id: []const u8, options: types.EventsOptions) std.Io.Writer.Error!void {
    try w.print("/v1beta1/{s}/events?prettyPrint=false", .{parent});
    var q: core.query.Params = .{ .w = w, .separator = '&' };
    try q.add("groupId", group_id);
    if (options.period) |p| try q.add("timeRange.period", p.wire());
    try writeFilter(&q, options.service);
    if (options.page_size) |n| try q.addInt("pageSize", n);
}

fn writeFilter(q: *core.query.Params, filter: types.ServiceFilter) std.Io.Writer.Error!void {
    if (filter.service) |s| try q.add("serviceFilter.service", s);
    if (filter.version) |v| try q.add("serviceFilter.version", v);
    if (filter.resource_type) |r| try q.add("serviceFilter.resourceType", r);
}

fn checkPageSize(diag: ?*core.Diagnostics, page_size: ?u31) Error!void {
    if (page_size) |n| if (n == 0) {
        if (diag) |d| d.print("invalid page_size: 0; leave it null for the server's default", .{});
        return error.InvalidOptions;
    };
}

fn checkFilter(diag: ?*core.Diagnostics, filter: types.ServiceFilter) Error!void {
    for ([_]?[]const u8{ filter.service, filter.version, filter.resource_type }) |value| {
        if (value) |v| if (validate.filterProblem(v)) |problem| {
            if (diag) |d| d.print("{s}", .{problem});
            return error.InvalidName;
        };
    }
}

const testing = std.testing;

test "groupStatsPath: only what differs from the defaults, every value escaped" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try testing.expectEqualStrings("/v1beta1/projects/p/groupStats?prettyPrint=false", try groupStatsPath(a, null, "projects/p", .{}));
    try testing.expectEqualStrings(
        "/v1beta1/projects/p/locations/-/groupStats?prettyPrint=false&timeRange.period=PERIOD_1_DAY&timedCountDuration=3600s&alignment=ALIGNMENT_EQUAL_ROUNDED&alignmentTime=2026-10-01T00%3A00%3A00Z&order=LAST_SEEN_DESC&serviceFilter.service=check%20out&serviceFilter.version=v%2F2&serviceFilter.resourceType=gae_app&groupId=CNDdw-bLr_rPjQE&groupId=COiYvODSyMz2Bg&pageSize=100",
        try groupStatsPath(a, null, "projects/p/locations/-", .{
            .period = .day,
            .timed_count_seconds = 3600,
            .alignment = .{ .rounded = try core.timestamp.parse("2026-10-01T00:00:00Z") },
            .order = .last_seen,
            .service = .{ .service = "check out", .version = "v/2", .resource_type = "gae_app" },
            .group_ids = &.{ "CNDdw-bLr_rPjQE", "COiYvODSyMz2Bg" },
            .page_size = 100,
        }),
    );
    // Without buckets, an alignment says nothing and is not sent.
    try testing.expectEqualStrings(
        "/v1beta1/projects/p/groupStats?prettyPrint=false&timeRange.period=PERIOD_30_DAYS",
        try groupStatsPath(a, null, "projects/p", .{ .period = .thirty_days, .alignment = .{ .rounded = .{ .nanoseconds = 0 } } }),
    );
}

test "groupStatsPath: at most 100 buckets a period, as production allows" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var diag: core.Diagnostics = .{};
    // Production's edges: 864 s over a day and 36 s over an hour taken,
    // 863 s and 35 s refused.
    _ = try groupStatsPath(a, &diag, "projects/p", .{ .period = .day, .timed_count_seconds = 864 });
    _ = try groupStatsPath(a, &diag, "projects/p", .{ .period = .hour, .timed_count_seconds = 36 });
    try testing.expectError(error.InvalidOptions, groupStatsPath(a, &diag, "projects/p", .{ .period = .day, .timed_count_seconds = 863 }));
    try testing.expectEqualStrings("invalid timed_count_seconds: at most 100 buckets a period, so at least 864 s for this one", diag.message());
    try testing.expectError(error.InvalidOptions, groupStatsPath(a, &diag, "projects/p", .{ .period = .hour, .timed_count_seconds = 35 }));
    try testing.expectEqualStrings("invalid timed_count_seconds: at most 100 buckets a period, so at least 36 s for this one", diag.message());
    // No period is the server's week: 6,048 s at least.
    _ = try groupStatsPath(a, &diag, "projects/p", .{ .timed_count_seconds = 6048 });
    try testing.expectError(error.InvalidOptions, groupStatsPath(a, &diag, "projects/p", .{ .timed_count_seconds = 6047 }));
    try testing.expectError(error.InvalidOptions, groupStatsPath(a, &diag, "projects/p", .{ .period = .thirty_days, .timed_count_seconds = 60 }));
}

test "groupStatsPath and eventsPath refuse what they will not send" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var diag: core.Diagnostics = .{};
    try testing.expectError(error.InvalidName, groupStatsPath(a, &diag, "projects/p", .{ .group_ids = &.{"a/b"} }));
    try testing.expectError(error.InvalidOptions, groupStatsPath(a, &diag, "projects/p", .{ .timed_count_seconds = 0 }));
    try testing.expectError(error.InvalidOptions, groupStatsPath(a, &diag, "projects/p", .{ .page_size = 0 }));
    try testing.expectError(error.InvalidName, groupStatsPath(a, &diag, "projects/p", .{ .service = .{ .version = "" } }));
    try testing.expectError(error.InvalidName, groupStatsPath(a, &diag, "projects/p", .{ .service = .{ .resource_type = "a\nb" } }));
    try testing.expectEqualStrings("invalid service filter: a control character", diag.message());
    try testing.expectError(error.InvalidName, eventsPath(a, &diag, "projects/p", "", .{}));
    try testing.expectError(error.InvalidOptions, eventsPath(a, &diag, "projects/p", "G", .{ .page_size = 0 }));
    try testing.expectError(error.InvalidName, eventsPath(a, &diag, "projects/p", "G", .{ .service = .{ .service = "\xff" } }));
    try testing.expectEqualStrings(
        "/v1beta1/projects/p/events?prettyPrint=false&groupId=G&timeRange.period=PERIOD_1_HOUR&serviceFilter.service=api&pageSize=2",
        try eventsPath(a, &diag, "projects/p", "G", .{ .period = .hour, .service = .{ .service = "api" }, .page_size = 2 }),
    );
}
