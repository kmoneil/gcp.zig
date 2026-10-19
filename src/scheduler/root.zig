//! Cloud Scheduler's v1 API, read only: the jobs a project schedules,
//! with their state, target and last attempt, for a health view that
//! shows the failing ones. Nothing here creates, changes, runs or
//! deletes a job.
//!
//! **Experimental**: new in 0.47.0, and free to change between minor
//! versions until it has been used in anger.
//!
//! Jobs live under a location, so a reader lists `listLocations` once and
//! `listJobs` per location. `Job.failing` answers the health view's
//! question: the job could not be updated, or its last attempt failed.
//! The one OAuth scope every call takes is `cloud-platform`: Cloud
//! Scheduler defines no narrower one, unlike the other modules' APIs.

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
pub const JobState = @import("types.zig").JobState;
pub const LastAttempt = @import("types.zig").LastAttempt;
pub const HttpMethod = @import("types.zig").HttpMethod;
pub const HttpAuth = @import("types.zig").HttpAuth;
pub const HttpTarget = @import("types.zig").HttpTarget;
pub const PubsubTarget = @import("types.zig").PubsubTarget;
pub const AppEngineTarget = @import("types.zig").AppEngineTarget;
pub const Target = @import("types.zig").Target;
pub const RetryConfig = @import("types.zig").RetryConfig;
pub const Job = @import("types.zig").Job;
pub const ListJobsOptions = @import("types.zig").ListJobsOptions;
pub const JobPage = @import("types.zig").JobPage;
pub const Location = @import("types.zig").Location;
pub const ListLocationsOptions = @import("types.zig").ListLocationsOptions;
pub const LocationPage = @import("types.zig").LocationPage;

/// The fixed limits and naming rules the client checks before sending.
pub const limits = @import("validate.zig");

/// The HTTP seam: implement `transport.Transport` to send requests
/// another way, or to fake the server in your own tests.
pub const transport = core.transport;

const core = @import("core");

test {
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
