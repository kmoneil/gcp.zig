//! The types callers see: scopes and names, query options, entries and their
//! parts, pages. Results come wrapped in core's `Owned`, re-exported here.

const std = @import("std");
const Allocator = std.mem.Allocator;
const core = @import("core");

pub const Owned = core.Owned;

/// One label of an entry or a monitored resource, in the order sent.
pub const Label = struct { key: []const u8, value: []const u8 };

/// What a project, folder, organization or billing account is called in a
/// resource name. Each holds the id alone: "my-project", "123456789".
pub const Parent = union(enum) {
    project: []const u8,
    folder: []const u8,
    organization: []const u8,
    /// Such as "012345-567890-ABCDEF".
    billing_account: []const u8,
};

/// A log bucket: `projects/P/locations/L/buckets/B`.
pub const BucketName = struct {
    parent: Parent,
    /// Such as "global" or "europe-west1".
    location: []const u8,
    /// Such as "_Default".
    bucket: []const u8,
};

/// A log view: `projects/P/locations/L/buckets/B/views/V`.
pub const ViewName = struct {
    parent: Parent,
    location: []const u8,
    bucket: []const u8,
    /// Such as "_AllLogs".
    view: []const u8,
};

/// What `entries.list` reads: a container, which is every bucket its logs
/// went to, or one view of one bucket.
pub const Scope = union(enum) {
    parent: Parent,
    view: ViewName,
};

/// The order of a listing. Entries with equal timestamps come in `insertId`
/// order either way.
pub const Order = enum {
    /// `timestamp desc`. The API reference advises it for recent entries,
    /// which `timestamp asc` "may take a long time" to reach.
    newest_first,
    /// `timestamp asc`, the API's own default.
    oldest_first,

    pub fn wire(self: Order) []const u8 {
        return switch (self) {
            .newest_first => "timestamp desc",
            .oldest_first => "timestamp asc",
        };
    }
};

/// How serious an entry is, by Logging's numbering: comparisons follow the
/// numbers, so `.warning` is below `.@"error"`.
pub const Severity = enum(u16) {
    default = 0,
    debug = 100,
    info = 200,
    notice = 300,
    warning = 400,
    @"error" = 500,
    critical = 600,
    alert = 700,
    emergency = 800,
    /// A name this version does not know.
    unknown = 65535,
    /// A number this version does not know, kept as sent.
    _,

    const names = [_]struct { []const u8, Severity }{
        .{ "DEFAULT", .default },   .{ "DEBUG", .debug },     .{ "INFO", .info },
        .{ "NOTICE", .notice },     .{ "WARNING", .warning }, .{ "ERROR", .@"error" },
        .{ "CRITICAL", .critical }, .{ "ALERT", .alert },     .{ "EMERGENCY", .emergency },
    };

    /// The name the API uses, such as "WARNING", or null for a severity
    /// it has none for.
    pub fn name(self: Severity) ?[]const u8 {
        for (names) |entry| if (entry[1] == self) return entry[0];
        return null;
    }

    /// The severity a name stands for, as the server writes names; any
    /// other is `.unknown`.
    pub fn fromName(text: []const u8) Severity {
        for (names) |entry| if (std.mem.eql(u8, entry[0], text)) return entry[1];
        return .unknown;
    }

    /// The severity a number stands for. One that fits no severity, the
    /// unknown one's own included, is `.unknown`.
    pub fn fromNumber(number: i64) Severity {
        if (number < 0 or number >= @backingInt(Severity.unknown)) return .unknown;
        return @fromBackingInt(@intCast(number));
    }
};

/// An entry's payload: the one of `textPayload`, `jsonPayload` and
/// `protoPayload` it has, or none.
pub const Payload = union(enum) {
    none,
    text: []const u8,
    /// The `jsonPayload` object's bytes, as the server sent them: valid
    /// JSON, numbers as it wrote them. It keeps JSON payloads as doubles,
    /// so a writer's 12345678901234567890 comes back as
    /// 1.2345678901234567e+19, and keys in an order of its own (measured
    /// on 2026-10-16).
    json: []const u8,
    /// The `protoPayload` object's bytes, as sent, and its top-level
    /// `"@type"`, such as "type.googleapis.com/google.cloud.audit.AuditLog"
    /// ("" when it has none). Nested `@type` keys stay in the bytes.
    proto: struct { type_url: []const u8, json: []const u8 },

    pub const ParseError = error{ NotJson, InvalidResponse, OutOfMemory };

    /// Parses the JSON of a `json` or `proto` payload into a
    /// `std.json.Value` whose numbers keep their text
    /// (`.number_string`). `text` and `none` are `error.NotJson`.
    pub fn parse(self: Payload, gpa: Allocator) ParseError!std.json.Parsed(std.json.Value) {
        const bytes = switch (self) {
            .json => |j| j,
            .proto => |p| p.json,
            .none, .text => return error.NotJson,
        };
        return std.json.parseFromSlice(std.json.Value, gpa, bytes, .{ .parse_numbers = false }) catch |err| switch (err) {
            error.OutOfMemory => error.OutOfMemory,
            // The bytes were read as one JSON value when the page was
            // decoded, so only a caller who built this payload gets here.
            else => error.InvalidResponse,
        };
    }
};

/// The HTTP request an entry is about, as `httpRequest` carries it.
pub const HttpRequest = struct {
    method: []const u8 = "",
    url: []const u8 = "",
    /// 0 when absent.
    status: u16 = 0,
    request_size: ?i64 = null,
    response_size: ?i64 = null,
    latency: ?std.Io.Duration = null,
    user_agent: []const u8 = "",
    remote_ip: []const u8 = "",
    server_ip: []const u8 = "",
    referer: []const u8 = "",
    /// Such as "HTTP/1.1".
    protocol: []const u8 = "",
    cache_lookup: bool = false,
    cache_hit: bool = false,
    cache_validated_with_origin_server: bool = false,
    cache_fill_bytes: ?i64 = null,
};

/// A long-running operation the entry belongs to.
pub const Operation = struct {
    id: []const u8 = "",
    producer: []const u8 = "",
    first: bool = false,
    last: bool = false,
};

pub const SourceLocation = struct {
    file: []const u8 = "",
    /// 0 when absent.
    line: i64 = 0,
    function: []const u8 = "",
};

/// One piece of an entry its writer split for size. Pieces share `uid`.
pub const Split = struct {
    uid: []const u8 = "",
    index: u32 = 0,
    total: u32 = 0,
};

/// One log entry. Every slice points into the page that holds it.
pub const Entry = struct {
    /// As sent, its log id URL-encoded: "projects/P/logs/run.googleapis.com%2Fstderr".
    log_name: []const u8,
    /// Decoded: "run.googleapis.com/stderr". "" when `log_name` has none.
    log_id: []const u8,
    resource_type: []const u8,
    resource_labels: []const Label,
    /// When the event happened, as its writer said, to the nanosecond.
    timestamp: std.Io.Timestamp,
    /// When Logging received it.
    receive_timestamp: ?std.Io.Timestamp,
    severity: Severity,
    insert_id: []const u8,
    payload: Payload,
    labels: []const Label,
    http_request: ?HttpRequest,
    operation: ?Operation,
    /// A bare trace id or `projects/P/traces/ID`, as sent.
    trace: []const u8,
    span_id: []const u8,
    trace_sampled: bool,
    source_location: ?SourceLocation,
    split: ?Split,
    /// The entry's JSON as received, for the fields not typed here, such
    /// as `otel`, `errorGroups` and `apphub`, and those still to come.
    raw: []const u8,
};

/// What `Client.query` builds one `entries.list` request from.
pub const QueryOptions = struct {
    /// 1 to 100. Empty: the client's project.
    scopes: []const Scope = &.{},
    /// The Logging query language, sent as written, inside parentheses.
    filter: []const u8 = "",
    /// Written as the literal bound `timestamp >= "..."`.
    since: ?std.Io.Timestamp = null,
    /// Written as the literal bound `timestamp < "..."`.
    until: ?std.Io.Timestamp = null,
    /// Written as `severity >= NAME`.
    min_severity: ?Severity = null,
    /// Written as `log_id("...")`: the plain id, such as
    /// "run.googleapis.com/stderr".
    log_id: ?[]const u8 = null,
    /// Written as `resource.type = "..."`.
    resource_type: ?[]const u8 = null,
    order: Order = .newest_first,
    /// At least 1. Production served pages above the proto's 1000 when
    /// measured; `Client.Options.max_response_bytes` bounds a large one.
    page_size: u32 = 100,
    /// How long the server may search for this query's pages, sent as
    /// `X-Server-Timeout`. 0: the server's own 10 s, after which a page
    /// comes back short or empty with a token. Measured on 2026-10-16, a
    /// broad query found 58 entries in 6 s by default and a full 1000 in
    /// 21 s with 30. Must stay under `Client.Options.request_timeout_ms`.
    server_timeout_s: u32 = 0,
};

/// One page of entries.
pub const EntryPage = struct {
    entries: []const Entry,
    /// Null: the listing is complete. Set with no entries: the server ran
    /// out of time, not of entries, and the next page goes on. A token
    /// lasts 24 hours and works only with the query that produced it.
    next_page_token: ?[]const u8,
};

/// What a `ReadBudget` has left.
pub const ReadStatus = struct {
    /// Calls counted in the last 60 seconds.
    used: u32,
    /// The most it allows in any 60 seconds; 0 means it counts nothing.
    limit: u32,
    /// How long until the next call may go: 0 when one may go now.
    next_free_ms: u64,
};

/// What `Client.listLogs` lists: a container's logs, or a view's.
pub const ListLogsOptions = struct {
    /// Null: the client's project.
    scope: ?Scope = null,
    /// 0: the server's choice.
    page_size: u32 = 0,
    page_token: ?[]const u8 = null,
};

/// One page of log names. Production lists only logs that have entries,
/// in byte order, and listed the probe's new logs within 100 s of their
/// first entry.
pub const LogPage = struct {
    /// As sent, each log id URL-encoded: "projects/P/logs/a%2Fb".
    log_names: []const []const u8,
    /// Decoded, in the same order: "a/b".
    log_ids: []const []const u8,
    next_page_token: ?[]const u8,
};

/// What `Client.listBuckets` lists.
pub const ListBucketsOptions = struct {
    /// Null: the client's project.
    parent: ?Parent = null,
    /// Null: every location, the API's `-`.
    location: ?[]const u8 = null,
    /// 0: the server's choice.
    page_size: u32 = 0,
    page_token: ?[]const u8 = null,
};

/// A page size and a token, for lists that take nothing else.
pub const PageOptions = struct {
    /// 0: the server's choice.
    page_size: u32 = 0,
    page_token: ?[]const u8 = null,
};

/// Where a bucket is in its life. A deleted one stays `delete_requested`
/// for 7 days, and Logging still routes entries to it meanwhile.
pub const BucketState = enum { active, delete_requested, updating, creating, failed, unspecified, unknown };

pub const BucketInfo = struct {
    name: BucketName,
    description: []const u8,
    /// Absent on `_Default` and `_Required`.
    create_time: ?std.Io.Timestamp,
    update_time: ?std.Io.Timestamp,
    /// 0 when absent.
    retention_days: u32,
    /// Its retention can no longer change.
    locked: bool,
    state: BucketState,
    analytics_enabled: bool,
    /// Field paths hidden in this bucket.
    restricted_fields: []const []const u8,
};

pub const BucketPage = struct {
    buckets: []const BucketInfo,
    next_page_token: ?[]const u8,
};

pub const ViewInfo = struct {
    name: ViewName,
    description: []const u8,
    /// What the view shows of its bucket, such as `NOT
    /// LOG_ID("cloudaudit.googleapis.com/data_access")`; "" for all of it.
    filter: []const u8,
    create_time: ?std.Io.Timestamp,
    update_time: ?std.Io.Timestamp,
};

pub const ViewPage = struct {
    views: []const ViewInfo,
    next_page_token: ?[]const u8,
};

/// One bucket of a picker, with its views.
pub const PickerBucket = struct {
    info: BucketInfo,
    /// `_Default` first, then `_AllLogs`, then the rest by id.
    views: []const ViewInfo,
    /// The caller may not list this bucket's views.
    views_denied: bool,
};

/// A parent's buckets and their views, ordered for a picker: `_Default`
/// first, then `_Required`, then the rest by location and id. The server
/// documents no order of its own.
pub const Picker = struct {
    buckets: []const PickerBucket,
    /// The caller may not list buckets, as a Logs View Accessor cannot:
    /// the app needs view names from elsewhere, or reads the parent itself.
    list_denied: bool,
};

/// Where a tail is: a time, and the `insertId` of the last entry returned
/// at that time when a poll stopped partway through it ("" otherwise).
pub const Cursor = struct {
    timestamp: std.Io.Timestamp,
    insert_id: []const u8 = "",
};

/// What `Client.tail` follows, and how.
pub const TailOptions = struct {
    /// 1 to 100. Empty: the client's project.
    scopes: []const Scope = &.{},
    /// The Logging query language, as a query takes it.
    filter: []const u8 = "",
    min_severity: ?Severity = null,
    log_id: ?[]const u8 = null,
    resource_type: ?[]const u8 = null,
    /// Where to begin: a cursor kept from an earlier tail. Null: now, less
    /// `settle_ms`.
    from: ?Cursor = null,
    /// Entries newer than now less this wait for the next poll, so those
    /// still arriving have time to.
    settle_ms: u32 = 5_000,
    /// Each poll reads this far back behind its cursor, for entries that
    /// arrived late. At least `settle_ms`.
    overlap_ms: u32 = 60_000,
    page_size: u32 = 1000,
    /// `entries.list` calls one poll may make, empty pages included.
    max_calls_per_poll: u32 = 3,
    /// As `QueryOptions.server_timeout_s`.
    server_timeout_s: u32 = 0,
};

/// What one poll returned.
pub const TailBatch = struct {
    /// Entries not returned before, oldest first.
    entries: []const Entry,
    /// More was waiting than the poll's calls allowed: the tail is behind,
    /// and the next poll goes on from here.
    behind: bool,
    /// Why the poll stopped early, with what it had: the read budget or the
    /// server's quota (`error.ResourceExhausted`), or a call that failed
    /// after entries came. The next poll tries again from the cursor.
    stopped: ?anyerror,
};

pub const TailStats = struct {
    polls: u64 = 0,
    calls: u64 = 0,
    entries: u64 = 0,
    /// Seen again in an overlap and dropped.
    duplicates: u64 = 0,
    /// Arrived after a poll had passed their timestamp, and caught by the
    /// overlap.
    late: u64 = 0,
    /// How far behind the cursor the latest-arriving late entry was: how
    /// close `overlap_ms` came to missing it.
    latest_late_ms: u64 = 0,
};
