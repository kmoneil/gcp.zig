//! The Cloud Billing Catalog API, v1, read only: the services Google bills
//! for, and a service's SKUs with their list prices, the latest or every
//! one in force over a range of time within a month, in USD or another
//! currency; and what a Compute Engine machine type costs an hour, on
//! demand and spot, from the SKUs that price its vCPUs and memory apart
//! (`Client.computePrices`, `compute.PriceList`). **Experimental.**
//!
//! Nothing here touches a billing account: the catalog's prices are the
//! public list prices. The Cloud Billing API must be enabled in the
//! token's project, which every call is billed to; until it is, every call
//! is `error.PermissionDenied`.
//!
//! A client asks for one OAuth scope, `Client.Options.scope`:
//! `cloud-billing.readonly` by default, or `cloud-platform`.

pub const Client = @import("Client.zig");

pub const TokenProvider = core.TokenProvider;
pub const StaticToken = core.StaticToken;

/// The OAuth scopes a client can ask for (`Client.Options.scope`).
pub const Scope = @import("rpc.zig").Scope;
/// The default scope's URL, `cloud-billing.readonly`.
pub const auth_scope = @import("rpc.zig").scope;

pub const RetryPolicy = core.RetryPolicy;
pub const Diagnostics = core.Diagnostics;
pub const Error = @import("errors.zig").Error;
pub const ApiError = core.ApiError;

pub const Owned = @import("types.zig").Owned;
pub const Service = @import("types.zig").Service;
pub const ListServicesOptions = @import("types.zig").ListServicesOptions;
pub const ServicePage = @import("types.zig").ServicePage;
pub const UsageType = @import("types.zig").UsageType;
pub const GeoType = @import("types.zig").GeoType;
pub const Geo = @import("types.zig").Geo;
pub const Money = @import("types.zig").Money;
pub const Tier = @import("types.zig").Tier;
pub const Aggregation = @import("types.zig").Aggregation;
pub const Pricing = @import("types.zig").Pricing;
pub const Sku = @import("types.zig").Sku;
pub const ListSkusOptions = @import("types.zig").ListSkusOptions;
pub const SkuPage = @import("types.zig").SkuPage;

/// Compute Engine's service id.
pub const compute_engine_service_id = Client.compute_engine_service_id;

/// What a Compute Engine machine type costs an hour, on demand and spot:
/// `compute.PriceList`, built by `Client.computePrices`.
pub const compute = @import("compute.zig");
pub const ComputePricesOptions = Client.ComputePricesOptions;

/// The fixed limits and naming rules the client checks before sending,
/// and the Los Angeles calendar a time range is held to.
pub const limits = @import("validate.zig");

/// The HTTP seam: implement `transport.Transport` to send requests
/// another way, or to fake the server in your own tests.
pub const transport = core.transport;

/// What a test of code that reads prices can stand on, with no network.
pub const testing = struct {
    /// The Cloud Billing Catalog in memory, behind
    /// `Client.Options.transport`: services and SKUs with price timelines
    /// a test puts in, read back as production answered when measured,
    /// refusals in its words.
    pub const FakeBilling = @import("fake_billing.zig").FakeBilling;
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
    _ = @import("compute.zig");
    _ = @import("errors.zig");
    _ = @import("fake_billing.zig");
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
