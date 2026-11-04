//! The Cloud Billing Catalog in memory, for tests of code that reads
//! prices: behind `Client.Options.transport`, it answers `services.list`
//! and `services.skus.list` as production answered them when measured on
//! 2026-11-04 (issue #350).
//!
//! - Services and SKUs are put in by the test (`putService`, `putSku`),
//!   each SKU with its price timeline in USD, oldest first; `setRate`
//!   makes another currency known, at a rate from USD.
//! - Lists sort by id and page as production does: the default page is
//!   the maximum, 5000; a page token is the next offset in base64 (`Mg==`
//!   for 2), and the last page's is `""`.
//! - With no time range, each SKU answers the price in force now, said to
//!   take effect at midnight in Los Angeles today, as production says.
//!   Over a range, the price in force at its start (said to take effect
//!   then) and every later one that took effect before its end. A start
//!   alone runs to now.
//! - Another currency's prices are the USD nanos times the rate,
//!   truncated, with the rate beside them, as production converts.
//! - Refused in production's words: a page size over 5000 or below 0, a
//!   page token it did not make, an unknown or lowercase currency, a range
//!   in the future, ending before it starts, with an end and no start, or
//!   across a month in Los Angeles (each a bare 400, "Request contains an
//!   invalid argument."); a timestamp that is not one (400, the one
//!   refusal that says why); a service nobody put (404 "Requested entity
//!   was not found."); a call with no credentials (403).
//! - Faults a test asks for: refusals and dropped connections.
//!
//! Not modelled, answered 501 with the reason: a page token past the end
//! of the list, query parameters the client never sends, and every other
//! method or path (v2beta, billing accounts).

const std = @import("std");
const Allocator = std.mem.Allocator;
const Stringify = std.json.Stringify;
const Timestamp = std.Io.Timestamp;
const core = @import("core");
const tp = core.transport;
const validate = @import("validate.zig");

pub const FakeBilling = struct {
    gpa: Allocator,
    io: std.Io,
    mutex: std.Io.Mutex = .init,
    /// Strings, services and SKUs, freed with the fake.
    store: std.heap.ArenaAllocator,
    /// By id, sorted on read.
    services: std.StringArrayHashMapUnmanaged(PutService) = .empty,
    /// By id, sorted on read.
    skus: std.StringArrayHashMapUnmanaged(PutSku) = .empty,
    /// From USD, by currency code. USD is always 1.
    rates: std.StringArrayHashMapUnmanaged(f64) = .empty,
    faults: [2]Fault = .{ .{}, .{} },
    calls: usize = 0,

    const Fault = struct { n: usize = 0, status: u16 = 0 };
    const refuse = 0;
    const drop = 1;

    pub const Reply = struct { status: u16, headers: []const tp.Header = &.{}, body: []const u8 };

    pub const PutService = struct {
        /// Three groups of four uppercase hex digits, such as
        /// `6F81-5844-456A`.
        id: []const u8,
        display_name: []const u8,
        business_entity: []const u8 = "businessEntities/GCP",
    };

    /// One tier of a price, in USD nanos per usage unit.
    pub const PutTier = struct {
        start_usage: f64 = 0,
        usd_nanos: i64,
    };

    /// A price from `from` on, until the next one in the SKU's timeline.
    pub const PutPrice = struct {
        from: Timestamp,
        tiers: []const PutTier,
    };

    pub const PutSku = struct {
        /// The form of a service id, such as `CF4E-A0C7-E3BF`.
        id: []const u8,
        service_id: []const u8,
        description: []const u8,
        resource_family: []const u8 = "Compute",
        resource_group: []const u8 = "CPU",
        /// The wire's word: `OnDemand`, `Preemptible`, `Commit1Yr`, ...
        usage_type: []const u8 = "OnDemand",
        regions: []const []const u8 = &.{},
        /// `GLOBAL`, `REGIONAL` or `MULTI_REGIONAL`.
        geo_type: []const u8 = "REGIONAL",
        usage_unit: []const u8 = "h",
        usage_unit_description: []const u8 = "hour",
        base_unit: []const u8 = "s",
        base_unit_description: []const u8 = "second",
        base_unit_conversion_factor: f64 = 3600,
        service_provider: []const u8 = "Google",
        /// Oldest first, at least one.
        prices: []const PutPrice,
    };

    pub const PutError = Allocator.Error || error{
        /// An id not of the form `6F81-5844-456A`, a SKU of a service not
        /// put, no prices, or prices out of order.
        InvalidPut,
    };

    pub fn init(gpa: Allocator, io: std.Io) FakeBilling {
        return .{ .gpa = gpa, .io = io, .store = .init(gpa) };
    }

    pub fn deinit(f: *FakeBilling) void {
        f.services.deinit(f.gpa);
        f.skus.deinit(f.gpa);
        f.rates.deinit(f.gpa);
        f.store.deinit();
        f.* = undefined;
    }

    /// Goes into `Client.Options.transport`.
    pub fn transport(f: *FakeBilling) tp.Transport {
        return .{ .ptr = f, .vtable = &.{ .send = send } };
    }

    // Faults, each for the next `n` calls.

    /// Answers them with `status`.
    pub fn refuseNext(f: *FakeBilling, n: usize, status: u16) void {
        f.setFault(refuse, .{ .n = n, .status = status });
    }

    /// Closes their connection before any answer.
    pub fn dropNext(f: *FakeBilling, n: usize) void {
        f.setFault(drop, .{ .n = n });
    }

    fn setFault(f: *FakeBilling, slot: usize, fault: Fault) void {
        f.mutex.lockUncancelable(f.io);
        defer f.mutex.unlock(f.io);
        f.faults[slot] = fault;
    }

    fn takeFault(f: *FakeBilling, slot: usize) ?Fault {
        const fault = &f.faults[slot];
        if (fault.n == 0) return null;
        fault.n -= 1;
        return fault.*;
    }

    /// Calls served, refusals included.
    pub fn callCount(f: *FakeBilling) usize {
        f.mutex.lockUncancelable(f.io);
        defer f.mutex.unlock(f.io);
        return f.calls;
    }

    // What a test puts in.

    /// Adds a service, or replaces the one with its id.
    pub fn putService(f: *FakeBilling, service: PutService) PutError!void {
        if (!validate.isServiceId(service.id)) return error.InvalidPut;
        f.mutex.lockUncancelable(f.io);
        defer f.mutex.unlock(f.io);
        const s = f.store.allocator();
        const copy: PutService = .{
            .id = try s.dupe(u8, service.id),
            .display_name = try s.dupe(u8, service.display_name),
            .business_entity = try s.dupe(u8, service.business_entity),
        };
        try f.services.put(f.gpa, copy.id, copy);
    }

    /// Adds a SKU to a service already put, or replaces the one with its id.
    pub fn putSku(f: *FakeBilling, sku: PutSku) PutError!void {
        if (!validate.isServiceId(sku.id) or sku.prices.len == 0) return error.InvalidPut;
        for (sku.prices[0 .. sku.prices.len - 1], sku.prices[1..]) |a, b| {
            if (a.from.nanoseconds >= b.from.nanoseconds) return error.InvalidPut;
        }
        f.mutex.lockUncancelable(f.io);
        defer f.mutex.unlock(f.io);
        if (!f.services.contains(sku.service_id)) return error.InvalidPut;
        const copy = try f.copySku(sku);
        try f.skus.put(f.gpa, copy.id, copy);
    }

    fn copySku(f: *FakeBilling, sku: PutSku) Allocator.Error!PutSku {
        const s = f.store.allocator();
        var copy = sku;
        inline for (.{ "id", "service_id", "description", "resource_family", "resource_group", "usage_type", "geo_type", "usage_unit", "usage_unit_description", "base_unit", "base_unit_description", "service_provider" }) |name| {
            @field(copy, name) = try s.dupe(u8, @field(sku, name));
        }
        const regions = try s.alloc([]const u8, sku.regions.len);
        for (sku.regions, regions) |r, *out| out.* = try s.dupe(u8, r);
        copy.regions = regions;
        const prices = try s.alloc(PutPrice, sku.prices.len);
        for (sku.prices, prices) |p, *out| out.* = .{ .from = p.from, .tiers = try s.dupe(PutTier, p.tiers) };
        copy.prices = prices;
        return copy;
    }

    /// Makes `currency` known, at `rate` from USD.
    pub fn setRate(f: *FakeBilling, currency: []const u8, rate: f64) PutError!void {
        if (!validate.isCurrencyCode(currency) or !(rate > 0)) return error.InvalidPut;
        f.mutex.lockUncancelable(f.io);
        defer f.mutex.unlock(f.io);
        try f.rates.put(f.gpa, try f.store.allocator().dupe(u8, currency), rate);
    }

    // The transport.

    fn send(ptr: *anyopaque, req: tp.Request, arena: Allocator) tp.Error!tp.Response {
        const f: *FakeBilling = @ptrCast(@alignCast(ptr));
        const reply = try f.serve(req, arena);
        return .{ .status = reply.status, .headers = reply.headers, .body = reply.body };
    }

    /// One request, as `send` serves it: for a test that wants to send
    /// what no client would.
    pub fn serve(f: *FakeBilling, req: tp.Request, arena: Allocator) tp.Error!Reply {
        const path = pathOf(req.url);
        const q_at = std.mem.indexOfScalar(u8, path, '?');
        const route_text = path[0 .. q_at orelse path.len];
        const query = if (q_at) |q| path[q + 1 ..] else "";
        f.mutex.lockUncancelable(f.io);
        defer f.mutex.unlock(f.io);
        f.calls += 1;
        if (f.takeFault(drop) != null) return error.ConnectionResetByPeer;
        if (f.takeFault(refuse)) |fault| return refusal(arena, fault.status);
        return f.route(req, arena, route_text, query);
    }

    fn route(f: *FakeBilling, req: tp.Request, arena: Allocator, route_text: []const u8, query: []const u8) Allocator.Error!Reply {
        if (req.bearer == null) return fail(arena, 403, "PERMISSION_DENIED", "Method doesn't allow unregistered callers (callers without established identity). Please use API Key or other form of API consumer identity to call this API.");
        if (req.method != .GET) return notModelled(arena, "any method but GET");
        const params = try parseParams(arena, query) orelse return invalid(arena);
        for (params) |p| if (!knownParam(p.name)) return notModelled(arena, try arena.print("the query parameter '{s}'", .{p.name}));
        if (std.mem.eql(u8, route_text, "/v1/services")) return f.listServices(arena, params);
        const prefix = "/v1/services/";
        const suffix = "/skus";
        if (std.mem.startsWith(u8, route_text, prefix) and std.mem.endsWith(u8, route_text, suffix) and route_text.len > prefix.len + suffix.len) {
            return f.listSkus(arena, params, route_text[prefix.len .. route_text.len - suffix.len]);
        }
        return notModelled(arena, "this path");
    }

    fn knownParam(name: []const u8) bool {
        inline for (.{ "pageSize", "pageToken", "currencyCode", "startTime", "endTime" }) |known| {
            if (std.mem.eql(u8, name, known)) return true;
        }
        return false;
    }

    /// Where a page starts and how long it is, or why it was refused.
    const Window = union(enum) {
        ok: struct { offset: usize, size: usize },
        refused: Reply,
    };

    fn window(arena: Allocator, params: []const Param, total: usize) Allocator.Error!Window {
        var size: usize = validate.max_page_size;
        if (paramOf(params, "pageSize")) |text| {
            const n = std.fmt.parseInt(i64, text, 10) catch return .{ .refused = try invalid(arena) };
            if (n < 0 or n > validate.max_page_size) return .{ .refused = try invalid(arena) };
            if (n > 0) size = @intCast(n);
        }
        var offset: usize = 0;
        if (paramOf(params, "pageToken")) |t| if (t.len > 0) {
            offset = decodeToken(t) orelse return .{ .refused = try invalid(arena) };
            if (offset > total) return .{ .refused = try notModelled(arena, "a page token past the end of the list") };
        };
        return .{ .ok = .{ .offset = offset, .size = size } };
    }

    fn listServices(f: *FakeBilling, arena: Allocator, params: []const Param) Allocator.Error!Reply {
        const ids = try sortedKeys(arena, f.services.keys());
        const w = switch (try window(arena, params, ids.len)) {
            .ok => |w| w,
            .refused => |r| return r,
        };
        const end = @min(ids.len, w.offset + w.size);
        var out: std.Io.Writer.Allocating = .init(arena);
        var jw: Stringify = .{ .writer = &out.writer, .options = .{ .whitespace = .indent_2 } };
        writeServices(&jw, f, ids[w.offset..end], try nextToken(arena, end, ids.len)) catch return error.OutOfMemory;
        return .{ .status = 200, .body = out.written() };
    }

    fn writeServices(jw: *Stringify, f: *FakeBilling, ids: []const []const u8, next: []const u8) Stringify.Error!void {
        try jw.beginObject();
        try jw.objectField("services");
        try jw.beginArray();
        for (ids) |id| {
            const s = f.services.get(id).?;
            try jw.beginObject();
            try jw.objectField("name");
            try jw.print("\"services/{s}\"", .{s.id});
            try jw.objectField("serviceId");
            try jw.write(s.id);
            try jw.objectField("displayName");
            try jw.write(s.display_name);
            try jw.objectField("businessEntityName");
            try jw.write(s.business_entity);
            try jw.endObject();
        }
        try jw.endArray();
        try jw.objectField("nextPageToken");
        try jw.write(next);
        try jw.endObject();
    }

    /// What a SKU list's prices are read for: a currency and a range.
    const Reading = struct {
        currency: []const u8,
        rate: f64,
        /// Null with no range: the price in force now, said to take effect
        /// at midnight in Los Angeles.
        start: ?Timestamp,
        end: Timestamp,
        now: Timestamp,
    };

    fn listSkus(f: *FakeBilling, arena: Allocator, params: []const Param, service_id: []const u8) Allocator.Error!Reply {
        if (!f.services.contains(service_id)) return fail(arena, 404, "NOT_FOUND", "Requested entity was not found.");
        const reading = switch (try f.readingOf(arena, params)) {
            .ok => |r| r,
            .refused => |r| return r,
        };
        var ids: std.ArrayList([]const u8) = .empty;
        for (f.skus.values()) |sku| if (std.mem.eql(u8, sku.service_id, service_id)) try ids.append(arena, sku.id);
        const sorted = try sortedKeys(arena, ids.items);
        const w = switch (try window(arena, params, sorted.len)) {
            .ok => |w| w,
            .refused => |r| return r,
        };
        const end = @min(sorted.len, w.offset + w.size);
        var out: std.Io.Writer.Allocating = .init(arena);
        var jw: Stringify = .{ .writer = &out.writer, .options = .{ .whitespace = .indent_2 } };
        f.writeSkus(&jw, sorted[w.offset..end], reading, try nextToken(arena, end, sorted.len)) catch return error.OutOfMemory;
        return .{ .status = 200, .body = out.written() };
    }

    const ReadingOrRefusal = union(enum) { ok: Reading, refused: Reply };

    fn readingOf(f: *FakeBilling, arena: Allocator, params: []const Param) Allocator.Error!ReadingOrRefusal {
        const now = std.Io.Clock.real.now(f.io);
        var reading: Reading = .{ .currency = "USD", .rate = 1, .start = null, .end = now, .now = now };
        if (paramOf(params, "currencyCode")) |code| if (!std.mem.eql(u8, code, "USD")) {
            reading.rate = f.rates.get(code) orelse return .{ .refused = try invalid(arena) };
            reading.currency = code;
        };
        const start = switch (try timeParam(arena, params, "startTime", "start_time")) {
            .ok => |t| t,
            .refused => |r| return .{ .refused = r },
        };
        const end = switch (try timeParam(arena, params, "endTime", "end_time")) {
            .ok => |t| t,
            .refused => |r| return .{ .refused = r },
        };
        if (validate.rangeProblem(start, end, now) != null) return .{ .refused = try invalid(arena) };
        reading.start = start;
        if (end) |e| reading.end = e;
        return .{ .ok = reading };
    }

    const TimeOrRefusal = union(enum) { ok: ?Timestamp, refused: Reply };

    fn timeParam(arena: Allocator, params: []const Param, name: []const u8, proto_name: []const u8) Allocator.Error!TimeOrRefusal {
        const text = paramOf(params, name) orelse return .{ .ok = null };
        const t = core.timestamp.parse(text) catch return .{ .refused = try fail(arena, 400, "INVALID_ARGUMENT", try arena.print(
            "Invalid value at '{s}' (type.googleapis.com/google.protobuf.Timestamp), Field '{s}', Illegal timestamp format; timestamps must end with 'Z' or have a valid timezone offset.",
            .{ proto_name, proto_name },
        )) };
        return .{ .ok = t };
    }

    fn writeSkus(f: *FakeBilling, jw: *Stringify, ids: []const []const u8, reading: Reading, next: []const u8) Stringify.Error!void {
        try jw.beginObject();
        try jw.objectField("skus");
        try jw.beginArray();
        for (ids) |id| {
            const sku = f.skus.get(id).?;
            try writeSku(jw, sku, f.services.get(sku.service_id).?.display_name, reading);
        }
        try jw.endArray();
        try jw.objectField("nextPageToken");
        try jw.write(next);
        try jw.endObject();
    }

    fn writeSku(jw: *Stringify, sku: PutSku, service_name: []const u8, reading: Reading) Stringify.Error!void {
        try jw.beginObject();
        try jw.objectField("name");
        try jw.print("\"services/{s}/skus/{s}\"", .{ sku.service_id, sku.id });
        try jw.objectField("skuId");
        try jw.write(sku.id);
        try jw.objectField("description");
        try jw.write(sku.description);
        try jw.objectField("category");
        try jw.write(.{
            .serviceDisplayName = service_name,
            .resourceFamily = sku.resource_family,
            .resourceGroup = sku.resource_group,
            .usageType = sku.usage_type,
        });
        try jw.objectField("serviceRegions");
        try jw.write(sku.regions);
        try jw.objectField("pricingInfo");
        try jw.beginArray();
        try writeTimeline(jw, sku, reading);
        try jw.endArray();
        try jw.objectField("serviceProviderName");
        try jw.write(sku.service_provider);
        try jw.objectField("geoTaxonomy");
        try jw.write(.{ .type = sku.geo_type, .regions = sku.regions });
        try jw.endObject();
    }

    /// The prices a reading sees: the one in force at its start (or now),
    /// and, over a range, every later one that took effect before its end.
    fn writeTimeline(jw: *Stringify, sku: PutSku, reading: Reading) Stringify.Error!void {
        const from = reading.start orelse reading.now;
        var in_force: ?usize = null;
        for (sku.prices, 0..) |p, i| {
            if (p.from.nanoseconds <= from.nanoseconds) in_force = i;
        }
        if (in_force) |i| {
            const said = reading.start orelse validate.pacificDayStart(reading.now);
            try writePricing(jw, sku, sku.prices[i], said, reading);
        }
        if (reading.start == null) return;
        for (sku.prices) |p| {
            if (p.from.nanoseconds > from.nanoseconds and p.from.nanoseconds < reading.end.nanoseconds) {
                try writePricing(jw, sku, p, p.from, reading);
            }
        }
    }

    fn writePricing(jw: *Stringify, sku: PutSku, price: PutPrice, effective: Timestamp, reading: Reading) Stringify.Error!void {
        try jw.beginObject();
        try jw.objectField("summary");
        try jw.write("");
        try jw.objectField("pricingExpression");
        try jw.beginObject();
        try jw.objectField("usageUnit");
        try jw.write(sku.usage_unit);
        try jw.objectField("displayQuantity");
        try writeNumber(jw, 1);
        try jw.objectField("tieredRates");
        try jw.beginArray();
        for (price.tiers) |tier| {
            const nanos = convert(tier.usd_nanos, reading.rate);
            try jw.beginObject();
            try jw.objectField("startUsageAmount");
            try writeNumber(jw, tier.start_usage);
            try jw.objectField("unitPrice");
            try jw.beginObject();
            try jw.objectField("currencyCode");
            try jw.write(reading.currency);
            try jw.objectField("units");
            try jw.print("\"{d}\"", .{@divTrunc(nanos, 1_000_000_000)});
            try jw.objectField("nanos");
            try jw.write(@rem(nanos, 1_000_000_000));
            try jw.endObject();
            try jw.endObject();
        }
        try jw.endArray();
        try jw.objectField("usageUnitDescription");
        try jw.write(sku.usage_unit_description);
        try jw.objectField("baseUnit");
        try jw.write(sku.base_unit);
        try jw.objectField("baseUnitDescription");
        try jw.write(sku.base_unit_description);
        try jw.objectField("baseUnitConversionFactor");
        try writeNumber(jw, sku.base_unit_conversion_factor);
        try jw.endObject();
        try jw.objectField("currencyConversionRate");
        try writeNumber(jw, reading.rate);
        try jw.objectField("effectiveTime");
        var buf: [core.timestamp.max_len]u8 = undefined;
        try jw.write(core.timestamp.format(&buf, effective));
        try jw.endObject();
    }

    /// USD nanos in another currency: times the rate, truncated, as
    /// production converted ($0.00495495 at 0.8981 is 0.00445004 EUR).
    fn convert(usd_nanos: i64, rate: f64) i64 {
        if (rate == 1) return usd_nanos;
        return @intFromFloat(@trunc(@as(f64, @floatFromInt(usd_nanos)) * rate));
    }

    /// A whole number as production writes one (`3600`, `1`), anything
    /// else as a double.
    fn writeNumber(jw: *Stringify, x: f64) Stringify.Error!void {
        if (@trunc(x) == x and @abs(x) < 1e15) return jw.write(@as(i64, @intFromFloat(x)));
        return jw.write(x);
    }

    fn sortedKeys(arena: Allocator, keys: []const []const u8) Allocator.Error![]const []const u8 {
        const sorted = try arena.dupe([]const u8, keys);
        std.mem.sortUnstable([]const u8, sorted, {}, lessThan);
        return sorted;
    }

    fn lessThan(_: void, a: []const u8, b: []const u8) bool {
        return std.mem.order(u8, a, b) == .lt;
    }

    /// The next page's token: the offset in base64, or "" at the end.
    fn nextToken(arena: Allocator, end: usize, total: usize) Allocator.Error![]const u8 {
        if (end >= total) return "";
        var digits: [20]u8 = undefined;
        const text = std.fmt.bufPrint(&digits, "{d}", .{end}) catch unreachable;
        const out = try arena.alloc(u8, std.base64.standard.Encoder.calcSize(text.len));
        return std.base64.standard.Encoder.encode(out, text);
    }

    fn decodeToken(token: []const u8) ?usize {
        var buf: [32]u8 = undefined;
        const len = std.base64.standard.Decoder.calcSizeForSlice(token) catch return null;
        if (len == 0 or len > buf.len) return null;
        std.base64.standard.Decoder.decode(buf[0..len], token) catch return null;
        return std.fmt.parseInt(usize, buf[0..len], 10) catch null;
    }

    fn pathOf(url: []const u8) []const u8 {
        const scheme = std.mem.indexOf(u8, url, "://") orelse return url;
        const rest = url[scheme + 3 ..];
        const slash = std.mem.indexOfScalar(u8, rest, '/') orelse return "/";
        return rest[slash..];
    }

    const Param = struct { name: []const u8, value: []const u8 };

    fn parseParams(arena: Allocator, query: []const u8) Allocator.Error!?[]const Param {
        var list: std.ArrayList(Param) = .empty;
        if (query.len == 0) return list.items;
        var it = std.mem.splitScalar(u8, query, '&');
        while (it.next()) |pair| {
            const eq = std.mem.indexOfScalar(u8, pair, '=') orelse return null;
            const name_copy = try arena.dupe(u8, pair[0..eq]);
            const value_copy = try arena.dupe(u8, pair[eq + 1 ..]);
            try list.append(arena, .{
                .name = std.Uri.percentDecodeInPlace(name_copy),
                .value = std.Uri.percentDecodeInPlace(value_copy),
            });
        }
        return list.items;
    }

    fn paramOf(params: []const Param, name: []const u8) ?[]const u8 {
        for (params) |p| if (std.mem.eql(u8, p.name, name)) return p.value;
        return null;
    }

    fn fail(arena: Allocator, code: u16, status: []const u8, message: []const u8) Allocator.Error!Reply {
        return .{ .status = code, .body = try Stringify.valueAlloc(arena, .{ .@"error" = .{
            .code = code,
            .message = message,
            .status = status,
        } }, .{}) };
    }

    /// Production's bare 400, which most refusals here are.
    fn invalid(arena: Allocator) Allocator.Error!Reply {
        return fail(arena, 400, "INVALID_ARGUMENT", "Request contains an invalid argument.");
    }

    fn notModelled(arena: Allocator, what: []const u8) Allocator.Error!Reply {
        return fail(arena, 501, "UNIMPLEMENTED", try arena.print("fake: {s} is not modelled yet", .{what}));
    }

    fn refusal(arena: Allocator, status: u16) Allocator.Error!Reply {
        const name = switch (status) {
            400 => "INVALID_ARGUMENT",
            401 => "UNAUTHENTICATED",
            403 => "PERMISSION_DENIED",
            404 => "NOT_FOUND",
            429 => "RESOURCE_EXHAUSTED",
            500 => "INTERNAL",
            503 => "UNAVAILABLE",
            504 => "DEADLINE_EXCEEDED",
            else => "UNKNOWN",
        };
        return fail(arena, status, name, "fake: refused as the test asked");
    }
};

// Tests, held to what production answered in milestone 0.

const testing = std.testing;
const codec = @import("codec.zig");
const types = @import("types.zig");
const production = @import("production_bodies.zig");
const Client = @import("Client.zig");
const test_util = @import("test_util.zig");

fn ts(text: []const u8) Timestamp {
    return core.timestamp.parse(text) catch unreachable;
}

/// A fake, a clock at the afternoon milestone 0 ran, and a client on both.
const Bench = struct {
    clock: test_util.FakeClock,
    fake: FakeBilling,
    token: test_util.FakeTokenProvider,
    diag: core.Diagnostics,
    client: Client,

    fn init(b: *Bench, currency: ?[]const u8) !void {
        b.clock = .{ .now_ns = test_util.milestone_0_ns };
        b.fake = .init(testing.allocator, b.clock.io());
        errdefer b.fake.deinit();
        b.token = .{ .token = "ya29.test-token" };
        b.diag = .{};
        b.client = try .init(testing.allocator, b.clock.io(), .{
            .token_provider = b.token.provider(),
            .currency_code = currency,
            .diagnostics = &b.diag,
            .transport = b.fake.transport(),
        });
    }

    fn deinit(b: *Bench) void {
        b.client.deinit();
        b.fake.deinit();
    }

    /// Asks the fake directly, as no client would.
    fn ask(b: *Bench, arena: Allocator, url: []const u8, bearer: ?[]const u8) !FakeBilling.Reply {
        return b.fake.serve(.{ .method = .GET, .url = url, .bearer = bearer }, arena);
    }
};

/// The two SKUs of production's `skus_small`, with the second one's
/// October timeline from `skus_october`. Its latest price, 0.01423, was
/// what production answered on 2026-11-04; that it took effect on
/// Monday 2026-11-02 at midnight in Los Angeles is inferred from the
/// Mondays October's changes fell on.
fn putProductionSkus(f: *FakeBilling) !void {
    try f.putService(.{ .id = "6F81-5844-456A", .display_name = "Compute Engine" });
    try f.putSku(.{
        .id = "0001-B904-8A40",
        .service_id = "6F81-5844-456A",
        .description = "Sole Tenancy Premium for C4 Sole Tenancy Instance Core running in Santiago",
        .resource_group = "CPU",
        .regions = &.{"southamerica-west1"},
        .prices = &.{.{ .from = ts("2026-01-01T08:00:00Z"), .tiers = &.{.{ .usd_nanos = 4_954_950 }} }},
    });
    try f.putSku(.{
        .id = "0001-FC8F-A9AF",
        .service_id = "6F81-5844-456A",
        .description = "Spot Preemptible E2 Custom Instance Core running in Paris",
        .resource_group = "CPU",
        .usage_type = "Preemptible",
        .regions = &.{"europe-west9"},
        .prices = &.{
            .{ .from = ts("2026-09-28T07:00:00Z"), .tiers = &.{.{ .usd_nanos = 13_620_000 }} },
            .{ .from = ts("2026-10-05T07:00:00Z"), .tiers = &.{.{ .usd_nanos = 14_300_000 }} },
            .{ .from = ts("2026-10-12T07:00:00Z"), .tiers = &.{.{ .usd_nanos = 15_020_000 }} },
            .{ .from = ts("2026-10-19T07:00:00Z"), .tiers = &.{.{ .usd_nanos = 14_270_000 }} },
            .{ .from = ts("2026-10-26T07:00:00Z"), .tiers = &.{.{ .usd_nanos = 14_980_000 }} },
            .{ .from = ts("2026-11-02T08:00:00Z"), .tiers = &.{.{ .usd_nanos = 14_230_000 }} },
        },
    });
}

fn expectSameSku(wanted: types.Sku, got: types.Sku) !void {
    try testing.expectEqualStrings(wanted.id, got.id);
    try testing.expectEqualStrings(wanted.name, got.name);
    try testing.expectEqualStrings(wanted.description, got.description);
    try testing.expectEqualStrings(wanted.service_display_name, got.service_display_name);
    try testing.expectEqualStrings(wanted.resource_family, got.resource_family);
    try testing.expectEqualStrings(wanted.resource_group, got.resource_group);
    try testing.expectEqualStrings(wanted.usage_type_text, got.usage_type_text);
    try testing.expectEqual(wanted.service_regions.len, got.service_regions.len);
    for (wanted.service_regions, got.service_regions) |w, g| try testing.expectEqualStrings(w, g);
    try testing.expectEqual(wanted.geo.type, got.geo.type);
    try testing.expectEqualStrings(wanted.service_provider, got.service_provider);
    try testing.expectEqual(wanted.pricing.len, got.pricing.len);
    for (wanted.pricing, got.pricing) |w, g| {
        try testing.expectEqual(w.effective_time, g.effective_time);
        try testing.expectEqualStrings(w.usage_unit, g.usage_unit);
        try testing.expectEqualStrings(w.base_unit, g.base_unit);
        try testing.expectEqual(w.base_unit_conversion_factor, g.base_unit_conversion_factor);
        try testing.expectEqual(w.display_quantity, g.display_quantity);
        try testing.expectEqual(w.currency_conversion_rate, g.currency_conversion_rate);
        try testing.expectEqual(w.tiers.len, g.tiers.len);
        for (w.tiers, g.tiers) |wt, gt| {
            try testing.expectEqual(wt.start_usage, gt.start_usage);
            try testing.expectEqualStrings(wt.unit_price.currency, gt.unit_price.currency);
            try testing.expectEqual(wt.unit_price.toNanos(), gt.unit_price.toNanos());
        }
    }
}

fn expectSamePage(wanted_body: []const u8, got: types.SkuPage) !void {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const wanted = try codec.decodeSkuPage(arena.allocator(), arena.allocator(), wanted_body);
    try testing.expectEqual(wanted.skus.len, got.skus.len);
    for (wanted.skus, got.skus) |w, g| try expectSameSku(w, g);
    if (wanted.next_page_token) |t| try testing.expectEqualStrings(t, got.next_page_token.?) else try testing.expectEqual(null, got.next_page_token);
}

test "held to production: the latest prices, EUR and October read as production read them" {
    var b: Bench = undefined;
    try b.init(null);
    defer b.deinit();
    try putProductionSkus(&b.fake);
    var latest = try b.client.listSkus("6F81-5844-456A", .{ .page_size = 2 });
    defer latest.deinit();
    // Production's page had more after it; this catalog has only these.
    try testing.expectEqual(null, latest.value.next_page_token);
    latest.value.next_page_token = "Mg==";
    try expectSamePage(production.skus_small, latest.value);

    var october = try b.client.listSkus("6F81-5844-456A", .{
        .page_size = 2,
        .start_time = ts("2026-10-01T07:00:00Z"),
        .end_time = ts("2026-10-31T06:59:59Z"),
    });
    defer october.deinit();
    october.value.next_page_token = "Mg==";
    try expectSamePage(production.skus_october, october.value);

    var eur: Bench = undefined;
    try eur.init("EUR");
    defer eur.deinit();
    try putProductionSkus(&eur.fake);
    try eur.fake.setRate("EUR", 0.8980999999998375);
    var in_eur = try eur.client.listSkus("6F81-5844-456A", .{ .page_size = 2 });
    defer in_eur.deinit();
    in_eur.value.next_page_token = "Mg==";
    try expectSamePage(production.skus_eur, in_eur.value);
}

test "held to production: refusals in production's words" {
    var b: Bench = undefined;
    try b.init(null);
    defer b.deinit();
    try putProductionSkus(&b.fake);
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const base = "https://cloudbilling.googleapis.com/v1/services/6F81-5844-456A/skus?pageSize=2";
    const cases = [_]struct { url: []const u8, wanted: []const u8, bearer: ?[]const u8 = "t" }{
        .{ .url = "https://cloudbilling.googleapis.com/v1/services/6F81-5844-456A/skus?pageSize=100000", .wanted = production.refusal_invalid_argument },
        .{ .url = "https://cloudbilling.googleapis.com/v1/services/6F81-5844-456A/skus?pageSize=5001", .wanted = production.refusal_invalid_argument },
        .{ .url = "https://cloudbilling.googleapis.com/v1/services/6F81-5844-456A/skus?pageSize=-1", .wanted = production.refusal_invalid_argument },
        .{ .url = "https://cloudbilling.googleapis.com/v1/services?pageSize=6000", .wanted = production.refusal_invalid_argument },
        .{ .url = base ++ "&pageToken=bogus", .wanted = production.refusal_invalid_argument },
        .{ .url = base ++ "&currencyCode=XYZ", .wanted = production.refusal_invalid_argument },
        .{ .url = base ++ "&currencyCode=eur", .wanted = production.refusal_invalid_argument },
        .{ .url = base ++ "&startTime=2027-01-01T00:00:00Z&endTime=2027-01-02T00:00:00Z", .wanted = production.refusal_invalid_argument },
        .{ .url = base ++ "&endTime=2026-11-02T08:00:00Z", .wanted = production.refusal_invalid_argument },
        .{ .url = base ++ "&startTime=2026-11-03T00:00:00Z&endTime=2026-11-02T00:00:00Z", .wanted = production.refusal_invalid_argument },
        .{ .url = base ++ "&startTime=2026-09-15T00:00:00Z&endTime=2026-10-15T00:00:00Z", .wanted = production.refusal_invalid_argument },
        .{ .url = base ++ "&startTime=yesterday&endTime=2026-11-02T00:00:00Z", .wanted = production.refusal_bad_time },
        .{ .url = "https://cloudbilling.googleapis.com/v1/services/0000-0000-0000/skus?pageSize=2", .wanted = production.refusal_not_found },
        .{ .url = "https://cloudbilling.googleapis.com/v1/services/not-a-service/skus?pageSize=2", .wanted = production.refusal_not_found },
        .{ .url = "https://cloudbilling.googleapis.com/v1/services?pageSize=1", .wanted = production.refusal_unregistered, .bearer = null },
    };
    for (cases) |c| {
        const reply = try b.ask(a, c.url, c.bearer);
        const wanted = try std.json.parseFromSliceLeaky(std.json.Value, a, c.wanted, .{});
        const got = try std.json.parseFromSliceLeaky(std.json.Value, a, reply.body, .{});
        const we = wanted.object.get("error").?.object;
        const ge = got.object.get("error").?.object;
        testing.expectEqual(we.get("code").?.integer, @as(i64, reply.status)) catch |err| {
            std.debug.print("case {s}: status {d}\n", .{ c.url, reply.status });
            return err;
        };
        try testing.expectEqual(we.get("code").?.integer, ge.get("code").?.integer);
        try testing.expectEqualStrings(we.get("status").?.string, ge.get("status").?.string);
        try testing.expectEqualStrings(we.get("message").?.string, ge.get("message").?.string);
    }
}

test "pages: tokens are the offset in base64, the last page's is empty, a start alone runs to now" {
    var b: Bench = undefined;
    try b.init(null);
    defer b.deinit();
    try putProductionSkus(&b.fake);
    try b.fake.putService(.{ .id = "0017-8C5E-5B91", .display_name = "OpenLogic CentOS 7.8" });
    try b.fake.putService(.{ .id = "005A-0B51-C56E", .display_name = "Metabase" });

    var first = try b.client.listServices(.{ .page_size = 2 });
    defer first.deinit();
    try testing.expectEqualStrings("0017-8C5E-5B91", first.value.services[0].id);
    try testing.expectEqualStrings("Mg==", first.value.next_page_token.?);
    var rest = try b.client.listServices(.{ .page_size = 2, .page_token = "Mg==" });
    defer rest.deinit();
    try testing.expectEqual(1, rest.value.services.len);
    try testing.expectEqualStrings("6F81-5844-456A", rest.value.services[0].id);
    try testing.expectEqual(null, rest.value.next_page_token);

    var found = (try b.client.findService("Compute Engine")).?;
    defer found.deinit();
    try testing.expectEqualStrings("6F81-5844-456A", found.value.id);

    // From November's start: the price in force then (October 26's),
    // said to take effect at the start, and November 2's.
    var since = try b.client.listSkus("6F81-5844-456A", .{ .start_time = ts("2026-11-01T08:00:00Z") });
    defer since.deinit();
    const timeline = since.value.skus[1].pricing;
    try testing.expectEqual(2, timeline.len);
    try testing.expectEqual(ts("2026-11-01T08:00:00Z"), timeline[0].effective_time);
    try testing.expectEqual(14_980_000, timeline[0].unitPrice().?.toNanos());
    try testing.expectEqual(14_230_000, timeline[1].unitPrice().?.toNanos());

    // A range starting the moment a price changed: that price, once, said
    // to take effect then.
    var at_change = try b.client.listSkus("6F81-5844-456A", .{
        .start_time = ts("2026-10-05T07:00:00Z"),
        .end_time = ts("2026-10-12T07:00:00Z"),
    });
    defer at_change.deinit();
    const week = at_change.value.skus[1].pricing;
    try testing.expectEqual(1, week.len);
    try testing.expectEqual(ts("2026-10-05T07:00:00Z"), week[0].effective_time);
    try testing.expectEqual(14_300_000, week[0].unitPrice().?.toNanos());

    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const past_end = try b.ask(arena.allocator(), "https://cloudbilling.googleapis.com/v1/services?pageToken=OTk=", "t");
    try testing.expectEqual(501, past_end.status);
    const post = try b.fake.serve(.{ .method = .POST, .url = "https://cloudbilling.googleapis.com/v1/services", .bearer = "t" }, arena.allocator());
    try testing.expectEqual(501, post.status);
    const v2 = try b.ask(arena.allocator(), "https://cloudbilling.googleapis.com/v2beta/skus", "t");
    try testing.expectEqual(501, v2.status);
}

test "faults: a refusal is retried, a dropped connection too" {
    var b: Bench = undefined;
    try b.init(null);
    defer b.deinit();
    try putProductionSkus(&b.fake);
    b.fake.refuseNext(1, 503);
    b.fake.dropNext(1);
    var page = try b.client.listSkus("6F81-5844-456A", .{});
    defer page.deinit();
    try testing.expectEqual(2, page.value.skus.len);
    try testing.expectEqual(3, b.fake.callCount());
    b.fake.refuseNext(1, 403);
    try testing.expectError(error.PermissionDenied, b.client.listSkus("6F81-5844-456A", .{}));
    try testing.expectError(error.InvalidPut, b.fake.putSku(.{ .id = "AAAA-AAAA-AAAA", .service_id = "0000-0000-0000", .description = "", .prices = &.{.{ .from = ts("2026-01-01T00:00:00Z"), .tiers = &.{} }} }));
    try testing.expectError(error.InvalidPut, b.fake.putSku(.{ .id = "AAAA-AAAA-AAAA", .service_id = "6F81-5844-456A", .description = "", .prices = &.{} }));
    try testing.expectError(error.InvalidPut, b.fake.putSku(.{ .id = "AAAA-AAAA-AAAA", .service_id = "6F81-5844-456A", .description = "", .prices = &.{
        .{ .from = ts("2026-02-01T00:00:00Z"), .tiers = &.{} },
        .{ .from = ts("2026-01-01T00:00:00Z"), .tiers = &.{} },
    } }));
    try testing.expectError(error.InvalidPut, b.fake.setRate("eur", 1));
    try testing.expectError(error.InvalidPut, b.fake.putService(.{ .id = "x", .display_name = "x" }));
}

/// A catalog of random SKUs, each with up to four prices over the months
/// around milestone 0, read with random page sizes and ranges.
fn catalogProperty(_: void, input: []const u8) !void {
    const gpa = test_util.propertyAllocator();
    var g: test_util.ByteGen = .init(input);
    var clock: test_util.FakeClock = .{ .now_ns = test_util.milestone_0_ns };
    var fake: FakeBilling = .init(gpa, clock.io());
    defer fake.deinit();
    var token: test_util.FakeTokenProvider = .{ .token = "t" };
    var client: Client = try .init(gpa, clock.io(), .{ .token_provider = token.provider(), .transport = fake.transport(), .retry = .{ .max_attempts = 1 } });
    defer client.deinit();
    try fake.putService(.{ .id = "6F81-5844-456A", .display_name = "Compute Engine" });

    const count = g.intRange(usize, 0, 12);
    var model: std.ArrayList([2]i64) = .empty; // (id number, price count)
    defer model.deinit(gpa);
    var prices_buf: [4]FakeBilling.PutPrice = undefined;
    var tiers_buf: [4][1]FakeBilling.PutTier = undefined;
    var id_buf: [12][14]u8 = undefined;
    for (0..count) |i| {
        const n = g.intRange(u16, 0, 0xffff);
        const id = std.fmt.bufPrint(&id_buf[i], "{X:0>4}-0000-0000", .{n}) catch unreachable;
        const k = g.intRange(usize, 1, 4);
        // Mondays at midnight in Los Angeles, from 2026-09-07, one to
        // three weeks apart.
        var at: i64 = 1_788_764_400;
        for (0..k) |j| {
            tiers_buf[j] = .{.{ .usd_nanos = g.intRange(u32, 1, 100_000_000) }};
            prices_buf[j] = .{ .from = .{ .nanoseconds = @as(i96, at) * std.time.ns_per_s }, .tiers = &tiers_buf[j] };
            at += @as(i64, g.intRange(u8, 1, 3)) * 7 * std.time.s_per_day;
        }
        try fake.putSku(.{ .id = id, .service_id = "6F81-5844-456A", .description = "d", .prices = prices_buf[0..k] });
        var replaced = false;
        for (model.items) |*m| if (m[0] == n) {
            m[1] = @intCast(k);
            replaced = true;
        };
        if (!replaced) try model.append(gpa, .{ n, @intCast(k) });
    }
    std.mem.sortUnstable([2]i64, model.items, {}, struct {
        fn lt(_: void, a: [2]i64, b: [2]i64) bool {
            return a[0] < b[0];
        }
    }.lt);

    // Every SKU once, in order, whatever the page size.
    const size = g.intRange(u32, 1, 5);
    var seen: usize = 0;
    var next: ?[]const u8 = null;
    var token_copy: [32]u8 = undefined;
    while (true) {
        var page = try client.listSkus("6F81-5844-456A", .{ .page_size = size, .page_token = next });
        defer page.deinit();
        try testing.expect(page.value.skus.len <= size);
        for (page.value.skus) |sku| {
            var want: [14]u8 = undefined;
            try testing.expectEqualStrings(std.fmt.bufPrint(&want, "{X:0>4}-0000-0000", .{@as(u16, @intCast(model.items[seen][0]))}) catch unreachable, sku.id);
            // With no range, one price: the one in force now.
            try testing.expect(sku.pricing.len <= 1);
            seen += 1;
        }
        const t = page.value.next_page_token orelse break;
        @memcpy(token_copy[0..t.len], t);
        next = token_copy[0..t.len];
    }
    try testing.expectEqual(model.items.len, seen);

    // A random range: refused before sending exactly when the catalog
    // would refuse it, and otherwise every SKU's timeline is oldest first
    // and starts no earlier than the range.
    const back: i96 = @as(i96, g.intRange(u32, 0, 91 * 86_400)) - 86_400;
    const start: Timestamp = .{ .nanoseconds = test_util.milestone_0_ns - back * std.time.ns_per_s };
    const span: i96 = @as(i96, g.intRange(u32, 0, 40 * 86_400 + 3600)) - 3600;
    const end: ?Timestamp = if (g.boolean()) .{ .nanoseconds = start.nanoseconds + span * std.time.ns_per_s } else null;
    const problem = validate.rangeProblem(start, end, std.Io.Clock.real.now(clock.io()));
    if (client.listSkus("6F81-5844-456A", .{ .start_time = start, .end_time = end })) |page| {
        var p = page;
        defer p.deinit();
        try testing.expectEqual(null, problem);
        for (p.value.skus) |sku| {
            for (sku.pricing) |price| try testing.expect(price.effective_time.nanoseconds >= start.nanoseconds);
            if (sku.pricing.len > 1) for (sku.pricing[0 .. sku.pricing.len - 1], sku.pricing[1..]) |x, y| {
                try testing.expect(x.effective_time.nanoseconds < y.effective_time.nanoseconds);
            };
        }
    } else |err| {
        try testing.expectEqual(error.InvalidOptions, err);
        try testing.expect(problem != null);
    }
}

test "fuzz catalog: pages see every SKU once in order, ranges refused exactly as the catalog would" {
    try test_util.fuzzBytes({}, catalogProperty, .{ .corpus = &.{
        "\x05\x00\x01\x02\x03\x04\x05\x06\x07\x08\x09\x0a\x0b\x0c\x0d\x0e\x0f\x10\x11\x12\x13\x14\x15\x16\x17",
        "\x0c\xff\xfe\xfd\xfc\xfb\xfa\xf9\xf8\xf7\xf6\xf5\xf4\xf3\xf2\xf1\xf0\xef\xee\xed\xec\xeb\xea\xe9\xe8",
    } });
}
