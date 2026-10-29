//! Cloud Error Reporting v1beta1 REST client, the read side: error groups,
//! their counts and events, and a group's status, for a dashboard.
//!
//! `Client.groupStats` lists what each group's errors in a period came to,
//! with timed counts for a trend chart; `Client.events` lists one group's
//! errors with their stack traces; `Client.group(id)` reads a group, the
//! only way to see a muted one, and sets its status. Counts are estimates:
//! Error Reporting samples. Data is kept 30 days. No errors are reported:
//! this module reads them.
//!
//! The per-user quota is 60 calls a minute, so a client counts its calls
//! and refuses one past the count at once, saying how long to wait. There
//! is no emulator and no unauthenticated mode: every client needs a
//! `TokenProvider`, which the `auth` module supplies.

const core = @import("core");

pub const Client = @import("Client.zig");
pub const GroupRef = Client.GroupRef;
pub const Query = @import("query.zig").Query;
pub const GroupStatsQuery = Query(GroupStats);
pub const EventQuery = Query(Event);
pub const Budget = @import("budget.zig").Budget;

pub const TokenProvider = core.TokenProvider;
pub const StaticToken = core.StaticToken;
/// The OAuth scope the client requests from its `TokenProvider`.
pub const auth_scope = @import("rpc.zig").scope;

pub const RetryPolicy = core.RetryPolicy;
pub const Diagnostics = core.Diagnostics;
pub const Error = @import("errors.zig").Error;
pub const ApiError = core.ApiError;

pub const Owned = @import("types.zig").Owned;
pub const Period = @import("types.zig").Period;
pub const Order = @import("types.zig").Order;
pub const Alignment = @import("types.zig").Alignment;
pub const Status = @import("types.zig").Status;
pub const ServiceFilter = @import("types.zig").ServiceFilter;
pub const ServiceContext = @import("types.zig").ServiceContext;
pub const GroupStatsOptions = @import("types.zig").GroupStatsOptions;
pub const EventsOptions = @import("types.zig").EventsOptions;
pub const TrackingIssue = @import("types.zig").TrackingIssue;
pub const Group = @import("types.zig").Group;
pub const HttpRequest = @import("types.zig").HttpRequest;
pub const SourceLocation = @import("types.zig").SourceLocation;
pub const SourceReference = @import("types.zig").SourceReference;
pub const ErrorContext = @import("types.zig").ErrorContext;
pub const Event = @import("types.zig").Event;
pub const TimedCount = @import("types.zig").TimedCount;
pub const GroupStats = @import("types.zig").GroupStats;
pub const Page = @import("types.zig").Page;
pub const GroupStatsPage = @import("types.zig").GroupStatsPage;
pub const EventPage = @import("types.zig").EventPage;
pub const ConsumerRefusal = @import("types.zig").ConsumerRefusal;
pub const BudgetStatus = @import("types.zig").BudgetStatus;
/// A stack trace's first line, which names the exception and its message.
pub const headlineOf = @import("types.zig").headlineOf;

/// The fixed limits and naming rules the client checks before sending.
pub const limits = @import("validate.zig");

/// The HTTP seam: implement `transport.Transport` to send requests another
/// way, or to fake the server in your own tests.
pub const transport = core.transport;

/// What a test of code that reads errors can stand on, with no emulator and
/// no network.
pub const testing = struct {
    /// Cloud Error Reporting in memory, behind `Client.Options.transport`:
    /// errors a test reports, grouped, counted in buckets, listed and read
    /// as production answered, statuses and refusals included. It says so
    /// where it does not model something.
    pub const FakeErrorReporting = @import("fake_error_reporting.zig").FakeErrorReporting;
    /// An `Io` whose clock a test moves, for periods, buckets and the
    /// budget's minute.
    pub const FakeClock = core.testing.FakeClock;
};

test {
    @import("std").testing.refAllDecls(@This());
    _ = @import("Client.zig");
    _ = @import("budget.zig");
    _ = @import("codec.zig");
    _ = @import("errors.zig");
    _ = @import("fake_error_reporting.zig");
    _ = @import("logging.zig");
    _ = @import("query.zig");
    _ = @import("rpc.zig");
    _ = @import("types.zig");
    _ = @import("validate.zig");
}
