//! Dataflow's v1b3 API, read only: the jobs a project runs, across every
//! region in one call or one region at a time, with their states, for a
//! health view's pipelines widget. Nothing here creates, updates,
//! cancels or drains a job, and nothing launches a template.
//!
//! **Experimental**: new in 0.50.0, and free to change between minor
//! versions until it has been used in anger.
//!
//! `Client.aggregatedJobs` is the widget's one call: every region's
//! jobs, each carrying the `location` a `getJob` of it needs, and
//! `failed_locations` naming any region that did not answer, without
//! which a partial page looks complete. `Job.terminal` and
//! `Job.failing` answer the widget's questions; `Client.listMessages`
//! at `.@"error"` answers "why is it red". The OAuth scope is
//! `cloud-platform`: v1b3 has no read-only scope, so what a token may
//! read is IAM's to decide.

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
pub const JobType = @import("types.zig").JobType;
pub const StageState = @import("types.zig").StageState;
pub const Job = @import("types.zig").Job;
pub const Filter = @import("types.zig").Filter;
pub const JobView = @import("types.zig").JobView;
pub const ListJobsOptions = @import("types.zig").ListJobsOptions;
pub const AggregatedOptions = @import("types.zig").AggregatedOptions;
pub const JobPage = @import("types.zig").JobPage;
pub const MessageImportance = @import("types.zig").MessageImportance;
pub const JobMessage = @import("types.zig").JobMessage;
pub const AutoscalingEvent = @import("types.zig").AutoscalingEvent;
pub const ListMessagesOptions = @import("types.zig").ListMessagesOptions;
pub const MessagePage = @import("types.zig").MessagePage;

/// The fixed limits and naming rules the client checks before sending.
pub const limits = @import("validate.zig");

/// What a test of code that reads Dataflow can stand on, with no
/// emulator and no network. **Experimental**, as the module is.
pub const testing = struct {
    /// Dataflow in memory, behind `Client.Options.transport`. It
    /// answers and refuses as production did when measured, and says
    /// so where it does not model something.
    pub const FakeDataflow = @import("fake_dataflow.zig").FakeDataflow;
};

/// The HTTP seam: implement `transport.Transport` to send requests
/// another way, or to fake the server in your own tests.
pub const transport = core.transport;

const core = @import("core");

test {
    _ = @import("Client.zig");
    _ = @import("codec.zig");
    _ = @import("errors.zig");
    _ = @import("fake_dataflow.zig");
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
