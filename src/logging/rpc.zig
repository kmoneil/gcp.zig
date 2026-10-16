//! Runs one API call: core's request engine builds the URL, attaches
//! credentials, sends through the client's transport, maps failures to
//! errors and keeps `Diagnostics` and the log current. This file binds that
//! engine to a Logging client, and runs `entries.list`'s own retry loop,
//! which counts every attempt against the client's `ReadBudget`.

const std = @import("std");
const Allocator = std.mem.Allocator;
const core = @import("core");

const Client = @import("Client.zig");
const budget_mod = @import("budget.zig");
const codec = @import("codec.zig");
const errors = @import("errors.zig");
const log = @import("log.zig");
const Error = errors.Error;

/// The OAuth scope the client asks its token provider for: the narrowest
/// one every read here accepts. The effective rules in `logging_v2.yaml`
/// leave `logging.write` out of every read.
pub const scope = "https://www.googleapis.com/auth/logging.read";

/// The shared engine, logging under this module's scope.
const Engine = core.rpc.Engine(.gcp_logging);

pub const Call = core.rpc.Call;

/// The engine, filled in from one client's settings. There is no
/// unauthenticated mode: Logging has no emulator.
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
    };
}

/// Starts a public call: `Diagnostics` describe only the latest call.
pub fn begin(client: *Client) void {
    engine(client).begin();
}

/// What every call here retries: what core retries, but for
/// `ResourceExhausted`. A 429 is the read quota, 60 calls a minute, and
/// another try in the same minute only spends more of it. Google's own
/// clients never retry it either.
pub fn retryable(err: anyerror, http_status: u16) bool {
    _ = http_status;
    return err != error.ResourceExhausted and core.isRetryable(err);
}

/// Sends `call`, with the module's retry rule, and returns the body of the
/// first 2xx response, which lives in `response`.
pub fn execute(client: *Client, response: *std.heap.ArenaAllocator, call: Call) Error![]const u8 {
    var c = call;
    c.retryable = retryable;
    return engine(client).execute(response, c) catch |err| return mapped(client, err, null);
}

/// The path of every `entries.list`. `prettyPrint=false`: the server
/// indents by default, and the response limit counts decompressed bytes.
pub const list_path = "/v2/entries:list?prettyPrint=false";

/// Sends one `entries.list` body and returns the page's body, which lives
/// in `response`. Each attempt is counted against the client's read budget
/// first, and one the budget has no room for is not sent:
/// `error.ResourceExhausted`, with the wait in `Diagnostics`. A 429 spends
/// the budget's next minute and is not retried.
pub fn listEntries(client: *Client, response: *std.heap.ArenaAllocator, body: []const u8, headers: []const core.transport.Header) Error![]const u8 {
    var local: core.Diagnostics = .{};
    var e = engine(client);
    if (e.diagnostics == null) e.diagnostics = &local;
    const diag = e.diagnostics.?;
    var attempt: u32 = 1;
    while (true) : (attempt += 1) {
        if (client.budget.take(client.io)) |wait_ms| {
            diag.print("local read budget: {d} entries.list calls a minute are spent; the next is free in {d} ms", .{ client.budget.limit, wait_ms });
            return error.ResourceExhausted;
        }
        var error_body: ?[]const u8 = null;
        if (e.execute(response, .{ .method = .POST, .path = list_path, .body = body, .headers = headers, .retry = false, .error_body_out = &error_body })) |page| {
            return page;
        } else |err| {
            if (err == error.ResourceExhausted) client.budget.pauseFor(client.io, try quotaPauseNs(client, error_body));
            if (attempt >= client.retry.max_attempts or !retryable(err, diag.http_status)) return mapped(client, err, diag);
            const delay_ms = client.retry.backoffMs(attempt, core.rpc.entropy(client.io));
            log.warn("POST /v2/entries:list failed with {t}; retrying in {d} ms (attempt {d} of {d})", .{
                err, delay_ms, attempt + 1, client.retry.max_attempts,
            });
            _ = response.reset(.retain_capacity);
            try client.io.sleep(.fromMilliseconds(delay_ms), .awake);
        }
    }
}

/// How long a 429 holds calls back: until the quota window it names ends,
/// at least a second and at most a minute, or `ReadBudget.refusal_pause_ns`
/// when it names none. Production's 429 carries an `ErrorInfo` with
/// `quota_unit` "1/min/{project}" and `window_start_time` in Unix seconds;
/// measured on 2026-10-16, calls were served again 5.2 s after the 429,
/// where the window ended.
fn quotaPauseNs(client: *Client, error_body: ?[]const u8) Allocator.Error!i96 {
    const fallback = budget_mod.ReadBudget.refusal_pause_ns;
    const body = error_body orelse return fallback;
    var scratch: std.heap.ArenaAllocator = .init(client.gpa);
    defer scratch.deinit();
    const infos = try core.errors.decodeErrorInfos(scratch.allocator(), body);
    for (infos) |info| {
        if (!std.mem.eql(u8, info.reason, "RATE_LIMIT_EXCEEDED")) continue;
        for (info.metadata) |m| {
            if (!std.mem.eql(u8, m.key, "window_start_time")) continue;
            const start_s = std.fmt.parseInt(i64, m.value, 10) catch return fallback;
            const end_ns = (@as(i96, start_s) + 60) * std.time.ns_per_s;
            const now_ns = std.Io.Clock.real.now(client.io).nanoseconds;
            return std.math.clamp(end_ns - now_ns, std.time.ns_per_s, 60 * std.time.ns_per_s);
        }
    }
    return fallback;
}

/// Production's words for a filter it cannot read: "Unparseable filter:
/// syntax error at line 8, column 86, token '`'", seen through gRPC. The
/// REST body is captured in milestone 0.
const unparseable_filter = "Unparseable filter";
/// Production's words for a token sent with another request than its own,
/// as every client library's issue tracker quotes them.
const token_mismatch = "page_token doesn't match arguments";
/// Production's words for a filter naming a field no entry has, measured
/// on 2026-10-16: "Field not found: 'thud'."
const unknown_field = "Field not found: ";
/// Production's words for a token it did not issue, measured on
/// 2026-10-16.
const invalid_token = "Invalid page_token";

/// Maps the refusals this module has errors of its own for, and says what a
/// response too large to read means here.
fn mapped(client: *Client, err: Error, diag_or_null: ?*core.Diagnostics) Error {
    const diag = diag_or_null orelse client.diagnostics;
    if (err == error.InvalidArgument) if (diag) |d| {
        if (std.mem.indexOf(u8, d.message(), unparseable_filter) != null) return error.InvalidFilter;
        if (std.mem.startsWith(u8, d.message(), unknown_field)) return error.InvalidFilter;
        if (std.mem.indexOf(u8, d.message(), token_mismatch) != null) return error.InvalidPageToken;
        if (std.mem.eql(u8, d.message(), invalid_token)) return error.InvalidPageToken;
    };
    if (err == error.ResponseTooLarge) if (diag) |d| {
        d.print("the response was larger than max_response_bytes ({d}); ask for a smaller page_size", .{client.max_response_bytes});
    };
    return err;
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
