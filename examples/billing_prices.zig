//! What a Compute Engine machine type costs an hour in a region, on demand
//! and as spot, from the Cloud Billing Catalog's list prices.
//!
//!     zig build example-billing_prices -- e2-standard-2 2 8 us-central1
//!     zig build example-billing_prices -- --fake     # no network
//!
//! The arguments are the machine type, its vCPUs and its memory in GiB
//! (as `compute.Client.getMachineType` reports them), and the region;
//! e2-standard-2 with 2 vCPUs and 8 GiB in us-central1 when left out.
//! Credentials come from `auth.findDefault`; the Cloud Billing API must be
//! enabled in their project, and no billing role is needed. Reading every
//! Compute Engine SKU takes about 9 s. `--fake` reads
//! `billing.testing.FakeBilling` instead, holding E2's prices as
//! production answered them on 2026-11-04.

const std = @import("std");
const auth = @import("auth");
const billing = @import("billing");

pub const std_options: std.Options = .{
    .log_scope_levels = &.{
        .{ .scope = .gcp_auth, .level = .warn },
        .{ .scope = .gcp_billing, .level = .warn },
    },
};

const Args = struct {
    fake: bool = false,
    machine: billing.compute.Machine = .{ .name = "e2-standard-2", .vcpus = 2, .memory_mb = 8 * 1024 },
    region: []const u8 = "us-central1",
};

fn parseArgs(args: []const []const u8) !Args {
    var parsed: Args = .{};
    var rest: [4][]const u8 = undefined;
    var n: usize = 0;
    for (args) |arg| {
        if (std.mem.eql(u8, arg, "--fake")) {
            parsed.fake = true;
        } else if (n < rest.len) {
            rest[n] = arg;
            n += 1;
        } else return error.Usage;
    }
    if (n == 0) return parsed;
    if (n != 4) return error.Usage;
    const gib = std.fmt.parseFloat(f64, rest[2]) catch return error.Usage;
    if (!(gib > 0 and gib < 1 << 20)) return error.Usage;
    parsed.machine = .{
        .name = rest[0],
        .vcpus = std.fmt.parseInt(u32, rest[1], 10) catch return error.Usage,
        .memory_mb = @intFromFloat(@round(gib * 1024)),
    };
    parsed.region = rest[3];
    return parsed;
}

pub fn main(init: std.process.Init) !void {
    const arena = init.arena.allocator();
    var stdout_buffer: [4096]u8 = undefined;
    var stdout = std.Io.File.stdout().writerStreaming(init.io, &stdout_buffer);
    const out = &stdout.interface;
    var diag: billing.Diagnostics = .{};

    const all = try init.minimal.args.toSlice(arena);
    const args = parseArgs(all[@min(1, all.len)..]) catch {
        std.debug.print("usage: billing_prices [--fake] [MACHINE_TYPE VCPUS MEMORY_GIB REGION]\n", .{});
        return error.Usage;
    };

    var fake: billing.testing.FakeBilling = .init(init.gpa, init.io);
    defer fake.deinit();
    var static: billing.StaticToken = .{ .token = "fake" };
    var creds: ?auth.Credentials = null;
    defer if (creds) |*c| c.deinit();
    if (args.fake) {
        try putE2(&fake);
    } else {
        var lookup = try auth.Lookup.fromEnv(init.environ_map, arena);
        lookup.diagnostics = &diag;
        creds = try auth.findDefault(init.gpa, init.io, lookup, .{});
    }
    var client = try billing.Client.init(init.gpa, init.io, .{
        .token_provider = if (creds) |*c| c.provider() else static.provider(),
        .transport = if (args.fake) fake.transport() else null,
        .diagnostics = &diag,
    });
    defer client.deinit();

    var list = client.computePrices(.{}) catch |err| {
        std.debug.print("reading Compute Engine's prices failed: {t}: {s}\n", .{ err, diag.message() });
        return err;
    };
    defer list.deinit();

    const m = args.machine;
    try out.print("{s} ({d} vCPUs, {d} MiB) in {s}, list prices in {s}:\n", .{ m.name, m.vcpus, m.memory_mb, args.region, list.currency });
    inline for (.{ billing.compute.Model.on_demand, billing.compute.Model.spot }) |model| {
        if (list.hourly(m, args.region, model)) |price| {
            try out.print("  {s:<9} {f} an hour, {f} for 730 hours (SKUs {s} and {s})\n", .{
                @tagName(model),
                amount(price.nanos_per_hour),
                amount(price.nanos_per_hour * 730),
                price.core_sku,
                price.ram_sku,
            });
        } else {
            try out.print("  {s:<9} not priced here: a family the list leaves out, or no SKU in this region\n", .{@tagName(model)});
        }
    }
    try out.flush();
}

/// Nanos as a decimal amount with six places: 67011420 is 0.067011.
fn amount(nanos: i128) Amount {
    return .{ .nanos = nanos };
}

const Amount = struct {
    nanos: i128,

    pub fn format(self: Amount, w: *std.Io.Writer) std.Io.Writer.Error!void {
        const micros = @divTrunc(self.nanos + 500, 1000);
        try w.print("{d}.{d:0>6}", .{ @divTrunc(micros, 1_000_000), @as(u64, @intCast(@mod(micros, 1_000_000))) });
    }
};

/// E2's vCPU and memory in us-central1, us-east1 and us-west1, as
/// production priced them on 2026-11-04.
fn putE2(fake: *billing.testing.FakeBilling) !void {
    const engine = billing.compute_engine_service_id;
    try fake.putService(.{ .id = engine, .display_name = "Compute Engine" });
    const since: std.Io.Timestamp = .{ .nanoseconds = 1_767_254_400 * std.time.ns_per_s };
    const americas: []const []const u8 = &.{ "us-central1", "us-east1", "us-west1" };
    inline for (.{
        .{ "CF4E-A0C7-E3BF", "E2 Instance Core running in Americas", "CPU", "OnDemand", 21_811_590 },
        .{ "F449-33EC-A5EF", "E2 Instance Ram running in Americas", "RAM", "OnDemand", 2_923_530 },
        .{ "F179-E1EA-D97A", "Spot Preemptible E2 Instance Core running in Americas", "CPU", "Preemptible", 13_090_000 },
        .{ "9B1F-1E62-4061", "Spot Preemptible E2 Instance Ram running in Americas", "RAM", "Preemptible", 1_754_000 },
    }) |s| {
        const ram = comptime std.mem.eql(u8, s[2], "RAM");
        try fake.putSku(.{
            .id = s[0],
            .service_id = engine,
            .description = s[1],
            .resource_group = s[2],
            .usage_type = s[3],
            .regions = americas,
            .geo_type = "MULTI_REGIONAL",
            .usage_unit = if (ram) "GiBy.h" else "h",
            .base_unit = if (ram) "By.s" else "s",
            .base_unit_conversion_factor = if (ram) 3_865_470_566_400 else 3600,
            .prices = &.{.{ .from = since, .tiers = &.{.{ .usd_nanos = s[4] }} }},
        });
    }
}
