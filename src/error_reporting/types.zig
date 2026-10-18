//! The types of the public API: error groups, their statistics and events,
//! pages of them, and the options of a query. Results come wrapped in
//! core's `Owned`, re-exported here.

const std = @import("std");
const core = @import("core");

pub const Owned = core.Owned;

/// How far back a query looks. The periods are fixed and end now; the API
/// takes nothing else.
pub const Period = enum {
    hour,
    six_hours,
    day,
    week,
    thirty_days,

    pub fn wire(self: Period) []const u8 {
        return switch (self) {
            .hour => "PERIOD_1_HOUR",
            .six_hours => "PERIOD_6_HOURS",
            .day => "PERIOD_1_DAY",
            .week => "PERIOD_1_WEEK",
            .thirty_days => "PERIOD_30_DAYS",
        };
    }

    /// What group stats cover when no period is sent: 7 days, measured.
    pub const default: Period = .week;

    pub fn seconds(self: Period) i64 {
        return switch (self) {
            .hour => 3600,
            .six_hours => 6 * 3600,
            .day => 24 * 3600,
            .week => 7 * 24 * 3600,
            .thirty_days => 30 * 24 * 3600,
        };
    }
};

/// The order of group stats, always descending.
pub const Order = enum {
    /// By how many errors the group had in the period: the default.
    count,
    /// By the group's latest error.
    last_seen,
    /// By when the group was made.
    created,
    /// By how many users the group's errors reached.
    affected_users,

    pub fn wire(self: Order) []const u8 {
        return switch (self) {
            .count => "COUNT_DESC",
            .last_seen => "LAST_SEEN_DESC",
            .created => "CREATED_DESC",
            .affected_users => "AFFECTED_USERS_DESC",
        };
    }
};

/// Where timed counts' buckets begin and end.
pub const Alignment = union(enum) {
    /// Buckets of equal width ending exactly at now, the first cut short
    /// when the width does not divide the period.
    end,
    /// Buckets on a grid through this time, which need not be in the
    /// period: the first starts at the period's start and the last ends at
    /// now, both cut short. Midnight UTC makes daily buckets calendar days.
    rounded: std.Io.Timestamp,
};

/// What has been decided about a group. Error Reporting changes it on its
/// own once: a resolved group that has a new error is open again.
pub const Status = enum {
    /// New groups are open; a resolved one that recurs comes back here.
    open,
    acknowledged,
    /// More errors are not expected. A new one reopens the group.
    resolved,
    /// Hidden: left out of group stats, even when asked for by id, and its
    /// new errors are not recorded. Only `Client.group(id).get()` reads it.
    muted,
    /// A name or number this version does not know. Never sent; never a
    /// failure.
    unknown,

    pub fn wire(self: Status) []const u8 {
        return switch (self) {
            .open => "OPEN",
            .acknowledged => "ACKNOWLEDGED",
            .resolved => "RESOLVED",
            .muted => "MUTED",
            .unknown => unreachable,
        };
    }

    /// As the server spells it. `RESOLUTION_STATUS_UNSPECIFIED`, which it
    /// stores as open, is open.
    pub fn fromWire(name: []const u8) Status {
        const names = [_]struct { []const u8, Status }{
            .{ "OPEN", .open },
            .{ "ACKNOWLEDGED", .acknowledged },
            .{ "RESOLVED", .resolved },
            .{ "MUTED", .muted },
            .{ "RESOLUTION_STATUS_UNSPECIFIED", .open },
        };
        for (names) |entry| if (std.mem.eql(u8, name, entry[0])) return entry[1];
        return .unknown;
    }

    /// As a client that asks for `enum-encoding=int` gets it.
    pub fn fromNumber(n: i64) Status {
        return switch (n) {
            0, 1 => .open,
            2 => .acknowledged,
            3 => .resolved,
            4 => .muted,
            else => .unknown,
        };
    }
};

/// A service, a version and a resource type, any of which may be left out:
/// as a filter, what to match; in an answer, what sent the error.
pub const ServiceFilter = struct {
    /// A service name: the App Engine service, or what the reporter set.
    service: ?[]const u8 = null,
    /// A version label or a source revision.
    version: ?[]const u8 = null,
    /// A monitored resource type, such as `gae_app`, or `reported_errors`
    /// for errors sent through the API.
    resource_type: ?[]const u8 = null,
};

/// What sent an error.
pub const ServiceContext = ServiceFilter;

/// What a group-stats query sends with every page.
pub const GroupStatsOptions = struct {
    /// Null for the server's default: the last 7 days, when measured.
    period: ?Period = null,
    /// Bucket width for `GroupStats.timed_counts`, in seconds; null asks
    /// for no buckets. Production refuses buckets too narrow for the
    /// period: 60 s over 30 days was refused, 600 s over an hour taken.
    timed_count_seconds: ?u32 = null,
    alignment: Alignment = .end,
    order: Order = .count,
    service: ServiceFilter = .{},
    /// Only these groups, those with no errors in the period included. A
    /// muted group is left out even when named.
    group_ids: []const []const u8 = &.{},
    /// Null for the server's 20. Production took 5,000.
    page_size: ?u31 = null,
};

/// What an events query sends with every page.
pub const EventsOptions = struct {
    /// Null for the server's default: the last 30 days, when measured.
    period: ?Period = null,
    service: ServiceFilter = .{},
    /// Null for the server's default.
    page_size: ?u31 = null,
};

/// A link from a group to an issue tracker.
pub const TrackingIssue = struct { url: []const u8 };

/// An error group: errors Error Reporting found alike, by exception type
/// and the top frames of their stack traces.
pub const Group = struct {
    /// "projects/my-project/groups/CNDdw-bLr_rPjQE", as the server names
    /// it, which leaves the location out.
    name: []const u8,
    /// Opaque, assigned by Error Reporting, base64url characters.
    id: []const u8,
    status: Status = .open,
    tracking_issues: []const TrackingIssue = &.{},
};

/// An HTTP request that met an error.
pub const HttpRequest = struct {
    method: ?[]const u8 = null,
    url: ?[]const u8 = null,
    user_agent: ?[]const u8 = null,
    referrer: ?[]const u8 = null,
    response_status_code: ?i32 = null,
    /// An address, or a token derived from one.
    remote_ip: ?[]const u8 = null,
};

/// Where an error was reported from.
pub const SourceLocation = struct {
    file_path: ?[]const u8 = null,
    /// 1-based; 0 or null when unknown.
    line_number: ?i32 = null,
    function_name: ?[]const u8 = null,
};

/// The source revision a service was built from.
pub const SourceReference = struct {
    repository: ?[]const u8 = null,
    revision_id: ?[]const u8 = null,
};

/// What surrounded an error.
pub const ErrorContext = struct {
    http_request: ?HttpRequest = null,
    /// The user who met it, as the reporter named them; null when none.
    user: ?[]const u8 = null,
    report_location: ?SourceLocation = null,
    source_references: []const SourceReference = &.{},
};

/// One error.
pub const Event = struct {
    /// When it happened, or when it was received if the report said not.
    time: ?std.Io.Timestamp = null,
    service: ServiceContext = .{},
    /// The stack trace, as reported or logged.
    message: []const u8 = "",
    context: ErrorContext = .{},

    /// The stack trace's first line: see `headline`.
    pub fn headline(self: Event) []const u8 {
        return headlineOf(self.message);
    }
};

/// The first line of a stack trace, which in every language Error
/// Reporting reads names the exception and its message ("ValueError: order
/// has no lines", "java.lang.NullPointerException: customer is null",
/// "panic: runtime error: ..."). Python's starts with "Traceback (most
/// recent call last):", so for it the last line is taken. Text, not parsed:
/// no language's format is guessed at beyond that.
pub fn headlineOf(message: []const u8) []const u8 {
    const trimmed = std.mem.trim(u8, message, " \t\r\n");
    const first_end = std.mem.indexOfScalar(u8, trimmed, '\n') orelse trimmed.len;
    const first = std.mem.trimEnd(u8, trimmed[0..first_end], " \t\r");
    if (!std.mem.startsWith(u8, first, "Traceback (most recent call last)")) return first;
    const last_start = if (std.mem.lastIndexOfScalar(u8, trimmed, '\n')) |at| at + 1 else 0;
    return std.mem.trim(u8, trimmed[last_start..], " \t\r");
}

/// Errors in one bucket of a period.
pub const TimedCount = struct {
    /// Included.
    start: std.Io.Timestamp,
    /// Excluded.
    end: std.Io.Timestamp,
    /// Estimated: Error Reporting samples. 0 for a bucket with none, which
    /// production sends without a count.
    count: u64 = 0,
};

/// A group, and what its errors in the period came to. Every count is an
/// estimate: Error Reporting samples up to 1,000 errors an hour.
pub const GroupStats = struct {
    group: Group,
    count: u64 = 0,
    /// Distinct users, by `ErrorContext.user` or an HTTP request's remote
    /// address; 0 when the errors named none.
    affected_users: u64 = 0,
    /// Ascending, non-overlapping, inside the period: every bucket, those
    /// with no errors too. Empty unless `timed_count_seconds` was set.
    timed_counts: []const TimedCount = &.{},
    /// The time of the group's first error to arrive, whatever the period:
    /// a report backdated after the group was made does not move it.
    first_seen: ?std.Io.Timestamp = null,
    /// The latest error's time, whatever the period, in whole seconds.
    last_seen: ?std.Io.Timestamp = null,
    /// Services with errors in the group; may be cut short.
    affected_services: []const ServiceContext = &.{},
    /// How many there are, cut short or not.
    affected_service_count: u32 = 0,
    /// One of the group's errors, chosen by the server: not the newest.
    representative: ?Event = null,
};

/// One page of a query. `items` may be empty while `next_page_token` is
/// set; only a null token ends it.
pub fn Page(comptime T: type) type {
    return struct {
        items: []const T,
        next_page_token: ?[]const u8 = null,
        /// Where the server's period began, after any data it no longer
        /// holds.
        time_range_begin: ?std.Io.Timestamp = null,
    };
}

pub const GroupStatsPage = Page(GroupStats);
pub const EventPage = Page(Event);

/// A refusal that names the project charged: the API off there, or a quota
/// project the caller may not use.
pub const ConsumerRefusal = struct {
    reason: Reason,
    /// "projects/82150720798", as the server names it.
    consumer: []const u8,
    /// The page that turns the API on, or the project's IAM page, when the
    /// server sent one.
    link: ?[]const u8,

    pub const Reason = enum {
        /// `error.ServiceDisabled`.
        service_disabled,
        /// `error.QuotaProjectDenied`.
        quota_project_denied,
    };
};

/// Where a client's call budget stands.
pub const BudgetStatus = struct {
    /// Calls in the last minute.
    used: u32,
    /// 0 when nothing is counted.
    limit: u32,
    /// How long until a call may go: 0 when one may go now.
    next_free_ms: u64,
};

test "headlineOf: the line that names the exception, in each language's trace" {
    const cases = [_]struct { []const u8, []const u8 }{
        .{ "Traceback (most recent call last):\n  File \"a.py\", line 1, in f\n    g()\nValueError: order has no lines\n", "ValueError: order has no lines" },
        .{ "java.lang.NullPointerException: customer is null\n\tat com.example.Billing.charge(Billing.java:88)", "java.lang.NullPointerException: customer is null" },
        .{ "TypeError: Cannot read properties of undefined (reading 'id')\n    at render (/srv/view.js:17:23)", "TypeError: Cannot read properties of undefined (reading 'id')" },
        .{ "panic: runtime error: index out of range [3] with length 3\n\ngoroutine 1 [running]:", "panic: runtime error: index out of range [3] with length 3" },
        .{ "  one line, padded  \r\n", "one line, padded" },
        .{ "", "" },
        .{ "Traceback (most recent call last):", "Traceback (most recent call last):" },
    };
    for (cases) |case| try std.testing.expectEqualStrings(case[1], headlineOf(case[0]));
}

test "Status: names and numbers, and what this version does not know" {
    try std.testing.expectEqual(.muted, Status.fromWire("MUTED"));
    try std.testing.expectEqual(.open, Status.fromWire("RESOLUTION_STATUS_UNSPECIFIED"));
    try std.testing.expectEqual(.unknown, Status.fromWire("WONTFIX"));
    for ([_]Status{ .open, .acknowledged, .resolved, .muted }) |s| try std.testing.expectEqual(s, Status.fromWire(s.wire()));
    try std.testing.expectEqual(.open, Status.fromNumber(1));
    try std.testing.expectEqual(.resolved, Status.fromNumber(3));
    try std.testing.expectEqual(.unknown, Status.fromNumber(9));
}
