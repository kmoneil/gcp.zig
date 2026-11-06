//! Service Usage's v1 API, read only: which services (APIs) a project has
//! enabled, every enabled one at once or a page at a time, and whether
//! one service, or up to 30 at once, is enabled: what a panel that says
//! an API is off asks after a call fails because it is.
//!
//! **Experimental**: new in 0.69.0, and free to change between minor
//! versions until it has been used in anger.
//!
//! Every call asks for only the name, title, summary and state of each
//! service (a `fields` mask): a service's whole configuration is large
//! (Compute Engine's was 1.39 MB, measured). A client asks for one OAuth
//! scope, `Client.Options.scope`: `cloud-platform.read-only` by default,
//! or `cloud-platform`; production takes no other.

pub const Client = @import("Client.zig");

pub const TokenProvider = core.TokenProvider;
pub const StaticToken = core.StaticToken;

/// The OAuth scopes a client can ask for (`Client.Options.scope`).
pub const Scope = @import("rpc.zig").Scope;
/// The default scope's URL, `cloud-platform.read-only`.
pub const auth_scope = @import("rpc.zig").scope;

pub const RetryPolicy = core.RetryPolicy;
pub const Diagnostics = core.Diagnostics;
pub const Error = @import("errors.zig").Error;
pub const ApiError = core.ApiError;

pub const Owned = @import("types.zig").Owned;
pub const State = @import("types.zig").State;
pub const Service = @import("types.zig").Service;
pub const StateFilter = @import("types.zig").StateFilter;
pub const ListServicesOptions = @import("types.zig").ListServicesOptions;
pub const ServicePage = @import("types.zig").ServicePage;

/// The fixed limits and naming rules the client checks before sending.
pub const limits = @import("validate.zig");

/// The HTTP seam: implement `transport.Transport` to send requests
/// another way, or to fake the server in your own tests.
pub const transport = core.transport;

/// What a test of code that asks which APIs are on can stand on, with no
/// network. **Experimental**, as the module is.
pub const testing = struct {
    /// Service Usage in memory, behind `Client.Options.transport`: the
    /// services a test puts in, each enabled or not, listed, read and
    /// batched as production answered when measured, refusals in its
    /// words. It says so where it does not model something.
    pub const FakeServiceUsage = @import("fake_service_usage.zig").FakeServiceUsage;
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
    _ = @import("fake_service_usage.zig");
    _ = @import("logging.zig");
    _ = @import("rpc.zig");
    _ = @import("types.zig");
    _ = @import("validate.zig");
}

test "every public declaration of types.zig is public here too" {
    inline for (@typeInfo(@import("types.zig")).@"struct".decl_names) |name| {
        if (!@hasDecl(@This(), name)) @compileError("not exported: types." ++ name);
    }
}
