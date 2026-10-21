//! Runs one API call: core's request engine builds the URL, attaches
//! credentials and the quota project, sends through the client's
//! transport, maps failures to errors and keeps `Diagnostics` and the log
//! current. BigQuery names a refusal's kind in its body
//! (`errors[].reason`) more truly than in its status, a rate limit coming
//! as 403 at times, so the engine reads the reason to decide a retry, and
//! the module turns the reasons a console acts on into errors of its own.

const std = @import("std");
const Allocator = std.mem.Allocator;
const core = @import("core");

const Client = @import("Client.zig");
const errors = @import("errors.zig");
const Error = errors.Error;

/// The OAuth scopes a client can ask its token provider for. BigQuery has
/// no `bigquery.readonly`; every read, a dry run and a query take any of
/// these, and a cancel only the first two (measured 2026-10-21).
pub const Scope = enum {
    /// `bigquery`, the default: everything here.
    bigquery,
    /// `cloud-platform`, for credentials already fixed to it.
    cloud_platform,
    /// `cloud-platform.read-only`: reads every Google Cloud API, so
    /// offered rather than the default. Production served the reads, a
    /// dry run, a query and its results with it, and refused a cancel.
    cloud_platform_read_only,

    pub fn url(self: Scope) []const u8 {
        return switch (self) {
            .bigquery => "https://www.googleapis.com/auth/bigquery",
            .cloud_platform => "https://www.googleapis.com/auth/cloud-platform",
            .cloud_platform_read_only => "https://www.googleapis.com/auth/cloud-platform.read-only",
        };
    }
};

/// The default scope's URL.
pub const scope = Scope.bigquery.url();

/// The shared engine, logging under this module's scope.
const Engine = core.rpc.Engine(.gcp_bigquery);

pub const Call = core.rpc.Call;

/// The engine, filled in from one client's settings.
fn engine(client: *Client) Engine {
    return .{
        .gpa = client.gpa,
        .io = client.io,
        .transport = client.transport,
        .base_url = client.base_url,
        .auth_scope = client.scope.url(),
        .token_provider = client.token_provider,
        .send_quota_project = client.send_quota_project,
        .retry = client.retry,
        .request_timeout_ms = client.request_timeout_ms,
        .diagnostics = client.diagnostics,
        .server_delay_out = &client.server_delay_ms,
        .classify_refusal = classify,
    };
}

/// Starts a public call: `Diagnostics` describe only the latest call.
pub fn begin(client: *Client) void {
    engine(client).begin();
}

/// Sends `call`, retrying transient failures, and returns the body of the
/// first 2xx response, which lives in `response`. A refusal whose reason a
/// console acts on is that reason's error.
pub fn execute(client: *Client, response: *std.heap.ArenaAllocator, call: Call) Error![]const u8 {
    return executeHeld(client, response, call, 0);
}

/// How much longer than the server is asked to hold a call the request
/// may take before it is `error.TimedOut`.
pub const hold_margin_ms = 30_000;

/// `execute` for a call the server holds up to `hold_ms` for a job to
/// finish (`timeoutMs`): the request's timeout rises to `hold_ms` and a
/// margin when the client's is shorter, so the call is never cut while the
/// server is waiting as asked.
pub fn executeHeld(client: *Client, response: *std.heap.ArenaAllocator, call: Call, hold_ms: u32) Error![]const u8 {
    var e = engine(client);
    if (e.request_timeout_ms != 0) e.request_timeout_ms = @max(e.request_timeout_ms, hold_ms +| hold_margin_ms);
    var local: ?[]const u8 = null;
    var with_body = call;
    const out = call.error_body_out orelse &local;
    with_body.error_body_out = out;
    return e.execute(response, with_body) catch |err| return refined(client, err, out.*);
}

/// The first `error.errors[].reason` of a refusal's body, or null for a
/// body without one.
pub fn firstReason(scratch: Allocator, body: []const u8) Allocator.Error!?[]const u8 {
    const value = std.json.parseFromSliceLeaky(std.json.Value, scratch, body, .{}) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return null,
    };
    if (value != .object) return null;
    const outer = value.object.get("error") orelse return null;
    if (outer != .object) return null;
    const list = outer.object.get("errors") orelse return null;
    if (list != .array or list.array.items.len == 0) return null;
    const first = list.array.items[0];
    if (first != .object) return null;
    const reason = first.object.get("reason") orelse return null;
    return if (reason == .string) reason.string else null;
}

/// For the engine: the reasons Google's clients retry are transient
/// whatever the status they come with.
fn classify(scratch: Allocator, http_status: u16, body: []const u8) Allocator.Error!?core.rpc.Error {
    _ = http_status;
    const reason = try firstReason(scratch, body) orelse return null;
    const map = std.StaticStringMap(core.rpc.Error).initComptime(.{
        .{ "rateLimitExceeded", error.ResourceExhausted },
        .{ "backendError", error.Unavailable },
        .{ "badGateway", error.Unavailable },
        .{ "internalError", error.Internal },
    });
    return map.get(reason);
}

/// The module's error for a failed call: a reason a console acts on, read
/// from the refusal's body, or the engine's mapping.
fn refined(client: *Client, err: Error, error_body: ?[]const u8) Error {
    if (err == error.ResponseTooLarge) {
        if (client.diagnostics) |d| d.print("the response was larger than max_response_bytes ({d}); ask for a smaller page_size", .{client.max_response_bytes});
        return err;
    }
    const body = error_body orelse return err;
    var scratch: std.heap.ArenaAllocator = .init(client.gpa);
    defer scratch.deinit();
    const reason = try firstReason(scratch.allocator(), body) orelse return err;
    return reasonError(reason) orelse err;
}

/// The module's error a refusal's reason stands for, or null for one the
/// engine's mapping covers.
pub fn reasonError(reason: []const u8) ?Error {
    const map = std.StaticStringMap(Error).initComptime(.{
        .{ "invalidQuery", error.InvalidQuery },
        .{ "bytesBilledLimitExceeded", error.BytesBilledLimitExceeded },
        .{ "responseTooLarge", error.ResultTooLarge },
        .{ "quotaExceeded", error.QuotaExceeded },
    });
    return map.get(reason);
}

pub fn decodeFailed(client: *Client, err: @import("codec.zig").DecodeError, what: []const u8) Error {
    if (err == error.InvalidResponse) {
        if (client.diagnostics) |d| d.print("the {s} response could not be decoded", .{what});
    }
    return err;
}

const testing = std.testing;

test "firstReason reads the first error's reason, or nothing" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try testing.expectEqualStrings("invalidQuery", (try firstReason(a, "{\"error\":{\"code\":400,\"errors\":[{\"reason\":\"invalidQuery\",\"location\":\"q\"},{\"reason\":\"other\"}]}}")).?);
    try testing.expectEqual(null, try firstReason(a, "{\"error\":{\"code\":403,\"message\":\"no errors list\"}}"));
    try testing.expectEqual(null, try firstReason(a, "{\"error\":{\"errors\":[]}}"));
    try testing.expectEqual(null, try firstReason(a, "{\"error\":{\"errors\":[{\"reason\":7}]}}"));
    try testing.expectEqual(null, try firstReason(a, "<html>bad gateway</html>"));
    try testing.expectEqual(null, try firstReason(a, "[]"));
    try testing.expectEqual(null, try firstReason(a, "{\"error\":\"x\"}"));
}

test "classify: Google's transient reasons, whatever the status; the rest left to it" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try testing.expectEqual(error.ResourceExhausted, (try classify(a, 403, "{\"error\":{\"errors\":[{\"reason\":\"rateLimitExceeded\"}]}}")).?);
    try testing.expectEqual(error.Unavailable, (try classify(a, 500, "{\"error\":{\"errors\":[{\"reason\":\"backendError\"}]}}")).?);
    try testing.expectEqual(error.Unavailable, (try classify(a, 502, "{\"error\":{\"errors\":[{\"reason\":\"badGateway\"}]}}")).?);
    try testing.expectEqual(error.Internal, (try classify(a, 500, "{\"error\":{\"errors\":[{\"reason\":\"internalError\"}]}}")).?);
    try testing.expectEqual(null, try classify(a, 400, "{\"error\":{\"errors\":[{\"reason\":\"invalidQuery\"}]}}"));
    try testing.expectEqual(null, try classify(a, 403, "{\"error\":{\"errors\":[{\"reason\":\"accessDenied\"}]}}"));
    // A job's own failure (a new job id would be needed) is no transient.
    try testing.expectEqual(null, try classify(a, 400, "{\"error\":{\"errors\":[{\"reason\":\"jobBackendError\"}]}}"));
    try testing.expectEqual(error.QuotaExceeded, reasonError("quotaExceeded").?);
    try testing.expectEqual(null, reasonError("notFound"));
}
