//! Data Transfer's values as this library holds them: locations,
//! transfer configs (scheduled queries among them), their runs, and a
//! run's messages. Wire names live in the codec.

const std = @import("std");
const core = @import("core");

pub const Owned = core.Owned;

/// A location configs can live in: `us`, `europe`, or a region such as
/// `us-east1`, as `listLocations` answers them (measured).
pub const Location = struct {
    /// `projects/{p}/locations/{l}`.
    name: []const u8,
    /// `us`, `europe`, `us-east1`: what a list of configs takes.
    id: []const u8,
    display_name: []const u8 = "",
};

pub const LocationPage = struct {
    locations: []const Location,
    /// Null on the last page.
    next_page_token: ?[]const u8 = null,
};

/// The state of a run, and of a config's latest run.
pub const TransferState = enum {
    pending,
    running,
    succeeded,
    failed,
    cancelled,
    /// None given, or a state this library does not know.
    unknown,

    pub fn fromWire(name: []const u8) TransferState {
        inline for (.{
            .{ "PENDING", .pending },
            .{ "RUNNING", .running },
            .{ "SUCCEEDED", .succeeded },
            .{ "FAILED", .failed },
            .{ "CANCELLED", .cancelled },
        }) |entry| {
            if (std.mem.eql(u8, name, entry[0])) return entry[1];
        }
        return .unknown;
    }

    /// The wire name a `states` filter takes; null for `.unknown`.
    pub fn wireName(self: TransferState) ?[]const u8 {
        return switch (self) {
            .pending => "PENDING",
            .running => "RUNNING",
            .succeeded => "SUCCEEDED",
            .failed => "FAILED",
            .cancelled => "CANCELLED",
            .unknown => null,
        };
    }

    /// Whether a run in this state has ended.
    pub fn ended(self: TransferState) bool {
        return self == .succeeded or self == .failed or self == .cancelled;
    }
};

pub const MessageSeverity = enum {
    info,
    warning,
    @"error",
    /// A severity this library does not know.
    unknown,

    pub fn fromWire(name: []const u8) MessageSeverity {
        if (std.mem.eql(u8, name, "INFO")) return .info;
        if (std.mem.eql(u8, name, "WARNING")) return .warning;
        if (std.mem.eql(u8, name, "ERROR")) return .@"error";
        return .unknown;
    }

    /// The wire name a `messageTypes` filter takes; null for `.unknown`.
    pub fn wireName(self: MessageSeverity) ?[]const u8 {
        return switch (self) {
            .info => "INFO",
            .warning => "WARNING",
            .@"error" => "ERROR",
            .unknown => null,
        };
    }
};

/// A `google.rpc.Status`: a run's or a config's error.
pub const Status = struct {
    /// The gRPC code: 3 is INVALID_ARGUMENT, 5 NOT_FOUND, and so on.
    code: i32 = 0,
    message: []const u8 = "",
};

/// When a config runs, from either of the API's two shapes (`schedule`
/// with `scheduleOptions`, or `scheduleOptionsV2`): production answers
/// both for a config made with either (measured).
pub const Schedule = union(enum) {
    /// The data source's default schedule: none given.
    default,
    /// On a schedule, such as `every 24 hours` or `every mon 09:00`, in
    /// UTC, between optional start and end times.
    time_based: TimeBased,
    /// Only when run by hand (`disableAutoScheduling`).
    manual,
    /// When a Pub/Sub subscription has a message.
    event_driven: []const u8,

    pub const TimeBased = struct {
        /// App Engine cron syntax, as given.
        schedule: []const u8,
        start_time: ?std.Io.Timestamp = null,
        end_time: ?std.Io.Timestamp = null,
    };
};

/// One of a config's params: its key, and its value's JSON text, as
/// answered (a string quoted, a number bare).
pub const Param = struct {
    key: []const u8,
    json: []const u8,
};

/// A scheduled query's params, typed.
pub const ScheduledQuery = struct {
    /// GoogleSQL; may use `@run_time` and `@run_date`.
    query: []const u8 = "",
    /// Where results go, such as `sales_{run_date}`; empty for DDL and
    /// DML.
    destination_table_name_template: []const u8 = "",
    /// `WRITE_TRUNCATE` or `WRITE_APPEND`; empty for DDL and DML.
    write_disposition: []const u8 = "",
    partitioning_field: []const u8 = "",
};

pub const TransferConfig = struct {
    /// `projects/{number}/locations/{l}/transferConfigs/{id}`: production
    /// names the project by number (measured). What every call about the
    /// config takes.
    name: []const u8,
    /// From the name.
    location: []const u8,
    /// From the name: a UUID, usually.
    id: []const u8,
    display_name: []const u8 = "",
    /// `scheduled_query`, `google_cloud_storage`, and so on.
    data_source_id: []const u8 = "",
    destination_dataset_id: []const u8 = "",
    /// The destination dataset's region, lower case (`us`, measured).
    dataset_region: []const u8 = "",
    schedule: Schedule = .default,
    /// When it runs next; none for a manual or disabled config.
    next_run_time: ?std.Io.Timestamp = null,
    /// Its latest run's state; `.unknown` before its first.
    state: TransferState = .unknown,
    /// No run is scheduled, and a run now is refused.
    disabled: bool = false,
    update_time: ?std.Io.Timestamp = null,
    /// Whose credentials it runs with. Production gives it on a get, not
    /// in a list (measured).
    owner_email: []const u8 = "",
    params: []const Param = &.{},
    /// The typed params of a config whose data source is
    /// `scheduled_query`.
    scheduled_query: ?ScheduledQuery = null,
    /// Its latest failure, if it has one.
    @"error": ?Status = null,
    notification_topic: []const u8 = "",
    failure_email: bool = false,
};

pub const TransferConfigPage = struct {
    configs: []const TransferConfig,
    /// Null on the last page.
    next_page_token: ?[]const u8 = null,
};

pub const TransferRun = struct {
    /// `.../transferConfigs/{id}/runs/{run}`.
    name: []const u8,
    /// The config's name, from the run's.
    config_name: []const u8,
    /// From the name.
    id: []const u8,
    state: TransferState = .unknown,
    /// When it may start.
    schedule_time: ?std.Io.Timestamp = null,
    /// The moment it runs for: a scheduled query's `@run_time`.
    run_time: ?std.Io.Timestamp = null,
    start_time: ?std.Io.Timestamp = null,
    end_time: ?std.Io.Timestamp = null,
    update_time: ?std.Io.Timestamp = null,
    @"error": ?Status = null,
    data_source_id: []const u8 = "",
    destination_dataset_id: []const u8 = "",
    /// The schedule it ran on; empty for a run started by hand.
    schedule: []const u8 = "",
    params: []const Param = &.{},

    pub fn ended(self: TransferRun) bool {
        return self.state.ended();
    }

    pub fn succeeded(self: TransferRun) bool {
        return self.state == .succeeded;
    }

    pub fn failed(self: TransferRun) bool {
        return self.state == .failed;
    }
};

pub const TransferRunPage = struct {
    runs: []const TransferRun,
    /// Null on the last page.
    next_page_token: ?[]const u8 = null,
};

pub const TransferMessage = struct {
    time: ?std.Io.Timestamp = null,
    severity: MessageSeverity = .unknown,
    text: []const u8 = "",
};

pub const TransferMessagePage = struct {
    messages: []const TransferMessage,
    /// Null on the last page.
    next_page_token: ?[]const u8 = null,
};

pub const ListLocationsOptions = struct {
    /// Production answered every location on one page and refused a page
    /// size (measured), so a list asks none; a token, should it ever page.
    page_token: ?[]const u8 = null,
};

pub const ListConfigsOptions = struct {
    /// Only configs of these data sources, such as `scheduled_query`;
    /// empty for every one.
    data_sources: []const []const u8 = &.{},
    /// 0 for the server's default, 1000.
    page_size: u32 = 0,
    page_token: ?[]const u8 = null,
};

pub const ListRunsOptions = struct {
    /// Only runs in these states; empty for every state.
    states: []const TransferState = &.{},
    /// Only the latest run of each day (`runAttempt=LATEST`); false for
    /// every run, the API's default.
    latest_only: bool = false,
    page_size: u32 = 0,
    page_token: ?[]const u8 = null,
};

/// What `startManualRun` asks.
pub const StartManualRunOptions = struct {
    /// The moment to run for: a scheduled query's `@run_time` and
    /// `@run_date`. Null for now, by the client's `std.Io` clock.
    /// Production took a time 60 s ahead of its own as readily as a past
    /// one (measured), so a clock running ahead is no refusal. Sent to
    /// the microsecond. Give the same time to `startManualRunRequest` and
    /// the call to send exactly what was shown.
    run_time: ?std.Io.Timestamp = null,
};

/// What a run now answers: the runs it started, one for a run now
/// (measured), `PENDING`.
pub const StartedRuns = struct {
    runs: []const TransferRun,
};

pub const ListMessagesOptions = struct {
    /// Only messages of these severities; empty for every one.
    severities: []const MessageSeverity = &.{},
    page_size: u32 = 0,
    page_token: ?[]const u8 = null,
};
