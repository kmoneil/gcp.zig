//! The Cloud Billing Catalog's values as this library holds them: the
//! services Google bills for, and their SKUs with list prices. Wire names
//! live in the codec.

const std = @import("std");
const core = @import("core");
const Timestamp = std.Io.Timestamp;

pub const Owned = core.Owned;

/// A service Google bills for, as `services.list` answers it.
pub const Service = struct {
    /// Such as `6F81-5844-456A`, Compute Engine's.
    id: []const u8,
    /// `services/` and the id.
    name: []const u8,
    /// Such as "Compute Engine".
    display_name: []const u8 = "",
    /// Such as `businessEntities/GCP` or `businessEntities/Maps`.
    business_entity: []const u8 = "",
};

pub const ListServicesOptions = struct {
    /// 0 lets the server choose: 5000, its maximum. More is refused before
    /// sending.
    page_size: u32 = 0,
    page_token: ?[]const u8 = null,
};

pub const ServicePage = struct {
    services: []const Service,
    /// Null on the last page, where production sends `""`.
    next_page_token: ?[]const u8 = null,
};

/// How a SKU is consumed: on demand, as spot (the wire's `Preemptible`),
/// or under a commitment.
pub const UsageType = enum {
    on_demand,
    /// Spot and preemptible VMs.
    preemptible,
    commit_1mo,
    commit_1yr,
    commit_3yr,
    /// Any other, such as `CmtCudPremium` or `Commit` (measured on
    /// 2026-11-04); `Sku.usage_type_text` keeps the wire's word.
    other,

    pub fn fromWire(text: []const u8) UsageType {
        inline for (.{
            .{ "OnDemand", .on_demand },
            .{ "Preemptible", .preemptible },
            .{ "Commit1Mo", .commit_1mo },
            .{ "Commit1Yr", .commit_1yr },
            .{ "Commit3Yr", .commit_3yr },
        }) |entry| {
            if (std.mem.eql(u8, text, entry[0])) return entry[1];
        }
        return .other;
    }
};

pub const GeoType = enum {
    /// Every region: production's 1,228 global Compute Engine SKUs.
    global,
    /// One region.
    regional,
    /// Several, such as the three a SKU "running in Americas" covers.
    multi_regional,
    /// Not sent: 53 of Compute Engine's SKUs had no `geoTaxonomy`.
    unspecified,
    /// A type this library does not know.
    other,

    pub fn fromWire(text: []const u8) GeoType {
        inline for (.{
            .{ "GLOBAL", .global },
            .{ "REGIONAL", .regional },
            .{ "MULTI_REGIONAL", .multi_regional },
            .{ "TYPE_UNSPECIFIED", .unspecified },
        }) |entry| {
            if (std.mem.eql(u8, text, entry[0])) return entry[1];
        }
        return .other;
    }
};

pub const Geo = struct {
    type: GeoType = .unspecified,
    regions: []const []const u8 = &.{},
};

/// An amount of money, exactly: whole `units` and `nanos` (billionths),
/// with the same sign, as `google.type.Money` holds it.
pub const Money = struct {
    /// ISO 4217, such as `USD`.
    currency: []const u8 = "",
    units: i64 = 0,
    /// From -999,999,999 to 999,999,999, the sign of `units` when that is
    /// not 0. The codec refuses anything else.
    nanos: i32 = 0,

    /// The amount in billionths of the currency's unit: $0.02181159 is
    /// 21,811,590. Wide enough that prices add and multiply exactly.
    pub fn toNanos(m: Money) i128 {
        return @as(i128, m.units) * 1_000_000_000 + m.nanos;
    }

    /// Whether `units` and `nanos` hold an amount `google.type.Money`
    /// allows.
    pub fn isValid(m: Money) bool {
        if (m.nanos <= -1_000_000_000 or m.nanos >= 1_000_000_000) return false;
        if (m.units > 0 and m.nanos < 0) return false;
        if (m.units < 0 and m.nanos > 0) return false;
        return true;
    }
};

/// One tier of a price: usage above `start_usage` units costs `unit_price`
/// per unit, until the next tier's start. Usage below the first tier's
/// start is free. Every machine SKU measured had one tier, from 0.
pub const Tier = struct {
    start_usage: f64 = 0,
    unit_price: Money,
};

/// Over how much usage tiers are counted, when they are.
pub const Aggregation = struct {
    /// Such as `ACCOUNT` or `PROJECT`.
    level: []const u8 = "",
    /// Such as `DAILY` or `MONTHLY`.
    interval: []const u8 = "",
    count: i64 = 0,
};

/// A SKU's price from one moment on, with its unit.
pub const Pricing = struct {
    /// When the price took effect within the range read. With no range,
    /// production answers midnight in Los Angeles on the day of the read,
    /// not the day the price last changed; over a range, the range's start
    /// for the price in force then.
    effective_time: Timestamp,
    summary: []const u8 = "",
    /// Such as `h` (a vCPU-hour), `GiBy.h` (a GiB-hour) or `GiBy.mo`.
    usage_unit: []const u8 = "",
    usage_unit_description: []const u8 = "",
    base_unit: []const u8 = "",
    base_unit_description: []const u8 = "",
    /// How many base units make one usage unit: 3600 for `h` over `s`.
    base_unit_conversion_factor: f64 = 0,
    display_quantity: f64 = 0,
    tiers: []const Tier = &.{},
    aggregation: ?Aggregation = null,
    /// From USD to the currency asked for: 1 for USD. Prices are already
    /// converted (and truncated to whole nanos); a caller applies nothing.
    currency_conversion_rate: f64 = 1,

    /// The price per usage unit of the first tier, the one usage starts
    /// in: every machine SKU's only one. Null with no tiers.
    pub fn unitPrice(p: Pricing) ?Money {
        if (p.tiers.len == 0) return null;
        return p.tiers[0].unit_price;
    }
};

/// A thing Google bills for, with its prices.
pub const Sku = struct {
    /// Such as `CF4E-A0C7-E3BF`.
    id: []const u8,
    /// `services/<service id>/skus/<id>`.
    name: []const u8,
    /// Up to 256 characters, such as "E2 Instance Core running in
    /// Americas". For a machine's vCPU and memory SKUs, the only place the
    /// machine family is named.
    description: []const u8 = "",
    service_display_name: []const u8 = "",
    /// Such as `Compute`, `Storage`, `Network` or `License`.
    resource_family: []const u8 = "",
    /// Such as `CPU`, `RAM`, `GPU`, `N1Standard`, `F1Micro`.
    resource_group: []const u8 = "",
    usage_type: UsageType = .other,
    /// The wire's word for `usage_type`, such as `OnDemand`.
    usage_type_text: []const u8 = "",
    /// Region names, such as `us-central1`. A SKU "running in Americas"
    /// lists us-central1, us-east1 and us-west1.
    service_regions: []const []const u8 = &.{},
    geo: Geo = .{},
    /// `Google` for Google's own services.
    service_provider: []const u8 = "",
    /// Oldest first: one entry for the latest price, more over a range in
    /// which it changed.
    pricing: []const Pricing = &.{},

    /// The newest entry in `pricing`, or null when there is none.
    pub fn latest(s: Sku) ?Pricing {
        if (s.pricing.len == 0) return null;
        return s.pricing[s.pricing.len - 1];
    }

    /// Whether `region` is among `service_regions`.
    pub fn offeredIn(s: Sku, region: []const u8) bool {
        for (s.service_regions) |r| if (std.mem.eql(u8, r, region)) return true;
        return false;
    }
};

pub const ListSkusOptions = struct {
    /// 0 lets the server choose: 5000, its maximum. More is refused before
    /// sending. Compute Engine's 33,567 SKUs are 7 pages of 5000, 46 MB.
    page_size: u32 = 0,
    page_token: ?[]const u8 = null,
    /// With no range, each SKU's latest price (production: at most 12
    /// hours old). Over a range, every price in force during it. A range
    /// lies in one calendar month in Los Angeles and never in the future;
    /// an end needs a start, and a start alone runs to now. The client
    /// refuses any other before sending, where production answers a bare
    /// 400.
    start_time: ?Timestamp = null,
    end_time: ?Timestamp = null,
};

pub const SkuPage = struct {
    skus: []const Sku,
    /// Null on the last page, where production sends `""`.
    next_page_token: ?[]const u8 = null,
};

const testing = std.testing;

test "Money: nanos exactly, and what google.type.Money allows" {
    const core_price: Money = .{ .currency = "USD", .nanos = 21_811_590 };
    try testing.expectEqual(21_811_590, core_price.toNanos());
    try testing.expectEqual(2_500_000_000, (Money{ .units = 2, .nanos = 500_000_000 }).toNanos());
    try testing.expectEqual(-1_750_000_000, (Money{ .units = -1, .nanos = -750_000_000 }).toNanos());
    try testing.expect((Money{ .units = 3 }).isValid());
    try testing.expect(!(Money{ .units = 1, .nanos = -1 }).isValid());
    try testing.expect(!(Money{ .units = -1, .nanos = 1 }).isValid());
    try testing.expect(!(Money{ .nanos = 1_000_000_000 }).isValid());
    try testing.expect((Money{ .nanos = -5 }).isValid());
}

fn moneyProperty(_: void, input: []const u8) !void {
    var g: core.testing.ByteGen = .init(input);
    const units: i64 = @bitCast(g.intRange(u64, 0, std.math.maxInt(u64)));
    const nanos: i32 = @intCast(@as(i64, g.intRange(u32, 0, 1_999_999_998)) - 999_999_999);
    const m: Money = .{ .units = units, .nanos = nanos };
    // A decimal model: the same amount written out and read back.
    var buf: [48]u8 = undefined;
    const negative = units < 0 or (units == 0 and nanos < 0);
    const text = try std.fmt.bufPrint(&buf, "{s}{d}{d:0>9}", .{
        if (negative) "-" else "",
        @abs(units),
        @abs(nanos),
    });
    const model = try std.fmt.parseInt(i128, text, 10);
    if (m.isValid()) try testing.expectEqual(model, m.toNanos());
    try testing.expectEqual(!((units > 0 and nanos < 0) or (units < 0 and nanos > 0)), m.isValid());
}

test "fuzz Money: toNanos matches a decimal model for every amount the wire allows" {
    try core.testing.fuzzBytes({}, moneyProperty, .{ .corpus = &.{
        "\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00",
        "\xff\xff\xff\xff\xff\xff\xff\xff\xff\xff\xff\xff",
        "\x80\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00",
    } });
}

test "Sku: latest, offeredIn and the first tier's price" {
    const old: Pricing = .{ .effective_time = .{ .nanoseconds = 1 }, .tiers = &.{.{ .unit_price = .{ .nanos = 1 } }} };
    const new: Pricing = .{ .effective_time = .{ .nanoseconds = 2 }, .tiers = &.{.{ .unit_price = .{ .nanos = 2 } }} };
    const sku: Sku = .{ .id = "A", .name = "services/S/skus/A", .service_regions = &.{ "us-central1", "us-east1" }, .pricing = &.{ old, new } };
    try testing.expectEqual(2, sku.latest().?.unitPrice().?.nanos);
    try testing.expect(sku.offeredIn("us-east1"));
    try testing.expect(!sku.offeredIn("europe-west1"));
    try testing.expectEqual(null, (Sku{ .id = "B", .name = "b" }).latest());
    try testing.expectEqual(null, (Pricing{ .effective_time = .{ .nanoseconds = 0 } }).unitPrice());
    try testing.expectEqual(UsageType.preemptible, UsageType.fromWire("Preemptible"));
    try testing.expectEqual(UsageType.other, UsageType.fromWire("CmtCudPremium"));
    try testing.expectEqual(GeoType.multi_regional, GeoType.fromWire("MULTI_REGIONAL"));
    try testing.expectEqual(GeoType.other, GeoType.fromWire("PLANETARY"));
}
