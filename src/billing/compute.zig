//! What a Compute Engine machine type costs an hour, on demand and spot,
//! from Compute Engine's SKUs: `PriceList`. Measured on 2026-11-04: a
//! machine's vCPUs and memory are priced by separate SKUs, named only in
//! their descriptions ("E2 Instance Core running in Americas", "Spot
//! Preemptible E2 Instance Ram ..."), one per family and region, and
//! us-central1, us-east1 and us-west1 share one SKU per family.
//!
//! The families priced are the ones a vCPU and a memory SKU price whole:
//! e2 (and its shared-core e2-micro, e2-small and e2-medium, billed as a
//! quarter, a half and one vCPU), n1, n2, n2d, n4, n4a, n4d, c2, c2d, c3,
//! c3d, c4, c4a, c4d, c4n, t2a, t2d, h3, m3, z3, and f1-micro and
//! g1-small, priced per VM. Left out, and counted as such: M1 and M2
//! (their SKUs cannot be told apart in three regions, and M2 adds a
//! premium SKU), the M4 family, the GPU families (A2, A3, G2, G4, whose
//! GPUs are priced apart), H4D, Z4D and Z4M; and every custom, extended,
//! sole-tenancy, committed or reserved price.

const std = @import("std");
const Allocator = std.mem.Allocator;
const Timestamp = std.Io.Timestamp;
const core = @import("core");
const types = @import("types.zig");

/// How a VM is bought.
pub const Model = enum {
    on_demand,
    /// Spot VMs: the SKUs whose usage type is `Preemptible`.
    spot,
};

/// A machine type's size, as Compute Engine reports it:
/// `compute.Client.getMachineType` answers `guest_cpus` and `memory_mb`.
pub const Machine = struct {
    /// Such as `e2-standard-2`: the series before the first `-` picks the
    /// SKUs, and a shared-core type its fraction of a vCPU.
    name: []const u8,
    vcpus: u32,
    /// Mebibytes: e2-standard-2 has 8192.
    memory_mb: u64,
};

/// What a machine type costs an hour in a region.
pub const Price = struct {
    currency: []const u8,
    /// Billionths of the currency, rounded to the nearest: $0.067011420
    /// is 67,011,420.
    nanos_per_hour: i128,
    /// The vCPU SKU, or the one per-VM SKU for f1-micro and g1-small.
    core_sku: []const u8,
    /// The memory SKU; "" for f1-micro and g1-small.
    ram_sku: []const u8 = "",
    /// The later of the two prices' effective times.
    effective_time: Timestamp,
};

/// Why a SKU did not go into the list. `PriceList.skipped` counts each.
pub const Skip = enum {
    /// Not `resourceFamily` Compute: network, storage, licenses.
    not_compute,
    /// Neither on demand nor spot: a commitment.
    usage,
    /// Not a vCPU, memory or per-VM SKU: GPUs, local SSD, TPUs.
    resource_group,
    /// Custom, extended, sole tenancy, committed, reserved, premiums.
    wording,
    /// A family left out on purpose (see the top of this file).
    excluded_family,
    /// A family this list does not know.
    unknown_family,
    /// A unit, tier or conversion factor it cannot price exactly.
    unit,
    /// No price at all.
    no_price,
    /// A second SKU for the same family, region, model and part: both are
    /// dropped, as "Memory-optimized" has two in three regions.
    duplicate,
};

/// The parts of a machine a SKU prices.
const Part = enum { core, ram, vm };

/// One SKU's latest price, per usage unit, and how many base units (a
/// vCPU-second, a byte-second) make that unit.
const Rate = struct {
    sku: []const u8,
    nanos: i128,
    factor: u64,
    effective_time: Timestamp,
};

/// The families priced, by series, with their SKUs' description stem.
const families = [_]struct { series: []const u8, stem: []const u8 }{
    .{ .series = "e2", .stem = "E2" },
    .{ .series = "n1", .stem = "N1 Predefined" },
    .{ .series = "n2", .stem = "N2" },
    .{ .series = "n2d", .stem = "N2D AMD" },
    .{ .series = "n4", .stem = "N4" },
    .{ .series = "n4a", .stem = "N4A" },
    .{ .series = "n4d", .stem = "N4D" },
    .{ .series = "c2", .stem = "Compute optimized" },
    .{ .series = "c2d", .stem = "C2D AMD" },
    .{ .series = "c3", .stem = "C3" },
    .{ .series = "c3d", .stem = "C3D" },
    .{ .series = "c4", .stem = "C4" },
    .{ .series = "c4a", .stem = "C4A Arm" },
    .{ .series = "c4d", .stem = "C4D" },
    .{ .series = "c4n", .stem = "C4N" },
    .{ .series = "t2a", .stem = "T2A Arm" },
    .{ .series = "t2d", .stem = "T2D AMD" },
    .{ .series = "h3", .stem = "H3" },
    .{ .series = "m3", .stem = "M3 Memory-optimized" },
    .{ .series = "z3", .stem = "Z3" },
    .{ .series = "f1", .stem = "Micro Instance with burstable CPU" },
    .{ .series = "g1", .stem = "Small Instance with 1 VCPU" },
};

/// Stems left out on purpose, so they count apart from the unknown.
const excluded_stems = [_][]const u8{ "Memory-optimized", "M4", "M4N", "M4Ultramem224", "M4NUltramem224", "A2", "A3", "A3Plus", "A3Ultra", "G2", "G4", "H4D", "H4D-Megamem-192", "Z4D-HIGHMEM-HIGHLSSD", "Z4D-HIGHMEM-STANDARDLSSD", "Z4M" };

/// Words in a description that make a SKU something other than a plain
/// machine's price.
const skip_words = [_][]const u8{ "Custom", "Sole Tenancy", "Commit", "Reserved", "Premium", "Extended", "Upgrade", "Licens", "DWS", "Calendar", "Flex", "Reservation", "Dynamic Workload" };

/// e2's shared-core types, in quarters of the vCPU they are billed for
/// (Google's machine docs: 0.25, 0.5 and 1).
const shared_core = [_]struct { name: []const u8, quarters: u32 }{
    .{ .name = "e2-micro", .quarters = 1 },
    .{ .name = "e2-small", .quarters = 2 },
    .{ .name = "e2-medium", .quarters = 4 },
};

/// Machine prices by family, region and model, built from Compute
/// Engine's SKUs a page at a time with `add`, or read back from the small
/// form `write` gives.
pub const PriceList = struct {
    arena: *std.heap.ArenaAllocator,
    /// The currency of every price, from the first SKU added; "" until
    /// then.
    currency: []const u8 = "",
    rates: std.StringHashMapUnmanaged(Rate) = .empty,
    /// Keys seen twice: dropped, and kept out.
    duplicates: std.StringHashMapUnmanaged(void) = .empty,
    skipped: std.EnumArray(Skip, u32) = .initFill(0),
    /// SKUs taken in.
    kept: u32 = 0,

    pub const Error = Allocator.Error || error{
        /// A SKU priced in another currency than the ones before it.
        MixedCurrencies,
    };

    pub fn init(gpa: Allocator) Allocator.Error!PriceList {
        const arena = try gpa.create(std.heap.ArenaAllocator);
        arena.* = .init(gpa);
        return .{ .arena = arena };
    }

    pub fn deinit(self: *PriceList) void {
        const gpa = self.arena.child_allocator;
        self.arena.deinit();
        gpa.destroy(self.arena);
        self.* = undefined;
    }

    /// Takes in a page of Compute Engine's SKUs, keeping the plain machine
    /// prices and counting the rest in `skipped`. The SKUs need not
    /// outlive the call.
    pub fn add(self: *PriceList, skus: []const types.Sku) Error!void {
        for (skus) |sku| try self.addOne(sku);
    }

    fn addOne(self: *PriceList, sku: types.Sku) Error!void {
        const c = switch (classify(sku)) {
            .ok => |c| c,
            .skip => |why| {
                self.skipped.getPtr(why).* += 1;
                return;
            },
        };
        const price = sku.latest().?;
        const money = price.unitPrice().?;
        if (self.currency.len == 0) {
            self.currency = try self.arena.allocator().dupe(u8, money.currency);
        } else if (!std.mem.eql(u8, self.currency, money.currency)) return error.MixedCurrencies;
        const rate: Rate = .{
            .sku = try self.arena.allocator().dupe(u8, sku.id),
            .nanos = money.toNanos(),
            .factor = c.factor,
            .effective_time = price.effective_time,
        };
        for (sku.service_regions) |region| try self.put(c.series, region, c.model, c.part, rate);
        self.kept += 1;
    }

    fn put(self: *PriceList, series: []const u8, region: []const u8, model: Model, part: Part, rate: Rate) Allocator.Error!void {
        const a = self.arena.allocator();
        const key = try keyOf(a, series, region, model, part);
        if (self.duplicates.contains(key)) return;
        const slot = try self.rates.getOrPut(a, key);
        if (slot.found_existing) {
            _ = self.rates.remove(key);
            try self.duplicates.put(a, key, {});
            self.skipped.getPtr(.duplicate).* += 1;
            return;
        }
        slot.value_ptr.* = rate;
    }

    /// What `machine` costs an hour in `region` (such as `us-central1`),
    /// or null when this list cannot say: a family left out, a custom
    /// type, or no SKU for that region and model.
    pub fn hourly(self: *const PriceList, machine: Machine, region: []const u8, model: Model) ?Price {
        if (std.mem.indexOf(u8, machine.name, "custom") != null) return null;
        const series = seriesOf(machine.name);
        if (std.mem.eql(u8, series, "f1") or std.mem.eql(u8, series, "g1")) {
            const vm = self.rateOf(series, region, model, .vm) orelse return null;
            return .{ .currency = self.currency, .nanos_per_hour = perHour(vm, 1, 1), .core_sku = vm.sku, .effective_time = vm.effective_time };
        }
        const core_rate = self.rateOf(series, region, model, .core) orelse return null;
        const ram_rate = self.rateOf(series, region, model, .ram) orelse return null;
        const quarters: u64 = quartersOf(machine);
        const bytes: u64 = machine.memory_mb * 1024 * 1024;
        // One rounding, of the exact sum: each part is nanos per usage unit
        // times base units an hour, over base units per usage unit.
        const num = core_rate.nanos * quarters * 3600 * ram_rate.factor +
            ram_rate.nanos * bytes * 3600 * 4 * core_rate.factor;
        const den: i128 = @as(i128, 4) * core_rate.factor * ram_rate.factor;
        return .{
            .currency = self.currency,
            .nanos_per_hour = roundDiv(num, den),
            .core_sku = core_rate.sku,
            .ram_sku = ram_rate.sku,
            .effective_time = if (core_rate.effective_time.nanoseconds >= ram_rate.effective_time.nanoseconds) core_rate.effective_time else ram_rate.effective_time,
        };
    }

    fn rateOf(self: *const PriceList, series: []const u8, region: []const u8, model: Model, part: Part) ?Rate {
        var buf: [128]u8 = undefined;
        const key = std.fmt.bufPrint(&buf, key_format, keyArgs(series, region, model, part)) catch return null;
        return self.rates.get(key);
    }

    /// The list alone, as JSON: a few hundred kilobytes where Compute
    /// Engine's SKUs are 46 MB, for a cache that `read` takes back.
    pub fn write(self: *const PriceList, w: *std.Io.Writer) std.Io.Writer.Error!void {
        var jw: std.json.Stringify = .{ .writer = w };
        try jw.beginObject();
        try jw.objectField("currency");
        try jw.write(self.currency);
        try jw.objectField("rates");
        try jw.beginArray();
        const keys = try sortedKeys(self);
        defer self.arena.child_allocator.free(keys);
        for (keys) |key| {
            const r = self.rates.get(key).?;
            var buf: [core.timestamp.max_len]u8 = undefined;
            try jw.write(.{
                .key = key,
                .sku = r.sku,
                .nanos = r.nanos,
                .factor = r.factor,
                .effective = core.timestamp.format(&buf, r.effective_time),
            });
        }
        try jw.endArray();
        try jw.endObject();
    }

    fn sortedKeys(self: *const PriceList) std.Io.Writer.Error![][]const u8 {
        const keys = self.arena.child_allocator.alloc([]const u8, self.rates.count()) catch return error.WriteFailed;
        var it = self.rates.keyIterator();
        var i: usize = 0;
        while (it.next()) |k| : (i += 1) keys[i] = k.*;
        std.mem.sortUnstable([]const u8, keys, {}, struct {
            fn lt(_: void, a: []const u8, b: []const u8) bool {
                return std.mem.order(u8, a, b) == .lt;
            }
        }.lt);
        return keys;
    }

    pub const ReadError = Allocator.Error || error{
        /// Not a list `write` wrote.
        InvalidPriceList,
    };

    /// A list `write` wrote.
    pub fn read(gpa: Allocator, text: []const u8) ReadError!PriceList {
        var list: PriceList = try .init(gpa);
        errdefer list.deinit();
        const a = list.arena.allocator();
        const Stored = struct {
            currency: []const u8,
            rates: []const struct { key: []const u8, sku: []const u8, nanos: i128, factor: u64, effective: []const u8 },
        };
        const stored = std.json.parseFromSliceLeaky(Stored, a, text, .{ .ignore_unknown_fields = true, .allocate = .alloc_always }) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            else => return error.InvalidPriceList,
        };
        list.currency = stored.currency;
        for (stored.rates) |r| {
            if (r.factor == 0 or !isKey(r.key)) return error.InvalidPriceList;
            const effective = core.timestamp.parse(r.effective) catch return error.InvalidPriceList;
            const slot = try list.rates.getOrPut(a, r.key);
            if (slot.found_existing) return error.InvalidPriceList;
            slot.value_ptr.* = .{ .sku = r.sku, .nanos = r.nanos, .factor = r.factor, .effective_time = effective };
        }
        return list;
    }
};

const Classified = struct { series: []const u8, model: Model, part: Part, factor: u64 };

/// A SKU's model, and whether it prices a whole VM; or why it prices no
/// plain machine at all.
fn kindOf(sku: types.Sku) union(enum) { ok: struct { model: Model, per_vm: bool }, skip: Skip } {
    if (!std.mem.eql(u8, sku.resource_family, "Compute")) return .{ .skip = .not_compute };
    const model: Model = switch (sku.usage_type) {
        .on_demand => .on_demand,
        .preemptible => .spot,
        else => return .{ .skip = .usage },
    };
    const per_vm = isOneOf(sku.resource_group, &.{ "F1Micro", "G1Small" });
    if (!per_vm and !isOneOf(sku.resource_group, &.{ "CPU", "RAM", "N1Standard" })) return .{ .skip = .resource_group };
    for (skip_words) |word| if (std.mem.indexOf(u8, sku.description, word) != null) return .{ .skip = .wording };
    return .{ .ok = .{ .model = model, .per_vm = per_vm } };
}

fn isOneOf(text: []const u8, options: []const []const u8) bool {
    for (options) |o| if (std.mem.eql(u8, text, o)) return true;
    return false;
}

/// Whether `sku` is a plain machine price, and of what; or why not.
fn classify(sku: types.Sku) union(enum) { ok: Classified, skip: Skip } {
    const kind = switch (kindOf(sku)) {
        .ok => |k| k,
        .skip => |why| return .{ .skip = why },
    };
    const model = kind.model;
    const shape = shapeOf(sku.description, model);
    const part: Part = if (kind.per_vm) .vm else shape.part orelse return .{ .skip = .unit };
    const series = switch (seriesOfStem(shape.stem)) {
        .series => |s| s,
        .skip => |why| return .{ .skip = why },
    };
    const price = sku.latest() orelse return .{ .skip = .no_price };
    if (price.tiers.len != 1 or price.tiers[0].start_usage != 0) return .{ .skip = .unit };
    const factor = factorOf(price, part) orelse return .{ .skip = .unit };
    return .{ .ok = .{ .series = series, .model = model, .part = part, .factor = factor } };
}

/// A description's stem and the part it prices: "Spot Preemptible E2
/// Instance Core running in Americas" is `E2`, a core.
fn shapeOf(description: []const u8, model: Model) struct { stem: []const u8, part: ?Part } {
    var d = description;
    if (model == .spot) d = trimPrefix(d, "Spot Preemptible ");
    if (std.mem.indexOf(u8, d, " running in ")) |i| d = d[0..i] else if (std.mem.lastIndexOf(u8, d, " in ")) |i| d = d[0..i];
    var part: ?Part = null;
    if (std.mem.endsWith(u8, d, " Core")) {
        part = .core;
        d = d[0 .. d.len - " Core".len];
    } else if (std.mem.endsWith(u8, d, " Ram")) {
        part = .ram;
        d = d[0 .. d.len - " Ram".len];
    }
    // Production wrote one stem with no space before it: "M4NUltramem224Instance Ram".
    if (part != null and std.mem.endsWith(u8, d, "Instance")) d = std.mem.trimEnd(u8, d[0 .. d.len - "Instance".len], " ");
    return .{ .stem = d, .part = part };
}

fn seriesOfStem(stem: []const u8) union(enum) { series: []const u8, skip: Skip } {
    for (families) |f| if (std.mem.eql(u8, f.stem, stem)) return .{ .series = f.series };
    for (excluded_stems) |e| if (std.mem.eql(u8, e, stem)) return .{ .skip = .excluded_family };
    return .{ .skip = .unknown_family };
}

/// Base units per usage unit, for the units this list prices: a vCPU-hour
/// is 3600 vCPU-seconds; memory is `GiBy.h` (2^30 x 3600 byte-seconds) or,
/// for C4D and M4's ultramem types, `GBy.h` (10^9 x 3600), measured.
fn factorOf(price: types.Pricing, part: Part) ?u64 {
    const f = price.base_unit_conversion_factor;
    if (!(f >= 1 and f <= 1e15) or @trunc(f) != f) return null;
    const factor: u64 = @intFromFloat(f);
    const ok = switch (part) {
        .core, .vm => std.mem.eql(u8, price.usage_unit, "h") and factor == 3600,
        .ram => (std.mem.eql(u8, price.usage_unit, "GiBy.h") or std.mem.eql(u8, price.usage_unit, "GBy.h")) and factor % 3600 == 0,
    };
    return if (ok) factor else null;
}

fn trimPrefix(text: []const u8, prefix: []const u8) []const u8 {
    return if (std.mem.startsWith(u8, text, prefix)) text[prefix.len..] else text;
}

fn seriesOf(name: []const u8) []const u8 {
    return name[0 .. std.mem.indexOfScalar(u8, name, '-') orelse name.len];
}

/// The vCPUs a machine is billed for, in quarters.
fn quartersOf(machine: Machine) u64 {
    for (shared_core) |s| if (std.mem.eql(u8, s.name, machine.name)) return s.quarters;
    return @as(u64, machine.vcpus) * 4;
}

fn perHour(r: Rate, units: i128, per: i128) i128 {
    return roundDiv(r.nanos * units * 3600, @as(i128, r.factor) * per);
}

/// `num / den` rounded to the nearest, halves away from zero; `den > 0`.
fn roundDiv(num: i128, den: i128) i128 {
    const q = @divTrunc(num, den);
    const r = @rem(num, den);
    if (2 * @abs(r) >= den) return if (num < 0) q - 1 else q + 1;
    return q;
}

const key_format = "{s}|{s}|{s}|{s}";

fn keyArgs(series: []const u8, region: []const u8, model: Model, part: Part) struct { []const u8, []const u8, []const u8, []const u8 } {
    return .{ series, region, @tagName(model), @tagName(part) };
}

fn keyOf(a: Allocator, series: []const u8, region: []const u8, model: Model, part: Part) Allocator.Error![]const u8 {
    return std.fmt.allocPrint(a, key_format, keyArgs(series, region, model, part));
}

fn isKey(key: []const u8) bool {
    var parts = std.mem.splitScalar(u8, key, '|');
    var n: usize = 0;
    while (parts.next()) |p| : (n += 1) if (p.len == 0) return false;
    return n == 4;
}

const testing = std.testing;
const codec = @import("codec.zig");
const production = @import("production_bodies.zig");

fn ts(text: []const u8) Timestamp {
    return core.timestamp.parse(text) catch unreachable;
}

/// The five E2 SKUs production answered, decoded, in a list.
fn productionList(arena: *std.heap.ArenaAllocator) !PriceList {
    var list: PriceList = try .init(testing.allocator);
    errdefer list.deinit();
    const a = arena.allocator();
    var skus: [5]types.Sku = undefined;
    for ([_][]const u8{
        production.sku_e2_core_americas,
        production.sku_e2_ram_americas,
        production.sku_e2_spot_core_americas,
        production.sku_e2_spot_ram_americas,
        production.sku_e2_core_belgium,
    }, &skus) |body, *sku| sku.* = try codec.decodeSku(a, a, body);
    try list.add(&skus);
    return list;
}

test "production's E2 SKUs price e2 machines as production priced them" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    var list = try productionList(&arena);
    defer list.deinit();
    try testing.expectEqualStrings("USD", list.currency);
    try testing.expectEqual(5, list.kept);

    // e2-standard-2: 2 x 0.02181159 + 8 x 0.00292353.
    const std2: Machine = .{ .name = "e2-standard-2", .vcpus = 2, .memory_mb = 8192 };
    const on_demand = list.hourly(std2, "us-central1", .on_demand).?;
    try testing.expectEqual(67_011_420, on_demand.nanos_per_hour);
    try testing.expectEqualStrings("CF4E-A0C7-E3BF", on_demand.core_sku);
    try testing.expectEqualStrings("F449-33EC-A5EF", on_demand.ram_sku);
    try testing.expectEqual(ts("2026-11-04T08:00:00Z"), on_demand.effective_time);
    try testing.expectEqual(40_212_000, list.hourly(std2, "us-central1", .spot).?.nanos_per_hour);
    // One SKU for the three "Americas" regions.
    try testing.expectEqual(67_011_420, list.hourly(std2, "us-west1", .on_demand).?.nanos_per_hour);
    // Belgium has a vCPU SKU here and no memory SKU: no price.
    try testing.expectEqual(null, list.hourly(std2, "europe-west1", .on_demand));
    try testing.expectEqual(null, list.hourly(std2, "asia-east1", .on_demand));

    // Shared-core: a quarter, a half and a whole vCPU, rounded once.
    try testing.expectEqual(8_376_428, list.hourly(.{ .name = "e2-micro", .vcpus = 2, .memory_mb = 1024 }, "us-central1", .on_demand).?.nanos_per_hour);
    try testing.expectEqual(16_752_855, list.hourly(.{ .name = "e2-small", .vcpus = 2, .memory_mb = 2048 }, "us-central1", .on_demand).?.nanos_per_hour);
    try testing.expectEqual(33_505_710, list.hourly(.{ .name = "e2-medium", .vcpus = 2, .memory_mb = 4096 }, "us-central1", .on_demand).?.nanos_per_hour);

    // What the list cannot price.
    try testing.expectEqual(null, list.hourly(.{ .name = "e2-custom-4-8192", .vcpus = 4, .memory_mb = 8192 }, "us-central1", .on_demand));
    try testing.expectEqual(null, list.hourly(.{ .name = "n2-standard-2", .vcpus = 2, .memory_mb = 8192 }, "us-central1", .on_demand));
}

fn testSku(id: []const u8, description: []const u8, group: []const u8, usage: types.UsageType, unit: []const u8, factor: f64, nanos: i32, regions: []const []const u8) types.Sku {
    const S = struct {
        var tiers: [64][1]types.Tier = undefined;
        var prices: [64][1]types.Pricing = undefined;
        var next: usize = 0;
    };
    const i = S.next;
    S.next = (S.next + 1) % 64;
    S.tiers[i] = .{.{ .unit_price = .{ .currency = "USD", .nanos = nanos } }};
    S.prices[i] = .{.{ .effective_time = ts("2026-11-04T08:00:00Z"), .usage_unit = unit, .base_unit_conversion_factor = factor, .tiers = &S.tiers[i] }};
    return .{
        .id = id,
        .name = id,
        .description = description,
        .resource_family = "Compute",
        .resource_group = group,
        .usage_type = usage,
        .service_regions = regions,
        .pricing = &S.prices[i],
    };
}

const gib_h: f64 = 3_865_470_566_400;
const gb_h: f64 = 3_600_000_000_000;

test "memory priced per GB-hour (C4D) is converted to the machine's bytes exactly" {
    var list: PriceList = try .init(testing.allocator);
    defer list.deinit();
    try list.add(&.{
        testSku("C4D-0000-CORE", "C4D Instance Core running in Paris", "CPU", .on_demand, "h", 3600, 40_000_000, &.{"europe-west9"}),
        testSku("C4D-0000-RAMM", "C4D Instance Ram running in Paris", "RAM", .on_demand, "GBy.h", gb_h, 4_000_000, &.{"europe-west9"}),
    });
    // 2 x 0.04 + 7168 MiB (7.516192768 GB) x 0.004 = 0.110064771072.
    const price = list.hourly(.{ .name = "c4d-standard-2", .vcpus = 2, .memory_mb = 7168 }, "europe-west9", .on_demand).?;
    try testing.expectEqual(110_064_771, price.nanos_per_hour);
}

test "a price is as old as the newer of its two SKUs' prices" {
    var list: PriceList = try .init(testing.allocator);
    defer list.deinit();
    var core_sku = testSku("N2CO-0000-0000", "N2 Instance Core running in Americas", "CPU", .on_demand, "h", 3600, 31_611_000, &.{"us-central1"});
    var ram_sku = testSku("N2RA-0000-0000", "N2 Instance Ram running in Americas", "RAM", .on_demand, "GiBy.h", gib_h, 4_237_000, &.{"us-central1"});
    const old: []const types.Pricing = &.{.{ .effective_time = ts("2026-10-01T07:00:00Z"), .usage_unit = "h", .base_unit_conversion_factor = 3600, .tiers = core_sku.pricing[0].tiers }};
    core_sku.pricing = old;
    try list.add(&.{ core_sku, ram_sku });
    const p = list.hourly(.{ .name = "n2-standard-2", .vcpus = 2, .memory_mb = 8192 }, "us-central1", .on_demand).?;
    try testing.expectEqual(ts("2026-11-04T08:00:00Z"), p.effective_time);
    // And the other way round.
    var list2: PriceList = try .init(testing.allocator);
    defer list2.deinit();
    const newer: []const types.Pricing = &.{.{ .effective_time = ts("2026-11-05T08:00:00Z"), .usage_unit = "h", .base_unit_conversion_factor = 3600, .tiers = core_sku.pricing[0].tiers }};
    core_sku.pricing = newer;
    ram_sku.id = "N2RA-0000-0001";
    try list2.add(&.{ core_sku, ram_sku });
    try testing.expectEqual(ts("2026-11-05T08:00:00Z"), list2.hourly(.{ .name = "n2-standard-2", .vcpus = 2, .memory_mb = 8192 }, "us-central1", .on_demand).?.effective_time);
}

test "tiered prices are not machine prices: counted as a unit the list cannot price" {
    var list: PriceList = try .init(testing.allocator);
    defer list.deinit();
    var two = testSku("TWOT-0000-0000", "E2 Instance Core running in Americas", "CPU", .on_demand, "h", 3600, 1, &.{"us-central1"});
    const two_tiers: []const types.Tier = &.{ .{ .unit_price = .{ .nanos = 2 } }, .{ .start_usage = 100, .unit_price = .{ .nanos = 1 } } };
    const two_pricing: []const types.Pricing = &.{.{ .effective_time = ts("2026-11-04T08:00:00Z"), .usage_unit = "h", .base_unit_conversion_factor = 3600, .tiers = two_tiers }};
    two.pricing = two_pricing;
    var free_first = testSku("FREE-0000-0000", "E2 Instance Ram running in Americas", "RAM", .on_demand, "GiBy.h", gib_h, 1, &.{"us-central1"});
    const late_tiers: []const types.Tier = &.{.{ .start_usage = 20, .unit_price = .{ .nanos = 2 } }};
    const late_pricing: []const types.Pricing = &.{.{ .effective_time = ts("2026-11-04T08:00:00Z"), .usage_unit = "GiBy.h", .base_unit_conversion_factor = gib_h, .tiers = late_tiers }};
    free_first.pricing = late_pricing;
    try list.add(&.{ two, free_first });
    try testing.expectEqual(2, list.skipped.get(.unit));
    try testing.expectEqual(0, list.kept);
}

test "what goes in, what is counted out, and why" {
    var list: PriceList = try .init(testing.allocator);
    defer list.deinit();
    const r: []const []const u8 = &.{"us-central1"};
    var no_price = testSku("NOPR-0000-0000", "N2 Instance Core running in Americas", "CPU", .on_demand, "h", 3600, 1, r);
    no_price.pricing = &.{};
    var other_family = testSku("OTHE-0000-0000", "Licence", "CPU", .on_demand, "h", 3600, 1, r);
    other_family.resource_family = "License";
    try list.add(&.{
        testSku("F1MI-0000-0000", "Micro Instance with burstable CPU running in Americas", "F1Micro", .on_demand, "h", 3600, 7_600_000, r),
        testSku("SPOT-F1MI-0000", "Spot Preemptible Micro Instance with burstable CPU running in Americas", "F1Micro", .preemptible, "h", 3600, 3_500_000, r),
        testSku("N1CO-0000-0000", "N1 Predefined Instance Core running in Americas", "N1Standard", .on_demand, "h", 3600, 31_611_000, r),
        testSku("N1RA-0000-0000", "N1 Predefined Instance Ram running in Americas", "N1Standard", .on_demand, "GiBy.h", gib_h, 4_237_000, r),
        other_family,
        testSku("CMMT-0000-0000", "Commitment v1: E2 Cpu in Americas for 1 Year", "CPU", .commit_1yr, "h", 3600, 1, r),
        testSku("GPUS-0000-0000", "Nvidia Tesla T4 GPU running in Americas", "GPU", .on_demand, "h", 3600, 1, r),
        testSku("CUST-0000-0000", "E2 Custom Instance Core running in Americas", "CPU", .on_demand, "h", 3600, 1, r),
        testSku("SOLE-0000-0000", "Sole Tenancy Premium for C4 Sole Tenancy Instance Core running in Americas", "CPU", .on_demand, "h", 3600, 1, r),
        testSku("MEMO-0000-0000", "Memory-optimized Instance Core running in Americas", "CPU", .on_demand, "h", 3600, 1, r),
        testSku("A2CO-0000-0000", "A2 Instance Core running in Americas", "CPU", .on_demand, "h", 3600, 1, r),
        testSku("NEWF-0000-0000", "X9 Instance Core running in Americas", "CPU", .on_demand, "h", 3600, 1, r),
        testSku("M4NU-0000-0000", "M4NUltramem224Instance Ram running in Americas", "RAM", .on_demand, "GiBy.h", gib_h, 1, r),
        testSku("UNIT-0000-0000", "N2 Instance Ram running in Americas", "RAM", .on_demand, "GiBy.mo", gib_h, 1, r),
        no_price,
        // Two vCPU SKUs for N4 in one region: neither is trusted.
        testSku("N4C1-0000-0000", "N4 Instance Core running in Americas", "CPU", .on_demand, "h", 3600, 1, r),
        testSku("N4C2-0000-0000", "N4 Instance Core running in Iowa", "CPU", .on_demand, "h", 3600, 2, r),
        testSku("N4RA-0000-0000", "N4 Instance Ram running in Americas", "RAM", .on_demand, "GiBy.h", gib_h, 1, r),
        testSku("N4C3-0000-0000", "N4 Instance Core running in Iowa", "CPU", .on_demand, "h", 3600, 3, r),
    });
    try testing.expectEqual(1, list.skipped.get(.not_compute));
    try testing.expectEqual(1, list.skipped.get(.usage));
    try testing.expectEqual(1, list.skipped.get(.resource_group));
    try testing.expectEqual(2, list.skipped.get(.wording));
    try testing.expectEqual(3, list.skipped.get(.excluded_family));
    try testing.expectEqual(1, list.skipped.get(.unknown_family));
    try testing.expectEqual(1, list.skipped.get(.unit));
    try testing.expectEqual(1, list.skipped.get(.no_price));
    try testing.expectEqual(1, list.skipped.get(.duplicate));

    // f1-micro: one SKU prices the VM.
    const f1: Machine = .{ .name = "f1-micro", .vcpus = 1, .memory_mb = 614 };
    try testing.expectEqual(7_600_000, list.hourly(f1, "us-central1", .on_demand).?.nanos_per_hour);
    try testing.expectEqual(3_500_000, list.hourly(f1, "us-central1", .spot).?.nanos_per_hour);
    try testing.expectEqualStrings("", list.hourly(f1, "us-central1", .spot).?.ram_sku);
    // n1-standard-1: 1 vCPU and 3.75 GiB.
    try testing.expectEqual(47_499_750, list.hourly(.{ .name = "n1-standard-1", .vcpus = 1, .memory_mb = 3840 }, "us-central1", .on_demand).?.nanos_per_hour);
    // N4's vCPU SKU was seen more than once: no price, however many more.
    try testing.expectEqual(null, list.hourly(.{ .name = "n4-standard-2", .vcpus = 2, .memory_mb = 8192 }, "us-central1", .on_demand));

    var eur = testSku("EURO-0000-0000", "E2 Instance Core running in Americas", "CPU", .on_demand, "h", 3600, 1, r);
    const tiers: []const types.Tier = &.{.{ .unit_price = .{ .currency = "EUR", .nanos = 1 } }};
    const pricing: []const types.Pricing = &.{.{ .effective_time = ts("2026-11-04T08:00:00Z"), .usage_unit = "h", .base_unit_conversion_factor = 3600, .tiers = tiers }};
    eur.pricing = pricing;
    try testing.expectError(error.MixedCurrencies, list.add(&.{eur}));
}

test "write and read: the list alone, and every price the same" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    var list = try productionList(&arena);
    defer list.deinit();
    var out: std.Io.Writer.Allocating = .init(testing.allocator);
    defer out.deinit();
    try list.write(&out.writer);
    var back = try PriceList.read(testing.allocator, out.written());
    defer back.deinit();
    try testing.expectEqualStrings("USD", back.currency);
    const std2: Machine = .{ .name = "e2-standard-2", .vcpus = 2, .memory_mb = 8192 };
    inline for (.{ Model.on_demand, Model.spot }) |model| {
        const want = list.hourly(std2, "us-east1", model).?;
        const got = back.hourly(std2, "us-east1", model).?;
        try testing.expectEqual(want.nanos_per_hour, got.nanos_per_hour);
        try testing.expectEqualStrings(want.core_sku, got.core_sku);
        try testing.expectEqual(want.effective_time, got.effective_time);
    }
    for ([_][]const u8{
        "",
        "{}",
        "{\"currency\":\"USD\",\"rates\":[{\"key\":\"e2|us-central1|spot\",\"sku\":\"x\",\"nanos\":1,\"factor\":3600,\"effective\":\"2026-11-04T08:00:00Z\"}]}",
        "{\"currency\":\"USD\",\"rates\":[{\"key\":\"e2|r|spot|core\",\"sku\":\"x\",\"nanos\":1,\"factor\":0,\"effective\":\"2026-11-04T08:00:00Z\"}]}",
        "{\"currency\":\"USD\",\"rates\":[{\"key\":\"e2|r|spot|core\",\"sku\":\"x\",\"nanos\":1,\"factor\":3600,\"effective\":\"soon\"}]}",
        "{\"currency\":\"USD\",\"rates\":[{\"key\":\"e2|r|spot|core\",\"sku\":\"x\",\"nanos\":1,\"factor\":3600,\"effective\":\"2026-11-04T08:00:00Z\"},{\"key\":\"e2|r|spot|core\",\"sku\":\"y\",\"nanos\":2,\"factor\":3600,\"effective\":\"2026-11-04T08:00:00Z\"}]}",
    }) |text| try testing.expectError(error.InvalidPriceList, PriceList.read(testing.allocator, text));
}

fn listProperty(_: void, input: []const u8) !void {
    const gpa = @import("test_util.zig").propertyAllocator();
    var g: core.testing.ByteGen = .init(input);
    var list: PriceList = try .init(gpa);
    defer list.deinit();
    const regions = [_][]const u8{ "us-central1", "europe-west1", "asia-east1" };
    const stems = [_][]const u8{ "E2", "N2", "C4D", "T2D AMD" };
    var ids: [16][14]u8 = undefined;
    var descriptions: [16][64]u8 = undefined;
    var skus: [16]types.Sku = undefined;
    const n = g.intRange(usize, 0, 16);
    for (0..n) |i| {
        const spot = g.boolean();
        const ram = g.boolean();
        const stem = stems[g.intRange(usize, 0, stems.len - 1)];
        const ri = g.intRange(usize, 0, regions.len - 1);
        const id = std.fmt.bufPrint(&ids[i], "{X:0>4}-0000-0000", .{i}) catch unreachable;
        const d = std.fmt.bufPrint(&descriptions[i], "{s}{s} Instance {s} running in Somewhere", .{ if (spot) "Spot Preemptible " else "", stem, if (ram) "Ram" else "Core" }) catch unreachable;
        const factor: f64 = if (!ram) 3600 else if (g.boolean()) gib_h else gb_h;
        skus[i] = testSku(id, d, if (ram) "RAM" else "CPU", if (spot) .preemptible else .on_demand, if (!ram) "h" else if (factor == gb_h) "GBy.h" else "GiBy.h", factor, @intCast(g.intRange(u32, 0, 200_000_000)), regions[ri..][0..1]);
    }
    try list.add(skus[0..n]);
    var out: std.Io.Writer.Allocating = .init(gpa);
    defer out.deinit();
    try list.write(&out.writer);
    var back = try PriceList.read(gpa, out.written());
    defer back.deinit();
    const series = [_][]const u8{ "e2", "n2", "c4d", "t2d" };
    for (series) |s| for (regions) |region| inline for (.{ Model.on_demand, Model.spot }) |model| {
        const vcpus = g.intRange(u32, 1, 416);
        const mb = g.intRange(u64, 512, 32 * 1024 * 1024);
        var name_buf: [32]u8 = undefined;
        const name = std.fmt.bufPrint(&name_buf, "{s}-standard-{d}", .{ s, vcpus }) catch unreachable;
        const machine: Machine = .{ .name = name, .vcpus = vcpus, .memory_mb = mb };
        const a = list.hourly(machine, region, model);
        const b = back.hourly(machine, region, model);
        try testing.expectEqual(a == null, b == null);
        if (a) |p| {
            try testing.expectEqual(p.nanos_per_hour, b.?.nanos_per_hour);
            // More of the machine never costs less.
            const bigger = list.hourly(.{ .name = name, .vcpus = vcpus + 1, .memory_mb = mb + 1024 }, region, model).?;
            try testing.expect(bigger.nanos_per_hour >= p.nanos_per_hour);
            try testing.expect(p.nanos_per_hour >= 0);
        }
    };
}

test "fuzz price list: write and read keep every price, and more machine never costs less" {
    try @import("test_util.zig").fuzzBytes({}, listProperty, .{ .corpus = &.{
        "\x08\x01\x00\x00\x00\x00\x01\x01\x01\x00\x01\x00\x01\x02\x00\x00\x00\x03\x01\x02\x01\x00\x00\x01",
        "\x10\xff\xfe\xfd\xfc\xfb\xfa\xf9\xf8\xf7\xf6\xf5\xf4\xf3\xf2\xf1\xf0\xef\xee\xed\xec\xeb\xea\xe9\xe8",
    } });
}
