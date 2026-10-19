//! Cloud Run's v2 API, read only: the services a project runs and the
//! revisions behind them, with their conditions, for a health view's
//! "recent revisions" widget and a trend chart's deploy markers. Nothing
//! here deploys, routes traffic or deletes anything.
//!
//! **Experimental**: new in 0.48.0, and free to change between minor
//! versions until it has been used in anger.
//!
//! Services live in a location, so a reader lists `listLocations` once
//! (v1's list on the same host: v2 has none) and asks per location, or
//! gives `-` for every region at once, which production answers with
//! `unreachable_regions` for the ones it could not ask. `Service.ready`
//! and `Revision.ready` answer the health view's question; a revision's
//! `create_time` is the deploy marker. The OAuth scope is
//! `run.readonly`, the narrowest every read takes.

pub const Client = @import("Client.zig");

pub const TokenProvider = core.TokenProvider;
pub const StaticToken = core.StaticToken;

pub const auth_scope = @import("rpc.zig").scope;

pub const RetryPolicy = core.RetryPolicy;
pub const Diagnostics = core.Diagnostics;
pub const Error = @import("errors.zig").Error;
pub const ApiError = core.ApiError;

pub const Owned = @import("types.zig").Owned;
pub const Label = @import("types.zig").Label;
pub const ConditionState = @import("types.zig").ConditionState;
pub const ConditionSeverity = @import("types.zig").ConditionSeverity;
pub const Condition = @import("types.zig").Condition;
pub const TrafficType = @import("types.zig").TrafficType;
pub const TrafficTarget = @import("types.zig").TrafficTarget;
pub const Container = @import("types.zig").Container;
pub const Service = @import("types.zig").Service;
pub const Revision = @import("types.zig").Revision;
pub const ListOptions = @import("types.zig").ListOptions;
pub const ServicePage = @import("types.zig").ServicePage;
pub const RevisionPage = @import("types.zig").RevisionPage;
pub const Location = @import("types.zig").Location;
pub const LocationPage = @import("types.zig").LocationPage;

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
