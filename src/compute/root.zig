//! Compute Engine's v1 API: the VMs a project runs, in one zone or every
//! zone at once, each with its status, scheduling (spot or standard, a run
//! limit and what happens at it), disks, network, labels, metadata and the
//! fingerprints a change must send back; a VM's serial console and the
//! guest attributes its guest wrote; the zones, machine types and images a
//! create needs; and Compute's own operations, read, listed and waited on.
//! Nothing here creates, changes or deletes anything yet: those calls come
//! in the module's next milestones. **Experimental.**
//!
//! Every write Compute takes answers an `Operation` at once, which a
//! caller waits on with `Client.waitOperation`. What Compute can refuse at
//! once is an HTTP error (`error.NotFound`, `error.AlreadyExists`,
//! `error.FailedPrecondition` for a stale fingerprint); what it finds out
//! while acting is an operation that ends DONE with `Operation.failure`
//! set. A zone's operations also say what ended a VM: a preemption, a run
//! limit or its guest powering off.
//!
//! A client asks for one OAuth scope, `Client.Options.scope`:
//! `compute.readonly` by default, which every call here takes.

pub const Client = @import("Client.zig");

pub const TokenProvider = core.TokenProvider;
pub const StaticToken = core.StaticToken;

/// The OAuth scopes a client can ask for (`Client.Options.scope`).
pub const Scope = @import("rpc.zig").Scope;
/// The default scope's URL, `compute.readonly`.
pub const auth_scope = @import("rpc.zig").scope;

pub const RetryPolicy = core.RetryPolicy;
pub const Diagnostics = core.Diagnostics;
pub const Error = @import("errors.zig").Error;
pub const ApiError = core.ApiError;

pub const Owned = @import("types.zig").Owned;
pub const Label = @import("types.zig").Label;
pub const Status = @import("types.zig").Status;
pub const MetadataItem = @import("types.zig").MetadataItem;
pub const Metadata = @import("types.zig").Metadata;
pub const Tags = @import("types.zig").Tags;
pub const AttachedDisk = @import("types.zig").AttachedDisk;
pub const AccessConfig = @import("types.zig").AccessConfig;
pub const NetworkInterface = @import("types.zig").NetworkInterface;
pub const ServiceAccount = @import("types.zig").ServiceAccount;
pub const ProvisioningModel = @import("types.zig").ProvisioningModel;
pub const TerminationAction = @import("types.zig").TerminationAction;
pub const Scheduling = @import("types.zig").Scheduling;
pub const Instance = @import("types.zig").Instance;
pub const ListOptions = @import("types.zig").ListOptions;
pub const InstancePage = @import("types.zig").InstancePage;
pub const ScopeWarning = @import("types.zig").ScopeWarning;
pub const AggregatedInstancePage = @import("types.zig").AggregatedInstancePage;
pub const SerialOptions = @import("types.zig").SerialOptions;
pub const SerialOutput = @import("types.zig").SerialOutput;
pub const GuestAttribute = @import("types.zig").GuestAttribute;
pub const GuestAttributes = @import("types.zig").GuestAttributes;
pub const Zone = @import("types.zig").Zone;
pub const ZonePage = @import("types.zig").ZonePage;
pub const MachineType = @import("types.zig").MachineType;
pub const MachineTypePage = @import("types.zig").MachineTypePage;
pub const Image = @import("types.zig").Image;
pub const OperationScope = @import("types.zig").OperationScope;
pub const OperationRef = @import("types.zig").OperationRef;
pub const OperationStatus = @import("types.zig").OperationStatus;
pub const Operation = @import("types.zig").Operation;
pub const OperationPage = @import("types.zig").OperationPage;
pub const WaitOptions = @import("types.zig").WaitOptions;

/// The fixed limits and naming rules the client checks before sending.
pub const limits = @import("validate.zig");

/// The HTTP seam: implement `transport.Transport` to send requests
/// another way, or to fake the server in your own tests.
pub const transport = core.transport;

/// What a test of code that reads VMs and waits on operations can stand
/// on, with no network.
pub const testing = struct {
    /// Compute Engine in memory, behind `Client.Options.transport`: zones,
    /// VMs, serial output, guest attributes, machine types, images and
    /// operations a test puts in, read back as production answered when
    /// measured, refusals in its words. It says so where it does not model
    /// something.
    pub const FakeCompute = @import("fake_compute.zig").FakeCompute;
    /// An `Io` whose clock a test moves.
    pub const FakeClock = core.testing.FakeClock;
};

const core = @import("core");

test {
    _ = @import("production_bodies.zig");
    _ = @import("test_util.zig");
    @import("std").testing.refAllDecls(@This());
    _ = @import("Client.zig");
    _ = @import("Client_test.zig");
    _ = @import("codec.zig");
    _ = @import("errors.zig");
    _ = @import("fake_compute.zig");
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
