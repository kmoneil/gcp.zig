[Docs](../README.md) › [Billing](README.md) › Testing

# Testing with the in-memory Cloud Billing Catalog

`billing.testing.FakeBilling` is the Cloud Billing Catalog in memory,
behind `Client.Options.transport`, for tests of code that reads prices:
a scheduler that ranks machines by price, or a cost estimate, with no
network and no project. It answers `services.list` and
`services.skus.list` as production answered them when measured on
2026-11-04, its refusals in production's words.

`putService` and `putSku` stand in for Google's catalog. Each SKU has a
price timeline in USD, oldest first; the fake answers the price in
force at the time asked, as production does.

<!-- snippet: tests/docs_examples.zig#billing-fake -->
```zig
test "an hourly price, read from the in-memory catalog" {
    var fake: billing.testing.FakeBilling = .init(std.testing.allocator, std.testing.io);
    defer fake.deinit();
    const engine = billing.compute_engine_service_id;
    try fake.putService(.{ .id = engine, .display_name = "Compute Engine" });
    // E2's vCPU and memory in us-central1, priced as production priced
    // them on 2026-11-04, standing in for Google's catalog.
    const since: std.Io.Timestamp = .{ .nanoseconds = 1_767_254_400 * std.time.ns_per_s };
    const americas: []const []const u8 = &.{ "us-central1", "us-east1", "us-west1" };
    try fake.putSku(.{
        .id = "CF4E-A0C7-E3BF",
        .service_id = engine,
        .description = "E2 Instance Core running in Americas",
        .regions = americas,
        .geo_type = "MULTI_REGIONAL",
        .prices = &.{.{ .from = since, .tiers = &.{.{ .usd_nanos = 21_811_590 }} }},
    });
    try fake.putSku(.{
        .id = "F449-33EC-A5EF",
        .service_id = engine,
        .description = "E2 Instance Ram running in Americas",
        .resource_group = "RAM",
        .usage_unit = "GiBy.h",
        .usage_unit_description = "gibibyte hour",
        .base_unit = "By.s",
        .base_unit_description = "byte second",
        .base_unit_conversion_factor = 3_865_470_566_400,
        .regions = americas,
        .geo_type = "MULTI_REGIONAL",
        .prices = &.{.{ .from = since, .tiers = &.{.{ .usd_nanos = 2_923_530 }} }},
    });

    var token: billing.StaticToken = .{ .token = "none" };
    var client = try billing.Client.init(std.testing.allocator, std.testing.io, .{
        .token_provider = token.provider(),
        .transport = fake.transport(),
    });
    defer client.deinit();
    var page = try client.listSkus(engine, .{});
    defer page.deinit();

    // e2-standard-2: two vCPUs and 8 GiB, each priced apart.
    var nanos: i128 = 0;
    for (page.value.skus) |sku| {
        if (!sku.offeredIn("us-central1")) continue;
        const unit = sku.latest().?.unitPrice().?.toNanos();
        nanos += if (std.mem.eql(u8, sku.resource_group, "CPU")) 2 * unit else 8 * unit;
    }
    try std.testing.expectEqual(67_011_420, nanos); // $0.06701142 an hour
}
```

## What it answers, and how

- Lists sort by id and page as production does: the default page is the
  maximum, 5000, and a page token is the next offset in base64 (`Mg==`
  for 2). The last page's token is `""`, which the client reads as none.
- With no time range, each SKU answers the price in force on the fake's
  clock, said to take effect at midnight in Los Angeles that day, as
  production says. Over a range, it answers the price in force at the
  range's start, said to take effect then, and every later change
  before the range's end.
- `setRate("EUR", 0.8981)` makes a currency known: its prices are the
  USD nanos times the rate, truncated, with the rate beside them, as
  production converts.
- Refused in production's words: a page size over 5000 or below 0, a
  page token the fake did not make, an unknown or lowercase currency,
  and a range in the future, ending before it starts, with an end and
  no start, or across a month in Los Angeles (each production's bare
  400); a timestamp that is not one (400, naming the field); a service
  nobody put (404 "Requested entity was not found."); a call with no
  credentials (403).
- `Client.computePrices` reads the fake as it reads production, page by
  page, so a test can give a scheduler a price list built from the SKUs
  it put in.
- `refuseNext(n, status)` and `dropNext(n)` fail the next calls, for a
  test of what a caller does when a read is refused or its connection
  drops.

Not modelled, answered 501 with the reason: a page token past the end
of a list, query parameters the client never sends, and every other
method or path, such as v2beta or billing accounts.

The fake is held to production by a test that puts in the SKUs
production answered on 2026-11-04 and reads them back the way
production was read: the latest prices, in EUR, and over October, when
one of them changed price four times.
