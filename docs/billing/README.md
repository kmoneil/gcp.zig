[Docs](../README.md) › Billing

# 🧾 Billing

A client for the Cloud Billing Catalog API, v1: the services Google
bills for, and a service's SKUs with their public list prices, the
latest or every price in force over a range of time, in USD or another
currency. Read only: nothing here touches a billing account.
**Experimental.**

```zig
const std = @import("std");
const auth = @import("auth");
const billing = @import("billing");

pub fn main(init: std.process.Init) !void {
    const arena = init.arena.allocator();
    const lookup = try auth.Lookup.fromEnv(init.environ_map, arena);
    var creds = try auth.findDefault(init.gpa, init.io, lookup, .{});
    defer creds.deinit();
    var client = try billing.Client.init(init.gpa, init.io, .{
        .token_provider = creds.provider(),
    });
    defer client.deinit();
    var page = try client.listSkus(billing.compute_engine_service_id, .{});
    defer page.deinit();
    for (page.value.skus) |sku| {
        const price = sku.latest() orelse continue;
        std.debug.print("{s}: {d} nanos per {s}\n", .{ sku.description, price.unitPrice().?.toNanos(), price.usage_unit });
    }
}
```

## The calls

| Call | What it does |
| --- | --- |
| `Client.listServices(options)` | One page of the services Google bills for, sorted by id; the default page, 5000, held all 1,781 when measured |
| `Client.findService(display_name)` | The service named, such as "Compute Engine", read through every page; null when none has it |
| `Client.listSkus(service_id, options)` | One page of a service's SKUs, sorted by id, each with its latest price or every one in force over `start_time` to `end_time` |

`billing.compute_engine_service_id` is Compute Engine's, `6F81-5844-456A`.

A `Sku` carries its `description` ("E2 Instance Core running in
Americas"), `resource_family` (Compute, Storage, Network, License),
`resource_group` (CPU, RAM, GPU, ...), `usage_type` (on demand,
`preemptible` for spot, or a commitment), the regions it is offered in,
and `pricing`, oldest first. Each `Pricing` has its unit (`h` for a
vCPU-hour, `GiBy.h` for a GiB-hour of memory) and its tiers, each a
`Money`: whole `units` and `nanos`, exact, with `toNanos()` for sums.

## Prices, as production showed them

Measured on 2026-11-04 with a service account in a test project.

- **Compute Engine has 33,567 SKUs**: 7 pages of 5000, 46 MB, read in
  about 9 s. Read them a page at a time; nothing needs all of them at
  once.
- **A machine is priced by its vCPU and memory SKUs, apart.**
  e2-standard-2 in us-central1 is 2 × $0.02181159 (E2 Instance Core)
  plus 8 × $0.00292353 (E2 Instance Ram): $0.067011 an hour on demand,
  $0.040212 as spot. Spot SKUs read "Spot Preemptible E2 Instance Core
  ..." with `usage_type` `.preemptible`.
- **`usage_type` alone does not find a machine's price**: sole-tenancy
  premiums, committed-use premiums, reservations and custom and extended
  machines are `.on_demand` too. The family is named only in the
  description, and not always by its name: C2 is "Compute optimized",
  M1 and M2 "Memory-optimized", N2D "N2D AMD".
- **us-central1, us-east1 and us-west1 share one SKU per family**,
  "running in Americas"; every other region has its own.
- **e2-micro, e2-small and e2-medium have no SKU of their own**: Google
  bills them as 0.25, 0.5 and 1 E2 vCPU with 1, 2 and 4 GB.
- **Spot prices change about weekly.** In October, 1,655 spot vCPU and
  memory SKUs changed price, most of them on Mondays at midnight in Los
  Angeles, by 5 to 10%; Google's docs say spot prices can change once a
  day. On-demand prices barely moved.
- **The latest price says it took effect at midnight in Los Angeles
  today**, whenever it really changed. Over a range, the price in force
  at the range's start says it took effect then, and each later change
  says when it happened.
- Every machine SKU has one tier, from 0, in USD unless asked otherwise.

## Time ranges and currencies

`ListSkusOptions.start_time` and `end_time` ask for every price in force
over a range. Production holds a range to one calendar month in Los
Angeles, never in the future; an end needs a start, and a start alone
reads to now. It answers anything else with a bare 400, "Request
contains an invalid argument.", so the client refuses those before
sending, with `error.InvalidOptions` and the reason in `Diagnostics`.
`billing.limits` has the Los Angeles calendar it checks with.

`Client.Options.currency_code` asks for prices in another currency,
such as `EUR`. The server converts them, truncated to whole nanos, and
says the rate beside each; a caller applies nothing. Three uppercase
letters: production refuses `eur`.

## Access

The catalog belongs to no project, but production refuses a call
without credentials and bills it to the token's project, where the
Cloud Billing API (`cloudbilling.googleapis.com`) must be enabled.
Until it is, every call is `error.PermissionDenied` with production's
`SERVICE_DISABLED` message in `Diagnostics`. No billing role is needed:
any token reads the public prices. The default scope is
`cloud-billing.readonly`; `.cloud_platform` is there for credentials
fixed to it.

In tests, `billing.testing.FakeBilling` holds services and SKUs with
their price timelines, and answers as production does: [Testing](testing.md).
