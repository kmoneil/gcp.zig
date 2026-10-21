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

/// The fixed limits and naming rules the client checks before sending.
pub const limits = @import("validate.zig");

/// The HTTP seam: implement `transport.Transport` to send requests
/// another way, or to fake the server in your own tests.
pub const transport = core.transport;

const core = @import("core");

test {
    _ = @import("production_bodies.zig");
    _ = @import("test_util.zig");
    @import("std").testing.refAllDecls(@This());
    _ = @import("Client.zig");
    _ = @import("codec.zig");
    _ = @import("errors.zig");
    _ = @import("logging.zig");
    _ = @import("names.zig");
    _ = @import("rpc.zig");
    _ = @import("types.zig");
    _ = @import("validate.zig");
}

test "every public declaration of types.zig is public here too" {
    inline for (@typeInfo(@import("types.zig")).@"struct".decl_names) |name| {
        if (!@hasDecl(@This(), name)) @compileError("not exported: types." ++ name);
    }
}
