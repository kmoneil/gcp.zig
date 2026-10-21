//! BigQuery's v2 API: the datasets a project holds, their tables with
//! their schemas, and the job history, from the client's own project or
//! any other a caller can read (`bigquery-public-data` among them).
//!
//! **Experimental**: new in 0.55.0, and free to change between minor
//! versions until it has been used in anger.
//!
//! Every read names its project through a ref (`DatasetRef`, `TableRef`,
//! `JobRef`), an empty project being the client's own. A table's schema
//! comes with `getTable`; a list carries less (no schema, no row count),
//! as production sends it. A client asks for one OAuth scope,
//! `Client.Options.scope`: `bigquery` by default. BigQuery has no
//! read-only scope of its own; `cloud-platform.read-only` serves every
//! read here (measured).

pub const Client = @import("Client.zig");

pub const TokenProvider = core.TokenProvider;
pub const StaticToken = core.StaticToken;

/// The OAuth scopes a client can ask for (`Client.Options.scope`).
pub const Scope = @import("rpc.zig").Scope;
/// The default scope's URL, `bigquery`.
pub const auth_scope = @import("rpc.zig").scope;

pub const RetryPolicy = core.RetryPolicy;
pub const Diagnostics = core.Diagnostics;
pub const Error = @import("errors.zig").Error;
pub const ApiError = core.ApiError;

pub const Owned = @import("types.zig").Owned;
pub const Label = @import("types.zig").Label;
pub const DatasetRef = @import("types.zig").DatasetRef;
pub const TableRef = @import("types.zig").TableRef;
pub const JobRef = @import("types.zig").JobRef;
pub const Dataset = @import("types.zig").Dataset;
pub const DatasetPage = @import("types.zig").DatasetPage;
pub const TableType = @import("types.zig").TableType;
pub const FieldType = @import("types.zig").FieldType;
pub const FieldMode = @import("types.zig").FieldMode;
pub const Field = @import("types.zig").Field;
pub const TimePartitioning = @import("types.zig").TimePartitioning;
pub const RangePartitioning = @import("types.zig").RangePartitioning;
pub const MaterializedView = @import("types.zig").MaterializedView;
pub const Table = @import("types.zig").Table;
pub const TablePage = @import("types.zig").TablePage;
pub const JobType = @import("types.zig").JobType;
pub const JobState = @import("types.zig").JobState;
pub const JobError = @import("types.zig").JobError;
pub const Job = @import("types.zig").Job;
pub const JobPage = @import("types.zig").JobPage;
pub const ListOptions = @import("types.zig").ListOptions;
pub const ListDatasetsOptions = @import("types.zig").ListDatasetsOptions;
pub const ListJobsOptions = @import("types.zig").ListJobsOptions;
pub const QueryOptions = @import("types.zig").QueryOptions;
pub const ResultsOptions = @import("types.zig").ResultsOptions;
pub const DryRun = @import("types.zig").DryRun;
pub const QueryPage = @import("types.zig").QueryPage;
/// A request as a call would send it, built without sending it: what
/// `Client.queryRequest` and the other previews answer.
pub const PreparedRequest = core.PreparedRequest;

/// A query's rows, decoded against its schema.
pub const Row = @import("values.zig").Row;
pub const Cell = @import("values.zig").Cell;
pub const Value = @import("values.zig").Value;
pub const Decimal = @import("values.zig").Decimal;
pub const Date = @import("values.zig").Date;
pub const Time = @import("values.zig").Time;
pub const DateTime = @import("values.zig").DateTime;
pub const Interval = @import("values.zig").Interval;
pub const Range = @import("values.zig").Range;
pub const RangeBound = @import("values.zig").RangeBound;
/// Where a query error points, `errorPosition`'s answer.
pub const Position = @import("values.zig").Position;
pub const errorPosition = @import("values.zig").errorPosition;

/// The fixed limits and naming rules the client checks before sending.
pub const limits = @import("validate.zig");

/// The HTTP seam: implement `transport.Transport` to send requests
/// another way, or to fake the server in your own tests.
pub const transport = core.transport;

/// What a test of code that browses datasets and runs queries can stand
/// on, with no network. **Experimental**, as the module is.
pub const testing = struct {
    /// BigQuery in memory, behind `Client.Options.transport`: datasets,
    /// tables and jobs a test puts in, and an answer per query text (no
    /// SQL engine), served as production answered when measured,
    /// refusals in its words. It says so where it does not model
    /// something.
    pub const FakeBigQuery = @import("fake_bigquery.zig").FakeBigQuery;
    /// An `Io` whose clock a test moves.
    pub const FakeClock = core.testing.FakeClock;
};

const core = @import("core");

test {
    _ = @import("production_bodies.zig");
    _ = @import("test_util.zig");
    @import("std").testing.refAllDecls(@This());
    _ = @import("Client.zig");
    _ = @import("codec.zig");
    _ = @import("errors.zig");
    _ = @import("fake_bigquery.zig");
    _ = @import("logging.zig");
    _ = @import("names.zig");
    _ = @import("rpc.zig");
    _ = @import("types.zig");
    _ = @import("validate.zig");
    _ = @import("values.zig");
}

test "every public declaration of types.zig is public here too" {
    inline for (@typeInfo(@import("types.zig")).@"struct".decl_names) |name| {
        if (!@hasDecl(@This(), name)) @compileError("not exported: types." ++ name);
    }
}
