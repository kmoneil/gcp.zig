//! Cloud Run's v2 API: the services a project runs and the revisions
//! behind them, with their conditions, for a health view's "recent
//! revisions" widget and a trend chart's deploy markers; the jobs it
//! runs, with their executions; and three writes a console confirms
//! before sending, each with a twin that builds its exact request: run a
//! job, cancel an execution, send all of a service's traffic to one
//! revision. `Client.getServiceIamPolicy` and its siblings read a
//! service's or a job's IAM policy and test the caller's permissions.
//! Nothing here deploys, creates or deletes anything.
//!
//! **Experimental**: new in 0.48.0, and free to change between minor
//! versions until it has been used in anger. Jobs, executions,
//! operations and the writes are new in 0.54.0 and carry their own
//! marker.
//!
//! Services live in a location, so a reader lists `listLocations` once
//! (v1's list on the same host: v2 has none) and asks per location, or
//! gives `-` for every region at once, which production answers with
//! `unreachable_regions` for the ones it could not ask. Jobs are listed
//! one region at a time: production refuses `-` for them. `Service.ready`
//! and `Revision.ready` answer the health view's question; a revision's
//! `create_time` is the deploy marker; `Execution.status` says where a
//! run stands. A client asks for one OAuth scope, `Client.Options.scope`:
//! `run.readonly` by default, the narrowest every read takes, and
//! `.read_write` for the writes, which production refuses to
//! `run.readonly`.

pub const Client = @import("Client.zig");

pub const TokenProvider = core.TokenProvider;
pub const StaticToken = core.StaticToken;

/// The OAuth scopes a client can ask for (`Client.Options.scope`).
pub const Scope = @import("rpc.zig").Scope;
/// The default scope's URL, `run.readonly`.
pub const auth_scope = @import("rpc.zig").scope;

pub const RetryPolicy = core.RetryPolicy;
/// IAM policies as services and jobs read them: `Policy`, `Binding`, and
/// `Policy.grants`.
pub const iam = core.iam;
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
pub const EnvVar = @import("types.zig").EnvVar;
pub const SecretRef = @import("types.zig").SecretRef;
pub const Resources = @import("types.zig").Resources;
pub const Port = @import("types.zig").Port;
pub const VolumeMount = @import("types.zig").VolumeMount;
pub const Volume = @import("types.zig").Volume;
pub const SecretVolume = @import("types.zig").SecretVolume;
pub const SecretItem = @import("types.zig").SecretItem;
pub const EmptyDir = @import("types.zig").EmptyDir;
pub const CloudSql = @import("types.zig").CloudSql;
pub const GcsVolume = @import("types.zig").GcsVolume;
pub const NfsVolume = @import("types.zig").NfsVolume;
pub const Egress = @import("types.zig").Egress;
pub const VpcAccess = @import("types.zig").VpcAccess;
pub const NetworkInterface = @import("types.zig").NetworkInterface;
pub const ExecutionEnvironment = @import("types.zig").ExecutionEnvironment;
pub const Ingress = @import("types.zig").Ingress;
pub const ScalingMode = @import("types.zig").ScalingMode;
pub const ServiceScaling = @import("types.zig").ServiceScaling;
pub const RevisionTemplate = @import("types.zig").RevisionTemplate;
pub const Service = @import("types.zig").Service;
pub const Revision = @import("types.zig").Revision;
pub const ListOptions = @import("types.zig").ListOptions;
pub const ServicePage = @import("types.zig").ServicePage;
pub const RevisionPage = @import("types.zig").RevisionPage;
pub const Location = @import("types.zig").Location;
pub const LocationPage = @import("types.zig").LocationPage;
/// Jobs, executions and operations: **Experimental** on their own, new
/// in 0.54.0.
pub const ExecutionStatus = @import("types.zig").ExecutionStatus;
pub const ExecutionReference = @import("types.zig").ExecutionReference;
pub const Job = @import("types.zig").Job;
pub const JobPage = @import("types.zig").JobPage;
pub const Execution = @import("types.zig").Execution;
pub const ExecutionPage = @import("types.zig").ExecutionPage;
pub const Operation = @import("types.zig").Operation;
pub const RouteOptions = @import("types.zig").RouteOptions;
/// A request as a write would send it, built without sending it: what
/// `Client.runJobRequest` and the other previews answer.
pub const PreparedRequest = core.PreparedRequest;

/// The fixed limits and naming rules the client checks before sending.
pub const limits = @import("validate.zig");

/// The HTTP seam: implement `transport.Transport` to send requests
/// another way, or to fake the server in your own tests.
pub const transport = core.transport;

/// What a test of code that reads services and revisions can stand on,
/// with no network. **Experimental**, as the module is.
pub const testing = struct {
    /// Cloud Run in memory, behind `Client.Options.transport`: locations,
    /// services and revisions a test puts in, read back as production
    /// answered when measured, refusals in its words. It says so where it
    /// does not model something.
    pub const FakeRun = @import("fake_run.zig").FakeRun;
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
    _ = @import("fake_run.zig");
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
