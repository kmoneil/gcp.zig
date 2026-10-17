//! Runs one API call: core's request engine builds the URL, attaches
//! credentials and the quota project the client chose, sends through the
//! client's transport, maps failures to errors and keeps `Diagnostics` and
//! the log current. This file binds that engine to a Resource Manager
//! client, sets the retry rule, and reads the refusals this module has
//! errors of its own for.

const std = @import("std");
const core = @import("core");

const Client = @import("Client.zig");
const codec = @import("codec.zig");
const errors = @import("errors.zig");
const types = @import("types.zig");
const Error = errors.Error;

/// The OAuth scope the client asks its token provider for: the narrowest
/// one the service config and discovery give every call here. A token with
/// only `cloudplatformprojects.readonly` also searched projects when
/// measured, but that scope is not listed for folder and organization
/// search.
pub const scope = "https://www.googleapis.com/auth/cloud-platform.read-only";

/// The shared engine, logging under this module's scope.
const Engine = core.rpc.Engine(.gcp_resource_manager);

/// The engine, filled in from one client's settings. There is no
/// unauthenticated mode: Resource Manager has no emulator.
fn engine(client: *Client) Engine {
    return .{
        .gpa = client.gpa,
        .io = client.io,
        .transport = client.transport,
        .base_url = client.base_url,
        .auth_scope = scope,
        .token_provider = client.token_provider,
        .send_quota_project = client.quota_project != .none,
        .retry = client.retry,
        .request_timeout_ms = client.request_timeout_ms,
        .diagnostics = client.diagnostics,
    };
}

/// Starts a public call: `Diagnostics` and the consumer refusal describe
/// only the latest call.
pub fn begin(client: *Client) void {
    engine(client).begin();
    client.refusal = null;
}

/// What every call here retries: what core retries, but for
/// `ResourceExhausted`. The searches share 4 calls a second and 240 a
/// minute per charged project with every other user of it, and core's
/// default would spend four more within 1.5 s. Google's own clients never
/// retry a search, and retry a get only on UNAVAILABLE; every call here is
/// a GET with no side effect, so the 500s and dropped connections core
/// retries are safe to try again.
pub fn retryable(err: anyerror, http_status: u16) bool {
    _ = http_status;
    return err != error.ResourceExhausted and core.isRetryable(err);
}

/// Sends a GET of `path` and returns the body of the first 2xx response,
/// which lives in `response`. `with_token` says the path carries a page
/// token, the only thing production refuses with nothing but "Request
/// contains an invalid argument.".
pub fn get(client: *Client, response: *std.heap.ArenaAllocator, path: []const u8, with_token: bool) Error![]const u8 {
    var local: core.Diagnostics = .{};
    var e = engine(client);
    if (e.diagnostics == null) e.diagnostics = &local;
    var error_body: ?[]const u8 = null;
    return e.execute(response, .{
        .method = .GET,
        .path = path,
        .retryable = retryable,
        .quota_project = switch (client.quota_project) {
            .project => |p| p,
            .none, .from_credentials => null,
        },
        .error_body_out = &error_body,
    }) catch |err| return mapped(client, err, e.diagnostics.?, error_body, with_token);
}

/// Production's words for a query it cannot read, measured on 2026-10-17:
/// "field [query] has issue [invalid syntax]", "field [query] has issue
/// [contains global restriction]", "field [filter] has issue [Could not
/// parse query]" for a query of one space, and "field [filter] has issue
/// [Parent id must be a number.]".
const query_refusals = [_][]const u8{ "field [query] has issue [", "field [filter] has issue [" };
/// Production's whole answer to a page token it did not issue.
const token_refusal = "Request contains an invalid argument.";
/// The 2020 answer for a disabled API, before ErrorInfo: "Cloud Resource
/// Manager API has not been used in project N before or it is disabled.
/// Enable it by visiting URL then retry. ..."
const disabled_sentence = " has not been used in project ";
const enable_sentence = "Enable it by visiting ";

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
    const message = diag.message();
    if (err == error.PermissionDenied) if (std.mem.indexOf(u8, message, disabled_sentence)) |at| {
        const digits_at = at + disabled_sentence.len;
        var end = digits_at;
        while (end < message.len and std.ascii.isDigit(message[end])) end += 1;
        if (end > digits_at) {
            const link: ?[]const u8 = if (std.mem.indexOf(u8, message, enable_sentence)) |e| link: {
                const start = e + enable_sentence.len;
                const stop = std.mem.indexOfScalarPos(u8, message, start, ' ') orelse message.len;
                break :link message[start..stop];
            } else null;
            client.setRefusal(.service_disabled, "projects/", message[digits_at..end], link);
            return error.ServiceDisabled;
        }
    };
    if (err == error.InvalidArgument) {
        for (query_refusals) |prefix| if (std.mem.startsWith(u8, message, prefix)) return error.InvalidQuery;
        if (with_token and std.mem.eql(u8, message, token_refusal)) return error.InvalidPageToken;
    }
    if (err == error.ResponseTooLarge) {
        diag.print("the response was larger than max_response_bytes ({d}); ask for a smaller page_size", .{client.max_response_bytes});
    }
    return err;
}

/// Reads a `SERVICE_DISABLED` or `USER_PROJECT_DENIED` ErrorInfo from
/// Google's own domain, and keeps its consumer and link in the client.
fn consumerRefusal(client: *Client, body: []const u8) std.mem.Allocator.Error!?types.ConsumerRefusal.Reason {
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
        client.setRefusal(reason, "", consumer, link);
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
