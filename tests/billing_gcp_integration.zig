//! Integration tests against the real Cloud Billing Catalog, which has no
//! emulator: issue #350. They need a token whose project has the Cloud
//! Billing API enabled; no billing role:
//!
//!     GCP_TEST_TOKEN=$(cat token.txt) BILLING_TEST=1 \
//!     zig build test-integration-gcp -Dtest-filter=billing
//!
//! Without the variables the tests skip. They read only: the services,
//! every Compute Engine SKU (7 pages, about 9 s), and this month's price
//! changes, and hold `FakeBilling` to what production answered.

const std = @import("std");
const core = @import("core");
const billing = @import("billing");
const testing = std.testing;

const Fixture = struct {
    env: std.process.Environ.Map,
    token: core.StaticToken,
    diag: core.Diagnostics = .{},
    client: billing.Client,

    fn init(f: *Fixture) !bool {
        const gpa = testing.allocator;
        f.env = try testing.environ.createMap(gpa);
        errdefer f.env.deinit();
        const token = f.env.get("GCP_TEST_TOKEN") orelse return f.skip();
        if (f.env.get("BILLING_TEST") == null) return f.skip();
        f.token = .{ .token = std.mem.trim(u8, token, &std.ascii.whitespace) };
        f.diag = .{};
        f.client = try .init(gpa, testing.io, .{
            .token_provider = f.token.provider(),
            .scope = .cloud_platform,
            .diagnostics = &f.diag,
        });
        return true;
    }

    fn skip(f: *Fixture) bool {
        f.env.deinit();
        return false;
    }

    fn deinit(f: *Fixture) void {
        f.client.deinit();
        f.env.deinit();
    }
};

test "billing: Compute Engine is found by name, among every service in one page" {
    var f: Fixture = undefined;
    if (!try f.init()) return error.SkipZigTest;
    defer f.deinit();
    var found = (try f.client.findService("Compute Engine")).?;
    defer found.deinit();
    try testing.expectEqualStrings(billing.compute_engine_service_id, found.value.id);
    var all = try f.client.listServices(.{});
    defer all.deinit();
    try testing.expect(all.value.services.len > 1000);
    try testing.expectEqual(null, all.value.next_page_token);
    for (all.value.services[0 .. all.value.services.len - 1], all.value.services[1..]) |a, b| {
        try testing.expect(std.mem.order(u8, a.id, b.id) == .lt);
    }
}

test "billing: every family the price list knows is priced, on demand above spot" {
    var f: Fixture = undefined;
    if (!try f.init()) return error.SkipZigTest;
    defer f.deinit();
    var list = f.client.computePrices(.{}) catch |err| {
        std.debug.print("computePrices: {t}: {s}\n", .{ err, f.diag.message() });
        return err;
    };
    defer list.deinit();
    try testing.expectEqualStrings("USD", list.currency);
    try testing.expect(list.kept > 1000);
    // A family Google adds shows here first: the list must learn it.
    try testing.expectEqual(0, list.skipped.get(.unknown_family));
    try testing.expectEqual(0, list.skipped.get(.duplicate));
    try testing.expectEqual(0, list.skipped.get(.unit));

    const Case = struct { name: []const u8, vcpus: u32, gib: u64, region: []const u8 };
    for ([_]Case{
        .{ .name = "e2-standard-2", .vcpus = 2, .gib = 8, .region = "us-central1" },
        .{ .name = "e2-micro", .vcpus = 2, .gib = 1, .region = "us-central1" },
        .{ .name = "n1-standard-1", .vcpus = 1, .gib = 4, .region = "us-central1" },
        .{ .name = "n2-standard-4", .vcpus = 4, .gib = 16, .region = "us-central1" },
        .{ .name = "n2d-standard-4", .vcpus = 4, .gib = 16, .region = "us-central1" },
        .{ .name = "n4-standard-4", .vcpus = 4, .gib = 16, .region = "us-central1" },
        .{ .name = "c2-standard-4", .vcpus = 4, .gib = 16, .region = "us-central1" },
        .{ .name = "c2d-standard-4", .vcpus = 4, .gib = 16, .region = "us-central1" },
        .{ .name = "c3-standard-4", .vcpus = 4, .gib = 16, .region = "us-central1" },
        .{ .name = "c3d-standard-4", .vcpus = 4, .gib = 16, .region = "us-central1" },
        .{ .name = "c4-standard-4", .vcpus = 4, .gib = 15, .region = "us-central1" },
        .{ .name = "c4a-standard-4", .vcpus = 4, .gib = 16, .region = "us-central1" },
        .{ .name = "c4d-standard-4", .vcpus = 4, .gib = 15, .region = "us-central1" },
        .{ .name = "t2d-standard-4", .vcpus = 4, .gib = 16, .region = "us-central1" },
        .{ .name = "m3-megamem-64", .vcpus = 64, .gib = 976, .region = "us-central1" },
        .{ .name = "e2-standard-2", .vcpus = 2, .gib = 8, .region = "europe-west1" },
        .{ .name = "f1-micro", .vcpus = 1, .gib = 1, .region = "us-central1" },
    }) |c| {
        const machine: billing.compute.Machine = .{ .name = c.name, .vcpus = c.vcpus, .memory_mb = c.gib * 1024 };
        const on_demand = list.hourly(machine, c.region, .on_demand) orelse {
            std.debug.print("no on-demand price for {s} in {s}\n", .{ c.name, c.region });
            return error.TestUnexpectedResult;
        };
        const spot = list.hourly(machine, c.region, .spot) orelse {
            std.debug.print("no spot price for {s} in {s}\n", .{ c.name, c.region });
            return error.TestUnexpectedResult;
        };
        std.debug.print("{s:<15} {s:<12} on demand {d:>12} spot {d:>12} nanos/h\n", .{ c.name, c.region, on_demand.nanos_per_hour, spot.nanos_per_hour });
        try testing.expect(spot.nanos_per_hour > 0);
        try testing.expect(spot.nanos_per_hour < on_demand.nanos_per_hour);
    }

    // The cache form holds the same prices.
    var out: std.Io.Writer.Allocating = .init(testing.allocator);
    defer out.deinit();
    try list.write(&out.writer);
    std.debug.print("the price list's cache form: {d} bytes\n", .{out.written().len});
    var back = try billing.compute.PriceList.read(testing.allocator, out.written());
    defer back.deinit();
    const std2: billing.compute.Machine = .{ .name = "e2-standard-2", .vcpus = 2, .memory_mb = 8192 };
    try testing.expectEqual(list.hourly(std2, "us-central1", .spot).?.nanos_per_hour, back.hourly(std2, "us-central1", .spot).?.nanos_per_hour);
}

test "billing: this month's price changes read oldest first, from the range's start" {
    var f: Fixture = undefined;
    if (!try f.init()) return error.SkipZigTest;
    defer f.deinit();
    const now = std.Io.Clock.real.now(testing.io);
    // The start of this month in Los Angeles, found by walking back a day
    // at a time while the month holds.
    var start = billing.limits.pacificDayStart(now);
    while (true) {
        const before = billing.limits.pacificDayStart(.{ .nanoseconds = start.nanoseconds - std.time.ns_per_hour });
        if (!std.meta.eql(billing.limits.pacificMonth(before), billing.limits.pacificMonth(now))) break;
        start = before;
    }
    var page = try f.client.listSkus(billing.compute_engine_service_id, .{ .page_size = 500, .start_time = start });
    defer page.deinit();
    try testing.expectEqual(500, page.value.skus.len);
    for (page.value.skus) |sku| {
        try testing.expect(sku.pricing.len >= 1);
        try testing.expectEqual(start, sku.pricing[0].effective_time);
        for (sku.pricing[0 .. sku.pricing.len - 1], sku.pricing[1..]) |a, b| {
            try testing.expect(a.effective_time.nanoseconds < b.effective_time.nanoseconds);
        }
    }
}

test "billing: FakeBilling answers a page as production answered it" {
    var f: Fixture = undefined;
    if (!try f.init()) return error.SkipZigTest;
    defer f.deinit();
    var real = try f.client.listSkus(billing.compute_engine_service_id, .{ .page_size = 3 });
    defer real.deinit();

    var fake: billing.testing.FakeBilling = .init(testing.allocator, testing.io);
    defer fake.deinit();
    try fake.putService(.{ .id = billing.compute_engine_service_id, .display_name = "Compute Engine" });
    for (real.value.skus) |sku| {
        const p = sku.latest().?;
        var tiers: [8]billing.testing.FakeBilling.PutTier = undefined;
        for (p.tiers, 0..) |t, i| tiers[i] = .{ .start_usage = t.start_usage, .usd_nanos = @intCast(t.unit_price.toNanos()) };
        try fake.putSku(.{
            .id = sku.id,
            .service_id = billing.compute_engine_service_id,
            .description = sku.description,
            .resource_family = sku.resource_family,
            .resource_group = sku.resource_group,
            .usage_type = sku.usage_type_text,
            .regions = sku.service_regions,
            .geo_type = switch (sku.geo.type) {
                .global => "GLOBAL",
                .regional => "REGIONAL",
                .multi_regional => "MULTI_REGIONAL",
                .unspecified, .other => "TYPE_UNSPECIFIED",
            },
            .usage_unit = p.usage_unit,
            .usage_unit_description = p.usage_unit_description,
            .base_unit = p.base_unit,
            .base_unit_description = p.base_unit_description,
            .base_unit_conversion_factor = p.base_unit_conversion_factor,
            .service_provider = sku.service_provider,
            .prices = &.{.{ .from = .{ .nanoseconds = p.effective_time.nanoseconds - std.time.ns_per_day }, .tiers = tiers[0..p.tiers.len] }},
        });
    }
    var token: billing.StaticToken = .{ .token = "t" };
    var client: billing.Client = try .init(testing.allocator, testing.io, .{ .token_provider = token.provider(), .transport = fake.transport() });
    defer client.deinit();
    var mirrored = try client.listSkus(billing.compute_engine_service_id, .{ .page_size = 3 });
    defer mirrored.deinit();
    try testing.expectEqual(real.value.skus.len, mirrored.value.skus.len);
    for (real.value.skus, mirrored.value.skus) |r, m| {
        try testing.expectEqualStrings(r.id, m.id);
        try testing.expectEqualStrings(r.description, m.description);
        try testing.expectEqualStrings(r.usage_type_text, m.usage_type_text);
        try testing.expectEqual(r.latest().?.effective_time, m.latest().?.effective_time);
        try testing.expectEqual(r.latest().?.unitPrice().?.toNanos(), m.latest().?.unitPrice().?.toNanos());
        try testing.expectEqual(r.latest().?.base_unit_conversion_factor, m.latest().?.base_unit_conversion_factor);
    }
}
