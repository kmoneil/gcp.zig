//! Cloud Monitoring v3 REST client: write a program's own metrics, and
//! manage metric descriptors.
//!
//! `Client.write` sends one point to each of up to 200 series and says how
//! many the server wrote and why it refused the rest. `Client.metric(type)`
//! creates, reads and deletes a metric's descriptor; `Client.listMetrics`
//! and the resource type calls list what the project has. There is no
//! emulator and no unauthenticated mode: every client needs a
//! `TokenProvider`, which the `auth` module supplies. **Experimental**: new
//! in 0.44.0, and free to change between minor versions until it has been
//! used for a while.

const core = @import("core");

pub const Client = @import("Client.zig");
pub const Metric = @import("Metric.zig");
pub const Recorder = @import("Recorder.zig");

pub const TokenProvider = core.TokenProvider;
pub const StaticToken = core.StaticToken;
/// The OAuth scope the client requests from its `TokenProvider`.
pub const auth_scope = @import("rpc.zig").scope;

pub const RetryPolicy = core.RetryPolicy;
pub const Diagnostics = core.Diagnostics;
pub const Error = @import("errors.zig").Error;
pub const ApiError = core.ApiError;

pub const Owned = @import("types.zig").Owned;
pub const Kind = @import("types.zig").Kind;
pub const ValueType = @import("types.zig").ValueType;
pub const Label = @import("types.zig").Label;
pub const LabelType = @import("types.zig").LabelType;
pub const LabelDescriptor = @import("types.zig").LabelDescriptor;
pub const MetricConfig = @import("types.zig").MetricConfig;
pub const Resource = @import("types.zig").Resource;
pub const Value = @import("types.zig").Value;
pub const Distribution = @import("types.zig").Distribution;
pub const TimeSeries = @import("types.zig").TimeSeries;
pub const WriteResult = @import("types.zig").WriteResult;
pub const WriteRetries = @import("types.zig").WriteRetries;
pub const MetricInfo = @import("types.zig").MetricInfo;
pub const ListMetricsOptions = @import("types.zig").ListMetricsOptions;
pub const MetricPage = @import("types.zig").MetricPage;
pub const ResourceTypeInfo = @import("types.zig").ResourceTypeInfo;
pub const ListOptions = @import("types.zig").ListOptions;
pub const ResourceTypePage = @import("types.zig").ResourceTypePage;
pub const Aligner = @import("types.zig").Aligner;
pub const Reducer = @import("types.zig").Reducer;
pub const Match = @import("types.zig").Match;
pub const Filter = @import("types.zig").Filter;
pub const Aggregation = @import("types.zig").Aggregation;
pub const View = @import("types.zig").View;
pub const ReadOptions = @import("types.zig").ReadOptions;
pub const ReadPoint = @import("types.zig").ReadPoint;
pub const Series = @import("types.zig").Series;
pub const ExecutionError = @import("types.zig").ExecutionError;
pub const SeriesPage = @import("types.zig").SeriesPage;

/// The fixed limits and naming rules the client checks before sending.
pub const limits = @import("validate.zig");

/// The HTTP seam: implement `transport.Transport` to send requests another
/// way, or to fake the server in your own tests.
pub const transport = core.transport;

/// What a test of code that writes or reads metrics can stand on, with no
/// emulator and no network. **Experimental**, as the module is.
pub const testing = struct {
    /// Cloud Monitoring in memory, behind `Client.Options.transport`:
    /// descriptors and points, held to the rules production enforced when
    /// measured, refusals in its words. It says so where it does not model
    /// something.
    pub const FakeMonitoring = @import("fake_monitoring.zig").FakeMonitoring;
    /// An `Io` whose clock a test moves, for the time between points.
    pub const FakeClock = core.testing.FakeClock;
};

test {
    @import("std").testing.refAllDecls(@This());
    _ = @import("Client.zig");
    _ = @import("Metric.zig");
    _ = @import("Recorder.zig");
    _ = @import("codec.zig");
    _ = @import("errors.zig");
    _ = @import("filter.zig");
    _ = @import("fake_monitoring.zig");
    _ = @import("logging.zig");
    _ = @import("names.zig");
    _ = @import("rpc.zig");
    _ = @import("types.zig");
    _ = @import("validate.zig");
}

test "every public declaration of types.zig is public here too" {
    // Storage's retention types were public in its types.zig and missing
    // from its root before 0.26.0 was tagged; the same check guards here.
    inline for (@typeInfo(@import("types.zig")).@"struct".decl_names) |name| {
        if (!@hasDecl(@This(), name)) @compileError("not exported: types." ++ name);
    }
}
