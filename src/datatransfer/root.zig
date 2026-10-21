//! BigQuery Data Transfer's v1 API: the transfer configs a project holds
//! (BigQuery's scheduled queries among them), their runs, and a run's
//! messages.
//!
//! **Experimental**: new in 0.56.0, and free to change between minor
//! versions until it has been used in anger.
//!
//! Configs live in a location, and production lists them one location at
//! a time with no value for every one (`-` is refused, measured), so a
//! console walks `listLocations`. Every call about a config or a run takes
//! its name as a list or get gave it, which names the project by number.
//! A client asks for one OAuth scope, `Client.Options.scope`: `bigquery`
//! by default, as `bigquery.Client`'s, so one token serves both modules.

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
pub const Location = @import("types.zig").Location;
pub const LocationPage = @import("types.zig").LocationPage;
pub const TransferState = @import("types.zig").TransferState;
pub const MessageSeverity = @import("types.zig").MessageSeverity;
pub const Status = @import("types.zig").Status;
pub const Schedule = @import("types.zig").Schedule;
pub const Param = @import("types.zig").Param;
pub const ScheduledQuery = @import("types.zig").ScheduledQuery;
pub const TransferConfig = @import("types.zig").TransferConfig;
pub const TransferConfigPage = @import("types.zig").TransferConfigPage;
pub const TransferRun = @import("types.zig").TransferRun;
pub const TransferRunPage = @import("types.zig").TransferRunPage;
pub const TransferMessage = @import("types.zig").TransferMessage;
pub const TransferMessagePage = @import("types.zig").TransferMessagePage;
pub const ListLocationsOptions = @import("types.zig").ListLocationsOptions;
pub const ListConfigsOptions = @import("types.zig").ListConfigsOptions;
pub const ListRunsOptions = @import("types.zig").ListRunsOptions;
pub const ListMessagesOptions = @import("types.zig").ListMessagesOptions;
pub const StartManualRunOptions = @import("types.zig").StartManualRunOptions;
pub const StartedRuns = @import("types.zig").StartedRuns;
/// A request as a call would send it, built without sending it: what
/// `Client.startManualRunRequest` answers.
pub const PreparedRequest = core.PreparedRequest;

/// The fixed limits and naming rules the client checks before sending.
pub const limits = @import("validate.zig");

/// The HTTP seam: implement `transport.Transport` to send requests
/// another way, or to fake the server in your own tests.
pub const transport = core.transport;

/// What a test of code that reads scheduled queries and runs one now can
/// stand on, with no network. **Experimental**, as the module is.
pub const testing = struct {
    /// BigQuery Data Transfer in memory, behind `Client.Options.transport`:
    /// locations, configs, runs and messages a test puts in, and a run now
    /// whose outcome the test says, served as production answered when
    /// measured, refusals in its words. It says so where it does not model
    /// something.
    pub const FakeDataTransfer = @import("fake_datatransfer.zig").FakeDataTransfer;
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
    _ = @import("fake_datatransfer.zig");
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
