//! A Cloud Billing Catalog client: the services Google bills for, and a
//! service's SKUs with their list prices, the latest or over a range of
//! time. Read only: nothing here touches a billing account.
//!
//! Every call blocks the calling task until it completes, using the
//! `std.Io` and allocator passed to `init`. A client must not be used from
//! two tasks at once; give each task its own.

const Client = @This();

const std = @import("std");
const Allocator = std.mem.Allocator;
const core = @import("core");

const codec = @import("codec.zig");
const errors = @import("errors.zig");
const rpc = @import("rpc.zig");
const types = @import("types.zig");
const validate = @import("validate.zig");
const Diagnostics = core.Diagnostics;
const Error = errors.Error;
const HttpTransport = core.transport.HttpTransport;
const RetryPolicy = core.RetryPolicy;
const TokenProvider = core.TokenProvider;
const Transport = core.transport.Transport;

gpa: Allocator,
io: std.Io,
/// Owned. Scheme, host and port.
base_url: []const u8,
token_provider: TokenProvider,
scope: Scope,
/// Owned copy of `Options.currency_code`, or null for USD.
currency_code: ?[]const u8,
send_quota_project: bool,
retry: RetryPolicy,
request_timeout_ms: u32,
max_response_bytes: usize,
diagnostics: ?*Diagnostics,
transport: Transport,
/// The built-in transport, when `Options.transport` was null.
http: ?*HttpTransport,
/// Owned copy of `Options.user_agent`.
user_agent: []const u8,
/// The delay the last refused attempt asked for, kept by the engine.
server_delay_ms: ?u32 = null,

pub const default_endpoint = "https://cloudbilling.googleapis.com";

pub const Scope = rpc.Scope;

pub const Options = struct {
    /// Required. The catalog belongs to no project, but production refuses
    /// a call without credentials, and bills it to the token's project,
    /// where the Cloud Billing API must be enabled.
    token_provider: TokenProvider,
    /// `cloud-billing.readonly` by default; any of them reads everything.
    scope: Scope = .read_only,
    /// Prices in this ISO 4217 currency, such as `EUR`, converted by the
    /// server (and truncated to whole nanos) at the rate of the range's
    /// start. Null is USD. Three uppercase letters: production refuses
    /// `eur`.
    currency_code: ?[]const u8 = null,
    /// Overrides the host: a test server, say. Must be `https`, since it
    /// receives credentials.
    endpoint: ?[]const u8 = null,
    /// Sends the credentials' quota project as `x-goog-user-project`, as
    /// every module does.
    send_quota_project: bool = true,
    /// Every call is a read, retried on 5xx, 429 and dropped connections.
    retry: RetryPolicy = .{},
    /// How long one request may take before it is `error.TimedOut`, which
    /// is retried. A page of 5000 SKUs took 1 to 2.4 s when measured. 0
    /// removes the limit.
    request_timeout_ms: u32 = 30_000,
    /// A response whose decompressed body is larger fails with
    /// `error.ResponseTooLarge`. A page of 5000 Compute Engine SKUs is
    /// about 7.6 MB. Used by the built-in transport; a transport passed in
    /// keeps its own limit.
    max_response_bytes: usize = core.transport.default_max_response_bytes,
    /// Printable ASCII.
    user_agent: []const u8 = "gcp-zig-billing/0.64",
    /// Filled with details of every failed call; cleared by each new call.
    diagnostics: ?*Diagnostics = null,
    /// Sends requests through this instead of `std.http.Client`. Useful
    /// for tests, including tests of code that uses this library.
    transport: ?Transport = null,
};

/// Copies what it keeps from `options`; nothing borrowed outlives the call
/// except `diagnostics`, the token provider and the transport.
pub fn init(gpa: Allocator, io: std.Io, options: Options) Error!Client {
    const diag = options.diagnostics;
    if (diag) |d| d.clear();
    try checkOptions(options);
    const base_url = core.endpoint.baseUrl(gpa, options.endpoint orelse default_endpoint, .https) catch |err| {
        if (err == error.InvalidEndpoint) if (diag) |d| d.print("invalid endpoint: expected https://host[:port]", .{});
        return err;
    };
    errdefer gpa.free(base_url);
    // Every request carries a bearer token, which must not travel in
    // cleartext.
    if (!std.mem.startsWith(u8, base_url, "https://")) {
        if (diag) |d| d.print("invalid endpoint: endpoints that receive credentials must use https", .{});
        return error.InvalidEndpoint;
    }
    const currency_code = if (options.currency_code) |c| try gpa.dupe(u8, c) else null;
    errdefer if (currency_code) |c| gpa.free(c);
    const user_agent = try gpa.dupe(u8, options.user_agent);
    errdefer gpa.free(user_agent);

    var http: ?*HttpTransport = null;
    const transport = options.transport orelse t: {
        const h = try gpa.create(HttpTransport);
        h.* = .init(gpa, io, user_agent);
        h.max_response_bytes = options.max_response_bytes;
        http = h;
        break :t h.transport();
    };
    return .{
        .gpa = gpa,
        .io = io,
        .base_url = base_url,
        .token_provider = options.token_provider,
        .scope = options.scope,
        .currency_code = currency_code,
        .send_quota_project = options.send_quota_project,
        .retry = options.retry,
        .request_timeout_ms = options.request_timeout_ms,
        .max_response_bytes = options.max_response_bytes,
        .diagnostics = diag,
        .transport = transport,
        .http = http,
        .user_agent = user_agent,
    };
}

fn checkOptions(options: Options) Error!void {
    const diag = options.diagnostics;
    if (!options.retry.isValid()) {
        if (diag) |d| d.print("invalid retry policy: max_attempts must be at least 1, multiplier finite and at least 1", .{});
        return error.InvalidOptions;
    }
    if (!validate.isUserAgent(options.user_agent)) {
        if (diag) |d| d.print("invalid user agent: expected printable ASCII", .{});
        return error.InvalidOptions;
    }
    if (options.max_response_bytes == 0) {
        if (diag) |d| d.print("invalid max_response_bytes: 0 would refuse every answer", .{});
        return error.InvalidOptions;
    }
    if (options.currency_code) |c| if (!validate.isCurrencyCode(c)) {
        if (diag) |d| d.print("invalid currency_code: expected three uppercase letters, such as EUR", .{});
        return error.InvalidName;
    };
}

pub fn deinit(self: *Client) void {
    if (self.http) |h| {
        h.deinit();
        self.gpa.destroy(h);
    }
    if (self.currency_code) |c| self.gpa.free(c);
    self.gpa.free(self.user_agent);
    self.gpa.free(self.base_url);
    self.* = undefined;
}

/// One page of the services Google bills for, sorted by id. The default
/// page, 5000, held all 1,781 when measured.
pub fn listServices(self: *Client, options: types.ListServicesOptions) Error!types.Owned(types.ServicePage) {
    rpc.begin(self);
    try self.checkPage(options.page_size, options.page_token);
    var scratch: std.heap.ArenaAllocator = .init(self.gpa);
    defer scratch.deinit();
    const a = scratch.allocator();
    var w: std.Io.Writer.Allocating = .init(a);
    w.writer.writeAll("/v1/services") catch return error.OutOfMemory;
    var params: core.query.Params = .init(&w.writer);
    params.addNonZero("pageSize", options.page_size) catch return error.OutOfMemory;
    params.addOptional("pageToken", options.page_token) catch return error.OutOfMemory;

    var result: types.Owned(types.ServicePage) = try .init(self.gpa);
    errdefer result.deinit();
    const body = try rpc.execute(self, result.arena, .{ .method = .GET, .path = w.written() });
    result.value = codec.decodeServicePage(result.arena.allocator(), a, body) catch |err|
        return rpc.decodeFailed(self, err, "service list");
    return result;
}

/// The service whose display name is `display_name`, such as "Compute
/// Engine", read through every page; null when no service has it.
pub fn findService(self: *Client, display_name: []const u8) Error!?types.Owned(types.Service) {
    var token_buf: std.ArrayList(u8) = .empty;
    defer token_buf.deinit(self.gpa);
    var token: ?[]const u8 = null;
    while (true) {
        var page = try self.listServices(.{ .page_token = token });
        defer page.deinit();
        for (page.value.services) |s| {
            if (std.mem.eql(u8, s.display_name, display_name)) return try copyService(self.gpa, s);
        }
        const next = page.value.next_page_token orelse return null;
        if (token) |t| if (std.mem.eql(u8, t, next)) {
            if (self.diagnostics) |d| d.print("the service list answered the same page token twice", .{});
            return error.InvalidResponse;
        };
        token_buf.clearRetainingCapacity();
        try token_buf.appendSlice(self.gpa, next);
        token = token_buf.items;
    }
}

fn copyService(gpa: Allocator, s: types.Service) Allocator.Error!types.Owned(types.Service) {
    var result: types.Owned(types.Service) = try .init(gpa);
    errdefer result.deinit();
    const a = result.arena.allocator();
    result.value = .{
        .id = try a.dupe(u8, s.id),
        .name = try a.dupe(u8, s.name),
        .display_name = try a.dupe(u8, s.display_name),
        .business_entity = try a.dupe(u8, s.business_entity),
    };
    return result;
}

/// One page of a service's SKUs, sorted by id, each with its prices: the
/// latest, or every one in force during `options`' range. `service_id` is
/// such as `6F81-5844-456A` (Compute Engine); see `findService`.
pub fn listSkus(self: *Client, service_id: []const u8, options: types.ListSkusOptions) Error!types.Owned(types.SkuPage) {
    rpc.begin(self);
    if (!validate.isServiceId(service_id)) {
        if (self.diagnostics) |d| d.print("invalid service id: expected the form 6F81-5844-456A", .{});
        return error.InvalidName;
    }
    try self.checkPage(options.page_size, options.page_token);
    if (validate.rangeProblem(options.start_time, options.end_time, std.Io.Clock.real.now(self.io))) |why| {
        if (self.diagnostics) |d| d.print("invalid time range: {s}", .{why});
        return error.InvalidOptions;
    }
    var scratch: std.heap.ArenaAllocator = .init(self.gpa);
    defer scratch.deinit();
    const a = scratch.allocator();
    var w: std.Io.Writer.Allocating = .init(a);
    w.writer.print("/v1/services/{s}/skus", .{service_id}) catch return error.OutOfMemory;
    var params: core.query.Params = .init(&w.writer);
    params.addNonZero("pageSize", options.page_size) catch return error.OutOfMemory;
    params.addOptional("pageToken", options.page_token) catch return error.OutOfMemory;
    params.addOptional("currencyCode", self.currency_code) catch return error.OutOfMemory;
    addTime(&params, "startTime", options.start_time) catch return error.OutOfMemory;
    addTime(&params, "endTime", options.end_time) catch return error.OutOfMemory;

    var result: types.Owned(types.SkuPage) = try .init(self.gpa);
    errdefer result.deinit();
    const body = try rpc.execute(self, result.arena, .{ .method = .GET, .path = w.written() });
    result.value = codec.decodeSkuPage(result.arena.allocator(), a, body) catch |err|
        return rpc.decodeFailed(self, err, "SKU list");
    return result;
}

pub const ComputePricesOptions = struct {
    /// 0 is the server's 5000: Compute Engine's SKUs are then 7 pages.
    page_size: u32 = 0,
};

/// Every Compute Engine SKU, read a page at a time, as a `PriceList` of
/// machine prices in the client's currency. Each page is let go once
/// taken in, so this holds one page (about 7.6 MB) and the list (a few
/// hundred kilobytes) at once, never all 46 MB.
pub fn computePrices(self: *Client, options: ComputePricesOptions) Error!machine_prices.PriceList {
    var list: machine_prices.PriceList = try .init(self.gpa);
    errdefer list.deinit();
    var token_buf: std.ArrayList(u8) = .empty;
    defer token_buf.deinit(self.gpa);
    var token: ?[]const u8 = null;
    while (true) {
        var page = try self.listSkus(compute_engine_service_id, .{ .page_size = options.page_size, .page_token = token });
        defer page.deinit();
        list.add(page.value.skus) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            error.MixedCurrencies => {
                if (self.diagnostics) |d| d.print("the SKU list priced machines in more than one currency", .{});
                return error.InvalidResponse;
            },
        };
        const next = page.value.next_page_token orelse return list;
        if (token) |t| if (std.mem.eql(u8, t, next)) {
            if (self.diagnostics) |d| d.print("the SKU list answered the same page token twice", .{});
            return error.InvalidResponse;
        };
        token_buf.clearRetainingCapacity();
        try token_buf.appendSlice(self.gpa, next);
        token = token_buf.items;
    }
}

/// Compute Engine's service id.
pub const compute_engine_service_id = "6F81-5844-456A";

const machine_prices = @import("compute.zig");

fn addTime(params: *core.query.Params, name: []const u8, at: ?std.Io.Timestamp) std.Io.Writer.Error!void {
    var buf: [core.timestamp.max_len]u8 = undefined;
    try params.addOptional(name, if (at) |t| core.timestamp.format(&buf, t) else null);
}

fn checkPage(self: *Client, page_size: u32, page_token: ?[]const u8) Error!void {
    if (page_size > validate.max_page_size) {
        if (self.diagnostics) |d| d.print("invalid page_size: the server refuses more than {d}", .{validate.max_page_size});
        return error.InvalidOptions;
    }
    if (page_token) |t| if (!validate.isPageToken(t)) {
        if (self.diagnostics) |d| d.print("invalid page token: expected printable ASCII", .{});
        return error.InvalidName;
    };
}

const testing = std.testing;
const test_util = @import("test_util.zig");
const Harness = test_util.Harness;
const production = @import("production_bodies.zig");

fn ts(text: []const u8) std.Io.Timestamp {
    return core.timestamp.parse(text) catch unreachable;
}

test "golden: services and SKUs listed as production was asked" {
    var h: Harness = undefined;
    try h.initWith(&.{
        .{ .respond = .{ .body = production.services_small } },
        .{ .respond = .{ .body = production.skus_small } },
        .{ .respond = .{ .body = production.skus_october } },
        .{ .respond = .{ .body = production.skus_eur } },
    }, .{ .currency_code = "EUR" });
    defer h.deinit();

    var services = try h.client.listServices(.{ .page_size = 3 });
    defer services.deinit();
    try h.expectRequest(0, .GET, "https://cloudbilling.googleapis.com/v1/services?pageSize=3");
    try testing.expectEqual(3, services.value.services.len);
    try testing.expectEqualStrings("Mw==", services.value.next_page_token.?);

    var skus = try h.client.listSkus("6F81-5844-456A", .{ .page_size = 2, .page_token = "Mg==" });
    defer skus.deinit();
    try h.expectRequest(1, .GET, "https://cloudbilling.googleapis.com/v1/services/6F81-5844-456A/skus?pageSize=2&pageToken=Mg%3D%3D&currencyCode=EUR");
    try testing.expectEqual(2, skus.value.skus.len);

    var october = try h.client.listSkus("6F81-5844-456A", .{
        .start_time = ts("2026-10-01T07:00:00Z"),
        .end_time = ts("2026-10-31T06:59:59Z"),
    });
    defer october.deinit();
    try h.expectRequest(2, .GET, "https://cloudbilling.googleapis.com/v1/services/6F81-5844-456A/skus?currencyCode=EUR&startTime=2026-10-01T07%3A00%3A00Z&endTime=2026-10-31T06%3A59%3A59Z");
    try testing.expectEqual(5, october.value.skus[1].pricing.len);

    var since = try h.client.listSkus("6F81-5844-456A", .{ .start_time = ts("2026-11-01T08:00:00Z") });
    defer since.deinit();
    try h.expectRequest(3, .GET, "https://cloudbilling.googleapis.com/v1/services/6F81-5844-456A/skus?currencyCode=EUR&startTime=2026-11-01T08%3A00%3A00Z");
}

test "the calls refuse what production would, before sending" {
    var h: Harness = undefined;
    try h.init(&.{});
    defer h.deinit();
    const c = &h.client;
    try testing.expectError(error.InvalidOptions, c.listServices(.{ .page_size = 5001 }));
    try testing.expectEqualStrings("invalid page_size: the server refuses more than 5000", h.diag.message());
    try testing.expectError(error.InvalidName, c.listServices(.{ .page_token = "a b" }));
    try testing.expectError(error.InvalidName, c.listSkus("6f81-5844-456a", .{}));
    try testing.expectEqualStrings("invalid service id: expected the form 6F81-5844-456A", h.diag.message());
    try testing.expectError(error.InvalidName, c.listSkus("not-a-service", .{}));
    try testing.expectError(error.InvalidOptions, c.listSkus("6F81-5844-456A", .{ .page_size = 100_000 }));
    try testing.expectError(error.InvalidOptions, c.listSkus("6F81-5844-456A", .{ .end_time = ts("2026-11-02T08:00:00Z") }));
    try testing.expectEqualStrings("invalid time range: an end_time needs a start_time", h.diag.message());
    try testing.expectError(error.InvalidOptions, c.listSkus("6F81-5844-456A", .{
        .start_time = ts("2026-09-15T00:00:00Z"),
        .end_time = ts("2026-10-15T00:00:00Z"),
    }));
    try testing.expectEqualStrings("invalid time range: start_time and end_time must fall in one calendar month in Los Angeles", h.diag.message());
    try testing.expectError(error.InvalidOptions, c.listSkus("6F81-5844-456A", .{ .start_time = ts("2027-01-01T00:00:00Z") }));
    try testing.expectError(error.InvalidOptions, c.listSkus("6F81-5844-456A", .{ .start_time = ts("2026-10-20T00:00:00Z") }));
    try h.expectRequestCount(0);

    var bad_currency: Harness = undefined;
    try testing.expectError(error.InvalidName, bad_currency.initWith(&.{}, .{ .currency_code = "eur" }));
}

test "refusals carry production's words, and a 5xx is retried" {
    var h: Harness = undefined;
    try h.init(&.{
        .{ .respond = .{ .status = production.refusal_service_disabled_status, .body = production.refusal_service_disabled } },
        .{ .respond = .{ .status = production.refusal_not_found_status, .body = production.refusal_not_found } },
        .{ .respond = .{ .status = 503, .body = "{\"error\":{\"code\":503,\"message\":\"later\",\"status\":\"UNAVAILABLE\"}}" } },
        .{ .respond = .{ .body = production.skus_small } },
        .{ .respond = .{ .body = "{\"skus\":[{\"skuId\":\"no name\"}]}" } },
    });
    defer h.deinit();
    try testing.expectError(error.PermissionDenied, h.client.listServices(.{}));
    try testing.expect(std.mem.indexOf(u8, h.diag.message(), "Cloud Billing API has not been used in project") != null);
    try testing.expectError(error.NotFound, h.client.listSkus("0000-0000-0000", .{}));
    try testing.expect(std.mem.indexOf(u8, h.diag.message(), "Requested entity was not found.") != null);
    var retried = try h.client.listSkus("6F81-5844-456A", .{});
    defer retried.deinit();
    try testing.expectEqual(2, retried.value.skus.len);
    try testing.expectError(error.InvalidResponse, h.client.listSkus("6F81-5844-456A", .{}));
    try testing.expectEqualStrings("the SKU list response could not be decoded", h.diag.message());
}

test "findService: reads page after page until the name, or the end" {
    var h: Harness = undefined;
    try h.init(&.{
        .{ .respond = .{ .body = "{\"services\":[{\"name\":\"services/AAAA-0000-0001\",\"serviceId\":\"AAAA-0000-0001\",\"displayName\":\"Maps\"}],\"nextPageToken\":\"MQ==\"}" } },
        .{ .respond = .{ .body = "{\"services\":[{\"name\":\"services/6F81-5844-456A\",\"serviceId\":\"6F81-5844-456A\",\"displayName\":\"Compute Engine\",\"businessEntityName\":\"businessEntities/GCP\"}],\"nextPageToken\":\"\"}" } },
        .{ .respond = .{ .body = "{\"services\":[],\"nextPageToken\":\"Mg==\"}" } },
        .{ .respond = .{ .body = "{\"services\":[],\"nextPageToken\":\"Mg==\"}" } },
        .{ .respond = .{ .body = "{\"services\":[]}" } },
    });
    defer h.deinit();
    var found = (try h.client.findService("Compute Engine")).?;
    defer found.deinit();
    try testing.expectEqualStrings("6F81-5844-456A", found.value.id);
    try testing.expectEqualStrings("businessEntities/GCP", found.value.business_entity);
    try h.expectRequest(1, .GET, "https://cloudbilling.googleapis.com/v1/services?pageToken=MQ%3D%3D");
    // A server that hands back the token it was given would loop forever.
    try testing.expectError(error.InvalidResponse, h.client.findService("Nothing"));
    try testing.expectEqualStrings("the service list answered the same page token twice", h.diag.message());
    try testing.expectEqual(null, try h.client.findService("Nothing"));
}

test "computePrices: one currency, and a page token that does not repeat" {
    const usd = "{\"skus\":[{\"name\":\"services/6F81-5844-456A/skus/CF4E-A0C7-E3BF\",\"skuId\":\"CF4E-A0C7-E3BF\",\"description\":\"E2 Instance Core running in Americas\",\"category\":{\"resourceFamily\":\"Compute\",\"resourceGroup\":\"CPU\",\"usageType\":\"OnDemand\"},\"serviceRegions\":[\"us-central1\"],\"pricingInfo\":[{\"effectiveTime\":\"2026-11-04T08:00:00Z\",\"pricingExpression\":{\"usageUnit\":\"h\",\"baseUnitConversionFactor\":3600,\"tieredRates\":[{\"startUsageAmount\":0,\"unitPrice\":{\"currencyCode\":\"USD\",\"units\":\"0\",\"nanos\":21811590}}]}}]}],\"nextPageToken\":\"MQ==\"}";
    const eur = "{\"skus\":[{\"name\":\"services/6F81-5844-456A/skus/F449-33EC-A5EF\",\"skuId\":\"F449-33EC-A5EF\",\"description\":\"E2 Instance Ram running in Americas\",\"category\":{\"resourceFamily\":\"Compute\",\"resourceGroup\":\"RAM\",\"usageType\":\"OnDemand\"},\"serviceRegions\":[\"us-central1\"],\"pricingInfo\":[{\"effectiveTime\":\"2026-11-04T08:00:00Z\",\"pricingExpression\":{\"usageUnit\":\"GiBy.h\",\"baseUnitConversionFactor\":3865470566400,\"tieredRates\":[{\"startUsageAmount\":0,\"unitPrice\":{\"currencyCode\":\"EUR\",\"units\":\"0\",\"nanos\":2600000}}]}}]}],\"nextPageToken\":\"\"}";
    var h: Harness = undefined;
    try h.init(&.{
        .{ .respond = .{ .body = usd } },
        .{ .respond = .{ .body = eur } },
        .{ .respond = .{ .body = usd } },
        .{ .respond = .{ .body = usd } },
    });
    defer h.deinit();
    try testing.expectError(error.InvalidResponse, h.client.computePrices(.{}));
    try testing.expectEqualStrings("the SKU list priced machines in more than one currency", h.diag.message());
    try h.expectRequest(1, .GET, "https://cloudbilling.googleapis.com/v1/services/6F81-5844-456A/skus?pageToken=MQ%3D%3D");
    try testing.expectError(error.InvalidResponse, h.client.computePrices(.{}));
    try testing.expectEqualStrings("the SKU list answered the same page token twice", h.diag.message());
}

test "init refuses options no call could use" {
    var token: test_util.FakeTokenProvider = .{ .token = "t" };
    var diag: Diagnostics = .{};
    const io = std.Io.failing;
    try testing.expectError(error.InvalidEndpoint, init(testing.allocator, io, .{ .token_provider = token.provider(), .endpoint = "http://example.com", .diagnostics = &diag }));
    try testing.expectError(error.InvalidOptions, init(testing.allocator, io, .{ .token_provider = token.provider(), .user_agent = "a\nb" }));
    try testing.expectError(error.InvalidOptions, init(testing.allocator, io, .{ .token_provider = token.provider(), .max_response_bytes = 0 }));
    try testing.expectError(error.InvalidOptions, init(testing.allocator, io, .{ .token_provider = token.provider(), .retry = .{ .max_attempts = 0 } }));
    try testing.expectError(error.InvalidName, init(testing.allocator, io, .{ .token_provider = token.provider(), .currency_code = "EURO" }));
    var c = try init(testing.allocator, io, .{ .token_provider = token.provider(), .scope = .cloud_platform, .currency_code = "EUR" });
    defer c.deinit();
    try testing.expectEqualStrings("https://www.googleapis.com/auth/cloud-platform", c.scope.url());
}
