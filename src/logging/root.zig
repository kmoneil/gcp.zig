//! Cloud Logging v2 REST client, the read side.
//!
//! `Client` holds the configuration, the connection pool and the read
//! budget. `Client.query` fixes one `entries.list` request, and
//! `Query.page` fetches its pages, one per call: an empty page with a token
//! is an ordinary answer, and only a null token ends a listing. Entries
//! carry their envelope typed and their payload as JSON bytes.
//!
//! There is no emulator and no unauthenticated mode: every client needs a
//! `TokenProvider`, which the `auth` module supplies.

const core = @import("core");

pub const Client = @import("Client.zig");
pub const Query = @import("Query.zig");
pub const ReadBudget = @import("budget.zig").ReadBudget;

pub const TokenProvider = core.TokenProvider;
pub const StaticToken = core.StaticToken;
/// The OAuth scope the client requests from its `TokenProvider`: read only.
pub const auth_scope = @import("rpc.zig").scope;

pub const RetryPolicy = core.RetryPolicy;
pub const Diagnostics = core.Diagnostics;
pub const Error = @import("errors.zig").Error;
pub const ApiError = core.ApiError;

pub const Owned = @import("types.zig").Owned;
pub const Label = @import("types.zig").Label;
pub const Parent = @import("types.zig").Parent;
pub const BucketName = @import("types.zig").BucketName;
pub const ViewName = @import("types.zig").ViewName;
pub const Scope = @import("types.zig").Scope;
pub const Order = @import("types.zig").Order;
pub const Severity = @import("types.zig").Severity;
pub const Payload = @import("types.zig").Payload;
pub const HttpRequest = @import("types.zig").HttpRequest;
pub const Operation = @import("types.zig").Operation;
pub const SourceLocation = @import("types.zig").SourceLocation;
pub const Split = @import("types.zig").Split;
pub const Entry = @import("types.zig").Entry;
pub const QueryOptions = @import("types.zig").QueryOptions;
pub const EntryPage = @import("types.zig").EntryPage;
pub const ReadStatus = @import("types.zig").ReadStatus;

/// Parses an entry's `timestamp` (RFC 3339) to nanoseconds since the Unix
/// epoch.
pub const parseTimestamp = core.timestamp.parse;

/// The fixed API limits and naming rules the client checks before sending.
pub const limits = @import("validate.zig");

/// The HTTP seam: implement `transport.Transport` to send requests another
/// way, or to fake the server in your own tests.
pub const transport = core.transport;

/// What a test of code that reads logs can stand on, with no emulator and
/// no network. **Experimental**: new in 0.39.0, and free to change between
/// minor versions until it has been used for a while.
pub const testing = struct {
    /// Cloud Logging in memory, behind `Client.Options.transport`: entries
    /// a test writes, listed, ordered, paged and filtered as the API does,
    /// late arrivals and the server running out of time included. It says
    /// so where it does not model something.
    pub const FakeLogging = @import("fake_logging.zig").FakeLogging;
    /// An `Io` whose clock a test moves, for late arrivals, token lifetimes
    /// and the read budget's minute.
    pub const FakeClock = core.testing.FakeClock;
};

test {
    @import("std").testing.refAllDecls(@This());
    _ = @import("Client.zig");
    _ = @import("Query.zig");
    _ = @import("budget.zig");
    _ = @import("codec.zig");
    _ = @import("errors.zig");
    _ = @import("fake_filter.zig");
    _ = @import("fake_logging.zig");
    _ = @import("filter.zig");
    _ = @import("log.zig");
    _ = @import("names.zig");
    _ = @import("production_bodies.zig");
    _ = @import("rpc.zig");
    _ = @import("test_util.zig");
    _ = @import("types.zig");
    _ = @import("validate.zig");
}

test "every public declaration of types.zig is public here too" {
    inline for (@typeInfo(@import("types.zig")).@"struct".decl_names) |name| {
        if (!@hasDecl(@This(), name)) @compileError("not exported: types." ++ name);
    }
}
