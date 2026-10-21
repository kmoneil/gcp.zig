//! BigQuery's values as this library holds them: datasets, tables with
//! their schemas, and jobs. Wire names live in the codec. The schemas are
//! large; these types keep what a console's browser and job history show,
//! plus what identifies trouble, and the decode skips the rest.

const std = @import("std");
const core = @import("core");
const values = @import("values.zig");

pub const Owned = core.Owned;

pub const Label = struct {
    key: []const u8,
    value: []const u8,
};

/// A dataset, by project and id. An empty project is the client's own.
pub const DatasetRef = struct {
    project: []const u8 = "",
    dataset: []const u8,
};

/// A table, by project, dataset and id. An empty project is the client's
/// own.
pub const TableRef = struct {
    project: []const u8 = "",
    dataset: []const u8,
    table: []const u8,
};

/// A job, by project, id and location. An empty project is the client's
/// own; an empty location is left out of the request, which production
/// answers for a job in the US (measured), not for one in a single region.
pub const JobRef = struct {
    project: []const u8 = "",
    id: []const u8,
    location: []const u8 = "",
};

pub const Dataset = struct {
    /// As the server names it; the project is always filled in.
    ref: DatasetRef,
    friendly_name: []const u8 = "",
    description: []const u8 = "",
    labels: []const Label = &.{},
    /// `US`, `EU`, or a region such as `us-central1`. Tables inherit it.
    location: []const u8 = "",
    creation_time: ?std.Io.Timestamp = null,
    last_modified_time: ?std.Io.Timestamp = null,
    default_table_expiration_ms: ?i64 = null,
    default_partition_expiration_ms: ?i64 = null,
    /// `DEFAULT` for one of the project's own; `PUBLIC`, `LINKED` and
    /// others name other kinds, as the server sends them.
    type: []const u8 = "",
};

pub const DatasetPage = struct {
    /// What a list carries of each: the reference, friendly name, labels,
    /// location and type (measured).
    datasets: []const Dataset,
    /// Null on the last page.
    next_page_token: ?[]const u8 = null,
    /// Locations the server could not ask.
    unreachable_locations: []const []const u8 = &.{},
};

pub const TableType = enum {
    table,
    view,
    materialized_view,
    external,
    snapshot,
    /// A type this library does not know, read back from the server.
    unknown,

    pub fn fromWire(name: []const u8) TableType {
        inline for (.{
            .{ "TABLE", .table },
            .{ "VIEW", .view },
            .{ "MATERIALIZED_VIEW", .materialized_view },
            .{ "EXTERNAL", .external },
            .{ "SNAPSHOT", .snapshot },
        }) |entry| {
            if (std.mem.eql(u8, name, entry[0])) return entry[1];
        }
        return .unknown;
    }
};

/// A column's type. Production writes the legacy names (`INTEGER`,
/// `FLOAT`, `BOOLEAN`, `RECORD`) in results and in tables alike
/// (measured); both spellings decode.
pub const FieldType = enum {
    string,
    bytes,
    int64,
    float64,
    numeric,
    bignumeric,
    boolean,
    timestamp,
    date,
    time,
    datetime,
    geography,
    json,
    interval,
    range,
    record,
    /// A type this library does not know, read back from the server.
    unknown,

    pub fn fromWire(name: []const u8) FieldType {
        inline for (.{
            .{ "STRING", .string },
            .{ "BYTES", .bytes },
            .{ "INTEGER", .int64 },
            .{ "INT64", .int64 },
            .{ "FLOAT", .float64 },
            .{ "FLOAT64", .float64 },
            .{ "NUMERIC", .numeric },
            .{ "DECIMAL", .numeric },
            .{ "BIGNUMERIC", .bignumeric },
            .{ "BIGDECIMAL", .bignumeric },
            .{ "BOOLEAN", .boolean },
            .{ "BOOL", .boolean },
            .{ "TIMESTAMP", .timestamp },
            .{ "DATE", .date },
            .{ "TIME", .time },
            .{ "DATETIME", .datetime },
            .{ "GEOGRAPHY", .geography },
            .{ "JSON", .json },
            .{ "INTERVAL", .interval },
            .{ "RANGE", .range },
            .{ "RECORD", .record },
            .{ "STRUCT", .record },
        }) |entry| {
            if (std.mem.eql(u8, name, entry[0])) return entry[1];
        }
        return .unknown;
    }
};

pub const FieldMode = enum {
    nullable,
    required,
    repeated,
    /// A mode this library does not know, read back from the server.
    unknown,

    pub fn fromWire(name: []const u8) FieldMode {
        if (std.mem.eql(u8, name, "NULLABLE")) return .nullable;
        if (std.mem.eql(u8, name, "REQUIRED")) return .required;
        if (std.mem.eql(u8, name, "REPEATED")) return .repeated;
        return .unknown;
    }
};

/// One column of a schema, or one field of a record.
pub const Field = struct {
    name: []const u8,
    type: FieldType = .unknown,
    /// The wire's name for the type, kept for one this library does not
    /// know.
    type_name: []const u8 = "",
    mode: FieldMode = .nullable,
    /// A record's fields, in order.
    fields: []const Field = &.{},
    /// A RANGE's element type: `.date`, `.datetime` or `.timestamp`.
    range_element: ?FieldType = null,
    description: []const u8 = "",
    precision: ?i64 = null,
    scale: ?i64 = null,
    max_length: ?i64 = null,
};

pub const TimePartitioning = struct {
    /// `DAY`, `HOUR`, `MONTH` or `YEAR`.
    type: []const u8 = "",
    /// The column, or empty for the `_PARTITIONTIME` pseudo column.
    field: []const u8 = "",
    expiration_ms: ?i64 = null,
};

pub const RangePartitioning = struct {
    field: []const u8 = "",
    start: i64 = 0,
    /// Exclusive.
    end: i64 = 0,
    interval: i64 = 0,
};

pub const MaterializedView = struct {
    query: []const u8 = "",
    enable_refresh: bool = true,
    refresh_interval_ms: ?i64 = null,
    last_refresh_time: ?std.Io.Timestamp = null,
};

pub const Table = struct {
    /// As the server names it; the project is always filled in.
    ref: TableRef,
    type: TableType = .table,
    /// Empty in a list, which carries no schema (measured).
    schema: []const Field = &.{},
    /// Null in a list. A view reads 0 (measured).
    num_rows: ?u64 = null,
    num_bytes: ?u64 = null,
    time_partitioning: ?TimePartitioning = null,
    range_partitioning: ?RangePartitioning = null,
    /// Clustering columns, in order.
    clustering: []const []const u8 = &.{},
    require_partition_filter: bool = false,
    /// A view's query, or null for anything else.
    view_query: ?[]const u8 = null,
    view_uses_legacy_sql: bool = false,
    materialized_view: ?MaterializedView = null,
    friendly_name: []const u8 = "",
    description: []const u8 = "",
    labels: []const Label = &.{},
    location: []const u8 = "",
    creation_time: ?std.Io.Timestamp = null,
    last_modified_time: ?std.Io.Timestamp = null,
    expiration_time: ?std.Io.Timestamp = null,
};

pub const TablePage = struct {
    /// What a list carries of each: the reference, type, partitioning,
    /// clustering, creation and expiration times; no schema, no row count
    /// (measured).
    tables: []const Table,
    /// Null on the last page.
    next_page_token: ?[]const u8 = null,
    /// How many tables the dataset holds, when the server says.
    total_items: ?u32 = null,
};

pub const JobType = enum {
    query,
    load,
    extract,
    copy,
    /// A type this library does not know, or none sent.
    unknown,

    pub fn fromWire(name: []const u8) JobType {
        if (std.mem.eql(u8, name, "QUERY")) return .query;
        if (std.mem.eql(u8, name, "LOAD")) return .load;
        if (std.mem.eql(u8, name, "EXTRACT")) return .extract;
        if (std.mem.eql(u8, name, "COPY")) return .copy;
        return .unknown;
    }
};

pub const JobState = enum {
    pending,
    running,
    done,
    /// A state this library does not know, read back from the server.
    unknown,

    pub fn fromWire(name: []const u8) JobState {
        if (std.ascii.eqlIgnoreCase(name, "PENDING")) return .pending;
        if (std.ascii.eqlIgnoreCase(name, "RUNNING")) return .running;
        if (std.ascii.eqlIgnoreCase(name, "DONE")) return .done;
        return .unknown;
    }

    /// The name `jobs.list`'s `stateFilter` takes.
    pub fn filterName(self: JobState) ?[]const u8 {
        return switch (self) {
            .pending => "pending",
            .running => "running",
            .done => "done",
            .unknown => null,
        };
    }
};

/// One of a job's errors, or its final one.
pub const JobError = struct {
    /// `invalidQuery`, `bytesBilledLimitExceeded`, `stopped` for a
    /// cancelled job, and the rest of BigQuery's reasons.
    reason: []const u8 = "",
    /// Where it occurred, when the server says: `q` for the query text.
    location: []const u8 = "",
    message: []const u8 = "",
};

pub const Job = struct {
    /// The project and location are always filled in.
    ref: JobRef,
    type: JobType = .unknown,
    state: JobState = .unknown,
    /// The final error: set only once the job is done and failed. A
    /// cancelled job's reason is `stopped` (measured).
    @"error": ?JobError = null,
    /// The first errors or warnings met; not necessarily a failure.
    errors: []const JobError = &.{},
    /// A query job's text; absent from a list asked with the minimal
    /// projection, which this library never asks.
    query: []const u8 = "",
    /// A dry run, which production never lists (measured).
    dry_run: bool = false,
    /// `SELECT`, `INSERT`, `CREATE_TABLE_AS_SELECT` and the rest.
    statement_type: []const u8 = "",
    total_bytes_processed: ?u64 = null,
    total_bytes_billed: ?u64 = null,
    cache_hit: ?bool = null,
    num_dml_affected_rows: ?u64 = null,
    creation_time: ?std.Io.Timestamp = null,
    start_time: ?std.Io.Timestamp = null,
    end_time: ?std.Io.Timestamp = null,
    /// Who ran it.
    user_email: []const u8 = "",
    labels: []const Label = &.{},

    /// Done without an error.
    pub fn succeeded(self: Job) bool {
        return self.state == .done and self.@"error" == null;
    }

    /// Done with an error, a cancel's `stopped` included.
    pub fn failed(self: Job) bool {
        return self.state == .done and self.@"error" != null;
    }
};

pub const JobPage = struct {
    /// Newest first, as production lists them (measured).
    jobs: []const Job,
    /// Null on the last page.
    next_page_token: ?[]const u8 = null,
    unreachable_locations: []const []const u8 = &.{},
};

pub const ListOptions = struct {
    /// 0 for the server's default.
    page_size: u32 = 0,
    page_token: ?[]const u8 = null,
};

pub const ListDatasetsOptions = struct {
    /// Another project's, such as `bigquery-public-data`; empty for the
    /// client's own.
    project: []const u8 = "",
    /// Hidden datasets too.
    all: bool = false,
    /// `labels.<key>[:<value>]`, several joined by spaces, as BigQuery
    /// takes them.
    label_filter: ?[]const u8 = null,
    page_size: u32 = 0,
    page_token: ?[]const u8 = null,
};

pub const ListJobsOptions = struct {
    /// Another project's; empty for the client's own.
    project: []const u8 = "",
    /// Every user's jobs, not only the caller's: listing them needs
    /// `bigquery.jobs.list` (others' redacted) or `bigquery.jobs.listAll`.
    all_users: bool = false,
    /// Jobs in any of these states; empty for every state.
    states: []const JobState = &.{},
    /// Jobs created at or after it.
    min_creation_time: ?std.Io.Timestamp = null,
    /// Jobs created at or before it.
    max_creation_time: ?std.Io.Timestamp = null,
    page_size: u32 = 0,
    page_token: ?[]const u8 = null,
};

/// What `dryRun` and `query` ask. Every query this library sends is
/// GoogleSQL: it sends `useLegacySql` false, BigQuery's default being
/// legacy SQL still.
pub const QueryOptions = struct {
    /// The GoogleSQL text: UTF-8, and not empty.
    query: []const u8,
    /// The most the query may bill: one that would bill more fails,
    /// billing nothing, `error.BytesBilledLimitExceeded`. Null for the
    /// project's default. A query that reads a table bills at least 10 MiB
    /// (10,485,760 bytes), so a lower limit refuses every such query
    /// (measured); a query of literals alone billed 0.
    maximum_bytes_billed: ?u64 = null,
    /// Where the job runs: `US`, `EU` or a region. Empty lets BigQuery
    /// choose from the tables the query reads.
    location: []const u8 = "",
    /// The dataset unqualified table names resolve in.
    default_dataset: ?DatasetRef = null,
    /// False to run the query even when the same one ran recently and an
    /// answer is cached, which bills nothing.
    use_query_cache: bool = true,
    /// How long `query` holds the call for the job to finish before
    /// answering it incomplete. Production returns after about 200 s,
    /// whatever this asks. `dryRun` ignores it.
    timeout_ms: u32 = 10_000,
    /// Rows on the first page: null for as many as fit in production's
    /// 10 MB, 0 for none. `dryRun` ignores it.
    page_size: ?u32 = null,
    /// The job's labels: keys and values of lowercase letters, digits, _
    /// and -, at most 63 characters, a key starting with a letter; at
    /// most 64 of them.
    labels: []const Label = &.{},
    /// Makes a repeat of the same query, within 15 minutes, answer the
    /// first job rather than run it again: at most 36 ASCII characters.
    /// Null: `query` makes one, a UUID, for the call, so its own retries
    /// are safe. Give one (`Client.newRequestId`) to make a repeat of your
    /// own safe too, or to send exactly what `queryRequest` showed. `dryRun`
    /// ignores it: production never takes a dry run as a repeat.
    request_id: ?[]const u8 = null,
};

/// What `getQueryResults` asks.
pub const ResultsOptions = struct {
    page_token: ?[]const u8 = null,
    /// Rows on the page: null for as many as fit in production's 10 MB,
    /// 0 for none, to wait for the job without reading rows, as Google's
    /// clients do.
    page_size: ?u32 = null,
    /// How long the call is held for a job that has not finished: about
    /// this long (measured), and production returns after about 200 s
    /// whatever this asks.
    timeout_ms: u32 = 10_000,
    /// The first row to read, from 0, to jump into the results; not with
    /// `page_token`.
    start_index: ?u64 = null,
};

/// What a dry run says of a query, without running it.
pub const DryRun = struct {
    /// The bytes the query would read. What it would bill is at least
    /// 10 MiB for a query that reads a table, and 0 from the cache.
    total_bytes_processed: ?u64 = null,
    total_bytes_billed: ?u64 = null,
    cache_hit: ?bool = null,
    /// The columns it would answer.
    schema: []const Field = &.{},
    /// `SELECT`, `INSERT`, `CREATE_TABLE` and the like.
    statement_type: []const u8 = "",
    location: []const u8 = "",
};

/// A query's answer, or one page of its results.
pub const QueryPage = struct {
    /// The job, to read more pages of and to cancel. Null only for a
    /// query production answered without making one.
    job: ?JobRef = null,
    query_id: []const u8 = "",
    /// False: the job has not finished, and the page has no schema and
    /// no rows. Ask `getQueryResults` again.
    complete: bool = false,
    schema: []const Field = &.{},
    rows: []const values.Row = &.{},
    /// Every row the query answered, across all pages.
    total_rows: ?u64 = null,
    /// Null on the last page.
    page_token: ?[]const u8 = null,
    total_bytes_processed: ?u64 = null,
    total_bytes_billed: ?u64 = null,
    cache_hit: ?bool = null,
    /// On the first page only.
    statement_type: []const u8 = "",
    num_dml_affected_rows: ?u64 = null,
    /// Errors that did not stop the query, if any.
    errors: []const JobError = &.{},
};

const testing = std.testing;

test "enum wires both ways, both spellings, unknown for the rest" {
    try testing.expectEqual(FieldType.int64, FieldType.fromWire("INTEGER"));
    try testing.expectEqual(FieldType.int64, FieldType.fromWire("INT64"));
    try testing.expectEqual(FieldType.float64, FieldType.fromWire("FLOAT"));
    try testing.expectEqual(FieldType.float64, FieldType.fromWire("FLOAT64"));
    try testing.expectEqual(FieldType.boolean, FieldType.fromWire("BOOLEAN"));
    try testing.expectEqual(FieldType.boolean, FieldType.fromWire("BOOL"));
    try testing.expectEqual(FieldType.record, FieldType.fromWire("RECORD"));
    try testing.expectEqual(FieldType.record, FieldType.fromWire("STRUCT"));
    try testing.expectEqual(FieldType.numeric, FieldType.fromWire("DECIMAL"));
    try testing.expectEqual(FieldType.bignumeric, FieldType.fromWire("BIGDECIMAL"));
    try testing.expectEqual(FieldType.range, FieldType.fromWire("RANGE"));
    try testing.expectEqual(FieldType.interval, FieldType.fromWire("INTERVAL"));
    try testing.expectEqual(FieldType.unknown, FieldType.fromWire("UUID"));
    try testing.expectEqual(FieldMode.repeated, FieldMode.fromWire("REPEATED"));
    try testing.expectEqual(FieldMode.unknown, FieldMode.fromWire("OPTIONAL"));
    try testing.expectEqual(TableType.materialized_view, TableType.fromWire("MATERIALIZED_VIEW"));
    try testing.expectEqual(TableType.unknown, TableType.fromWire("CLONE"));
    try testing.expectEqual(JobState.done, JobState.fromWire("DONE"));
    try testing.expectEqual(JobState.running, JobState.fromWire("running"));
    try testing.expectEqual(JobState.unknown, JobState.fromWire("QUEUED"));
    try testing.expectEqualStrings("done", JobState.done.filterName().?);
    try testing.expectEqual(null, JobState.unknown.filterName());
    try testing.expectEqual(JobType.query, JobType.fromWire("QUERY"));
    try testing.expectEqual(JobType.unknown, JobType.fromWire(""));
}

test "Job.succeeded and failed read the state and the final error" {
    var job: Job = .{ .ref = .{ .project = "p", .id = "j", .location = "US" } };
    try testing.expect(!job.succeeded() and !job.failed());
    job.state = .running;
    try testing.expect(!job.succeeded() and !job.failed());
    job.state = .done;
    try testing.expect(job.succeeded() and !job.failed());
    job.@"error" = .{ .reason = "stopped", .message = "Job execution was cancelled: User requested cancellation" };
    try testing.expect(!job.succeeded() and job.failed());
}
