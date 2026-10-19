//! Cloud Scheduler's values as this library holds them: jobs, their
//! targets, states and last attempts, and the locations they live under.
//! Wire names live in the codec.

const std = @import("std");
const core = @import("core");

pub const Owned = core.Owned;

pub const Label = struct {
    key: []const u8,
    value: []const u8,
};

/// A job's state, as the server holds it.
pub const JobState = enum {
    /// The proto's default, never seen in an answer when measured.
    unspecified,
    enabled,
    paused,
    disabled,
    /// The job could not be updated: Scheduler's own trouble state.
    update_failed,
    /// A state this library does not know, read back from the server.
    unknown,

    pub fn fromWire(name: []const u8) JobState {
        inline for (.{
            .{ "ENABLED", .enabled },
            .{ "PAUSED", .paused },
            .{ "DISABLED", .disabled },
            .{ "UPDATE_FAILED", .update_failed },
            .{ "STATE_UNSPECIFIED", .unspecified },
        }) |entry| {
            if (std.mem.eql(u8, name, entry[0])) return entry[1];
        }
        return .unknown;
    }
};

/// The last attempt's `google.rpc.Status`. A job is born with code -1,
/// a sentinel no gRPC code names, before any attempt (measured
/// 2026-10-19); `Job.last_attempt` is null then, so this type only ever
/// holds a real attempt's outcome.
pub const LastAttempt = struct {
    /// The gRPC code: 0 is OK, anything else the failure. A host that
    /// did not resolve was 2 (UNKNOWN); a missing Pub/Sub topic 5
    /// (NOT_FOUND).
    code: i64,
    /// Production sent none for either failure when measured.
    message: []const u8 = "",

    /// Whether the attempt failed.
    pub fn failed(self: LastAttempt) bool {
        return self.code != 0;
    }
};

pub const HttpMethod = enum {
    unspecified,
    post,
    get,
    head,
    put,
    delete,
    patch,
    options,
    /// A method this library does not know, read back from the server.
    unknown,

    pub fn fromWire(name: []const u8) HttpMethod {
        inline for (.{
            .{ "POST", .post },
            .{ "GET", .get },
            .{ "HEAD", .head },
            .{ "PUT", .put },
            .{ "DELETE", .delete },
            .{ "PATCH", .patch },
            .{ "OPTIONS", .options },
            .{ "HTTP_METHOD_UNSPECIFIED", .unspecified },
        }) |entry| {
            if (std.mem.eql(u8, name, entry[0])) return entry[1];
        }
        return .unknown;
    }
};

/// How an HTTP target authenticates, when it does.
pub const HttpAuth = union(enum) {
    none,
    /// For Google APIs: an access token of this account.
    oauth: struct { service_account_email: []const u8, scope: []const u8 = "" },
    /// For everything else: an id token of this account.
    oidc: struct { service_account_email: []const u8, audience: []const u8 = "" },
};

pub const HttpTarget = struct {
    uri: []const u8,
    method: HttpMethod = .unspecified,
    /// As the server sent them; it adds its own (`User-Agent`, and a
    /// `Content-Type` when a body is set).
    headers: []const Label = &.{},
    /// Decoded from the wire's base64.
    body: []const u8 = "",
    auth: HttpAuth = .none,
};

pub const PubsubTarget = struct {
    /// `projects/P/topics/T`.
    topic_name: []const u8,
    /// Decoded from the wire's base64.
    data: []const u8 = "",
    attributes: []const Label = &.{},
};

pub const AppEngineTarget = struct {
    relative_uri: []const u8 = "",
    method: HttpMethod = .unspecified,
    headers: []const Label = &.{},
    /// Decoded from the wire's base64.
    body: []const u8 = "",
    service: []const u8 = "",
    version: []const u8 = "",
    instance: []const u8 = "",
    host: []const u8 = "",
};

/// What the job does when it fires: exactly one of these on the wire.
pub const Target = union(enum) {
    http: HttpTarget,
    pubsub: PubsubTarget,
    app_engine: AppEngineTarget,
    /// A target this library does not know, read back from the server.
    unknown,
};

/// The retry settings, as the server answers them: it fills defaults in
/// (retryCount 0 means Scheduler's own default behavior; durations come
/// as seconds).
pub const RetryConfig = struct {
    retry_count: ?i64 = null,
    max_retry_duration_s: ?f64 = null,
    min_backoff_duration_s: ?f64 = null,
    max_backoff_duration_s: ?f64 = null,
    max_doublings: ?i64 = null,
};

pub const Job = struct {
    /// `projects/P/locations/L/jobs/J`.
    name: []const u8,
    /// The trailing segment of `name`, for display.
    id: []const u8,
    /// The `L` segment of `name`.
    location: []const u8,
    description: []const u8 = "",
    /// The cron line, such as `0 0 1 1 *`.
    schedule: []const u8 = "",
    time_zone: []const u8 = "",
    state: JobState = .unknown,
    /// The last attempt's outcome, null before any attempt (the wire's
    /// status code -1).
    last_attempt: ?LastAttempt = null,
    last_attempt_time: ?std.Io.Timestamp = null,
    /// The next run the server has planned; a paused job has none.
    schedule_time: ?std.Io.Timestamp = null,
    user_update_time: ?std.Io.Timestamp = null,
    /// Seconds; the server answers 180 by default for HTTP targets.
    attempt_deadline_s: ?f64 = null,
    retry: RetryConfig = .{},
    target: Target = .unknown,

    /// Whether a health view shows it red: the job could not be updated,
    /// or its last attempt failed.
    pub fn failing(self: Job) bool {
        if (self.state == .update_failed) return true;
        if (self.last_attempt) |attempt| return attempt.failed();
        return false;
    }

    /// The header named `key` of an HTTP or App Engine target, or null.
    pub fn header(self: Job, key: []const u8) ?[]const u8 {
        const headers = switch (self.target) {
            .http => |t| t.headers,
            .app_engine => |t| t.headers,
            else => return null,
        };
        for (headers) |l| if (std.mem.eql(u8, l.key, key)) return l.value;
        return null;
    }
};

pub const ListJobsOptions = struct {
    /// 0 sends nothing: the server's default is its maximum, 500.
    /// More than 500 is refused before sending, as the server refuses it.
    page_size: u32 = 0,
    page_token: ?[]const u8 = null,
};

pub const JobPage = struct {
    jobs: []const Job,
    /// Null on the last page. "Fewer jobs than requested might be
    /// returned, even if more jobs exist": walk the token, not the
    /// counts. Production says a token is valid for 2 hours.
    next_page_token: ?[]const u8 = null,
};

pub const Location = struct {
    /// `projects/P/locations/L`.
    name: []const u8,
    /// The trailing segment: `us-central1`.
    id: []const u8,
    display_name: []const u8 = "",
    labels: []const Label = &.{},
};

pub const ListLocationsOptions = struct {
    /// 0 for the server's default.
    page_size: u32 = 0,
    page_token: ?[]const u8 = null,
};

pub const LocationPage = struct {
    locations: []const Location,
    /// Null on the last page.
    next_page_token: ?[]const u8 = null,
};

const testing = std.testing;

test "JobState and HttpMethod: wire names, unknown for the rest" {
    try testing.expectEqual(JobState.enabled, JobState.fromWire("ENABLED"));
    try testing.expectEqual(JobState.paused, JobState.fromWire("PAUSED"));
    try testing.expectEqual(JobState.disabled, JobState.fromWire("DISABLED"));
    try testing.expectEqual(JobState.update_failed, JobState.fromWire("UPDATE_FAILED"));
    try testing.expectEqual(JobState.unspecified, JobState.fromWire("STATE_UNSPECIFIED"));
    try testing.expectEqual(JobState.unknown, JobState.fromWire("SLEEPING"));
    try testing.expectEqual(HttpMethod.post, HttpMethod.fromWire("POST"));
    try testing.expectEqual(HttpMethod.options, HttpMethod.fromWire("OPTIONS"));
    try testing.expectEqual(HttpMethod.unspecified, HttpMethod.fromWire("HTTP_METHOD_UNSPECIFIED"));
    try testing.expectEqual(HttpMethod.unknown, HttpMethod.fromWire("BREW"));
}

test "Job.failing and the helpers answer the widget's question" {
    var job: Job = .{ .name = "projects/p/locations/l/jobs/j", .id = "j", .location = "l", .state = .enabled };
    try testing.expect(!job.failing());
    job.last_attempt = .{ .code = 0 };
    try testing.expect(!job.failing());
    job.last_attempt = .{ .code = 2 };
    try testing.expect(job.failing());
    try testing.expect(job.last_attempt.?.failed());
    job.last_attempt = null;
    job.state = .update_failed;
    try testing.expect(job.failing());

    job.target = .{ .http = .{ .uri = "https://x", .headers = &.{.{ .key = "X-Zigps", .value = "probe" }} } };
    try testing.expectEqualStrings("probe", job.header("X-Zigps").?);
    try testing.expectEqual(null, job.header("Other"));
    job.target = .{ .pubsub = .{ .topic_name = "projects/p/topics/t" } };
    try testing.expectEqual(null, job.header("X-Zigps"));
}
