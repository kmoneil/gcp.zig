//! Cloud Scheduler's v1 API: the jobs a project schedules, with their
//! state, target and last attempt, for a health view that shows the
//! failing ones; and three writes a console confirms before sending, run
//! a job now, pause it and resume it, each with a twin that builds the
//! exact request without sending it. Nothing here creates, updates or
//! deletes a job.
//!
//! **Experimental**: new in 0.47.0, and free to change between minor
//! versions until it has been used in anger. The writes are new in
//! 0.51.0.
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
/// What `Client.runJobRequest` and its siblings answer: a write's method,
/// URL and body, built without sending it.
pub const PreparedRequest = core.PreparedRequest;
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

/// What a test of code that reads jobs can stand on, with no network.
/// **Experimental**, as the module is.
pub const testing = struct {
    /// Cloud Scheduler in memory, behind `Client.Options.transport`:
    /// locations and jobs a test puts in, read back as production
    /// answered when measured, refusals in its words. It says so where
    /// it does not model something.
    pub const FakeScheduler = @import("fake_scheduler.zig").FakeScheduler;
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
    _ = @import("fake_scheduler.zig");
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
