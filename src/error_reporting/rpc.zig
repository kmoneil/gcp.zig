//! Runs one API call: core's request engine builds the URL, attaches
//! credentials and the quota project, sends through the client's transport,
//! maps failures to errors and keeps `Diagnostics` and the log current. This
//! file binds that engine to an Error Reporting client, counts every attempt
//! against the client's budget, sets the retry rule, and reads the refusals
//! this module has errors of its own for.

const std = @import("std");
const Allocator = std.mem.Allocator;
const core = @import("core");

const Client = @import("Client.zig");
const budget_mod = @import("budget.zig");
const codec = @import("codec.zig");
const errors = @import("errors.zig");
const logging = @import("logging.zig");
const types = @import("types.zig");
const Error = errors.Error;

/// The OAuth scope the client asks its token provider for: the only one
/// discovery lists for these calls.
pub const scope = "https://www.googleapis.com/auth/cloud-platform";

/// The shared engine, logging under this module's scope.
const Engine = core.rpc.Engine(.gcp_error_reporting);

/// The engine, filled in from one client's settings. There is no
/// unauthenticated mode: Error Reporting has no emulator.
fn engine(client: *Client) Engine {
    return .{
        .gpa = client.gpa,
        .io = client.io,
        .transport = client.transport,
        .base_url = client.base_url,
        .auth_scope = scope,
        .token_provider = client.token_provider,
        .send_quota_project = client.send_quota_project,
        .retry = client.retry,
        .request_timeout_ms = client.request_timeout_ms,
        .diagnostics = client.diagnostics,
        .server_delay_out = &client.server_delay_ms,
    };
}

/// Starts a public call: `Diagnostics` and the consumer refusal describe
/// only the latest call.
pub fn begin(client: *Client) void {
    engine(client).begin();
    client.refusal = null;
}

/// What every call here retries: what core retries, but for
/// `ResourceExhausted`. The quota is 60 calls a minute per user, and a
/// retry within seconds would spend more of it for nothing. Google's own
/// clients retry 503 and 504, the group update too; the 500s and dropped
/// connections core retries are as safe, as every call here is a GET or a
/// PUT of the whole group.
pub fn retryable(err: anyerror, http_status: u16) bool {
    _ = http_status;
    return err != error.ResourceExhausted and core.isRetryable(err);
}

/// Sends one request and returns the body of the first 2xx response,
/// which lives in `response`. Each attempt is counted against the client's
/// budget first, and one the budget has no room for is not sent:
/// `error.ResourceExhausted`, with the wait in `Diagnostics`. A 429 holds
/// the budget back and is not retried. `with_token` says the path carries
/// a page token.
pub fn call(client: *Client, response: *std.heap.ArenaAllocator, method: core.transport.Method, path: []const u8, body: ?[]const u8, with_token: bool) Error![]const u8 {
    var local: core.Diagnostics = .{};
    var e = engine(client);
    if (e.diagnostics == null) e.diagnostics = &local;
    const diag = e.diagnostics.?;
    var attempt: u32 = 1;
    while (true) : (attempt += 1) {
        if (client.budget.take(client.io)) |wait_ms| {
            diag.print("local budget: {d} calls a minute are spent; the next is free in {d} ms", .{ client.budget.limit, wait_ms });
            return error.ResourceExhausted;
        }
        var error_body: ?[]const u8 = null;
        if (e.execute(response, .{
            .method = method,
            .path = path,
            .body = body,
            .retry = false,
            .error_body_out = &error_body,
        })) |answer| {
            return answer;
        } else |err| {
            if (err == error.ResourceExhausted) {
                const asked: i96 = @as(i96, client.server_delay_ms orelse 0) * std.time.ns_per_ms;
                client.budget.pauseFor(client.io, @max(budget_mod.Budget.refusal_pause_ns, asked));
            }
            if (attempt >= client.retry.max_attempts or !retryable(err, diag.http_status)) {
                return mapped(client, err, diag, error_body, with_token);
            }
            const delay_ms = client.retry.waitMs(attempt, core.rpc.entropy(client.io), client.server_delay_ms) orelse
                return mapped(client, err, diag, error_body, with_token);
            logging.warn("{t} {s} failed with {t}; retrying in {d} ms (attempt {d} of {d})", .{
                method, logPath(path), err, delay_ms, attempt + 1, client.retry.max_attempts,
            });
            _ = response.reset(.retain_capacity);
            try client.io.sleep(.fromMilliseconds(delay_ms), .awake);
        }
    }
}

/// The path without its query, which can hold service names and tokens.
fn logPath(path: []const u8) []const u8 {
    return path[0 .. std.mem.indexOfScalar(u8, path, '?') orelse path.len];
}

/// Production's words, measured on 2026-10-18: an id that names no group,
/// well-formed or not, is 400 "Invalid group id: ID", never 404.
const group_refusal = "Invalid group id: ";
/// A page token it did not issue.
const token_refusal = "Error while unescaping page_token in request.";
/// Buckets too narrow for the period.
const width_refusal = "'timed_count_duration' is too short for the requested period";

/// Maps the refusals this module has errors of its own for, and says what a
/// response too large to read means here.
fn mapped(client: *Client, err: Error, diag: *core.Diagnostics, error_body: ?[]const u8, with_token: bool) Error {
    if (err == error.PermissionDenied or err == error.InvalidArgument) {
        if (error_body) |body| {
            if (consumerRefusal(client, body) catch |e| return e) |reason| return switch (reason) {
                .service_disabled => error.ServiceDisabled,
                .quota_project_denied => error.QuotaProjectDenied,
            };
        }
    }
    if (err == error.InvalidArgument) {
        const message = diag.message();
        if (std.mem.startsWith(u8, message, group_refusal)) return error.NotFound;
        if (with_token and std.mem.eql(u8, message, token_refusal)) return error.InvalidPageToken;
        if (std.mem.eql(u8, message, width_refusal)) return error.InvalidOptions;
    }
    if (err == error.ResponseTooLarge) {
        diag.print("the response was larger than max_response_bytes ({d}); ask for a smaller page_size", .{client.max_response_bytes});
    }
    return err;
}

/// Reads a `SERVICE_DISABLED` or `USER_PROJECT_DENIED` ErrorInfo from
/// Google's own domain, and keeps its consumer and link in the client.
fn consumerRefusal(client: *Client, body: []const u8) Allocator.Error!?types.ConsumerRefusal.Reason {
    var scratch: std.heap.ArenaAllocator = .init(client.gpa);
    defer scratch.deinit();
    const infos = try core.errors.decodeErrorInfos(scratch.allocator(), body);
    for (infos) |info| {
        if (!std.mem.eql(u8, info.domain, "googleapis.com")) continue;
        const reason: types.ConsumerRefusal.Reason, const link_key: []const u8 =
            if (std.mem.eql(u8, info.reason, "SERVICE_DISABLED"))
                .{ .service_disabled, "activationUrl" }
            else if (std.mem.eql(u8, info.reason, "USER_PROJECT_DENIED"))
                .{ .quota_project_denied, "consoleUrl" }
            else
                continue;
        var consumer: []const u8 = "";
        var link: ?[]const u8 = null;
        for (info.metadata) |m| {
            if (std.mem.eql(u8, m.key, "consumer")) consumer = m.value;
            if (std.mem.eql(u8, m.key, link_key)) link = m.value;
        }
        client.setRefusal(reason, consumer, link);
        return reason;
    }
    return null;
}

pub fn decodeFailed(client: *Client, err: codec.DecodeError, what: []const u8) Error {
    if (err == error.InvalidResponse) {
        if (client.diagnostics) |d| d.print("the {s} response could not be decoded", .{what});
    }
    return err;
}

test "retryable: what core retries, but never a 429" {
    try std.testing.expect(retryable(error.Unavailable, 503));
    try std.testing.expect(retryable(error.Internal, 500));
    try std.testing.expect(retryable(error.DeadlineExceeded, 504));
    try std.testing.expect(retryable(error.ConnectionResetByPeer, 0));
    try std.testing.expect(!retryable(error.ResourceExhausted, 429));
    try std.testing.expect(!retryable(error.InvalidArgument, 400));
    try std.testing.expect(!retryable(error.PermissionDenied, 403));
}

test "logPath: the query never reaches the log" {
    try std.testing.expectEqualStrings("/v1beta1/projects/p/groupStats", logPath("/v1beta1/projects/p/groupStats?serviceFilter.service=secret"));
    try std.testing.expectEqualStrings("/v1beta1/projects/p/groups/G", logPath("/v1beta1/projects/p/groups/G"));
}
