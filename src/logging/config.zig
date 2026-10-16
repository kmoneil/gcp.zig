//! Logs, buckets and views: what a picker lists before a query is made.
//! `logs.list` for a container or a view, `buckets.list` across locations,
//! bucket and view gets, and `picker`, which gathers a parent's buckets and
//! their views in the order a person looks for them.
//!
//! These are reads under no counted quota (the read quota counts
//! `entries.list`), retried as every call here is, a 429 never.

const std = @import("std");
const Allocator = std.mem.Allocator;
const Writer = std.Io.Writer;
const core = @import("core");

const Client = @import("Client.zig");
const codec = @import("codec.zig");
const errors = @import("errors.zig");
const names = @import("names.zig");
const rpc = @import("rpc.zig");
const types = @import("types.zig");
const validate = @import("validate.zig");
const Error = errors.Error;

pub fn listLogs(client: *Client, options: types.ListLogsOptions) Error!types.Owned(types.LogPage) {
    rpc.begin(client);
    const scope = options.scope orelse types.Scope{ .parent = .{ .project = client.project_id } };
    try checkScope(client, scope);
    try checkToken(client, options.page_token);
    var scratch: std.heap.ArenaAllocator = .init(client.gpa);
    defer scratch.deinit();
    var out: Writer.Allocating = .init(scratch.allocator());
    writePath(&out.writer, .{ .scope = scope }, "/logs", options.page_size, options.page_token) catch return error.OutOfMemory;

    var result: types.Owned(types.LogPage) = try .init(client.gpa);
    errdefer result.deinit();
    const body = try rpc.execute(client, result.arena, .{ .method = .GET, .path = out.written() });
    result.value = codec.decodeLogPage(result.arena.allocator(), body) catch |err| return rpc.decodeFailed(client, err, "log list");
    return result;
}

pub fn listBuckets(client: *Client, options: types.ListBucketsOptions) Error!types.Owned(types.BucketPage) {
    rpc.begin(client);
    const parent = options.parent orelse types.Parent{ .project = client.project_id };
    try checkScope(client, .{ .parent = parent });
    if (options.location) |l| if (!validate.isLocation(l)) {
        if (client.diagnostics) |d| d.print("invalid location: lowercase letters, digits and '-', such as \"global\"; null for every location", .{});
        return error.InvalidScope;
    };
    try checkToken(client, options.page_token);
    var scratch: std.heap.ArenaAllocator = .init(client.gpa);
    defer scratch.deinit();
    var out: Writer.Allocating = .init(scratch.allocator());
    writePath(&out.writer, .{ .buckets = .{ .parent = parent, .location = options.location orelse "-" } }, "/buckets", options.page_size, options.page_token) catch return error.OutOfMemory;

    var result: types.Owned(types.BucketPage) = try .init(client.gpa);
    errdefer result.deinit();
    const body = try rpc.execute(client, result.arena, .{ .method = .GET, .path = out.written() });
    result.value = codec.decodeBucketPage(result.arena.allocator(), body) catch |err| return rpc.decodeFailed(client, err, "bucket list");
    return result;
}

pub fn bucket(client: *Client, name: types.BucketName) Error!types.Owned(types.BucketInfo) {
    rpc.begin(client);
    try checkBucket(client, name);
    var scratch: std.heap.ArenaAllocator = .init(client.gpa);
    defer scratch.deinit();
    var out: Writer.Allocating = .init(scratch.allocator());
    writePath(&out.writer, .{ .bucket = name }, "", 0, null) catch return error.OutOfMemory;

    var result: types.Owned(types.BucketInfo) = try .init(client.gpa);
    errdefer result.deinit();
    const body = try rpc.execute(client, result.arena, .{ .method = .GET, .path = out.written() });
    result.value = codec.decodeBucket(result.arena.allocator(), body) catch |err| return rpc.decodeFailed(client, err, "bucket");
    return result;
}

pub fn listViews(client: *Client, bucket_name: types.BucketName, options: types.PageOptions) Error!types.Owned(types.ViewPage) {
    rpc.begin(client);
    try checkBucket(client, bucket_name);
    try checkToken(client, options.page_token);
    var scratch: std.heap.ArenaAllocator = .init(client.gpa);
    defer scratch.deinit();
    var out: Writer.Allocating = .init(scratch.allocator());
    writePath(&out.writer, .{ .bucket = bucket_name }, "/views", options.page_size, options.page_token) catch return error.OutOfMemory;

    var result: types.Owned(types.ViewPage) = try .init(client.gpa);
    errdefer result.deinit();
    const body = try rpc.execute(client, result.arena, .{ .method = .GET, .path = out.written() });
    result.value = codec.decodeViewPage(result.arena.allocator(), body) catch |err| return rpc.decodeFailed(client, err, "view list");
    return result;
}

pub fn view(client: *Client, name: types.ViewName) Error!types.Owned(types.ViewInfo) {
    rpc.begin(client);
    try checkScope(client, .{ .view = name });
    var scratch: std.heap.ArenaAllocator = .init(client.gpa);
    defer scratch.deinit();
    var out: Writer.Allocating = .init(scratch.allocator());
    writePath(&out.writer, .{ .scope = .{ .view = name } }, "", 0, null) catch return error.OutOfMemory;

    var result: types.Owned(types.ViewInfo) = try .init(client.gpa);
    errdefer result.deinit();
    const body = try rpc.execute(client, result.arena, .{ .method = .GET, .path = out.written() });
    result.value = codec.decodeView(result.arena.allocator(), body) catch |err| return rpc.decodeFailed(client, err, "view");
    return result;
}

/// Every bucket of `parent` in every location, each with its views,
/// following every page. A 403 on the bucket list is `list_denied` and an
/// empty picker; a 403 on one bucket's views is that bucket's
/// `views_denied`. Any other failure fails the call.
pub fn picker(client: *Client, parent: types.Parent) Error!types.Owned(types.Picker) {
    try checkScope(client, .{ .parent = parent });
    var result: types.Owned(types.Picker) = try .init(client.gpa);
    errdefer result.deinit();
    const a = result.arena.allocator();

    var buckets: std.ArrayList(types.PickerBucket) = .empty;
    var token: ?[]const u8 = null;
    while (true) {
        var page = listBuckets(client, .{ .parent = parent, .page_token = token }) catch |err| switch (err) {
            error.PermissionDenied => {
                result.value = .{ .buckets = &.{}, .list_denied = true };
                return result;
            },
            else => return err,
        };
        defer page.deinit();
        for (page.value.buckets) |b| try buckets.append(a, .{ .info = try copyBucket(a, b), .views = &.{}, .views_denied = false });
        token = if (page.value.next_page_token) |t| try a.dupe(u8, t) else break;
    }
    for (buckets.items) |*entry| {
        var views: std.ArrayList(types.ViewInfo) = .empty;
        var view_token: ?[]const u8 = null;
        while (true) {
            var page = listViews(client, entry.info.name, .{ .page_token = view_token }) catch |err| switch (err) {
                error.PermissionDenied => {
                    entry.views_denied = true;
                    break;
                },
                else => return err,
            };
            defer page.deinit();
            for (page.value.views) |v| try views.append(a, try copyView(a, v));
            view_token = if (page.value.next_page_token) |t| try a.dupe(u8, t) else break;
        }
        std.mem.sort(types.ViewInfo, views.items, {}, viewBefore);
        entry.views = views.items;
    }
    std.mem.sort(types.PickerBucket, buckets.items, {}, bucketBefore);
    if (client.diagnostics) |d| d.clear();
    result.value = .{ .buckets = buckets.items, .list_denied = false };
    return result;
}

fn rankBucket(id: []const u8) u8 {
    if (std.mem.eql(u8, id, "_Default")) return 0;
    if (std.mem.eql(u8, id, "_Required")) return 1;
    return 2;
}

fn bucketBefore(_: void, x: types.PickerBucket, y: types.PickerBucket) bool {
    const rx = rankBucket(x.info.name.bucket);
    const ry = rankBucket(y.info.name.bucket);
    if (rx != ry) return rx < ry;
    const by_location = std.mem.order(u8, x.info.name.location, y.info.name.location);
    if (by_location != .eq) return by_location == .lt;
    return std.mem.order(u8, x.info.name.bucket, y.info.name.bucket) == .lt;
}

fn rankView(id: []const u8) u8 {
    if (std.mem.eql(u8, id, "_Default")) return 0;
    if (std.mem.eql(u8, id, "_AllLogs")) return 1;
    return 2;
}

fn viewBefore(_: void, x: types.ViewInfo, y: types.ViewInfo) bool {
    const rx = rankView(x.name.view);
    const ry = rankView(y.name.view);
    if (rx != ry) return rx < ry;
    return std.mem.order(u8, x.name.view, y.name.view) == .lt;
}

fn copyParent(a: Allocator, p: types.Parent) Allocator.Error!types.Parent {
    return switch (p) {
        .project => |id| .{ .project = try a.dupe(u8, id) },
        .folder => |id| .{ .folder = try a.dupe(u8, id) },
        .organization => |id| .{ .organization = try a.dupe(u8, id) },
        .billing_account => |id| .{ .billing_account = try a.dupe(u8, id) },
    };
}

fn copyStrings(a: Allocator, list: []const []const u8) Allocator.Error![]const []const u8 {
    const out = try a.alloc([]const u8, list.len);
    for (list, out) |s, *o| o.* = try a.dupe(u8, s);
    return out;
}

fn copyBucket(a: Allocator, b: types.BucketInfo) Allocator.Error!types.BucketInfo {
    var out = b;
    out.name = .{ .parent = try copyParent(a, b.name.parent), .location = try a.dupe(u8, b.name.location), .bucket = try a.dupe(u8, b.name.bucket) };
    out.description = try a.dupe(u8, b.description);
    out.restricted_fields = try copyStrings(a, b.restricted_fields);
    return out;
}

fn copyView(a: Allocator, v: types.ViewInfo) Allocator.Error!types.ViewInfo {
    var out = v;
    out.name = .{
        .parent = try copyParent(a, v.name.parent),
        .location = try a.dupe(u8, v.name.location),
        .bucket = try a.dupe(u8, v.name.bucket),
        .view = try a.dupe(u8, v.name.view),
    };
    out.description = try a.dupe(u8, v.description);
    out.filter = try a.dupe(u8, v.filter);
    return out;
}

const Target = union(enum) {
    scope: types.Scope,
    bucket: types.BucketName,
    /// A parent's buckets in one location, or `-` for all.
    buckets: struct { parent: types.Parent, location: []const u8 },
};

/// `/v2/NAME` + `suffix`, then the page size and token, and
/// `prettyPrint=false`, which keeps answers small.
fn writePath(w: *Writer, target: Target, suffix: []const u8, page_size: u32, page_token: ?[]const u8) Writer.Error!void {
    try w.writeAll("/v2/");
    switch (target) {
        .scope => |s| try names.writeScope(w, s),
        .bucket => |b| try names.writeBucket(w, b),
        .buckets => |b| {
            try names.writeParent(w, b.parent);
            try w.print("/locations/{s}", .{b.location});
        },
    }
    try w.writeAll(suffix);
    var params: core.query.Params = .init(w);
    try params.addNonZero("pageSize", page_size);
    try params.addOptional("pageToken", page_token);
    try params.add("prettyPrint", "false");
}

fn checkScope(client: *Client, scope: types.Scope) Error!void {
    if (validate.isScope(scope)) return;
    if (client.diagnostics) |d| d.print("invalid scope: a parent id, location, bucket or view id breaks the naming rules", .{});
    return error.InvalidScope;
}

fn checkBucket(client: *Client, name: types.BucketName) Error!void {
    if (validate.isBucketName(name)) return;
    if (client.diagnostics) |d| d.print("invalid bucket name: a parent id, location or bucket id breaks the naming rules", .{});
    return error.InvalidScope;
}

fn checkToken(client: *Client, token: ?[]const u8) Error!void {
    const t = token orelse return;
    if (t.len > 0 and std.unicode.utf8ValidateSlice(t)) return;
    if (client.diagnostics) |d| d.print("invalid page token: expected the next_page_token of an earlier page", .{});
    return error.InvalidPageToken;
}

const testing = std.testing;
const test_util = @import("test_util.zig");
const production = @import("production_bodies.zig");

const base = "https://logging.googleapis.com";

test "golden: buckets across locations, as production listed them" {
    var h: test_util.Harness = undefined;
    try h.init(&.{
        .{ .respond = .{ .body = production.buckets_page } },
        .{ .respond = .{ .body = "{}" } },
    }, .{});
    defer h.deinit();
    var page = try h.client.listBuckets(.{});
    defer page.deinit();
    try h.expectRequest(0, .GET, base ++ "/v2/projects/extractctl/locations/-/buckets?prettyPrint=false", null);
    const list = page.value.buckets;
    try testing.expectEqual(2, list.len);
    try testing.expectEqual(null, page.value.next_page_token);
    try testing.expectEqualStrings("extractctl", list[0].name.parent.project);
    try testing.expectEqualStrings("global", list[0].name.location);
    try testing.expectEqualStrings("_Default", list[0].name.bucket);
    try testing.expectEqualStrings("Default bucket", list[0].description);
    try testing.expectEqual(30, list[0].retention_days);
    try testing.expectEqual(.active, list[0].state);
    try testing.expect(!list[0].locked);
    try testing.expectEqual(null, list[0].create_time);
    try testing.expectEqualStrings("_Required", list[1].name.bucket);
    try testing.expectEqualStrings("Audit bucket", list[1].description);
    try testing.expectEqual(400, list[1].retention_days);
    try testing.expect(list[1].locked);

    var next = try h.client.listBuckets(.{ .parent = .{ .folder = "12" }, .location = "europe-west1", .page_size = 5, .page_token = "a=b+c" });
    defer next.deinit();
    try h.expectRequest(1, .GET, base ++ "/v2/folders/12/locations/europe-west1/buckets?pageSize=5&pageToken=a%3Db%2Bc&prettyPrint=false", null);
    try testing.expectEqual(0, next.value.buckets.len);
}

test "golden: views, a bucket, a view, and production's refusals of each" {
    var h: test_util.Harness = undefined;
    try h.init(&.{
        .{ .respond = .{ .body = production.views_default } },
        .{ .respond = .{ .body = production.views_required } },
        .{ .respond = .{ .status = production.bucket_missing_status, .body = production.bucket_missing } },
        .{ .respond = .{ .status = production.view_missing_status, .body = production.view_missing } },
        .{ .respond = .{ .body = "{\"name\":\"projects/p/locations/eu/buckets/b\",\"createTime\":\"2026-10-16T09:00:00Z\",\"updateTime\":\"2026-10-16T09:00:01Z\",\"retentionDays\":\"90\",\"lifecycleState\":2,\"analyticsEnabled\":true,\"restrictedFields\":[\"jsonPayload.ssn\"]}" } },
        .{ .respond = .{ .body = "{\"name\":\"projects/p/locations/eu/buckets/b/views/v\",\"filter\":\"resource.type = \\\"gce_instance\\\"\",\"createTime\":\"2026-10-16T09:00:00Z\"}" } },
    }, .{});
    defer h.deinit();
    const default_bucket: types.BucketName = .{ .parent = .{ .project = "extractctl" }, .location = "global", .bucket = "_Default" };
    var views = try h.client.listViews(default_bucket, .{});
    defer views.deinit();
    try h.expectRequest(0, .GET, base ++ "/v2/projects/extractctl/locations/global/buckets/_Default/views?prettyPrint=false", null);
    try testing.expectEqual(2, views.value.views.len);
    try testing.expectEqualStrings("_AllLogs", views.value.views[0].name.view);
    try testing.expectEqualStrings("Access to all logs", views.value.views[0].description);
    try testing.expectEqualStrings("", views.value.views[0].filter);
    try testing.expectEqualStrings("_Default", views.value.views[1].name.view);
    try testing.expect(std.mem.startsWith(u8, views.value.views[1].filter, "NOT LOG_ID(\"cloudaudit.googleapis.com/data_access\")"));
    var required = try h.client.listViews(.{ .parent = .{ .project = "extractctl" }, .location = "global", .bucket = "_Required" }, .{ .page_size = 1 });
    defer required.deinit();
    try h.expectRequest(1, .GET, base ++ "/v2/projects/extractctl/locations/global/buckets/_Required/views?pageSize=1&prettyPrint=false", null);
    try testing.expectEqual(1, required.value.views.len);

    try testing.expectError(error.NotFound, h.client.bucket(.{ .parent = .{ .project = "extractctl" }, .location = "global", .bucket = "zigps-none" }));
    try h.expectRequest(2, .GET, base ++ "/v2/projects/extractctl/locations/global/buckets/zigps-none?prettyPrint=false", null);
    try testing.expectEqualStrings("Bucket `zigps-none` in location `global` does not exist", h.diag.message());
    try testing.expectError(error.NotFound, h.client.view(.{ .parent = .{ .project = "extractctl" }, .location = "global", .bucket = "_Default", .view = "zigps-none" }));
    try h.expectRequest(3, .GET, base ++ "/v2/projects/extractctl/locations/global/buckets/_Default/views/zigps-none?prettyPrint=false", null);

    var b = try h.client.bucket(.{ .parent = .{ .project = "p" }, .location = "eu", .bucket = "b" });
    defer b.deinit();
    try testing.expectEqual(1_792_141_200 * std.time.ns_per_s, b.value.create_time.?.nanoseconds);
    try testing.expectEqual(1_792_141_201 * std.time.ns_per_s, b.value.update_time.?.nanoseconds);
    try testing.expectEqual(90, b.value.retention_days);
    try testing.expectEqual(.delete_requested, b.value.state);
    try testing.expect(b.value.analytics_enabled);
    try testing.expectEqualStrings("jsonPayload.ssn", b.value.restricted_fields[0]);
    var v = try h.client.view(.{ .parent = .{ .project = "p" }, .location = "eu", .bucket = "b", .view = "v" });
    defer v.deinit();
    try testing.expectEqualStrings("resource.type = \"gce_instance\"", v.value.filter);
    try testing.expect(v.value.create_time != null);
}

test "golden: log names of a container and of a view, decoded" {
    var h: test_util.Harness = undefined;
    try h.init(&.{
        .{ .respond = .{ .body = "{\"logNames\":[\"projects/extractctl/logs/cloudaudit.googleapis.com%2Factivity\",\"projects/extractctl/logs/ping\"],\"nextPageToken\":\"n\"}" } },
        .{ .respond = .{ .body = "{\"logNames\":[]}" } },
    }, .{});
    defer h.deinit();
    var page = try h.client.listLogs(.{});
    defer page.deinit();
    try h.expectRequest(0, .GET, base ++ "/v2/projects/extractctl/logs?prettyPrint=false", null);
    try testing.expectEqualStrings("projects/extractctl/logs/cloudaudit.googleapis.com%2Factivity", page.value.log_names[0]);
    try testing.expectEqualStrings("cloudaudit.googleapis.com/activity", page.value.log_ids[0]);
    try testing.expectEqualStrings("ping", page.value.log_ids[1]);
    try testing.expectEqualStrings("n", page.value.next_page_token.?);
    var of_view = try h.client.listLogs(.{ .scope = .{ .view = .{ .parent = .{ .project = "p" }, .location = "global", .bucket = "_Default", .view = "_AllLogs" } }, .page_size = 2, .page_token = "n" });
    defer of_view.deinit();
    try h.expectRequest(1, .GET, base ++ "/v2/projects/p/locations/global/buckets/_Default/views/_AllLogs/logs?pageSize=2&pageToken=n&prettyPrint=false", null);
    try testing.expectEqual(0, of_view.value.log_names.len);
    try testing.expectEqual(null, of_view.value.next_page_token);
}

test "refusals before sending: names, locations and tokens" {
    var h: test_util.Harness = undefined;
    try h.init(&.{}, .{});
    defer h.deinit();
    const c = &h.client;
    try testing.expectError(error.InvalidScope, c.listLogs(.{ .scope = .{ .parent = .{ .project = "a b" } } }));
    try testing.expectError(error.InvalidPageToken, c.listLogs(.{ .page_token = "" }));
    try testing.expectError(error.InvalidScope, c.listBuckets(.{ .parent = .{ .folder = "x" } }));
    // Every location is null, never "-" spelled out.
    try testing.expectError(error.InvalidScope, c.listBuckets(.{ .location = "-" }));
    try testing.expectError(error.InvalidPageToken, c.listBuckets(.{ .page_token = "\xff" }));
    try testing.expectError(error.InvalidScope, c.bucket(.{ .parent = .{ .project = "p" }, .location = "-", .bucket = "b" }));
    try testing.expectError(error.InvalidScope, c.listViews(.{ .parent = .{ .project = "p" }, .location = "global", .bucket = "b/c" }, .{}));
    try testing.expectError(error.InvalidPageToken, c.listViews(.{ .parent = .{ .project = "p" }, .location = "global", .bucket = "b" }, .{ .page_token = "" }));
    try testing.expectError(error.InvalidScope, c.view(.{ .parent = .{ .project = "p" }, .location = "global", .bucket = "b", .view = "v.w" }));
    try testing.expectError(error.InvalidScope, c.picker(.{ .organization = "o" }));
    try h.expectRequestCount(0);
}

test "decode: bucket states by name and number, and what is no bucket" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const name = "\"name\":\"projects/p/locations/global/buckets/b\"";
    const cases = [_]struct { []const u8, types.BucketState }{
        .{ "{" ++ name ++ "}", .unspecified },
        .{ "{" ++ name ++ ",\"lifecycleState\":\"FAILED\"}", .failed },
        .{ "{" ++ name ++ ",\"lifecycleState\":\"CREATING\"}", .creating },
        .{ "{" ++ name ++ ",\"lifecycleState\":\"UPDATING\"}", .updating },
        .{ "{" ++ name ++ ",\"lifecycleState\":\"LIFECYCLE_STATE_UNSPECIFIED\"}", .unspecified },
        .{ "{" ++ name ++ ",\"lifecycleState\":\"MELTING\"}", .unknown },
        .{ "{" ++ name ++ ",\"lifecycleState\":1}", .active },
        .{ "{" ++ name ++ ",\"lifecycleState\":5}", .failed },
        .{ "{" ++ name ++ ",\"lifecycleState\":6}", .unknown },
        .{ "{" ++ name ++ ",\"lifecycleState\":-1}", .unknown },
        .{ "{" ++ name ++ ",\"lifecycleState\":true}", .unknown },
    };
    for (cases) |case| try testing.expectEqual(case[1], (try codec.decodeBucket(a, case[0])).state);
    for ([_][]const u8{
        "{}",
        "{\"name\":\"projects/p\"}",
        "{" ++ name ++ ",\"retentionDays\":-1}",
        "{" ++ name ++ ",\"createTime\":\"soon\"}",
        "[]",
    }) |body| try testing.expectError(error.InvalidResponse, codec.decodeBucket(a, body));
    try testing.expectError(error.InvalidResponse, codec.decodeView(a, "{\"name\":\"projects/p/locations/global/buckets/b\"}"));
    try testing.expectError(error.InvalidResponse, codec.decodeView(a, "{\"name\":\"projects/p/locations/global/buckets/b/views/v\",\"updateTime\":\"x\"}"));
    try testing.expectError(error.InvalidResponse, codec.decodeLogPage(a, "{\"logNames\":[1]}"));
    try testing.expectError(error.InvalidResponse, codec.decodeBucketPage(a, "{\"buckets\":[{}]}"));
    try testing.expectError(error.InvalidResponse, codec.decodeViewPage(a, "{\"views\":[{}]}"));
    try testing.expectEqual(null, (try codec.decodeViewPage(a, "{\"nextPageToken\":\"\"}")).next_page_token);
}

/// A bucket list answer of `ids`, all in `projects/p`, each `id@location`.
fn bucketsBody(comptime ids: []const []const u8, comptime token: ?[]const u8) []const u8 {
    comptime var body: []const u8 = "{\"buckets\":[";
    inline for (ids, 0..) |id_at, i| {
        const at = comptime std.mem.indexOfScalar(u8, id_at, '@').?;
        body = body ++ (if (i == 0) "" else ",") ++ "{\"name\":\"projects/p/locations/" ++ id_at[at + 1 ..] ++ "/buckets/" ++ id_at[0..at] ++ "\"}";
    }
    body = body ++ "]" ++ (if (token) |t| ",\"nextPageToken\":\"" ++ t ++ "\"" else "") ++ "}";
    return body;
}

fn viewsBody(comptime bucket_id: []const u8, comptime location: []const u8, comptime ids: []const []const u8) []const u8 {
    comptime var body: []const u8 = "{\"views\":[";
    inline for (ids, 0..) |id, i| body = body ++ (if (i == 0) "" else ",") ++ "{\"name\":\"projects/p/locations/" ++ location ++ "/buckets/" ++ bucket_id ++ "/views/" ++ id ++ "\"}";
    return body ++ "]}";
}

const denied: test_util.FakeTransport.Reply = .{ .respond = .{ .status = 403, .body = "{\"error\":{\"code\":403,\"message\":\"The caller does not have permission\",\"status\":\"PERMISSION_DENIED\"}}" } };

test "picker: every page, every bucket's views, in the order a person looks" {
    var h: test_util.Harness = undefined;
    try h.init(&.{
        .{ .respond = .{ .body = comptime bucketsBody(&.{ "zeta@us", "_Required@global" }, "page2") } },
        .{ .respond = .{ .body = comptime bucketsBody(&.{ "alpha@eu", "_Default@global", "beta@eu" }, null) } },
        // Views, a bucket at a time in the order listed.
        .{ .respond = .{ .body = comptime viewsBody("zeta", "us", &.{ "z2", "_AllLogs", "a1" }) } },
        .{ .respond = .{ .body = comptime viewsBody("_Required", "global", &.{"_AllLogs"}) } },
        denied,
        .{ .respond = .{ .body = "{\"views\":[{\"name\":\"projects/p/locations/global/buckets/_Default/views/_AllLogs\"}],\"nextPageToken\":\"v2\"}" } },
        .{ .respond = .{ .body = comptime viewsBody("_Default", "global", &.{"_Default"}) } },
        .{ .respond = .{ .body = "{}" } },
    }, .{});
    defer h.deinit();
    var p = try h.client.picker(.{ .project = "p" });
    defer p.deinit();
    try h.expectRequest(1, .GET, base ++ "/v2/projects/p/locations/-/buckets?pageToken=page2&prettyPrint=false", null);
    try h.expectRequest(6, .GET, base ++ "/v2/projects/p/locations/global/buckets/_Default/views?pageToken=v2&prettyPrint=false", null);
    try h.expectRequestCount(8);
    try testing.expect(!p.value.list_denied);
    const got = p.value.buckets;
    try testing.expectEqual(5, got.len);
    const order = [_][]const u8{ "_Default", "_Required", "alpha", "beta", "zeta" };
    for (order, got) |want, b| try testing.expectEqualStrings(want, b.info.name.bucket);
    // _Default's views from both pages, _Default first.
    try testing.expectEqualStrings("_Default", got[0].views[0].name.view);
    try testing.expectEqualStrings("_AllLogs", got[0].views[1].name.view);
    // alpha's view list was refused.
    try testing.expect(got[2].views_denied);
    try testing.expectEqual(0, got[2].views.len);
    try testing.expect(!got[3].views_denied);
    const zeta = got[4].views;
    try testing.expectEqualStrings("_AllLogs", zeta[0].name.view);
    try testing.expectEqualStrings("a1", zeta[1].name.view);
    try testing.expectEqualStrings("z2", zeta[2].name.view);
}

test "picker: a refused bucket list is list_denied; other failures fail" {
    var h: test_util.Harness = undefined;
    try h.init(&.{
        denied,
        .{ .respond = .{ .status = 404, .body = "{\"error\":{\"code\":404,\"message\":\"projects/p does not exist\",\"status\":\"NOT_FOUND\"}}" } },
        .{ .respond = .{ .body = comptime bucketsBody(&.{"_Default@global"}, null) } },
        .{ .respond = .{ .status = 400, .body = "{\"error\":{\"code\":400,\"message\":\"no\",\"status\":\"INVALID_ARGUMENT\"}}" } },
    }, .{});
    defer h.deinit();
    var refused = try h.client.picker(.{ .project = "p" });
    defer refused.deinit();
    try testing.expect(refused.value.list_denied);
    try testing.expectEqual(0, refused.value.buckets.len);
    try testing.expectError(error.NotFound, h.client.picker(.{ .project = "p" }));
    try testing.expectError(error.InvalidArgument, h.client.picker(.{ .project = "p" }));
}

test "picker: every allocation failure is OutOfMemory without leaks" {
    const Run = struct {
        fn run(gpa: Allocator) !void {
            var fake: test_util.FakeTransport = .init(testing.allocator, &.{
                .{ .respond = .{ .body = comptime bucketsBody(&.{ "b@eu", "_Default@global" }, null) } },
                .{ .respond = .{ .body = comptime viewsBody("b", "eu", &.{ "x", "_AllLogs" }) } },
                .{ .respond = .{ .body = comptime viewsBody("_Default", "global", &.{"_Default"}) } },
            });
            defer fake.deinit();
            var clock: test_util.FakeClock = .{};
            var token: test_util.FakeTokenProvider = .{};
            var client = try Client.init(gpa, clock.io(), .{ .project_id = "p", .token_provider = token.provider(), .transport = fake.transport() });
            defer client.deinit();
            var p = try client.picker(.{ .project = "p" });
            p.deinit();
        }
    };
    try testing.checkAllAllocationFailures(test_util.no_grow_allocator, Run.run, .{});
}
