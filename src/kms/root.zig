//! Cloud KMS v1 REST client: use and manage encryption, signing and MAC
//! keys.
//!
//! `Client.keyRing(id)` and `KeyRing.key(id)` name keys; `Key.create`,
//! `Key.version(n)` and the rest manage them: versions enabled, disabled,
//! destroyed, restored and deleted, the primary version and automatic
//! rotation. There is no emulator and no unauthenticated mode: every
//! client needs a `TokenProvider`, which the `auth` module supplies.
//! **Experimental**: new in 0.45.0, and free to change between minor
//! versions until it has been used for a while.

const core = @import("core");

pub const Client = @import("Client.zig");
pub const KeyRing = @import("KeyRing.zig");
pub const Key = @import("Key.zig");
pub const KeyVersion = @import("KeyVersion.zig");

pub const TokenProvider = core.TokenProvider;
pub const StaticToken = core.StaticToken;
/// The OAuth scope the client requests from its `TokenProvider`.
pub const auth_scope = @import("rpc.zig").scope;

pub const RetryPolicy = core.RetryPolicy;
pub const Diagnostics = core.Diagnostics;
pub const Error = @import("errors.zig").Error;
pub const ApiError = core.ApiError;
pub const Change = core.Change;

pub const Owned = @import("types.zig").Owned;
pub const Purpose = @import("types.zig").Purpose;
pub const ProtectionLevel = @import("types.zig").ProtectionLevel;
pub const Algorithm = @import("types.zig").Algorithm;
pub const State = @import("types.zig").State;
pub const Label = @import("types.zig").Label;
pub const Rotation = @import("types.zig").Rotation;
pub const KeyConfig = @import("types.zig").KeyConfig;
pub const KeyUpdate = @import("types.zig").KeyUpdate;
pub const KeyRingInfo = @import("types.zig").KeyRingInfo;
pub const KeyRingPage = @import("types.zig").KeyRingPage;
pub const VersionInfo = @import("types.zig").VersionInfo;
pub const VersionPage = @import("types.zig").VersionPage;
pub const KeyInfo = @import("types.zig").KeyInfo;
pub const KeyPage = @import("types.zig").KeyPage;
pub const ListOptions = @import("types.zig").ListOptions;
pub const LocationInfo = @import("types.zig").LocationInfo;
pub const LocationPage = @import("types.zig").LocationPage;
pub const RetiredKey = @import("types.zig").RetiredKey;
pub const RetiredKeyPage = @import("types.zig").RetiredKeyPage;

/// The fixed limits and naming rules the client checks before sending.
pub const limits = @import("validate.zig");

/// The HTTP seam: implement `transport.Transport` to send requests another
/// way, or to fake the server in your own tests.
pub const transport = core.transport;

/// What a test of code that uses keys can stand on, with no emulator and
/// no network. **Experimental**, as the module is.
pub const testing = struct {
    /// Cloud KMS in memory, behind `Client.Options.transport`: key rings,
    /// keys and versions with the state machine production documents,
    /// refusals in its words. It says so where it does not model something.
    pub const FakeKms = @import("fake_kms.zig").FakeKms;
    /// An `Io` whose clock a test moves, for destroy delays, rotation and
    /// key generation.
    pub const FakeClock = core.testing.FakeClock;
};

test {
    @import("std").testing.refAllDecls(@This());
    _ = @import("Client.zig");
    _ = @import("KeyRing.zig");
    _ = @import("Key.zig");
    _ = @import("KeyVersion.zig");
    _ = @import("codec.zig");
    _ = @import("errors.zig");
    _ = @import("fake_kms.zig");
    _ = @import("logging.zig");
    _ = @import("names.zig");
    _ = @import("operations.zig");
    _ = @import("rpc.zig");
    _ = @import("types.zig");
    _ = @import("validate.zig");
}

test "every public declaration of types.zig is public here too" {
    inline for (@typeInfo(@import("types.zig")).@"struct".decl_names) |name| {
        if (!@hasDecl(@This(), name)) @compileError("not exported: types." ++ name);
    }
}
