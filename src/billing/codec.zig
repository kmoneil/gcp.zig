//! Decoders for the Cloud Billing Catalog's proto3 JSON. Lenient where the
//! server may grow (unknown fields skipped, unknown enum values read as
//! `.other`), strict where a field identifies the answer or carries money:
//! a SKU without a name, a price without its effective time, or money whose
//! units and nanos disagree in sign is `error.InvalidResponse`.

const std = @import("std");
const Allocator = std.mem.Allocator;
const Value = std.json.Value;
const ObjectMap = std.json.ObjectMap;
const core = @import("core");
const types = @import("types.zig");

pub const DecodeError = error{ OutOfMemory, InvalidResponse };

/// A page of `services.list`.
pub fn decodeServicePage(out: Allocator, scratch: Allocator, body: []const u8) DecodeError!types.ServicePage {
    const obj = try object(try parse(scratch, body));
    const list = try field(obj, "services", .array);
    const services = try out.alloc(types.Service, if (list) |l| l.items.len else 0);
    if (list) |l| for (l.items, services) |v, *s| {
        s.* = try serviceOf(out, v);
    };
    return .{ .services = services, .next_page_token = try token(out, obj) };
}

/// A page of `services.skus.list`.
pub fn decodeSkuPage(out: Allocator, scratch: Allocator, body: []const u8) DecodeError!types.SkuPage {
    const obj = try object(try parse(scratch, body));
    const list = try field(obj, "skus", .array);
    const skus = try out.alloc(types.Sku, if (list) |l| l.items.len else 0);
    if (list) |l| for (l.items, skus) |v, *s| {
        s.* = try skuOf(out, v);
    };
    return .{ .skus = skus, .next_page_token = try token(out, obj) };
}

/// One SKU, as a page carries it: for tests and for a caller holding one.
pub fn decodeSku(out: Allocator, scratch: Allocator, body: []const u8) DecodeError!types.Sku {
    return skuOf(out, try parse(scratch, body));
}

fn serviceOf(out: Allocator, v: Value) DecodeError!types.Service {
    const obj = try object(v);
    const name = try string(out, obj, "name") orelse return error.InvalidResponse;
    return .{
        .name = name,
        .id = try string(out, obj, "serviceId") orelse trailing(name),
        .display_name = try string(out, obj, "displayName") orelse "",
        .business_entity = try string(out, obj, "businessEntityName") orelse "",
    };
}

fn skuOf(out: Allocator, v: Value) DecodeError!types.Sku {
    const obj = try object(v);
    const name = try string(out, obj, "name") orelse return error.InvalidResponse;
    var sku: types.Sku = .{
        .name = name,
        .id = try string(out, obj, "skuId") orelse trailing(name),
        .description = try string(out, obj, "description") orelse "",
        .service_regions = try stringList(out, obj, "serviceRegions"),
        .service_provider = try string(out, obj, "serviceProviderName") orelse "",
    };
    if (try field(obj, "category", .object)) |cat| {
        sku.service_display_name = try string(out, cat, "serviceDisplayName") orelse "";
        sku.resource_family = try string(out, cat, "resourceFamily") orelse "";
        sku.resource_group = try string(out, cat, "resourceGroup") orelse "";
        if (try string(out, cat, "usageType")) |u| {
            sku.usage_type_text = u;
            sku.usage_type = .fromWire(u);
        }
    }
    if (try field(obj, "geoTaxonomy", .object)) |geo| sku.geo = .{
        .type = if (try field(geo, "type", .string)) |t| .fromWire(t) else .unspecified,
        .regions = try stringList(out, geo, "regions"),
    };
    if (try field(obj, "pricingInfo", .array)) |list| {
        const pricing = try out.alloc(types.Pricing, list.items.len);
        for (list.items, pricing) |item, *p| p.* = try pricingOf(out, item);
        sku.pricing = pricing;
    }
    return sku;
}

fn pricingOf(out: Allocator, v: Value) DecodeError!types.Pricing {
    const obj = try object(v);
    var p: types.Pricing = .{
        .effective_time = try time(obj, "effectiveTime") orelse return error.InvalidResponse,
        .summary = try string(out, obj, "summary") orelse "",
        .currency_conversion_rate = try number(obj, "currencyConversionRate") orelse 1,
    };
    if (try field(obj, "pricingExpression", .object)) |e| try expressionOf(out, e, &p);
    if (try field(obj, "aggregationInfo", .object)) |a| p.aggregation = .{
        .level = try string(out, a, "aggregationLevel") orelse "",
        .interval = try string(out, a, "aggregationInterval") orelse "",
        .count = try integer(i64, a, "aggregationCount") orelse 0,
    };
    return p;
}

/// A `PricingExpression`'s units and tiers, into `p`.
fn expressionOf(out: Allocator, e: ObjectMap, p: *types.Pricing) DecodeError!void {
    p.usage_unit = try string(out, e, "usageUnit") orelse "";
    p.usage_unit_description = try string(out, e, "usageUnitDescription") orelse "";
    p.base_unit = try string(out, e, "baseUnit") orelse "";
    p.base_unit_description = try string(out, e, "baseUnitDescription") orelse "";
    p.base_unit_conversion_factor = try number(e, "baseUnitConversionFactor") orelse 0;
    p.display_quantity = try number(e, "displayQuantity") orelse 0;
    const rates = try field(e, "tieredRates", .array) orelse return;
    const tiers = try out.alloc(types.Tier, rates.items.len);
    for (rates.items, tiers) |item, *t| {
        const r = try object(item);
        t.* = .{
            .start_usage = try number(r, "startUsageAmount") orelse 0,
            .unit_price = try money(out, try field(r, "unitPrice", .object) orelse return error.InvalidResponse),
        };
    }
    p.tiers = tiers;
}

/// `google.type.Money`: `units` an int64 (a JSON string, as proto3 writes
/// one), `nanos` an int32 of the same sign.
fn money(out: Allocator, obj: ObjectMap) DecodeError!types.Money {
    const m: types.Money = .{
        .currency = try string(out, obj, "currencyCode") orelse "",
        .units = try integer(i64, obj, "units") orelse 0,
        .nanos = try integer(i32, obj, "nanos") orelse 0,
    };
    if (!m.isValid()) return error.InvalidResponse;
    return m;
}

/// The segment after the last `/`, or the whole name.
fn trailing(name: []const u8) []const u8 {
    if (std.mem.lastIndexOfScalar(u8, name, '/')) |i| return name[i + 1 ..];
    return name;
}

fn parse(scratch: Allocator, body: []const u8) DecodeError!Value {
    return std.json.parseFromSliceLeaky(Value, scratch, body, .{ .parse_numbers = false }) catch |err| switch (err) {
        error.OutOfMemory => error.OutOfMemory,
        else => error.InvalidResponse,
    };
}

fn object(v: Value) DecodeError!ObjectMap {
    return switch (v) {
        .object => |o| o,
        else => error.InvalidResponse,
    };
}

fn field(obj: ObjectMap, name: []const u8, comptime tag: std.meta.Tag(Value)) DecodeError!?@FieldType(Value, @tagName(tag)) {
    const v = obj.get(name) orelse return null;
    if (v == .null) return null;
    if (v != tag) return error.InvalidResponse;
    return @field(v, @tagName(tag));
}

fn string(out: Allocator, obj: ObjectMap, name: []const u8) DecodeError!?[]const u8 {
    const text = try field(obj, name, .string) orelse return null;
    return try out.dupe(u8, text);
}

fn stringList(out: Allocator, obj: ObjectMap, name: []const u8) DecodeError![]const []const u8 {
    const list = try field(obj, name, .array) orelse return &.{};
    const items = try out.alloc([]const u8, list.items.len);
    for (list.items, items) |v, *s| s.* = switch (v) {
        .string => |text| try out.dupe(u8, text),
        else => return error.InvalidResponse,
    };
    return items;
}

/// `nextPageToken`: "" means the last page, as production sends it.
fn token(out: Allocator, obj: ObjectMap) DecodeError!?[]const u8 {
    const text = try field(obj, "nextPageToken", .string) orelse return null;
    if (text.len == 0) return null;
    return try out.dupe(u8, text);
}

fn time(obj: ObjectMap, name: []const u8) DecodeError!?std.Io.Timestamp {
    const text = try field(obj, name, .string) orelse return null;
    return core.timestamp.parse(text) catch error.InvalidResponse;
}

/// An integer that may arrive as a JSON number or a string, as proto3
/// JSON allows.
fn integer(comptime T: type, obj: ObjectMap, name: []const u8) DecodeError!?T {
    const v = obj.get(name) orelse return null;
    const text = switch (v) {
        .null => return null,
        .number_string, .string => |s| s,
        else => return error.InvalidResponse,
    };
    return std.fmt.parseInt(T, text, 10) catch error.InvalidResponse;
}

/// A double: a JSON number, or a string as proto3 JSON may write one. Not a
/// number or not finite is refused: nothing here can use one.
fn number(obj: ObjectMap, name: []const u8) DecodeError!?f64 {
    const v = obj.get(name) orelse return null;
    const text = switch (v) {
        .null => return null,
        .number_string, .string => |s| s,
        else => return error.InvalidResponse,
    };
    const x = std.fmt.parseFloat(f64, text) catch return error.InvalidResponse;
    if (!std.math.isFinite(x)) return error.InvalidResponse;
    return x;
}

const testing = std.testing;
const production = @import("production_bodies.zig");

fn ts(text: []const u8) std.Io.Timestamp {
    return core.timestamp.parse(text) catch unreachable;
}

test "decodeServicePage: production's pages, and the last page's empty token" {
    var out: std.heap.ArenaAllocator = .init(testing.allocator);
    defer out.deinit();
    var scratch: std.heap.ArenaAllocator = .init(testing.allocator);
    defer scratch.deinit();
    const a = out.allocator();
    const s = scratch.allocator();

    const page = try decodeServicePage(a, s, production.services_small);
    try testing.expectEqual(3, page.services.len);
    try testing.expectEqualStrings("0017-8C5E-5B91", page.services[0].id);
    try testing.expectEqualStrings("services/0017-8C5E-5B91", page.services[0].name);
    try testing.expectEqualStrings("businessEntities/GCP", page.services[0].business_entity);
    try testing.expect(page.services[0].display_name.len > 0);
    // The token is the offset in base64: 3.
    try testing.expectEqualStrings("Mw==", page.next_page_token.?);
    const next = try decodeServicePage(a, s, production.services_small_p2);
    try testing.expectEqual(3, next.services.len);
    try testing.expect(std.mem.order(u8, page.services[2].id, next.services[0].id) == .lt);

    const last = try decodeServicePage(a, s, "{\"services\":[],\"nextPageToken\":\"\"}");
    try testing.expectEqual(0, last.services.len);
    try testing.expectEqual(null, last.next_page_token);
    const bare = try decodeServicePage(a, s, "{\"services\":[{\"name\":\"services/AAAA-BBBB-CCCC\"}]}");
    try testing.expectEqualStrings("AAAA-BBBB-CCCC", bare.services[0].id);
}

test "decodeSku: E2's vCPU and memory, on demand and spot, as production priced them" {
    var out: std.heap.ArenaAllocator = .init(testing.allocator);
    defer out.deinit();
    var scratch: std.heap.ArenaAllocator = .init(testing.allocator);
    defer scratch.deinit();
    const a = out.allocator();
    const s = scratch.allocator();

    const core_sku = try decodeSku(a, s, production.sku_e2_core_americas);
    try testing.expectEqualStrings("CF4E-A0C7-E3BF", core_sku.id);
    try testing.expectEqualStrings("E2 Instance Core running in Americas", core_sku.description);
    try testing.expectEqualStrings("Compute", core_sku.resource_family);
    try testing.expectEqualStrings("CPU", core_sku.resource_group);
    try testing.expectEqual(types.UsageType.on_demand, core_sku.usage_type);
    try testing.expectEqualStrings("OnDemand", core_sku.usage_type_text);
    try testing.expectEqual(3, core_sku.service_regions.len);
    try testing.expect(core_sku.offeredIn("us-east1"));
    try testing.expectEqual(types.GeoType.multi_regional, core_sku.geo.type);
    try testing.expectEqualStrings("Google", core_sku.service_provider);
    const price = core_sku.latest().?;
    try testing.expectEqual(ts("2026-11-04T08:00:00Z"), price.effective_time);
    try testing.expectEqualStrings("h", price.usage_unit);
    try testing.expectEqualStrings("s", price.base_unit);
    try testing.expectEqual(3600, price.base_unit_conversion_factor);
    try testing.expectEqual(1, price.currency_conversion_rate);
    try testing.expectEqual(1, price.tiers.len);
    try testing.expectEqual(0, price.tiers[0].start_usage);
    try testing.expectEqual(21_811_590, price.unitPrice().?.toNanos());
    try testing.expectEqualStrings("USD", price.unitPrice().?.currency);

    const ram = try decodeSku(a, s, production.sku_e2_ram_americas);
    try testing.expectEqualStrings("RAM", ram.resource_group);
    try testing.expectEqualStrings("GiBy.h", ram.latest().?.usage_unit);
    try testing.expectEqual(2_923_530, ram.latest().?.unitPrice().?.toNanos());

    const spot = try decodeSku(a, s, production.sku_e2_spot_core_americas);
    try testing.expectEqual(types.UsageType.preemptible, spot.usage_type);
    try testing.expectEqualStrings("Spot Preemptible E2 Instance Core running in Americas", spot.description);
    try testing.expectEqual(13_090_000, spot.latest().?.unitPrice().?.toNanos());
    try testing.expectEqual(1_754_000, (try decodeSku(a, s, production.sku_e2_spot_ram_americas)).latest().?.unitPrice().?.toNanos());

    const belgium = try decodeSku(a, s, production.sku_e2_core_belgium);
    try testing.expectEqual(1, belgium.service_regions.len);
    try testing.expectEqualStrings("europe-west1", belgium.service_regions[0]);
    try testing.expectEqual(types.GeoType.regional, belgium.geo.type);
}

test "decodeSkuPage: pages, EUR and October's timeline as production answered them" {
    var out: std.heap.ArenaAllocator = .init(testing.allocator);
    defer out.deinit();
    var scratch: std.heap.ArenaAllocator = .init(testing.allocator);
    defer scratch.deinit();
    const a = out.allocator();
    const s = scratch.allocator();

    const page = try decodeSkuPage(a, s, production.skus_small);
    try testing.expectEqual(2, page.skus.len);
    try testing.expectEqualStrings("Mg==", page.next_page_token.?);
    try testing.expectEqualStrings("0001-B904-8A40", page.skus[0].id);
    try testing.expectEqual(4_954_950, page.skus[0].latest().?.unitPrice().?.toNanos());

    // EUR: the same SKUs, prices converted and truncated, with the rate.
    const eur = try decodeSkuPage(a, s, production.skus_eur);
    const eur_price = eur.skus[0].latest().?;
    try testing.expectEqualStrings("EUR", eur_price.unitPrice().?.currency);
    try testing.expectEqual(4_450_040, eur_price.unitPrice().?.toNanos());
    try testing.expect(eur_price.currency_conversion_rate > 0.89 and eur_price.currency_conversion_rate < 0.9);

    // October: the second SKU's price changed four times; the first entry
    // took effect at the range's start, the rest oldest first.
    const october = try decodeSkuPage(a, s, production.skus_october);
    const timeline = october.skus[1].pricing;
    try testing.expectEqual(5, timeline.len);
    try testing.expectEqual(ts("2026-10-01T07:00:00Z"), timeline[0].effective_time);
    for (timeline[0 .. timeline.len - 1], timeline[1..]) |earlier, later| {
        try testing.expect(earlier.effective_time.nanoseconds < later.effective_time.nanoseconds);
    }
    try testing.expectEqual(1, october.skus[0].pricing.len);
}

test "decoders: lenient where they can be, InvalidResponse where they cannot" {
    var out: std.heap.ArenaAllocator = .init(testing.allocator);
    defer out.deinit();
    var scratch: std.heap.ArenaAllocator = .init(testing.allocator);
    defer scratch.deinit();
    const a = out.allocator();
    const s = scratch.allocator();

    // The least a SKU can be, unknown words, and an aggregation.
    const bare = try decodeSku(a, s, "{\"name\":\"services/S/skus/AAAA-BBBB-CCCC\",\"brandNew\":[1]}");
    try testing.expectEqualStrings("AAAA-BBBB-CCCC", bare.id);
    try testing.expectEqual(types.UsageType.other, bare.usage_type);
    try testing.expectEqual(types.GeoType.unspecified, bare.geo.type);
    try testing.expectEqual(null, bare.latest());
    const strange = try decodeSku(a, s,
        \\{"name":"n","category":{"usageType":"CmtCudPremium"},"geoTaxonomy":{"type":"PLANETARY"},
        \\ "pricingInfo":[{"effectiveTime":"2026-11-04T08:00:00Z","currencyConversionRate":"1.5",
        \\  "aggregationInfo":{"aggregationLevel":"ACCOUNT","aggregationInterval":"MONTHLY","aggregationCount":1},
        \\  "pricingExpression":{"tieredRates":[{"startUsageAmount":20,"unitPrice":{"units":"10"}},{"startUsageAmount":100,"unitPrice":{"units":5,"nanos":-0}}]}}]}
    );
    try testing.expectEqual(types.UsageType.other, strange.usage_type);
    try testing.expectEqualStrings("CmtCudPremium", strange.usage_type_text);
    try testing.expectEqual(types.GeoType.other, strange.geo.type);
    const p = strange.latest().?;
    try testing.expectEqual(1.5, p.currency_conversion_rate);
    try testing.expectEqualStrings("MONTHLY", p.aggregation.?.interval);
    try testing.expectEqual(20, p.tiers[0].start_usage);
    try testing.expectEqual(10_000_000_000, p.tiers[0].unit_price.toNanos());
    try testing.expectEqual(5_000_000_000, p.tiers[1].unit_price.toNanos());

    for ([_][]const u8{
        "[]",
        "{\"skus\":1}",
        "{\"services\":[{\"serviceId\":\"x\"}]}",
        "{\"skus\":[{\"skuId\":\"x\"}]}",
        "{\"name\":\"n\",\"serviceRegions\":[1]}",
        "{\"name\":\"n\",\"pricingInfo\":[{}]}",
        "{\"name\":\"n\",\"pricingInfo\":[{\"effectiveTime\":\"today\"}]}",
        "{\"name\":\"n\",\"pricingInfo\":[{\"effectiveTime\":\"2026-11-04T08:00:00Z\",\"pricingExpression\":{\"tieredRates\":[{}]}}]}",
        "{\"name\":\"n\",\"pricingInfo\":[{\"effectiveTime\":\"2026-11-04T08:00:00Z\",\"pricingExpression\":{\"tieredRates\":[{\"unitPrice\":{\"units\":\"1\",\"nanos\":-5}}]}}]}",
        "{\"name\":\"n\",\"pricingInfo\":[{\"effectiveTime\":\"2026-11-04T08:00:00Z\",\"pricingExpression\":{\"tieredRates\":[{\"unitPrice\":{\"nanos\":1000000000}}]}}]}",
        "{\"name\":\"n\",\"pricingInfo\":[{\"effectiveTime\":\"2026-11-04T08:00:00Z\",\"currencyConversionRate\":\"NaN\"}]}",
        "{\"name\":\"n\",\"pricingInfo\":[{\"effectiveTime\":\"2026-11-04T08:00:00Z\",\"pricingExpression\":{\"baseUnitConversionFactor\":true}}]}",
    }) |body| {
        const sku_err = decodeSku(a, s, body);
        const page_err = decodeSkuPage(a, s, body);
        const services_err = decodeServicePage(a, s, body);
        try testing.expect(sku_err == error.InvalidResponse or page_err == error.InvalidResponse or services_err == error.InvalidResponse);
    }
}

fn decodersProperty(_: void, input: []const u8) !void {
    const test_util = @import("test_util.zig");
    var out: std.heap.ArenaAllocator = .init(test_util.propertyAllocator());
    defer out.deinit();
    var scratch: std.heap.ArenaAllocator = .init(test_util.propertyAllocator());
    defer scratch.deinit();
    const a = out.allocator();
    const s = scratch.allocator();
    inline for (.{ decodeServicePage, decodeSkuPage, decodeSku }) |decode| {
        if (decode(a, s, input)) |_| {} else |err| try testing.expectEqual(error.InvalidResponse, err);
    }
}

test "fuzz decoders: any body decodes or is InvalidResponse, never a crash or a leak" {
    try @import("test_util.zig").fuzzBytes({}, decodersProperty, .{ .corpus = &.{
        production.services_small,
        production.skus_small,
        production.skus_october,
        production.sku_e2_core_americas,
        "{\"name\":\"n\",\"pricingInfo\":[{\"effectiveTime\":\"2026-11-04T08:00:00Z\",\"pricingExpression\":{\"tieredRates\":[{\"unitPrice\":{\"units\":\"-1\",\"nanos\":-5}}]}}]}",
    } });
}
